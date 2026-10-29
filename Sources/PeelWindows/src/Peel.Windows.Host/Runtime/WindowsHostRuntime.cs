using System.Net;
using Peel.Windows.Discovery;
using Peel.Windows.Host.Capture;
using Peel.Windows.Host.Encoding;
using Peel.Windows.Host.Input;
using Peel.Windows.Host.Networking;
using Peel.Windows.Host.Pairing;
using Peel.Windows.Host.Security;
using Peel.Windows.Protocol;
using Peel.Windows.Transport;

namespace Peel.Windows.Host.Runtime;

public sealed class WindowsHostRuntime : IAsyncDisposable
{
    private readonly object stateLock = new();
    private readonly SemaphoreSlim lifecycleGate = new(1, 1);
    private readonly CancellationTokenSource lifetimeCancellation = new();
    private readonly IPeelPskTransportFactory transportFactory;
    private readonly IPeelServiceRegistrar serviceRegistrar;
    private readonly WindowsPairedClientStore pairedClients;
    private readonly WindowsHostIdentityStore identityStore;
    private readonly IWindowCaptureBackend captureBackend;
    private readonly IVideoEncoderFactory encoderFactory;
    private readonly WindowsHostRuntimeOptions options;
    private readonly TimeProvider timeProvider;
    private readonly TimeSpan pairingLifetime;
    private readonly bool requireWindows;
    private readonly Func<IHostAwakeController> awakeControllerFactory;

    private HostAuthenticatedListener? authenticatedListener;
    private HostControlSessionManager? controlSessions;
    private HostVideoSessionManager? videoSessions;
    private PairingGeneration? pairingGeneration;
    private Task completion = Task.CompletedTask;
    private string? hostId;
    private string? lastError;
    private bool started;
    private bool disposed;

    public WindowsHostRuntime(WindowsHostRuntimeOptions? options = null)
        : this(
            new BouncyCastlePskTransportFactory(),
            new WindowsDnsSdRegistrar(),
            new WindowsPairedClientStore(),
            new WindowsHostIdentityStore(),
            new WindowsGraphicsCaptureBackend(),
            new MediaFoundationH264EncoderFactory(),
            options ?? new WindowsHostRuntimeOptions(),
            TimeProvider.System,
            HostPairingPin.DefaultLifetime,
            requireWindows: true,
            awakeControllerFactory: static () => new WindowsHostAwakeController())
    {
    }

    internal WindowsHostRuntime(
        IPeelPskTransportFactory transportFactory,
        IPeelServiceRegistrar serviceRegistrar,
        WindowsPairedClientStore pairedClients,
        WindowsHostIdentityStore identityStore,
        IWindowCaptureBackend captureBackend,
        IVideoEncoderFactory encoderFactory,
        WindowsHostRuntimeOptions options,
        TimeProvider? timeProvider = null,
        TimeSpan? pairingLifetime = null,
        bool requireWindows = false,
        Func<IHostAwakeController>? awakeControllerFactory = null)
    {
        this.transportFactory = PeelSecureTransport.Require(transportFactory);
        this.serviceRegistrar = serviceRegistrar ??
            throw new ArgumentNullException(nameof(serviceRegistrar));
        this.pairedClients = pairedClients ?? throw new ArgumentNullException(nameof(pairedClients));
        this.identityStore = identityStore ?? throw new ArgumentNullException(nameof(identityStore));
        this.captureBackend = captureBackend ?? throw new ArgumentNullException(nameof(captureBackend));
        this.encoderFactory = encoderFactory ?? throw new ArgumentNullException(nameof(encoderFactory));
        this.options = options ?? throw new ArgumentNullException(nameof(options));
        this.timeProvider = timeProvider ?? TimeProvider.System;
        this.pairingLifetime = pairingLifetime ?? HostPairingPin.DefaultLifetime;
        if (this.pairingLifetime <= TimeSpan.Zero || this.pairingLifetime > TimeSpan.FromHours(1))
        {
            throw new ArgumentOutOfRangeException(nameof(pairingLifetime));
        }

        this.requireWindows = requireWindows;
        this.awakeControllerFactory = awakeControllerFactory ??
            (static () => new NullHostAwakeController());
        InputPermission = new InputPermissionGate();
        InputPermission.SetEnabled(false);
    }

    public event Action? StateChanged;

    public InputPermissionGate InputPermission { get; }

