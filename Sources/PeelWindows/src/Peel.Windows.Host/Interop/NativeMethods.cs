using Microsoft.Win32.SafeHandles;
using System.Runtime.InteropServices;
using System.Text;

namespace Peel.Windows.Host.Interop;

internal static class NativeMethods
{
    internal const int GwlExStyle = -20;
    internal const long WsExToolWindow = 0x00000080L;
    internal const long WsExAppWindow = 0x00040000L;
    internal const uint GaRoot = 2;
    internal const uint DwmwaExtendedFrameBounds = 9;
    internal const uint DwmwaCloaked = 14;
    internal const uint WmGetIcon = 0x007F;
    internal const nuint IconSmall = 0;
    internal const nuint IconBig = 1;
    internal const nuint IconSmall2 = 2;
    internal const int GclpHicon = -14;
    internal const int GclpHiconSmall = -34;
    internal const uint SmtoBlock = 0x0001;
    internal const uint SmtoAbortIfHung = 0x0002;
    internal const uint MonitorInfofPrimary = 0x00000001;

    internal const int SmXVirtualScreen = 76;
    internal const int SmYVirtualScreen = 77;
    internal const int SmCxVirtualScreen = 78;
    internal const int SmCyVirtualScreen = 79;

    internal const uint InputMouse = 0;
    internal const uint InputKeyboard = 1;

    internal const uint MouseeventfMove = 0x0001;
    internal const uint MouseeventfLeftDown = 0x0002;
    internal const uint MouseeventfLeftUp = 0x0004;
    internal const uint MouseeventfRightDown = 0x0008;
    internal const uint MouseeventfRightUp = 0x0010;
    internal const uint MouseeventfMiddleDown = 0x0020;
    internal const uint MouseeventfMiddleUp = 0x0040;
    internal const uint MouseeventfXDown = 0x0080;
    internal const uint MouseeventfXUp = 0x0100;
    internal const uint MouseeventfWheel = 0x0800;
    internal const uint MouseeventfHwheel = 0x1000;
    internal const uint MouseeventfVirtualDesk = 0x4000;
    internal const uint MouseeventfAbsolute = 0x8000;

    internal const uint KeyeventfExtendedKey = 0x0001;
    internal const uint KeyeventfKeyUp = 0x0002;
    internal const uint KeyeventfUnicode = 0x0004;

    internal const uint ProcessQueryLimitedInformation = 0x1000;
    internal const uint TokenQuery = 0x0008;
    internal const int TokenIntegrityLevel = 25;

    internal delegate bool EnumWindowsProc(nint window, nint parameter);
    internal delegate bool MonitorEnumProc(
        nint monitor,
        nint monitorDeviceContext,
        ref Rect monitorRectangle,
        nint parameter);

    internal const int SwRestore = 9;

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool EnumWindows(EnumWindowsProc callback, nint parameter);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool EnumDisplayMonitors(
        nint deviceContext,
        nint clipRectangle,
        MonitorEnumProc callback,
        nint parameter);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool GetMonitorInfoW(nint monitor, ref MonitorInfo monitorInfo);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool IsWindowVisible(nint window);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool IsWindow(nint window);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool IsIconic(nint window);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool ShowWindowAsync(nint window, int command);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool SetForegroundWindow(nint window);

    [DllImport("user32.dll")]
    internal static extern nint GetForegroundWindow();

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool AttachThreadInput(
        uint attachThreadId,
        uint attachToThreadId,
        [MarshalAs(UnmanagedType.Bool)] bool attach);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool BringWindowToTop(nint window);

    [DllImport("kernel32.dll")]
    internal static extern uint GetCurrentThreadId();

    [DllImport("user32.dll", SetLastError = true)]
    internal static extern nint SetThreadDpiAwarenessContext(nint dpiContext);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    internal static extern int GetWindowTextW(nint window, StringBuilder text, int maximumCount);

    [DllImport("user32.dll", SetLastError = true)]
    internal static extern int GetWindowTextLengthW(nint window);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    internal static extern int GetClassNameW(nint window, StringBuilder className, int maximumCount);

