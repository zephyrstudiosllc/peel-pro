using Peel.Windows.Host.Capture;

namespace Peel.Windows.Host.Orchestration;

internal sealed class LatestRawFrameQueue(Action? onReplaced = null) : IDisposable
{
    private readonly object stateLock = new();
    private readonly SemaphoreSlim available = new(0, 1);
    private CapturedFrame? pending;
    private bool completed;
    private bool disposed;

    internal void Publish(CapturedFrame frame)
    {
        ArgumentNullException.ThrowIfNull(frame);

        var release = false;
        CapturedFrame? replaced;
        lock (stateLock)
        {
            // Ownership transfers on every publish, including a late frame during shutdown.
            if (completed || disposed)
            {
                frame.Dispose();
                return;
            }

            release = pending is null;
            replaced = pending;
            pending = frame;
        }
        replaced?.Dispose();
        if (replaced is not null) onReplaced?.Invoke();

        if (release)
        {
            available.Release();
        }
    }

    internal void Complete()
    {
        var release = false;
        lock (stateLock)
        {
            if (completed || disposed)
            {
                return;
            }

            completed = true;
            release = pending is null && available.CurrentCount == 0;
        }

        if (release)
        {
            available.Release();
        }
    }

    internal async Task RunAsync(
        Func<CapturedFrame, CancellationToken, ValueTask> handler,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(handler);

        while (true)
        {
            await available.WaitAsync(cancellationToken).ConfigureAwait(false);

            CapturedFrame? frame;
            bool isCompleted;
            lock (stateLock)
            {
                ObjectDisposedException.ThrowIf(disposed, this);
                frame = pending;
                pending = null;
                isCompleted = completed;
            }

            if (frame is null)
            {
                if (isCompleted)
                {
                    return;
                }

                continue;
            }

            using (frame) await handler(frame, cancellationToken).ConfigureAwait(false);

            lock (stateLock)
            {
                if (completed && pending is null)
                {
                    return;
                }
            }
        }
    }

    public void Dispose()
    {
        lock (stateLock)
        {
            if (disposed)
            {
                return;
            }

            disposed = true;
            completed = true;
            pending?.Dispose();
            pending = null;
        }

        available.Dispose();
    }
}
