namespace Peel.Windows.Host.Capture;

internal sealed class LatestFramePump<T> : IDisposable
    where T : class, IDisposable
{
    private readonly object stateLock = new();
    private readonly SemaphoreSlim available = new(0, 1);
    private T? pending;
    private Exception? terminalError;
    private bool completed;
    private bool disposed;

    internal void Publish(T item)
    {
        ArgumentNullException.ThrowIfNull(item);

        T? replaced = null;
        var release = false;
        lock (stateLock)
        {
            if (completed || disposed)
            {
                replaced = item;
            }
            else
            {
                replaced = pending;
                pending = item;
                release = replaced is null;
            }
        }

        replaced?.Dispose();
        if (release)
        {
            available.Release();
        }
    }

    internal void Complete(Exception? error = null)
    {
        T? abandoned;
        var release = false;
        lock (stateLock)
        {
            if (completed || disposed)
            {
                return;
            }

            completed = true;
            terminalError = error;
            abandoned = pending;
            pending = null;
            release = available.CurrentCount == 0;
        }

        abandoned?.Dispose();
        if (release)
        {
            available.Release();
        }
    }

    internal void DropPending()
    {
        T? abandoned;
        lock (stateLock)
        {
            abandoned = pending;
            pending = null;
        }

        abandoned?.Dispose();
    }

    internal async Task RunAsync(
        Func<T, CancellationToken, ValueTask> handler,
        CancellationToken cancellationToken,
        Action? afterItemDisposed = null)
    {
        ArgumentNullException.ThrowIfNull(handler);

        while (true)
        {
            await available.WaitAsync(cancellationToken).ConfigureAwait(false);

            T? item;
            Exception? error;
            bool isCompleted;
            lock (stateLock)
            {
                ObjectDisposedException.ThrowIf(disposed, this);
                item = pending;
                pending = null;
                error = terminalError;
                isCompleted = completed;
            }

            if (item is null)
            {
                if (error is not null)
                {
                    throw new InvalidOperationException("Windows capture stopped unexpectedly.", error);
                }

                if (isCompleted)
                {
                    return;
                }

                continue;
            }

            using (item)
            {
                await handler(item, cancellationToken).ConfigureAwait(false);
            }

            afterItemDisposed?.Invoke();
        }
    }

    public void Dispose()
    {
        T? abandoned;
        lock (stateLock)
        {
            if (disposed)
            {
                return;
            }

            disposed = true;
            completed = true;
            abandoned = pending;
            pending = null;
        }

        abandoned?.Dispose();
        available.Dispose();
    }
}
