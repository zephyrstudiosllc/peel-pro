using System.IO;
using Peel.Windows.Client.Models;
using Peel.Windows.Protocol;

namespace Peel.Windows.Client.Services;

public sealed class ClientStreamController : IStreamControlService, IAsyncDisposable
{
    private readonly object _stateGate = new();
    private readonly SemaphoreSlim _lifecycleGate = new(1, 1);
    private readonly ISecureConnectionService _connection;
    private readonly IWindowListService _windowList;
    private readonly IClientStreamControlChannel _control;
    private readonly ClientVideoSocketSession _video;
    private readonly PeelVideoCodec _codec;

    private PeelStreamState _state = PeelStreamState.Stopped;
    private uint? _streamingWindowId;
    private CancellationTokenSource? _streamCancellation;
    private long _generation;
    private bool _disposed;

    public ClientStreamController(
        ISecureConnectionService connection,
        IWindowListService windowList,
        IClientStreamControlChannel control,
        ClientVideoSocketSession video,
        PeelVideoCodec codec)
    {
        _connection = connection ?? throw new ArgumentNullException(nameof(connection));
        _windowList = windowList ?? throw new ArgumentNullException(nameof(windowList));
        _control = control ?? throw new ArgumentNullException(nameof(control));
        _video = video ?? throw new ArgumentNullException(nameof(video));
        if (codec is not PeelVideoCodec.H264 and not PeelVideoCodec.Hevc)
        {
            throw new ArgumentOutOfRangeException(nameof(codec));
        }

        _codec = codec;
        _connection.StateChanged += HandleConnectionStateChanged;
        _video.StateChanged += HandleVideoStateChanged;
    }

    public event EventHandler<StreamStateChangedEventArgs>? StateChanged;

    public event EventHandler<DecodedVideoFrameEventArgs>? FrameAvailable
    {
        add => _video.FrameDecoded += value;
        remove => _video.FrameDecoded -= value;
    }

    public PeelStreamState State
    {
        get
        {
            lock (_stateGate)
            {
                return _state;
            }
        }
    }

    public uint? StreamingWindowId
    {
        get
        {
            lock (_stateGate)
            {
                return _streamingWindowId;
            }
        }
    }

