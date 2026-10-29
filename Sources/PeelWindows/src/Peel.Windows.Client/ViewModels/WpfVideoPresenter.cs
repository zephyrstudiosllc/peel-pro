using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Peel.Windows.Client.Services;

namespace Peel.Windows.Client.ViewModels;

/// <summary>UI-owned surface switching; never waits for GPU decode or conversion.</summary>
internal sealed class WpfVideoPresenter : IDisposable
{
    private D3DImage? gpu;
    private GpuPresentationSurface? displayed;
    private WriteableBitmap? bitmap;
    internal ImageSource? Source { get; private set; }
    internal int PixelWidth { get; private set; }
    internal int PixelHeight { get; private set; }
    internal bool Present(DecodedVideoFrame frame)
    {
        if (frame.PresentationSurface is { } surface)
        {
            gpu ??= new D3DImage();
            if (!gpu.TryLock(new Duration(TimeSpan.Zero))) { frame.Diagnostics?.Record(Peel.Windows.Host.Diagnostics.StreamStage.PresentationSkipped); return false; }
            GpuPresentationSurface? owned = null;
            try
            {
                owned = surface.Retain();
                owned.PreventReuse();
                // Immutable GPU work is already complete. WPF owns its front-buffer copy.
                gpu.SetBackBuffer(D3DResourceType.IDirect3DSurface9, owned.Surface, enableSoftwareFallback: true);
                gpu.AddDirtyRect(new Int32Rect(0, 0, frame.PixelWidth, frame.PixelHeight));
                var old = displayed;
                // TryLock fenced WPF's previous copy and SetBackBuffer detached that surface.
                old?.AllowReuse();
                displayed = owned; owned = null; old?.Dispose();
                bitmap = null; Source = gpu;
            }
            finally { owned?.Dispose(); gpu.Unlock(); }
        }
        else
        {
            ClearGpu();
            bitmap = WpfDecodedFrameWriter.Write(bitmap, frame); Source = bitmap;
        }
        PixelWidth = frame.PixelWidth; PixelHeight = frame.PixelHeight;
        frame.Diagnostics?.Record(Peel.Windows.Host.Diagnostics.StreamStage.Presented); return true;
    }
    private void ClearGpu()
    {
        try
        {
            if (gpu is not null && gpu.TryLock(new Duration(TimeSpan.Zero)))
            {
                try { gpu.SetBackBuffer(D3DResourceType.IDirect3DSurface9, 0); displayed?.AllowReuse(); }
                finally { gpu.Unlock(); }
            }
        }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or InvalidOperationException) { }
        finally
        {
            // If detachment fails, WPF retains its COM reference and the lease prohibits recycling.
            gpu = null; displayed?.Dispose(); displayed = null;
        }
    }
    public void Dispose() { ClearGpu(); Source = null; bitmap = null; PixelWidth = PixelHeight = 0; }
}
