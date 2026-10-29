using System.Collections.Concurrent;
using Peel.Windows.Host.Capture;

namespace Peel.Windows.Host.Encoding;

public sealed class MediaFoundationH264EncoderFactory : IVideoEncoderFactory
{
    public async ValueTask<IVideoEncoder> CreateAsync(
        VideoEncodingSettings settings,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(settings);
        return await MediaFoundationH264Encoder.CreateAsync(settings, cancellationToken)
            .ConfigureAwait(false);
    }
}

internal sealed class MediaFoundationH264Encoder : IVideoEncoder
{
    private readonly BlockingCollection<EncodeWork> work =
        new(new ConcurrentQueue<EncodeWork>(), boundedCapacity: 1);
    private readonly TaskCompletionSource initialized = new(
        TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TaskCompletionSource workerCompleted = new(
        TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly Thread worker;
    private readonly VideoEncodingSettings settings;
    private Exception? workerFailure;
    private int disposed;
    private readonly CancellationTokenSource shutdown = new();

    private MediaFoundationH264Encoder(VideoEncodingSettings settings)
    {
        this.settings = settings;
        worker = new Thread(RunWorker)
        {
            IsBackground = true,
            Name = "Peel Media Foundation H.264 encoder",
        };
        worker.SetApartmentState(ApartmentState.MTA);
        worker.Start();
    }

    internal static async ValueTask<MediaFoundationH264Encoder> CreateAsync(
        VideoEncodingSettings settings,
        CancellationToken cancellationToken)
    {
        ValidateSettings(settings);
        var encoder = new MediaFoundationH264Encoder(settings);
        try
        {
            await encoder.initialized.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
            return encoder;
        }
        catch
        {
            await encoder.DisposeAsync().ConfigureAwait(false);
            throw;
        }
    }

    public ValueTask<EncodedVideoFrame?> EncodeAsync(
        CapturedFrame frame,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(frame);
        cancellationToken.ThrowIfCancellationRequested();
        ObjectDisposedException.ThrowIf(Volatile.Read(ref disposed) != 0, this);
        Exception? failure = Volatile.Read(ref workerFailure);
        if (failure is not null)
        {
            throw new InvalidOperationException("The Media Foundation encoder worker failed.", failure);
        }

        var completion = new TaskCompletionSource<EncodedVideoFrame?>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        CapturedFrame owned = frame.GpuSurface is { } gpu ? frame with { GpuSurface = gpu.Retain() } : frame;
        bool accepted;
        try
        {
            accepted = work.TryAdd(new EncodeWork(owned, completion, cancellationToken));
        }
        catch (InvalidOperationException)
        {
            accepted = false;
        }

        if (!accepted)
        {
            if (owned.GpuSurface is not null) owned.Dispose();
            ObjectDisposedException.ThrowIf(Volatile.Read(ref disposed) != 0, this);
            failure = Volatile.Read(ref workerFailure);
            if (failure is not null)
            {
                throw new InvalidOperationException("The Media Foundation encoder worker failed.", failure);
            }

            throw new InvalidOperationException("The Media Foundation encoder already has pending work.");
        }

        return new ValueTask<EncodedVideoFrame?>(completion.Task.WaitAsync(cancellationToken));
    }

    public ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) == 0)
        {
            shutdown.Cancel();
            work.CompleteAdding();
        }

