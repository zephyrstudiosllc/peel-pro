using System.IO;
using System.Text.Json;

namespace Peel.Windows.Client.Utilities;

public sealed class AlertPolicy
{
    public bool CpuAlertsEnabled { get; set; } = true;
    public bool MemoryAlertsEnabled { get; set; } = true;
    public double CpuThreshold { get; set; } = 60;
    public double MemoryThresholdMb { get; set; } = 1280;
    public int ConsecutiveSamples { get; set; } = 6;
    public int CooldownSeconds { get; set; } = 300;
    public bool NotifyTopAppChanged { get; set; }
    public string WatchedApp { get; set; } = "";
    public bool MemoryProtectionEnabled { get; set; }
    public string MemoryProtectionApp { get; set; } = "ChatGPT";
    public double MemoryProtectionMb { get; set; } = 4096;
    private static string PathName => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Zephyr Studios", "Peel", "Utilities", "alert-rules.json");
    public void Validate()
    {
        if (!double.IsFinite(CpuThreshold) || CpuThreshold is < 1 or > 100000 ||
            !double.IsFinite(MemoryThresholdMb) || MemoryThresholdMb is < 64 or > 1048576 ||
            !double.IsFinite(MemoryProtectionMb) || MemoryProtectionMb is < 256 or > 1048576 ||
            ConsecutiveSamples is < 2 or > 150 || CooldownSeconds is < 10 or > 86400 ||
            WatchedApp is null || MemoryProtectionApp is null || WatchedApp.Length > 120 || MemoryProtectionApp.Length > 120 ||
            WatchedApp.Any(char.IsControl) || MemoryProtectionApp.Any(char.IsControl) ||
            MemoryProtectionEnabled && string.IsNullOrWhiteSpace(MemoryProtectionApp))
            throw new ArgumentException("Use finite thresholds, 2–150 samples, a 10–86400 second cooldown, and bounded app names.");
    }
    public void Save()
    {
        Validate(); Directory.CreateDirectory(Path.GetDirectoryName(PathName)!);
        string temporary = PathName + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(this)); File.Move(temporary, PathName, true);
    }
    public static AlertPolicy Load()
    {
        try
        {
            if (!File.Exists(PathName) || new FileInfo(PathName).Length > 8192) return new();
            var value = JsonSerializer.Deserialize<AlertPolicy>(File.ReadAllText(PathName)) ?? new(); value.Validate();
            // Automatic process suspension requires renewed consent each Peel session.
            value.MemoryProtectionEnabled = false; return value;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or ArgumentException) { return new(); }
    }
}

public sealed record AlertEvaluation(IReadOnlyList<string> Notices, IReadOnlyList<ProcessReading> HoldCandidates);

public sealed class AlertEvaluator
{
    private readonly Dictionary<(int Id, long Start, string Kind), int> streaks = new();
    private readonly Dictionary<string, DateTimeOffset> notified = new();
    private HashSet<(int, long)> previous = new();
    private (int, long)? previousTop;
    private bool sampled;
    public AlertEvaluation Evaluate(SystemReading sample, AlertPolicy policy, bool notify, int processorCount)
    {
        policy.Validate();
        var notices = new List<string>(); var holds = new List<ProcessReading>();
        var current = new HashSet<(int, long)>();
        foreach (var app in sample.Processes.Where(p => p.HasWindow && p.Id != Environment.ProcessId).Take(512))
        {
            var identity = (app.Id, app.StartedUtcTicks); current.Add(identity);
            bool Match(string kind, bool matched)
            {
                var key = (app.Id, app.StartedUtcTicks, kind);
                if (!matched) { streaks.Remove(key); return false; }
                streaks.TryGetValue(key, out int count); streaks[key] = Math.Min(count + 1, policy.ConsecutiveSamples);
                return streaks[key] >= policy.ConsecutiveSamples;
            }
            void Report(string kind, string message)
            {
                if (notify && Admit(kind, sample.SampledAt, policy.CooldownSeconds)) notices.Add(message);
            }
            if (Match("cpu", policy.CpuAlertsEnabled && app.CpuPercent * processorCount >= policy.CpuThreshold))
                Report("cpu", $"{app.Name} sustained {app.CpuPercent * processorCount:F0}% CPU (per-core scale).");
            if (Match("memory", policy.MemoryAlertsEnabled && app.MemoryBytes / 1048576.0 >= policy.MemoryThresholdMb))
                Report("memory", $"{app.Name} sustained {app.MemoryBytes / 1048576.0:N0} MB memory.");
            if (sampled && !previous.Contains(identity) && !string.IsNullOrWhiteSpace(policy.WatchedApp) && app.Name.Contains(policy.WatchedApp, StringComparison.OrdinalIgnoreCase))
                Report("watch", $"{app.Name} appeared (PID {app.Id}).");
            if (Match("protection", policy.MemoryProtectionEnabled && string.Equals(app.Name, policy.MemoryProtectionApp.Trim(), StringComparison.OrdinalIgnoreCase)
                && app.MemoryBytes / 1048576.0 >= policy.MemoryProtectionMb) && Admit("hold:" + app.Id, sample.SampledAt, policy.CooldownSeconds))
                holds.Add(app);
        }
        var top = sample.Processes.FirstOrDefault(p => p.HasWindow && p.Id != Environment.ProcessId);
        (int, long)? topIdentity = top is null ? null : (top.Id, top.StartedUtcTicks);
        if (sampled && notify && policy.NotifyTopAppChanged && top is not null && topIdentity != previousTop && Admit("top", sample.SampledAt, policy.CooldownSeconds))
            notices.Add($"Most active app changed to {top.Name}.");
        foreach (var key in streaks.Keys.Where(k => !current.Contains((k.Id, k.Start))).ToArray()) streaks.Remove(key);
        foreach (var key in notified.Where(n => sample.SampledAt - n.Value > TimeSpan.FromDays(1)).Select(n => n.Key).ToArray()) notified.Remove(key);
        previous = current; previousTop = topIdentity; sampled = true;
        return new(notices, holds);
    }
    private bool Admit(string key, DateTimeOffset now, int cooldown)
    {
        if (notified.TryGetValue(key, out var last) && now - last < TimeSpan.FromSeconds(cooldown)) return false;
        if (notified.Count >= 1024) return false;
        notified[key] = now; return true;
    }
}
