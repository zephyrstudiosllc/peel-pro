namespace Peel.Windows.Client.Utilities;

public sealed record MetricHistoryPoint(DateTimeOffset At, double? Cpu, double? Memory, double? Gpu, double? DiskBusy,
    double? DiskRead, double? DiskWrite, double? Receive, double? Send)
{
    public double? Value(string metric) => metric switch
    {
        "CPU" => Cpu, "Memory" => Memory, "GPU" => Gpu, "Disk busy" => DiskBusy,
        "Disk read" => DiskRead, "Disk write" => DiskWrite, "Network receive" => Receive, "Network send" => Send, _ => null,
    };
    public static bool IsPercentage(string metric) => metric is "CPU" or "Memory" or "GPU" or "Disk busy";
}

/// <summary>Fifteen minutes of local metric values, never process names or durable telemetry.</summary>
internal sealed class SystemMetricHistory
{
    private readonly Queue<MetricHistoryPoint> points = new();
    internal const int MaximumPoints = 512;
    internal static readonly TimeSpan MaximumInterval = TimeSpan.FromSeconds(10);
    internal IReadOnlyList<MetricHistoryPoint> Snapshot() => points.ToArray();
    internal void Add(SystemReading sample)
    {
        if (points.Count > 0 && sample.SampledAt <= points.Last().At) points.Clear(); // Wall-clock correction starts a new observation window.
        points.Enqueue(new(sample.SampledAt, Percent(sample.CpuPercent), sample.MemoryTotalBytes > 0 ? Percent(sample.MemoryPercent) : null,
            Percent(sample.Hardware?.GpuPercent), Percent(sample.Hardware?.DiskBusyPercent), Rate(sample.Hardware?.DiskReadBytesPerSecond),
            Rate(sample.Hardware?.DiskWriteBytesPerSecond), Rate(sample.ReceiveBytesPerSecond), Rate(sample.SendBytesPerSecond)));
        // Keep one extra boundary sample for clipping the oldest interval.
        while (points.Count > MaximumPoints || points.Count > 1 && sample.SampledAt - points.Peek().At > TimeSpan.FromMinutes(15) + MaximumInterval) points.Dequeue();
    }
    internal double? Average(string metric, TimeSpan window)
    {
        if (points.Count < 2 || window <= TimeSpan.Zero) return null;
        var rows = points.ToArray(); var start = rows[^1].At - window;
        double covered = 0, weighted = 0;
        for (int i = 1; i < rows.Length; i++)
        {
            var interval = rows[i].At - rows[i - 1].At;
            if (interval <= TimeSpan.Zero || interval > MaximumInterval || rows[i].At <= start || rows[i].Value(metric) is not double value) continue;
            double seconds = (rows[i].At - (rows[i - 1].At > start ? rows[i - 1].At : start)).TotalSeconds;
            covered += seconds; weighted += value * seconds;
        }
        return covered >= window.TotalSeconds * .8 ? weighted / covered : null;
    }
    private static double? Percent(double? value) => value is { } v && double.IsFinite(v) && v is >= 0 and <= 100 ? v : null;
    private static double? Rate(double? value) => value is { } v && double.IsFinite(v) && v >= 0 ? v : null;
}