        return new ValueTask(workerCompleted.Task);
    }

    private void RunWorker()
    {
        MediaFoundationH264Transform? transform = null;
        int comResult = MediaFoundationNative.InitializeCom();
        bool uninitializeCom = comResult >= 0;
        try
        {
            if (comResult < 0 && comResult != MediaFoundationNative.RpcChangedMode)
            {
                MediaFoundationNative.Check(comResult, "CoInitializeEx");
            }

            transform = new MediaFoundationH264Transform(settings);
            initialized.TrySetResult();

            foreach (EncodeWork item in work.GetConsumingEnumerable())
            {
                try
                {
                    using var cancel = CancellationTokenSource.CreateLinkedTokenSource(item.Cancellation, shutdown.Token);
                    item.Completion.TrySetResult(transform.Encode(item.Frame, cancel.Token));
                }
                catch (Exception exception)
                {
                    item.Completion.TrySetException(exception);
                    throw;
                }
                finally { if (item.Frame.GpuSurface is not null) item.Frame.Dispose(); }
            }
        }
        catch (Exception exception)
        {
            Volatile.Write(ref workerFailure, exception);
            work.CompleteAdding();
            initialized.TrySetException(exception);
            while (work.TryTake(out EncodeWork? pending))
            {
                if (pending.Frame.GpuSurface is not null) pending.Frame.Dispose();
                pending.Completion.TrySetException(exception);
            }
        }
        finally
        {
            transform?.Dispose();
            if (uninitializeCom)
            {
                MediaFoundationNative.UninitializeCom();
            }

            workerCompleted.TrySetResult();
        }
    }

    private static void ValidateSettings(VideoEncodingSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        if (settings.Codec is not (VideoCodec.H264 or VideoCodec.Hevc))
        {
            throw new NotSupportedException("Unsupported Media Foundation video codec.");
        }

        if (settings.Width <= 0 || settings.Height <= 0 ||
            settings.Width > CaptureFrameLayout.MaximumD3D11TextureDimension ||
            settings.Height > CaptureFrameLayout.MaximumD3D11TextureDimension ||
            (settings.Width & 1) != 0 || (settings.Height & 1) != 0 ||
            settings.FramesPerSecond <= 0 || settings.FramesPerSecond > 240 ||
            settings.TargetBitrate <= 0)
        {
            throw new ArgumentException(
                "Media Foundation H.264 settings require bounded even dimensions, frame rate, and bitrate.",
                nameof(settings));
        }
    }

    private sealed record EncodeWork(
        CapturedFrame Frame,
        TaskCompletionSource<EncodedVideoFrame?> Completion,
        CancellationToken Cancellation);
}

internal sealed class MediaFoundationH264Transform : IDisposable
{
    internal static long GpuInputsSubmitted;
    private const uint Timescale = 10_000_000;
    private const uint ProgressiveInterlace = 2;
    private const uint H264MainProfile = 77;

    private readonly VideoEncodingSettings settings;
    private readonly long frameDuration;
    private nint transform;
    private nint outputType;
    private uint inputStreamId;
    private uint outputStreamId;
    private MediaFoundationNative.OutputStreamInfo outputInfo;
    private VideoEncoderConfiguration? configuration;
    private bool configurationSent;
    private bool startupTypeRefreshed;
    private bool mediaFoundationStarted;
    private bool disposed;
    private AsyncTransformEvents? asyncEvents;
    private readonly Queue<EncodedVideoFrame> pendingOutput = new();
    private long pendingOutputBytes;
    private D3D11VideoDevice? gpuDevice;

    internal MediaFoundationH264Transform(VideoEncodingSettings settings)
    {
        this.settings = settings;
        frameDuration = Math.Max(1, Timescale / settings.FramesPerSecond);

        nint inputType = 0;
        nint attributes = 0;
        try
        {
            MediaFoundationNative.Startup();
            mediaFoundationStarted = true;
            transform = settings.UseHardware ? MediaFoundationCodecCatalog.CreateHardware(settings.Codec, encoder: true)
                : settings.Codec == VideoCodec.Hevc
                ? MediaFoundationCodecCatalog.CreateSynchronous(VideoCodec.Hevc, encoder: true)
                : MediaFoundationNative.CreateH264Encoder();
            attributes = MediaFoundationNative.GetTransformAttributes(transform);
            if (settings.UseHardware)
            {
                MediaFoundationNative.SetUInt32(attributes, AsyncTransformEvents.Unlock, 1);
                asyncEvents = new AsyncTransformEvents(transform);
            }
            MediaFoundationNative.GetStreamIds(transform, out inputStreamId, out outputStreamId);
            MediaFoundationNative.SetUInt32(attributes, MediaFoundationNative.LowLatency, 1);
            if (settings.GpuDevice != 0)
            {
                if (!settings.UseHardware || !D3D11VideoDevice.Supports(attributes)) throw new PlatformNotSupportedException("This encoder cannot accept GPU capture surfaces.");
                gpuDevice = D3D11VideoDevice.Create(settings.GpuDevice);
                MediaFoundationNative.ProcessMessage(transform, 2, (nuint)gpuDevice.Manager);
            }

            outputType = MediaFoundationNative.CreateMediaType();
            ConfigureOutputType(outputType);
            MediaFoundationNative.SetOutputType(transform, outputStreamId, outputType);

            inputType = MediaFoundationNative.CreateMediaType();
            ConfigureInputType(inputType);
            MediaFoundationNative.SetInputType(transform, inputStreamId, inputType);

            outputInfo = MediaFoundationNative.GetOutputStreamInfo(transform, outputStreamId);
            MediaFoundationNative.ProcessMessage(
                transform,
                MediaFoundationNative.MessageNotifyBeginStreaming);
            MediaFoundationNative.ProcessMessage(
                transform,
                MediaFoundationNative.MessageNotifyStartOfStream);
            TryReadConfiguration();
        }
        catch
        {
            Dispose();
            throw;
        }
        finally
        {
            MediaFoundationNative.Release(ref attributes);
            MediaFoundationNative.Release(ref inputType);
        }
    }