    public async Task StartAsync(
        RemoteWindowDescriptor window,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(window);
        await _lifecycleGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ThrowIfDisposed();
            ValidateStartRequest(window);

            if (StreamingWindowId is not null)
            {
                await StopActiveLockedAsync(sendStopRequest: true).ConfigureAwait(false);
            }

            var host = _connection.ConnectedHost
                ?? throw new InvalidOperationException("A connected host is required before starting video.");
            var negotiation = _control.NegotiatedHost
                ?? throw new InvalidOperationException("A compatible hostHello is required before starting video.");
            if (!string.Equals(
                    host.StableHostId,
                    negotiation.StableHostId,
                    StringComparison.Ordinal))
            {
                throw new InvalidDataException("The negotiated video host does not match the connected stable host identity.");
            }

            var generation = checked(++_generation);
            var streamCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            lock (_stateGate)
            {
                _streamCancellation = streamCancellation;
                _streamingWindowId = window.Id;
            }

            SetState(PeelStreamState.Starting);
            var request = new NegotiatedVideoStreamRequest(
                negotiation.StableHostId,
                window.Id,
                _codec,
                negotiation.ProtocolVersion,
                negotiation.MinimumSupportedProtocolVersion,
                negotiation.Capabilities);

            try
            {
                // The dedicated socket must identify itself before startStream can
                // cause the host encoder to emit binary configuration and frames.
                await _video.StartAsync(request, streamCancellation.Token).ConfigureAwait(false);
                EnsureGeneration(generation);
                await _control.SendStartStreamAsync(window.Id, streamCancellation.Token).ConfigureAwait(false);
                EnsureGeneration(generation);
            }
            catch (OperationCanceledException)
            {
                await StopActiveLockedAsync(sendStopRequest: false).ConfigureAwait(false);
                SetState(PeelStreamState.Stopped);
                throw;
            }
            catch (Exception exception)
            {
                await StopActiveLockedAsync(sendStopRequest: false).ConfigureAwait(false);
                SetState(PeelStreamState.Error, exception.Message);
                throw;
            }
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
            if (StreamingWindowId is null)
            {
                SetState(PeelStreamState.Stopped);
                return;
            }

            SetState(PeelStreamState.Stopping);
            await StopActiveLockedAsync(sendStopRequest: true).ConfigureAwait(false);
            SetState(PeelStreamState.Stopped);
        }
        catch (Exception exception) when (
            exception is IOException or ObjectDisposedException or InvalidOperationException)
        {
            SetState(PeelStreamState.Error, exception.Message);
            throw;
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
            _connection.StateChanged -= HandleConnectionStateChanged;
            _video.StateChanged -= HandleVideoStateChanged;
            await StopActiveLockedAsync(sendStopRequest: false).ConfigureAwait(false);
            await _video.DisposeAsync().ConfigureAwait(false);
            SetState(PeelStreamState.Stopped);
        }
        finally
        {
            _lifecycleGate.Release();
        }
    }

    private void ValidateStartRequest(RemoteWindowDescriptor window)
    {
        if (window.Id == 0
            || _connection.State != PeelConnectionState.Connected
            || !_windowList.Windows.Any(candidate => candidate.Id == window.Id))
        {
            throw new InvalidOperationException(
                "Streaming requires a non-zero window from the current connected host window list.");
        }

        if (!_video.SupportedCodecs.Contains(_codec))
        {
            throw new ClientCapabilityUnavailableException(
                $"The configured decoder does not support {_codec}.");
        }
    }

    private async Task StopActiveLockedAsync(bool sendStopRequest)
    {
        uint? windowId;
        CancellationTokenSource? cancellation;
        lock (_stateGate)
        {
            _generation = checked(_generation + 1);
            windowId = _streamingWindowId;
            cancellation = _streamCancellation;
            _streamingWindowId = null;
            _streamCancellation = null;
        }

        cancellation?.Cancel();
        try
        {
            await _video.StopAsync(CancellationToken.None).ConfigureAwait(false);
        }
        finally
        {
            cancellation?.Dispose();
        }

        if (sendStopRequest
            && windowId is not null
            && _connection.State == PeelConnectionState.Connected)
        {
            await _control.SendStopStreamAsync(windowId.Value, CancellationToken.None)
                .ConfigureAwait(false);
        }
    }

    private void HandleConnectionStateChanged(
        object? sender,
        ConnectionStateChangedEventArgs eventArgs)
    {
        if (eventArgs.State != PeelConnectionState.Connected)
        {
            _ = StopForDisconnectedControlAsync();
        }
    }

    private async Task StopForDisconnectedControlAsync()
    {
        await _lifecycleGate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (_disposed || StreamingWindowId is null)
            {
                return;
            }

            await StopActiveLockedAsync(sendStopRequest: false).ConfigureAwait(false);
            SetState(PeelStreamState.Stopped);
        }
        catch (Exception exception) when (
            exception is IOException or ObjectDisposedException or InvalidOperationException)
        {
            SetState(PeelStreamState.Error, exception.Message);
        }
        finally
        {
            _lifecycleGate.Release();
        }
    }

    private void HandleVideoStateChanged(
        object? sender,
        ClientVideoSocketStateChangedEventArgs eventArgs)
    {
        if (StreamingWindowId is null)
        {
            return;
        }

        switch (eventArgs.State)
        {
            case ClientVideoSocketState.Connecting:
            case ClientVideoSocketState.WaitingForConfiguration:
            case ClientVideoSocketState.WaitingForKeyframe:
                SetState(PeelStreamState.Starting, eventArgs.Detail);
                break;

            case ClientVideoSocketState.Streaming:
                SetState(PeelStreamState.Streaming, eventArgs.Detail);
                break;

            case ClientVideoSocketState.Error:
                SetState(PeelStreamState.Error, eventArgs.Detail);
                break;

            case ClientVideoSocketState.Stopped:
                _ = StopForEndedVideoAsync();
                break;
        }
    }

    private async Task StopForEndedVideoAsync()
    {
        await _lifecycleGate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (_disposed || StreamingWindowId is null)
            {
                return;
            }

            await StopActiveLockedAsync(
                    sendStopRequest: _connection.State == PeelConnectionState.Connected)
                .ConfigureAwait(false);
            SetState(PeelStreamState.Stopped);
        }
        catch (Exception exception) when (
            exception is IOException or ObjectDisposedException or InvalidOperationException)
        {
            SetState(PeelStreamState.Error, exception.Message);
        }
        finally
        {
            _lifecycleGate.Release();
        }
    }

    private void EnsureGeneration(long generation)
    {
        lock (_stateGate)
        {
            if (_generation != generation)
            {
                throw new OperationCanceledException("The stream-control generation is stale.");
            }
        }
    }

    private void SetState(PeelStreamState state, string? detail = null)
    {
        lock (_stateGate)
        {
            _state = state;
        }

        StateChanged?.Invoke(this, new StreamStateChangedEventArgs(state, detail));
    }

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
    }
}
