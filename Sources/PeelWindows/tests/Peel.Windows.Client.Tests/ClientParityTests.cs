using System.Collections.Concurrent;
using System.Net;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Channels;
using Peel.Windows.Client.Models;
using Peel.Windows.Client.Services;
using Peel.Windows.Discovery;
using Peel.Windows.Host.Security;
using Peel.Windows.Protocol;

namespace Peel.Windows.Client.Tests;

internal static partial class Program
{
    private static async Task ImmediateWindowListAsync()
    {
        ScriptedDuplexStream? stream = null;
        using var accepted = new ManualResetEventSlim();
        stream = new(onWrite: bytes =>
        {
            if (ReadType(bytes) != PeelMessageType.RequestWindowList) return;
            stream!.EnqueueRead(PeelJson.SerializeLine(new WindowListMessage([new PeelWindow(7, "Fixture", "Immediate", 640, 480)])));
            True(accepted.Wait(TimeSpan.FromSeconds(1)), "Window list must be admitted before request WriteAsync returns.");
        });
        var host = Candidate("host-immediate", "fixture.local", 9001);
        var fixture = new Fixture(host, stream);
        await using var session = fixture.CreateSession();
        await ConnectAsync(session, stream, host);
        session.WindowsChanged += (_, _) => { if (session.Windows.Count == 1) accepted.Set(); };
        await ((IWindowListService)session).StartAsync(CancellationToken.None);
        Equal(7u, session.Windows.Single().Id);
    }

    private const string ParityHostId = "43929CEC-BDAD-489E-845C-E2B0B7BDC797";

    private static PeelDiscoveredService ParityService(string type, ushort port = 9002,
        PeelServiceChangeKind change = PeelServiceChangeKind.Added, uint interfaceIndex = 1) =>
        new(change, "Parity." + type, "Parity fixture", type, "127.0.0.1", port,
            new Dictionary<string, byte[]>
            {
                ["hostId"] = Encoding.UTF8.GetBytes(ParityHostId),
                ["pairMode"] = "pin"u8.ToArray(), ["tlsPSKOrder"] = "psk-identity"u8.ToArray(),
                ["pinSalt"] = Encoding.UTF8.GetBytes(Convert.ToBase64String(RandomNumberGenerator.GetBytes(16))),
            }, interfaceIndex);

    private static (WindowsPairedHostStore Store, ParityVault Vault) ParityStore()
    {
        var vault = new ParityVault();
        return (new WindowsPairedHostStore(new WindowsPairedClientStore(vault, new ParityMetadata(), "Peel.Parity.Fixture")), vault);
    }

    private static async Task ClientPinPairingPersistsAsync()
    {
        var (store, vault) = ParityStore();
        using (vault)
        {
            var service = ParityService(PeelServiceType.Pairing);
            byte[] key = RandomNumberGenerator.GetBytes(32);
            string pairingId = Guid.NewGuid().ToString();
            var stream = new ScriptedDuplexStream();
            var transport = new FakeTransportFactory(streams: [stream]);
            var pairing = new ClientPinPairing(transport, store);
            var pending = pairing.PairAsync(service, "123456", CancellationToken.None);
            await stream.WaitForWritesAsync(1);
            Equal(PeelPinPairing.TlsIdentity, transport.Identities.Single());
            var request = DeserializeWrite<PairRequestMessage>(stream, 0);
            byte[] pinKey = PeelPinPairing.DerivePreSharedKey("123456", Convert.FromBase64String(service.PairingSaltBase64!), ParityHostId);
            True(PeelPinPairing.VerifyProof(pinKey, ParityHostId, request.ClientDeviceId, request.PinProof), "PIN proof matches Host contract.");
            CryptographicOperations.ZeroMemory(pinKey);
            var response = PeelJson.SerializeLine(new PairResponseMessage("Fixture Mac", "Fixture", pairingId, key, true));
            stream.EnqueueRead(response[..5]); stream.EnqueueRead(response[5..]);
            await pending.WaitAsync(TimeSpan.FromSeconds(2));
            var saved = await store.GetForHostAsync(ParityHostId, CancellationToken.None);
            True(saved is not null, "Accepted pairing must resolve by exact stable Host identity.");
            Equal(pairingId, saved!.PairingId); SequenceEqual(key, saved.CopyPreSharedKey());
            Equal(request.ClientDeviceId, store.Snapshot().Single().LocalDeviceId);
            True(!store.IsPaired("wrong-host"), "A display name cannot authorize a different Host.");
            store.Forget(ParityHostId);
            Equal(0, vault.Count); Equal(0, store.Snapshot().Count);
            CryptographicOperations.ZeroMemory(key);
        }
    }

