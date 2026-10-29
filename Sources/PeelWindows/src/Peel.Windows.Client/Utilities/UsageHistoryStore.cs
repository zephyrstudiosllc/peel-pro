using System.IO;
using System.Text.Json;

namespace Peel.Windows.Client.Utilities;

public sealed record UsagePreferences(bool AutomaticRefresh = true, string PinnedId = "", string PinnedLabel = "");
public sealed record UsageChoice(string Id, string Label);
internal sealed class UsageHistoryStore
{
    private readonly string folder;
    public UsageHistoryStore(string? folder = null) => this.folder = folder ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Zephyr Studios", "Peel", "Utilities");
    public UsagePreferences LoadPreferences()
    {
        var value = Read<UsagePreferences>("usage-settings.json", 8192);
        return value is { PinnedId.Length: <= 512, PinnedLabel.Length: <= 256 } ? value : new();
    }
    public void SavePreferences(UsagePreferences value) => Save("usage-settings.json", value);
    public IReadOnlyList<UsageWindow> ReadHistory()
    {
        var rows = Read<UsageWindow[]>("usage-history.json", 4 * 1024 * 1024) ?? [];
        return Valid(rows);
    }
    private static UsageWindow[] Valid(IEnumerable<UsageWindow> rows) => rows.Where(r => r is not null && double.IsFinite(r.UsedPercent) && r.UsedPercent is >= 0 and <= 100 &&
            r.Provider is { Length: <= 100 } && r.Label is { Length: <= 256 } && r.WindowId is { Length: <= 512 } &&
            r.Source is { Length: <= 256 } && r.SampledAt > DateTimeOffset.UtcNow.AddDays(-30) &&
            r.SampledAt <= DateTimeOffset.UtcNow.AddMinutes(5)).TakeLast(4096).ToArray();
    public IReadOnlyList<UsageWindow> Append(IReadOnlyList<UsageWindow> rows)
    {
        var history = Valid(ReadHistory().Concat(rows.Take(128)));
        Save("usage-history.json", history); return history;
    }
    private T? Read<T>(string name, long maximum)
    {
        try
        {
            string path = Path.Combine(folder, name);
            return File.Exists(path) && new FileInfo(path).Length <= maximum ? JsonSerializer.Deserialize<T>(File.ReadAllText(path)) : default;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { return default; }
    }
    private void Save<T>(string name, T value)
    {
        Directory.CreateDirectory(folder); string path = Path.Combine(folder, name), temporary = path + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(value)); File.Move(temporary, path, true);
    }
}
