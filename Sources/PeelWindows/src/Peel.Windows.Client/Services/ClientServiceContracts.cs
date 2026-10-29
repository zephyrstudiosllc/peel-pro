using Peel.Windows.Client.Models;

namespace Peel.Windows.Client.Services;

public sealed class ClientCapabilityUnavailableException : InvalidOperationException
{
    public ClientCapabilityUnavailableException(string message)
        : base(message)
    {
    }
}

public sealed class ConnectionStateChangedEventArgs : EventArgs
{
    public ConnectionStateChangedEventArgs(PeelConnectionState state, string? detail = null)
    {
        State = state;
        Detail = detail;
    }

    public PeelConnectionState State { get; }

    public string? Detail { get; }
}

public sealed class StreamStateChangedEventArgs : EventArgs
{
    public StreamStateChangedEventArgs(PeelStreamState state, string? detail = null)
    {
        State = state;
        Detail = detail;
    }

    public PeelStreamState State { get; }

    public string? Detail { get; }
}

public sealed record DecodedVideoFrame(
    int PixelWidth,
    int PixelHeight,
    int Stride,
    ReadOnlyMemory<byte> Bgra32Pixels,
    long PresentationTimestamp) : IDisposable
{
    public bool HasGpuSurface { get; init; }
    internal GpuPresentationSurface? PresentationSurface { get; init; }
    internal Peel.Windows.Host.Diagnostics.StreamDiagnostics.Lease? Diagnostics { get; set; }
    public bool UsesGpuPresentation => PresentationSurface is not null;
    // FrameDecoded borrows this frame for the callback. Async consumers must retain it.
    public DecodedVideoFrame Retain() => PresentationSurface is null ? this : this with { PresentationSurface = PresentationSurface.Retain() };
    public void Dispose() => PresentationSurface?.Dispose();
}

public sealed class DecodedVideoFrameEventArgs : EventArgs
{
    public DecodedVideoFrameEventArgs(DecodedVideoFrame frame)
    {
        Frame = frame;
    }

    public DecodedVideoFrame Frame { get; }
}

public interface IHostDiscoveryService
{
    event EventHandler? HostsChanged;

    IReadOnlyList<HostCandidate> DiscoveredHosts { get; }

    IReadOnlyList<HostCandidate> SavedHosts { get; }

    Task StartAsync(CancellationToken cancellationToken);

    Task RefreshAsync(CancellationToken cancellationToken);

    Task StopAsync(CancellationToken cancellationToken);
}

public interface ISecureConnectionService
{
    event EventHandler<ConnectionStateChangedEventArgs>? StateChanged;

    PeelConnectionState State { get; }

    HostCandidate? ConnectedHost { get; }

    Task ConnectAsync(HostCandidate host, CancellationToken cancellationToken);

    Task DisconnectAsync(CancellationToken cancellationToken);
}

public interface IWindowListService
{
    event EventHandler? WindowsChanged;

    IReadOnlyList<RemoteWindowDescriptor> Windows { get; }

    Task StartAsync(CancellationToken cancellationToken);

    Task StopAsync(CancellationToken cancellationToken);
}

public interface IStreamControlService
{
    event EventHandler<StreamStateChangedEventArgs>? StateChanged;

    event EventHandler<DecodedVideoFrameEventArgs>? FrameAvailable;

    PeelStreamState State { get; }

    uint? StreamingWindowId { get; }

    Task StartAsync(RemoteWindowDescriptor window, CancellationToken cancellationToken);

    Task StopAsync(CancellationToken cancellationToken);
}

public interface INormalizedInputService
{
    Task SendPointerAsync(NormalizedPointerInput input, CancellationToken cancellationToken);

    Task SendKeyAsync(NormalizedKeyInput input, CancellationToken cancellationToken);
}
