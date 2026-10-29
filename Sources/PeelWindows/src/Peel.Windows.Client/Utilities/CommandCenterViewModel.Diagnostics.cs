using System.Text.Json;
using Peel.Windows.Host.Diagnostics;

namespace Peel.Windows.Client.Utilities;

public sealed partial class CommandCenterViewModel
{
    public bool StreamingDiagnosticsEnabled
    {
        get => StreamDiagnostics.Shared.Enabled;
        set { StreamDiagnostics.Shared.SetEnabled(value); OnPropertyChanged(); RefreshDiagnostics(); }
    }
    private string diagnosticsSummary = "Streaming diagnostics are off.", diagnosticsJson = "";
    public string DiagnosticsSummary { get => diagnosticsSummary; private set => SetProperty(ref diagnosticsSummary, value); }
    public string DiagnosticsJson { get => diagnosticsJson; private set => SetProperty(ref diagnosticsJson, value); }
    public StreamingDiagnosticsSnapshot ReadStreamingDiagnostics() => StreamDiagnostics.Shared.Snapshot();
    private void RefreshDiagnostics()
    {
        if (!StreamingDiagnosticsEnabled) { DiagnosticsSummary = "Streaming diagnostics are off."; DiagnosticsJson = ""; return; }
        var snapshot = ReadStreamingDiagnostics();
        DiagnosticsSummary = snapshot.Streams.Count == 0 ? "Diagnostics on · waiting for a stream." : string.Join(Environment.NewLine, snapshot.Streams.Select(row =>
        {
            double Rate(StreamStage stage) => row.Stages.FirstOrDefault(s => s.Stage == stage.ToString())?.EventsPerSecond ?? 0;
            string activity = row.Role == "host" ? $"capture {Rate(StreamStage.Captured):F1} · encode {Rate(StreamStage.Encoded):F1} · sent {Rate(StreamStage.Sent):F1} fps"
                : $"received {Rate(StreamStage.Received):F1} · decoded {Rate(StreamStage.Decoded):F1} · viewer {Rate(StreamStage.Presented):F1} updates/s";
            return $"{row.Role} #{row.WindowId} · {(row.Active ? "active" : "stopped")} · {row.Width} × {row.Height} {row.Codec} · {activity}";
        }));
        DiagnosticsJson = JsonSerializer.Serialize(snapshot, new JsonSerializerOptions { WriteIndented = true, PropertyNamingPolicy = JsonNamingPolicy.CamelCase });
    }
}
