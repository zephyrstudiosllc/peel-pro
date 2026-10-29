using System.Buffers;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using Peel.Windows.Client.Models;
using Peel.Windows.Protocol;

namespace Peel.Windows.Client.Services;

public sealed class ClientVideoSocketSession : IAsyncDisposable
{
    private readonly object _stateGate = new();
    private readonly SemaphoreSlim _lifecycleGate = new(1, 1);
    private readonly SemaphoreSlim _decoderGate = new(1, 1);
    private readonly IPeelPskTransportFactory _transportFactory;
    private readonly IPairedHostCredentialStore _credentialStore;
    private readonly IClientHostResolver _hostResolver;
    private readonly IVideoDecoderSink _decoderSink;
    private readonly ClientVideoSocketOptions _options;
    private readonly IReadOnlySet<PeelVideoCodec> _supportedCodecs;

    private ClientVideoSocketState _state = ClientVideoSocketState.Stopped;
    private CancellationTokenSource? _sessionCancellation;
    private Stream? _stream;
    private long _generation;
    private uint? _windowId;
    private PeelVideoCodec? _codec;
    private bool _hasConfiguration;
    private bool _hasKeyframe;
    private bool _disposed;

    public ClientVideoSocketSession(
        IPeelPskTransportFactory transportFactory,
        IPairedHostCredentialStore credentialStore,
        IClientHostResolver hostResolver,
        IVideoDecoderSink decoderSink,
        ClientVideoSocketOptions? options = null)
    {
        _transportFactory = PeelSecureTransport.Require(transportFactory);
        _credentialStore = credentialStore ?? throw new ArgumentNullException(nameof(credentialStore));
        _hostResolver = hostResolver ?? throw new ArgumentNullException(nameof(hostResolver));
        _decoderSink = decoderSink ?? throw new ArgumentNullException(nameof(decoderSink));
        _options = options ?? ClientVideoSocketOptions.Default;
        _options.Validate();

        _supportedCodecs = new HashSet<PeelVideoCodec>(decoderSink.SupportedCodecs);
        if (_supportedCodecs.Count == 0
            || _supportedCodecs.Any(codec => codec is not PeelVideoCodec.H264 and not PeelVideoCodec.Hevc))
        {
            throw new ArgumentException("The decoder sink must declare at least one supported Peel codec.", nameof(decoderSink));
        }
    }

    public event EventHandler<ClientVideoSocketStateChangedEventArgs>? StateChanged;

    public event EventHandler<DecodedVideoFrameEventArgs>? FrameDecoded
    {
        add => _decoderSink.FrameDecoded += value;
        remove => _decoderSink.FrameDecoded -= value;
    }

    public IReadOnlySet<PeelVideoCodec> SupportedCodecs => _supportedCodecs;

    public ClientVideoSocketState State
    {
        get
        {
            lock (_stateGate)
            {
                return _state;
            }
        }
    }

    public uint? WindowId
    {
        get
        {
            lock (_stateGate)
            {
                return _windowId;
            }
        }
    }

