using System.IO;
using System.Security.Cryptography;
using Peel.Windows.Client.Models;
using Peel.Windows.Protocol;

namespace Peel.Windows.Client.Services;

/// <summary>Playback-only attachment grant for one control generation. The ticket is opaque
/// attachment material: it is written only to the owned auxiliary TLS hello, never logged.</summary>
public sealed record AudioAuthorization(string RequestId, string PairingId, string Ticket, string HostId, long Generation)
{
    public override string ToString() => $"AudioAuthorization {{ Generation = {Generation} }}";
}

public sealed class AudioStateEventArgs(AudioSessionStateMessage state, long generation) : EventArgs
{
    public AudioSessionStateMessage State { get; } = state;
    public long Generation { get; } = generation;
}

public sealed class SourceMediaReplyEventArgs(string type, byte[] utf8, long generation) : EventArgs
{
    public string Type { get; } = type;
    public byte[] Utf8 { get; } = utf8;
    public long Generation { get; } = generation;
}

/// <summary>Linux adaptation of the Windows ClientAudioControl request/challenge/proof path.
/// Playback mode only: this client never requests Voice or opens a microphone.</summary>
public sealed partial class ClientSession : Peel.Linux.IReceiverAudioSession, Peel.Linux.ISourceMediaChannel
{
    Task<AudioAuthorization> Peel.Linux.IReceiverAudioSession.BeginAudioPlaybackAsync(long generation, CancellationToken token) =>
        BeginAudioPlaybackAsync(generation, token);

    Task Peel.Linux.IReceiverAudioSession.EndAudioAsync(string requestId, long generation) => EndAudioAsync(requestId, generation);

    Task Peel.Linux.ISourceMediaChannel.SendSourceMediaAsync<T>(T message, long generation, Func<bool> stillOwned, CancellationToken token) =>
        SendSourceMediaAsync(message, generation, stillOwned, token);

    public const string AudioPlaybackCapability = "mac-system-audio-v1";
    private string? _audioRequestId;
    private bool _audioProofSent;
    private TaskCompletionSource<AudioSessionStateMessage>? _audioCompletion;

    public event EventHandler<AudioStateEventArgs>? AudioStateChanged;

    /// <summary>Raw bounded sourceMediaAck/sourceVolumeState lines with their control generation.</summary>
    public event EventHandler<SourceMediaReplyEventArgs>? SourceMediaReplyReceived;

    public bool HostSupports(string capability)
    {
        lock (_stateGate)
        {
            return _state == PeelConnectionState.Connected && _negotiatedHost?.Capabilities.Contains(capability) == true;
        }
    }

    internal async Task<AudioAuthorization> BeginAudioPlaybackAsync(long expectedGeneration, CancellationToken token)
    {
        string id = Guid.NewGuid().ToString("D").ToUpperInvariant(), hostId, pairingId;
        long generation;
        var completion = new TaskCompletionSource<AudioSessionStateMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (_stateGate)
        {
            if (!_options.SupportsAudioPlayback || _state != PeelConnectionState.Connected || _generation != expectedGeneration ||
                _negotiatedHost?.Capabilities.Contains(AudioPlaybackCapability) != true || _connectedHost is null || _activePairingId is null)
                throw new InvalidOperationException("The connected computer does not offer audio to this session.");
            if (_audioRequestId is not null) throw new InvalidOperationException("An audio session is already active or starting.");
            _audioRequestId = id; _audioProofSent = false; _audioCompletion = completion;
            hostId = _connectedHost.StableHostId; pairingId = _activePairingId; generation = _generation;
        }
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token); timeout.CancelAfter(TimeSpan.FromSeconds(10));
        try
        {
            await SendMessageAsync(new AudioSessionRequestMessage(id, true, "playback"), generation, timeout.Token).ConfigureAwait(false);
            var ready = await completion.Task.WaitAsync(timeout.Token).ConfigureAwait(false);
            byte[] ticket;
            try { ticket = Convert.FromBase64String(ready.Ticket ?? ""); }
            catch (FormatException e) { throw new InvalidDataException("Invalid audio attachment ticket.", e); }
            bool valid = ticket.Length == 32;
            CryptographicOperations.ZeroMemory(ticket);
            if (!valid) throw new InvalidDataException("Invalid audio attachment ticket.");
            return new(id, pairingId, ready.Ticket!, hostId, generation);
        }
        catch { await EndAudioAsync(id, generation).ConfigureAwait(false); throw; }
    }

    internal async Task EndAudioAsync(string id, long generation)
    {
        bool connected;
        lock (_stateGate)
        {
            if (_audioRequestId != id || _generation != generation) return;
            _audioRequestId = null; _audioCompletion?.TrySetCanceled(); _audioCompletion = null; _audioProofSent = false;
            connected = _state == PeelConnectionState.Connected;
        }
        if (!connected) return;
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3));
        try { await SendMessageAsync(new AudioSessionRequestMessage(id, false, "playback"), generation, timeout.Token).ConfigureAwait(false); }
        catch (Exception e) when (e is IOException or InvalidOperationException or OperationCanceledException or ObjectDisposedException)
        {
            // The source may still believe audio is wanted; end this exact session rather than leave it ambiguous.
            if (SessionGeneration == generation) await DisconnectAsync(default).ConfigureAwait(false);
        }
    }

    private async Task HandleAudioChallengeAsync(AudioPairingChallengeMessage challenge, long generation, CancellationToken token)
    {
        string hostId;
        lock (_stateGate)
        {
            EnsureGenerationLocked(generation);
            if (_audioRequestId != challenge.RequestId || _audioCompletion is null || _audioProofSent ||
                challenge.PairingId != _activePairingId || _connectedHost is null) return;
            if ((challenge.Mode ?? "playback") != "playback" || !AgentPairingProof.IsFresh(new(challenge.RequestId, challenge.PairingId, challenge.Nonce, challenge.ExpiresAt),
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
            await SendMessageAsync(new AudioPairingProofMessage(challenge.RequestId, challenge.PairingId, AudioPairingProof.Make(challenge, key)), generation, token).ConfigureAwait(false);
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
                _audioCompletion?.TrySetException(new InvalidOperationException(message.Reason ?? "Source audio stopped."));
        }
        AudioStateChanged?.Invoke(this, new AudioStateEventArgs(message, generation));
    }

    /// <summary>Sends one source-media request only on the exact captured control generation.
    /// <paramref name="token"/> is linked through the writer wait; <paramref name="stillOwned"/>
    /// is rechecked after that wait, immediately before the bytes are written.</summary>
    internal async Task SendSourceMediaAsync<T>(T message, long generation, Func<bool> stillOwned, CancellationToken token)
    {
        CancellationToken session;
        lock (_stateGate)
        {
            if (_state != PeelConnectionState.Connected || _sessionCancellation is null || _generation != generation)
                throw new OperationCanceledException("The control session changed.");
            session = _sessionCancellation.Token;
        }
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(token, session);
        await SendMessageAsync(message, generation, linked.Token, stillOwned).ConfigureAwait(false);
    }
}
