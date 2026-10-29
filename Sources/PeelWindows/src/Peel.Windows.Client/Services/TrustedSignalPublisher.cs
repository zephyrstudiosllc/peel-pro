using System.Diagnostics;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Peel.Windows.Client.Utilities;
using Peel.Windows.Discovery;
using Peel.Windows.Host.Runtime;
using Peel.Windows.Host.Security;
using Peel.Windows.Protocol;
using Peel.Windows.Transport;

namespace Peel.Windows.Client.Services;

/// <summary>Explicit, session-only sharing of aggregate observed agent state with existing paired peers.</summary>
public sealed class TrustedSignalPublisher : IAsyncDisposable
{
    private readonly WindowsPairedHostStore hosts;
    private readonly Func<WindowsPairedClientStore> clients;
    private readonly Func<string> identity;
    private readonly IPeelServiceRegistrar registrar;
    private readonly IPeelPskTransportFactory transport;
    private readonly IPAddress listenAddress;
    private readonly string nodeId = Guid.NewGuid().ToString("D");
    private readonly object gate = new();
    private readonly SignalSettings signalSettings;
    private readonly LocalLightScenes localScenes = new();
    private readonly SemaphoreSlim lifecycle = new(1, 1);
    private Generation? current;
    private NearbySignalFrame? frame;
    private long sampledAt;
    private ulong sequence;
    private bool disposed;
    private long consentEpoch;
    private string status = "Local activity sharing is off.";
    private sealed class Generation(SignalPublisherTrust trust)
    {
        internal readonly SignalPublisherTrust Trust = trust;
        internal readonly CancellationTokenSource Cancel = new();
        internal Task Worker = Task.CompletedTask;
        internal int Receivers;
        internal int Port;
    }
    internal TrustedSignalPublisher(WindowsPairedHostStore hosts, Func<WindowsPairedClientStore>? clients = null,
        Func<string>? identity = null, IPeelServiceRegistrar? registrar = null, IPeelPskTransportFactory? transport = null, IPAddress? listenAddress = null,
        SignalSettings? signalSettings = null)
    {
        this.hosts = hosts; this.clients = clients ?? (() => new WindowsPairedClientStore());
        this.identity = identity ?? (() => new WindowsHostIdentityStore().LoadOrCreate());
        this.registrar = registrar ?? new WindowsDnsSdRegistrar();
        this.transport = PeelSecureTransport.Require(transport ?? new BouncyCastlePskTransportFactory());
        this.listenAddress = listenAddress ?? IPAddress.IPv6Any;
        this.signalSettings = signalSettings ?? SignalSettings.Shared;
    }
    public bool Enabled { get { lock (gate) return current is { Cancel.IsCancellationRequested: false }; } }
    public string Status { get { lock (gate) return status; } }
    internal int Port { get { lock (gate) return current?.Port ?? 0; } }
    internal int ReceiverCount { get { lock (gate) return current is { } generation ? Volatile.Read(ref generation.Receivers) : 0; } }
    public void UpdateLocalActivity(IReadOnlyList<AgentActivityReading> readings)
    {
        DateTimeOffset now = DateTimeOffset.UtcNow;
        lock (gate)
        {
            var scene = localScenes.Compile(signalSettings, AgentLighting.Visible(readings, now), now);
            string state = scene.State; var programs = scene.Programs;
            DateTimeOffset started = frame?.AggregateState == state && frame.ProProgram == programs.Pro && frame.DotProgram == programs.Dot ? frame.ProgramStartedAt : now;
            frame = new(1, nodeId, ++sequence, now, now, started, state, state != "idle", programs.Pro, programs.Dot);
            sampledAt = Stopwatch.GetTimestamp();
        }
    }
    internal static string ProgramFor(string state) => state switch
    {
        "working" => "brightness 106\n#000000\n#FF2BD6 517ms cosine\n#000000 517ms cosine\nrepeat",
        "toolRunning" => "brightness 106\n#000000\n#0018FF 517ms cosine\n#000000 517ms cosine\nrepeat",
        "waiting" => "brightness 224\n#FFD60A 368ms none\n#000000 369ms none\nrepeat",
        "error" => "brightness 242\n#FF0000",
        "completed" => "brightness 217\n#00D300",
        _ => "off",
    };
    private NearbySignalFrame LatestFrame()
    {
        lock (gate)
        {
            DateTimeOffset now = DateTimeOffset.UtcNow;
            if (frame is null || Stopwatch.GetElapsedTime(sampledAt) > TimeSpan.FromSeconds(10) && frame.HasVisibleActivity)
                frame = new(1, nodeId, ++sequence, now, now, now, "idle", false, "off", "off");
            return frame with { SentAt = now };
        }
    }
    public async Task StartAsync(CancellationToken token)
    {
        long startingEpoch; lock (gate) startingEpoch = consentEpoch;
        await lifecycle.WaitAsync(token).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            await StopCoreAsync().ConfigureAwait(false); token.ThrowIfCancellationRequested();
            var trust = new SignalPublisherTrust(hosts, clients, identity());
            if (trust.Snapshot().Count == 0)
            {
                const string unavailable = "Pair a device first. Older outgoing pairings must be renewed to retain this PC's identity.";
                lock (gate) status = unavailable;
                throw new InvalidOperationException(unavailable);
            }
            var generation = new Generation(trust);
            lock (gate)
            {
                if (startingEpoch != consentEpoch) { generation.Cancel.Dispose(); throw new OperationCanceledException("Local activity sharing was cancelled."); }
                current = generation; status = "Starting local activity sharing…";
            }
            generation.Worker = Task.Run(() => RunAsync(generation));
        }
        finally { lifecycle.Release(); }
    }
    public void Cancel()
    {
        lock (gate) { consentEpoch++; current?.Cancel.Cancel(); status = "Local activity sharing is off."; }
    }
    public async Task StopAsync()
    {
        Cancel(); await lifecycle.WaitAsync().ConfigureAwait(false);
        try { await StopCoreAsync().ConfigureAwait(false); }
        finally { lifecycle.Release(); }
    }
    private async Task StopCoreAsync()
    {
        Generation? old;
        lock (gate) { old = current; current = null; old?.Cancel.Cancel(); status = "Local activity sharing is off."; }
        if (old is null) return;
        try { await old.Worker.ConfigureAwait(false); }
        finally { old.Cancel.Dispose(); }
    }
    private async Task RunAsync(Generation generation)
    {
        CancellationToken token = generation.Cancel.Token;
        var registrations = new Dictionary<string, IAsyncDisposable>(StringComparer.OrdinalIgnoreCase);
        Task[] workers = [];
        try
        {
            await using var listener = await transport.ListenAsync(new IPEndPoint(listenAddress, 0), generation.Trust, token).ConfigureAwait(false);
            ushort port = checked((ushort)((IPEndPoint)listener.LocalEndPoint).Port);
            lock (gate) generation.Port = port;
            workers = Enumerable.Range(0, 8).Select(_ => AcceptLoopAsync(generation, listener)).ToArray();
            using var tick = new PeriodicTimer(TimeSpan.FromSeconds(1));
            do
            {
                var ids = generation.Trust.Snapshot().Select(p => p.PublisherId).Distinct(StringComparer.OrdinalIgnoreCase).ToHashSet(StringComparer.OrdinalIgnoreCase);
                foreach (string old in registrations.Keys.Where(id => !ids.Contains(id)).ToArray())
                { await registrations[old].DisposeAsync().ConfigureAwait(false); registrations.Remove(old); }
                foreach (string id in ids.Where(id => !registrations.ContainsKey(id)))
                {
                    // Separate names preserve the identity that each initiating Windows pairing actually sent.
                    string name = "Peel Signals · " + id;
                    registrations[id] = await registrar.RegisterAsync(new(name, TrustedSignals.ServiceType, port,
                        new Dictionary<string, byte[]> { ["hostId"] = Encoding.UTF8.GetBytes(id), ["version"] = "1"u8.ToArray() }), token).ConfigureAwait(false);
                }
                lock (gate) if (current == generation && !token.IsCancellationRequested)
                    status = ids.Count == 0 ? "Sharing has no eligible paired devices." : $"Sharing local activity · {Volatile.Read(ref generation.Receivers)} authenticated receiver(s).";
                if (workers.FirstOrDefault(w => w.IsFaulted) is { } failed) await failed.ConfigureAwait(false);
            } while (await tick.WaitForNextTickAsync(token).ConfigureAwait(false));
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (Exception e) when (e is IOException or InvalidDataException or InvalidOperationException or ArgumentException or System.Net.Sockets.SocketException or System.ComponentModel.Win32Exception or PlatformNotSupportedException)
        { lock (gate) if (current == generation && !token.IsCancellationRequested) status = "Local activity sharing is unavailable. Stop and try again."; }
        finally
        {
            generation.Cancel.Cancel();
            foreach (var registration in registrations.Values)
            {
                try { await registration.DisposeAsync().ConfigureAwait(false); }
                catch (Exception e) when (e is IOException or InvalidOperationException or System.ComponentModel.Win32Exception) { }
            }
            await Task.WhenAll(workers).ConfigureAwait(false);
        }
    }
    private async Task AcceptLoopAsync(Generation generation, IPeelPskListener listener)
    {
        CancellationToken token = generation.Cancel.Token;
        while (!token.IsCancellationRequested)
        {
            try
            {
                using var limit = CancellationTokenSource.CreateLinkedTokenSource(token); limit.CancelAfter(TimeSpan.FromSeconds(10));
                await using var connection = await listener.AcceptAsync(limit.Token).ConfigureAwait(false);
                await ServeAsync(generation, connection, token).ConfigureAwait(false);
            }
            catch (Exception e) when (e is IOException or InvalidDataException or JsonException or OperationCanceledException or InvalidOperationException or ArgumentException or System.Net.Sockets.SocketException or System.ComponentModel.Win32Exception) { }
        }
    }
    private static PeelPskCredential RequireTrust(Generation generation, SignalPublisherPeer peer, ReadOnlySpan<byte> expectedKey = default)
    {
        generation.Cancel.Token.ThrowIfCancellationRequested();
        if (!generation.Trust.Snapshot().Contains(peer) || !generation.Trust.TryResolve(peer.PairingId, out var credential) || credential is null)
            throw new InvalidDataException("Signal pairing is no longer trusted.");
        if (credential.PreSharedKey.Length == 32 && (expectedKey.IsEmpty || CryptographicOperations.FixedTimeEquals(expectedKey, credential.PreSharedKey))) return credential;
        CryptographicOperations.ZeroMemory(credential.PreSharedKey); throw new InvalidDataException("Signal pairing key changed.");
    }
    private async Task ServeAsync(Generation generation, PeelPskConnection connection, CancellationToken token)
    {
        byte[]? key = null;
        bool counted = false;
        using var abort = token.Register(static state => ((Stream)state!).Dispose(), connection.Stream);
        try
        {
            using var handshake = CancellationTokenSource.CreateLinkedTokenSource(token); handshake.CancelAfter(TimeSpan.FromSeconds(10));
            var hello = TrustedSignals.ReadHello(await ReadHandshakeLineAsync(connection.Stream, handshake.Token).ConfigureAwait(false));
            var peer = generation.Trust.Snapshot().SingleOrDefault(p => p.PairingId == connection.PeerIdentity);
            if (peer is null || hello.PairingId != connection.PeerIdentity || TrustedSignals.Uuid(hello.PublisherHostId) != TrustedSignals.Uuid(peer.PublisherId)
                || TrustedSignals.Uuid(hello.SubscriberHostId) != TrustedSignals.Uuid(peer.SubscriberId) || TrustedSignals.Uuid(hello.SubscriberNodeId) == TrustedSignals.Uuid(nodeId))
                throw new InvalidDataException("Signal hello identity does not match its pairing.");
            key = RequireTrust(generation, peer).PreSharedKey;
            string nonce = TrustedSignals.NewNonce();
            var challenge = new SignalChallengeMessage(nonce, nodeId, Convert.ToBase64String(TrustedSignals.Proof(true, hello, nonce, nodeId, key)));
            await connection.Stream.WriteAsync(PeelJson.SerializeLine(challenge), handshake.Token).ConfigureAwait(false);
            await connection.Stream.FlushAsync(handshake.Token).ConfigureAwait(false);
            var proof = TrustedSignals.ReadProof(await ReadHandshakeLineAsync(connection.Stream, handshake.Token).ConfigureAwait(false));
            if (!TrustedSignals.Verify(false, proof.Proof, hello, nonce, nodeId, key)) throw new InvalidDataException("Signal subscriber proof failed.");
            CryptographicOperations.ZeroMemory(RequireTrust(generation, peer, key).PreSharedKey);
            Interlocked.Increment(ref generation.Receivers); counted = true;
            using var closed = CancellationTokenSource.CreateLinkedTokenSource(token);
            var unexpectedInput = RejectFurtherInputAsync(connection.Stream, closed);
            try
            {
                using var tick = new PeriodicTimer(TimeSpan.FromSeconds(1));
                do
                {
                    CryptographicOperations.ZeroMemory(RequireTrust(generation, peer, key).PreSharedKey);
                    using var send = CancellationTokenSource.CreateLinkedTokenSource(closed.Token); send.CancelAfter(TimeSpan.FromSeconds(3));
                    await connection.Stream.WriteAsync(TrustedSignals.FrameLine(LatestFrame()), send.Token).ConfigureAwait(false);
                    await connection.Stream.FlushAsync(send.Token).ConfigureAwait(false);
                } while (await tick.WaitForNextTickAsync(closed.Token).ConfigureAwait(false));
            }
            finally
            {
                closed.Cancel(); connection.Stream.Dispose();
                await unexpectedInput.ConfigureAwait(false);
            }
        }
        finally
        {
            if (counted) Interlocked.Decrement(ref generation.Receivers);
            if (key is not null) CryptographicOperations.ZeroMemory(key);
        }
    }
    private static async Task RejectFurtherInputAsync(Stream stream, CancellationTokenSource close)
    {
        try { _ = await stream.ReadAsync(new byte[1], close.Token).ConfigureAwait(false); }
        catch (Exception e) when (e is IOException or OperationCanceledException or InvalidOperationException) { }
        finally { close.Cancel(); }
    }
    private static async Task<byte[]> ReadHandshakeLineAsync(Stream stream, CancellationToken token)
    {
        // Reading exactly through LF cannot consume a proof into another protocol phase.
        byte[] bytes = new byte[TrustedSignals.MaximumHandshakeBytes]; byte[] single = new byte[1]; int count = 0;
        while (count < bytes.Length)
        {
            if (await stream.ReadAsync(single, token).ConfigureAwait(false) == 0) throw new EndOfStreamException();
            if (single[0] == (byte)'\n') return bytes.AsSpan(0, count).ToArray();
            bytes[count++] = single[0];
        }
        throw new InvalidDataException("Signal handshake line is oversized.");
    }
    public async ValueTask DisposeAsync()
    {
        Cancel(); await lifecycle.WaitAsync().ConfigureAwait(false);
        try { disposed = true; await StopCoreAsync().ConfigureAwait(false); }
        finally { lifecycle.Release(); }
    }
}
