using System.Buffers;
using System.Text;
using System.Text.Json;
using Peel.Windows.Host.Input;
using Peel.Windows.Host.Windows;

namespace Peel.Windows.Client.Services;

/// <summary>A local agent refusal with a stable machine-readable code.</summary>
internal sealed class LocalAgentException(string code, string message) : InvalidOperationException(message)
{
    public string Code { get; } = code;
}

/// <summary>Window inventory, exact identity, foreground/UIPI and hit testing for this PC.</summary>
internal interface ILocalWindowPlatform
{
    /// <summary>Full inventory. Called only on the bridge's dispatcher.</summary>
    IReadOnlyList<WindowDescriptor> Enumerate();
    /// <summary>Re-reads exactly this listed window (HWND, PID, class, process name and start time); null when any changed.</summary>
    WindowDescriptor? TryReadCurrent(WindowDescriptor listed, bool allowMinimized);
    WindowInputTargetResult Resolve(WindowDescriptor window, WindowInputFocusMode focusMode);
    /// <summary>True only when the top-level window under the screen point is exactly this window.</summary>
    bool IsTopLevelTargetAt(WindowDescriptor window, ScreenPoint point);
    bool TryGetCursorPosition(out ScreenPoint point);
}

internal interface ILocalWindowCapture
{
    Task<LocalCapturedImage> CaptureAsync(WindowDescriptor window, CancellationToken cancellationToken);
}

internal sealed record LocalCapturedImage(int Width, int Height, int Stride, byte[] Bgra);

/// <summary>
/// The session's input-activity clock: the OS last-input timestamp and whether the normal input
/// desktop is active. No hook is installed and no key, character or pointer data is read.
/// </summary>
internal interface ILocalInputClock
{
    /// <summary>Millisecond tick (wrapping) of the latest input in this session, from a person or injected.</summary>
    bool TryReadLastInputTick(out uint tick);
    uint CurrentTick { get; }
    /// <summary>False while Windows shows a locked, secure (UAC or credential) or disconnected input desktop.</summary>
    bool IsInputDesktopActive();
}

/// <summary>
/// Input presence for this session: a count of every raw input notification Windows delivers for the registered
/// keyboard, mouse and (where Windows delivers them) pen/touch classes, whatever the device handle. Only event
/// headers are read; no key, character or pointer payload is read or kept. Nothing is attributed to the agent:
/// where Windows also reports injected input this way, the agent's own batches interrupt it (fail closed).
/// </summary>
internal interface ILocalHardwareActivity
{
    /// <summary>Takes ownership of the monitoring registration; false with a reason when it cannot, never stealing one.</summary>
    bool Start(out string? error);
    void Stop();
    /// <summary>
    /// True only while this monitor still owns its required keyboard and mouse registrations, Windows can report
    /// them, and no notification has been unreadable.
    /// </summary>
    bool IsActive { get; }
    long Events { get; }
    string Coverage { get; }
}

internal enum LocalControlAction { Click, Type, Key, Scroll, Drag }

