using System.Buffers.Binary;

namespace Peel.Windows.Host.Encoding;

internal static class H264AnnexB
{
    internal sealed record AccessUnit(
        byte[] LengthPrefixedPayload,
        byte[]? SequenceParameterSet,
        byte[]? PictureParameterSet,
        bool ContainsIdr);

    internal static AccessUnit ConvertAccessUnit(ReadOnlySpan<byte> annexB)
    {
        IReadOnlyList<byte[]> units = SplitNalUnits(annexB);
        byte[]? sps = null;
        byte[]? pps = null;
        var containsIdr = false;
        using var payload = new MemoryStream();
        Span<byte> length = stackalloc byte[sizeof(uint)];

        foreach (byte[] unit in units)
        {
            int type = unit[0] & 0x1F;
            if (type == 7)
            {
                sps ??= unit;
                continue;
            }

            if (type == 8)
            {
                pps ??= unit;
                continue;
            }

            containsIdr |= type == 5;
            BinaryPrimitives.WriteUInt32BigEndian(length, checked((uint)unit.Length));
            payload.Write(length);
            payload.Write(unit);
        }

        if (payload.Length == 0)
        {
            throw new InvalidDataException("The H.264 access unit contains no frame payload.");
        }

        return new AccessUnit(payload.ToArray(), sps, pps, containsIdr);
    }

    internal static (byte[] SequenceParameterSet, byte[] PictureParameterSet) ReadParameterSets(
        ReadOnlySpan<byte> annexB)
    {
        byte[]? sps = null;
        byte[]? pps = null;
        foreach (byte[] unit in SplitNalUnits(annexB))
        {
            int type = unit[0] & 0x1F;
            if (type == 7)
            {
                sps ??= unit;
            }
            else if (type == 8)
            {
                pps ??= unit;
            }
        }

        if (sps is null || pps is null)
        {
            throw new InvalidDataException("The H.264 sequence header is missing its SPS or PPS.");
        }

        return (sps, pps);
    }

    internal static IReadOnlyList<byte[]> SplitNalUnits(ReadOnlySpan<byte> annexB)
    {
        var units = new List<byte[]>();
        int searchOffset = 0;
        while (TryFindStartCode(annexB, searchOffset, out int start, out int startCodeLength))
        {
            int unitStart = start + startCodeLength;
            int nextStart = annexB.Length;
            if (TryFindStartCode(annexB, unitStart, out int foundNext, out _))
            {
                nextStart = foundNext;
            }

            int unitEnd = nextStart;
            while (unitEnd > unitStart && annexB[unitEnd - 1] == 0)
            {
                unitEnd--;
            }

            if (unitEnd > unitStart)
            {
                units.Add(annexB[unitStart..unitEnd].ToArray());
            }

            searchOffset = nextStart;
            if (searchOffset >= annexB.Length)
            {
                break;
            }
        }

        if (units.Count == 0)
        {
            throw new InvalidDataException("The H.264 sample is not an Annex-B access unit.");
        }

        return units;
    }

    private static bool TryFindStartCode(
        ReadOnlySpan<byte> bytes,
        int offset,
        out int start,
        out int length)
    {
        for (int index = Math.Max(0, offset); index + 2 < bytes.Length; index++)
        {
            if (bytes[index] != 0 || bytes[index + 1] != 0)
            {
                continue;
            }

            if (bytes[index + 2] == 1)
            {
                start = index;
                length = 3;
                return true;
            }

            if (index + 3 < bytes.Length && bytes[index + 2] == 0 && bytes[index + 3] == 1)
            {
                start = index;
                length = 4;
                return true;
            }
        }

        start = 0;
        length = 0;
        return false;
    }
}