    [DllImport("user32.dll")]
    internal static extern nint GetShellWindow();

    [DllImport("user32.dll")]
    internal static extern nint GetAncestor(nint window, uint flags);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool GetWindowRect(nint window, out Rect rectangle);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongW", SetLastError = true)]
    private static extern int GetWindowLong32(nint window, int index);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW", SetLastError = true)]
    private static extern nint GetWindowLongPtr64(nint window, int index);

    internal static nint GetWindowLongPtr(nint window, int index)
    {
        return nint.Size == 8
            ? GetWindowLongPtr64(window, index)
            : GetWindowLong32(window, index);
    }

    [DllImport("user32.dll", EntryPoint = "GetClassLongW", SetLastError = true)]
    private static extern uint GetClassLong32(nint window, int index);

    [DllImport("user32.dll", EntryPoint = "GetClassLongPtrW", SetLastError = true)]
    private static extern nuint GetClassLongPtr64(nint window, int index);

    internal static nint GetClassLongPtr(nint window, int index)
    {
        return nint.Size == 8
            ? unchecked((nint)GetClassLongPtr64(window, index))
            : unchecked((nint)GetClassLong32(window, index));
    }

    [DllImport("user32.dll", EntryPoint = "SendMessageTimeoutW", SetLastError = true)]
    internal static extern nint SendMessageTimeout(
        nint window,
        uint message,
        nuint wordParameter,
        nint longParameter,
        uint flags,
        uint timeoutMilliseconds,
        out nuint result);

    [DllImport("user32.dll")]
    internal static extern uint GetWindowThreadProcessId(nint window, out uint processId);

    [DllImport("dwmapi.dll")]
    internal static extern int DwmGetWindowAttribute(
        nint window,
        uint attribute,
        out uint value,
        int valueSize);

    [DllImport("dwmapi.dll")]
    internal static extern int DwmGetWindowAttribute(
        nint window,
        uint attribute,
        out Rect value,
        int valueSize);

    [DllImport("user32.dll")]
    internal static extern int GetSystemMetrics(int index);

    [DllImport("user32.dll", SetLastError = true)]
    internal static extern uint SendInput(
        uint inputCount,
        [In] Input[] inputs,
        int inputSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern SafeProcessHandle OpenProcess(
        uint desiredAccess,
        [MarshalAs(UnmanagedType.Bool)] bool inheritHandle,
        uint processId);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool OpenProcessToken(
        SafeProcessHandle processHandle,
        uint desiredAccess,
        out SafeAccessTokenHandle tokenHandle);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool GetTokenInformation(
        SafeAccessTokenHandle tokenHandle,
        int tokenInformationClass,
        nint tokenInformation,
        int tokenInformationLength,
        out int returnLength);

    [DllImport("advapi32.dll")]
    internal static extern nint GetSidSubAuthorityCount(nint sid);

    [DllImport("advapi32.dll")]
    internal static extern nint GetSidSubAuthority(nint sid, uint subAuthorityIndex);

    [StructLayout(LayoutKind.Sequential)]
    internal struct Rect
    {
        internal int Left;
        internal int Top;
        internal int Right;
        internal int Bottom;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct MonitorInfo
    {
        internal int Size;
        internal Rect Monitor;
        internal Rect Work;
        internal uint Flags;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct Input
    {
        internal uint Type;
        internal InputUnion Data;
    }

    [StructLayout(LayoutKind.Explicit)]
    internal struct InputUnion
    {
        [FieldOffset(0)]
        internal MouseInput Mouse;

        [FieldOffset(0)]
        internal KeyboardInput Keyboard;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct MouseInput
    {
        internal int Dx;
        internal int Dy;
        internal uint MouseData;
        internal uint Flags;
        internal uint Time;
        internal nuint ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct KeyboardInput
    {
        internal ushort VirtualKey;
        internal ushort ScanCode;
        internal uint Flags;
        internal uint Time;
        internal nuint ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct SidAndAttributes
    {
        internal nint Sid;
        internal uint Attributes;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct TokenMandatoryLabel
    {
        internal SidAndAttributes Label;
    }
}
