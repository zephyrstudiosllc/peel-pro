using System.Text.Json;
using Peel.Windows.Protocol;

namespace Peel.Windows.Protocol.Tests;
internal static partial class Program
{
    private static void StreamDiagnosticsContract()
    {
        var av = new AvPerformanceMetric(100, 2, 0, 80, .05, 4, 1, 98);
        var stream = new ClientStreamMetric(7, "75A3ED2E-A97A-4C71-BBA0-884837F6267F", "displayLayer", 5120, 2880, 100, 12345,
            99, 1, 0, 0, 0, 0, 4, 120, 1, false, null, av);
        var message = new ClientStreamMetricsMessage(1, 1000, [stream]);
        True(message.IsValid, "Native Apple receiver shape must validate.");
        var bytes = PeelJson.Serialize(message); var roundtrip = PeelJson.Deserialize<ClientStreamMetricsMessage>(bytes);
        True(roundtrip.IsValid, "Receiver report must round trip.");
        using var json = JsonDocument.Parse(bytes);
        True(!json.RootElement.TryGetProperty("IsValid", out _), "Local validation flags must not enter wire JSON.");
        var metric = json.RootElement.GetProperty("streams")[0];
        Equal(120, metric.GetProperty("screenMaximumFPS").GetInt32());
        Equal(98d, metric.GetProperty("avPerformance").GetProperty("estimatedPresentedFPS").GetDouble());
        foreach (var invalid in new[] { message with { Sequence = 0 }, message with { Sequence = ulong.MaxValue }, message with { Version = 2 },
            message with { Type = "unknown" }, message with { SampledAtClientUptimeSeconds = double.NaN }, message with { Streams = [stream, stream] },
            message with { UntrackedRendererRegistrations = -1 }, message with { Streams = null! }, message with { Streams = Enumerable.Repeat(stream, 33).ToArray() } })
            True(!invalid.IsValid, "Invalid receiver envelope must be rejected.");
        foreach (var invalid in new[] { stream with { Width = 0 }, stream with { Height = 16385 }, stream with { RendererGeneration = "bad" },
            stream with { RendererKind = "windowsWpf" }, stream with { ReceivedFrames = -1 }, stream with { ReceivedBytes = 9_000_000_000_001 },
            stream with { QueuedFrames = 257 }, stream with { QueuedBytes = -1 }, stream with { ScreenMaximumFps = 0 }, stream with { DisplayLayerStatus = 3 },
            stream with { LastReceivedFrameAgeMilliseconds = double.PositiveInfinity }, stream with { OldestQueuedFrameAgeMilliseconds = -1 },
            stream with { RendererKind = "spatialUninstrumented" }, stream with { AvPerformance = av with { DroppedFrames = 101 } },
            stream with { AvPerformance = av with { IntervalSeconds = null } }, stream with { AvPerformance = av with { SampleAgeMilliseconds = double.NaN } } })
            True(!invalid.IsValid, "Invalid or invented renderer observations must be rejected.");
        True(new ClientStreamMetric(0, Guid.NewGuid().ToString(), "spatialUninstrumented", 1, 1, 0, 0).IsValid, "Uninstrumented Apple renderer must omit unavailable fields.");
        Throws<JsonException>(() => PeelJson.Deserialize<ClientStreamMetricsMessage>("{}"u8));
        Throws<JsonException>(() => PeelJson.Deserialize<ClientStreamMetricsMessage>("{\"type\":\"clientStreamMetrics\",\"version\":1,\"sequence\":1,\"sampledAtClientUptimeSeconds\":1,\"untrackedRendererRegistrations\":0,\"streams\":[{}]}"u8));
    }
}
