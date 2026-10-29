using System.Net;
using Peel.Windows.Host.Pairing;
using Peel.Windows.Host.Runtime;
using Peel.Windows.Host.Security;

namespace Peel.Windows.Client.Services;

internal enum HostRuntimePauseReason
{
    SessionLocked,
    SystemSuspended,
}

internal sealed record HostRuntimeLifecycleState(
    bool IsRunning,
    string? Error,
    HostRuntimePauseReason? PauseReason,
    int? ControlPort,
    int? PairingPort,
    bool HasActivePeer,
    int ActiveStreamCount,
    bool IsClientVisible,
    bool IsPreventingSleep,
    string? AwakeError,
    HostPairingPin? PairingPin,
    IReadOnlyList<HostPairedClient> PairedClients,
    bool IsInputEnabled);

internal interface IHostRuntimeInstance : IAsyncDisposable
{
    event Action? StateChanged;

    bool IsRunning { get; }

    string? LastError { get; }

    IPEndPoint? ControlEndPoint { get; }

    IPEndPoint? PairingEndPoint { get; }

    string? ActivePeerIdentity { get; }

    int ActiveStreamCount { get; }

    bool IsClientVisible { get; }

    bool IsPreventingSleep { get; }

    string? AwakeError { get; }

    HostPairingPin? PairingPin { get; }

    IReadOnlyList<HostPairedClient> PairedClients { get; }

    bool IsInputEnabled { get; }

    ValueTask StartAsync(CancellationToken cancellationToken);

    ValueTask RefreshPairingAsync(CancellationToken cancellationToken);

    void SetInputEnabled(bool enabled);

    bool RemovePairedClient(string pairingId);
}

internal sealed class HostRuntimeLifecycleController : IAsyncDisposable
{
    private readonly object stateLock = new();
    private readonly SemaphoreSlim lifecycleGate = new(1, 1);
    private readonly CancellationTokenSource lifetimeCancellation = new();
    private readonly Func<IHostRuntimeInstance> runtimeFactory;
    private readonly Func<bool>? readInitialSessionLocked;
    private readonly HashSet<HostRuntimePauseReason> pauseReasons = [];
    private IHostRuntimeInstance? runtime;
    private string? lastError;
    private long requestedRuntimeGeneration;
    private long activeRuntimeGeneration;
    private bool startRequested;
    private bool initialSessionStateRead;
    private bool disposed;

    internal HostRuntimeLifecycleController()
        : this(static () => new WindowsHostRuntimeInstance(new WindowsHostRuntime(
            Utilities.StreamingPreferences.Load().CreateRuntimeOptions())))
    {
    }

    internal HostRuntimeLifecycleController(Func<bool> readInitialSessionLocked)
        : this(
            static () => new WindowsHostRuntimeInstance(new WindowsHostRuntime(
                Utilities.StreamingPreferences.Load().CreateRuntimeOptions())),
            readInitialSessionLocked ?? throw new ArgumentNullException(nameof(readInitialSessionLocked)))
    {
    }

    internal HostRuntimeLifecycleController(Func<IHostRuntimeInstance> runtimeFactory)
        : this(runtimeFactory, readInitialSessionLocked: null)
    {
    }

    internal HostRuntimeLifecycleController(
        Func<IHostRuntimeInstance> runtimeFactory,
        Func<bool>? readInitialSessionLocked)
    {
        this.runtimeFactory = runtimeFactory ?? throw new ArgumentNullException(nameof(runtimeFactory));
        this.readInitialSessionLocked = readInitialSessionLocked;
    }

    internal event Action? StateChanged;

    internal HostRuntimeLifecycleState State
    {
        get
        {
            lock (stateLock)
            {
                HostRuntimePauseReason? pauseReason = PrimaryPauseReasonLocked();
                IHostRuntimeInstance? activeRuntime =
                    startRequested &&
                    !disposed &&
                    activeRuntimeGeneration == requestedRuntimeGeneration
                        ? runtime
                        : null;
                return new HostRuntimeLifecycleState(
                    activeRuntime?.IsRunning == true && pauseReason is null,
                    lastError ?? activeRuntime?.LastError,
                    pauseReason,
                    activeRuntime?.ControlEndPoint?.Port,
                    activeRuntime?.PairingEndPoint?.Port,
                    activeRuntime?.ActivePeerIdentity is not null,
                    activeRuntime?.ActiveStreamCount ?? 0,
                    activeRuntime?.IsClientVisible == true,
                    activeRuntime?.IsPreventingSleep == true,
                    activeRuntime?.AwakeError,
                    activeRuntime?.PairingPin,
                    activeRuntime?.PairedClients ?? [],
                    activeRuntime?.IsInputEnabled == true && pauseReason is null);
            }
        }
    }

