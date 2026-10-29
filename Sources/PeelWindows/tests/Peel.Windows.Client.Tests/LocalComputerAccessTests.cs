using System.Collections.Concurrent;
using System.IO.Pipes;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Windows.Threading;
using Peel.Windows.Client.Models;
using Peel.Windows.Client.Services;
using Peel.Windows.Discovery;
using Peel.Windows.Host.Input;
using Peel.Windows.Host.Windows;
using Peel.Windows.Protocol;
using Peel.Windows.Transport;

namespace Peel.Windows.Client.Tests;

// Production LocalComputerAccess, LocalControlCommand, BoundedJpegEncoder, InputPermissionGate and LocalAgentBridge
// run unchanged here. Only the OS boundary (window platform, capture, input clock, raw input, SendInput) is faked.
// "Person input" is a hardware event plus a last-input tick; "external input" is another program's SendInput,
// which moves only the last-input tick.
internal static partial class Program
{
    private static readonly WindowBounds LocalFixtureBounds = new(100, 100, 800, 600);

    private static async Task LocalComputerConsentAndTokensAsync()
    {
        var f = new LocalFixture();
        var listed = JsonSerializer.SerializeToElement(f.Access.ListWindows());
        True(!listed.GetProperty("controlReady").GetBoolean(), "Control must not be advertised before consent.");
        Equal(JsonValueKind.Null, listed.GetProperty("windows")[0].GetProperty("windowToken").ValueKind);
        Equal("consent_required", await CodeAsync(() => f.Access.InspectAsync(1, "guess", () => true, CancellationToken.None)));
        True(!f.Access.Enable(false, out _), "Consent requires local agent connections.");
        True(!f.Access.LocalGate.IsEnabled, "A refused enable leaves the local gate closed.");
        True(f.Access.Enable(true, out _), "The UI can enable consent.");
        True(f.Access.LocalGate.IsEnabled && f.Access.ControlReady, "Consent opens only the dedicated local gate.");
        var (id, token) = f.List();
        Equal("person_active", await CodeAsync(() => f.Access.InspectAsync(id, token, () => true, CancellationToken.None)));
        f.Wait(1001);
        Equal("window_token_expired", await CodeAsync(() => f.Access.InspectAsync(id, Guid.NewGuid().ToString("D"), () => true, CancellationToken.None)));
        var inspection = await f.InspectAsync(id, token);
        byte[] jpeg = Convert.FromBase64String(inspection.GetProperty("imageBase64").GetString()!);
        True(jpeg.Length is > 3 and <= BoundedJpegEncoder.MaximumBytes && jpeg[0] == 0xFF && jpeg[1] == 0xD8 && jpeg[2] == 0xFF, "Inspection returns one bounded JPEG.");
        True(inspection.GetProperty("contentIsUntrusted").GetBoolean(), "Captured content is labeled untrusted.");
        // The bridge's admission is rechecked after the capture await: a revoked connection gets no image.
        f.Wait(300);
        Equal("interrupted", await CodeAsync(() => f.Access.InspectAsync(id, token, () => false, CancellationToken.None)));
        f.Access.Disable("Off");
        f.Wait(300);
        Equal("consent_required", await CodeAsync(() => f.Access.InspectAsync(id, token, () => true, CancellationToken.None)));
        True(!f.Access.LocalGate.IsEnabled, "Turning consent off closes the local gate.");
        Equal(0, f.Injector.Batches.Count);
    }

    private static async Task LocalComputerHumanInputVoidsAuthorityAsync()
    {
        var f = new LocalFixture(); f.EnableQuiet();
        var (id, token) = f.List();
        var inspection = await f.InspectAsync(id, token);
        string inspectionId = inspection.GetProperty("inspectionId").GetString()!;
        long generation = f.Access.Generation;
        // The person moves the mouse between requests; no agent request is running.
        f.PersonInput();
        f.Access.PollActivity();
        True(f.Access.Generation > generation, "Person input between requests advances the generation.");
        True(f.Access.IsEnabled, "Person input pauses rather than revokes consent.");
        Equal("person_active", await CodeAsync(() => f.ControlAsync(id, token, inspectionId, "{\"action\":\"type\",\"text\":\"hi\"}")));
        f.Wait(1001);
        Equal("window_token_expired", await CodeAsync(() => f.ControlAsync(id, token, inspectionId, "{\"action\":\"type\",\"text\":\"hi\"}")));
        Equal(0, f.Injector.Batches.Count);

        // Without a poll, the admission itself notices the person and voids the fresh inspection.
        (id, token) = f.List();
        inspectionId = (await f.InspectAsync(id, token)).GetProperty("inspectionId").GetString()!;
        f.PersonInput();
        Equal("person_active", await CodeAsync(() => f.ControlAsync(id, token, inspectionId, "{\"action\":\"type\",\"text\":\"hi\"}")));
        f.Wait(1001);
        (id, token) = f.List();
        Equal("inspection_required", await CodeAsync(() => f.ControlAsync(id, token, inspectionId, "{\"action\":\"type\",\"text\":\"hi\"}")));
        Equal(0, f.Injector.Batches.Count);
    }

    private static async Task LocalComputerOwnInputIsAccountedAsync()
    {
        var f = new LocalFixture(); f.EnableQuiet();
        // Windows stamps the last-input tick for injected events slightly after SendInput returns.
        f.Injector.OnBatch = () => f.Clock.StampLater(20);
        var (id, token) = f.List();
        string inspectionId = (await f.InspectAsync(id, token)).GetProperty("inspectionId").GetString()!;
        var result = await f.ControlAsync(id, token, inspectionId, "{\"action\":\"type\",\"text\":\"héllo\"}");
        Equal("posted", result.GetProperty("status").GetString());
        long generation = f.Access.Generation;
        f.Clock.Advance(30); f.Clock.ApplyStamp();
        f.Access.PollActivity();
        Equal(generation, f.Access.Generation);
        f.Clock.Advance(500); f.ExternalInput();
        f.Access.PollActivity();
        True(f.Access.Generation > generation, "Other software's input after the settle window interrupts like a person's.");
    }

    private static async Task LocalComputerIdentityReuseIsRefusedAsync()
    {
        var f = new LocalFixture(); f.EnableQuiet();
        var (id, token) = f.List();
        string inspectionId = (await f.InspectAsync(id, token)).GetProperty("inspectionId").GetString()!;
        f.Platform.Bounds = LocalFixtureBounds with { X = 140 };
        Equal("stale", await CodeAsync(() => f.ControlAsync(id, token, inspectionId, "{\"action\":\"click\",\"x\":0.5,\"y\":0.5}")));
        f.Platform.Bounds = LocalFixtureBounds;
        f.Wait(300);
        inspectionId = (await f.InspectAsync(id, token)).GetProperty("inspectionId").GetString()!;
        f.Platform.ProcessId = 9999; // Same HWND, new process instance.
        f.Wait(300);
        Equal("stale", await CodeAsync(() => f.ControlAsync(id, token, inspectionId, "{\"action\":\"click\",\"x\":0.5,\"y\":0.5}")));
        f.Platform.ProcessId = LocalFixture.Pid;
        f.Access.Disable("Stopped");
        True(f.Access.Enable(true, out _), "Re-enable.");
        f.Wait(1001);
        Equal("window_token_expired", await CodeAsync(() => f.Access.InspectAsync(id, token, () => true, CancellationToken.None)));
        Equal(0, f.Injector.Batches.Count);
    }

    private static async Task LocalComputerInspectionsExpireAndAreSingleUseAsync()
    {
        var f = new LocalFixture(); f.EnableQuiet();
        var (id, token) = f.List();
        string inspectionId = (await f.InspectAsync(id, token)).GetProperty("inspectionId").GetString()!;
        f.Wait(11_000);
        Equal("inspection_required", await CodeAsync(() => f.ControlAsync(id, token, inspectionId, "{\"action\":\"key\",\"key\":\"enter\"}")));
        inspectionId = (await f.InspectAsync(id, token)).GetProperty("inspectionId").GetString()!;
        f.Wait(300);
        Equal("posted", (await f.ControlAsync(id, token, inspectionId, "{\"action\":\"key\",\"key\":\"c\",\"modifiers\":[\"command\"]}")).GetProperty("status").GetString());
        SequenceEqual(new ushort[] { 0x11, 0x43 }, f.Injector.Batches.Single().Keys);
        f.Wait(300);
        Equal("inspection_required", await CodeAsync(() => f.ControlAsync(id, token, inspectionId, "{\"action\":\"key\",\"key\":\"enter\"}")));
        Equal("inspection_required", await CodeAsync(() => f.ControlAsync(id, token, Guid.NewGuid().ToString("D"), "{\"action\":\"key\",\"key\":\"enter\"}")));
        f.Wait(31_000);
        Equal("window_token_expired", await CodeAsync(() => f.Access.InspectAsync(id, token, () => true, CancellationToken.None)));
        Equal(1, f.Injector.Batches.Count);
    }

    private static async Task LocalComputerRefusesProtectedTargetsAsync()
    {
        var f = new LocalFixture(); f.EnableQuiet();
        var (id, token) = f.List();
        f.Platform.ResolveError = "The selected window belongs to a higher-integrity process. Windows integrity-level isolation (UIPI) blocks remote input.";
        Equal("target_unavailable", await CodeAsync(() => f.Access.InspectAsync(id, token, () => true, CancellationToken.None)));
        Equal(0, f.Capture.Captures);
        f.Platform.ResolveError = null;
        f.Wait(300);
        string inspectionId = (await f.InspectAsync(id, token)).GetProperty("inspectionId").GetString()!;
        f.Platform.Covered = true;
        f.Wait(300);
        Equal("interrupted", await CodeAsync(() => f.ControlAsync(id, token, inspectionId, "{\"action\":\"click\",\"x\":0.2,\"y\":0.2}")));
        f.Platform.Covered = false;
        f.DesktopActive(false);
        f.Access.PollActivity();
        True(!f.Access.IsEnabled && !f.Access.LocalGate.IsEnabled, "A locked or secure desktop turns local control off.");
        Equal(0, f.Injector.Batches.Count);
        // Secure and credential processes are never listed.
        var secure = new LocalFixture(processName: "consent");
        Equal(0, JsonSerializer.SerializeToElement(secure.Access.ListWindows()).GetProperty("windows").GetArrayLength());
    }

