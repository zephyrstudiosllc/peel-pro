using System.Globalization;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using MouseEventArgs = System.Windows.Input.MouseEventArgs;
using Point = System.Windows.Point;
using Pen = System.Windows.Media.Pen;
using Brushes = System.Windows.Media.Brushes;
using SystemFonts = System.Windows.SystemFonts;

namespace Peel.Windows.Client.Utilities;

/// <summary>Bounded native WPF chart. Missing observations and sampling gaps are not interpolated.</summary>
public sealed class MetricHistoryGraph : FrameworkElement
{
    public static readonly DependencyProperty SamplesProperty = DependencyProperty.Register(nameof(Samples), typeof(IReadOnlyList<MetricHistoryPoint>), typeof(MetricHistoryGraph), new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));
    public static readonly DependencyProperty MetricProperty = DependencyProperty.Register(nameof(Metric), typeof(string), typeof(MetricHistoryGraph), new FrameworkPropertyMetadata("Disk write", FrameworkPropertyMetadataOptions.AffectsRender));
    public static readonly DependencyProperty WindowMinutesProperty = DependencyProperty.Register(nameof(WindowMinutes), typeof(int), typeof(MetricHistoryGraph), new FrameworkPropertyMetadata(15, FrameworkPropertyMetadataOptions.AffectsRender));
    public IReadOnlyList<MetricHistoryPoint>? Samples { get => (IReadOnlyList<MetricHistoryPoint>?)GetValue(SamplesProperty); set => SetValue(SamplesProperty, value); }
    public string Metric { get => (string)GetValue(MetricProperty); set => SetValue(MetricProperty, value); }
    public int WindowMinutes { get => (int)GetValue(WindowMinutesProperty); set => SetValue(WindowMinutesProperty, value); }
    private double? pointer;
    protected override void OnMouseMove(MouseEventArgs e) { base.OnMouseMove(e); pointer = e.GetPosition(this).X; InvalidateVisual(); }
    protected override void OnMouseLeave(MouseEventArgs e) { base.OnMouseLeave(e); pointer = null; ToolTip = null; InvalidateVisual(); }
    protected override void OnRender(DrawingContext dc)
    {
        base.OnRender(dc);
        dc.DrawRectangle(Brushes.White, null, new Rect(RenderSize));
        if (ActualWidth < 120 || ActualHeight < 90) return;
        var plot = new Rect(54, 18, ActualWidth - 68, ActualHeight - 48);
        var rows = Samples;
        if (rows is null || rows.Count == 0) { Label("Waiting for samples", 12, 24); return; }
        var end = rows[^1].At; double seconds = WindowMinutes == 5 ? 300 : 900;
        var start = end - TimeSpan.FromSeconds(seconds);
        var visible = rows.Where(p => p.At >= start && p.At <= end).TakeLast(SystemMetricHistory.MaximumPoints).ToArray();
        bool percent = MetricHistoryPoint.IsPercentage(Metric);
        double scale = percent ? 1 : 1048576;
        double maximum = percent ? 100 : Math.Max(.01, visible.Select(p => p.Value(Metric) is { } v && double.IsFinite(v) && v >= 0 ? v / scale : 0).DefaultIfEmpty(0).Max() * 1.1);
        for (int i = 0; i <= 4; i++)
        {
            double y = plot.Bottom - plot.Height * i / 4;
            dc.DrawLine(new Pen(Brushes.Gainsboro, 1), new(plot.Left, y), new(plot.Right, y));
            Label((maximum * i / 4).ToString(percent ? "F0" : maximum < 1 ? "F3" : "F1", CultureInfo.CurrentCulture), 3, y - 7);
        }
        Label(percent ? "%" : "MB/s", 3, 0);
        Label($"−{seconds / 60:F0} min", plot.Left, plot.Bottom + 10);
        Label(end.ToLocalTime().ToString("HH:mm:ss"), plot.Right - 56, plot.Bottom + 10);
        var geometry = new StreamGeometry(); bool connected = false; DateTimeOffset previous = default;
        using (var context = geometry.Open())
        {
            foreach (var row in visible)
            {
                double? number = row.Value(Metric);
                if (number is not { } v || !double.IsFinite(v) || v < 0) { connected = false; continue; }
                var point = new Point(plot.Left + (row.At - start).TotalSeconds / seconds * plot.Width, plot.Bottom - Math.Clamp(v / scale / maximum, 0, 1) * plot.Height);
                if (!connected || row.At - previous > SystemMetricHistory.MaximumInterval) context.BeginFigure(point, false, false);
                else context.LineTo(point, true, false);
                connected = true; previous = row.At;
            }
        }
        geometry.Freeze(); dc.DrawGeometry(null, new Pen(Brushes.Teal, 2), geometry);
        if (!visible.Any(p => p.Value(Metric) is not null)) Label("No available readings in this window", plot.Left + 12, plot.Top + 12);
        if (pointer is { } x && x >= plot.Left && x <= plot.Right && visible.Length > 0)
        {
            var target = start + TimeSpan.FromSeconds((x - plot.Left) / plot.Width * seconds);
            var row = visible.MinBy(p => Math.Abs((p.At - target).Ticks))!;
            if (Math.Abs((row.At - target).TotalSeconds) <= SystemMetricHistory.MaximumInterval.TotalSeconds)
            {
                double at = plot.Left + (row.At - start).TotalSeconds / seconds * plot.Width;
                dc.DrawLine(new Pen(Brushes.DarkSlateGray, 1), new(at, plot.Top), new(at, plot.Bottom));
                ToolTip = $"{row.At.ToLocalTime():HH:mm:ss} · {Metric}: " + (row.Value(Metric) is { } v ? $"{v / scale:F2} {(percent ? "%" : "MB/s")}" : "unavailable");
            }
            else ToolTip = "No observation at this time";
        }
        void Label(string text, double x, double y) => dc.DrawText(new FormattedText(text, CultureInfo.CurrentCulture,
            System.Windows.FlowDirection.LeftToRight, new Typeface(SystemFonts.MessageFontFamily, FontStyles.Normal, FontWeights.Normal, FontStretches.Normal), 11,
            Brushes.DimGray, VisualTreeHelper.GetDpi(this).PixelsPerDip), new(x, y));
    }
}
