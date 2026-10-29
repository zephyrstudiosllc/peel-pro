using System.IO;
using System.Text.Json;

namespace Peel.Windows.Client.Utilities;
internal sealed record TimerPreferences(int Seconds = 1500, int WarningSeconds = 60, bool Animation = false)
{
    private static string PathName => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Zephyr Studios", "Peel", "Utilities", "timer.json");
    private bool Valid => Seconds is >= 1 and <= 86400 && WarningSeconds >= 0 && WarningSeconds <= Seconds;
    internal static TimerPreferences Load(string? path = null)
    {
        path ??= PathName;
        try
        {
            if (File.Exists(path) && new FileInfo(path).Length <= 2048 && JsonSerializer.Deserialize<TimerPreferences>(File.ReadAllText(path)) is { Valid: true } value) return value;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { }
        return new();
    }
    internal void Save(string? path = null)
    {
        if (!Valid) throw new InvalidDataException("Invalid countdown settings.");
        path ??= PathName; Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try { File.WriteAllText(temporary, JsonSerializer.Serialize(this)); File.Move(temporary, path, true); }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
