using System.Buffers.Binary;
using Peel.Windows.Protocol;

namespace Peel.Windows.Protocol.Tests;
internal static partial class Program
{
    private static void AudioPacketContract()
    {
        var format = new AudioPacket(0, 0, 0, 0, []);
        Equal("504541550100000000000000000000000000000000000000000000000000BB8000000202", Convert.ToHexString(format.Encode()));
        byte[] pcm = new AudioPacket(1, 0, 1, 48000, new byte[3840]).Encode();
        Equal(3840, AudioPacket.ValidateHeader(pcm.AsSpan(0, 36), 0));
        Throws<InvalidDataException>(() => AudioPacket.ValidateHeader(pcm.AsSpan(0, 36), 1));
        byte[] huge = pcm[..36]; BinaryPrimitives.WriteUInt32BigEndian(huge.AsSpan(8), uint.MaxValue);
        Throws<InvalidDataException>(() => AudioPacket.ValidateHeader(huge, 0));
        byte[] invalid = pcm[..36]; invalid[7] = 1;
        Throws<InvalidDataException>(() => AudioPacket.ValidateHeader(invalid, 0));
        var parser = new AudioPacketReader(0);
        Throws<InvalidDataException>(() => parser.ReadAsync(new MemoryStream(pcm), default).AsTask().GetAwaiter().GetResult());
        using var stream = new MemoryStream([.. format.Encode(), .. pcm]);
        parser = new(0);
        Equal((byte)0, parser.ReadAsync(stream, default).AsTask().GetAwaiter().GetResult().Kind);
        Equal(1ul, parser.ReadAsync(stream, default).AsTask().GetAwaiter().GetResult().Sequence);
        using var truncated = new MemoryStream(format.Encode()[..17]);
        Throws<EndOfStreamException>(() => new AudioPacketReader(0).ReadAsync(truncated, default).AsTask().GetAwaiter().GetResult());
        var challenge = new AudioPairingChallengeMessage("01234567-89ab-cdef-0123-456789abcdef", "windows-test-peer",
            Convert.ToBase64String(Enumerable.Range(0, 32).Select(i => (byte)i).ToArray()), 1791150000.25, "playback");
        byte[] key = Enumerable.Range(32, 32).Select(i => (byte)i).ToArray();
        // Independently verified with Swift CryptoKit on the reference Mac.
        Equal("a1ARrtDE5SaSeCPahmXIOffNJVhdAb9V5X/sHhCqysE=", AudioPairingProof.Make(challenge, key));
        Equal("8vcpTdK4ahdyOqqXH2x6O5Y4foD8+ylk0EjVlBFjGHU=", AudioPairingProof.Make(challenge with { Mode = "voice" }, key));
        True(AudioPairingProof.Make(challenge, key) != AudioPairingProof.Make(challenge with { Mode = "voice" }, key));
        Throws<InvalidDataException>(() => AudioPairingProof.Make(challenge with { Mode = "other" }, key));
    }
}
