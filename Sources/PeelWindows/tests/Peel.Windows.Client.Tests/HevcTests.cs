using Peel.Windows.Client.Services;
using Peel.Windows.Host.Capture;
using Peel.Windows.Host.Encoding;
using Peel.Windows.Protocol;

namespace Peel.Windows.Client.Tests;

internal static partial class Program
{
    private static void HevcFramingIsBounded()
    {
        var config = new VideoConfigPacket(3, PeelVideoCodec.Hevc, 5120, 2880, 10_000_000, 4,
            [0x42, 1, 1], [0x44, 1, 1], [0x40, 1, 1]);
        byte[] header = H264LengthPrefixed.CreateSequenceHeader(config);
        Equal(21, header.Length);
        var frame = new VideoFramePacket(3, true, 0, 83333, [0, 0, 0, 3, 0x26, 1, 1]);
        Equal(28, H264LengthPrefixed.ConvertFrame(config, frame).Length);
        Throws<InvalidDataException>(() => H264LengthPrefixed.CreateSequenceHeader(config with { Vps = [0x42, 1] }));
        Throws<InvalidDataException>(() => H264LengthPrefixed.ConvertFrame(config, frame with { Payload = [255, 255, 255, 255] }));
        Throws<InvalidDataException>(() => H264LengthPrefixed.ConvertFrame(config, frame with { Payload = [0, 0] }));
        var encoded = HevcAnnexB.Convert([0,0,1,0x40,1,1, 0,0,1,0x42,1,1, 0,0,1,0x44,1,1, 0,0,1,0x26,1,1]);
        True(encoded.Keyframe && encoded.Vps is not null && encoded.Sps is not null && encoded.Pps is not null, "HEVC parameter sets and IRAP must survive packetization.");
    }

    private static async Task<int> NativeHevcRoundTripAsync(int width = 64, int height = 64, bool hardware = false, bool preferHardwareDecode = true, bool gpuInput = false)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(45));
        await using var decoder = new MediaFoundationH264DecoderSink(preferHardwareDecode);
        True(decoder.SupportedCodecs.Contains(PeelVideoCodec.Hevc), "Installed HEVC decoder must activate.");
        using var device = gpuInput ? D3D11VideoDevice.Create() : null;
        using var convert = device is null ? null : new D3D11Nv12Converter(device.Device, device.Context, width, height);
        await using var encoder = await new MediaFoundationH264EncoderFactory().CreateAsync(new(VideoCodec.Hevc, width, height, 120, 20_000_000, hardware) { GpuDevice = device?.Device ?? 0 }, timeout.Token);
        int decoded = 0, encodedCount = 0, gpu = 0;
        var watch = System.Diagnostics.Stopwatch.StartNew();
        decoder.FrameDecoded += (_, e) =>
        {
            Equal(width, e.Frame.PixelWidth); Equal(height, e.Frame.PixelHeight);
            if (e.Frame.HasGpuSurface) gpu++;
            Interlocked.Increment(ref decoded);
        };
        for (int i = 0; i < 12; i++)
        {
            byte[] input = CreateNativeDecodeInput(width, height, i);
            using var frame = convert is null ? new CapturedFrame(width, height, width * 4, (i + 1) * 83333L, CapturePixelFormat.Bgra8, input)
                : new CapturedFrame(width, height, width, (i + 1) * 83333L, CapturePixelFormat.Nv12, ReadOnlyMemory<byte>.Empty) { GpuSurface = convert.ConvertBgraToSurface(input, width * 4) };
            var encoding = encoder.EncodeAsync(frame, timeout.Token);
            // The caller can release capture ownership before the worker reaches ProcessInput.
            frame.Dispose();
            var output = await encoding;
            if (output is null) continue;
            encodedCount++;
            if (output.Configuration is { } c)
                await decoder.ConfigureAsync(new(9, PeelVideoCodec.Hevc, (uint)width, (uint)height, c.Timescale, c.NalUnitHeaderLength,
                    c.SequenceParameterSet.ToArray(), c.PictureParameterSet.ToArray(), c.VideoParameterSet.ToArray()), timeout.Token);
            await decoder.SubmitAsync(new(9, output.IsKeyFrame, output.Timestamp100Nanoseconds, output.Duration100Nanoseconds, output.Bytes.ToArray()), timeout.Token);
        }
        True(decoded > 0, "Native HEVC must produce actual decoded pixels.");
        if (preferHardwareDecode && width == 5120) True(gpu > 0, "5K native fixture must exercise actual DXGI output surfaces on this PC.");
        if (!preferHardwareDecode) Equal(0, gpu);
        Console.WriteLine($"PASS native HEVC round-trip {width}x{height}: {encodedCount} encoded/{decoded} decoded ({gpu} GPU surfaces) in {watch.Elapsed.TotalSeconds:F2}s; hardwareEncode={hardware}; gpuInput={gpuInput}; target=120 fps (not a sustained throughput result).");
        return 0;
    }
}
