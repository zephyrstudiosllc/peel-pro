using Peel.Windows.Host.Capture;

namespace Peel.Windows.Host.Encoding;

public interface IVideoEncoderFactory
{
    ValueTask<IVideoEncoder> CreateAsync(
        VideoEncodingSettings settings,
        CancellationToken cancellationToken);
}

public interface IVideoEncoder : IAsyncDisposable
{
    ValueTask<EncodedVideoFrame?> EncodeAsync(
        CapturedFrame frame,
        CancellationToken cancellationToken);
}

public sealed record VideoEncodingSettings(
    VideoCodec Codec,
    int Width,
    int Height,
    int FramesPerSecond,
    int TargetBitrate,
    bool UseHardware = false)
{
    internal nint GpuDevice { get; init; }
}

public sealed record EncodedVideoFrame(
    VideoCodec Codec,
    long Timestamp100Nanoseconds,
    bool IsKeyFrame,
    ReadOnlyMemory<byte> Bytes,
    long Duration100Nanoseconds = 0,
    VideoEncoderConfiguration? Configuration = null);

public sealed record VideoEncoderConfiguration(
    VideoCodec Codec,
    int Width,
    int Height,
    uint Timescale,
    byte NalUnitHeaderLength,
    ReadOnlyMemory<byte> SequenceParameterSet,
    ReadOnlyMemory<byte> PictureParameterSet,
    ReadOnlyMemory<byte> VideoParameterSet = default);

public enum VideoCodec
{
    H264,
    Hevc,
}
