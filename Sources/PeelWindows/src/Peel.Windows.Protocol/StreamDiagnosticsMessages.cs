using System.Text.Json.Serialization;

namespace Peel.Windows.Protocol;

public sealed record ClientStreamMetricsMessage(
    [property: JsonPropertyName("sequence"), JsonRequired] ulong Sequence,
    [property: JsonPropertyName("sampledAtClientUptimeSeconds"), JsonRequired] double SampledAtClientUptimeSeconds,
    [property: JsonPropertyName("streams"), JsonRequired] IReadOnlyList<ClientStreamMetric> Streams,
    [property: JsonPropertyName("untrackedRendererRegistrations"), JsonRequired] long UntrackedRendererRegistrations = 0,
    [property: JsonPropertyName("version"), JsonRequired] int Version = 1,
    [property: JsonPropertyName("type"), JsonRequired] string Type = "clientStreamMetrics")
{
    public const string Capability = "stream-diagnostics-v1";
    [JsonIgnore] public bool IsValid => Type == "clientStreamMetrics" && Version == 1 && Sequence is > 0 and <= long.MaxValue &&
        StreamMetricBounds.Time(SampledAtClientUptimeSeconds) && StreamMetricBounds.Counter(UntrackedRendererRegistrations) &&
        Streams is { Count: <= 32 } && Streams.All(s => s is not null && s.IsValid) && Streams.Select(s => s.WindowId).Distinct().Count() == Streams.Count;
}

public sealed record ClientStreamMetric(
    [property: JsonPropertyName("windowId"), JsonRequired] uint WindowId,
    [property: JsonPropertyName("rendererGeneration"), JsonRequired] string RendererGeneration,
    [property: JsonPropertyName("rendererKind"), JsonRequired] string RendererKind,
    [property: JsonPropertyName("width"), JsonRequired] int Width,
    [property: JsonPropertyName("height"), JsonRequired] int Height,
    [property: JsonPropertyName("receivedFrames"), JsonRequired] long ReceivedFrames,
    [property: JsonPropertyName("receivedBytes"), JsonRequired] long ReceivedBytes,
    [property: JsonPropertyName("enqueuedFrames")] long? EnqueuedFrames = null,
    [property: JsonPropertyName("applicationDroppedFrames")] long? ApplicationDroppedFrames = null,
    [property: JsonPropertyName("recoveryRequests")] long? RecoveryRequests = null,
    [property: JsonPropertyName("queuedFrames")] int? QueuedFrames = null,
    [property: JsonPropertyName("queuedBytes")] int? QueuedBytes = null,
    [property: JsonPropertyName("oldestQueuedFrameAgeMilliseconds")] double? OldestQueuedFrameAgeMilliseconds = null,
    [property: JsonPropertyName("lastReceivedFrameAgeMilliseconds")] double? LastReceivedFrameAgeMilliseconds = null,
    [property: JsonPropertyName("screenMaximumFPS")] int? ScreenMaximumFps = null,
    [property: JsonPropertyName("displayLayerStatus")] int? DisplayLayerStatus = null,
    [property: JsonPropertyName("displayLayerRequiresFlush")] bool? DisplayLayerRequiresFlush = null,
    [property: JsonPropertyName("displayLayerErrorCode")] int? DisplayLayerErrorCode = null,
    [property: JsonPropertyName("avPerformance")] AvPerformanceMetric? AvPerformance = null)
{
    [JsonIgnore] public bool IsValid => Guid.TryParseExact(RendererGeneration, "D", out _) && RendererKind is "displayLayer" or "spatialUninstrumented" &&
        Width is >= 1 and <= 16384 && Height is >= 1 and <= 16384 && StreamMetricBounds.Counter(ReceivedFrames) && StreamMetricBounds.Counter(ReceivedBytes) &&
        StreamMetricBounds.Counter(EnqueuedFrames) && StreamMetricBounds.Counter(ApplicationDroppedFrames) && StreamMetricBounds.Counter(RecoveryRequests) &&
        (QueuedFrames is null or (>= 0 and <= 256)) && (QueuedBytes is null or (>= 0 and <= 128 * 1024 * 1024)) &&
        StreamMetricBounds.Time(OldestQueuedFrameAgeMilliseconds) && StreamMetricBounds.Time(LastReceivedFrameAgeMilliseconds) &&
        (ScreenMaximumFps is null or (>= 1 and <= 1000)) && (DisplayLayerStatus is null or (>= 0 and <= 2)) && (AvPerformance?.IsValid ?? true) &&
        (RendererKind != "spatialUninstrumented" || AvPerformance is null && EnqueuedFrames is null && ApplicationDroppedFrames is null &&
            RecoveryRequests is null && QueuedFrames is null && QueuedBytes is null && OldestQueuedFrameAgeMilliseconds is null && DisplayLayerStatus is null &&
            DisplayLayerRequiresFlush is null && DisplayLayerErrorCode is null);
}

public sealed record AvPerformanceMetric(
    [property: JsonPropertyName("totalFrames"), JsonRequired] long TotalFrames,
    [property: JsonPropertyName("droppedFrames"), JsonRequired] long DroppedFrames,
    [property: JsonPropertyName("corruptedFrames"), JsonRequired] long CorruptedFrames,
    [property: JsonPropertyName("optimizedCompositingFrames"), JsonRequired] long OptimizedCompositingFrames,
    [property: JsonPropertyName("accumulatedFrameDelaySeconds"), JsonRequired] double AccumulatedFrameDelaySeconds,
    [property: JsonPropertyName("sampleAgeMilliseconds"), JsonRequired] double SampleAgeMilliseconds,
    [property: JsonPropertyName("intervalSeconds")] double? IntervalSeconds = null,
    [property: JsonPropertyName("estimatedPresentedFPS")] double? EstimatedPresentedFps = null)
{
    [JsonIgnore] public bool IsValid => StreamMetricBounds.Counter(TotalFrames) && StreamMetricBounds.Counter(DroppedFrames) && StreamMetricBounds.Counter(CorruptedFrames) &&
        StreamMetricBounds.Counter(OptimizedCompositingFrames) && DroppedFrames <= TotalFrames && OptimizedCompositingFrames <= TotalFrames &&
        StreamMetricBounds.Time(AccumulatedFrameDelaySeconds) && StreamMetricBounds.Time(SampleAgeMilliseconds) &&
        (IntervalSeconds is null || double.IsFinite(IntervalSeconds.Value) && IntervalSeconds is > 0 and <= 60) &&
        (EstimatedPresentedFps is null || double.IsFinite(EstimatedPresentedFps.Value) && EstimatedPresentedFps is >= 0 and <= 1000 && IntervalSeconds is not null);
}

internal static class StreamMetricBounds
{
    internal static bool Counter(long? value) => value is null or (>= 0 and <= 9_000_000_000_000);
    internal static bool Time(double? value) => value is null || double.IsFinite(value.Value) && value is >= 0 and <= 1_000_000_000_000;
}
