using System.Diagnostics;
using System.Windows.Threading;
using Peel.Windows.Client.ViewModels;
using Peel.Windows.Host.Runtime;

namespace Peel.Windows.Client.Utilities;
public sealed partial class CommandCenterViewModel
{
    private readonly Countdown countdown = new();
    private readonly WindowsHostAwakeController keepAwake = new(displayRequired: false, reason: "Peel Pro Coffee — keep this PC awake");
    private DispatcherTimer? utilityTimer;
    private string lightMode = "Agent activity";
    private int timerSeconds = 1500, warningSeconds = 60;
    private bool timerAnimation;
    public string[] LightModes { get; } = ["Agent activity", "ON AIR", "Timer", "Progress", "Flashlight", "Off"];
    public string LightMode { get => lightMode; set { if (LightModes.Contains(value) && SetProperty(ref lightMode, value)) { if (value is "Off" or "Flashlight") batteryPreview = null; RefreshSignalPresentation(); } } }
    public int TimerSeconds { get => timerSeconds; set => SetProperty(ref timerSeconds, Math.Clamp(value, 1, 86400)); }
    public int TimerWarningSeconds { get => warningSeconds; set => SetProperty(ref warningSeconds, Math.Clamp(value, 0, 86400)); }
    public bool TimerAnimation { get => timerAnimation; set { if (SetProperty(ref timerAnimation, value)) RefreshSignalPresentation(); } }
    public string TimerLabel => UtilityScenes.Timer(countdown, DateTimeOffset.UtcNow, TimerWarningSeconds, TimerAnimation).Label;
    public bool KeepAwake { get => keepAwake.IsHolding; set { keepAwake.SetClientVisible(value); OnPropertyChanged(); OnPropertyChanged(nameof(KeepAwakeStatus)); } }
    public string KeepAwakeStatus => keepAwake.LastError ?? (keepAwake.IsHolding ? "Coffee on · idle sleep prevention requested" : "Coffee off");
    public AsyncCommand StartTimerCommand { get; private set; } = null!;
    public AsyncCommand PauseTimerCommand { get; private set; } = null!;
    public AsyncCommand ResumeTimerCommand { get; private set; } = null!;
    public AsyncCommand ResetTimerCommand { get; private set; } = null!;
    private void InitializeUtilityModes()
    {
        var saved = TimerPreferences.Load(); timerSeconds = saved.Seconds; warningSeconds = saved.WarningSeconds; timerAnimation = saved.Animation;
        StartTimerCommand = new(() =>
        {
            try { new TimerPreferences(TimerSeconds, Math.Min(TimerSeconds, TimerWarningSeconds), TimerAnimation).Save(); }
            catch (Exception e) when (e is System.IO.IOException or System.IO.InvalidDataException or UnauthorizedAccessException) { Notice = "Timer started; countdown preferences could not be saved."; }
            countdown.Start(TimerSeconds, DateTimeOffset.UtcNow); LightMode = "Timer"; TickUtilities(); return Task.CompletedTask;
        });
        PauseTimerCommand = new(() => { countdown.Pause(DateTimeOffset.UtcNow); TickUtilities(); return Task.CompletedTask; });
        ResumeTimerCommand = new(() => { countdown.Resume(DateTimeOffset.UtcNow); TickUtilities(); return Task.CompletedTask; });
        ResetTimerCommand = new(() => { countdown.Reset(); if (LightMode == "Timer") LightMode = "Agent activity"; TickUtilities(); return Task.CompletedTask; });
        utilityTimer = new DispatcherTimer(DispatcherPriority.Background, dispatcher) { Interval = TimeSpan.FromMilliseconds(250) };
        utilityTimer.Tick += (_, _) => TickUtilities();
    }
    private void TickUtilities()
    {
        if (OnAirEnabled) { OnPropertyChanged(nameof(OnAirStatus)); OnPropertyChanged(nameof(OnAirCaptureStatus)); }
        RefreshProgress();
        if (countdown.Tick(DateTimeOffset.UtcNow)) PublishAlert("Timer finished.");
        OnPropertyChanged(nameof(TimerLabel));
        if (LightMode != "Agent activity" || batteryPreview is not null) RefreshSignalPresentation();
    }
    private UtilityScene? CurrentUtilityScene() => BatteryPreview() ?? LightMode switch
    {
        "Timer" => UtilityScenes.Timer(countdown, DateTimeOffset.UtcNow, TimerWarningSeconds, TimerAnimation),
        "Progress" => ProgressScene(),
        "ON AIR" => OnAirScene(),
        "Flashlight" => new("flashlight", "Flashlight · white lights", "brightness 255\n#FFFFFF", "brightness 255\n#FFFFFF"),
        "Off" => new("off", "Light display off", "off", "off"),
        _ => null,
    };
    public void PauseSessionUtilities()
    { OnAirEnabled = false; KeepAwake = false; CancelHardwareOutput(); }
}
