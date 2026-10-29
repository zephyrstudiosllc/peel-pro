using System.Text.Json.Serialization;

namespace Peel.Windows.Protocol;

public sealed record AudioSessionRequestMessage(
    [property: JsonPropertyName("requestId")] string RequestId,
    [property: JsonPropertyName("enabled")] bool Enabled,
    [property: JsonPropertyName("mode")] string? Mode = null,
    [property: JsonPropertyName("type")] string Type = "audioSessionRequest");
public sealed record AudioSessionStateMessage(
    [property: JsonPropertyName("requestId")] string RequestId,
    [property: JsonPropertyName("pairingId")] string PairingId,
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("reason")] string? Reason = null,
    [property: JsonPropertyName("ticket")] string? Ticket = null,
    [property: JsonPropertyName("type")] string Type = "audioSessionState");
public sealed record AudioPairingChallengeMessage(
    [property: JsonPropertyName("requestId")] string RequestId,
    [property: JsonPropertyName("pairingId")] string PairingId,
    [property: JsonPropertyName("nonce")] string Nonce,
    [property: JsonPropertyName("expiresAt")] double ExpiresAt,
    [property: JsonPropertyName("mode")] string? Mode = null,
    [property: JsonPropertyName("type")] string Type = "audioPairingChallenge");
public sealed record AudioPairingProofMessage(
    [property: JsonPropertyName("requestId")] string RequestId,
    [property: JsonPropertyName("pairingId")] string PairingId,
    [property: JsonPropertyName("proof")] string Proof,
    [property: JsonPropertyName("type")] string Type = "audioPairingProof");
public sealed record AudioStreamHelloMessage(
    [property: JsonPropertyName("requestId")] string RequestId,
    [property: JsonPropertyName("pairingId")] string PairingId,
    [property: JsonPropertyName("ticket")] string Ticket,
    [property: JsonPropertyName("version")] int Version = 1,
    [property: JsonPropertyName("type")] string Type = "audioStreamHello");
public static class AudioPairingProof
{
    public static string Make(AudioPairingChallengeMessage challenge, ReadOnlySpan<byte> key)
    {
        if (challenge.Mode is not (null or "playback" or "voice")) throw new InvalidDataException("Invalid audio proof mode.");
        return AgentPairingProof.MakeDomain(new(challenge.RequestId, challenge.PairingId, challenge.Nonce, challenge.ExpiresAt), key,
            challenge.Mode == "voice" ? "peel.voice-pairing-proof.v1\0" : "peel.audio-pairing-proof.v1\0");
    }
}
