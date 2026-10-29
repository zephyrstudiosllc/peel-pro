using System.Diagnostics;
using Peel.Windows.Client.Utilities;
using Peel.Windows.Protocol;

namespace Peel.Windows.Client.Tests;
internal static partial class Program
{
    private static void BatteryIndicatorSemantics()
    {
        foreach (var mode in BatteryScenes.Modes) foreach (int count in new[] { 2, 8 }) foreach (double charge in new[] { 0, .125, .25, .5, .75, 1d })
        {
            string program = BatteryScenes.Program(charge, count, mode.Id, 25); TrustedSignals.ValidateProgram(program);
            True(new SignalProgram(program, count).Frame(1.5).All(c => c.Red is >= 0 and <= 1), "All battery programs must remain within the firmware contract.");
        }
        var zero = new SignalProgram(BatteryScenes.Program(0, 8, "levelColor", 25)).Frame(1.5);
        Equal(1d, zero[0].Red); Equal(default(SignalColor), zero[1]);
        var outline = new SignalProgram(BatteryScenes.Program(.25, 8, "greenOutline", 25)).Frame(1.5);
        Equal(77d / 255, outline[2].Red); Equal(102d / 255, outline[0].Red);
        Equal("brightness 255\noff\n0:#FF9F0A 2s none", BatteryScenes.Program(.25, 8, "statusBottom", 25));
        Equal("brightness 255\noff\n#66FF5F 2s none", BatteryScenes.Program(.26, 8, "statusArray", 25));
        Throws<InvalidDataException>(() => BatteryScenes.Program(double.NaN, 8, "green", 25));
        var at = DateTimeOffset.UtcNow; long now = Stopwatch.GetTimestamp(); var policy = new BatteryCuePolicy(); var preferences = new BatteryPreferences();
        var plugged = MetricFixture(at) with { BatteryPercent = 20, ExternallyPowered = true, Charging = false };
        True(!policy.Observe(plugged, preferences, now), "Initial power observation is not a charger transition.");
        var battery = plugged with { ExternallyPowered = false };
        True(policy.Observe(battery, preferences, now), "A known unplug transition starts a preview and resets reminder cadence.");
        True(!policy.Observe(battery, preferences, now + Stopwatch.Frequency * 5), "Low battery must respect its repeat interval.");
        True(policy.Observe(battery, preferences, now + Stopwatch.Frequency * 15), "Low battery repeats after its configured interval.");
        True(!policy.Observe(battery with { ExternallyPowered = null }, preferences, now + Stopwatch.Frequency * 20), "Unknown power cannot prove battery operation.");
        True(!policy.Observe(battery with { Charging = true }, preferences, now + Stopwatch.Frequency * 21), "Charging suppresses the low-battery reminder.");
        True(!policy.Observe(plugged, preferences with { ShowCharge = false }, now + Stopwatch.Frequency * 22), "Disabled previews suppress power transitions.");
        string root = Path.Combine(Path.GetTempPath(), "peel-battery-settings-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root); string path = Path.Combine(root, "battery.json");
        try
        {
            var saved = new BatteryPreferences("statusBottom", true, false, true, 10, 60); saved.Save(path); Equal(saved, BatteryPreferences.Load(path));
            Throws<InvalidDataException>(() => (saved with { ReminderSeconds = 0 }).Save(path)); Equal(saved, BatteryPreferences.Load(path));
            File.WriteAllText(path, "{\"Mode\":\"unknown\"}"); Equal(new BatteryPreferences(), BatteryPreferences.Load(path));
        }
        finally { File.Delete(path); Directory.Delete(root); }
    }
}