    private static async Task ClientPinPairingHostileAsync()
    {
        foreach (var payload in new[]
        {
            "{\"type\":\"unexpected\"}\n", "{bad}\n",
            "{\"type\":\"pairResponse\",\"accepted\":true,\"pairingId\":\"bad\",\"hostName\":\"Mac\",\"psk\":\"AA==\"}\n",
            new string('x', 17000) + "\n",
        })
        {
            var (store, vault) = ParityStore();
            using (vault)
            {
                var stream = new ScriptedDuplexStream(); stream.EnqueueRead(Encoding.UTF8.GetBytes(payload));
                var pairing = new ClientPinPairing(new FakeTransportFactory(streams: [stream]), store);
                bool failed = false;
                try { await pairing.PairAsync(ParityService(PeelServiceType.Pairing), "123456", CancellationToken.None); }
                catch (Exception e) when (e is System.IO.InvalidDataException or System.Text.Json.JsonException) { failed = true; }
                True(failed, "Hostile pairing must fail."); Equal(0, store.Snapshot().Count); Equal(0, vault.Count);
            }
        }
        var (cancelStore, cancelVault) = ParityStore();
        using (cancelVault)
        using (var cancellation = new CancellationTokenSource())
        {
            var stream = new ScriptedDuplexStream(); stream.EnqueueRead("{\"type\":\"pair"u8.ToArray());
            var pairing = new ClientPinPairing(new FakeTransportFactory(streams: [stream]), cancelStore);
            var task = pairing.PairAsync(ParityService(PeelServiceType.Pairing), "123456", cancellation.Token);
            await stream.WaitForWritesAsync(1); cancellation.Cancel();
            await ThrowsAsync<OperationCanceledException>(() => task);
            Equal(0, cancelVault.Count);
        }
    }

    private static async Task ClientDiscoveryPinsEndpointAsync()
    {
        var (store, vault) = ParityStore();
        using (vault)
        {
            var path = Path.Combine(Path.GetTempPath(), "peel-parity-" + Guid.NewGuid().ToString("N"), "addresses.json");
            var addresses = new SavedHostAddressStore(path);
            var browser = new ParityBrowser();
            await using var discovery = new ClientHostDiscovery(store, addresses, browser);
            await discovery.StartAsync(CancellationToken.None);
            browser.Push(ParityService(PeelServiceType.Control, 9002, interfaceIndex: 1));
            browser.Push(ParityService(PeelServiceType.Control, 9003, interfaceIndex: 2));
            await WaitUntilAsync(() => discovery.DiscoveredHosts.Count == 1);
            var nearby = discovery.DiscoveredHosts.Single(); discovery.PinEndpoint(nearby);
            var pinned = await discovery.ResolveFreshAsync(ParityHostId, CancellationToken.None);
            browser.Push(ParityService(PeelServiceType.Control, change: PeelServiceChangeKind.Removed, interfaceIndex: 1));
            await Task.Delay(30);
            Equal(1, discovery.DiscoveredHosts.Count);
            Equal(pinned, await discovery.ResolveFreshAsync(ParityHostId, CancellationToken.None));
            store.Save(ParityHostId, "Fixture", Guid.NewGuid().ToString(), RandomNumberGenerator.GetBytes(32));
            addresses.Save(new(ParityHostId, "VPN fixture", "100.64.2.3", 9010));
            var saved = discovery.SavedHosts.Single(); True(saved.IsDirect, "Saved endpoints must be explicit.");
            discovery.PinEndpoint(saved); Equal("100.64.2.3", (await discovery.ResolveFreshAsync(ParityHostId, CancellationToken.None))!.Address);
            True(await discovery.ResolveFreshAsync("wrong", CancellationToken.None) is null, "Never fall back to another identity.");
            addresses.Remove(ParityHostId);
            Throws<InvalidOperationException>(() => discovery.PinEndpoint(saved));
            store.Forget(ParityHostId);
            Directory.Delete(Path.GetDirectoryName(path)!, recursive: true);
        }
    }

