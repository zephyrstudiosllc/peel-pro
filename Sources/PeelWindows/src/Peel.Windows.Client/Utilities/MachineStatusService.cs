using System.IO;
using System.Text;
using Peel.Windows.Host.Networking;
using Peel.Windows.Protocol;

namespace Peel.Windows.Client.Utilities;

public sealed class MachineStatusService : IHostMachineStatusProvider
{
    public static MachineStatusService Shared { get; } = new();
    private readonly string preferencePath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Zephyr Studios", "Peel", "Utilities", "share-status.txt");
    private bool enabled;
    private long consentVersion;
    public long ConsentVersion => Interlocked.Read(ref consentVersion);
    private SystemReading? reading;
    private UsageWindow[] usage = [];
    public bool Enabled => Volatile.Read(ref enabled);
    private MachineStatusService()
    {
        try { enabled = File.Exists(preferencePath) && new FileInfo(preferencePath).Length < 16 && File.ReadAllText(preferencePath) == "enabled"; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { enabled = false; }
    }
    public void SetEnabled(bool value)
    {
        Interlocked.Increment(ref consentVersion);
        // Revoking takes effect immediately even if disk persistence subsequently fails.
        if (!value) Volatile.Write(ref enabled, false);
        Directory.CreateDirectory(Path.GetDirectoryName(preferencePath)!);
        File.WriteAllText(preferencePath, value ? "enabled" : "disabled");
        Volatile.Write(ref enabled, value);
    }
    public void Update(SystemReading value) => Volatile.Write(ref reading, value);
    public void UpdateUsage(IEnumerable<UsageWindow> value) => Volatile.Write(ref usage, value.Take(8).ToArray());
    public ValueTask<MachineStatusMessage> ReadAsync(string requestId, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var sample = Volatile.Read(ref reading);
        double now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
        if (!Enabled || sample is null || DateTimeOffset.UtcNow - sample.SampledAt > TimeSpan.FromSeconds(15))
            return ValueTask.FromResult(new MachineStatusMessage(requestId, now, Bounded(Environment.MachineName), LocalStatus: "Current readings are unavailable."));
        var windows = Volatile.Read(ref usage).Where(w => DateTimeOffset.UtcNow - w.SampledAt < TimeSpan.FromMinutes(10))
            .Select(w => new MachineStatusUsage(Bounded(w.Label), double.IsFinite(w.UsedPercent) ? w.UsedPercent : null,
                w.ResetsAt?.ToUnixTimeMilliseconds() / 1000.0)).ToArray();
        return ValueTask.FromResult(new MachineStatusMessage(requestId, sample.SampledAt.ToUnixTimeMilliseconds() / 1000.0,
            Bounded(Environment.MachineName), sample.CpuPercent / 100, sample.MemoryPercent / 100,
            (ulong)sample.MemoryUsedBytes, (ulong)sample.MemoryTotalBytes, (ulong)sample.StorageFreeBytes,
            (ulong)sample.StorageTotalBytes, sample.BatteryPercent / 100, sample.ReceiveBytesPerSecond, sample.SendBytesPerSecond,
            GpuFraction: sample.Hardware?.GpuPercent / 100,
            TopApps: sample.Processes.Where(p => p.HasWindow).Take(5).Select(p => new MachineStatusApp(Bounded(p.Name), p.Id,
                p.CpuPercent * Environment.ProcessorCount, (ulong)Math.Max(0, p.MemoryBytes))).ToArray(),
            Usage: windows, LocalStatus: "Windows memory occupancy; process CPU uses per-core percentages."));
    }
    private static string Bounded(string text)
    {
        var result = new StringBuilder(); int bytes = 0;
        foreach (var rune in text.EnumerateRunes())
        {
            if (rune.Value < 32 || rune.Value == 127) continue;
            if (bytes + rune.Utf8SequenceLength > 256) break;
            result.Append(rune); bytes += rune.Utf8SequenceLength;
        }
        return result.Length == 0 ? "Unnamed" : result.ToString();
    }
}
