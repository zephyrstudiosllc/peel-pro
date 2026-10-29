using System.Text.Json;

namespace Peel.Windows.Protocol;

/// <summary>Local IPC only. Not part of Peel's TLS-PSK wire protocol.</summary>
public static class LocalAgentProtocol
{
    public const int MaximumLineBytes = 256 * 1024;
    public static string PipeName(string userSid) => "Peel.AgentBridge." + userSid;
    public static async Task<byte[]?> ReadLineAsync(Stream stream, CancellationToken token)
    {
        using var line = new MemoryStream();
        byte[] one = new byte[1];
        while (await stream.ReadAsync(one, token).ConfigureAwait(false) != 0)
        {
            if (one[0] == 10) return line.ToArray();
            if (line.Length >= MaximumLineBytes) throw new InvalidDataException("Agent message exceeds 256 KiB.");
            line.WriteByte(one[0]);
        }
        if (line.Length != 0) throw new EndOfStreamException("Truncated agent message.");
        return null;
    }
    public static byte[] EncodeLine(object value)
    {
        byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(value);
        if (bytes.Length >= MaximumLineBytes) throw new InvalidDataException("Agent response exceeds 256 KiB.");
        return [.. bytes, 10];
    }
}
