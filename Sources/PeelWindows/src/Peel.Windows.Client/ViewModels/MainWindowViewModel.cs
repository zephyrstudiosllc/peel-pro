using System.Collections.ObjectModel;
using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;
using Peel.Windows.Client.Models;
using Peel.Windows.Client.Services;
using Application = System.Windows.Application;

namespace Peel.Windows.Client.ViewModels;

public sealed class MainWindowViewModel : ObservableObject, IAsyncDisposable
{
    private readonly IHostDiscoveryService _discovery;
    private readonly ISecureConnectionService _connection;
    private readonly IWindowListService _windowList;
    private readonly IStreamControlService _streamControl;
    private readonly INormalizedInputService _input;
    private readonly ProductionClientServices? _production;
    private readonly CancellationTokenSource _lifetime = new();
    private readonly LatestDecodedFrameMailbox _frameMailbox = new();
    private readonly WpfVideoPresenter _presenter = new();
    private readonly System.Diagnostics.Stopwatch _presentationClock = new();
    private long _presented;
    private string _frameStatistics = "";

    private HostCandidate? _selectedHost;
    private HostCandidate? _selectedDiscoveredHost;
    private HostCandidate? _selectedSavedHost;
    private RemoteWindowDescriptor? _selectedWindow;
    private PeelConnectionState _connectionState = PeelConnectionState.Disconnected;
    private PeelStreamState _streamState = PeelStreamState.Stopped;
    private string _noticeTitle = "Remote Desktop unavailable";
    private string _noticeDetail = "No discovery, secure connection, or video implementation is active.";
    private ImageSource? _peeledFrameSource;
    private string _windowSearch = "";
    private string _directAddress = "";
    private string _directPort = "";
    private string _controlStatus = "Control off";
    private bool _autoOpenedDesktop;

    public MainWindowViewModel(
        IHostDiscoveryService discovery,
        ISecureConnectionService connection,
        IWindowListService windowList,
        IStreamControlService streamControl,
        INormalizedInputService input)
    {
        _discovery = discovery;
        _connection = connection;
        _windowList = windowList;
        _streamControl = streamControl;
        _input = input;
        _production = discovery as ProductionClientServices;
        ArgumentNullException.ThrowIfNull(input);
        SourceControls = new SourceControlsViewModel(_production?.MainSourceMedia, SourceControlPreferences.Shared);

        RefreshHostsCommand = new AsyncCommand(RefreshHostsAsync);
        ConnectCommand = new AsyncCommand(ConnectAsync, () => SelectedHost is not null && ConnectionState != PeelConnectionState.Connected);
        DisconnectCommand = new AsyncCommand(DisconnectAsync, () => ConnectionState == PeelConnectionState.Connected);
        StartStreamCommand = new AsyncCommand(StartStreamAsync, () => SelectedWindow is not null && ConnectionState == PeelConnectionState.Connected);
        StopStreamCommand = new AsyncCommand(StopStreamAsync, () => StreamState == PeelStreamState.Streaming);
        RefreshWindowsCommand = new AsyncCommand(() => RunClientActionAsync("Window list refreshed",
            () => _production!.RefreshWindowsAsync(_lifetime.Token)), () => _production is not null && ConnectionState == PeelConnectionState.Connected);
        ToggleControlCommand = new AsyncCommand(ToggleControlAsync, () => _production is not null && StreamState == PeelStreamState.Streaming);
        ForgetHostCommand = new AsyncCommand(() => RunClientActionAsync("Pairing forgotten",
            () => _production!.ForgetAsync(SelectedHost!, _lifetime.Token)), () => SelectedHost is not null && _production?.IsPaired(SelectedHost.Id) == true);
        SaveAddressCommand = new AsyncCommand(SaveAddressAsync, () => SelectedHost is not null && _production?.IsPaired(SelectedHost.Id) == true);
        RemoveAddressCommand = new AsyncCommand(() => RunClientActionAsync("Saved address removed",
            () => _production!.RemoveAddressAsync(SelectedHost!, _lifetime.Token)), () => SelectedHost?.IsDirect == true);

        _discovery.HostsChanged += HandleHostsChanged;
        _connection.StateChanged += HandleConnectionStateChanged;
        _windowList.WindowsChanged += HandleWindowsChanged;
        _streamControl.StateChanged += HandleStreamStateChanged;
        _streamControl.FrameAvailable += HandleFrameAvailable;
        if (_production is not null)
        {
            _production.DiscoveryFailed += (_, detail) => OnUiThread(() => SetNotice("Nearby discovery unavailable", detail));
            _production.Input.ControlChanged += (_, detail) => OnUiThread(() =>
            {
                _controlStatus = detail; OnPropertyChanged(nameof(ControlStatus));
                OnPropertyChanged(nameof(IsControlEnabled)); OnPropertyChanged(nameof(ControlButtonLabel));
            });
        }
    }

