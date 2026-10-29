using System.Windows.Input;
using System.Windows.Threading;
using Peel.Windows.Client.Services;
using Peel.Windows.Protocol;

namespace Peel.Windows.Client.ViewModels;

/// <summary>
/// Client-local, pure presentation: whether viewers show the source volume and media groups.
/// Hiding a group never stops playback, changes the source, revokes a grant or touches a microphone.
/// Persisted with the other utility settings; both default to shown.
/// </summary>
public sealed class SourceControlPreferences : ObservableObject
{
    public static SourceControlPreferences Shared { get; } = new();

    private bool showVolume = true;
    private bool showMediaControls = true;

    public bool ShowVolume { get => showVolume; set => SetProperty(ref showVolume, value); }

    public bool ShowMediaControls { get => showMediaControls; set => SetProperty(ref showMediaControls, value); }
}

/// <summary>
/// Toolbar state for one viewer window. Every tap captures that window's own source binding
/// (connection generation, pairing and streamed window); results from an older binding are ignored.
/// Controls act only on the streamed source; nothing changes this PC's volume or media.
/// </summary>
public sealed class SourceControlsViewModel : ObservableObject, IDisposable
{
    private const string PlayGlyph = "";
    private const string PreviousGlyph = "";
    private const string NextGlyph = "";
    private const string VolumeOnGlyph = "";
    private const string MutedGlyph = "";

    private readonly ClientSourceMediaController? controller;
    private readonly SourceControlPreferences preferences;
    private readonly Dispatcher? dispatcher;
    private readonly CancellationTokenSource lifetime = new();
    private static readonly TimeSpan VolumeCommitDelay = TimeSpan.FromMilliseconds(150);
    private readonly TimeProvider time;
    // The latest slider gesture: its owner and desired level, captured when the user moved it.
    private (SourceMediaBinding Binding, double Level)? pendingVolume;
    private CancellationTokenSource? volumeCommit;
    private string status = "";
    private bool isVolumeOpen;
    private double volumeSliderValue;
    private bool applyingReading;
    private bool disposed;

    public SourceControlsViewModel(ClientSourceMediaController? controller, SourceControlPreferences preferences,
        Dispatcher? dispatcher = null, TimeProvider? timeProvider = null)
    {
        time = timeProvider ?? TimeProvider.System;
        this.controller = controller;
        this.preferences = preferences ?? throw new ArgumentNullException(nameof(preferences));
        this.dispatcher = dispatcher ?? System.Windows.Application.Current?.Dispatcher;
        PlayPauseCommand = new(() => SendMediaAsync(SourceMediaAction.PlayPause), () => CanUseMedia);
        PreviousTrackCommand = new(() => SendMediaAsync(SourceMediaAction.PreviousTrack), () => CanUseMedia);
        NextTrackCommand = new(() => SendMediaAsync(SourceMediaAction.NextTrack), () => CanUseMedia);
        ToggleMuteCommand = new(ToggleMuteAsync, () => CanToggleMute);
        ToggleVolumeCommand = new(() => { IsVolumeOpen = !IsVolumeOpen; return Task.CompletedTask; }, () => ShowVolumeGroup);
        preferences.PropertyChanged += PreferencesChanged;
        if (controller is not null) controller.Changed += ControllerChanged;
    }

    public string PlayPauseGlyph => PlayGlyph;
    public string PreviousTrackGlyph => PreviousGlyph;
    public string NextTrackGlyph => NextGlyph;

    public SourceControlCommand PlayPauseCommand { get; }
    public SourceControlCommand PreviousTrackCommand { get; }
    public SourceControlCommand NextTrackCommand { get; }
    public SourceControlCommand ToggleMuteCommand { get; }
    public SourceControlCommand ToggleVolumeCommand { get; }

    public bool ShowVolumeGroup => preferences.ShowVolume;
    public bool ShowMediaGroup => preferences.ShowMediaControls;

    private SourceMediaAvailability Availability =>
        controller?.Availability ?? new SourceMediaAvailability(false, false, false);

    private SourceVolumeReading? Reading => CanUseVolume ? controller?.Volume : null;

    public bool CanUseMedia => Availability.MediaKeys;

    public string MediaHint => Availability switch
    {
        { Streaming: false } => "Open a stream to control media on that computer.",
        { MediaKeys: false } => "This computer doesn't accept remote media keys. Nothing is sent to this PC instead.",
        _ => "",
    };

    public string PlayPauseToolTip => CanUseMedia ? "Play or pause on the streamed computer" : MediaHint;
    public string PreviousTrackToolTip => CanUseMedia ? "Previous track on the streamed computer" : MediaHint;
    public string NextTrackToolTip => CanUseMedia ? "Next track on the streamed computer" : MediaHint;

    public bool CanUseVolume =>
        ClientSourceMediaController.SelectedVolumeScope is not null && Availability.Volume;

    public bool CanSetVolume => Reading is { CanSetVolume: true };

    public bool CanToggleMute => Reading is { CanSetMute: true, Muted: not null };

