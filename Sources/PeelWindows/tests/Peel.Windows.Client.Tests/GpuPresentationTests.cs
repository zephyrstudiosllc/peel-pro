using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Runtime.InteropServices;
using Peel.Windows.Client.Services;
using Peel.Windows.Client.ViewModels;
using Peel.Windows.Host.Capture;
using Peel.Windows.Host.Encoding;

namespace Peel.Windows.Client.Tests;

internal static partial class Program
{
    private static void GpuLeaseOwnership()
    {
        int releases = 0; bool reused = false;
        var first = new GpuPresentationSurface(1, safe => { releases++; reused = safe; });
        var second = first.Retain(); var third = first.Retain();
        first.Dispose(); first.Dispose(); Equal(0, releases);
        second.PreventReuse(); third.PreventReuse(); second.AllowReuse(); second.Dispose(); Equal(0, releases);
        third.Dispose(); Equal(1, releases); True(!reused, "One still-attached compositor must prevent recycling across all leases.");
        var detached = new GpuPresentationSurface(1, safe => { releases++; reused = safe; });
        detached.PreventReuse(); detached.AllowReuse(); detached.Dispose();
        Equal(2, releases); True(reused, "A detached completed image can return to its pool exactly once.");
        Throws<ObjectDisposedException>(() => detached.Retain());
    }