    public ObservableCollection<HostCandidate> DiscoveredHosts { get; } = new();

    public ObservableCollection<HostCandidate> SavedHosts { get; } = new();

    public ObservableCollection<RemoteWindowDescriptor> RemoteWindows { get; } = new();

    public AsyncCommand RefreshHostsCommand { get; }

    public AsyncCommand ConnectCommand { get; }

    public AsyncCommand DisconnectCommand { get; }

    public AsyncCommand StartStreamCommand { get; }

    public AsyncCommand StopStreamCommand { get; }
    public AsyncCommand RefreshWindowsCommand { get; }
    public AsyncCommand ToggleControlCommand { get; }
    public AsyncCommand ForgetHostCommand { get; }
    public AsyncCommand SaveAddressCommand { get; }
    public AsyncCommand RemoveAddressCommand { get; }
    public bool IsControlEnabled => _production?.Input.IsEnabled == true;
    public string ControlButtonLabel => IsControlEnabled ? "Release control" : "Enable control";
    public string ControlStatus => _controlStatus;
    public string WindowSearch { get => _windowSearch; set { if (SetProperty(ref _windowSearch, value)) ReloadWindows(); } }
    public string DirectAddress { get => _directAddress; set => SetProperty(ref _directAddress, value); }
    public string DirectPort { get => _directPort; set => SetProperty(ref _directPort, value); }
    public uint? StreamingWindowId => _streamControl.StreamingWindowId;
    internal ProductionClientServices? ProductionServices => _production;
    /// <summary>Source volume and media controls bound to the main viewer's own stream.</summary>
    public SourceControlsViewModel SourceControls { get; }

    public Task SendPointerAsync(NormalizedPointerInput input) => _input.SendPointerAsync(input, _lifetime.Token);
    public Task SendKeyAsync(NormalizedKeyInput input) => _input.SendKeyAsync(input, _lifetime.Token);
    public void ReleaseControl() => _production?.DisableAllInputs();
    public async Task SetClientVisibilityAsync(bool visible)
    {
        if (_production is null || _lifetime.IsCancellationRequested) return;
        try { await _production.SetVisibilityAsync(visible, _lifetime.Token); }
        catch (Exception e) when (e is IOException or InvalidOperationException or OperationCanceledException) { ReleaseControl(); }
    }

    public Task PairSelectedHostAsync(string pin) => RunClientActionAsync("Paired · select Connect to continue",
        async () =>
        {
            var host = SelectedHost ?? throw new InvalidOperationException("Select a nearby computer first.");
            if (_production is null) throw new ClientCapabilityUnavailableException("Pairing is unavailable.");
            await _production.PairAsync(host, pin, _lifetime.Token);
            SelectedSavedHost = SavedHosts.FirstOrDefault(h => h.Id == host.Id);
        });

    private async Task SaveAddressAsync()
    {
        await RunClientActionAsync("Private address saved · select Connect to use it", async () =>
        {
            var host = SelectedHost ?? throw new InvalidOperationException("Select a paired computer first.");
            if (!int.TryParse(DirectPort, out var port)) throw new ArgumentException("Enter the computer's actual TLS port.");
            await _production!.SaveAddressAsync(host, DirectAddress.Trim(), port, _lifetime.Token);
            SelectedSavedHost = SavedHosts.FirstOrDefault(h => h.Id == host.Id);
        });
    }

    private async Task RunClientActionAsync(string title, Func<Task> action)
    {
        try { await action(); ReloadHosts(); SetNotice(title, "Manual streaming is free. Remote input always requires explicit control."); }
        catch (OperationCanceledException) when (_lifetime.IsCancellationRequested) { }
        catch (Exception e) { SetNotice("Action could not complete", e.Message); }
    }

    private async Task ToggleControlAsync()
    {
        if (IsControlEnabled) { ReleaseControl(); return; }
        await RunClientActionAsync("Control requested", () => _production!.EnableViewerControlAsync(_production.Input, _lifetime.Token));
    }

