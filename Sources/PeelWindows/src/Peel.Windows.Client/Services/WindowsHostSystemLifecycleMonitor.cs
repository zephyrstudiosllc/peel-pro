using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace Peel.Windows.Client.Services;

internal enum HostSystemLifecycleEvent
{
    SessionLocked,
    SessionUnlocked,
    Suspending,
    Resumed,
}

internal sealed class WindowsHostSystemLifecycleMonitor : IDisposable
{
    internal const int SessionChangeMessage = 0x02B1;
    internal const int PowerBroadcastMessage = 0x0218;
    internal const int SessionLock = 0x7;
    internal const int SessionUnlock = 0x8;
    internal const int PowerSuspend = 0x4;
    internal const int PowerResumeCritical = 0x6;
    internal const int PowerResumeSuspend = 0x7;
    internal const int PowerResumeAutomatic = 0x12;
    private const int NotifyForThisSession = 0;
    private const int SessionInfoEx = 25;

    private readonly nint windowHandle;
    private readonly HwndSource source;
    private readonly Action<HostSystemLifecycleEvent> callback;
    private bool disposed;

    internal WindowsHostSystemLifecycleMonitor(
        Window window,
        Action<HostSystemLifecycleEvent> callback)
    {
        ArgumentNullException.ThrowIfNull(window);
        this.callback = callback ?? throw new ArgumentNullException(nameof(callback));
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "Windows Host session monitoring requires Windows.");
        }

        windowHandle = new WindowInteropHelper(window).Handle;
        if (windowHandle == 0)
        {
            throw new InvalidOperationException(
                "The Peel window handle is unavailable for session monitoring.");
        }

        source = HwndSource.FromHwnd(windowHandle) ??
            throw new InvalidOperationException(
                "The Peel window source is unavailable for session monitoring.");
        source.AddHook(WindowProcedure);
        if (!WTSRegisterSessionNotification(windowHandle, NotifyForThisSession))
        {
            int error = Marshal.GetLastPInvokeError();
            source.RemoveHook(WindowProcedure);
            throw new Win32Exception(error, "Windows session monitoring could not start.");
        }
    }

    internal static HostSystemLifecycleEvent? ClassifyMessage(int message, nint value)
    {
        int eventValue = unchecked((int)value);
        return message switch
        {
            SessionChangeMessage when eventValue == SessionLock =>
                HostSystemLifecycleEvent.SessionLocked,
            SessionChangeMessage when eventValue == SessionUnlock =>
                HostSystemLifecycleEvent.SessionUnlocked,
            PowerBroadcastMessage when eventValue == PowerSuspend =>
                HostSystemLifecycleEvent.Suspending,
            PowerBroadcastMessage when eventValue is
                PowerResumeCritical or PowerResumeSuspend or PowerResumeAutomatic =>
                HostSystemLifecycleEvent.Resumed,
            _ => null,
        };
    }

    internal bool ReadInitialSessionLocked()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        using Process process = Process.GetCurrentProcess();
        int sessionId = process.SessionId;
        nint buffer = 0;
        try
        {
            if (!WTSQuerySessionInformationW(
                    0,
                    sessionId,
                    SessionInfoEx,
                    out buffer,
                    out int bytesReturned))
            {
                throw new Win32Exception(
                    Marshal.GetLastPInvokeError(),
                    "Windows session lock state could not be read.");
            }

            if (buffer == 0 || bytesReturned < Marshal.SizeOf<SessionInformationEx>())
            {
                throw new InvalidDataException(
                    "Windows returned incomplete session lock information.");
            }

            SessionInformationEx information = Marshal.PtrToStructure<SessionInformationEx>(buffer);
            return ClassifyInitialSessionLocked(
                information.Level,
                information.SessionId,
                information.SessionState,
                information.SessionFlags,
                sessionId);
        }
        finally
        {
            if (buffer != 0)
            {
                WTSFreeMemory(buffer);
            }
        }
    }

    internal static bool ClassifyInitialSessionLocked(
        uint level,
        uint reportedSessionId,
        int sessionState,
        int sessionFlags,
        int expectedSessionId)
    {
        if (level != 1 || expectedSessionId < 0 || reportedSessionId != (uint)expectedSessionId)
        {
            throw new InvalidDataException(
                "Windows returned unexpected session lock information.");
        }

        if (sessionState != 0) // WTSActive
        {
            throw new InvalidOperationException(
                "The current Windows session is not active. Secure hosting remains offline.");
        }

        return sessionFlags switch
        {
            0 => true, // WTS_SESSIONSTATE_LOCK
            1 => false, // WTS_SESSIONSTATE_UNLOCK (Windows 10 and later)
            _ => throw new InvalidDataException("Windows session lock state is unknown."),
        };
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        _ = WTSUnRegisterSessionNotification(windowHandle);
        source.RemoveHook(WindowProcedure);
    }

    private nint WindowProcedure(
        nint window,
        int message,
        nint wParam,
        nint lParam,
        ref bool handled)
    {
        _ = window;
        _ = lParam;
        _ = handled;
        HostSystemLifecycleEvent? lifecycleEvent = ClassifyMessage(message, wParam);
        if (lifecycleEvent is not null)
        {
            try
            {
                callback(lifecycleEvent.Value);
            }
            catch
            {
                // The message hook must never destabilize WPF dispatch.
            }
        }

        return 0;
    }

    [DllImport("wtsapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WTSRegisterSessionNotification(nint windowHandle, int flags);

    [DllImport("wtsapi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WTSUnRegisterSessionNotification(nint windowHandle);

    // WTSINFOEXW contains an eight-byte-aligned WTSINFOEX_LEVEL1_W union.
    // Only its nonpersonal prefix is read; the remaining native fields stay opaque.
    [StructLayout(LayoutKind.Explicit, Size = 232)]
    private struct SessionInformationEx
    {
        [FieldOffset(0)] internal uint Level;
        [FieldOffset(8)] internal uint SessionId;
        [FieldOffset(12)] internal int SessionState;
        [FieldOffset(16)] internal int SessionFlags;
    }

    [DllImport("wtsapi32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WTSQuerySessionInformationW(
        nint server,
        int sessionId,
        int informationClass,
        out nint buffer,
        out int bytesReturned);

    [DllImport("wtsapi32.dll", ExactSpelling = true)]
    private static extern void WTSFreeMemory(nint buffer);
}
