using System.ComponentModel;
using System.Drawing;
using System.Windows;
using Forms = System.Windows.Forms;

namespace Peel.Windows.Client.Services;

internal sealed class TrayWindowClosePolicy
{
    private int exitRequested;

    internal bool ShouldHideWindow => Volatile.Read(ref exitRequested) == 0;

    internal void AllowExit() => Interlocked.Exchange(ref exitRequested, 1);
}

internal sealed class WindowsTrayController : IDisposable
{
    private readonly Window window;
    private readonly TrayWindowClosePolicy closePolicy;
    private readonly Icon icon;
    private readonly Forms.ContextMenuStrip menu;
    private readonly Forms.ToolStripMenuItem openItem;
    private readonly Forms.ToolStripMenuItem exitItem;
    private readonly Forms.NotifyIcon notifyIcon;
    private bool hideNoticeShown;
    private bool disposed;

    internal WindowsTrayController(
        Window window,
        TrayWindowClosePolicy? closePolicy = null)
    {
        this.window = window ?? throw new ArgumentNullException(nameof(window));
        this.closePolicy = closePolicy ?? new TrayWindowClosePolicy();
        icon = CreateTrayIcon();
        openItem = new Forms.ToolStripMenuItem("Open Peel Pro");
        exitItem = new Forms.ToolStripMenuItem("Exit Peel Pro");
        menu = new Forms.ContextMenuStrip();
        _ = menu.Items.Add(openItem);
        if (window is MainWindow main)
        {
            _ = menu.Items.Add("App Mechanic", null, (_, _) => QueueOnWindowDispatcher(() => { ShowWindow(); main.ShowUtilities(0); }));
            _ = menu.Items.Add("Usage Limits", null, (_, _) => QueueOnWindowDispatcher(() => { ShowWindow(); main.ShowUtilities(1); }));
            _ = menu.Items.Add("Compact bar", null, (_, _) => QueueOnWindowDispatcher(() => main.Utilities.ShowUsageBar?.Invoke()));
        }
        _ = menu.Items.Add(new Forms.ToolStripSeparator());
        _ = menu.Items.Add(exitItem);
        notifyIcon = new Forms.NotifyIcon
        {
            ContextMenuStrip = menu,
            Icon = icon,
            Text = "Peel Pro",
            Visible = true,
        };

        window.Closing += Window_Closing;
        openItem.Click += OpenItem_Click;
        exitItem.Click += ExitItem_Click;
        notifyIcon.DoubleClick += NotifyIcon_DoubleClick;
        if (window is MainWindow owner)
        {
            owner.Utilities.Updated += Utilities_Updated;
            owner.Utilities.AlertRaised += Utilities_AlertRaised;
        }
    }

    private void Utilities_Updated(object? sender, EventArgs e)
    {
        if (disposed || window is not MainWindow owner) return;
        string text = string.IsNullOrWhiteSpace(owner.Utilities.TraySummary)
            ? "Peel Pro" : "Peel Pro · " + owner.Utilities.TraySummary;
        notifyIcon.Text = text.Length <= 127 ? text : text[..127];
    }
    private void Utilities_AlertRaised(object? sender, string message)
    {
        if (!disposed) notifyIcon.ShowBalloonTip(5000, "App Mechanic", message, Forms.ToolTipIcon.Warning);
    }

    internal void AllowExit() => closePolicy.AllowExit();

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        if (window is MainWindow owner)
        {
            owner.Utilities.Updated -= Utilities_Updated;
            owner.Utilities.AlertRaised -= Utilities_AlertRaised;
        }
        window.Closing -= Window_Closing;
        openItem.Click -= OpenItem_Click;
        exitItem.Click -= ExitItem_Click;
        notifyIcon.DoubleClick -= NotifyIcon_DoubleClick;
        notifyIcon.Visible = false;
        notifyIcon.Dispose();
        menu.Dispose();
        icon.Dispose();
    }

    private void Window_Closing(object? sender, CancelEventArgs e)
    {
        _ = sender;
        if (!closePolicy.ShouldHideWindow)
        {
            return;
        }

        e.Cancel = true;
        window.Hide();
        if (!hideNoticeShown)
        {
            hideNoticeShown = true;
            notifyIcon.ShowBalloonTip(
                3000,
                "Peel Pro is still hosting",
                "Use the Peel Pro tray icon to reopen or exit the app.",
                Forms.ToolTipIcon.Info);
        }
    }

    private void OpenItem_Click(object? sender, EventArgs e)
    {
        _ = sender;
        _ = e;
        QueueOnWindowDispatcher(ShowWindow);
    }

    private void ExitItem_Click(object? sender, EventArgs e)
    {
        _ = sender;
        _ = e;
        QueueOnWindowDispatcher(() =>
        {
            closePolicy.AllowExit();
            window.Close();
        });
    }

    private void NotifyIcon_DoubleClick(object? sender, EventArgs e)
    {
        _ = sender;
        _ = e;
        QueueOnWindowDispatcher(ShowWindow);
    }

    private void ShowWindow()
    {
        if (!window.IsVisible)
        {
            window.Show();
        }
        if (window.WindowState == WindowState.Minimized)
        {
            window.WindowState = WindowState.Normal;
        }

        _ = window.Activate();
    }

    private void QueueOnWindowDispatcher(Action action)
    {
        if (!window.Dispatcher.HasShutdownStarted)
        {
            _ = window.Dispatcher.BeginInvoke(action);
        }
    }

    private static Icon CreateTrayIcon()
    {
        string? executablePath = Environment.ProcessPath;
        if (!string.IsNullOrWhiteSpace(executablePath))
        {
            using Icon? executableIcon = Icon.ExtractAssociatedIcon(executablePath);
            if (executableIcon is not null)
            {
                return (Icon)executableIcon.Clone();
            }
        }

        return (Icon)SystemIcons.Application.Clone();
    }
}
