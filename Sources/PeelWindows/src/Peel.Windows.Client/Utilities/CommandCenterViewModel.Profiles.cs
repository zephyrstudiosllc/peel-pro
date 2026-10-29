using System.Collections.ObjectModel;
using System.IO;
using Peel.Windows.Client.ViewModels;

namespace Peel.Windows.Client.Utilities;

public sealed record LightingChoice(string Id, string Label);
public sealed record LightAllocationRow(string Output, string Lights, string Session, string State)
{
    public string StateLabel => LightingStateChoice.Title(State);
}
public sealed record LightingStateChoice(string Id, string Label, string Detail, string Color)
{
    public static string Title(string state) => state switch
    {
        "working" => "Thinking", "toolRunning" => "Tool Running", "waiting" => "Needs Input",
        "completed" => "Done", "error" => "Interrupted", "idle" => "Idle", _ => state
    };
}

public sealed partial class CommandCenterViewModel
{
    public ObservableCollection<LightingChoice> LightingProfiles { get; } = new();
    public ObservableCollection<LightAllocationRow> LightAllocations { get; } = new();
    public LightingChoice[] AgentDisplayModes { get; } = [new("simple", "Simple · one combined state"), new("perAgent", "Per agent · individual sessions")];
    public LightingChoice[] AllocationStrategies { get; } = [new("adaptiveOccupancy", "Adaptive Array"), new("stableAgents", "Stable Agent Slots"), new("providerLanes", "Provider Lanes"), new("priorityStack", "Priority Stack")];
    public string[] ProfileMotions => LightStyle.Motions;
    public string[] ProfileColorModes => LightStyle.ColorModes;
    public LightingChoice[] ProfileMotionChoices { get; } = LightStyle.Motions.Select(id => new LightingChoice(id, char.ToUpperInvariant(id[0]) + id[1..])).ToArray();
    public LightingChoice[] ProfileColorChoices { get; } = [new("single", "Single color"), new("colorway", "Two-color blend"), new("rainbow", "Rainbow"), new("rotatingColorway", "Rotating colorway")];
    public LightingStateChoice[] ProfileStateChoices => SignalSettings.States.Select(state =>
    {
        var style = signalSettings.Profiles.Selected.Style(state);
        string motion = ProfileMotionChoices.Single(c => c.Id == style.Motion).Label;
        return new LightingStateChoice(state, LightingStateChoice.Title(state), motion + " · " + ProfileColorChoices.Single(c => c.Id == style.ColorMode).Label, style.ColorHex);
    }).ToArray();
    public string ProfileStateTitle => LightingStateChoice.Title(ProfileState);
    public string ProfileStateDescription => ProfileState switch
    {
        "working" => "An agent is thinking through its next step.",
        "toolRunning" => "An agent is using a tool or running a command.",
        "waiting" => "An agent needs your attention to continue.",
        "completed" => "An agent has finished its work.",
        "error" => "An agent stopped or reported an error.",
        _ => "No active work is being observed."
    };
    public string AgentDisplayMode { get => signalSettings.Presentation.DisplayMode; set { if (value is "simple" or "perAgent") SaveSignalPresentation(signalSettings.Presentation with { DisplayMode = value }); } }
    private bool loadingProfiles;
    public string SelectedLightingProfile
    {
        get => signalSettings.Profiles.Selected.Id.ToString("D");
        set { if (!loadingProfiles && Guid.TryParse(value, out var id)) ChangeProfile(() => signalSettings.Profiles.Select(id), "Profile selected."); }
    }
    private string profileName = "", profileStrategy = "adaptiveOccupancy", profileState = "working", profileColor = "#FFFFFF", profileSecondary = "#7C3AED", profileMotion = "solid", profileColorMode = "single";
    private double profileBrightness = .72, profileIntensity = .5, profileCycle = 2;
    private string profileStatus = "Profiles style local activity. Imported profiles keep their colors and allocation strategy.";
    private string allocationStatus = "No local sessions are visible.";
    public string ProfileName { get => profileName; set => SetProperty(ref profileName, value); }
    public string ProfileStrategy { get => profileStrategy; set => SetProperty(ref profileStrategy, value); }
    public double ProfileBrightness { get => profileBrightness; set => SetProperty(ref profileBrightness, value); }
    public string ProfileState { get => profileState; set { if (SignalSettings.States.Contains(value) && SetProperty(ref profileState, value)) { LoadProfileStyle(); OnPropertyChanged(nameof(ProfileStateTitle)); OnPropertyChanged(nameof(ProfileStateDescription)); } } }
    public string ProfileColor { get => profileColor; set => SetProperty(ref profileColor, value); }
    public string ProfileSecondaryColor { get => profileSecondary; set => SetProperty(ref profileSecondary, value); }
    public string ProfileMotion { get => profileMotion; set => SetProperty(ref profileMotion, value); }
    public string ProfileColorMode { get => profileColorMode; set => SetProperty(ref profileColorMode, value); }
    public double ProfileIntensity { get => profileIntensity; set => SetProperty(ref profileIntensity, value); }
    public double ProfileCycle { get => profileCycle; set => SetProperty(ref profileCycle, value); }
    public string ProfileStatus { get => profileStatus; private set => SetProperty(ref profileStatus, value); }
    public string AllocationStatus { get => allocationStatus; private set => SetProperty(ref allocationStatus, value); }
    public string DefaultProfileLabel
    {
        get { var library = signalSettings.Profiles.Read(); return "Default: " + library.Profiles.Single(p => p.Id == library.DefaultProfileID).Name; }
    }
    public bool CanDeleteProfile => signalSettings.Profiles.Read().Profiles.Length > 1;
    public string ProfileOverrideNote => SignalSettings.States.Any(s => signalSettings.Override(s) is not null)
        ? "Advanced state programs are saved. They override profile styles in Simple mode or for one visible session. Use profile programs to clear those overrides."
        : "Profile programs are active. Multiple visible sessions always use the profile's allocation and styles.";
    public AsyncCommand NewLightingProfileCommand { get; private set; } = null!;
    public AsyncCommand DuplicateLightingProfileCommand { get; private set; } = null!;
    public AsyncCommand DeleteLightingProfileCommand { get; private set; } = null!;
    public AsyncCommand SaveLightingProfileCommand { get; private set; } = null!;
    public AsyncCommand ResetProfileStateCommand { get; private set; } = null!;
    public AsyncCommand DefaultLightingProfileCommand { get; private set; } = null!;
    public AsyncCommand UseDefaultLightingProfileCommand { get; private set; } = null!;
    public AsyncCommand AddQuietProfileCommand { get; private set; } = null!;
    public AsyncCommand AddHighProfileCommand { get; private set; } = null!;
    public AsyncCommand ImportLightingProfilesCommand { get; private set; } = null!;
    public AsyncCommand ExportLightingProfilesCommand { get; private set; } = null!;
    public AsyncCommand UseProfileProgramsCommand { get; private set; } = null!;

