namespace Peel.Windows.Host.Capture;

internal sealed class CaptureTimestampClock
{
    private readonly object stateLock = new();
    private long lastTimestamp = -1;

    internal long Next(TimeSpan systemRelativeTime)
    {
        lock (stateLock)
        {
            long candidate = Math.Max(0, systemRelativeTime.Ticks);
            if (candidate <= lastTimestamp)
            {
                if (lastTimestamp == long.MaxValue)
                {
                    throw new InvalidDataException("The capture timestamp range was exhausted.");
                }

                candidate = lastTimestamp + 1;
            }

            lastTimestamp = candidate;
            return candidate;
        }
    }
}
