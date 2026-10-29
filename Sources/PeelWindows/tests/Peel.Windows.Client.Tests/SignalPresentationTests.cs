using System.Diagnostics;
using Peel.Windows.Client.Services;
using Peel.Windows.Client.Utilities;

namespace Peel.Windows.Client.Tests;
internal static partial class Program
{
    private static async Task<int> NativeSignalLightsAsync()
    {
        await OnStaAsync(() =>
        {
            var lights = new SignalLights { Program = "#FF0000", StartedAt = DateTimeOffset.UtcNow, Width = 320, Height = 24 };
            var window = new System.Windows.Window { Title = "Peel light expiry fixture", Content = lights, Width = 360, Height = 85, ShowInTaskbar = false };
            try
            {
                window.Show(); lights.ValidUntil = Stopwatch.GetTimestamp() + Stopwatch.Frequency / 2;
                window.UpdateLayout();
                static int RedPixels(SignalLights view)
                {
                    var bitmap = new System.Windows.Media.Imaging.RenderTargetBitmap(320, 24, 96, 96, System.Windows.Media.PixelFormats.Pbgra32);
                    bitmap.Render(view); byte[] pixels = new byte[320 * 24 * 4]; bitmap.CopyPixels(pixels, 320 * 4, 0);
                    int red = 0; for (int i = 0; i < pixels.Length; i += 4) if (pixels[i + 2] > 200 && pixels[i + 1] < 20 && pixels[i] < 20) red++;
                    return red;
                }
                True(RedPixels(lights) > 0, "Fresh static program should paint red pixels.");
                var frame = new System.Windows.Threading.DispatcherFrame();
                var timeout = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
                timeout.Tick += (_, _) => { timeout.Stop(); frame.Continue = false; };
                timeout.Start(); System.Windows.Threading.Dispatcher.PushFrame(frame);
                Equal(0, RedPixels(lights)); // RenderTargetBitmap uses the cached visual: the expiry timer must invalidate it.
            }
            finally { window.Close(); }
        });
        Console.WriteLine("PASS native WPF solid lights expire without a new signal or view-model refresh."); return 0;
    }

    private static void SignalFirmwareRendering()
    {
        static void Near(double wanted, double actual) => True(Math.Abs(wanted - actual) < 0.000001, $"Expected {wanted}, got {actual}.");
        var solid = new SignalProgram("brightness 128\n#FF0000");
        Near(128d / 255, solid.Frame(10)[7].Red); Near(0, solid.Frame(0)[0].Green);
        True(!solid.NeedsAnimation(1), "Completed solids should not require animation.");
        var indices = new SignalProgram("#FFFFFF\n0:#FF0000;7:#0000FF;0:#00FF00");
        var colors = indices.Frame(1); Near(1, colors[0].Green); Near(0, colors[0].Red); Near(1, colors[7].Blue); Near(1, colors[1].Red);
        colors = new SignalProgram("#FF0000 #00FF00 #0000FF").Frame(1);
        Near(1, colors[0].Red); Near(1, colors[1].Green); Near(1, colors[2].Blue); Near(0, colors[3].Red);
        var pulse = new SignalProgram("#FF0000 1s pulse");
        Near(0, pulse.Frame(0)[0].Red); Near(1, pulse.Frame(.5)[0].Red); Near(0, pulse.Frame(1)[0].Red);
        var delay = new SignalProgram("0:#FF0000 1s linear 1s;1:#00FF00 2s linear");
        Near(0, delay.Frame(.5)[0].Red); Near(.25, delay.Frame(.5)[1].Green); Near(.5, delay.Frame(1.5)[0].Red);
        Near(.15625, new SignalProgram("#FFFFFF 1s ease").Frame(.25)[0].Red);
        Near(.0625, new SignalProgram("#FFFFFF 1s ease-in").Frame(.25)[0].Red);
        Near(.4375, new SignalProgram("#FFFFFF 1s ease-out").Frame(.25)[0].Red);
        Near(.5, new SignalProgram("#FFFFFF 1s ease-in-out").Frame(.5)[0].Red);
        Near(1, new SignalProgram("#FFFFFF 1s none").Frame(0)[0].Red);
        var repeat = new SignalProgram("#FF0000 1s none\n#0000FF 1s none\nrepeat\nbrightness 0");
        Near(1, repeat.Frame(2.5)[0].Red); Near(1, repeat.Frame(3.5)[0].Blue);
        True(repeat.NeedsAnimation(1000), "Repeated programs keep animating.");
        var working = new SignalProgram(TrustedSignalPublisher.ProgramFor("working"));
        Near(0, working.Frame(0)[0].Red); Near(106d / 255, working.Frame(1d / 60 + .517)[0].Red);
        var dot = new SignalProgram("7:#FF0000\n0:#00FF00", 1); Near(1, dot.Frame(1)[0].Green); Equal(1, dot.Frame(1).Length);
        True(new SignalProgram("#FF0000 9223372036854775807ms cosine\nrepeat").Frame(double.MaxValue).All(c => double.IsFinite(c.Red)), "Long legal durations must not overflow.");
        Near(0, working.Frame(double.NaN)[0].Red);
        foreach (string invalid in new[] { "", "#123", "brightness 256", "8:#FF0000", "#FF0000 0ms linear", "#FF0000 1s mystery", new string('x', 513) })
            Throws<InvalidDataException>(() => new SignalProgram(invalid));
    }