/// <summary>Bounded action vocabulary for one local control call, matching the Mac route's names and limits.</summary>
internal sealed record LocalControlCommand(LocalControlAction Action, double X, double Y, double ToX, double ToY,
    MouseButton Button, string Text, ushort VirtualKey, IReadOnlyList<ushort> Modifiers, int DeltaX, int DeltaY)
{
    internal const int MaximumTextScalars = 512;
    internal const int MaximumTextUtf8Bytes = 1024;
    private const ushort ControlKey = 0x11, AltKey = 0x12, ShiftKey = 0x10, EscapeKey = 0x1B, TabKey = 0x09;
    private static readonly string[] BaseFields = ["targetId", "windowId", "windowToken", "inspectionId", "action"];

    private static readonly Dictionary<string, ushort> NamedKeys = new(StringComparer.Ordinal)
    {
        ["backspace"] = 0x08, ["delete"] = 0x08, ["forwardDelete"] = 0x2E, ["enter"] = 0x0D, ["returnKey"] = 0x0D,
        ["space"] = 0x20, ["tab"] = TabKey, ["escape"] = EscapeKey, ["leftArrow"] = 0x25, ["upArrow"] = 0x26,
        ["rightArrow"] = 0x27, ["downArrow"] = 0x28, ["home"] = 0x24, ["end"] = 0x23, ["pageUp"] = 0x21,
        ["pageDown"] = 0x22, ["f1"] = 0x70, ["f2"] = 0x71, ["f3"] = 0x72, ["f4"] = 0x73, ["f5"] = 0x74,
        ["f6"] = 0x75, ["f7"] = 0x76, ["f8"] = 0x77, ["f9"] = 0x78, ["f10"] = 0x79, ["f11"] = 0x7A, ["f12"] = 0x7B,
    };

    // "command" is the cross-platform primary shortcut modifier and maps to Ctrl. The Windows key is never sent.
    private static readonly Dictionary<string, ushort> ModifierKeys = new(StringComparer.Ordinal)
    {
        ["command"] = ControlKey, ["control"] = ControlKey, ["option"] = AltKey, ["shift"] = ShiftKey,
    };

    internal static LocalControlCommand Parse(JsonElement p)
    {
        if (p.ValueKind != JsonValueKind.Object) throw Invalid("Control arguments must be an object.");
        string actionName = p.TryGetProperty("action", out var a) && a.ValueKind == JsonValueKind.String ? a.GetString()! : "";
        (LocalControlAction action, string[] fields) = actionName switch
        {
            "click" => (LocalControlAction.Click, new[] { "x", "y", "button" }),
            "type" => (LocalControlAction.Type, new[] { "text" }),
            "key" => (LocalControlAction.Key, new[] { "key", "modifiers" }),
            "scroll" => (LocalControlAction.Scroll, new[] { "deltaX", "deltaY" }),
            "drag" => (LocalControlAction.Drag, new[] { "x", "y", "toX", "toY" }),
            _ => throw Invalid("Unknown control action."),
        };
        foreach (var property in p.EnumerateObject())
        {
            if (!BaseFields.Contains(property.Name) && !fields.Contains(property.Name)) throw Invalid("Fields must belong to this exact action: " + property.Name + ".");
        }

        double x = 0.5, y = 0.5, toX = 0.5, toY = 0.5;
        var button = MouseButton.Left; string text = ""; ushort key = 0; ushort[] modifiers = []; int deltaX = 0, deltaY = 0;
        switch (action)
        {
            case LocalControlAction.Click or LocalControlAction.Drag:
                x = Number(p, "x", 0, 1); y = Number(p, "y", 0, 1);
                if (action == LocalControlAction.Drag) { toX = Number(p, "toX", 0, 1); toY = Number(p, "toY", 0, 1); }
                else if (p.TryGetProperty("button", out var b))
                {
                    button = b.ValueKind == JsonValueKind.String ? b.GetString() switch
                    {
                        "left" => MouseButton.Left, "right" => MouseButton.Right, _ => throw Invalid("Button must be left or right."),
                    } : throw Invalid("Button must be left or right.");
                }
                break;
            case LocalControlAction.Type:
                text = p.TryGetProperty("text", out var t) && t.ValueKind == JsonValueKind.String ? t.GetString()! : "";
                ValidateText(text);
                break;
            case LocalControlAction.Key:
                string name = p.TryGetProperty("key", out var k) && k.ValueKind == JsonValueKind.String ? k.GetString()! : "";
                if (NamedKeys.TryGetValue(name, out ushort named)) key = named;
                else if (name.Length == 1 && name[0] is >= 'a' and <= 'z') key = (ushort)(0x41 + name[0] - 'a');
                else if (name.Length == 1 && name[0] is >= '0' and <= '9') key = (ushort)(0x30 + name[0] - '0');
                else throw Invalid("Use a named navigation/function key or a lowercase letter/digit.");
                if (p.TryGetProperty("modifiers", out var m))
                {
                    if (m.ValueKind != JsonValueKind.Array || m.GetArrayLength() > 4) throw Invalid("At most four modifiers are allowed.");
                    var names = new List<string>();
                    foreach (var item in m.EnumerateArray())
                    {
                        string modifier = item.ValueKind == JsonValueKind.String ? item.GetString()! : "";
                        if (!ModifierKeys.ContainsKey(modifier) || names.Contains(modifier)) throw Invalid("Use unique command/option/control/shift modifiers.");
                        names.Add(modifier);
                    }
                    modifiers = names.Select(n => ModifierKeys[n]).Distinct().ToArray();
                }
                // Shell-level shortcuts leave the inspected window: Start, Task Manager and app switching.
                if ((key == EscapeKey && (modifiers.Contains(ControlKey) || modifiers.Contains(AltKey))) ||
                    (key == TabKey && modifiers.Contains(AltKey)))
                    throw Invalid("Shortcuts that open Start or Task Manager or switch apps are not available.");
                break;
            case LocalControlAction.Scroll:
                double dx = Number(p, "deltaX", -1200, 1200), dy = Number(p, "deltaY", -1200, 1200);
                if (Math.Abs(dx) < 2 && Math.Abs(dy) < 2) throw Invalid("Scroll must include at least two input units.");
                deltaX = (int)Math.Round(dx, MidpointRounding.AwayFromZero); deltaY = (int)Math.Round(dy, MidpointRounding.AwayFromZero);
                break;
        }
        return new(action, x, y, toX, toY, button, text, key, modifiers, deltaX, deltaY);
    }

    internal static void ValidateText(string text)
    {
        if (text.Length == 0 || Encoding.UTF8.GetByteCount(text) > MaximumTextUtf8Bytes) throw Invalid("Text must be 1 to 1024 UTF-8 bytes.");
        int scalars = 0; var remaining = text.AsSpan();
        while (!remaining.IsEmpty)
        {
            if (Rune.DecodeFromUtf16(remaining, out Rune rune, out int used) != OperationStatus.Done) throw Invalid("Text contains invalid Unicode.");
            var category = Rune.GetUnicodeCategory(rune);
            if (category is System.Globalization.UnicodeCategory.Control or System.Globalization.UnicodeCategory.Format)
                throw Invalid("Text cannot contain control or formatting characters; send enter or tab with the key action.");
            remaining = remaining[used..];
            if (++scalars > MaximumTextScalars) throw Invalid("Text is limited to 512 Unicode scalars.");
        }
    }

    private static double Number(JsonElement p, string name, double minimum, double maximum)
    {
        if (!p.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Number || !value.TryGetDouble(out double number) ||
            !double.IsFinite(number) || number < minimum || number > maximum) throw Invalid($"{name} must be a number from {minimum} to {maximum}.");
        return number;
    }

    private static ArgumentException Invalid(string message) => new(message);
}

