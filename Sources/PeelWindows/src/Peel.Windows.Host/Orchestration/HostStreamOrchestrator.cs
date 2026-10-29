using Peel.Windows.Host.Capture;
using Peel.Windows.Host.Encoding;
using Peel.Windows.Host.Networking;
using Peel.Windows.Host.Windows;
using System.Runtime.ExceptionServices;
using System.Diagnostics;
using Peel.Windows.Host.Diagnostics;

namespace Peel.Windows.Host.Orchestration;

public sealed class HostStreamOrchestrator
{
    private readonly IWindowCaptureBackend _captureBackend;
    private readonly IVideoEncoderFactory _encoderFactory;
    private readonly IHostTransport? _transport;

    public HostStreamOrchestrator(
        IWindowCaptureBackend captureBackend,
        IVideoEncoderFactory encoderFactory,
        IHostTransport transport)
    {
        _captureBackend = captureBackend;
        _encoderFactory = encoderFactory;
        _transport = transport;
    }

    internal HostStreamOrchestrator(
        IWindowCaptureBackend captureBackend,
        IVideoEncoderFactory encoderFactory)
    {
        _captureBackend = captureBackend;
        _encoderFactory = encoderFactory;
    }

    public async Task RunWindowStreamAsync(
        WindowDescriptor window,
        VideoEncodingSettings settings,
        CancellationToken cancellationToken)
    {
        if (_transport is null)
        {
            throw new InvalidOperationException("No legacy Host transport was configured.");
        }

        if (!window.Bounds.IsUsable)
        {
            throw new ArgumentException("The selected window has invalid bounds.", nameof(window));
        }

        await RunEncodedWindowStreamAsync(
            window,
            settings,
            async (encoded, frameCancellationToken) =>
            {
                await _transport.SendVideoFrameAsync(
                    window.Handle,
                    encoded,
                    frameCancellationToken);
            },
            static () => true,
            cancellationToken);
    }

    internal async Task RunEncodedWindowStreamAsync(
        WindowDescriptor window,
        VideoEncodingSettings settings,
        Func<EncodedVideoFrame, CancellationToken, ValueTask> encodedFrameHandler,
        Func<bool> isCurrentGeneration,
        CancellationToken cancellationToken,
        StreamDiagnostics.Lease? diagnostics = null)
    {
        ArgumentNullException.ThrowIfNull(window);
        ArgumentNullException.ThrowIfNull(settings);
        ArgumentNullException.ThrowIfNull(encodedFrameHandler);
        ArgumentNullException.ThrowIfNull(isCurrentGeneration);

        if (!window.Bounds.IsUsable)
        {
            throw new ArgumentException("The selected window has invalid bounds.", nameof(window));
        }

        await using IWindowCaptureSession capture =
            await _captureBackend.OpenAsync(window, cancellationToken);
        IGpuWindowCaptureSession? gpuCapture = settings.UseHardware && capture.InitialWidth >= 2 && capture.InitialHeight >= 2 && _encoderFactory is MediaFoundationH264EncoderFactory
            ? capture as IGpuWindowCaptureSession : null;
        if (gpuCapture is not null) settings = settings with { GpuDevice = gpuCapture.GpuDevice };
        using var frames = new LatestRawFrameQueue(() => diagnostics?.Record(StreamStage.ReplacedRaw));
        using var pipelineCancellation = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken);
        IVideoEncoder? encoder = null;
        VideoEncodingSettings? encoderSettings = null;
        VideoEncodingSettings? initialSettings = CreateEncodingSettings(
            settings,
            capture.InitialWidth,
            capture.InitialHeight);
        if (initialSettings is not null)
        {
            try
            {
                encoder = await _encoderFactory.CreateAsync(initialSettings, cancellationToken).ConfigureAwait(false);
                gpuCapture?.SetGpuFramesEnabled(true);
            }
            catch (Exception e) when (settings.GpuDevice != 0 && e is System.Runtime.InteropServices.COMException or PlatformNotSupportedException)
            {
                settings = settings with { GpuDevice = 0 }; initialSettings = initialSettings with { GpuDevice = 0 };
                gpuCapture?.SetGpuFramesEnabled(false); gpuCapture = null;
                encoder = await _encoderFactory.CreateAsync(initialSettings, cancellationToken).ConfigureAwait(false);
            }
            encoderSettings = initialSettings;
        }

