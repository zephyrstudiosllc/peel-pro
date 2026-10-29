using System.Globalization;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using System.Windows.Input;
using Peel.Windows.Client.Models;
using Peel.Windows.Client.ViewModels;
using Peel.Windows.Client.Services;
using Peel.Windows.Host.Security;
using Peel.Windows.Host.Windows;
using Peel.Windows.Client.Utilities;
using Color = System.Windows.Media.Color;
using MouseEventArgs = System.Windows.Input.MouseEventArgs;

namespace Peel.Windows.Client;

public partial class MainWindow : Window
{
    private readonly IWindowEnumerator _hostWindowEnumerator = new Win32WindowEnumerator();
    private readonly HostRuntimeLifecycleController _hostLifecycle;
    private readonly WindowsLaunchAtLoginService _launchAtLogin = new();
    private readonly CancellationTokenSource _windowLifetime = new();
    private readonly DispatcherTimer _hostStatusTimer;
    private WindowsHostSystemLifecycleMonitor? _hostSystemLifecycle;
    private WindowsHostNetworkMonitor? _hostNetworkLifecycle;
    private string? _hostLifecycleError;
    private bool _hostStartAttempted;
    private bool _hostRetryInProgress;
    private bool _hostPairedClientRevocationInProgress;
    private bool _showingHostMode = true;
    private bool _closing;
    internal CommandCenterViewModel Utilities { get; }
    private UsageBarWindow? usageBar;
    private readonly LocalAgentBridge _agentBridge;
    private readonly LocalComputerAccess _localComputer;

    private const int DwmUseImmersiveDarkMode = 20;
    private const int DwmUseImmersiveDarkModeBefore20H1 = 19;
    private const int DwmWindowCornerPreference = 33;
    private const int DwmRoundCorners = 2;

    public MainWindow()
    {
        _hostLifecycle = new HostRuntimeLifecycleController(ReadInitialSessionLocked);
        InitializeComponent();
        Utilities = new CommandCenterViewModel(Dispatcher);
        Utilities.ShowUsageBar = () =>
        {
            if (usageBar is null)
            {
                usageBar = new UsageBarWindow(Utilities, () => { Show(); WindowState = WindowState.Normal; ShowUtilities(1); Activate(); });
                usageBar.Closed += (_, _) => usageBar = null;
            }
            usageBar.Show();
        };
        Utilities.ApplyStreamingSettings = () => _hostLifecycle.RestartAsync(_windowLifetime.Token);
        // Explicit Start clears and explicit Stop saves this pairing's Listen Off; automatic stops never do.
        Utilities.StartAudio = token => ClientViewModel?.ProductionServices?.StartListeningAsync(token)
            ?? Task.FromException(new InvalidOperationException("Connect to a computer in Remote Desktop first."));
        Utilities.StopAudio = () => ClientViewModel?.ProductionServices?.StopListeningAsync() ?? Task.CompletedTask;
        Utilities.StartVoice = token => ClientViewModel?.ProductionServices?.Audio.StartVoiceAsync(token)
            ?? Task.FromException(new InvalidOperationException("Connect to a computer in Remote Desktop first."));
        Utilities.ReadAudioStatus = () => ClientViewModel?.ProductionServices?.Audio.Status ?? "Connect to a computer in Remote Desktop first.";
        Utilities.ActiveHostedStreams = () => _hostLifecycle.State.ActiveStreamCount;
        Utilities.RequestRemoteStatus = token => ClientViewModel?.ProductionServices?.RequestMachineStatusAsync(token)
            ?? Task.FromException<Peel.Windows.Protocol.MachineStatusMessage>(new InvalidOperationException("Connect to a computer in Remote Desktop first."));
        CommandCenter.DataContext = Utilities;
        CommandCenter.SectionChanged += section => SelectStudioPage((section switch { 5 or 6 => 4, 12 or 13 or 14 => 11, _ => section }).ToString(CultureInfo.InvariantCulture));
        // Local AI use of this PC has its own input gate; enabling it never opens control to paired devices.
        // Person priority comes from header-only raw input owned by its own thread, plus the last-input clock.
        _localComputer = new LocalComputerAccess(new Win32LocalWindowPlatform(), new LocalWindowCapture(), new Win32LocalInputClock(),
            new Win32RawInputActivityMonitor(), gate => new Peel.Windows.Host.Input.WindowsInputInjector(gate));
        Utilities.AttachLocalComputer(_localComputer);
        _agentBridge = new LocalAgentBridge(Dispatcher,
            () => Utilities.AllowLocalAgents && !_closing && _hostLifecycle.State.PauseReason is null,
            () => Utilities.ReadStreamingDiagnostics(), Utilities.NotifyFromAgent,
            consentVersion: () => Utilities.AgentConsentVersion, localComputer: _localComputer);
        Utilities.LocalAgentConsentChanged += (_, _) => _agentBridge.Invalidate();
        Utilities.Start();
        SetMode(hostMode: true);
        _hostLifecycle.StateChanged += HostRuntime_StateChanged;
        _hostStatusTimer = new DispatcherTimer(
            TimeSpan.FromSeconds(1),
            DispatcherPriority.Background,
            (_, _) => { UpdateHostRuntimeStatus(); Utilities.RefreshSignals(); },
            Dispatcher);
        Loaded += MainWindow_Loaded;
        SourceInitialized += (_, _) => ApplyWindowChrome();
        Deactivated += (_, _) => ClientViewModel?.ReleaseControl();
        IsVisibleChanged += async (_, _) => await UpdateClientVisibilityAsync();
        StateChanged += async (_, _) => await UpdateClientVisibilityAsync();
        DataContextChanged += (_, e) =>
        {
            if (e.OldValue is MainWindowViewModel oldModel) oldModel.PropertyChanged -= ClientViewModel_PropertyChanged;
            if (e.NewValue is MainWindowViewModel newModel) newModel.PropertyChanged += ClientViewModel_PropertyChanged;
            Utilities.DeviceSignals = (e.NewValue as MainWindowViewModel)?.ProductionServices?.Signals;
            Utilities.SignalPublisher = (e.NewValue as MainWindowViewModel)?.ProductionServices?.SignalPublisher;
        };
    }

