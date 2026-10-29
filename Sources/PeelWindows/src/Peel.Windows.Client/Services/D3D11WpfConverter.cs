using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;

namespace Peel.Windows.Client.Services;

/// <summary>Decoder-worker-only NV12 conversion to an immutable D3D9Ex surface shared with WPF.
/// GPU completion is checked here, never on the UI thread. No CPU pixel readback occurs.</summary>
internal sealed unsafe class D3D11WpfConverter : IDisposable
{
    private readonly nint device, context;
    private readonly int width, height;
    private readonly object poolGate = new();
    private readonly Stack<SharedTarget> idle = new();
    private bool closed;
    internal (double AllocationMs, double SubmissionMs, double CompletionMs) LastTimings { get; private set; }
    internal bool UsedDirectInput { get; private set; }
    private nint d3d9, device9, videoDevice, videoContext, enumerator, processor, input, inputView, completion;
    internal D3D11WpfConverter(nint device, nint context, int width, int height)
    {
        this.device = device; this.context = context; this.width = width; this.height = height;
        if (width <= 0 || height <= 0 || (width & 1) != 0 || (height & 1) != 0 || (long)width * height > 16_777_216)
            throw new ArgumentOutOfRangeException(nameof(width));
        try
        {
            CreateInteropDevice();
            Guid vd = new("10ec4d5b-975a-4689-b9e4-d0aac30fe333"), vc = new("61f21c45-3c0e-4a74-9cea-67100d9ad5e4");
            Check(Marshal.QueryInterface(device, in vd, out videoDevice)); Check(Marshal.QueryInterface(context, in vc, out videoContext));
            var content = new ContentDescription { InputWidth = (uint)width, InputHeight = (uint)height, OutputWidth = (uint)width, OutputHeight = (uint)height,
                InputRateNumerator = 120, InputRateDenominator = 1, OutputRateNumerator = 120, OutputRateDenominator = 1, Usage = 1 }; // OPTIMAL_SPEED.
            nint local = 0;
            Check(((delegate* unmanaged[Stdcall]<nint, ContentDescription*, nint*, int>)Slot(videoDevice, 10))(videoDevice, &content, &local)); enumerator = local;
            uint inputFlags = 0, outputFlags = 0;
            var format = (delegate* unmanaged[Stdcall]<nint, int, uint*, int>)Slot(enumerator, 8);
            Check(format(enumerator, 103, &inputFlags)); Check(format(enumerator, 87, &outputFlags));
            if ((inputFlags & 1) == 0 || (outputFlags & 2) == 0) throw new PlatformNotSupportedException("GPU NV12 presentation is unavailable.");
            Check(((delegate* unmanaged[Stdcall]<nint, nint, uint, nint*, int>)Slot(videoDevice, 4))(videoDevice, enumerator, 0, &local)); processor = local;
            var desc = new TextureDescription { Width = (uint)width, Height = (uint)height, MipLevels = 1, ArraySize = 1, Format = 103, SampleCount = 1, BindFlags = 0x20 };
            Check(((delegate* unmanaged[Stdcall]<nint, TextureDescription*, nint, nint*, int>)Slot(device, 5))(device, &desc, 0, &local)); input = local;
            var iv = new InputViewDescription { Dimension = 1 };
            Check(((delegate* unmanaged[Stdcall]<nint, nint, nint, InputViewDescription*, nint*, int>)Slot(videoDevice, 8))(videoDevice, input, enumerator, &iv, &local)); inputView = local;
            uint outputColor = 1 | (2u << 4); // Full RGB output.
            ((delegate* unmanaged[Stdcall]<nint, nint, uint*, void>)Slot(videoContext, 15))(videoContext, processor, &outputColor);
            ((delegate* unmanaged[Stdcall]<nint, nint, uint, int, void>)Slot(videoContext, 37))(videoContext, processor, 0, 0);
            ((delegate* unmanaged[Stdcall]<nint, nint, uint, int, void>)Slot(videoContext, 27))(videoContext, processor, 0, 0);
            var rectangle = new Rectangle { Right = width, Bottom = height };
            ((delegate* unmanaged[Stdcall]<nint, nint, uint, int, Rectangle*, void>)Slot(videoContext, 30))(videoContext, processor, 0, 1, &rectangle);
            ((delegate* unmanaged[Stdcall]<nint, nint, uint, int, Rectangle*, void>)Slot(videoContext, 31))(videoContext, processor, 0, 1, &rectangle);
            QueryDescription query = default; // D3D11_QUERY_EVENT.
            Check(((delegate* unmanaged[Stdcall]<nint, QueryDescription*, nint*, int>)Slot(device, 24))(device, &query, &local)); completion = local;
        }
        catch { Dispose(); throw; }
    }

