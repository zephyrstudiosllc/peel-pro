using System.Net.NetworkInformation;
using System.Windows;
using System.Windows.Threading;

namespace Peel.Windows.Client.Services;

internal sealed class WindowsHostNetworkMonitor : IDisposable
{
    private readonly Action callback;
    private readonly Action<Action> schedule;
    private readonly bool subscribedToSystem;
    private int callbackScheduled;
    private int disposed;

    internal WindowsHostNetworkMonitor(Window window, Action callback)
    {
        ArgumentNullException.ThrowIfNull(window);
        this.callback = callback ?? throw new ArgumentNullException(nameof(callback));
        Dispatcher dispatcher = window.Dispatcher;
        schedule = action =>
        {
            _ = dispatcher.BeginInvoke(DispatcherPriority.Background, action);
        };
        NetworkChange.NetworkAddressChanged += NetworkAddressChanged;
        subscribedToSystem = true;
    }

    internal WindowsHostNetworkMonitor(Action callback, Action<Action> schedule)
    {
        this.callback = callback ?? throw new ArgumentNullException(nameof(callback));
        this.schedule = schedule ?? throw new ArgumentNullException(nameof(schedule));
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0)
        {
            return;
        }

        if (subscribedToSystem)
        {
            NetworkChange.NetworkAddressChanged -= NetworkAddressChanged;
        }
    }

    internal void NotifyAddressChangedForTesting() => QueueCallback();

    private void NetworkAddressChanged(object? sender, EventArgs eventArgs)
    {
        _ = sender;
        _ = eventArgs;
        QueueCallback();
    }

    private void QueueCallback()
    {
        if (Volatile.Read(ref disposed) != 0 ||
            Interlocked.Exchange(ref callbackScheduled, 1) != 0)
        {
            return;
        }

        try
        {
            schedule(DeliverCallback);
        }
        catch
        {
            Interlocked.Exchange(ref callbackScheduled, 0);
        }
    }

    private void DeliverCallback()
    {
        Interlocked.Exchange(ref callbackScheduled, 0);
        if (Volatile.Read(ref disposed) != 0)
        {
            return;
        }

        try
        {
            callback();
        }
        catch
        {
            // A Windows network notification cannot destabilize WPF dispatch.
        }
    }
}
