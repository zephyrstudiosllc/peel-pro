using System.Text.Json;
using Peel.Windows.Host.Capture;
using Peel.Windows.Host.Encoding;
using Peel.Windows.Host.Orchestration;
using Peel.Windows.Protocol;

namespace Peel.Windows.Host.Networking;

/// Owns authenticated per-window video connections after a control session has
/// published a session-local window identifier. Listener and credential ownership
/// deliberately remain outside this boundary.
public sealed class HostVideoSessionManager : IAsyncDisposable
{
    private const int ReadBufferBytes = 4 * 1024;

    private readonly object stateLock = new();
    private readonly IHostVideoBindingResolver bindingResolver;
    private readonly HostControlSessionManager? controlSessionManager;
    private readonly IWindowCaptureBackend captureBackend;
    private readonly IVideoEncoderFactory encoderFactory;
    private readonly HostVideoSessionOptions options;
    private readonly CancellationTokenSource lifetimeCancellation = new();
    private readonly Dictionary<long, ActiveVideoOperation> operations = [];
    private readonly Dictionary<VideoSlot, long> currentOperationsByWindow = [];
    private long nextOperationId;
    private bool disposed;

    public HostVideoSessionManager(
        HostControlSessionManager controlSessionManager,
        IWindowCaptureBackend captureBackend,
        IVideoEncoderFactory encoderFactory,
        HostVideoSessionOptions options)
        : this(
            (IHostVideoBindingResolver)controlSessionManager,
            captureBackend,
            encoderFactory,
            options)
    {
        this.controlSessionManager = controlSessionManager ??
            throw new ArgumentNullException(nameof(controlSessionManager));
        this.controlSessionManager.VideoStopRequested += HandleVideoStopRequested;
        this.controlSessionManager.SetActiveVideoProbe(HasActiveVideo);
    }

    /// <summary>Whether this exact control generation and peer currently own an admitted video socket.</summary>
    internal bool HasActiveVideo(long controlGeneration, string peerIdentity, uint windowId)
    {
        lock (stateLock)
        {
            return !disposed &&
                currentOperationsByWindow.TryGetValue(new VideoSlot(controlGeneration, windowId), out long operationId) &&
                operations.TryGetValue(operationId, out ActiveVideoOperation? operation) &&
                StringComparer.Ordinal.Equals(operation.Connection.PeerIdentity, peerIdentity);
        }
    }

    internal HostVideoSessionManager(
        IHostVideoBindingResolver bindingResolver,
        IWindowCaptureBackend captureBackend,
        IVideoEncoderFactory encoderFactory,
        HostVideoSessionOptions options)
    {
        this.bindingResolver = bindingResolver ??
            throw new ArgumentNullException(nameof(bindingResolver));
        this.captureBackend = captureBackend ??
            throw new ArgumentNullException(nameof(captureBackend));
        this.encoderFactory = encoderFactory ??
            throw new ArgumentNullException(nameof(encoderFactory));
        this.options = options ?? throw new ArgumentNullException(nameof(options));
    }

    public Task RunAuthenticatedVideoSessionAsync(
        PeelPskConnection connection,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(connection);

        ActiveVideoOperation operation;
        lock (stateLock)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            long operationId = checked(++nextOperationId);
            var operationCancellation = CancellationTokenSource.CreateLinkedTokenSource(
                lifetimeCancellation.Token,
                cancellationToken);
            operation = new ActiveVideoOperation(
                operationId,
                connection,
                operationCancellation);
            operations.Add(operationId, operation);
            operation.Completion = RunAndRemoveAsync(operation);
        }

