using System.Buffers.Binary;
using System.Runtime.InteropServices;

namespace Peel.Windows.Protocol;

public enum PeelBinaryPacketType : byte
{
    JpegFrame = 0x02,
    VideoConfig = 0x10,
    VideoFrame = 0x11,
    HevcVideoConfig = 0x12,
}

public enum PeelVideoCodec : byte
{
    H264 = 1,
    Hevc = 2,
}

public interface IPeelBinaryPacket
{
    PeelBinaryPacketType PacketType { get; }

    uint WindowId { get; }

    byte[] Encode();
}

public sealed record VideoConfigPacket(
    uint WindowId,
    PeelVideoCodec Codec,
    uint Width,
    uint Height,
    uint Timescale,
    byte NalUnitHeaderLength,
    byte[] Sps,
    byte[] Pps,
    byte[]? Vps = null) : IPeelBinaryPacket
{
    public PeelBinaryPacketType PacketType =>
        Codec == PeelVideoCodec.Hevc ? PeelBinaryPacketType.HevcVideoConfig : PeelBinaryPacketType.VideoConfig;

    public int EncodedLength
    {
        get
        {
            var headerLength = Codec == PeelVideoCodec.Hevc ? 31 : 27;
            return checked(headerLength + Sps.Length + Pps.Length + (Codec == PeelVideoCodec.Hevc ? Vps?.Length ?? 0 : 0));
        }
    }

    public byte[] Encode()
    {
        Validate();

        var data = new byte[EncodedLength];
        var span = data.AsSpan();
        span[0] = (byte)PacketType;
        BinaryPrimitives.WriteUInt32LittleEndian(span[1..5], WindowId);
        span[5] = (byte)Codec;
        BinaryPrimitives.WriteUInt32LittleEndian(span[6..10], Width);
        BinaryPrimitives.WriteUInt32LittleEndian(span[10..14], Height);
        BinaryPrimitives.WriteUInt32LittleEndian(span[14..18], Timescale);
        span[18] = NalUnitHeaderLength;

        var offset = 19;
        if (Codec == PeelVideoCodec.Hevc)
        {
            BinaryPrimitives.WriteUInt32LittleEndian(span[offset..(offset + 4)], checked((uint)(Vps?.Length ?? 0)));
            offset += 4;
        }

        BinaryPrimitives.WriteUInt32LittleEndian(span[offset..(offset + 4)], checked((uint)Sps.Length));
        offset += 4;
        BinaryPrimitives.WriteUInt32LittleEndian(span[offset..(offset + 4)], checked((uint)Pps.Length));
        offset += 4;

        if (Codec == PeelVideoCodec.Hevc && Vps is not null)
        {
            Vps.CopyTo(span[offset..]);
            offset += Vps.Length;
        }

        Sps.CopyTo(span[offset..]);
        offset += Sps.Length;
        Pps.CopyTo(span[offset..]);
        return data;
    }

    public static VideoConfigPacket Decode(ReadOnlySpan<byte> data)
    {
        var packetLength = PeelBinaryFraming.GetCompletePacketLength(data, data.Length);
        if (packetLength != data.Length)
        {
            throw new InvalidDataException("Video config buffer contains trailing packet data.");
        }

        var packetType = (PeelBinaryPacketType)data[0];
        var isHevc = packetType == PeelBinaryPacketType.HevcVideoConfig;
        var codec = (PeelVideoCodec)data[5];
        if ((isHevc && codec != PeelVideoCodec.Hevc) || (!isHevc && codec != PeelVideoCodec.H264))
        {
            throw new InvalidDataException("Video config packet type and codec disagree.");
        }

        var offset = 19;
        var vpsLength = 0;
        if (isHevc)
        {
            vpsLength = checked((int)BinaryPrimitives.ReadUInt32LittleEndian(data[offset..(offset + 4)]));
            offset += 4;
        }

        var spsLength = checked((int)BinaryPrimitives.ReadUInt32LittleEndian(data[offset..(offset + 4)]));
        offset += 4;
        var ppsLength = checked((int)BinaryPrimitives.ReadUInt32LittleEndian(data[offset..(offset + 4)]));
        offset += 4;

        var vps = isHevc ? data.Slice(offset, vpsLength).ToArray() : null;
        offset += vpsLength;
        var sps = data.Slice(offset, spsLength).ToArray();
        offset += spsLength;
        var pps = data.Slice(offset, ppsLength).ToArray();

        return new VideoConfigPacket(
            BinaryPrimitives.ReadUInt32LittleEndian(data[1..5]),
            codec,
            BinaryPrimitives.ReadUInt32LittleEndian(data[6..10]),
            BinaryPrimitives.ReadUInt32LittleEndian(data[10..14]),
            BinaryPrimitives.ReadUInt32LittleEndian(data[14..18]),
            data[18],
            sps,
            pps,
            vps);
    }

    private void Validate()
    {
        if (Codec is not PeelVideoCodec.H264 and not PeelVideoCodec.Hevc)
        {
            throw new InvalidDataException($"Unsupported video codec byte {(byte)Codec}.");
        }

        if (Codec == PeelVideoCodec.H264 && Vps is { Length: > 0 })
        {
            throw new InvalidDataException("H.264 config packets cannot carry a VPS.");
        }

        _ = checked((uint)Sps.Length);
        _ = checked((uint)Pps.Length);
        _ = checked((uint)(Vps?.Length ?? 0));
    }
}

