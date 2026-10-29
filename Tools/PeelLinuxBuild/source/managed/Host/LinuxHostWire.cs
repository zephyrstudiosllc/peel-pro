using System.Text;
using System.Text.Json;
using Peel.Windows.Protocol;
namespace Peel.Linux.Host;
internal static class LinuxHostWire
{
    internal const int Limit = 16384;
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    internal static bool Text(string? value, int max)
    {
        if (value is not { Length: > 0 } || value.Length > max || value.Any(char.IsControl)) return false;
        try { return StrictUtf8.GetByteCount(value) <= max * 4; } catch (EncoderFallbackException) { return false; }
    }
    internal static JsonDocument Parse(byte[] data)
    {
        if (data.Length is 0 or > Limit) throw new InvalidDataException("Message exceeds its bound.");
        var d = JsonDocument.Parse(data, new JsonDocumentOptions { MaxDepth = 8 });
        try { Check(d.RootElement); return d; } catch { d.Dispose(); throw; }
    }
    private static void Check(JsonElement e)
    {
        if (e.ValueKind == JsonValueKind.Object)
        {
            var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (var p in e.EnumerateObject())
            { if (!seen.Add(p.Name) || seen.Count > 32) throw new InvalidDataException("Duplicate or excessive JSON keys."); Check(p.Value); }
        }
        else if (e.ValueKind == JsonValueKind.Array)
        { if (e.GetArrayLength() > 64) throw new InvalidDataException("Array exceeds its bound."); foreach (var item in e.EnumerateArray()) Check(item); }
    }
    internal static void Exact(JsonElement e, params string[] keys)
    {
        if (e.ValueKind != JsonValueKind.Object) throw new InvalidDataException();
        var expected = keys.ToHashSet(StringComparer.Ordinal);
        foreach (var p in e.EnumerateObject()) if (!expected.Remove(p.Name)) throw new InvalidDataException("Unexpected or duplicate JSON field.");
        if (expected.Count != 0) throw new InvalidDataException("Missing JSON field.");
    }
    internal static void Allowed(JsonElement e, string[] required, params string[] optional)
    {
        if (e.ValueKind != JsonValueKind.Object) throw new InvalidDataException();
        var all = required.Concat(optional).ToHashSet(StringComparer.Ordinal);
        foreach (var p in e.EnumerateObject()) if (!all.Contains(p.Name)) throw new InvalidDataException("Unsupported JSON field.");
        foreach (string name in required) if (!e.TryGetProperty(name, out _)) throw new InvalidDataException("Missing JSON field.");
    }
    internal static string Type(JsonElement e) => e.GetProperty("type").GetString() ?? throw new InvalidDataException();
    internal static string[] Capabilities(JsonElement e)
    {
        if (!e.TryGetProperty("capabilities", out var c)) return [];
        if (c.ValueKind != JsonValueKind.Array || c.GetArrayLength() > 64) throw new InvalidDataException();
        var set = new HashSet<string>(StringComparer.Ordinal);
        foreach (var v in c.EnumerateArray()) { string s = v.GetString() ?? ""; if (!Text(s, 128) || !set.Add(s)) throw new InvalidDataException(); }
        return set.ToArray();
    }
    internal static readonly string[] VideoCapabilities = [PeelCapability.H264Video, PeelCapability.PerWindowVideoConnections, PeelCapability.BinaryVideoTransportV2];
    internal static void Hello(JsonElement e, string peer, bool video)
    {
        if (video) Allowed(e, ["type", "windowId", "protocolVersion", "minimumSupportedProtocolVersion"], "pairingID", "capabilities");
        else Allowed(e, ["type", "deviceName", "platform"], "pairingID", "deviceModel", "osVersion", "appVersion", "protocolVersion", "minimumSupportedProtocolVersion", "capabilities");
        if (e.TryGetProperty("pairingID", out var pairing) && pairing.ValueKind != JsonValueKind.Null && pairing.GetString() != peer) throw new InvalidDataException("TLS and hello identities differ.");
        int? version = e.TryGetProperty("protocolVersion", out var v) ? v.GetInt32() : null;
        int? minimum = e.TryGetProperty("minimumSupportedProtocolVersion", out var m) ? m.GetInt32() : null;
        if (!PeelProtocol.IsCompatible(version, minimum) || !VideoCapabilities.All(Capabilities(e).Contains)) throw new InvalidDataException("Protocol/capability mismatch.");
        if (!video)
            foreach (string name in new[] { "deviceName", "platform", "deviceModel", "osVersion", "appVersion" })
                if (e.TryGetProperty(name, out var s) && s.ValueKind != JsonValueKind.Null && !Text(s.GetString(), 256)) throw new InvalidDataException();
    }
    // Pairing is one complete JSON object without a newline in the Apple wire.
    // Control/video are NDJSON. Byte-wise reading preserves subsequent records.
    internal static async Task<byte[]> ReadAsync(Stream stream, bool completeObject, CancellationToken token)
    {
        using var data = new MemoryStream(); byte[] one = new byte[1]; int depth = 0; bool quoted = false, escaped = false, started = false;
        while (data.Length < Limit)
        {
            if (await stream.ReadAsync(one, token).ConfigureAwait(false) != 1) throw new EndOfStreamException();
            byte b = one[0];
            if (!completeObject && b == 10) return data.ToArray();
            data.WriteByte(b);
            if (!completeObject) continue;
            if (!started) { if (b is 32 or 13 or 10 or 9) continue; if (b != (byte)'{') throw new InvalidDataException(); started = true; depth = 1; continue; }
            if (quoted) { if (escaped) escaped = false; else if (b == (byte)'\\') escaped = true; else if (b == (byte)'"') quoted = false; }
            else if (b == (byte)'"') quoted = true;
            else if (b is (byte)'{' or (byte)'[') depth++;
            else if (b is (byte)'}' or (byte)']') { if (--depth == 0) return data.ToArray(); }
        }
        throw new InvalidDataException("Message exceeds its bound.");
    }
    internal static async Task SendAsync<T>(Stream s, T message, CancellationToken token)
    { byte[] data = PeelJson.SerializeLine(message); if (data.Length > Limit) throw new InvalidDataException(); await s.WriteAsync(data, token).ConfigureAwait(false); }
}
