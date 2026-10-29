using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Interop;
using System.Windows.Threading;
using Peel.Windows.Host.Capture;
using Peel.Windows.Host.Input;
using Peel.Windows.Host.Interop;
using Peel.Windows.Host.Windows;

namespace Peel.Windows.Client.Services;

/// <summary>Production window identity, foreground/UIPI resolution and hit testing for local agents.</summary>
internal sealed class Win32LocalWindowPlatform : ILocalWindowPlatform
{
    // The enumerator's icon cache is not thread-safe; only the bridge's dispatcher enumerates.
    private readonly Win32WindowEnumerator enumerator = new();

    public IReadOnlyList<WindowDescriptor> Enumerate() => enumerator.Enumerate();

    public WindowDescriptor? TryReadCurrent(WindowDescriptor listed, bool allowMinimized)
    {
        if (!OperatingSystem.IsWindows() || listed.IsDisplay) return null;
        using WindowsDpiAwarenessScope dpi = WindowsDpiAwarenessScope.EnterPerMonitorV2();
        nint window = listed.Handle;
        if (window == 0 || !NativeMethods.IsWindow(window) || !NativeMethods.IsWindowVisible(window) ||
            NativeMethods.GetAncestor(window, NativeMethods.GaRoot) != window) return null;
        bool minimized = NativeMethods.IsIconic(window);
        if (minimized && !allowMinimized) return null;
        _ = NativeMethods.GetWindowThreadProcessId(window, out uint processId);
        if (processId == 0 || processId != listed.ProcessId || processId == (uint)Environment.ProcessId) return null;
        var className = new StringBuilder(256);
        if (NativeMethods.GetClassNameW(window, className, className.Capacity) <= 0 ||
            !string.Equals(className.ToString(), listed.ClassName, StringComparison.Ordinal)) return null;
        try
        {
            // Same derivation as the enumerator, so an exact equality means the same process instance.
            using var process = Process.GetProcessById(checked((int)processId));
            double started = new DateTimeOffset(process.StartTime).ToUnixTimeMilliseconds() / 1000.0;
            if (started != listed.AppLaunchTimeIntervalSince1970 ||
                !string.Equals(process.ProcessName, listed.ProcessName, StringComparison.OrdinalIgnoreCase)) return null;
        }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception or OverflowException)
        {
            return null;
        }
        WindowBounds bounds = listed.Bounds;
        if (!minimized && !Win32WindowEnumerator.TryReadBounds(window, out bounds)) return null;
        return listed with { Bounds = bounds };
    }

    // A fresh resolver reads the current and target integrity levels on every check, so a reused
    // process ID can never inherit a cached lower integrity level.
    public WindowInputTargetResult Resolve(WindowDescriptor window, WindowInputFocusMode focusMode) =>
        new WindowsWindowInputTargetResolver().Resolve(window, focusMode);

    public bool IsTopLevelTargetAt(WindowDescriptor window, ScreenPoint point)
    {
        // Same per-monitor coordinate space as the resolver's bounds.
        using WindowsDpiAwarenessScope dpi = WindowsDpiAwarenessScope.EnterPerMonitorV2();
        nint hit = WindowFromPoint(new NativePoint { X = point.X, Y = point.Y });
        return hit != 0 && NativeMethods.GetAncestor(hit, NativeMethods.GaRoot) == window.Handle;
    }

    public bool TryGetCursorPosition(out ScreenPoint point)
    {
        using WindowsDpiAwarenessScope dpi = WindowsDpiAwarenessScope.EnterPerMonitorV2();
        bool ok = GetCursorPos(out NativePoint native);
        point = new ScreenPoint(native.X, native.Y);
        return ok;
    }

    [StructLayout(LayoutKind.Sequential)] private struct NativePoint { public int X; public int Y; }
    [DllImport("user32.dll")] private static extern nint WindowFromPoint(NativePoint point);
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetCursorPos(out NativePoint point);
}

/// <summary>
/// GetLastInputInfo and the input desktop. Windows updates the last-input tick for every keyboard,
/// mouse, pen or touch event in this session, including SendInput, and exposes no event contents.
/// </summary>
internal sealed class Win32LocalInputClock : ILocalInputClock
{
    private const uint DesktopReadObjects = 0x0001;

