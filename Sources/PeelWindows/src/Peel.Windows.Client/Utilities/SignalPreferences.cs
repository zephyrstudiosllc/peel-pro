using System.IO;
using System.Text.Json;
using Peel.Windows.Protocol;

namespace Peel.Windows.Client.Utilities;

public sealed record SignalSourceChoice(string Id, string Label);
public sealed record SignalPrograms(string Pro, string Dot);
internal sealed record SignalPreferences(string Source = "automatic", string SourceLabel = "Automatic · local first", bool ShowLights = true, bool ShowUsage = true, string DisplayMode = "simple")
{
    internal void Validate()
    {
        if (Source is null || Source != "automatic" && Source != "local" && Source != "paired" &&
            !(Source.StartsWith("host:", StringComparison.Ordinal) && Guid.TryParseExact(Source[5..], "D", out _)) ||
            SourceLabel is null || SourceLabel.Length > 256 || SourceLabel.Any(char.IsControl) || DisplayMode is not ("simple" or "perAgent")) throw new InvalidDataException("Invalid signal source preference.");
    }
}
internal sealed record SignalSettingsDocument(SignalPreferences Presentation, Dictionary<string, SignalPrograms> Styles);

/// <summary>Only display preferences/programs persist. Network and hardware consent never does.</summary>
internal sealed class SignalSettings
{
    internal static readonly string[] States = ["idle", "working", "toolRunning", "waiting", "error", "completed"];
    internal static SignalSettings Shared { get; } = new();
    private readonly string path;
    private readonly object sync = new();
    private SignalSettingsDocument current = new(new(), []);
    internal LightingProfileStore Profiles { get; }
    internal SignalSettings(string? path = null)
    {
        this.path = path ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Zephyr Studios", "Peel", "Utilities", "signals.json");
        Profiles = new(Path.Combine(Path.GetDirectoryName(Path.GetFullPath(this.path))!, "lighting-profiles.json"));
        try
        {
            if (!File.Exists(this.path)) return;
            if (new FileInfo(this.path).Length > 16384) throw new InvalidDataException("Signal settings are too large.");
            var saved = JsonSerializer.Deserialize<SignalSettingsDocument>(File.ReadAllText(this.path)) ?? throw new InvalidDataException("Missing signal settings.");
            Validate(saved); current = saved;
        }
        catch (Exception e) when (e is IOException or InvalidDataException or UnauthorizedAccessException or JsonException) { }
    }
    internal SignalPreferences Presentation { get { lock (sync) return current.Presentation; } }
    internal SignalPrograms Programs(string state)
    {
        if (state == "progress") state = "working";
        if (Override(state) is { } program) return program;
        var now = DateTimeOffset.UtcNow;
        var agents = new[] { new LightAgent("preview", state, now) };
        var profile = Profiles.Selected;
        return new(AgentLighting.Compile(profile, agents, new(), 8, now).Program, AgentLighting.Compile(profile, agents, new(), 2, now).Program);
    }
    internal SignalPrograms? Override(string state) { lock (sync) return current.Styles.GetValueOrDefault(state); }
    internal void ClearOverrides() { lock (sync) Save(current with { Styles = [] }); }
    internal void SavePresentation(SignalPreferences preferences)
    { lock (sync) Save(current with { Presentation = preferences }); }
    internal void SaveStyle(string state, SignalPrograms? program)
    {
        if (!States.Contains(state)) throw new InvalidDataException("Unknown signal state.");
        lock (sync)
        {
            var styles = new Dictionary<string, SignalPrograms>(current.Styles);
            if (program is null) styles.Remove(state); else styles[state] = program;
            Save(current with { Styles = styles });
        }
    }
    private void Save(SignalSettingsDocument value)
    {
        Validate(value); Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try { File.WriteAllText(temporary, JsonSerializer.Serialize(value)); File.Move(temporary, path, true); current = value; }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    private static void Validate(SignalSettingsDocument value)
    {
        if (value.Presentation is null || value.Styles is null || value.Styles.Count > 6) throw new InvalidDataException("Invalid signal settings.");
        value.Presentation.Validate();
        foreach (var (state, program) in value.Styles)
        {
            if (!States.Contains(state) || program is null) throw new InvalidDataException("Invalid signal style.");
            TrustedSignals.ValidateProgram(program.Pro); TrustedSignals.ValidateProgram(program.Dot);
        }
    }
}