    public string VolumeGlyph => Reading is { Muted: true } ? MutedGlyph : VolumeOnGlyph;

    public string VolumeLabel => Reading switch
    {
        { Muted: true } => "Muted",
        { Volume: { } level } => $"{level * 100:F0}%",
        _ => "—",
    };

    public string MuteButtonLabel => Reading is { Muted: true } ? "Unmute streamed computer" : "Mute streamed computer";

    public string VolumeHint => Availability switch
    {
        { Streaming: false } => "Open a stream to use that computer's volume.",
        _ when !CanUseVolume => "That computer doesn't offer remote volume control. This PC's volume is never changed here.",
        _ when Reading is { Supported: false, Reason: SourceMediaReason.NoOutputDevice } => "That computer has no sound output right now.",
        _ when Reading is { Supported: false } => "That computer's sound output has a fixed volume.",
        _ when Reading is null => "Reading the streamed computer's volume…",
        _ when Reading is { CanSetVolume: false, CanSetMute: false } => "That computer's sound output has a fixed volume.",
        _ => "Changes the streamed computer's system volume, not this PC.",
    };

    public string VolumeToolTip => CanUseVolume ? $"Streamed computer's system volume · {VolumeLabel}" : VolumeHint;

    public bool IsVolumeOpen
    {
        get => isVolumeOpen;
        set
        {
            if (!SetProperty(ref isVolumeOpen, value)) return;
            OnPropertyChanged(nameof(IsVolumeClosed));
            // Actual state is read when the popover appears; it is never assumed.
            if (value) _ = QueryVolumeAsync();
        }
    }

    /// <summary>A light-dismiss popover is open: its button must not reopen it on the same click.</summary>
    public bool IsVolumeClosed => !isVolumeOpen;

    /// <summary>0...100 slider position. Only the source's reply changes the displayed actual level.</summary>
    public double VolumeSliderValue
    {
        get => volumeSliderValue;
        set
        {
            if (!SetProperty(ref volumeSliderValue, Math.Clamp(value, 0, 100)) || applyingReading || !CanSetVolume) return;
            ScheduleVolumeCommit(Math.Round(volumeSliderValue) / 100.0);
        }
    }

    public string Status { get => status; private set => SetProperty(ref status, value); }