    public bool IsRunning
    {
        get
        {
            lock (stateLock)
            {
                return started && !disposed && authenticatedListener is not null && lastError is null;
            }
        }
    }

    public string? HostId
    {
        get
        {
            lock (stateLock)
            {
                return hostId;
            }
        }
    }

    public HostPairingPin? PairingPin
    {
        get
        {
            lock (stateLock)
            {
                return pairingGeneration?.Pin;
            }
        }
    }

    public IPEndPoint? ControlEndPoint
    {
        get
        {
            lock (stateLock)
            {
                return authenticatedListener?.LocalEndPoint as IPEndPoint;
            }
        }
    }

    public IPEndPoint? PairingEndPoint
    {
        get
        {
            lock (stateLock)
            {
                return pairingGeneration?.Listener.LocalEndPoint as IPEndPoint;
            }
        }
    }

    public string? ActivePeerIdentity
    {
        get
        {
            lock (stateLock)
            {
                return controlSessions?.ActivePeerIdentity;
            }
        }
    }

    public int ActiveStreamCount
    {
        get
        {
            lock (stateLock)
            {
                return videoSessions?.ActiveStreamCount ?? 0;
            }
        }
    }

    public bool IsClientVisible
    {
        get
        {
            lock (stateLock)
            {
                return controlSessions?.IsActiveClientVisible == true;
            }
        }
    }

    public bool IsPreventingSleep
    {
        get
        {
            lock (stateLock)
            {
                return controlSessions?.IsPreventingSleep == true;
            }
        }
    }

    public string? AwakeError
    {
        get
        {
            lock (stateLock)
            {
                return controlSessions?.AwakeError;
            }
        }
    }

    public int PairedClientCount => pairedClients.Snapshot().Count;

    public IReadOnlyList<HostPairedClient> PairedClients => pairedClients.Snapshot();

    public string? LastError
    {
        get
        {
            lock (stateLock)
            {
                return lastError;
            }
        }
    }

    public Task Completion
    {
        get
        {
            lock (stateLock)
            {
                return completion;
            }
        }
    }

    public bool RemovePairedClient(string pairingId) => pairedClients.Remove(pairingId);

    public async ValueTask StartAsync(CancellationToken cancellationToken = default)
    {
        if (requireWindows && !OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
        {
            throw new PlatformNotSupportedException(
                "Peel Pro hosting requires Windows 10 version 2004 or later.");
        }

        await lifecycleGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            lock (stateLock)
            {
                ObjectDisposedException.ThrowIf(disposed, this);
                if (started)
                {
                    throw new InvalidOperationException("The Windows Host runtime was already started.");
                }

                started = true;
            }

            string stableHostId = identityStore.LoadOrCreate();
            var capabilities = new List<string> { PeelCapability.H264Video, PeelCapability.PerWindowVideoConnections,
                PeelCapability.BinaryVideoTransportV2, PeelCapability.ClientVisibility,
                PeelCapability.ExpandedKeyboard, PeelCapability.InputFocus };
            if (options.EnableHevc) capabilities.Add(PeelCapability.HevcVideo);
            capabilities.Add(ClientStreamMetricsMessage.Capability);
            if (options.MachineStatusProvider is not null) capabilities.Add(PeelCapability.MachineStatus);
            if (options.AudioSharing?.Supported == true) capabilities.Add("mac-system-audio-v1");
            // This runtime always composes the SendInput-backed input session, which posts
            // source media keys, and the Core Audio default-output backend for systemOutput
            // volume/mute. peelStream remains unsupported under the same capability.
            capabilities.Add(SourceMediaProtocol.MediaKeysCapability);
            var sourceVolume = new Audio.WindowsSystemOutputVolume();
            capabilities.Add(SourceMediaProtocol.VolumeCapability);
            var controlOptions = new HostControlSessionOptions(
                options.HostName,
                Environment.OSVersion.VersionString,
                options.AppVersion,
                capabilities: capabilities)
            { MachineStatusProvider = options.MachineStatusProvider, MachineStatusCredentials = pairedClients,
                AudioSharing = options.AudioSharing, AudioCredentials = pairedClients, SourceVolume = sourceVolume };
            var createdControlSessions = new HostControlSessionManager(
                InputPermission,
                controlOptions,
                peerIdentity =>
                {
                    if (pairedClients.UpdateLastSeen(peerIdentity))
                    {
                        RaiseStateChanged();
                    }
                },
                awakeControllerFactory(),
                RaiseStateChanged);
            var createdVideoSessions = new HostVideoSessionManager(
                createdControlSessions,
                captureBackend,
                encoderFactory,
                new HostVideoSessionOptions(options.VideoSettings, enableHevc: options.EnableHevc));
            var createdAuthenticatedListener = new HostAuthenticatedListener(
                transportFactory,
                pairedClients,
                createdControlSessions,
                createdVideoSessions);

            try
            {
                await createdAuthenticatedListener.StartAsync(
                        new IPEndPoint(options.ListenAddress, options.ControlPort),
                        lifetimeCancellation.Token)
                    .ConfigureAwait(false);
                IPEndPoint controlEndPoint = RequireIpEndPoint(
                    createdAuthenticatedListener.LocalEndPoint,
                    "authenticated");
                PairingGeneration createdPairing = await CreatePairingGenerationAsync(
                        stableHostId,
                        checked((ushort)controlEndPoint.Port),
                        lifetimeCancellation.Token)
                    .ConfigureAwait(false);

                lock (stateLock)
                {
                    hostId = stableHostId;
                    controlSessions = createdControlSessions;
                    videoSessions = createdVideoSessions;
                    authenticatedListener = createdAuthenticatedListener;
                    pairingGeneration = createdPairing;
                    completion = RunLifetimeAsync();
                }
            }
            catch
            {
                await createdAuthenticatedListener.DisposeAsync().ConfigureAwait(false);
                throw;
            }
        }
        catch (Exception exception)
        {
            lock (stateLock)
            {
                lastError = SafeError(exception);
            }

            InputPermission.SetEnabled(false);
            RaiseStateChanged();
            throw;
        }
        finally
        {
            lifecycleGate.Release();
        }

        RaiseStateChanged();
    }