public sealed record VideoFramePacket(
    uint WindowId,
    bool IsKeyframe,
    long PtsValue,
    long DurationValue,
    byte[] Payload) : IPeelBinaryPacket
{
    public const int HeaderLength = 26;

    public PeelBinaryPacketType PacketType => PeelBinaryPacketType.VideoFrame;

    public int EncodedLength => checked(HeaderLength + Payload.Length);

    public byte[] Encode()
    {
        var data = new byte[EncodedLength];
        var span = data.AsSpan();
        span[0] = (byte)PacketType;
        BinaryPrimitives.WriteUInt32LittleEndian(span[1..5], WindowId);
        span[5] = IsKeyframe ? (byte)1 : (byte)0;
        BinaryPrimitives.WriteInt64LittleEndian(span[6..14], PtsValue);
        BinaryPrimitives.WriteInt64LittleEndian(span[14..22], DurationValue);
        BinaryPrimitives.WriteUInt32LittleEndian(span[22..26], checked((uint)Payload.Length));
        Payload.CopyTo(span[HeaderLength..]);
        return data;
    }

    public static VideoFramePacket Decode(ReadOnlySpan<byte> data)
    {
        var packetLength = PeelBinaryFraming.GetCompletePacketLength(data, data.Length);
        if (packetLength != data.Length)
        {
            throw new InvalidDataException("Video frame buffer contains trailing packet data.");
        }

        return new VideoFramePacket(
            BinaryPrimitives.ReadUInt32LittleEndian(data[1..5]),
            data[5] != 0,
            BinaryPrimitives.ReadInt64LittleEndian(data[6..14]),
            BinaryPrimitives.ReadInt64LittleEndian(data[14..22]),
            data[HeaderLength..].ToArray());
    }
}

public static class PeelBinaryFraming
{
    public const int DefaultMaximumPacketBytes = 64 * 1024 * 1024;