    internal EncodedVideoFrame? Encode(CapturedFrame frame, CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        ValidateFrame(frame);
        if (asyncEvents is not null)
        {
            asyncEvents.Poll();
            while (asyncEvents.InputTickets == 0)
            {
                asyncEvents.WaitForProgress(() => asyncEvents.InputTickets > 0 || asyncEvents.OutputTickets > 0, cancellationToken);
                DrainHardwareOutput(frame);
            }
        }
        nint inputSample = 0;
        try
        {
            if (frame.GpuSurface is { } surface)
            {
                if (gpuDevice is null || surface.Device != settings.GpuDevice || frame.PixelFormat != CapturePixelFormat.Nv12)
                    throw new InvalidDataException("GPU capture belongs to a different encoder device.");
                inputSample = MediaFoundationNative.CreateGpuInputSample(surface.Texture, frame.Timestamp100Nanoseconds, frameDuration);
            }
            else inputSample = MediaFoundationNative.CreateInputSample(BgraToNv12Converter.EncoderInput(frame).Span, frame.Timestamp100Nanoseconds, frameDuration);
            MediaFoundationNative.ProcessInput(transform, inputStreamId, inputSample);
            if (frame.GpuSurface is not null) Interlocked.Increment(ref GpuInputsSubmitted);
            asyncEvents?.TakeInput();
        }
        finally
        {
            MediaFoundationNative.Release(ref inputSample);
        }

        if (asyncEvents is not null)
        {
            asyncEvents.WaitForProgress(() => asyncEvents.OutputTickets > 0 || asyncEvents.InputTickets > 0, cancellationToken);
            DrainHardwareOutput(frame);
            if (!pendingOutput.TryDequeue(out var encoded)) return null;
            pendingOutputBytes -= encoded.Bytes.Length;
            return encoded;
        }
        return ReadEncodedOutput(frame);
    }

    private void DrainHardwareOutput(CapturedFrame frame)
    {
        while (asyncEvents!.OutputTickets > 0)
        {
            asyncEvents.TakeOutput();
            if (ReadEncodedOutput(frame) is not { } output) continue;
            pendingOutputBytes = checked(pendingOutputBytes + output.Bytes.Length);
            if (pendingOutputBytes > 16 * 1024 * 1024 || pendingOutput.Count >= 8)
                throw new InvalidDataException("Hardware encoder output exceeded the bounded queue.");
            pendingOutput.Enqueue(output);
        }
    }

