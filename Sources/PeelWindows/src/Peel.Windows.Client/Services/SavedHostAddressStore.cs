using System.IO;
using System.Net;
using System.Text.Json;

namespace Peel.Windows.Client.Services;

public sealed record SavedHostAddress(string HostId, string Label, string Address, int Port);

public sealed class SavedHostAddressStore
{
    private readonly object gate = new();
    private readonly string path;
    private SavedHostAddress[] records = [];

    public SavedHostAddressStore(string? path = null)
    {
        this.path = path ?? Path.Combine(WindowsPairedHostStore.ClientDataDirectory, "addresses.json");
        if (!File.Exists(this.path)) return;
        if (new FileInfo(this.path).Length > 32 * 1024) throw new InvalidDataException("Saved addresses are oversized.");
        var loaded = JsonSerializer.Deserialize<SavedHostAddress[]>(File.ReadAllBytes(this.path))
            ?? throw new InvalidDataException("Saved addresses are invalid.");
        if (loaded.Length > 16) throw new InvalidDataException("Too many saved addresses.");
        foreach (var item in loaded) Validate(item);
        if (loaded.Select(r => r.HostId).Distinct(StringComparer.Ordinal).Count() != loaded.Length)
            throw new InvalidDataException("Duplicate saved computer identities.");
        records = loaded;
    }

    public IReadOnlyList<SavedHostAddress> Snapshot() { lock (gate) return records.ToArray(); }

    public void Save(SavedHostAddress address)
    {
        Validate(address);
        lock (gate)
        {
            var updated = records.Where(r => r.HostId != address.HostId).Append(address).ToArray();
            if (updated.Length > 16) throw new InvalidOperationException("At most 16 saved computers are supported.");
            Persist(updated);
        }
    }

    public void Remove(string hostId) { lock (gate) Persist(records.Where(r => r.HostId != hostId).ToArray()); }

    public void Prune(IReadOnlySet<string> pairedIds)
    {
        lock (gate)
        {
            var updated = records.Where(r => pairedIds.Contains(r.HostId)).ToArray();
            if (updated.Length != records.Length) Persist(updated);
        }
    }

    private void Persist(SavedHostAddress[] updated)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        var temporary = path + ".tmp";
        File.WriteAllBytes(temporary, JsonSerializer.SerializeToUtf8Bytes(updated));
        File.Move(temporary, path, overwrite: true);
        records = updated;
    }

    public static void Validate(SavedHostAddress value)
    {
        if (value is null || !Guid.TryParse(value.HostId, out _) || string.IsNullOrWhiteSpace(value.Label)
            || value.Label.Length > 256 || value.Label.Any(char.IsControl)
            || value.Port is < 1 or > 65535 || !IsPrivateAddress(value.Address))
            throw new ArgumentException("Use a paired computer, a label, a private/VPN address, and port 1–65535.");
    }

    internal static bool IsPrivateAddress(string address)
    {
        if (string.IsNullOrWhiteSpace(address) || address.Length > 253 || address != address.Trim()) return false;
        if (IPAddress.TryParse(address, out var ip))
        {
            if (ip.IsIPv4MappedToIPv6) ip = ip.MapToIPv4();
            if (IPAddress.IsLoopback(ip)) return true;
            var b = ip.GetAddressBytes();
            return b.Length == 4
                ? b[0] == 10 || (b[0] == 172 && b[1] is >= 16 and <= 31) || (b[0] == 192 && b[1] == 168)
                    || (b[0] == 100 && b[1] is >= 64 and <= 127) || (b[0] == 169 && b[1] == 254)
                : ip.IsIPv6LinkLocal || (b[0] & 0xfe) == 0xfc;
        }
        var name = address.TrimEnd('.');
        return (name.EndsWith(".local", StringComparison.OrdinalIgnoreCase)
                || name.EndsWith(".ts.net", StringComparison.OrdinalIgnoreCase) || !name.Contains('.'))
            && name.Split('.').All(p => p.Length is > 0 and <= 63 && char.IsAsciiLetterOrDigit(p[0])
                && char.IsAsciiLetterOrDigit(p[^1]) && p.All(c => char.IsAsciiLetterOrDigit(c) || c == '-'));
    }
}