    public async Task StartAsync(
        NegotiatedVideoStreamRequest request,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        await _lifecycleGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ThrowIfDisposed();
            var previousWindowId = StopCurrentLocked();
            if (previousWindowId is not null && previousWindowId != request.WindowId)
            {
                await ResetDecoderAsync(previousWindowId.Value).ConfigureAwait(false);
            }

            ValidateNegotiation(request);
            await ResetDecoderAsync(request.WindowId, cancellationToken).ConfigureAwait(false);
            SetState(ClientVideoSocketState.Connecting);

            var freshHost = await ResolveAndValidateHostAsync(request.StableHostId, cancellationToken)
                .ConfigureAwait(false);
            var credential = await GetAndValidateCredentialAsync(request.StableHostId, cancellationToken)
                .ConfigureAwait(false);

            var generation = CurrentGeneration;
            var sessionCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            lock (_stateGate)
            {
                EnsureGenerationLocked(generation);
                _sessionCancellation = sessionCancellation;
                _windowId = request.WindowId;
                _codec = request.Codec;
            }

            var stream = await OpenSecureStreamAsync(freshHost, credential, sessionCancellation.Token)
                .ConfigureAwait(false);
            lock (_stateGate)
            {
                EnsureGenerationLocked(generation);
                _stream = stream;
            }

            var hello = PeelHello.CreateVideoStream(
                request.WindowId,
                credential.PairingId,
                CreateAdvertisedCapabilities());
            var line = PeelJson.SerializeLine(hello);
            await stream.WriteAsync(line, sessionCancellation.Token).ConfigureAwait(false);
            await stream.FlushAsync(sessionCancellation.Token).ConfigureAwait(false);

            SetState(ClientVideoSocketState.WaitingForConfiguration);
            _ = ReadBinaryLoopAsync(stream, generation, sessionCancellation.Token);
        }
        catch (OperationCanceledException)
        {
            var windowId = StopCurrentLocked();
            if (windowId is not null)
            {
                await ResetDecoderAsync(windowId.Value).ConfigureAwait(false);
            }

            SetState(ClientVideoSocketState.Stopped);
            throw;
        }
        catch (Exception exception)
        {
            var windowId = StopCurrentLocked();
            if (windowId is not null)
            {
                await ResetDecoderAsync(windowId.Value).ConfigureAwait(false);
            }

            SetState(ClientVideoSocketState.Error, exception.Message);
            throw;
        }
        finally
        {
            _lifecycleGate.Release();
        }
    }

    public async Task StopAsync(CancellationToken cancellationToken)
    {
        await _lifecycleGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var windowId = StopCurrentLocked();
            if (windowId is not null)
            {
                await ResetDecoderAsync(windowId.Value).ConfigureAwait(false);
            }

            SetState(ClientVideoSocketState.Stopped);
        }
        finally
        {
            _lifecycleGate.Release();
        }
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
            var windowId = StopCurrentLocked();
            if (windowId is not null)
            {
                await ResetDecoderAsync(windowId.Value).ConfigureAwait(false);
            }

            SetState(ClientVideoSocketState.Stopped);
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

    private void ValidateNegotiation(NegotiatedVideoStreamRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.StableHostId) || request.WindowId == 0)
        {
            throw new InvalidDataException("A stable host ID and non-zero window ID are required.");
        }

        if (!_supportedCodecs.Contains(request.Codec))
        {
            throw new ClientCapabilityUnavailableException(
                $"The configured decoder does not support {request.Codec}.");
        }

        if (!PeelProtocol.IsCompatible(
                request.RemoteProtocolVersion,
                request.RemoteMinimumSupportedProtocolVersion))
        {
            throw new InvalidDataException("The negotiated host protocol is incompatible with Peel protocol v2.");
        }

        var codecCapability = request.Codec == PeelVideoCodec.Hevc
            ? PeelCapability.HevcVideo
            : PeelCapability.H264Video;
        if (request.RemoteCapabilities is null
            || !request.RemoteCapabilities.Contains(PeelCapability.PerWindowVideoConnections)
            || !request.RemoteCapabilities.Contains(PeelCapability.BinaryVideoTransportV2)
            || !request.RemoteCapabilities.Contains(codecCapability))
        {
            throw new ClientCapabilityUnavailableException(
                "The negotiated host capabilities do not support the requested per-window binary codec.");
        }
    }

    private IReadOnlyList<string> CreateAdvertisedCapabilities()
    {
        var capabilities = new List<string>
        {
            PeelCapability.BinaryVideoTransportV2,
            PeelCapability.PerWindowVideoConnections,
        };

        if (_supportedCodecs.Contains(PeelVideoCodec.H264))
        {
            capabilities.Add(PeelCapability.H264Video);
        }

        if (_supportedCodecs.Contains(PeelVideoCodec.Hevc))
        {
            capabilities.Add(PeelCapability.HevcVideo);
        }

        return PeelHello.SortedCapabilities(capabilities);
    }

    private async ValueTask<HostCandidate> ResolveAndValidateHostAsync(
        string stableHostId,
        CancellationToken cancellationToken)
    {
        var host = await _hostResolver.ResolveFreshAsync(stableHostId, cancellationToken)
            .ConfigureAwait(false);
        if (host is null)
        {
            throw new IOException($"Host '{stableHostId}' is not currently discoverable.");
        }

        if (!string.Equals(host.StableHostId, stableHostId, StringComparison.Ordinal))
        {
            throw new InvalidDataException("Fresh discovery returned a different stable host identity.");
        }

        if (string.IsNullOrWhiteSpace(host.Address) || host.Port is < 1 or > 65535)
        {
            throw new InvalidDataException("Fresh discovery returned an invalid host endpoint.");
        }

        return host;
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

    private async Task ReadBinaryLoopAsync(
        Stream stream,
        long generation,
        CancellationToken cancellationToken)
    {
        var reader = new PeelBinaryPacketReader(_options.MaximumPacketBytes);
        var buffer = ArrayPool<byte>.Shared.Rent(256 * 1024);
        Exception? failure = null;

        try
        {
            while (true)
            {
                var count = await stream.ReadAsync(buffer.AsMemory(), cancellationToken).ConfigureAwait(false);
                if (count == 0)
                {
                    throw new IOException("The host closed the secure video connection.");
                }

                foreach (var packet in reader.Append(buffer.AsSpan(0, count)))
                {
                    await HandlePacketAsync(packet, generation, cancellationToken).ConfigureAwait(false);
                }
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch (Exception exception) when (
            exception is IOException or InvalidDataException or ObjectDisposedException)
        {
            failure = exception;
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(buffer);
        }

        await HandleEndedAsync(generation, failure, cancellationToken.IsCancellationRequested)
            .ConfigureAwait(false);
    }

    private async ValueTask HandlePacketAsync(
        IPeelBinaryPacket packet,
        long generation,
        CancellationToken cancellationToken)
    {
        uint windowId;
        PeelVideoCodec codec;
        lock (_stateGate)
        {
            EnsureGenerationLocked(generation);
            windowId = _windowId
                ?? throw new OperationCanceledException("The video window is no longer active.");
            codec = _codec
                ?? throw new OperationCanceledException("The video codec is no longer active.");
        }

        if (packet.WindowId != windowId)
        {
            throw new InvalidDataException("The video socket received a packet for a different window ID.");
        }

        switch (packet)
        {
            case VideoConfigPacket configuration:
                ValidateConfiguration(configuration, codec);
                await _decoderGate.WaitAsync(cancellationToken).ConfigureAwait(false);
                try
                {
                    lock (_stateGate)
                    {
                        EnsureGenerationLocked(generation);
                    }

                    await _decoderSink.ConfigureAsync(configuration, cancellationToken).ConfigureAwait(false);
                    lock (_stateGate)
                    {
                        EnsureGenerationLocked(generation);
                        _hasConfiguration = true;
                        _hasKeyframe = false;
                    }
                }
                finally
                {
                    _decoderGate.Release();
                }

                SetStateForGeneration(generation, ClientVideoSocketState.WaitingForKeyframe);
                break;

            case VideoFramePacket frame:
                bool hasConfiguration;
                bool hasKeyframe;
                lock (_stateGate)
                {
                    EnsureGenerationLocked(generation);
                    hasConfiguration = _hasConfiguration;
                    hasKeyframe = _hasKeyframe;
                }

                if (!hasConfiguration)
                {
                    throw new InvalidDataException("The video socket received a frame before codec configuration.");
                }

                if (frame.Payload.Length == 0 ||
                    frame.PtsValue < 0 ||
                    frame.DurationValue < 0)
                {
                    throw new InvalidDataException("The video socket received a malformed encoded frame.");
                }

                try
                {
                    _ = checked(frame.PtsValue + frame.DurationValue);
                }
                catch (OverflowException exception)
                {
                    throw new InvalidDataException(
                        "The video frame timestamp range overflowed.",
                        exception);
                }

                if (!hasKeyframe && !frame.IsKeyframe)
                {
                    return;
                }

                await _decoderGate.WaitAsync(cancellationToken).ConfigureAwait(false);
                try
                {
                    lock (_stateGate)
                    {
                        EnsureGenerationLocked(generation);
                    }

                    await _decoderSink.SubmitAsync(frame, cancellationToken).ConfigureAwait(false);
                    lock (_stateGate)
                    {
                        EnsureGenerationLocked(generation);
                        _hasKeyframe = true;
                    }
                }
                finally
                {
                    _decoderGate.Release();
                }

                SetStateForGeneration(generation, ClientVideoSocketState.Streaming);
                break;

            default:
                throw new InvalidDataException($"Unsupported binary packet type {packet.PacketType}.");
        }
    }

    private void ValidateConfiguration(VideoConfigPacket configuration, PeelVideoCodec expectedCodec)
    {
        if (configuration.Codec != expectedCodec
            || configuration.Width == 0
            || configuration.Height == 0
            || configuration.Width > _options.MaximumDimension
            || configuration.Height > _options.MaximumDimension
            || configuration.Timescale == 0
            || configuration.NalUnitHeaderLength is not (1 or 2 or 4)
            || configuration.Sps.Length == 0
            || configuration.Pps.Length == 0
            || (configuration.Codec == PeelVideoCodec.Hevc && configuration.Vps is not { Length: > 0 })
            || (configuration.Codec == PeelVideoCodec.H264 && configuration.Vps is { Length: > 0 }))
        {
            throw new InvalidDataException("The video socket received an invalid codec configuration.");
        }
    }

    private async Task HandleEndedAsync(long generation, Exception? failure, bool cancelled)
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

            var windowId = StopCurrentLocked();
            if (windowId is not null)
            {
                await ResetDecoderAsync(windowId.Value).ConfigureAwait(false);
            }

            SetState(
                cancelled ? ClientVideoSocketState.Stopped : ClientVideoSocketState.Error,
                failure?.Message);
        }
        finally
        {
            _lifecycleGate.Release();
        }
    }

    private uint? StopCurrentLocked()
    {
        CancellationTokenSource? cancellation;
        Stream? stream;
        uint? windowId;
        lock (_stateGate)
        {
            _generation = checked(_generation + 1);
            cancellation = _sessionCancellation;
            stream = _stream;
            windowId = _windowId;

            _sessionCancellation = null;
            _stream = null;
            _windowId = null;
            _codec = null;
            _hasConfiguration = false;
            _hasKeyframe = false;
        }

        cancellation?.Cancel();
        stream?.Dispose();
        cancellation?.Dispose();
        return windowId;
    }

    private async ValueTask ResetDecoderAsync(
        uint windowId,
        CancellationToken cancellationToken = default)
    {
        await _decoderGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await _decoderSink.ResetAsync(windowId, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _decoderGate.Release();
        }
    }

    private void SetState(ClientVideoSocketState state, string? detail = null)
    {
        lock (_stateGate)
        {
            _state = state;
        }

        StateChanged?.Invoke(this, new ClientVideoSocketStateChangedEventArgs(state, detail));
    }

    private void SetStateForGeneration(
        long generation,
        ClientVideoSocketState state,
        string? detail = null)
    {
        lock (_stateGate)
        {
            EnsureGenerationLocked(generation);
            _state = state;
        }

        StateChanged?.Invoke(this, new ClientVideoSocketStateChangedEventArgs(state, detail));
    }

    private void EnsureGenerationLocked(long generation)
    {
        if (_generation != generation)
        {
            throw new OperationCanceledException("The video session generation is stale.");
        }
    }

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
    }
}
