using Peel.Windows.Client.ViewModels;

namespace Peel.Windows.Client.Utilities;
public sealed partial class CommandCenterViewModel
{
    private readonly ProgressTasks progressTasks = new();
    private ProgressSnapshot progressSnapshot = ProgressSnapshot.Idle;
    private string progressCommand = "", progressDirectory = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), progressOutput = "";
    private int progressPid;
    private bool progressAnimation;
    public string ProgressCommand { get => progressCommand; set => SetProperty(ref progressCommand, value); }
    public string ProgressDirectory { get => progressDirectory; set => SetProperty(ref progressDirectory, value); }
    public int ProgressPid { get => progressPid; set => SetProperty(ref progressPid, value); }
    public bool ProgressAnimation { get => progressAnimation; set { if (SetProperty(ref progressAnimation, value)) RefreshSignalPresentation(); } }
    public string ProgressTitle => progressSnapshot.Title;
    public string ProgressStatus => progressSnapshot.Phase + (progressSnapshot.Percent is { } value ? $" · {value}%" : "") + " · " + progressSnapshot.Detail;
    public double ProgressValue => progressSnapshot.Percent ?? 0;
    public bool ProgressIndeterminate => progressSnapshot.Phase == "running" && progressSnapshot.Percent is null;
    public string ProgressOutputText => progressOutput;
    public AsyncCommand RunProgressCommand { get; private set; } = null!;
    public AsyncCommand WatchProgressCommand { get; private set; } = null!;
    public AsyncCommand WatchSelectedAppCommand { get; private set; } = null!;
    public AsyncCommand CancelProgressCommand { get; private set; } = null!;
    public AsyncCommand ClearProgressCommand { get; private set; } = null!;
    public AsyncCommand CopyProgressOutputCommand { get; private set; } = null!;
    private void InitializeProgress()
    {
        RunProgressCommand = new(() => { ProgressAction(() => progressTasks.Run(ProgressCommand, ProgressDirectory)); return Task.CompletedTask; });
        WatchProgressCommand = new(() => { ProgressAction(() => progressTasks.Watch(ProgressPid)); return Task.CompletedTask; });
        WatchSelectedAppCommand = new(() =>
        {
            if (SelectedProcess is { } app) ProgressAction(() => progressTasks.Watch(app.Id, app.StartedUtcTicks));
            else Notice = "Select an app in App Mechanic first.";
            return Task.CompletedTask;
        });
        CancelProgressCommand = new(() => { progressTasks.Cancel(); RefreshProgress(); return Task.CompletedTask; });
        ClearProgressCommand = new(() => { progressTasks.Clear(); RefreshProgress(); if (!progressTasks.Running && LightMode == "Progress") LightMode = "Agent activity"; return Task.CompletedTask; });
        CopyProgressOutputCommand = new(() =>
        {
            try { System.Windows.Clipboard.SetText(progressTasks.Output(false)); }
            catch (System.Runtime.InteropServices.ExternalException) { Notice = "The clipboard is busy; try copying again."; }
            return Task.CompletedTask;
        });
    }
    private void ProgressAction(Action action)
    {
        try { action(); LightMode = "Progress"; RefreshProgress(); }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException) { Notice = e.Message; }
    }
    private void RefreshProgress()
    {
        var next = progressTasks.Snapshot;
        if (next != progressSnapshot)
        {
            if (AlertsEnabled && progressSnapshot.Phase == "running" && next.Phase is "completed" or "failed") PublishAlert("Progress task · " + next.Phase);
            progressSnapshot = next;
            foreach (string property in new[] { nameof(ProgressTitle), nameof(ProgressStatus), nameof(ProgressValue), nameof(ProgressIndeterminate) }) OnPropertyChanged(property);
        }
        string output = progressTasks.Output();
        if (progressOutput != output) { progressOutput = output; OnPropertyChanged(nameof(ProgressOutputText)); }
    }
    private UtilityScene ProgressScene()
    {
        var state = progressTasks.Snapshot;
        string label = "Progress · " + state.Phase + (state.Percent is { } percent ? $" · {percent}%" : "");
        if (state.Phase is "idle" or "cancelled") return new("progress:" + state.Phase, label, "off", "off");
        bool running = state.Phase == "running", failed = state.Phase == "failed";
        string color = failed ? "#FF453A" : running ? "#0A84FF" : "#30D158";
        string motion = failed ? "flash" : running ? "breathe" : "solid";
        double intensity = failed ? .9 : running ? .7 : .85;
        double fraction = running && !ProgressAnimation && state.Percent is { } value ? value / 100d : 1;
        string pro = UtilityScenes.Program(color, intensity, 8, fraction, motion, failed ? .8 : 1.6);
        string dot = UtilityScenes.Program(color, intensity, 2, fraction, motion, failed ? .8 : 1.6);
        return new("progress:" + pro, label, pro, dot);
    }
}
