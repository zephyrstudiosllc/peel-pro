using System.Runtime.InteropServices;

namespace Peel.Windows.Host.Capture;

/// <summary>Serial, capture-generation-owned GPU conversion with owned surfaces or compact NV12 readback.</summary>
internal sealed unsafe class D3D11Nv12Converter : IDisposable
{
    private readonly nint device, context;
    private nint videoDevice, videoContext, enumerator, processor, input, inputView, output, outputView, staging;
    internal int Width { get; }
    internal int Height { get; }
    internal D3D11Nv12Converter(nint device, nint context, int width, int height)
    {
        CaptureFrameLayout.ValidateCaptureSize(width, height);
        if ((width & 1) != 0 || (height & 1) != 0) throw new ArgumentException("NV12 dimensions must be even.");
        this.device = device; this.context = context; Width = width; Height = height;
        try
        {
            Guid vd = new("10ec4d5b-975a-4689-b9e4-d0aac30fe333"), vc = new("61f21c45-3c0e-4a74-9cea-67100d9ad5e4");
            Check(Marshal.QueryInterface(device, in vd, out videoDevice));
            Check(Marshal.QueryInterface(context, in vc, out videoContext));
            var content = new ContentDescription { InputWidth = (uint)width, InputHeight = (uint)height, OutputWidth = (uint)width, OutputHeight = (uint)height,
                InputRateNumerator = 120, InputRateDenominator = 1, OutputRateNumerator = 120, OutputRateDenominator = 1 };
            nint local = 0;
            Check(((delegate* unmanaged[Stdcall]<nint, ContentDescription*, nint*, int>)Slot(videoDevice, 10))(videoDevice, &content, &local)); enumerator = local;
            uint inputFlags = 0, outputFlags = 0;
            var format = (delegate* unmanaged[Stdcall]<nint, int, uint*, int>)Slot(enumerator, 8);
            Check(format(enumerator, 87, &inputFlags)); Check(format(enumerator, 103, &outputFlags));
            if ((inputFlags & 1) == 0 || (outputFlags & 2) == 0) throw new PlatformNotSupportedException("GPU BGRA to NV12 conversion is unavailable.");
            Check(((delegate* unmanaged[Stdcall]<nint, nint, uint, nint*, int>)Slot(videoDevice, 4))(videoDevice, enumerator, 0, &local)); processor = local;
            input = CreateTexture(87, 0, 0x28, 0); // SHADER_RESOURCE | RENDER_TARGET.
            output = CreateTexture(103, 0, 0x20, 0);
            staging = CreateTexture(103, 3, 0, 0x20000);
            var iv = new InputViewDescription { Dimension = 1 };
            Check(((delegate* unmanaged[Stdcall]<nint, nint, nint, InputViewDescription*, nint*, int>)Slot(videoDevice, 8))(videoDevice, input, enumerator, &iv, &local)); inputView = local;
            var ov = new OutputViewDescription { Dimension = 1 };
            Check(((delegate* unmanaged[Stdcall]<nint, nint, nint, OutputViewDescription*, nint*, int>)Slot(videoDevice, 9))(videoDevice, output, enumerator, &ov, &local)); outputView = local;
            uint inputColor = 1 | (2u << 4), outputColor = 1 | (1u << 4); // Full RGB → limited BT.601; no automatic enhancement.
            ((delegate* unmanaged[Stdcall]<nint, nint, uint, uint*, void>)Slot(videoContext, 28))(videoContext, processor, 0, &inputColor);
            ((delegate* unmanaged[Stdcall]<nint, nint, uint*, void>)Slot(videoContext, 15))(videoContext, processor, &outputColor);
            ((delegate* unmanaged[Stdcall]<nint, nint, uint, int, void>)Slot(videoContext, 37))(videoContext, processor, 0, 0);
            ((delegate* unmanaged[Stdcall]<nint, nint, uint, int, void>)Slot(videoContext, 27))(videoContext, processor, 0, 0);
            var rectangle = new Rectangle { Right = width, Bottom = height };
            var sourceRect = (delegate* unmanaged[Stdcall]<nint, nint, uint, int, Rectangle*, void>)Slot(videoContext, 30);
            var destRect = (delegate* unmanaged[Stdcall]<nint, nint, uint, int, Rectangle*, void>)Slot(videoContext, 31);
            sourceRect(videoContext, processor, 0, 1, &rectangle); destRect(videoContext, processor, 0, 1, &rectangle);
        }
        catch { Dispose(); throw; }
    }
    internal byte[] ConvertTexture(nint source)
    {
        ObjectDisposedException.ThrowIf(processor == 0, this);
        var box = new Box { Right = (uint)Width, Bottom = (uint)Height, Back = 1 };
        ((delegate* unmanaged[Stdcall]<nint, nint, uint, uint, uint, uint, nint, uint, Box*, void>)Slot(context, 46))
            (context, input, 0, 0, 0, 0, source, 0, &box);
        return ProcessAndRead();
    }
    internal byte[] ConvertBgra(ReadOnlySpan<byte> pixels, int stride)
    {
        ObjectDisposedException.ThrowIf(processor == 0, this);
        if (stride < checked(Width * 4) || pixels.Length < checked(stride * (Height - 1) + Width * 4)) throw new ArgumentException("Truncated BGRA surface.");
        fixed (byte* data = pixels)
            ((delegate* unmanaged[Stdcall]<nint, nint, uint, nint, byte*, uint, uint, void>)Slot(context, 48))(context, input, 0, 0, data, (uint)stride, 0);
        return ProcessAndRead();
    }
    internal GpuCapturedSurface ConvertBgraToSurface(ReadOnlySpan<byte> pixels, int stride)
    {
        ObjectDisposedException.ThrowIf(processor == 0, this);
        if (stride < checked(Width * 4) || pixels.Length < checked(stride * (Height - 1) + Width * 4)) throw new ArgumentException("Truncated BGRA surface.");
        fixed (byte* data = pixels)
            ((delegate* unmanaged[Stdcall]<nint, nint, uint, nint, byte*, uint, uint, void>)Slot(context, 48))(context, input, 0, 0, data, (uint)stride, 0);
        return ProcessToSurface();
    }
    internal GpuCapturedSurface ConvertTextureToSurface(nint source)
    {
        ObjectDisposedException.ThrowIf(processor == 0, this);
        var box = new Box { Right = (uint)Width, Bottom = (uint)Height, Back = 1 };
        ((delegate* unmanaged[Stdcall]<nint, nint, uint, uint, uint, uint, nint, uint, Box*, void>)Slot(context, 46))
            (context, input, 0, 0, 0, 0, source, 0, &box);
        return ProcessToSurface();
    }
    private GpuCapturedSurface ProcessToSurface()
    {
        Process();
        nint immutable = CreateTexture(103, 0, 0x20, 0);
        ((delegate* unmanaged[Stdcall]<nint, nint, nint, void>)Slot(context, 47))(context, immutable, output);
        ((delegate* unmanaged[Stdcall]<nint, void>)Slot(context, 111))(context); // Submit before handing a different codec thread the texture.
        return new GpuCapturedSurface(immutable, device);
    }
    private void Process()
    {
        var stream = new ProcessorStream { Enabled = 1, InputSurface = inputView };
        Check(((delegate* unmanaged[Stdcall]<nint, nint, nint, uint, uint, ProcessorStream*, int>)Slot(videoContext, 53))
            (videoContext, processor, outputView, 0, 1, &stream));
    }
    private byte[] ProcessAndRead()
    {
        Process();
        ((delegate* unmanaged[Stdcall]<nint, nint, nint, void>)Slot(context, 47))(context, staging, output);
        Mapped mapped = default;
        Check(((delegate* unmanaged[Stdcall]<nint, nint, uint, int, uint, Mapped*, int>)Slot(context, 14))(context, staging, 0, 1, 0, &mapped));
        try
        {
            if (mapped.Data == 0 || mapped.RowPitch < Width || mapped.RowPitch > int.MaxValue) throw new InvalidDataException("Invalid NV12 mapped surface.");
            byte[] packed = GC.AllocateUninitializedArray<byte>(checked(Width * Height * 3 / 2));
            for (int y = 0; y < Height + Height / 2; y++)
                new ReadOnlySpan<byte>((byte*)mapped.Data + (nuint)y * mapped.RowPitch, Width).CopyTo(packed.AsSpan(y * Width, Width));
            return packed;
        }
        finally { ((delegate* unmanaged[Stdcall]<nint, nint, uint, void>)Slot(context, 15))(context, staging, 0); }
    }
    private nint CreateTexture(int format, uint usage, uint bind, uint cpu)
    {
        var desc = new TextureDescription { Width = (uint)Width, Height = (uint)Height, MipLevels = 1, ArraySize = 1, Format = format, SampleCount = 1,
            Usage = usage, BindFlags = bind, CpuAccess = cpu };
        nint texture = 0;
        Check(((delegate* unmanaged[Stdcall]<nint, TextureDescription*, nint, nint*, int>)Slot(device, 5))(device, &desc, 0, &texture));
        return texture;
    }
    public void Dispose()
    {
        Release(ref staging); Release(ref outputView); Release(ref output); Release(ref inputView); Release(ref input);
        Release(ref processor); Release(ref enumerator); Release(ref videoContext); Release(ref videoDevice);
    }
    private static nint Slot(nint value, int slot) => (*(nint**)value)[slot];
    private static void Release(ref nint value) { if (value != 0) { Marshal.Release(value); value = 0; } }
    private static void Check(int value) => Marshal.ThrowExceptionForHR(value);
    [StructLayout(LayoutKind.Sequential)] private struct ContentDescription { public int FrameFormat; public uint InputRateNumerator, InputRateDenominator, InputWidth, InputHeight, OutputRateNumerator, OutputRateDenominator, OutputWidth, OutputHeight; public int Usage; }
    [StructLayout(LayoutKind.Sequential)] private struct TextureDescription { public uint Width, Height, MipLevels, ArraySize; public int Format; public uint SampleCount, SampleQuality, Usage, BindFlags, CpuAccess, MiscFlags; }
    [StructLayout(LayoutKind.Sequential)] private struct InputViewDescription { public uint FourCC, Dimension, MipSlice, ArraySlice; }
    [StructLayout(LayoutKind.Sequential)] private struct OutputViewDescription { public uint Dimension, MipSlice, FirstArraySlice, ArraySize; }
    [StructLayout(LayoutKind.Sequential)] private struct ProcessorStream { public int Enabled; public uint OutputIndex, InputFrame, PastFrames, FutureFrames; public nint PastSurfaces, InputSurface, FutureSurfaces, PastRight, InputRight, FutureRight; }
    [StructLayout(LayoutKind.Sequential)] private struct Mapped { public nint Data; public uint RowPitch, DepthPitch; }
    [StructLayout(LayoutKind.Sequential)] private struct Box { public uint Left, Top, Front, Right, Bottom, Back; }
    [StructLayout(LayoutKind.Sequential)] private struct Rectangle { public int Left, Top, Right, Bottom; }
}
