using System.ComponentModel;
using System.Text.Json;
using Peel.Windows.Host.Input;
using Peel.Windows.Host.Runtime;
using Peel.Windows.Host.Windows;
using Peel.Windows.Protocol;

namespace Peel.Windows.Host.Networking;

internal sealed record HostVideoBinding(
    long ControlGeneration,
    string PeerIdentity,
    uint WindowId,
    WindowDescriptor Window,
    IReadOnlySet<string> ClientCapabilities,
    CancellationToken ControlLifetime);

internal readonly record struct HostVideoStopRequest(
    long ControlGeneration,
    string PeerIdentity,
    uint WindowId);

internal interface IHostVideoBindingResolver
{
    bool TryResolveVideoBinding(
        string peerIdentity,
        uint windowId,
        out HostVideoBinding? binding);

    bool IsCurrentVideoBinding(HostVideoBinding binding);
}

/// Owns at most one already-authenticated TLS-PSK control session. Listener binding,
/// credential lookup, and pairing storage deliberately remain outside this boundary.
public sealed class HostControlSessionManager : IAsyncDisposable, IHostVideoBindingResolver
{
    private readonly object stateLock = new();
    private readonly SemaphoreSlim transitionGate = new(1, 1);
    private readonly object awakeUpdateGate = new();
    private readonly object observerGate = new();
    private bool observerRunning, observerPending, observerStopped;
    private int waitingTransitions;
    private string? pendingAuthenticatedPeer;
    private readonly IWindowEnumerator windowEnumerator;
    private readonly IHostInputSessionFactory inputSessionFactory;
    private readonly HostControlSessionOptions options;
    private readonly Action<string> peerAuthenticated;
    private readonly IHostAwakeController awakeController;
    private readonly Action clientStateChanged;
    private readonly CancellationTokenSource lifetimeCancellation = new();
    private readonly HostWindowIdMap windowIds = new();

    private ActiveSession? activeSession;
    private bool activeClientVisible;
    private long nextGeneration;
    private bool disposed;
    private Func<long, string, uint, bool>? activeVideoProbe;

    internal event Action<HostVideoStopRequest>? VideoStopRequested;

    /// <summary>Set by the video owner: whether (generation, peer, window) has an admitted video socket now.</summary>
    internal void SetActiveVideoProbe(Func<long, string, uint, bool>? probe) =>
        Volatile.Write(ref activeVideoProbe, probe);

    private bool HasActiveVideo(long generation, string peerIdentity, uint windowId) =>
        Volatile.Read(ref activeVideoProbe) is { } probe && probe(generation, peerIdentity, windowId);

    // In-process diagnostic only; proves actual semaphore admission is pending.
    internal int WaitingTransitionCount => Volatile.Read(ref waitingTransitions);

    public HostControlSessionManager(HostControlSessionOptions options)
        : this(new InputPermissionGate(), options)
    {
    }

    public HostControlSessionManager(
        InputPermissionGate inputPermissionGate,
        HostControlSessionOptions options,
        Action<string>? peerAuthenticated = null)
        : this(
            new Win32WindowEnumerator(),
            new WindowsHostInputSessionFactory(inputPermissionGate),
            options,
            peerAuthenticated)
    {
    }

    internal HostControlSessionManager(
        InputPermissionGate inputPermissionGate,
        HostControlSessionOptions options,
        Action<string>? peerAuthenticated,
        IHostAwakeController awakeController,
        Action clientStateChanged)
        : this(
            new Win32WindowEnumerator(),
            new WindowsHostInputSessionFactory(inputPermissionGate),
            options,
            peerAuthenticated,
            awakeController,
            clientStateChanged)
    {
    }

    internal HostControlSessionManager(
        IWindowEnumerator windowEnumerator,
        HostControlSessionOptions options,
        Action<string>? peerAuthenticated = null)
        : this(
            windowEnumerator,
            new WindowsHostInputSessionFactory(new InputPermissionGate()),
            options,
            peerAuthenticated)
    {
    }

    internal HostControlSessionManager(
        IWindowEnumerator windowEnumerator,
        IHostInputSessionFactory inputSessionFactory,
        HostControlSessionOptions options,
        Action<string>? peerAuthenticated = null,
        IHostAwakeController? awakeController = null,
        Action? clientStateChanged = null)
    {
        this.windowEnumerator = windowEnumerator ??
            throw new ArgumentNullException(nameof(windowEnumerator));
        this.inputSessionFactory = inputSessionFactory ??
            throw new ArgumentNullException(nameof(inputSessionFactory));
        this.options = options ?? throw new ArgumentNullException(nameof(options));
        this.peerAuthenticated = peerAuthenticated ?? (static _ => { });
        this.awakeController = awakeController ?? new NullHostAwakeController();
        this.clientStateChanged = clientStateChanged ?? (static () => { });
    }

    public long? ActiveGeneration
    {
        get
        {
            lock (stateLock)
            {
                return activeSession?.Generation;
            }
        }
    }

    public string? ActivePeerIdentity
    {
        get
        {
            lock (stateLock)
            {
                return activeSession?.Session.PeerIdentity;
            }
        }
    }

    public bool IsActiveClientVisible
    {
        get
        {
            lock (stateLock)
            {
                return activeClientVisible;
            }
        }
    }

    public bool IsPreventingSleep => awakeController.IsHolding;

    public string? AwakeError => awakeController.LastError;

    internal async Task RunAuthenticatedAudioSessionAsync(PeelPskConnection connection, CancellationToken token)
    {
        HostControlSession? session;
        lock (stateLock) session = disposed ? null : activeSession?.Session;
        if (session is null || session.PeerIdentity != connection.PeerIdentity)
            await connection.DisposeAsync().ConfigureAwait(false);
        else await session.AttachAudioAsync(connection, token).ConfigureAwait(false);
    }

