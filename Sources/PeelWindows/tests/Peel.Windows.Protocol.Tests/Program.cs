using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Peel.Windows.Protocol;

namespace Peel.Windows.Protocol.Tests;

internal static partial class Program
{
    private static readonly (string Name, Action Test)[] Tests =
    {
        ("source media v1 matches the frozen JSON, strict identity and closed enums", SourceMediaContract),
        ("receiver diagnostics preserve Apple fields and reject invented or hostile observations", StreamDiagnosticsContract),
        ("trusted signals match Swift role proofs and bound frame programs", TrustedSignalContract),
        ("PEAU packets bound format, direction and lengths", AudioPacketContract),
        ("Machine Status bounds and Mac proof golden vector", MachineStatusProofContract),
        ("protocol compatibility", ProtocolCompatibility),
        ("hello casing and optional fields", HelloCasingAndOptionalFields),
        ("pair response base64 and casing", PairResponseBase64AndCasing),
        ("Apple PIN pairing derivation", ApplePinPairingDerivation),
        ("Swift Date numeric epoch", SwiftDateNumericEpoch),
        ("additive JSON fields", AdditiveJsonFields),
        ("keyboard macro shape", KeyboardMacroShape),
        ("NDJSON incremental framing", NdjsonIncrementalFraming),
        ("NDJSON hostile line limit", NdjsonHostileLineLimit),
        ("H.264 config golden bytes", H264ConfigGoldenBytes),
        ("HEVC config round trip", HevcConfigRoundTrip),
        ("video frame golden bytes", VideoFrameGoldenBytes),
        ("binary incremental framing", BinaryIncrementalFraming),
        ("binary hostile length limit", BinaryHostileLengthLimit),
        ("TLS-PSK fail-closed gate", TlsPskFailClosedGate),
    };

    public static int Main()
    {
        var failures = 0;
        foreach (var (name, test) in Tests)
        {
            try
            {
                test();
                Console.WriteLine($"PASS {name}");
            }
            catch (Exception exception)
            {
                failures++;
                Console.Error.WriteLine($"FAIL {name}: {exception.Message}");
            }
        }

        Console.WriteLine($"{Tests.Length - failures}/{Tests.Length} contract tests passed");
        return failures == 0 ? 0 : 1;
    }

    private static void ProtocolCompatibility()
    {
        Equal(2, PeelProtocol.CurrentProtocolVersion);
        Equal(2, PeelProtocol.MinimumSupportedProtocolVersion);
        True(PeelProtocol.IsCompatible(2, 2));
        True(!PeelProtocol.IsCompatible(null, null), "Missing fields must be treated as v1 and rejected by v2.");
        True(!PeelProtocol.IsCompatible(3, 3), "A v2 peer cannot safely speak to a peer whose minimum is v3.");
    }

    private static void HelloCasingAndOptionalFields()
    {
        var hello = PeelHello.CreateClient(
            "PAIR-123",
            "Windows Laptop",
            "Windows",
            capabilities: [PeelCapability.H264Video, PeelCapability.BinaryVideoTransportV2]);
        var json = PeelJson.SerializeString(hello);
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;

        Equal(PeelMessageType.ClientHello, root.GetProperty("type").GetString());
        Equal("PAIR-123", root.GetProperty("pairingID").GetString());
        True(!root.TryGetProperty("pairingId", out _), "clientHello uses pairingID with an uppercase D.");
        True(!root.TryGetProperty("deviceModel", out _), "Null additive fields must be omitted like Swift optionals.");
        Equal(2, root.GetProperty("protocolVersion").GetInt32());
        Equal(2, root.GetProperty("minimumSupportedProtocolVersion").GetInt32());

        const string oldHelloJson = "{\"type\":\"clientHello\",\"deviceName\":\"Old\",\"platform\":\"visionOS\"}";
        var oldHello = PeelJson.Deserialize<ClientHelloMessage>(Encoding.UTF8.GetBytes(oldHelloJson));
        Equal<int?>(null, oldHello.ProtocolVersion);
        Equal<int?>(null, oldHello.MinimumSupportedProtocolVersion);
        True(!PeelProtocol.IsCompatible(oldHello.ProtocolVersion, oldHello.MinimumSupportedProtocolVersion));
    }

    private static void PairResponseBase64AndCasing()
    {
        var response = new PairResponseMessage("Host", "Peel on Host", "pair-1", [0x00, 0xFF, 0x10], true);
        using var document = JsonDocument.Parse(PeelJson.Serialize(response));
        var root = document.RootElement;

        Equal("pair-1", root.GetProperty("pairingId").GetString());
        True(!root.TryGetProperty("pairingID", out _), "pairResponse uses pairingId with a lowercase d.");
        Equal("AP8Q", root.GetProperty("psk").GetString());

        var decoded = PeelJson.Deserialize<PairResponseMessage>(Encoding.UTF8.GetBytes(root.GetRawText()));
        SequenceEqual(response.Psk, decoded.Psk);
    }

