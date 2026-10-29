using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Peel.Windows.Client.Utilities;

internal sealed record LightStyle(
    [property: JsonRequired] string State,
    [property: JsonRequired] string ColorHex,
    [property: JsonRequired] string Motion,
    [property: JsonRequired] double CycleSeconds,
    [property: JsonRequired] double Intensity,
    string SecondaryColorHex = "#7C3AED", string ColorMode = "single")
{
    internal static readonly string[] Motions = ["off", "solid", "flash", "pulse", "breathe", "chase", "converge", "diverge"];
    internal static readonly string[] ColorModes = ["single", "colorway", "rainbow", "rotatingColorway"];
    internal LightStyle Validate()
    {
        string state = State == "progress" ? "working" : State;
        string motion = Motion switch { "heartbeat" or "solidFade" => "pulse", "shimmer" => "breathe", _ => Motion };
        if (!SignalSettings.States.Contains(state) || !Motions.Contains(motion) || !ColorModes.Contains(ColorMode) ||
            !IsColor(ColorHex) || !IsColor(SecondaryColorHex) || !double.IsFinite(CycleSeconds) || CycleSeconds is < .2 or > 30 ||
            !double.IsFinite(Intensity) || Intensity is < 0 or > 1) throw new InvalidDataException("Invalid profile light style.");
        return this with { State = state, Motion = motion, ColorHex = ColorHex.ToUpperInvariant(), SecondaryColorHex = SecondaryColorHex.ToUpperInvariant() };
    }
    internal static bool IsColor(string? value) => value is { Length: 7 } && value[0] == '#' && value.AsSpan(1).IndexOfAnyExcept("0123456789abcdefABCDEF") < 0;
}

internal sealed record LightingProfile(
    [property: JsonRequired] Guid Id, [property: JsonRequired] string Name,
    [property: JsonRequired] string Symbol, [property: JsonRequired] string Strategy,
    [property: JsonRequired] double DeviceBrightness, [property: JsonRequired] LightStyle[] Styles)
{
    internal static readonly string[] Strategies = ["adaptiveOccupancy", "stableAgents", "providerLanes", "priorityStack"];
    internal LightStyle Style(string state) => Styles.FirstOrDefault(s => s.State == state) ?? new(state, "#FFFFFF", "solid", 2, .5);
    internal LightingProfile Validate()
    {
        if (Id == Guid.Empty || string.IsNullOrWhiteSpace(Name) || Name.Length > 80 || Name.Any(char.IsControl) ||
            Symbol is null || Symbol.Length > 80 || Symbol.Any(char.IsControl) || !Strategies.Contains(Strategy) ||
            !double.IsFinite(DeviceBrightness) || DeviceBrightness is < 0 or > 1 || Styles is null || Styles.Length is < 1 or > 6 || Styles.Any(s => s is null))
            throw new InvalidDataException("Invalid lighting profile.");
        var styles = Styles.Select(s => s.Validate()).ToArray();
        if (styles.Select(s => s.State).Distinct().Count() != styles.Length) throw new InvalidDataException("Profile states must be unique.");
        return this with { Name = Name.Trim(), Styles = styles };
    }
    internal LightingProfile UpdateStyle(LightStyle style)
    {
        style = style.Validate(); var styles = Styles.Where(s => s.State != style.State).Append(style).ToList();
        if (style.State is "working" or "toolRunning")
        {
            string other = style.State == "working" ? "toolRunning" : "working";
            var companion = Style(other) with { Motion = style.Motion, CycleSeconds = style.CycleSeconds, Intensity = style.Intensity };
            styles.RemoveAll(s => s.State == other); styles.Add(companion);
        }
        return (this with { Styles = styles.ToArray() }).Validate();
    }
    internal static LightingProfile Factory => new(new("1b91f090-339b-4c53-8dd2-74ff1f1e0611"), "Default", "command", "adaptiveOccupancy", .72,
    [
        new("idle", "#EEF9E0", "off", 8, 0),
        new("working", "#FF2BD6", "breathe", 1.0340260549065254, .41507945559610704, "#DBD1EE"),
        new("toolRunning", "#0018FF", "breathe", 1.0340260549065254, .41507945559610704),
        new("waiting", "#FFD60A", "flash", .7369829683698299, .88),
        new("error", "#FF0000", "solid", 1, .95),
        new("completed", "#00D300", "solid", 1, .85),
    ]);
    internal static LightingProfile Quiet => Factory with { Id = new("7159fd95-bb00-483d-ba83-a619787972b4"), Name = "Quiet Night", Symbol = "moon.stars.fill", DeviceBrightness = .28,
        Styles = Factory.Styles.Select(s => s with { Intensity = s.Intensity * .45, CycleSeconds = s.CycleSeconds * 1.35, Motion = s.Motion == "chase" ? "breathe" : s.Motion }).ToArray() };
    internal static LightingProfile High => Factory with { Id = new("658ce9cf-17fc-4cb1-93fa-b60134121391"), Name = "High Signal", Symbol = "bolt.fill", DeviceBrightness = 1,
        Styles = Factory.Styles.Select(s => s with { Intensity = Math.Min(1, s.Intensity * 1.3) }).ToArray() };
}

internal sealed record LightingLibrary(int SchemaVersion, LightingProfile[] Profiles, Guid SelectedProfileID, Guid DefaultProfileID);
internal sealed record LightingArchive(
    [property: JsonRequired] string Format, [property: JsonRequired] int FormatVersion,
    [property: JsonRequired] string ExportedAt, [property: JsonRequired] LightingProfile[] Profiles);
