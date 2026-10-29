using System.Diagnostics;
using Peel.Windows.Host.Capture;
using Peel.Windows.Host.Encoding;
using Peel.Windows.Client.Services;

namespace Peel.Windows.Client.Tests;

internal static partial class Program
{
    private static async Task<int> GpuOwnershipSmokeAsync()
    {
        MediaFoundationNative.Startup();
        try
        {
            using var device = D3D11VideoDevice.Create();
            using var convert = new D3D11Nv12Converter(device.Device, device.Context, 64, 64);
            CapturedFrame Create() => new(64, 64, 64, 0, CapturePixelFormat.Nv12, ReadOnlyMemory<byte>.Empty)
                { GpuSurface = convert.ConvertBgraToSurface(new byte[64 * 64 * 4], 256) };
            using var queue = new Peel.Windows.Host.Orchestration.LatestRawFrameQueue();
            var first = Create(); var second = Create();
            using var independent = first.GpuSurface!.Retain();
            queue.Publish(first); queue.Publish(second);
            Throws<ObjectDisposedException>(() => _ = first.GpuSurface.Texture);
            True(independent.Texture != 0, "Replacing capture must preserve a separately retained codec reference.");
            queue.Complete();
            int handled = 0;
            await queue.RunAsync((frame, _) => { True(frame.GpuSurface!.Texture != 0, "Handler owns its frame."); handled++; return ValueTask.CompletedTask; }, CancellationToken.None);
            Equal(1, handled);
            Throws<ObjectDisposedException>(() => _ = second.GpuSurface!.Texture);
            var completed = Create(); queue.Publish(completed);
            Throws<ObjectDisposedException>(() => _ = completed.GpuSurface!.Texture);
            queue.Dispose();
            var late = Create(); queue.Publish(late);
            Throws<ObjectDisposedException>(() => _ = late.GpuSurface!.Texture);
            using var cancelledQueue = new Peel.Windows.Host.Orchestration.LatestRawFrameQueue();
            var abandoned = Create(); cancelledQueue.Publish(abandoned);
            using var cancel = new CancellationTokenSource(); cancel.Cancel();
            try { await cancelledQueue.RunAsync((_, _) => ValueTask.CompletedTask, cancel.Token); throw new Exception("Expected cancellation."); }
            catch (OperationCanceledException) { }
            cancelledQueue.Dispose();
            Throws<ObjectDisposedException>(() => _ = abandoned.GpuSurface!.Texture);
            Console.WriteLine("PASS actual GPU texture ownership: replacement, retained codec owner, completed/late publish, cancellation and pending disposal.");
            return 0;
        }
        finally { MediaFoundationNative.Shutdown(); }
    }

    private static int GpuColorConversionSmoke()
    {
        MediaFoundationNative.Startup();
        try
        {
            using var device = D3D11VideoDevice.Create();
            using (var convert = new D3D11Nv12Converter(device.Device, device.Context, 64, 64))
            {
                foreach (var color in new[] { (B:0, G:0, R:0), (B:255, G:255, R:255), (B:0, G:0, R:255), (B:0, G:255, R:0), (B:255, G:0, R:0) })
                {
                    byte[] pixels = new byte[64 * 64 * 4];
                    for (int i = 0; i < pixels.Length; i += 4) { pixels[i] = (byte)color.B; pixels[i+1] = (byte)color.G; pixels[i+2] = (byte)color.R; pixels[i+3] = 255; }
                    var actual = convert.ConvertBgra(pixels, 64 * 4);
                    var expected = BgraToNv12Converter.Convert(new(64, 64, 256, 0, CapturePixelFormat.Bgra8, pixels), false);
                    Equal(expected.Length, actual.Length);
                    foreach (int offset in new[] { 64 * 32 + 32, 64 * 64 + 64 * 16 + 32, 64 * 64 + 64 * 16 + 33 })
                        True(Math.Abs(actual[offset] - expected[offset]) <= 3, $"GPU BT.601 color differs: {actual[offset]} vs {expected[offset]}.");
                }
            }
            using var large = new D3D11Nv12Converter(device.Device, device.Context, 5120, 2880);
            byte[] source = new byte[5120 * 2880 * 4];
            _ = large.ConvertBgra(source, 5120 * 4);
            var watch = Stopwatch.StartNew();
            for (int i = 0; i < 12; i++) Equal(5120 * 2880 * 3 / 2, large.ConvertBgra(source, 5120 * 4).Length);
            Console.WriteLine($"PASS native GPU RGB->NV12: five solid colors match BT.601 within3; 5K upload/convert/readback12frames {watch.Elapsed.TotalSeconds:F2}s (not a capture throughput measurement).");
            return 0;
        }
        finally { MediaFoundationNative.Shutdown(); }
    }
    private static void SimdPixelConversionMatchesScalar()
    {
        var packed = new CapturedFrame(8, 4, 8, 0, CapturePixelFormat.Nv12, new byte[48]);
        True(BgraToNv12Converter.EncoderInput(packed).Equals(packed.Pixels), "Packed GPU capture must not create a second NV12 copy.");
        Throws<InvalidDataException>(() => BgraToNv12Converter.EncoderInput(packed with { BytesPerRow = 10 }));
        Throws<InvalidDataException>(() => BgraToNv12Converter.EncoderInput(packed with { Pixels = new byte[47] }));
        Throws<InvalidDataException>(() => BgraToNv12Converter.EncoderInput(packed with { Height = 3 }));
        var random = new Random(88);
        foreach (int width in new[] { 2, 6, 8, 10, 16, 30, 128, 514 })
        foreach (int height in new[] { 2, 4, 32 })
        foreach (int padding in new[] { 0, 12 })
        {
            int stride = width * 4 + padding;
            var bgra = new byte[(height - 1) * stride + width * 4]; random.NextBytes(bgra);
            var frame = new CapturedFrame(width, height, stride, 0, CapturePixelFormat.Bgra8, bgra);
            SequenceEqual(BgraToNv12Converter.Convert(frame, false), BgraToNv12Converter.Convert(frame));
            var nv12 = new byte[width * height * 3 / 2]; random.NextBytes(nv12);
            SequenceEqual(Nv12ToBgra32Converter.Convert(nv12, width, height, false), Nv12ToBgra32Converter.Convert(nv12, width, height));
        }
    }
    private static int PixelConversionBenchmark()
    {
        const int width = 5120, height = 2880;
        var source = new byte[width * height * 4]; new Random(77).NextBytes(source);
        var frame = new CapturedFrame(width, height, width * 4, 0, CapturePixelFormat.Bgra8, source);
        byte[] nv12 = BgraToNv12Converter.Convert(frame);
        _ = Nv12ToBgra32Converter.Convert(nv12, width, height);
        var encode = new List<double>(); var decode = new List<double>();
        for (int i = 0; i < 12; i++)
        {
            long started = Stopwatch.GetTimestamp(); nv12 = BgraToNv12Converter.Convert(frame);
            encode.Add(Stopwatch.GetElapsedTime(started).TotalMilliseconds);
            started = Stopwatch.GetTimestamp(); _ = Nv12ToBgra32Converter.Convert(nv12, width, height);
            decode.Add(Stopwatch.GetElapsedTime(started).TotalMilliseconds);
        }
        encode.Sort(); decode.Sort();
        Console.WriteLine($"5K conversion median (12 frames, includes allocation): BGRA->NV12 {encode[6]:F2}ms; NV12->BGRA {decode[6]:F2}ms; AVX2={System.Runtime.Intrinsics.X86.Avx2.IsSupported}");
        return 0;
    }
}