    private static void ApplePinPairingDerivation()
    {
        byte[] salt = Enumerable.Range(0, PeelPinPairing.GeneratedSaltBytes)
            .Select(static value => checked((byte)value))
            .ToArray();
        byte[] key = PeelPinPairing.DerivePreSharedKey(" 123456 ", salt, "host-123");
        try
        {
            Equal(
                "7F75F4DB5E559E03FD10B60FDA391470A46B1834A4D238E9DD635280C4A4EF82",
                Convert.ToHexString(key));
            string proof = PeelPinPairing.CreateProof(key, " host-123 ", " client-abc ");
            Equal("Pvy0lSN86diOrYJvohSD74nb/ARXncW2LNbc9DXrJfA=", proof);
            True(PeelPinPairing.VerifyProof(key, "host-123", "client-abc", proof));
            True(!PeelPinPairing.VerifyProof(
                key,
                "host-123",
                "different-client",
                proof));
            True(!PeelPinPairing.VerifyProof(key, "host-123", "client-abc", "not-base64"));
        }
        finally
        {
            CryptographicOperations.ZeroMemory(key);
        }
    }

    private static void SwiftDateNumericEpoch()
    {
        var message = new InputRejectedMessage(7, "blocked", new DateTimeOffset(2001, 1, 1, 0, 0, 0, TimeSpan.Zero));
        using var document = JsonDocument.Parse(PeelJson.Serialize(message));
        var timestamp = document.RootElement.GetProperty("timestamp");
        Equal(JsonValueKind.Number, timestamp.ValueKind);
        Equal(0d, timestamp.GetDouble());

        const string wire = "{\"type\":\"hostStreamDebug\",\"windowId\":9,\"stage\":\"test\",\"timestamp\":60}";
        var decoded = PeelJson.Deserialize<HostStreamDebugMessage>(Encoding.UTF8.GetBytes(wire));
        Equal(new DateTimeOffset(2001, 1, 1, 0, 1, 0, TimeSpan.Zero), decoded.Timestamp);
    }

    private static void AdditiveJsonFields()
    {
        const string json = "{\"type\":\"clientPing\",\"futureOptionalField\":123}";
        var message = PeelJson.Deserialize<ClientPingMessage>(Encoding.UTF8.GetBytes(json));
        Equal(PeelMessageType.ClientPing, message.Type);
    }

    private static void KeyboardMacroShape()
    {
        var message = new KeyboardMacroMessage(
            [
                KeyboardMacroStep.ForChord(new KeyboardChord([KeyboardCommand.Command, KeyboardCommand.Shift, KeyboardCommand.F4])),
                KeyboardMacroStep.ForDelay(30),
            ],
            WindowId: 42,
            ExecuteAtomically: true);
        using var document = JsonDocument.Parse(PeelJson.Serialize(message));
        var steps = document.RootElement.GetProperty("steps");
        Equal("chord", steps[0].GetProperty("kind").GetString());
        Equal("command", steps[0].GetProperty("chord").GetProperty("keys")[0].GetString());
        Equal("f4", steps[0].GetProperty("chord").GetProperty("keys")[2].GetString());
        Equal("delayMilliseconds", steps[1].GetProperty("kind").GetString());
        Equal(30, steps[1].GetProperty("delayMilliseconds").GetInt32());
        True(!steps[1].TryGetProperty("text", out _));
    }

    private static void NdjsonIncrementalFraming()
    {
        var reader = new NdjsonReader();
        Equal(0, reader.Append(Encoding.UTF8.GetBytes("{\"type\":\"client")).Count);
        var lines = reader.Append(Encoding.UTF8.GetBytes("Ping\"}\n\n{\"type\":\"clientVisibility\",\"isVisible\":true}\r\n"));
        Equal(2, lines.Count);
        Equal("clientPing", PeelJson.ReadEnvelope(Encoding.UTF8.GetBytes(lines[0])).Type);
        Equal("clientVisibility", PeelJson.ReadEnvelope(Encoding.UTF8.GetBytes(lines[1])).Type);

        var encoded = PeelJson.SerializeLine(new ClientPingMessage());
        Equal((byte)'\n', encoded[^1]);
    }

    private static void NdjsonHostileLineLimit()
    {
        var reader = new NdjsonReader(8);
        Throws<InvalidDataException>(() => reader.Append(Encoding.UTF8.GetBytes("123456789")));
    }

