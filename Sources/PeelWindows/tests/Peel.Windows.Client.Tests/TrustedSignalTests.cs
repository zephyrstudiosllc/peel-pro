using System.Diagnostics;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using Peel.Windows.Client.Services;
using Peel.Windows.Discovery;
using Peel.Windows.Protocol;
using Peel.Windows.Transport;

namespace Peel.Windows.Client.Tests;
internal static partial class Program
{
    private static async Task<int> NativeTrustedSignalsAsync()
    {
        foreach (string scenario in new[] { "revocation", "bad-proof", "wrong-node", "sequence", "partial-cancel", "unknown-type", "oversized", "malformed", "burst" })
            await NativeSignalCaseAsync(scenario);
        Console.WriteLine("PASS real TLS trusted signals: bilateral role proofs, fragmented challenge/frame, fresh activity, expiry, key revocation, forged publisher, wrong node, sequence regression and partial-read cancellation.");
        return 0;
    }
    private static async Task NativeSignalCaseAsync(string scenario)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(18));
        var (store, vault) = ParityStore(); using var secrets = vault;
        byte[] key = RandomNumberGenerator.GetBytes(32);
        string pairing = Guid.NewGuid().ToString(), local = Guid.NewGuid().ToString(), publisher = Guid.NewGuid().ToString();
        store.Save(ParityHostId, "Signal fixture", pairing, key, local);
        var transport = new BouncyCastlePskTransportFactory();
        await using var listener = await transport.ListenAsync(new IPEndPoint(IPAddress.Loopback, 0), new ParityTlsResolver(pairing, key), timeout.Token);
        ushort port = (ushort)((IPEndPoint)listener.LocalEndPoint).Port;
        var browser = new ParityBrowser();
        await using var receiver = new TrustedSignalReceiver(store, browser, transport);
        True(!receiver.Enabled, "Signals start off.");
        var sent = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var again = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var server = Task.Run(async () =>
        {
            await using var socket = await listener.AcceptAsync(timeout.Token);
            Equal(pairing, socket.PeerIdentity);
            var hello = TrustedSignals.ReadHello(await LocalAgentProtocol.ReadLineAsync(socket.Stream, timeout.Token) ?? throw new EndOfStreamException());
            Equal(local, hello.SubscriberHostId); Equal(ParityHostId, hello.PublisherHostId); Equal(pairing, hello.PairingId);
            string nonce = TrustedSignals.NewNonce();
            var challenge = new SignalChallengeMessage(nonce, publisher, Convert.ToBase64String(scenario == "bad-proof" ? new byte[32] : TrustedSignals.Proof(true, hello, nonce, publisher, key)));
            byte[] line = PeelJson.SerializeLine(challenge);
            await socket.Stream.WriteAsync(line.AsMemory(0, 13), timeout.Token); await socket.Stream.FlushAsync(timeout.Token);
            if (scenario == "partial-cancel") { sent.TrySetResult(); await ExpectSignalClosedAsync(socket.Stream, timeout.Token); return; }
            await socket.Stream.WriteAsync(line.AsMemory(13), timeout.Token); await socket.Stream.FlushAsync(timeout.Token);
            if (scenario == "bad-proof") { sent.TrySetResult(); await ExpectSignalClosedAsync(socket.Stream, timeout.Token); return; }
            var proof = TrustedSignals.ReadProof(await LocalAgentProtocol.ReadLineAsync(socket.Stream, timeout.Token) ?? throw new EndOfStreamException());
            True(TrustedSignals.Verify(false, proof.Proof, hello, nonce, publisher, key), "Client role proof must bind this exact challenge.");
            if (scenario is "unknown-type" or "oversized" or "malformed")
            {
                byte[] hostile = Encoding.UTF8.GetBytes(scenario == "unknown-type" ? "{\"type\":\"futureSignal\"}\n" : scenario == "malformed" ? "{oops}\n" : new string('a', 13000));
                await socket.Stream.WriteAsync(hostile, timeout.Token); await socket.Stream.FlushAsync(timeout.Token); sent.TrySetResult();
                await ExpectSignalClosedAsync(socket.Stream, timeout.Token); return;
            }
            var now = DateTimeOffset.UtcNow;
            var frame = new NearbySignalFrame(1, scenario == "wrong-node" ? Guid.NewGuid().ToString() : publisher, 12, now, now, now, "waiting", true, "#ffaa00", "#ffaa00");
            byte[] encoded = TrustedSignals.FrameLine(frame);
            await socket.Stream.WriteAsync(encoded.AsMemory(0, 19), timeout.Token);
            await socket.Stream.WriteAsync(encoded.AsMemory(19), timeout.Token); await socket.Stream.FlushAsync(timeout.Token); sent.TrySetResult();
            if (scenario == "burst")
            {
                try { for (int i = 0; i < 9; i++) await socket.Stream.WriteAsync(encoded, timeout.Token); await socket.Stream.FlushAsync(timeout.Token); }
                catch (IOException) { }
            }
            if (scenario is "sequence" or "revocation")
            {
                await again.Task.WaitAsync(timeout.Token);
                await socket.Stream.WriteAsync(TrustedSignals.FrameLine(frame with { Sequence = scenario == "sequence" ? 11UL : 13UL }), timeout.Token);
                await socket.Stream.FlushAsync(timeout.Token);
            }
            await ExpectSignalClosedAsync(socket.Stream, timeout.Token);
        }, timeout.Token);
        await receiver.StartAsync(timeout.Token);
        browser.Push(new(PeelServiceChangeKind.Added, "SignalFixture", "SignalFixture", TrustedSignals.ServiceType, "127.0.0.1", port,
            new Dictionary<string, byte[]> { ["hostId"] = Encoding.UTF8.GetBytes(ParityHostId), ["version"] = "1"u8.ToArray() }));
        await sent.Task.WaitAsync(timeout.Token);
        if (scenario is "revocation" or "sequence")
        {
            await WaitUntilAsync(() => receiver.Snapshot().Count == 1);
            Equal("Needs approval", receiver.Snapshot().Single().StateLabel);
            Equal(ParityHostId, receiver.Snapshot().Single().HostId);
            if (scenario == "revocation")
            {
                await Task.Delay(TimeSpan.FromSeconds(3.7), timeout.Token); Equal(0, receiver.Snapshot().Count);
                again.TrySetResult(); await WaitUntilAsync(() => receiver.Snapshot().Count == 1);
                store.Forget(ParityHostId);
            }
            else again.TrySetResult();
        }
        if (scenario == "partial-cancel") await receiver.StopAsync();
        await server.WaitAsync(timeout.Token);
        await WaitUntilAsync(() => receiver.Snapshot().Count == 0);
        Equal(0, receiver.Snapshot().Count);
        await receiver.StopAsync(); True(!receiver.Enabled, "Explicit stop must revoke the generation.");
        store.Forget(ParityHostId); Equal(0, vault.Count); CryptographicOperations.ZeroMemory(key);
        Console.WriteLine("PASS trusted signal TLS " + scenario);
    }
    private static async Task ExpectSignalClosedAsync(Stream stream, CancellationToken token)
    {
        try { Equal(0, await stream.ReadAsync(new byte[1], token)); }
        catch (IOException) { }
    }
}