    internal Task StartAsync(CancellationToken cancellationToken = default)
    {
        lock (stateLock)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            ReadInitialSessionStateLocked();
            if (!startRequested)
            {
                startRequested = true;
                requestedRuntimeGeneration = checked(requestedRuntimeGeneration + 1);
            }
        }

        return ReconcileAsync(cancellationToken);
    }

    internal Task RestartAsync(CancellationToken cancellationToken = default)
    {
        return RequestFreshRuntimeAsync(startIfNeeded: false, cancellationToken);
    }

    internal Task RetryAsync(CancellationToken cancellationToken = default)
    {
        return RequestFreshRuntimeAsync(startIfNeeded: true, cancellationToken);
    }

    private Task RequestFreshRuntimeAsync(
        bool startIfNeeded,
        CancellationToken cancellationToken)
    {
        IHostRuntimeInstance? inputOwner;
        lock (stateLock)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (!startRequested && !startIfNeeded)
            {
                return Task.CompletedTask;
            }

            ReadInitialSessionStateLocked();
            if (!startRequested)
            {
                startRequested = true;
            }

            requestedRuntimeGeneration = checked(requestedRuntimeGeneration + 1);
            inputOwner = runtime;
        }

        if (inputOwner is not null)
        {
            try
            {
                inputOwner.SetInputEnabled(false);
            }
            catch (ObjectDisposedException)
            {
            }
            catch (Exception exception)
            {
                lock (stateLock)
                {
                    lastError = SafeError(exception);
                }
            }
        }

        RaiseStateChanged();
        return ReconcileAsync(cancellationToken);
    }

    private void ReadInitialSessionStateLocked()
    {
        if (initialSessionStateRead)
        {
            return;
        }

        if (readInitialSessionLocked is null)
        {
            initialSessionStateRead = true;
            return;
        }

        bool initiallyLocked;
        try
        {
            initiallyLocked = readInitialSessionLocked();
        }
        catch (Exception exception)
        {
            lastError = SafeError(exception);
            throw;
        }

        if (initiallyLocked)
        {
            pauseReasons.Add(HostRuntimePauseReason.SessionLocked);
        }
        else
        {
            pauseReasons.Remove(HostRuntimePauseReason.SessionLocked);
        }

        initialSessionStateRead = true;
        lastError = null;
    }

    internal Task SetPausedAsync(
        HostRuntimePauseReason reason,
        bool paused,
        CancellationToken cancellationToken = default)
    {
        if (!Enum.IsDefined(reason))
        {
            throw new ArgumentOutOfRangeException(nameof(reason));
        }

        IHostRuntimeInstance? inputOwner = null;
        bool changed;
        lock (stateLock)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            changed = paused ? pauseReasons.Add(reason) : pauseReasons.Remove(reason);
            if (changed && paused)
            {
                inputOwner = runtime;
            }
        }

        if (inputOwner is not null)
        {
            try
            {
                inputOwner.SetInputEnabled(false);
            }
            catch (ObjectDisposedException)
            {
                // A concurrent lifecycle pass already removed this runtime.
            }
            catch (Exception exception)
            {
                lock (stateLock)
                {
                    lastError = SafeError(exception);
                }
            }
        }

        if (changed)
        {
            RaiseStateChanged();
        }

        return ReconcileAsync(cancellationToken);
    }

    internal void SetInputEnabled(bool enabled)
    {
        IHostRuntimeInstance activeRuntime;
        lock (stateLock)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (pauseReasons.Count != 0)
            {
                throw new InvalidOperationException(
                    "Remote input cannot be enabled while Windows hosting is paused.");
            }

            if (activeRuntimeGeneration != requestedRuntimeGeneration)
            {
                throw new InvalidOperationException(
                    "Remote input cannot change while secure hosting is restarting.");
            }

            activeRuntime = runtime ??
                throw new InvalidOperationException("Secure hosting is not running.");
        }

        activeRuntime.SetInputEnabled(enabled);
        RaiseStateChanged();
    }

    internal async Task RefreshPairingAsync(CancellationToken cancellationToken = default)
    {
        await lifecycleGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            IHostRuntimeInstance activeRuntime;
            lock (stateLock)
            {
                ObjectDisposedException.ThrowIf(disposed, this);
                if (pauseReasons.Count != 0)
                {
                    throw new InvalidOperationException(
                        "Pairing cannot refresh while Windows hosting is paused.");
                }

                if (activeRuntimeGeneration != requestedRuntimeGeneration)
                {
                    throw new InvalidOperationException(
                        "Pairing cannot refresh while secure hosting is restarting.");
                }

                activeRuntime = runtime ??
                    throw new InvalidOperationException("Secure hosting is not running.");
            }

            await activeRuntime.RefreshPairingAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            lifecycleGate.Release();
        }

        RaiseStateChanged();
    }

    internal async Task<bool> RevokePairedClientAsync(
        string pairingId,
        CancellationToken cancellationToken = default)
    {
        IHostRuntimeInstance activeRuntime;
        bool removed;
        await lifecycleGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            lock (stateLock)
            {
                ObjectDisposedException.ThrowIf(disposed, this);
                if (pauseReasons.Count != 0 ||
                    activeRuntimeGeneration != requestedRuntimeGeneration)
                {
                    throw new InvalidOperationException(
                        "Paired devices cannot change while secure hosting is paused or restarting.");
                }

                activeRuntime = runtime ??
                    throw new InvalidOperationException("Secure hosting is not running.");
            }

            try
            {
                activeRuntime.SetInputEnabled(false);
            }
            catch (ObjectDisposedException)
            {
            }
            catch (Exception exception)
            {
                lock (stateLock)
                {
                    lastError = SafeError(exception);
                }
            }

            removed = activeRuntime.RemovePairedClient(pairingId);
        }
        finally
        {
            lifecycleGate.Release();
        }

        RaiseStateChanged();
        if (!removed)
        {
            return false;
        }

        // Credential removal is irreversible. Finish teardown even if the initiating
        // window closes so an already-authenticated or in-flight peer cannot survive.
        await RestartAsync(CancellationToken.None).ConfigureAwait(false);
        return true;
    }

    public async ValueTask DisposeAsync()
    {
        IHostRuntimeInstance? inputOwner;
        lock (stateLock)
        {
            if (disposed)
            {
                return;
            }

            disposed = true;
            startRequested = false;
            inputOwner = runtime;
        }

        if (inputOwner is not null)
        {
            try
            {
                inputOwner.SetInputEnabled(false);
            }
            catch (ObjectDisposedException)
            {
            }
            catch
            {
                // Runtime disposal still owns the final fail-closed teardown.
            }
        }

        lifetimeCancellation.Cancel();
        await ReconcileAsync(CancellationToken.None).ConfigureAwait(false);
        lifetimeCancellation.Dispose();
        lifecycleGate.Dispose();
    }

    private async Task ReconcileAsync(CancellationToken cancellationToken)
    {
        await lifecycleGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            while (true)
            {
                IHostRuntimeInstance? current;
                bool shouldRun;
                bool replaceCurrent;
                lock (stateLock)
                {
                    current = runtime;
                    shouldRun = startRequested && !disposed && pauseReasons.Count == 0;
                    replaceCurrent = shouldRun &&
                        current is not null &&
                        activeRuntimeGeneration != requestedRuntimeGeneration;
                }

                if ((!shouldRun || replaceCurrent) && current is not null)
                {
                    lock (stateLock)
                    {
                        if (!ReferenceEquals(runtime, current))
                        {
                            continue;
                        }

                        runtime = null;
                        activeRuntimeGeneration = 0;
                    }

                    current.StateChanged -= Runtime_StateChanged;
                    try
                    {
                        await current.DisposeAsync().ConfigureAwait(false);
                    }
                    catch (Exception exception)
                    {
                        lock (stateLock)
                        {
                            lastError = SafeError(exception);
                        }
                    }

                    RaiseStateChanged();
                    continue;
                }

                if (!shouldRun || current is not null)
                {
                    return;
                }

                IHostRuntimeInstance candidate;
                long candidateGeneration;
                lock (stateLock)
                {
                    candidateGeneration = requestedRuntimeGeneration;
                }

                try
                {
                    candidate = runtimeFactory();
                }
                catch (Exception exception)
                {
                    lock (stateLock)
                    {
                        lastError = SafeError(exception);
                    }

                    RaiseStateChanged();
                    return;
                }

                bool accepted;
                lock (stateLock)
                {
                    accepted = startRequested &&
                        !disposed &&
                        pauseReasons.Count == 0 &&
                        runtime is null &&
                        requestedRuntimeGeneration == candidateGeneration;
                    if (accepted)
                    {
                        runtime = candidate;
                        activeRuntimeGeneration = candidateGeneration;
                        lastError = null;
                    }
                }

                if (!accepted)
                {
                    await candidate.DisposeAsync().ConfigureAwait(false);
                    continue;
                }

                candidate.StateChanged += Runtime_StateChanged;
                RaiseStateChanged();
                try
                {
                    await candidate.StartAsync(lifetimeCancellation.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (lifetimeCancellation.IsCancellationRequested)
                {
                }
                catch (Exception exception)
                {
                    lock (stateLock)
                    {
                        if (ReferenceEquals(runtime, candidate))
                        {
                            runtime = null;
                            activeRuntimeGeneration = 0;
                            lastError = SafeError(exception);
                        }
                    }

                    candidate.StateChanged -= Runtime_StateChanged;
                    try
                    {
                        await candidate.DisposeAsync().ConfigureAwait(false);
                    }
                    catch (Exception cleanupException)
                    {
                        lock (stateLock)
                        {
                            lastError = SafeError(cleanupException);
                        }
                    }

                    RaiseStateChanged();
                    return;
                }

                RaiseStateChanged();
            }
        }
        finally
        {
            lifecycleGate.Release();
        }
    }

    private HostRuntimePauseReason? PrimaryPauseReasonLocked()
    {
        if (pauseReasons.Contains(HostRuntimePauseReason.SessionLocked))
        {
            return HostRuntimePauseReason.SessionLocked;
        }

        return pauseReasons.Contains(HostRuntimePauseReason.SystemSuspended)
            ? HostRuntimePauseReason.SystemSuspended
            : null;
    }

    private void Runtime_StateChanged() => RaiseStateChanged();

    private void RaiseStateChanged()
    {
        try
        {
            StateChanged?.Invoke();
        }
        catch
        {
            // UI observers do not own the secure Host lifecycle.
        }
    }

    private static string SafeError(Exception exception)
    {
        string message = exception.Message.Trim();
        return message.Length is 0 ? exception.GetType().Name : message;
    }

    private sealed class WindowsHostRuntimeInstance(WindowsHostRuntime owner)
        : IHostRuntimeInstance
    {
        public event Action? StateChanged
        {
            add => owner.StateChanged += value;
            remove => owner.StateChanged -= value;
        }

        public bool IsRunning => owner.IsRunning;

        public string? LastError => owner.LastError;

        public IPEndPoint? ControlEndPoint => owner.ControlEndPoint;

        public IPEndPoint? PairingEndPoint => owner.PairingEndPoint;

        public string? ActivePeerIdentity => owner.ActivePeerIdentity;

        public int ActiveStreamCount => owner.ActiveStreamCount;

        public bool IsClientVisible => owner.IsClientVisible;

        public bool IsPreventingSleep => owner.IsPreventingSleep;

        public string? AwakeError => owner.AwakeError;

        public HostPairingPin? PairingPin => owner.PairingPin;

        public IReadOnlyList<HostPairedClient> PairedClients => owner.PairedClients;

        public bool IsInputEnabled => owner.InputPermission.IsEnabled;

        public ValueTask StartAsync(CancellationToken cancellationToken) =>
            owner.StartAsync(cancellationToken);

        public ValueTask RefreshPairingAsync(CancellationToken cancellationToken) =>
            owner.RefreshPairingAsync(cancellationToken);

        public void SetInputEnabled(bool enabled) => owner.SetInputEnabled(enabled);

        public bool RemovePairedClient(string pairingId) => owner.RemovePairedClient(pairingId);

        public ValueTask DisposeAsync() => owner.DisposeAsync();
    }
}
