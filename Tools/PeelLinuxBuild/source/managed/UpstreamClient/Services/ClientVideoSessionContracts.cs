using Peel.Windows.Protocol;

namespace Peel.Windows.Client.Services;

public enum ClientVideoSocketState
{
    Stopped,
    Connecting,
    WaitingForConfiguration,
    WaitingForKeyframe,
    Streaming,
    Error,
}

public sealed class ClientVideoSocketStateChangedEventArgs : EventArgs
{
    public ClientVideoSocketStateChangedEventArgs(ClientVideoSocketState state, string? detail = null)
    {
        State = state;
        Detail = detail;
    }

    public ClientVideoSocketState State { get; }

    public string? Detail { get; }
}

public sealed record NegotiatedVideoStreamRequest(
    string StableHostId,
    uint WindowId,
    PeelVideoCodec Codec,
    int? RemoteProtocolVersion,
    int? RemoteMinimumSupportedProtocolVersion,
    IReadOnlySet<string> RemoteCapabilities);

/// A native decoder owns codec configuration and encoded-frame submission behind
/// this boundary. The socket session never fabricates decoded pixels or frames.
public interface IVideoDecoderSink
{
    event EventHandler<DecodedVideoFrameEventArgs>? FrameDecoded;

    IReadOnlySet<PeelVideoCodec> SupportedCodecs { get; }

    ValueTask ResetAsync(uint windowId, CancellationToken cancellationToken);

    ValueTask ConfigureAsync(VideoConfigPacket configuration, CancellationToken cancellationToken);

    ValueTask SubmitAsync(VideoFramePacket frame, CancellationToken cancellationToken);
}

public sealed record ClientVideoSocketOptions
{
    public static ClientVideoSocketOptions Default { get; } = new();

    public int MaximumPacketBytes { get; init; } = PeelBinaryFraming.DefaultMaximumPacketBytes;

    public uint MaximumDimension { get; init; } = 16_384;

    public void Validate()
    {
        if (MaximumPacketBytes < VideoFramePacket.HeaderLength)
        {
            throw new ArgumentOutOfRangeException(nameof(MaximumPacketBytes));
        }

        if (MaximumDimension < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(MaximumDimension));
        }
    }
}
