using System.Buffers.Binary;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Peel.Windows.Protocol;

public sealed record SignalHelloMessage(
    [property: JsonPropertyName("pairingId"), JsonRequired] string PairingId,
    [property: JsonPropertyName("publisherHostId"), JsonRequired] string PublisherHostId,
    [property: JsonPropertyName("subscriberHostId"), JsonRequired] string SubscriberHostId,
    [property: JsonPropertyName("subscriberNodeId"), JsonRequired] string SubscriberNodeId,
    [property: JsonPropertyName("clientNonce"), JsonRequired] string ClientNonce)
{ [JsonPropertyName("type")] public string Type => "peelSignalHello"; }

public sealed record SignalChallengeMessage(
    [property: JsonPropertyName("serverNonce"), JsonRequired] string ServerNonce,
    [property: JsonPropertyName("publisherNodeId"), JsonRequired] string PublisherNodeId,
    [property: JsonPropertyName("proof"), JsonRequired] string Proof)
{ [JsonPropertyName("type")] public string Type => "peelSignalChallenge"; }

public sealed record SignalProofMessage([property: JsonPropertyName("proof"), JsonRequired] string Proof)
{ [JsonPropertyName("type")] public string Type => "peelSignalProof"; }

public sealed record SignalFrameMessage([property: JsonPropertyName("payload"), JsonRequired] string Payload)
{ [JsonPropertyName("type")] public string Type => "peelSignalFrame"; }

public sealed record NearbySignalFrame(
    [property: JsonPropertyName("version"), JsonRequired] int Version,
    [property: JsonPropertyName("sourceNodeID"), JsonRequired] string SourceNodeId,
    [property: JsonPropertyName("sequence"), JsonRequired] ulong Sequence,
    [property: JsonPropertyName("generatedAt"), JsonRequired] DateTimeOffset GeneratedAt,
    [property: JsonPropertyName("sentAt"), JsonRequired] DateTimeOffset SentAt,
    [property: JsonPropertyName("programStartedAt"), JsonRequired] DateTimeOffset ProgramStartedAt,
    [property: JsonPropertyName("aggregateState"), JsonRequired] string AggregateState,
    [property: JsonPropertyName("hasVisibleActivity"), JsonRequired] bool HasVisibleActivity,
    [property: JsonPropertyName("proProgram"), JsonRequired] string ProProgram,
    [property: JsonPropertyName("dotProgram"), JsonRequired] string DotProgram)
{
    [JsonIgnore] public int Priority => AggregateState switch { "error" => 0, "waiting" => 1, "toolRunning" => 2, "working" or "progress" => 3, "completed" => 4, _ => 5 };
    [JsonIgnore] public string StateLabel => AggregateState switch { "error" => "Error / blocked", "waiting" => "Needs approval", "toolRunning" => "Tool running", "working" or "progress" => "Thinking", "completed" => "Done", _ => "Idle" };
}

