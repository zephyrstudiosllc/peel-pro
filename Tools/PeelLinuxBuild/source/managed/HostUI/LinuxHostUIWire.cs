using System.Runtime.InteropServices;
namespace Peel.Linux.HostUI;
internal static class LinuxHostUIWire
{
    private const string Library = "peel_linux";
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate void Event(int kind, ulong epoch, IntPtr user);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate void Answer(ulong operation, int result, IntPtr user);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate void Discovery(ulong operation, int result, IntPtr user);
    [DllImport(Library, CallingConvention=CallingConvention.Cdecl)] internal static extern void peel_linux_host_ui_register(Event action, Answer answer, IntPtr user);
    [DllImport(Library, CallingConvention=CallingConvention.Cdecl)] internal static extern void peel_linux_host_ui_state(ulong epoch,ulong revision,[MarshalAs(UnmanagedType.LPUTF8Str)]string message,int pair,int share,int stop);
    [DllImport(Library, CallingConvention=CallingConvention.Cdecl)] internal static extern int peel_linux_host_ui_present(ulong epoch,ulong operation,int kind,[MarshalAs(UnmanagedType.LPUTF8Str)]string name,[MarshalAs(UnmanagedType.LPUTF8Str)]string detail);
    [DllImport(Library, CallingConvention=CallingConvention.Cdecl)] internal static extern void peel_linux_host_ui_dismiss(ulong epoch,ulong operation);
    [DllImport(Library, CallingConvention=CallingConvention.Cdecl)] internal static extern void peel_linux_host_ui_finish_close(ulong epoch);
    [DllImport(Library, CallingConvention=CallingConvention.Cdecl)] internal static extern int peel_linux_discovery_publish(ulong operation,[MarshalAs(UnmanagedType.LPUTF8Str)]string name,[MarshalAs(UnmanagedType.LPUTF8Str)]string type,ushort port,int interfaceIndex,int protocol,[MarshalAs(UnmanagedType.LPUTF8Str)]string txt,Discovery response,IntPtr user);
    [DllImport(Library, CallingConvention=CallingConvention.Cdecl)] internal static extern int peel_linux_discovery_update(ulong operation,ulong transaction,[MarshalAs(UnmanagedType.LPUTF8Str)]string txt,Discovery response,IntPtr user);
    [DllImport(Library, CallingConvention=CallingConvention.Cdecl)] internal static extern void peel_linux_discovery_stop(ulong operation);
}
internal interface ILinuxHostUIChannel
{
    Task<bool> Present(ulong epoch,ulong operation,int kind,string name,string detail,Func<Func<bool>,bool> admission);
    Task Dismiss(ulong epoch,ulong operation);
    Task State(ulong epoch,ulong revision,string text,bool pair,bool share,bool stop);
    Task FinishClose(ulong epoch);
}
internal sealed class LinuxHostUIChannel : ILinuxHostUIChannel
{
    public Task<bool> Present(ulong e,ulong o,int k,string n,string d,Func<Func<bool>,bool> admission) => Peel.Linux.Host.LinuxHostGtk.InvokeAsync(() => admission(() => LinuxHostUIWire.peel_linux_host_ui_present(e,o,k,n,d)==1));
    public Task Dismiss(ulong e,ulong o) => Peel.Linux.Host.LinuxHostGtk.InvokeAsync(() => { LinuxHostUIWire.peel_linux_host_ui_dismiss(e,o);return true; });
    public Task State(ulong e,ulong revision,string t,bool p,bool s,bool x) => Peel.Linux.Host.LinuxHostGtk.InvokeAsync(() => { LinuxHostUIWire.peel_linux_host_ui_state(e,revision,t,p?1:0,s?1:0,x?1:0);return true; });
    public Task FinishClose(ulong e) => Peel.Linux.Host.LinuxHostGtk.InvokeAsync(() => { LinuxHostUIWire.peel_linux_host_ui_finish_close(e);return true; });
}
