using System.Runtime.InteropServices;

namespace Peel.Windows.Client.Services;

/// <summary>An immutable, completed GPU image. Every asynchronous consumer owns a separate lease.</summary>
internal sealed class GpuPresentationSurface : IDisposable
{
    private readonly object gate = new();
    private Shared? shared;
    private bool presentationAttached;
    internal GpuPresentationSurface(nint ownedSurface, Action<bool>? release = null) => shared = new(ownedSurface, release ?? (_ => Marshal.Release(ownedSurface)));
    private GpuPresentationSurface(Shared retained) => shared = retained;
    internal nint Surface { get { lock (gate) { ObjectDisposedException.ThrowIf(shared is null, this); return shared.Surface; } } }
    internal void PreventReuse() { lock (gate) { ObjectDisposedException.ThrowIf(shared is null, this); presentationAttached = true; } }
    internal void AllowReuse() { lock (gate) { ObjectDisposedException.ThrowIf(shared is null, this); presentationAttached = false; } }
    internal GpuPresentationSurface Retain()
    {
        lock (gate) { ObjectDisposedException.ThrowIf(shared is null, this); Interlocked.Increment(ref shared.References); return new(shared); }
    }
    public void Dispose()
    {
        Shared? releasing;
        lock (gate)
        {
            releasing = shared; shared = null;
            // A surface still attached to any compositor must never re-enter the writable pool.
            if (presentationAttached && releasing is not null) Volatile.Write(ref releasing.Reusable, false);
        }
        if (releasing is not null && Interlocked.Decrement(ref releasing.References) == 0) releasing.Release(Volatile.Read(ref releasing.Reusable));
    }
    private sealed class Shared(nint surface, Action<bool> release)
    {
        internal readonly nint Surface = surface;
        internal readonly Action<bool> Release = release;
        internal int References = 1;
        internal bool Reusable = true;
    }
}