    internal GpuPresentationSurface Convert(nint texture, uint subresource, bool bt709 = false, bool fullRange = false)
    {
        ObjectDisposedException.ThrowIf(processor == 0, this);
        TextureDescription source = default;
        ((delegate* unmanaged[Stdcall]<nint, TextureDescription*, void>)Slot(texture, 10))(texture, &source);
        if (source.Format != 103 || source.Width < width || source.Height < height || source.MipLevels != 1 || subresource >= source.ArraySize || source.SampleCount != 1)
            throw new InvalidDataException("Decoder returned an incompatible NV12 graphics surface.");
        long allocationStart = Stopwatch.GetTimestamp();
        SharedTarget? target = RentTarget();
        nint directView = 0;
        try
        {
            long submissionStart = Stopwatch.GetTimestamp();
            var sourceView = new InputViewDescription { Dimension = 1, ArraySlice = subresource };
            UsedDirectInput = ((delegate* unmanaged[Stdcall]<nint, nint, nint, InputViewDescription*, nint*, int>)Slot(videoDevice, 8))
                (videoDevice, texture, enumerator, &sourceView, &directView) >= 0;
            if (!UsedDirectInput)
            {
                Release(ref directView);
                var box = new Box { Right = (uint)width, Bottom = (uint)height, Back = 1 };
                ((delegate* unmanaged[Stdcall]<nint, nint, uint, uint, uint, uint, nint, uint, Box*, void>)Slot(context, 46))
                    (context, input, 0, 0, 0, 0, texture, subresource, &box);
            }
            uint color = 1 | (bt709 ? 4u : 0) | ((fullRange ? 2u : 1u) << 4);
            ((delegate* unmanaged[Stdcall]<nint, nint, uint, uint*, void>)Slot(videoContext, 28))(videoContext, processor, 0, &color);
            var stream = new ProcessorStream { Enabled = 1, InputSurface = UsedDirectInput ? directView : inputView };
            Check(((delegate* unmanaged[Stdcall]<nint, nint, nint, uint, uint, ProcessorStream*, int>)Slot(videoContext, 53))(videoContext, processor, target.View, 0, 1, &stream));
            ((delegate* unmanaged[Stdcall]<nint, nint, void>)Slot(context, 28))(context, completion);
            ((delegate* unmanaged[Stdcall]<nint, void>)Slot(context, 111))(context);
            long started = Stopwatch.GetTimestamp();
            while (true)
            {
                int ready = 0;
                int result = ((delegate* unmanaged[Stdcall]<nint, nint, int*, uint, uint, int>)Slot(context, 29))(context, completion, &ready, 4, 1);
                Check(result);
                if (result == 0 && ready != 0) break;
                if (Stopwatch.GetElapsedTime(started) > TimeSpan.FromSeconds(5)) throw new TimeoutException("GPU presentation conversion did not complete.");
                Thread.Yield();
            }
            LastTimings = (Stopwatch.GetElapsedTime(allocationStart, submissionStart).TotalMilliseconds,
                Stopwatch.GetElapsedTime(submissionStart, started).TotalMilliseconds, Stopwatch.GetElapsedTime(started).TotalMilliseconds);
            SharedTarget returning = target;
            var owned = new GpuPresentationSurface(target.Surface, reusable => ReturnTarget(returning, reusable));
            target = null; return owned;
        }
        finally { Release(ref directView); target?.Dispose(); }
    }

    private SharedTarget RentTarget()
    {
        lock (poolGate) { ObjectDisposedException.ThrowIf(closed, this); if (idle.TryPop(out var reused)) return reused; }
        nint texture9 = 0, surface = 0, texture11 = 0, view = 0;
        try
        {
            nint handle = 0;
            Check(((delegate* unmanaged[Stdcall]<nint, uint, uint, uint, uint, int, int, nint*, nint*, int>)Slot(device9, 23))
                (device9, (uint)width, (uint)height, 1, 1, 21, 0, &texture9, &handle));
            Check(((delegate* unmanaged[Stdcall]<nint, uint, nint*, int>)Slot(texture9, 18))(texture9, 0, &surface));
            Guid iid = new("6f15aaf2-d208-4e89-9ab4-489535d34f9c");
            Check(((delegate* unmanaged[Stdcall]<nint, nint, Guid*, nint*, int>)Slot(device, 28))(device, handle, &iid, &texture11));
            var ov = new OutputViewDescription { Dimension = 1 };
            Check(((delegate* unmanaged[Stdcall]<nint, nint, nint, OutputViewDescription*, nint*, int>)Slot(videoDevice, 9))(videoDevice, texture11, enumerator, &ov, &view));
            return new SharedTarget(surface, texture9, texture11, view);
        }
        catch { Release(ref view); Release(ref texture11); Release(ref surface); Release(ref texture9); throw; }
    }
    private void ReturnTarget(SharedTarget target, bool reusable)
    {
        // Two idle allocation slots, not queued frames. In-flight ownership remains bounded by the decoder/mailbox.
        lock (poolGate)
        {
            if (!closed && reusable && idle.Count < 2) { idle.Push(target); return; }
        }
        target.Dispose();
    }
    private sealed class SharedTarget(nint surface, nint texture9, nint texture11, nint view) : IDisposable
    {
        internal nint Surface = surface, Texture9 = texture9, Texture11 = texture11, View = view;
        public void Dispose() { Release(ref View); Release(ref Texture11); Release(ref Surface); Release(ref Texture9); }
    }

