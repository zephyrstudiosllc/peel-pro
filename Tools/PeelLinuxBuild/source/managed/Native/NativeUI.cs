using System.Runtime.InteropServices;
namespace Peel.Linux;
internal static class NativeUI
{
    private const string Library = "peel_linux";
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate void Connect([MarshalAs(UnmanagedType.LPUTF8Str)] string id, [MarshalAs(UnmanagedType.LPUTF8Str)] string address, int port, IntPtr user);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate void OpenWindow(uint window, ulong generation, IntPtr user);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate void Disconnect(IntPtr user);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate void CloseWindow(uint window, ulong generation, IntPtr user);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int peel_linux_run(Connect connect, OpenWindow open, Disconnect disconnect, CloseWindow close, IntPtr user);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern void peel_linux_status([MarshalAs(UnmanagedType.LPUTF8Str)] string text);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern void peel_linux_windows([MarshalAs(UnmanagedType.LPUTF8Str)] string json, ulong generation);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr peel_linux_secret_lookup([MarshalAs(UnmanagedType.LPUTF8Str)] string id);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int peel_linux_secret_store([MarshalAs(UnmanagedType.LPUTF8Str)] string id, [MarshalAs(UnmanagedType.LPUTF8Str)] string secret);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern void peel_linux_secret_free(IntPtr secret);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern void peel_linux_receiver_generation(ulong generation);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr peel_linux_decoder_new(ulong generation, uint window);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int peel_linux_decoder_configure(IntPtr handle, uint width, uint height, byte[] parameters, nuint count);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int peel_linux_decoder_push(IntPtr handle, byte[] bytes, nuint count, ulong pts, ulong duration);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern void peel_linux_decoder_free(IntPtr handle);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int peel_linux_audio_available();
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr peel_linux_audio_new(ulong generation);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int peel_linux_audio_push(IntPtr handle, byte[] pcm, nuint count);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern void peel_linux_audio_free(IntPtr handle);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate void ViewerControl(uint window, ulong generation, int command, double value, IntPtr user);
    [StructLayout(LayoutKind.Sequential)] internal struct ViewerState
    {
        public int Audio, ListenEnabled, MediaEnabled, VolumeSupported, CanSetVolume, CanSetMute, Muted;
        public double Volume;
    }
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern void peel_linux_viewer_register(ViewerControl control, IntPtr user);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern void peel_linux_viewer_visibility(int showVolume, int showMedia);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern void peel_linux_viewer_state(ulong generation, uint window, ref ViewerState state, [MarshalAs(UnmanagedType.LPUTF8Str)] string? note);
}