    public async Task RunAuthenticatedSessionAsync(
        PeelPskConnection connection,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(connection);
        ActiveSession? replacement = null;
        IHostInputSession? createdInput = null;
        CancellationTokenSource? createdCancellation = null;
        bool entered = false, published = false, scheduled = false, notifyStateChanged = false;
        try
        {
            // A->B->C transitions, including factories, are serialized. No native
            // backend or observer is invoked while stateLock is held.
            Task admission = transitionGate.WaitAsync(cancellationToken);
            bool waiting = !admission.IsCompleted;
            if (waiting) Interlocked.Increment(ref waitingTransitions);
            try { await admission.ConfigureAwait(false); }
            finally { if (waiting) Interlocked.Decrement(ref waitingTransitions); }
            entered = true;
            // Wait admission occurs before yielding: a returned pending call is
            // already queued behind the transition currently revoking native input.
            await Task.Yield();
            long generation;
            lock (stateLock)
            {
                ObjectDisposedException.ThrowIf(disposed, this);
                generation = checked(++nextGeneration);
            }
            createdCancellation = CancellationTokenSource.CreateLinkedTokenSource(
                lifetimeCancellation.Token, cancellationToken);
            createdInput = inputSessionFactory.Create()
                ?? throw new InvalidOperationException("The input factory did not create a session.");
            createdCancellation.Token.ThrowIfCancellationRequested();
            var session = new HostControlSession(connection, generation, createdCancellation.Token,
                IsCurrentGeneration, NotifyVideoStopRequested, NotifyClientVisibility,
                windowEnumerator, windowIds, createdInput, options, QueuePeerAuthenticated, HasActiveVideo);
            replacement = new ActiveSession(generation, session, createdCancellation);
            ActiveSession? previous;
            lock (stateLock)
            {
                ObjectDisposedException.ThrowIf(disposed, this);
                previous = activeSession;
                activeSession = replacement;
                notifyStateChanged = activeClientVisible;
                activeClientVisible = false;
                published = true;
            }
            createdInput = null;
            createdCancellation = null;
            // Publish the new epoch first, then finish releasing prior native
            // input outside stateLock BEFORE scheduling any replacement hello.
            previous?.Cancel();
            _ = RunAndClearAsync(replacement, startSession: true);
            scheduled = true;
        }
        finally
        {
            try
            {
                if (published && !scheduled && replacement is not null)
                {
                    // An already-published, never-admitted session still settles
                    // Completion and releases its owned resources.
                    _ = RunAndClearAsync(replacement, startSession: false);
                }
                if (!published)
                {
                    // Even a canceled factory result finishes synchronous native
                    // ownership before the next transition may start. The factory
                    // interface itself does not promise an empty native owner.
                    try { createdInput?.Dispose(); }
                    finally { createdCancellation?.Dispose(); }
                }
            }
            finally
            {
                if (entered) transitionGate.Release();
                // Async transport cleanup does not hold the native startup barrier.
                if (!published) await connection.DisposeAsync().ConfigureAwait(false);
            }
        }
        // Neither awake backends nor observers can hold the transition barrier.
        UpdateAwakeState();
        if (notifyStateChanged) NotifyClientStateChanged();
        await replacement!.Completion.ConfigureAwait(false);
    }

    bool IHostVideoBindingResolver.TryResolveVideoBinding(
        string peerIdentity,
        uint windowId,
        out HostVideoBinding? binding)
    {
        lock (stateLock)
        {
            ActiveSession? active = activeSession;
            if (disposed ||
                active is null ||
                !StringComparer.Ordinal.Equals(active.Session.PeerIdentity, peerIdentity) ||
                !active.Session.TryResolveVideoWindow(windowId, out WindowDescriptor? window) ||
                window is null)
            {
                binding = null;
                return false;
            }

            binding = new HostVideoBinding(
                active.Generation,
                peerIdentity,
                windowId,
                window,
                active.Session.ClientCapabilities,
                active.Cancellation.Token);
            return true;
        }
    }

    bool IHostVideoBindingResolver.IsCurrentVideoBinding(HostVideoBinding binding)
    {
        lock (stateLock)
        {
            return !disposed &&
                activeSession is ActiveSession active &&
                active.Generation == binding.ControlGeneration &&
                StringComparer.Ordinal.Equals(active.Session.PeerIdentity, binding.PeerIdentity) &&
                active.Session.IsCurrentVideoWindow(binding.WindowId, binding.Window);
        }
    }

    public async ValueTask DisposeAsync()
    {
        await transitionGate.WaitAsync().ConfigureAwait(false);
        ActiveSession? session = null;
        bool alreadyDisposed;
        try
        {
            lock (stateLock)
            {
                alreadyDisposed = disposed;
                if (!alreadyDisposed)
                {
                    disposed = true;
                    session = activeSession;
                    activeClientVisible = false;
                }
            }
            if (alreadyDisposed) return;
            // Native held state is revoked before cancellation callbacks, power
            // work or observers. Pending startup uses the same transition gate.
            session?.Cancel();
            lifetimeCancellation.Cancel();
        }
        finally { transitionGate.Release(); }
        lock (observerGate)
        {
            observerStopped = true;
            observerPending = false;
            pendingAuthenticatedPeer = null;
        }
        try
        {
            // Stop releases the power request before unrelated audio/session
            // teardown. The transition barrier has already revoked native input.
            lock (awakeUpdateGate)
            {
                awakeController.SetClientVisible(false);
                awakeController.Dispose();
            }
            if (session is not null) await session.Completion.ConfigureAwait(false);
        }
        finally { lifetimeCancellation.Dispose(); }
    }

    private bool IsCurrentGeneration(long generation)
    {
        lock (stateLock)
        {
            return !disposed && activeSession is { } active && active.Generation == generation &&
                !active.Cancellation.IsCancellationRequested;
        }
    }

    private void NotifyVideoStopRequested(HostVideoStopRequest request) =>
        VideoStopRequested?.Invoke(request);

    private void NotifyClientVisibility(long generation, bool visible)
    {
        bool changed;
        lock (stateLock)
        {
            changed = !disposed && activeSession?.Generation == generation && activeClientVisible != visible;
            if (changed) activeClientVisible = visible;
        }
        if (changed)
        {
            UpdateAwakeState();
            NotifyClientStateChanged();
        }
    }

    private void UpdateAwakeState()
    {
        lock (awakeUpdateGate)
        {
            bool visible;
            lock (stateLock)
            {
                if (disposed) return;
                visible = activeClientVisible;
            }
            // A delayed old notification reads CURRENT state here, rather than
            // applying a stale captured false/true. Never holds stateLock.
            awakeController.SetClientVisible(visible);
        }
    }

    private void QueuePeerAuthenticated(string peer)
    {
        lock (observerGate)
        {
            if (observerStopped) return;
            pendingAuthenticatedPeer = peer;
            StartObserverLocked();
        }
    }

    private void NotifyClientStateChanged()
    {
        lock (observerGate)
        {
            if (observerStopped) return;
            observerPending = true;
            StartObserverLocked();
        }
    }

    private void StartObserverLocked()
    {
        if (observerRunning) return;
        observerRunning = true;
        // Exactly one observer worker plus the latest pending state/peer. A
        // blocked external callback never owns startup, release or disposal.
        _ = Task.Run(DrainObservers);
    }

