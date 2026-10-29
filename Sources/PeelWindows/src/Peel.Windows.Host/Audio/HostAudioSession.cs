using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json;
using System.Threading.Channels;
using Peel.Windows.Protocol;
using Peel.Windows.Host.Networking;

namespace Peel.Windows.Host.Audio;

/// <summary>One authenticated control generation owns its challenge, ticket and auxiliary audio socket.</summary>
internal sealed class HostAudioSession(HostAudioSharing sharing, IPeelPskCredentialResolver credentials,
    string pairingId, Func<bool> eligible, Func<object, CancellationToken, ValueTask<bool>> send) : IAsyncDisposable
{
    private readonly SemaphoreSlim gate = new(1, 1);
    private Pending? pending;
    private volatile bool disposed;
    private static bool Fresh(long at) => Stopwatch.GetElapsedTime(at) < TimeSpan.FromSeconds(10);
    private AudioSessionStateMessage State(string id, string status, string? reason = null, string? ticket = null) => new(id, pairingId, status, reason, ticket);
    private bool Authorized(Pending p) => !disposed && eligible() && sharing.Enabled && !p.Consent.IsCancellationRequested &&
        credentials.TryResolve(pairingId, out var key) && key is not null &&
        CryptographicOperations.FixedTimeEquals(p.KeyHash, SHA256.HashData(key.PreSharedKey));

    internal async ValueTask<object?> RequestAsync(AudioSessionRequestMessage request, CancellationToken token)
    {
        MachineStatusValidation.RequestId(request.RequestId);
        await gate.WaitAsync(token).ConfigureAwait(false);
        try
        {
            if (!request.Enabled)
            {
                if (pending?.Challenge.RequestId != request.RequestId) return null;
                await StopLockedAsync().ConfigureAwait(false);
                return State(request.RequestId, "stopped");
            }
            if (request.Mode is not (null or "playback"))
                return State(request.RequestId, "unavailable", "Voice input to this PC is unavailable.");
            if (disposed || !eligible() || !sharing.Enabled || !sharing.Supported)
                return State(request.RequestId, "unavailable", "System audio sharing is off or the client is hidden.");
            if (pending is { } previous)
            {
                if (previous.Worker is { IsCompleted: false } || previous.Worker is null && Fresh(previous.Issued))
                    return State(request.RequestId, "unavailable", "An audio session is already pending or active.");
                await StopLockedAsync().ConfigureAwait(false);
            }
            if (!credentials.TryResolve(pairingId, out var key) || key is null)
                return State(request.RequestId, "unavailable", "Audio pairing is unavailable.");
            var challenge = new AudioPairingChallengeMessage(request.RequestId, pairingId,
                Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)), DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0 + 10, request.Mode);
            pending = new(challenge, SHA256.HashData(key.PreSharedKey), sharing.Permission);
            var created = pending; var expiryToken = created.Stop.Token;
            _ = Task.Run(() => ExpireAsync(created, expiryToken), CancellationToken.None);
            return challenge;
        }
        finally { gate.Release(); }
    }

    private async Task ExpireAsync(Pending p, CancellationToken token)
    {
        try
        {
            while (true)
            {
                var remaining = TimeSpan.FromSeconds(10) - Stopwatch.GetElapsedTime(Interlocked.Read(ref p.Issued));
                await Task.Delay(remaining > TimeSpan.Zero ? remaining : TimeSpan.FromMilliseconds(1), token).ConfigureAwait(false);
                await gate.WaitAsync(token).ConfigureAwait(false);
                try
                {
                    if (pending != p || disposed || p.Worker is not null) return;
                    if (Fresh(p.Issued)) continue; // Proof grants a fresh, bounded attachment interval.
                    await StopLockedAsync().ConfigureAwait(false);
                    await SendStateAsync(State(p.Challenge.RequestId, "stopped", "Audio authorization expired."), CancellationToken.None).ConfigureAwait(false);
                    return;
                }
                finally { gate.Release(); }
            }
        }
        catch (Exception e) when (e is IOException or OperationCanceledException or ObjectDisposedException) { }
    }

    internal async ValueTask<object?> ProveAsync(AudioPairingProofMessage proof, CancellationToken token)
    {
        await gate.WaitAsync(token).ConfigureAwait(false);
        try
        {
            var p = pending;
            if (p is null || p.Worker is not null || p.Ticket is not null) return null;
            bool valid = Authorized(p) && Fresh(p.Issued) && proof.RequestId == p.Challenge.RequestId && proof.PairingId == pairingId &&
                credentials.TryResolve(pairingId, out var key) && key is not null &&
                EqualSecret(proof.Proof, AudioPairingProof.Make(p.Challenge, key.PreSharedKey));
            if (!valid)
            {
                await StopLockedAsync().ConfigureAwait(false);
                return State(p.Challenge.RequestId, "stopped", "Audio proof expired or was refused.");
            }
            p.Ticket = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)); p.Issued = Stopwatch.GetTimestamp();
            return State(p.Challenge.RequestId, "ready", ticket: p.Ticket);
        }
        finally { gate.Release(); }
    }

    internal async Task AttachAsync(PeelPskConnection connection, CancellationToken token)
    {
        await using var owned = connection;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeout.CancelAfter(TimeSpan.FromSeconds(10));
        try
        {
            var reader = new BoundedNdjsonLineReader(4096); byte[] buffer = new byte[4096];
            AudioStreamHelloMessage hello;
            while (true)
            {
                int count = await connection.Stream.ReadAsync(buffer, timeout.Token).ConfigureAwait(false);
                if (count == 0) return;
                if (!reader.TryAppend(buffer.AsSpan(0, count), out int consumed, out var line)) continue;
                if (consumed != count || PeelJson.ReadEnvelope(line.Span).Type != "audioStreamHello") return;
                hello = PeelJson.Deserialize<AudioStreamHelloMessage>(line.Span); break;
            }
            Task? worker = null;
            await gate.WaitAsync(timeout.Token).ConfigureAwait(false);
            try
            {
                var p = pending;
                if (p is null || p.Worker is not null || p.Ticket is null || !Authorized(p) || !Fresh(p.Issued) || hello.Version != 1 ||
                    connection.PeerIdentity != pairingId || hello.PairingId != pairingId || hello.RequestId != p.Challenge.RequestId || !EqualSecret(hello.Ticket, p.Ticket)) return;
                p.Ticket = null; // Consume before scheduling capture or any socket write.
                worker = p.Worker = Task.Run(() => RunAsync(p, connection.Stream, token), CancellationToken.None);
            }
            finally { gate.Release(); }
            await worker.ConfigureAwait(false);
        }
        catch (Exception e) when (e is IOException or JsonException or InvalidDataException or OperationCanceledException or ObjectDisposedException) { }
    }

    private async Task RunAsync(Pending p, Stream stream, CancellationToken connectionToken)
    {
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(p.Stop.Token, p.Consent, connectionToken);
        var token = lifetime.Token;
        // Six pending PCM packets plus at most one in flight matches the Mac sender's drop-new policy.
        var packets = Channel.CreateBounded<byte[]>(new BoundedChannelOptions(6) { SingleReader = true, SingleWriter = true, FullMode = BoundedChannelFullMode.Wait });
        IHostAudioCapture? capture = null; Task? receive = null, transmit = null, watch = null;
        string reason = "System audio stopped.";
        try
        {
            if (!Authorized(p)) return;
            capture = sharing.TryReserve(p.Consent) ?? throw new InvalidOperationException("Another audio capture is stopping or active.");
            await WriteAsync(new AudioPacket(0, 0, 0, 0, []).Encode()).ConfigureAwait(false);
            receive = RejectIncomingAsync();
            await capture.StartAsync(packet =>
            {
                if (token.IsCancellationRequested) return;
                packet.Validate();
                if (packet.Kind != 1 || packet.Direction != 0) throw new InvalidDataException("Invalid host capture direction.");
                packets.Writer.TryWrite(packet.Encode());
            }, token).ConfigureAwait(false);
            sharing.SetStatus("Sharing this PC's system audio with a paired client.", p.Consent);
            await SendStateAsync(State(p.Challenge.RequestId, "streaming"), token).ConfigureAwait(false);
            transmit = TransmitAsync(); watch = WatchAsync();
            await await Task.WhenAny(receive, transmit, watch, capture.Completion).ConfigureAwait(false);
        }
        catch (Exception e)
        { reason = e is OperationCanceledException ? "System audio stopped." : "System audio capture or transport became unavailable."; }
        finally
        {
            lifetime.Cancel(); packets.Writer.TryComplete();
            try { stream.Dispose(); } catch (IOException) { }
            // Every owned task is observed before releasing native capture, including unexpected adapter failures.
            foreach (var task in new[] { receive, transmit, watch }) if (task is not null) try { await task.ConfigureAwait(false); } catch (Exception) { }
            if (capture is not null) try { await capture.DisposeAsync().ConfigureAwait(false); }
                catch (Exception) { reason = "Audio capture could not confirm a clean stop; restart Peel Pro before sharing again."; }
            sharing.SetStatus(reason, p.Consent);
            try { await SendStateAsync(State(p.Challenge.RequestId, "stopped", reason), CancellationToken.None).ConfigureAwait(false); }
            catch (Exception) { /* A dead control transport must not prevent audio cleanup. */ }
        }
        async Task WriteAsync(byte[] bytes)
        {
            if (!Authorized(p)) throw new OperationCanceledException();
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token); deadline.CancelAfter(TimeSpan.FromSeconds(3));
            await stream.WriteAsync(bytes, deadline.Token).ConfigureAwait(false);
            await stream.FlushAsync(deadline.Token).ConfigureAwait(false);
        }
        async Task RejectIncomingAsync()
        { _ = await stream.ReadAsync(new byte[1], token).ConfigureAwait(false); lifetime.Cancel(); }
        async Task TransmitAsync()
        { await foreach (var bytes in packets.Reader.ReadAllAsync(token).ConfigureAwait(false)) await WriteAsync(bytes).ConfigureAwait(false); }
        async Task WatchAsync()
        { while (true) { await Task.Delay(250, token).ConfigureAwait(false); if (!Authorized(p)) throw new OperationCanceledException(); } }
    }

    private async Task SendStateAsync(object state, CancellationToken token)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token); deadline.CancelAfter(TimeSpan.FromSeconds(3));
        await send(state, deadline.Token).ConfigureAwait(false);
    }
    internal async ValueTask StopAsync()
    {
        await gate.WaitAsync().ConfigureAwait(false);
        try { await StopLockedAsync().ConfigureAwait(false); }
        finally { gate.Release(); }
    }
    private async Task StopLockedAsync()
    {
        var p = pending; pending = null;
        if (p is null) return;
        p.Stop.Cancel();
        try { if (p.Worker is not null) await p.Worker.ConfigureAwait(false); }
        finally { p.Stop.Dispose(); CryptographicOperations.ZeroMemory(p.KeyHash); }
    }
    public async ValueTask DisposeAsync()
    {
        await gate.WaitAsync().ConfigureAwait(false);
        try { disposed = true; await StopLockedAsync().ConfigureAwait(false); }
        finally { gate.Release(); }
    }
    private static bool EqualSecret(string? a, string b)
    {
        if (a is null || a.Length != 44) return false;
        Span<byte> decoded = stackalloc byte[32], expected = stackalloc byte[32];
        return Convert.TryFromBase64String(a, decoded, out int count) && count == 32 && Convert.ToBase64String(decoded) == a &&
            Convert.TryFromBase64String(b, expected, out count) && count == 32 && CryptographicOperations.FixedTimeEquals(decoded, expected);
    }
    private sealed class Pending(AudioPairingChallengeMessage challenge, byte[] keyHash, CancellationToken consent)
    {
        internal AudioPairingChallengeMessage Challenge = challenge;
        internal byte[] KeyHash = keyHash;
        internal CancellationToken Consent = consent;
        internal CancellationTokenSource Stop = new();
        internal long Issued = Stopwatch.GetTimestamp();
        internal string? Ticket;
        internal Task? Worker;
    }
}
