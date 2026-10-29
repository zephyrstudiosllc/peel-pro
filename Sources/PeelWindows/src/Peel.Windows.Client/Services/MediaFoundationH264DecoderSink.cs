using System.Collections.Concurrent;
using System.IO;
using System.Runtime.InteropServices;
using Peel.Windows.Protocol;

namespace Peel.Windows.Client.Services;

public sealed class MediaFoundationH264DecoderSink : IVideoDecoderSink, IAsyncDisposable
{
    private const uint MaximumWidth = 8192;
    private const uint MaximumHeight = 8192;
    private const ulong MaximumPixels = 16_777_216;
    private const int MaximumParameterSetBytes = 1024 * 1024;

    private static readonly Lazy<IReadOnlySet<PeelVideoCodec>> Codecs = new(() =>
        Peel.Windows.Host.Encoding.MediaFoundationCodecCatalog.CanActivateSynchronous(Peel.Windows.Host.Encoding.VideoCodec.Hevc, encoder: false)
            ? new HashSet<PeelVideoCodec> { PeelVideoCodec.H264, PeelVideoCodec.Hevc }
            : new HashSet<PeelVideoCodec> { PeelVideoCodec.H264 });

    private readonly SemaphoreSlim lifecycleGate = new(1, 1);
    private DecoderGeneration? generation;
    private bool disposed;
    private readonly bool preferHardware;
    private readonly bool gpuPresentation;
    public MediaFoundationH264DecoderSink(bool preferHardware = true, bool gpuPresentation = false)
    { this.preferHardware = preferHardware; this.gpuPresentation = gpuPresentation; }

    public event EventHandler<DecodedVideoFrameEventArgs>? FrameDecoded;

    public IReadOnlySet<PeelVideoCodec> SupportedCodecs => Codecs.Value;