    private static void PrivateAddressesFailClosed()
    {
        foreach (var host in new[] { "192.168.1.2", "10.1.2.3", "172.16.1.1", "100.64.0.1", "fd12::1", "fe80::1%2", "mini.local", "mini.tailnet.ts.net" })
            True(SavedHostAddressStore.IsPrivateAddress(host), "Private/VPN addresses must be accepted.");
        foreach (var host in new[] { "8.8.8.8", "172.32.0.1", "100.128.0.1", "2001:4860:4860::8888", "https://mini.local", "mini.local:123", "mini.local\n", "-bad.local", "a..local" })
            True(!SavedHostAddressStore.IsPrivateAddress(host), "Public or malformed endpoints must be rejected.");
        Throws<ArgumentException>(() => SavedHostAddressStore.Validate(new(ParityHostId, "Mac", "10.0.0.1", -1)));
        Throws<ArgumentException>(() => SavedHostAddressStore.Validate(new(ParityHostId, "Mac", "10.0.0.1", 65536)));
        var corruptPath = Path.Combine(Path.GetTempPath(), "peel-null-address-" + Guid.NewGuid().ToString("N") + ".json");
        try
        {
            File.WriteAllText(corruptPath, "[null]");
            Throws<ArgumentException>(() => new SavedHostAddressStore(corruptPath));
        }
        finally { File.Delete(corruptPath); }
    }

    private static void ViewportLetterboxing()
    {
        True(!ClientViewport.TryNormalize(10, 20, 1000, 1000, 1920, 1080, false, out _), "Black-bar clicks must not reach Host.");
        True(ClientViewport.TryNormalize(500, 500, 1000, 1000, 1920, 1080, false, out var center), "Center maps.");
        Equal(0.5, center.X); Equal(0.5, center.Y);
        True(ClientViewport.TryNormalize(-100, -100, 1000, 1000, 1920, 1080, true, out var edge), "Captured drag clamps.");
        Equal(0.0, edge.X); Equal(0.0, edge.Y);
        True(!ClientViewport.TryNormalize(double.NaN, 0, 1, 1, 1, 1, false, out _), "NaN rejected.");
        True(!ClientViewport.TryNormalize(0, 0, double.PositiveInfinity, 1, 1, 1, false, out _), "Infinite geometry rejected.");
        True(!ClientViewport.TryNormalize(0, 0, 0, 1, 1, 1, false, out _), "Zero size rejected.");
    }