    public bool TryReadLastInputTick(out uint tick)
    {
        var info = new LastInputInfo { Size = (uint)Marshal.SizeOf<LastInputInfo>() };
        bool ok = OperatingSystem.IsWindows() && GetLastInputInfo(ref info);
        tick = info.Time;
        return ok;
    }

    public uint CurrentTick => unchecked((uint)Environment.TickCount64);

    public bool IsInputDesktopActive()
    {
        if (!OperatingSystem.IsWindows()) return false;
        // Fails while the lock screen, the secure desktop (UAC, Ctrl+Alt+Del) or a disconnected session owns input.
        nint desktop = OpenInputDesktop(0, false, DesktopReadObjects);
        if (desktop == 0) return false;
        _ = CloseDesktop(desktop);
        return true;
    }

    [StructLayout(LayoutKind.Sequential)] private struct LastInputInfo { public uint Size; public uint Time; }
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetLastInputInfo(ref LastInputInfo info);
    [DllImport("user32.dll", SetLastError = true)] private static extern nint OpenInputDesktop(uint flags, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint access);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseDesktop(nint desktop);
}

/// <summary>
/// Counts WM_INPUT notifications from header reads only; no key, character or pointer payload is read or kept.
/// Every complete header counts as person activity whatever its device handle: a precision touchpad, for example,
/// can report a zero handle. A failed, short or unrecognised read also counts and faults the counter, because
/// Windows signalled input that could not be observed; a faulted monitor is no longer available.
/// </summary>
internal sealed class RawInputActivityCounter
{
    internal static readonly uint HeaderSize = (uint)Marshal.SizeOf<RawInputHeader>();
    private const uint RimTypeHid = 2; // RIM_TYPEMOUSE 0, RIM_TYPEKEYBOARD 1, RIM_TYPEHID 2
    private long events;
    private int faulted;

    public long Events => Interlocked.Read(ref events);
    public bool Faulted => Volatile.Read(ref faulted) != 0;

    /// <summary>O(1). <paramref name="read"/> is GetRawInputData's return value for a RID_HEADER read.</summary>
    internal void Observe(uint read, in RawInputHeader header)
    {
        Interlocked.Increment(ref events);
        if (!IsComplete(read, header)) Volatile.Write(ref faulted, 1);
    }

    /// <summary>A fresh registration starts unfaulted; the event count stays monotonic.</summary>
    internal void Rearm() => Volatile.Write(ref faulted, 0);

    internal static bool IsComplete(uint read, in RawInputHeader header) =>
        read == HeaderSize && header.Size >= HeaderSize && header.Type <= RimTypeHid;
}

[StructLayout(LayoutKind.Sequential)]
internal struct RawInputHeader { public uint Type; public uint Size; public nint Device; public nint WParam; }

[StructLayout(LayoutKind.Sequential)]
internal struct RawInputDevice { public ushort UsagePage; public ushort Usage; public uint Flags; public nint Target; }

/// <summary>GetRegisteredRawInputDevices with its last error, so tests can fake the exact Win32 boundary.</summary>
internal delegate uint RegisteredRawInputQuery(RawInputDevice[]? devices, ref uint count, out int lastError);

/// <summary>
/// Hardware input presence from raw input headers. A dedicated thread owns a message-only window registered with
/// RIDEV_INPUTSINK for keyboard and mouse (required) and, where Windows accepts them, pen and touch-screen
/// digitizers (optional; registration does not prove Windows delivers them). Each WM_INPUT is read with RID_HEADER
/// only and counted by <see cref="RawInputActivityCounter"/> whatever its device handle. Where Windows also reports
/// this feature's own SendInput as WM_INPUT, that input interrupts the agent too: fail closed, not attributed away.
/// Registration is per process and per device class: an existing registration is never replaced, ownership that
/// cannot be read is never assumed, and losing ours (or an unreadable header) makes <see cref="IsActive"/> false,
/// which turns AI control off.
/// </summary>
internal sealed class Win32RawInputActivityMonitor : ILocalHardwareActivity
{
    private const int WmInput = 0x00FF;
    private const uint RidHeader = 0x10000005;
    private const uint RidevRemove = 0x00000001;
    private const uint RidevInputSink = 0x00000100;
    private const int ErrorInsufficientBuffer = 122;
    private const uint MaximumRegistrations = 256;
    private static readonly nint MessageOnlyParent = new(-3);
    private static readonly uint DeviceSize = (uint)Marshal.SizeOf<RawInputDevice>();
    private static readonly (ushort Page, ushort Usage)[] Required = [(0x01, 0x02), (0x01, 0x06)]; // mouse, keyboard
    private static readonly (ushort Page, ushort Usage)[] Optional = [(0x0D, 0x02), (0x0D, 0x04)]; // pen, touch screen

