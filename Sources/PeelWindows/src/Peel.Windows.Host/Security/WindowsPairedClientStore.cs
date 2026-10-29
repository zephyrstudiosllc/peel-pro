using System.ComponentModel;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Peel.Windows.Protocol;

namespace Peel.Windows.Host.Security;

public sealed record HostPairedClient(
    string PairingId,
    string DisplayName,
    string DeviceId,
    DateTimeOffset CreatedAt,
    DateTimeOffset? LastSeenAt = null,
    string? LocalDeviceId = null);

internal interface IHostPairedClientMetadataRepository
{
    IReadOnlyList<HostPairedClient> Load();

    void Save(IReadOnlyList<HostPairedClient> pairedClients);
}

public sealed class WindowsPairedClientStore : IPeelPskCredentialResolver
{
    public const string DefaultCredentialTargetPrefix = "ZephyrStudios.Peel.Host.PSK";
    public const int PreSharedKeyBytes = 32;

    private const int MaximumPairingIdentityBytes = 1024;
    private const int MaximumDisplayNameCodeUnits = 256;
    private const int MaximumDeviceIdCodeUnits = 1024;
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    private readonly object stateLock = new();
    private readonly ICurrentUserCredentialVault credentialVault;
    private readonly IHostPairedClientMetadataRepository metadataRepository;
    private readonly string credentialTargetPrefix;
    private IReadOnlyList<HostPairedClient> pairedClients;
    private string? loadError;
    private string? lastCredentialError;

    public WindowsPairedClientStore(string? metadataFilePath = null)
        : this(
            new WindowsCredentialManager(),
            new JsonHostPairedClientMetadataRepository(
                metadataFilePath ?? DefaultMetadataFilePath()),
            DefaultCredentialTargetPrefix)
    {
    }

    internal WindowsPairedClientStore(
        ICurrentUserCredentialVault credentialVault,
        IHostPairedClientMetadataRepository metadataRepository,
        string credentialTargetPrefix)
    {
        this.credentialVault = credentialVault ??
            throw new ArgumentNullException(nameof(credentialVault));
        this.metadataRepository = metadataRepository ??
            throw new ArgumentNullException(nameof(metadataRepository));
        this.credentialTargetPrefix = NormalizeTargetPrefix(credentialTargetPrefix);

        try
        {
            IReadOnlyList<HostPairedClient> loaded = metadataRepository.Load();
            ValidateSnapshot(loaded);
            pairedClients = loaded
                .OrderBy(static peer => peer.DisplayName, StringComparer.OrdinalIgnoreCase)
                .ThenBy(static peer => peer.PairingId, StringComparer.Ordinal)
                .ToArray();
        }
        catch (Exception exception) when (
            exception is IOException or
                UnauthorizedAccessException or
                JsonException or
                InvalidDataException or
                ArgumentException)
        {
            pairedClients = [];
            loadError =
                "Paired-client metadata could not be loaded, so all stored clients are rejected.";
        }
    }

    public string? LoadError
    {
        get
        {
            lock (stateLock)
            {
                return loadError;
            }
        }
    }

    public string? LastCredentialError
    {
        get
        {
            lock (stateLock)
            {
                return lastCredentialError;
            }
        }
    }

    public IReadOnlyList<HostPairedClient> Snapshot()
    {
        lock (stateLock)
        {
            return pairedClients.ToArray();
        }
    }

    public HostPairedClient AddOrReplace(
        string pairingId,
        string displayName,
        string deviceId,
        ReadOnlySpan<byte> preSharedKey,
        DateTimeOffset? createdAt = null,
        string? localDeviceId = null)
    {
        string normalizedPairingId = NormalizePairingId(pairingId);
        string normalizedDisplayName = NormalizeBoundedText(
            displayName,
            nameof(displayName),
            MaximumDisplayNameCodeUnits);
        string normalizedDeviceId = NormalizeBoundedText(
            deviceId,
            nameof(deviceId),
            MaximumDeviceIdCodeUnits);
        if (preSharedKey.Length != PreSharedKeyBytes)
        {
            throw new ArgumentException(
                $"Peel TLS-PSK credentials require exactly {PreSharedKeyBytes} key bytes.",
                nameof(preSharedKey));
        }

        if (localDeviceId is not null && !Guid.TryParseExact(localDeviceId, "D", out _))
            throw new ArgumentException("The local pairing device identity must be a UUID.", nameof(localDeviceId));
        var peer = new HostPairedClient(
            normalizedPairingId,
            normalizedDisplayName,
            normalizedDeviceId,
            createdAt ?? DateTimeOffset.UtcNow,
            DateTimeOffset.UtcNow,
            localDeviceId);

        lock (stateLock)
        {
            if (pairedClients.Any(existing =>
                    StringComparer.Ordinal.Equals(existing.PairingId, normalizedPairingId)))
            {
                throw new InvalidOperationException(
                    "The pairing identity is already present; generate a new identity when re-pairing.");
            }

            HostPairedClient[] replaced = pairedClients
                .Where(existing => StringComparer.Ordinal.Equals(
                    existing.DeviceId,
                    normalizedDeviceId))
                .ToArray();
            HostPairedClient[] updated = pairedClients
                .Where(existing => !StringComparer.Ordinal.Equals(
                    existing.DeviceId,
                    normalizedDeviceId))
                .Append(peer)
                .OrderBy(static existing => existing.DisplayName, StringComparer.OrdinalIgnoreCase)
                .ThenBy(static existing => existing.PairingId, StringComparer.Ordinal)
                .ToArray();

            string targetName = CredentialTarget(normalizedPairingId);
            credentialVault.Write(targetName, preSharedKey);
            try
            {
                metadataRepository.Save(updated);
            }
            catch
            {
                TryDeleteCredential(targetName);
                throw;
            }

            pairedClients = updated;
            loadError = null;
            lastCredentialError = null;
            foreach (HostPairedClient previous in replaced)
            {
                TryDeleteCredential(CredentialTarget(previous.PairingId));
            }
        }

        return peer;
    }

