using System.Windows;
using Peel.Windows.Client.Services;
using Peel.Windows.Client.ViewModels;
using WpfApplication = System.Windows.Application;
using WpfMessageBox = System.Windows.MessageBox;

namespace Peel.Windows.Client;

public partial class App : WpfApplication
{
    private MainWindowViewModel? _mainWindowViewModel;
    private SingleInstanceLease? _singleInstanceLease;
    private WindowsTrayController? _trayController;
    private ProductionClientServices? _clientServices;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        try
        {
            _singleInstanceLease = SingleInstanceLease.TryAcquire();
        }
        catch (Exception exception)
        {
            WpfMessageBox.Show(
                $"Peel Pro could not verify that it is the only running copy.\n\n{exception.Message}",
                "Peel Pro",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            Shutdown(1);
            return;
        }

        if (_singleInstanceLease is null)
        {
            WpfMessageBox.Show(
                "Peel Pro is already running for this Windows account.",
                "Peel Pro",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
            Shutdown();
            return;
        }

        try
        {
            var services = _clientServices = new ProductionClientServices();
            _mainWindowViewModel = new MainWindowViewModel(services, services, services, services, services);
        }
        catch (Exception exception) when (exception is System.IO.IOException or UnauthorizedAccessException
            or System.Text.Json.JsonException or ArgumentException or InvalidOperationException)
        {
            var unavailable = new UnavailableClientServices("Client settings could not be loaded. " + exception.Message);
            _mainWindowViewModel = new MainWindowViewModel(unavailable, unavailable, unavailable, unavailable, unavailable);
        }

        var window = new MainWindow
        {
            DataContext = _mainWindowViewModel
        };

        MainWindow = window;
        _trayController = new WindowsTrayController(window);
        window.Show();
        if (WindowsLaunchAtLoginService.IsBackgroundStart(e.Args))
        {
            window.Hide();
        }
        _ = _mainWindowViewModel.InitializeAsync();
    }

    protected override void OnSessionEnding(SessionEndingCancelEventArgs e)
    {
        _trayController?.AllowExit();
        base.OnSessionEnding(e);
    }

    internal void RequestExit()
    {
        _trayController?.AllowExit();
        Shutdown();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        try
        {
            _mainWindowViewModel?.DisposeAsync().AsTask().GetAwaiter().GetResult();
            _clientServices?.DisposeAsync().AsTask().GetAwaiter().GetResult();
        }
        finally
        {
            _trayController?.Dispose();
            _singleInstanceLease?.Dispose();
            base.OnExit(e);
        }
    }
}
