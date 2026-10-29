namespace Peel.Windows.Client.Utilities;

public sealed record MechanicGauge(string Name, string Value, string Detail);

public sealed partial class CommandCenterViewModel
{
    private MechanicPreferences mechanic = MechanicPreferences.Load();
    private readonly SystemMetricHistory metricHistory = new();
    public IReadOnlyList<MetricHistoryPoint> HistorySamples { get; private set; } = [];
    public string[] ProcessRankings => MechanicPreferences.Rankings;
    public string[] HistoryMetrics => MechanicPreferences.Metrics;
    public int[] HistoryDurations { get; } = [5, 15];
    public int[] TopAppCounts { get; } = [3, 5];
    public string ProcessRanking { get => mechanic.Ranking; set { if (value is not null) SaveMechanic(mechanic with { Ranking = value }); } }
    public string HistoryMetric { get => mechanic.HistoryMetric; set { if (value is not null) SaveMechanic(mechanic with { HistoryMetric = value }); } }
    public int HistoryMinutes { get => mechanic.HistoryMinutes; set => SaveMechanic(mechanic with { HistoryMinutes = value }); }
    public int TopAppCount { get => mechanic.TopAppCount; set => SaveMechanic(mechanic with { TopAppCount = value }); }
    public bool ShowBarGauge { get => mechanic.ShowBarGauge; set => SaveMechanic(mechanic with { ShowBarGauge = value }); }
    public bool ShowBarApps { get => mechanic.ShowBarApps; set => SaveMechanic(mechanic with { ShowBarApps = value }); }
    public bool CombinedGauges { get => mechanic.CombinedGauges; set => SaveMechanic(mechanic with { CombinedGauges = value }); }
    public bool GaugeCpu { get => HasGauge(1); set => SetGauge(1, value); }
    public bool GaugeMemory { get => HasGauge(2); set => SetGauge(2, value); }
    public bool GaugeDisk { get => HasGauge(4); set => SetGauge(4, value); }
    public bool GaugeGpu { get => HasGauge(8); set => SetGauge(8, value); }
    public string TopAppsLabel => string.Join(Environment.NewLine, RankedProcesses().Where(p => p.HasWindow).Take(TopAppCount)
        .Select(p => $"{p.Name} · {p.CpuLabel} CPU · {p.MemoryLabel}"));
    public string SelectedGaugesLabel
    {
        get
        {
            var values = new (bool Include, string Name, double? Value)[] { (GaugeCpu, "CPU", reading?.CpuPercent),
                (GaugeMemory, "RAM occupancy", reading is { MemoryTotalBytes: > 0 } ? reading.MemoryPercent : null),
                (GaugeDisk, "Disk busy", reading?.Hardware?.DiskBusyPercent), (GaugeGpu, "GPU", reading?.Hardware?.GpuPercent) };
            var selected = values.Where(v => v.Include).ToArray();
            var available = selected.Where(v => v.Value is { } n && double.IsFinite(n) && n is >= 0 and <= 100).ToArray();
            if (selected.Length == 0) return "No gauges selected";
            if (CombinedGauges) return available.Length == 0 ? "Combined activity: unavailable" :
                $"Combined activity {available.Average(v => v.Value!.Value):F0}% · {available.Length}/{selected.Length} gauges available";
            return string.Join(" · ", selected.Select(v => $"{v.Name} " + (v.Value is { } n && double.IsFinite(n) && n is >= 0 and <= 100 ? $"{n:F0}%" : "unavailable")));
        }
    }
    public string HistoryAverageLabel => $"{HistoryMetric} · 5 min {AverageLabel(5)} · 15 min {AverageLabel(15)}";
    public string DiskWriteHistoryLabel => $"Writes · now {RateLabel(reading?.Hardware?.DiskWriteBytesPerSecond)} · 5 min {RateLabel(metricHistory.Average("Disk write", TimeSpan.FromMinutes(5)))} · 15 min {RateLabel(metricHistory.Average("Disk write", TimeSpan.FromMinutes(15)))}";
    public string GpuMemoryLabel => reading?.Hardware is { } h
        ? $"GPU memory · dedicated {BytesLabel(h.DedicatedBytes)} · shared {BytesLabel(h.SharedBytes)}" : "GPU memory unavailable";
    public IReadOnlyList<MechanicGauge> GaugeCards
    {
        get
        {
            var selected = new List<MechanicGauge>();
            if (CombinedGauges) return [new("SELECTED GAUGES", SelectedGaugesLabel, "Average of available readings")];
            if (GaugeCpu) selected.Add(new("CPU", CpuLabel, "Total machine capacity"));
            if (GaugeMemory) selected.Add(new("RAM OCCUPANCY", reading is { MemoryTotalBytes: > 0 } ? $"{reading.MemoryPercent:F0}%" : "Unavailable", MemoryLabel));
            if (GaugeDisk) selected.Add(new("DISK BUSY", reading?.Hardware?.DiskBusyPercent is { } disk ? $"{disk:F0}%" : "Unavailable", "Physical disks · busy time"));
            if (GaugeGpu) selected.Add(new("GPU", reading?.Hardware?.GpuPercent is { } gpu ? $"{gpu:F0}%" : "Unavailable", "Busiest GPU engine"));
            return selected;
        }
    }
    public int GaugeColumns => Math.Max(1, GaugeCards.Count);
    public string SystemDetailLabel => $"Storage: {StorageLabel} · {DiskIoLabel}" + Environment.NewLine + $"Network: {NetworkLabel} · Battery: {BatteryLabel}";
    private static string BytesLabel(double? bytes) => bytes is { } n && double.IsFinite(n) && n >= 0 ? $"{n / 1048576:F0} MB" : "unavailable";
    private static string RateLabel(double? value) => value is { } n ? $"{n / 1048576:F2} MB/s" : "unavailable";
    private string AverageLabel(int minutes)
    {
        var average = metricHistory.Average(HistoryMetric, TimeSpan.FromMinutes(minutes));
        return MetricHistoryPoint.IsPercentage(HistoryMetric) ? average is { } n ? $"{n:F1}%" : "unavailable" : RateLabel(average);
    }
    private bool HasGauge(int mask) => (mechanic.GaugeMask & mask) != 0;
    private void SetGauge(int mask, bool enabled) => SaveMechanic(mechanic with { GaugeMask = enabled ? mechanic.GaugeMask | mask : mechanic.GaugeMask & ~mask });
    private IEnumerable<ProcessReading> RankedProcesses()
    {
        var rows = reading?.Processes ?? [];
        return ProcessRanking switch { "Memory" => rows.OrderByDescending(p => p.MemoryBytes).ThenByDescending(p => p.CpuPercent),
            "Name" => rows.OrderBy(p => p.Name, StringComparer.OrdinalIgnoreCase).ThenBy(p => p.Id),
            _ => rows.OrderByDescending(p => p.CpuPercent).ThenByDescending(p => p.MemoryBytes) };
    }
    private void SaveMechanic(MechanicPreferences value)
    {
        if (value == mechanic) return;
        try { value.Save(); mechanic = value; }
        catch (Exception e) when (e is System.IO.IOException or System.IO.InvalidDataException or UnauthorizedAccessException) { Notice = "Could not save App Mechanic preferences."; }
        RefreshProcessRows();
        foreach (var name in new[] { nameof(ProcessRanking), nameof(HistoryMetric), nameof(HistoryMinutes), nameof(TopAppCount), nameof(ShowBarGauge), nameof(ShowBarApps),
            nameof(CombinedGauges), nameof(GaugeCpu), nameof(GaugeMemory), nameof(GaugeDisk), nameof(GaugeGpu) }) OnPropertyChanged(name);
        NotifyMechanic(); Updated?.Invoke(this, EventArgs.Empty);
    }
    private void NotifyMechanic()
    {
        foreach (var name in new[] { nameof(SelectedGaugesLabel), nameof(GaugeCards), nameof(GaugeColumns), nameof(SystemDetailLabel), nameof(HistoryAverageLabel), nameof(DiskWriteHistoryLabel), nameof(GpuMemoryLabel), nameof(TopAppLabel), nameof(TopAppsLabel), nameof(TraySummary) }) OnPropertyChanged(name);
    }
    private void RecordMechanic(SystemReading sample)
    { metricHistory.Add(sample); HistorySamples = metricHistory.Snapshot(); OnPropertyChanged(nameof(HistorySamples)); NotifyMechanic(); }
}