    public bool Remove(string pairingId)
    {
        string normalizedPairingId = NormalizePairingId(pairingId);
        lock (stateLock)
        {
            HostPairedClient[] updated = pairedClients
                .Where(peer => !StringComparer.Ordinal.Equals(
                    peer.PairingId,
                    normalizedPairingId))
                .ToArray();
            if (updated.Length == pairedClients.Count)
            {
                return false;
            }

            metadataRepository.Save(updated);
            pairedClients = updated;
            loadError = null;
            lastCredentialError = null;
            TryDeleteCredential(CredentialTarget(normalizedPairingId));
            return true;
        }
    }

    public bool UpdateLastSeen(string pairingId, DateTimeOffset? timestamp = null)
    {
        string normalizedPairingId = NormalizePairingId(pairingId);
        lock (stateLock)
        {
            var found = false;
            HostPairedClient[] updated = pairedClients
                .Select(peer =>
                {
                    if (!StringComparer.Ordinal.Equals(peer.PairingId, normalizedPairingId))
                    {
                        return peer;
                    }

                    found = true;
                    return peer with { LastSeenAt = timestamp ?? DateTimeOffset.UtcNow };
                })
                .ToArray();
            if (!found)
            {
                return false;
            }

            metadataRepository.Save(updated);
            pairedClients = updated;
            loadError = null;
            return true;
        }
    }

    public bool TryResolve(string identity, out PeelPskCredential? credential)
    {
        credential = null;
        string normalizedIdentity;
        try
        {
            normalizedIdentity = NormalizePairingId(identity);
        }
        catch (ArgumentException)
        {
            return false;
        }

        lock (stateLock)
        {
            if (!StringComparer.Ordinal.Equals(identity, normalizedIdentity) ||
                !pairedClients.Any(peer => StringComparer.Ordinal.Equals(
                    peer.PairingId,
                    normalizedIdentity)))
            {
                return false;
            }

            byte[]? secret = null;
            try
            {
                if (!credentialVault.TryRead(CredentialTarget(normalizedIdentity), out secret) ||
                    secret is not { Length: PreSharedKeyBytes })
                {
                    lastCredentialError =
                        "The paired client has no valid 32-byte secret in Windows Credential Manager.";
                    return false;
                }

                credential = new PeelPskCredential(normalizedIdentity, secret);
                lastCredentialError = null;
                return true;
            }
            catch (Exception exception) when (
                exception is Win32Exception or
                    PlatformNotSupportedException or
                    InvalidOperationException)
            {
                lastCredentialError =
                    "Windows Credential Manager could not resolve the paired-client secret.";
                return false;
            }
            finally
            {
                if (secret is not null)
                {
                    CryptographicOperations.ZeroMemory(secret);
                }
            }
        }
    }

    private void TryDeleteCredential(string targetName)
    {
        try
        {
            _ = credentialVault.Delete(targetName);
        }
        catch (Exception exception) when (
            exception is Win32Exception or
                PlatformNotSupportedException or
                InvalidOperationException)
        {
            lastCredentialError =
                "Windows Credential Manager could not remove an obsolete Peel secret.";
        }
    }

    private string CredentialTarget(string pairingId) =>
        CredentialTarget(credentialTargetPrefix, pairingId);

    internal static string CredentialTarget(string targetPrefix, string pairingId)
    {
        byte[] identityBytes = StrictUtf8.GetBytes(NormalizePairingId(pairingId));
        byte[] digest = SHA256.HashData(identityBytes);
        return $"{NormalizeTargetPrefix(targetPrefix)}/{Convert.ToHexString(digest)}";
    }

