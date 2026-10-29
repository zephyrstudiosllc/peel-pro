using System.Diagnostics;
using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;

namespace Peel.Windows.Client.Utilities;

/// <summary>On-screen SidePulse equivalent; animation exists only while this control is visible.</summary>
public sealed class SignalLights : FrameworkElement
{
    public static readonly DependencyProperty ProgramProperty = DependencyProperty.Register(nameof(Program), typeof(string), typeof(SignalLights), new FrameworkPropertyMetadata("off", FrameworkPropertyMetadataOptions.AffectsRender, Changed));
    public static readonly DependencyProperty StartedAtProperty = DependencyProperty.Register(nameof(StartedAt), typeof(DateTimeOffset), typeof(SignalLights), new FrameworkPropertyMetadata(default(DateTimeOffset), FrameworkPropertyMetadataOptions.AffectsRender, AnimationChanged));
    public static readonly DependencyProperty ValidUntilProperty = DependencyProperty.Register(nameof(ValidUntil), typeof(long), typeof(SignalLights), new FrameworkPropertyMetadata(0L, FrameworkPropertyMetadataOptions.AffectsRender, AnimationChanged));
    public static readonly DependencyProperty LedCountProperty = DependencyProperty.Register(nameof(LedCount), typeof(int), typeof(SignalLights), new FrameworkPropertyMetadata(8, FrameworkPropertyMetadataOptions.AffectsRender, Changed), value => value is int count && count is >= 1 and <= 8);
    public int LedCount { get => (int)GetValue(LedCountProperty); set => SetValue(LedCountProperty, value); }
    public string Program { get => (string)GetValue(ProgramProperty); set => SetValue(ProgramProperty, value); }
    public DateTimeOffset StartedAt { get => (DateTimeOffset)GetValue(StartedAtProperty); set => SetValue(StartedAtProperty, value); }
    public long ValidUntil { get => (long)GetValue(ValidUntilProperty); set => SetValue(ValidUntilProperty, value); }
    private SignalProgram compiled = new("off");
    private readonly DispatcherTimer timer;
    public SignalLights()
    {
        timer = new DispatcherTimer(DispatcherPriority.Background, Dispatcher) { Interval = TimeSpan.FromSeconds(1d / 30) };
        timer.Tick += (_, _) => { InvalidateVisual(); UpdateAnimation(); };
        Loaded += (_, _) => UpdateAnimation(); Unloaded += (_, _) => timer.Stop(); IsVisibleChanged += (_, _) => UpdateAnimation();
    }
    private void UpdateAnimation()
    {
        double remaining = (ValidUntil - Stopwatch.GetTimestamp()) / (double)Stopwatch.Frequency;
        if (!IsLoaded || !IsVisible || Program == "off" || remaining <= 0) { timer.Stop(); return; }
        // Solid programs need only their expiry wakeup; an expired solid must not remain lit.
        timer.Interval = TimeSpan.FromSeconds(compiled.NeedsAnimation((DateTimeOffset.UtcNow - StartedAt).TotalSeconds)
            ? 1d / 30 : Math.Clamp(remaining, 1d / 30, 60));
        timer.Start();
    }
    private static void AnimationChanged(DependencyObject target, DependencyPropertyChangedEventArgs args) => ((SignalLights)target).UpdateAnimation();
    private static void Changed(DependencyObject target, DependencyPropertyChangedEventArgs args)
    {
        var view = (SignalLights)target;
        try { view.compiled = new(view.Program, view.LedCount); }
        catch (System.IO.InvalidDataException) { view.compiled = new("off", view.LedCount); }
        view.UpdateAnimation();
    }
    protected override void OnRender(DrawingContext dc)
    {
        base.OnRender(dc);
        if (ActualWidth <= 0 || ActualHeight <= 0) return;
        var colors = Stopwatch.GetTimestamp() <= ValidUntil ? compiled.Frame((DateTimeOffset.UtcNow - StartedAt).TotalSeconds) : new SignalColor[LedCount];
        double spacing = ActualWidth / LedCount, radius = Math.Max(0, Math.Min(ActualHeight / 2 - 1, spacing * .32));
        for (int i = 0; i < colors.Length; i++)
        {
            var c = colors[i];
            var color = System.Windows.Media.Color.FromRgb((byte)Math.Clamp(Math.Round(c.Red * 255), 0, 255), (byte)Math.Clamp(Math.Round(c.Green * 255), 0, 255), (byte)Math.Clamp(Math.Round(c.Blue * 255), 0, 255));
            var brush = new SolidColorBrush(color); brush.Freeze();
            dc.DrawEllipse(brush, new System.Windows.Media.Pen(System.Windows.Media.Brushes.DimGray, 1), new System.Windows.Point(spacing * (i + .5), ActualHeight / 2), radius, radius);
        }
    }
}