/// <summary>Exact existing Mac trusted SidePulse contract. This is separate from control/video ABI.</summary>
public static class TrustedSignals
{
    public const string ServiceType = "_peel-signal._tcp";
    public const int MaximumHandshakeBytes = 4096, MaximumFrameBytes = 12288, MaximumPayloadBytes = 8192;
    public static string NewNonce() => Convert.ToBase64String(RandomNumberGenerator.GetBytes(32));
    public static Guid Uuid(string? value)
    {
        if (value is null || value.Length != 36 || !Guid.TryParseExact(value, "D", out var id) ||
            (value != value.ToUpperInvariant() && value != value.ToLowerInvariant()))
            throw new InvalidDataException("Signal identity must be a canonical UUID.");
        return id;
    }
    public static byte[] Base64(string? value, int? exactLength = 32, int maximumLength = 32)
    {
        if (value is null || value.Length > ((maximumLength + 2) / 3) * 4) throw new InvalidDataException("Invalid signal payload size.");
        byte[] bytes;
        try { bytes = Convert.FromBase64String(value); }
        catch (FormatException e) { throw new InvalidDataException("Invalid signal Base64.", e); }
        if (bytes.Length > maximumLength || exactLength is { } length && bytes.Length != length || Convert.ToBase64String(bytes) != value)
            throw new InvalidDataException("Invalid signal Base64 or byte count.");
        return bytes;
    }
    public static SignalHelloMessage ReadHello(ReadOnlySpan<byte> json)
    {
        var value = Read<SignalHelloMessage>(json, "peelSignalHello", MaximumHandshakeBytes);
        Validate(value); return value;
    }
    public static SignalChallengeMessage ReadChallenge(ReadOnlySpan<byte> json)
    {
        var value = Read<SignalChallengeMessage>(json, "peelSignalChallenge", MaximumHandshakeBytes);
        _ = Uuid(value.PublisherNodeId); _ = Base64(value.ServerNonce); _ = Base64(value.Proof); return value;
    }
    public static SignalProofMessage ReadProof(ReadOnlySpan<byte> json)
    {
        var value = Read<SignalProofMessage>(json, "peelSignalProof", MaximumHandshakeBytes);
        _ = Base64(value.Proof); return value;
    }
    public static NearbySignalFrame ReadFrame(ReadOnlySpan<byte> json)
    {
        var envelope = Read<SignalFrameMessage>(json, "peelSignalFrame", MaximumFrameBytes);
        byte[] payload = Base64(envelope.Payload, null, MaximumPayloadBytes);
        RejectDuplicateProperties(payload);
        var value = PeelJson.Deserialize<NearbySignalFrame>(payload); Validate(value); return value;
    }
    public static byte[] FrameLine(NearbySignalFrame frame)
    {
        Validate(frame); byte[] payload = PeelJson.Serialize(frame);
        if (payload.Length > MaximumPayloadBytes) throw new InvalidDataException("Signal payload is too large.");
        return PeelJson.SerializeLine(new SignalFrameMessage(Convert.ToBase64String(payload)));
    }
    private static T Read<T>(ReadOnlySpan<byte> json, string type, int limit)
    {
        if (json.Length > limit) throw new InvalidDataException("Signal JSON is too large.");
        RejectDuplicateProperties(json);
        using var doc = JsonDocument.Parse(json.ToArray(), new JsonDocumentOptions { MaxDepth = 8 });
        if (!doc.RootElement.TryGetProperty("type", out var discriminator) || discriminator.GetString() != type)
            throw new InvalidDataException("Unexpected signal message.");
        return PeelJson.Deserialize<T>(json);
    }
    private static void RejectDuplicateProperties(ReadOnlySpan<byte> json)
    {
        var reader = new Utf8JsonReader(json, new JsonReaderOptions { MaxDepth = 8 });
        var objects = new Stack<HashSet<string>>();
        while (reader.Read())
        {
            if (reader.TokenType == JsonTokenType.StartObject) objects.Push(new(StringComparer.Ordinal));
            else if (reader.TokenType == JsonTokenType.EndObject) objects.Pop();
            else if (reader.TokenType == JsonTokenType.PropertyName && !objects.Peek().Add(reader.GetString()!))
                throw new InvalidDataException("Duplicate signal property.");
        }
    }
    public static void Validate(SignalHelloMessage hello)
    {
        _ = Uuid(hello.PairingId); _ = Uuid(hello.PublisherHostId); _ = Uuid(hello.SubscriberHostId); _ = Uuid(hello.SubscriberNodeId); _ = Base64(hello.ClientNonce);
    }
    public static byte[] Proof(bool server, SignalHelloMessage hello, string serverNonce, string publisherNodeId, ReadOnlySpan<byte> key)
    {
        Validate(hello);
        if (key.Length != 32) throw new InvalidDataException("Signal proofs require a 32-byte pairing key.");
        using var transcript = new MemoryStream();
        void Append(string value)
        {
            byte[] bytes = Encoding.UTF8.GetBytes(value); Span<byte> count = stackalloc byte[4];
            BinaryPrimitives.WriteUInt32BigEndian(count, (uint)bytes.Length); transcript.Write(count); transcript.Write(bytes);
        }
        Append(server ? "peel.sidepulse.server.v1" : "peel.sidepulse.client.v1");
        foreach (string id in new[] { hello.PairingId, hello.PublisherHostId, hello.SubscriberHostId, hello.SubscriberNodeId }) Append(Uuid(id).ToString("D"));
        transcript.Write(Base64(hello.ClientNonce)); transcript.Write(Base64(serverNonce)); Append(Uuid(publisherNodeId).ToString("D"));
        return HMACSHA256.HashData(key, transcript.GetBuffer().AsSpan(0, (int)transcript.Length));
    }
    public static bool Verify(bool server, string proof, SignalHelloMessage hello, string serverNonce, string publisherNodeId, ReadOnlySpan<byte> key) =>
        CryptographicOperations.FixedTimeEquals(Base64(proof), Proof(server, hello, serverNonce, publisherNodeId, key));