    private void RefreshHostWindows_Click(object sender, RoutedEventArgs e) => RefreshHostWindows();

    private void HostSetupDisclosure_Click(object sender, RoutedEventArgs e)
    {
        bool expand = HostSetupContent.Visibility != Visibility.Visible;
        SetHostDisclosureSection(expand ? HostSetupContent : null);
        if (expand)
        {
            RefreshHostWindows();
        }
    }

    private void HostPairDisclosure_Click(object sender, RoutedEventArgs e)
    {
        bool expand = HostPairContent.Visibility != Visibility.Visible;
        SetHostDisclosureSection(expand ? HostPairContent : null);
    }

    private void HostDevicesDisclosure_Click(object sender, RoutedEventArgs e)
    {
        bool expand = HostDevicesContent.Visibility != Visibility.Visible;
        SetHostDisclosureSection(expand ? HostDevicesContent : null);
    }

    private void HostWindowsOptionsDisclosure_Click(object sender, RoutedEventArgs e)
    {
        HostWindowsOptionsContent.Visibility =
            HostWindowsOptionsContent.Visibility == Visibility.Visible
                ? Visibility.Collapsed
                : Visibility.Visible;
        if (HostWindowsOptionsContent.Visibility == Visibility.Visible)
        {
            RefreshHostWindows();
        }
    }

    private void SetHostDisclosureSection(FrameworkElement? expandedSection)
    {
        HostSectionsScrollViewer.VerticalScrollBarVisibility =
            ReferenceEquals(expandedSection, HostSetupContent)
                ? ScrollBarVisibility.Hidden
                : ScrollBarVisibility.Auto;
        HostSetupContent.Visibility = ReferenceEquals(expandedSection, HostSetupContent)
            ? Visibility.Visible
            : Visibility.Collapsed;
        HostPairContent.Visibility = ReferenceEquals(expandedSection, HostPairContent)
            ? Visibility.Visible
            : Visibility.Collapsed;
        HostDevicesContent.Visibility = ReferenceEquals(expandedSection, HostDevicesContent)
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    private void CopyHostPairingPin_Click(object sender, RoutedEventArgs e)
    {
        string pin = HostPairingPinText.Text.Replace(" ", string.Empty, StringComparison.Ordinal);
        if (pin.Length == 6 && pin.All(char.IsAsciiDigit))
        {
            System.Windows.Clipboard.SetText(pin);
        }
    }

    private void CloseHostWindow_Click(object sender, RoutedEventArgs e) => Hide();

    private void MinimizeWindow_Click(object sender, RoutedEventArgs e) =>
        WindowState = WindowState.Minimized;

    private void ZoomWindow_Click(object sender, RoutedEventArgs e)
    {
        if (_showingHostMode)
        {
            return;
        }

        WindowState = WindowState == WindowState.Maximized
            ? WindowState.Normal
            : WindowState.Maximized;
    }

    private void HostSettings_Click(object sender, RoutedEventArgs e)
    {
        if (HostSettingsButton.ContextMenu is { } menu)
        {
            menu.PlacementTarget = HostSettingsButton;
            menu.IsOpen = true;
        }
    }

    private void RemoteDesktopMode_Click(object sender, RoutedEventArgs e)
    {
        if (RemoteDesktopModeButton.ContextMenu is { } menu)
        {
            menu.PlacementTarget = RemoteDesktopModeButton;
            menu.Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom;
            menu.IsOpen = true;
        }
    }

    /// <summary>Mirrors the current page in the visible Remote Desktop selector; null while a utility page is shown.</summary>
    private void UpdateRemoteDesktopModeSelector(bool? hostMode)
    {
        RemoteDesktopModeText.Text = hostMode switch { true => "Share This PC", false => "Connect", null => "Connect or Share" };
        System.Windows.Automation.AutomationProperties.SetName(RemoteDesktopModeButton, "Remote Desktop: " + RemoteDesktopModeText.Text);
        if (RemoteDesktopModeButton.ContextMenu?.Items.OfType<System.Windows.Controls.MenuItem>().ToArray() is
            [var connectMenuItem, var shareMenuItem])
        {
            connectMenuItem.IsChecked = hostMode == false;
            shareMenuItem.IsChecked = hostMode == true;
        }
    }

    private void ShowHostMode_Click(object sender, RoutedEventArgs e) =>
        SetMode(hostMode: true);

    private void ShowClientMode_Click(object sender, RoutedEventArgs e) =>
        SetMode(hostMode: false);

    private void ShowMechanic_Click(object sender, RoutedEventArgs e) => ShowUtilities(0);
    private void ShowUsage_Click(object sender, RoutedEventArgs e) => ShowUtilities(1);
    private bool selectingStudioPage;
    private void StudioNavigation_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (selectingStudioPage || StudioNavigation.SelectedItem is not ListBoxItem { Tag: string page }) return;
        if (page == "host") SetMode(true);
        else if (page == "remote") SetMode(false);
        else if (int.TryParse(page, out int section)) ShowUtilities(section);
    }
    private void SelectStudioPage(string page)
    {
        selectingStudioPage = true;
        try { StudioNavigation.SelectedItem = StudioNavigation.Items.OfType<ListBoxItem>().FirstOrDefault(item => Equals(item.Tag, page)); }
        finally { selectingStudioPage = false; }
    }
    internal void ShowUtilities(int section)
    {
        SetMode(hostMode: false);
        ClientModeContent.Visibility = Visibility.Collapsed;
        CommandCenter.Visibility = Visibility.Visible;
        CommandCenter.SelectSection(section);
        UpdateRemoteDesktopModeSelector(null);
        Title = "Peel Pro";
        WindowCaptionText.Text = Title;
        _ = UpdateClientVisibilityAsync();
    }

