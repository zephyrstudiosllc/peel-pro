using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Peel.Windows.Protocol;

namespace Peel.Linux.Host;

// Dedicated inbound trust. Outbound SavedComputer secrets are never consulted.
internal interface ILinuxHostSecretVault { string? Read(string key); void Write(string key, string value); }
internal sealed class LinuxHostSecretServiceVault : ILinuxHostSecretVault
{
    public string? Read(string key)
    {
        IntPtr p = NativeUI.peel_linux_secret_lookup(key);
        if (p == IntPtr.Zero) return null; // Missing/locked/error all DENY, never mint trust.
        try { return Marshal.PtrToStringUTF8(p); } finally { NativeUI.peel_linux_secret_free(p); }
    }
    public void Write(string key, string value)
    {
        if (NativeUI.peel_linux_secret_store(key, value) != 1) throw new IOException("Inbound pairing could not be saved in Secret Service.");
    }
}
internal sealed record LinuxHostPeer(string PairingId, string DeviceId, string Name, Guid Revision, string KeySHA256);
internal sealed class LinuxHostPeerLease
{
    private readonly LinuxHostTrust owner;
    internal LinuxHostPeer Peer { get; }
    internal LinuxHostPeerLease(LinuxHostTrust owner, LinuxHostPeer peer) { this.owner = owner; Peer = peer; }
    internal bool IsCurrent => owner.IsCurrent(Peer);
}
internal sealed class LinuxHostTrust : IPeelPskCredentialResolver, IDisposable
{
    private readonly object gate = new();
    private readonly object mutation = new();
    private readonly ILinuxHostSecretVault vault;
    private readonly Action<IReadOnlyList<LinuxHostPeer>> persist;
    private readonly Dictionary<string, LinuxHostPeer> peers;
    private readonly HashSet<string> denied = new(StringComparer.Ordinal);
    private bool disposed;
    internal string HostId { get; }
    internal event Action<string>? PeerRevoked;
    internal LinuxHostTrust(string hostId, ILinuxHostSecretVault vault, IReadOnlyList<LinuxHostPeer> existing,
                            Action<IReadOnlyList<LinuxHostPeer>> persist)
    {
        if (!Guid.TryParseExact(hostId, "D", out _)) throw new InvalidDataException("Invalid local host identity.");
        HostId = hostId; this.vault = vault; this.persist = persist;
        if (existing.Count > 8) throw new InvalidDataException("Too many inbound pairings.");
        peers = new(StringComparer.Ordinal);
        var devices = new HashSet<string>(StringComparer.Ordinal);
        foreach (var peer in existing)
        {
            Validate(peer);
            if (!peers.TryAdd(peer.PairingId, peer) || !devices.Add(peer.DeviceId)) throw new InvalidDataException("Duplicate inbound pairing.");
        }
    }
    internal int Count { get { lock (gate) return disposed ? 0 : peers.Count; } }
    internal IReadOnlyList<LinuxHostPeer> Snapshot() { lock (gate) return peers.Values.ToArray(); }
    internal bool IsCurrent(LinuxHostPeer peer)
    {
        lock (gate) return !disposed && !denied.Contains(peer.PairingId) && peers.TryGetValue(peer.PairingId, out var live) && live == peer;
    }
    private string Key(string id) => "peel-inbound-v1:" + HostId + ":" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(id)));
    internal LinuxHostPeerLease Capture(string id)
    {
        LinuxHostPeer peer;
        lock (gate)
        { if (disposed || denied.Contains(id) || !peers.TryGetValue(id, out peer!)) throw new InvalidDataException("Inbound pairing is not current."); }
        byte[] secret = ReadSecret(peer);
        try { if (!IsCurrent(peer)) throw new InvalidDataException("Inbound pairing changed."); return new(this, peer); }
        finally { CryptographicOperations.ZeroMemory(secret); }
    }
    public bool TryResolve(string identity, out PeelPskCredential? credential)
    {
        credential = null; LinuxHostPeer peer;
        lock (gate) { if (disposed || denied.Contains(identity) || !peers.TryGetValue(identity, out peer!)) return false; }
        byte[] key = [];
        try { key = ReadSecret(peer); if (!IsCurrent(peer)) return false; credential = new(identity, key); return true; }
        catch (Exception e) when (e is IOException or JsonException or FormatException or InvalidOperationException) { return false; }
        finally { CryptographicOperations.ZeroMemory(key); }
    }
    private byte[] ReadSecret(LinuxHostPeer peer)
    {
        var text = vault.Read(Key(peer.PairingId)) ?? throw new IOException("Inbound secret missing or unavailable.");
        if (Encoding.UTF8.GetByteCount(text) > 4096) throw new InvalidDataException("Invalid inbound secret.");
        using var d = JsonDocument.Parse(text);
        var r = d.RootElement; LinuxHostWire.Exact(r, "schema", "hostId", "pairingId", "deviceId", "revision", "key");
        if (r.GetProperty("schema").GetInt32() != 1 || r.GetProperty("hostId").GetString() != HostId
            || r.GetProperty("pairingId").GetString() != peer.PairingId || r.GetProperty("deviceId").GetString() != peer.DeviceId
            || r.GetProperty("revision").GetString() != peer.Revision.ToString("D")) throw new InvalidDataException("Inbound key belongs to another enrollment.");
        string encoded = r.GetProperty("key").GetString() ?? throw new InvalidDataException();
        byte[] bytes = Convert.FromBase64String(encoded);
        if (bytes.Length != 32 || Convert.ToBase64String(bytes) != encoded || Convert.ToHexString(SHA256.HashData(bytes)) != peer.KeySHA256)
        { CryptographicOperations.ZeroMemory(bytes); throw new InvalidDataException("Invalid inbound key."); }
        return bytes;
    }
    // Called ONLY after current finite visible PIN consent + authenticated PIN proof.
    internal LinuxHostPeer EnrollFromPin(string deviceId, string name, ReadOnlySpan<byte> key, Action<LinuxHostPeer> beforePersist)
    {
        string id = Guid.NewGuid().ToString("D").ToUpperInvariant();
        var peer = new LinuxHostPeer(id, deviceId, name, Guid.NewGuid(), Convert.ToHexString(SHA256.HashData(key)));
        Validate(peer); if (key.Length != 32) throw new InvalidDataException("Invalid pairing key size.");
        // Owner sees the exact provisional identity BEFORE any key/metadata write.
        // Its synchronous cancellation fence can deny even an in-progress commit.
        beforePersist(peer);
        string[] replaced;
        lock (mutation)
        {
            LinuxHostPeer[] next;
            lock (gate)
            {
                ObjectDisposedException.ThrowIf(disposed, this);
                if (denied.Contains(peer.PairingId)) throw new OperationCanceledException("Provisional enrollment was denied.");
                replaced = peers.Values.Where(p => p.DeviceId == deviceId).Select(p => p.PairingId).ToArray();
                if (peers.Count - replaced.Length >= 8 || peers.ContainsKey(id)) throw new InvalidOperationException("Inbound pairing capacity reached.");
                next = peers.Values.Where(p => p.DeviceId != deviceId && !denied.Contains(p.PairingId)).Append(peer).ToArray();
            }
            // No Secret Service/disk operation holds the live-currentness lock.
            vault.Write(Key(id), JsonSerializer.Serialize(new { schema = 1, hostId = HostId, pairingId = id, deviceId, revision = peer.Revision.ToString("D"), key = Convert.ToBase64String(key) }));
            persist(next);
            lock (gate)
            {
                ObjectDisposedException.ThrowIf(disposed, this);
                if (denied.Contains(peer.PairingId)) throw new OperationCanceledException("Provisional enrollment was denied.");
                foreach (string old in replaced) { denied.Add(old); peers.Remove(old); }
                peers.Add(id, peer);
            }
        }
        foreach (string old in replaced) PeerRevoked?.Invoke(old);
        return peer;
    }
    internal void MarkDenied(string id)
    {
        lock (gate) denied.Add(id);
        PeerRevoked?.Invoke(id);
    }
    internal void Revoke(string id)
    {
        // Synchronous known-authority closure precedes any secure-store I/O.
        MarkDenied(id);
        lock (mutation)
        {
            LinuxHostPeer[] next;
            lock (gate) { next = peers.Values.Where(p => p.PairingId != id && !denied.Contains(p.PairingId)).ToArray(); }
            // Tombstone even a not-yet-published provisional ID. A cancelled
            // commit may have written durable metadata before publication.
            // mutation serializes this cleanup with that exact commit.
            // Tombstone first: stale metadata cannot restore this key after crash.
            vault.Write(Key(id), "{\"schema\":1,\"revoked\":true}"); persist(next);
            lock (gate) peers.Remove(id);
        }
    }
    public void Dispose() { lock (gate) { disposed = true; foreach (string id in peers.Keys) denied.Add(id); } }
    private static void Validate(LinuxHostPeer peer)
    {
        if (!Guid.TryParse(peer.PairingId, out _) || peer.Revision == Guid.Empty || !LinuxHostWire.Text(peer.DeviceId, 1024)
            || !LinuxHostWire.Text(peer.Name, 256) || peer.KeySHA256 is not { Length: 64 } || peer.KeySHA256.Any(c => !Uri.IsHexDigit(c))) throw new InvalidDataException("Invalid inbound metadata.");
    }
}
