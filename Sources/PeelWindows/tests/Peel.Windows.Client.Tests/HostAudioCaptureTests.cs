using Peel.Windows.Client.Services;
using Peel.Windows.Host.Audio;
using Peel.Windows.Protocol;

namespace Peel.Windows.Client.Tests;

internal static partial class Program
{
    private static void HostPcmFramesAreBounded()
    {
        var packets = new List<AudioPacket>(); var framer = new HostPcmFramer(packets.Add);
        framer.Append(new byte[400], 100); Equal(0, packets.Count);
        framer.Append(Enumerable.Repeat((byte)1, 3440).ToArray(), 200); Equal(1, packets.Count);
        Equal(100L, packets[0].SampleTime); Equal(0UL, packets[0].Sequence); packets[0].Validate();
        True(packets[0].Payload.AsSpan(0, 400).IndexOfAnyExcept((byte)0) < 0, "Partial input keeps its exact PCM bytes.");
        True(packets[0].Payload.AsSpan(400).IndexOfAnyExcept((byte)1) < 0, "The next contiguous range completes the packet.");
        framer.Append(new byte[400], 1060); framer.Append(new byte[3840], 9000, true);
        Equal(2, packets.Count); Equal(9000L, packets[1].SampleTime); Equal(1UL, packets[1].Sequence);
        framer.Append(new byte[7680], 9960); Equal(4, packets.Count); Equal(10920L, packets[3].SampleTime);
        Throws<InvalidDataException>(() => framer.Append(new byte[3], 1));
        Throws<InvalidDataException>(() => framer.Append(new byte[4], -1));
        Throws<InvalidDataException>(() => framer.Append(new byte[192004], 0));
    }
    private static async Task<int> NativeProcessLoopbackAsync()
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(12));
        await using var capture = new WindowsLoopbackAudioCapture((uint)Environment.ProcessId, includeProcess: true);
        int count = 0, peak = 0; long previous = -1;
        var gotAudio = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await capture.StartAsync(packet =>
        {
            packet.Validate();
            int packetPeak = 0;
            for (int i = 0; i < packet.Payload.Length; i += 2) packetPeak = Math.Max(packetPeak, Math.Abs((int)System.Buffers.Binary.BinaryPrimitives.ReadInt16LittleEndian(packet.Payload.AsSpan(i))));
            peak = Math.Max(peak, packetPeak);
            True(packetPeak <= 1, $"Generated silence permits only one-bit conversion dither (peak={packetPeak}).");
            True(packet.SampleTime >= previous, "Captured sample positions must not regress."); previous = packet.SampleTime;
            if (Interlocked.Increment(ref count) >= 10) gotAudio.TrySetResult();
        }, timeout.Token);
        using var playback = new WaveAudioPlayback();
        for (int i = 0; i < 80 && !gotAudio.Task.IsCompleted; i++)
        {
            if (capture.Completion.IsCompleted) await capture.Completion;
            _ = playback.Offer(new byte[3840]); await Task.Delay(20, timeout.Token);
        }
        await gotAudio.Task.WaitAsync(timeout.Token);
        await capture.DisposeAsync(); await capture.Completion;
        Console.WriteLine($"PASS native WASAPI process loopback: {count} actual 48kHz stereo S16LE packets from owned generated silence (peak={peak}); same-thread capture release and clean stop. Other apps and microphones were excluded.");
        return 0;
    }
}
