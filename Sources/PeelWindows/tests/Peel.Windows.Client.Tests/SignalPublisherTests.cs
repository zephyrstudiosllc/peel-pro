using System.Collections.Concurrent;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using Peel.Windows.Client.Services;
using Peel.Windows.Client.Utilities;
using Peel.Windows.Discovery;
using Peel.Windows.Host.Security;
using Peel.Windows.Protocol;
using Peel.Windows.Transport;

namespace Peel.Windows.Client.Tests;

internal static partial class Program
{
    private static async Task SignalPublishingCancelDuringStartAsync()
    {
        var (hosts, vault) = ParityStore(); using var secrets = vault;
        using var hostVault = new ParityVault();
        var clients = new WindowsPairedClientStore(hostVault, new ParityMetadata(), "Peel.Signal.Host.Fixture");
        byte[] key = RandomNumberGenerator.GetBytes(32);
        hosts.Save(ParityHostId, "Consent race", Guid.NewGuid().ToString(), key, Guid.NewGuid().ToString());
        TrustedSignalPublisher? publisher = null;
        await using (publisher = new(hosts, () => clients, () => { publisher!.Cancel(); return Guid.NewGuid().ToString(); }, new SignalTestRegistrar()))
        {
            try { await publisher.StartAsync(CancellationToken.None); throw new Exception("Start must observe the intervening consent cancellation."); }
            catch (OperationCanceledException) { }
            True(!publisher.Enabled && publisher.Port == 0, "A start completing after lock/stop must not restore consent.");
        }
        CryptographicOperations.ZeroMemory(key);
    }
    private static void SignalPublishingUsesPairingIdentity()
    {
        var (hosts, vault) = ParityStore(); using var secrets = vault;
        using var hostVault = new ParityVault();
        var clients = new WindowsPairedClientStore(hostVault, new ParityMetadata(), "Peel.Signal.Host.Fixture");
        string identity = Guid.NewGuid().ToString(), incoming = Guid.NewGuid().ToString(), alias = Guid.NewGuid().ToString(), outgoing = Guid.NewGuid().ToString();
        byte[] key = RandomNumberGenerator.GetBytes(32);
        clients.AddOrReplace(incoming, "Incoming fixture", Guid.NewGuid().ToString(), key);
        hosts.Save(ParityHostId, "Outgoing fixture", outgoing, key, alias);
        hosts.Save(Guid.NewGuid().ToString(), "Legacy outgoing", Guid.NewGuid().ToString(), key);
        var trust = new SignalPublisherTrust(hosts, () => clients, identity);
        var peers = trust.Snapshot(); Equal(2, peers.Count);
        Equal(identity, peers.Single(p => p.IsHostPairing).PublisherId);
        Equal(alias, peers.Single(p => !p.IsHostPairing).PublisherId);
        foreach (string state in new[] { "working", "toolRunning", "waiting", "error", "completed", "idle" }) TrustedSignals.ValidateProgram(TrustedSignalPublisher.ProgramFor(state));
        clients.AddOrReplace(outgoing, "Ambiguous identity", Guid.NewGuid().ToString(), key);
        True(!trust.Snapshot().Any(p => p.PairingId == outgoing), "Colliding pairing namespaces must fail closed.");
        CryptographicOperations.ZeroMemory(key);
    }

    private static async Task<int> NativeSignalPublishingAsync()
    {
        foreach (string scenario in new[] { "outgoing", "incoming", "profiles", "wrong-publisher", "wrong-subscriber", "wrong-pairing", "bad-proof", "reflected-proof",
            "partial-hello", "partial-proof", "unknown-type", "malformed", "oversized", "extra-input", "revoked-before-proof", "revoked-after-proof", "key-change" })
            await NativeSignalPublishingCaseAsync(scenario);
        Console.WriteLine("PASS native trusted signal publishing: exact TLS, both pairing directions, mutual role proofs, identity binding, bounded hostile input, cancellation, revocation and changed-key teardown.");
        return 0;
    }