    private static void H264ConfigGoldenBytes()
    {
        var packet = new VideoConfigPacket(
            0x01020304,
            PeelVideoCodec.H264,
            1920,
            1080,
            600,
            4,
            [0xAA, 0xBB],
            [0xCC]);
        var expected = Convert.FromHexString(
            "100403020101800700003804000058020000040200000001000000AABBCC");
        var encoded = packet.Encode();
        SequenceEqual(expected, encoded);

        var decoded = VideoConfigPacket.Decode(encoded);
        Equal(packet.WindowId, decoded.WindowId);
        Equal(packet.Codec, decoded.Codec);
        SequenceEqual(packet.Sps, decoded.Sps);
        SequenceEqual(packet.Pps, decoded.Pps);
    }

    private static void HevcConfigRoundTrip()
    {
        var packet = new VideoConfigPacket(
            12,
            PeelVideoCodec.Hevc,
            3840,
            2160,
            90000,
            4,
            [0x67, 0x01],
            [0x68],
            [0x40, 0x01, 0x0C]);
        var encoded = packet.Encode();
        Equal((byte)PeelBinaryPacketType.HevcVideoConfig, encoded[0]);
        Equal((byte)PeelVideoCodec.Hevc, encoded[5]);
        Equal(3u, BinaryPrimitives.ReadUInt32LittleEndian(encoded.AsSpan(19, 4)));

        var decoded = VideoConfigPacket.Decode(encoded);
        SequenceEqual(packet.Vps!, decoded.Vps!);
        SequenceEqual(packet.Sps, decoded.Sps);
        SequenceEqual(packet.Pps, decoded.Pps);
    }

    private static void VideoFrameGoldenBytes()
    {
        var packet = new VideoFramePacket(1, true, 2, 3, [0xDE, 0xAD]);
        var expected = Convert.FromHexString(
            "1101000000010200000000000000030000000000000002000000DEAD");
        var encoded = packet.Encode();
        SequenceEqual(expected, encoded);

        var decoded = VideoFramePacket.Decode(encoded);
        Equal(packet.WindowId, decoded.WindowId);
        Equal(packet.IsKeyframe, decoded.IsKeyframe);
        Equal(packet.PtsValue, decoded.PtsValue);
        Equal(packet.DurationValue, decoded.DurationValue);
        SequenceEqual(packet.Payload, decoded.Payload);
    }

    private static void BinaryIncrementalFraming()
    {
        var config = new VideoConfigPacket(1, PeelVideoCodec.H264, 640, 480, 600, 4, [1], [2]).Encode();
        var frame = new VideoFramePacket(1, true, 0, 10, [3, 4, 5]).Encode();
        var joined = config.Concat(frame).ToArray();
        var reader = new PeelBinaryPacketReader();

        Equal(0, reader.Append(joined.AsSpan(0, 8)).Count);
        var packets = reader.Append(joined.AsSpan(8));
        Equal(2, packets.Count);
        True(packets[0] is VideoConfigPacket);
        True(packets[1] is VideoFramePacket);
    }

    private static void BinaryHostileLengthLimit()
    {
        var header = new byte[VideoFramePacket.HeaderLength];
        header[0] = (byte)PeelBinaryPacketType.VideoFrame;
        BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(22, 4), 1_000_000);
        Throws<InvalidDataException>(() =>
            PeelBinaryFraming.TryGetCompletePacketLength(header, out _, maximumPacketBytes: 1024));

        header[0] = 0xFF;
        Throws<InvalidDataException>(() =>
            PeelBinaryFraming.TryGetCompletePacketLength(header, out _));
    }

    private static void TlsPskFailClosedGate()
    {
        Throws<PlatformNotSupportedException>(() => PeelSecureTransport.Require(null));
        Throws<ArgumentException>(() => new PeelPskCredential("pairing", []));
    }

    private static void True(bool condition, string? message = null)
    {
        if (!condition)
        {
            throw new InvalidOperationException(message ?? "Expected condition to be true.");
        }
    }

    private static void Equal<T>(T expected, T actual)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
        {
            throw new InvalidOperationException($"Expected '{expected}', got '{actual}'.");
        }
    }

    private static void SequenceEqual(byte[] expected, byte[] actual)
    {
        if (!expected.AsSpan().SequenceEqual(actual))
        {
            throw new InvalidOperationException(
                $"Expected {Convert.ToHexString(expected)}, got {Convert.ToHexString(actual)}.");
        }
    }

    private static void Throws<TException>(Action action)
        where TException : Exception
    {
        try
        {
            action();
        }
        catch (TException)
        {
            return;
        }

        throw new InvalidOperationException($"Expected {typeof(TException).Name}.");
    }
}
