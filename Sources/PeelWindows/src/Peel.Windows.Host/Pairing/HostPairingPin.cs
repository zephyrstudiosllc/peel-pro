using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Peel.Windows.Protocol;

namespace Peel.Windows.Host.Pairing;

public sealed class HostPairingPin
{
    public static readonly TimeSpan DefaultLifetime = TimeSpan.FromMinutes(10);
    public const string TlsPskOrderTxtKey = "tlsPSKOrder";
    public const string StandardTlsPskOrder = "psk-identity";

    private readonly byte[] salt;

    internal HostPairingPin(string pin, ReadOnlySpan<byte> salt, DateTimeOffset expiresAt)
    {
        byte[] validationKey = PeelPinPairing.DerivePreSharedKey(
            pin,
            salt,
            "validation-host");
        CryptographicOperations.ZeroMemory(validationKey);
        if (salt.Length != PeelPinPairing.GeneratedSaltBytes)
        {
            throw new ArgumentException(
                $"Generated pairing salts must contain exactly {PeelPinPairing.GeneratedSaltBytes} bytes.",
                nameof(salt));
        }

        Pin = pin.Trim();
        this.salt = salt.ToArray();
        ExpiresAt = expiresAt;
    }

    public string Pin { get; }

    public string SaltBase64 => Convert.ToBase64String(salt);

    public DateTimeOffset ExpiresAt { get; }

    public static HostPairingPin Generate(
        DateTimeOffset? now = null,
        TimeSpan? lifetime = null)
    {
        TimeSpan boundedLifetime = lifetime ?? DefaultLifetime;
        if (boundedLifetime <= TimeSpan.Zero || boundedLifetime > TimeSpan.FromHours(1))
        {
            throw new ArgumentOutOfRangeException(nameof(lifetime));
        }

        string pin = RandomNumberGenerator
            .GetInt32(1_000_000)
            .ToString("D6", CultureInfo.InvariantCulture);
        return new HostPairingPin(
            pin,
            RandomNumberGenerator.GetBytes(PeelPinPairing.GeneratedSaltBytes),
            (now ?? DateTimeOffset.UtcNow).Add(boundedLifetime));
    }

    public IReadOnlyDictionary<string, byte[]> CreateTxtRecords(
        string hostId,
        ushort pairingPort)
    {
        if (pairingPort == 0)
        {
            throw new ArgumentOutOfRangeException(nameof(pairingPort));
        }

        byte[] key = DerivePreSharedKey(hostId);
        CryptographicOperations.ZeroMemory(key);
        return new Dictionary<string, byte[]>(StringComparer.Ordinal)
        {
            ["hostId"] = System.Text.Encoding.UTF8.GetBytes(hostId),
            ["pairMode"] = "pin"u8.ToArray(),
            ["pinSalt"] = System.Text.Encoding.UTF8.GetBytes(SaltBase64),
            ["pinExp"] = System.Text.Encoding.UTF8.GetBytes(
                ExpiresAt.ToUnixTimeSeconds().ToString(CultureInfo.InvariantCulture)),
            ["pairPort"] = System.Text.Encoding.UTF8.GetBytes(
                pairingPort.ToString(CultureInfo.InvariantCulture)),
            [TlsPskOrderTxtKey] = System.Text.Encoding.UTF8.GetBytes(StandardTlsPskOrder),
        };
    }

    internal byte[] DerivePreSharedKey(string hostId) =>
        PeelPinPairing.DerivePreSharedKey(Pin, salt, hostId);
}
