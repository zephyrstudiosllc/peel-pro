using System.Runtime.InteropServices;

namespace Peel.Windows.Host.Capture;

/// <summary>One immutable NV12 texture reference. Each queue/codec owner retains its own reference.</summary>
internal sealed class GpuCapturedSurface : IDisposable
{
    private readonly object gate = new();
    private nint texture;
    internal nint Device { get; }
    internal nint Texture { get { lock (gate) { ObjectDisposedException.ThrowIf(texture == 0, this); return texture; } } }
    internal GpuCapturedSurface(nint texture, nint device) { this.texture = texture; Device = device; }
    internal GpuCapturedSurface Retain()
    {
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(texture == 0, this); Marshal.AddRef(texture);
            return new(texture, Device);
        }
    }
    public void Dispose()
    {
        lock (gate) { if (texture != 0) { Marshal.Release(texture); texture = 0; } }
    }
}