    private readonly object gate = new();
    private readonly RegisteredRawInputQuery query;
    private readonly RawInputActivityCounter counter = new();
    private Thread? thread;
    private Dispatcher? dispatcher;
    private nint window;
    private bool stopping;
    private (ushort Page, ushort Usage)[] owned = [];

    /// <param name="query">The registration query; tests substitute failures. Production uses Windows.</param>
    internal Win32RawInputActivityMonitor(RegisteredRawInputQuery? query = null) => this.query = query ?? new RegisteredRawInputQuery(QueryWindows);

    public long Events => counter.Events;
    public string Coverage { get; private set; } = "Off";
    /// <summary>The header counter this monitor's window feeds.</summary>
    internal RawInputActivityCounter Counter => counter;

    public bool Start(out string? error)
    {
        error = null;
        if (!OperatingSystem.IsWindows()) { error = "Keyboard and mouse activity monitoring requires Windows."; return false; }
        Thread? previous;
        lock (gate)
        {
            if (thread is not null && !stopping) return true;
            previous = thread;
        }
        // A stopping monitor must finish removing its registration before a new one can own it.
        if (previous is not null && !previous.Join(TimeSpan.FromSeconds(2)))
        {
            error = "The previous keyboard and mouse activity monitor is still stopping. Try again.";
            return false;
        }
        var ready = new TaskCompletionSource<string?>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (gate)
        {
            if (thread is not null && !ReferenceEquals(thread, previous)) { error = "Keyboard and mouse activity monitoring is already starting."; return false; }
            dispatcher = null; Volatile.Write(ref window, 0); stopping = false; counter.Rearm();
            thread = new Thread(() => Run(ready)) { IsBackground = true, Name = "Peel local input activity" };
            thread.SetApartmentState(ApartmentState.STA);
            thread.Start();
        }
        // Never wait while holding the lock: the monitor thread takes it to publish or abandon its registration.
        if (!ready.Task.Wait(TimeSpan.FromSeconds(2)))
        {
            lock (gate) stopping = true; // A late registration sees this and removes itself.
            error = "Keyboard and mouse activity monitoring did not start in time, so AI control stays off.";
            return false;
        }
        error = ready.Task.Result;
        if (error is not null) { lock (gate) stopping = true; return false; }
        return true;
    }

    public void Stop()
    {
        Dispatcher? owner;
        lock (gate)
        {
            if (thread is null || stopping) return;
            stopping = true; owner = dispatcher;
        }
        Coverage = "Off";
        owner?.BeginInvoke(new Action(() =>
        {
            Unregister(Volatile.Read(ref window));
            Volatile.Write(ref window, 0);
            Dispatcher.CurrentDispatcher.InvokeShutdown();
        }));
    }

    public bool IsActive
    {
        get
        {
            nint target = Volatile.Read(ref window);
            if (target == 0 || counter.Faulted) return false;
            // A dead thread or destroyed window can leave a registration that no longer counts anything.
            lock (gate) if (stopping || thread is not { IsAlive: true }) return false;
            if (!NativeMethods.IsWindow(target)) return false;
            return OwnsRequired(ReadRegistrations(query), target);
        }
    }

    /// <summary>Process-wide raw input registrations, for ownership checks; null when Windows could not report them.</summary>
    internal static RawInputDevice[]? ReadRegistrations() => ReadRegistrations(QueryWindows);

