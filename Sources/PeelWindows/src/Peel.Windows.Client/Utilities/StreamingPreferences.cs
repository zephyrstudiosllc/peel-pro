using System.IO;
using System.Text.Json;
using Peel.Windows.Host.Encoding;
using Peel.Windows.Host.Runtime;

namespace Peel.Windows.Client.Utilities;

public sealed record StreamingPreferences(int FramesPerSecond = 60, int BitrateMbps = 30, bool HardwareEncoding = true, bool EnableHevc = true)
{
    private static string SettingsPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Zephyr Studios", "Peel", "Utilities", "streaming.json");
    public static StreamingPreferences Load()
    {
        try
        {
            if (!File.Exists(SettingsPath)) return new();
            if (new FileInfo(SettingsPath).Length > 4096) throw new InvalidDataException("Streaming preferences are too large.");
            var value = JsonSerializer.Deserialize<StreamingPreferences>(File.ReadAllText(SettingsPath)) ?? new();
            value.Validate(); return value;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or ArgumentException) { return new(); }
    }
    public void Save()
    {
        Validate(); Directory.CreateDirectory(Path.GetDirectoryName(SettingsPath)!);
        string temporary = SettingsPath + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(this)); File.Move(temporary, SettingsPath, true);
    }
    public void Validate()
    {
        if (FramesPerSecond is not (30 or 60 or 120) || BitrateMbps is < 4 or > 200)
            throw new ArgumentOutOfRangeException(nameof(FramesPerSecond), "Choose 30, 60, or 120 fps and 4–200 Mbps.");
    }
    public WindowsHostRuntimeOptions CreateRuntimeOptions()
    {
        Validate();
        bool hardwareH264 = HardwareEncoding && MediaFoundationCodecCatalog.Inspect(VideoCodec.H264, true).Any(x => x.Hardware);
        bool hevc = EnableHevc && (hardwareH264
            ? MediaFoundationCodecCatalog.Inspect(VideoCodec.Hevc, true).Any(x => x.Hardware)
            : MediaFoundationCodecCatalog.CanActivateSynchronous(VideoCodec.Hevc, true));
        return new(framesPerSecond: FramesPerSecond, targetBitrate: BitrateMbps * 1_000_000,
            enableHevc: hevc, hardwareEncoding: hardwareH264)
            { MachineStatusProvider = MachineStatusService.Shared, AudioSharing = HostAudioService.Shared };
    }
}