    public static void Validate(NearbySignalFrame frame)
    {
        _ = Uuid(frame.SourceNodeId);
        if (frame.Version != 1 || frame.AggregateState is not ("idle" or "working" or "progress" or "toolRunning" or "waiting" or "error" or "completed") ||
            Math.Abs((frame.SentAt - frame.ProgramStartedAt).TotalDays) >= 366)
            throw new InvalidDataException("Invalid signal state or clock origin.");
        ValidateProgram(frame.ProProgram); ValidateProgram(frame.DotProgram);
    }
    private static readonly HashSet<string> Easings = new(StringComparer.Ordinal) { "linear", "ease", "ease-in", "ease-out", "ease-in-out", "cosine", "pulse", "none" };
    public static void ValidateProgram(string? program)
    {
        if (program is null || Encoding.UTF8.GetByteCount(program) is < 1 or > 512) throw new InvalidDataException("Invalid signal program size.");
        var lines = program.Replace("\r\n", "\n").Split(['\n', '\r', '\v', '\f', '\u0085', '\u2028', '\u2029']);
        if (lines.Length > 20 || lines.Any(line => !ValidLine(line))) throw new InvalidDataException("Invalid signal program syntax.");
    }
    private static bool Number(string s, out long value) => long.TryParse(s, NumberStyles.None, CultureInfo.InvariantCulture, out value) && (s.Length == 1 || s[0] != '0');
    private static bool Duration(string s)
    {
        if (s.EndsWith("ms", StringComparison.Ordinal)) return Number(s[..^2], out long n) && n > 0;
        if (!s.EndsWith('s')) return false;
        var parts = s[..^1].Split('.');
        return parts.Length is 1 or 2 && Number(parts[0], out _) &&
            (parts.Length == 1 || parts[1].Length is 1 or 2 && parts[1].All(char.IsAsciiDigit)) &&
            s[..^1] is not ("0" or "0.0" or "0.00");
    }
    private static bool Color(string s) => s.Length == 7 && s[0] == '#' && s.AsSpan(1).IndexOfAnyExcept("0123456789abcdefABCDEF") < 0;
    private static bool Timing(string[] tokens) => tokens.Length == 0 || tokens.Length is 2 or 3 && Duration(tokens[0]) && Easings.Contains(tokens[1]) && (tokens.Length == 2 || Duration(tokens[2]));
    private static bool ValidLine(string line)
    {
        if (line is "off" or "repeat") return true;
        if (line.StartsWith("brightness ", StringComparison.Ordinal)) return Number(line[11..], out long n) && n <= 255;
        var segments = line.Split(';').Select(s => s.Split(' ')).ToArray();
        if (segments.Any(s => s.Any(string.IsNullOrEmpty))) return false;
        string first = segments[0][0];
        if (Color(first)) return segments.Length == 1 && (segments[0].Length <= 8 && segments[0].All(Color) || Timing(segments[0][1..]));
        return segments.All(s => (s[0] == "off" || s[0].Length == 9 && s[0][0] is >= '0' and <= '7' && s[0][1] == ':' && Color(s[0][2..])) && Timing(s[1..]));
    }
}
