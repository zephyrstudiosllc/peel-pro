using System.Text.Json;
using Peel.Windows.Client.Models;
using Peel.Windows.Protocol;

namespace Peel.Windows.Client.Services;

/// <summary>A validated source-media reply and the control generation that received it.</summary>
public sealed record SourceMediaReply(long Generation, SourceMediaAckMessage? Ack, SourceVolumeStateMessage? VolumeState);

/// <summary>The exact paired control session a source control is captured against.</summary>
public sealed record SourceMediaSessionIdentity(long Generation, string PairingId, bool MediaKeys, bool Volume);

public sealed partial class ClientSession
{
    internal event EventHandler<SourceMediaReply>? SourceMediaReplyReceived;

    internal SourceMediaSessionIdentity? SourceMediaIdentity
    {
        get
        {
            lock (_stateGate)
            {
                if (_state != PeelConnectionState.Connected || _activePairingId is null || _negotiatedHost is null) return null;
                return new(_generation, _activePairingId,
                    _negotiatedHost.Capabilities.Contains(SourceMediaProtocol.MediaKeysCapability),
                    _negotiatedHost.Capabilities.Contains(SourceMediaProtocol.VolumeCapability));
            }
        }
    }

    /// <summary>Connected session that can request default playback: its generation and pairing.</summary>
    internal (long Generation, string PairingId)? AudioPlaybackIdentity
    {
        get
        {
            lock (_stateGate)
            {
                if (!_options.SupportsAudioPlayback || _state != PeelConnectionState.Connected || _activePairingId is null ||
                    _negotiatedHost?.Capabilities.Contains("mac-system-audio-v1") != true) return null;
                return (_generation, _activePairingId);
            }
        }
    }

    internal string? ActivePairingId { get { lock (_stateGate) return _state == PeelConnectionState.Connected ? _activePairingId : null; } }

    // Replies are advisory: a malformed, stale or foreign one is dropped and never ends the session.
    private void HandleSourceMediaReply(string type, byte[] utf8, long generation)
    {
        if (utf8.Length > SourceMediaProtocol.MaximumLineBytes) return;
        SourceMediaReply reply;
        try
        {
            if (type == SourceMediaProtocol.AckType)
            {
                var ack = PeelJson.Deserialize<SourceMediaAckMessage>(utf8);
                if (!ack.TryParse(out _, out _)) return;
                reply = new(generation, ack, null);
            }
            else
            {
                var state = PeelJson.Deserialize<SourceVolumeStateMessage>(utf8);
                if (!state.IsValid) return;
                reply = new(generation, null, state);
            }
        }
        catch (JsonException) { return; }
        lock (_stateGate)
        {
            if (_generation != generation || _state != PeelConnectionState.Connected) return;
            string? pairingId = reply.Ack?.PairingId ?? reply.VolumeState?.PairingId;
            if (!StringComparer.Ordinal.Equals(pairingId, _activePairingId)) return;
        }
        SourceMediaReplyReceived?.Invoke(this, reply);
    }
}
