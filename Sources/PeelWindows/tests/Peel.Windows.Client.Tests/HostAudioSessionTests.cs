using Peel.Windows.Host.Audio;
using System.Collections.Concurrent;
using Peel.Windows.Host.Networking;
using Peel.Windows.Client.Services;
using Peel.Windows.Protocol;
using Peel.Windows.Transport;

namespace Peel.Windows.Client.Tests;
internal static partial class Program
{
    private sealed class AudioTestKeys : IPeelPskCredentialResolver
    {
        internal bool Revoked, Changed;
        public bool TryResolve(string id, out PeelPskCredential? credential)
        { credential = !Revoked && id == Fixture.PairingId ? new(id, Changed ? new byte[32] : Fixture.Key) : null; return credential is not null; }
    }
    private sealed class SilentHostCapture(bool burst = true) : IHostAudioCapture
    {
        internal bool Started, Disposed;
        private Task worker = Task.CompletedTask;
        private CancellationTokenSource? stop;
        public Task Completion => worker;
        public ValueTask StartAsync(Action<AudioPacket> offer, CancellationToken token)
        {
            Started = true; stop = CancellationTokenSource.CreateLinkedTokenSource(token);
            if (burst) for (ulong i = 0; i < 50; i++) offer(new(1, 0, i, (long)i * 960, new byte[3840]));
            worker = Task.Run(async () =>
            {
                try
                {
                    ulong sequence = 50;
                    while (true)
                    {
                        await Task.Delay(burst ? 100000 : 20, stop.Token);
                        offer(new(1, 0, sequence, (long)sequence * 960, new byte[3840])); sequence++;
                    }
                }
                catch (OperationCanceledException) when (stop.IsCancellationRequested) { }
            });
            return ValueTask.CompletedTask;
        }
        public async ValueTask DisposeAsync()
        { if (stop is not null) { stop.Cancel(); await worker; stop.Dispose(); stop = null; } Disposed = true; }
    }
    private static async Task HostAudioAuthorizationAsync()
    {
        foreach (string scenario in new[] { "off", "voice", "unknown-mode", "bad-proof", "voice-proof", "wrong-proof-request", "wrong-proof-pair",
            "consent-replaced", "key-changed", "revoked", "wrong-ticket", "wrong-hello-pair", "wrong-hello-request", "wrong-version",
            "trailing-bytes", "unknown-hello", "malformed", "oversized", "partial-cancel", "burst-stop", "consent-stop", "hidden-stop", "revoke-stop", "incoming-stop" })
        {
            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(8));
            var capture = new SilentHostCapture(); var sharing = new HostAudioSharing(true, () => capture);
            var keys = new AudioTestKeys(); bool visible = true;
            var states = new ConcurrentQueue<AudioSessionStateMessage>();
            await using var session = new HostAudioSession(sharing, keys, Fixture.PairingId, () => visible,
                (value, _) => { if (value is AudioSessionStateMessage state) states.Enqueue(state); return ValueTask.FromResult(true); });
            if (scenario != "off") sharing.SetEnabled(true);
            string id = Guid.NewGuid().ToString("D");
            var result = await session.RequestAsync(new(id, true, scenario == "voice" ? "voice" : scenario == "unknown-mode" ? "unknown" : "playback"), deadline.Token);
            if (scenario is "off" or "voice" or "unknown-mode")
            { Equal("unavailable", ((AudioSessionStateMessage)result!).Status); True(!capture.Started, scenario); continue; }
            var challenge = (AudioPairingChallengeMessage)result!;
            var busy = (AudioSessionStateMessage)(await session.RequestAsync(new(Guid.NewGuid().ToString(), true), deadline.Token))!;
            Equal("unavailable", busy.Status);
            if (scenario == "consent-replaced") { sharing.SetEnabled(false); sharing.SetEnabled(true); }
            if (scenario == "key-changed") keys.Changed = true;
            if (scenario == "revoked") keys.Revoked = true;
            var proof = new AudioPairingProofMessage(scenario == "wrong-proof-request" ? Guid.NewGuid().ToString() : id,
                scenario == "wrong-proof-pair" ? Guid.NewGuid().ToString() : Fixture.PairingId,
                scenario == "bad-proof" ? Convert.ToBase64String(new byte[32]) : AudioPairingProof.Make(scenario == "voice-proof" ? challenge with { Mode = "voice" } : challenge, Fixture.Key));
            var ready = (AudioSessionStateMessage)(await session.ProveAsync(proof, deadline.Token))!;
            if (scenario is "bad-proof" or "voice-proof" or "wrong-proof-request" or "wrong-proof-pair" or "consent-replaced" or "key-changed" or "revoked")
            { Equal("stopped", ready.Status); True(!capture.Started, scenario); continue; }
            Equal("ready", ready.Status); True(!capture.Started, "A proof must not start capture before attachment.");
            var hello = new AudioStreamHelloMessage(scenario == "wrong-hello-request" ? Guid.NewGuid().ToString() : id,
                scenario == "wrong-hello-pair" ? Guid.NewGuid().ToString() : Fixture.PairingId,
                scenario == "wrong-ticket" ? Convert.ToBase64String(new byte[32]) : ready.Ticket!, scenario == "wrong-version" ? 2 : 1);
            var stream = new ScriptedDuplexStream();
            byte[] line = PeelJson.SerializeLine(hello);
            if (scenario == "trailing-bytes") line = [.. line, 1];
            if (scenario == "unknown-hello") line = PeelJson.SerializeLine(new { type = "unknown" });
            if (scenario == "malformed") line = "{broken}\n"u8.ToArray();
            if (scenario == "oversized") line = Enumerable.Repeat((byte)'a', 4097).ToArray();
            if (scenario == "partial-cancel") line = "{\"type\":"u8.ToArray();
            stream.EnqueueRead(line);
            using var attachmentStop = CancellationTokenSource.CreateLinkedTokenSource(deadline.Token);
            var attached = session.AttachAsync(new(stream, Fixture.PairingId), attachmentStop.Token);
            if (scenario == "partial-cancel") attachmentStop.Cancel();
            if (scenario is "wrong-ticket" or "wrong-hello-pair" or "wrong-hello-request" or "wrong-version" or "trailing-bytes" or "unknown-hello" or "malformed" or "oversized" or "partial-cancel")
            { await attached.WaitAsync(deadline.Token); True(!capture.Started, scenario); continue; }
            await stream.WaitForWritesAsync(7);
            Equal(7, SnapshotWrites(stream).Length); // Format plus six queued PCM; later burst samples were dropped.
            Equal(36, SnapshotWrites(stream)[0].Length);
            var replay = new ScriptedDuplexStream(); replay.EnqueueRead(PeelJson.SerializeLine(hello));
            await session.AttachAsync(new(replay, Fixture.PairingId), deadline.Token);
            Equal(0, SnapshotWrites(replay).Length);
            var ignoredStop = await session.RequestAsync(new(Guid.NewGuid().ToString(), false), deadline.Token);
            True(ignoredStop is null && !capture.Disposed, "A foreign request must not stop the current capture.");
            switch (scenario)
            {
                case "consent-stop": sharing.SetEnabled(false); break;
                case "hidden-stop": visible = false; break;
                case "revoke-stop": keys.Revoked = true; break;
                case "incoming-stop": stream.EnqueueRead([1]); break;
                default: await session.RequestAsync(new(id, false), deadline.Token); break;
            }
            await attached.WaitAsync(deadline.Token);
            True(capture.Disposed, "Stop must await capture disposal: " + scenario);
            True(states.Any(s => s.Status == "stopped"), "The control peer receives a stopped state.");
        }
    }
    private static async Task<int> NativeHostAudioAsync(bool nativeCapture = false)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        var factory = new BouncyCastlePskTransportFactory(); var keys = new AudioTestKeys();
        IHostAudioCapture capture = nativeCapture ? new WindowsLoopbackAudioCapture((uint)Environment.ProcessId, true) : new SilentHostCapture(false);
        var sharing = new HostAudioSharing(true, () => capture); sharing.SetEnabled(true);
        await using var listener = await factory.ListenAsync(new(System.Net.IPAddress.Loopback, 0), keys, timeout.Token);
        await using var host = new HostControlSessionManager(new HostControlSessionOptions("Audio host fixture", capabilities: ["mac-system-audio-v1", PeelCapability.ClientVisibility])
        { AudioSharing = sharing, AudioCredentials = keys });
        var router = new HostAuthenticatedConnectionRouter(host.RunAuthenticatedSessionAsync,
            static (connection, _) => connection.DisposeAsync().AsTask(), new(), host.RunAuthenticatedAudioSessionAsync);
        var serving = Task.Run(async () =>
        {
            var control = router.RouteAsync(await listener.AcceptAsync(timeout.Token), timeout.Token);
            var audio = router.RouteAsync(await listener.AcceptAsync(timeout.Token), timeout.Token);
            await Task.WhenAll(control, audio);
        });
        var endpoint = (System.Net.IPEndPoint)listener.LocalEndPoint;
        var candidate = Candidate("audio-host-fixture", "127.0.0.1", endpoint.Port);
        var credentials = new InMemoryPairedHostCredentialStore(); credentials.Set(new(candidate.StableHostId, Fixture.PairingId, Fixture.Key));
        var resolver = new MutableHostResolver(candidate);
        await using var client = new ClientSession(factory, credentials, resolver, new("Audio fixture", "PC", "Windows", "test"), new ClientSessionOptions { SupportsAudioPlayback = true });
        await using var playback = new ClientAudioPlayback(client, factory, credentials, resolver);
        using var output = nativeCapture ? new WaveAudioPlayback() : null;
        using var generating = CancellationTokenSource.CreateLinkedTokenSource(timeout.Token);
        var generator = Task.Run(async () =>
        {
            try { while (output is not null) { output.Offer(new byte[3840]); await Task.Delay(20, generating.Token); } }
            catch (OperationCanceledException) when (generating.IsCancellationRequested) { }
        });
        try
        {
            await client.ConnectAsync(candidate, timeout.Token);
            await playback.StartAsync(timeout.Token);
            await WaitUntilAsync(() => playback.Status.StartsWith("Playing", StringComparison.Ordinal));
            await Task.Delay(300, timeout.Token);
            await playback.StopAsync(); await WaitUntilAsync(() => capture.Completion.IsCompleted && (capture is not SilentHostCapture fixture || fixture.Disposed));
            await client.DisconnectAsync(timeout.Token); await serving.WaitAsync(timeout.Token);
        }
        finally { generating.Cancel(); await generator; }
        Console.WriteLine($"PASS native Windows audio hosting ({(nativeCapture ? "WASAPI loopback" : "generated PCM")}): real TLS-PSK routing, control proof, one-use auxiliary ticket, owned stereo silence to native playback, and awaited Stop. No microphone or other-app audio recorded.");
        return 0;
    }

    private static async Task<int> NativeAudioExpiryAsync()
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(25));
        foreach (bool prove in new[] { false, true })
        {
            var capture = new SilentHostCapture(); var sharing = new HostAudioSharing(true, () => capture); sharing.SetEnabled(true);
            var expired = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            await using var session = new HostAudioSession(sharing, new AudioTestKeys(), Fixture.PairingId, () => true,
                (state, _) => { if (state is AudioSessionStateMessage { Status: "stopped" }) expired.TrySetResult(); return ValueTask.FromResult(true); });
            string id = Guid.NewGuid().ToString();
            var challenge = (AudioPairingChallengeMessage)(await session.RequestAsync(new(id, true), timeout.Token))!;
            if (prove) await session.ProveAsync(new(id, Fixture.PairingId, AudioPairingProof.Make(challenge, Fixture.Key)), timeout.Token);
            await expired.Task.WaitAsync(timeout.Token);
            True(!capture.Started, "Expired authorization must not capture.");
            True(await session.ProveAsync(new(id, Fixture.PairingId, AudioPairingProof.Make(challenge, Fixture.Key)), timeout.Token) is null, "Expired proof cannot restore authorization.");
            True(await session.RequestAsync(new(Guid.NewGuid().ToString(), true), timeout.Token) is AudioPairingChallengeMessage, "Expiration frees the pending owner.");
        }
        Console.WriteLine("PASS audio challenge and attachment-ticket expiration: actual ten-second deadlines, stopped state, late proof rejection, and fresh retry without capture.");
        return 0;
    }
}
