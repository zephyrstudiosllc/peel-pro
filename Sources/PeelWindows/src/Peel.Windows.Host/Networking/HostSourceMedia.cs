using System.Diagnostics;
using Peel.Windows.Protocol;

namespace Peel.Windows.Host.Networking;

internal enum HostSourceMediaLimit
{
    Media,
    VolumeSet,
    VolumeQuery,
}

internal readonly record struct HostSourceMediaRefusal(SourceMediaStatus Status, SourceMediaReason Reason);

/// <summary>
/// Sliding one-second admission per control session. A replacement session owns a new
/// limiter, so it always starts empty. Only the session read loop calls it.
/// </summary>
internal sealed class HostSourceMediaLimiter(Func<long>? timestamp = null)
{
    private readonly Func<long> timestamp = timestamp ?? Stopwatch.GetTimestamp;
    private readonly Queue<long>[] admitted = [new(), new(), new()];

    internal bool TryAdmit(HostSourceMediaLimit kind)
    {
        int perSecond = kind switch
        {
            HostSourceMediaLimit.Media => SourceMediaProtocol.MediaActionsPerSecond,
            HostSourceMediaLimit.VolumeSet => SourceMediaProtocol.VolumeSetsPerSecond,
            HostSourceMediaLimit.VolumeQuery => SourceMediaProtocol.VolumeQueriesPerSecond,
            _ => 0,
        };
        Queue<long> times = admitted[(int)kind];
        long now = timestamp();
        while (times.Count > 0 && now - times.Peek() >= Stopwatch.Frequency) times.Dequeue();
        if (times.Count >= perSecond) return false;
        times.Enqueue(now);
        return true;
    }
}

internal static class HostSourceMedia
{
    private static long volumeSequence;

    /// <summary>Monotonic per source process, as the contract requires for sourceVolumeState.</summary>
    internal static ulong NextVolumeSequence() => unchecked((ulong)Interlocked.Increment(ref volumeSequence));

    /// <summary>
    /// Actual systemOutput state for one request. No output is unsupported/noOutputDevice; an output
    /// with no readable control is unsupported/fixedVolume; read-only values say fixedVolume.
    /// </summary>
    internal static SourceVolumeStateMessage SystemOutputState(string requestId, string pairingId, uint windowId,
        Audio.SourceVolumeReading reading, ulong sequence)
    {
        if (reading.DeviceId is null)
            return SourceVolumeStateMessage.Unsupported(requestId, pairingId, windowId, SourceVolumeScope.SystemOutput,
                sequence, SourceMediaReason.NoOutputDevice);
        if (reading.Volume is null && reading.Muted is null)
            return SourceVolumeStateMessage.Unsupported(requestId, pairingId, windowId, SourceVolumeScope.SystemOutput,
                sequence, SourceMediaReason.FixedVolume);
        bool canSetVolume = reading.CanSetVolume && reading.Volume is not null;
        bool canSetMute = reading.CanSetMute && reading.Muted is not null;
        return SourceVolumeStateMessage.Create(requestId, pairingId, windowId, SourceVolumeScope.SystemOutput, true,
            canSetVolume, canSetMute, reading.Volume, reading.Muted, sequence,
            canSetVolume || canSetMute ? null : SourceMediaReason.FixedVolume);
    }
}