    private static async Task ClientInputFocusAndReleaseAsync()
    {
        var host = Candidate("host-input", "input.local", 9030); var wire = new ScriptedDuplexStream();
        var fixture = new Fixture(host, wire); await using var session = fixture.CreateSession();
        await ConnectAndPublishWindowAsync(session, wire, host, 51, includeInputFocus: true);
        var streams = new ParityStream(51); var input = new ClientInputController(session, streams);
        NormalizedPoint.TryCreate(0.25, 0.75, out var point);
        int before = wire.Writes.Count;
        await input.SendPointerAsync(new(51, NormalizedPointerAction.Down, point, NormalizedPointerButton.Primary, 0, 0), CancellationToken.None);
        Equal(before, wire.Writes.Count);
        await ThrowsAsync<InvalidOperationException>(() => input.EnableAsync(CancellationToken.None));
        streams.PublishFrame();
        var enable = input.EnableAsync(CancellationToken.None);
        await wire.WaitForWritesAsync(before + 1); True(!input.IsEnabled, "Focus confirmation gates input.");
        wire.EnqueueRead(PeelJson.SerializeLine(new WindowFocusStateMessage(99, 99, true)));
        await Task.Delay(20); True(!enable.IsCompleted, "Unrelated focus must not enable control.");
        wire.EnqueueRead(PeelJson.SerializeLine(new WindowFocusStateMessage(51, 51, true)));
        await enable; True(input.IsEnabled, "Matching Host focus enables control.");
        await input.SendPointerAsync(new(51, NormalizedPointerAction.Down, point, NormalizedPointerButton.Primary, 0, 0), CancellationToken.None);
        await input.SendKeyAsync(new(51, 0x41, true, false, false, true, false, false), CancellationToken.None);
        input.Disable();
        await WaitUntilAsync(() => wire.Writes.Any(b => ReadType(b) == PeelMessageType.MouseUp));
        True(wire.Writes.Where(b => ReadType(b) == PeelMessageType.KeyboardHardwareKey)
            .Select(b => PeelJson.Deserialize<KeyboardHardwareKeyMessage>(TrimLine(b))).Any(k => k.Action == KeyboardCommandAction.Up), "Held keys are released.");
        int stoppedCount = wire.Writes.Count;
        await input.SendKeyAsync(new(51, 0x41, true, false, false, false, false, false), CancellationToken.None);
        Equal(stoppedCount, wire.Writes.Count); Equal(1, wire.MaximumConcurrentWrites);
    }

    private static async Task ClientInputFocusCancellationAsync()
    {
        var host = Candidate("host-focus-cancel", "focus.local", 9031); var wire = new ScriptedDuplexStream();
        var fixture = new Fixture(host, wire); await using var session = fixture.CreateSession();
        await ConnectAndPublishWindowAsync(session, wire, host, 52, includeInputFocus: true);
        var streams = new ParityStream(52); var input = new ClientInputController(session, streams); streams.PublishFrame();
        var enable = input.EnableAsync(CancellationToken.None); await wire.WaitForWritesAsync(4);
        input.Disable(); wire.EnqueueRead(PeelJson.SerializeLine(new WindowFocusStateMessage(52, 52, true)));
        await ThrowsAsync<OperationCanceledException>(() => enable);
        True(!input.IsEnabled, "A late focus response cannot restore revoked control.");
    }

    private static async Task ReusedWindowIdentityStopsAsync()
    {
        var host = Candidate("host-reuse", "reuse.local", 9040);
        var wire = new ScriptedDuplexStream(); var videoWire = new ScriptedDuplexStream();
        var fixture = new Fixture(host, wire, videoWire); await using var session = fixture.CreateSession();
        await ConnectAndPublishWindowAsync(session, wire, host, 53);
        var video = fixture.CreateVideoSession(new RecordingVideoDecoderSink(PeelVideoCodec.H264));
        await using var streams = new ClientStreamController(session, session, session, video, PeelVideoCodec.H264);
        await streams.StartAsync(session.Windows.Single(), CancellationToken.None);
        wire.EnqueueRead(PeelJson.SerializeLine(new WindowListMessage([new PeelWindow(53, "New instance", "Reused", 640, 480, AppLaunchTimeIntervalSince1970: 20)])));
        await WaitUntilAsync(() => streams.State == PeelStreamState.Stopped);
        True(streams.StreamingWindowId is null, "Reused IDs must not inherit active streaming/input.");
    }

    private static async Task ClientInputRejectionAsync()
    {
        var host = Candidate("host-rejection", "rejection.local", 9032);
        var wire = new ScriptedDuplexStream();
        var fixture = new Fixture(host, wire); await using var session = fixture.CreateSession();
        await ConnectAndPublishWindowAsync(session, wire, host, 54, includeInputFocus: true);
        var streams = new ParityStream(54); var input = new ClientInputController(session, streams); streams.PublishFrame();
        var enable = input.EnableAsync(CancellationToken.None); await wire.WaitForWritesAsync(4);
        wire.EnqueueRead(PeelJson.SerializeLine(new WindowFocusStateMessage(54, 54, true))); await enable;
        await input.SendKeyAsync(new(54, 0x41, true, false, false, false, false, false), CancellationToken.None);
        wire.EnqueueRead(PeelJson.SerializeLine(new InputRejectedMessage(54, "controlDisabled", DateTimeOffset.UtcNow)));
        await WaitUntilAsync(() => !input.IsEnabled && wire.Writes.Any(b => ReadType(b) == PeelMessageType.KeyboardHardwareKey
            && PeelJson.Deserialize<KeyboardHardwareKeyMessage>(TrimLine(b)).Action == KeyboardCommandAction.Up));
        int count = wire.Writes.Count;
        await input.SendKeyAsync(new(54, 0x42, true, false, false, false, false, false), CancellationToken.None);
        Equal(count, wire.Writes.Count);
    }

