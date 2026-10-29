using System.Diagnostics;

namespace Peel.Windows.Client.Utilities;
public sealed partial class CommandCenterViewModel
{
    private bool onAirEnabled;
    private long onAirEpoch;
    private MicrophoneActivitySnapshot microphone = MicrophoneActivitySnapshot.Unavailable("Observation is off.");
    public Func<int>? ActiveHostedStreams { get; set; }
    public bool OnAirEnabled
    {
        get => onAirEnabled;
        set
        {
            if (!SetProperty(ref onAirEnabled, value)) return;
            Interlocked.Increment(ref onAirEpoch);
            microphone = MicrophoneActivitySnapshot.Unavailable(value ? "Waiting for an input-session observation…" : "Observation is off.");
            if (value) LightMode = "ON AIR";
            OnPropertyChanged(nameof(OnAirStatus)); OnPropertyChanged(nameof(OnAirDevices)); RefreshSignalPresentation();
        }
    }
    public string OnAirStatus => !OnAirEnabled ? "ON AIR observation is off." : microphone.Fresh ? microphone.Detail : "Input-session observation is stale.";
    public string OnAirDevices => OnAirEnabled ? microphone.Devices : "";
    public string OnAirCaptureStatus => $"Peel Pro is hosting {ActiveHostedStreams?.Invoke() ?? 0} video source(s).";
    private (long Epoch, MicrophoneActivitySnapshot? Snapshot) ReadOnAir()
    {
        long epoch = Interlocked.Read(ref onAirEpoch);
        return (epoch, Volatile.Read(ref onAirEnabled) ? MicrophoneActivity.Read() : null);
    }
    private void ApplyOnAir((long Epoch, MicrophoneActivitySnapshot? Snapshot) observation)
    {
        if (OnAirEnabled && observation.Epoch == Interlocked.Read(ref onAirEpoch) && observation.Snapshot is { } snapshot) microphone = snapshot;
        OnPropertyChanged(nameof(OnAirStatus)); OnPropertyChanged(nameof(OnAirDevices)); OnPropertyChanged(nameof(OnAirCaptureStatus));
    }
    private UtilityScene OnAirScene()
    {
        if (!OnAirEnabled) return new("onair:off", "ON AIR observation off", "off", "off");
        string state = microphone.Fresh ? microphone.State : "unavailable";
        bool capturing = (ActiveHostedStreams?.Invoke() ?? 0) > 0;
        if (state == "active" || capturing)
        {
            string key = state == "active" ? "onair:ON AIR · microphone session active" : "onair:ON AIR · Peel video capture active";
            string label = state == "active" ? "ON AIR · microphone session active" : "ON AIR · Peel Pro video capture active";
            return new(key, label, UtilityScenes.Program("#FF9F0A", .9, 8, motion: "converge", seconds: 1.8), UtilityScenes.Program("#FF9F0A", .9, 2, motion: "converge", seconds: 1.8));
        }
        if (state == "muted") return new("onair:muted", "ON AIR · active input endpoints muted", UtilityScenes.Program("#FFD60A", .6, 8), UtilityScenes.Program("#FFD60A", .6, 2));
        return new("onair:" + state, state == "unavailable" ? "ON AIR · input status unavailable" : "ON AIR · no active capture sessions observed", "off", "off");
    }
}
