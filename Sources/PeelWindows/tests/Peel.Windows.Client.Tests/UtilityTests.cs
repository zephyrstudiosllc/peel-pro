using System.Text.Json;
using Peel.Windows.Client.Utilities;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Peel.Windows.Client.Tests;

internal static partial class Program
{
    private static void UsageBucketsPreserveUnavailable()
    {
        using var json = JsonDocument.Parse("""
            {"rateLimitsByLimitId":{"codex":{"limitName":"Codex","primary":{"usedPercent":23,"windowDurationMins":300,"resetsAt":1800000000},"secondary":null},
            "spark":{"limitName":"Spark","primary":{"usedPercent":125,"windowDurationMins":10080},"secondary":{"usedPercent":null}}},
            "rateLimits":{"primary":{"usedPercent":99}}}
            """);
        var now = DateTimeOffset.UtcNow;
        var rows = CodexUsageProvider.Parse(json.RootElement, now);
        Equal(2, rows.Count); Equal(77.0, rows[0].RemainingPercent); Equal(0.0, rows[1].RemainingPercent);
        True(rows[0].Label.Contains("5 hour", StringComparison.Ordinal), "Duration must come from the response.");
        Equal<DateTimeOffset?>(null, rows[1].ResetsAt);
        using var missing = JsonDocument.Parse("{\"rateLimits\":{\"primary\":null}}");
        Throws<InvalidDataException>(() => CodexUsageProvider.Parse(missing.RootElement, now));
    }

    private static void UtilityActionsRejectUnsafeIdentity()
    {
        using var actions = new ProcessActions();
        using var current = System.Diagnostics.Process.GetCurrentProcess();
        var self = new ProcessReading(Environment.ProcessId, current.StartTime.ToUniversalTime().Ticks, "fixture", 0, 0, true, current.SessionId);
        Throws<InvalidOperationException>(() => actions.Hold(self));
        Throws<InvalidOperationException>(() => actions.Close(self, true));
        Throws<InvalidOperationException>(() => actions.Hold(self with { Id = 4 }));
        Throws<InvalidOperationException>(() => actions.Close(self with { Id = 12345, HasWindow = false }, true));
        Throws<InvalidOperationException>(() => actions.Close(self with { Id = 12345, SessionId = -1 }, true));
    }