    private void DrainObservers()
    {
        while (true)
        {
            bool notify;
            string? peer;
            lock (observerGate)
            {
                if (observerStopped || !observerPending && pendingAuthenticatedPeer is null)
                {
                    observerRunning = false;
                    return;
                }
                notify = observerPending;
                observerPending = false;
                peer = pendingAuthenticatedPeer;
                pendingAuthenticatedPeer = null;
            }
            try { if (peer is not null) peerAuthenticated(peer); } catch { }
            try { if (notify) clientStateChanged(); } catch { }
        }
    }

    private async Task RunAndClearAsync(ActiveSession active, bool startSession)
    {
        await Task.Yield();
        Exception? failure = null;
        try
        {
            if (startSession) await active.Session.RunAsync(active.Cancellation.Token).ConfigureAwait(false);
            else await active.Session.DisposeBeforeStartAsync().ConfigureAwait(false);
        }
        catch (Exception error) { failure = error; }
        finally
        {
            try { active.Cancel(); }
            catch (Exception error) { failure ??= error; }
            try
            {
                bool changed = false;
                lock (stateLock)
                {
                    if (ReferenceEquals(activeSession, active))
                    {
                        activeSession = null;
                        changed = activeClientVisible;
                        activeClientVisible = false;
                    }
                }
                if (changed)
                {
                    UpdateAwakeState();
                    NotifyClientStateChanged();
                }
            }
            catch (Exception error) { failure ??= error; }
            finally
            {
                active.Cancellation.Dispose();
                if (failure is null) active.Finish.TrySetResult();
                else active.Finish.TrySetException(failure);
            }
        }
    }

    private sealed class ActiveSession(
        long generation,
        HostControlSession session,
        CancellationTokenSource cancellation)
    {
        internal long Generation { get; } = generation;
        internal HostControlSession Session { get; } = session;
        internal CancellationTokenSource Cancellation { get; } = cancellation;
        internal TaskCompletionSource Finish { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal Task Completion => Finish.Task;

        internal void Cancel()
        {
            Session.RevokeInput();
            try
            {
                Cancellation.Cancel();
            }
            catch (ObjectDisposedException)
            {
                // A naturally completed session may dispose its linked token while a
                // concurrent replacement is taking its cancellation snapshot.
            }

            Session.AbortTransport();
        }
    }
}

internal sealed class HostControlSession
{
    private readonly Guid diagnosticsSession = Guid.NewGuid();
    private readonly Audio.HostAudioSession? audio;
    private readonly HostMachineStatus? machineStatus;
    private bool clientVisible;
    private readonly object inputLifecycleGate = new();
    private readonly CancellationToken inputLifetime;
    private bool inputRevoked;
    private int cleaned;
    private const int ReadBufferBytes = 8 * 1024;
    private const int MaximumInputRejectionReasonCodeUnits = 512;

    private readonly PeelPskConnection connection;
    private readonly long generation;
    private readonly Func<long, bool> isCurrentGeneration;
    private readonly Action<HostVideoStopRequest> notifyVideoStopRequested;
    private readonly Action<long, bool> notifyClientVisibility;
    private readonly IWindowEnumerator windowEnumerator;
    private readonly HostWindowIdMap windowIds;
    private readonly IHostInputSession inputSession;
    private readonly HostControlSessionOptions options;
    private readonly Action<string> peerAuthenticated;
    private readonly Func<long, string, uint, bool> hasActiveVideo;
    private readonly HostSourceMediaLimiter sourceMediaLimits = new();
    private readonly SemaphoreSlim writeGate = new(1, 1);
    private readonly HostStreamRequestGate streamRequests = new();
    private IReadOnlySet<string> clientCapabilities = new HashSet<string>(StringComparer.Ordinal);
    private bool negotiated;

    internal HostControlSession(
        PeelPskConnection connection,
        long generation,
        CancellationToken inputLifetime,
        Func<long, bool> isCurrentGeneration,
        Action<HostVideoStopRequest> notifyVideoStopRequested,
        Action<long, bool> notifyClientVisibility,
        IWindowEnumerator windowEnumerator,
        HostWindowIdMap windowIds,
        IHostInputSession inputSession,
        HostControlSessionOptions options,
        Action<string> peerAuthenticated,
        Func<long, string, uint, bool> hasActiveVideo)
    {
        this.connection = connection;
        this.hasActiveVideo = hasActiveVideo;
        this.generation = generation;
        this.inputLifetime = inputLifetime;
        this.isCurrentGeneration = isCurrentGeneration;
        this.notifyVideoStopRequested = notifyVideoStopRequested;
        this.notifyClientVisibility = notifyClientVisibility;
        this.windowEnumerator = windowEnumerator;
        this.windowIds = windowIds;
        this.inputSession = inputSession;
        this.options = options;
        this.peerAuthenticated = peerAuthenticated;
        if (options.MachineStatusProvider is { } provider && options.MachineStatusCredentials is { } credentials)
            machineStatus = new(provider, credentials, connection.PeerIdentity);
        if (options.AudioSharing is { } sharing && options.AudioCredentials is { } audioCredentials)
            audio = new(sharing, audioCredentials, connection.PeerIdentity,
                () => Volatile.Read(ref negotiated) && Volatile.Read(ref clientVisible) && isCurrentGeneration(generation) &&
                    ClientCapabilities.Contains("mac-system-audio-v1"), SendAsync);
    }

    internal string PeerIdentity => connection.PeerIdentity;

    internal IReadOnlySet<string> ClientCapabilities => Volatile.Read(ref clientCapabilities);

    internal DateTimeOffset LastActivityAt { get; private set; }

    internal async Task AttachAudioAsync(PeelPskConnection connection, CancellationToken token)
    {
        if (audio is null) await connection.DisposeAsync().ConfigureAwait(false);
        else await audio.AttachAsync(connection, token).ConfigureAwait(false);
    }

    internal void AbortTransport()
    {
        try
        {
            connection.Stream.Dispose();
        }
        catch (Exception exception) when (IsFailSoftSessionException(exception))
        {
        }
    }

    internal bool TryResolveVideoWindow(uint windowId, out WindowDescriptor? window)
    {
        if (!Volatile.Read(ref negotiated))
        {
            window = null;
            return false;
        }

        if (!windowIds.TryResolve(windowId, out window) || !streamRequests.IsAllowed(windowId))
        {
            window = null;
            return false;
        }

        return true;
    }

    internal bool IsCurrentVideoWindow(uint windowId, WindowDescriptor expectedWindow) =>
        Volatile.Read(ref negotiated) &&
        windowIds.IsCurrent(windowId, expectedWindow) &&
        streamRequests.IsAllowed(windowId);

