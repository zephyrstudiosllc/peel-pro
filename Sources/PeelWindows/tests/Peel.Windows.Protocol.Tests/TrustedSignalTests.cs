using System.Text;
using System.Text.Json;
using Peel.Windows.Protocol;

namespace Peel.Windows.Protocol.Tests;
internal static partial class Program
{
    private static void TrustedSignalContract()
    {
        var hello = new SignalHelloMessage("AAAAAAAA-0000-0000-0000-000000000001", "BBBBBBBB-0000-0000-0000-000000000002",
            "CCCCCCCC-0000-0000-0000-000000000003", "DDDDDDDD-0000-0000-0000-000000000004", Convert.ToBase64String(Enumerable.Range(0, 32).Select(i => (byte)i).ToArray()));
        string nonce = Convert.ToBase64String(Enumerable.Range(32, 32).Select(i => (byte)i).ToArray()), publisher = "EEEEEEEE-0000-0000-0000-000000000005";
        byte[] key = Enumerable.Range(64, 32).Select(i => (byte)i).ToArray();
        // Independent Swift CryptoKit execution on the reference Mac, October 5, 2026.
        const string server = "12nVwQAczJREscXEULrJpl9F9fihwNs8SBjTdp3tvG8=", client = "W2ji/csofIw8HbnSIy9dtgomOtPMcGcwy5D0GLUDK38=";
        Equal(server, Convert.ToBase64String(TrustedSignals.Proof(true, hello, nonce, publisher, key)));
        Equal(client, Convert.ToBase64String(TrustedSignals.Proof(false, hello, nonce, publisher, key)));
        True(TrustedSignals.Verify(true, server, hello, nonce, publisher, key));
        True(!TrustedSignals.Verify(false, server, hello, nonce, publisher, key));
        True(!TrustedSignals.Verify(true, server, hello with { SubscriberHostId = Guid.NewGuid().ToString() }, nonce, publisher, key));
        True(!TrustedSignals.Verify(true, server, hello, TrustedSignals.NewNonce(), publisher, key));
        Equal(hello, TrustedSignals.ReadHello(PeelJson.Serialize(hello)));
        Throws<InvalidDataException>(() => TrustedSignals.ReadHello(Encoding.UTF8.GetBytes(PeelJson.SerializeString(hello).Replace("peelSignalHello", "peelSignalProof"))));
        Throws<InvalidDataException>(() => TrustedSignals.Uuid("aaaaaaaa-0000-0000-0000-00000000000A"));
        Throws<InvalidDataException>(() => TrustedSignals.Base64(" " + nonce));
        Throws<InvalidDataException>(() => TrustedSignals.Base64("AA=="));
        Throws<InvalidDataException>(() => TrustedSignals.ReadChallenge(new byte[4097]));
        Throws<InvalidDataException>(() => TrustedSignals.ReadProof(Encoding.UTF8.GetBytes("{\"type\":\"peelSignalProof\",\"type\":\"peelSignalProof\",\"proof\":\"" + client + "\"}")));
        Throws<JsonException>(() => TrustedSignals.ReadChallenge(Encoding.UTF8.GetBytes("{\"type\":\"peelSignalChallenge\"}")));
        var now = DateTimeOffset.UtcNow;
        var frame = new NearbySignalFrame(1, publisher, 42, now, now, now, "waiting", true, "brightness 128\n0:#ffaa00 0.5s pulse;1:#ff0000 50ms linear\nrepeat", "#ffaa00");
        var decoded = TrustedSignals.ReadFrame(TrustedSignals.FrameLine(frame)); Equal(42UL, decoded.Sequence); Equal("Needs approval", decoded.StateLabel);
        foreach (string program in new[] { "off", "#123456", "#123456 #ABCDEF", "0:#123456", "off 1s ease", "brightness 0\n#123456 0.01s cosine 1s\nrepeat" }) TrustedSignals.ValidateProgram(program);
        foreach (string program in new[] { "", "off\n", "brightness 256", "brightness 01", "#123456 0s ease", "#123456 0.00s ease", "8:#123456", "0:#123456;", "#123456  1s ease", "off 1s invalid", new string('x', 513), string.Join('\n', Enumerable.Repeat("off", 21)) })
            Throws<InvalidDataException>(() => TrustedSignals.ValidateProgram(program));
        Throws<InvalidDataException>(() => TrustedSignals.Validate(frame with { Version = 2 }));
        Throws<InvalidDataException>(() => TrustedSignals.Validate(frame with { AggregateState = "guessed" }));
        Throws<InvalidDataException>(() => TrustedSignals.Validate(frame with { ProgramStartedAt = now.AddDays(-367) }));
        Throws<InvalidDataException>(() => TrustedSignals.ReadFrame(PeelJson.Serialize(new SignalFrameMessage(Convert.ToBase64String(new byte[8193])))));
        string hostile = PeelJson.SerializeString(frame).Replace("\"sequence\":42", "\"sequence\":-1");
        Throws<JsonException>(() => TrustedSignals.ReadFrame(PeelJson.Serialize(new SignalFrameMessage(Convert.ToBase64String(Encoding.UTF8.GetBytes(hostile))))));
        hostile = PeelJson.SerializeString(frame).Replace("\"hasVisibleActivity\":true,", "");
        Throws<JsonException>(() => TrustedSignals.ReadFrame(PeelJson.Serialize(new SignalFrameMessage(Convert.ToBase64String(Encoding.UTF8.GetBytes(hostile))))));
    }
}
