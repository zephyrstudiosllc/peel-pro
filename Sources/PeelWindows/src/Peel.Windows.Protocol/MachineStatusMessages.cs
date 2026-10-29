using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Serialization;

namespace Peel.Windows.Protocol;

public sealed record AgentPairingChallengeMessage(
    [property: JsonPropertyName("requestId")] string RequestId,
    [property: JsonPropertyName("pairingId")] string PairingId,
    [property: JsonPropertyName("nonce")] string Nonce,
    [property: JsonPropertyName("expiresAt")] double ExpiresAt,
    [property: JsonPropertyName("type")] string Type = "agentPairingChallenge");

public sealed record AgentPairingProofMessage(
    [property: JsonPropertyName("requestId")] string RequestId,
    [property: JsonPropertyName("pairingId")] string PairingId,
    [property: JsonPropertyName("proof")] string Proof,
    [property: JsonPropertyName("type")] string Type = "agentPairingProof");

/// <summary>Byte-for-byte equivalent to the Mac's additive agent proof. TLS pairing is unchanged.</summary>
public static class AgentPairingProof
{
    public static bool IsFresh(AgentPairingChallengeMessage challenge, double now) =>
        double.IsFinite(now) && double.IsFinite(challenge.ExpiresAt) &&
        challenge.ExpiresAt > now && challenge.ExpiresAt <= now + 60;

    public static string Make(AgentPairingChallengeMessage challenge, ReadOnlySpan<byte> key)
        => MakeDomain(challenge, key, "peel.agent-pairing-proof.v1\0");
    internal static string MakeDomain(AgentPairingChallengeMessage challenge, ReadOnlySpan<byte> key, string domain)
    {
        if (key.Length < 32) throw new InvalidDataException("Invalid proof key size.");
        return Convert.ToBase64String(HMACSHA256.HashData(key, Payload(challenge, domain)));
    }

    public static bool Verify(string proof, AgentPairingChallengeMessage challenge, ReadOnlySpan<byte> key)
    {
        if (proof is null || proof.Length > 64 || key.Length < 32) return false;
        Span<byte> decoded = stackalloc byte[32];
        if (!Convert.TryFromBase64String(proof, decoded, out int written) || written != 32) return false;
        return CryptographicOperations.FixedTimeEquals(decoded, HMACSHA256.HashData(key, Payload(challenge)));
    }

    private static byte[] Payload(AgentPairingChallengeMessage challenge, string domain = "peel.agent-pairing-proof.v1\0")
    {
        if (!Guid.TryParseExact(challenge.RequestId, "D", out var id) ||
            string.IsNullOrEmpty(challenge.PairingId) || Encoding.UTF8.GetByteCount(challenge.PairingId) > 256 ||
            challenge.PairingId.Contains('\0') || !double.IsFinite(challenge.ExpiresAt) || challenge.ExpiresAt <= 0 ||
            challenge.Nonce is null || challenge.Nonce.Length > 64)
            throw new InvalidDataException("Invalid agent challenge.");
        Span<byte> nonce = stackalloc byte[32];
        if (!Convert.TryFromBase64String(challenge.Nonce, nonce, out int written) || written != 32)
            throw new InvalidDataException("Invalid agent nonce.");
        using var bytes = new MemoryStream();
        bytes.Write(Encoding.UTF8.GetBytes(domain));
        bytes.Write(Encoding.UTF8.GetBytes(id.ToString("D").ToUpperInvariant())); bytes.WriteByte(0);
        bytes.Write(Encoding.UTF8.GetBytes(challenge.PairingId)); bytes.WriteByte(0);
        bytes.Write(nonce);
        Span<byte> expiry = stackalloc byte[8];
        BinaryPrimitives.WriteInt64BigEndian(expiry, BitConverter.DoubleToInt64Bits(challenge.ExpiresAt));
        bytes.Write(expiry); return bytes.ToArray();
    }
}

public sealed record MachineStatusRequestMessage(
    [property: JsonPropertyName("requestId")] string RequestId,
    [property: JsonPropertyName("type")] string Type = "machineStatusRequest");
public sealed record MachineStatusErrorMessage(
    [property: JsonPropertyName("requestId")] string RequestId,
    [property: JsonPropertyName("reason")] string Reason,
    [property: JsonPropertyName("type")] string Type = "machineStatusError");
