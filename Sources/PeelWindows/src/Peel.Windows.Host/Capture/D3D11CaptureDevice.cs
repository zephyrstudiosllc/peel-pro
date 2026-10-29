using System.Runtime.InteropServices;
using Windows.Graphics.DirectX.Direct3D11;
using WinRT;

namespace Peel.Windows.Host.Capture;

internal sealed unsafe class D3D11CaptureDevice : IDisposable
{
    private const uint D3D11SdkVersion = 7;
    private const uint D3D11CreateDeviceBgraSupport = 0x20;
    private const int D3DDriverTypeHardware = 1;
    private const int D3DDriverTypeWarp = 5;
    private const int D3D11UsageStaging = 3;
    private const uint D3D11CpuAccessRead = 0x00020000;
    private const int D3D11MapRead = 1;
    private const int DxgiFormatB8G8R8A8Unorm = 87;

    private static readonly Guid IidDxgiDevice =
        new("54EC77FA-1377-44E6-8C32-88FD5F44C84C");
    private static readonly Guid IidDirect3DDxgiInterfaceAccess =
        new("A9B3D012-3DF2-4EE3-B8D1-8695F457D3C1");
    private static readonly Guid IidD3D11Texture2D =
        new("6F15AAF2-D208-4E89-9AB4-489535D34F9C");

    private readonly object stateLock = new();
    private nint device;
    private nint immediateContext;
    private nint stagingTexture;
    private D3D11Texture2DDescription stagingDescription;
    private D3D11Nv12Converter? nv12Converter;
    private bool conversionUnavailable;
    private bool disposed;

    private D3D11CaptureDevice(
        nint device,
        nint immediateContext,
        IDirect3DDevice windowsRuntimeDevice)
    {
        this.device = device;
        this.immediateContext = immediateContext;
        WindowsRuntimeDevice = windowsRuntimeDevice;
    }

    internal IDirect3DDevice WindowsRuntimeDevice { get; }
    internal nint Device => device;
    internal bool UseGpuFrames { get; set; }

    internal static D3D11CaptureDevice Create()
    {
        CreateRawDevice(out nint device, out nint immediateContext);

        nint dxgiDevice = 0;
        nint inspectableDevice = 0;
        try
        {
            ThrowIfFailed(QueryInterface(device, IidDxgiDevice, out dxgiDevice));
            ThrowIfFailed(CreateDirect3D11DeviceFromDXGIDevice(
                dxgiDevice,
                out inspectableDevice));

            IDirect3DDevice windowsRuntimeDevice =
                MarshalInterface<IDirect3DDevice>.FromAbi(inspectableDevice);
            return new D3D11CaptureDevice(device, immediateContext, windowsRuntimeDevice);
        }
        catch
        {
            Release(immediateContext);
            Release(device);
            throw;
        }
        finally
        {
            Release(dxgiDevice);
            if (inspectableDevice != 0)
            {
                MarshalInterface<IDirect3DDevice>.DisposeAbi(inspectableDevice);
            }
        }
    }