    private void AboutPeel_Click(object sender, RoutedEventArgs e)
    {
        System.Windows.MessageBox.Show(
            this,
            "Peel Pro\n\nSecurely pair a Peel Pro device to stream individual app windows.",
            "About Peel Pro",
            MessageBoxButton.OK,
            MessageBoxImage.Information);
    }

    private async void RestartHost_Click(object sender, RoutedEventArgs e)
    {
        if (_hostRetryInProgress || _closing)
        {
            return;
        }

        _hostRetryInProgress = true;
        _hostLifecycleError = null;
        UpdateHostRuntimeStatus();
        try
        {
            EnsureHostLifecycleMonitoring();
            await _hostLifecycle.RetryAsync(_windowLifetime.Token);
        }
        catch (OperationCanceledException) when (_windowLifetime.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            _hostLifecycleError = exception.Message;
        }
        finally
        {
            _hostRetryInProgress = false;
            UpdateHostRuntimeStatus();
        }
    }

    private void QuitPeel_Click(object sender, RoutedEventArgs e)
    {
        MessageBoxResult result = System.Windows.MessageBox.Show(
            this,
            "Peel Pro can only stream and accept connections while it is active. " +
            "If you quit now, paired devices will not be able to connect until you reopen the app.",
            "Quit Peel Pro?",
            MessageBoxButton.OKCancel,
            MessageBoxImage.Warning,
            MessageBoxResult.Cancel);
        if (result == MessageBoxResult.OK)
        {
            (System.Windows.Application.Current as App)?.RequestExit();
        }
    }

    private void SetMode(bool hostMode)
    {
        CommandCenter.Visibility = Visibility.Collapsed;
        ClientViewModel?.ReleaseControl();
        _showingHostMode = hostMode;
        Title = "Peel Pro";
        WindowCaptionText.Text = Title;
        HostModeContent.Visibility = hostMode ? Visibility.Visible : Visibility.Collapsed;
        ClientModeContent.Visibility = hostMode ? Visibility.Collapsed : Visibility.Visible;
        if (HostSettingsButton.ContextMenu?.Items.OfType<System.Windows.Controls.MenuItem>().ToArray() is
            [var hostMenuItem, var clientMenuItem])
        {
            hostMenuItem.IsChecked = hostMode;
            clientMenuItem.IsChecked = !hostMode;
        }
        UpdateRemoteDesktopModeSelector(hostMode);
        ZoomWindowButton.IsEnabled = true;
        ResizeMode = System.Windows.ResizeMode.CanResize;
        SelectStudioPage(hostMode ? "host" : "remote");
        ApplyDarkTitleBar(enabled: true);
        _ = UpdateClientVisibilityAsync();
    }

    private MainWindowViewModel? ClientViewModel => DataContext as MainWindowViewModel;
    private bool expandedClientViewer;
    private bool releasingClientCapture;

    private Task UpdateClientVisibilityAsync() => ClientViewModel?.SetClientVisibilityAsync(
        !_showingHostMode && IsVisible && WindowState != WindowState.Minimized) ?? Task.CompletedTask;