    private static async Task LocalComputerCancellationReleasesOwnedInputAsync()
    {
        // Stop during a drag: the button this access pressed is released exactly once, nothing else.
        var f = new LocalFixture(); f.EnableQuiet();
        var (id, token) = f.List();
        string inspectionId = (await f.InspectAsync(id, token)).GetProperty("inspectionId").GetString()!;
        int moves = 0;
        f.Injector.OnBatch = () => { if (f.Injector.Batches.Last().Kind == "move" && ++moves == 3) f.Access.Disable("Stopped"); };
        f.Wait(300);
        string code = await CodeAsync(() => f.ControlAsync(id, token, inspectionId, "{\"action\":\"drag\",\"x\":0.1,\"y\":0.1,\"toX\":0.9,\"toY\":0.9}"));
        Equal("interrupted", code);
        Equal(1, f.Injector.Releases.Count);
        SequenceEqual(new[] { MouseButton.Left }, f.Injector.Releases.Single().Buttons);
        Equal(0, f.Injector.Releases.Single().Keys.Length);
        True(!f.Injector.Batches.Any(b => b.Kind == "up"), "No release batch is replayed after Stop.");
        True(!f.Access.LocalGate.IsEnabled, "Stop closes the local gate.");

        // The person moving the pointer during a drag interrupts it the same way.
        var g = new LocalFixture(); g.EnableQuiet();
        (id, token) = g.List();
        inspectionId = (await g.InspectAsync(id, token)).GetProperty("inspectionId").GetString()!;
        g.Injector.OnBatch = () => { if (g.Injector.Batches.Count == 2) g.Platform.CursorOverride = new ScreenPoint(5, 5); };
        g.Wait(300);
        Equal("interrupted", await CodeAsync(() => g.ControlAsync(id, token, inspectionId, "{\"action\":\"drag\",\"x\":0.1,\"y\":0.1,\"toX\":0.9,\"toY\":0.9}")));
        SequenceEqual(new[] { MouseButton.Left }, g.Injector.Releases.Single().Buttons);
        True(g.Access.IsEnabled, "Person input pauses; it does not revoke consent.");
        Equal(2, g.Injector.Batches.Count);
    }

    /// <summary>
    /// Reviewer P1 regression: own batch, then a person's key 50 ms later inside the batch's own-input clock window.
    /// The clock tick is attributed to the batch, but the hardware event is not, so authority is voided and stays voided.
    /// </summary>
    private static async Task LocalComputerPersonInsideOwnWindowIsNeverAbsorbedAsync()
    {
        var f = new LocalFixture(); f.EnableQuiet();
        f.Injector.OnBatch = () => f.Clock.StampLater(1);
        var (id, token) = f.List();
        string inspectionId = (await f.InspectAsync(id, token)).GetProperty("inspectionId").GetString()!;
        Equal("posted", (await f.ControlAsync(id, token, inspectionId, "{\"action\":\"type\",\"text\":\"ok\"}")).GetProperty("status").GetString());
        f.Clock.ApplyStamp();
        long generation = f.Access.Generation;
        f.Clock.Advance(50); f.PersonInput();          // inside the 100 ms own-input window
        f.Clock.Advance(10); f.Access.PollActivity();   // poll at +60 ms
        True(f.Access.Generation > generation, "A person's key inside the agent's own-input window voids authority.");
        long voided = f.Access.Generation;
        f.Clock.Advance(140); f.Access.PollActivity();  // +200 ms: nothing new, nothing reconsidered away
        Equal(voided, f.Access.Generation);
        Equal("person_active", await CodeAsync(() => f.Access.InspectAsync(id, token, () => true, CancellationToken.None)));
        f.Wait(1001);
        Equal("window_token_expired", await CodeAsync(() => f.Access.InspectAsync(id, token, () => true, CancellationToken.None)));
        Equal(1, f.Injector.Batches.Count);
    }

    /// <summary>Keyboard-only person input during a drag (no cursor drift) stops the drag and releases only its press.</summary>
    private static async Task LocalComputerKeyboardDuringDragInterruptsAsync()
    {
        var f = new LocalFixture(); f.EnableQuiet();
        var (id, token) = f.List();
        string inspectionId = (await f.InspectAsync(id, token)).GetProperty("inspectionId").GetString()!;
        f.Injector.OnBatch = () => { if (f.Injector.Batches.Count == 3) f.Hardware.Bump(); }; // a key press; the pointer is untouched
        f.Wait(300);
        Equal("interrupted", await CodeAsync(() => f.ControlAsync(id, token, inspectionId, "{\"action\":\"drag\",\"x\":0.1,\"y\":0.1,\"toX\":0.9,\"toY\":0.9}")));
        Equal(3, f.Injector.Batches.Count);
        SequenceEqual(new[] { MouseButton.Left }, f.Injector.Releases.Single().Buttons);
        True(f.Access.IsEnabled, "Person input pauses; it does not revoke consent.");
    }

    /// <summary>Control never starts without an owned hardware activity source, and stops when ownership is lost.</summary>
    private static async Task LocalComputerRequiresOwnedActivityMonitorAsync()
    {
        var f = new LocalFixture();
        f.Hardware.Available = false;
        True(!f.Access.Enable(true, out string? error) && error is not null, "No raw input registration means no consent.");
        True(!f.Access.IsEnabled && !f.Access.LocalGate.IsEnabled && !f.Access.ControlReady, "Nothing opens without the monitor.");
        f.Hardware.Available = true; f.EnableQuiet();
        var (id, token) = f.List();
        f.Hardware.Lost = true; // Another registration owner took the device class, or the monitor thread died.
        Equal("monitor_unavailable", await CodeAsync(() => f.Access.InspectAsync(id, token, () => true, CancellationToken.None)));
        True(!f.Access.ControlReady, "Lost monitoring is never advertised as control.");
        f.Access.PollActivity();
        True(!f.Access.IsEnabled && !f.Access.LocalGate.IsEnabled && f.Hardware.Stops == 1, "Lost monitoring turns control off.");
        Equal(0, f.Injector.Batches.Count);
    }

    /// <summary>
    /// Reviewer P2 regression: Stop arrives from another thread after the last recheck but before the gated send.
    /// Stop must not wait for the paused input path, the closed gate rejects the batch, and nothing the batch never
    /// pressed is released. An already accepted drag press is still released exactly once.
    /// </summary>
    private static async Task LocalComputerStopBeforeGatedSendReleasesNothingAsync()
    {
        var f = new LocalFixture(); f.EnableQuiet();
        var (id, token) = f.List();
        string inspectionId = (await f.InspectAsync(id, token)).GetProperty("inspectionId").GetString()!;
        using (var atRecheck = new ManualResetEventSlim())
        using (var resume = new ManualResetEventSlim())
        {
            f.Platform.BeforeHitTest = () => { atRecheck.Set(); resume.Wait(TimeSpan.FromSeconds(5)); };
            f.Wait(300);
            var click = Task.Run(() => f.ControlAsync(id, token, inspectionId, "{\"action\":\"click\",\"x\":0.5,\"y\":0.5}"));
            True(atRecheck.Wait(TimeSpan.FromSeconds(5)), "The click reached its last recheck.");
            True(Task.Run(() => f.Access.Disable("Stopped")).Wait(TimeSpan.FromSeconds(2)), "Stop never waits on the paused input path.");
            resume.Set();
            Equal("input_rejected", await CodeAsync(() => click));
        }
        Equal(0, f.Injector.Snapshot().Length);
        Equal(0, f.Injector.ReleaseSnapshot().Length);

        var g = new LocalFixture(); g.EnableQuiet();
        (id, token) = g.List();
        inspectionId = (await g.InspectAsync(id, token)).GetProperty("inspectionId").GetString()!;
        using (var atRecheck = new ManualResetEventSlim())
        using (var resume = new ManualResetEventSlim())
        {
            int rechecks = 0;
            g.Platform.BeforeHitTest = () => { if (++rechecks == 4) { atRecheck.Set(); resume.Wait(TimeSpan.FromSeconds(5)); } };
            g.Wait(300);
            var drag = Task.Run(() => g.ControlAsync(id, token, inspectionId, "{\"action\":\"drag\",\"x\":0.1,\"y\":0.1,\"toX\":0.9,\"toY\":0.9}"));
            True(atRecheck.Wait(TimeSpan.FromSeconds(5)), "The drag paused before its third move.");
            True(Task.Run(() => g.Access.Disable("Stopped")).Wait(TimeSpan.FromSeconds(2)), "Stop never waits on the paused input path.");
            SequenceEqual(new[] { MouseButton.Left }, g.Injector.ReleaseSnapshot().Single().Buttons);
            resume.Set();
            Equal("interrupted", await CodeAsync(() => drag));
        }
        SequenceEqual(new[] { "down", "move", "move" }, g.Injector.Snapshot().Select(b => b.Kind));
        Equal(1, g.Injector.ReleaseSnapshot().Length);
    }

