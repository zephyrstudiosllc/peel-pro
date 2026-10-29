namespace Peel.Windows.Host.Networking;

internal sealed class BoundedNdjsonLineReader
{
    private readonly List<byte> buffer = [];
    private int maximumLineBytes;

    internal BoundedNdjsonLineReader(int maximumLineBytes)
    {
        MaximumLineBytes = maximumLineBytes;
    }

    internal int MaximumLineBytes
    {
        get => maximumLineBytes;
        set
        {
            if (value < 1 || value < buffer.Count)
            {
                throw new ArgumentOutOfRangeException(nameof(value));
            }

            maximumLineBytes = value;
        }
    }

    internal bool HasBufferedBytes => buffer.Count != 0;

    internal bool TryAppend(
        ReadOnlySpan<byte> bytes,
        out int bytesConsumed,
        out ReadOnlyMemory<byte> line)
    {
        for (var index = 0; index < bytes.Length; index++)
        {
            byte value = bytes[index];
            if (value == (byte)'\n')
            {
                var lineLength = buffer.Count;
                if (lineLength > 0 && buffer[^1] == (byte)'\r')
                {
                    lineLength--;
                }

                line = buffer.GetRange(0, lineLength).ToArray();
                buffer.Clear();
                bytesConsumed = index + 1;
                return true;
            }

            if (buffer.Count >= MaximumLineBytes)
            {
                buffer.Clear();
                throw new InvalidDataException(
                    $"NDJSON line exceeded {MaximumLineBytes} bytes.");
            }

            buffer.Add(value);
        }

        bytesConsumed = bytes.Length;
        line = default;
        return false;
    }
}