        return operation.Completion;
    }

    public int ActiveStreamCount
    {
        get
        {
            lock (stateLock)
            {
                return currentOperationsByWindow.Count;
            }
        }
    }

    public async ValueTask DisposeAsync()
    {
        ActiveVideoOperation[] activeOperations;
        lock (stateLock)
        {
            if (disposed)
            {
                return;
            }

            disposed = true;
            if (controlSessionManager is not null)
            {
                controlSessionManager.VideoStopRequested -= HandleVideoStopRequested;
                controlSessionManager.SetActiveVideoProbe(null);
            }

            activeOperations = operations.Values.ToArray();
        }

        lifetimeCancellation.Cancel();
        foreach (ActiveVideoOperation operation in activeOperations)
        {
            operation.Cancel();
        }

        try
        {
            await Task.WhenAll(activeOperations.Select(static operation => operation.Completion))
                .ConfigureAwait(false);
        }
        catch (Exception)
        {
            // Every operation fails soft at its network boundary. This catch also
            // preserves teardown if a future encoder violates that boundary.
        }

        lifetimeCancellation.Dispose();
    }

    private async Task RunAndRemoveAsync(ActiveVideoOperation operation)
    {
        await Task.Yield();

        try
        {
            await RunOperationAsync(operation).ConfigureAwait(false);
        }
        catch (Exception exception) when (IsFailSoftSessionException(exception))
        {
            // Hostile hello data, encoder contract violations, replacement, and
            // transport teardown close only this video connection.
        }
        finally
        {
            lock (stateLock)
            {
                operations.Remove(operation.OperationId);
                if (operation.Slot is VideoSlot slot &&
                    currentOperationsByWindow.TryGetValue(slot, out long currentId) &&
                    currentId == operation.OperationId)
                {
                    currentOperationsByWindow.Remove(slot);
                }
            }

            operation.Cancellation.Dispose();
        }
    }

    private async Task RunOperationAsync(ActiveVideoOperation operation)
    {
        await using PeelPskConnection connection = operation.Connection;
        VideoStreamHelloMessage hello = await ReadVideoHelloAsync(
            connection.Stream,
            operation.Cancellation.Token).ConfigureAwait(false);

        if (!ValidateHello(connection.PeerIdentity, hello) ||
            !bindingResolver.TryResolveVideoBinding(
                connection.PeerIdentity,
                hello.WindowId,
                out HostVideoBinding? binding) ||
            binding is null ||
            !ValidateCapabilities(hello.Capabilities))
        {
            return;
        }

        VideoSlot slot = new(binding.ControlGeneration, binding.WindowId);
        ActiveVideoOperation? previous = null;
        lock (stateLock)
        {
            if (disposed || !bindingResolver.IsCurrentVideoBinding(binding))
            {
                return;
            }

            operation.Slot = slot;
            if (currentOperationsByWindow.TryGetValue(slot, out long previousId))
            {
                operations.TryGetValue(previousId, out previous);
            }

            currentOperationsByWindow[slot] = operation.OperationId;
        }

        previous?.Cancel();
        if (!bindingResolver.IsCurrentVideoBinding(binding))
        {
            return;
        }

        using CancellationTokenSource sessionCancellation =
            CancellationTokenSource.CreateLinkedTokenSource(
                operation.Cancellation.Token,
                binding.ControlLifetime);
        var orchestrator = new HostStreamOrchestrator(captureBackend, encoderFactory);
        var selectedOptions = options.Negotiate(hello.Capabilities);
        using var diagnostics = Diagnostics.StreamDiagnostics.Shared.Begin("host", binding.WindowId,
            selectedOptions.EncodingSettings.Codec.ToString(), selectedOptions.EncodingSettings.FramesPerSecond, selectedOptions.EncodingSettings.TargetBitrate);
        using var writer = new HostVideoPacketWriter(
            connection,
            binding,
            selectedOptions,
            () => IsCurrent(operation, binding));

        await orchestrator.RunEncodedWindowStreamAsync(
            binding.Window,
            selectedOptions.EncodingSettings,
            writer.SendEncodedFrameAsync,
            () => IsCurrent(operation, binding),
            sessionCancellation.Token, diagnostics).ConfigureAwait(false);
    }

    private bool IsCurrent(ActiveVideoOperation operation, HostVideoBinding binding)
    {
        bool isCurrent;
        lock (stateLock)
        {
            isCurrent = !disposed &&
                operation.Slot is VideoSlot slot &&
                currentOperationsByWindow.TryGetValue(slot, out long operationId) &&
                operationId == operation.OperationId;
        }

        return isCurrent && bindingResolver.IsCurrentVideoBinding(binding);
    }

    private void HandleVideoStopRequested(HostVideoStopRequest request)
    {
        ActiveVideoOperation? operation = null;
        lock (stateLock)
        {
            if (disposed)
            {
                return;
            }

            var slot = new VideoSlot(request.ControlGeneration, request.WindowId);
            if (currentOperationsByWindow.TryGetValue(slot, out long operationId) &&
                operations.TryGetValue(operationId, out ActiveVideoOperation? candidate) &&
                StringComparer.Ordinal.Equals(
                    candidate.Connection.PeerIdentity,
                    request.PeerIdentity))
            {
                operation = candidate;
            }
        }

        operation?.Cancel();
    }

    private async ValueTask<VideoStreamHelloMessage> ReadVideoHelloAsync(
        Stream stream,
        CancellationToken cancellationToken)
    {
        var reader = new BoundedNdjsonLineReader(options.MaximumHelloLineBytes);
        var readBuffer = new byte[ReadBufferBytes];

        while (true)
        {
            int byteCount = await stream.ReadAsync(readBuffer, cancellationToken)
                .ConfigureAwait(false);
            if (byteCount == 0)
            {
                throw new InvalidDataException("The video connection ended before its hello.");
            }

            bool hasLine = reader.TryAppend(
                readBuffer.AsSpan(0, byteCount),
                out int consumed,
                out ReadOnlyMemory<byte> line);
            if (!hasLine)
            {
                continue;
            }

            if (line.IsEmpty || consumed != byteCount)
            {
                throw new InvalidDataException(
                    "The video hello must be the connection's first and only inbound line.");
            }

            MessageEnvelope envelope = PeelJson.ReadEnvelope(line.Span);
            if (!StringComparer.Ordinal.Equals(envelope.Type, PeelMessageType.VideoStreamHello))
            {
                throw new InvalidDataException("A video connection must begin with videoStreamHello.");
            }

            return PeelJson.Deserialize<VideoStreamHelloMessage>(line.Span);
        }
    }

    private static bool ValidateHello(string peerIdentity, VideoStreamHelloMessage hello) =>
        hello.WindowId != 0 &&
        PeelProtocol.IsCompatible(
            hello.ProtocolVersion,
            hello.MinimumSupportedProtocolVersion) &&
        (hello.PairingId is null ||
            StringComparer.Ordinal.Equals(hello.PairingId, peerIdentity));

    private bool ValidateCapabilities(IReadOnlyList<string>? videoCapabilities)
    {
        if (videoCapabilities is null)
        {
            return false;
        }

        var videoCapabilitySet = new HashSet<string>(
            videoCapabilities,
            StringComparer.Ordinal);
        foreach (string required in options.RequiredVideoCapabilities)
        {
            if (!videoCapabilitySet.Contains(required))
            {
                return false;
            }
        }

        return videoCapabilitySet.Contains(options.CodecCapability) ||
            (options.EnableHevc && videoCapabilitySet.Contains(PeelCapability.HevcVideo));
    }

    private static bool IsFailSoftSessionException(Exception exception) =>
        exception is IOException or
            InvalidDataException or
            JsonException or
            ObjectDisposedException or
            OperationCanceledException or
            InvalidOperationException or
            ArgumentException or
            NotSupportedException or
            TimeoutException or
            OverflowException;

    private sealed class ActiveVideoOperation(
        long operationId,
        PeelPskConnection connection,
        CancellationTokenSource cancellation)
    {
        internal long OperationId { get; } = operationId;
        internal PeelPskConnection Connection { get; } = connection;
        internal CancellationTokenSource Cancellation { get; } = cancellation;
        internal VideoSlot? Slot { get; set; }
        internal Task Completion { get; set; } = Task.CompletedTask;

        internal void Cancel()
        {
            try
            {
                Cancellation.Cancel();
            }
            catch (ObjectDisposedException)
            {
            }

            try
            {
                Connection.Stream.Dispose();
            }
            catch (Exception exception) when (IsFailSoftSessionException(exception))
            {
            }
        }
    }

    private readonly record struct VideoSlot(long ControlGeneration, uint WindowId);
}
