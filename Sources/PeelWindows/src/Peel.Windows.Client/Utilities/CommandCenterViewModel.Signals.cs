using System.Collections.ObjectModel;
using System.Diagnostics;
using Peel.Windows.Client.ViewModels;

namespace Peel.Windows.Client.Utilities;

public sealed partial class CommandCenterViewModel
{
    private readonly SignalSettings signalSettings;
    private readonly LocalLightScenes localLightScenes = new();
    public ObservableCollection<SignalSourceChoice> SignalSources { get; } = new();
    private string selectedState = "working", editPro = "", editDot = "", styleStatus = "Programs use the paired SidePulse firmware syntax.";
    private string activityLabel = "No visible activity", activityProgram = "off", activityKey = "";
    private string activityDotProgram = "off";
    private DateTimeOffset activityStartedAt;
    private long activityValidUntil;
    public string ActivityLabel => activityLabel;
    public string ActivityProgram => activityProgram;
    public string ActivityDotProgram => activityDotProgram;
    public DateTimeOffset ActivityStartedAt => activityStartedAt;
    public long ActivityValidUntil => activityValidUntil;
    public bool ShowActivityLights { get => signalSettings.Presentation.ShowLights; set => SaveSignalPresentation(signalSettings.Presentation with { ShowLights = value }); }
    public bool ShowUsageInBar { get => signalSettings.Presentation.ShowUsage; set => SaveSignalPresentation(signalSettings.Presentation with { ShowUsage = value }); }
    public string SignalSource
    {
        get => signalSettings.Presentation.Source;
        set
        {
            if (value is null) return;
            string label = SignalSources.FirstOrDefault(s => s.Id == value)?.Label ?? signalSettings.Presentation.SourceLabel;
            SaveSignalPresentation(signalSettings.Presentation with { Source = value, SourceLabel = label });
        }
    }
    public string[] SignalStyleStates => SignalSettings.States;
    public string SelectedSignalState { get => selectedState; set { if (value is not null && SetProperty(ref selectedState, value)) LoadSignalStyle(); } }
    public string EditProProgram { get => editPro; set => SetProperty(ref editPro, value); }
    public string EditDotProgram { get => editDot; set => SetProperty(ref editDot, value); }
    public string SignalStyleStatus { get => styleStatus; private set => SetProperty(ref styleStatus, value); }
    public AsyncCommand SaveSignalStyleCommand { get; private set; } = null!;
    public AsyncCommand ResetSignalStyleCommand { get; private set; } = null!;
    private void InitializeSignalPresentation()
    {
        InitializeLightingProfiles();
        SaveSignalStyleCommand = new(() => { SaveSignalStyle(new(EditProProgram, EditDotProgram)); return Task.CompletedTask; });
        ResetSignalStyleCommand = new(() => { SaveSignalStyle(null); return Task.CompletedTask; });
        LoadSignalStyle(); RefreshSignalPresentation();
    }
    private void LoadSignalStyle()
    {
        try { var programs = signalSettings.Programs(SelectedSignalState); EditProProgram = programs.Pro; EditDotProgram = programs.Dot; }
        catch (System.IO.InvalidDataException) { EditProProgram = EditDotProgram = "off"; SignalStyleStatus = "This style exceeds light program limits. Simplify its motion."; }
    }
    private void SaveSignalStyle(SignalPrograms? programs)
    {
        try
        {
            signalSettings.SaveStyle(SelectedSignalState, programs); LoadSignalStyle();
            OnPropertyChanged(nameof(ProfileOverrideNote));
            SignalStyleStatus = programs is null ? "Restored this state's default program." : "Saved. Local indicators and shared local activity use this state's programs.";
            SignalPublisher?.UpdateLocalActivity(LocalActivity); RefreshSignalPresentation();
        }
        catch (Exception e) when (e is System.IO.IOException or System.IO.InvalidDataException or UnauthorizedAccessException)
        { SignalStyleStatus = "Could not save: " + e.Message; }
    }
    private void SaveSignalPresentation(SignalPreferences value)
    {
        try { signalSettings.SavePresentation(value); }
        catch (Exception e) when (e is System.IO.IOException or System.IO.InvalidDataException or UnauthorizedAccessException) { SignalStyleStatus = "Could not save the signal display preference."; }
        OnPropertyChanged(nameof(ShowActivityLights)); OnPropertyChanged(nameof(ShowUsageInBar)); OnPropertyChanged(nameof(SignalSource)); OnPropertyChanged(nameof(TraySummary)); OnPropertyChanged(nameof(AgentDisplayMode));
        SignalPublisher?.UpdateLocalActivity(LocalActivity);
        RefreshSignalPresentation(); Updated?.Invoke(this, EventArgs.Empty);
    }
    internal void RefreshSignalPresentation()
    {
        var preferences = signalSettings.Presentation;
        var choices = new List<SignalSourceChoice> { new("automatic", "Automatic · local first"), new("local", "This PC"), new("paired", "Paired devices · highest priority") };
        foreach (var signal in SignalRows) choices.Add(new("host:" + signal.HostId, signal.DisplayName));
        if (!choices.Any(c => c.Id == preferences.Source)) choices.Add(new(preferences.Source, preferences.SourceLabel + " · unavailable"));
        if (!SignalSources.SequenceEqual(choices)) { SignalSources.Clear(); foreach (var choice in choices) SignalSources.Add(choice); OnPropertyChanged(nameof(SignalSource)); }
        var now = DateTimeOffset.UtcNow;
        var visible = LocalActivity.Where(r => !dismissedActivity.TryGetValue(r.Id, out var at) || at < r.EventAt).ToArray();
        var agents = AgentLighting.Visible(visible, now);
        var local = visible.Where(r => agents.Any(a => a.Id == r.Id)).OrderBy(r => r.Priority).ThenByDescending(r => r.EventAt).FirstOrDefault();
        var localScene = localLightScenes.Compile(signalSettings, agents, now);
        RefreshLightAllocations(localScene, visible);
        var remote = SignalRows.Where(r => r.IsFresh && r.Frame.HasVisibleActivity && (preferences.Source is "automatic" or "paired" || preferences.Source == "host:" + r.HostId))
            .OrderBy(r => r.Frame.Priority).ThenBy(r => r.HostId, StringComparer.Ordinal).FirstOrDefault();
        bool useLocal = local is not null && (preferences.Source is "automatic" or "local");
        string key, program, dotProgram; DateTimeOffset started; long valid;
        if (useLocal)
        {
            var programs = localScene.Programs;
            key = "local:" + programs.Pro + ":" + programs.Dot; program = programs.Pro; dotProgram = programs.Dot;
            started = key == activityKey ? activityStartedAt : DateTimeOffset.UtcNow;
            valid = Stopwatch.GetTimestamp() + Stopwatch.Frequency * 10;
            activityLabel = localScene.Error ?? (preferences.DisplayMode == "perAgent" ? $"This PC · {agents.Length} observed sessions · {signalSettings.Profiles.Selected.Name}" : $"This PC · {(local! with { State = localScene.State }).StateLabel} · {agents.Length} observed sessions");
        }
        else if (remote is not null)
        {
            key = "host:" + remote.HostId; program = remote.Frame.ProProgram; dotProgram = remote.Frame.DotProgram; started = remote.Frame.ProgramStartedAt;
            valid = remote.ReceivedTimestamp + (long)(Stopwatch.Frequency * 3.5);
            activityLabel = $"{remote.DisplayName} · {remote.StateLabel}";
        }
        else
        {
            key = "idle"; program = dotProgram = "off"; started = DateTimeOffset.UtcNow; valid = 0;
            activityLabel = preferences.Source.StartsWith("host:", StringComparison.Ordinal) ? preferences.SourceLabel + " · no fresh visible activity" : "No visible activity from the selected source";
        }
        if (CurrentUtilityScene() is { } scene)
        {
            key = scene.Key; program = scene.Pro; dotProgram = scene.Dot; activityLabel = scene.Label;
            started = scene.StartedAt ?? (key == activityKey ? activityStartedAt : DateTimeOffset.UtcNow);
            valid = scene.ValidUntil ?? Stopwatch.GetTimestamp() + Stopwatch.Frequency * 10;
        }
        activityKey = key; activityProgram = program; activityDotProgram = dotProgram; activityStartedAt = started; activityValidUntil = valid;
        RefreshHardwareOutput();
        foreach (string property in new[] { nameof(ActivityLabel), nameof(ActivityProgram), nameof(ActivityDotProgram), nameof(ActivityStartedAt), nameof(ActivityValidUntil), nameof(CompactActivityLabel) }) OnPropertyChanged(property);
    }
}
