using Peel.Windows.Host.Capture;
using Peel.Windows.Host.Encoding;
using Peel.Windows.Protocol;

namespace Peel.Windows.Host.Networking;

public sealed record HostVideoSessionOptions
{
    public const int DefaultMaximumHelloLineBytes = 16 * 1024;
    public const int MaximumHelloLineBytesLimit = 1024 * 1024;
    public const int DefaultMaximumEncodedPacketBytes = 16 * 1024 * 1024;
    public const int DefaultMaximumParameterSetBytes = 1024 * 1024;

    public HostVideoSessionOptions(
        VideoEncodingSettings encodingSettings,
        int maximumHelloLineBytes = DefaultMaximumHelloLineBytes,
        int maximumEncodedPacketBytes = DefaultMaximumEncodedPacketBytes,
        int maximumParameterSetBytes = DefaultMaximumParameterSetBytes,
        bool enableHevc = false)
    {
        ArgumentNullException.ThrowIfNull(encodingSettings);
        if (!Enum.IsDefined(encodingSettings.Codec) ||
            encodingSettings.Width <= 0 ||
            encodingSettings.Width > CaptureFrameLayout.MaximumD3D11TextureDimension ||
            encodingSettings.Height <= 0 ||
            encodingSettings.Height > CaptureFrameLayout.MaximumD3D11TextureDimension ||
            encodingSettings.FramesPerSecond <= 0 ||
            encodingSettings.FramesPerSecond > 240 ||
            encodingSettings.TargetBitrate <= 0)
        {
            throw new ArgumentException("The video encoding settings are invalid.", nameof(encodingSettings));
        }

        if (maximumHelloLineBytes <= 0 ||
            maximumHelloLineBytes > MaximumHelloLineBytesLimit)
        {
            throw new ArgumentOutOfRangeException(nameof(maximumHelloLineBytes));
        }

        if (maximumEncodedPacketBytes < VideoFramePacket.HeaderLength ||
            maximumEncodedPacketBytes > PeelBinaryFraming.DefaultMaximumPacketBytes)
        {
            throw new ArgumentOutOfRangeException(nameof(maximumEncodedPacketBytes));
        }

        if (maximumParameterSetBytes <= 0 ||
            maximumParameterSetBytes > maximumEncodedPacketBytes)
        {
            throw new ArgumentOutOfRangeException(nameof(maximumParameterSetBytes));
        }

        EncodingSettings = encodingSettings;
        EnableHevc = enableHevc;
        MaximumHelloLineBytes = maximumHelloLineBytes;
        MaximumEncodedPacketBytes = maximumEncodedPacketBytes;
        MaximumParameterSetBytes = maximumParameterSetBytes;
    }

    public VideoEncodingSettings EncodingSettings { get; }
    public bool EnableHevc { get; }

    internal HostVideoSessionOptions Negotiate(IReadOnlyList<string>? capabilities)
    {
        var settings = EnableHevc && capabilities?.Contains(PeelCapability.HevcVideo) == true
            ? EncodingSettings with { Codec = VideoCodec.Hevc } : EncodingSettings;
        return new(settings, MaximumHelloLineBytes, MaximumEncodedPacketBytes, MaximumParameterSetBytes);
    }

    public int MaximumHelloLineBytes { get; }

    public int MaximumEncodedPacketBytes { get; }

    public int MaximumParameterSetBytes { get; }

    internal IReadOnlySet<string> RequiredVideoCapabilities { get; } =
        new HashSet<string>(StringComparer.Ordinal)
        {
            PeelCapability.PerWindowVideoConnections,
            PeelCapability.BinaryVideoTransportV2,
        };

    internal string CodecCapability => EncodingSettings.Codec switch
    {
        VideoCodec.H264 => PeelCapability.H264Video,
        VideoCodec.Hevc => PeelCapability.HevcVideo,
        _ => throw new InvalidOperationException("Unsupported configured video codec."),
    };
}