    public void SetInputEnabled(bool enabled)
    {
        lock (stateLock)
        {
            if (enabled &&
                (!started || disposed || authenticatedListener is null || lastError is not null))
            {
                throw new InvalidOperationException(
                    "Remote input cannot be enabled while secure hosting is offline.");
            }

            InputPermission.SetEnabled(enabled);
        }

        RaiseStateChanged();
    }

    public async ValueTask RefreshPairingAsync(CancellationToken cancellationToken = default)
    {
        Exception? refreshFailure = null;
        await lifecycleGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            string stableHostId;
            HostAuthenticatedListener activeAuthenticatedListener;
            PairingGeneration? previous;
            lock (stateLock)
            {
                if (!started ||
                    lastError is not null ||
                    hostId is null ||
                    authenticatedListener is null)
                {
                    throw new InvalidOperationException("Secure hosting is not running.");
                }

                stableHostId = hostId;
                activeAuthenticatedListener = authenticatedListener;
                previous = pairingGeneration;
            }

            IPEndPoint controlEndPoint = RequireIpEndPoint(
                activeAuthenticatedListener.LocalEndPoint,
                "authenticated");
            PairingGeneration replacement = await CreatePairingGenerationListenerAsync(
                    stableHostId,
                    lifetimeCancellation.Token)
                .ConfigureAwait(false);

            try
            {
                if (previous is not null)
                {
                    await previous.DisposeAdvertisementsAsync().ConfigureAwait(false);
                }

                await RegisterAdvertisementsAsync(
                        replacement,
                        stableHostId,
                        checked((ushort)controlEndPoint.Port),
                        lifetimeCancellation.Token)
                    .ConfigureAwait(false);
            }
            catch
            {
                await replacement.DisposeAsync().ConfigureAwait(false);
                throw;
            }

            lock (stateLock)
            {
                pairingGeneration = replacement;
            }

            if (previous is not null)
            {
                await previous.DisposeListenerAsync().ConfigureAwait(false);
            }
        }
        catch (Exception exception)
        {
            refreshFailure = exception;
            lock (stateLock)
            {
                lastError = SafeError(exception);
            }

            InputPermission.SetEnabled(false);
            lifetimeCancellation.Cancel();
        }
        finally
        {
            lifecycleGate.Release();
        }

        if (refreshFailure is not null)
        {
            await StopResourcesAsync().ConfigureAwait(false);
            RaiseStateChanged();
            System.Runtime.ExceptionServices.ExceptionDispatchInfo
                .Capture(refreshFailure)
                .Throw();
        }

