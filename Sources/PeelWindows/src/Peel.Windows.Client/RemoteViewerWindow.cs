using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Peel.Windows.Client.Models;
using Peel.Windows.Client.Services;
using Peel.Windows.Client.ViewModels;
using Button = System.Windows.Controls.Button;
using MouseEventArgs = System.Windows.Input.MouseEventArgs;
using Brushes = System.Windows.Media.Brushes;
using Color = System.Windows.Media.Color;

namespace Peel.Windows.Client;

/// <summary>The service owns connections; this window owns only presentation and attended input.</summary>
public sealed class RemoteViewerWindow : Window
{
    private readonly DetachedViewerSession viewer;
    private readonly ProductionClientServices owner;
    private readonly CancellationTokenSource lifetime = new();
    private readonly LatestDecodedFrameMailbox mailbox = new();
    private readonly WpfVideoPresenter presenter = new();
    private readonly System.Windows.Controls.Image image = new() { Stretch = Stretch.Uniform, IsHitTestVisible = false };
    private readonly Grid surface = new() { Background = Brushes.Black, Focusable = true };
    private readonly TextBlock status = new() { Foreground = Brushes.LightGray, Margin = new Thickness(12) };
    private readonly Button control = new() { Content = "Enable control", Padding = new Thickness(12, 6, 12, 6), Margin = new Thickness(8) };
    private readonly SourceControlsViewModel sourceControls;
    private bool closing, releasingCapture;
    private long presentationCount;
    private readonly System.Diagnostics.Stopwatch elapsed = System.Diagnostics.Stopwatch.StartNew();

    internal RemoteViewerWindow(DetachedViewerSession viewer, ProductionClientServices owner)
    {
        this.viewer = viewer; this.owner = owner;
        Title = $"{viewer.Window.Title} — Peel Pro"; Width = 1100; Height = 740; MinWidth = 420; MinHeight = 300;
        Background = new SolidColorBrush(Color.FromRgb(28, 31, 36));
        var root = new DockPanel(); var toolbar = new DockPanel();
        // Source controls belong to this window's own stream and session, never the main selection.
        sourceControls = new SourceControlsViewModel(viewer.SourceMedia, SourceControlPreferences.Shared, Dispatcher);
        var sourceGroup = CreateSourceControls(sourceControls);
        DockPanel.SetDock(toolbar, Dock.Top); DockPanel.SetDock(control, Dock.Right); DockPanel.SetDock(sourceGroup, Dock.Right);
        toolbar.Children.Add(control); toolbar.Children.Add(sourceGroup); toolbar.Children.Add(status); root.Children.Add(toolbar);
        sourceControls.PropertyChanged += (_, e) =>
        {
            if (!closing && e.PropertyName == nameof(SourceControlsViewModel.Status) && sourceControls.Status.Length != 0)
                status.Text = sourceControls.Status;
        };
        surface.Children.Add(image); root.Children.Add(surface); Content = root;
        System.Windows.Automation.AutomationProperties.SetName(surface, "Peeled window video and control");
        viewer.Streams.FrameAvailable += FrameAvailable;
        viewer.Streams.StateChanged += StreamChanged;
        viewer.Input.ControlChanged += ControlChanged;
        control.Click += async (_, _) => await AttemptAsync(async () =>
        {
            if (viewer.Input.IsEnabled) viewer.Input.Disable();
            else { await owner.EnableViewerControlAsync(viewer.Input, lifetime.Token); surface.Focus(); }
        });
        surface.MouseMove += async (_, e) => { if (surface.IsKeyboardFocusWithin && Point(e, out var p)) await SendPointerAsync(NormalizedPointerAction.Move, p); };
        surface.MouseDown += async (_, e) =>
        {
            if (e.ChangedButton is not (MouseButton.Left or MouseButton.Right) || !Point(e, out var p)) return;
            surface.Focus(); surface.CaptureMouse(); e.Handled = true;
            await SendPointerAsync(NormalizedPointerAction.Down, p, e.ChangedButton == MouseButton.Left ? NormalizedPointerButton.Primary : NormalizedPointerButton.Secondary);
        };
        surface.MouseUp += async (_, e) =>
        {
            if (e.ChangedButton is not (MouseButton.Left or MouseButton.Right) || !Point(e, out var p)) return;
            e.Handled = true;
            await SendPointerAsync(NormalizedPointerAction.Up, p, e.ChangedButton == MouseButton.Left ? NormalizedPointerButton.Primary : NormalizedPointerButton.Secondary);
            if (e.LeftButton != MouseButtonState.Pressed && e.RightButton != MouseButtonState.Pressed)
            { releasingCapture = true; try { surface.ReleaseMouseCapture(); } finally { releasingCapture = false; } }
        };
        surface.MouseWheel += async (_, e) =>
        {
            if (!Point(e, out var p)) return; e.Handled = true;
            await AttemptAsync(() => viewer.Input.SendPointerAsync(new(viewer.Window.Id, NormalizedPointerAction.Scroll, p, NormalizedPointerButton.None,
                Keyboard.Modifiers.HasFlag(ModifierKeys.Shift) ? e.Delta : 0, Keyboard.Modifiers.HasFlag(ModifierKeys.Shift) ? 0 : e.Delta), lifetime.Token));
        };
        surface.PreviewKeyDown += async (_, e) => await KeyAsync(e, true);
        surface.PreviewKeyUp += async (_, e) => await KeyAsync(e, false);
        surface.LostKeyboardFocus += (_, _) => viewer.Input.Disable();
        surface.LostMouseCapture += (_, _) => { if (!releasingCapture) viewer.Input.Disable(); };
        Deactivated += (_, _) => viewer.Input.Disable();
        StateChanged += async (_, _) => await UpdateVisibilityAsync();
        IsVisibleChanged += async (_, _) => await UpdateVisibilityAsync();
        owner.StateChanged += ConnectionChanged;
    }