    /// <summary>Ownership follows what Windows accepted: partial batches release exactly their own presses.</summary>
    private static async Task LocalComputerPartialSendReleasesExactlyItsPressesAsync()
    {
        Equal(2, LocalComputerAccess.AcceptedEvents("SendInput accepted 2 of 3 events (Access is denied.). The target may be blocked by Windows integrity-level isolation (UIPI)."));
        Equal(0, LocalComputerAccess.AcceptedEvents(InputPermissionGate.DisabledReason));
        Equal(0, LocalComputerAccess.AcceptedEvents("Pointer coordinates or target window bounds are invalid."));
        SequenceEqual(new ushort[] { 0x11 }, LocalComputerAccess.ChordKeysHeld([0x11, 0x43], 3));
        SequenceEqual(new ushort[] { 0x11, 0x43 }, LocalComputerAccess.ChordKeysHeld([0x11, 0x43], 2));
        Equal(0, LocalComputerAccess.ChordKeysHeld([0x11, 0x43], 4).Length);

        var f = new LocalFixture(); f.EnableQuiet();
        var (id, token) = f.List();
        // Move and down accepted, up refused: the right button is down and is released exactly once.
        f.Injector.Result = kind => kind == "click" ? InputInjectionResult.Rejected("SendInput accepted 2 of 3 events (fixture). The target may be blocked by Windows integrity-level isolation (UIPI).") : null;
        string inspectionId = (await f.InspectAsync(id, token)).GetProperty("inspectionId").GetString()!;
        Equal("interrupted", await CodeAsync(() => f.ControlAsync(id, token, inspectionId, "{\"action\":\"click\",\"x\":0.5,\"y\":0.5,\"button\":\"right\"}")));
        SequenceEqual(new[] { MouseButton.Right }, f.Injector.ReleaseSnapshot().Single().Buttons);
        // Nothing accepted: nothing released, so a modifier the person holds is never lifted.
        f.Injector.Result = kind => kind == "chord" ? InputInjectionResult.Rejected("SendInput accepted 0 of 4 events (fixture). The target may be blocked by Windows integrity-level isolation (UIPI).") : null;
        f.Wait(300);
        inspectionId = (await f.InspectAsync(id, token)).GetProperty("inspectionId").GetString()!;
        Equal("input_rejected", await CodeAsync(() => f.ControlAsync(id, token, inspectionId, "{\"action\":\"key\",\"key\":\"c\",\"modifiers\":[\"command\"]}")));
        Equal(1, f.Injector.ReleaseSnapshot().Length);
        // Ctrl down, C down, C up accepted: only Ctrl is still down and only Ctrl is released.
        f.Injector.Result = kind => kind == "chord" ? InputInjectionResult.Rejected("SendInput accepted 3 of 4 events (fixture). The target may be blocked by Windows integrity-level isolation (UIPI).") : null;
        f.Wait(300);
        inspectionId = (await f.InspectAsync(id, token)).GetProperty("inspectionId").GetString()!;
        Equal("interrupted", await CodeAsync(() => f.ControlAsync(id, token, inspectionId, "{\"action\":\"key\",\"key\":\"c\",\"modifiers\":[\"command\"]}")));
        var last = f.Injector.ReleaseSnapshot();
        Equal(2, last.Length);
        SequenceEqual(new ushort[] { 0x11 }, last[1].Keys); Equal(0, last[1].Buttons.Length);
    }

    /// <summary>Pipe policy: the owner CurrentUserOnly clients verify, access for this user only, and no owner WRITE_DAC.</summary>
    private static void LocalAgentPipeSecurityStaysCurrentUser()
    {
        const string user = "S-1-5-21-1000-2000-3000-1001", administrators = "S-1-5-32-544";
        foreach (string owner in new[] { user, administrators })
        {
            string sddl = LocalAgentBridge.PipeSecurityDescriptor(user, owner);
            True(sddl.StartsWith("O:" + owner + "D:P", StringComparison.Ordinal), "Owner is the token default owner; the DACL is protected.");
            string[] aces = sddl[(sddl.IndexOf("D:P", StringComparison.Ordinal) + 3)..].Trim('(', ')').Split(")(");
            SequenceEqual(new[] { "A;;GA;;;" + user, "A;;RC;;;OW" }, aces);
        }
    }

    /// <summary>
    /// Reviewer P1: the production header classification counts every complete WM_INPUT header whatever its device
    /// handle, and counts plus faults on a failed, short or unrecognised read. No payload exists to read.
    /// </summary>
    private static void RawInputHeadersCountWhateverTheDevice()
    {
        var counter = new RawInputActivityCounter();
        uint size = RawInputActivityCounter.HeaderSize;
        counter.Observe(size, RawHeader(0, 0));      // precision touchpad: mouse header, zero device handle
        counter.Observe(size, RawHeader(1, 0));      // keyboard header, zero device handle
        counter.Observe(size, RawHeader(2, 0));      // HID (pen/touch) header, zero device handle
        counter.Observe(size, RawHeader(0, 0x51));   // mouse header naming a device
        True(counter.Events == 4 && !counter.Faulted, "Every complete header counts; a zero device handle is never discarded.");
        foreach (var (read, header) in new (uint, RawInputHeader)[]
        {
            (uint.MaxValue, RawHeader(1, 0x51)),                    // GetRawInputData failed
            (0, RawHeader(1, 0x51)),                                // nothing copied
            (size - 1, RawHeader(1, 0x51)),                         // short header
            (size, RawHeader(1, 0x51) with { Size = size - 1 }),    // impossible packet size
            (size, RawHeader(7, 0x51)),                             // unrecognised type
        })
        {
            counter.Rearm();
            long before = counter.Events;
            counter.Observe(read, header);
            True(counter.Events == before + 1 && counter.Faulted, "An unreadable header counts as activity and faults the monitor.");
        }
        counter.Rearm();
        True(!counter.Faulted && counter.Events == 9, "A fresh registration starts unfaulted; the count stays monotonic.");
    }

    /// <summary>
    /// Reviewer P2: the exact GetRegisteredRawInputDevices boundary. A failed size query, a failed, short or impossible
    /// fill and an implausible count are unknown (null), never "no registrations"; unknown refuses registration,
    /// removes nothing and is never ownership.
    /// </summary>
    private static void RawInputRegistrationUnknownIsNotEmpty()
    {
        const nint ours = 0x1000, other = 0x2000;
        RawInputDevice Device(ushort page, ushort usage, nint target) => new() { UsagePage = page, Usage = usage, Target = target };
        RawInputDevice[] none = [];
        RawInputDevice[] mine = [Device(1, 2, ours), Device(1, 6, ours), Device(0x0D, 2, other)];
        (ushort, ushort)[] owned = [(1, 2), (1, 6), (0x0D, 2)];
        RawInputDevice[]? Read(params (uint, uint, int, RawInputDevice[])[] script) =>
            Win32RawInputActivityMonitor.ReadRegistrations(new FixtureRegistrationQuery(script).Query);

        var initialFailure = new FixtureRegistrationQuery([(uint.MaxValue, 0, 5, none)]);
        True(Win32RawInputActivityMonitor.ReadRegistrations(initialFailure.Query) is null && initialFailure.Fills == 0, "A failed size query is unknown and nothing is filled.");
        True(Read((uint.MaxValue, 0, 122, none)) is null, "Insufficient buffer with no count is unknown.");
        True(Read((0, 1000, 0, none)) is null, "An implausible count is unknown.");
        True(Read((0, 2, 0, none), (uint.MaxValue, 2, 5, none)) is null, "A failed fill is unknown.");
        True(Read((0, 3, 0, none), (2, 3, 0, mine)) is null, "A short fill is unknown.");
        True(Read((0, 2, 0, none), (3, 3, 0, mine)) is null, "A fill larger than the buffer is unknown.");
        True(Read((uint.MaxValue, 3, 122, none), (uint.MaxValue, 4, 122, none)) is null, "A list that keeps growing is unknown after three attempts.");
        Equal(0, Read((0, 0, 0, none))!.Length);
        Equal(3, Read((uint.MaxValue, 3, 122, none), (3, 3, 0, mine))!.Length);
        Equal(3, Read((0, 2, 0, none), (uint.MaxValue, 3, 122, none), (0, 3, 0, none), (3, 3, 0, mine))!.Length);

        True(Win32RawInputActivityMonitor.RegistrationRefusal(null) is not null, "Unknown ownership refuses registration.");
        True(Win32RawInputActivityMonitor.RegistrationRefusal(none) is null, "Known-empty registrations may be taken.");
        True(Win32RawInputActivityMonitor.RegistrationRefusal([Device(1, 6, other)]) is not null, "An existing keyboard owner is never replaced.");
        True(Win32RawInputActivityMonitor.RegistrationRefusal([Device(0x0D, 4, other)]) is null, "Optional classes do not block the required ones.");
        Equal(0, Win32RawInputActivityMonitor.RemovableRegistrations(null, owned, ours).Length);
        SequenceEqual(new (ushort, ushort)[] { (1, 2), (1, 6) }, Win32RawInputActivityMonitor.RemovableRegistrations(mine, owned, ours));
        True(!Win32RawInputActivityMonitor.OwnsRequired(null, ours), "Unknown registrations are never ownership.");
        True(Win32RawInputActivityMonitor.OwnsRequired(mine, ours) && !Win32RawInputActivityMonitor.OwnsRequired(mine, other), "Ownership needs both required classes on this window.");
        True(!Win32RawInputActivityMonitor.OwnsRequired([Device(1, 2, ours)], ours), "Losing one required class is not ownership.");
    }