    internal async Task RunAsync(CancellationToken cancellationToken)
    {
        await using var ownedConnection = connection;
        var reader = new BoundedNdjsonLineReader(options.MaximumFirstLineBytes);
        var readBuffer = new byte[ReadBufferBytes];
        bool receivedHello = false;

        try
        {
            while (isCurrentGeneration(generation))
            {
                int byteCount = await connection.Stream.ReadAsync(
                    readBuffer,
                    cancellationToken).ConfigureAwait(false);
                if (byteCount == 0)
                {
                    return;
                }

                int offset = 0;
                while (offset < byteCount)
                {
                    bool hasLine = reader.TryAppend(
                        readBuffer.AsSpan(offset, byteCount - offset),
                        out int consumed,
                        out ReadOnlyMemory<byte> line);
                    offset += consumed;

                    if (!hasLine)
                    {
                        continue;
                    }

                    if (!receivedHello)
                    {
                        if (line.IsEmpty || !await HandleClientHelloAsync(line, cancellationToken).ConfigureAwait(false))
                        {
                            return;
                        }

                        receivedHello = true;
                        reader.MaximumLineBytes = options.MaximumControlLineBytes;
                        continue;
                    }

                    if (line.IsEmpty)
                    {
                        continue;
                    }

                    if (!await HandleControlLineAsync(line, cancellationToken).ConfigureAwait(false))
                    {
                        return;
                    }
                }
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            // Session replacement and shutdown are normal disconnect paths.
        }
        catch (Exception exception) when (IsFailSoftSessionException(exception))
        {
            // Malformed peer data, stream teardown, and disappearing windows close or
            // skip work at this session boundary; they never escape into the Host.
        }
        finally { await CleanupAsync().ConfigureAwait(false); }
    }

    internal async ValueTask DisposeBeforeStartAsync()
    {
        await using var ownedConnection = connection;
        await CleanupAsync().ConfigureAwait(false);
    }

    private async ValueTask CleanupAsync()
    {
        if (Interlocked.Exchange(ref cleaned, 1) != 0) return;
        Volatile.Write(ref negotiated, false);
        // Release held input before any unrelated asynchronous media teardown.
        RevokeInput();
        // Listener cancellation waits for this routed session before manager
        // disposal. End this generation's visibility before audio can delay it.
        // The manager guard prevents stale cleanup from hiding a replacement.
        notifyClientVisibility(generation, false);
        Diagnostics.StreamDiagnostics.Shared.ClearPeer(diagnosticsSession, end: true);
        try { if (audio is not null) await audio.DisposeAsync().ConfigureAwait(false); }
        finally { writeGate.Dispose(); }
    }

    internal void RevokeInput()
    {
        lock (inputLifecycleGate)
        {
            if (inputRevoked) return;
            inputRevoked = true;
            // WindowsHostInputSession.Dispose permanently disables this native
            // session and synchronously releases its tracked keys/buttons. Every
            // control dispatch uses this same gate, including target focus.
            inputSession.Dispose();
        }
    }

    private InputInjectionResult InvokeInput(WindowDescriptor window, Func<WindowDescriptor, InputInjectionResult> handle)
    {
        lock (inputLifecycleGate)
        {
            if (inputRevoked || inputLifetime.IsCancellationRequested || !isCurrentGeneration(generation))
                return InputInjectionResult.Rejected("The remote input session has ended.");
            return handle(window);
        }
    }

    private async ValueTask<bool> HandleClientHelloAsync(
        ReadOnlyMemory<byte> line,
        CancellationToken cancellationToken)
    {
        MessageEnvelope envelope = PeelJson.ReadEnvelope(line.Span);
        if (!StringComparer.Ordinal.Equals(envelope.Type, PeelMessageType.ClientHello))
        {
            return false;
        }

        ClientHelloMessage hello = PeelJson.Deserialize<ClientHelloMessage>(line.Span);
        if (string.IsNullOrWhiteSpace(hello.DeviceName) ||
            string.IsNullOrWhiteSpace(hello.Platform) ||
            hello.PairingId is not null &&
            !StringComparer.Ordinal.Equals(hello.PairingId, PeerIdentity))
        {
            return false;
        }

        LastActivityAt = DateTimeOffset.UtcNow;

        if (!PeelProtocol.IsCompatible(
                hello.ProtocolVersion,
                hello.MinimumSupportedProtocolVersion))
        {
            await SendAsync(
                ProtocolRejectedMessage.Create(
                    "This Peel client is not compatible with this Peel Pro host.",
                    hello.ProtocolVersion,
                    hello.MinimumSupportedProtocolVersion),
                cancellationToken).ConfigureAwait(false);
            return false;
        }

        if (Volatile.Read(ref negotiated))
        {
            // A same-peer hello refreshes advertised capabilities on this TLS
            // session. It does not reopen input/video or override visibility.
            // Sending another hostHello would restart the Mac viewer handshake.
            if (!isCurrentGeneration(generation)) return false;
            IReadOnlySet<string> previous = ClientCapabilities;
            var replacement = new HashSet<string>(hello.Capabilities ?? [], StringComparer.Ordinal);
            Volatile.Write(ref clientCapabilities, replacement);
            Diagnostics.StreamDiagnostics.Shared.RefreshPeerSession(diagnosticsSession,
                replacement.Contains(ClientStreamMetricsMessage.Capability) &&
                options.Capabilities.Contains(ClientStreamMetricsMessage.Capability));
            if (previous.Contains(PeelCapability.MachineStatus) && !replacement.Contains(PeelCapability.MachineStatus))
                machineStatus?.Reset();
            if (previous.Contains("mac-system-audio-v1") && !replacement.Contains("mac-system-audio-v1") && audio is not null)
                await audio.StopAsync().ConfigureAwait(false);
            return isCurrentGeneration(generation);
        }

        bool sent = await SendAsync(
            PeelHello.CreateHost(
                options.HostName,
                osVersion: options.OperatingSystemVersion,
                appVersion: options.AppVersion,
                capabilities: options.Capabilities),
            cancellationToken).ConfigureAwait(false);
        if (sent)
        {
            lock (inputLifecycleGate)
            {
                if (inputRevoked || inputLifetime.IsCancellationRequested || !isCurrentGeneration(generation))
                    return false;
                Volatile.Write(ref clientCapabilities, new HashSet<string>(
                    hello.Capabilities ?? [], StringComparer.Ordinal));
                Volatile.Write(ref negotiated, true);
                Diagnostics.StreamDiagnostics.Shared.SetPeerSession(diagnosticsSession,
                    clientCapabilities.Contains(ClientStreamMetricsMessage.Capability) && options.Capabilities.Contains(ClientStreamMetricsMessage.Capability));
                clientVisible = true;
            }
            NotifyPeerAuthenticated();
            notifyClientVisibility(generation, true);
        }

        return sent;
    }

    private void NotifyPeerAuthenticated()
    {
        try
        {
            peerAuthenticated(PeerIdentity);
        }
        catch
        {
            // Last-seen bookkeeping never owns the authenticated session lifetime.
        }
    }

    private async ValueTask<bool> HandleControlLineAsync(
        ReadOnlyMemory<byte> line,
        CancellationToken cancellationToken)
    {
        MessageEnvelope envelope = PeelJson.ReadEnvelope(line.Span);

        switch (envelope.Type)
        {
            case "clientStreamMetrics":
                if (clientVisible && isCurrentGeneration(generation) && line.Length <= 64 * 1024)
                    Diagnostics.StreamDiagnostics.Shared.AcceptPeer(diagnosticsSession, PeelJson.Deserialize<ClientStreamMetricsMessage>(line.Span));
                return true;
            case "audioSessionRequest":
                var audioRequest = PeelJson.Deserialize<AudioSessionRequestMessage>(line.Span);
                MachineStatusValidation.RequestId(audioRequest.RequestId);
                var audioReply = audio is null
                    ? new AudioSessionStateMessage(audioRequest.RequestId, PeerIdentity, "unavailable", "System audio hosting is unavailable.")
                    : await audio.RequestAsync(audioRequest, cancellationToken).ConfigureAwait(false);
                return audioReply is null || await SendAsync(audioReply, cancellationToken).ConfigureAwait(false);
            case "audioPairingProof":
                if (audio is null) return true;
                var audioProofReply = await audio.ProveAsync(PeelJson.Deserialize<AudioPairingProofMessage>(line.Span), cancellationToken).ConfigureAwait(false);
                return audioProofReply is null || await SendAsync(audioProofReply, cancellationToken).ConfigureAwait(false);
            case "machineStatusRequest":
                if (machineStatus is null) return true;
                var statusReply = await machineStatus.RequestAsync(PeelJson.Deserialize<MachineStatusRequestMessage>(line.Span),
                    clientVisible && clientCapabilities.Contains(PeelCapability.MachineStatus), cancellationToken).ConfigureAwait(false);
                return await SendAsync(statusReply, cancellationToken).ConfigureAwait(false);
            case "agentPairingProof":
                if (machineStatus is null) return true;
                var proofReply = await machineStatus.ProveAsync(PeelJson.Deserialize<AgentPairingProofMessage>(line.Span),
                    clientVisible && clientCapabilities.Contains(PeelCapability.MachineStatus), cancellationToken).ConfigureAwait(false);
                return proofReply is null || await SendAsync(proofReply, cancellationToken).ConfigureAwait(false);
            case PeelMessageType.RequestWindowList:
                _ = PeelJson.Deserialize<PeelRequest>(line.Span);
                LastActivityAt = DateTimeOffset.UtcNow;
                clientVisible = true;
                notifyClientVisibility(generation, true);
                return await SendWindowListAsync(cancellationToken).ConfigureAwait(false);

            case PeelMessageType.StartStream:
            case PeelMessageType.StopStream:
                PeelRequest streamRequest = PeelJson.Deserialize<PeelRequest>(line.Span);
                LastActivityAt = DateTimeOffset.UtcNow;
                if (streamRequest.WindowId is not uint windowId ||
                    windowId == 0 ||
                    !windowIds.TryResolve(windowId, out _))
                {
                    return true;
                }

                bool isStarting = StringComparer.Ordinal.Equals(
                    envelope.Type,
                    PeelMessageType.StartStream);
                streamRequests.SetAllowed(windowId, isStarting);
                if (!isStarting)
                {
                    notifyVideoStopRequested(new HostVideoStopRequest(
                        generation,
                        PeerIdentity,
                        windowId));
                }

                return true;

            case PeelMessageType.MouseClick:
            case PeelMessageType.MouseMove:
            case PeelMessageType.MouseScroll:
            case PeelMessageType.MouseDown:
            case PeelMessageType.MouseDrag:
            case PeelMessageType.MouseUp:
                PeelRequest mouseRequest = PeelJson.Deserialize<PeelRequest>(line.Span);
                return await HandleInputAsync(
                        mouseRequest.WindowId,
                        window => inputSession.HandleMouse(mouseRequest, window),
                        cancellationToken)
                    .ConfigureAwait(false);

            case PeelMessageType.KeyboardText:
                KeyboardTextMessage textMessage =
                    PeelJson.Deserialize<KeyboardTextMessage>(line.Span);
                return await HandleInputAsync(
                        textMessage.WindowId,
                        window => inputSession.HandleKeyboardText(textMessage, window),
                        cancellationToken)
                    .ConfigureAwait(false);

            case PeelMessageType.KeyboardCommand:
                KeyboardCommandMessage commandMessage =
                    PeelJson.Deserialize<KeyboardCommandMessage>(line.Span);
                return await HandleInputAsync(
                        commandMessage.WindowId,
                        window => inputSession.HandleKeyboardCommand(commandMessage, window),
                        cancellationToken)
                    .ConfigureAwait(false);

            case PeelMessageType.KeyboardHardwareKey:
                KeyboardHardwareKeyMessage hardwareMessage =
                    PeelJson.Deserialize<KeyboardHardwareKeyMessage>(line.Span);
                return await HandleInputAsync(
                        hardwareMessage.WindowId,
                        window => inputSession.HandleKeyboardHardwareKey(hardwareMessage, window),
                        cancellationToken)
                    .ConfigureAwait(false);

            case PeelMessageType.KeyboardChord:
                KeyboardChordMessage chordMessage =
                    PeelJson.Deserialize<KeyboardChordMessage>(line.Span);
                return await HandleInputAsync(
                        chordMessage.WindowId,
                        window => inputSession.HandleKeyboardChord(chordMessage, window),
                        cancellationToken)
                    .ConfigureAwait(false);

            case PeelMessageType.KeyboardMacro:
                KeyboardMacroMessage macroMessage =
                    PeelJson.Deserialize<KeyboardMacroMessage>(line.Span);
                return await HandleInputAsync(
                        macroMessage.WindowId,
                        window => inputSession.HandleKeyboardMacro(macroMessage, window),
                        cancellationToken)
                    .ConfigureAwait(false);

            case SourceMediaProtocol.CommandType:
            case SourceMediaProtocol.VolumeQueryType:
            case SourceMediaProtocol.VolumeSetType:
                return await HandleSourceMediaAsync(envelope.Type, line, cancellationToken)
                    .ConfigureAwait(false);

            case PeelMessageType.ClientPing:
                _ = PeelJson.Deserialize<ClientPingMessage>(line.Span);
                LastActivityAt = DateTimeOffset.UtcNow;
                return true;

            case PeelMessageType.ClientVisibility:
                ClientVisibilityMessage visibility =
                    PeelJson.Deserialize<ClientVisibilityMessage>(line.Span);
                LastActivityAt = DateTimeOffset.UtcNow;
                clientVisible = visibility.IsVisible;
                if (!clientVisible) machineStatus?.Reset();
                if (!clientVisible) Diagnostics.StreamDiagnostics.Shared.ClearPeer(diagnosticsSession);
                if (!clientVisible && audio is not null) await audio.StopAsync().ConfigureAwait(false);
                notifyClientVisibility(generation, visibility.IsVisible);
                return true;

            case PeelMessageType.ClientActiveWindow:
                ClientActiveWindowMessage focusRequest =
                    PeelJson.Deserialize<ClientActiveWindowMessage>(line.Span);
                return await HandleClientActiveWindowAsync(
                        focusRequest.WindowId,
                        focusRequest.FocusRequestId,
                        cancellationToken)
                    .ConfigureAwait(false);

            case PeelMessageType.PairingRevoked:
                _ = PeelJson.Deserialize<PairingRevokedMessage>(line.Span);
                return false;

            case PeelMessageType.ProtocolRejected:
                _ = PeelJson.Deserialize<ProtocolRejectedMessage>(line.Span);
                return false;

            case PeelMessageType.ClientHello:
                return await HandleClientHelloAsync(line, cancellationToken).ConfigureAwait(false);

            case PeelMessageType.VideoStreamHello:
                return false;

            default:
                // Unknown additive messages are ignored without changing liveness.
                return true;
        }
    }

    private async ValueTask<bool> SendWindowListAsync(CancellationToken cancellationToken)
    {
        IReadOnlyList<WindowDescriptor> descriptors;
        try
        {
            descriptors = windowEnumerator.Enumerate();
        }
        catch (Exception exception) when (
            exception is Win32Exception or InvalidOperationException or PlatformNotSupportedException)
        {
            return true;
        }

        IReadOnlyList<PeelWindow> windows = windowIds.CreateSnapshot(descriptors);
        return await SendAsync(new WindowListMessage(windows), cancellationToken).ConfigureAwait(false);
    }

    private async ValueTask<bool> HandleInputAsync(
        uint? requestedWindowId,
        Func<WindowDescriptor, InputInjectionResult> handle,
        CancellationToken cancellationToken,
        Func<InputInjectionResult, ValueTask<bool>>? report = null)
    {
        LastActivityAt = DateTimeOffset.UtcNow;
        uint responseWindowId = requestedWindowId ?? 0;
        InputInjectionResult result;
        if (requestedWindowId is not uint windowId ||
            windowId == 0 ||
            !windowIds.TryResolve(windowId, out WindowDescriptor? window) ||
            window is null)
        {
            result = InputInjectionResult.Rejected(
                "Remote input requires a current session-local window identifier.");
        }
        else
        {
            try
            {
                result = InvokeInput(window, handle);
            }
            catch (Exception exception) when (
                exception is Win32Exception or
                    InvalidOperationException or
                    ArgumentException or
                    PlatformNotSupportedException or
                    OverflowException)
            {
                result = InputInjectionResult.Rejected(
                    "Windows rejected the remote input operation.");
            }
        }

        if (report is not null)
        {
            // Source controls answer with their own bounded, request-targeted reply.
            return await report(result).ConfigureAwait(false);
        }

        if (result.Succeeded)
        {
            return true;
        }

        string reason = string.IsNullOrWhiteSpace(result.Error)
            ? "Remote input was rejected."
            : result.Error;
        if (reason.Length > MaximumInputRejectionReasonCodeUnits)
        {
            reason = reason[..MaximumInputRejectionReasonCodeUnits];
        }

        return await SendAsync(
                new InputRejectedMessage(
                    responseWindowId,
                    reason,
                    DateTimeOffset.UtcNow),
                cancellationToken)
            .ConfigureAwait(false);
    }

    /// <summary>
    /// Source media v1. Media keys and volume sets are ordinary remote user input: they use
    /// HandleInputAsync's current-window admission and the input session's master gate,
    /// with visibility and the window's admitted video socket rechecked before any OS effect.
    /// Replies go only to this current paired generation. Volume is this computer's actual
    /// default system output (systemOutput); peelStream stays unsupported.
    /// </summary>
    private async ValueTask<bool> HandleSourceMediaAsync(
        string type,
        ReadOnlyMemory<byte> line,
        CancellationToken cancellationToken)
    {
        // An identity that cannot be validated gets no reply and never ends the session.
        if (line.Length > SourceMediaProtocol.MaximumLineBytes ||
            !TryReadSourceMedia(line, out SourceMediaRequestIdentityMessage? identity) ||
            !StringComparer.Ordinal.Equals(identity.Type, type) ||
            !identity.IsValid ||
            !StringComparer.Ordinal.Equals(identity.PairingId, PeerIdentity) ||
            !Volatile.Read(ref negotiated) ||
            !isCurrentGeneration(generation))
        {
            return true;
        }

        LastActivityAt = DateTimeOffset.UtcNow;
        string requestId = identity.RequestId!;
        uint windowId = identity.WindowId!.Value;
        ValueTask<bool> Reply(SourceMediaStatus status, SourceMediaReason? reason = null) =>
            SendAsync(SourceMediaAckMessage.Create(requestId, PeerIdentity, windowId, status, reason), cancellationToken);

        switch (type)
        {
            case SourceMediaProtocol.CommandType:
            {
                if (!TryReadSourceMedia(line, out SourceMediaCommandMessage? command))
                    return await Reply(SourceMediaStatus.Invalid).ConfigureAwait(false);
                SourceMediaCheck<SourceMediaAction> check = command.Check();
                if (!check.IsValid)
                    return await Reply(check.RefusalStatus!.Value, check.RefusalReason).ConfigureAwait(false);
                if (SourceMediaRefusal(windowId, null) is { } refusal)
                    return await Reply(refusal.Status, refusal.Reason).ConfigureAwait(false);
                if (!sourceMediaLimits.TryAdmit(HostSourceMediaLimit.Media))
                    return await Reply(SourceMediaStatus.Denied, SourceMediaReason.RateLimited).ConfigureAwait(false);
                HostSourceMediaRefusal? late = null;
                return await HandleInputAsync(
                        windowId,
                        window =>
                        {
                            // Runs under the input lifecycle gate, immediately before SendInput.
                            late = SourceMediaRefusal(windowId, window);
                            return late is null
                                ? inputSession.HandleSourceMediaKey(check.Value, window)
                                : InputInjectionResult.Rejected("The source control is no longer admitted.");
                        },
                        cancellationToken,
                        result => ReportSourceInput(result, late, SourceMediaStatus.Applied, null, Reply))
                    .ConfigureAwait(false);
            }

            case SourceMediaProtocol.VolumeQueryType:
            {
                if (!TryReadSourceMedia(line, out SourceVolumeQueryMessage? query))
                    return await Reply(SourceMediaStatus.Invalid).ConfigureAwait(false);
                SourceMediaCheck<SourceVolumeScope> check = query.Check();
                if (!check.IsValid)
                    return await Reply(check.RefusalStatus!.Value, check.RefusalReason).ConfigureAwait(false);
                // Read-only: current paired generation, visible client and active stream; not a new grant.
                if (SourceMediaRefusal(windowId, null) is { } refusal)
                    return await Reply(refusal.Status, refusal.Reason).ConfigureAwait(false);
                if (!sourceMediaLimits.TryAdmit(HostSourceMediaLimit.VolumeQuery))
                    return await Reply(SourceMediaStatus.Denied, SourceMediaReason.RateLimited).ConfigureAwait(false);
                if (check.Value != SourceVolumeScope.SystemOutput || options.SourceVolume is not { } sourceVolume)
                    return await SendAsync(
                            SourceVolumeStateMessage.Unsupported(requestId, PeerIdentity, windowId, check.Value,
                                HostSourceMedia.NextVolumeSequence()),
                            cancellationToken)
                        .ConfigureAwait(false);
                Audio.SourceVolumeReading reading = sourceVolume.Read();
                return await SendAsync(
                        HostSourceMedia.SystemOutputState(requestId, PeerIdentity, windowId, reading,
                            HostSourceMedia.NextVolumeSequence()),
                        cancellationToken)
                    .ConfigureAwait(false);
            }

            case SourceMediaProtocol.VolumeSetType:
            {
                if (!TryReadSourceMedia(line, out SourceVolumeSetMessage? volumeSet))
                    return await Reply(SourceMediaStatus.Invalid).ConfigureAwait(false);
                SourceMediaCheck<SourceVolumeChange> check = volumeSet.Check();
                if (!check.IsValid)
                    return await Reply(check.RefusalStatus!.Value, check.RefusalReason).ConfigureAwait(false);
                if (SourceMediaRefusal(windowId, null) is { } refusal)
                    return await Reply(refusal.Status, refusal.Reason).ConfigureAwait(false);
                if (!sourceMediaLimits.TryAdmit(HostSourceMediaLimit.VolumeSet))
                    return await Reply(SourceMediaStatus.Denied, SourceMediaReason.RateLimited).ConfigureAwait(false);
                SourceVolumeChange change = check.Value;
                if (change.Scope != SourceVolumeScope.SystemOutput || options.SourceVolume is not { } sourceVolume)
                    return await Reply(SourceMediaStatus.Unsupported, SourceMediaReason.ScopeUnsupported).ConfigureAwait(false);
                // The endpoint is fixed at admission; a newly selected output is never changed.
                if (sourceVolume.CurrentDevice() is not { } admittedDevice)
                    return await Reply(SourceMediaStatus.Failed, SourceMediaReason.NoOutputDevice).ConfigureAwait(false);
                HostSourceMediaRefusal? late = null;
                Audio.SourceVolumeApplyResult? applied = null;
                return await HandleInputAsync(
                        windowId,
                        window =>
                        {
                            late = SourceMediaRefusal(windowId, window);
                            if (late is not null)
                                return InputInjectionResult.Rejected("The source control is no longer admitted.");
                            return inputSession.HandleSourceVolume(window, () =>
                            {
                                Audio.SourceVolumeApplyResult result = sourceVolume.Apply(change.Volume, change.Muted, admittedDevice);
                                applied = result;
                                return result.Status == Audio.SourceVolumeApplyStatus.Applied
                                    ? InputInjectionResult.Success
                                    : InputInjectionResult.Rejected("The source volume change was not applied.");
                            });
                        },
                        cancellationToken,
                        result => applied is { } outcome && late is null
                            ? ReportSourceVolume(outcome, requestId, windowId, Reply, cancellationToken)
                            : ReportSourceInput(result, late, SourceMediaStatus.Failed, SourceMediaReason.OsRefused, Reply))
                    .ConfigureAwait(false);
            }

            default:
                return true;
        }
    }

    // Actual post-write state, never the requested values; failures map to bounded codes.
    private ValueTask<bool> ReportSourceVolume(
        Audio.SourceVolumeApplyResult outcome,
        string requestId,
        uint windowId,
        Func<SourceMediaStatus, SourceMediaReason?, ValueTask<bool>> reply,
        CancellationToken cancellationToken) => outcome.Status switch
    {
        Audio.SourceVolumeApplyStatus.Applied when outcome.Reading is { } reading => SendAsync(
            HostSourceMedia.SystemOutputState(requestId, PeerIdentity, windowId, reading, HostSourceMedia.NextVolumeSequence()),
            cancellationToken),
        Audio.SourceVolumeApplyStatus.DeviceChanged => reply(SourceMediaStatus.Stale, null),
        Audio.SourceVolumeApplyStatus.NoOutputDevice => reply(SourceMediaStatus.Failed, SourceMediaReason.NoOutputDevice),
        Audio.SourceVolumeApplyStatus.NotSettable => reply(SourceMediaStatus.Unsupported, SourceMediaReason.FixedVolume),
        _ => reply(SourceMediaStatus.Failed, SourceMediaReason.OsRefused),
    };

    private ValueTask<bool> ReportSourceInput(
        InputInjectionResult result,
        HostSourceMediaRefusal? late,
        SourceMediaStatus admittedStatus,
        SourceMediaReason? admittedReason,
        Func<SourceMediaStatus, SourceMediaReason?, ValueTask<bool>> reply)
    {
        if (late is { } refusal) return reply(refusal.Status, refusal.Reason);
        if (result.Succeeded) return reply(admittedStatus, admittedReason);
        if (StringComparer.Ordinal.Equals(result.Error, InputPermissionGate.DisabledReason))
            return reply(SourceMediaStatus.Denied, SourceMediaReason.ControlOff);
        // An ended session has no current requester to answer.
        if (!isCurrentGeneration(generation)) return ValueTask.FromResult(false);
        return reply(SourceMediaStatus.Failed, SourceMediaReason.OsRefused);
    }

    // Visible client, current window identity, not stopped, and an admitted video socket for
    // exactly this generation and peer. Host lock/sleep pauses hosting and closes the master
    // input gate first, so a locked source answers controlOff or has no session at all.
    private HostSourceMediaRefusal? SourceMediaRefusal(uint windowId, WindowDescriptor? window)
    {
        if (!clientVisible)
            return new(SourceMediaStatus.Denied, SourceMediaReason.NotVisible);
        if (windowId == 0 ||
            !windowIds.TryResolve(windowId, out WindowDescriptor? current) || current is null ||
            window is not null && !windowIds.IsCurrent(windowId, window) ||
            !streamRequests.IsAllowed(windowId) ||
            !hasActiveVideo(generation, PeerIdentity, windowId))
            return new(SourceMediaStatus.Stale, SourceMediaReason.StaleStream);
        return null;
    }

    private static bool TryReadSourceMedia<T>(
        ReadOnlyMemory<byte> line,
        [System.Diagnostics.CodeAnalysis.NotNullWhen(true)] out T? message)
        where T : class
    {
        try
        {
            message = PeelJson.Deserialize<T>(line.Span);
            return true;
        }
        catch (JsonException)
        {
            message = null;
            return false;
        }
    }

    private async ValueTask<bool> HandleClientActiveWindowAsync(
        uint requestedWindowId,
        string? focusRequestId,
        CancellationToken cancellationToken)
    {
        LastActivityAt = DateTimeOffset.UtcNow;
        bool didActivate = false;
        if (requestedWindowId != 0 &&
            windowIds.TryResolve(requestedWindowId, out WindowDescriptor? window) &&
            window is not null)
        {
            try
            {
                didActivate = InvokeInput(window, inputSession.HandleClientActiveWindow).Succeeded;
            }
            catch (Exception exception) when (
                exception is Win32Exception or
                    InvalidOperationException or
                    ArgumentException or
                    PlatformNotSupportedException)
            {
                didActivate = false;
            }
        }

        return await SendAsync(
                new WindowFocusStateMessage(
                    didActivate ? requestedWindowId : null,
                    requestedWindowId,
                    didActivate,
                    FocusRequestId: focusRequestId),
                cancellationToken)
            .ConfigureAwait(false);
    }

    private async ValueTask<bool> SendAsync<T>(T message, CancellationToken cancellationToken)
    {
        if (!isCurrentGeneration(generation))
        {
            return false;
        }

        byte[] line = PeelJson.SerializeLine(message);
        await writeGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (!isCurrentGeneration(generation))
            {
                return false;
            }

            await connection.Stream.WriteAsync(line, cancellationToken).ConfigureAwait(false);
            await connection.Stream.FlushAsync(cancellationToken).ConfigureAwait(false);
            return true;
        }
        finally
        {
            writeGate.Release();
        }
    }

