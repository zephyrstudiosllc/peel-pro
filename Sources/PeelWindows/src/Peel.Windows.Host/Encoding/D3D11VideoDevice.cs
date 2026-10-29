using System.Runtime.InteropServices;

namespace Peel.Windows.Host.Encoding;

/// <summary>A generation-owned DXVA device and manager; no software adapter masquerades as hardware.</summary>
internal sealed unsafe class D3D11VideoDevice : IDisposable
{
    internal static readonly Guid D3D11Aware = new("206b4fc8-fcf9-4c51-afe3-9764369e33a0");
    private static readonly Guid Multithread = new("9b7e4e00-342c-4106-a19f-4f2704f689f0");
    private nint device, context, manager;
    internal nint Manager => manager;
    internal nint Device => device;
    internal nint Context => context;
    private D3D11VideoDevice() { }
    internal static D3D11VideoDevice Create(nint existingDevice = 0)
    {
        var owned = new D3D11VideoDevice();
        nint multithread = 0;
        try
        {
            if (existingDevice == 0)
                Check(D3D11CreateDevice(0, 1, 0, 0x20 | 0x800, 0, 0, 7,
                    out owned.device, out _, out owned.context)); // BGRA_SUPPORT | VIDEO_SUPPORT; hardware only.
            else
            {
                Marshal.AddRef(existingDevice); owned.device = existingDevice;
                nint context = 0;
                ((delegate* unmanaged[Stdcall]<nint, nint*, void>)(*(nint**)existingDevice)[40])(existingDevice, &context);
                owned.context = context;
            }
            Guid iid = Multithread;
            Check(Marshal.QueryInterface(owned.device, in iid, out multithread));
            var protect = (delegate* unmanaged[Stdcall]<nint, int, int>)(*(nint**)multithread)[5];
            _ = protect(multithread, 1);
            Check(MFCreateDXGIDeviceManager(out uint token, out owned.manager));
            var reset = (delegate* unmanaged[Stdcall]<nint, nint, uint, int>)(*(nint**)owned.manager)[7];
            Check(reset(owned.manager, owned.device, token));
            return owned;
        }
        catch { owned.Dispose(); throw; }
        finally { if (multithread != 0) Marshal.Release(multithread); }
    }
    internal static bool Supports(nint attributes)
    {
        Guid key = D3D11Aware; uint value = 0;
        var get = (delegate* unmanaged[Stdcall]<nint, Guid*, uint*, int>)(*(nint**)attributes)[7];
        return get(attributes, &key, &value) >= 0 && value != 0;
    }
    public void Dispose()
    {
        if (manager != 0) { Marshal.Release(manager); manager = 0; }
        if (context != 0) { Marshal.Release(context); context = 0; }
        if (device != 0) { Marshal.Release(device); device = 0; }
    }
    private static void Check(int result) => Marshal.ThrowExceptionForHR(result);
    [DllImport("d3d11.dll")] private static extern int D3D11CreateDevice(nint adapter, int driverType, nint software,
        uint flags, nint levels, uint levelCount, uint sdkVersion, out nint device, out uint level, out nint context);
    [DllImport("mfplat.dll")] private static extern int MFCreateDXGIDeviceManager(out uint token, out nint manager);
}
