using Peel.Windows.Protocol;

namespace Peel.Windows.Host.Audio;

public interface IHostAudioCapture : IAsyncDisposable
{
    Task Completion { get; }
    ValueTask StartAsync(Action<AudioPacket> onPacket, CancellationToken cancellationToken);
}

/// <summary>One bounded 20 ms assembly buffer. Discontinuities never join unrelated sample ranges.</summary>
internal sealed class HostPcmFramer(Action<AudioPacket> onPacket)
{
    private byte[] pending = new byte[AudioPacket.Frames * 4];
    private int used;
    private long start, next;
    private ulong sequence;
    internal void Append(ReadOnlySpan<byte> bytes, long sampleTime, bool discontinuity = false)
    {
        if (sampleTime < 0 || bytes.Length % 4 != 0 || bytes.Length > 48000 * 4)
            throw new InvalidDataException("Invalid captured stereo audio buffer.");
        if (discontinuity || used != 0 && sampleTime != next) used = 0;
        while (!bytes.IsEmpty)
        {
            if (used == 0) start = sampleTime;
            int count = Math.Min(pending.Length - used, bytes.Length);
            bytes[..count].CopyTo(pending.AsSpan(used)); used += count;
            sampleTime = checked(sampleTime + count / 4); next = sampleTime; bytes = bytes[count..];
            if (used == pending.Length)
            {
                var packet = new AudioPacket(1, 0, sequence++, start, pending);
                pending = new byte[AudioPacket.Frames * 4]; used = 0;
                onPacket(packet);
            }
        }
    }
}