    private static bool IsFailSoftSessionException(Exception exception) =>
        exception is IOException or InvalidDataException or JsonException or ObjectDisposedException;
}

internal sealed class HostWindowIdMap
{
    private readonly object stateLock = new();
    private readonly Dictionary<WindowIdentity, uint> idsByIdentity = [];
    private Dictionary<uint, WindowDescriptor> currentWindows = [];
    private uint nextWindowId = 1;

    internal IReadOnlyList<PeelWindow> CreateSnapshot(IReadOnlyList<WindowDescriptor> descriptors)
    {
        lock (stateLock)
        {
            var windows = new List<PeelWindow>(descriptors.Count);
            var emittedIdentities = new HashSet<WindowIdentity>();
            var emittedWindowIds = new HashSet<uint>();
            var replacementCurrentWindows = new Dictionary<uint, WindowDescriptor>();

            foreach (WindowDescriptor descriptor in descriptors)
            {
                var identity = new WindowIdentity(
                    descriptor.SourceKind,
                    descriptor.Handle,
                    descriptor.ProcessId);
                if (descriptor.Handle == nint.Zero ||
                    !descriptor.Bounds.IsUsable ||
                    string.IsNullOrWhiteSpace(descriptor.Title) ||
                    descriptor.IsDisplay != (descriptor.ProcessId == 0) ||
                    !emittedIdentities.Add(identity))
                {
                    continue;
                }

                uint windowId;
                if (descriptor.IsDisplay)
                {
                    if (descriptor.FixedWindowId is not uint fixedWindowId ||
                        fixedWindowId < WindowsDisplayCaptureSource.SyntheticBase ||
                        fixedWindowId >= WindowsDisplayCaptureSource.SyntheticBase +
                            WindowsDisplayCaptureSource.MaximumSyntheticDisplays)
                    {
                        continue;
                    }

                    windowId = fixedWindowId;
                }
                else if (!idsByIdentity.TryGetValue(identity, out windowId))
                {
                    if (nextWindowId == 0 ||
                        nextWindowId >= WindowsDisplayCaptureSource.SyntheticBase)
                    {
                        throw new InvalidOperationException("The session exhausted its window identifiers.");
                    }

                    windowId = nextWindowId++;
                    idsByIdentity.Add(identity, windowId);
                }

                if (!emittedWindowIds.Add(windowId))
                {
                    continue;
                }

                replacementCurrentWindows.Add(windowId, descriptor);
                windows.Add(new PeelWindow(
                    windowId,
                    string.IsNullOrWhiteSpace(descriptor.ProcessName) ? "Windows" : descriptor.ProcessName,
                    descriptor.Title,
                    descriptor.Bounds.Width,
                    descriptor.Bounds.Height,
                    StatusSummary: descriptor.StatusSummary,
                    AppIconPngBase64: descriptor.AppIconPngBase64,
                    AppLaunchTimeIntervalSince1970: descriptor.AppLaunchTimeIntervalSince1970));
            }

            currentWindows = replacementCurrentWindows;
            return windows.AsReadOnly();
        }
    }

