using System.Diagnostics;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Peel.Windows.Discovery;
using Peel.Windows.Host.Security;
using Peel.Windows.Protocol;
using Peel.Windows.Transport;

namespace Peel.Windows.Client.Services;

public sealed record ReceivedDeviceSignal(string HostId, string DisplayName, NearbySignalFrame Frame, long ReceivedTimestamp)
{
    public bool IsFresh => Stopwatch.GetElapsedTime(ReceivedTimestamp) <= TimeSpan.FromSeconds(3.5);
    public string StateLabel => Frame.StateLabel;
    public string ActivityLabel => Frame.HasVisibleActivity ? "Active signal" : "No visible activity";
}

/// <summary>Opt-in, generation-owned receiver for the Mac's paired SidePulse service.</summary>
public sealed class TrustedSignalReceiver : IAsyncDisposable
{
    private readonly WindowsPairedHostStore credentials;
    private readonly IPeelServiceBrowser browser;
    private readonly IPeelPskTransportFactory transport;
    private readonly SemaphoreSlim lifecycle = new(1, 1);
    private readonly object gate = new();
    private readonly string nodeId = Guid.NewGuid().ToString("D");
    private Generation? current;
    private bool disposed;
    private long consentEpoch;
    private string status = "Paired signals are off.";
    private sealed class Generation
    {
        internal readonly CancellationTokenSource Cancel = new();
        internal readonly Dictionary<string, PeelDiscoveredService> Endpoints = new(StringComparer.Ordinal);
        internal readonly Dictionary<string, ReceivedDeviceSignal> Signals = new(StringComparer.Ordinal);
        internal Task Worker = Task.CompletedTask;
    }
    private sealed class PeerJob(HostPairedClient peer, PeelDiscoveredService endpoint, CancellationToken token) : IDisposable
    {
        internal HostPairedClient Peer { get; } = peer;
        internal PeelDiscoveredService Endpoint { get; } = endpoint;
        internal CancellationTokenSource Cancel { get; } = CancellationTokenSource.CreateLinkedTokenSource(token);
        internal Task Worker = Task.CompletedTask;
        public void Dispose() => Cancel.Dispose();
    }
    public TrustedSignalReceiver(WindowsPairedHostStore credentials, IPeelServiceBrowser? browser = null, IPeelPskTransportFactory? transport = null)
    { this.credentials = credentials; this.browser = browser ?? new WindowsDnsSdBrowser(); this.transport = PeelSecureTransport.Require(transport ?? new BouncyCastlePskTransportFactory()); }
    public bool Enabled { get { lock (gate) return current is { Cancel.IsCancellationRequested: false }; } }
    public string Status { get { lock (gate) return status; } }
    public IReadOnlyList<ReceivedDeviceSignal> Snapshot()
    {
        lock (gate) return current is not { Cancel.IsCancellationRequested: false } generation ? [] :
            generation.Signals.Values.Where(v => v.IsFresh).OrderBy(v => v.Frame.Priority).ThenBy(v => v.HostId, StringComparer.Ordinal).ToArray();
    }
    public async Task StartAsync(CancellationToken token)
    {
        long startingEpoch; lock (gate) startingEpoch = consentEpoch;
        await lifecycle.WaitAsync(token).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            await StopCoreAsync().ConfigureAwait(false); token.ThrowIfCancellationRequested();
            var generation = new Generation();
            lock (gate)
            {
                if (startingEpoch != consentEpoch) { generation.Cancel.Dispose(); throw new OperationCanceledException("Following device signals was cancelled."); }
                current = generation; status = "Looking for paired device signals…";
            }
            generation.Worker = Task.Run(() => RunAsync(generation));
        }
        finally { lifecycle.Release(); }
    }
    public void Cancel()
    {
        lock (gate)
        {
            consentEpoch++;
            current?.Cancel.Cancel(); current?.Signals.Clear(); status = "Paired signals are off.";
        }
    }
    public async Task StopAsync()
    {
        Cancel(); await lifecycle.WaitAsync().ConfigureAwait(false);
        try { await StopCoreAsync().ConfigureAwait(false); }
        finally { lifecycle.Release(); }
    }
    private async Task StopCoreAsync()
    {
        Generation? previous;
        lock (gate) { previous = current; current = null; previous?.Cancel.Cancel(); status = "Paired signals are off."; }
        if (previous is null) return;
        try { await previous.Worker.ConfigureAwait(false); }
        finally { previous.Cancel.Dispose(); }
    }
    private async Task RunAsync(Generation generation)
    {
        CancellationToken token = generation.Cancel.Token;
        var jobs = new Dictionary<string, PeerJob>(StringComparer.Ordinal);
        var retryAfter = new Dictionary<string, long>(StringComparer.Ordinal);
        Task browsing = BrowseAsync(generation);
        try
        {
            using var timer = new PeriodicTimer(TimeSpan.FromSeconds(1));
            do
            {
                var paired = credentials.Snapshot().Take(128).ToArray();
                PeelDiscoveredService[] endpoints;
                lock (gate) endpoints = generation.Endpoints.Values.ToArray();
                foreach (var entry in jobs.ToArray())
                {
                    var job = entry.Value;
                    bool trusted = paired.Any(p => SameIdentity(p, job.Peer));
                    bool located = endpoints.Any(e => SameEndpoint(e, job.Endpoint));
                    if (!trusted || !located) job.Cancel.Cancel();
                    if (!job.Worker.IsCompleted) continue;
                    await job.Worker.ConfigureAwait(false); job.Dispose(); jobs.Remove(entry.Key);
                    retryAfter[entry.Key] = Stopwatch.GetTimestamp();
                }
                foreach (var peer in paired)
                {
                    if (jobs.Count >= 16) break;
                    if (!Guid.TryParseExact(peer.LocalDeviceId, "D", out _) || !Guid.TryParseExact(peer.DeviceId, "D", out var remote) || !Guid.TryParseExact(peer.PairingId, "D", out _) || jobs.ContainsKey(peer.PairingId)) continue;
                    if (retryAfter.TryGetValue(peer.PairingId, out long last) && Stopwatch.GetElapsedTime(last) < TimeSpan.FromSeconds(3)) continue;
                    var endpoint = endpoints.FirstOrDefault(e => Guid.TryParseExact(e.HostId, "D", out var id) && id == remote);
                    if (endpoint is null) continue;
                    var job = new PeerJob(peer, endpoint, token); jobs.Add(peer.PairingId, job);
                    job.Worker = ReceiveAsync(generation, job);
                }
                // Retry bookkeeping follows current trust; it cannot grow with revoked pairings.
                foreach (string id in retryAfter.Keys.Where(id => !paired.Any(p => p.PairingId == id)).ToArray()) retryAfter.Remove(id);
                lock (gate)
                {
                    foreach (string host in generation.Signals.Keys.Where(host => !paired.Any(p => p.DeviceId == host)).ToArray()) generation.Signals.Remove(host);
                    if (current == generation && !token.IsCancellationRequested)
                    {
                        int ready = generation.Signals.Values.Count(s => s.IsFresh);
                        int legacy = paired.Count(p => p.LocalDeviceId is null);
                        status = ready > 0 ? $"{ready} authenticated device signal(s)." : paired.Length == 0 ? "Pair a computer in Peel Pro to follow its activity." :
                            legacy == paired.Length ? "Renew pairing to enable signals: older Windows pairings did not retain this PC's device identity." : "Waiting for paired devices with SidePulse sharing enabled.";
                    }
                }
                if (browsing.IsCompleted) await browsing.ConfigureAwait(false);
            } while (await timer.WaitForNextTickAsync(token).ConfigureAwait(false));
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (Exception e) when (e is IOException or InvalidOperationException or System.ComponentModel.Win32Exception or PlatformNotSupportedException)
        { lock (gate) if (current == generation && !token.IsCancellationRequested) status = "Paired signal discovery is unavailable. Stop and try again."; }
        finally
        {
            generation.Cancel.Cancel();
            foreach (var job in jobs.Values) job.Cancel.Cancel();
            foreach (var job in jobs.Values) { await job.Worker.ConfigureAwait(false); job.Dispose(); }
            try { await browsing.ConfigureAwait(false); } catch (OperationCanceledException) { } catch (Exception e) when (e is IOException or InvalidOperationException or System.ComponentModel.Win32Exception or PlatformNotSupportedException) { }
            lock (gate) generation.Signals.Clear();
        }
    }
    private async Task BrowseAsync(Generation generation)
    {
        await foreach (var endpoint in browser.BrowseAsync(TrustedSignals.ServiceType, generation.Cancel.Token).ConfigureAwait(false))
        {
            lock (gate)
            {
                if (current != generation || generation.Cancel.IsCancellationRequested) return;
                string key = endpoint.InstanceName + "|" + endpoint.InterfaceIndex;
                if (endpoint.ChangeKind == PeelServiceChangeKind.Removed) { generation.Endpoints.Remove(key); continue; }
                if (!ClientHostDiscovery.ValidService(endpoint, TrustedSignals.ServiceType) || endpoint.GetUtf8Txt("version") != "1" ||
                    !credentials.Snapshot().Any(p => Guid.TryParse(p.DeviceId, out var id) && Guid.TryParse(endpoint.HostId, out var found) && id == found)) continue;
                if (generation.Endpoints.Count < 128 || generation.Endpoints.ContainsKey(key)) generation.Endpoints[key] = endpoint;
            }
        }
    }
    private static bool SameIdentity(HostPairedClient a, HostPairedClient b) => a.PairingId == b.PairingId && a.DeviceId == b.DeviceId && a.LocalDeviceId == b.LocalDeviceId;
    private static bool SameEndpoint(PeelDiscoveredService a, PeelDiscoveredService b) => a.InstanceName == b.InstanceName && a.InterfaceIndex == b.InterfaceIndex && a.HostName == b.HostName && a.Port == b.Port && a.HostId == b.HostId;
    private async Task RequireTrustedAsync(HostPairedClient peer, byte[] key, CancellationToken token)
    {
        if (!credentials.Snapshot().Any(p => SameIdentity(p, peer))) throw new InvalidDataException("The signal pairing changed.");
        var credential = await credentials.GetForHostAsync(peer.DeviceId, token).ConfigureAwait(false);
        byte[]? currentKey = credential?.CopyPreSharedKey();
        try
        {
            if (credential?.PairingId != peer.PairingId || currentKey is null || !CryptographicOperations.FixedTimeEquals(key, currentKey))
                throw new InvalidDataException("The signal pairing is no longer trusted.");
        }
        finally { if (currentKey is not null) CryptographicOperations.ZeroMemory(currentKey); }
    }
    private async Task ReceiveAsync(Generation generation, PeerJob job)
    {
        byte[]? key = null; PeelPskCredential? tls = null;
        CancellationToken token = job.Cancel.Token;
        try
        {
            var credential = await credentials.GetForHostAsync(job.Peer.DeviceId, token).ConfigureAwait(false) ?? throw new InvalidDataException("Pairing unavailable.");
            key = credential.CopyPreSharedKey(); await RequireTrustedAsync(job.Peer, key, token).ConfigureAwait(false);
            tls = new(job.Peer.PairingId, key);
            using var handshake = CancellationTokenSource.CreateLinkedTokenSource(token); handshake.CancelAfter(TimeSpan.FromSeconds(10));
            await using var stream = await transport.ConnectAsync(new DnsEndPoint(job.Endpoint.HostName!, job.Endpoint.Port!.Value), tls, handshake.Token).ConfigureAwait(false);
            using var abort = token.Register(static value => ((Stream)value!).Dispose(), stream);
            var hello = new SignalHelloMessage(job.Peer.PairingId, job.Peer.DeviceId, job.Peer.LocalDeviceId!, nodeId, TrustedSignals.NewNonce());
            await stream.WriteAsync(PeelJson.SerializeLine(hello), handshake.Token).ConfigureAwait(false);
            await stream.FlushAsync(handshake.Token).ConfigureAwait(false);
            var lines = new SignalLines(stream);
            var challenge = TrustedSignals.ReadChallenge(await lines.ReadAsync(handshake.Token).ConfigureAwait(false));
            await RequireTrustedAsync(job.Peer, key, token).ConfigureAwait(false);
            if (!TrustedSignals.Verify(true, challenge.Proof, hello, challenge.ServerNonce, challenge.PublisherNodeId, key)) throw new InvalidDataException("Signal publisher proof failed.");
            var proof = new SignalProofMessage(Convert.ToBase64String(TrustedSignals.Proof(false, hello, challenge.ServerNonce, challenge.PublisherNodeId, key)));
            await stream.WriteAsync(PeelJson.SerializeLine(proof), handshake.Token).ConfigureAwait(false);
            await stream.FlushAsync(handshake.Token).ConfigureAwait(false);
            ulong? sequence = null; long burst = Stopwatch.GetTimestamp(); int burstCount = 0;
            while (true)
            {
                using var idle = CancellationTokenSource.CreateLinkedTokenSource(token); idle.CancelAfter(TimeSpan.FromSeconds(15));
                var frame = TrustedSignals.ReadFrame(await lines.ReadAsync(idle.Token).ConfigureAwait(false));
                await RequireTrustedAsync(job.Peer, key, token).ConfigureAwait(false);
                if (TrustedSignals.Uuid(frame.SourceNodeId) != TrustedSignals.Uuid(challenge.PublisherNodeId) || sequence is { } previous && frame.Sequence < previous)
                    throw new InvalidDataException("Signal source or sequence changed.");
                if (Stopwatch.GetElapsedTime(burst) > TimeSpan.FromSeconds(1)) { burst = Stopwatch.GetTimestamp(); burstCount = 0; }
                if (++burstCount > 8) throw new InvalidDataException("Signal rate exceeded.");
                sequence = frame.Sequence;
                lock (gate) if (current == generation && !token.IsCancellationRequested)
                    generation.Signals[job.Peer.DeviceId] = new(job.Peer.DeviceId, job.Peer.DisplayName, frame, Stopwatch.GetTimestamp());
            }
        }
        catch (Exception e) when (e is IOException or InvalidDataException or JsonException or OperationCanceledException or InvalidOperationException or System.Net.Sockets.SocketException or ArgumentException or System.ComponentModel.Win32Exception) { }
        finally
        {
            if (key is not null) CryptographicOperations.ZeroMemory(key);
            if (tls is not null) CryptographicOperations.ZeroMemory(tls.PreSharedKey);
            lock (gate) generation.Signals.Remove(job.Peer.DeviceId);
        }
    }
    private sealed class SignalLines(Stream stream)
    {
        private readonly NdjsonReader reader = new(TrustedSignals.MaximumFrameBytes);
        private readonly Queue<string> pending = new();
        private readonly byte[] buffer = new byte[4096];
        internal async Task<byte[]> ReadAsync(CancellationToken token)
        {
            while (pending.Count == 0)
            {
                int count = await stream.ReadAsync(buffer, token).ConfigureAwait(false);
                if (count == 0) throw new IOException("Signal stream closed.");
                foreach (string line in reader.Append(buffer.AsSpan(0, count)))
                { if (pending.Count >= 4) throw new InvalidDataException("Too many signal messages."); pending.Enqueue(line); }
            }
            return Encoding.UTF8.GetBytes(pending.Dequeue());
        }
    }
    public async ValueTask DisposeAsync()
    {
        Cancel();
        await lifecycle.WaitAsync().ConfigureAwait(false);
        try { disposed = true; await StopCoreAsync().ConfigureAwait(false); }
        finally { lifecycle.Release(); }
    }
}
