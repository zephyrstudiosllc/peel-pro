using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Runtime.InteropServices;

namespace Peel.Windows.Protocol;

public static class PeelJson
{
    public static JsonSerializerOptions Options { get; } = CreateOptions();

    public static byte[] Serialize<T>(T value) => JsonSerializer.SerializeToUtf8Bytes(value, Options);

    public static string SerializeString<T>(T value) => JsonSerializer.Serialize(value, Options);

    public static byte[] SerializeLine<T>(T value)
    {
        var json = Serialize(value);
        var line = new byte[checked(json.Length + 1)];
        json.CopyTo(line, 0);
        line[^1] = (byte)'\n';
        return line;
    }

    public static T Deserialize<T>(ReadOnlySpan<byte> utf8Json) =>
        JsonSerializer.Deserialize<T>(utf8Json, Options)
        ?? throw new JsonException($"Peel JSON decoded to null for {typeof(T).Name}.");

    public static MessageEnvelope ReadEnvelope(ReadOnlySpan<byte> utf8Json) =>
        Deserialize<MessageEnvelope>(utf8Json);

    private static JsonSerializerOptions CreateOptions()
    {
        var options = new JsonSerializerOptions
        {
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            PropertyNameCaseInsensitive = false,
            UnmappedMemberHandling = JsonUnmappedMemberHandling.Skip,
            WriteIndented = false,
        };
        options.Converters.Add(new SwiftDateTimeOffsetConverter());
        return options;
    }
}

/// Swift's default Codable Date representation is a floating-point count of
/// seconds from 2001-01-01T00:00:00Z, not an ISO-8601 string or Unix timestamp.
public sealed class SwiftDateTimeOffsetConverter : JsonConverter<DateTimeOffset>
{
    private static readonly DateTimeOffset ReferenceDate =
        new(2001, 1, 1, 0, 0, 0, TimeSpan.Zero);

    public override DateTimeOffset Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.Number || !reader.TryGetDouble(out var seconds) || !double.IsFinite(seconds))
        {
            throw new JsonException("Expected finite Swift Date seconds since 2001-01-01.");
        }

        try
        {
            return ReferenceDate.AddSeconds(seconds);
        }
        catch (ArgumentOutOfRangeException exception)
        {
            throw new JsonException("Swift Date is outside the supported DateTimeOffset range.", exception);
        }
    }

    public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options)
    {
        writer.WriteNumberValue((value.ToUniversalTime() - ReferenceDate).TotalSeconds);
    }
}

public sealed class PeelStringEnumConverter<TEnum> : JsonConverter<TEnum>
    where TEnum : struct, Enum
{
    private static readonly IReadOnlyDictionary<string, TEnum> ValuesByWireName =
        Enum.GetValues<TEnum>().ToDictionary(ToWireName, value => value, StringComparer.Ordinal);

    public override TEnum Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        var wireName = reader.GetString();
        if (wireName is null || !ValuesByWireName.TryGetValue(wireName, out var value))
        {
            throw new JsonException($"Unknown {typeof(TEnum).Name} wire value '{wireName}'.");
        }

        return value;
    }

    public override void Write(Utf8JsonWriter writer, TEnum value, JsonSerializerOptions options) =>
        writer.WriteStringValue(ToWireName(value));

    private static string ToWireName(TEnum value) =>
        JsonNamingPolicy.CamelCase.ConvertName(value.ToString());
}

public sealed class NdjsonReader
{
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private readonly List<byte> buffer = [];

    public NdjsonReader(int maximumLineBytes = 64 * 1024)
    {
        if (maximumLineBytes < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(maximumLineBytes));
        }

        MaximumLineBytes = maximumLineBytes;
    }

    public int MaximumLineBytes { get; }

    public IReadOnlyList<string> Append(ReadOnlySpan<byte> bytes)
    {
        var lines = new List<string>();

        foreach (var value in bytes)
        {
            if (value == (byte)'\n')
            {
                var lineLength = buffer.Count;
                if (lineLength > 0 && buffer[^1] == (byte)'\r')
                {
                    lineLength--;
                }

                if (lineLength > 0)
                {
                    lines.Add(StrictUtf8.GetString(CollectionsMarshal.AsSpan(buffer)[..lineLength]));
                }

                buffer.Clear();
                continue;
            }

            if (buffer.Count >= MaximumLineBytes)
            {
                buffer.Clear();
                throw new InvalidDataException($"NDJSON line exceeded {MaximumLineBytes} bytes.");
            }

            buffer.Add(value);
        }

        return lines;
    }

    public void Reset() => buffer.Clear();
}