    /// <summary>
    /// Reviewer P1 regression through production LocalComputerAccess: own batch, then a person's touchpad motion whose
    /// header has a zero device handle 50 ms later, inside the batch's own-input clock window. It voids authority.
    /// The same clock change without a raw input header is the declared boundary: it stays attributed to the batch.
    /// </summary>
    private static async Task LocalComputerZeroDeviceInsideOwnWindowVoidsAuthorityAsync()
    {
        var f = new LocalFixture(); f.EnableQuiet();
        f.Injector.OnBatch = () => f.Clock.StampLater(1);
        var (id, token) = f.List();
        string inspectionId = (await f.InspectAsync(id, token)).GetProperty("inspectionId").GetString()!;
        Equal("posted", (await f.ControlAsync(id, token, inspectionId, "{\"action\":\"type\",\"text\":\"ok\"}")).GetProperty("status").GetString());
        f.Clock.ApplyStamp();
        long generation = f.Access.Generation;
        f.Clock.Advance(50); f.ExternalInput();           // clock only, inside the 100 ms window
        f.Clock.Advance(10); f.Access.PollActivity();
        Equal(generation, f.Access.Generation);            // declared boundary: clock-only input in the window is not detected

        f.Wait(300);
        (id, token) = f.List();
        inspectionId = (await f.InspectAsync(id, token)).GetProperty("inspectionId").GetString()!;
        f.Wait(300);
        Equal("posted", (await f.ControlAsync(id, token, inspectionId, "{\"action\":\"type\",\"text\":\"ok\"}")).GetProperty("status").GetString());
        f.Clock.ApplyStamp();
        generation = f.Access.Generation;
        f.Clock.Advance(50);
        f.Hardware.Header(RawHeader(0, 0)); f.Clock.PersonInput();   // precision touchpad: hDevice 0, tick inside the window
        f.Clock.Advance(10); f.Access.PollActivity();
        True(f.Access.Generation > generation, "Zero-device raw input inside the own-input window voids authority.");
        Equal("person_active", await CodeAsync(() => f.Access.InspectAsync(id, token, () => true, CancellationToken.None)));
        f.Wait(1001);
        Equal("window_token_expired", await CodeAsync(() => f.Access.InspectAsync(id, token, () => true, CancellationToken.None)));
        True(f.Access.IsEnabled, "Person input pauses rather than revokes consent.");

        // An unreadable header is never preserved as authority: the monitor retires and control turns off.
        f.Access.Disable("Stopped"); True(f.Access.Enable(true, out _), "Re-enable."); f.Wait(1001);
        (id, token) = f.List();
        f.Hardware.Header(RawHeader(1, 0x51), read: uint.MaxValue);
        True(!f.Access.ControlReady, "An unreadable header makes control unavailable at once.");
        Equal("monitor_unavailable", await CodeAsync(() => f.Access.InspectAsync(id, token, () => true, CancellationToken.None)));
        f.Access.PollActivity();
        True(!f.Access.IsEnabled && !f.Access.LocalGate.IsEnabled, "An unreadable header turns local control off.");
        Equal(2, f.Injector.Batches.Count);
    }

    /// <summary>
    /// Where Windows reports this feature's own SendInput as raw input (hDevice 0), nothing attributes it away: the drag
    /// interrupts itself after its first batch and releases only its own press. Fail closed, never authority.
    /// </summary>
    private static async Task LocalComputerOwnRawInputSelfInterruptsAsync()
    {
        var f = new LocalFixture(); f.EnableQuiet();
        var (id, token) = f.List();
        string inspectionId = (await f.InspectAsync(id, token)).GetProperty("inspectionId").GetString()!;
        f.Injector.OnBatch = () => { f.Hardware.Header(RawHeader(0, 0)); f.Clock.StampLater(1); };
        f.Wait(300);
        Equal("interrupted", await CodeAsync(() => f.ControlAsync(id, token, inspectionId, "{\"action\":\"drag\",\"x\":0.1,\"y\":0.1,\"toX\":0.9,\"toY\":0.9}")));
        SequenceEqual(new[] { "down" }, f.Injector.Snapshot().Select(b => b.Kind));
        SequenceEqual(new[] { MouseButton.Left }, f.Injector.ReleaseSnapshot().Single().Buttons);
        True(f.Access.IsEnabled && f.Access.ControlReady, "Self-interruption pauses; consent and monitoring stay on.");
    }

    /// <summary>
    /// Reviewer P2: the fixed Terminal route rechecks this request's token and admission and fresh control consent
    /// (production LocalComputerAccess.ControlReady) after package lookup and immediately before activation, after the
    /// activation manager exists. Stop, a lost monitor, revoked connections or this caller leaving at either stage
    /// activate nothing. Settings and executables recheck the request immediately before their side effect.
    /// </summary>
    private static void LocalLaunchRechecksRequestAuthority()
    {
        var f = new LocalFixture();
        var launch = new FixtureLaunchPlatform();
        var apps = new LocalAppCatalog(() => f.Access.ControlReady, launch);
        bool admitted = true;
        using var caller = new CancellationTokenSource();
        var request = new LocalLaunchAuthority(() => admitted, caller.Token);
        string? Listed(string name) => JsonSerializer.SerializeToElement(apps.List(name)).GetProperty("apps").EnumerateArray()
            .Where(a => a.GetProperty("name").GetString() == name).Select(a => a.GetProperty("appId").GetString()).FirstOrDefault();
        string Refusal(string id, LocalLaunchAuthority authority)
        {
            try { apps.Launch(id, authority); }
            catch (LocalAgentException e) { return e.Code; }
            catch (OperationCanceledException) { return "cancelled"; }
            catch (InvalidOperationException) { return "unavailable"; }
            throw new InvalidOperationException("Expected the launch to be refused.");
        }
        void Fresh() { f.Access.Disable("Stopped"); f.Hardware.Lost = false; True(f.Access.Enable(true, out _), "Enable."); f.Wait(1001); }

        True(Listed("Terminal") is null, "Terminal is not listed without fresh control consent.");
        Fresh();
        string? listedTerminal = Listed("Terminal");
        True(listedTerminal is not null, "Terminal is listed under fresh control consent.");
        string terminal = listedTerminal!;
        Equal("launched", JsonSerializer.SerializeToElement(apps.Launch(terminal, request)).GetProperty("status").GetString());
        SequenceEqual(new[] { LocalAppCatalog.TerminalAppUserModelId }, launch.ActivationSnapshot());
        Equal(1, launch.ActivatorsDisposed);

        // Stop during package lookup: refused before any activation manager exists.
        launch.DuringLookup = () => f.Access.Disable("Stopped");
        Equal("consent_required", Refusal(terminal, request));
        launch.DuringLookup = null; Equal(1, launch.Activators);
        // Lost monitor while the activation manager is created: refused immediately before activation.
        Fresh(); terminal = Listed("Terminal")!;
        launch.DuringActivatorCreation = () => f.Hardware.Lost = true;
        Equal("consent_required", Refusal(terminal, request));
        launch.DuringActivatorCreation = null; Equal(2, launch.Activators); Equal(2, launch.ActivatorsDisposed);
        // This caller's EOF during lookup, then during activation preparation.
        Fresh(); terminal = Listed("Terminal")!;
        using (var eof = new CancellationTokenSource())
        {
            launch.DuringLookup = eof.Cancel;
            Equal("cancelled", Refusal(terminal, request with { Request = eof.Token }));
            launch.DuringLookup = null;
        }
        Equal(2, launch.Activators);
        using (var eof = new CancellationTokenSource())
        {
            launch.DuringActivatorCreation = eof.Cancel;
            Equal("cancelled", Refusal(terminal, request with { Request = eof.Token }));
            launch.DuringActivatorCreation = null;
        }
        Equal(3, launch.Activators); Equal(3, launch.ActivatorsDisposed);
        // Local agent connections turned off during lookup; a package that changed during lookup.
        terminal = Listed("Terminal")!;
        launch.DuringLookup = () => admitted = false;
        Equal("unavailable", Refusal(terminal, request));
        launch.DuringLookup = null; admitted = true;
        terminal = Listed("Terminal")!;
        launch.Terminal = null;
        Equal("unavailable", Refusal(terminal, request));
        launch.Terminal = LocalAppCatalog.TerminalAppUserModelId;
        Equal(3, launch.Activators);
        Equal(1, launch.ActivationSnapshot().Length);

        // Settings: the fixed URI opens only for a live, admitted request.
        string settings = Listed("Settings")!;
        using (var eof = new CancellationTokenSource())
        {
            eof.Cancel();
            Equal("cancelled", Refusal(settings, request with { Request = eof.Token }));
        }
        settings = Listed("Settings")!;
        admitted = false; Equal("unavailable", Refusal(settings, request)); admitted = true;
        settings = Listed("Settings")!;
        Equal("launched", JsonSerializer.SerializeToElement(apps.Launch(settings, request)).GetProperty("status").GetString());
        Equal(1, launch.Settings);
        Equal(0, launch.Executables);
        Equal(0, f.Injector.Batches.Count);
    }

    private static void LocalAndRemoteInputGatesAreIsolated()
    {
        var remoteGate = new InputPermissionGate(); // The Host's paired-device gate.
        var remoteInjector = new WindowsInputInjector(remoteGate);
        var f = new LocalFixture(); f.EnableQuiet();
        True(!ReferenceEquals(remoteGate, f.Access.LocalGate), "Local control owns a dedicated gate.");
        True(f.Access.LocalGate.IsEnabled && !remoteGate.IsEnabled, "Enabling local AI never opens paired-device control.");
        // The production injector on the closed remote gate refuses before SendInput.
        Equal(InputPermissionGate.DisabledReason, remoteInjector.SendText("x").Error);
        f.Access.Disable("Stopped");
        remoteGate.SetEnabled(true);
        True(remoteGate.IsEnabled && !f.Access.LocalGate.IsEnabled, "Remote consent does not enable local AI.");
        remoteGate.SetEnabled(false);
    }