    private static async Task ClientPairingRevocationAsync()
    {
        var host = Candidate("host-revocation", "revocation.local", 9033);
        var wire = new ScriptedDuplexStream();
        var fixture = new Fixture(host, wire); await using var session = fixture.CreateSession();
        await ConnectAsync(session, wire, host);
        wire.EnqueueRead(PeelJson.SerializeLine(new PairingRevokedMessage("different-pairing")));
        // A subsequent valid catalog proves the unrelated message has been processed.
        await ((IWindowListService)session).StartAsync(CancellationToken.None);
        wire.EnqueueRead(PeelJson.SerializeLine(new WindowListMessage([new PeelWindow(55, "Fixture", "Still connected", 640, 480)])));
        await WaitUntilAsync(() => session.Windows.Count == 1);
        Equal(PeelConnectionState.Connected, session.State);
        wire.EnqueueRead(PeelJson.SerializeLine(new PairingRevokedMessage(Fixture.PairingId)));
        await WaitUntilAsync(() => session.State == PeelConnectionState.Error);
        True(session.ConnectedHost is null, "Matching revocation must close the authenticated session.");
    }

    private sealed class ParityVault : ICurrentUserCredentialVault, IDisposable
    {
        private readonly Dictionary<string, byte[]> values = [];
        public int Count => values.Count;
        public void Write(string name, ReadOnlySpan<byte> key) => values[name] = key.ToArray();
        public bool TryRead(string name, out byte[]? key) { bool found = values.TryGetValue(name, out var value); key = value?.ToArray(); return found; }
        public bool Delete(string name) { if (!values.Remove(name, out var key)) return false; CryptographicOperations.ZeroMemory(key); return true; }
        public void Dispose() { foreach (var name in values.Keys.ToArray()) Delete(name); }
    }
    private sealed class ParityMetadata : IHostPairedClientMetadataRepository
    {
        private HostPairedClient[] values = [];
        public IReadOnlyList<HostPairedClient> Load() => values;
        public void Save(IReadOnlyList<HostPairedClient> peers) => values = peers.ToArray();
    }
    private sealed class ParityBrowser : IPeelServiceBrowser
    {
        private readonly ConcurrentDictionary<string, Channel<PeelDiscoveredService>> channels = new();
        public void Push(PeelDiscoveredService service) => channels.GetOrAdd(service.ServiceType, _ => Channel.CreateUnbounded<PeelDiscoveredService>()).Writer.TryWrite(service);
        public async IAsyncEnumerable<PeelDiscoveredService> BrowseAsync(string type, [EnumeratorCancellation] CancellationToken token)
        { await foreach (var item in channels.GetOrAdd(type, _ => Channel.CreateUnbounded<PeelDiscoveredService>()).Reader.ReadAllAsync(token)) yield return item; }
    }
    private sealed class ParityStream(uint id) : IStreamControlService
    {
        public event EventHandler<StreamStateChangedEventArgs>? StateChanged { add { } remove { } }
        public event EventHandler<DecodedVideoFrameEventArgs>? FrameAvailable;
        public PeelStreamState State => PeelStreamState.Streaming;
        public uint? StreamingWindowId => id;
        public Task StartAsync(RemoteWindowDescriptor window, CancellationToken token) => Task.CompletedTask;
        public Task StopAsync(CancellationToken token) => Task.CompletedTask;
        public void PublishFrame() => FrameAvailable?.Invoke(this, new(new(2, 2, 8, new byte[16], 1)));
    }
}
