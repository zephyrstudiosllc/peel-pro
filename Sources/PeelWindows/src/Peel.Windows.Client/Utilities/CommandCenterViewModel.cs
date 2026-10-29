using System.Collections.ObjectModel;
using System.IO;
using System.Text.Json;
using System.Windows.Threading;
using Peel.Windows.Client.ViewModels;

namespace Peel.Windows.Client.Utilities;

public sealed partial class CommandCenterViewModel : ObservableObject, IAsyncDisposable
{
    private readonly SystemMonitor monitor = new();
    private readonly CodexUsageProvider usage = new();
    private readonly ProcessActions actions = new();
    private readonly LocalAgentActivity activity = new();
    private readonly Dictionary<string, DateTimeOffset> dismissedActivity = new();
    public ObservableCollection<AgentActivityReading> LocalActivity { get; } = new();
    public AgentActivityReading? SelectedActivity { get; set; }
    public AsyncCommand DismissActivityCommand { get; }
    public string LocalActivityStatus => LocalActivity.Count == 0 ? "No recognized Codex activity in the last 15 minutes." : $"{LocalActivity.Count} local Codex session(s) with recent recorded activity.";
    public string CompactActivityLabel => ActivityLabel;
    private readonly Dispatcher dispatcher;
    private readonly CancellationTokenSource lifetime = new();
    private readonly SemaphoreSlim usageGate = new(1, 1);
    private readonly SemaphoreSlim historyGate = new(1, 1);
    private readonly UsageHistoryStore historyStore = new();
    private UsagePreferences usagePreferences;
    private Task? usageLoop;
    private long nextUsageRefresh;
    private string historyStatus = "Refresh to read recent local Codex chat metadata.";
    public ObservableCollection<UsageWindow> UsageHistory { get; } = new();
    public ObservableCollection<UsageChoice> UsageChoices { get; } = new();
    public ObservableCollection<AgentHistoryEntry> AgentHistory { get; } = new();
    public AsyncCommand RefreshAgentHistoryCommand { get; }
    public AsyncCommand ShowUsageBarCommand { get; }
    public Action? ShowUsageBar { get; set; }
    public string HistoryStatus { get => historyStatus; private set => SetProperty(ref historyStatus, value); }
    public bool AutomaticUsageRefresh
    {
        get => usagePreferences.AutomaticRefresh;
        set { usagePreferences = usagePreferences with { AutomaticRefresh = value }; SaveUsagePreferences(); OnPropertyChanged(); }
    }
    public string PinnedUsageId
    {
        get => usagePreferences.PinnedId;
        set
        {
            if (value is null) return; // ItemsSource replacement must not erase a saved, temporarily unavailable selection.
            var label = UsageChoices.FirstOrDefault(c => c.Id == value)?.Label ?? "";
            usagePreferences = usagePreferences with { PinnedId = value, PinnedLabel = label };
            SaveUsagePreferences(); OnPropertyChanged(); OnPropertyChanged(nameof(PinnedUsageLabel)); Updated?.Invoke(this, EventArgs.Empty);
        }
    }
    public string PinnedUsageLabel
    {
        get
        {
            if (string.IsNullOrEmpty(PinnedUsageId)) return "No allowance pinned";
            var row = Usage.FirstOrDefault(r => r.Id == PinnedUsageId);
            return row is null ? $"{usagePreferences.PinnedLabel}: unavailable" :
                $"{row.Label}: {row.RemainingLabel}" + (DateTimeOffset.UtcNow - row.SampledAt > TimeSpan.FromMinutes(10) ? " · stale" : "");
        }
    }
    public string TopAppLabel => RankedProcesses().FirstOrDefault(p => p.HasWindow) is { } p ? $"{p.Name} · {p.CpuLabel} CPU · {p.MemoryLabel}" : "No active app reading";
    private Task? sampling;
    private SystemReading? reading;
    private string notice = "Reading this PC…", usageStatus = "Refresh to read your signed-in Codex account.";
    private string filter = "";
    private bool applicationsOnly = true;
    private ProcessReading? selected;
    private bool alertsEnabled;
    private readonly AlertEvaluator alertEvaluator = new();
    public AlertPolicy AlertPolicy { get; } = AlertPolicy.Load();
    public AsyncCommand SaveAlertPolicyCommand { get; }
    private readonly string settingsPath;
    private StreamingPreferences streaming = StreamingPreferences.Load();
    private string streamingStatus = "Capture uses the source's native size. Target frame rate depends on hardware, source refresh, and network throughput.";
    public int[] FrameRates { get; } = [30, 60, 120];
    public int TargetFrameRate { get => streaming.FramesPerSecond; set { streaming = streaming with { FramesPerSecond = value }; OnPropertyChanged(); } }
    public int TargetBitrate { get => streaming.BitrateMbps; set { streaming = streaming with { BitrateMbps = value }; OnPropertyChanged(); } }
    public bool HardwareEncoding { get => streaming.HardwareEncoding; set { streaming = streaming with { HardwareEncoding = value }; OnPropertyChanged(); } }
    public bool EnableHevc { get => streaming.EnableHevc; set { streaming = streaming with { EnableHevc = value }; OnPropertyChanged(); } }
    public string StreamingStatus { get => streamingStatus; private set => SetProperty(ref streamingStatus, value); }
    public Func<Task>? ApplyStreamingSettings { get; set; }
    public AsyncCommand ApplyStreamingCommand { get; }
    private string audioStatus = "Audio off";
    // Saved Host audio sharing choice; null means never chosen, which defaults to on.
    private bool? shareSystemAudioChoice;
    private bool SavedShareSystemAudio => shareSystemAudioChoice ?? true;
    public bool CanShareSystemAudio => HostAudioService.Shared.Supported;
    public bool ShareSystemAudio
    {
        get => HostAudioService.Shared.Enabled;
        set
        {
            // Only this explicit setting is saved. Lock, suspend and exit pause sharing without a saved Off.
            shareSystemAudioChoice = value; SaveUtilitySettings();
            HostAudioService.Shared.SetEnabled(value); OnPropertyChanged(); OnPropertyChanged(nameof(HostAudioStatus));
        }
    }
    /// <summary>Temporarily stops Host audio sharing (lock or suspend) without changing the saved choice.</summary>
    internal void SuspendSystemAudioSharing()
    {
        HostAudioService.Shared.SetEnabled(false); OnPropertyChanged(nameof(ShareSystemAudio)); OnPropertyChanged(nameof(HostAudioStatus));
    }
    /// <summary>Reapplies the saved Host audio sharing choice once hosting is no longer paused.</summary>
    internal void RestoreSystemAudioSharing()
    {
        HostAudioService.Shared.SetEnabled(SavedShareSystemAudio); OnPropertyChanged(nameof(ShareSystemAudio)); OnPropertyChanged(nameof(HostAudioStatus));
    }
    private readonly ViewModels.SourceControlPreferences sourceControls;
    /// <summary>Pure presentation: shows the streamed computer's volume group in viewers.</summary>
    public bool ShowSourceVolume
    {
        get => sourceControls.ShowVolume;
        set { if (sourceControls.ShowVolume == value) return; sourceControls.ShowVolume = value; SaveUtilitySettings(); OnPropertyChanged(); }
    }
    /// <summary>Pure presentation: shows the streamed computer's previous/play-pause/next group in viewers.</summary>
    public bool ShowSourceMediaControls
    {
        get => sourceControls.ShowMediaControls;
        set { if (sourceControls.ShowMediaControls == value) return; sourceControls.ShowMediaControls = value; SaveUtilitySettings(); OnPropertyChanged(); }
    }
    public string HostAudioStatus => CanShareSystemAudio ? HostAudioService.Shared.Status : "System audio sharing requires Windows build 20348 or later.";
    public string AudioStatus { get => audioStatus; private set => SetProperty(ref audioStatus, value); }
    public Func<CancellationToken, Task>? StartAudio { get; set; }
    public Func<CancellationToken, Task>? StartVoice { get; set; }
    public Func<Task>? StopAudio { get; set; }
    public Func<string>? ReadAudioStatus { get; set; }
    public AsyncCommand StartAudioCommand { get; }
    public AsyncCommand StartVoiceCommand { get; }
    public AsyncCommand StopAudioCommand { get; }
    public Services.TrustedSignalReceiver? DeviceSignals { get; set; }
    public Services.TrustedSignalPublisher? SignalPublisher { get; set; }
    public AsyncCommand StartPublishingSignalsCommand { get; }
    public AsyncCommand StopPublishingSignalsCommand { get; }
    private string publishingStatus = "Local activity sharing is off.";
    public string PublishingStatus { get => publishingStatus; private set => SetProperty(ref publishingStatus, value); }
    public ObservableCollection<Services.ReceivedDeviceSignal> SignalRows { get; } = new();
    public AsyncCommand StartSignalsCommand { get; }
    public AsyncCommand StopSignalsCommand { get; }
    private string signalStatus = "Paired signals are off.", signalLabel = "Device activity off";
    public string SignalStatus { get => signalStatus; private set => SetProperty(ref signalStatus, value); }
    public string SignalLabel { get => signalLabel; private set { if (SetProperty(ref signalLabel, value)) OnPropertyChanged(nameof(CompactActivityLabel)); } }
    private bool allowLocalAgents;
    private long agentConsentVersion;
    public long AgentConsentVersion => Interlocked.Read(ref agentConsentVersion);
    public bool AllowLocalAgents { get => allowLocalAgents; set { if (SetProperty(ref allowLocalAgents, value)) { Interlocked.Increment(ref agentConsentVersion); if (!value) localComputer?.Disable("Off · local agent connections are off."); LocalAgentConsentChanged?.Invoke(this, EventArgs.Empty); RefreshAgentAppControl(); } } }
    public event EventHandler? LocalAgentConsentChanged;