    public HostCandidate? SelectedHost
    {
        get => _selectedHost;
        private set
        {
            if (!SetProperty(ref _selectedHost, value))
            {
                return;
            }

            OnPropertyChanged(nameof(SelectedHostLabel));
            DirectAddress = value?.IsDirect == true ? value.Address : "";
            DirectPort = value?.IsDirect == true ? value.Port.ToString() : "";
            RaiseCommandStates();
        }
    }

    public HostCandidate? SelectedDiscoveredHost
    {
        get => _selectedDiscoveredHost;
        set
        {
            if (!SetProperty(ref _selectedDiscoveredHost, value))
            {
                return;
            }

            if (value is not null)
            {
                if (_selectedSavedHost is not null)
                {
                    _selectedSavedHost = null;
                    OnPropertyChanged(nameof(SelectedSavedHost));
                }

                SelectedHost = value;
            }
            else if (SelectedSavedHost is null)
            {
                SelectedHost = null;
            }
        }
    }

    public HostCandidate? SelectedSavedHost
    {
        get => _selectedSavedHost;
        set
        {
            if (!SetProperty(ref _selectedSavedHost, value))
            {
                return;
            }

            if (value is not null)
            {
                if (_selectedDiscoveredHost is not null)
                {
                    _selectedDiscoveredHost = null;
                    OnPropertyChanged(nameof(SelectedDiscoveredHost));
                }

                SelectedHost = value;
            }
            else if (SelectedDiscoveredHost is null)
            {
                SelectedHost = null;
            }
        }
    }

    public RemoteWindowDescriptor? SelectedWindow
    {
        get => _selectedWindow;
        set
        {
            if (!SetProperty(ref _selectedWindow, value))
            {
                return;
            }

            ReleaseControl();

            OnPropertyChanged(nameof(SurfaceTitle));
            OnPropertyChanged(nameof(SurfaceMessage));
            RaiseCommandStates();
        }
    }

    public PeelConnectionState ConnectionState
    {
        get => _connectionState;
        private set
        {
            if (SetProperty(ref _connectionState, value))
            {
                OnPropertyChanged(nameof(ConnectionStateLabel));
                OnPropertyChanged(nameof(InputAvailabilityText));
                RaiseCommandStates();
            }
        }
    }

    public PeelStreamState StreamState
    {
        get => _streamState;
        private set
        {
            if (SetProperty(ref _streamState, value))
            {
                if (value is PeelStreamState.Stopped or PeelStreamState.Error)
                {
                    ClearPresentedFrame();
                }

                OnPropertyChanged(nameof(StreamStateLabel));
                OnPropertyChanged(nameof(SurfaceMessage));
                OnPropertyChanged(nameof(InputAvailabilityText));
                RaiseCommandStates();
            }
        }
    }

    public string NoticeTitle
    {
        get => _noticeTitle;
        private set => SetProperty(ref _noticeTitle, value);
    }

    public string NoticeDetail
    {
        get => _noticeDetail;
        private set => SetProperty(ref _noticeDetail, value);
    }

    public bool HasNoDiscoveredHosts => DiscoveredHosts.Count == 0;

    public bool HasNoSavedHosts => SavedHosts.Count == 0;

    public bool HasNoRemoteWindows => RemoteWindows.Count == 0;

    /// <summary>Same admission as Show here; the selection is always an entry of the current inventory.</summary>
    public bool CanOpenSelectedWindow => SelectedWindow is not null && ConnectionState == PeelConnectionState.Connected;

    public int FramePixelWidth => _presenter.PixelWidth;
    public int FramePixelHeight => _presenter.PixelHeight;
    public string FrameStatistics { get => _frameStatistics; private set => SetProperty(ref _frameStatistics, value); }
    public ImageSource? PeeledFrameSource
    {
        get => _peeledFrameSource;
        private set => SetProperty(ref _peeledFrameSource, value);
    }

    public string SelectedHostLabel => SelectedHost?.DisplayName ?? "No computer selected";

    public string ConnectionStateLabel => ConnectionState switch
    {
        PeelConnectionState.Disconnected => "Disconnected",
        PeelConnectionState.Connecting => "Connecting",
        PeelConnectionState.Connected => "Connected",
        PeelConnectionState.Disconnecting => "Disconnecting",
        PeelConnectionState.Error => "Unavailable",
        _ => "Unknown"
    };