    private EncodedVideoFrame? ReadEncodedOutput(CapturedFrame frame)
    {
        nint providedSample = 0;
        nint outputSample = 0;
        var output = new MediaFoundationNative.OutputDataBuffer
        {
            StreamId = outputStreamId,
        };

        bool transformProvidesSamples =
            (outputInfo.Flags & (MediaFoundationNative.OutputProvidesSamples |
                MediaFoundationNative.OutputCanProvideSamples)) != 0;
        if (!transformProvidesSamples)
        {
            providedSample = MediaFoundationNative.CreateOutputSample(outputInfo.Size);
            output.Sample = providedSample;
        }

        try
        {
            int result = MediaFoundationNative.ProcessOutput(transform, ref output, out _);
            outputSample = output.Sample;
            if (result == MediaFoundationNative.TransformNeedsMoreInput)
            {
                return null;
            }

            if (result == MediaFoundationNative.TransformStreamChange && !configurationSent && !startupTypeRefreshed)
            {
                // Some hardware encoders publish their final sequence header at first output.
                // Only accept the same codec and dimensions before any wire configuration is sent.
                nint revisedType = MediaFoundationNative.GetOutputAvailableType(transform, outputStreamId);
                try
                {
                    Guid subtype = settings.Codec == VideoCodec.Hevc ? MediaFoundationCodecCatalog.HevcSubtype : MediaFoundationNative.VideoFormatH264;
                    if (!MediaFoundationNative.HasVideoFormat(revisedType, subtype, settings.Width, settings.Height))
                        throw new InvalidDataException("The hardware encoder changed the requested format.");
                    MediaFoundationNative.SetOutputType(transform, outputStreamId, revisedType);
                    MediaFoundationNative.Release(ref outputType);
                    outputType = revisedType; revisedType = 0;
                    outputInfo = MediaFoundationNative.GetOutputStreamInfo(transform, outputStreamId);
                    configuration = null; startupTypeRefreshed = true;
                    return null;
                }
                finally { MediaFoundationNative.Release(ref revisedType); }
            }

            MediaFoundationNative.Check(result, "IMFTransform.ProcessOutput");
            if (outputSample == 0)
            {
                throw new InvalidDataException("The H.264 transform returned no output sample.");
            }

            byte[] annexB = MediaFoundationNative.ReadSampleBytes(outputSample);
            var hevc = settings.Codec == VideoCodec.Hevc ? HevcAnnexB.Convert(annexB) : null;
            H264AnnexB.AccessUnit accessUnit = hevc is null ? H264AnnexB.ConvertAccessUnit(annexB)
                : new(hevc.Payload, hevc.Sps, hevc.Pps, hevc.Keyframe);
            TryReadConfiguration();
            configuration ??= hevc is null ? CreateConfigurationFromAccessUnit(accessUnit)
                : CreateConfiguration(hevc.Sps ?? throw new InvalidDataException("HEVC SPS is missing."),
                    hevc.Pps ?? throw new InvalidDataException("HEVC PPS is missing."),
                    hevc.Vps ?? throw new InvalidDataException("HEVC VPS is missing."));

            bool isKeyFrame =
                (MediaFoundationNative.TryGetUInt32(
                    outputSample,
                    MediaFoundationNative.CleanPoint,
                    out uint cleanPoint) && cleanPoint != 0) ||
                accessUnit.ContainsIdr;
            if (!configurationSent && !isKeyFrame)
            {
                throw new InvalidDataException("The H.264 stream did not begin at a keyframe.");
            }

            long timestamp = MediaFoundationNative.TryGetSampleTime(outputSample, out long sampleTime)
                ? sampleTime
                : frame.Timestamp100Nanoseconds;
            long duration = MediaFoundationNative.TryGetSampleDuration(outputSample, out long sampleDuration)
                ? Math.Max(0, sampleDuration)
                : frameDuration;
            VideoEncoderConfiguration? frameConfiguration = configurationSent
                ? null
                : configuration;
            configurationSent = true;

            return new EncodedVideoFrame(
                settings.Codec,
                timestamp,
                isKeyFrame,
                accessUnit.LengthPrefixedPayload,
                duration,
                frameConfiguration);
        }
        finally
        {
            if (output.Events != 0)
            {
                _ = System.Runtime.InteropServices.Marshal.Release(output.Events);
            }

            if (outputSample != 0 && outputSample != providedSample)
            {
                MediaFoundationNative.Release(ref outputSample);
            }

            MediaFoundationNative.Release(ref providedSample);
        }
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        asyncEvents?.Dispose();
        asyncEvents = null;
        if (transform != 0)
        {
            MediaFoundationNative.TryProcessMessage(
                transform,
                MediaFoundationNative.MessageNotifyEndOfStream);
            MediaFoundationNative.TryProcessMessage(
                transform,
                MediaFoundationNative.MessageCommandDrain);
            MediaFoundationNative.TryProcessMessage(
                transform,
                MediaFoundationNative.MessageNotifyEndStreaming);
            MediaFoundationNative.TryProcessMessage(
                transform,
                MediaFoundationNative.MessageCommandFlush);
            if (settings.UseHardware) _ = AsyncTransformEvents.MFShutdownObject(transform);
        }

        MediaFoundationNative.Release(ref outputType);
        MediaFoundationNative.Release(ref transform);
        gpuDevice?.Dispose(); gpuDevice = null;
        if (mediaFoundationStarted)
        {
            mediaFoundationStarted = false;
            try
            {
                MediaFoundationNative.Shutdown();
            }
            catch (System.Runtime.InteropServices.COMException)
            {
            }
        }
    }

