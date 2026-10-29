using System.IO;
using System.Runtime.InteropServices;

namespace Peel.Windows.Client.Services;

internal interface IMicrophoneCapture : IDisposable
{
    Task RunAsync(Func<byte[], CancellationToken, Task> send, CancellationToken token);
}

/// <summary>Explicitly started microphone capture. Six native mono PCM buffers; no file recording.</summary>
internal sealed class WaveMicrophoneCapture : IMicrophoneCapture
{
    private nint device;
    private readonly AutoResetEvent available = new(false);
    private readonly List<(nint Header, nint Data)> buffers = new();
    private int started;
    public static bool Available => waveInGetNumDevs() != 0;
    private static WaveFormat Format => new() { Tag = 1, Channels = 1, SampleRate = 48000, BytesPerSecond = 96000, BlockAlign = 2, BitsPerSample = 16 };
    internal static bool QueryFormat()
    {
        var format = Format;
        return waveInOpen(out _, uint.MaxValue, ref format, 0, 0, 1) == 0; // WAVE_FORMAT_QUERY: does not open or record.
    }
    internal WaveMicrophoneCapture()
    {
        var format = Format;
        try
        {
            Check(waveInOpen(out device, uint.MaxValue, ref format, available.SafeWaitHandle.DangerousGetHandle(), 0, 0x50000));
            for (int i = 0; i < 6; i++)
            {
                nint data = Marshal.AllocHGlobal(1920), header = Marshal.AllocHGlobal(Marshal.SizeOf<WaveHeader>());
                Marshal.StructureToPtr(new WaveHeader { Data = data, Length = 1920 }, header, false);
                buffers.Add((header, data));
                Check(waveInPrepareHeader(device, header, (uint)Marshal.SizeOf<WaveHeader>()));
                Check(waveInAddBuffer(device, header, (uint)Marshal.SizeOf<WaveHeader>()));
            }
        }
        catch { Dispose(); throw; }
    }
    public Task RunAsync(Func<byte[], CancellationToken, Task> send, CancellationToken token)
    {
        if (Interlocked.Exchange(ref started, 1) != 0) throw new InvalidOperationException("Microphone capture can start once.");
        return Task.Factory.StartNew(() =>
        {
            token.ThrowIfCancellationRequested(); Check(waveInStart(device));
            WaitHandle[] signals = [available, token.WaitHandle];
            int next = 0;
            while (true)
            {
                token.ThrowIfCancellationRequested();
                var buffer = buffers[next];
                var header = Marshal.PtrToStructure<WaveHeader>(buffer.Header);
                if ((header.Flags & 1) == 0) { _ = WaitHandle.WaitAny(signals, 500); continue; }
                if (header.Recorded > 1920) throw new IOException("The microphone returned an oversized audio buffer.");
                byte[]? pcm = null;
                if (header.Recorded == 1920) { pcm = new byte[1920]; Marshal.Copy(buffer.Data, pcm, 0, 1920); }
                Check(waveInAddBuffer(device, buffer.Header, (uint)Marshal.SizeOf<WaveHeader>()));
                next = (next + 1) % buffers.Count;
                if (pcm is not null) send(pcm, token).GetAwaiter().GetResult();
            }
        }, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
    }
    public void Dispose()
    {
        // Owner cancels and awaits RunAsync before disposal. Buffers must outlive native ownership.
        uint failure = 0;
        if (device != 0)
        {
            uint reset = waveInReset(device); if (reset != 0) failure = reset;
            for (int i = buffers.Count - 1; i >= 0; i--)
            {
                var buffer = buffers[i];
                uint result = waveInUnprepareHeader(device, buffer.Header, (uint)Marshal.SizeOf<WaveHeader>());
                if (result == 0) { Marshal.FreeHGlobal(buffer.Header); Marshal.FreeHGlobal(buffer.Data); buffers.RemoveAt(i); }
                else failure = result;
            }
            if (buffers.Count == 0)
            {
                uint close = waveInClose(device); if (close == 0) device = 0; else failure = close;
            }
        }
        if (device == 0) available.Dispose();
        if (failure != 0) throw new IOException($"Windows could not fully release microphone capture (code {failure}).");
    }
    private static void Check(uint code) { if (code != 0) throw new IOException($"Windows microphone access failed (code {code}). Check the selected input device and Windows microphone privacy settings."); }
    [StructLayout(LayoutKind.Sequential, Pack = 2)] private struct WaveFormat { public ushort Tag, Channels; public uint SampleRate, BytesPerSecond; public ushort BlockAlign, BitsPerSample, ExtraSize; }
    [StructLayout(LayoutKind.Sequential)] private struct WaveHeader { public nint Data; public uint Length, Recorded; public nuint User; public uint Flags, Loops; public nint Next; public nuint Reserved; }
    [DllImport("winmm.dll")] private static extern uint waveInGetNumDevs();
    [DllImport("winmm.dll")] private static extern uint waveInOpen(out nint device, uint id, ref WaveFormat format, nint callback, nint instance, uint flags);
    [DllImport("winmm.dll")] private static extern uint waveInPrepareHeader(nint device, nint header, uint bytes);
    [DllImport("winmm.dll")] private static extern uint waveInAddBuffer(nint device, nint header, uint bytes);
    [DllImport("winmm.dll")] private static extern uint waveInStart(nint device);
    [DllImport("winmm.dll")] private static extern uint waveInReset(nint device);
    [DllImport("winmm.dll")] private static extern uint waveInUnprepareHeader(nint device, nint header, uint bytes);
    [DllImport("winmm.dll")] private static extern uint waveInClose(nint device);
}