    private static void LocalControlVocabularyIsBounded()
    {
        LocalControlCommand Parse(string json) => LocalControlCommand.Parse(JsonDocument.Parse(json).RootElement);
        foreach (string invalid in new[]
        {
            "{\"action\":\"shell\"}", "{\"action\":\"type\",\"text\":\"a\",\"x\":0.5}", "{\"action\":\"type\",\"text\":\"a\\u0007\"}",
            "{\"action\":\"type\",\"text\":\"\"}", "{\"action\":\"key\",\"key\":\"meta\"}", "{\"action\":\"key\",\"key\":\"tab\",\"modifiers\":[\"option\"]}",
            "{\"action\":\"key\",\"key\":\"escape\",\"modifiers\":[\"control\"]}", "{\"action\":\"key\",\"key\":\"a\",\"modifiers\":[\"shift\",\"shift\"]}",
            "{\"action\":\"key\",\"key\":\"a\",\"modifiers\":[\"windows\"]}", "{\"action\":\"scroll\",\"deltaX\":1,\"deltaY\":1}",
            "{\"action\":\"click\",\"x\":1.5,\"y\":0.5}", "{\"action\":\"drag\",\"x\":0.1,\"y\":0.1,\"toX\":0.2}",
            "{\"action\":\"click\",\"x\":0.5,\"y\":0.5,\"button\":\"middle\"}",
        }) Throws<ArgumentException>(() => Parse(invalid));
        Throws<ArgumentException>(() => Parse("{\"action\":\"type\",\"text\":\"" + new string('a', 513) + "\"}"));
        Equal(512, Parse("{\"action\":\"type\",\"text\":\"" + new string('a', 512) + "\"}").Text.Length);
        SequenceEqual(new ushort[] { 0x11, 0x12 }, Parse("{\"action\":\"key\",\"key\":\"f4\",\"modifiers\":[\"command\",\"control\",\"option\"]}").Modifiers);
        Equal(-120, Parse("{\"action\":\"scroll\",\"deltaX\":0,\"deltaY\":-120}").DeltaY);
    }

    private static void BoundedJpegFailsClosed()
    {
        int width = 4000, height = 3000; var gradient = new byte[width * height * 4];
        for (int y = 0; y < height; y++)
            for (int x = 0; x < width; x++) { int o = (y * width + x) * 4; gradient[o] = (byte)x; gradient[o + 1] = (byte)y; gradient[o + 2] = (byte)(x + y); }
        var result = BoundedJpegEncoder.Encode(gradient, width, height, width * 4);
        True(result.Jpeg.Length <= BoundedJpegEncoder.MaximumBytes && Math.Max(result.Width, result.Height) <= 1280, "Large captures are downscaled and bounded.");
        True(Convert.ToBase64String(result.Jpeg).Length <= 160_000, "The encoded image fits the MCP image bound.");
        var noise = RandomNumberGenerator.GetBytes(512 * 512 * 4);
        try { BoundedJpegEncoder.Encode(noise, 512, 512, 2048, maximumBytes: 1024); throw new InvalidOperationException("Expected capture_too_large."); }
        catch (LocalAgentException e) { Equal("capture_too_large", e.Code); }
        Throws<ArgumentException>(() => BoundedJpegEncoder.Encode(new byte[16], 4, 4, 8));
        Throws<ArgumentException>(() => BoundedJpegEncoder.Encode(new byte[64], 4, 5, 16));
    }

    /// <summary>
    /// Native: the real current-user pipe and bridge carry inspect/control to production LocalComputerAccess
    /// (fixture OS boundary). Proves agents cannot enable consent and control replies stay inside one line.
    /// </summary>
    private static async Task<int> NativeLocalComputerBridgeAsync()
    {
        var ready = new TaskCompletionSource<(Dispatcher Dispatcher, LocalAgentBridge Bridge, LocalFixture Fixture)>(TaskCreationOptions.RunContinuationsAsynchronously);
        string pipeName = "Peel.AgentBridge.Validation." + Guid.NewGuid().ToString("N");
        long version = 1;
        var launch = new FixtureLaunchPlatform();
        var thread = new Thread(() =>
        {
            var dispatcher = Dispatcher.CurrentDispatcher;
            var fixture = new LocalFixture(width: 1920, height: 1080);
            var bridge = new LocalAgentBridge(dispatcher, () => true, () => new { fixture = true }, (_, _) => { }, pipeName,
                () => Interlocked.Read(ref version), fixture.Access, launch);
            ready.SetResult((dispatcher, bridge, fixture)); Dispatcher.Run();
        });
        thread.SetApartmentState(ApartmentState.STA); thread.Start();
        var context = await ready.Task;
        var f = context.Fixture;
        try
        {
            async Task<JsonElement> Request(string method, object parameters)
            {
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(12));
                await using var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await pipe.ConnectAsync(timeout.Token);
                string id = Guid.NewGuid().ToString("D");
                await pipe.WriteAsync(LocalAgentProtocol.EncodeLine(new { version = 1, id, method, @params = parameters }), timeout.Token);
                byte[] reply = await LocalAgentProtocol.ReadLineAsync(pipe, timeout.Token) ?? throw new EndOfStreamException();
                using var document = JsonDocument.Parse(reply); Equal(id, document.RootElement.GetProperty("id").GetString());
                return document.RootElement.Clone();
            }
            // Fixture replies hold no person data, so an unexpected shape is reported in full instead of a bare KeyNotFound.
            static JsonElement Result(JsonElement reply, string step) =>
                reply.TryGetProperty("result", out var result) ? result : throw new InvalidOperationException(step + ": expected a result, got " + reply.GetRawText());
            static string Code(JsonElement reply) =>
                reply.TryGetProperty("error", out var error) && error.TryGetProperty("code", out var code) ? code.GetString()!
                    : throw new InvalidOperationException("Expected an error, got " + Clip(reply.GetRawText()));
            static string Clip(string text) => text.Length <= 2048 ? text : text[..2048] + "…";
            // Every listing issues fresh window IDs, so each step uses the ID and token from the same listing.
            async Task<(uint Id, string? Token)> ListAsync(string step)
            {
                var window = Result(await Request("listWindows", new { targetId = "local" }), step).GetProperty("windows")[0];
                var listedToken = window.GetProperty("windowToken");
                return (window.GetProperty("windowId").GetUInt32(), listedToken.ValueKind == JsonValueKind.String ? listedToken.GetString() : null);
            }
            // CurrentUserOnly clients compare the pipe owner with their token's default owner; an elevated administrator
            // token (for example an SSH logon) owns objects as BUILTIN\Administrators. Report which case this run covered.
            bool ownerIsUser;
            using (var identity = System.Security.Principal.WindowsIdentity.GetCurrent()) ownerIsUser = identity.Owner == identity.User;
            var device = Result(await Request("listDevices", new { }), "listDevices before consent").GetProperty("devices")[0];
            True(!device.GetProperty("controlReady").GetBoolean() && !device.GetProperty("inspectReady").GetBoolean(), "No control is advertised before consent.");
            foreach (string method in new[] { "enableControl", "setConsent", "allowAgentAppControl" })
                True((await Request(method, new { targetId = "local" })).TryGetProperty("error", out _), "Agents have no route that grants consent.");
            var (windowId, unconsentedToken) = await ListAsync("listWindows before consent");
            True(unconsentedToken is null, "No window token is issued before consent.");
            Equal("consent_required", Code(await Request("inspectWindow", new { targetId = "local", windowId, windowToken = Guid.NewGuid().ToString("D") })));
            await context.Dispatcher.InvokeAsync(() => f.EnableQuiet());
            var (listedId, listedToken) = await ListAsync("listWindows after consent");
            windowId = listedId; string token = listedToken ?? throw new InvalidOperationException("listWindows after consent issued no windowToken.");
            True((await Request("inspectWindow", new { targetId = "local", windowId, windowToken = token, extra = 1 })).TryGetProperty("error", out _), "Unknown inspect fields are refused.");
            Equal("unavailable", Code(await Request("inspectWindow", new { targetId = "other", windowId, windowToken = token })));
            var inspection = Result(await Request("inspectWindow", new { targetId = "local", windowId, windowToken = token }), "first inspectWindow");
            True(Convert.FromBase64String(inspection.GetProperty("imageBase64").GetString()!).Length <= BoundedJpegEncoder.MaximumBytes, "Full-HD capture fits one bounded line.");
            f.Wait(300);
            var control = await Request("controlWindow", new { targetId = "local", windowId, windowToken = token,
                inspectionId = inspection.GetProperty("inspectionId").GetString(), action = "click", x = 0.5, y = 0.5 });
            Equal("posted", Result(control, "click controlWindow").GetProperty("status").GetString());

            // A caller that disconnects mid-drag cancels only its own request: no later batch, and exactly the owned press is released.
            f.Wait(300);
            (listedId, listedToken) = await ListAsync("listWindows before drag");
            windowId = listedId; token = listedToken!;
            inspection = Result(await Request("inspectWindow", new { targetId = "local", windowId, windowToken = token }), "inspectWindow before drag");
            int batchesBefore = f.Injector.Snapshot().Length, releasesBefore = f.Injector.ReleaseSnapshot().Length;
            f.Time.HoldTimers = true; // Drag step delays now end only by cancellation, never by the 5 s action deadline.
            var watch = System.Diagnostics.Stopwatch.StartNew();
            await using (var caller = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly))
            {
                await caller.ConnectAsync(5000);
                await caller.WriteAsync(LocalAgentProtocol.EncodeLine(new { version = 1, id = Guid.NewGuid().ToString("D"), method = "controlWindow", @params = new
                {
                    targetId = "local", windowId, windowToken = token, inspectionId = inspection.GetProperty("inspectionId").GetString(),
                    action = "drag", x = 0.1, y = 0.1, toX = 0.9, toY = 0.9,
                } }));
                await WaitUntilAsync(() => f.Injector.Snapshot().Length > batchesBefore);
            } // The caller closes its pipe after the press, while the drag waits for its next step.
            await WaitUntilAsync(() => f.Injector.ReleaseSnapshot().Length > releasesBefore);
            True(watch.Elapsed < LocalComputerAccess.ControlDeadline, "Caller EOF, not the action deadline, ended the drag.");
            SequenceEqual(new[] { "down" }, f.Injector.Snapshot().Skip(batchesBefore).Select(b => b.Kind));
            SequenceEqual(new[] { MouseButton.Left }, f.Injector.ReleaseSnapshot().Skip(releasesBefore).Single().Buttons);
            f.Time.HoldTimers = false;

