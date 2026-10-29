using System.IO;
using System.Security.Cryptography;
using Peel.Windows.Client.Models;
using Peel.Windows.Protocol;

namespace Peel.Windows.Client.Services;

public sealed record AudioAuthorization(string RequestId, string PairingId, string Ticket, string HostId, long Generation, string Mode = "playback");
public sealed partial class ClientSession
{
    private string? _audioRequestId;
    private bool _audioProofSent;
    private string? _audioMode;
    private TaskCompletionSource<AudioSessionStateMessage>? _audioCompletion;
    public event EventHandler<AudioSessionStateMessage>? AudioStateChanged;

    internal Task<AudioAuthorization> BeginAudioPlaybackAsync(CancellationToken token) => BeginAudioAsync(false, token);
    internal Task<AudioAuthorization> BeginVoiceAsync(CancellationToken token) => BeginAudioAsync(true, token);
    private async Task<AudioAuthorization> BeginAudioAsync(bool voice, CancellationToken token)
    {
        string id = Guid.NewGuid().ToString("D").ToUpperInvariant(), hostId, pairingId;
        long generation;
        var completion = new TaskCompletionSource<AudioSessionStateMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (_stateGate)
        {
            if (!_options.SupportsAudioPlayback || _state != PeelConnectionState.Connected || _negotiatedHost?.Capabilities.Contains("mac-system-audio-v1") != true || _connectedHost is null || _activePairingId is null)
                throw new InvalidOperationException("Connect to a host with audio support and enable audio sharing there first.");
            if (_audioRequestId is not null) throw new InvalidOperationException("An audio session is already active or starting.");
            if (voice && (!_options.SupportsMicrophone || _negotiatedHost.Capabilities.Contains("remote-voice-v1") != true))
                throw new InvalidOperationException("Voice requires an available Windows microphone and a host advertising remote voice support.");
            _audioRequestId = id; _audioProofSent = false; _audioCompletion = completion;
            _audioMode = voice ? "voice" : "playback";
            hostId = _connectedHost.StableHostId; pairingId = _activePairingId; generation = _generation;
        }
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token); timeout.CancelAfter(TimeSpan.FromSeconds(10));
        try
        {
            await SendClientMessageAsync(new AudioSessionRequestMessage(id, true, voice ? "voice" : "playback"), generation, timeout.Token).ConfigureAwait(false);
            var ready = await completion.Task.WaitAsync(timeout.Token).ConfigureAwait(false);
            byte[] ticket;
            try { ticket = Convert.FromBase64String(ready.Ticket ?? ""); }
            catch (FormatException e) { throw new InvalidDataException("Invalid audio attachment ticket.", e); }
            if (ticket.Length != 32) throw new InvalidDataException("Invalid audio attachment ticket.");
            return new(id, pairingId, ready.Ticket!, hostId, generation, voice ? "voice" : "playback");
        }
        catch { await EndAudioAsync(id, generation).ConfigureAwait(false); throw; }
    }

    internal async Task EndAudioAsync(string id, long generation)
    {
        bool connected; string? mode;
        lock (_stateGate)
        {
            if (_audioRequestId != id || _generation != generation) return;
            _audioRequestId = null; _audioCompletion?.TrySetCanceled(); _audioCompletion = null; mode = _audioMode; _audioMode = null;
            connected = _state == PeelConnectionState.Connected;
        }
        if (!connected) return;
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3));
        try { await SendClientMessageAsync(new AudioSessionRequestMessage(id, false, mode), generation, timeout.Token).ConfigureAwait(false); }
        catch (Exception e) when (e is IOException or InvalidOperationException or OperationCanceledException or ObjectDisposedException)
        { if (SessionGeneration == generation) await DisconnectAsync(default).ConfigureAwait(false); }
    }

    private async Task HandleAudioChallengeAsync(AudioPairingChallengeMessage challenge, long generation, CancellationToken token)
    {
        string hostId;
        lock (_stateGate)
        {
            EnsureGenerationLocked(generation);
            if (_audioRequestId != challenge.RequestId || _audioCompletion is null || _audioProofSent ||
                challenge.PairingId != _activePairingId || _connectedHost is null) return;
            if ((challenge.Mode ?? "playback") != _audioMode || !AgentPairingProof.IsFresh(new(challenge.RequestId, challenge.PairingId, challenge.Nonce, challenge.ExpiresAt),
                DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0)) throw new InvalidDataException("Invalid, mismatched or expired audio challenge.");
            _audioProofSent = true; hostId = _connectedHost.StableHostId;
        }
        var credential = await GetAndValidateCredentialAsync(hostId, token).ConfigureAwait(false);
        byte[] key = credential.CopyPreSharedKey();
        try
        {
            lock (_stateGate)
            {
                EnsureGenerationLocked(generation);
                if (_audioRequestId != challenge.RequestId || credential.PairingId != challenge.PairingId) return;
            }
            await SendClientMessageAsync(new AudioPairingProofMessage(challenge.RequestId, challenge.PairingId, AudioPairingProof.Make(challenge, key)), generation, token).ConfigureAwait(false);
        }
        finally { CryptographicOperations.ZeroMemory(key); }
    }

    private void HandleAudioState(AudioSessionStateMessage message, long generation)
    {
        MachineStatusValidation.RequestId(message.RequestId);
        if (message.PairingId is null || message.PairingId.Length > 256 || message.Status is not ("ready" or "streaming" or "stopped" or "unavailable") ||
            message.Reason?.Length > 512 || message.Ticket?.Length > 64) throw new InvalidDataException("Invalid audio state.");
        lock (_stateGate)
        {
            EnsureGenerationLocked(generation);
            if (_audioRequestId != message.RequestId || _activePairingId != message.PairingId) return;
            if (message.Status == "ready")
            {
                if (!_audioProofSent) throw new InvalidDataException("Audio ticket arrived before proof.");
                _audioCompletion?.TrySetResult(message);
            }
            else if (message.Status is "stopped" or "unavailable")
                _audioCompletion?.TrySetException(new InvalidOperationException(message.Reason ?? "Host audio stopped."));
        }
        AudioStateChanged?.Invoke(this, message);
    }
}