    public static bool TryGetCompletePacketLength(
        ReadOnlySpan<byte> data,
        out int packetLength,
        int maximumPacketBytes = DefaultMaximumPacketBytes)
    {
        packetLength = 0;
        if (data.IsEmpty)
        {
            return false;
        }

        if (maximumPacketBytes < VideoFramePacket.HeaderLength)
        {
            throw new ArgumentOutOfRangeException(nameof(maximumPacketBytes));
        }

        var packetType = (PeelBinaryPacketType)data[0];
        int headerLength;
        ulong variableLength;

        switch (packetType)
        {
            case PeelBinaryPacketType.VideoFrame:
                headerLength = VideoFramePacket.HeaderLength;
                if (data.Length < headerLength)
                {
                    return false;
                }

                variableLength = BinaryPrimitives.ReadUInt32LittleEndian(data[22..26]);
                break;

            case PeelBinaryPacketType.VideoConfig:
                headerLength = 27;
                if (data.Length < headerLength)
                {
                    return false;
                }

                if (data[5] != (byte)PeelVideoCodec.H264)
                {
                    throw new InvalidDataException("H.264 config packet carries a different codec byte.");
                }

                variableLength = (ulong)BinaryPrimitives.ReadUInt32LittleEndian(data[19..23])
                    + BinaryPrimitives.ReadUInt32LittleEndian(data[23..27]);
                break;

            case PeelBinaryPacketType.HevcVideoConfig:
                headerLength = 31;
                if (data.Length < headerLength)
                {
                    return false;
                }

                if (data[5] != (byte)PeelVideoCodec.Hevc)
                {
                    throw new InvalidDataException("HEVC config packet carries a different codec byte.");
                }

                variableLength = (ulong)BinaryPrimitives.ReadUInt32LittleEndian(data[19..23])
                    + BinaryPrimitives.ReadUInt32LittleEndian(data[23..27])
                    + BinaryPrimitives.ReadUInt32LittleEndian(data[27..31]);
                break;

            case PeelBinaryPacketType.JpegFrame:
                throw new NotSupportedException("Legacy JPEG packets are not part of the selected v2 transport.");

            default:
                throw new InvalidDataException($"Unknown Peel binary packet type 0x{data[0]:X2}.");
        }

        var totalLength = checked((ulong)headerLength + variableLength);
        if (totalLength > (ulong)maximumPacketBytes || totalLength > int.MaxValue)
        {
            throw new InvalidDataException($"Peel binary packet length {totalLength} exceeds the configured limit.");
        }

        packetLength = (int)totalLength;
        return data.Length >= packetLength;
    }

    internal static int GetCompletePacketLength(ReadOnlySpan<byte> data, int maximumPacketBytes)
    {
        if (!TryGetCompletePacketLength(data, out var packetLength, maximumPacketBytes))
        {
            throw new InvalidDataException("Incomplete Peel binary packet.");
        }

        return packetLength;
    }
}

public sealed class PeelBinaryPacketReader
{
    private readonly List<byte> buffer = [];

    public PeelBinaryPacketReader(int maximumPacketBytes = PeelBinaryFraming.DefaultMaximumPacketBytes)
    {
        if (maximumPacketBytes < VideoFramePacket.HeaderLength)
        {
            throw new ArgumentOutOfRangeException(nameof(maximumPacketBytes));
        }

        MaximumPacketBytes = maximumPacketBytes;
    }

    public int MaximumPacketBytes { get; }

    public IReadOnlyList<IPeelBinaryPacket> Append(ReadOnlySpan<byte> bytes)
    {
        if ((long)buffer.Count + bytes.Length > MaximumPacketBytes)
        {
            buffer.Clear();
            throw new InvalidDataException("Buffered Peel video data exceeds the configured packet limit.");
        }

        foreach (var value in bytes)
        {
            buffer.Add(value);
        }

        var packets = new List<IPeelBinaryPacket>();
        while (buffer.Count > 0)
        {
            var span = CollectionsMarshal.AsSpan(buffer);
            if (!PeelBinaryFraming.TryGetCompletePacketLength(span, out var packetLength, MaximumPacketBytes))
            {
                break;
            }

            var packetSpan = span[..packetLength];
            packets.Add((PeelBinaryPacketType)packetSpan[0] switch
            {
                PeelBinaryPacketType.VideoConfig or PeelBinaryPacketType.HevcVideoConfig => VideoConfigPacket.Decode(packetSpan),
                PeelBinaryPacketType.VideoFrame => VideoFramePacket.Decode(packetSpan),
                _ => throw new InvalidDataException($"Unsupported Peel packet type 0x{packetSpan[0]:X2}."),
            });
            buffer.RemoveRange(0, packetLength);
        }

        return packets;
    }

    public void Reset() => buffer.Clear();
}