    internal bool TryResolve(uint windowId, out WindowDescriptor? window)
    {
        lock (stateLock)
        {
            return currentWindows.TryGetValue(windowId, out window);
        }
    }

    internal bool IsCurrent(uint windowId, WindowDescriptor expectedWindow)
    {
        lock (stateLock)
        {
            return currentWindows.TryGetValue(windowId, out WindowDescriptor? current) &&
                current.SourceKind == expectedWindow.SourceKind &&
                current.Handle == expectedWindow.Handle &&
                current.ProcessId == expectedWindow.ProcessId;
        }
    }

    private readonly record struct WindowIdentity(
        CaptureSourceKind SourceKind,
        nint Handle,
        uint ProcessId);
}

internal sealed class HostStreamRequestGate
{
    private readonly object stateLock = new();
    private readonly HashSet<uint> stoppedWindowIds = [];

    internal bool IsAllowed(uint windowId)
    {
        lock (stateLock)
        {
            return !stoppedWindowIds.Contains(windowId);
        }
    }

    internal void SetAllowed(uint windowId, bool allowed)
    {
        lock (stateLock)
        {
            if (allowed)
            {
                stoppedWindowIds.Remove(windowId);
            }
            else
            {
                stoppedWindowIds.Add(windowId);
            }
        }
    }
}
