using Peel.Windows.Host.Windows;

namespace Peel.Windows.Host.Capture;

public interface IWindowCaptureBackend
{
    ValueTask<IWindowCaptureSession> OpenAsync(
        WindowDescriptor window,
        CancellationToken cancellationToken);
}

public interface IWindowCaptureSession : IAsyncDisposable
{
    WindowDescriptor Window { get; }

    int InitialWidth { get; }

    int InitialHeight { get; }

    Task RunAsync(CapturedFrameHandler frameHandler, CancellationToken cancellationToken);
}

internal interface IGpuWindowCaptureSession
{
    nint GpuDevice { get; }
    void SetGpuFramesEnabled(bool enabled);
}

public delegate ValueTask CapturedFrameHandler(
    CapturedFrame frame,
    CancellationToken cancellationToken);

public sealed record CapturedFrame(
    int Width,
    int Height,
    int BytesPerRow,
    long Timestamp100Nanoseconds,
    CapturePixelFormat PixelFormat,
    ReadOnlyMemory<byte> Pixels) : IDisposable
{
    internal GpuCapturedSurface? GpuSurface { get; init; }
    public void Dispose() => GpuSurface?.Dispose();
}

public enum CapturePixelFormat
{
    Bgra8,
    Nv12,
}