/// <summary>
/// Owns "Allow AI to see and use apps on this PC": runtime-only consent set only by Peel's UI, a
/// generation, a dedicated input gate (never the remote Host gate), 30-second window tokens,
/// single-use 10-second inspections, one operation at a time and quarter-second admissions.
/// Person priority has two sources and no hook: every raw input notification counted by
/// <see cref="ILocalHardwareActivity"/> (never attributed to the agent, whatever its device handle), and
/// last-input clock changes outside the agent's own batch window (other software's injected input that Windows
/// does not report as raw input; inside that window it can go unnoticed). Either advances the
/// generation, which voids every token, inspection and running operation, including between requests.
/// Every await and every input batch rechecks consent, generation, person activity, the monitor's
/// registration, the input desktop, exact identity, foreground/UIPI and geometry.
/// </summary>
internal sealed class LocalComputerAccess : IDisposable
{
    internal const string TargetId = "local";
    internal static readonly TimeSpan WindowTokenLifetime = TimeSpan.FromSeconds(30);
    internal static readonly TimeSpan InspectionLifetime = TimeSpan.FromSeconds(10);
    internal static readonly TimeSpan AdmissionInterval = TimeSpan.FromMilliseconds(250);
    internal static readonly TimeSpan CaptureDeadline = TimeSpan.FromSeconds(4);
    internal static readonly TimeSpan ControlDeadline = TimeSpan.FromSeconds(5);
    internal static readonly TimeSpan ActivityPollInterval = TimeSpan.FromMilliseconds(100);
    /// <summary>The person must leave keyboard and mouse alone this long before an agent may inspect or act.</summary>
    internal const uint HumanQuietMilliseconds = 1000;
    /// <summary>
    /// Windows may stamp the last-input time just after SendInput returns, so a clock change inside this window is
    /// treated as the batch's own. Counted raw input (including a zero device handle) is never subject to it; input
    /// that reaches only the clock, such as other software's injected input or a device class Windows does not
    /// deliver as raw input, can go unnoticed inside the window.
    /// </summary>
    internal const uint OwnInputSettleMilliseconds = 100;
    internal const int PointerTolerancePixels = 2;
    internal const int MaximumListedWindows = 128;
    internal const int MaximumInspections = 4;
    internal const int DragSteps = 10;
    private static readonly TimeSpan StepDelay = TimeSpan.FromMilliseconds(12);
    private const string OnStatus = "On · AI can see and use listed apps on this PC. Your keyboard or mouse pauses it.";
    private const string PausedStatus = "Paused for your keyboard or mouse. The agent must inspect again.";

    // Secure, credential and system-control UI is never listed, inspected or controlled.
    private static readonly HashSet<string> ExcludedProcesses = new(StringComparer.OrdinalIgnoreCase)
        { "CredentialUIBroker", "consent", "LockApp", "LogonUI", "winlogon", "Taskmgr", "SecHealthUI", "UserAccountControlSettings" };
    private static readonly HashSet<string> ExcludedClasses = new(StringComparer.Ordinal) { "Credential Dialog Xaml Host" };

    private sealed record Listing(WindowDescriptor Window, string? Token, long IssuedAt, long Generation);
    private sealed record Inspection(uint WindowId, string WindowToken, WindowBounds Bounds, long Generation, long IssuedAt);
    private sealed class Operation(CancellationTokenSource source, long generation)
    {
        public CancellationTokenSource Source { get; } = source;
        public long Generation { get; } = generation;
    }
    private sealed class Progress { public int Posted; public bool MaybePartial; }

    // Lock order: inputLock, then sync. inputLock makes each recheck and its SendInput batch one step
    // relative to human interruption. The UI thread (Enable/Disable) never takes inputLock.
    private readonly object inputLock = new();
    private readonly object sync = new();
    private readonly ILocalWindowPlatform platform;
    private readonly ILocalWindowCapture capture;
    private readonly ILocalInputClock clock;
    private readonly ILocalHardwareActivity hardware;
    private readonly IHostInputInjector injector;
    private readonly TimeProvider time;
    private readonly ITimer? activityPoll;
    private readonly Dictionary<uint, Listing> listings = new();
    private readonly Dictionary<string, Inspection> inspections = new(StringComparer.Ordinal);
    // Owned held input changes only inside LocalGate's critical section, together with the accepted send.
    private readonly HashSet<MouseButton> heldButtons = [];
    private readonly HashSet<ushort> heldKeys = [];
    private uint nextWindowId;
    private bool consent, disposed, pausedForPerson;
    private long generation;
    private uint accountedInputTick, lastPersonInputTick, ownInputStart, ownInputEnd;
    private long accountedHardwareEvents;
    private long? lastCaptureAdmission, lastInputAdmission;
    private Operation? operation;
    private string? activeApplication;
    private string status = "Off";