            // A caller that disconnects while its capture is pending cancels that capture; no inspection is issued.
            f.Wait(300);
            (listedId, listedToken) = await ListAsync("listWindows before held capture");
            windowId = listedId; token = listedToken!;
            f.Capture.Hold = true;
            watch.Restart();
            await using (var caller = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly))
            {
                await caller.ConnectAsync(5000);
                await caller.WriteAsync(LocalAgentProtocol.EncodeLine(new { version = 1, id = Guid.NewGuid().ToString("D"), method = "inspectWindow",
                    @params = new { targetId = "local", windowId, windowToken = token } }));
                await WaitUntilAsync(() => f.Capture.Started);
            }
            await WaitUntilAsync(() => f.Capture.ObservedCancellation);
            True(watch.Elapsed < LocalComputerAccess.CaptureDeadline, "Caller EOF, not the capture deadline, cancelled the capture.");
            f.Capture.Hold = false;

            // Fixed Terminal launch through the pipe (fake activation stage, so nothing opens): one exact activation for a
            // present caller, and none for a caller that leaves while the package lookup runs.
            string TerminalId(JsonElement reply) => Result(reply, "listApps Terminal").GetProperty("apps").EnumerateArray()
                .First(a => a.GetProperty("name").GetString() == "Terminal").GetProperty("appId").GetString()!;
            string terminalId = TerminalId(await Request("listApps", new { targetId = "local", query = "Terminal" }));
            Equal("launched", Result(await Request("launchApp", new { targetId = "local", appId = terminalId }), "launchApp Terminal").GetProperty("status").GetString());
            SequenceEqual(new[] { LocalAppCatalog.TerminalAppUserModelId }, launch.ActivationSnapshot());
            terminalId = TerminalId(await Request("listApps", new { targetId = "local", query = "Terminal" }));
            int activatorsBefore = launch.Activators;
            launch.HoldLookup = true; // The lookup now waits for this request's token, bounded at 5 s.
            watch.Restart();
            await using (var caller = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly))
            {
                await caller.ConnectAsync(5000);
                await caller.WriteAsync(LocalAgentProtocol.EncodeLine(new { version = 1, id = Guid.NewGuid().ToString("D"), method = "launchApp",
                    @params = new { targetId = "local", appId = terminalId } }));
                await WaitUntilAsync(() => launch.LookupStarted);
            }
            await WaitUntilAsync(() => launch.LookupObservedCancellation);
            True(watch.Elapsed < TimeSpan.FromSeconds(5), "Caller EOF, not the lookup bound, ended the launch.");
            launch.HoldLookup = false;
            Equal(1, launch.ActivationSnapshot().Length);
            Equal(activatorsBefore, launch.Activators);

            // Other and later callers are unaffected.
            True(Result(await Request("listDevices", new { }), "fresh listDevices").GetProperty("devices")[0].GetProperty("controlReady").GetBoolean(),
                "A fresh caller still works after another caller disconnected.");

            // Turning local agent connections off bumps the version and disables local access, as the Agent Hub does.
            Interlocked.Increment(ref version);
            await context.Dispatcher.InvokeAsync(() => f.Access.Disable("Off · local agent connections are off."));
            f.Wait(300);
            Equal("consent_required", Code(await Request("inspectWindow", new { targetId = "local", windowId, windowToken = token })));
            Console.WriteLine($"PASS native local computer bridge: current-user pipe (CurrentUserOnly owner check passed; token owner {(ownerIsUser ? "is the user" : "differs from the user, e.g. an elevated administrator token")}), no agent consent route, consent_required before UI consent, bounded JPEG line, one posted click, caller EOF cancels only its drag (owned press released, no later batch), its pending capture and its Terminal launch during package lookup (zero activations), fresh caller unaffected, consent_required after connections turn off. OS capture/input/raw input/package lookup/activation were fixture boundaries.");
            return 0;
        }
        finally
        {
            await context.Bridge.DisposeAsync(); f.Access.Dispose();
            context.Dispatcher.BeginInvokeShutdown(DispatcherPriority.Send); thread.Join(3000);
        }
    }

    /// <summary>
    /// Native: the production client opens a detached viewer over real TLS-PSK loopback. A second viewer or an
    /// in-page stream of the same window is refused, every input starts released, and disconnect closes viewers.
    /// </summary>
    private static async Task<int> NativeDetachedViewerLifecycleAsync()
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        var (store, vault) = ParityStore();
        using (vault)
        {
            byte[] key = RandomNumberGenerator.GetBytes(32);
            string pairingId = Guid.NewGuid().ToString();
            store.Save(ParityHostId, "Detached viewer fixture", pairingId, key);
            var factory = new BouncyCastlePskTransportFactory();
            await using var listener = await factory.ListenAsync(new IPEndPoint(IPAddress.Loopback, 0), new ParityTlsResolver(pairingId, key), timeout.Token);
            var port = checked((ushort)((IPEndPoint)listener.LocalEndPoint).Port);
            var browser = new ParityBrowser();
            var addresses = new SavedHostAddressStore(Path.Combine(Path.GetTempPath(), "peel-native-unused-" + Guid.NewGuid().ToString("N") + ".json"));
            await using var client = new ProductionClientServices(store, addresses, browser, factory, useGpuPresentation: false);
            var hello = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var started = new ConcurrentQueue<uint>(); var videoHellos = new ConcurrentQueue<uint>();
            var videoConnections = new ConcurrentBag<PeelPskConnection>();
            var controlServer = Task.Run(async () =>
            {
                await using var connection = await listener.AcceptAsync(timeout.Token);
                var reader = new NdjsonReader(64 * 1024); var buffer = new byte[4096];
                while (true)
                {
                    int count = await connection.Stream.ReadAsync(buffer, timeout.Token);
                    if (count == 0) return;
                    foreach (var line in reader.Append(buffer.AsSpan(0, count)))
                    {
                        var bytes = Encoding.UTF8.GetBytes(line);
                        switch (PeelJson.ReadEnvelope(bytes).Type)
                        {
                            case PeelMessageType.ClientHello:
                                await connection.Stream.WriteAsync(PeelJson.SerializeLine(PeelHello.CreateHost("Detached viewer fixture", capabilities:
                                    [PeelCapability.H264Video, PeelCapability.BinaryVideoTransportV2, PeelCapability.PerWindowVideoConnections])), timeout.Token);
                                await connection.Stream.FlushAsync(timeout.Token); hello.TrySetResult(); break;
                            case PeelMessageType.RequestWindowList:
                                await connection.Stream.WriteAsync(PeelJson.SerializeLine(new WindowListMessage([
                                    new PeelWindow(101, "Fixture", "Detached A", 640, 480), new PeelWindow(102, "Fixture", "Detached B", 640, 480)])), timeout.Token);
                                await connection.Stream.FlushAsync(timeout.Token); break;
                            case PeelMessageType.StartStream: started.Enqueue(PeelJson.Deserialize<PeelRequest>(bytes).WindowId ?? 0); break;
                        }
                    }
                }
            }, timeout.Token);
            var videoServer = Task.Run(async () =>
            {
                await hello.Task.WaitAsync(timeout.Token);
                while (!timeout.IsCancellationRequested)
                {
                    var connection = await listener.AcceptAsync(timeout.Token); videoConnections.Add(connection);
                    var reader = new NdjsonReader(16 * 1024); var buffer = new byte[4096]; VideoStreamHelloMessage? request = null;
                    while (request is null)
                    {
                        int count = await connection.Stream.ReadAsync(buffer, timeout.Token);
                        if (count == 0) break;
                        foreach (var line in reader.Append(buffer.AsSpan(0, count))) request = PeelJson.Deserialize<VideoStreamHelloMessage>(Encoding.UTF8.GetBytes(line));
                    }
                    if (request is not null) videoHellos.Enqueue(request.WindowId);
                }
            }, timeout.Token);

            await client.StartAsync(timeout.Token);
            browser.Push(ParityService(PeelServiceType.Control, port));
            await WaitUntilAsync(() => client.DiscoveredHosts.Count == 1);
            await client.ConnectAsync(client.DiscoveredHosts.Single(), timeout.Token);
            await ((IWindowListService)client).StartAsync(timeout.Token);
            await WaitUntilAsync(() => client.Windows.Count == 2);
            var first = client.Windows.Single(w => w.Id == 101);
            client.DisableAllInputs();
            var viewer = await client.OpenViewerAsync(first, timeout.Token);
            await WaitUntilAsync(() => started.Contains(101u) && videoHellos.Contains(101u));
            True(!viewer.Input.IsEnabled && !client.Input.IsEnabled, "A new viewer starts with every input released.");
            True(client.StreamingWindowId is null, "Opening a viewer leaves the manager's own viewer free.");
            await ThrowsAsync<InvalidOperationException>(() => client.OpenViewerAsync(first, timeout.Token));
            await ThrowsAsync<InvalidOperationException>(() => ((IStreamControlService)client).StartAsync(first, timeout.Token));
            Equal(1, started.Count(id => id == 101));
            await client.DisconnectAsync(timeout.Token);
            Equal(PeelConnectionState.Disconnected, client.State);
            True(!viewer.IsVisible && !viewer.Input.IsEnabled, "Disconnect disposes every detached viewer.");
            try { await client.OpenViewerAsync(first, timeout.Token); throw new InvalidDataException("A stale window must not reopen after disconnect."); }
            catch (InvalidOperationException e) { True(e.Message.Contains("current connected host window list", StringComparison.Ordinal), e.Message); }
            timeout.Cancel();
            foreach (var connection in videoConnections) await connection.DisposeAsync();
            // Fixture teardown only: the accept loop ends by cancellation and TLS may report it differently.
            try { await Task.WhenAll(controlServer, videoServer); } catch (Exception) { }
            store.Forget(ParityHostId); CryptographicOperations.ZeroMemory(key);
            Console.WriteLine("PASS native detached viewer lifecycle: real TLS-PSK control/video sockets, one viewer per window, in-page duplicate refused, inputs released, disconnect closes viewers, no stale reopen.");
            return 0;
        }
    }

    /// <summary>
    /// Native, unattended: the production raw-input monitor owns keyboard and mouse registrations on its own thread,
    /// refuses to replace an existing owner, refuses to register when ownership cannot be read, retires on an
    /// unreadable header, and removes exactly its registrations on Stop. Registration only; whether hardware events
    /// are delivered needs the attended mode below.
    /// </summary>
    private static async Task<int> NativeRawInputRegistrationAsync()
    {
        static bool KeyboardOrMouseRegistered()
        {
            var current = Win32RawInputActivityMonitor.ReadRegistrations();
            True(current is not null, "Windows reports this process's raw input registrations.");
            return current!.Any(d => d.UsagePage == 1 && d.Usage is 2 or 6);
        }
        True(!KeyboardOrMouseRegistered(), "The fixture process starts with no keyboard or mouse raw input owner.");
        // Unknown ownership is never treated as "no owner": a failing query registers nothing.
        var unknown = new Win32RawInputActivityMonitor((RawInputDevice[]? devices, ref uint count, out int lastError) => { lastError = 5; return uint.MaxValue; });
        True(!unknown.Start(out string? unknownError) && unknownError is not null, "Unreadable registrations refuse to start.");
        True(!KeyboardOrMouseRegistered(), "Nothing was registered while ownership was unknown.");
        var monitor = new Win32RawInputActivityMonitor();
        True(monitor.Start(out string? error), error ?? "start");
        string coverage = monitor.Coverage;
        try
        {
            True(monitor.IsActive, "The monitor owns its keyboard and mouse registrations.");
            var second = new Win32RawInputActivityMonitor();
            True(!second.Start(out string? refused) && refused is not null, "A second owner is refused rather than taking the registration.");
            True(monitor.IsActive, "The first owner keeps its registration.");
        }
        finally { monitor.Stop(); }
        True(!monitor.IsActive, "A stopped monitor reports inactive at once.");
        await WaitUntilAsync(() => !KeyboardOrMouseRegistered());
        // A query that starts failing while running makes the owner unavailable rather than assumed.
        bool failQuery = false;
        var third = new Win32RawInputActivityMonitor((RawInputDevice[]? devices, ref uint count, out int lastError) =>
        {
            if (Volatile.Read(ref failQuery)) { lastError = 5; return uint.MaxValue; }
            return Win32RawInputActivityMonitor.QueryWindows(devices, ref count, out lastError);
        });
        True(third.Start(out string? restartError), restartError ?? "restart");
        True(third.IsActive, "The re-registered monitor owns its registrations.");
        Volatile.Write(ref failQuery, true);
        True(!third.IsActive, "Unreadable registrations make the monitor unavailable.");
        Volatile.Write(ref failQuery, false);
        True(third.IsActive, "Readable registrations restore the observation.");
        // An unreadable WM_INPUT header (fed through the production counter) retires the real monitor.
        long before = third.Events;
        third.Counter.Observe(uint.MaxValue, default);
        True(third.Events == before + 1 && !third.IsActive, "An unreadable header counts as activity and retires the monitor.");
        third.Stop();
        await WaitUntilAsync(() => !KeyboardOrMouseRegistered());
        Console.WriteLine($"PASS native raw input registration: owned on a dedicated thread ({coverage}), no takeover of an existing owner, no registration while ownership is unreadable, unavailable while the query fails, retired by an unreadable header, exact removal on Stop, clean re-registration. Event delivery not exercised.");
        return 0;
    }

    /// <summary>
    /// ATTENDED ONLY (interactive desktop; moves the pointer onto its current position). Records whether Windows
    /// reports this process's own SendInput as raw input (if so, every agent batch self-interrupts: fail closed, so
    /// multi-batch actions such as drag cannot complete), then requires a real key press or mouse movement to be
    /// counted while another window is in the foreground.
    /// </summary>
    private static async Task<int> AttendedRawInputAttributionAsync()
    {
        var monitor = new Win32RawInputActivityMonitor();
        True(monitor.Start(out string? error), error ?? "start");
        try
        {
            var platform = new Win32LocalWindowPlatform();
            True(platform.TryGetCursorPosition(out var cursor), "Cursor position is readable.");
            var gate = new InputPermissionGate(); gate.SetEnabled(true);
            var injector = new WindowsInputInjector(gate);
            await Task.Delay(500);
            long before = monitor.Events;
            for (int i = 0; i < 20; i++)
            {
                True(injector.MovePointer(new WindowBounds(cursor.X, cursor.Y, 2, 2), 0, 0).Succeeded, "SendInput accepted the fixture move.");
                await Task.Delay(10);
            }
            await Task.Delay(300);
            gate.SetEnabled(false);
            long ownCounted = monitor.Events - before;
            Console.WriteLine($"OWN_SENDINPUT_COUNTED={ownCounted} (keep hands off input during this step). " + (ownCounted == 0
                ? "Windows did not report this feature's own SendInput as raw input here."
                : "Windows reports this feature's own SendInput as raw input here, so each agent batch interrupts the agent (fail closed); drag and other multi-batch actions will stop after their first batch."));
            True(monitor.IsActive, "No raw input header was unreadable while injecting.");
            Console.WriteLine("Now press any key or move the physical mouse within 15 seconds (any window may be in front).");
            long waitFrom = monitor.Events;
            var deadline = DateTime.UtcNow.AddSeconds(15);
            while (monitor.Events == waitFrom && DateTime.UtcNow < deadline) await Task.Delay(50);
            True(monitor.Events > waitFrom, "A hardware key or mouse event must be counted in the background.");
            True(monitor.IsActive, "No raw input header was unreadable during physical input.");
            Console.WriteLine($"PASS attended raw input: physical input counted ({monitor.Events - waitFrom} events); own SendInput counted {ownCounted}. Coverage: {monitor.Coverage}. Pen, touch, touchpad and virtual devices were not separately exercised.");
            return 0;
        }
        finally { monitor.Stop(); }
    }

    private static async Task<string> CodeAsync(Func<Task> action)
    {
        try { await action(); }
        catch (LocalAgentException e) { return e.Code; }
        throw new InvalidOperationException("Expected a local agent refusal.");
    }

    private sealed class LocalFixture
    {
        internal const uint Pid = 4242;
        public FixtureClock Clock { get; } = new();
        public FixtureTime Time { get; } = new();
        public FixturePlatform Platform { get; }
        public FixtureCapture Capture { get; }
        public FixtureHardware Hardware { get; } = new();
        public FixtureInjector Injector { get; private set; } = null!;
        public LocalComputerAccess Access { get; }

        public LocalFixture(string processName = "Notepad", int width = 640, int height = 480)
        {
            Platform = new FixturePlatform(new WindowDescriptor(0x1234, Pid, processName, "Notepad", "Fixture", LocalFixtureBounds,
                AppLaunchTimeIntervalSince1970: 1_700_000_000));
            Capture = new FixtureCapture(width, height);
            Access = new LocalComputerAccess(Platform, Capture, Clock, Hardware, gate => Injector = new FixtureInjector(gate, Platform), Time, pollActivity: false);
        }

        public void EnableQuiet()
        {
            True(Access.Enable(true, out string? error), error ?? "enable");
            Wait(1001);
        }

        /// <summary>Advances both the input clock (quiet periods) and the TimeProvider (leases and rate limits).</summary>
        public void Wait(uint milliseconds)
        {
            Clock.Advance(milliseconds); Time.Advance(TimeSpan.FromMilliseconds(milliseconds));
        }

        public void DesktopActive(bool active) => Clock.Desktop = active;

        /// <summary>A real key press or mouse movement: one hardware raw-input event and a last-input tick.</summary>
        public void PersonInput() { Hardware.Bump(); Clock.PersonInput(); }

        /// <summary>Another program's SendInput: only the last-input tick moves.</summary>
        public void ExternalInput() => Clock.PersonInput();

        public (uint Id, string Token) List()
        {
            var window = JsonSerializer.SerializeToElement(Access.ListWindows()).GetProperty("windows")[0];
            var token = window.GetProperty("windowToken");
            return (window.GetProperty("windowId").GetUInt32(), token.ValueKind == JsonValueKind.String ? token.GetString()! : "");
        }

        public async Task<JsonElement> InspectAsync(uint id, string token) =>
            JsonSerializer.SerializeToElement(await Access.InspectAsync(id, token, () => true, CancellationToken.None));

        public async Task<JsonElement> ControlAsync(uint id, string token, string inspectionId, string actionJson)
        {
            using var document = JsonDocument.Parse(actionJson);
            var command = LocalControlCommand.Parse(document.RootElement);
            return JsonSerializer.SerializeToElement(await Access.ControlAsync(id, token, inspectionId, command, () => true, CancellationToken.None));
        }
    }

    private sealed class FixtureClock : ILocalInputClock
    {
        private uint now = 50_000, last = 50_000; private uint? pending;
        public bool Desktop { get; set; } = true;
        public uint CurrentTick { get { lock (this) return now; } }
        public bool TryReadLastInputTick(out uint tick) { lock (this) tick = last; return true; }
        public bool IsInputDesktopActive() => Desktop;
        public void Advance(uint milliseconds) { lock (this) now = unchecked(now + milliseconds); }
        public void PersonInput() { lock (this) { now = unchecked(now + 1); last = now; } }
        public void StampLater(uint delay) { lock (this) pending = unchecked(now + delay); }
        public void ApplyStamp() { lock (this) if (pending is { } t) { last = t; pending = null; } }
    }

    private sealed class FixtureTime : TimeProvider
    {
        private long ticks = 1_000_000;
        /// <summary>While true, delays (drag steps) end only by cancellation, never by elapsed time.</summary>
        public volatile bool HoldTimers;
        public override long TimestampFrequency => TimeSpan.TicksPerSecond;
        public override long GetTimestamp() => Interlocked.Read(ref ticks);
        public void Advance(TimeSpan by) => Interlocked.Add(ref ticks, by.Ticks);
        public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period) =>
            HoldTimers ? new HeldTimer() : base.CreateTimer(callback, state, dueTime, period);
        private sealed class HeldTimer : ITimer
        {
            public bool Change(TimeSpan dueTime, TimeSpan period) => true;
            public void Dispose() { }
            public ValueTask DisposeAsync() => ValueTask.CompletedTask;
        }
    }

    /// <summary>
    /// Registration is faked; every event goes through the production <see cref="RawInputActivityCounter"/>, the same
    /// classification the monitor's WM_INPUT hook uses, and a faulted counter makes the fixture unavailable as it
    /// makes the monitor unavailable.
    /// </summary>
    private sealed class FixtureHardware : ILocalHardwareActivity
    {
        private volatile bool running;
        public volatile bool Available = true, Lost;
        public int Stops;
        public RawInputActivityCounter Counter { get; } = new();
        public bool Start(out string? error)
        {
            error = Available ? null : "Fixture: raw input registration refused.";
            if (Available) Counter.Rearm();
            running = Available; return Available;
        }
        public void Stop() { if (running) Interlocked.Increment(ref Stops); running = false; }
        public bool IsActive => running && !Lost && !Counter.Faulted;
        public long Events => Counter.Events;
        public string Coverage => "fixture keyboard and mouse";
        /// <summary>A keyboard header naming a device.</summary>
        public void Bump() => Header(RawHeader(1, 0x51));
        /// <summary>One WM_INPUT header read with GetRawInputData's return value <paramref name="read"/>.</summary>
        public void Header(RawInputHeader header, uint? read = null) => Counter.Observe(read ?? RawInputActivityCounter.HeaderSize, header);
    }

    /// <summary>A complete header: type 0 mouse, 1 keyboard, 2 HID; device 0 is what a precision touchpad can report.</summary>
    private static RawInputHeader RawHeader(uint type, nint device) =>
        new() { Type = type, Size = RawInputActivityCounter.HeaderSize + 24, Device = device };

    /// <summary>Scripted GetRegisteredRawInputDevices: each call returns the next (result, count, last error, devices written).</summary>
    private sealed class FixtureRegistrationQuery((uint Result, uint Count, int Error, RawInputDevice[] Written)[] script)
    {
        public int Calls, Fills;
        public uint Query(RawInputDevice[]? devices, ref uint count, out int lastError)
        {
            var step = script[Math.Min(Calls++, script.Length - 1)];
            if (devices is not null) { Fills++; step.Written.AsSpan(0, Math.Min(step.Written.Length, devices.Length)).CopyTo(devices); }
            count = step.Count; lastError = step.Error;
            return step.Result;
        }
    }

    /// <summary>Fake launch stages: nothing is launched; each stage can run a callback (Stop, lost monitor, caller EOF).</summary>
    private sealed class FixtureLaunchPlatform : ILocalAppLaunchPlatform
    {
        private readonly List<string> activations = [];
        public string? Terminal { get; set; } = LocalAppCatalog.TerminalAppUserModelId;
        public Action? DuringLookup { get; set; }
        public Action? DuringActivatorCreation { get; set; }
        /// <summary>While true, a lookup waits (at most 5 s) for its request token, as a slow package query would.</summary>
        public volatile bool HoldLookup, LookupStarted, LookupObservedCancellation;
        public int Activators, ActivatorsDisposed, Settings, Executables;
        public string[] ActivationSnapshot() { lock (activations) return activations.ToArray(); }
        public string? FindWindowsTerminal(CancellationToken cancellationToken)
        {
            if (HoldLookup)
            {
                LookupStarted = true;
                if (cancellationToken.WaitHandle.WaitOne(TimeSpan.FromSeconds(5))) LookupObservedCancellation = true;
            }
            DuringLookup?.Invoke();
            return Terminal;
        }
        public ILocalPackagedActivator CreateActivator()
        {
            Interlocked.Increment(ref Activators);
            DuringActivatorCreation?.Invoke();
            return new Activation(this);
        }
        public void OpenSettings() => Interlocked.Increment(ref Settings);
        public int StartExecutable(string path, string workingDirectory) { Interlocked.Increment(ref Executables); return 1; }
        private sealed class Activation(FixtureLaunchPlatform owner) : ILocalPackagedActivator
        {
            public uint Activate(string appUserModelId) { lock (owner.activations) owner.activations.Add(appUserModelId); return 77; }
            public void Dispose() => Interlocked.Increment(ref owner.ActivatorsDisposed);
        }
    }

    private sealed class FixturePlatform(WindowDescriptor window) : ILocalWindowPlatform
    {
        public WindowBounds Bounds { get; set; } = window.Bounds;
        public uint ProcessId { get; set; } = window.ProcessId;
        public string? ResolveError { get; set; }
        public bool Covered { get; set; }
        public ScreenPoint? CursorOverride { get; set; }
        public ScreenPoint Cursor { get; set; } = new(0, 0);
        /// <summary>Runs in the last recheck before a pointer batch's gated send.</summary>
        public Action? BeforeHitTest { get; set; }
        public IReadOnlyList<WindowDescriptor> Enumerate() => [window];
        public WindowDescriptor? TryReadCurrent(WindowDescriptor listed, bool allowMinimized) =>
            listed.Handle == window.Handle && listed.ProcessId == ProcessId ? listed with { Bounds = Bounds } : null;
        public WindowInputTargetResult Resolve(WindowDescriptor target, WindowInputFocusMode focusMode) =>
            ResolveError is { } error ? WindowInputTargetResult.Rejected(error) : WindowInputTargetResult.Success(Bounds);
        public bool IsTopLevelTargetAt(WindowDescriptor target, ScreenPoint point) { BeforeHitTest?.Invoke(); return !Covered; }
        public bool TryGetCursorPosition(out ScreenPoint point) { point = CursorOverride ?? Cursor; return true; }
    }

    private sealed class FixtureCapture(int width, int height) : ILocalWindowCapture
    {
        public int Captures;
        /// <summary>While true, a capture stays pending until its token is cancelled.</summary>
        public volatile bool Hold, Started, ObservedCancellation;
        public async Task<LocalCapturedImage> CaptureAsync(WindowDescriptor window, CancellationToken cancellationToken)
        {
            Interlocked.Increment(ref Captures);
            if (Hold)
            {
                Started = true;
                try { await Task.Delay(Timeout.Infinite, cancellationToken); }
                catch (OperationCanceledException) { ObservedCancellation = true; throw; }
            }
            var pixels = new byte[width * height * 4];
            for (int i = 0; i < pixels.Length; i += 4) { pixels[i] = (byte)(i / 4 % width); pixels[i + 1] = (byte)(i / 4 / width); pixels[i + 2] = 0x80; }
            return new LocalCapturedImage(width, height, width * 4, pixels);
        }
    }

    private sealed record FixtureBatch(string Kind, ushort[] Keys);
    private sealed record FixtureRelease(MouseButton[] Buttons, ushort[] Keys);

    /// <summary>Records batches through the production InputPermissionGate; pointer moves update the fixture cursor.</summary>
    private sealed class FixtureInjector(InputPermissionGate gate, FixturePlatform platform) : IHostInputInjector
    {
        public List<FixtureBatch> Batches { get; } = [];
        public List<FixtureRelease> Releases { get; } = [];
        public Action? OnBatch { get; set; }
        /// <summary>Replaces a batch's result, e.g. a partial "SendInput accepted N of M" report.</summary>
        public Func<string, InputInjectionResult?>? Result { get; set; }
        public FixtureBatch[] Snapshot() { lock (Batches) return Batches.ToArray(); }
        public FixtureRelease[] ReleaseSnapshot() { lock (Releases) return Releases.ToArray(); }
        private InputInjectionResult Record(string kind, ushort[]? keys = null, (WindowBounds Bounds, double X, double Y)? move = null) =>
            gate.ExecuteIfEnabled(() =>
            {
                if (move is { } m && NormalizedCoordinateMapper.TryMapToScreen(m.Bounds, m.X, m.Y, out var point) && platform.CursorOverride is null) platform.Cursor = point;
                lock (Batches) Batches.Add(new(kind, keys ?? []));
                OnBatch?.Invoke();
                return Result?.Invoke(kind) ?? InputInjectionResult.Success;
            });
        public InputInjectionResult MovePointer(WindowBounds targetWindow, double normalizedX, double normalizedY) => Record("move", move: (targetWindow, normalizedX, normalizedY));
        public InputInjectionResult SendPointerButton(WindowBounds targetWindow, double normalizedX, double normalizedY, MouseButton button, MouseButtonAction action) =>
            Record(action switch { MouseButtonAction.Down => "down", MouseButtonAction.Up => "up", _ => "click" }, move: (targetWindow, normalizedX, normalizedY));
        public InputInjectionResult SendMouseButton(MouseButton button, MouseButtonAction action) => Record("button");
        public InputInjectionResult SendMouseWheel(int verticalDelta, int horizontalDelta) => Record("wheel");
        public InputInjectionResult SendVirtualKey(ushort virtualKey, VirtualKeyAction action) => Record("key", [virtualKey]);
        public InputInjectionResult SendVirtualKeyChord(IReadOnlyList<ushort> virtualKeys) => Record("chord", virtualKeys.ToArray());
        public InputInjectionResult SendText(string? text) => Record("text");
        public InputInjectionResult ReleaseHeldInputs(IReadOnlyCollection<MouseButton> mouseButtons, IReadOnlyCollection<ushort> virtualKeys)
        {
            lock (Releases) Releases.Add(new(mouseButtons.ToArray(), virtualKeys.ToArray()));
            return InputInjectionResult.Success;
        }
    }
}
