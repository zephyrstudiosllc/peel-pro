using System.Runtime.InteropServices;
namespace Peel.Linux.Host;
internal interface ILinuxHostNative : IAsyncDisposable
{
    bool Available { get; }
    Task InitializeAsync(Action<LinuxHostCapture?> changed);
    Task<ulong> StartAsync(LinuxHostAuthority authority, LinuxHostReservation reservation, LinuxHostVideoQueue queue, CancellationToken token);
    Task StopAsync(ulong source, ulong encoder);
}
internal static class LinuxHostGtk
{
    private const string Glib = "libglib-2.0.so.0";
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int Source(IntPtr data);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void Destroy(IntPtr data);
    [DllImport(Glib, CallingConvention = CallingConvention.Cdecl)] private static extern IntPtr g_main_context_default();
    [DllImport(Glib, CallingConvention = CallingConvention.Cdecl)] private static extern int g_main_context_is_owner(IntPtr context);
    [DllImport(Glib, CallingConvention = CallingConvention.Cdecl)] private static extern void g_main_context_invoke_full(IntPtr context, int priority, Source action, IntPtr data, Destroy destroy);
    private static readonly Source Run = p => { ((Action)GCHandle.FromIntPtr(p).Target!)(); return 0; };
    private static readonly Destroy Free = p => GCHandle.FromIntPtr(p).Free();
    internal static Task<T> InvokeAsync<T>(Func<T> action)
    {
        IntPtr main = g_main_context_default();
        if (g_main_context_is_owner(main) != 0) { try { return Task.FromResult(action()); } catch (Exception e) { return Task.FromException<T>(e); } }
        var done = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        Action run = () => { try { done.TrySetResult(action()); } catch (Exception e) { done.TrySetException(e); } };
        var handle = GCHandle.Alloc(run);
        g_main_context_invoke_full(main, 0, Run, GCHandle.ToIntPtr(handle), Free); return done.Task;
    }
}
internal sealed class LinuxHostNativeBridge : ILinuxHostNative
{
    private const string Library = "peel_linux";
    [StructLayout(LayoutKind.Sequential)] private struct Capture { public ulong Generation; public uint Source, Width, Height, Kind; public int Active; }
    [StructLayout(LayoutKind.Sequential)] private struct Encoded
    {
        public ulong SourceGeneration, EncoderGeneration, ConfigurationGeneration;
        public uint Source, Width, Height, Timescale;
        public long Pts, Duration;
        public int Keyframe, ConfigurationChanged;
        public IntPtr Avcc; public nuint AvccLength;
        public IntPtr Sps; public nuint SpsLength;
        public IntPtr Pps; public nuint PpsLength;
    }
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void Changed(IntPtr capture, IntPtr user);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int Sink(IntPtr frame, IntPtr user);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void Failed(ulong source, ulong encoder, IntPtr user);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] private static extern int peel_linux_host_observe(Changed? changed, IntPtr user);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] private static extern int peel_linux_host_get_capture(out Capture capture);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] private static extern int peel_linux_h264_encoder_available();
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] private static extern ulong peel_linux_host_encoder_start(ulong source, uint bitrate, uint gop, Sink sink, Failed failed, IntPtr user);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] private static extern int peel_linux_host_encoder_stop(ulong source, ulong encoder);
    private Changed? observer;
    private Action<LinuxHostCapture?>? changed;
    private readonly Dictionary<ulong, (Sink sink, Failed failed, ulong source)> encoders = [];
    private bool disposed, initialized;
    public bool Available { get; private set; }
    public Task InitializeAsync(Action<LinuxHostCapture?> onChanged) => LinuxHostGtk.InvokeAsync(() =>
    {
        ObjectDisposedException.ThrowIf(disposed, this); if (IntPtr.Size != 8) throw new PlatformNotSupportedException("The native host ABI requires 64-bit."); if (initialized) throw new InvalidOperationException();
        changed = onChanged;
        observer = (pointer, _) => { try { Publish(Marshal.PtrToStructure<Capture>(pointer)); } catch { changed?.Invoke(null); } };
        if (peel_linux_host_observe(observer, IntPtr.Zero) != 1) throw new IOException("Native portal observer unavailable.");
        initialized = true; Available = peel_linux_h264_encoder_available() == 1;
        if (peel_linux_host_get_capture(out var snapshot) == 1) Publish(snapshot); else changed?.Invoke(null);
        return true;
    });
    private void Publish(Capture capture)
    {
        changed?.Invoke(capture.Active == 1 ? new(capture.Generation, capture.Source, capture.Width, capture.Height, capture.Kind) : null);
    }
    public Task<ulong> StartAsync(LinuxHostAuthority authority, LinuxHostReservation reservation, LinuxHostVideoQueue queue, CancellationToken token) => LinuxHostGtk.InvokeAsync(() =>
    {
        ObjectDisposedException.ThrowIf(disposed, this); token.ThrowIfCancellationRequested();
        if (!initialized || !Available || !authority.IsCurrent(reservation)) throw new IOException("Current native capture/encoder required.");
        Sink sink = (pointer, _) =>
        {
            try
            {
                var f = Marshal.PtrToStructure<Encoded>(pointer);
                if (f.Avcc == IntPtr.Zero || f.Sps == IntPtr.Zero || f.Pps == IntPtr.Zero || f.AvccLength is 0 or > LinuxHostVideoQueue.MaxBytes
                    || f.SpsLength is 0 or > 524288 || f.PpsLength is 0 or > 524288 || f.Keyframe is not (0 or 1)
                    || !queue.CanCopy(checked((int)(f.AvccLength + f.SpsLength + f.PpsLength)))) { queue.Recover(); return 0; }
                byte[] avcc = Copy(f.Avcc, f.AvccLength), sps = Copy(f.Sps, f.SpsLength), pps = Copy(f.Pps, f.PpsLength);
                bool accepted = queue.TryEnqueue(new(f.SourceGeneration, f.EncoderGeneration, f.ConfigurationGeneration, f.Source, f.Width, f.Height,
                    f.Timescale, f.Pts, f.Duration, f.Keyframe == 1, avcc, sps, pps));
                if (!accepted) queue.Recover(); return accepted ? 1 : 0;
            }
            catch { queue.Recover(); return 0; }
        };
        Failed failed = (source, encoder, _) => { if (source == reservation.Capture.Generation && encoder == reservation.Encoder) authority.EndVideo(reservation); };
        ulong generation = peel_linux_host_encoder_start(reservation.Capture.Generation, 12_000_000, 60, sink, failed, IntPtr.Zero);
        if (generation == 0) throw new IOException("Actual native encoder could not start.");
        // Bind synchronously on GTK before it can deliver the first callback.
        try { token.ThrowIfCancellationRequested(); authority.BindEncoder(reservation, generation, queue.Close); encoders.Add(generation, (sink, failed, reservation.Capture.Generation)); }
        catch { peel_linux_host_encoder_stop(reservation.Capture.Generation, generation); throw; }
        return generation;
    });
    private static byte[] Copy(IntPtr pointer, nuint length) { byte[] bytes = new byte[checked((int)length)]; Marshal.Copy(pointer, bytes, 0, bytes.Length); return bytes; }
    public Task StopAsync(ulong source, ulong encoder) => LinuxHostGtk.InvokeAsync(() =>
    {
        if (encoders.TryGetValue(encoder, out var e) && e.source == source)
        {
            peel_linux_host_encoder_stop(source, encoder); encoders.Remove(encoder);
            // Callbacks remain rooted through the exact stop call.
            GC.KeepAlive(e);
        }
        return true;
    });
    public async ValueTask DisposeAsync()
    {
        await LinuxHostGtk.InvokeAsync(() =>
        {
            if (disposed) return true; disposed = true; Available = false;
            foreach (var e in encoders.ToArray()) { peel_linux_host_encoder_stop(e.Value.source, e.Key); GC.KeepAlive(e.Value); }
            encoders.Clear(); if (initialized) peel_linux_host_observe(null, IntPtr.Zero);
            GC.KeepAlive(observer); observer = null; changed = null; return true;
        }).ConfigureAwait(false);
    }
}