    private Services.LocalComputerAccess? localComputer;
    private AsyncCommand? stopAgentAppControl;
    /// <summary>Lets the Agent Hub drive runtime-only "Allow AI to see and use apps on this PC" consent and Stop.</summary>
    internal void AttachLocalComputer(Services.LocalComputerAccess access)
    {
        localComputer = access;
        access.Changed += (_, _) => dispatcher.BeginInvoke(new Action(RefreshAgentAppControl));
        RefreshAgentAppControl();
    }
    private void RefreshAgentAppControl()
    {
        OnPropertyChanged(nameof(AllowAgentAppControl)); OnPropertyChanged(nameof(IsAgentAppControlActive));
        OnPropertyChanged(nameof(AgentAppControlEnabled)); OnPropertyChanged(nameof(AgentAppControlStatus));
        StopAgentAppControlCommand.RaiseCanExecuteChanged();
    }
    /// <summary>Turning it on needs local agent connections; turning it off is always available.</summary>
    public bool AgentAppControlEnabled => localComputer is not null && (AllowLocalAgents || localComputer.IsEnabled);
    public bool IsAgentAppControlActive => localComputer?.IsEnabled ?? false;
    public string AgentAppControlStatus => localComputer?.Status ?? "Local AI window control is not included in this build.";
    public bool AllowAgentAppControl
    {
        get => localComputer?.IsEnabled ?? false;
        set
        {
            if (localComputer is null) return;
            if (!value) localComputer.Disable("Off");
            else if (!localComputer.Enable(AllowLocalAgents, out string? error)) Notice = error ?? "AI control stays off.";
            RefreshAgentAppControl();
        }
    }
    public AsyncCommand StopAgentAppControlCommand => stopAgentAppControl ??=
        new(() => { localComputer?.Disable("Stopped"); return Task.CompletedTask; }, () => IsAgentAppControlActive);
    public string AgentConfiguration => FormatAgentConfiguration(AppContext.BaseDirectory, File.Exists);
    /// <summary>Self-contained installs ship the companion's own apphost beside Peel and need no dotnet on PATH;
    /// only a framework-dependent layout without it runs the sibling dll through a dotnet host.</summary>
    internal static string FormatAgentConfiguration(string baseDirectory, Func<string, bool> fileExists)
    {
        string command = Path.Combine(baseDirectory, "Peel.Windows.Mcp.exe");
        string[] args = [];
        if (!fileExists(command))
        {
            string runtime = System.Runtime.InteropServices.RuntimeEnvironment.GetRuntimeDirectory();
            string dotnet = Path.GetFullPath(Path.Combine(runtime, "..", "..", "..", "dotnet.exe"));
            command = fileExists(dotnet) ? dotnet : "dotnet";
            args = [Path.Combine(baseDirectory, "Peel.Windows.Mcp.dll")];
        }
        return JsonSerializer.Serialize(new { mcpServers = new { peel = new { command, args } } }, new JsonSerializerOptions { WriteIndented = true });
    }
    public void NotifyFromAgent(string title, string message) => AlertRaised?.Invoke(this, title + " · " + message);
    public AsyncCommand RefreshRemoteStatusCommand { get; }
    public Func<CancellationToken, Task<Peel.Windows.Protocol.MachineStatusMessage>>? RequestRemoteStatus { get; set; }
    private string remoteStatus = "Connect to a host, then request a snapshot. Sharing must also be enabled on that host.";
    public string RemoteStatus { get => remoteStatus; private set => SetProperty(ref remoteStatus, value); }
    public bool ShareMachineStatus
    {
        get => MachineStatusService.Shared.Enabled;
        set
        {
            try { MachineStatusService.Shared.SetEnabled(value); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { Notice = "Could not save Machine Status preference."; }
            OnPropertyChanged();
        }
    }
    public ObservableCollection<ProcessReading> Processes { get; } = new();
    public ObservableCollection<UsageWindow> Usage { get; } = new();
    public ObservableCollection<string> Alerts { get; } = new();
    public ObservableCollection<string> Agents { get; } = new();
    public AsyncCommand RefreshUsageCommand { get; }
    public event EventHandler<string>? AlertRaised;
    public event EventHandler? Updated;
    public string Notice { get => notice; private set => SetProperty(ref notice, value); }
    public string UsageStatus { get => usageStatus; private set => SetProperty(ref usageStatus, value); }
    public string CpuLabel => reading?.CpuPercent is { } cpu ? $"{cpu:F0}%" : "Sampling…";
    public string GpuLabel => reading?.Hardware?.GpuPercent is { } gpu ? $"GPU {gpu:F0}% · busiest engine" : "GPU unavailable";
    public string DiskIoLabel => reading?.Hardware is { DiskReadBytesPerSecond: { } r, DiskWriteBytesPerSecond: { } w }
        ? $"Read {r / 1048576:F1} · Write {w / 1048576:F1} MB/s" : "Disk activity unavailable";
    public string MemoryLabel => reading is { } s ? $"{s.MemoryUsedBytes / 1073741824.0:F1} / {s.MemoryTotalBytes / 1073741824.0:F1} GB" : "—";
    public double MemoryPercent => reading?.MemoryPercent ?? 0;
    public string StorageLabel => reading is { } s ? $"{s.StorageFreeBytes / 1073741824.0:N0} GB free" : "—";
    public string BatteryLabel => reading?.BatteryPercent is { } b ? $"{b:F0}%" : "Not available";
    public string NetworkLabel => reading is { } s ? $"↓ {s.ReceiveBytesPerSecond / 1048576.0:F2}  ↑ {s.SendBytesPerSecond / 1048576.0:F2} MB/s" : "—";
    public string TraySummary => string.Join(" · ", new[]
    {
        ShowBarGauge ? SelectedGaugesLabel : null,
        ShowUsageInBar && !string.IsNullOrEmpty(PinnedUsageId) ? PinnedUsageLabel : null,
    }.Where(static value => !string.IsNullOrWhiteSpace(value)));
    public string ProcessFilter { get => filter; set { if (SetProperty(ref filter, value)) RefreshProcessRows(); } }
    public bool ApplicationsOnly { get => applicationsOnly; set { if (SetProperty(ref applicationsOnly, value)) RefreshProcessRows(); } }
    public ProcessReading? SelectedProcess { get => selected; set => SetProperty(ref selected, value); }
    public bool AlertsEnabled
    {
        get => alertsEnabled;
        set
        {
            if (!SetProperty(ref alertsEnabled, value)) return;
            SaveUtilitySettings();
        }
    }

    private void SaveUtilitySettings()
    {
        // One document for every utility key, so saving one setting never erases another.
        var values = new Dictionary<string, bool>
        {
            ["alertsEnabled"] = alertsEnabled,
            ["showVolume"] = sourceControls.ShowVolume,
            ["showMediaControls"] = sourceControls.ShowMediaControls,
        };
        if (shareSystemAudioChoice is { } share) values["shareSystemAudio"] = share;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(settingsPath)!);
            string temporary = settingsPath + ".tmp";
            File.WriteAllText(temporary, JsonSerializer.Serialize(values)); File.Move(temporary, settingsPath, true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { Notice = "Could not save utility preferences."; }
    }

    public CommandCenterViewModel(Dispatcher dispatcher) : this(dispatcher, SignalSettings.Shared) { }
    internal CommandCenterViewModel(Dispatcher dispatcher, SignalSettings signalSettings,
        ViewModels.SourceControlPreferences? sourceControls = null)
    {
        this.signalSettings = signalSettings;
        this.sourceControls = sourceControls ?? ViewModels.SourceControlPreferences.Shared;
        this.dispatcher = dispatcher;
        usagePreferences = historyStore.LoadPreferences();
        RebuildUsageChoices();
        settingsPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Zephyr Studios", "Peel", "Utilities", "settings.json");
        try
        {
            if (File.Exists(settingsPath) && new FileInfo(settingsPath).Length > 4096) throw new IOException("Utility settings are too large.");
            if (File.Exists(settingsPath))
            {
                using var doc = JsonDocument.Parse(File.ReadAllText(settingsPath));
                alertsEnabled = doc.RootElement.TryGetProperty("alertsEnabled", out var enabled) && enabled.ValueKind == JsonValueKind.True;
                // Visibility defaults to shown; only an explicit false hides a group.
                this.sourceControls.ShowVolume = !(doc.RootElement.TryGetProperty("showVolume", out var volume) && volume.ValueKind == JsonValueKind.False);
                this.sourceControls.ShowMediaControls = !(doc.RootElement.TryGetProperty("showMediaControls", out var media) && media.ValueKind == JsonValueKind.False);
                if (doc.RootElement.TryGetProperty("shareSystemAudio", out var share) && share.ValueKind is JsonValueKind.True or JsonValueKind.False)
                    shareSystemAudioChoice = share.ValueKind == JsonValueKind.True;
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or InvalidOperationException)
        {
            // An unreadable file may hold a saved Off: Host audio sharing stays off until chosen again.
            shareSystemAudioChoice = false;
            Notice = "Using default utility preferences; settings could not be read.";
        }
        // Host audio sharing defaults on when never chosen. Consent per session, a visible paired client,
        // proof and lock/suspend pauses still apply; this only sets the Host's saved willingness.
        HostAudioService.Shared.SetEnabled(SavedShareSystemAudio);
        RefreshUsageCommand = new(() => Task.Run(RefreshUsageAsync));
        RefreshAgentHistoryCommand = new(() => Task.Run(RefreshAgentHistoryAsync));
        ShowUsageBarCommand = new(() => { ShowUsageBar?.Invoke(); return Task.CompletedTask; });
        DismissActivityCommand = new(() =>
        {
            if (SelectedActivity is { } row) dismissedActivity[row.Id] = row.EventAt;
            RefreshSignalPresentation(); return Task.CompletedTask;
        });
        StartSignalsCommand = new(async () =>
        {
            if (DeviceSignals is null) { SignalStatus = "Device signals are unavailable."; return; }
            try { await DeviceSignals.StartAsync(lifetime.Token); RefreshSignals(); }
            catch (OperationCanceledException) { SignalStatus = "Signal discovery canceled."; }
            catch (Exception e) when (e is IOException or InvalidOperationException) { SignalStatus = "Could not start paired signals."; }
        });
        StopSignalsCommand = new(async () => { if (DeviceSignals is not null) await DeviceSignals.StopAsync(); RefreshSignals(); });
        StartPublishingSignalsCommand = new(async () =>
        {
            if (SignalPublisher is null) { PublishingStatus = "Local activity sharing is unavailable."; return; }
            try { SignalPublisher.UpdateLocalActivity(LocalActivity); await SignalPublisher.StartAsync(lifetime.Token); RefreshSignals(); }
            catch (Exception e) when (e is IOException or InvalidDataException or InvalidOperationException or ArgumentException or OperationCanceledException)
            { PublishingStatus = e.Message; }
        });
        StopPublishingSignalsCommand = new(async () => { if (SignalPublisher is not null) await SignalPublisher.StopAsync(); RefreshSignals(); });
        StartAudioCommand = new(async () =>
        {
            try
            {
                if (StartAudio is null) throw new InvalidOperationException("Connect to a host first.");
                await StartAudio(lifetime.Token); AudioStatus = ReadAudioStatus?.Invoke() ?? "Audio status unavailable";
            }
            catch (OperationCanceledException) { AudioStatus = ReadAudioStatus?.Invoke() ?? "Audio canceled"; }
            catch (Exception e) when (e is IOException or InvalidOperationException) { AudioStatus = e.Message; }
        });
        StartVoiceCommand = new(async () =>
        {
            try
            {
                if (StartVoice is null) throw new InvalidOperationException("Connect to a host first.");
                await StartVoice(lifetime.Token); AudioStatus = ReadAudioStatus?.Invoke() ?? "Voice status unavailable";
            }
            catch (OperationCanceledException) { AudioStatus = ReadAudioStatus?.Invoke() ?? "Voice canceled"; }
            catch (Exception e) when (e is IOException or InvalidOperationException) { AudioStatus = e.Message; }
        });
        StopAudioCommand = new(async () => { if (StopAudio is not null) await StopAudio(); AudioStatus = ReadAudioStatus?.Invoke() ?? "Audio off"; });
        SaveAlertPolicyCommand = new(() =>
        {
            try { AlertPolicy.Save(); Notice = "Alert rules saved. Memory protection requires renewed consent after Peel Pro restarts."; }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException) { Notice = e.Message; }
            return Task.CompletedTask;
        });
        RefreshRemoteStatusCommand = new(async () =>
        {
            try
            {
                if (RequestRemoteStatus is null) throw new InvalidOperationException("Connect to a remote host first.");
                RemoteStatus = "Requesting an authorized snapshot…";
                var status = await RequestRemoteStatus(lifetime.Token);
                static string Percent(double? value) => value is { } n ? $"{n * 100:F0}%" : "Unavailable";
                RemoteStatus = $"{status.HostName}\nCPU: {Percent(status.CpuFraction)} · Memory: {Percent(status.MemoryFraction)}\n" +
                    $"Battery: {Percent(status.BatteryFraction)} · GPU: {Percent(status.GpuFraction)}\n" +
                    string.Join("\n", (status.TopApps ?? []).Select(a => $"{a.DisplayName} · {a.CpuPercent:F1}% CPU · {a.MemoryBytes / 1048576.0:N0} MB")) +
                    "\n" + string.Join("\n", (status.Usage ?? []).Select(u => $"{u.ProviderName}: {(u.UsedPercent is { } n ? $"{n:F0}% used" : "Unavailable")}")) +
                    $"\n{status.LocalStatus}\nSnapshot requested at {DateTimeOffset.Now:t}; refresh to update.";
            }
            catch (OperationCanceledException) { RemoteStatus = "Status request timed out or was canceled."; }
            catch (Exception e) when (e is IOException or InvalidOperationException) { RemoteStatus = e.Message; }
        });
        InitializeBattery(); InitializeProgress(); InitializeUtilityModes(); InitializeHardwareOutput(); InitializeSignalPresentation();
        ApplyStreamingCommand = new(async () =>
        {
            try
            {
                streaming.Save();
                if (ApplyStreamingSettings is not null) await ApplyStreamingSettings();
                StreamingStatus = $"Saved {streaming.FramesPerSecond} fps target · {streaming.BitrateMbps} Mbps. Hosting restarted; connected clients must reconnect. Remote input remains off.";
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or InvalidOperationException)
            { StreamingStatus = e.Message; }
        });
    }

    public void Start()
    {
        utilityTimer?.Start();
        sampling ??= Task.Run(SampleLoopAsync);
        usageLoop ??= Task.Run(UsageLoopAsync);
    }

    private void SaveUsagePreferences()
    {
        try { historyStore.SavePreferences(usagePreferences); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { UsageStatus = "Could not save usage preferences."; }
    }

    private void RebuildUsageChoices()
    {
        string pinned = usagePreferences.PinnedId;
        UsageChoices.Clear(); UsageChoices.Add(new("", "None"));
        foreach (var row in Usage.DistinctBy(r => r.Id)) UsageChoices.Add(new(row.Id, row.Label));
        if (!string.IsNullOrEmpty(pinned) && !UsageChoices.Any(c => c.Id == pinned))
            UsageChoices.Add(new(pinned, usagePreferences.PinnedLabel));
        OnPropertyChanged(nameof(PinnedUsageId)); OnPropertyChanged(nameof(PinnedUsageLabel));
    }

    private async Task UsageLoopAsync()
    {
        try
        {
            var saved = historyStore.ReadHistory();
            await dispatcher.InvokeAsync(() => { foreach (var row in saved.Reverse().Take(256)) UsageHistory.Add(row); }, DispatcherPriority.Background, lifetime.Token);
            using var timer = new PeriodicTimer(TimeSpan.FromSeconds(10));
            do
            {
                if (usagePreferences.AutomaticRefresh && DateTimeOffset.UtcNow.UtcTicks >= Interlocked.Read(ref nextUsageRefresh))
                    await RefreshUsageAsync().ConfigureAwait(false);
            } while (await timer.WaitForNextTickAsync(lifetime.Token).ConfigureAwait(false));
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
    }

    private async Task RefreshAgentHistoryAsync()
    {
        if (lifetime.IsCancellationRequested || !await historyGate.WaitAsync(0).ConfigureAwait(false)) return;
        try
        {
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
            deadline.CancelAfter(TimeSpan.FromSeconds(5));
            var rows = LocalAgentHistory.Read(deadline.Token);
            await dispatcher.InvokeAsync(() =>
            {
                AgentHistory.Clear(); foreach (var row in rows) AgentHistory.Add(row);
                HistoryStatus = $"{rows.Count} recent local chats · refreshed {DateTimeOffset.Now:t}. Recorded tokens are not billing or account allowance.";
            }, DispatcherPriority.Background, lifetime.Token);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidOperationException or DllNotFoundException or EntryPointNotFoundException or OperationCanceledException)
        {
            if (!lifetime.IsCancellationRequested)
            {
                try { await dispatcher.InvokeAsync(() => HistoryStatus = e is OperationCanceledException ? "History refresh timed out." : e.Message, DispatcherPriority.Background, lifetime.Token); }
                catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
            }
        }
        finally { historyGate.Release(); }
    }

    private async Task SampleLoopAsync()
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(2));
        try
        {
            do
            {
                try
                {
                    var sample = monitor.Sample();
                    var inputActivity = ReadOnAir();
                    IReadOnlyList<AgentActivityReading> observations;
                    try { observations = activity.Read(lifetime.Token); }
                    catch (Exception e) when (e is IOException or UnauthorizedAccessException) { observations = []; }
                    await dispatcher.InvokeAsync(() => { ApplyOnAir(inputActivity); ApplyActivity(observations); Apply(sample); }, DispatcherPriority.Background, lifetime.Token);
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
                { await dispatcher.InvokeAsync(() => Notice = "Some Windows metrics are unavailable.", DispatcherPriority.Background, lifetime.Token); }
            } while (await timer.WaitForNextTickAsync(lifetime.Token));
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
    }

    private void Apply(SystemReading sample)
    {
        if (lifetime.IsCancellationRequested) return;
        reading = sample;
        ObserveBattery(sample);
        RecordMechanic(sample);
        RefreshDiagnostics();
        AudioStatus = ReadAudioStatus?.Invoke() ?? AudioStatus;
        RefreshSignals();
        MachineStatusService.Shared.Update(sample);
        Notice = $"{Environment.MachineName} · updated {sample.SampledAt.ToLocalTime():h:mm:ss tt}";
        foreach (string name in new[] { nameof(CpuLabel), nameof(GpuLabel), nameof(DiskIoLabel), nameof(MemoryLabel), nameof(MemoryPercent), nameof(StorageLabel), nameof(BatteryLabel), nameof(NetworkLabel), nameof(TraySummary), nameof(PinnedUsageLabel), nameof(TopAppLabel) }) OnPropertyChanged(name);
        RefreshProcessRows();
        Agents.Clear();
        foreach (var process in sample.Processes.Where(p => new[] { "codex", "claude", "cursor", "grok", "copilot" }.Any(n => p.Name.Contains(n, StringComparison.OrdinalIgnoreCase))).Take(32))
            Agents.Add($"{process.Name} · PID {process.Id} · {process.CpuLabel} CPU · {process.MemoryLabel}");
        if (Agents.Count == 0) Agents.Add("No supported agent app processes are running on this PC.");
        try
        {
            var evaluation = alertEvaluator.Evaluate(sample, AlertPolicy, AlertsEnabled, Environment.ProcessorCount);
            foreach (string text in evaluation.Notices) PublishAlert(text);
            foreach (var candidate in evaluation.HoldCandidates)
            {
                if (actions.IsHeld(candidate)) continue;
                try { actions.Hold(candidate); PublishAlert($"Memory protection held {candidate.Name} (PID {candidate.Id}). Select it in App Mechanic to resume."); }
                catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception or ArgumentException)
                { PublishAlert($"Memory protection could not hold {candidate.Name}: {e.Message}"); }
            }
        }
        catch (ArgumentException) { Notice = "Alert rules contain an invalid value; evaluation is paused until corrected."; }
        Updated?.Invoke(this, EventArgs.Empty);
    }

    private void ApplyActivity(IReadOnlyList<AgentActivityReading> observations)
    {
        if (lifetime.IsCancellationRequested) return;
        SignalPublisher?.UpdateLocalActivity(observations);
        var previous = LocalActivity.ToDictionary(r => r.Id);
        string? selectedId = SelectedActivity?.Id;
        LocalActivity.Clear();
        foreach (var row in observations)
        {
            LocalActivity.Add(row);
            if (AlertsEnabled && previous.TryGetValue(row.Id, out var old) && row.EventAt > old.EventAt && row.State != old.State && row.State is "waiting" or "completed" or "error")
                PublishAlert($"Codex · {row.Project}: {row.StateLabel}");
        }
        SelectedActivity = LocalActivity.FirstOrDefault(r => r.Id == selectedId);
        foreach (string id in dismissedActivity.Keys.Where(id => !observations.Any(r => r.Id == id)).ToArray()) dismissedActivity.Remove(id);
        OnPropertyChanged(nameof(SelectedActivity)); OnPropertyChanged(nameof(LocalActivityStatus)); OnPropertyChanged(nameof(CompactActivityLabel));
    }

    private void RefreshProcessRows()
    {
        if (reading is null) return;
        var identity = selected;
        Processes.Clear();
        foreach (var process in RankedProcesses().Where(p => (!ApplicationsOnly || p.HasWindow) && p.Name.Contains(filter, StringComparison.OrdinalIgnoreCase)).Take(256))
            Processes.Add(process with { IsHeld = actions.IsHeld(process) });
        SelectedProcess = Processes.FirstOrDefault(p => p.Id == identity?.Id && p.StartedUtcTicks == identity.StartedUtcTicks);
    }

    public void RefreshSignals()
    {
        OnPropertyChanged(nameof(ShareSystemAudio)); OnPropertyChanged(nameof(HostAudioStatus));
        SignalRows.Clear();
        if (DeviceSignals is not null) foreach (var signal in DeviceSignals.Snapshot()) SignalRows.Add(signal);
        SignalStatus = DeviceSignals?.Status ?? "Paired signals are off.";
        PublishingStatus = SignalPublisher?.Status ?? "Local activity sharing is off.";
        var active = SignalRows.FirstOrDefault(row => row.Frame.HasVisibleActivity);
        SignalLabel = active is null ? DeviceSignals?.Enabled == true ? "No fresh paired-device activity" : "Device activity off" : $"{active.DisplayName} · {active.StateLabel}";
        RefreshSignalPresentation();
    }
    private void PublishAlert(string text)
    {
        string alert = $"{DateTimeOffset.Now:t} · {text}";
        Alerts.Insert(0, alert); while (Alerts.Count > 100) Alerts.RemoveAt(Alerts.Count - 1);
        AlertRaised?.Invoke(this, alert);
    }

    public void ActOnSelected(string action)
    {
        if (SelectedProcess is not { } process) { Notice = "Select an app first."; return; }
        try
        {
            switch (action)
            {
                case "close": actions.Close(process, force: false); break;
                case "kill": actions.Close(process, force: true); break;
                case "hold": actions.Hold(process); break;
                case "resume": actions.Resume(process); break;
                default: throw new ArgumentException("Unknown process action.", nameof(action));
            }
            Notice = $"{process.Name}: {action} requested.";
        }
        catch (Exception e) when (e is InvalidOperationException or ArgumentException or System.ComponentModel.Win32Exception or NotSupportedException)
        { Notice = e.Message; }
    }

    private async Task RefreshUsageAsync()
    {
        if (lifetime.IsCancellationRequested || !await usageGate.WaitAsync(0).ConfigureAwait(false)) return;
        string? error = null;
        try
        {
            await dispatcher.InvokeAsync(() => UsageStatus = "Reading account allowances…", DispatcherPriority.Background, lifetime.Token);
            var rows = await usage.ReadAsync(lifetime.Token).ConfigureAwait(false);
            IReadOnlyList<UsageWindow> history = [];
            string saved = "";
            try { history = historyStore.Append(rows); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { saved = " History could not be saved."; }
            await dispatcher.InvokeAsync(() =>
            {
                Usage.Clear(); foreach (var row in rows) Usage.Add(row);
                UsageHistory.Clear(); foreach (var row in history.Reverse().Take(256)) UsageHistory.Add(row);
                RebuildUsageChoices(); MachineStatusService.Shared.UpdateUsage(rows);
                UsageStatus = $"Local Codex account · refreshed {DateTimeOffset.Now:h:mm tt}" + saved;
                Updated?.Invoke(this, EventArgs.Empty);
            }, DispatcherPriority.Background, lifetime.Token);
        }
        catch (OperationCanceledException) { error = "Usage refresh timed out or was canceled; previous readings are retained."; }
        catch (Exception e) when (e is IOException or JsonException or InvalidOperationException or System.ComponentModel.Win32Exception)
        { error = e.Message + " Any previous readings are stale."; }
        finally
        {
            Interlocked.Exchange(ref nextUsageRefresh, DateTimeOffset.UtcNow.AddMinutes(5).UtcTicks);
            try
            {
                if (error is not null && !lifetime.IsCancellationRequested)
                    await dispatcher.InvokeAsync(() => UsageStatus = error, DispatcherPriority.Background, lifetime.Token);
            }
            catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
            finally { usageGate.Release(); }
        }
    }

    public async ValueTask DisposeAsync()
    {
        utilityTimer?.Stop(); keepAwake.Dispose();
        HostAudioService.Shared.SetEnabled(false);
        Peel.Windows.Host.Diagnostics.StreamDiagnostics.Shared.SetEnabled(false);
        lifetime.Cancel();
        CancelHardwareOutput();
        progressTasks.Cancel();
        SignalPublisher?.Cancel();
        actions.Dispose();
        if (sampling is not null) await sampling.ConfigureAwait(false);
        if (usageLoop is not null) await usageLoop.ConfigureAwait(false);
        await proOutput.DisposeAsync().ConfigureAwait(false); await dotOutput.DisposeAsync().ConfigureAwait(false);
        await progressTasks.DisposeAsync().ConfigureAwait(false);
        await usageGate.WaitAsync().ConfigureAwait(false); usageGate.Release();
        await historyGate.WaitAsync().ConfigureAwait(false); historyGate.Release();
        monitor.Dispose();
        lifetime.Dispose();
    }
}
