using System.Buffers;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Peel.Windows.Client.Models;
using Peel.Windows.Protocol;

namespace Peel.Windows.Client.Services;

public sealed partial class ClientSession :
    ISecureConnectionService,
    IWindowListService,
    IClientStreamControlChannel,
    IAsyncDisposable
{
    // Playback is advertised only when the native audio backend was actually
    // found ready for this session; Voice/microphone is never advertised.
    private IReadOnlyList<string> ImplementedCapabilities =>
        _options.SupportsAudioPlayback
            ? new[] { PeelCapability.ClientVisibility, AudioPlaybackCapability }
            : new[] { PeelCapability.ClientVisibility };

    private readonly object _stateGate = new();
    private readonly SemaphoreSlim _lifecycleGate = new(1, 1);
    private readonly SemaphoreSlim _writerGate = new(1, 1);
    private readonly IPeelPskTransportFactory _transportFactory;
    private readonly IPairedHostCredentialStore _credentialStore;
    private readonly IClientHostResolver _hostResolver;
    private readonly ClientHelloProfile _profile;
    private readonly ClientSessionOptions _options;

    private PeelConnectionState _state = PeelConnectionState.Disconnected;
    private HostCandidate? _connectedHost;
    private NegotiatedClientHost? _negotiatedHost;
    private IReadOnlyList<RemoteWindowDescriptor> _windows = Array.Empty<RemoteWindowDescriptor>();
    private CancellationTokenSource? _sessionCancellation;
    private Stream? _controlStream;
    private TaskCompletionSource<HostHelloMessage>? _hostHelloCompletion;
    private long _generation;
    private string? _activePairingId;
    private bool _windowListStarted;
    private bool _disposed;

    public ClientSession(
        IPeelPskTransportFactory transportFactory,
        IPairedHostCredentialStore credentialStore,
        IClientHostResolver hostResolver,
        ClientHelloProfile profile,
        ClientSessionOptions? options = null)
    {
        _transportFactory = PeelSecureTransport.Require(transportFactory);
        _credentialStore = credentialStore ?? throw new ArgumentNullException(nameof(credentialStore));
        _hostResolver = hostResolver ?? throw new ArgumentNullException(nameof(hostResolver));
        _profile = profile ?? throw new ArgumentNullException(nameof(profile));
        _options = options ?? ClientSessionOptions.Default;

        _profile.Validate();
        _options.Validate();
    }

    public event EventHandler<ConnectionStateChangedEventArgs>? StateChanged;

    public event EventHandler? WindowsChanged;

    public PeelConnectionState State
    {
        get
        {
            lock (_stateGate)
            {
                return _state;
            }
        }
    }

    public HostCandidate? ConnectedHost
    {
        get
        {
            lock (_stateGate)
            {
                return _connectedHost;
            }
        }
    }

    public NegotiatedClientHost? NegotiatedHost
    {
        get
        {
            lock (_stateGate)
            {
                return _negotiatedHost is null
                    ? null
                    : _negotiatedHost with
                    {
                        Capabilities = new HashSet<string>(
                            _negotiatedHost.Capabilities,
                            StringComparer.Ordinal),
                    };
            }
        }
    }

    public long SessionGeneration
    {
        get
        {
            lock (_stateGate)
            {
                return _generation;
            }
        }
    }

    public string? ActivePairingId
    {
        get
        {
            lock (_stateGate)
            {
                return _state == PeelConnectionState.Connected ? _activePairingId : null;
            }
        }
    }

    public IReadOnlyList<RemoteWindowDescriptor> Windows
    {
        get
        {
            lock (_stateGate)
            {
                return _windows;
            }
        }
    }

    public async Task ConnectAsync(HostCandidate host, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(host);
        await _lifecycleGate.WaitAsync(cancellationToken).ConfigureAwait(false);

        try
        {
            ThrowIfDisposed();
            StopCurrentSessionLocked();
            SetState(PeelConnectionState.Connecting);

            var freshHost = await ResolveAndValidateHostAsync(host.StableHostId, cancellationToken)
                .ConfigureAwait(false);
            var credential = await GetAndValidateCredentialAsync(freshHost.StableHostId, cancellationToken)
                .ConfigureAwait(false);

            var generation = CurrentGeneration;
            var sessionCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            var helloCompletion = new TaskCompletionSource<HostHelloMessage>(
                TaskCreationOptions.RunContinuationsAsynchronously);

            lock (_stateGate)
            {
                EnsureGenerationLocked(generation);
                _sessionCancellation = sessionCancellation;
                _hostHelloCompletion = helloCompletion;
            }

            var stream = await OpenSecureStreamAsync(freshHost, credential, sessionCancellation.Token)
                .ConfigureAwait(false);

            lock (_stateGate)
            {
                EnsureGenerationLocked(generation);
                _controlStream = stream;
            }

            _ = ReadControlLoopAsync(stream, generation, sessionCancellation.Token);

            var hello = PeelHello.CreateClient(
                credential.PairingId,
                _profile.DeviceName,
                "Linux",
                _profile.DeviceModel,
                _profile.OsVersion,
                _profile.AppVersion,
                ImplementedCapabilities);
            await SendMessageAsync(hello, generation, sessionCancellation.Token).ConfigureAwait(false);

            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(sessionCancellation.Token);
            timeout.CancelAfter(_options.HostHelloTimeout);
            HostHelloMessage hostHello;
            try
            {
                hostHello = await helloCompletion.Task.WaitAsync(timeout.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (!sessionCancellation.IsCancellationRequested)
            {
                throw new TimeoutException("The host did not send a compatible hostHello in time.");
            }

            if (!PeelProtocol.IsCompatible(
                    hostHello.ProtocolVersion,
                    hostHello.MinimumSupportedProtocolVersion))
            {
                throw new InvalidDataException("The hostHello protocol range is incompatible with Peel protocol v2.");
            }

            lock (_stateGate)
            {
                EnsureGenerationLocked(generation);
                _connectedHost = freshHost;
                _activePairingId = credential.PairingId;
                _negotiatedHost = new NegotiatedClientHost(
                    freshHost.StableHostId,
                    hostHello.ProtocolVersion,
                    hostHello.MinimumSupportedProtocolVersion,
                    new HashSet<string>(hostHello.Capabilities ?? [], StringComparer.Ordinal));
            }

            SetState(PeelConnectionState.Connected);
            await SendMessageAsync(
                    new ClientVisibilityMessage(true),
                    generation,
                    sessionCancellation.Token)
                .ConfigureAwait(false);
            _ = RunPingLoopAsync(generation, sessionCancellation.Token);
        }
        catch (OperationCanceledException)
        {
            StopCurrentSessionLocked();
            SetState(PeelConnectionState.Disconnected);
            throw;
        }
        catch (Exception exception)
        {
            StopCurrentSessionLocked();
            SetState(PeelConnectionState.Error, exception.Message);
            throw;
        }
        finally
        {
            _lifecycleGate.Release();
        }
    }

    public async Task DisconnectAsync(CancellationToken cancellationToken)
    {
        await _lifecycleGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_disposed && State == PeelConnectionState.Disconnected)
            {
                return;
            }

            SetState(PeelConnectionState.Disconnecting);
            StopCurrentSessionLocked();
            SetState(PeelConnectionState.Disconnected);
        }
        finally
        {
            _lifecycleGate.Release();
        }
    }

    public Task SendStartStreamAsync(uint windowId, CancellationToken cancellationToken) =>
        SendStreamControlAsync(PeelMessageType.StartStream, windowId, cancellationToken);

    public Task SendStopStreamAsync(uint windowId, CancellationToken cancellationToken) =>
        SendStreamControlAsync(PeelMessageType.StopStream, windowId, cancellationToken);

    async Task IWindowListService.StartAsync(CancellationToken cancellationToken)
    {
        await _lifecycleGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ThrowIfDisposed();
            long generation;
            CancellationToken sessionToken;

            lock (_stateGate)
            {
                if (_state != PeelConnectionState.Connected || _sessionCancellation is null)
                {
                    throw new InvalidOperationException("A compatible secure host session is required before requesting windows.");
                }

                if (_windowListStarted)
                {
                    return;
                }

                generation = _generation;
                sessionToken = _sessionCancellation.Token;
            }

            using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, sessionToken);
            await SendMessageAsync(
                    new PeelRequest(PeelMessageType.RequestWindowList),
                    generation,
                    linked.Token)
                .ConfigureAwait(false);

            lock (_stateGate)
            {
                EnsureGenerationLocked(generation);
                _windowListStarted = true;
            }
        }
        catch (Exception exception) when (exception is IOException or ObjectDisposedException)
        {
            SetState(PeelConnectionState.Error, exception.Message);
            throw;
        }
        finally
        {
            _lifecycleGate.Release();
        }
    }

    Task IWindowListService.StopAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        bool changed;
        lock (_stateGate)
        {
            _windowListStarted = false;
            changed = _windows.Count > 0;
            _windows = Array.Empty<RemoteWindowDescriptor>();
        }

        if (changed)
        {
            WindowsChanged?.Invoke(this, EventArgs.Empty);
        }

        return Task.CompletedTask;
    }

    public async ValueTask DisposeAsync()
    {
        await _lifecycleGate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            StopCurrentSessionLocked();
            SetState(PeelConnectionState.Disconnected);
        }
        finally
        {
            _lifecycleGate.Release();
        }
    }

    private long CurrentGeneration
    {
        get
        {
            lock (_stateGate)
            {
                return _generation;
            }
        }
    }

    private async ValueTask<HostCandidate> ResolveAndValidateHostAsync(
        string stableHostId,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(stableHostId))
        {
            throw new InvalidDataException("A stable host ID is required before connecting.");
        }

        var resolved = await _hostResolver.ResolveFreshAsync(stableHostId, cancellationToken)
            .ConfigureAwait(false);
        if (resolved is null)
        {
            throw new IOException($"Host '{stableHostId}' is not currently discoverable.");
        }

        if (!string.Equals(resolved.StableHostId, stableHostId, StringComparison.Ordinal))
        {
            throw new InvalidDataException("Fresh discovery returned a different stable host identity.");
        }

        if (string.IsNullOrWhiteSpace(resolved.Address) || resolved.Port is < 1 or > 65535)
        {
            throw new InvalidDataException("Fresh discovery returned an invalid host endpoint.");
        }

        return resolved;
    }

    private async ValueTask<PairedHostCredential> GetAndValidateCredentialAsync(
        string stableHostId,
        CancellationToken cancellationToken)
    {
        var credential = await _credentialStore.GetForHostAsync(stableHostId, cancellationToken)
            .ConfigureAwait(false);
        if (credential is null)
        {
            throw new ClientCapabilityUnavailableException(
                $"No paired TLS-PSK credential is available for host '{stableHostId}'.");
        }

        if (!string.Equals(credential.StableHostId, stableHostId, StringComparison.Ordinal))
        {
            throw new InvalidDataException("The stored TLS pairing belongs to a different stable host identity.");
        }

        return credential;
    }

    private async ValueTask<Stream> OpenSecureStreamAsync(
        HostCandidate host,
        PairedHostCredential credential,
        CancellationToken cancellationToken)
    {
        var key = credential.CopyPreSharedKey();
        PeelPskCredential? transportCredential = null;
        try
        {
            transportCredential = new PeelPskCredential(credential.PairingId, key);
            return await _transportFactory.ConnectAsync(
                    new DnsEndPoint(host.Address, host.Port),
                    transportCredential,
                    cancellationToken)
                .ConfigureAwait(false);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(key);
            if (transportCredential is not null)
            {
                CryptographicOperations.ZeroMemory(transportCredential.PreSharedKey);
            }
        }
    }

    private async Task ReadControlLoopAsync(
        Stream stream,
        long generation,
        CancellationToken cancellationToken)
    {
        var reader = new NdjsonReader(_options.MaximumControlLineBytes);
        var buffer = ArrayPool<byte>.Shared.Rent(16 * 1024);
        Exception? failure = null;

        try
        {
            while (true)
            {
                var count = await stream.ReadAsync(buffer.AsMemory(), cancellationToken).ConfigureAwait(false);
                if (count == 0)
                {
                    throw new IOException("The host closed the secure control connection.");
                }

                foreach (var line in reader.Append(buffer.AsSpan(0, count)))
                {
                    await HandleControlLineAsync(line, generation, cancellationToken).ConfigureAwait(false);
                }
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch (Exception exception) when (exception is IOException or InvalidDataException or JsonException)
        {
            failure = exception;
            CompleteHostHelloWithFailure(generation, exception);
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(buffer);
        }

        await HandleTransportEndedAsync(generation, failure, cancellationToken.IsCancellationRequested)
            .ConfigureAwait(false);
    }

    private Task HandleControlLineAsync(
        string line,
        long generation,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var utf8 = Encoding.UTF8.GetBytes(line);
        var envelope = PeelJson.ReadEnvelope(utf8);

        switch (envelope.Type)
        {
            case PeelMessageType.HostHello:
                HandleHostHello(PeelJson.Deserialize<HostHelloMessage>(utf8), generation);
                break;

            case PeelMessageType.ProtocolRejected:
                var rejected = PeelJson.Deserialize<ProtocolRejectedMessage>(utf8);
                throw new InvalidDataException($"The host rejected the client protocol: {rejected.Reason}");

            case PeelMessageType.WindowList:
                HandleWindowList(PeelJson.Deserialize<WindowListMessage>(utf8), generation);
                break;

            case "audioPairingChallenge":
                return HandleAudioChallengeAsync(PeelJson.Deserialize<AudioPairingChallengeMessage>(utf8), generation, cancellationToken);

            case "audioSessionState":
                HandleAudioState(PeelJson.Deserialize<AudioSessionStateMessage>(utf8), generation);
                break;

            case SourceMediaProtocol.AckType:
            case SourceMediaProtocol.VolumeStateType:
                // Bounded raw reply; the owning source-media client validates it
                // against its captured pairing, window and request.
                if (utf8.Length <= SourceMediaProtocol.MaximumLineBytes)
                {
                    SourceMediaReplyReceived?.Invoke(this, new SourceMediaReplyEventArgs(envelope.Type, utf8, generation));
                }

                break;
        }

        return Task.CompletedTask;
    }

    private void HandleHostHello(HostHelloMessage hello, long generation)
    {
        TaskCompletionSource<HostHelloMessage> completion;
        lock (_stateGate)
        {
            EnsureGenerationLocked(generation);
            if (_state != PeelConnectionState.Connecting
                || _hostHelloCompletion is null
                || _hostHelloCompletion.Task.IsCompleted)
            {
                throw new InvalidDataException("Received an unexpected or duplicate hostHello.");
            }

            if (string.IsNullOrWhiteSpace(hello.HostName))
            {
                throw new InvalidDataException("The hostHello did not contain a host name.");
            }

            if (!PeelProtocol.IsCompatible(
                    hello.ProtocolVersion,
                    hello.MinimumSupportedProtocolVersion))
            {
                throw new InvalidDataException("The hostHello protocol range is incompatible with Peel protocol v2.");
            }

            completion = _hostHelloCompletion;
        }

        completion.TrySetResult(hello);
    }

    private void HandleWindowList(WindowListMessage message, long generation)
    {
        if (message.Windows is null || message.Windows.Count > _options.MaximumWindowCount)
        {
            throw new InvalidDataException("The host sent an invalid or oversized window list.");
        }

        var seen = new HashSet<uint>();
        var mapped = new List<RemoteWindowDescriptor>(message.Windows.Count);
        foreach (var window in message.Windows)
        {
            if (!seen.Add(window.WindowId)
                || string.IsNullOrWhiteSpace(window.AppName)
                || window.Title is null
                || window.Width < 0
                || window.Height < 0
                || window.Width > _options.MaximumWindowDimension
                || window.Height > _options.MaximumWindowDimension)
            {
                throw new InvalidDataException("The host sent a malformed window descriptor.");
            }

            mapped.Add(new RemoteWindowDescriptor(
                window.WindowId,
                window.Title,
                window.AppName,
                window.Width,
                window.Height));
        }

        lock (_stateGate)
        {
            EnsureGenerationLocked(generation);
            if (_state != PeelConnectionState.Connected || !_windowListStarted)
            {
                throw new InvalidDataException("Received a windowList before the client requested one.");
            }

            _windows = mapped.ToArray();
        }

        WindowsChanged?.Invoke(this, EventArgs.Empty);
    }

    private async Task RunPingLoopAsync(long generation, CancellationToken cancellationToken)
    {
        try
        {
            using var timer = new PeriodicTimer(_options.PingInterval);
            while (await timer.WaitForNextTickAsync(cancellationToken).ConfigureAwait(false))
            {
                await SendMessageAsync(new ClientPingMessage(), generation, cancellationToken)
                    .ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch (Exception exception) when (exception is IOException or ObjectDisposedException)
        {
            await HandleTransportEndedAsync(generation, exception, cancelled: false).ConfigureAwait(false);
        }
    }

    private async Task SendMessageAsync<T>(
        T message,
        long generation,
        CancellationToken cancellationToken,
        Func<bool>? stillOwned = null)
    {
        var line = PeelJson.SerializeLine(message);
        await _writerGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            // Final write-time check after the writer wait: a request whose owner was
            // cancelled or replaced while queued is never written.
            cancellationToken.ThrowIfCancellationRequested();
            if (stillOwned is not null && !stillOwned())
            {
                throw new OperationCanceledException("The request's owner changed before it was written.");
            }

            Stream stream;
            lock (_stateGate)
            {
                EnsureGenerationLocked(generation);
                stream = _controlStream
                    ?? throw new IOException("The secure control stream is not available.");
            }

            await stream.WriteAsync(line, cancellationToken).ConfigureAwait(false);
            await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _writerGate.Release();
        }
    }

    private async Task SendStreamControlAsync(
        string messageType,
        uint windowId,
        CancellationToken cancellationToken)
    {
        if (windowId == 0
            || messageType is not PeelMessageType.StartStream and not PeelMessageType.StopStream)
        {
            throw new ArgumentOutOfRangeException(nameof(windowId));
        }

        await _lifecycleGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ThrowIfDisposed();
            long generation;
            CancellationToken sessionToken;
            lock (_stateGate)
            {
                if (_state != PeelConnectionState.Connected || _sessionCancellation is null)
                {
                    throw new InvalidOperationException(
                        "A compatible secure host session is required before controlling a stream.");
                }

                generation = _generation;
                sessionToken = _sessionCancellation.Token;
            }

            using var linked = CancellationTokenSource.CreateLinkedTokenSource(
                cancellationToken,
                sessionToken);
            await SendMessageAsync(
                    new PeelRequest(messageType, windowId),
                    generation,
                    linked.Token)
                .ConfigureAwait(false);
        }
        catch (Exception exception) when (exception is IOException or ObjectDisposedException)
        {
            StopCurrentSessionLocked();
            SetState(PeelConnectionState.Error, exception.Message);
            throw;
        }
        finally
        {
            _lifecycleGate.Release();
        }
    }

    private async Task HandleTransportEndedAsync(
        long generation,
        Exception? failure,
        bool cancelled)
    {
        await _lifecycleGate.WaitAsync().ConfigureAwait(false);
        try
        {
            lock (_stateGate)
            {
                if (_generation != generation)
                {
                    return;
                }
            }

            StopCurrentSessionLocked();
            SetState(
                cancelled ? PeelConnectionState.Disconnected : PeelConnectionState.Error,
                failure?.Message);
        }
        finally
        {
            _lifecycleGate.Release();
        }
    }

    private void CompleteHostHelloWithFailure(long generation, Exception failure)
    {
        TaskCompletionSource<HostHelloMessage>? completion;
        lock (_stateGate)
        {
            if (_generation != generation)
            {
                return;
            }

            completion = _hostHelloCompletion;
        }

        completion?.TrySetException(failure);
    }

    private void StopCurrentSessionLocked()
    {
        CancellationTokenSource? cancellation;
        Stream? stream;
        TaskCompletionSource<HostHelloMessage>? helloCompletion;
        bool windowsChanged;

        lock (_stateGate)
        {
            _generation = checked(_generation + 1);
            cancellation = _sessionCancellation;
            stream = _controlStream;
            helloCompletion = _hostHelloCompletion;
            windowsChanged = _windows.Count > 0;

            _sessionCancellation = null;
            _controlStream = null;
            _hostHelloCompletion = null;
            _connectedHost = null;
            _negotiatedHost = null;
            _activePairingId = null;
            _audioCompletion?.TrySetCanceled();
            _audioCompletion = null;
            _audioRequestId = null;
            _audioProofSent = false;
            _windowListStarted = false;
            _windows = Array.Empty<RemoteWindowDescriptor>();
        }

        cancellation?.Cancel();
        helloCompletion?.TrySetCanceled();
        stream?.Dispose();
        cancellation?.Dispose();

        if (windowsChanged)
        {
            WindowsChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    private void SetState(PeelConnectionState state, string? detail = null)
    {
        lock (_stateGate)
        {
            _state = state;
        }

        StateChanged?.Invoke(this, new ConnectionStateChangedEventArgs(state, detail));
    }

    private void EnsureGenerationLocked(long generation)
    {
        if (_generation != generation)
        {
            throw new OperationCanceledException("The client session generation is stale.");
        }
    }

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
    }
}