public sealed record MachineStatusApp(
    [property: JsonPropertyName("displayName")] string DisplayName,
    [property: JsonPropertyName("pid")] int Pid,
    [property: JsonPropertyName("cpuPercent")] double CpuPercent,
    [property: JsonPropertyName("memoryBytes")] ulong MemoryBytes);
public sealed record MachineStatusUsage(
    [property: JsonPropertyName("providerName")] string ProviderName,
    [property: JsonPropertyName("usedPercent")] double? UsedPercent = null,
    [property: JsonPropertyName("resetAt")] double? ResetAt = null);
public sealed record MachineStatusMessage(
    [property: JsonPropertyName("requestId")] string RequestId,
    [property: JsonPropertyName("sampledAt")] double SampledAt,
    [property: JsonPropertyName("hostName")] string HostName,
    [property: JsonPropertyName("cpuFraction")] double? CpuFraction = null,
    [property: JsonPropertyName("memoryFraction")] double? MemoryFraction = null,
    [property: JsonPropertyName("memoryUsedBytes")] ulong? MemoryUsedBytes = null,
    [property: JsonPropertyName("memoryTotalBytes")] ulong? MemoryTotalBytes = null,
    [property: JsonPropertyName("storageFreeBytes")] ulong? StorageFreeBytes = null,
    [property: JsonPropertyName("storageTotalBytes")] ulong? StorageTotalBytes = null,
    [property: JsonPropertyName("batteryFraction")] double? BatteryFraction = null,
    [property: JsonPropertyName("networkReceiveBytesPerSecond")] double? NetworkReceiveBytesPerSecond = null,
    [property: JsonPropertyName("networkSendBytesPerSecond")] double? NetworkSendBytesPerSecond = null,
    [property: JsonPropertyName("gpuFraction")] double? GpuFraction = null,
    [property: JsonPropertyName("topApps")] IReadOnlyList<MachineStatusApp>? TopApps = null,
    [property: JsonPropertyName("usage")] IReadOnlyList<MachineStatusUsage>? Usage = null,
    [property: JsonPropertyName("localStatus")] string? LocalStatus = null,
    [property: JsonPropertyName("type")] string Type = "machineStatus")
{
    public void Validate()
    {
        if (Type != "machineStatus") throw new InvalidDataException("Invalid status discriminator.");
        MachineStatusValidation.RequestId(RequestId); MachineStatusValidation.Text(HostName);
        MachineStatusValidation.Range(SampledAt, double.MaxValue);
        foreach (double? fraction in new[] { CpuFraction, MemoryFraction, BatteryFraction, GpuFraction })
            MachineStatusValidation.Range(fraction, 1);
        MachineStatusValidation.Range(NetworkReceiveBytesPerSecond, double.MaxValue);
        MachineStatusValidation.Range(NetworkSendBytesPerSecond, double.MaxValue);
        if (LocalStatus is not null) MachineStatusValidation.Text(LocalStatus);
        if (TopApps?.Count > 5 || Usage?.Count > 8) throw new InvalidDataException("Oversized status snapshot.");
        foreach (var app in TopApps ?? [])
        {
            if (app is null || app.Pid < 0) throw new InvalidDataException("Invalid process.");
            MachineStatusValidation.Text(app.DisplayName); MachineStatusValidation.Range(app.CpuPercent, 100000);
        }
        foreach (var usage in Usage ?? [])
        {
            if (usage is null) throw new InvalidDataException("Invalid usage.");
            MachineStatusValidation.Text(usage.ProviderName); MachineStatusValidation.Range(usage.UsedPercent, 100);
            MachineStatusValidation.Range(usage.ResetAt, double.MaxValue);
        }
    }
}
public static class MachineStatusValidation
{
    public static void RequestId(string? value)
    { if (!Guid.TryParseExact(value, "D", out _)) throw new InvalidDataException("Status request ID must be a UUID."); }
    public static void Text(string? value)
    {
        if (string.IsNullOrWhiteSpace(value) || Encoding.UTF8.GetByteCount(value) > 256 || value.Any(c => c < 32 || c == 127))
            throw new InvalidDataException("Invalid status display text.");
    }
    public static void Range(double? value, double maximum)
    { if (value is { } n && (!double.IsFinite(n) || n < 0 || n > maximum)) throw new InvalidDataException("Invalid status reading."); }
}