    private async Task SendMediaAsync(SourceMediaAction action)
    {
        if (controller is null || controller.CaptureBinding() is not { MediaKeys: true } binding) { Status = MediaHint; return; }
        try
        {
            SourceMediaResult result = await controller.SendMediaAsync(binding, action, lifetime.Token);
            // An answer for an owner/stream/connection that has since changed is not shown.
            if (!disposed && controller.Epoch == binding.Epoch) Status = Describe(result);
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
    }

    private async Task QueryVolumeAsync()
    {
        if (ClientSourceMediaController.SelectedVolumeScope is not { } scope ||
            controller is null || controller.CaptureBinding() is not { Volume: true } binding) { Refresh(); return; }
        try
        {
            SourceMediaResult result = await controller.QueryVolumeAsync(binding, scope, lifetime.Token);
            if (!disposed && controller.Epoch == binding.Epoch && result.Kind != SourceMediaResultKind.Reply) Status = Describe(result);
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
    }

    private Task ToggleMuteAsync()
    {
        // The owner and the intended state are both captured at the tap.
        if (Reading is not { CanSetMute: true, Muted: { } muted } ||
            controller?.CaptureBinding() is not { Volume: true } binding) return Task.CompletedTask;
        return SetVolumeAsync(binding, null, !muted);
    }

    // Latest-coalesced slider commits: each gesture replaces the pending one, at most one set per
    // quiet interval, and only the owner captured with the gesture can receive it.
    private void ScheduleVolumeCommit(double level)
    {
        CancelVolumeCommit();
        if (disposed || controller?.CaptureBinding() is not { Volume: true } binding) return;
        pendingVolume = (binding, level);
        var delay = volumeCommit = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        _ = CommitAfterDelayAsync(delay.Token);
    }

    private async Task CommitAfterDelayAsync(CancellationToken token)
    {
        try { await Task.Delay(VolumeCommitDelay, time, token).ConfigureAwait(false); }
        catch (OperationCanceledException) { return; }
        OnUi(() =>
        {
            if (disposed || token.IsCancellationRequested || pendingVolume is not { } pending) return;
            pendingVolume = null;
            _ = SetVolumeAsync(pending.Binding, pending.Level, null);
        });
    }

    private void CancelVolumeCommit()
    {
        pendingVolume = null;
        CancellationTokenSource? delay = volumeCommit;
        volumeCommit = null;
        if (delay is null) return;
        delay.Cancel();
        delay.Dispose();
    }

    private async Task SetVolumeAsync(SourceMediaBinding binding, double? level, bool? muted)
    {
        if (ClientSourceMediaController.SelectedVolumeScope is not { } scope || controller is null) { Refresh(); return; }
        try
        {
            SourceMediaResult result = await controller.SetVolumeAsync(binding, scope, level, muted, lifetime.Token);
            if (disposed || controller.Epoch != binding.Epoch) return;
            if (result.Kind != SourceMediaResultKind.Reply || result.Status != SourceMediaStatus.Applied) Status = Describe(result);
            // The source's state reply (or a fresh query) is the only truth for the displayed level.
            if (result.Volume is null) await QueryVolumeAsync();
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
    }

    internal static string Describe(SourceMediaResult result) => result.Kind switch
    {
        SourceMediaResultKind.Busy => "Waiting for the streamed computer to answer earlier presses.",
        SourceMediaResultKind.TimedOut => "No answer from the streamed computer.",
        SourceMediaResultKind.Stale => "The stream changed. Try again.",
        SourceMediaResultKind.Unavailable => "This control isn't available for the streamed computer.",
        _ => (result.Status, result.Reason) switch
        {
            (SourceMediaStatus.Applied, _) => "Sent to the streamed computer.",
            (SourceMediaStatus.Denied, SourceMediaReason.ControlOff) => "Turn on remote control on the streamed computer to use these controls.",
            (SourceMediaStatus.Denied, SourceMediaReason.NotVisible) => "The streamed computer sees this viewer as hidden.",
            (SourceMediaStatus.Denied, SourceMediaReason.Locked) => "The streamed computer is locked.",
            (SourceMediaStatus.Denied, SourceMediaReason.AccessibilityMissing) => "The streamed computer needs Accessibility permission for Peel.",
            (SourceMediaStatus.Denied, SourceMediaReason.RateLimited) => "Too many presses. Wait a moment.",
            (SourceMediaStatus.Denied, _) => "The streamed computer declined.",
            (SourceMediaStatus.Unsupported, SourceMediaReason.ScopeUnsupported) => "The streamed computer doesn't support this volume control.",
            (SourceMediaStatus.Unsupported, _) => "The streamed computer doesn't support this control.",
            (SourceMediaStatus.Stale, _) => "The stream changed on that computer. Try again.",
            (SourceMediaStatus.Failed, _) => "The streamed computer couldn't apply it.",
            _ => "The streamed computer rejected the request.",
        },
    };

    private void PreferencesChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e) => OnUi(() =>
    {
        if (!ShowVolumeGroup) IsVolumeOpen = false;
        Refresh();
    });

    private void ControllerChanged(object? sender, EventArgs e) => OnUi(Refresh);

    private void Refresh()
    {
        if (disposed) return;
        // A gesture captured for an owner that has since changed is dropped, never redirected.
        if (pendingVolume is { } pending && controller?.Epoch != pending.Binding.Epoch) CancelVolumeCommit();
        // An open popover stays open to explain unavailability; only hiding the group closes it.
        // Actual readback never replaces a gesture that is still waiting to be sent.
        if (pendingVolume is null && Reading is { Volume: { } level })
        {
            applyingReading = true;
            try { VolumeSliderValue = level * 100; }
            finally { applyingReading = false; }
        }
        foreach (string name in new[]
        {
            nameof(ShowVolumeGroup), nameof(ShowMediaGroup), nameof(CanUseMedia), nameof(MediaHint),
            nameof(PlayPauseToolTip), nameof(PreviousTrackToolTip), nameof(NextTrackToolTip), nameof(CanUseVolume),
            nameof(CanSetVolume), nameof(CanToggleMute), nameof(VolumeGlyph), nameof(VolumeLabel), nameof(MuteButtonLabel),
            nameof(VolumeHint), nameof(VolumeToolTip),
        }) OnPropertyChanged(name);
        PlayPauseCommand.RaiseCanExecuteChanged(); PreviousTrackCommand.RaiseCanExecuteChanged();
        NextTrackCommand.RaiseCanExecuteChanged(); ToggleMuteCommand.RaiseCanExecuteChanged();
        ToggleVolumeCommand.RaiseCanExecuteChanged();
    }

    private void OnUi(Action action)
    {
        if (dispatcher is null || dispatcher.CheckAccess()) { action(); return; }
        if (!dispatcher.HasShutdownStarted) _ = dispatcher.BeginInvoke(action);
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        CancelVolumeCommit();
        lifetime.Cancel();
        preferences.PropertyChanged -= PreferencesChanged;
        if (controller is not null) controller.Changed -= ControllerChanged;
        lifetime.Dispose();
    }
}

/// <summary>A command that does not block repeated presses while an earlier one awaits its reply.</summary>
public sealed class SourceControlCommand(Func<Task> execute, Func<bool> canExecute) : ICommand
{
    public event EventHandler? CanExecuteChanged;

    public bool CanExecute(object? parameter) => canExecute();

    public async void Execute(object? parameter)
    {
        if (!CanExecute(parameter)) return;
        try { await execute(); }
        catch (Exception error) when (error is InvalidOperationException or ArgumentException or ObjectDisposedException) { }
    }

    public void RaiseCanExecuteChanged() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);
}
