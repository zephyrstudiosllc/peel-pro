using Peel.Windows.Host.Capture;
using Peel.Windows.Host.Encoding;
using Peel.Windows.Protocol;

namespace Peel.Windows.Host.Networking;

internal sealed class HostVideoPacketWriter : IDisposable
{
    private const uint TimestampTimescale = 10_000_000;

    private readonly PeelPskConnection connection;
    private readonly HostVideoBinding binding;
    private readonly HostVideoSessionOptions options;
    private readonly Func<bool> isCurrentGeneration;
    private readonly SemaphoreSlim writeGate = new(1, 1);
    private VideoEncoderConfiguration? configuration;
    private long lastTimestamp = -1;
    private bool disposed;

    internal HostVideoPacketWriter(
        PeelPskConnection connection,
        HostVideoBinding binding,
        HostVideoSessionOptions options,
        Func<bool> isCurrentGeneration)
    {
        this.connection = connection;
        this.binding = binding;
        this.options = options;
        this.isCurrentGeneration = isCurrentGeneration;
    }

    internal async ValueTask SendEncodedFrameAsync(
        EncodedVideoFrame frame,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(frame);
        ObjectDisposedException.ThrowIf(disposed, this);

        ValidateFrame(frame);
        byte[]? configBytes = null;
        VideoEncoderConfiguration? pendingConfiguration = null;
        if (frame.Configuration is not null)
        {
            if (!frame.IsKeyFrame)
            {
                throw new InvalidDataException(
                    "An encoder configuration must accompany a keyframe.");
            }

            VideoConfigPacket configPacket = CreateConfigPacket(frame.Configuration);
            configBytes = configPacket.Encode();
            EnsurePacketBound(configBytes.Length);
            pendingConfiguration = frame.Configuration;
        }
        else if (configuration is null)
        {
            throw new InvalidDataException(
                "The video stream must begin with a configured keyframe.");
        }

        byte[] payload = frame.Bytes.ToArray();
        byte[] frameBytes = new VideoFramePacket(
            binding.WindowId,
            frame.IsKeyFrame,
            frame.Timestamp100Nanoseconds,
            frame.Duration100Nanoseconds,
            payload).Encode();
        EnsurePacketBound(frameBytes.Length);

        await writeGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (!isCurrentGeneration())
            {
                throw new OperationCanceledException(
                    "The video connection is no longer current.",
                    cancellationToken);
            }

            if (configBytes is not null)
            {
                await connection.Stream.WriteAsync(configBytes, cancellationToken)
                    .ConfigureAwait(false);
                EnsureCurrent(cancellationToken);
            }

            EnsureCurrent(cancellationToken);
            await connection.Stream.WriteAsync(frameBytes, cancellationToken)
                .ConfigureAwait(false);
            EnsureCurrent(cancellationToken);
            await connection.Stream.FlushAsync(cancellationToken).ConfigureAwait(false);
            if (pendingConfiguration is not null)
            {
                configuration = pendingConfiguration;
            }
            lastTimestamp = frame.Timestamp100Nanoseconds;
        }
        finally
        {
            writeGate.Release();
        }
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        writeGate.Dispose();
    }

    private void ValidateFrame(EncodedVideoFrame frame)
    {
        if (frame.Codec != options.EncodingSettings.Codec ||
            frame.Bytes.IsEmpty ||
            frame.Timestamp100Nanoseconds < 0 ||
            frame.Timestamp100Nanoseconds <= lastTimestamp ||
            frame.Duration100Nanoseconds < 0)
        {
            throw new InvalidDataException("The encoded video frame metadata is invalid.");
        }

        try
        {
            _ = checked(frame.Timestamp100Nanoseconds + frame.Duration100Nanoseconds);
        }
        catch (OverflowException exception)
        {
            throw new InvalidDataException("The encoded frame timestamp range overflowed.", exception);
        }

        if (frame.Bytes.Length > options.MaximumEncodedPacketBytes - VideoFramePacket.HeaderLength)
        {
            throw new InvalidDataException("The encoded video frame exceeds the configured packet limit.");
        }
    }

    private VideoConfigPacket CreateConfigPacket(VideoEncoderConfiguration candidate)
    {
        if (candidate.Codec != options.EncodingSettings.Codec ||
            candidate.Width <= 0 ||
            candidate.Width > CaptureFrameLayout.MaximumD3D11TextureDimension ||
            candidate.Height <= 0 ||
            candidate.Height > CaptureFrameLayout.MaximumD3D11TextureDimension ||
            candidate.Timescale != TimestampTimescale ||
            candidate.NalUnitHeaderLength is not (1 or 2 or 4))
        {
            throw new InvalidDataException("The encoder configuration metadata is invalid.");
        }

        ValidateParameterSet(candidate.SequenceParameterSet, "SPS");
        ValidateParameterSet(candidate.PictureParameterSet, "PPS");
        if (candidate.Codec == VideoCodec.Hevc)
        {
            ValidateParameterSet(candidate.VideoParameterSet, "VPS");
        }
        else if (!candidate.VideoParameterSet.IsEmpty)
        {
            throw new InvalidDataException("An H.264 configuration cannot carry a VPS.");
        }

        long encodedLength =
            (candidate.Codec == VideoCodec.Hevc ? 31L : 27L) +
            candidate.SequenceParameterSet.Length +
            candidate.PictureParameterSet.Length +
            candidate.VideoParameterSet.Length;
        if (encodedLength > options.MaximumEncodedPacketBytes)
        {
            throw new InvalidDataException(
                "The encoder configuration exceeds the configured packet limit.");
        }

        return new VideoConfigPacket(
            binding.WindowId,
            ToProtocolCodec(candidate.Codec),
            checked((uint)candidate.Width),
            checked((uint)candidate.Height),
            candidate.Timescale,
            candidate.NalUnitHeaderLength,
            candidate.SequenceParameterSet.ToArray(),
            candidate.PictureParameterSet.ToArray(),
            candidate.Codec == VideoCodec.Hevc
                ? candidate.VideoParameterSet.ToArray()
                : null);
    }

    private void ValidateParameterSet(ReadOnlyMemory<byte> bytes, string name)
    {
        if (bytes.IsEmpty || bytes.Length > options.MaximumParameterSetBytes)
        {
            throw new InvalidDataException($"The encoder {name} is empty or oversized.");
        }
    }

    private void EnsurePacketBound(int byteCount)
    {
        if (byteCount > options.MaximumEncodedPacketBytes)
        {
            throw new InvalidDataException("The encoded video packet exceeds the configured limit.");
        }
    }

    private void EnsureCurrent(CancellationToken cancellationToken)
    {
        if (!isCurrentGeneration())
        {
            throw new OperationCanceledException(
                "The video connection is no longer current.",
                cancellationToken);
        }
    }

    private static PeelVideoCodec ToProtocolCodec(VideoCodec codec) => codec switch
    {
        VideoCodec.H264 => PeelVideoCodec.H264,
        VideoCodec.Hevc => PeelVideoCodec.Hevc,
        _ => throw new InvalidDataException("The encoder returned an unsupported codec."),
    };
}
