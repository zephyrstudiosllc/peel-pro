using System.IO;
using System.Text.Json;

namespace Peel.Windows.Client.Utilities;

public sealed record MechanicPreferences(int GaugeMask = 15, bool CombinedGauges = false, bool ShowBarGauge = true,
    bool ShowBarApps = true, int TopAppCount = 3, string Ranking = "CPU", string HistoryMetric = "Disk write", int HistoryMinutes = 15)
{
    private static string DefaultPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Zephyr Studios", "Peel", "Utilities", "mechanic.json");
    internal static readonly string[] Rankings = ["CPU", "Memory", "Name"];
    internal static readonly string[] Metrics = ["CPU", "Memory", "GPU", "Disk busy", "Disk read", "Disk write", "Network receive", "Network send"];
    internal void Validate()
    {
        if (GaugeMask is < 0 or > 15 || TopAppCount is not (3 or 5) || !Rankings.Contains(Ranking) ||
            !Metrics.Contains(HistoryMetric) || HistoryMinutes is not (5 or 15)) throw new InvalidDataException("Invalid App Mechanic preferences.");
    }
    internal static MechanicPreferences Load(string? path = null)
    {
        path ??= DefaultPath;
        try
        {
            if (!File.Exists(path)) return new();
            if (new FileInfo(path).Length > 4096) throw new InvalidDataException("App Mechanic preferences are too large.");
            var value = JsonSerializer.Deserialize<MechanicPreferences>(File.ReadAllText(path)) ?? new(); value.Validate(); return value;
        }
        catch (Exception e) when (e is IOException or InvalidDataException or UnauthorizedAccessException or JsonException) { return new(); }
    }
    internal void Save(string? path = null)
    {
        Validate(); path ??= DefaultPath; Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try { File.WriteAllText(temporary, JsonSerializer.Serialize(this)); File.Move(temporary, path, true); }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