        Task encodeTask = frames.RunAsync(
            async (frame, frameCancellationToken) =>
            {
                if (!isCurrentGeneration())
                {
                    pipelineCancellation.Cancel();
                    return;
                }

                CapturedFrame? encodingFrame = PrepareFrameForEncoding(frame);
                if (encodingFrame is null)
                {
                    return;
                }

                VideoEncodingSettings requiredSettings = CreateEncodingSettings(
                    settings,
                    encodingFrame.Width,
                    encodingFrame.Height) ??
                    throw new InvalidDataException(
                        "The captured frame is too small for H.264 encoding.");
                if (encoder is null || encoderSettings != requiredSettings)
                {
                    if (encoder is not null)
                    {
                        await encoder.DisposeAsync().ConfigureAwait(false);
                        encoder = null;
                        encoderSettings = null;
                    }

                    encoder = await _encoderFactory.CreateAsync(
                            requiredSettings,
                            frameCancellationToken)
                        .ConfigureAwait(false);
                    encoderSettings = requiredSettings;
                }

                diagnostics?.Configure(encodingFrame.Width, encodingFrame.Height, settings.UseHardware
                    ? encodingFrame.GpuSurface is not null ? "Hardware requested · GPU input" : "Hardware requested · CPU input" : "Software requested · CPU input");
                long encodeStarted = Stopwatch.GetTimestamp();
                EncodedVideoFrame? encoded =
                    await encoder.EncodeAsync(encodingFrame, frameCancellationToken)
                        .ConfigureAwait(false);
                diagnostics?.Record(StreamStage.Submitted, callMilliseconds: Stopwatch.GetElapsedTime(encodeStarted).TotalMilliseconds);
                if (encoded is not null && isCurrentGeneration())
                {
                    diagnostics?.Record(StreamStage.Encoded, encoded.Bytes.Length);
                    long sendStarted = Stopwatch.GetTimestamp();
                    await encodedFrameHandler(encoded, frameCancellationToken).ConfigureAwait(false);
                    diagnostics?.Record(StreamStage.Sent, encoded.Bytes.Length, Stopwatch.GetElapsedTime(sendStarted).TotalMilliseconds);
                }
            },
            pipelineCancellation.Token);

        _ = encodeTask.ContinueWith(
            static (_, state) => ((CancellationTokenSource)state!).Cancel(),
            pipelineCancellation,
            CancellationToken.None,
            TaskContinuationOptions.ExecuteSynchronously |
                TaskContinuationOptions.OnlyOnFaulted,
            TaskScheduler.Default);

        try
        {
            Exception? captureFailure = null;
            try
            {
                await capture.RunAsync(
                    (frame, _) =>
                    {
                        if (!isCurrentGeneration())
                        {
                            frame.Dispose();
                            pipelineCancellation.Cancel();
                        }
                        else
                        {
                            diagnostics?.Record(StreamStage.Captured);
                            frames.Publish(frame);
                        }

                        return ValueTask.CompletedTask;
                    },
                    pipelineCancellation.Token).ConfigureAwait(false);
            }
            catch (Exception exception)
            {
                captureFailure = exception;
            }
            finally
            {
                frames.Complete();
            }

            await encodeTask.ConfigureAwait(false);

            if (captureFailure is not null)
            {
                ExceptionDispatchInfo.Capture(captureFailure).Throw();
            }
        }
        finally
        {
            if (encoder is not null)
            {
                await encoder.DisposeAsync().ConfigureAwait(false);
            }
        }
    }

    private static CapturedFrame? PrepareFrameForEncoding(CapturedFrame frame)
    {
        int evenWidth = frame.Width & ~1;
        int evenHeight = frame.Height & ~1;
        if (evenWidth <= 0 || evenHeight <= 0)
        {
            return null;
        }

        return evenWidth == frame.Width && evenHeight == frame.Height
            ? frame
            : frame with { Width = evenWidth, Height = evenHeight };
    }

    private static VideoEncodingSettings? CreateEncodingSettings(
        VideoEncodingSettings template,
        int width,
        int height)
    {
        int evenWidth = width & ~1;
        int evenHeight = height & ~1;
        return evenWidth <= 0 || evenHeight <= 0
            ? null
            : template with { Width = evenWidth, Height = evenHeight };
    }
}
