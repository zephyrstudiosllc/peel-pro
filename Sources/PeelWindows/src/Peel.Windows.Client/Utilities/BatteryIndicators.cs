using System.Diagnostics;
using System.IO;
using System.Text.Json;
using Peel.Windows.Protocol;

namespace Peel.Windows.Client.Utilities;
public sealed record BatteryModeChoice(string Id, string Label);
internal sealed record BatteryPreferences(string Mode = "levelColorOutline", bool ShowCharge = true, bool PowerChanges = true, bool Reminders = true, int Threshold = 25, int ReminderSeconds = 15)
{
    private static string PathName => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Zephyr Studios", "Peel", "Utilities", "battery.json");
    internal bool Valid => BatteryScenes.Modes.Any(m => m.Id == Mode) && Threshold is >= 5 and <= 100 && ReminderSeconds is >= 5 and <= 3600;
    internal static BatteryPreferences Load(string? path = null)
    {
        path ??= PathName;
        try { if (File.Exists(path) && new FileInfo(path).Length <= 4096 && JsonSerializer.Deserialize<BatteryPreferences>(File.ReadAllText(path)) is { Valid: true } saved) return saved; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { }
        return new();
    }
    internal void Save(string? path = null)
    {
        if (!Valid) throw new InvalidDataException("Invalid battery indicator preferences.");
        path ??= PathName; Directory.CreateDirectory(Path.GetDirectoryName(path)!); string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try { File.WriteAllText(temporary, JsonSerializer.Serialize(this)); File.Move(temporary, path, true); }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
internal sealed class BatteryCuePolicy
{
    private bool? previousPower;
    private long? lastReminder;
    internal bool Observe(SystemReading reading, BatteryPreferences preferences, long now)
    {
        bool changed = previousPower is { } previous && reading.ExternallyPowered is { } power && previous != power;
        previousPower = reading.ExternallyPowered;
        bool showChange = preferences.ShowCharge && preferences.PowerChanges && changed && reading.BatteryPercent is not null;
        bool low = preferences.ShowCharge && preferences.Reminders && reading.BatteryPercent is { } value && value <= preferences.Threshold && reading.ExternallyPowered == false && reading.Charging == false;
        if (!low) { lastReminder = null; return showChange; }
        if (showChange || lastReminder is null || Stopwatch.GetElapsedTime(lastReminder.Value, now).TotalSeconds >= preferences.ReminderSeconds)
        { lastReminder = now; return true; }
        return false;
    }
}
internal static class BatteryScenes
{
    internal static readonly BatteryModeChoice[] Modes = [new("levelColorOutline", "Level colors + outline"), new("levelColor", "Level colors"), new("greenOutline", "Green bar + outline"), new("green", "Green bar"), new("splitGreenOrange", "Green → orange bar"), new("statusArray", "Charge status · full array"), new("statusBottom", "Charge status · first light")];
    internal static string Program(double fraction, int count, string mode, int threshold)
    {
        if (!double.IsFinite(fraction) || count is < 1 or > 8 || !Modes.Any(m => m.Id == mode)) throw new InvalidDataException("Invalid battery scene.");
        fraction = Math.Clamp(fraction, 0, 1);
        const string green = "#66FF5F", orange = "#FF9F0A", red = "#FF3B30";
        if (mode is "statusArray" or "statusBottom")
            return "brightness 255\noff\n" + (mode == "statusBottom" ? "0:" : "") + (fraction <= Math.Clamp(threshold, 5, 100) / 100d ? orange : green) + " 2s none";
        int lit = Math.Clamp((int)Math.Floor(fraction * count + .5), 1, count);
        string remainder = mode is "levelColorOutline" or "greenOutline" ? "#4D4D4D" : "#000000";
        string Color(int index) => mode switch
        {
            "levelColorOutline" or "levelColor" => lit * 8 >= count * 5 ? green : lit * 8 >= count * 3 ? orange : red,
            "splitGreenOrange" => index < Math.Max(1, count / 2) ? green : orange,
            _ => green,
        };
        int transition = lit == 1 ? 500 : 120, stagger = lit == 1 ? 0 : (500 - transition) / (lit - 1);
        string sweep = string.Join(';', Enumerable.Range(0, lit).Select(i => $"{i}:{Color(i)} {transition}ms cosine" + (i * stagger == 0 ? "" : $" {i * stagger}ms")));
        string hold = string.Join(';', Enumerable.Range(0, count).Select(i => $"{i}:{(i < lit ? Color(i) : remainder)} 1500ms none"));
        string program = $"brightness 255\n{(remainder == "#000000" ? "off" : remainder)}\n{sweep}\n{hold}";
        TrustedSignals.ValidateProgram(program); return program;
    }
}