    private static async Task<int> NativeSignalAdvertisementAsync()
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(25));
        string id = Guid.NewGuid().ToString();
        var browser = new WindowsDnsSdBrowser();
        var found = new TaskCompletionSource<PeelDiscoveredService>(TaskCreationOptions.RunContinuationsAsynchronously);
        var browsing = Task.Run(async () =>
        {
            try
            {
                await foreach (var service in browser.BrowseAsync(TrustedSignals.ServiceType, timeout.Token))
                    if (service.HostId == id && service.ChangeKind == PeelServiceChangeKind.Added) { found.TrySetResult(service); return; }
            }
            catch (OperationCanceledException) when (timeout.IsCancellationRequested) { }
        });
        await using (var registration = await new WindowsDnsSdRegistrar().RegisterAsync(new("Peel Signals · " + id, TrustedSignals.ServiceType, 43210,
            new Dictionary<string, byte[]> { ["hostId"] = Encoding.UTF8.GetBytes(id), ["version"] = "1"u8.ToArray() }), timeout.Token))
        {
            var discovered = await found.Task.WaitAsync(timeout.Token); Equal((ushort)43210, discovered.Port!.Value); Equal("1", discovered.GetUtf8Txt("version"));
        }
        timeout.Cancel(); await browsing;
        Console.WriteLine("PASS real Windows DNS-SD trusted-signal advertisement/discovery with exact hostId/version/port; fixture registration removed.");
        return 0;
    }
    private static async Task NativeSignalPublishingCaseAsync(string scenario)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(18));
        var (hosts, vault) = ParityStore(); using var secrets = vault;
        using var hostVault = new ParityVault();
        var clients = new WindowsPairedClientStore(hostVault, new ParityMetadata(), "Peel.Signal.Host.Fixture");
        string pairing = Guid.NewGuid().ToString(), identity = Guid.NewGuid().ToString(), alias = Guid.NewGuid().ToString(), subscriber = Guid.NewGuid().ToString();
        byte[] key = RandomNumberGenerator.GetBytes(32);
        bool incoming = scenario == "incoming";
        if (incoming) clients.AddOrReplace(pairing, "Native signal peer", subscriber, key);
        else hosts.Save(subscriber, "Native signal peer", pairing, key, alias);
        var registrations = new SignalTestRegistrar();
        var transport = new BouncyCastlePskTransportFactory();
        using var lights = new LightingFixture();
        if (scenario == "profiles")
        {
            lights.Settings.SavePresentation(new(DisplayMode: "perAgent"));
            lights.Settings.Profiles.Add([LightingProfile.Quiet]);
        }
        await using var publisher = new TrustedSignalPublisher(hosts, () => clients, () => identity, registrations, transport, IPAddress.Loopback, lights.Settings);
        True(!publisher.Enabled && publisher.Port == 0, "Publishing starts off without an open listener.");
        var readings = new List<AgentActivityReading> { new("fixture-private-chat", "fixture-private-project", "working", "fixture-private-tool", DateTimeOffset.UtcNow) };
        if (scenario == "profiles") readings.Add(new("fixture-private-chat-2", "fixture-private-project-2", "completed", "", DateTimeOffset.UtcNow.AddSeconds(-1)));
        publisher.UpdateLocalActivity(readings);
        await publisher.StartAsync(timeout.Token);
        await WaitUntilAsync(() => registrations.Active.Count == 1);
        var ad = registrations.Active.Values.Single();
        Equal(TrustedSignals.ServiceType, ad.ServiceType); Equal(incoming ? identity : alias, Encoding.UTF8.GetString(ad.TxtRecords["hostId"]));
        var credential = new PeelPskCredential(pairing, key);
        await using var stream = await transport.ConnectAsync(new("127.0.0.1", publisher.Port), credential, timeout.Token);
        CryptographicOperations.ZeroMemory(credential.PreSharedKey);
        var hello = new SignalHelloMessage(scenario == "wrong-pairing" ? Guid.NewGuid().ToString() : pairing,
            scenario == "wrong-publisher" ? Guid.NewGuid().ToString() : incoming ? identity : alias,
            scenario == "wrong-subscriber" ? Guid.NewGuid().ToString() : subscriber, Guid.NewGuid().ToString(), TrustedSignals.NewNonce());
        if (scenario is "unknown-type" or "malformed" or "oversized" or "partial-hello")
        {
            byte[] bytes = Encoding.UTF8.GetBytes(scenario switch
            { "unknown-type" => "{\"type\":\"unknown\"}\n", "malformed" => "{bad json}\n", "oversized" => new string('a', 4097), _ => "{\"type\":" });
            await stream.WriteAsync(bytes, timeout.Token); await stream.FlushAsync(timeout.Token);
            if (scenario == "partial-hello") await publisher.StopAsync();
            await ExpectSignalClosedAsync(stream, timeout.Token);
        }
        else
        {
            byte[] bytes = PeelJson.SerializeLine(hello);
            await stream.WriteAsync(bytes.AsMemory(0, 9), timeout.Token); await stream.WriteAsync(bytes.AsMemory(9), timeout.Token); await stream.FlushAsync(timeout.Token);
            if (scenario.StartsWith("wrong-", StringComparison.Ordinal)) await ExpectSignalClosedAsync(stream, timeout.Token);
            else
            {
                var challenge = TrustedSignals.ReadChallenge(await LocalAgentProtocol.ReadLineAsync(stream, timeout.Token) ?? throw new EndOfStreamException());
                True(TrustedSignals.Verify(true, challenge.Proof, hello, challenge.ServerNonce, challenge.PublisherNodeId, key), "Publisher proof must authenticate every hello field.");
                if (scenario == "partial-proof")
                {
                    await stream.WriteAsync("{\"type\":\"peelSignalProof\""u8.ToArray(), timeout.Token); await stream.FlushAsync(timeout.Token);
                    await publisher.StopAsync(); await ExpectSignalClosedAsync(stream, timeout.Token);
                }
                else
                {
                    // The server must not leak a frame while still waiting for subscriber proof.
                    var pendingFrame = LocalAgentProtocol.ReadLineAsync(stream, timeout.Token);
                    await Task.Delay(80, timeout.Token); True(!pendingFrame.IsCompleted, "No activity may leave before both role proofs complete.");
                    if (scenario == "revoked-before-proof") hosts.Forget(subscriber);
                    string proof = scenario == "bad-proof" ? Convert.ToBase64String(new byte[32]) : scenario == "reflected-proof" ? challenge.Proof :
                        Convert.ToBase64String(TrustedSignals.Proof(false, hello, challenge.ServerNonce, challenge.PublisherNodeId, key));
                    await stream.WriteAsync(PeelJson.SerializeLine(new SignalProofMessage(proof)), timeout.Token); await stream.FlushAsync(timeout.Token);
                    if (scenario is "bad-proof" or "reflected-proof" or "revoked-before-proof")
                    {
                        try { True(await pendingFrame is null, "Unauthorized subscribers receive no frame."); } catch (IOException) { }
                    }
                    else
                    {
                        byte[] frameBytes = await pendingFrame ?? throw new EndOfStreamException();
                        var frame = TrustedSignals.ReadFrame(frameBytes);
                        Equal("working", frame.AggregateState); True(frame.HasVisibleActivity, "Actual observed activity is shared.");
                        Equal(challenge.PublisherNodeId, frame.SourceNodeId);
                        var expectedScene = new LocalLightScenes().Compile(lights.Settings, AgentLighting.Visible(readings, DateTimeOffset.UtcNow), DateTimeOffset.UtcNow);
                        Equal(expectedScene.Programs.Pro, frame.ProProgram); Equal(expectedScene.Programs.Dot, frame.DotProgram);
                        string decoded = Encoding.UTF8.GetString(TrustedSignals.Base64(PeelJson.Deserialize<SignalFrameMessage>(frameBytes).Payload, null, 8192));
                        True(!decoded.Contains("fixture-private", StringComparison.Ordinal), "Frames contain aggregate state only, never project/chat/tool labels.");
                        if (scenario == "revoked-after-proof") hosts.Forget(subscriber);
                        else if (scenario == "key-change") vault.Write(WindowsPairedClientStore.CredentialTarget("Peel.Parity.Fixture", pairing), RandomNumberGenerator.GetBytes(32));
                        else if (scenario == "extra-input") { await stream.WriteAsync("{bad}\n"u8.ToArray(), timeout.Token); await stream.FlushAsync(timeout.Token); }
                        else
                        {
                            if (scenario == "profiles")
                            {
                                lights.Settings.Profiles.Select(LightingProfile.Factory.Id); publisher.UpdateLocalActivity(readings);
                                var changed = TrustedSignals.ReadFrame(await LocalAgentProtocol.ReadLineAsync(stream, timeout.Token) ?? throw new EndOfStreamException());
                                True(changed.ProProgram != frame.ProProgram && changed.DotProgram != frame.DotProgram, "Profile changes must reach the authenticated receiver on both outputs.");
                                True(changed.Sequence > frame.Sequence, "Profile update preserves ordered frame publication.");
                            }
                            publisher.UpdateLocalActivity([]);
                            var idle = TrustedSignals.ReadFrame(await LocalAgentProtocol.ReadLineAsync(stream, timeout.Token) ?? throw new EndOfStreamException());
                            Equal("idle", idle.AggregateState); True(!idle.HasVisibleActivity && idle.Sequence >= frame.Sequence, "Cleared activity publishes idle with monotonic sequence.");
                            await publisher.StopAsync();
                        }
                        await ExpectSignalClosedAsync(stream, timeout.Token);
                    }
                }
            }
        }
        await publisher.StopAsync(); Equal(0, registrations.Active.Count); Equal(0, publisher.ReceiverCount);
        True(!publisher.Enabled, "Stopped publisher must release its listener and consent.");
        CryptographicOperations.ZeroMemory(key);
        Console.WriteLine("PASS signal publisher TLS " + scenario);
    }
    private sealed class SignalTestRegistrar : IPeelServiceRegistrar
    {
        internal ConcurrentDictionary<string, PeelServiceAdvertisement> Active { get; } = new();
        public ValueTask<IAsyncDisposable> RegisterAsync(PeelServiceAdvertisement advertisement, CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested(); True(Active.TryAdd(advertisement.DisplayName, advertisement), "Signal names must be unique.");
            return ValueTask.FromResult<IAsyncDisposable>(new SignalRegistration(() => Active.TryRemove(advertisement.DisplayName, out _)));
        }
    }
    private sealed class SignalRegistration(Action dispose) : IAsyncDisposable
    { public ValueTask DisposeAsync() { dispose(); return ValueTask.CompletedTask; } }
}