    private static async Task SignalPresentationSelectionAsync()
    {
        string root = Path.Combine(Path.GetTempPath(), "peel-signal-settings-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root); string path = Path.Combine(root, "signals.json");
        try
        {
            var settings = new SignalSettings(path);
            settings.SaveStyle("working", new("#112233", "#445566"));
            Equal(new SignalPrograms("#112233", "#445566"), new SignalSettings(path).Programs("progress"));
            Throws<InvalidDataException>(() => settings.SaveStyle("unknown", new("off", "off")));
            Throws<InvalidDataException>(() => settings.SaveStyle("working", new("bad", "off")));
            Equal("#112233", new SignalSettings(path).Programs("working").Pro);
            await OnStaAsync(() =>
            {
                var model = new CommandCenterViewModel(System.Windows.Threading.Dispatcher.CurrentDispatcher, settings);
                var now = DateTimeOffset.UtcNow;
                string host = Guid.NewGuid().ToString("D");
                var peer = new ReceivedDeviceSignal(host, "Fixture Mac", new(1, Guid.NewGuid().ToString("D"), 1, now, now, now, "error", true, "#FF0000", "#00FF00"), Stopwatch.GetTimestamp());
                model.SignalRows.Add(peer);
                var local = new AgentActivityReading("local", "Fixture project", "working", "", now);
                model.LocalActivity.Add(local); model.RefreshSignalPresentation();
                Equal("#112233", model.ActivityProgram); // Automatic honors local ownership before remote priority.
                DateTimeOffset started = model.ActivityStartedAt;
                model.RefreshSignalPresentation(); Equal(started, model.ActivityStartedAt);
                model.SignalSource = "paired"; Equal("#FF0000", model.ActivityProgram); Equal(now, model.ActivityStartedAt);
                model.SignalSource = "host:" + host; model.SignalRows.Clear(); model.RefreshSignalPresentation();
                Equal("off", model.ActivityProgram); Equal("host:" + host, model.SignalSource);
                True(model.SignalSources.Any(s => s.Id == model.SignalSource && s.Label.Contains("unavailable")), "Missing source must retain exact selection.");
                model.SignalRows.Add(peer with { ReceivedTimestamp = Stopwatch.GetTimestamp() - Stopwatch.Frequency * 4 });
                model.RefreshSignalPresentation(); Equal("off", model.ActivityProgram);
                model.SignalSource = "local"; Equal("#112233", model.ActivityProgram);
                model.LocalActivity.Clear(); model.LocalActivity.Add(local with { EventAt = now.AddMinutes(-16) }); model.RefreshSignalPresentation(); Equal("off", model.ActivityProgram);
                model.LocalActivity.Clear(); model.LocalActivity.Add(local with { EventAt = now.AddMinutes(6) }); model.RefreshSignalPresentation(); Equal("off", model.ActivityProgram);
                model.ShowActivityLights = false; model.ShowUsageInBar = false;
                model.DisposeAsync().AsTask().GetAwaiter().GetResult();
            });
            Equal(new SignalPreferences("local", "This PC", false, false), new SignalSettings(path).Presentation);
            settings.SaveStyle("working", null);
            Equal(AgentLighting.Compile(LightingProfile.Factory, [new("a", "working", DateTimeOffset.UtcNow)], new(), 8, DateTimeOffset.UtcNow).Program, settings.Programs("working").Pro);
            File.WriteAllText(path, "{\"Presentation\":null,\"Styles\":{}}"); Equal(new SignalPreferences(), new SignalSettings(path).Presentation);
            File.WriteAllText(path, new string('x', 16385)); Equal(new SignalPreferences(), new SignalSettings(path).Presentation);
            True(Directory.GetFiles(root).Length == 1, "Atomic saves must not leave temporary files.");
        }
        finally { File.Delete(path); Directory.Delete(root); }
    }
}
