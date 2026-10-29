using System.Buffers.Binary;
using System.IO;
using Peel.Windows.Protocol;

namespace Peel.Windows.Client.Services;

internal static class H264LengthPrefixed
{
    private const int MaximumAnnexBBytes = 64 * 1024 * 1024;
    private static readonly byte[] StartCode = [0, 0, 0, 1];

    internal static byte[] CreateSequenceHeader(VideoConfigPacket configuration)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        if (configuration.Codec == PeelVideoCodec.Hevc)
        {
            if (!HevcParameter(configuration.Vps, 32) || !HevcParameter(configuration.Sps, 33) || !HevcParameter(configuration.Pps, 34))
                throw new InvalidDataException("The HEVC configuration has invalid VPS/SPS/PPS parameter sets.");
            return BuildAnnexB([configuration.Vps!, configuration.Sps, configuration.Pps], "The HEVC sequence header is oversized.");
        }
        if (configuration.Codec is not (PeelVideoCodec.H264 or PeelVideoCodec.Hevc) ||
            configuration.Sps.Length == 0 ||
            configuration.Pps.Length == 0 ||
            (configuration.Sps[0] & 0x1F) != 7 ||
            (configuration.Pps[0] & 0x1F) != 8)
        {
            throw new InvalidDataException("The H.264 configuration has invalid parameter sets.");
        }

        return BuildAnnexB(
            [configuration.Sps, configuration.Pps],
            "The H.264 sequence header is oversized.");
    }

    internal static byte[] ConvertFrame(
        VideoConfigPacket configuration,
        VideoFramePacket frame)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        ArgumentNullException.ThrowIfNull(frame);
        if (configuration.Codec is not (PeelVideoCodec.H264 or PeelVideoCodec.Hevc) ||
            configuration.NalUnitHeaderLength is not (1 or 2 or 4) ||
            frame.WindowId != configuration.WindowId ||
            frame.Payload.Length == 0)
        {
            throw new InvalidDataException("The H.264 frame metadata is invalid.");
        }

        var units = new List<byte[]>();
        if (frame.IsKeyframe)
        {
            _ = CreateSequenceHeader(configuration);
            if (configuration.Codec == PeelVideoCodec.Hevc) units.Add(configuration.Vps!);
            units.Add(configuration.Sps);
            units.Add(configuration.Pps);
        }

        ReadOnlySpan<byte> payload = frame.Payload;
        int offset = 0;
        while (offset < payload.Length)
        {
            int headerLength = configuration.NalUnitHeaderLength;
            if (payload.Length - offset < headerLength)
            {
                throw new InvalidDataException("The H.264 frame has a truncated NAL length.");
            }

            uint unitLength = ReadLength(payload.Slice(offset, headerLength), headerLength);
            offset += headerLength;
            if (unitLength == 0 || unitLength > payload.Length - offset)
            {
                throw new InvalidDataException("The H.264 frame has an invalid NAL length.");
            }

            units.Add(payload.Slice(offset, checked((int)unitLength)).ToArray());
            if (units.Count > 65536) throw new InvalidDataException("Too many NAL units in one frame.");
            offset = checked(offset + (int)unitLength);
        }

        return BuildAnnexB(units, "The converted H.264 frame is oversized.");
    }

    private static bool HevcParameter(byte[]? unit, int type) => unit is { Length: >= 2 }
        && unit.Length <= 1024 * 1024 && (unit[0] & 0x80) == 0 && ((unit[0] >> 1) & 63) == type && (unit[1] & 7) != 0;

    private static byte[] BuildAnnexB(IReadOnlyList<byte[]> units, string oversizedMessage)
    {
        long byteCount = 0;
        foreach (byte[] unit in units)
        {
            if (unit.Length == 0)
            {
                throw new InvalidDataException("The H.264 stream contains an empty NAL unit.");
            }

            byteCount = checked(byteCount + StartCode.Length + unit.Length);
            if (byteCount > MaximumAnnexBBytes)
            {
                throw new InvalidDataException(oversizedMessage);
            }
        }

        var output = new byte[checked((int)byteCount)];
        int offset = 0;
        foreach (byte[] unit in units)
        {
            StartCode.CopyTo(output, offset);
            offset += StartCode.Length;
            unit.CopyTo(output, offset);
            offset += unit.Length;
        }

        return output;
    }

    private static uint ReadLength(ReadOnlySpan<byte> bytes, int headerLength) => headerLength switch
    {
        1 => bytes[0],
        2 => BinaryPrimitives.ReadUInt16BigEndian(bytes),
        4 => BinaryPrimitives.ReadUInt32BigEndian(bytes),
        _ => throw new InvalidDataException("Unsupported H.264 NAL length width."),
    };
}