    /// <summary>
    /// Null (unknown) unless both the size query and the fill succeed consistently. An empty array means Windows
    /// reported no registrations; it is never a stand-in for a failed, short or impossible result.
    /// </summary>
    internal static RawInputDevice[]? ReadRegistrations(RegisteredRawInputQuery query)
    {
        for (int attempt = 0; attempt < 3; attempt++)
        {
            uint count = 0;
            uint sized = query(null, ref count, out int error);
            // Windows reports the count with 0, or with -1 and ERROR_INSUFFICIENT_BUFFER; anything else is a failure.
            bool reported = sized == 0 || (sized == uint.MaxValue && error == ErrorInsufficientBuffer && count > 0);
            if (!reported || count > MaximumRegistrations) return null;
            if (count == 0) return [];
            uint capacity = count;
            var devices = new RawInputDevice[capacity];
            uint read = query(devices, ref count, out error);
            if (read == capacity) return devices;
            if (read == uint.MaxValue && error == ErrorInsufficientBuffer) continue; // Grew between the calls; ask again.
            return null;
        }
        return null;
    }

    /// <summary>True only when the registrations are known and both required classes target this exact window.</summary>
    internal static bool OwnsRequired(RawInputDevice[]? current, nint target) =>
        target != 0 && current is { } known &&
        Required.All(r => known.Any(d => d.UsagePage == r.Page && d.Usage == r.Usage && d.Target == target));

    /// <summary>Why registration must not proceed: unknown ownership or an existing keyboard/mouse owner. Null to proceed.</summary>
    internal static string? RegistrationRefusal(RawInputDevice[]? existing)
    {
        if (existing is not { } known)
            return "Windows could not report existing raw input registrations, so nothing was registered and AI control stays off.";
        if (Required.Any(r => known.Any(d => d.UsagePage == r.Page && d.Usage == r.Usage)))
            return "Keyboard or mouse raw input is already registered in Peel Pro (another owner, or an earlier monitor whose removal could not be confirmed), so AI control stays off.";
        return null;
    }

    /// <summary>The owned classes still targeting this window; none when the registrations cannot be read.</summary>
    internal static (ushort Page, ushort Usage)[] RemovableRegistrations(RawInputDevice[]? current, (ushort Page, ushort Usage)[] owned, nint target)
    {
        if (target == 0 || current is not { } known) return [];
        return owned.Where(o => known.Any(d => d.UsagePage == o.Page && d.Usage == o.Usage && d.Target == target)).ToArray();
    }

    internal static uint QueryWindows(RawInputDevice[]? devices, ref uint count, out int lastError)
    {
        uint result = GetRegisteredRawInputDevices(devices, ref count, DeviceSize);
        lastError = Marshal.GetLastPInvokeError();
        return result;
    }

    private void Run(TaskCompletionSource<string?> ready)
    {
        HwndSource? source = null;
        string? error;
        try
        {
            source = new HwndSource(new HwndSourceParameters("Peel local input activity")
            {
                ParentWindow = MessageOnlyParent, Width = 0, Height = 0, WindowStyle = 0,
            });
            source.AddHook(Hook);
            error = Register(source.Handle);
            if (error is null)
            {
                lock (gate)
                {
                    if (stopping) { Unregister(source.Handle); error = "Keyboard and mouse activity monitoring was cancelled."; }
                    else { dispatcher = Dispatcher.CurrentDispatcher; Volatile.Write(ref window, source.Handle); }
                }
            }
        }
        catch (Exception e) when (e is ExternalException or InvalidOperationException)
        {
            error = "Keyboard and mouse activity monitoring is unavailable: " + e.Message;
        }
        ready.TrySetResult(error);
        try { if (error is null) Dispatcher.Run(); }
        finally { source?.Dispose(); }
    }

    private string? Register(nint target)
    {
        var existing = ReadRegistrations(query);
        if (RegistrationRefusal(existing) is { } refusal) return refusal;
        var required = Required.Select(r => new RawInputDevice { UsagePage = r.Page, Usage = r.Usage, Flags = RidevInputSink, Target = target }).ToArray();
        if (!RegisterRawInputDevices(required, (uint)required.Length, DeviceSize))
            return $"Windows refused keyboard and mouse activity monitoring (error {Marshal.GetLastPInvokeError()}), so AI control stays off.";
        var ownedList = new List<(ushort, ushort)>(Required);
        var coverage = new List<string> { "keyboard", "mouse" };
        foreach (var o in Optional)
        {
            if (existing!.Any(d => d.UsagePage == o.Page && d.Usage == o.Usage)) continue; // Never replace another owner.
            var device = new[] { new RawInputDevice { UsagePage = o.Page, Usage = o.Usage, Flags = RidevInputSink, Target = target } };
            if (!RegisterRawInputDevices(device, 1, DeviceSize)) continue;
            ownedList.Add(o); coverage.Add(o.Usage == 0x02 ? "pen" : "touch screen");
        }
        owned = ownedList.ToArray();
        Coverage = string.Join(", ", coverage) + " (registered; delivery is a runtime gate)";
        return null;
    }

