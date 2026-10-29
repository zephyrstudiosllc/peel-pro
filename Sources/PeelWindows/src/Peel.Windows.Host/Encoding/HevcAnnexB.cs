using System.Buffers.Binary;

namespace Peel.Windows.Host.Encoding;

internal static class HevcAnnexB
{
    internal sealed record AccessUnit(byte[] Payload, byte[]? Vps, byte[]? Sps, byte[]? Pps, bool Keyframe);
    internal static AccessUnit Convert(ReadOnlySpan<byte> annexB, bool requireFrame = true)
    {
        byte[]? vps = null, sps = null, pps = null;
        bool key = false;
        using var output = new MemoryStream();
        Span<byte> length = stackalloc byte[4];
        foreach (var unit in H264AnnexB.SplitNalUnits(annexB))
        {
            if (unit.Length < 2 || (unit[0] & 0x80) != 0 || (unit[1] & 7) == 0) throw new InvalidDataException("Invalid HEVC NAL header.");
            int type = (unit[0] >> 1) & 63;
            switch (type)
            {
                case 32: vps ??= unit; continue;
                case 33: sps ??= unit; continue;
                case 34: pps ??= unit; continue;
            }
            key |= type is >= 16 and <= 21;
            BinaryPrimitives.WriteUInt32BigEndian(length, (uint)unit.Length);
            output.Write(length); output.Write(unit);
        }
        if (requireFrame && output.Length == 0) throw new InvalidDataException("HEVC output has no frame payload.");
        return new(output.ToArray(), vps, sps, pps, key);
    }

    internal static (byte[] Vps, byte[] Sps, byte[] Pps) ReadParameterSets(ReadOnlySpan<byte> data)
    {
        AccessUnit config;
        if (data.Length >= 23 && data[0] == 1)
        {
            // HEVCDecoderConfigurationRecord (hvcC), as emitted by some Windows MFTs.
            using var annexB = new MemoryStream();
            int offset = 23;
            for (int array = 0; array < data[22]; array++)
            {
                if (data.Length - offset < 3) throw new InvalidDataException("Truncated HEVC configuration array.");
                offset++; int count = BinaryPrimitives.ReadUInt16BigEndian(data.Slice(offset, 2)); offset += 2;
                for (int i = 0; i < count; i++)
                {
                    if (data.Length - offset < 2) throw new InvalidDataException("Truncated HEVC configuration length.");
                    int size = BinaryPrimitives.ReadUInt16BigEndian(data.Slice(offset, 2)); offset += 2;
                    if (size < 2 || size > data.Length - offset) throw new InvalidDataException("Invalid HEVC configuration length.");
                    annexB.Write([0, 0, 0, 1]); annexB.Write(data.Slice(offset, size)); offset += size;
                }
            }
            if (offset != data.Length) throw new InvalidDataException("Unexpected HEVC configuration trailing bytes.");
            config = Convert(annexB.ToArray(), false);
        }
        else config = Convert(data, false);
        return (config.Vps ?? throw new InvalidDataException("HEVC VPS is missing."),
            config.Sps ?? throw new InvalidDataException("HEVC SPS is missing."),
            config.Pps ?? throw new InvalidDataException("HEVC PPS is missing."));
    }
}