    public async ValueTask ResetAsync(uint windowId, CancellationToken cancellationToken)
    {
        await lifecycleGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            DecoderGeneration? previous = generation;
            generation = null;
            if (previous is not null)
            {
                await previous.DisposeAsync().ConfigureAwait(false);
            }
        }
        finally
        {
            lifecycleGate.Release();
        }
    }

    public async ValueTask ConfigureAsync(
        VideoConfigPacket configuration,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        ValidateConfiguration(configuration);
        await lifecycleGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            DecoderGeneration? previous = generation;
            generation = null;
            if (previous is not null)
            {
                await previous.DisposeAsync().ConfigureAwait(false);
            }

            try
            {
                generation = await DecoderGeneration.CreateAsync(
                        configuration,
                        cancellationToken, preferHardware, gpuPresentation)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception exception) when (exception is not InvalidDataException)
            {
                throw new InvalidDataException(
                    "Media Foundation could not configure the H.264 decoder.",
                    exception);
            }
        }
        finally
        {
            lifecycleGate.Release();
        }
    }

    public async ValueTask SubmitAsync(
        VideoFramePacket frame,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(frame);
        DecodedVideoFrame[] decodedFrames;
        await lifecycleGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            DecoderGeneration current = generation ??
                throw new InvalidDataException("The H.264 decoder has no active configuration.");
            if (frame.WindowId != current.WindowId ||
                frame.PtsValue < 0 ||
                frame.DurationValue < 0 ||
                frame.Payload.Length == 0)
            {
                throw new InvalidDataException("The H.264 frame metadata is invalid.");
            }

            try
            {
                decodedFrames = await current.DecodeAsync(frame, cancellationToken)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception exception) when (exception is not InvalidDataException)
            {
                throw new InvalidDataException("Media Foundation could not decode the H.264 frame.", exception);
            }
        }
        finally
        {
            lifecycleGate.Release();
        }

        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            foreach (DecodedVideoFrame decodedFrame in decodedFrames)
                FrameDecoded?.Invoke(this, new DecodedVideoFrameEventArgs(decodedFrame));
        }
        finally { foreach (var decoded in decodedFrames) decoded.Dispose(); }
    }

    public async ValueTask DisposeAsync()
    {
        await lifecycleGate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (disposed)
            {
                return;
            }

            disposed = true;
            DecoderGeneration? previous = generation;
            generation = null;
            if (previous is not null)
            {
                await previous.DisposeAsync().ConfigureAwait(false);
            }
        }
        finally
        {
            lifecycleGate.Release();
        }
    }

    private static void ValidateConfiguration(VideoConfigPacket configuration)
    {
        if (configuration.Codec is not (PeelVideoCodec.H264 or PeelVideoCodec.Hevc) ||
            configuration.Width is 0 or > MaximumWidth ||
            configuration.Height is 0 or > MaximumHeight ||
            (ulong)configuration.Width * configuration.Height > MaximumPixels ||
            (configuration.Width & 1) != 0 ||
            (configuration.Height & 1) != 0 ||
            configuration.Timescale == 0 ||
            configuration.NalUnitHeaderLength is not (1 or 2 or 4) ||
            configuration.Sps.Length is 0 or > MaximumParameterSetBytes ||
            configuration.Pps.Length is 0 or > MaximumParameterSetBytes ||
            (configuration.Codec == PeelVideoCodec.H264 && configuration.Vps is { Length: > 0 }) ||
            (configuration.Codec == PeelVideoCodec.Hevc && configuration.Vps is not { Length: > 0 and <= MaximumParameterSetBytes }))
        {
            throw new InvalidDataException("The Media Foundation H.264 configuration is invalid.");
        }

        _ = H264LengthPrefixed.CreateSequenceHeader(configuration);
    }

    private sealed class DecoderGeneration : IAsyncDisposable
    {
        private readonly BlockingCollection<DecodeWork> work =
            new(new ConcurrentQueue<DecodeWork>(), boundedCapacity: 1);
        private readonly TaskCompletionSource initialized = new(
            TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource workerCompleted = new(
            TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly VideoConfigPacket configuration;
        private readonly bool preferHardware;
        private readonly bool gpuPresentation;
        private readonly Thread worker;
        private Exception? workerFailure;
        private int disposed;

        private DecoderGeneration(VideoConfigPacket configuration, bool preferHardware, bool gpuPresentation)
        {
            this.configuration = configuration;
            this.preferHardware = preferHardware;
            this.gpuPresentation = gpuPresentation;
            worker = new Thread(RunWorker)
            {
                IsBackground = true,
                Name = "Peel Media Foundation H.264 decoder",
            };
            worker.SetApartmentState(ApartmentState.MTA);
            worker.Start();
        }

        internal uint WindowId => configuration.WindowId;

        internal static async ValueTask<DecoderGeneration> CreateAsync(
            VideoConfigPacket configuration,
            CancellationToken cancellationToken, bool preferHardware, bool gpuPresentation)
        {
            var decoder = new DecoderGeneration(configuration, preferHardware, gpuPresentation);
            try
            {
                await decoder.initialized.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
                return decoder;
            }
            catch
            {
                await decoder.DisposeAsync().ConfigureAwait(false);
                throw;
            }
        }

        internal async ValueTask<DecodedVideoFrame[]> DecodeAsync(
            VideoFramePacket frame,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            ObjectDisposedException.ThrowIf(Volatile.Read(ref disposed) != 0, this);
            Exception? failure = Volatile.Read(ref workerFailure);
            if (failure is not null)
            {
                throw new InvalidDataException("The Media Foundation decoder worker failed.", failure);
            }

            var completion = new TaskCompletionSource<DecodedVideoFrame[]>(
                TaskCreationOptions.RunContinuationsAsynchronously);
            bool accepted;
            try
            {
                accepted = work.TryAdd(new DecodeWork(frame, completion));
            }
            catch (InvalidOperationException)
            {
                accepted = false;
            }

            if (!accepted)
            {
                ObjectDisposedException.ThrowIf(Volatile.Read(ref disposed) != 0, this);
                failure = Volatile.Read(ref workerFailure);
                if (failure is not null)
                {
                    throw new InvalidDataException("The Media Foundation decoder worker failed.", failure);
                }

                throw new InvalidOperationException("The Media Foundation decoder already has pending work.");
            }

            // Once accepted, the worker owns native resources. Observe completion even on cancellation.
            var frames = await completion.Task.ConfigureAwait(false);
            if (cancellationToken.IsCancellationRequested)
            {
                foreach (var decoded in frames) decoded.Dispose();
                cancellationToken.ThrowIfCancellationRequested();
            }
            return frames;
        }

        public ValueTask DisposeAsync()
        {
            if (Interlocked.Exchange(ref disposed, 1) == 0)
            {
                work.CompleteAdding();
            }

            return new ValueTask(workerCompleted.Task);
        }

        private void RunWorker()
        {
            MediaFoundationH264DecoderTransform? transform = null;
            int comResult = MediaFoundationDecoderNative.InitializeCom();
            bool uninitializeCom = comResult >= 0;
            try
            {
                if (comResult < 0 && comResult != MediaFoundationDecoderNative.RpcChangedMode)
                {
                    MediaFoundationDecoderNative.Check(comResult, "CoInitializeEx");
                }

                transform = new MediaFoundationH264DecoderTransform(configuration, preferHardware, gpuPresentation);
                initialized.TrySetResult();
                foreach (DecodeWork item in work.GetConsumingEnumerable())
                {
                    try
                    {
                        item.Completion.TrySetResult(transform.Decode(item.Frame));
                    }
                    catch (Exception exception)
                    {
                        item.Completion.TrySetException(exception);
                        throw;
                    }
                }
            }
            catch (Exception exception)
            {
                Volatile.Write(ref workerFailure, exception);
                work.CompleteAdding();
                initialized.TrySetException(exception);
                while (work.TryTake(out DecodeWork? pending))
                {
                    pending.Completion.TrySetException(exception);
                }
            }
            finally
            {
                transform?.Dispose();
                if (uninitializeCom)
                {
                    MediaFoundationDecoderNative.UninitializeCom();
                }

                workerCompleted.TrySetResult();
            }
        }

        private sealed record DecodeWork(
            VideoFramePacket Frame,
            TaskCompletionSource<DecodedVideoFrame[]> Completion);
    }
}

internal sealed class MediaFoundationH264DecoderTransform : IDisposable
{
    private const uint HundredNanosecondTimescale = 10_000_000;
    private const uint ProgressiveInterlace = 2;
    private const int MaximumProcessOutputCallsPerInput = 16;
    private const int MaximumDecodedFramesPerInput = 8;
    private const int MaximumStreamChangesPerInput = 2;

    private readonly VideoConfigPacket configuration;
    private nint transform;
    private nint inputType;
    private nint outputType;
    private uint inputStreamId;
    private uint outputStreamId;
    private MediaFoundationDecoderNative.OutputStreamInfo outputInfo;
    private bool mediaFoundationStarted;
    private bool disposed;
    private Peel.Windows.Host.Encoding.D3D11VideoDevice? videoDevice;
    private D3D11WpfConverter? presenter;
    private bool gpuPresentation;
    private (bool Bt709, bool FullRange) color;

    internal MediaFoundationH264DecoderTransform(VideoConfigPacket configuration, bool preferHardware = true, bool gpuPresentation = false)
    {
        this.configuration = configuration;
        this.gpuPresentation = gpuPresentation;
        nint attributes = 0;
        try
        {
            MediaFoundationDecoderNative.Startup();
            mediaFoundationStarted = true;
            transform = configuration.Codec == PeelVideoCodec.Hevc
                ? Peel.Windows.Host.Encoding.MediaFoundationCodecCatalog.CreateSynchronous(Peel.Windows.Host.Encoding.VideoCodec.Hevc, encoder: false)
                : MediaFoundationDecoderNative.CreateH264Decoder();
            MediaFoundationDecoderNative.GetStreamIds(transform, out inputStreamId, out outputStreamId);

            attributes = MediaFoundationDecoderNative.GetTransformAttributes(transform);
            MediaFoundationDecoderNative.SetUInt32(
                attributes,
                MediaFoundationDecoderNative.LowLatency,
                1);
            if (preferHardware && Peel.Windows.Host.Encoding.D3D11VideoDevice.Supports(attributes))
            {
                try
                {
                    videoDevice = Peel.Windows.Host.Encoding.D3D11VideoDevice.Create();
                    MediaFoundationDecoderNative.ProcessMessage(transform, 2, (nuint)videoDevice.Manager);
                }
                catch (COMException)
                {
                    MediaFoundationDecoderNative.TryProcessMessage(transform, 2);
                    videoDevice?.Dispose(); videoDevice = null;
                }
            }

            inputType = MediaFoundationDecoderNative.CreateMediaType();
            ConfigureInputType(inputType);
            try
            {
                MediaFoundationDecoderNative.SetInputType(transform, inputStreamId, inputType);
                ConfigureOutputType();
            }
            catch (COMException) when (videoDevice is not null)
            {
                // Unsupported hardware format: the documented DXVA fallback renegotiates before streaming.
                MediaFoundationDecoderNative.ProcessMessage(transform, 2, 0);
                videoDevice.Dispose(); videoDevice = null;
                MediaFoundationDecoderNative.SetInputType(transform, inputStreamId, inputType);
                ConfigureOutputType();
            }

            MediaFoundationDecoderNative.ProcessMessage(
                transform,
                MediaFoundationDecoderNative.MessageNotifyBeginStreaming);
            MediaFoundationDecoderNative.ProcessMessage(
                transform,
                MediaFoundationDecoderNative.MessageNotifyStartOfStream);
        }
        catch
        {
            Dispose();
            throw;
        }
        finally
        {
            MediaFoundationDecoderNative.Release(ref attributes);
        }
    }

    internal DecodedVideoFrame[] Decode(VideoFramePacket frame)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        byte[] annexB = H264LengthPrefixed.ConvertFrame(configuration, frame);
        long timestamp100Nanoseconds = ScaleTimestamp(
            frame.PtsValue,
            configuration.Timescale,
            HundredNanosecondTimescale);
        long duration100Nanoseconds = Math.Max(
            1,
            ScaleTimestamp(
                frame.DurationValue,
                configuration.Timescale,
                HundredNanosecondTimescale));
        nint inputSample = 0;
        try
        {
            inputSample = MediaFoundationDecoderNative.CreateInputSample(
                annexB,
                timestamp100Nanoseconds,
                duration100Nanoseconds);
            MediaFoundationDecoderNative.ProcessInput(transform, inputStreamId, inputSample);
        }
        finally
        {
            MediaFoundationDecoderNative.Release(ref inputSample);
        }

        var frames = new List<DecodedVideoFrame>();
        var processOutputCalls = 0;
        var streamChanges = 0;
        try
        {
            while (true)
            {
                if (++processOutputCalls > MaximumProcessOutputCallsPerInput)
                {
                    throw new InvalidDataException("The H.264 decoder exceeded its bounded output work.");
                }

                int result = ReadOutput(out DecodedVideoFrame? decodedFrame);
                if (result == MediaFoundationDecoderNative.TransformNeedsMoreInput)
                {
                    break;
                }

                if (result == MediaFoundationDecoderNative.TransformStreamChange)
                {
                    if (++streamChanges > MaximumStreamChangesPerInput)
                    {
                        throw new InvalidDataException("The H.264 decoder reported excessive format changes.");
                    }

                    ConfigureOutputType();
                    continue;
                }

                MediaFoundationDecoderNative.Check(result, "IMFTransform.ProcessOutput");
                if (decodedFrame is null)
                {
                    throw new InvalidDataException("The H.264 decoder returned no output frame.");
                }

                frames.Add(decodedFrame);
                if (frames.Count > MaximumDecodedFramesPerInput)
                {
                    throw new InvalidDataException("The H.264 decoder emitted excessive frames for one input.");
                }
            }

            return frames.ToArray();
        }
        catch { foreach (var decoded in frames) decoded.Dispose(); throw; }
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        if (transform != 0)
        {
            MediaFoundationDecoderNative.TryProcessMessage(
                transform,
                MediaFoundationDecoderNative.MessageNotifyEndOfStream);
            MediaFoundationDecoderNative.TryProcessMessage(
                transform,
                MediaFoundationDecoderNative.MessageCommandDrain);
            MediaFoundationDecoderNative.TryProcessMessage(
                transform,
                MediaFoundationDecoderNative.MessageNotifyEndStreaming);
            MediaFoundationDecoderNative.TryProcessMessage(
                transform,
                MediaFoundationDecoderNative.MessageCommandFlush);
            if (videoDevice is not null) MediaFoundationDecoderNative.TryProcessMessage(transform, 2);
        }

        MediaFoundationDecoderNative.Release(ref outputType);
        MediaFoundationDecoderNative.Release(ref inputType);
        MediaFoundationDecoderNative.Release(ref transform);
        presenter?.Dispose(); presenter = null;
        videoDevice?.Dispose(); videoDevice = null;
        if (mediaFoundationStarted)
        {
            mediaFoundationStarted = false;
            try
            {
                MediaFoundationDecoderNative.Shutdown();
            }
            catch (COMException)
            {
            }
        }
    }

    private int ReadOutput(out DecodedVideoFrame? decodedFrame)
    {
        nint providedSample = 0;
        nint outputSample = 0;
        var output = new MediaFoundationDecoderNative.OutputDataBuffer
        {
            StreamId = outputStreamId,
        };
        bool transformProvidesSamples =
            (outputInfo.Flags & (MediaFoundationDecoderNative.OutputProvidesSamples |
                MediaFoundationDecoderNative.OutputCanProvideSamples)) != 0;
        if (!transformProvidesSamples)
        {
            int nv12ByteCount = checked(
                (int)configuration.Width * (int)configuration.Height * 3 / 2);
            providedSample = MediaFoundationDecoderNative.CreateOutputSample(
                Math.Max(outputInfo.Size, checked((uint)nv12ByteCount)));
            output.Sample = providedSample;
        }

        try
        {
            int result = MediaFoundationDecoderNative.ProcessOutput(transform, ref output, out _);
            outputSample = output.Sample;
            if (result < 0)
            {
                decodedFrame = null;
                return result;
            }

            if (outputSample == 0)
            {
                throw new InvalidDataException("The H.264 decoder returned no output sample.");
            }

            int width = checked((int)configuration.Width);
            int height = checked((int)configuration.Height);
            long presentationTimestamp = FrameTimestampFromOutput(outputSample);
            if (gpuPresentation && videoDevice is not null)
            {
                nint texture = 0;
                try
                {
                    texture = MediaFoundationDecoderNative.GetDxgiTexture(outputSample, out uint subresource);
                    if (texture != 0)
                    {
                        presenter ??= new D3D11WpfConverter(videoDevice.Device, videoDevice.Context, width, height);
                        var surface = presenter.Convert(texture, subresource, color.Bt709, color.FullRange);
                        decodedFrame = new(width, height, checked(width * 4), ReadOnlyMemory<byte>.Empty, presentationTimestamp)
                        { HasGpuSurface = true, PresentationSurface = surface };
                        return result;
                    }
                }
                catch (Exception e) when (e is COMException or PlatformNotSupportedException)
                {
                    presenter?.Dispose(); presenter = null; gpuPresentation = false;
                }
                finally { MediaFoundationDecoderNative.Release(ref texture); }
            }
            byte[] nv12 = MediaFoundationDecoderNative.ReadSampleBytes(outputSample);
            byte[] bgra32 = Nv12ToBgra32Converter.Convert(nv12, width, height, bt709: color.Bt709, fullRange: color.FullRange);
            decodedFrame = new DecodedVideoFrame(
                width,
                height,
                checked(width * 4),
                bgra32,
                presentationTimestamp) { HasGpuSurface = MediaFoundationDecoderNative.HasDxgiBuffer(outputSample) };
            return result;
        }
        finally
        {
            if (output.Events != 0)
            {
                _ = Marshal.Release(output.Events);
            }

            if (outputSample != 0 && outputSample != providedSample)
            {
                MediaFoundationDecoderNative.Release(ref outputSample);
            }

            MediaFoundationDecoderNative.Release(ref providedSample);
        }
    }

    private long FrameTimestampFromOutput(nint outputSample)
    {
        if (!MediaFoundationDecoderNative.TryGetSampleTime(outputSample, out long timestamp100Nanoseconds))
        {
            throw new InvalidDataException("The H.264 decoder output has no presentation timestamp.");
        }

        return ScaleTimestamp(
            timestamp100Nanoseconds,
            HundredNanosecondTimescale,
            configuration.Timescale);
    }

    private void ConfigureInputType(nint mediaType)
    {
        MediaFoundationDecoderNative.SetGuid(
            mediaType,
            MediaFoundationDecoderNative.MajorType,
            MediaFoundationDecoderNative.MediaTypeVideo);
        MediaFoundationDecoderNative.SetGuid(
            mediaType,
            MediaFoundationDecoderNative.Subtype,
            configuration.Codec == PeelVideoCodec.Hevc ? Peel.Windows.Host.Encoding.MediaFoundationCodecCatalog.HevcSubtype : MediaFoundationDecoderNative.VideoFormatH264);
        MediaFoundationDecoderNative.SetSize(
            mediaType,
            MediaFoundationDecoderNative.FrameSize,
            configuration.Width,
            configuration.Height);
        MediaFoundationDecoderNative.SetRatio(
            mediaType,
            MediaFoundationDecoderNative.FrameRate,
            30,
            1);
        MediaFoundationDecoderNative.SetRatio(
            mediaType,
            MediaFoundationDecoderNative.PixelAspectRatio,
            1,
            1);
        MediaFoundationDecoderNative.SetUInt32(
            mediaType,
            MediaFoundationDecoderNative.InterlaceMode,
            ProgressiveInterlace);
        MediaFoundationDecoderNative.SetBlob(
            mediaType,
            MediaFoundationDecoderNative.MpegSequenceHeader,
            H264LengthPrefixed.CreateSequenceHeader(configuration));
    }

    private void ConfigureOutputType()
    {
        color = MediaFoundationDecoderNative.GetOutputColor(transform, outputStreamId);
        MediaFoundationDecoderNative.Release(ref outputType);
        outputType = MediaFoundationDecoderNative.CreateMediaType();
        MediaFoundationDecoderNative.SetGuid(
            outputType,
            MediaFoundationDecoderNative.MajorType,
            MediaFoundationDecoderNative.MediaTypeVideo);
        MediaFoundationDecoderNative.SetGuid(
            outputType,
            MediaFoundationDecoderNative.Subtype,
            MediaFoundationDecoderNative.VideoFormatNv12);
        MediaFoundationDecoderNative.SetSize(
            outputType,
            MediaFoundationDecoderNative.FrameSize,
            configuration.Width,
            configuration.Height);
        MediaFoundationDecoderNative.SetRatio(
            outputType,
            MediaFoundationDecoderNative.FrameRate,
            30,
            1);
        MediaFoundationDecoderNative.SetRatio(
            outputType,
            MediaFoundationDecoderNative.PixelAspectRatio,
            1,
            1);
        MediaFoundationDecoderNative.SetUInt32(
            outputType,
            MediaFoundationDecoderNative.InterlaceMode,
            ProgressiveInterlace);
        MediaFoundationDecoderNative.SetUInt32(
            outputType,
            MediaFoundationDecoderNative.DefaultStride,
            configuration.Width);
        MediaFoundationDecoderNative.SetOutputType(transform, outputStreamId, outputType);
        outputInfo = MediaFoundationDecoderNative.GetOutputStreamInfo(transform, outputStreamId);
    }

    private static long ScaleTimestamp(long value, uint sourceTimescale, uint destinationTimescale)
    {
        if (value < 0 || sourceTimescale == 0 || destinationTimescale == 0)
        {
            throw new InvalidDataException("The video timestamp is invalid.");
        }

        long whole = value / sourceTimescale;
        long remainder = value % sourceTimescale;
        try
        {
            return checked(
                (whole * destinationTimescale) +
                ((remainder * destinationTimescale) / sourceTimescale));
        }
        catch (OverflowException exception)
        {
            throw new InvalidDataException("The video timestamp is oversized.", exception);
        }
    }
}