    public string StreamStateLabel => StreamState switch
    {
        PeelStreamState.Stopped => "No stream",
        PeelStreamState.Starting => "Starting",
        PeelStreamState.Streaming => "Live",
        PeelStreamState.Stopping => "Stopping",
        PeelStreamState.Error => "Unavailable",
        _ => "Unknown"
    };

    public string SurfaceTitle => _windowList.Windows.FirstOrDefault(w => w.Id == _streamControl.StreamingWindowId)?.Title
        ?? SelectedWindow?.Title ?? "Remote desktop";

    public string SurfaceMessage => StreamState switch
    {
        PeelStreamState.Streaming => "Waiting for the first decoded frame…",
        PeelStreamState.Error => "Streaming is unavailable. No placeholder frames are being presented.",
        _ when SelectedWindow is not null => "Choose Open for its own window, or Show here to view it beside this list.",
        _ => "Connect to a computer, then choose a desktop or app window."
    };

    public string InputAvailabilityText => ConnectionState == PeelConnectionState.Connected && StreamState == PeelStreamState.Streaming
        ? "Pointer and keyboard input may be sent only through the normalized input service."
        : "Input is disabled until a secure session and live stream are established.";

    public async Task InitializeAsync()
    {
        try
        {
            await _discovery.StartAsync(_lifetime.Token);
            ReloadHosts();
            SetNotice("Ready to connect", _production?.LoadError ?? "Select a nearby computer and pair with its PIN. Manual streaming is free.");
        }
        catch (OperationCanceledException) when (_lifetime.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            ConnectionState = PeelConnectionState.Error;
            SetUnavailable(exception);
        }
    }

    private async Task RefreshHostsAsync()
    {
        try
        {
            await _discovery.RefreshAsync(_lifetime.Token);
            ReloadHosts();
            SetNotice("Discovery refreshed", "Only computers currently advertising Peel Pro on this network are shown.");
        }
        catch (OperationCanceledException) when (_lifetime.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            ConnectionState = PeelConnectionState.Error;
            SetUnavailable(exception);
        }
    }

    private async Task ConnectAsync()
    {
        if (SelectedHost is null)
        {
            return;
        }

        try
        {
            ConnectionState = PeelConnectionState.Connecting;
            SetNotice("Connecting securely", $"Opening a TLS-PSK session to {SelectedHost.DisplayName}.");
            await _connection.ConnectAsync(SelectedHost, _lifetime.Token);
            await _windowList.StartAsync(_lifetime.Token);
            ConnectionState = _connection.State;
            ReloadWindows();
        }
        catch (OperationCanceledException) when (_lifetime.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            ConnectionState = PeelConnectionState.Error;
            RemoteWindows.Clear();
            RaiseCollectionStates();
            SetUnavailable(exception);
        }
    }

    private async Task DisconnectAsync()
    {
        try
        {
            await StopStreamIfNeededAsync();
            await _windowList.StopAsync(_lifetime.Token);
            await _connection.DisconnectAsync(_lifetime.Token);
            ConnectionState = PeelConnectionState.Disconnected;
            RemoteWindows.Clear();
            SelectedWindow = null;
            RaiseCollectionStates();
            SetNotice("Disconnected", "Select a nearby or paired computer to reconnect.");
        }
        catch (OperationCanceledException) when (_lifetime.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            ConnectionState = PeelConnectionState.Error;
            SetUnavailable(exception);
        }
    }

    private async Task StartStreamAsync()
    {
        if (SelectedWindow is null)
        {
            return;
        }

        try
        {
            ClearPresentedFrame();
            StreamState = PeelStreamState.Starting;
            await _streamControl.StartAsync(SelectedWindow, _lifetime.Token);
            StreamState = _streamControl.State;
        }
        catch (OperationCanceledException) when (_lifetime.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            StreamState = PeelStreamState.Error;
            SetUnavailable(exception);
        }
    }

    private async Task StopStreamAsync()
    {
        try
        {
            StreamState = PeelStreamState.Stopping;
            await _streamControl.StopAsync(_lifetime.Token);
            StreamState = PeelStreamState.Stopped;
        }
        catch (OperationCanceledException) when (_lifetime.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            StreamState = PeelStreamState.Error;
            SetUnavailable(exception);
        }
    }