    internal CapturedFrame? TryCopyFrame(
        IDirect3DSurface surface,
        int contentWidth,
        int contentHeight,
        long timestamp100Nanoseconds)
    {
        ArgumentNullException.ThrowIfNull(surface);

        lock (stateLock)
        {
            ObjectDisposedException.ThrowIf(disposed, this);

            nint surfaceAbi = MarshalInterface<IDirect3DSurface>.FromManaged(surface);
            nint surfaceAccess = 0;
            nint sourceTexture = 0;
            try
            {
                ThrowIfFailed(QueryInterface(
                    surfaceAbi,
                    IidDirect3DDxgiInterfaceAccess,
                    out surfaceAccess));
                ThrowIfFailed(GetWrappedInterface(
                    surfaceAccess,
                    IidD3D11Texture2D,
                    out sourceTexture));

                D3D11Texture2DDescription sourceDescription = GetTextureDescription(sourceTexture);
                ValidateSourceTexture(sourceDescription);
                if ((uint)contentWidth > sourceDescription.Width ||
                    (uint)contentHeight > sourceDescription.Height)
                {
                    // WGC may hand out one old-pool surface after ContentSize has
                    // advanced during Recreate. It is not safe to copy that frame,
                    // but the next latest frame can recover on the same session.
                    return null;
                }

                // NV12 codecs need even sizes. Crop at most one trailing row/column rather
                // than rejecting ordinary odd-sized desktop windows.
                contentWidth &= ~1; contentHeight &= ~1;
                if (contentWidth == 0 || contentHeight == 0) return null;
                if (!conversionUnavailable)
                {
                    try
                    {
                        if (nv12Converter is null || nv12Converter.Width != contentWidth || nv12Converter.Height != contentHeight)
                        {
                            nv12Converter?.Dispose(); nv12Converter = null;
                            nv12Converter = new D3D11Nv12Converter(device, immediateContext, contentWidth, contentHeight);
                        }
                        if (UseGpuFrames)
                            return new CapturedFrame(contentWidth, contentHeight, contentWidth, timestamp100Nanoseconds,
                                CapturePixelFormat.Nv12, ReadOnlyMemory<byte>.Empty) { GpuSurface = nv12Converter.ConvertTextureToSurface(sourceTexture) };
                        return new CapturedFrame(contentWidth, contentHeight, contentWidth, timestamp100Nanoseconds,
                            CapturePixelFormat.Nv12, nv12Converter.ConvertTexture(sourceTexture));
                    }
                    catch (Exception e) when (e is COMException or PlatformNotSupportedException)
                    {
                        nv12Converter?.Dispose(); nv12Converter = null; conversionUnavailable = true;
                        // Try once per capture size/generation; unsupported adapters retain BGRA capture.
                    }
                }

                EnsureStagingTexture(sourceDescription);

                CopyResource(immediateContext, stagingTexture, sourceTexture);
                D3D11MappedSubresource mapped = default;
                ThrowIfFailed(Map(
                    immediateContext,
                    stagingTexture,
                    0,
                    D3D11MapRead,
                    0,
                    out mapped));

                try
                {
                    CaptureFrameLayout layout = CaptureFrameLayout.Create(
                        contentWidth,
                        contentHeight,
                        sourceDescription.Width,
                        sourceDescription.Height,
                        mapped.RowPitch);

                    if (mapped.Data == 0)
                    {
                        throw new InvalidDataException("Direct3D returned an empty mapped surface.");
                    }

                    byte[] pixels = GC.AllocateUninitializedArray<byte>(layout.PixelByteCount);
                    for (var row = 0; row < layout.Height; row++)
                    {
                        byte* sourceRow = (byte*)mapped.Data + ((nuint)row * mapped.RowPitch);
                        new ReadOnlySpan<byte>(sourceRow, layout.BytesPerRow).CopyTo(
                            pixels.AsSpan(row * layout.BytesPerRow, layout.BytesPerRow));
                    }

                    return new CapturedFrame(
                        layout.Width,
                        layout.Height,
                        layout.BytesPerRow,
                        timestamp100Nanoseconds,
                        CapturePixelFormat.Bgra8,
                        pixels);
                }
                finally
                {
                    Unmap(immediateContext, stagingTexture, 0);
                }
            }
            finally
            {
                Release(sourceTexture);
                Release(surfaceAccess);
                MarshalInterface<IDirect3DSurface>.DisposeAbi(surfaceAbi);
            }
        }
    }