    private void ClientViewModel_PropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(MainWindowViewModel.IsControlEnabled)) return;
        if (ClientViewModel?.IsControlEnabled == true) ClientVideoSurface.Focus();
        else if (ClientVideoSurface.IsMouseCaptured) ClientVideoSurface.ReleaseMouseCapture();
    }

    private async void PairClientHost_Click(object sender, RoutedEventArgs e)
    {
        var pin = ClientPairingPin.Password;
        ClientPairingPin.Clear();
        if (ClientViewModel is { } vm) await vm.PairSelectedHostAsync(pin);
    }

    private void ForgetClientHost_Click(object sender, RoutedEventArgs e)
    {
        if (ClientViewModel is not { SelectedHost: { } host } vm || !vm.ForgetHostCommand.CanExecute(null)) return;
        vm.ReleaseControl();
        if (System.Windows.MessageBox.Show(this, $"Forget the pairing with {host.DisplayName}? You will need its PIN to reconnect.",
            "Forget paired computer", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes)
            vm.ForgetHostCommand.Execute(null);
    }

    private void EnableClientControl_Click(object sender, RoutedEventArgs e) => ClientVideoSurface.Focus();

    private bool openingDetachedViewer;

    /// <summary>
    /// Default open: the selected entry from the current inventory gets its own viewer window while this
    /// manager stays open. The service owns the connection, refuses a second viewer for the same window and
    /// keeps a single control owner; every input starts released.
    /// </summary>
    private async void OpenDetachedViewer_Click(object sender, RoutedEventArgs e)
    {
        if (openingDetachedViewer || ClientViewModel is not { SelectedWindow: { } selected } vm) return;
        if (vm.ProductionServices is not { } services)
        {
            // No separate viewer without the production stream stack; show the selection here instead.
            if (vm.StartStreamCommand.CanExecute(null)) vm.StartStreamCommand.Execute(null);
            return;
        }
        openingDetachedViewer = true;
        try
        {
            services.DisableAllInputs();
            var viewer = await services.OpenViewerAsync(selected, _windowLifetime.Token);
            new RemoteViewerWindow(viewer, services).Show();
        }
        catch (Exception error) when (error is System.IO.IOException or InvalidOperationException or OperationCanceledException)
        { System.Windows.MessageBox.Show(this, error.Message, "Open peeled window", MessageBoxButton.OK, MessageBoxImage.Information); }
        finally { openingDetachedViewer = false; }
    }

    private void RemoteWindowCatalog_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Left || sender is not System.Windows.Controls.ListBox list ||
            e.OriginalSource is not DependencyObject source || ItemsControl.ContainerFromElement(list, source) is not ListBoxItem) return;
        e.Handled = true;
        OpenDetachedViewer_Click(sender, e);
    }

    private void ClientFullScreen_Click(object sender, RoutedEventArgs e)
    {
        ClientViewModel?.ReleaseControl();
        expandedClientViewer = !expandedClientViewer;
        ClientSidebar.Visibility = expandedClientViewer ? Visibility.Collapsed : Visibility.Visible;
        Grid.SetColumn(ClientViewerPanel, expandedClientViewer ? 0 : 2);
        Grid.SetColumnSpan(ClientViewerPanel, expandedClientViewer ? 3 : 1);
        if (expandedClientViewer) WindowState = WindowState.Maximized;
        if (sender is System.Windows.Controls.Button button) button.Content = expandedClientViewer ? "Show computers" : "Expand viewer";
    }

    private bool TryClientPoint(MouseEventArgs e, out NormalizedPoint point)
    {
        point = default;
        if (ClientViewModel is not { IsControlEnabled: true, PeeledFrameSource: { } frame } vm
            || vm.StreamingWindowId is null) return false;
        var position = e.GetPosition(ClientVideoSurface);
        return ClientViewport.TryNormalize(position.X, position.Y, ClientVideoSurface.ActualWidth,
            ClientVideoSurface.ActualHeight, vm.FramePixelWidth, vm.FramePixelHeight,
            ClientVideoSurface.IsMouseCaptured, out point);
    }

    private async void ClientSurface_MouseMove(object sender, MouseEventArgs e)
    {
        if (!ClientVideoSurface.IsKeyboardFocusWithin || !TryClientPoint(e, out var point)) return;
        await ClientViewModel!.SendPointerAsync(new(ClientViewModel.StreamingWindowId!.Value,
            NormalizedPointerAction.Move, point, NormalizedPointerButton.None, 0, 0));
    }

    private async void ClientSurface_MouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton is not (MouseButton.Left or MouseButton.Right) || !TryClientPoint(e, out var point)) return;
        ClientVideoSurface.Focus(); ClientVideoSurface.CaptureMouse(); e.Handled = true;
        await ClientViewModel!.SendPointerAsync(new(ClientViewModel.StreamingWindowId!.Value, NormalizedPointerAction.Down,
            point, e.ChangedButton == MouseButton.Left ? NormalizedPointerButton.Primary : NormalizedPointerButton.Secondary, 0, 0));
    }

    private async void ClientSurface_MouseUp(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton is not (MouseButton.Left or MouseButton.Right) || !TryClientPoint(e, out var point)) return;
        e.Handled = true;
        await ClientViewModel!.SendPointerAsync(new(ClientViewModel.StreamingWindowId!.Value, NormalizedPointerAction.Up,
            point, e.ChangedButton == MouseButton.Left ? NormalizedPointerButton.Primary : NormalizedPointerButton.Secondary, 0, 0));
        if (e.LeftButton != MouseButtonState.Pressed && e.RightButton != MouseButtonState.Pressed)
        {
            releasingClientCapture = true;
            try { ClientVideoSurface.ReleaseMouseCapture(); }
            finally { releasingClientCapture = false; }
        }
    }

    private async void ClientSurface_MouseWheel(object sender, MouseWheelEventArgs e)
    {
        if (!TryClientPoint(e, out var point)) return;
        e.Handled = true;
        await ClientViewModel!.SendPointerAsync(new(ClientViewModel.StreamingWindowId!.Value,
            NormalizedPointerAction.Scroll, point, NormalizedPointerButton.None,
            Keyboard.Modifiers.HasFlag(ModifierKeys.Shift) ? e.Delta : 0,
            Keyboard.Modifiers.HasFlag(ModifierKeys.Shift) ? 0 : e.Delta));
    }

    private async void ClientSurface_KeyDown(object sender, System.Windows.Input.KeyEventArgs e) => await SendClientKeyAsync(e, true);
    private async void ClientSurface_KeyUp(object sender, System.Windows.Input.KeyEventArgs e) => await SendClientKeyAsync(e, false);
    private async Task SendClientKeyAsync(System.Windows.Input.KeyEventArgs e, bool down)
    {
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        var modifiers = Keyboard.Modifiers;
        if (key == Key.Escape && modifiers.HasFlag(ModifierKeys.Control) && modifiers.HasFlag(ModifierKeys.Alt))
        { ClientViewModel?.ReleaseControl(); e.Handled = true; return; }
        if (ClientViewModel is not { IsControlEnabled: true, StreamingWindowId: { } id } vm) return;
        var virtualKey = checked((ushort)KeyInterop.VirtualKeyFromKey(key));
        if (ClientInputController.ToHidUsage(virtualKey) == 0) return;
        e.Handled = true;
        await vm.SendKeyAsync(new(id, virtualKey, down, e.IsRepeat,
            modifiers.HasFlag(ModifierKeys.Shift), modifiers.HasFlag(ModifierKeys.Control),
            modifiers.HasFlag(ModifierKeys.Alt), modifiers.HasFlag(ModifierKeys.Windows)));
    }

    private void ClientSurface_LostKeyboardFocus(object sender, KeyboardFocusChangedEventArgs e) => ClientViewModel?.ReleaseControl();
    private void ClientSurface_LostMouseCapture(object sender, MouseEventArgs e)
    {
        if (!releasingClientCapture && ClientViewModel?.IsControlEnabled == true) ClientViewModel.ReleaseControl();
    }

    private void ApplyWindowChrome()
    {
        ApplyDarkTitleBar(enabled: true);

        IntPtr handle = new WindowInteropHelper(this).Handle;
        if (handle == IntPtr.Zero)
        {
            return;
        }

        int cornerPreference = DwmRoundCorners;
        _ = DwmSetWindowAttribute(
            handle,
            DwmWindowCornerPreference,
            ref cornerPreference,
            sizeof(int));
    }

    private void ApplyDarkTitleBar(bool enabled)
    {
        IntPtr handle = new WindowInteropHelper(this).Handle;
        if (handle == IntPtr.Zero)
        {
            return;
        }

        int value = enabled ? 1 : 0;
        if (DwmSetWindowAttribute(handle, DwmUseImmersiveDarkMode, ref value, sizeof(int)) != 0)
        {
            _ = DwmSetWindowAttribute(
                handle,
                DwmUseImmersiveDarkModeBefore20H1,
                ref value,
                sizeof(int));
        }
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(
        IntPtr window,
        int attribute,
        ref int value,
        int valueSize);

    private async void MainWindow_Loaded(object sender, RoutedEventArgs e)
    {
        RefreshLaunchAtLoginSetting();
        _ = Dispatcher.BeginInvoke(
            DispatcherPriority.Background,
            new Action(RefreshHostWindows));
        if (_hostStartAttempted)
        {
            return;
        }

        _hostStartAttempted = true;
        _hostStatusTimer.Start();
        UpdateHostRuntimeStatus();
        try
        {
            EnsureHostLifecycleMonitoring();
            await _hostLifecycle.StartAsync(_windowLifetime.Token);
        }
        catch (OperationCanceledException) when (_windowLifetime.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            _hostLifecycleError = exception.Message;
        }

        UpdateHostRuntimeStatus();
    }

    private void EnsureHostLifecycleMonitoring()
    {
        // Register before taking the initial snapshot so later lock/unlock messages
        // continue the same fail-closed lifecycle instead of leaving a startup gap.
        _hostSystemLifecycle ??= new WindowsHostSystemLifecycleMonitor(
            this,
            HostSystemLifecycle_Changed);
        _hostNetworkLifecycle ??= new WindowsHostNetworkMonitor(this, HostNetwork_Changed);
    }

    private bool ReadInitialSessionLocked() =>
        (_hostSystemLifecycle ?? throw new InvalidOperationException(
            "Windows session monitoring is unavailable. Secure hosting remains offline."))
        .ReadInitialSessionLocked();

    private void HostLaunchAtLogin_Click(object sender, RoutedEventArgs e)
    {
        _ = sender;
        _ = e;
        bool requested = HostLaunchAtLoginCheckBox.IsChecked == true;
        try
        {
            _launchAtLogin.SetEnabled(requested);
            HostLaunchAtLoginStatusText.Text = requested
                ? "On. Peel Pro will start in the tray with remote input off."
                : "Off. When enabled, Peel Pro starts in the tray with remote input off.";
        }
        catch (Exception exception)
        {
            HostLaunchAtLoginCheckBox.IsChecked = !requested;
            HostLaunchAtLoginStatusText.Text =
                $"Windows sign-in startup could not change: {exception.Message}";
        }
    }

    private async void RefreshHostPairing_Click(object sender, RoutedEventArgs e)
    {
        RefreshHostPairingButton.IsEnabled = false;
        try
        {
            await _hostLifecycle.RefreshPairingAsync(_windowLifetime.Token);
        }
        catch (OperationCanceledException) when (_windowLifetime.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            ShowHostRuntimeFailure(exception.Message);
        }
        finally
        {
            UpdateHostRuntimeStatus();
        }
    }

    private async void RetryHostRuntime_Click(object sender, RoutedEventArgs e)
    {
        _ = sender;
        _ = e;
        if (_hostRetryInProgress || _closing)
        {
            return;
        }

        _hostRetryInProgress = true;
        _hostLifecycleError = null;
        UpdateHostRuntimeStatus();
        try
        {
            EnsureHostLifecycleMonitoring();
            await _hostLifecycle.RetryAsync(_windowLifetime.Token);
        }
        catch (OperationCanceledException) when (_windowLifetime.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            _hostLifecycleError = exception.Message;
        }
        finally
        {
            _hostRetryInProgress = false;
            UpdateHostRuntimeStatus();
        }
    }

    private void HostRemoteInput_Click(object sender, RoutedEventArgs e)
    {
        bool requested = HostRemoteInputCheckBox.IsChecked == true;
        try
        {
            _hostLifecycle.SetInputEnabled(requested);
        }
        catch (Exception exception)
        {
            HostRemoteInputCheckBox.IsChecked = false;
            ShowHostRuntimeFailure(exception.Message);
        }

        UpdateHostRuntimeStatus();
    }

    private void HostPairedClients_SelectionChanged(
        object sender,
        System.Windows.Controls.SelectionChangedEventArgs e)
    {
        _ = sender;
        _ = e;
        UpdateForgetHostPairedClientButton();
    }

    private async void ForgetHostPairedClient_Click(object sender, RoutedEventArgs e)
    {
        _ = sender;
        _ = e;
        if (_hostPairedClientRevocationInProgress ||
            HostPairedClientsList.SelectedItem is not HostPairedClientRow selected)
        {
            return;
        }

        await ForgetPairedClientAsync(selected);
    }

    private async void ForgetHostPairedClientRow_Click(object sender, RoutedEventArgs e)
    {
        if (_hostPairedClientRevocationInProgress ||
            sender is not System.Windows.Controls.Button { DataContext: HostPairedClientRow selected })
        {
            return;
        }

        HostPairedClientsList.SelectedItem = selected;
        await ForgetPairedClientAsync(selected);
    }

    private async Task ForgetPairedClientAsync(HostPairedClientRow selected)
    {
        var confirmation = new ForgetPairedDeviceWindow(selected.DisplayName)
        {
            Owner = this,
        };
        if (confirmation.ShowDialog() != true)
        {
            return;
        }

        _hostPairedClientRevocationInProgress = true;
        UpdateForgetHostPairedClientButton();
        string? failure = null;
        try
        {
            if (Utilities.SignalPublisher is { } publisher) await publisher.StopAsync();
            bool removed = await _hostLifecycle.RevokePairedClientAsync(
                selected.PairingId,
                _windowLifetime.Token);
            if (!removed)
            {
                failure = "That paired device was already removed.";
            }
        }
        catch (OperationCanceledException) when (_windowLifetime.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            failure = exception.Message;
        }
        finally
        {
            _hostPairedClientRevocationInProgress = false;
            UpdateHostRuntimeStatus();
        }

        if (failure is not null)
        {
            ShowHostRuntimeFailure(failure);
        }
    }

    protected override void OnClosed(EventArgs e)
    {
        _closing = true;
        usageBar?.Close();
        foreach (var viewer in System.Windows.Application.Current.Windows.OfType<RemoteViewerWindow>().ToArray()) viewer.Close();
        _hostStatusTimer.Stop();
        _hostNetworkLifecycle?.Dispose();
        _hostNetworkLifecycle = null;
        _hostSystemLifecycle?.Dispose();
        _hostSystemLifecycle = null;
        _hostLifecycle.StateChanged -= HostRuntime_StateChanged;
        _windowLifetime.Cancel();
        try
        {
            Utilities.DisposeAsync().AsTask().GetAwaiter().GetResult();
            _agentBridge.DisposeAsync().AsTask().GetAwaiter().GetResult();
            _localComputer.Dispose();
            _hostLifecycle.DisposeAsync().AsTask().GetAwaiter().GetResult();
        }
        finally
        {
            _windowLifetime.Dispose();
            base.OnClosed(e);
        }
    }

    private async void HostSystemLifecycle_Changed(HostSystemLifecycleEvent lifecycleEvent)
    {
        if (_closing)
        {
            return;
        }

        try
        {
            if (lifecycleEvent is HostSystemLifecycleEvent.SessionLocked or HostSystemLifecycleEvent.Suspending)
            { Utilities.PauseSessionUtilities(); Utilities.StreamingDiagnosticsEnabled = false; Utilities.SuspendSystemAudioSharing(); Utilities.AllowLocalAgents = false; _localComputer.Disable("Windows locked or sleeping."); _agentBridge.Invalidate(); Utilities.DeviceSignals?.Cancel(); Utilities.SignalPublisher?.Cancel(); Utilities.RefreshSignals(); usageBar?.Close(); }
            if (lifecycleEvent is HostSystemLifecycleEvent.SessionLocked or HostSystemLifecycleEvent.Suspending
                && ClientViewModel is { } client)
            {
                client.ReleaseControl();
                if (client.DisconnectCommand.CanExecute(null)) client.DisconnectCommand.Execute(null);
            }
            switch (lifecycleEvent)
            {
                case HostSystemLifecycleEvent.SessionLocked:
                    await _hostLifecycle.SetPausedAsync(
                        HostRuntimePauseReason.SessionLocked,
                        paused: true,
                        _windowLifetime.Token);
                    break;
                case HostSystemLifecycleEvent.SessionUnlocked:
                    await _hostLifecycle.SetPausedAsync(
                        HostRuntimePauseReason.SessionLocked,
                        paused: false,
                        _windowLifetime.Token);
                    break;
                case HostSystemLifecycleEvent.Suspending:
                    await _hostLifecycle.SetPausedAsync(
                        HostRuntimePauseReason.SystemSuspended,
                        paused: true,
                        _windowLifetime.Token);
                    break;
                case HostSystemLifecycleEvent.Resumed:
                    await _hostLifecycle.SetPausedAsync(
                        HostRuntimePauseReason.SystemSuspended,
                        paused: false,
                        _windowLifetime.Token);
                    break;
                default:
                    throw new ArgumentOutOfRangeException(nameof(lifecycleEvent));
            }

            // A lock or suspend pause never became a saved Off; reapply the saved choice once fully unpaused.
            if (lifecycleEvent is HostSystemLifecycleEvent.SessionUnlocked or HostSystemLifecycleEvent.Resumed &&
                _hostLifecycle.State.PauseReason is null)
                Utilities.RestoreSystemAudioSharing();

            _hostLifecycleError = null;
        }
        catch (OperationCanceledException) when (_windowLifetime.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            _hostLifecycleError = exception.Message;
        }

        UpdateHostRuntimeStatus();
    }

    private async void HostNetwork_Changed()
    {
        if (_closing)
        {
            return;
        }

        try
        {
            await _hostLifecycle.RestartAsync(_windowLifetime.Token);
            _hostLifecycleError = null;
        }
        catch (OperationCanceledException) when (_windowLifetime.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            _hostLifecycleError = exception.Message;
        }

        UpdateHostRuntimeStatus();
    }

    private void RefreshHostWindows()
    {
        try
        {
            var windows = _hostWindowEnumerator.Enumerate();
            HostWindowsList.ItemsSource = windows;
            HostWindowCountText.Text = windows.Count == 1 ? "1 window" : $"{windows.Count} windows";
        }
        catch (Exception)
        {
            HostWindowsList.ItemsSource = null;
            HostWindowCountText.Text = "Window discovery unavailable";
        }
    }

    private void RefreshLaunchAtLoginSetting()
    {
        try
        {
            bool enabled = _launchAtLogin.IsEnabled;
            HostLaunchAtLoginCheckBox.IsChecked = enabled;
            HostLaunchAtLoginCheckBox.IsEnabled = true;
            HostLaunchAtLoginStatusText.Text = enabled
                ? "On. Peel Pro will start in the tray with remote input off."
                : "Off. When enabled, Peel Pro starts in the tray with remote input off.";
        }
        catch (Exception exception)
        {
            HostLaunchAtLoginCheckBox.IsChecked = false;
            HostLaunchAtLoginCheckBox.IsEnabled = false;
            HostLaunchAtLoginStatusText.Text =
                $"Windows sign-in startup is unavailable: {exception.Message}";
        }
    }

    private void HostRuntime_StateChanged()
    {
        if (!Dispatcher.HasShutdownStarted)
        {
            _ = Dispatcher.BeginInvoke(
                DispatcherPriority.Background,
                new Action(UpdateHostRuntimeStatus));
        }
    }

    private void UpdateHostRuntimeStatus()
    {
        HostRuntimeLifecycleState hostState = _hostLifecycle.State;
        if (_hostLifecycleError is not null)
        {
            ShowHostRuntimeOffline(_hostLifecycleError);
            return;
        }

        if (hostState.PauseReason is not null)
        {
            ShowHostRuntimePaused(hostState.PauseReason.Value);
            return;
        }

        if (!hostState.IsRunning)
        {
            ShowHostRuntimeOffline(hostState.Error);
            return;
        }

        HostStatusDot.Fill = new SolidColorBrush(Color.FromRgb(47, 157, 93));
        HostStatusText.Text = hostState.HasActivePeer ? "Connected" : "Available";
        HostNoticeBorder.Visibility = Visibility.Collapsed;
        HostNoticeBorder.Background = new SolidColorBrush(Color.FromRgb(234, 248, 239));
        HostNoticeBorder.BorderBrush = new SolidColorBrush(Color.FromRgb(180, 226, 196));
        HostNoticeTitleText.Text = "Ready for Peel Pro clients";
        HostNoticeDetailText.Text =
            "This PC is discoverable through authenticated Peel v2. Pair with the PIN below; remote input remains under your local control.";

        HostRemoteConnectionStatusText.Text = hostState switch
        {
            { HasActivePeer: false, PairedClients.Count: 0 } =>
                "Looking for clients to pair with.",
            { HasActivePeer: false } =>
                "Waiting for a paired Peel Pro device to connect.",
            { IsClientVisible: true, IsPreventingSleep: true } =>
                "A Peel Pro device is connected to this PC and keeping it awake.",
            { IsClientVisible: true, AwakeError: not null } =>
                "A Peel Pro device is connected. Windows keep-awake is unavailable.",
            { IsClientVisible: true } =>
                "A Peel Pro device is connected to this PC.",
            _ => "A paired Peel Pro device is connected in the background.",
        };
        HostDiscoveryStatusText.Text = "This PC is available to paired Peel Pro devices.";
        HostVideoStatusText.Text = hostState.ActiveStreamCount switch
        {
            0 => "H.264 window and display streaming ready on demand",
            1 => "Streaming 1 source securely",
            _ => $"Streaming {hostState.ActiveStreamCount} sources securely",
        };
        HostPairingPinText.Text = FormatPin(hostState.PairingPin?.Pin);
        if (hostState.PairingPin is { } pin)
        {
            TimeSpan remaining = pin.ExpiresAt - DateTimeOffset.UtcNow;
            int seconds = Math.Max(0, (int)Math.Ceiling(remaining.TotalSeconds));
            HostPairingExpiryText.Text = seconds > 0
                ? $"Expires in {seconds}s"
                : "Expired (regenerating…)";
        }
        else
        {
            HostPairingExpiryText.Text = "Refreshing secure pairing…";
        }

        string? selectedPairingId =
            (HostPairedClientsList.SelectedItem as HostPairedClientRow)?.PairingId;
        HostPairedClientRow[] pairedClientRows = hostState.PairedClients
            .Select(CreateHostPairedClientRow)
            .ToArray();
        HostPairedClientsList.ItemsSource = pairedClientRows;
        HostPairedClientsList.SelectedItem = pairedClientRows.FirstOrDefault(
            row => StringComparer.Ordinal.Equals(row.PairingId, selectedPairingId));
        HostPairedClientsText.Text = pairedClientRows.Length switch
        {
            0 => "No paired devices yet.",
            _ => string.Empty,
        };
        HostPairedDevicesCountText.Text = pairedClientRows.Length.ToString(CultureInfo.InvariantCulture);
        HostPairedDevicesSubtitleText.Text = pairedClientRows.Length == 0
            ? "No paired devices yet."
            : "Manage devices that can connect to this PC.";
        HostSetupSummaryText.Text = "3/3";
        HostRemoteInputCheckBox.IsEnabled = true;
        HostRemoteInputCheckBox.IsChecked = hostState.IsInputEnabled;
        HostRemoteInputStatusText.Text = hostState.IsInputEnabled ? "Allowed" : "Off";
        HostRemoteInputStatusText.Foreground = new SolidColorBrush(hostState.IsInputEnabled
            ? Color.FromRgb(228, 231, 233)
            : Color.FromRgb(144, 149, 152));
        HostRemoteInputStatusDot.Fill = new SolidColorBrush(hostState.IsInputEnabled
            ? Color.FromRgb(52, 199, 89)
            : Color.FromRgb(139, 135, 130));
        RefreshHostPairingButton.IsEnabled = true;
        RetryHostRuntimeButton.Visibility = Visibility.Collapsed;
        UpdateForgetHostPairedClientButton();
    }

    private void ShowHostRuntimeOffline(string? error)
    {
        HostStatusDot.Fill = new SolidColorBrush(Color.FromRgb(139, 135, 130));
        HostStatusText.Text = error is null ? "Starting secure Host…" : "Hosting offline";
        HostSetupSummaryText.Text = "—";
        HostPairedDevicesCountText.Text = "0";
        HostPairedDevicesSubtitleText.Text = "No paired devices yet.";
        HostNoticeBorder.Visibility = error is null ? Visibility.Collapsed : Visibility.Visible;
        HostNoticeBorder.Background = new SolidColorBrush(Color.FromRgb(64, 46, 38));
        HostNoticeBorder.BorderBrush = new SolidColorBrush(Color.FromRgb(122, 74, 53));
        HostNoticeTitleText.Text = error is null
            ? "Starting secure hosting"
            : "Secure hosting needs attention";
        HostNoticeDetailText.Text = error ??
            "Opening authenticated listeners and Bonjour-compatible discovery. Remote input stays disabled until you turn it on below.";
        HostRemoteConnectionStatusText.Text = error is null ? "Starting…" : "Offline";
        HostVideoStatusText.Text = error is null ? "Starting video service…" : "Video unavailable";
        HostPairingPinText.Text = "——————";
        HostPairingExpiryText.Text = "Pairing unavailable";
        HostPairedClientsText.Text = "No active pairing surface";
        HostPairedClientsList.ItemsSource = null;
        ForgetHostPairedClientButton.IsEnabled = false;
        HostRemoteInputCheckBox.IsChecked = false;
        HostRemoteInputCheckBox.IsEnabled = false;
        HostRemoteInputStatusText.Text = "Off";
        HostRemoteInputStatusText.Foreground = new SolidColorBrush(Color.FromRgb(144, 149, 152));
        HostRemoteInputStatusDot.Fill = new SolidColorBrush(Color.FromRgb(139, 135, 130));
        RefreshHostPairingButton.IsEnabled = false;
        RetryHostRuntimeButton.Visibility = error is null
            ? Visibility.Collapsed
            : Visibility.Visible;
        RetryHostRuntimeButton.IsEnabled = !_hostRetryInProgress;
    }

    private void ShowHostRuntimePaused(HostRuntimePauseReason reason)
    {
        string status;
        string detail;
        if (reason == HostRuntimePauseReason.SessionLocked)
        {
            status = "Paused while Windows is locked";
            detail =
                "Remote devices were disconnected and input was disabled. Secure hosting restarts after Windows is unlocked.";
        }
        else
        {
            status = "Paused while this PC sleeps";
            detail =
                "Remote devices were disconnected and input was disabled. Secure hosting restarts after Windows resumes.";
        }

        HostStatusDot.Fill = new SolidColorBrush(Color.FromRgb(197, 139, 40));
        HostStatusText.Text = "Hosting paused";
        HostSetupSummaryText.Text = "—";
        HostPairedDevicesCountText.Text = "0";
        HostPairedDevicesSubtitleText.Text = "Saved pairings return after resume.";
        HostNoticeBorder.Visibility = Visibility.Collapsed;
        HostNoticeBorder.Background = new SolidColorBrush(Color.FromRgb(66, 56, 35));
        HostNoticeBorder.BorderBrush = new SolidColorBrush(Color.FromRgb(128, 103, 52));
        HostNoticeTitleText.Text = status;
        HostNoticeDetailText.Text = detail;
        HostRemoteConnectionStatusText.Text = status;
        HostVideoStatusText.Text = "Video paused";
        HostPairingPinText.Text = "——————";
        HostPairingExpiryText.Text = "Pairing paused";
        HostPairedClientsText.Text = "Saved pairings remain available after resume";
        HostPairedClientsList.ItemsSource = null;
        ForgetHostPairedClientButton.IsEnabled = false;
        HostRemoteInputCheckBox.IsChecked = false;
        HostRemoteInputCheckBox.IsEnabled = false;
        HostRemoteInputStatusText.Text = "Off";
        HostRemoteInputStatusText.Foreground = new SolidColorBrush(Color.FromRgb(144, 149, 152));
        HostRemoteInputStatusDot.Fill = new SolidColorBrush(Color.FromRgb(139, 135, 130));
        RefreshHostPairingButton.IsEnabled = false;
        RetryHostRuntimeButton.Visibility = Visibility.Collapsed;
    }

    private void ShowHostRuntimeFailure(string message)
    {
        HostNoticeBorder.Visibility = Visibility.Visible;
        HostNoticeBorder.Background = new SolidColorBrush(Color.FromRgb(64, 46, 38));
        HostNoticeBorder.BorderBrush = new SolidColorBrush(Color.FromRgb(122, 74, 53));
        HostNoticeTitleText.Text = "Secure hosting needs attention";
        HostNoticeDetailText.Text = string.IsNullOrWhiteSpace(message)
            ? "The secure Host runtime could not start."
            : message;
    }

    private static string FormatPin(string? pin) =>
        pin is { Length: 6 }
            ? pin
            : "——————";

    private void UpdateForgetHostPairedClientButton()
    {
        ForgetHostPairedClientButton.IsEnabled =
            !_hostPairedClientRevocationInProgress &&
            _hostLifecycle.State.IsRunning &&
            HostPairedClientsList.SelectedItem is HostPairedClientRow;
    }

    private static HostPairedClientRow CreateHostPairedClientRow(HostPairedClient client)
    {
        string displayName = new(
            client.DisplayName
                .Select(static character => char.IsControl(character) ? ' ' : character)
                .ToArray());
        displayName = displayName.Trim();
        if (displayName.Length == 0)
        {
            displayName = "Paired device";
        }

        DateTimeOffset activity = client.LastSeenAt ?? client.CreatedAt;
        string activityPrefix = client.LastSeenAt is null ? "Paired" : "Last connected";
        string activityLabel =
            $"{activityPrefix} {activity.ToLocalTime().ToString("g", CultureInfo.CurrentCulture)}";
        return new HostPairedClientRow(client.PairingId, displayName, activityLabel);
    }

    private sealed record HostPairedClientRow(
        string PairingId,
        string DisplayName,
        string ActivityLabel);
}
