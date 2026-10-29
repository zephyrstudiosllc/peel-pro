using System.Text.Json;
using System.Text.Json.Serialization;

namespace Peel.Windows.Protocol;

/// <summary>Bounds the optional D36 focus correlation value without changing its case.</summary>
public sealed class FocusRequestIdJsonConverter : JsonConverter<string>
{
    public override string? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.String)
        {
            throw new JsonException("A focus request ID must be a canonical UUID string.");
        }

        string? value = reader.GetString();
        if (value is null || !IsCanonical(value))
        {
            throw new JsonException("The focus request ID is invalid or oversized.");
        }
        return value;
    }

    public override void Write(Utf8JsonWriter writer, string value, JsonSerializerOptions options)
    {
        if (!IsCanonical(value))
        {
            throw new JsonException("The focus request ID is invalid or oversized.");
        }
        writer.WriteStringValue(value);
    }

    private static bool IsCanonical(string value)
    {
        if (value.Length != 36) return false;
        for (int index = 0; index < value.Length; index++)
        {
            char character = value[index];
            if (index is 8 or 13 or 18 or 23)
            {
                if (character != '-') return false;
            }
            else if (character is not (>= '0' and <= '9') and
                     not (>= 'a' and <= 'f') and
                     not (>= 'A' and <= 'F'))
            {
                return false;
            }
        }
        return true;
    }
}
