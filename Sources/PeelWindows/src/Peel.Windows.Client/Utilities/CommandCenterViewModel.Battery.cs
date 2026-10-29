using System.Diagnostics;
using Peel.Windows.Client.ViewModels;

namespace Peel.Windows.Client.Utilities;
public sealed partial class CommandCenterViewModel
{
    private BatteryPreferences batteryPreferences = BatteryPreferences.Load();
    private readonly BatteryCuePolicy batteryPolicy = new();
    private UtilityScene? batteryPreview;
    public BatteryModeChoice[] BatteryModes => BatteryScenes.Modes;
    public string BatteryMode { get => batteryPreferences.Mode; set { if (value is not null) { SaveBatteryPreferences(batteryPreferences with { Mode = value }); OnPropertyChanged(); } } }
    public bool ShowBatteryCharge { get => batteryPreferences.ShowCharge; set { SaveBatteryPreferences(batteryPreferences with { ShowCharge = value }); OnPropertyChanged(); } }
    public bool BatteryPowerChanges { get => batteryPreferences.PowerChanges; set { SaveBatteryPreferences(batteryPreferences with { PowerChanges = value }); OnPropertyChanged(); } }
    public bool BatteryReminders { get => batteryPreferences.Reminders; set { SaveBatteryPreferences(batteryPreferences with { Reminders = value }); OnPropertyChanged(); } }
    public int BatteryThreshold { get => batteryPreferences.Threshold; set { SaveBatteryPreferences(batteryPreferences with { Threshold = Math.Clamp(value, 5, 100) }); OnPropertyChanged(); } }
    public int BatteryReminderSeconds { get => batteryPreferences.ReminderSeconds; set { SaveBatteryPreferences(batteryPreferences with { ReminderSeconds = Math.Clamp(value, 5, 3600) }); OnPropertyChanged(); } }
    public string BatteryPowerLabel => reading?.ExternallyPowered switch { true => reading.Charging == true ? "External power · charging" : "External power", false => "Battery power", _ => "Power source unavailable" };
    public AsyncCommand ShowBatteryCommand { get; private set; } = null!;
    private void InitializeBattery() => ShowBatteryCommand = new(() => { PreviewBattery(manual: true); RefreshSignalPresentation(); return Task.CompletedTask; });
    private void SaveBatteryPreferences(BatteryPreferences value)
    {
        try { value.Save(); batteryPreferences = value; if (!value.ShowCharge) batteryPreview = null; RefreshSignalPresentation(); }
        catch (Exception e) when (e is System.IO.IOException or System.IO.InvalidDataException or UnauthorizedAccessException) { Notice = "Could not save battery indicator preferences."; }
    }
    private void ObserveBattery(SystemReading value)
    {
        if (batteryPolicy.Observe(value, batteryPreferences, Stopwatch.GetTimestamp())) PreviewBattery();
        OnPropertyChanged(nameof(BatteryPowerLabel));
    }
    private void PreviewBattery(bool manual = false)
    {
        if (!ShowBatteryCharge || LightMode is "Off" or "Flashlight") { if (manual) Notice = "Enable battery previews and select an activity or utility light mode first."; return; }
        if (reading?.BatteryPercent is not { } charge || DateTimeOffset.UtcNow - reading.SampledAt > TimeSpan.FromSeconds(10)) { Notice = "A recent battery reading is unavailable."; return; }
        batteryPreview = new("battery:" + Guid.NewGuid().ToString("N"), $"Battery · {charge:F0}% · {BatteryPowerLabel}",
            BatteryScenes.Program(charge / 100d, 8, BatteryMode, BatteryThreshold), BatteryScenes.Program(charge / 100d, 2, BatteryMode, BatteryThreshold),
            Stopwatch.GetTimestamp() + Stopwatch.Frequency * 2, DateTimeOffset.UtcNow);
    }
    private UtilityScene? BatteryPreview()
    {
        if (batteryPreview is { ValidUntil: { } deadline } && Stopwatch.GetTimestamp() >= deadline) batteryPreview = null;
        return batteryPreview;
    }
}