    internal LocalComputerAccess(ILocalWindowPlatform platform, ILocalWindowCapture capture, ILocalInputClock clock,
        ILocalHardwareActivity hardware, Func<InputPermissionGate, IHostInputInjector> injectorFactory,
        TimeProvider? time = null, bool pollActivity = true)
    {
        this.platform = platform; this.capture = capture; this.clock = clock; this.hardware = hardware;
        this.time = time ?? TimeProvider.System;
        injector = injectorFactory(LocalGate);
        if (pollActivity) activityPoll = this.time.CreateTimer(_ => PollActivity(), null, Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
    }

    /// <summary>Raised after consent, status or the active application changes. May be raised off the UI thread.</summary>
    public event EventHandler? Changed;

    /// <summary>Dedicated to local agents. The remote Host gate is a different instance and is never touched here.</summary>
    internal InputPermissionGate LocalGate { get; } = new();
    public bool IsEnabled { get { lock (sync) return consent; } }
    public long Generation { get { lock (sync) return generation; } }
    public bool ControlReady { get { lock (sync) return consent && !disposed && hardware.IsActive; } }
    public string Status
    {
        get
        {
            lock (sync)
            {
                if (!consent) return status;
                return activeApplication is { } app ? "AI is using " + Safe(app, 80) + " · Stop or use your keyboard or mouse to take over." : status;
            }
        }
    }

    /// <summary>Only Peel's UI calls this. The agent bridge has no route that enables consent.</summary>
    public bool Enable(bool agentConnectionsAllowed, out string? error)
    {
        error = null;
        if (!agentConnectionsAllowed) { error = "Turn on local agent connections first."; return false; }
        lock (sync)
        {
            if (disposed) { error = "Peel Pro is closing."; return false; }
            if (consent) return true;
        }
        // Control never starts without a hardware activity source this process owns.
        if (!hardware.Start(out string? monitorError))
        {
            error = monitorError ?? "Peel Pro could not watch for keyboard and mouse activity, so AI control stays off.";
            lock (sync) status = error;
            Raise(); return false;
        }
        lock (sync)
        {
            if (disposed) error = "Peel Pro is closing.";
            else if (!clock.IsInputDesktopActive()) error = "Windows is showing a locked or secure screen, so AI control stays off.";
            else if (!clock.TryReadLastInputTick(out uint tick)) error = "Windows input activity is unavailable, so AI control stays off.";
            else
            {
                consent = true; generation++; inspections.Clear();
                lastCaptureAdmission = lastInputAdmission = null;
                // The click that enabled consent is the person's input; the quiet period starts from it.
                accountedInputTick = lastPersonInputTick = ownInputStart = ownInputEnd = tick;
                accountedHardwareEvents = hardware.Events;
                pausedForPerson = true; status = PausedStatus;
            }
            if (error is not null) status = error;
        }
        if (error is not null) hardware.Stop();
        else LocalGate.SetEnabled(true);
        if (error is null) activityPoll?.Change(ActivityPollInterval, ActivityPollInterval);
        Raise();
        return error is null;
    }

    /// <summary>Turn off, Stop, lock, sleep or exit: closes the local gate, cancels work and releases only input this access holds.</summary>
    public void Disable(string reason)
    {
        bool changed; Operation? running;
        // Never waits on inputLock: this runs on the UI thread. The generation bump fails every later
        // recheck, and closing the dedicated gate waits only for a SendInput batch already inside it.
        lock (sync)
        {
            changed = consent || operation is not null || status != reason;
            consent = false; pausedForPerson = false; generation++; inspections.Clear();
            lastCaptureAdmission = lastInputAdmission = null; activeApplication = null;
            status = reason; running = operation;
        }
        // Waits only for a batch already inside the gate; after this no batch can be accepted or settle ownership.
        LocalGate.SetEnabled(false);
        ReleaseOwnedInput();
        hardware.Stop();
        activityPoll?.Change(Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
        Cancel(running);
        if (changed) Raise();
    }

    /// <summary>Clears listed windows and inspections, e.g. when local agent connections change.</summary>
    public void InvalidateListings() { lock (sync) { listings.Clear(); inspections.Clear(); } }

    /// <summary>
    /// Runs every 100 ms while consent is on. Reads only the hardware event count, the last-input tick, the input
    /// desktop state and whether the monitor still owns its registration. Person input voids outstanding tokens and
    /// inspections even when no request is running; a lost monitor turns control off.
    /// </summary>
    internal void PollActivity()
    {
        lock (sync) if (!consent || disposed) return;
        if (!clock.IsInputDesktopActive()) { Disable("Windows switched to a locked or secure screen, so AI control turned off."); return; }
        if (!hardware.IsActive) { Disable("Keyboard and mouse activity monitoring stopped, so AI control turned off."); return; }
        Operation? running = null; bool person = false, unavailable = false, changed = false;
        lock (inputLock)
        {
            lock (sync)
            {
                if (!consent || disposed) return;
                if (!clock.TryReadLastInputTick(out uint tick)) unavailable = true;
                else if (!ObservePerson_locked(tick))
                {
                    changed = !pausedForPerson || operation is not null;
                    running = Interrupt_locked(); person = true;
                }
                else if (pausedForPerson && PersonQuiet_locked()) { pausedForPerson = false; status = OnStatus; changed = true; }
            }
            if (person) ReleaseOwnedInput();
        }
        if (unavailable) { Disable("Windows input activity became unavailable, so AI control turned off."); return; }
        Cancel(running);
        if (changed) Raise();
    }

    public object ListWindows()
    {
        var snapshot = platform.Enumerate()
            .Where(w => !w.IsDisplay && w.AppLaunchTimeIntervalSince1970 is > 0 && !IsExcluded(w))
            .Take(MaximumListedWindows + 1).ToArray();
        lock (sync)
        {
            listings.Clear(); inspections.Clear();
            bool tokens = consent && !disposed && hardware.IsActive;
            long now = time.GetTimestamp();
            var result = new List<object>();
            foreach (var window in snapshot.Take(MaximumListedWindows))
            {
                uint id = checked(++nextWindowId);
                string? token = tokens ? Guid.NewGuid().ToString("D") : null;
                listings[id] = new Listing(window, token, now, generation);
                result.Add(new
                {
                    windowId = id, name = Safe(window.ProcessName ?? "App", 120), title = Safe(window.Title, 256),
                    processId = window.ProcessId, width = window.Bounds.Width, height = window.Bounds.Height, windowToken = token,
                });
            }
            return new { windows = result, truncated = snapshot.Length > MaximumListedWindows, controlReady = tokens };
        }
    }

    /// <summary>The existing presentWindow route: exact listed identity, no token or control consent required.</summary>
    public WindowDescriptor ResolveListedWindow(uint windowId)
    {
        Listing? listing;
        lock (sync) listings.TryGetValue(windowId, out listing);
        if (listing is null) throw new ArgumentException("List current windows before presenting an exact windowId.");
        return platform.TryReadCurrent(listing.Window, allowMinimized: true)
            ?? throw new InvalidOperationException("The advertised app instance changed. Refresh its window list.");
    }

    public async Task<object> InspectAsync(uint windowId, string windowToken, Func<bool> admitted, CancellationToken cancellationToken)
    {
        Listing listing; Operation op;
        RequirePersonIdle();
        lock (inputLock)
        {
            lock (sync)
            {
                RequireReady_locked();
                listing = RequireListing_locked(windowId, windowToken);
                if (operation is not null) throw new LocalAgentException("busy", "Another local agent action is running. Wait for it to finish.");
                if (!Admit_locked(ref lastCaptureAdmission)) throw new LocalAgentException("rate_limited", "Inspections are limited to four per second.");
                op = operation = new Operation(CancellationTokenSource.CreateLinkedTokenSource(cancellationToken), generation);
                activeApplication = listing.Window.ProcessName;
            }
        }
        Raise();
        try
        {
            op.Source.CancelAfter(CaptureDeadline);
            WindowDescriptor current = RequireCurrent(listing.Window);
            WindowBounds bounds = RequireForeground(current);
            LocalCapturedImage image;
            try { image = await capture.CaptureAsync(current, op.Source.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            { throw new LocalAgentException("interrupted", "The capture was stopped, interrupted or exceeded its deadline."); }
            catch (Exception e) when (e is not OperationCanceledException and not LocalAgentException)
            { throw new LocalAgentException("capture_unavailable", "Windows could not capture this window: " + e.Message); }
            RequireUnchanged(op, admitted);
            if (RequireForeground(current) != bounds) throw new LocalAgentException("stale", "The window moved or resized during capture. Inspect again.");
            BoundedJpegEncoder.Result jpeg;
            try { jpeg = await Task.Run(() => BoundedJpegEncoder.Encode(image.Bgra, image.Width, image.Height, image.Stride), op.Source.Token).ConfigureAwait(false); }
            catch (Exception e) when (e is not OperationCanceledException and not LocalAgentException)
            { throw new LocalAgentException("capture_unavailable", "Windows could not encode the window image: " + e.Message); }
            RequireUnchanged(op, admitted);
            string id = Guid.NewGuid().ToString("D");
            lock (sync)
            {
                if (!consent || generation != op.Generation) throw Stopped();
                foreach (var expired in inspections.Where(i => Expired(i.Value.IssuedAt, InspectionLifetime)).Select(i => i.Key).ToArray()) inspections.Remove(expired);
                while (inspections.Count >= MaximumInspections) inspections.Remove(inspections.MinBy(i => i.Value.IssuedAt).Key);
                inspections[id] = new Inspection(windowId, windowToken, bounds, op.Generation, time.GetTimestamp());
            }
            return new
            {
                inspectionId = id, windowId, expiresInSeconds = (int)InspectionLifetime.TotalSeconds,
                mimeType = "image/jpeg", imageBase64 = Convert.ToBase64String(jpeg.Jpeg),
                width = jpeg.Width, height = jpeg.Height, sourceWidth = image.Width, sourceHeight = image.Height,
                visibilityEvidence = "local_foreground_window", contentIsUntrusted = true,
            };
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new LocalAgentException("interrupted", "The inspection was stopped, interrupted or exceeded its deadline.");
        }
        finally { EndOperation(op); }
    }

    public async Task<object> ControlAsync(uint windowId, string windowToken, string inspectionId, LocalControlCommand command,
        Func<bool> admitted, CancellationToken cancellationToken)
    {
        Listing listing; Inspection inspection; Operation op;
        RequirePersonIdle();
        lock (inputLock)
        {
            lock (sync)
            {
                bool found = inspections.Remove(inspectionId, out var taken); // Single use, even when refused below.
                RequireReady_locked();
                listing = RequireListing_locked(windowId, windowToken);
                if (!found || taken!.WindowId != windowId || !string.Equals(taken.WindowToken, windowToken, StringComparison.Ordinal) ||
                    taken.Generation != generation || Expired(taken.IssuedAt, InspectionLifetime))
                    throw new LocalAgentException("inspection_required", "Inspect this exact window again. Inspections are single-use and expire after 10 seconds.");
                inspection = taken!;
                if (operation is not null) throw new LocalAgentException("busy", "Another local agent action is running. Wait for it to finish.");
                if (!Admit_locked(ref lastInputAdmission)) throw new LocalAgentException("rate_limited", "Actions are limited to four per second.");
                op = operation = new Operation(CancellationTokenSource.CreateLinkedTokenSource(cancellationToken), generation);
                activeApplication = listing.Window.ProcessName;
            }
        }
        Raise();
        var progress = new Progress();
        try
        {
            op.Source.CancelAfter(ControlDeadline);
            WindowDescriptor current = RequireCurrent(listing.Window);
            if (RequireForeground(current) != inspection.Bounds)
                throw new LocalAgentException("stale", "The window moved or resized after inspection. Inspect again.");
            await ExecuteAsync(command, current, inspection, op, admitted, progress).ConfigureAwait(false);
            return new
            {
                status = "posted", action = command.Action.ToString().ToLowerInvariant(), windowId, eventsPosted = progress.Posted,
                note = "Posted events do not prove the app handled them. Inspect again to verify; never retry blindly.",
            };
        }
        catch (Exception e) when ((progress.Posted > 0 || progress.MaybePartial) &&
            (e is LocalAgentException || e is OperationCanceledException && !cancellationToken.IsCancellationRequested))
        {
            throw new LocalAgentException("interrupted",
                $"Stopped after {progress.Posted} posted events; the action may be partly applied and was not retried. {e.Message} Inspect again.");
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new LocalAgentException("interrupted", "The action was stopped before any input was posted.");
        }
        finally
        {
            ReleaseOwnedInput();
            EndOperation(op);
        }
    }

    private async Task ExecuteAsync(LocalControlCommand c, WindowDescriptor target, Inspection inspection, Operation op,
        Func<bool> admitted, Progress progress)
    {
        WindowBounds bounds = inspection.Bounds;
        CancellationToken token = op.Source.Token;
        switch (c.Action)
        {
            case LocalControlAction.Click:
                // [move, down, up]: exactly two accepted events leave this feature's button down.
                Send(op, admitted, inspection, target, (c.X, c.Y), null, progress, 3,
                    () => injector.SendPointerButton(bounds, c.X, c.Y, c.Button, MouseButtonAction.Press),
                    accepted => { if (accepted == 2) heldButtons.Add(c.Button); });
                break;
            case LocalControlAction.Type:
                Send(op, admitted, inspection, target, null, null, progress, c.Text.Length * 2, () => injector.SendText(c.Text));
                break;
            case LocalControlAction.Key:
                ushort[] chord = [.. c.Modifiers, c.VirtualKey];
                Send(op, admitted, inspection, target, null, null, progress, chord.Length * 2,
                    () => injector.SendVirtualKeyChord(chord), accepted => heldKeys.UnionWith(ChordKeysHeld(chord, accepted)));
                break;
            case LocalControlAction.Scroll:
                // Scroll where the cursor already rests inside the window; otherwise move it to the centre first.
                (double X, double Y) point = (0.5, 0.5);
                ScreenPoint expected;
                if (platform.TryGetCursorPosition(out var cursor) && Contains(bounds, cursor) && platform.IsTopLevelTargetAt(target, cursor))
                {
                    point = ((cursor.X - bounds.X) / (double)Math.Max(1, bounds.Width - 1), (cursor.Y - bounds.Y) / (double)Math.Max(1, bounds.Height - 1));
                    expected = cursor;
                }
                else
                {
                    Send(op, admitted, inspection, target, point, null, progress, 1, () => injector.MovePointer(bounds, point.X, point.Y));
                    expected = Map(bounds, point);
                    await Task.Delay(StepDelay, time, token).ConfigureAwait(false);
                }
                Send(op, admitted, inspection, target, point, expected, progress, (c.DeltaX != 0 ? 1 : 0) + (c.DeltaY != 0 ? 1 : 0),
                    () => injector.SendMouseWheel(c.DeltaY, c.DeltaX));
                break;
            case LocalControlAction.Drag:
                // [move, down]: the press is owned only once Windows accepted it.
                Send(op, admitted, inspection, target, (c.X, c.Y), null, progress, 2,
                    () => injector.SendPointerButton(bounds, c.X, c.Y, MouseButton.Left, MouseButtonAction.Down),
                    accepted => { if (accepted >= 2) heldButtons.Add(MouseButton.Left); });
                ScreenPoint last = Map(bounds, (c.X, c.Y));
                for (int step = 1; step <= DragSteps; step++)
                {
                    await Task.Delay(StepDelay, time, token).ConfigureAwait(false);
                    double f = (double)step / (DragSteps + 1);
                    (double X, double Y) next = (c.X + (c.ToX - c.X) * f, c.Y + (c.ToY - c.Y) * f);
                    Send(op, admitted, inspection, target, next, last, progress, 1, () => injector.MovePointer(bounds, next.X, next.Y));
                    last = Map(bounds, next);
                }
                await Task.Delay(StepDelay, time, token).ConfigureAwait(false);
                Send(op, admitted, inspection, target, (c.ToX, c.ToY), last, progress, 2,
                    () => injector.SendPointerButton(bounds, c.ToX, c.ToY, MouseButton.Left, MouseButtonAction.Up),
                    accepted => { if (accepted >= 2) heldButtons.Remove(MouseButton.Left); });
                break;
        }
    }

    /// <summary>
    /// One recheck and one SendInput batch. inputLock makes the pair atomic relative to person interruption.
    /// LocalGate makes acceptance, the send and settlement of owned held input one step relative to Disable,
    /// which closes the gate before releasing owned input: a batch the closed gate rejects never becomes owned,
    /// and an accepted batch's presses are recorded before Disable can release them. Ownership follows the
    /// number of events Windows accepted, so partial batches release exactly what they pressed.
    /// </summary>
    private void Send(Operation op, Func<bool> admitted, Inspection inspection, WindowDescriptor target, (double X, double Y)? point,
        ScreenPoint? expectedCursor, Progress progress, int events, Func<InputInjectionResult> batch, Action<int>? settle = null)
    {
        lock (inputLock)
        {
            Guard(op, admitted, inspection, target, point, expectedCursor);
            bool cancelled = false;
            InputInjectionResult result = LocalGate.ExecuteIfEnabled(() =>
            {
                if (op.Source.IsCancellationRequested) { cancelled = true; return InputInjectionResult.Rejected("The action was cancelled."); }
                uint start = clock.CurrentTick;
                InputInjectionResult sent;
                try { sent = batch(); } // The injector re-enters this gate on the same thread.
                finally { lock (sync) { ownInputStart = start; ownInputEnd = unchecked(clock.CurrentTick + OwnInputSettleMilliseconds); } }
                int accepted = sent.Succeeded ? events : Math.Min(events, AcceptedEvents(sent.Error));
                if (settle is not null) lock (sync) settle(accepted);
                progress.Posted += accepted;
                if (!sent.Succeeded && accepted > 0) progress.MaybePartial = true;
                return sent;
            });
            if (cancelled) op.Source.Token.ThrowIfCancellationRequested();
            if (!result.Succeeded) throw new LocalAgentException("input_rejected", result.Error ?? "Windows rejected the input.");
        }
    }

    /// <summary>Events SendInput accepted, from the unchanged injector's "SendInput accepted N of M" report; 0 when nothing was sent.</summary>
    internal static int AcceptedEvents(string? error)
    {
        const string prefix = "SendInput accepted ";
        if (error is null || !error.StartsWith(prefix, StringComparison.Ordinal)) return 0;
        int end = error.IndexOf(' ', prefix.Length);
        return end > prefix.Length && int.TryParse(error.AsSpan(prefix.Length, end - prefix.Length),
            System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out int count) ? count : 0;
    }

    /// <summary>A chord is [down 0..N-1, up N-1..0]; returns the keys still down after <paramref name="accepted"/> events.</summary>
    internal static ushort[] ChordKeysHeld(IReadOnlyList<ushort> chord, int accepted)
    {
        int n = chord.Count;
        int held = accepted <= n ? accepted : Math.Max(0, 2 * n - accepted);
        return chord.Take(Math.Clamp(held, 0, n)).ToArray();
    }

    /// <summary>Runs inside inputLock immediately before every SendInput batch.</summary>
    private void Guard(Operation op, Func<bool> admitted, Inspection inspection, WindowDescriptor target,
        (double X, double Y)? point, ScreenPoint? expectedCursor)
    {
        op.Source.Token.ThrowIfCancellationRequested();
        if (!admitted()) throw new LocalAgentException("interrupted", "Local agent connections were turned off.");
        if (!clock.IsInputDesktopActive()) throw new LocalAgentException("interrupted", "Windows switched to a locked or secure screen.");
        if (!hardware.IsActive) throw new LocalAgentException("monitor_unavailable", "Keyboard and mouse activity monitoring stopped.");
        bool person;
        lock (sync)
        {
            if (!consent || disposed || generation != op.Generation) throw Stopped();
            if (!clock.TryReadLastInputTick(out uint tick)) throw new LocalAgentException("monitor_unavailable", "Windows input activity is unavailable.");
            person = !ObservePerson_locked(tick);
            if (!person && expectedCursor is { } expected &&
                (!platform.TryGetCursorPosition(out var cursor) ||
                 Math.Abs((long)cursor.X - expected.X) > PointerTolerancePixels || Math.Abs((long)cursor.Y - expected.Y) > PointerTolerancePixels))
            {
                lastPersonInputTick = clock.CurrentTick; person = true;
            }
            if (person) _ = Interrupt_locked();
        }
        if (person)
        {
            ReleaseOwnedInput();
            Cancel(op);
            Raise();
            throw new LocalAgentException("interrupted", "Keyboard or mouse use by the person at this PC took priority.");
        }
        if (platform.TryReadCurrent(target, allowMinimized: false) is null)
            throw new LocalAgentException("interrupted", "The window closed or changed identity.");
        var resolved = platform.Resolve(target, WindowInputFocusMode.RequireForeground);
        if (!resolved.Succeeded) throw new LocalAgentException("interrupted", resolved.Error ?? "The window is no longer the foreground target.");
        if (resolved.Bounds != inspection.Bounds) throw new LocalAgentException("interrupted", "The window moved or resized.");
        if (point is { } p && (!NormalizedCoordinateMapper.TryMapToScreen(resolved.Bounds, p.X, p.Y, out var screen) ||
            !platform.IsTopLevelTargetAt(target, screen)))
            throw new LocalAgentException("interrupted", "Another window covers that point.");
    }

    /// <summary>
    /// False when the person (or other software) acted since the last observation. Any newly counted raw input
    /// notification is treated as the person's, whatever its device handle; it is consumed here and never attributed
    /// to the agent, however close to a batch.
    /// A last-input clock change is attributed to the agent only inside its latest batch's settle window.
    /// </summary>
    private bool ObservePerson_locked(uint tick)
    {
        long events = hardware.Events;
        bool hardwareSeen = events != accountedHardwareEvents;
        accountedHardwareEvents = events;
        bool clockOwn = AccountInput_locked(tick);
        if (!hardwareSeen) return clockOwn;
        lastPersonInputTick = clock.CurrentTick;
        return false;
    }

    /// <summary>
    /// Attributes a changed last-input tick to this access's own latest batch when it falls inside that
    /// batch's settle window; anything else is other software (or the person) and returns false.
    /// </summary>
    private bool AccountInput_locked(uint tick)
    {
        if (tick == accountedInputTick) return true;
        accountedInputTick = tick;
        if (unchecked(tick - ownInputStart) <= unchecked(ownInputEnd - ownInputStart)) return true;
        lastPersonInputTick = tick;
        return false;
    }

    private bool PersonQuiet_locked() => unchecked(clock.CurrentTick - lastPersonInputTick) >= HumanQuietMilliseconds;

    /// <summary>Voids tokens, inspections and the running operation; consent stays on.</summary>
    private Operation? Interrupt_locked()
    {
        generation++; inspections.Clear();
        lastCaptureAdmission = lastInputAdmission = null;
        pausedForPerson = true; status = PausedStatus;
        return operation;
    }

    /// <summary>Releases only buttons and keys this access pressed; never input held by the person or a paired device.</summary>
    private void ReleaseOwnedInput()
    {
        MouseButton[] buttons; ushort[] keys;
        lock (sync)
        {
            buttons = heldButtons.ToArray(); keys = heldKeys.ToArray();
            heldButtons.Clear(); heldKeys.Clear();
        }
        if (buttons.Length == 0 && keys.Length == 0) return;
        uint start = clock.CurrentTick;
        // Release bypasses the closed gate by design, matching the remote Host's held-input recovery.
        try { _ = injector.ReleaseHeldInputs(buttons, keys); }
        finally { lock (sync) { ownInputStart = start; ownInputEnd = unchecked(clock.CurrentTick + OwnInputSettleMilliseconds); } }
    }

    private void RequireUnchanged(Operation op, Func<bool> admitted)
    {
        op.Source.Token.ThrowIfCancellationRequested();
        if (!admitted()) throw new LocalAgentException("interrupted", "Local agent connections were turned off.");
        if (!clock.IsInputDesktopActive()) throw new LocalAgentException("interrupted", "Windows switched to a locked or secure screen.");
        bool person;
        lock (sync)
        {
            if (!consent || disposed || generation != op.Generation) throw Stopped();
            person = !hardware.IsActive || !clock.TryReadLastInputTick(out uint tick) || !ObservePerson_locked(tick);
            if (person) _ = Interrupt_locked();
        }
        if (person)
        {
            Cancel(op); Raise();
            throw new LocalAgentException("interrupted", "Keyboard or mouse use by the person at this PC took priority.");
        }
    }

    private WindowDescriptor RequireCurrent(WindowDescriptor listed)
    {
        var current = platform.TryReadCurrent(listed, allowMinimized: false);
        if (current is null || IsExcluded(current)) throw new LocalAgentException("stale", "The listed app window closed, was minimized or changed. List windows again.");
        return current;
    }

    private WindowBounds RequireForeground(WindowDescriptor current)
    {
        if (!clock.IsInputDesktopActive()) throw new LocalAgentException("target_unavailable", "Windows is showing a locked or secure screen.");
        var result = platform.Resolve(current, WindowInputFocusMode.RequireForeground);
        if (!result.Succeeded) throw new LocalAgentException("target_unavailable", (result.Error ?? "The window cannot be used.") + " Present it first, then inspect.");
        return result.Bounds;
    }

    private void RequireReady_locked()
    {
        if (disposed) throw new LocalAgentException("unavailable", "Peel Pro is closing.");
        if (!consent) throw new LocalAgentException("consent_required", "Turn on \"Allow AI to see and use apps on this PC\" in Peel Pro. Agents cannot turn it on.");
    }

    /// <summary>Admission: new person input voids outstanding authority first; recent person input defers the agent.</summary>
    private void RequirePersonIdle()
    {
        Operation? interrupted = null; bool person = false, unavailable = false, recent = false;
        lock (inputLock)
        {
            lock (sync)
            {
                RequireReady_locked();
                if (!hardware.IsActive || !clock.TryReadLastInputTick(out uint tick)) unavailable = true;
                else if (!ObservePerson_locked(tick)) { interrupted = Interrupt_locked(); person = true; }
                else recent = !PersonQuiet_locked();
            }
            if (person) ReleaseOwnedInput();
        }
        if (unavailable) throw new LocalAgentException("monitor_unavailable", "Keyboard and mouse activity monitoring is unavailable, so AI control is paused.");
        if (person)
        {
            Cancel(interrupted); Raise();
            throw new LocalAgentException("person_active", "The person at this PC is using the keyboard or mouse. Wait until they stop, then list and inspect again.");
        }
        if (recent) throw new LocalAgentException("person_active", "The person at this PC used the keyboard or mouse in the last second. Wait, then try again.");
    }

    private Listing RequireListing_locked(uint windowId, string token)
    {
        if (!listings.TryGetValue(windowId, out var listing) || listing.Token is null ||
            !string.Equals(listing.Token, token, StringComparison.Ordinal) || listing.Generation != generation ||
            Expired(listing.IssuedAt, WindowTokenLifetime))
            throw new LocalAgentException("window_token_expired", "List windows again and use that exact windowId and windowToken. Tokens expire after 30 seconds or when the person uses the keyboard or mouse.");
        return listing;
    }

    private bool Admit_locked(ref long? last)
    {
        long now = time.GetTimestamp();
        if (last is { } previous && time.GetElapsedTime(previous, now) < AdmissionInterval) return false;
        last = now; return true;
    }

    private bool Expired(long issuedAt, TimeSpan lifetime) => time.GetElapsedTime(issuedAt) > lifetime;

    private void EndOperation(Operation op)
    {
        lock (sync) if (ReferenceEquals(operation, op)) { operation = null; activeApplication = null; }
        op.Source.Dispose();
        Raise();
    }

    private static void Cancel(Operation? op)
    {
        try { op?.Source.Cancel(); }
        catch (ObjectDisposedException) { } // Already finished.
    }

    private static ScreenPoint Map(WindowBounds bounds, (double X, double Y) point) =>
        NormalizedCoordinateMapper.TryMapToScreen(bounds, point.X, point.Y, out var screen) ? screen
            : throw new LocalAgentException("interrupted", "The window has unusable bounds.");

    private static bool Contains(WindowBounds bounds, ScreenPoint point) =>
        point.X >= bounds.X && point.Y >= bounds.Y && point.X < (long)bounds.X + bounds.Width && point.Y < (long)bounds.Y + bounds.Height;

    internal static bool IsExcluded(WindowDescriptor window) =>
        ExcludedProcesses.Contains(window.ProcessName ?? "") || ExcludedClasses.Contains(window.ClassName);

    private static LocalAgentException Stopped() => new("interrupted", "AI control was turned off, stopped or paused for the person at this PC.");

    private static string Safe(string text, int count) => new(text.Take(count).Select(c => c < 32 || c == 127 ? ' ' : c).ToArray());

    private void Raise() => Changed?.Invoke(this, EventArgs.Empty);

    public void Dispose()
    {
        lock (sync) if (disposed) return;
        Disable("Off");
        lock (sync) disposed = true;
        activityPoll?.Dispose();
    }
}
