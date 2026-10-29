using Peel.Windows.Client.Models;
using Peel.Windows.Protocol;

namespace Peel.Windows.Client.Services;

public sealed class PairedHostCredential
{
    private readonly byte[] _preSharedKey;

    public PairedHostCredential(string stableHostId, string pairingId, ReadOnlySpan<byte> preSharedKey)
    {
        if (string.IsNullOrWhiteSpace(stableHostId))
        {
            throw new ArgumentException("A stable host ID is required.", nameof(stableHostId));
        }

        if (string.IsNullOrWhiteSpace(pairingId))
        {
            throw new ArgumentException("A TLS pairing ID is required.", nameof(pairingId));
        }

        if (preSharedKey.Length != 32)
        {
            throw new ArgumentException("Peel TLS-PSK credentials require exactly 32 key bytes.", nameof(preSharedKey));
        }

        StableHostId = stableHostId;
        PairingId = pairingId;
        _preSharedKey = preSharedKey.ToArray();
    }

    public string StableHostId { get; }

    public string PairingId { get; }

    public byte[] CopyPreSharedKey() => _preSharedKey.ToArray();
}

public interface IPairedHostCredentialStore
{
    ValueTask<PairedHostCredential?> GetForHostAsync(
        string stableHostId,
        CancellationToken cancellationToken);
}

public interface IClientHostResolver
{
    ValueTask<HostCandidate?> ResolveFreshAsync(
        string stableHostId,
        CancellationToken cancellationToken);
}

public sealed record NegotiatedClientHost(
    string StableHostId,
    int? ProtocolVersion,
    int? MinimumSupportedProtocolVersion,
    IReadOnlySet<string> Capabilities);

public interface IClientStreamControlChannel
{
    NegotiatedClientHost? NegotiatedHost { get; }

    Task SendStartStreamAsync(uint windowId, CancellationToken cancellationToken);

    Task SendStopStreamAsync(uint windowId, CancellationToken cancellationToken);
}

public sealed record ClientHelloProfile(
    string DeviceName,
    string DeviceModel,
    string OsVersion,
    string AppVersion)
{
    public void Validate()
    {
        if (string.IsNullOrWhiteSpace(DeviceName)
            || string.IsNullOrWhiteSpace(DeviceModel)
            || string.IsNullOrWhiteSpace(OsVersion)
            || string.IsNullOrWhiteSpace(AppVersion))
        {
            throw new InvalidOperationException("A complete Windows client identity is required.");
        }
    }
}

public sealed record ClientSessionOptions
{
    public bool SupportsHevc { get; init; }
    public bool SupportsAudioPlayback { get; init; }
    public bool SupportsMicrophone { get; init; }
    public static ClientSessionOptions Default { get; } = new();

    public int MaximumControlLineBytes { get; init; } = 64 * 1024;

    public int MaximumWindowCount { get; init; } = 4096;

    public int MaximumWindowDimension { get; init; } = 100_000;

    public TimeSpan HostHelloTimeout { get; init; } = TimeSpan.FromSeconds(5);

    public TimeSpan PingInterval { get; init; } = TimeSpan.FromSeconds(4);

    public void Validate()
    {
        if (MaximumControlLineBytes < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(MaximumControlLineBytes));
        }

        if (MaximumWindowCount < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(MaximumWindowCount));
        }

        if (MaximumWindowDimension < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(MaximumWindowDimension));
        }

        if (HostHelloTimeout <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(HostHelloTimeout));
        }

        if (PingInterval <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(PingInterval));
        }
    }
}
