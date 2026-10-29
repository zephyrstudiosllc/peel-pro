using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Peel.Windows.Client.Utilities;

/// <summary>Only interactive same-session processes, bound to creation time; never elevates.</summary>
public sealed class ProcessActions : IDisposable
{
    private readonly Dictionary<(int Id, long Start), List<SafeWaitHandle>> held = new();
    private readonly int sessionId = Process.GetCurrentProcess().SessionId;
    private static readonly HashSet<string> ProtectedNames = new(StringComparer.OrdinalIgnoreCase)
        { "explorer", "dwm", "winlogon", "csrss", "lsass", "services", "smss", "sihost", "fontdrvhost", "ShellExperienceHost", "StartMenuExperienceHost" };
    public bool IsHeld(ProcessReading reading) => held.ContainsKey((reading.Id, reading.StartedUtcTicks));

    public void Close(ProcessReading reading, bool force)
    {
        using var process = OpenCurrent(reading);
        // Process.Handle is cached before identity validation, so Kill cannot reopen a reused PID.
        if (force) process.Kill(entireProcessTree: false);
        else if (!process.CloseMainWindow()) throw new InvalidOperationException("This app has no window that can be asked to close.");
    }

    public void Hold(ProcessReading reading)
    {
        if (IsHeld(reading)) return;
        using var process = OpenCurrent(reading);
        var handles = new List<SafeWaitHandle>();
        try
        {
            foreach (ProcessThread thread in process.Threads)
            {
                using (thread)
                {
                    var handle = OpenThread(0x0002 | 0x0040, false, (uint)thread.Id);
                    if (handle.IsInvalid) { handle.Dispose(); throw new Win32Exception(Marshal.GetLastWin32Error()); }
                    if (GetProcessIdOfThread(handle) != (uint)reading.Id || process.HasExited)
                    { handle.Dispose(); throw new InvalidOperationException("The app changed before it could be held."); }
                    if (SuspendThread(handle) == uint.MaxValue)
                    { handle.Dispose(); throw new Win32Exception(Marshal.GetLastWin32Error()); }
                    handles.Add(handle);
                }
            }
            if (handles.Count == 0) throw new InvalidOperationException("The app has no live threads.");
            held.Add((reading.Id, reading.StartedUtcTicks), handles);
        }
        catch { Release(handles); throw; }
    }

    public void Resume(ProcessReading reading)
    {
        if (held.Remove((reading.Id, reading.StartedUtcTicks), out var handles)) Release(handles);
    }

    public void Dispose()
    {
        foreach (var handles in held.Values) Release(handles);
        held.Clear();
    }

    private Process OpenCurrent(ProcessReading reading)
    {
        if (reading.Id <= 4 || reading.Id == Environment.ProcessId || reading.SessionId != sessionId || !reading.HasWindow)
            throw new InvalidOperationException("Actions are limited to other apps with a window in your Windows session.");
        var process = Process.GetProcessById(reading.Id);
        try
        {
            _ = process.Handle;
            if (process.HasExited || process.StartTime.ToUniversalTime().Ticks != reading.StartedUtcTicks || process.SessionId != sessionId || process.MainWindowHandle == 0)
                throw new InvalidOperationException("This process has exited or its identity has changed. Refresh and select it again.");
            if (ProtectedNames.Contains(process.ProcessName) || !IsProcessCritical(process.Handle, out bool critical) || critical)
                throw new InvalidOperationException("Windows system and shell processes are protected from App Mechanic actions.");
            return process;
        }
        catch { process.Dispose(); throw; }
    }

    private static void Release(IEnumerable<SafeWaitHandle> handles)
    {
        // Release only our single suspend count, never someone else's debugger/hold.
        foreach (var handle in handles) { _ = ResumeThread(handle); handle.Dispose(); }
    }
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern SafeWaitHandle OpenThread(uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint id);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern uint SuspendThread(SafeWaitHandle thread);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern uint ResumeThread(SafeWaitHandle thread);
    [DllImport("kernel32.dll")] private static extern uint GetProcessIdOfThread(SafeWaitHandle thread);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool IsProcessCritical(nint process, [MarshalAs(UnmanagedType.Bool)] out bool critical);
}