    private static string DefaultMetadataFilePath() =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Zephyr Studios",
            "Peel",
            "Host",
            "paired-clients.json");

    private static string NormalizeTargetPrefix(string value) =>
        NormalizeBoundedText(value, nameof(value), 512);

    private static string NormalizePairingId(string value)
    {
        string normalized = NormalizeBoundedText(value, nameof(value), 1024);
        int byteCount;
        try
        {
            byteCount = StrictUtf8.GetByteCount(normalized);
        }
        catch (EncoderFallbackException exception)
        {
            throw new ArgumentException(
                "The pairing identity is not valid UTF-8 text.",
                nameof(value),
                exception);
        }

        if (byteCount > MaximumPairingIdentityBytes)
        {
            throw new ArgumentException(
                $"The pairing identity exceeds {MaximumPairingIdentityBytes} UTF-8 bytes.",
                nameof(value));
        }

        return normalized;
    }

    private static string NormalizeBoundedText(
        string value,
        string parameterName,
        int maximumCodeUnits)
    {
        if (value is null)
        {
            throw new ArgumentNullException(parameterName);
        }

        string normalized = value.Trim();
        if (normalized.Length is 0 ||
            normalized.Length > maximumCodeUnits ||
            normalized.IndexOf('\0') >= 0)
        {
            throw new ArgumentException(
                $"A non-empty value of at most {maximumCodeUnits} UTF-16 code units is required.",
                parameterName);
        }

        return normalized;
    }

    private static void ValidateSnapshot(IReadOnlyList<HostPairedClient> snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        var pairingIds = new HashSet<string>(StringComparer.Ordinal);
        var deviceIds = new HashSet<string>(StringComparer.Ordinal);
        foreach (HostPairedClient peer in snapshot)
        {
            string pairingId = NormalizePairingId(peer.PairingId);
            string displayName = NormalizeBoundedText(
                peer.DisplayName,
                nameof(peer.DisplayName),
                MaximumDisplayNameCodeUnits);
            string deviceId = NormalizeBoundedText(
                peer.DeviceId,
                nameof(peer.DeviceId),
                MaximumDeviceIdCodeUnits);
            if (!StringComparer.Ordinal.Equals(pairingId, peer.PairingId) ||
                !StringComparer.Ordinal.Equals(displayName, peer.DisplayName) ||
                !StringComparer.Ordinal.Equals(deviceId, peer.DeviceId) ||
                !pairingIds.Add(pairingId) ||
                !deviceIds.Add(deviceId) ||
                peer.LocalDeviceId is not null && !Guid.TryParseExact(peer.LocalDeviceId, "D", out _))
            {
                throw new InvalidDataException(
                    "Paired-client metadata contains a duplicate or non-canonical identity.");
            }
        }
    }
}

internal sealed class JsonHostPairedClientMetadataRepository(string filePath) :
    IHostPairedClientMetadataRepository
{
    private const int MaximumMetadataBytes = 1024 * 1024;
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
    };

    private readonly string filePath = string.IsNullOrWhiteSpace(filePath)
        ? throw new ArgumentException("A metadata file path is required.", nameof(filePath))
        : Path.GetFullPath(filePath);

    public IReadOnlyList<HostPairedClient> Load()
    {
        if (!File.Exists(filePath))
        {
            return [];
        }

        var info = new FileInfo(filePath);
        if (info.Length is < 0 or > MaximumMetadataBytes)
        {
            throw new InvalidDataException("Paired-client metadata is oversized.");
        }

        byte[] data = File.ReadAllBytes(filePath);
        if (data.Length > MaximumMetadataBytes)
        {
            throw new InvalidDataException("Paired-client metadata is oversized.");
        }

        return JsonSerializer.Deserialize<List<HostPairedClient>>(data, JsonOptions) ?? [];
    }

    public void Save(IReadOnlyList<HostPairedClient> pairedClients)
    {
        ArgumentNullException.ThrowIfNull(pairedClients);
        byte[] data = JsonSerializer.SerializeToUtf8Bytes(pairedClients, JsonOptions);
        if (data.Length > MaximumMetadataBytes)
        {
            throw new InvalidDataException("Paired-client metadata is oversized.");
        }

        string? directory = Path.GetDirectoryName(filePath);
        if (string.IsNullOrEmpty(directory))
        {
            throw new InvalidOperationException("The paired-client metadata path has no directory.");
        }

        Directory.CreateDirectory(directory);
        string temporaryPath = Path.Combine(directory, $".{Path.GetFileName(filePath)}.{Guid.NewGuid():N}.tmp");
        try
        {
            using (var stream = new FileStream(
                temporaryPath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None))
            {
                stream.Write(data);
                stream.Flush(flushToDisk: true);
            }

            File.Move(temporaryPath, filePath, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }
}
