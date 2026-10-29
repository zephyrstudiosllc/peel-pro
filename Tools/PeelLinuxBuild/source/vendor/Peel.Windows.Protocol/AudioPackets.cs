using System.Buffers.Binary;

namespace Peel.Windows.Protocol;

/// <summary>PEAU v1: fixed 48 kHz S16LE, 20 ms packets; header fields are big endian.</summary>
public sealed record AudioPacket(byte Kind, byte Direction, ulong Sequence, long SampleTime, byte[] Payload)
{
    public const int HeaderBytes = 36;
    public const int Frames = 960;
    public int Channels => Direction == 0 ? 2 : 1;
    public void Validate()
    {
        if (Kind > 1 || Direction > 1 || SampleTime < 0 || Payload is null || Payload.Length > 4096 ||
            Kind == 0 && (Sequence != 0 || SampleTime != 0 || Payload.Length != 0) || Kind == 1 && Payload.Length != Frames * Channels * 2)
            throw new InvalidDataException("Invalid PEAU audio packet.");
    }
    public byte[] Encode()
    {
        Validate(); byte[] data = new byte[HeaderBytes + Payload.Length];
        "PEAU"u8.CopyTo(data); data[4] = 1; data[5] = Kind; data[6] = Direction;
        BinaryPrimitives.WriteUInt32BigEndian(data.AsSpan(8), (uint)Payload.Length);
        BinaryPrimitives.WriteUInt64BigEndian(data.AsSpan(12), Sequence);
        BinaryPrimitives.WriteInt64BigEndian(data.AsSpan(20), SampleTime);
        BinaryPrimitives.WriteUInt32BigEndian(data.AsSpan(28), 48000);
        BinaryPrimitives.WriteUInt16BigEndian(data.AsSpan(32), Kind == 0 ? (ushort)0 : (ushort)Frames);
        data[34] = (byte)Channels; data[35] = 2; Payload.CopyTo(data, HeaderBytes); return data;
    }
    public static int ValidateHeader(ReadOnlySpan<byte> data, byte expectedDirection)
    {
        if (data.Length != HeaderBytes || !data[..4].SequenceEqual("PEAU"u8) || data[4] != 1 || data[5] > 1 || data[6] != expectedDirection || expectedDirection > 1 || data[7] != 0 ||
            BinaryPrimitives.ReadUInt32BigEndian(data[28..]) != 48000 || data[34] != (expectedDirection == 0 ? 2 : 1) || data[35] != 2 ||
            BinaryPrimitives.ReadInt64BigEndian(data[20..]) < 0) throw new InvalidDataException("Invalid PEAU audio header.");
        uint size = BinaryPrimitives.ReadUInt32BigEndian(data[8..]);
        ushort frames = BinaryPrimitives.ReadUInt16BigEndian(data[32..]);
        if (size > 4096 || data[5] == 0 && (size != 0 || frames != 0 || BinaryPrimitives.ReadUInt64BigEndian(data[12..]) != 0 || BinaryPrimitives.ReadInt64BigEndian(data[20..]) != 0) ||
            data[5] == 1 && (frames != Frames || size != frames * data[34] * 2)) throw new InvalidDataException("Invalid PEAU audio length.");
        return (int)size;
    }
}

public sealed class AudioPacketReader(byte expectedDirection)
{
    private bool formatted;
    public async ValueTask<AudioPacket> ReadAsync(Stream stream, CancellationToken token)
    {
        byte[] header = new byte[AudioPacket.HeaderBytes];
        await stream.ReadExactlyAsync(header, token).ConfigureAwait(false);
        int size = AudioPacket.ValidateHeader(header, expectedDirection); // Bound before allocating payload.
        if (header[5] == 1 && !formatted) throw new InvalidDataException("Audio PCM arrived before format.");
        byte[] payload = new byte[size];
        await stream.ReadExactlyAsync(payload, token).ConfigureAwait(false);
        if (header[5] == 0) formatted = true;
        return new(header[5], header[6], BinaryPrimitives.ReadUInt64BigEndian(header.AsSpan(12)), BinaryPrimitives.ReadInt64BigEndian(header.AsSpan(20)), payload);
    }
}
