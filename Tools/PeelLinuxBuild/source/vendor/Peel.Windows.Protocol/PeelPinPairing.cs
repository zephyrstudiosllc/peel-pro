using System.Security.Cryptography;
using System.Text;

namespace Peel.Windows.Protocol;

public static class PeelPinPairing
{
    public const string TlsIdentity = "peel-pin";
    public const int PinDigits = 6;
    public const int GeneratedSaltBytes = 16;
    public const int PreSharedKeyBytes = 32;
    public const int ProofBytes = 32;
    public const int MaximumSaltBytes = 64;
    public const int MaximumIdentityCodeUnits = 1024;

    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private static readonly byte[] DerivationInfo = "peel-pair-pin-v1"u8.ToArray();

    public static byte[] DerivePreSharedKey(
        string pin,
        ReadOnlySpan<byte> salt,
        string hostId)
    {
        string normalizedPin = NormalizePin(pin);
        string validatedHostId = ValidateIdentity(hostId, nameof(hostId), trim: false);
        if (salt.Length is < 1 or > MaximumSaltBytes)
        {
            throw new ArgumentOutOfRangeException(nameof(salt));
        }

        byte[] inputKeyMaterial = StrictUtf8.GetBytes($"{normalizedPin}|{validatedHostId}");
        byte[] extractedKey = [];
        byte[] expandInput = [];
        try
        {
            extractedKey = HMACSHA256.HashData(salt, inputKeyMaterial);
            expandInput = new byte[DerivationInfo.Length + 1];
            DerivationInfo.CopyTo(expandInput, 0);
            expandInput[^1] = 1;
            return HMACSHA256.HashData(extractedKey, expandInput);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(inputKeyMaterial);
            CryptographicOperations.ZeroMemory(extractedKey);
            CryptographicOperations.ZeroMemory(expandInput);
        }
    }

    public static string CreateProof(
        ReadOnlySpan<byte> pinPreSharedKey,
        string hostId,
        string clientDeviceId)
    {
        byte[] signature = CreateProofBytes(pinPreSharedKey, hostId, clientDeviceId);
        try
        {
            return Convert.ToBase64String(signature);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(signature);
        }
    }

    public static bool VerifyProof(
        ReadOnlySpan<byte> pinPreSharedKey,
        string hostId,
        string clientDeviceId,
        string? proof)
    {
        ValidatePreSharedKey(pinPreSharedKey);
        string normalizedProof = proof?.Trim() ?? string.Empty;
        byte[] received;
        try
        {
            received = Convert.FromBase64String(normalizedProof);
        }
        catch (FormatException)
        {
            return false;
        }

        if (received.Length != ProofBytes ||
            !StringComparer.Ordinal.Equals(
                Convert.ToBase64String(received),
                normalizedProof))
        {
            CryptographicOperations.ZeroMemory(received);
            return false;
        }

        byte[] expected = [];
        try
        {
            expected = CreateProofBytes(pinPreSharedKey, hostId, clientDeviceId);
            return CryptographicOperations.FixedTimeEquals(received, expected);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(received);
            CryptographicOperations.ZeroMemory(expected);
        }
    }

    private static byte[] CreateProofBytes(
        ReadOnlySpan<byte> pinPreSharedKey,
        string hostId,
        string clientDeviceId)
    {
        ValidatePreSharedKey(pinPreSharedKey);
        string normalizedHostId = ValidateIdentity(hostId, nameof(hostId), trim: true);
        string normalizedClientDeviceId = ValidateIdentity(
            clientDeviceId,
            nameof(clientDeviceId),
            trim: true);
        byte[] message = StrictUtf8.GetBytes(
            $"peel-pin-proof-v1|{normalizedHostId}|{normalizedClientDeviceId}");
        try
        {
            return HMACSHA256.HashData(pinPreSharedKey, message);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(message);
        }
    }

    private static string NormalizePin(string pin)
    {
        if (pin is null)
        {
            throw new ArgumentNullException(nameof(pin));
        }

        string normalized = pin.Trim();
        if (normalized.Length != PinDigits ||
            normalized.Any(static character => character is < '0' or > '9'))
        {
            throw new ArgumentException("A valid 6-digit pairing PIN is required.", nameof(pin));
        }

        return normalized;
    }

    private static string ValidateIdentity(
        string value,
        string parameterName,
        bool trim)
    {
        if (value is null)
        {
            throw new ArgumentNullException(parameterName);
        }

        string normalized = trim ? value.Trim() : value;
        if (normalized.Length is 0 or > MaximumIdentityCodeUnits ||
            normalized.IndexOf('\0') >= 0)
        {
            throw new ArgumentException(
                $"A non-empty identity of at most {MaximumIdentityCodeUnits} UTF-16 code units is required.",
                parameterName);
        }

        _ = StrictUtf8.GetByteCount(normalized);
        return normalized;
    }

    private static void ValidatePreSharedKey(ReadOnlySpan<byte> pinPreSharedKey)
    {
        if (pinPreSharedKey.Length != PreSharedKeyBytes)
        {
            throw new ArgumentException(
                $"The pairing PIN key must contain exactly {PreSharedKeyBytes} bytes.",
                nameof(pinPreSharedKey));
        }
    }
}
