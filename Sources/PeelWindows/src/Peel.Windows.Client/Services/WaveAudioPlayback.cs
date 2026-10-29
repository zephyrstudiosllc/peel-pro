using System.IO;
using System.Runtime.InteropServices;

namespace Peel.Windows.Client.Services;

/// <summary>Native Windows PCM playback with six owned 20ms buffers. No unbounded jitter queue.</summary>
public sealed class WaveAudioPlayback : IDisposable
{
    private readonly object gate = new();
    private nint device;
    private readonly List<(nint Header, nint Data)> buffers = new();
    public static bool Available => waveOutGetNumDevs() > 0;
    public WaveAudioPlayback()
    {
        var format = new WaveFormat { Tag = 1, Channels = 2, SampleRate = 48000, BytesPerSecond = 192000, BlockAlign = 4, BitsPerSample = 16 };
        Check(waveOutOpen(out device, uint.MaxValue, ref format, 0, 0, 0));
        try
        {
            for (int i = 0; i < 6; i++)
            {
                nint data = Marshal.AllocHGlobal(3840), header = Marshal.AllocHGlobal(Marshal.SizeOf<WaveHeader>());
                Marshal.StructureToPtr(new WaveHeader { Data = data, Length = 3840 }, header, false);
                buffers.Add((header, data));
                Check(waveOutPrepareHeader(device, header, (uint)Marshal.SizeOf<WaveHeader>()));
            }
        }
        catch { Dispose(); throw; }
    }
    public bool Offer(ReadOnlySpan<byte> stereoPcm)
    {
        if (stereoPcm.Length != 3840) throw new InvalidDataException("Playback expects exactly 960 stereo S16LE frames.");
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(device == 0, this);
            foreach (var buffer in buffers)
            {
                var header = Marshal.PtrToStructure<WaveHeader>(buffer.Header);
                if ((header.Flags & 0x10) != 0) continue; // WHDR_INQUEUE
                CopyPcm(stereoPcm, buffer.Data);
                Check(waveOutWrite(device, buffer.Header, (uint)Marshal.SizeOf<WaveHeader>())); return true;
            }
            return false; // Audio can drop under backpressure; queued latency remains at most 120ms.
        }
    }
    public void Dispose()
    {
        lock (gate)
        {
            if (device == 0) return;
            uint failure = waveOutReset(device);
            for (int i = buffers.Count - 1; i >= 0; i--)
            {
                var buffer = buffers[i];
                // Do not free a header still owned by a failed driver reset.
                uint result = waveOutUnprepareHeader(device, buffer.Header, (uint)Marshal.SizeOf<WaveHeader>());
                if (result == 0) { Marshal.FreeHGlobal(buffer.Header); Marshal.FreeHGlobal(buffer.Data); buffers.RemoveAt(i); }
                else failure = result;
            }
            if (buffers.Count == 0)
            {
                uint close = waveOutClose(device); if (close == 0) device = 0; else failure = close;
            }
            if (failure != 0) throw new IOException($"Windows could not fully release audio playback (code {failure}).");
        }
    }
    private static unsafe void CopyPcm(ReadOnlySpan<byte> pcm, nint destination)
    {
        fixed (byte* source = pcm) Buffer.MemoryCopy(source, (void*)destination, 3840, 3840);
    }
    private static void Check(uint code) { if (code != 0) throw new IOException($"Windows audio output failed (code {code})."); }
    [StructLayout(LayoutKind.Sequential, Pack = 2)] private struct WaveFormat { public ushort Tag, Channels; public uint SampleRate, BytesPerSecond; public ushort BlockAlign, BitsPerSample, ExtraSize; }
    [StructLayout(LayoutKind.Sequential)] private struct WaveHeader { public nint Data; public uint Length, Recorded; public nuint User; public uint Flags, Loops; public nint Next; public nuint Reserved; }
    [DllImport("winmm.dll")] private static extern uint waveOutGetNumDevs();
    [DllImport("winmm.dll")] private static extern uint waveOutOpen(out nint device, uint id, ref WaveFormat format, nint callback, nint instance, uint flags);
    [DllImport("winmm.dll")] private static extern uint waveOutPrepareHeader(nint device, nint header, uint bytes);
    [DllImport("winmm.dll")] private static extern uint waveOutWrite(nint device, nint header, uint bytes);
    [DllImport("winmm.dll")] private static extern uint waveOutReset(nint device);
    [DllImport("winmm.dll")] private static extern uint waveOutUnprepareHeader(nint device, nint header, uint bytes);
    [DllImport("winmm.dll")] private static extern uint waveOutClose(nint device);
}