internal sealed class LightingProfileStore
{
    internal const int MaxBytes = 256 * 1024, MaxProfiles = 32;
    internal static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true, MaxDepth = 12 };
    private readonly string path;
    private readonly object gate = new();
    private LightingLibrary library = new(9, [LightingProfile.Factory], LightingProfile.Factory.Id, LightingProfile.Factory.Id);
    internal LightingProfileStore(string path)
    {
        this.path = path;
        try { if (File.Exists(path)) library = Validate(JsonSerializer.Deserialize<LightingLibrary>(ReadBounded(path), Json) ?? throw new InvalidDataException("Missing profile library.")); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or InvalidDataException) { }
    }
    internal LightingLibrary Read() { lock (gate) return library with { Profiles = library.Profiles.Select(p => p with { Styles = p.Styles.ToArray() }).ToArray() }; }
    internal LightingProfile Selected { get { var current = Read(); return current.Profiles.Single(p => p.Id == current.SelectedProfileID); } }
    internal void Save(LightingLibrary value)
    {
        value = Validate(value); byte[] data = JsonSerializer.SerializeToUtf8Bytes(value, Json);
        if (data.Length > MaxBytes) throw new InvalidDataException("Profile library is too large.");
        lock (gate)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!); string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try { File.WriteAllBytes(temporary, data); File.Move(temporary, path, true); library = value; }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
    }
    internal void Select(Guid id) { lock (gate) Save(library with { SelectedProfileID = id }); }
    internal void SetDefault() { lock (gate) Save(library with { DefaultProfileID = library.SelectedProfileID }); }
    internal void SelectDefault() { lock (gate) Select(library.DefaultProfileID); }
    internal void Update(LightingProfile profile)
    {
        lock (gate)
        {
            if (!library.Profiles.Any(p => p.Id == profile.Id)) throw new InvalidDataException("The selected profile no longer exists.");
            Save(library with { Profiles = library.Profiles.Select(p => p.Id == profile.Id ? profile : p).ToArray() });
        }
    }
    internal void Add(IEnumerable<LightingProfile> profiles)
    {
        lock (gate)
        {
            var result = library.Profiles.ToList(); Guid selected = library.SelectedProfileID; bool first = true;
            foreach (var input in profiles)
            {
                var profile = input.Validate();
                if (result.Any(p => p.Id == profile.Id)) profile = profile with { Id = Guid.NewGuid() };
                result.Add(profile); if (first) { selected = profile.Id; first = false; }
            }
            Save(library with { Profiles = result.ToArray(), SelectedProfileID = selected });
        }
    }
    internal void DeleteSelected()
    {
        lock (gate)
        {
            if (library.Profiles.Length == 1) throw new InvalidDataException("Keep at least one profile.");
            var profiles = library.Profiles.Where(p => p.Id != library.SelectedProfileID).ToArray();
            Guid fallback = profiles.Any(p => p.Id == library.DefaultProfileID) ? library.DefaultProfileID : profiles[0].Id;
            Save(library with { Profiles = profiles, SelectedProfileID = fallback, DefaultProfileID = fallback });
        }
    }
    internal static byte[] ReadBounded(string path)
    {
        using var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 4096, FileOptions.SequentialScan);
        using var output = new MemoryStream(); byte[] buffer = new byte[4096]; int count;
        while ((count = input.Read(buffer)) != 0) { if (output.Length + count > MaxBytes) throw new InvalidDataException("Profile file exceeds 256 KiB."); output.Write(buffer, 0, count); }
        return output.ToArray();
    }
    internal static byte[] Export(IEnumerable<LightingProfile> profiles)
    {
        var validated = ValidateProfiles(profiles.ToArray());
        // Foundation's .iso8601 decoder requires whole seconds (no fractional suffix).
        byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(new LightingArchive("com.zephyrstudios.sidepulse.profiles", 1,
            DateTimeOffset.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", System.Globalization.CultureInfo.InvariantCulture), validated), Json);
        if (bytes.Length > MaxBytes) throw new InvalidDataException("Profile archive is too large."); return bytes;
    }
    internal static LightingProfile[] Import(ReadOnlySpan<byte> data)
    {
        if (data.Length > MaxBytes) throw new InvalidDataException("Profile file exceeds 256 KiB.");
        try
        {
            var archive = JsonSerializer.Deserialize<LightingArchive>(data, Json);
            if (archive is null || archive.Format != "com.zephyrstudios.sidepulse.profiles" || archive.FormatVersion != 1) throw new InvalidDataException("Unsupported SidePulse profile archive.");
            if (!DateTimeOffset.TryParseExact(archive.ExportedAt, ["yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd'T'HH:mm:sszzz"],
                System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AssumeUniversal, out _))
                throw new InvalidDataException("Invalid profile export date.");
            return ValidateProfiles(archive.Profiles);
        }
        catch (JsonException e) { throw new InvalidDataException("Invalid SidePulse profile JSON.", e); }
    }
    private static LightingProfile[] ValidateProfiles(LightingProfile[]? profiles)
    {
        if (profiles is null || profiles.Length is < 1 or > MaxProfiles || profiles.Any(p => p is null)) throw new InvalidDataException("A library must contain 1–32 profiles.");
        var validated = profiles.Select(p => p.Validate()).ToArray();
        if (validated.Select(p => p.Id).Distinct().Count() != validated.Length) throw new InvalidDataException("Profile identifiers must be unique.");
        return validated;
    }
    private static LightingLibrary Validate(LightingLibrary library)
    {
        var profiles = ValidateProfiles(library.Profiles);
        if (library.SchemaVersion != 9 || !profiles.Any(p => p.Id == library.SelectedProfileID) || !profiles.Any(p => p.Id == library.DefaultProfileID))
            throw new InvalidDataException("Invalid profile selection.");
        return library with { Profiles = profiles };
    }
}
