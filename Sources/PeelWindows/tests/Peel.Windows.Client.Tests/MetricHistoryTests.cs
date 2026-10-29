using Peel.Windows.Client.Utilities;

namespace Peel.Windows.Client.Tests;
internal static partial class Program
{
    private static SystemReading MetricFixture(DateTimeOffset at, double? cpu = 42, double? write = 2097152) =>
        new(at, cpu, 8L << 30, 16L << 30, 100L << 30, 500L << 30, null, 100, 200, [], new(10, 1234, 5678, 1048576, write, 20));
    private static void MetricHistoryCoverage()
    {
        var at = DateTimeOffset.UtcNow; var history = new SystemMetricHistory();
        for (int i = 0; i < 120; i++) history.Add(MetricFixture(at.AddSeconds(i * 2)));
        True(history.Average("Disk write", TimeSpan.FromMinutes(5)) is null, "Less than 80% coverage stays unavailable.");
        history.Add(MetricFixture(at.AddSeconds(240)));
        Equal(2097152d, history.Average("Disk write", TimeSpan.FromMinutes(5))!.Value);
        True(history.Average("Disk write", TimeSpan.FromMinutes(15)) is null, "Five-minute history cannot pretend to cover fifteen minutes.");
        var weighted = new SystemMetricHistory();
        weighted.Add(MetricFixture(at, write: 999));
        weighted.Add(MetricFixture(at.AddSeconds(2), write: 10));
        weighted.Add(MetricFixture(at.AddSeconds(10), write: 20));
        Equal(18d, weighted.Average("Disk write", TimeSpan.FromSeconds(10))!.Value);
        weighted.Add(MetricFixture(at.AddSeconds(30), write: 10000));
        True(weighted.Average("Disk write", TimeSpan.FromSeconds(20)) is null, "A sampling gap must not count as zero or current activity.");
        weighted.Add(MetricFixture(at.AddSeconds(32), double.NaN, double.PositiveInfinity));
        True(weighted.Snapshot()[^1].Cpu is null && weighted.Snapshot()[^1].DiskWrite is null, "Non-finite data is unavailable.");
        weighted.Add(MetricFixture(at.AddSeconds(-1)));
        Equal(1, weighted.Snapshot().Count);
        for (int i = 0; i < 2000; i++) history.Add(MetricFixture(at.AddSeconds(242 + i * 2)));
        True(history.Snapshot().Count <= SystemMetricHistory.MaximumPoints, "History must stay fixed-size.");
        Equal(2097152d, history.Average("Disk write", TimeSpan.FromMinutes(15))!.Value);
        var sparse = new SystemMetricHistory();
        for (int i = 0; i <= 450; i++) sparse.Add(MetricFixture(at.AddSeconds(i * 2), write: i % 2 == 0 ? null : 50));
        True(sparse.Average("Disk write", TimeSpan.FromMinutes(15)) is null, "Unavailable samples cannot satisfy time coverage.");
        string root = Path.Combine(Path.GetTempPath(), "peel-metric-preferences-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root); string path = Path.Combine(root, "settings.json");
        try
        {
            var saved = new MechanicPreferences(5, true, false, true, 5, "Memory", "CPU", 5); saved.Save(path);
            Equal(saved, MechanicPreferences.Load(path));
            File.WriteAllText(path, "{\"GaugeMask\":32}"); Equal(new MechanicPreferences(), MechanicPreferences.Load(path));
            File.WriteAllText(path, new string('a', 4097)); Equal(new MechanicPreferences(), MechanicPreferences.Load(path));
        }
        finally { File.Delete(path); Directory.Delete(root); }
    }
}