    private async Task StopStreamIfNeededAsync()
    {
        if (StreamState is PeelStreamState.Starting or PeelStreamState.Streaming or PeelStreamState.Error)
        {
            await _streamControl.StopAsync(_lifetime.Token);
            StreamState = PeelStreamState.Stopped;
        }
    }

    private void HandleHostsChanged(object? sender, EventArgs e) => OnUiThread(ReloadHosts);

    private void HandleWindowsChanged(object? sender, EventArgs e) => OnUiThread(ReloadWindows);

    private void HandleConnectionStateChanged(object? sender, ConnectionStateChangedEventArgs e)
    {
        OnUiThread(() =>
        {
            ConnectionState = e.State;
            if (e.State != PeelConnectionState.Connected)
            {
                _autoOpenedDesktop = false;
                ReleaseControl();
                RemoteWindows.Clear(); SelectedWindow = null; ClearPresentedFrame(); RaiseCollectionStates();
            }
            else SetNotice("Connected securely", "Choose a desktop or app window. Control starts off.");
            if (!string.IsNullOrWhiteSpace(e.Detail))
            {
                SetNotice(ConnectionStateLabel, e.Detail);
            }
        });
    }

    private void HandleStreamStateChanged(object? sender, StreamStateChangedEventArgs e)
    {
        OnUiThread(() =>
        {
            StreamState = e.State;
            if (!string.IsNullOrWhiteSpace(e.Detail))
            {
                SetNotice(StreamStateLabel, e.Detail);
            }
        });
    }

    private void HandleFrameAvailable(object? sender, DecodedVideoFrameEventArgs e)
    {
        if (_lifetime.IsCancellationRequested || !_frameMailbox.Publish(e.Frame))
        {
            return;
        }

        QueueFramePresentation();
    }

    private void QueueFramePresentation()
    {
        var dispatcher = Application.Current?.Dispatcher;
        if (dispatcher is null || dispatcher.HasShutdownStarted || dispatcher.HasShutdownFinished)
        {
            _frameMailbox.Reset();
            return;
        }

        try
        {
            _ = dispatcher.BeginInvoke(
                DispatcherPriority.Render,
                new Action(PresentLatestFrame));
        }
        catch (InvalidOperationException)
        {
            _frameMailbox.Reset();
        }
    }

    private void PresentLatestFrame()
    {
        try
        {
            using DecodedVideoFrame? frame = _frameMailbox.TakeLatest();
            if (frame is null ||
                _lifetime.IsCancellationRequested ||
                StreamState is not (PeelStreamState.Starting or PeelStreamState.Streaming))
            {
                return;
            }

            if (_presenter.Present(frame))
            {
                PeeledFrameSource = _presenter.Source;
                _presentationClock.Start(); _presented++;
                if (_presentationClock.Elapsed.TotalSeconds >= 1)
                {
                    FrameStatistics = $"{frame.PixelWidth} × {frame.PixelHeight} · {_presented / _presentationClock.Elapsed.TotalSeconds:F1} viewer updates/s · {(frame.UsesGpuPresentation ? "GPU" : "CPU fallback")}";
                    _presentationClock.Restart(); _presented = 0;
                }
            }
        }
        catch (InvalidDataException exception)
        {
            ClearPresentedFrame(); _production?.Input.Disable();
            SetNotice("Decoded frame rejected", exception.Message);
        }
        catch (ArgumentException exception)
        {
            ClearPresentedFrame(); _production?.Input.Disable();
            SetNotice("Frame presentation unavailable", exception.Message);
        }
        catch (System.Runtime.InteropServices.COMException exception)
        {
            ClearPresentedFrame(); _production?.Input.Disable();
            SetNotice("Graphics presentation unavailable", exception.Message);
        }
        finally
        {
            if (_frameMailbox.CompletePresentation())
            {
                QueueFramePresentation();
            }
        }
    }

    private void ClearPresentedFrame()
    {
        _frameMailbox.Reset();
        PeeledFrameSource = null;
        _presenter.Dispose();
        _presentationClock.Reset(); _presented = 0; FrameStatistics = "";
    }

    private void ReloadHosts()
    {
        var selected = SelectedHost;
        ReplaceItems(DiscoveredHosts, _discovery.DiscoveredHosts);
        ReplaceItems(SavedHosts, _discovery.SavedHosts);
        if (selected is not null)
        {
            if (selected.IsSaved) SelectedSavedHost = SavedHosts.FirstOrDefault(h => h.Id == selected.Id && h.IsDirect == selected.IsDirect);
            else SelectedDiscoveredHost = DiscoveredHosts.FirstOrDefault(h => h.Id == selected.Id);
        }
        RaiseCommandStates();
        RaiseCollectionStates();
    }

