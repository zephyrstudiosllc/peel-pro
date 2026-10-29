using Peel.Windows.Client.Services;
using Peel.Windows.Protocol;
using System.Net;
using Peel.Windows.Transport;

namespace Peel.Windows.Client.Tests;
internal static partial class Program
{
    private static async Task<int> NativeAudioReceiveAsync(bool voice = false)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        var transport = new BouncyCastlePskTransportFactory();
        await using var listener = await transport.ListenAsync(new(IPAddress.Loopback, 0), new NativeStatusKeys(), timeout.Token);
        var endpoint = (IPEndPoint)listener.LocalEndPoint;
        var host = Candidate("audio-fixture", "127.0.0.1", endpoint.Port);
        var credentials = new InMemoryPairedHostCredentialStore(); credentials.Set(new(host.StableHostId, Fixture.PairingId, Fixture.Key));
        var resolver = new MutableHostResolver(host);
        var packetsReceived = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var server = Task.Run(async () =>
        {
            await using var control = await listener.AcceptAsync(timeout.Token);
            async Task<byte[]> Read(string type)
            {
                while (true)
                {
                    byte[] line = await LocalAgentProtocol.ReadLineAsync(control.Stream, timeout.Token) ?? throw new EndOfStreamException();
                    if (PeelJson.ReadEnvelope(line).Type == type) return line;
                }
            }
            _ = await Read("clientHello");
            await control.Stream.WriteAsync(PeelJson.SerializeLine(PeelHello.CreateHost("Audio fixture", capabilities: ["mac-system-audio-v1", "remote-voice-v1"])), timeout.Token);
            var request = PeelJson.Deserialize<AudioSessionRequestMessage>(await Read("audioSessionRequest"));
            var challenge = new AudioPairingChallengeMessage(request.RequestId, Fixture.PairingId,
                Convert.ToBase64String(System.Security.Cryptography.RandomNumberGenerator.GetBytes(32)), DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0 + 10, voice ? "voice" : "playback");
            Equal(voice ? "voice" : "playback", request.Mode);
            await control.Stream.WriteAsync(PeelJson.SerializeLine(challenge), timeout.Token);
            var proof = PeelJson.Deserialize<AudioPairingProofMessage>(await Read("audioPairingProof"));
            Equal(AudioPairingProof.Make(challenge, Fixture.Key), proof.Proof);
            string ticket = Convert.ToBase64String(System.Security.Cryptography.RandomNumberGenerator.GetBytes(32));
            await control.Stream.WriteAsync(PeelJson.SerializeLine(new AudioSessionStateMessage(request.RequestId, Fixture.PairingId, "ready", Ticket: ticket)), timeout.Token);
            await using var audio = await listener.AcceptAsync(timeout.Token);
            var hello = PeelJson.Deserialize<AudioStreamHelloMessage>(await LocalAgentProtocol.ReadLineAsync(audio.Stream, timeout.Token) ?? throw new EndOfStreamException());
            Equal(ticket, hello.Ticket); Equal(request.RequestId, hello.RequestId); Equal(Fixture.PairingId, audio.PeerIdentity);
            Task? input = voice ? Task.Run(async () =>
            {
                var reader = new AudioPacketReader(1);
                Equal((byte)0, (await reader.ReadAsync(audio.Stream, timeout.Token)).Kind);
                for (ulong i = 0; i < 10; i++)
                {
                    var packet = await reader.ReadAsync(audio.Stream, timeout.Token);
                    Equal(i, packet.Sequence); Equal((long)i * 960, packet.SampleTime);
                    True(packet.Payload.All(b => b == 0), "Fixture uplink must contain generated silence only.");
                }
            }) : null;
            await audio.Stream.WriteAsync(new AudioPacket(0, 0, 0, 0, []).Encode(), timeout.Token);
            for (ulong i = 1; i <= 10; i++)
            {
                await audio.Stream.WriteAsync(new AudioPacket(1, 0, i, (long)i * 960, new byte[3840]).Encode(), timeout.Token);
                await Task.Delay(20, timeout.Token);
            }
            if (input is not null) await input.WaitAsync(timeout.Token);
            packetsReceived.TrySetResult();
            var stopped = PeelJson.Deserialize<AudioSessionRequestMessage>(await Read("audioSessionRequest"));
            True(!stopped.Enabled && stopped.RequestId == request.RequestId, "Stopping must revoke the exact native audio session.");
            Equal(voice ? "voice" : "playback", stopped.Mode);
        });
        var microphone = new SilentMicrophoneFixture();
        await using var session = new ClientSession(transport, credentials, resolver, new("Audio fixture", "PC", "Windows", "test"), new ClientSessionOptions { SupportsAudioPlayback = true, SupportsMicrophone = true });
        await using var audioClient = new ClientAudioPlayback(session, transport, credentials, resolver, () => microphone);
        await session.ConnectAsync(host, timeout.Token);
        if (voice) await audioClient.StartVoiceAsync(timeout.Token); else await audioClient.StartAsync(timeout.Token);
        await WaitUntilAsync(() => audioClient.Status.StartsWith(voice ? "Microphone forwarding ON" : "Playing", StringComparison.Ordinal));
        await packetsReceived.Task.WaitAsync(timeout.Token);
        await audioClient.StopAsync(); await server.WaitAsync(timeout.Token);
        if (voice) True(microphone.Stopped && microphone.Disposed, "Uplink must be awaited and disposed before Stop returns.");
        else True(!microphone.Started, "Playback must never start microphone capture.");
        Console.WriteLine($"PASS native audio {(voice ? "voice duplex" : "receive")}: real TLS-PSK control and auxiliary sockets, fresh mode-bound proof, ticket binding, PEAU silence to Windows output, exact-request Stop. No microphone recorded.");
        return 0;
    }
    private static int NativeAudioOutputSmoke()
    {
        True(WaveAudioPlayback.Available, "A native output device must be present.");
        using var playback = new WaveAudioPlayback();
        int accepted = 0;
        for (int i = 0; i < 12; i++) if (playback.Offer(new byte[3840])) accepted++;
        True(accepted is > 0 and <= 12, "Silence must be submitted to the native output.");
        playback.Dispose();
        Console.WriteLine($"PASS native Windows PCM output: {accepted} bounded silence buffers accepted; reset, unprepare and close completed.");
        return 0;
    }
    private sealed class SilentMicrophoneFixture : IMicrophoneCapture
    {
        internal bool Started, Stopped, Disposed;
        public async Task RunAsync(Func<byte[], CancellationToken, Task> send, CancellationToken token)
        {
            Started = true;
            try { while (true) { await send(new byte[1920], token); await Task.Delay(20, token); } }
            finally { Stopped = true; }
        }
        public void Dispose() => Disposed = true;
    }
    private static async Task AudioConsentAsync()
    {
        var stream = new ScriptedDuplexStream();
        var fixture = new Fixture(Candidate("host-1", "fresh.local", 2222), stream);
        await using var session = new ClientSession(fixture.Transport, fixture.Credentials, fixture.Resolver,
            new("Test", "PC", "Windows", "test"), new ClientSessionOptions { SupportsAudioPlayback = true, PingInterval = TimeSpan.FromHours(1) });
        var connect = session.ConnectAsync(fixture.Resolver.Current, default);
        await stream.WaitForWritesAsync(1);
        stream.EnqueueRead(PeelJson.SerializeLine(PeelHello.CreateHost("Mac", capabilities: ["mac-system-audio-v1"])));
        await connect; await stream.WaitForWritesAsync(2);
        await ThrowsAsync<InvalidOperationException>(() => session.BeginVoiceAsync(default));
        Equal(2, SnapshotWrites(stream).Length);
        var challenge = new AudioPairingChallengeMessage(Guid.NewGuid().ToString(), Fixture.PairingId,
            Convert.ToBase64String(new byte[32]), DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0 + 10, "playback");
        stream.EnqueueRead(PeelJson.SerializeLine(challenge)); await Task.Delay(30);
        Equal(2, SnapshotWrites(stream).Length);
        var starting = session.BeginAudioPlaybackAsync(default);
        await stream.WaitForWritesAsync(3);
        var request = DeserializeWrite<AudioSessionRequestMessage>(stream, 2);
        Equal("playback", request.Mode);
        challenge = challenge with { RequestId = request.RequestId };
        stream.EnqueueRead(PeelJson.SerializeLine(challenge)); await stream.WaitForWritesAsync(4);
        Equal(AudioPairingProof.Make(challenge, Fixture.Key), DeserializeWrite<AudioPairingProofMessage>(stream, 3).Proof);
        stream.EnqueueRead(PeelJson.SerializeLine(new AudioSessionStateMessage(request.RequestId, Fixture.PairingId, "ready", Ticket: Convert.ToBase64String(new byte[32]))));
        var receipt = await starting;
        await session.EndAudioAsync(receipt.RequestId, receipt.Generation);
        await stream.WaitForWritesAsync(5); True(!DeserializeWrite<AudioSessionRequestMessage>(stream, 4).Enabled, "Stop must disable this exact audio request.");
        stream.EnqueueRead(PeelJson.SerializeLine(challenge)); await Task.Delay(30); Equal(5, SnapshotWrites(stream).Length);
        var next = session.BeginAudioPlaybackAsync(default); await stream.WaitForWritesAsync(6);
        var nextRequest = DeserializeWrite<AudioSessionRequestMessage>(stream, 5);
        stream.EnqueueRead(PeelJson.SerializeLine(challenge with { RequestId = nextRequest.RequestId, Mode = "voice" }));
        await ThrowsAsync<OperationCanceledException>(() => next);
        await WaitUntilAsync(() => session.State == Peel.Windows.Client.Models.PeelConnectionState.Error);
        Equal(Peel.Windows.Client.Models.PeelConnectionState.Error, session.State);
    }
}