    private void ConfigureOutputType(nint mediaType)
    {
        MediaFoundationNative.SetGuid(
            mediaType,
            MediaFoundationNative.MajorType,
            MediaFoundationNative.MediaTypeVideo);
        MediaFoundationNative.SetGuid(
            mediaType,
            MediaFoundationNative.Subtype,
            settings.Codec == VideoCodec.Hevc ? MediaFoundationCodecCatalog.HevcSubtype : MediaFoundationNative.VideoFormatH264);
        MediaFoundationNative.SetUInt32(
            mediaType,
            MediaFoundationNative.AverageBitrate,
            checked((uint)settings.TargetBitrate));
        MediaFoundationNative.SetSize(
            mediaType,
            MediaFoundationNative.FrameSize,
            checked((uint)settings.Width),
            checked((uint)settings.Height));
        MediaFoundationNative.SetRatio(
            mediaType,
            MediaFoundationNative.FrameRate,
            checked((uint)settings.FramesPerSecond),
            1);
        MediaFoundationNative.SetRatio(
            mediaType,
            MediaFoundationNative.PixelAspectRatio,
            1,
            1);
        MediaFoundationNative.SetUInt32(
            mediaType,
            MediaFoundationNative.InterlaceMode,
            ProgressiveInterlace);
        MediaFoundationNative.SetUInt32(
            mediaType,
            MediaFoundationNative.Mpeg2Profile,
            settings.Codec == VideoCodec.Hevc ? 1u : H264MainProfile);
    }

    private void ConfigureInputType(nint mediaType)
    {
        MediaFoundationNative.SetGuid(
            mediaType,
            MediaFoundationNative.MajorType,
            MediaFoundationNative.MediaTypeVideo);
        MediaFoundationNative.SetGuid(
            mediaType,
            MediaFoundationNative.Subtype,
            MediaFoundationNative.VideoFormatNv12);
        MediaFoundationNative.SetSize(
            mediaType,
            MediaFoundationNative.FrameSize,
            checked((uint)settings.Width),
            checked((uint)settings.Height));
        MediaFoundationNative.SetRatio(
            mediaType,
            MediaFoundationNative.FrameRate,
            checked((uint)settings.FramesPerSecond),
            1);
        MediaFoundationNative.SetRatio(
            mediaType,
            MediaFoundationNative.PixelAspectRatio,
            1,
            1);
        MediaFoundationNative.SetUInt32(
            mediaType,
            MediaFoundationNative.InterlaceMode,
            ProgressiveInterlace);
        MediaFoundationNative.SetUInt32(
            mediaType,
            MediaFoundationNative.DefaultStride,
            checked((uint)settings.Width));
    }

    private void TryReadConfiguration()
    {
        if (configuration is not null ||
            !MediaFoundationNative.TryGetBlob(
                outputType,
                MediaFoundationNative.MpegSequenceHeader,
                out byte[] sequenceHeader))
        {
            return;
        }

        if (settings.Codec == VideoCodec.Hevc)
        {
            var (vps, sps, pps) = HevcAnnexB.ReadParameterSets(sequenceHeader);
            configuration = CreateConfiguration(sps, pps, vps);
        }
        else
        {
            (byte[] sps, byte[] pps) = H264AnnexB.ReadParameterSets(sequenceHeader);
            configuration = CreateConfiguration(sps, pps);
        }
    }

    private VideoEncoderConfiguration CreateConfigurationFromAccessUnit(
        H264AnnexB.AccessUnit accessUnit)
    {
        if (accessUnit.SequenceParameterSet is null || accessUnit.PictureParameterSet is null)
        {
            throw new InvalidDataException("The first H.264 output is missing its SPS or PPS.");
        }

        return CreateConfiguration(
            accessUnit.SequenceParameterSet,
            accessUnit.PictureParameterSet);
    }

    private VideoEncoderConfiguration CreateConfiguration(byte[] sps, byte[] pps, byte[]? vps = null) =>
        new(
            settings.Codec,
            settings.Width,
            settings.Height,
            Timescale,
            4,
            sps,
            pps,
            vps ?? []);

    private void ValidateFrame(CapturedFrame frame)
    {
        if (frame.Width != settings.Width || frame.Height != settings.Height)
        {
            throw new InvalidDataException(
                "Captured dimensions changed inside one H.264 encoder generation.");
        }

        if (frame.Timestamp100Nanoseconds < 0)
        {
            throw new InvalidDataException("Captured frames require a nonnegative timestamp.");
        }
    }
}