        RaiseStateChanged();
    }

    public async ValueTask DisposeAsync()
    {
        lock (stateLock)
        {
            if (disposed)
            {
                return;
            }

            disposed = true;
        }

        InputPermission.SetEnabled(false);
        lifetimeCancellation.Cancel();
        Exception? cleanupFailure = null;
        try
        {
            await StopResourcesAsync().ConfigureAwait(false);
        }
        catch (Exception exception)
        {
            cleanupFailure = exception;
        }

        try
        {
            Task activeCompletion = Completion;
            try
            {
                await activeCompletion.ConfigureAwait(false);
            }
            catch (Exception) when (lifetimeCancellation.IsCancellationRequested)
            {
            }
        }
        finally
        {
            lifetimeCancellation.Dispose();
            lifecycleGate.Dispose();
            RaiseStateChanged();
        }

        if (cleanupFailure is not null)
        {
            System.Runtime.ExceptionServices.ExceptionDispatchInfo
                .Capture(cleanupFailure)
                .Throw();
        }
    }

    private async Task RunLifetimeAsync()
    {
        try
        {
            while (!lifetimeCancellation.IsCancellationRequested)
            {
                HostAuthenticatedListener activeAuthenticatedListener;
                PairingGeneration activePairing;
                lock (stateLock)
                {
                    activeAuthenticatedListener = authenticatedListener ??
                        throw new InvalidOperationException("The authenticated listener is unavailable.");
                    activePairing = pairingGeneration ??
                        throw new InvalidOperationException("The pairing listener is unavailable.");
                }

                TimeSpan remaining = activePairing.Pin.ExpiresAt - timeProvider.GetUtcNow();
                if (remaining < TimeSpan.Zero)
                {
                    remaining = TimeSpan.Zero;
                }

                Task delay = Task.Delay(remaining, timeProvider, lifetimeCancellation.Token);
                Task finished = await Task.WhenAny(
                        delay,
                        activeAuthenticatedListener.Completion,
                        activePairing.Listener.Completion)
                    .ConfigureAwait(false);

                if (lifetimeCancellation.IsCancellationRequested)
                {
                    return;
                }

                if (ReferenceEquals(finished, delay))
                {
                    await RefreshPairingAsync(lifetimeCancellation.Token).ConfigureAwait(false);
                    continue;
                }

                lock (stateLock)
                {
                    if (!ReferenceEquals(activePairing, pairingGeneration))
                    {
                        continue;
                    }
                }

                await finished.ConfigureAwait(false);
                throw new IOException("A secure Host listener stopped unexpectedly.");
            }
        }
        catch (OperationCanceledException) when (lifetimeCancellation.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            lock (stateLock)
            {
                lastError = SafeError(exception);
            }

            InputPermission.SetEnabled(false);
            await StopResourcesAsync().ConfigureAwait(false);
            RaiseStateChanged();
            throw;
        }
    }

    private async ValueTask<PairingGeneration> CreatePairingGenerationAsync(
        string stableHostId,
        ushort controlPort,
        CancellationToken cancellationToken)
    {
        PairingGeneration generation = await CreatePairingGenerationListenerAsync(
                stableHostId,
                cancellationToken)
            .ConfigureAwait(false);
        try
        {
            await RegisterAdvertisementsAsync(
                    generation,
                    stableHostId,
                    controlPort,
                    cancellationToken)
                .ConfigureAwait(false);
            return generation;
        }
        catch
        {
            await generation.DisposeAsync().ConfigureAwait(false);
            throw;
        }
    }

    private async ValueTask<PairingGeneration> CreatePairingGenerationListenerAsync(
        string stableHostId,
        CancellationToken cancellationToken)
    {
        HostPairingPin pin = HostPairingPin.Generate(
            timeProvider.GetUtcNow(),
            pairingLifetime);
        var listener = new HostPinPairingListener(
            transportFactory,
            pairedClients,
            stableHostId,
            options.HostName,
            options.ServiceName,
            pin);
        try
        {
            await listener.StartAsync(
                    new IPEndPoint(options.ListenAddress, options.PairingPort),
                    cancellationToken)
                .ConfigureAwait(false);
            _ = RequireIpEndPoint(listener.LocalEndPoint, "pairing");
            return new PairingGeneration(pin, listener);
        }
        catch
        {
            await listener.DisposeAsync().ConfigureAwait(false);
            throw;
        }
    }

    private async ValueTask RegisterAdvertisementsAsync(
        PairingGeneration generation,
        string stableHostId,
        ushort controlPort,
        CancellationToken cancellationToken)
    {
        IPEndPoint pairingEndPoint = RequireIpEndPoint(
            generation.Listener.LocalEndPoint,
            "pairing");
        IReadOnlyDictionary<string, byte[]> records = generation.Pin.CreateTxtRecords(
            stableHostId,
            checked((ushort)pairingEndPoint.Port));
        var controlAdvertisement = new PeelServiceAdvertisement(
            options.ServiceName,
            PeelServiceType.Control,
            controlPort,
            records);
        var pairingAdvertisement = new PeelServiceAdvertisement(
            options.PairingServiceName,
            PeelServiceType.Pairing,
            checked((ushort)pairingEndPoint.Port),
            records);

        IAsyncDisposable? controlRegistration = null;
        try
        {
            controlRegistration = await serviceRegistrar.RegisterAsync(
                    controlAdvertisement,
                    cancellationToken)
                .ConfigureAwait(false);
            IAsyncDisposable pairingRegistration = await serviceRegistrar.RegisterAsync(
                    pairingAdvertisement,
                    cancellationToken)
                .ConfigureAwait(false);
            generation.SetAdvertisements(controlRegistration, pairingRegistration);
        }
        catch
        {
            if (controlRegistration is not null)
            {
                await controlRegistration.DisposeAsync().ConfigureAwait(false);
            }

            throw;
        }
    }

    private async ValueTask StopResourcesAsync()
    {
        await lifecycleGate.WaitAsync().ConfigureAwait(false);
        HostAuthenticatedListener? listener;
        PairingGeneration? generation;
        try
        {
            lock (stateLock)
            {
                listener = authenticatedListener;
                generation = pairingGeneration;
                authenticatedListener = null;
                controlSessions = null;
                videoSessions = null;
                pairingGeneration = null;
            }
        }
        finally
        {
            lifecycleGate.Release();
        }

        try
        {
            if (generation is not null)
            {
                await generation.DisposeAsync().ConfigureAwait(false);
            }
        }
        finally
        {
            if (listener is not null)
            {
                await listener.DisposeAsync().ConfigureAwait(false);
            }
        }
    }

    private void RaiseStateChanged()
    {
        try
        {
            StateChanged?.Invoke();
        }
        catch
        {
            // UI observers do not own the secure Host runtime lifecycle.
        }
    }

    private static IPEndPoint RequireIpEndPoint(EndPoint? endpoint, string listenerName) =>
        endpoint as IPEndPoint ??
        throw new InvalidDataException($"The {listenerName} Host listener has no TCP endpoint.");

    private static string SafeError(Exception exception)
    {
        string message = exception.Message.Trim();
        return message.Length is 0 ? exception.GetType().Name : message;
    }

    private sealed class PairingGeneration(
        HostPairingPin pin,
        HostPinPairingListener listener) : IAsyncDisposable
    {
        private IAsyncDisposable? controlAdvertisement;
        private IAsyncDisposable? pairingAdvertisement;
        private int listenerDisposed;

        internal HostPairingPin Pin { get; } = pin;

        internal HostPinPairingListener Listener { get; } = listener;

        internal void SetAdvertisements(
            IAsyncDisposable controlRegistration,
            IAsyncDisposable pairingRegistration)
        {
            if (controlAdvertisement is not null || pairingAdvertisement is not null)
            {
                throw new InvalidOperationException("This pairing generation is already advertised.");
            }

            controlAdvertisement = controlRegistration;
            pairingAdvertisement = pairingRegistration;
        }

        internal async ValueTask DisposeAdvertisementsAsync()
        {
            IAsyncDisposable? pairing = Interlocked.Exchange(ref pairingAdvertisement, null);
            IAsyncDisposable? control = Interlocked.Exchange(ref controlAdvertisement, null);
            try
            {
                if (pairing is not null)
                {
                    await pairing.DisposeAsync().ConfigureAwait(false);
                }
            }
            finally
            {
                if (control is not null)
                {
                    await control.DisposeAsync().ConfigureAwait(false);
                }
            }
        }

        internal async ValueTask DisposeListenerAsync()
        {
            if (Interlocked.Exchange(ref listenerDisposed, 1) == 0)
            {
                await Listener.DisposeAsync().ConfigureAwait(false);
            }
        }

        public async ValueTask DisposeAsync()
        {
            try
            {
                await DisposeAdvertisementsAsync().ConfigureAwait(false);
            }
            finally
            {
                await DisposeListenerAsync().ConfigureAwait(false);
            }
        }
    }
}
