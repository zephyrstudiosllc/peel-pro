using Peel.Windows.Protocol;

namespace Peel.Windows.Host.Networking;

public sealed class HostControlSessionOptions
{
    public Peel.Windows.Host.Audio.HostAudioSharing? AudioSharing { get; init; }
    public IPeelPskCredentialResolver? AudioCredentials { get; init; }
    public IHostMachineStatusProvider? MachineStatusProvider { get; init; }
    public IPeelPskCredentialResolver? MachineStatusCredentials { get; init; }
    /// <summary>The source systemOutput volume backend; null means no source volume is offered.</summary>
    internal Peel.Windows.Host.Audio.ISourceSystemVolume? SourceVolume { get; init; }
    public const int DefaultMaximumFirstLineBytes = 16 * 1024;
    public const int DefaultMaximumControlLineBytes = 64 * 1024;

    public HostControlSessionOptions(
        string hostName,
        string? operatingSystemVersion = null,
        string? appVersion = null,
        int maximumFirstLineBytes = DefaultMaximumFirstLineBytes,
        int maximumControlLineBytes = DefaultMaximumControlLineBytes,
        IEnumerable<string>? capabilities = null)
    {
        if (string.IsNullOrWhiteSpace(hostName))
        {
            throw new ArgumentException("A non-empty Host name is required.", nameof(hostName));
        }

        if (maximumFirstLineBytes < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(maximumFirstLineBytes));
        }

        if (maximumControlLineBytes < maximumFirstLineBytes)
        {
            throw new ArgumentOutOfRangeException(
                nameof(maximumControlLineBytes),
                "The control-line limit cannot be smaller than the first-line limit.");
        }

        HostName = hostName;
        OperatingSystemVersion = operatingSystemVersion;
        AppVersion = appVersion;
        MaximumFirstLineBytes = maximumFirstLineBytes;
        MaximumControlLineBytes = maximumControlLineBytes;
        Capabilities = PeelHello.SortedCapabilities(
            capabilities ??
            [
                PeelCapability.H264Video,
                PeelCapability.PerWindowVideoConnections,
                PeelCapability.BinaryVideoTransportV2,
                PeelCapability.ClientVisibility,
                PeelCapability.ExpandedKeyboard,
                PeelCapability.InputFocus,
            ]);
    }

    public string HostName { get; }

    public string? OperatingSystemVersion { get; }

    public string? AppVersion { get; }

    public int MaximumFirstLineBytes { get; }

    public int MaximumControlLineBytes { get; }

    public IReadOnlyList<string> Capabilities { get; }
}