    private static async Task<int> GpuPresentationSmokeAsync()
    {
        MediaFoundationNative.Startup();
        try
        {
            using var device = D3D11VideoDevice.Create();
            using (var sourceConversion = new D3D11Nv12Converter(device.Device, device.Context, 64, 64))
            using (var presentationConversion = new D3D11WpfConverter(device.Device, device.Context, 64, 64))
            {
                byte[] redPixels = new byte[64 * 64 * 4], bluePixels = new byte[64 * 64 * 4];
                for (int i = 0; i < redPixels.Length; i += 4) { redPixels[i + 2] = 255; redPixels[i + 3] = 255; bluePixels[i] = 255; bluePixels[i + 3] = 255; }
                using var red = sourceConversion.ConvertBgraToSurface(redPixels, 256);
                using var blue = sourceConversion.ConvertBgraToSurface(bluePixels, 256);
                using var first = new DecodedVideoFrame(64, 64, 256, ReadOnlyMemory<byte>.Empty, 1) { PresentationSurface = presentationConversion.Convert(red.Texture, 0) };
                nint firstSurface = first.PresentationSurface.Surface;
                await OnStaAsync(() =>
                {
                    using var presenter = new WpfVideoPresenter(); presenter.Present(first); first.Dispose();
                    using var second = new DecodedVideoFrame(64, 64, 256, ReadOnlyMemory<byte>.Empty, 2)
                    { PresentationSurface = Task.Run(() => presentationConversion.Convert(blue.Texture, 0)).GetAwaiter().GetResult() };
                    True(second.PresentationSurface.Surface != firstSurface, "A WPF-attached surface must not be overwritten by the next conversion.");
                    CheckImageColor(presenter.Source!, 2);
                    presenter.Present(second); CheckImageColor(presenter.Source!, 0);
                    using var third = Task.Run(() => presentationConversion.Convert(red.Texture, 0)).GetAwaiter().GetResult();
                    Equal(firstSurface, third.Surface); // WPF detached it under TryLock; all Peel leases ended.
                    CheckImageColor(presenter.Source!, 0);
                    presentationConversion.Dispose(); // Displayed leases remain valid beyond their decoder generation.
                    CheckImageColor(presenter.Source!, 0);
                });
                Console.WriteLine("PASS WPF-attached surfaces stay immutable; detached surfaces reuse; active display outlives decoder generation.");
            }
            using (var colorConverter = new D3D11WpfConverter(device.Device, device.Context, 64, 64))
            {
                foreach (bool bt709 in new[] { false, true })
                foreach (bool fullRange in new[] { false, true })
                {
                    byte[] source = new byte[64 * 64 * 3 / 2];
                    source.AsSpan(0, 64 * 64).Fill(82);
                    for (int i = 64 * 64; i < source.Length; i += 2) { source[i] = 90; source[i + 1] = 210; }
                    using var input = UploadNv12(device.Device, device.Context, source, 64, 64);
                    using var output = new DecodedVideoFrame(64, 64, 256, ReadOnlyMemory<byte>.Empty, 0)
                    { PresentationSurface = colorConverter.Convert(input.Texture, 0, bt709, fullRange) };
                    byte[] expected = Nv12ToBgra32Converter.Convert(source, 64, 64, bt709: bt709, fullRange: fullRange);
                    await OnStaAsync(() =>
                    {
                        using var presenter = new WpfVideoPresenter(); True(presenter.Present(output), "Color fixture must present.");
                        var image = new System.Windows.Controls.Image { Source = presenter.Source };
                        image.Measure(new Size(64, 64)); image.Arrange(new Rect(0, 0, 64, 64));
                        var bitmap = new RenderTargetBitmap(64, 64, 96, 96, PixelFormats.Pbgra32); bitmap.Render(image);
                        var actual = new byte[64 * 64 * 4]; bitmap.CopyPixels(actual, 256, 0);
                        int center = (32 * 64 + 32) * 4;
                        for (int c = 0; c < 4; c++) True(Math.Abs(actual[center + c] - expected[center + c]) <= 3,
                            $"GPU color metadata 709={bt709}, full={fullRange}, channel={c}: {actual[center+c]} vs {expected[center+c]}.");
                    });
                }
                Console.WriteLine("PASS full/limited BT.601/BT.709 GPU and CPU color agreement.");
            }
            foreach (var size in new[] { (64, 64), (1920, 1080), (5120, 2880), (128, 96) })
            {
                int width = size.Item1, height = size.Item2;
                using var nv12 = new D3D11Nv12Converter(device.Device, device.Context, width, height);
                using var convert = new D3D11WpfConverter(device.Device, device.Context, width, height);
                foreach (var color in new[] { (B:0, G:0, R:255), (B:0, G:255, R:0), (B:255, G:0, R:0), (B:255, G:255, R:255), (B:0, G:0, R:0) })
                {
                    byte[] pixels = new byte[width * height * 4];
                    for (int i = 0; i < pixels.Length; i += 4) { pixels[i] = (byte)color.B; pixels[i+1] = (byte)color.G; pixels[i+2] = (byte)color.R; pixels[i+3] = 255; }
                    using var input = nv12.ConvertBgraToSurface(pixels, width * 4);
                    var frame = new DecodedVideoFrame(width, height, width * 4, ReadOnlyMemory<byte>.Empty, 0)
                    { HasGpuSurface = true, PresentationSurface = convert.Convert(input.Texture, 0) };
                    using var lease = frame.Retain(); frame.Dispose();
                    Throws<ObjectDisposedException>(() => _ = frame.PresentationSurface!.Surface);
                    var mailbox = new LatestDecodedFrameMailbox();
                    True(mailbox.Publish(lease), "First retained GPU frame must schedule.");
                    True(!mailbox.Publish(lease), "Replacing GPU frame must keep one pending presentation.");
                    using var pending = mailbox.TakeLatest();
                    mailbox.Reset();
                    True(pending!.PresentationSurface!.Surface != 0, "Taking the latest frame transfers its retained reference.");
                    await OnStaAsync(() =>
                    {
                        using var presenter = new WpfVideoPresenter();
                        True(presenter.Present(pending), "GPU surface must be accepted by D3DImage.");
                        Equal(width, presenter.PixelWidth); Equal(height, presenter.PixelHeight);
                        var image = new System.Windows.Controls.Image { Source = presenter.Source, Stretch = Stretch.Fill };
                        image.Measure(new Size(64, 64)); image.Arrange(new Rect(0, 0, 64, 64));
                        var result = new RenderTargetBitmap(64, 64, 96, 96, PixelFormats.Pbgra32); result.Render(image);
                        byte[] read = new byte[64 * 64 * 4]; result.CopyPixels(read, 256, 0);
                        int center = (32 * 64 + 32) * 4;
                        foreach (var channel in new[] { (Offset:0, Value:color.B), (Offset:1, Value:color.G), (Offset:2, Value:color.R) })
                            True(Math.Abs(read[center + channel.Offset] - channel.Value) <= 5,
                                $"{width}x{height} GPU/WPF color {channel.Offset}: expected {channel.Value}, actual {read[center + channel.Offset]}.");
                        True(read[center + 3] == 255, "GPU presentation must be opaque.");
                    });
                    mailbox.Close();
                    True(!mailbox.Publish(lease), "Closed viewers must not retain late GPU callbacks.");
                    True(mailbox.TakeLatest() is null, "A closed viewer has no retained pending frame.");
                }
                Console.WriteLine($"PASS GPU NV12 -> shared D3D9Ex -> WPF: {width}x{height}, RGB/black/white pixels within 5, retained frame/mailbox ownership.");
            }
            return 0;
        }
        finally { MediaFoundationNative.Shutdown(); }
    }

    private static void CheckImageColor(ImageSource source, int dominant)
    {
        var image = new System.Windows.Controls.Image { Source = source };
        image.Measure(new Size(64, 64)); image.Arrange(new Rect(0, 0, 64, 64));
        var bitmap = new RenderTargetBitmap(64, 64, 96, 96, PixelFormats.Pbgra32); bitmap.Render(image);
        byte[] actual = new byte[64 * 64 * 4]; bitmap.CopyPixels(actual, 256, 0);
        int center = (32 * 64 + 32) * 4;
        for (int c = 0; c < 3; c++) True(Math.Abs(actual[center + c] - (c == dominant ? 255 : 0)) <= 5, "A retained GPU presentation must preserve its original pixels.");
    }

