using System.Buffers.Binary;
using Peel.Windows.Client.Services;
using Peel.Windows.Protocol;
namespace Peel.Linux;
internal sealed class LinuxDecoder(ulong sessionGeneration) : IVideoDecoderSink, IDisposable
{
    private readonly object gate = new();
    private IntPtr handle;
    private uint window;
    private uint timescale;
    private byte lengthBytes;
    private bool admitted;
    private bool disposed;
    /// <summary>Once per configured window, after its first access unit was actually
    /// accepted by the native decoder queue. Raised outside the decoder lock.</summary>
    public event Action<uint>? FirstFrameAdmitted;
    // Rendering happens in the actual native appsink/GTK popout. Do not invent
    // managed decoded-frame events from an encoded packet's successful enqueue.
    public event EventHandler<DecodedVideoFrameEventArgs>? FrameDecoded { add { } remove { } }
    public IReadOnlySet<PeelVideoCodec> SupportedCodecs { get; } = new HashSet<PeelVideoCodec> { PeelVideoCodec.H264 };
    public ValueTask ResetAsync(uint windowId, CancellationToken token)
    {
        token.ThrowIfCancellationRequested(); lock (gate) { ResetLocked(); }
        return ValueTask.CompletedTask;
    }
    public ValueTask ConfigureAsync(VideoConfigPacket config, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        if (config.Codec != PeelVideoCodec.H264 || config.Width is < 1 or > 8192 || config.Height is < 1 or > 8192
            || (ulong)config.Width * config.Height > 33_554_432 || config.Timescale == 0 || config.NalUnitHeaderLength is not (1 or 2 or 4)
            || config.Sps.Length is < 1 or > 524_288 || config.Pps.Length is < 1 or > 524_288) throw new InvalidDataException("Unsupported H264 configuration.");
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this); ResetLocked();
            handle = NativeUI.peel_linux_decoder_new(sessionGeneration, config.WindowId);
            if (handle == IntPtr.Zero) throw new IOException("Native Linux decoder unavailable.");
            window = config.WindowId; timescale = config.Timescale; lengthBytes = config.NalUnitHeaderLength;
            var parameters = new byte[8 + config.Sps.Length + config.Pps.Length];
            parameters[3] = 1; config.Sps.CopyTo(parameters, 4);
            parameters[7 + config.Sps.Length] = 1; config.Pps.CopyTo(parameters, 8 + config.Sps.Length);
            if (NativeUI.peel_linux_decoder_configure(handle, config.Width, config.Height, parameters, (nuint)parameters.Length) != 1)
            { ResetLocked(); throw new IOException("Native H264 pipeline could not start."); }
        }
        return ValueTask.CompletedTask;
    }
    public ValueTask SubmitAsync(VideoFramePacket frame, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        bool first; uint admittedWindow;
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (handle == IntPtr.Zero || frame.WindowId != window || frame.Payload.Length > 8_388_608 || frame.PtsValue < 0 || frame.DurationValue < 0)
                throw new InvalidDataException("Frame does not belong to configured Linux decoder.");
            var bytes = ToAnnexB(frame.Payload, lengthBytes);
            ulong pts = Nanoseconds(frame.PtsValue, timescale), duration = Nanoseconds(frame.DurationValue, timescale);
            if (NativeUI.peel_linux_decoder_push(handle, bytes, (nuint)bytes.Length, pts, duration) != 1)
                throw new IOException("Native decoder failed or its bounded queue is full.");
            first = !admitted; admitted = true; admittedWindow = window;
        }
        if (first) FirstFrameAdmitted?.Invoke(admittedWindow);
        return ValueTask.CompletedTask;
    }
    internal static ulong Nanoseconds(long value, uint scale) => checked((ulong)(((UInt128)(ulong)value * 1_000_000_000) / scale));
    internal static byte[] ToAnnexB(ReadOnlySpan<byte> input, int prefix)
    {
        if (prefix is not (1 or 2 or 4) || input.Length is < 1 or > 8_388_608) throw new InvalidDataException("Invalid AVC access unit.");
        using var output = new MemoryStream(); int offset = 0, count = 0;
        while (offset < input.Length)
        {
            if (input.Length - offset < prefix || ++count > 65_536) throw new InvalidDataException("Truncated or excessive NAL units.");
            uint size = prefix == 1 ? input[offset] : prefix == 2 ? BinaryPrimitives.ReadUInt16BigEndian(input[offset..]) : BinaryPrimitives.ReadUInt32BigEndian(input[offset..]);
            offset += prefix;
            if (size == 0 || size > input.Length - offset || output.Length + 4 + size > 8_388_608) throw new InvalidDataException("Invalid bounded NAL size.");
            output.Write(new byte[] { 0, 0, 0, 1 }); output.Write(input.Slice(offset, (int)size)); offset += (int)size;
        }
        return output.ToArray();
    }
    private void ResetLocked()
    {
        if (handle != IntPtr.Zero) NativeUI.peel_linux_decoder_free(handle);
        handle = IntPtr.Zero; window = 0; timescale = 0; lengthBytes = 0; admitted = false;
    }
    public void Dispose() { lock (gate) { if (disposed) return; disposed = true; ResetLocked(); } }
}
