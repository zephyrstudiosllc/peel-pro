using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
namespace Peel.Linux;

/// <summary>Receiver presentation toggles and the explicit per-pair Listen Off choice.
/// Pairing IDs are stored only as domain-separated SHA-256; no host, key or ticket data.
/// An existing but unreadable file suppresses automatic Listen for every pair (fail
/// toward the user's possible Off) until an explicit choice rewrites it.</summary>
internal sealed class LinuxReceiverPreferences
{
    internal const string ShowVolumeKey = "peel.controls.showVolume", ShowMediaKey = "peel.controls.showMediaControls";
    private const int MaximumOffPairs = 256, MaximumBytes = 32 * 1024;
    private readonly object gate = new();
    private readonly string? path;
    private readonly HashSet<string> audioOff = new(StringComparer.Ordinal);
    private bool showVolume = true, showMedia = true, unreadable;

    internal LinuxReceiverPreferences(string? path)
    {
        this.path = path;
        if (path is null) return;
        try
        {
            NoLinks(path);
            if (!File.Exists(path)) return;
            if (new FileInfo(path).Length > MaximumBytes) throw new InvalidDataException();
            using var document = JsonDocument.Parse(File.ReadAllBytes(path));
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("schema", out var schema) || schema.GetInt32() != 1) throw new InvalidDataException();
            showVolume = root.GetProperty(ShowVolumeKey).GetBoolean();
            showMedia = root.GetProperty(ShowMediaKey).GetBoolean();
            var off = root.GetProperty("audioOffPairings");
            if (off.ValueKind != JsonValueKind.Array || off.GetArrayLength() > MaximumOffPairs) throw new InvalidDataException();
            foreach (var row in off.EnumerateArray())
            {
                string value = row.GetString() ?? throw new InvalidDataException();
                if (value.Length != 64 || !value.All(char.IsAsciiHexDigitLower)) throw new InvalidDataException();
                audioOff.Add(value);
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or InvalidDataException or InvalidOperationException or KeyNotFoundException or FormatException)
        {
            unreadable = true; audioOff.Clear(); showVolume = true; showMedia = true;
        }
    }

    internal static LinuxReceiverPreferences OpenDefault()
    {
        try
        {
            string parent = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            if (!Path.IsPathFullyQualified(parent)) return new(null);
            string root = Path.Combine(parent, "PeelPro", "Receiver");
            NoLinks(root); Directory.CreateDirectory(root); NoLinks(root);
            if (OperatingSystem.IsLinux()) File.SetUnixFileMode(root, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            return new(Path.Combine(root, "preferences.json"));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return new(null); }
    }

    internal bool ShowVolume { get { lock (gate) return showVolume; } }
    internal bool ShowMedia { get { lock (gate) return showMedia; } }

    internal bool IsAudioOff(string pairingId)
    {
        string key = Key(pairingId);
        lock (gate) return unreadable || audioOff.Contains(key);
    }

    /// <summary>Only an explicit user Listen choice calls this; lifecycle stops never do.</summary>
    internal void SetAudioOff(string pairingId, bool off)
    {
        string key = Key(pairingId);
        lock (gate)
        {
            unreadable = false;
            if (off) { if (audioOff.Count >= MaximumOffPairs && !audioOff.Contains(key)) audioOff.Remove(audioOff.First()); audioOff.Add(key); }
            else audioOff.Remove(key);
            SaveLocked();
        }
    }

    /// <summary>In-memory now (GTK main may call this); persist with <see cref="Save"/> off that thread.
    /// Any save writes the latest values, so reordered saves cannot restore an older choice.</summary>
    internal void SetVisibility(bool? volume, bool? media)
    {
        lock (gate)
        {
            if (volume is { } v) showVolume = v;
            if (media is { } m) showMedia = m;
        }
    }

    internal void Save() { lock (gate) SaveLocked(); }

    internal static string Key(string pairingId)
    {
        if (string.IsNullOrEmpty(pairingId) || pairingId.Length > 1024) throw new ArgumentException("Invalid pairing.", nameof(pairingId));
        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes("peel.receiver.audio-off.v1\0" + pairingId)));
    }

    private void SaveLocked()
    {
        // An unreadable file is kept (and keeps suppressing auto Listen) until an explicit Listen choice.
        if (path is null || unreadable) return;
        try
        {
            NoLinks(path);
            byte[] data = JsonSerializer.SerializeToUtf8Bytes(new Dictionary<string, object>
            {
                ["schema"] = 1, [ShowVolumeKey] = showVolume, [ShowMediaKey] = showMedia, ["audioOffPairings"] = audioOff.Order(StringComparer.Ordinal).ToArray(),
            });
            if (data.Length > MaximumBytes) return;
            string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                var options = new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write };
                if (OperatingSystem.IsLinux()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
                using (var file = new FileStream(temporary, options)) { file.Write(data); file.Flush(true); }
                NoLinks(path); File.Move(temporary, path, true);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { /* In-memory choice still applies this run. */ }
    }

    private static void NoLinks(string path)
    {
        for (string? current = Path.GetFullPath(path); current is not null; current = Path.GetDirectoryName(current))
            if (new FileInfo(current).LinkTarget is not null) throw new IOException("Symlinked receiver storage is not supported.");
    }
}