    internal void ResetStagingTexture()
    {
        lock (stateLock)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            Release(stagingTexture);
            stagingTexture = 0;
            stagingDescription = default;
            nv12Converter?.Dispose(); nv12Converter = null; conversionUnavailable = false;
        }
    }

    public void Dispose()
    {
        lock (stateLock)
        {
            if (disposed)
            {
                return;
            }

            disposed = true;
            nv12Converter?.Dispose(); nv12Converter = null;
            Release(stagingTexture);
            Release(immediateContext);
            Release(device);
            stagingTexture = 0;
            immediateContext = 0;
            device = 0;

            if (WindowsRuntimeDevice is IWinRTObject windowsRuntimeObject)
            {
                windowsRuntimeObject.NativeObject.Dispose();
            }
        }
    }

    private static void CreateRawDevice(out nint device, out nint immediateContext)
    {
        int result = D3D11CreateDevice(
            0,
            D3DDriverTypeHardware,
            0,
            D3D11CreateDeviceBgraSupport,
            0,
            0,
            D3D11SdkVersion,
            out device,
            out _,
            out immediateContext);

        if (result >= 0)
        {
            return;
        }

        Release(immediateContext);
        Release(device);
        result = D3D11CreateDevice(
            0,
            D3DDriverTypeWarp,
            0,
            D3D11CreateDeviceBgraSupport,
            0,
            0,
            D3D11SdkVersion,
            out device,
            out _,
            out immediateContext);
        if (result < 0)
        {
            Release(immediateContext);
            Release(device);
            immediateContext = 0;
            device = 0;
            ThrowIfFailed(result);
        }
    }

    private void EnsureStagingTexture(D3D11Texture2DDescription sourceDescription)
    {
        if (stagingTexture != 0 &&
            stagingDescription.Width == sourceDescription.Width &&
            stagingDescription.Height == sourceDescription.Height &&
            stagingDescription.Format == sourceDescription.Format)
        {
            return;
        }

        Release(stagingTexture);
        stagingTexture = 0;

        D3D11Texture2DDescription description = sourceDescription;
        description.Usage = D3D11UsageStaging;
        description.BindFlags = 0;
        description.CpuAccessFlags = D3D11CpuAccessRead;
        description.MiscFlags = 0;

        ThrowIfFailed(CreateTexture2D(device, description, out stagingTexture));
        stagingDescription = description;
    }

    private static void ValidateSourceTexture(D3D11Texture2DDescription description)
    {
        if (description.Format != DxgiFormatB8G8R8A8Unorm)
        {
            throw new InvalidDataException("Windows capture returned a non-BGRA8 surface.");
        }

        if (description.MipLevels != 1 ||
            description.ArraySize != 1 ||
            description.SampleDescription.Count != 1)
        {
            throw new InvalidDataException("Windows capture returned an unsupported texture layout.");
        }
    }

    private static int QueryInterface(nint instance, Guid iid, out nint result)
    {
        nint localResult = 0;
        Guid localIid = iid;
        var method = (delegate* unmanaged[Stdcall]<nint, Guid*, nint*, int>)
            GetMethodAddress(instance, 0);
        int hresult = method(instance, &localIid, &localResult);
        result = localResult;
        return hresult;
    }

    private static int GetWrappedInterface(nint access, Guid iid, out nint result)
    {
        nint localResult = 0;
        Guid localIid = iid;
        var method = (delegate* unmanaged[Stdcall]<nint, Guid*, nint*, int>)
            GetMethodAddress(access, 3);
        int hresult = method(access, &localIid, &localResult);
        result = localResult;
        return hresult;
    }

    private static D3D11Texture2DDescription GetTextureDescription(nint texture)
    {
        D3D11Texture2DDescription description = default;
        var method = (delegate* unmanaged[Stdcall]<nint, D3D11Texture2DDescription*, void>)
            GetMethodAddress(texture, 10);
        method(texture, &description);
        return description;
    }

    private static int CreateTexture2D(
        nint device,
        D3D11Texture2DDescription description,
        out nint texture)
    {
        nint localTexture = 0;
        var method = (delegate* unmanaged[Stdcall]<
            nint,
            D3D11Texture2DDescription*,
            nint,
            nint*,
            int>)GetMethodAddress(device, 5);
        int hresult = method(device, &description, 0, &localTexture);
        texture = localTexture;
        return hresult;
    }

    private static void CopyResource(nint context, nint destination, nint source)
    {
        var method = (delegate* unmanaged[Stdcall]<nint, nint, nint, void>)
            GetMethodAddress(context, 47);
        method(context, destination, source);
    }

    private static int Map(
        nint context,
        nint resource,
        uint subresource,
        int mapType,
        uint mapFlags,
        out D3D11MappedSubresource mapped)
    {
        D3D11MappedSubresource localMapped = default;
        var method = (delegate* unmanaged[Stdcall]<
            nint,
            nint,
            uint,
            int,
            uint,
            D3D11MappedSubresource*,
            int>)GetMethodAddress(context, 14);
        int hresult = method(
            context,
            resource,
            subresource,
            mapType,
            mapFlags,
            &localMapped);
        mapped = localMapped;
        return hresult;
    }

    private static void Unmap(nint context, nint resource, uint subresource)
    {
        var method = (delegate* unmanaged[Stdcall]<nint, nint, uint, void>)
            GetMethodAddress(context, 15);
        method(context, resource, subresource);
    }

    private static nint GetMethodAddress(nint instance, int slot)
    {
        if (instance == 0)
        {
            throw new InvalidOperationException("A Direct3D COM object was not initialized.");
        }

        return (*(nint**)instance)[slot];
    }

    private static void Release(nint instance)
    {
        if (instance != 0)
        {
            var method = (delegate* unmanaged[Stdcall]<nint, uint>)
                GetMethodAddress(instance, 2);
            _ = method(instance);
        }
    }

    private static void ThrowIfFailed(int hresult) => Marshal.ThrowExceptionForHR(hresult);

    [DllImport("d3d11.dll")]
    private static extern int D3D11CreateDevice(
        nint adapter,
        int driverType,
        nint software,
        uint flags,
        nint featureLevels,
        uint featureLevelCount,
        uint sdkVersion,
        out nint device,
        out int selectedFeatureLevel,
        out nint immediateContext);

    [DllImport("d3d11.dll")]
    private static extern int CreateDirect3D11DeviceFromDXGIDevice(
        nint dxgiDevice,
        out nint graphicsDevice);

    [StructLayout(LayoutKind.Sequential)]
    private struct DxgiSampleDescription
    {
        internal uint Count;
        internal uint Quality;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct D3D11Texture2DDescription
    {
        internal uint Width;
        internal uint Height;
        internal uint MipLevels;
        internal uint ArraySize;
        internal int Format;
        internal DxgiSampleDescription SampleDescription;
        internal int Usage;
        internal uint BindFlags;
        internal uint CpuAccessFlags;
        internal uint MiscFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct D3D11MappedSubresource
    {
        internal nint Data;
        internal uint RowPitch;
        internal uint DepthPitch;
    }
}