    private static FrameworkElement CreateSourceControls(SourceControlsViewModel model)
    {
        var panel = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, DataContext = model };
        var visibility = new BooleanToVisibilityConverter();
        var media = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
        System.Windows.Automation.AutomationProperties.SetName(media, "Streamed computer media controls");
        media.SetBinding(VisibilityProperty, new System.Windows.Data.Binding(nameof(model.ShowMediaGroup)) { Converter = visibility });
        media.Children.Add(IconButton(nameof(model.PreviousTrackGlyph), nameof(model.PreviousTrackCommand),
            nameof(model.PreviousTrackToolTip), "Previous track on the streamed computer"));
        media.Children.Add(IconButton(nameof(model.PlayPauseGlyph), nameof(model.PlayPauseCommand),
            nameof(model.PlayPauseToolTip), "Play or pause on the streamed computer"));
        media.Children.Add(IconButton(nameof(model.NextTrackGlyph), nameof(model.NextTrackCommand),
            nameof(model.NextTrackToolTip), "Next track on the streamed computer"));

        var volume = new Grid();
        volume.SetBinding(VisibilityProperty, new System.Windows.Data.Binding(nameof(model.ShowVolumeGroup)) { Converter = visibility });
        Button volumeButton = IconButton(nameof(model.VolumeGlyph), nameof(model.ToggleVolumeCommand),
            nameof(model.VolumeToolTip), "Streamed computer volume");
        volumeButton.SetBinding(IsHitTestVisibleProperty, new System.Windows.Data.Binding(nameof(model.IsVolumeClosed)));
        var title = new TextBlock { Foreground = Brushes.White, FontWeight = FontWeights.SemiBold, Text = "Streamed computer volume" };
        var level = new TextBlock { Foreground = Brushes.White };
        level.SetBinding(TextBlock.TextProperty, new System.Windows.Data.Binding(nameof(model.VolumeLabel)));
        var slider = new Slider { Minimum = 0, Maximum = 100, Margin = new Thickness(0, 10, 0, 8) };
        System.Windows.Automation.AutomationProperties.SetName(slider, "Streamed computer volume level");
        slider.SetBinding(System.Windows.Controls.Primitives.RangeBase.ValueProperty,
            new System.Windows.Data.Binding(nameof(model.VolumeSliderValue)) { Mode = System.Windows.Data.BindingMode.TwoWay });
        slider.SetBinding(IsEnabledProperty, new System.Windows.Data.Binding(nameof(model.CanSetVolume)));
        var mute = new Button { Padding = new Thickness(10, 4, 10, 4), HorizontalAlignment = System.Windows.HorizontalAlignment.Left };
        mute.SetBinding(ContentProperty, new System.Windows.Data.Binding(nameof(model.MuteButtonLabel)));
        mute.SetBinding(Button.CommandProperty, new System.Windows.Data.Binding(nameof(model.ToggleMuteCommand)));
        var hint = new TextBlock { Foreground = Brushes.LightGray, FontSize = 11, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0) };
        hint.SetBinding(TextBlock.TextProperty, new System.Windows.Data.Binding(nameof(model.VolumeHint)));
        var popover = new StackPanel { Width = 220 };
        popover.Children.Add(title); popover.Children.Add(level); popover.Children.Add(slider); popover.Children.Add(mute); popover.Children.Add(hint);
        var popup = new System.Windows.Controls.Primitives.Popup
        {
            PlacementTarget = volumeButton, Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom,
            StaysOpen = false, AllowsTransparency = true,
            Child = new Border
            {
                Background = new SolidColorBrush(Color.FromRgb(41, 45, 53)), BorderBrush = new SolidColorBrush(Color.FromRgb(65, 70, 80)),
                BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(9), Padding = new Thickness(12), Child = popover,
            },
        };
        popup.SetBinding(System.Windows.Controls.Primitives.Popup.IsOpenProperty,
            new System.Windows.Data.Binding(nameof(model.IsVolumeOpen)) { Mode = System.Windows.Data.BindingMode.TwoWay });
        volume.Children.Add(volumeButton); volume.Children.Add(popup);

        panel.Children.Add(media); panel.Children.Add(volume);
        return panel;
    }

    private static Button IconButton(string glyph, string command, string toolTip, string name)
    {
        var button = new Button
        {
            FontFamily = new System.Windows.Media.FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"),
            Padding = new Thickness(8, 4, 8, 4), Margin = new Thickness(2, 8, 2, 8), MinWidth = 32,
        };
        button.SetBinding(ContentProperty, new System.Windows.Data.Binding(glyph));
        button.SetBinding(Button.CommandProperty, new System.Windows.Data.Binding(command));
        button.SetBinding(ToolTipProperty, new System.Windows.Data.Binding(toolTip));
        ToolTipService.SetShowOnDisabled(button, true);
        System.Windows.Automation.AutomationProperties.SetName(button, name);
        return button;
    }

    private void ConnectionChanged(object? sender, ConnectionStateChangedEventArgs e)
    {
        if (e.State is PeelConnectionState.Disconnected or PeelConnectionState.Error) Queue(() => { if (!closing) Close(); });
    }
    private async Task UpdateVisibilityAsync()
    {
        viewer.IsVisible = IsVisible && WindowState != WindowState.Minimized && !closing;
        if (!viewer.IsVisible) viewer.Input.Disable();
        await AttemptAsync(() => owner.UpdateViewerVisibilityAsync(lifetime.Token));
    }
    private bool Point(MouseEventArgs e, out NormalizedPoint p)
    {
        p = default;
        if (!viewer.Input.IsEnabled || image.Source is null) return false;
        var point = e.GetPosition(surface);
        return ClientViewport.TryNormalize(point.X, point.Y, surface.ActualWidth, surface.ActualHeight,
            presenter.PixelWidth, presenter.PixelHeight, surface.IsMouseCaptured, out p);
    }
    private Task SendPointerAsync(NormalizedPointerAction action, NormalizedPoint p, NormalizedPointerButton button = NormalizedPointerButton.None) =>
        AttemptAsync(() => viewer.Input.SendPointerAsync(new(viewer.Window.Id, action, p, button, 0, 0), lifetime.Token));
    private async Task KeyAsync(System.Windows.Input.KeyEventArgs e, bool down)
    {
        var key = e.Key == Key.System ? e.SystemKey : e.Key; var modifiers = Keyboard.Modifiers;
        if (key == Key.Escape && modifiers.HasFlag(ModifierKeys.Control) && modifiers.HasFlag(ModifierKeys.Alt))
        { viewer.Input.Disable(); e.Handled = true; return; }
        if (!viewer.Input.IsEnabled) return;
        ushort code = (ushort)KeyInterop.VirtualKeyFromKey(key);
        if (ClientInputController.ToHidUsage(code) == 0) return;
        e.Handled = true;
        await AttemptAsync(() => viewer.Input.SendKeyAsync(new(viewer.Window.Id, code, down, e.IsRepeat,
            modifiers.HasFlag(ModifierKeys.Shift), modifiers.HasFlag(ModifierKeys.Control),
            modifiers.HasFlag(ModifierKeys.Alt), modifiers.HasFlag(ModifierKeys.Windows)), lifetime.Token));
    }
    private async Task AttemptAsync(Func<Task> operation)
    {
        try { if (!closing) await operation(); }
        catch (Exception e) when (e is IOException or InvalidOperationException or OperationCanceledException)
        { if (!closing) status.Text = e.Message; }
    }
    private void FrameAvailable(object? sender, DecodedVideoFrameEventArgs e)
    {
        if (!closing && mailbox.Publish(e.Frame)) Queue(Present);
    }
    private void Present()
    {
        try
        {
            using var frame = mailbox.TakeLatest();
            if (closing || frame is null || viewer.Streams.State is not (PeelStreamState.Starting or PeelStreamState.Streaming)) return;
            if (!presenter.Present(frame)) return;
            image.Source = presenter.Source; presentationCount++;
            if (elapsed.Elapsed.TotalSeconds >= 1)
            {
                status.Text = $"{frame.PixelWidth} × {frame.PixelHeight} · {presentationCount / elapsed.Elapsed.TotalSeconds:F1} viewer updates/s · {(frame.UsesGpuPresentation ? "GPU" : "CPU fallback")}";
                elapsed.Restart(); presentationCount = 0;
            }
        }
        catch (Exception e) when (e is InvalidDataException or ArgumentException or System.Runtime.InteropServices.COMException)
        { image.Source = null; presenter.Dispose(); status.Text = e.Message; viewer.Input.Disable(); }
        finally { if (mailbox.CompletePresentation()) Queue(Present); }
    }
    private void StreamChanged(object? sender, StreamStateChangedEventArgs e) => Queue(() =>
    {
        status.Text = e.Detail ?? e.State.ToString();
        if (e.State is not (PeelStreamState.Streaming or PeelStreamState.Starting)) { mailbox.Reset(); image.Source = null; presenter.Dispose(); }
    });
    private void ControlChanged(object? sender, string text) => Queue(() =>
    {
        control.Content = viewer.Input.IsEnabled ? "Release control" : "Enable control";
        status.Text = text;
    });
    private void Queue(Action action) { if (!Dispatcher.HasShutdownStarted && !closing) _ = Dispatcher.BeginInvoke(action, DispatcherPriority.Render); }
    protected override void OnClosed(EventArgs e)
    {
        closing = true; lifetime.Cancel(); viewer.Input.Disable(); sourceControls.Dispose(); mailbox.Close(); image.Source = null; presenter.Dispose();
        owner.StateChanged -= ConnectionChanged; viewer.Streams.FrameAvailable -= FrameAvailable;
        viewer.Streams.StateChanged -= StreamChanged; viewer.Input.ControlChanged -= ControlChanged;
        _ = CloseSessionAsync(); base.OnClosed(e);
    }
    private async Task CloseSessionAsync()
    {
        try { await viewer.DisposeAsync().ConfigureAwait(false); await owner.UpdateViewerVisibilityAsync(CancellationToken.None).ConfigureAwait(false); }
        catch (Exception e) when (e is IOException or InvalidOperationException or OperationCanceledException) { }
        finally { lifetime.Dispose(); }
    }
}
