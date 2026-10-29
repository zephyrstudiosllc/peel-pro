using System.IO;
using System.Text.Json;

namespace Peel.Windows.Client.Services;

/// <summary>
/// Per-pairing explicit Listen Off, kept across reconnect and relaunch. Absent means the default
/// (Listen on). An explicit Start clears it. Only pairing identifiers are stored, never secrets.
/// A present but unreadable file fails toward no automatic playback rather than erasing an Off.
/// </summary>
public sealed class ClientAudioPreferenceStore
{
    private const int MaximumEntries = 64;
    private const int MaximumFileBytes = 32 * 1024;
    private readonly string path;
    private readonly object gate = new();
    private List<string>? listenOff;
    private bool unreadable;

    public ClientAudioPreferenceStore(string? path = null) =>
        this.path = path ?? Path.Combine(WindowsPairedHostStore.ClientDataDirectory, "audio-preferences.json");

    public bool IsExplicitOff(string pairingId)
    {
        lock (gate)
        {
            LoadLocked();
            return unreadable || listenOff!.Contains(pairingId, StringComparer.Ordinal);
        }
    }

    /// <summary>Records an explicit Off, or clears it for an explicit On. Returns false if it could not be saved.</summary>
    public bool SetExplicitOff(string pairingId, bool off)
    {
        if (string.IsNullOrEmpty(pairingId)) return false;
        string[] snapshot;
        lock (gate)
        {
            LoadLocked();
            listenOff!.RemoveAll(id => StringComparer.Ordinal.Equals(id, pairingId));
            if (off) listenOff.Add(pairingId);
            while (listenOff.Count > MaximumEntries) listenOff.RemoveAt(0);
            // The user's explicit choice replaces an unreadable file's unknown state.
            unreadable = false;
            snapshot = [.. listenOff];
        }
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            string temporary = path + ".tmp";
            File.WriteAllText(temporary, JsonSerializer.Serialize(new Document { ListenOff = snapshot }));
            File.Move(temporary, path, true);
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return false; }
    }

    private void LoadLocked()
    {
        if (listenOff is not null) return;
        listenOff = [];
        try
        {
            if (!File.Exists(path)) return;
            if (new FileInfo(path).Length > MaximumFileBytes) throw new InvalidDataException("Audio preferences are too large.");
            var document = JsonSerializer.Deserialize<Document>(File.ReadAllText(path));
            foreach (string? id in document?.ListenOff ?? [])
            {
                if (string.IsNullOrEmpty(id) || id.Length > 256) throw new InvalidDataException("Invalid audio preference.");
                listenOff.Add(id);
            }
            while (listenOff.Count > MaximumEntries) listenOff.RemoveAt(0);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or InvalidDataException)
        {
            listenOff.Clear();
            unreadable = true;
        }
    }

    private sealed class Document
    {
        [System.Text.Json.Serialization.JsonPropertyName("listenOff")]
        public string?[]? ListenOff { get; set; }
    }
}