    private void InitializeLightingProfiles()
    {
        AsyncCommand Edit(Action action, string message) => new(() => { ChangeProfile(action, message); return Task.CompletedTask; });
        NewLightingProfileCommand = Edit(() => signalSettings.Profiles.Add([LightingProfile.Factory with { Id = Guid.NewGuid(), Name = "New profile" }]), "Created a profile.");
        DuplicateLightingProfileCommand = Edit(() =>
        {
            var selected = signalSettings.Profiles.Selected;
            string name = selected.Name.Length > 75 ? selected.Name[..75] : selected.Name;
            signalSettings.Profiles.Add([selected with { Id = Guid.NewGuid(), Name = name + " copy" }]);
        }, "Duplicated the selected profile.");
        DeleteLightingProfileCommand = Edit(signalSettings.Profiles.DeleteSelected, "Deleted the selected profile.");
        DefaultLightingProfileCommand = Edit(signalSettings.Profiles.SetDefault, "Saved the default profile.");
        UseDefaultLightingProfileCommand = Edit(signalSettings.Profiles.SelectDefault, "Selected the default profile.");
        UseProfileProgramsCommand = Edit(signalSettings.ClearOverrides, "Cleared advanced state overrides. Profile styles are active.");
        AddQuietProfileCommand = Edit(() => signalSettings.Profiles.Add([LightingProfile.Quiet]), "Added Quiet Night.");
        AddHighProfileCommand = Edit(() => signalSettings.Profiles.Add([LightingProfile.High]), "Added High Signal.");
        SaveLightingProfileCommand = Edit(() =>
        {
            var selected = signalSettings.Profiles.Selected with { Name = ProfileName, Strategy = ProfileStrategy, DeviceBrightness = ProfileBrightness };
            selected = selected.UpdateStyle(new(ProfileState, ProfileColor, ProfileMotion, ProfileCycle, ProfileIntensity, ProfileSecondaryColor, ProfileColorMode));
            signalSettings.Profiles.Update(selected);
        }, "Saved profile and state. Thinking and Tool Running share motion, speed and intensity; their colors stay independent.");
        ResetProfileStateCommand = Edit(() => signalSettings.Profiles.Update(signalSettings.Profiles.Selected.UpdateStyle(LightingProfile.Factory.Style(ProfileState))), "Restored this state's factory style.");
        ImportLightingProfilesCommand = new(() =>
        {
            var picker = new Microsoft.Win32.OpenFileDialog { Title = "Import SidePulse lighting profiles", Filter = "Lighting profiles (*.json)|*.json", CheckFileExists = true };
            if (picker.ShowDialog() == true) ChangeProfile(() => ImportLightingProfiles(picker.FileName), "Imported profiles. Duplicate identifiers receive new local identifiers.");
            return Task.CompletedTask;
        });
        ExportLightingProfilesCommand = new(() =>
        {
            var picker = new Microsoft.Win32.SaveFileDialog { Title = "Export lighting profile library", Filter = "Lighting profiles (*.json)|*.json", FileName = "Peel-lighting-profiles.json", AddExtension = true };
            if (picker.ShowDialog() == true) ChangeProfile(() => ExportLightingProfiles(picker.FileName), "Exported the profile library.");
            return Task.CompletedTask;
        });
        ReloadLightingProfiles();
    }
    internal void ImportLightingProfiles(string path) => signalSettings.Profiles.Add(LightingProfileStore.Import(LightingProfileStore.ReadBounded(path)));
    internal void ExportLightingProfiles(string path) => File.WriteAllBytes(path, LightingProfileStore.Export(signalSettings.Profiles.Read().Profiles));
    private void ChangeProfile(Action change, string message)
    {
        try
        {
            change(); ReloadLightingProfiles(); LoadSignalStyle(); RefreshSignalPresentation();
            SignalPublisher?.UpdateLocalActivity(LocalActivity); Updated?.Invoke(this, EventArgs.Empty); ProfileStatus = message;
        }
        catch (Exception e) when (e is IOException or InvalidDataException or UnauthorizedAccessException)
        { ProfileStatus = "Could not update profiles: " + e.Message; }
    }
    private void ReloadLightingProfiles()
    {
        loadingProfiles = true;
        try
        {
            LightingProfiles.Clear(); foreach (var profile in signalSettings.Profiles.Read().Profiles) LightingProfiles.Add(new(profile.Id.ToString("D"), profile.Name));
            var selected = signalSettings.Profiles.Selected;
            ProfileName = selected.Name; ProfileStrategy = selected.Strategy; ProfileBrightness = selected.DeviceBrightness;
            OnPropertyChanged(nameof(SelectedLightingProfile)); OnPropertyChanged(nameof(DefaultProfileLabel)); OnPropertyChanged(nameof(CanDeleteProfile));
            OnPropertyChanged(nameof(ProfileOverrideNote));
            OnPropertyChanged(nameof(ProfileStateChoices));
            LoadProfileStyle();
        }
        finally { loadingProfiles = false; }
    }
    private void LoadProfileStyle()
    {
        var style = signalSettings.Profiles.Selected.Style(ProfileState);
        ProfileColor = style.ColorHex; ProfileSecondaryColor = style.SecondaryColorHex; ProfileMotion = style.Motion;
        ProfileColorMode = style.ColorMode; ProfileIntensity = style.Intensity; ProfileCycle = style.CycleSeconds;
    }
    private void RefreshLightAllocations(LocalLightScene scene, IReadOnlyList<AgentActivityReading> readings)
    {
        var rows = new List<LightAllocationRow>();
        void Add(string output, LightAgent?[] slots)
        {
            foreach (var group in slots.Select((a, i) => (Agent: a, Index: i)).Where(p => p.Agent is not null).GroupBy(p => p.Agent!.Id))
            {
                var agent = group.First().Agent!;
                string label = agent.Id == "sidepulse:simple-signal" ? "Combined local activity" : readings.FirstOrDefault(r => r.Id == agent.Id)?.Project ?? agent.Id;
                if (agent.Id != "sidepulse:simple-signal") label += " · " + agent.Id[^Math.Min(8, agent.Id.Length)..];
                rows.Add(new(output, string.Join(", ", group.Select(p => p.Index + 1)), label, agent.State));
            }
        }
        Add("Pro", scene.ProSlots); Add("Dot", scene.DotSlots);
        if (!LightAllocations.SequenceEqual(rows)) { LightAllocations.Clear(); foreach (var row in rows) LightAllocations.Add(row); }
        AllocationStatus = scene.Error ?? (rows.Count == 0 ? "No local sessions are visible." : "Local allocation · lights numbered 1–8 on Pro and 1–2 on Dot. Paired sources keep the sender's programs.");
    }
}
