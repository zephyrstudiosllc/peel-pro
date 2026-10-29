using System.Buffers.Binary;
using Peel.Windows.Protocol;
namespace Peel.Linux.Host;
internal sealed record LinuxHostEncoded(ulong SourceGeneration, ulong EncoderGeneration, ulong ConfigurationGeneration,
    uint SourceId, uint Width, uint Height, uint Timescale, long Pts, long Duration, bool Keyframe, byte[] Avcc, byte[] Sps, byte[] Pps);
internal sealed class LinuxHostVideoQueue : IDisposable
{
    internal const int MaxBytes = 8 * 1024 * 1024, MaxFrames = 2;
    private readonly object gate = new();
    private readonly Queue<(LinuxHostEncoded frame, Guid recovery)> queue = new();
    private Guid recovery = Guid.NewGuid();
    private readonly SemaphoreSlim ready = new(0);
    private readonly LinuxHostAuthority authority;
    private readonly LinuxHostReservation reservation;
    private bool closed, waitingForIdr = true;
    private int bytes;
    private ulong config;
    private byte[] sps = [], pps = [];
    private long pts = -1;
    internal LinuxHostVideoQueue(LinuxHostAuthority authority, LinuxHostReservation reservation) { this.authority = authority; this.reservation = reservation; }
    internal bool CanCopy(int size) { lock (gate) return !closed && size > 0 && size <= MaxBytes && queue.Count < MaxFrames && bytes <= MaxBytes - size; }
    internal bool TryEnqueue(LinuxHostEncoded frame)
    {
        if (!authority.IsCurrent(reservation)) return false;
        lock (gate)
        {
            int size = checked(frame.Avcc.Length + frame.Sps.Length + frame.Pps.Length);
            if (closed || frame.SourceGeneration != reservation.Capture.Generation
                || frame.EncoderGeneration != reservation.Encoder || frame.SourceId != reservation.Capture.SourceId
                || frame.Width != reservation.Capture.Width || frame.Height != reservation.Capture.Height || frame.Timescale != 1_000_000_000
                || frame.ConfigurationGeneration == 0 || frame.Pts < 0 || frame.Duration < 0 || frame.Duration > long.MaxValue - frame.Pts || frame.Pts <= pts || !ValidateAvcc(frame.Avcc, frame.Keyframe)) return false;
            if (queue.Count >= MaxFrames || size > MaxBytes || bytes > MaxBytes - size)
            { DropLocked(); return false; }
            if (frame.ConfigurationGeneration < config) return false;
            if (frame.ConfigurationGeneration == config && (!frame.Sps.AsSpan().SequenceEqual(sps) || !frame.Pps.AsSpan().SequenceEqual(pps))) return false;
            if (waitingForIdr || frame.ConfigurationGeneration != config)
            {
                if (!frame.Keyframe || !Parameters(frame.Sps, 7) || !Parameters(frame.Pps, 8)) return false;
                config = frame.ConfigurationGeneration; sps = frame.Sps; pps = frame.Pps; waitingForIdr = false;
            }
            else if (frame.Keyframe && (!Parameters(frame.Sps, 7) || !Parameters(frame.Pps, 8))) return false;
            pts = frame.Pts; queue.Enqueue((frame,recovery)); bytes += size; ready.Release(); return true;
        }
    }
    internal static bool Parameters(byte[] bytes, int type) => bytes.Length is > 0 and <= 524288 && (bytes[0] & 31) == type && (bytes[0] & 128) == 0;
    internal static bool ValidateAvcc(byte[] data, bool claimedIdr)
    {
        if (data.Length is < 5 or > MaxBytes) return false;
        int offset = 0; bool idr = false, vcl = false; int count = 0;
        while (offset < data.Length)
        {
            if (data.Length - offset < 5 || ++count > 1024) return false;
            uint n = BinaryPrimitives.ReadUInt32BigEndian(data.AsSpan(offset, 4)); offset += 4;
            if (n == 0 || n > (uint)(data.Length - offset)) return false;
            byte header = data[offset]; int type = header & 31;
            if ((header & 128) != 0 || type is 0 or > 23 || type is 7 or 8) return false;
            if (type is 1 or 5) vcl = true;
            if (type == 5) idr = true;
            offset += checked((int)n);
        }
        return vcl && idr == claimedIdr;
    }
    private void DropLocked() { recovery = Guid.NewGuid(); queue.Clear(); bytes = 0; waitingForIdr = true; }
    private ValueTask AdmitOutput(Guid expected, Func<ValueTask> launch)
    {
        lock (gate) { if (closed || recovery != expected) throw new OperationCanceledException("Queued output was retired by recovery."); return launch(); }
    }
    internal void Recover() { lock (gate) DropLocked(); }
    internal void Close() { lock (gate) { if (closed) return; closed = true; DropLocked(); ready.Release(); } }
    internal async Task WriteAsync(CancellationToken token)
    {
        ulong sentConfig = 0; long lastPts = -1;
        while (true)
        {
            await ready.WaitAsync(token).ConfigureAwait(false);
            LinuxHostEncoded? f; Guid epoch;
            lock (gate)
            {
                if (closed) return;
                if (queue.Count == 0) continue;
                var item = queue.Dequeue(); f = item.frame; epoch = item.recovery;
                bytes -= f.Avcc.Length + f.Sps.Length + f.Pps.Length;
            }
            if (!authority.IsCurrent(reservation) || f.Pts <= lastPts) throw new OperationCanceledException();
            using var write = CancellationTokenSource.CreateLinkedTokenSource(token); write.CancelAfter(TimeSpan.FromSeconds(3));
            if (f.Keyframe)
            {
                byte[] configBytes = new VideoConfigPacket(1, PeelVideoCodec.H264, f.Width, f.Height, f.Timescale, 4, f.Sps, f.Pps).Encode();
                await authority.Dispatch(reservation, configBytes, write.Token, launch => AdmitOutput(epoch,launch)).ConfigureAwait(false); sentConfig = f.ConfigurationGeneration;
            }
            if (sentConfig != f.ConfigurationGeneration) throw new InvalidDataException("Dependent frame before current IDR configuration.");
            byte[] packetBytes = new VideoFramePacket(1, f.Keyframe, f.Pts, f.Duration, f.Avcc).Encode();
            await authority.Dispatch(reservation, packetBytes, write.Token, launch => AdmitOutput(epoch,launch)).ConfigureAwait(false); lastPts = f.Pts;
        }
    }
    public void Dispose() => Close(); // Semaphore stays alive until owned writer drains.
}