    private void CreateInteropDevice()
    {
        nint dxgi = 0, adapter = 0;
        try
        {
            Guid iid = new("54ec77fa-1377-44e6-8c32-88fd5f44c84c");
            Check(Marshal.QueryInterface(device, in iid, out dxgi));
            Check(((delegate* unmanaged[Stdcall]<nint, nint*, int>)Slot(dxgi, 7))(dxgi, &adapter));
            byte* desc = stackalloc byte[512];
            Check(((delegate* unmanaged[Stdcall]<nint, byte*, int>)Slot(adapter, 8))(adapter, desc));
            long luid = *(long*)(desc + 272 + 3 * IntPtr.Size);
            Check(Direct3DCreate9Ex(32, out d3d9));
            uint count = ((delegate* unmanaged[Stdcall]<nint, uint>)Slot(d3d9, 4))(d3d9);
            uint selected = uint.MaxValue;
            for (uint i = 0; i < Math.Min(count, 32); i++)
            {
                long candidate = 0;
                if (((delegate* unmanaged[Stdcall]<nint, uint, long*, int>)Slot(d3d9, 21))(d3d9, i, &candidate) >= 0 && candidate == luid) { selected = i; break; }
            }
            if (selected == uint.MaxValue) throw new PlatformNotSupportedException("WPF and the decoder have no matching graphics adapter.");
            var pp = new PresentationParameters { Width = 1, Height = 1, Format = 0, Count = 1, SwapEffect = 1, Window = GetDesktopWindow(), Windowed = 1, Interval = 0x80000000 };
            nint created = 0;
            Check(((delegate* unmanaged[Stdcall]<nint, uint, int, nint, uint, PresentationParameters*, nint, nint*, int>)Slot(d3d9, 20))
                (d3d9, selected, 1, pp.Window, 2 | 4 | 0x20 | 0x800, &pp, 0, &created));
            device9 = created;
        }
        finally { Release(ref adapter); Release(ref dxgi); }
    }
    public void Dispose()
    {
        lock (poolGate)
        {
            closed = true;
            while (idle.TryPop(out var target)) target.Dispose();
        }
        Release(ref completion); Release(ref inputView); Release(ref input); Release(ref processor); Release(ref enumerator);
        Release(ref videoContext); Release(ref videoDevice); Release(ref device9); Release(ref d3d9);
    }
    private static nint Slot(nint value, int index) => (*(nint**)value)[index];
    private static void Check(int result) => Marshal.ThrowExceptionForHR(result);
    private static void Release(ref nint value) { if (value != 0) { Marshal.Release(value); value = 0; } }
    [DllImport("d3d9.dll")] private static extern int Direct3DCreate9Ex(uint version, out nint direct3d);
    [DllImport("user32.dll")] private static extern nint GetDesktopWindow();
    [StructLayout(LayoutKind.Sequential)] private struct PresentationParameters { public uint Width, Height, Format, Count, Samples, Quality, SwapEffect; public nint Window; public int Windowed, Depth; public uint DepthFormat, Flags, Refresh, Interval; }
    [StructLayout(LayoutKind.Sequential)] private struct ContentDescription { public int FrameFormat; public uint InputRateNumerator, InputRateDenominator, InputWidth, InputHeight, OutputRateNumerator, OutputRateDenominator, OutputWidth, OutputHeight; public int Usage; }
    [StructLayout(LayoutKind.Sequential)] private struct TextureDescription { public uint Width, Height, MipLevels, ArraySize; public int Format; public uint SampleCount, SampleQuality, Usage, BindFlags, CpuAccess, MiscFlags; }
    [StructLayout(LayoutKind.Sequential)] private struct InputViewDescription { public uint FourCC, Dimension, MipSlice, ArraySlice; }
    [StructLayout(LayoutKind.Sequential)] private struct OutputViewDescription { public uint Dimension, MipSlice, FirstArraySlice, ArraySize; }
    [StructLayout(LayoutKind.Sequential)] private struct QueryDescription { public uint Query, Flags; }
    [StructLayout(LayoutKind.Sequential)] private struct ProcessorStream { public int Enabled; public uint OutputIndex, InputFrame, PastFrames, FutureFrames; public nint PastSurfaces, InputSurface, FutureSurfaces, PastRight, InputRight, FutureRight; }
    [StructLayout(LayoutKind.Sequential)] private struct Box { public uint Left, Top, Front, Right, Bottom, Back; }
    [StructLayout(LayoutKind.Sequential)] private struct Rectangle { public int Left, Top, Right, Bottom; }
}