    /// <summary>
    /// Removes only registrations that still target this monitor's window. When Windows cannot report the current
    /// registrations nothing is removed, because the class may belong to another owner; a later start then refuses.
    /// </summary>
    private void Unregister(nint target)
    {
        if (target == 0) return;
        foreach (var o in RemovableRegistrations(ReadRegistrations(query), owned, target))
            _ = RegisterRawInputDevices([new RawInputDevice { UsagePage = o.Page, Usage = o.Usage, Flags = RidevRemove, Target = 0 }], 1, DeviceSize);
        owned = [];
    }

    /// <summary>
    /// O(1): one header read and one increment, whatever the device handle. An unreadable header also counts and
    /// faults the monitor. DefWindowProc still performs WM_INPUT cleanup.
    /// </summary>
    private nint Hook(nint hwnd, int message, nint wParam, nint lParam, ref bool handled)
    {
        if (message == WmInput)
        {
            uint size = RawInputActivityCounter.HeaderSize;
            uint read = GetRawInputData(lParam, RidHeader, out RawInputHeader header, ref size, RawInputActivityCounter.HeaderSize);
            counter.Observe(read, header);
        }
        return 0;
    }

    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RegisterRawInputDevices(RawInputDevice[] devices, uint count, uint size);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetRegisteredRawInputDevices([In, Out] RawInputDevice[]? devices, ref uint count, uint size);
    [DllImport("user32.dll")]
    private static extern uint GetRawInputData(nint rawInput, uint command, out RawInputHeader data, ref uint size, uint headerSize);
}

/// <summary>One-frame Windows.Graphics.Capture of an exact window. Windows shows its capture border meanwhile.</summary>
internal sealed class LocalWindowCapture : ILocalWindowCapture
{
    private readonly IWindowCaptureBackend backend = new WindowsGraphicsCaptureBackend();

    public async Task<LocalCapturedImage> CaptureAsync(WindowDescriptor window, CancellationToken cancellationToken)
    {
        IWindowCaptureSession session = await backend.OpenAsync(window, cancellationToken).ConfigureAwait(false);
        await using (session.ConfigureAwait(false))
        {
            using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            var first = new TaskCompletionSource<LocalCapturedImage>(TaskCreationOptions.RunContinuationsAsynchronously);
            Task run = session.RunAsync((frame, _) =>
            {
                if (first.Task.IsCompleted || frame.Pixels.IsEmpty) return ValueTask.CompletedTask;
                try
                {
                    if (frame.PixelFormat == CapturePixelFormat.Bgra8)
                        first.TrySetResult(new(frame.Width, frame.Height, frame.BytesPerRow, frame.Pixels.ToArray()));
                    else if (frame.PixelFormat == CapturePixelFormat.Nv12)
                        // Capture converts full-range RGB to limited BT.601, the converter's default.
                        first.TrySetResult(new(frame.Width, frame.Height, frame.Width * 4,
                            Nv12ToBgra32Converter.Convert(frame.Pixels.Span, frame.Width, frame.Height)));
                }
                catch (Exception e) { first.TrySetException(e); }
                if (first.Task.IsCompleted) stop.Cancel();
                return ValueTask.CompletedTask;
            }, stop.Token);
            // If capture ends first (window closed, device lost), report that instead of waiting forever.
            _ = run.ContinueWith(t => first.TrySetException(t.Exception?.InnerException ??
                    new InvalidOperationException("The window stopped producing frames before one was captured.")),
                CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
            using var registration = cancellationToken.Register(() => first.TrySetCanceled(cancellationToken));
            try { return await first.Task.ConfigureAwait(false); }
            finally
            {
                stop.Cancel();
                // The first frame (or its failure) already decided the result; capture teardown cannot change it.
                try { await run.ConfigureAwait(false); } catch (Exception) { }
            }
        }
    }
}