    private static async Task<int> NativeUtilitiesSmokeAsync()
    {
        using var monitor = new SystemMonitor();
        var first = await Task.Run(monitor.Sample);
        await Task.Delay(300);
        var sample = await Task.Run(monitor.Sample);
        True(sample.MemoryTotalBytes > 0 && sample.MemoryUsedBytes <= sample.MemoryTotalBytes, "Native memory counters must be bounded.");
        True(sample.CpuPercent is >= 0 and <= 100, "Native CPU deltas must produce a bounded percent.");
        True(sample.Processes.Any(p => p.Id == Environment.ProcessId), "Native process sampler must include this fixture.");
        True(sample.Hardware?.DiskBusyPercent is null or (>= 0 and <= 100), "Disk busy time must remain bounded or unavailable.");
        Console.WriteLine($"GPU busiest engine: {sample.Hardware?.GpuPercent?.ToString("F1") ?? "unavailable"}%; disk busy: {sample.Hardware?.DiskBusyPercent?.ToString("F1") ?? "unavailable"}%; disk read: {sample.Hardware?.DiskReadBytesPerSecond?.ToString("F0") ?? "unavailable"} bytes/s.");
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(25));
        var rows = await new CodexUsageProvider().ReadAsync(timeout.Token);
        True(rows.Count > 0 && rows.All(r => r.UsedPercent is >= 0 and <= 100), "Actual Codex account should return bounded allowance windows.");
        Console.WriteLine($"PASS native utilities: system CPU/memory/storage/network/processes; {rows.Count} real account allowance windows; helper shut down.");
        return 0;
    }

    private static async Task<int> RenderUtilitiesLayoutAsync(string path, int section = 0)
    {
        await OnStaAsync(() =>
        {
            using var lighting = new LightingFixture();
            var model = new CommandCenterViewModel(System.Windows.Threading.Dispatcher.CurrentDispatcher, lighting.Settings);
            model.Processes.Add(new(101, 1, "Layout fixture app", 12.5, 512 * 1048576L, true, 1));
            model.Usage.Add(new("Codex", "Layout fixture · 5 hour", 35, DateTimeOffset.Now.AddHours(2), DateTimeOffset.Now, "Fixture"));
            model.SignalRows.Add(new(Guid.NewGuid().ToString(), "Layout fixture Mac", new(1, Guid.NewGuid().ToString(), 1, DateTimeOffset.UtcNow, DateTimeOffset.UtcNow, DateTimeOffset.UtcNow, "waiting", true, "#ffaa00", "#ffaa00"), System.Diagnostics.Stopwatch.GetTimestamp()));
            model.LocalActivity.Add(new(Guid.NewGuid().ToString(), "Layout fixture project", "toolRunning", "Editing code", DateTimeOffset.Now));
            if (section is 15 or 16)
            {
                model.AgentDisplayMode = "perAgent";
                model.LocalActivity.Add(new("fixture-b", "Layout fixture · needs input", "waiting", "", DateTimeOffset.UtcNow.AddSeconds(-1)));
                model.LocalActivity.Add(new("fixture-c", "Layout fixture · completed", "completed", "", DateTimeOffset.UtcNow.AddSeconds(-2)));
            }
            model.RefreshSignalPresentation();
            if (section == 14)
            {
                typeof(CommandCenterViewModel).GetProperty(nameof(CommandCenterViewModel.Notice))!.SetValue(model, "Layout fixture · 58% battery, external power");
                typeof(CommandCenterViewModel).GetField("reading", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!.SetValue(model, MetricFixture(DateTimeOffset.UtcNow) with { BatteryPercent = 58, ExternallyPowered = true, Charging = false });
            }
            if (section == 8)
            {
                var sampledAt = DateTimeOffset.UtcNow.AddMinutes(-15);
                var rows = Enumerable.Range(0, 451).Select(i => new MetricHistoryPoint(sampledAt.AddSeconds(i * 2), 30 + 20 * Math.Sin(i / 30.0), 50, 10, 20,
                    1048576, i is > 140 and < 180 ? null : 1048576 * (3 + 2 * Math.Sin(i / 20.0)), 100, 200)).ToArray();
                typeof(CommandCenterViewModel).GetProperty(nameof(CommandCenterViewModel.HistorySamples))!.SetValue(model, rows);
            }
            var view = new CommandCenterView { DataContext = model, Width = 1200, Height = 760 };
            view.SelectSection(section);
            view.Measure(new System.Windows.Size(1200, 760)); view.Arrange(new System.Windows.Rect(0, 0, 1200, 760)); view.UpdateLayout();
            if (section is 4 or 7 or 16)
            {
                static void Scroll(System.Windows.DependencyObject parent)
                {
                    for (int i = 0; i < System.Windows.Media.VisualTreeHelper.GetChildrenCount(parent); i++)
                    {
                        var child = System.Windows.Media.VisualTreeHelper.GetChild(parent, i);
                        if (child is System.Windows.Controls.ScrollViewer scroll) scroll.ScrollToEnd();
                        else Scroll(child);
                    }
                }
                Scroll(view); view.UpdateLayout();
            }
            var image = new RenderTargetBitmap(1200, 760, 96, 96, PixelFormats.Pbgra32); image.Render(view);
            var png = new PngBitmapEncoder(); png.Frames.Add(BitmapFrame.Create(image));
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
            using var output = File.Create(path); png.Save(output);
            model.DisposeAsync().AsTask().GetAwaiter().GetResult();
        });
        Console.WriteLine("PASS production Command Center XAML rendered with labeled fixture data.");
        return 0;
    }
}
