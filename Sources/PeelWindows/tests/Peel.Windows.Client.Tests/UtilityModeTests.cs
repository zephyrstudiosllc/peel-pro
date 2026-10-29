using Peel.Windows.Client.Utilities;
using Peel.Windows.Host.Runtime;
using Peel.Windows.Protocol;

namespace Peel.Windows.Client.Tests;
internal static partial class Program
{
    private static void MicrophoneObservationSemantics()
    {
        long now = System.Diagnostics.Stopwatch.GetTimestamp();
        Equal("unavailable", MicrophoneActivity.Reduce([], true, now).State);
        var idle = new InputDeviceActivity("Fixture input", false, false, false);
        Equal("idle", MicrophoneActivity.Reduce([idle], true, now).State);
        Equal("unavailable", MicrophoneActivity.Reduce([idle], false, now).State);
        Equal("active", MicrophoneActivity.Reduce([idle with { Active = true, Muted = null }], true, now).State);
        var muted = idle with { Active = true, Muted = true };
        var snapshot = MicrophoneActivity.Reduce([muted], true, now);
        Equal("muted", snapshot.State); True(snapshot.Detail.Contains("Windows mute"), "Software endpoint mute must not claim a hardware switch.");
        Equal("active", MicrophoneActivity.Reduce([muted, idle with { Active = true }], true, now).State);
        Equal("unavailable", MicrophoneActivity.Reduce([muted], false, now).State);
        True(MicrophoneActivity.Reduce([muted with { HardwareMute = true }], true, now).Detail.Contains("hardware mute"), "Hardware is labeled only when the native capability is present.");
        True(!MicrophoneActivity.Reduce([idle], true, now - System.Diagnostics.Stopwatch.Frequency * 4).Fresh, "Stale session facts cannot keep an indicator active.");
        foreach (int count in new[] { 2, 8 }) TrustedSignals.ValidateProgram(UtilityScenes.Program("#FF9F0A", .9, count, motion: "converge", seconds: 1.8));
    }
    private static void CountdownAndScenes()
    {
        var now = DateTimeOffset.UtcNow; var timer = new Countdown();
        Equal("00:00", Countdown.Label(-1)); Equal("01:01", Countdown.Label(60.1)); Equal("24:00:00", Countdown.Label(86400));
        timer.Start(100, now); Equal(100d, timer.Remaining(now)); Equal(50d, timer.Remaining(now.AddSeconds(50)));
        timer.Pause(now.AddSeconds(50)); Equal(CountdownPhase.Paused, timer.Phase); Equal(50d, timer.Remaining(now.AddHours(1)));
        timer.Resume(now.AddHours(1)); Equal(1d, timer.Remaining(now.AddHours(1).AddSeconds(49)));
        True(timer.Tick(now.AddHours(1).AddSeconds(50)), "Completion must be observed once.");
        True(!timer.Tick(now.AddDays(1)), "Completed timers do not repeat notifications.");
        timer.Pause(now.AddDays(1)); timer.Resume(now.AddDays(1)); Equal(CountdownPhase.Finished, timer.Phase);
        timer.Reset(); Equal(CountdownPhase.Idle, timer.Phase);
        timer.Start(double.NaN, now); Equal(1500d, timer.Duration); timer.Start(999999, now); Equal(86400d, timer.Duration);
        timer.Start(100, now);
        var running = UtilityScenes.Timer(timer, now.AddSeconds(50), 10, false);
        var rendered = new SignalProgram(running.Pro).Frame(1);
        True(rendered.Take(4).All(c => c.Blue > 0) && rendered.Skip(4).All(c => c == default), "The remaining bar uses ceil(fraction * LED count).");
        Equal("0:#51269A;1:#51269A;2:#51269A;3:#51269A;4:#51269A;5:#51269A;6:#51269A;7:#51269A", UtilityScenes.Program("#7C3AED", .65, 8));
        foreach (int count in new[] { 1, 2, 8 }) foreach (string motion in new[] { "solid", "pulse", "flash", "breathe", "converge" }) foreach (double fraction in new[] { 0d, .01, .5, 1, double.NaN })
        {
            string program = UtilityScenes.Program("#FF9F0A", .8, count, fraction, motion, 1.5);
            TrustedSignals.ValidateProgram(program);
            True(new SignalProgram(program, count).Frame(100).All(c => c.Red is >= 0 and <= 1), "Every utility scene must fit real firmware and remain bounded.");
        }
        True(UtilityScenes.Timer(timer, now.AddSeconds(95), 10, true).Pro.Contains("1.5s pulse"), "Warning uses the Mac's pulse duration.");
        timer.Tick(now.AddSeconds(100)); True(UtilityScenes.Timer(timer, now.AddSeconds(100), 10, false).Pro.Contains("300ms none"), "Completion flashes with the Mac's half-cycle.");
        string root = Path.Combine(Path.GetTempPath(), "peel-timer-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root); string path = Path.Combine(root, "timer.json");
        try
        {
            var preferences = new TimerPreferences(45, 10, true); preferences.Save(path); Equal(preferences, TimerPreferences.Load(path));
            Throws<InvalidDataException>(() => new TimerPreferences(0).Save(path)); Equal(preferences, TimerPreferences.Load(path));
            File.WriteAllText(path, "{\"Seconds\":-1}"); Equal(new TimerPreferences(), TimerPreferences.Load(path));
            File.WriteAllText(path, new string('x', 2049)); Equal(new TimerPreferences(), TimerPreferences.Load(path));
        }
        finally { File.Delete(path); Directory.Delete(root); }
    }
    private static int NativeKeepAwake()
    {
        using var awake = new WindowsHostAwakeController(displayRequired: false, reason: "Peel Coffee validation fixture");
        awake.SetClientVisible(true); True(awake.IsHolding && awake.LastError is null, "Native system-only power request should be accepted.");
        awake.SetClientVisible(true); awake.SetClientVisible(false); True(!awake.IsHolding && awake.LastError is null, "Repeated enable must require only one release.");
        awake.SetClientVisible(true); awake.Dispose(); True(!awake.IsHolding, "Dispose releases its own power request.");
        Console.WriteLine("PASS native system-only keep-awake acquisition, idempotence, release and disposal; no global power policy changed."); return 0;
    }
}