    private static unsafe GpuCapturedSurface UploadNv12(nint device, nint context, byte[] pixels, int width, int height)
    {
        uint* desc = stackalloc uint[11] { (uint)width, (uint)height, 1, 1, 103, 1, 0, 0, 0x20, 0, 0 };
        nint texture = 0;
        Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, uint*, nint, nint*, int>)(*(nint**)device)[5])(device, desc, 0, &texture));
        fixed (byte* data = pixels)
            ((delegate* unmanaged[Stdcall]<nint, nint, uint, nint, byte*, uint, uint, void>)(*(nint**)context)[48])(context, texture, 0, 0, data, (uint)width, 0);
        return new GpuCapturedSurface(texture, device);
    }

    private static async Task<int> NativeGpuPipelineBenchmarkAsync()
    {
        const int width = 5120, height = 2880, count = 120;
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(90));
        using var device = D3D11VideoDevice.Create();
        using var convert = new D3D11Nv12Converter(device.Device, device.Context, width, height);
        using var source = convert.ConvertBgraToSurface(CreateNativeDecodeInput(width, height, 5), width * 4);
        using (var displayConversion = new D3D11WpfConverter(device.Device, device.Context, width, height))
        {
            var conversionWatch = System.Diagnostics.Stopwatch.StartNew();
            double allocation = 0, submission = 0, completion = 0;
            for (int i = 0; i < count; i++)
            {
                using var output = displayConversion.Convert(source.Texture, 0);
                allocation += displayConversion.LastTimings.AllocationMs; submission += displayConversion.LastTimings.SubmissionMs; completion += displayConversion.LastTimings.CompletionMs;
            }
            Console.WriteLine($"5K completed shared-surface conversion only: {count / conversionWatch.Elapsed.TotalSeconds:F1} fps; average allocation={allocation/count:F2}ms, submission={submission/count:F2}ms, completion={completion/count:F2}ms; directInput={displayConversion.UsedDirectInput} (no decode or WPF composition).");
        }
        await using var encoder = await new MediaFoundationH264EncoderFactory().CreateAsync(new(VideoCodec.Hevc, width, height, 120, 20_000_000, true) { GpuDevice = device.Device }, timeout.Token);
        var packets = new List<Peel.Windows.Protocol.VideoFramePacket>();
        Peel.Windows.Protocol.VideoConfigPacket? config = null;
        var encodeWatch = System.Diagnostics.Stopwatch.StartNew();
        for (int i = 0; i < count; i++)
        {
            using var input = new CapturedFrame(width, height, width, (i + 1) * 83333L, CapturePixelFormat.Nv12, ReadOnlyMemory<byte>.Empty) { GpuSurface = source.Retain() };
            var output = await encoder.EncodeAsync(input, timeout.Token);
            if (output is null) continue;
            if (output.Configuration is { } c) config = new(9, Peel.Windows.Protocol.PeelVideoCodec.Hevc, width, height, c.Timescale, c.NalUnitHeaderLength,
                c.SequenceParameterSet.ToArray(), c.PictureParameterSet.ToArray(), c.VideoParameterSet.ToArray());
            packets.Add(new(9, output.IsKeyFrame, output.Timestamp100Nanoseconds, output.Duration100Nanoseconds, output.Bytes.ToArray()));
        }
        encodeWatch.Stop(); True(config is not null && packets.Count > 100, "Benchmark requires real encoded HEVC packets.");
        await using var decoder = new MediaFoundationH264DecoderSink(gpuPresentation: true);
        await decoder.ConfigureAsync(config!, timeout.Token);
        int received = 0; DecodedVideoFrame? borrowed = null;
        decoder.FrameDecoded += (_, e) => { True(e.Frame.UsesGpuPresentation && e.Frame.Bgra32Pixels.IsEmpty, "Every benchmark output must remain GPU-only."); received++; borrowed = e.Frame; };
        var decodeWatch = System.Diagnostics.Stopwatch.StartNew();
        foreach (var packet in packets) await decoder.SubmitAsync(packet, timeout.Token);
        decodeWatch.Stop();
        True(received > 100, "Benchmark must decode actual output frames.");
        Throws<ObjectDisposedException>(() => _ = borrowed!.PresentationSurface!.Surface);
        Console.WriteLine($"5K HEVC static-surface probe ({packets.Count} packets): encode {packets.Count / encodeWatch.Elapsed.TotalSeconds:F1} fps; decode + completed GPU/WPF surface {received / decodeWatch.Elapsed.TotalSeconds:F1} fps. Sequential stages, no capture/network/display scanout; not end-to-end 120 fps acceptance.");
        return 0;
    }
}