    private void ReloadWindows()
    {
        var selected = SelectedWindow;
        var filtered = _windowList.Windows.Where(w => string.IsNullOrWhiteSpace(WindowSearch)
            || w.Title.Contains(WindowSearch, StringComparison.OrdinalIgnoreCase)
            || w.OwnerName.Contains(WindowSearch, StringComparison.OrdinalIgnoreCase));
        ReplaceItems(RemoteWindows, filtered);
        SelectedWindow = selected is null ? null : RemoteWindows.FirstOrDefault(w => w.Id == selected.Id);
        if (!_autoOpenedDesktop && ConnectionState == PeelConnectionState.Connected)
        {
            var desktop = RemoteWindows.FirstOrDefault(w => w.IsDesktop);
            if (desktop is not null) { _autoOpenedDesktop = true; SelectedWindow = desktop; _ = StartStreamAsync(); }
        }
        RaiseCollectionStates();
    }

    private static void ReplaceItems<T>(ObservableCollection<T> target, IEnumerable<T> source)
    {
        var items = source.ToArray();
        for (int i = 0; i < items.Length; i++)
        {
            if (i < target.Count && EqualityComparer<T>.Default.Equals(target[i], items[i])) continue;
            int existing = target.IndexOf(items[i]);
            if (existing >= 0) target.Move(existing, i);
            else target.Insert(i, items[i]);
        }
        while (target.Count > items.Length) target.RemoveAt(target.Count - 1);
    }

    private static void OnUiThread(Action action)
    {
        var dispatcher = Application.Current?.Dispatcher;
        if (dispatcher is null || dispatcher.CheckAccess())
        {
            action();
            return;
        }

        // Never block a transport/decoder worker waiting on the UI during shutdown.
        if (!dispatcher.HasShutdownStarted) _ = dispatcher.BeginInvoke(action);
    }

    private void SetUnavailable(Exception exception)
    {
        SetNotice("Client capability unavailable", exception.Message);
    }

    private void SetNotice(string title, string detail)
    {
        NoticeTitle = title;
        NoticeDetail = detail;
    }

    private void RaiseCollectionStates()
    {
        OnPropertyChanged(nameof(HasNoDiscoveredHosts));
        OnPropertyChanged(nameof(HasNoSavedHosts));
        OnPropertyChanged(nameof(HasNoRemoteWindows));
    }

    private void RaiseCommandStates()
    {
        ConnectCommand.RaiseCanExecuteChanged();
        DisconnectCommand.RaiseCanExecuteChanged();
        StartStreamCommand.RaiseCanExecuteChanged(); OnPropertyChanged(nameof(CanOpenSelectedWindow));
        StopStreamCommand.RaiseCanExecuteChanged();
        RefreshWindowsCommand.RaiseCanExecuteChanged(); ToggleControlCommand.RaiseCanExecuteChanged();
        ForgetHostCommand.RaiseCanExecuteChanged(); SaveAddressCommand.RaiseCanExecuteChanged(); RemoveAddressCommand.RaiseCanExecuteChanged();
    }

    public async ValueTask DisposeAsync()
    {
        _lifetime.Cancel();
        _frameMailbox.Close();

        _discovery.HostsChanged -= HandleHostsChanged;
        _connection.StateChanged -= HandleConnectionStateChanged;
        _windowList.WindowsChanged -= HandleWindowsChanged;
        _streamControl.StateChanged -= HandleStreamStateChanged;
        _streamControl.FrameAvailable -= HandleFrameAvailable;
        SourceControls.Dispose();
        ClearPresentedFrame();

        using var shutdownTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        try
        {
            await _streamControl.StopAsync(shutdownTimeout.Token).ConfigureAwait(false);
            await _windowList.StopAsync(shutdownTimeout.Token).ConfigureAwait(false);
            await _connection.DisconnectAsync(shutdownTimeout.Token).ConfigureAwait(false);
            await _discovery.StopAsync(shutdownTimeout.Token).ConfigureAwait(false);
        }
        catch
        {
            // Shutdown is best effort. Each service still owns cancellation and resource cleanup.
        }

        _lifetime.Dispose();
    }
}
