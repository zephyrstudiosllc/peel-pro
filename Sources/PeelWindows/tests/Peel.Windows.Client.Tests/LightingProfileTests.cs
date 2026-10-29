using System.Text.Json;
using Peel.Windows.Client.Utilities;
using Peel.Windows.Protocol;

namespace Peel.Windows.Client.Tests;

internal static partial class Program
{
    private sealed class LightingFixture : IDisposable
    {
        internal readonly string Root = Path.Combine(Path.GetTempPath(), "peel-lighting-" + Guid.NewGuid().ToString("N"));
        internal readonly SignalSettings Settings;
        internal LightingFixture() { Directory.CreateDirectory(Root); Settings = new(Path.Combine(Root, "signals.json")); }
        public void Dispose() { foreach (var path in Directory.GetFiles(Root)) File.Delete(path); Directory.Delete(Root); }
    }
    private static void LightingProfilePersistence()
    {
        using var fixture = new LightingFixture(); var store = fixture.Settings.Profiles;
        Equal(LightingProfile.Factory.Id, store.Selected.Id);
        store.Add([LightingProfile.Quiet, LightingProfile.High]); store.SetDefault();
        Guid quiet = store.Selected.Id;
        store.Update(store.Selected with { Name = "Saved custom profile", DeviceBrightness = .63 });
        store.Select(LightingProfile.High.Id);
        var reload = new SignalSettings(Path.Combine(fixture.Root, "signals.json")).Profiles;
        Equal(LightingProfile.High.Id, reload.Selected.Id); reload.SelectDefault(); Equal(quiet, reload.Selected.Id); Equal(.63, reload.Selected.DeviceBrightness);
        var archive = LightingProfileStore.Export(reload.Read().Profiles);
        var imported = LightingProfileStore.Import(archive); Equal(3, imported.Length);
        using (var json = JsonDocument.Parse(archive))
        {
            string date = json.RootElement.GetProperty("exportedAt").GetString()!;
            True(date.EndsWith('Z') && !date.Contains('.'), "Mac ISO8601 import requires whole seconds.");
        }
        reload.Add(imported); Equal(6, reload.Read().Profiles.Length); Equal(6, reload.Read().Profiles.Select(p => p.Id).Distinct().Count());
        True(reload.Selected.Id != imported[0].Id, "An import collision must not replace an existing profile.");
        reload.DeleteSelected(); Equal(quiet, reload.Selected.Id);
        var before = File.ReadAllBytes(Path.Combine(fixture.Root, "lighting-profiles.json"));
        Throws<InvalidDataException>(() => reload.Update(reload.Selected with { DeviceBrightness = double.NaN }));
        Throws<InvalidDataException>(() => reload.Select(Guid.NewGuid()));
        Throws<InvalidDataException>(() => reload.Add(Enumerable.Range(0, 33).Select(_ => LightingProfile.Factory with { Id = Guid.NewGuid() })));
        True(before.SequenceEqual(File.ReadAllBytes(Path.Combine(fixture.Root, "lighting-profiles.json"))), "Rejected changes must preserve the saved library.");
        var snapshot = reload.Read(); snapshot.Profiles[0].Styles[0] = new("idle", "#FFFFFF", "solid", 1, 1);
        True(reload.Read().Profiles[0].Styles[0].Motion == "off", "Read snapshots cannot mutate stored style arrays.");
        foreach (string bad in new[] { "null", "{}", "[]", "{bad}", System.Text.Encoding.UTF8.GetString(archive).Replace("\"single\"", "null"),
            System.Text.Encoding.UTF8.GetString(archive).Replace("\"#FF2BD6\"", "\"#ZZZZZZ\""),
            System.Text.Encoding.UTF8.GetString(archive).Replace("\"formatVersion\": 1", "\"formatVersion\": 99") })
            Throws<InvalidDataException>(() => LightingProfileStore.Import(System.Text.Encoding.UTF8.GetBytes(bad)));
        Throws<InvalidDataException>(() => LightingProfileStore.Import(new byte[LightingProfileStore.MaxBytes + 1]));
        Throws<InvalidDataException>(() => LightingProfileStore.Export([LightingProfile.Factory, LightingProfile.Factory]));
        var linked = LightingProfile.Factory.UpdateStyle(new("working", "#112233", "chase", 3, .6));
        Equal("chase", linked.Style("toolRunning").Motion); Equal(3d, linked.Style("toolRunning").CycleSeconds);
        Equal("#0018FF", linked.Style("toolRunning").ColorHex); Equal("#112233", linked.Style("working").ColorHex);
        File.WriteAllText(Path.Combine(fixture.Root, "lighting-profiles.json"), "{broken");
        Equal(LightingProfile.Factory.Id, new SignalSettings(Path.Combine(fixture.Root, "signals.json")).Profiles.Selected.Id);
        True(Directory.GetFiles(fixture.Root).All(p => !p.EndsWith(".tmp")), "Atomic saves must not leave temporary files.");
    }

    private static void LightingAllocationSemantics()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(1800000000);
        LightAgent A(string id, string state = "working", int age = 0) => new(id, state, now.AddSeconds(-age));
        var adaptive = new LightAllocator(); var slots = adaptive.Assign([A("a", age: 10)], 8, "adaptiveOccupancy", now);
        Equal(8, slots.Count(a => a?.Id == "a"));
        slots = adaptive.Assign([A("b"), A("a", age: 10)], 8, "adaptiveOccupancy", now);
        SequenceEqual(new[] { "b", "b", "b", "b", "a", "a", "a", "a" }, slots.Select(a => a!.Id));
        slots = adaptive.Assign([A("a", "error"), A("b", age: 1)], 8, "adaptiveOccupancy", now);
        Equal("a", slots[7]!.Id); // Updating state/recency does not move a resident.
        slots = adaptive.Assign([A("a"), A("b"), A("c")], 8, "adaptiveOccupancy", now);
        Equal(2, slots.Count(a => a is null)); Equal(2, slots.Count(a => a?.Id == "c"));
        var dot = new LightAllocator(); dot.Assign([A("a", age: 10), A("b", age: 5)], 2, "adaptiveOccupancy", now);
        slots = dot.Assign([A("a", age: 10), A("b", age: 5), A("c")], 2, "adaptiveOccupancy", now);
        True(slots.All(a => a?.Id != "a") && slots.Any(a => a?.Id == "c"), "Dot evicts only the oldest resident for newer activity.");
        var stable = new LightAllocator(); stable.Assign([A("a", "error"), A("b")], 2, "stableAgents", now);
        slots = stable.Assign([A("b")], 2, "stableAgents", now.AddSeconds(1)); Equal<string?>(null, slots[0]?.Id); Equal("b", slots[1]!.Id);
        slots = stable.Assign([A("a"), A("b", "error")], 2, "stableAgents", now.AddSeconds(2)); Equal("a", slots[0]!.Id);
        stable.Assign([], 2, "stableAgents", now.AddSeconds(303));
        slots = stable.Assign([A("a"), A("b", "error")], 2, "stableAgents", now.AddSeconds(304)); Equal("b", slots[0]!.Id);
        slots = stable.Assign([A("a", "error"), A("b")], 2, "priorityStack", now); Equal("a", slots[0]!.Id);
        Equal("working", AgentLighting.ForMode([A("a", "toolRunning"), A("b", "completed")], "simple").Single().State);
        Equal("error", AgentLighting.ForMode([A("a", "waiting"), A("b", "error")], "simple").Single().State);
        Equal(0, AgentLighting.Visible([new("a", "fixture", "working", "", now.AddMinutes(-16)), new("b", "fixture", "working", "", now.AddMinutes(6))], now).Length);
        foreach (var profile in new[] { LightingProfile.Factory, LightingProfile.Quiet, LightingProfile.High })
            foreach (string state in SignalSettings.States)
                foreach (int count in new[] { 2, 8 })
                    TrustedSignals.ValidateProgram(AgentLighting.Compile(profile, [A("a", state)], new(), count, now).Program);
    }

    private static async Task LightingProfileCompositionAsync()
    {
        using var fixture = new LightingFixture(); var settings = fixture.Settings;
        await OnStaAsync(() =>
        {
            var model = new CommandCenterViewModel(System.Windows.Threading.Dispatcher.CurrentDispatcher, settings);
            try
            {
                var studio = new LightingStudioView { DataContext = model, Width = 700, Height = 620 };
                studio.Measure(new System.Windows.Size(700, 620)); studio.Arrange(new System.Windows.Rect(0, 0, 700, 620)); studio.UpdateLayout();
                static IEnumerable<T> Controls<T>(System.Windows.DependencyObject parent) where T : System.Windows.DependencyObject
                {
                    for (int i = 0; i < System.Windows.Media.VisualTreeHelper.GetChildrenCount(parent); i++)
                    {
                        var child = System.Windows.Media.VisualTreeHelper.GetChild(parent, i);
                        if (child is T match) yield return match;
                        foreach (var nested in Controls<T>(child)) yield return nested;
                    }
                }
                var stateList = Controls<System.Windows.Controls.ListBox>(studio).Single();
                stateList.SelectedValue = "waiting";
                Equal("waiting", model.ProfileState); Equal("Needs Input", model.ProfileStateTitle);
                var colorMode = Controls<System.Windows.Controls.ComboBox>(studio).Single(c => System.Windows.Automation.AutomationProperties.GetName(c) == "Profile color mode");
                colorMode.SelectedValue = "rainbow"; Equal("rainbow", model.ProfileColorMode);
                colorMode.SelectedValue = "single";
                var motion = Controls<System.Windows.Controls.ComboBox>(studio).Single(c => System.Windows.Automation.AutomationProperties.GetName(c) == "Profile motion");
                motion.SelectedValue = "chase"; Equal("chase", model.ProfileMotion);
                model.ProfileState = "working";
                Equal("working", stateList.SelectedValue); Equal("breathe", motion.SelectedValue);
                var center = new CommandCenterView { DataContext = model, Width = 960, Height = 740 };
                center.SelectSection(15);
                center.Measure(new System.Windows.Size(960, 740)); center.Arrange(new System.Windows.Rect(0, 0, 960, 740)); center.UpdateLayout();
                var pageHost = (StudioPageHost)center.FindName("Sections");
                var pagePeer = System.Windows.Automation.Peers.UIElementAutomationPeer.CreatePeerForElement(pageHost)!;
                static IEnumerable<string> AccessibleNames(System.Windows.Automation.Peers.AutomationPeer peer)
                {
                    yield return peer.GetName();
                    foreach (var child in peer.GetChildren() ?? [])
                        foreach (var name in AccessibleNames(child)) yield return name;
                }
                var names = AccessibleNames(pagePeer).ToArray();
                True(names.Contains("Lighting profile") && names.Contains("Profile state") && names.Contains("Save profile and state"),
                    "Sidebar pages must expose actual lighting controls through Windows accessibility.");
                center.SelectSection(2); center.UpdateLayout();
                center.Dispatcher.Invoke(() => { }, System.Windows.Threading.DispatcherPriority.ContextIdle);
                names = AccessibleNames(pagePeer).ToArray();
                True(names.Contains("Refresh local chats") && !names.Contains("Lighting profile"),
                    "Changing pages must expose the new controls and remove the previous page.");
                var now = DateTimeOffset.UtcNow;
                model.LocalActivity.Add(new("a", "Project A", "working", "", now.AddSeconds(-1)));
                model.LocalActivity.Add(new("b", "Project B", "waiting", "", now));
                model.AgentDisplayMode = "perAgent";
                Equal(4, model.LightAllocations.Count); True(model.LightAllocations.Any(r => r.Session == "Project A · a" && r.Lights == "1, 2, 3, 4"), "Adaptive Pro shows each session's block.");
                string initial = model.ActivityProgram; var started = model.ActivityStartedAt;
                model.RefreshSignalPresentation(); Equal(started, model.ActivityStartedAt);
                model.ProfileName = "Integration fixture"; model.ProfileBrightness = .4; model.ProfileColor = "#123456";
                model.SaveLightingProfileCommand.Execute(null); Equal("Integration fixture", settings.Profiles.Selected.Name);
                True(model.ActivityProgram != initial, "Saving a profile refreshes current output.");
                model.DuplicateLightingProfileCommand.Execute(null); Equal(2, model.LightingProfiles.Count);
                model.DefaultLightingProfileCommand.Execute(null); var defaultId = settings.Profiles.Selected.Id;
                model.NewLightingProfileCommand.Execute(null); Equal(3, model.LightingProfiles.Count);
                model.UseDefaultLightingProfileCommand.Execute(null); Equal(defaultId, settings.Profiles.Selected.Id);
                model.DeleteLightingProfileCommand.Execute(null); Equal(2, model.LightingProfiles.Count);
                model.ProfileColor = "invalid"; model.SaveLightingProfileCommand.Execute(null);
                True(model.ProfileStatus.StartsWith("Could not"), "Invalid style input must be reported without changing saved output.");
                model.AgentDisplayMode = "simple"; Equal(2, model.LightAllocations.Count);
                settings.SaveStyle("waiting", new("#123456", "#654321")); model.RefreshSignalPresentation(); Equal("#123456", model.ActivityProgram);
                model.AgentDisplayMode = "perAgent"; True(model.ActivityProgram != "#123456", "An array-wide legacy override must not replace multiple agent slots.");
                model.AgentDisplayMode = "simple"; Equal("#123456", model.ActivityProgram);
                model.UseProfileProgramsCommand.Execute(null); True(model.ActivityProgram != "#123456" && settings.Override("waiting") is null, "Explicit override reset restores the selected profile.");
                model.LocalActivity.Clear(); model.RefreshSignalPresentation(); Equal("off", model.ActivityProgram); Equal("off", model.ActivityDotProgram); Equal(0, model.LightAllocations.Count);
            }
            finally { model.DisposeAsync().AsTask().GetAwaiter().GetResult(); }
        });
        Equal("simple", new SignalSettings(Path.Combine(fixture.Root, "signals.json")).Presentation.DisplayMode);
    }

    private static void MacLightingVectors()
    {
        using var data = typeof(Program).Assembly.GetManifestResourceStream("Peel.Windows.Client.Tests.mac-lighting-vectors.json") ?? throw new InvalidOperationException("Missing Mac reference vectors.");
        using var json = JsonDocument.Parse(data);
        var allocators = new Dictionary<string, LightAllocator>(); int count = 0;
        foreach (var vector in json.RootElement.EnumerateArray())
        {
            string name = vector.GetProperty("name").GetString()!, group = vector.GetProperty("group").GetString()!;
            var profile = vector.GetProperty("profile").Deserialize<LightingProfile>(LightingProfileStore.Json)!.Validate();
            var agents = vector.GetProperty("agents").EnumerateArray().Select(a => new LightAgent(a.GetProperty("id").GetString()!, a.GetProperty("state").GetString()!,
                DateTimeOffset.FromUnixTimeSeconds((long)a.GetProperty("updatedAt").GetDouble()), a.GetProperty("provider").GetString()!)).ToArray();
            agents = AgentLighting.ForMode(agents, vector.GetProperty("mode").GetString()!);
            if (!allocators.TryGetValue(group, out var allocator)) allocators[group] = allocator = new();
            var scene = AgentLighting.Compile(profile, agents, allocator, vector.GetProperty("ledCount").GetInt32(), DateTimeOffset.FromUnixTimeSeconds((long)vector.GetProperty("now").GetDouble()));
            True(vector.GetProperty("program").GetString() == scene.Program, "Mac program differs: " + name + "\n" + scene.Program);
            SequenceEqual(vector.GetProperty("slots").EnumerateArray().Select(v => v.GetString()), scene.Slots.Select(a => a?.Id));
            Equal(vector.GetProperty("state").GetString(), agents.OrderBy(a => a.Priority).ThenByDescending(a => a.UpdatedAt).FirstOrDefault()?.State ?? "idle");
            count++;
        }
        True(count >= 170, "Expected the complete live-Mac compiler/allocator reference corpus.");
        Console.WriteLine($"PASS {count} exact Mac compiler/allocation vectors.");
    }

    private static async Task<int> NativeLightingProfileAsync()
    {
        using var fixture = new LightingFixture(); var settings = fixture.Settings;
        settings.SavePresentation(new(DisplayMode: "perAgent"));
        var profile = LightingProfile.Factory.UpdateStyle(new("error", "#FF0000", "solid", 1, 1)).UpdateStyle(new("completed", "#00FF00", "solid", 1, 1)) with { DeviceBrightness = 1 };
        settings.Profiles.Update(profile);
        var now = DateTimeOffset.UtcNow;
        var scene = new LocalLightScenes().Compile(settings, [new("a", "error", now), new("b", "completed", now.AddSeconds(-1))], now);
        await OnStaAsync(() =>
        {
            void Verify(string program, int count)
            {
                var lights = new SignalLights { Program = program, LedCount = count, StartedAt = now, ValidUntil = System.Diagnostics.Stopwatch.GetTimestamp() + System.Diagnostics.Stopwatch.Frequency * 5, Width = count * 40, Height = 24 };
                lights.Measure(new System.Windows.Size(count * 40, 24)); lights.Arrange(new System.Windows.Rect(0, 0, count * 40, 24));
                var bitmap = new System.Windows.Media.Imaging.RenderTargetBitmap(count * 40, 24, 96, 96, System.Windows.Media.PixelFormats.Pbgra32);
                bitmap.Render(lights); byte[] pixels = new byte[count * 40 * 24 * 4]; bitmap.CopyPixels(pixels, count * 40 * 4, 0);
                for (int i = 0; i < count; i++)
                {
                    int offset = (12 * count * 40 + i * 40 + 20) * 4;
                    Equal((byte)(i < count / 2 ? 255 : 0), pixels[offset + 1]);
                    Equal((byte)(i >= count / 2 ? 255 : 0), pixels[offset + 2]);
                }
            }
            Verify(scene.Programs.Pro, 8); Verify(scene.Programs.Dot, 2);
        });
        string file = Path.Combine(fixture.Root, "LEDS.LED");
        async Task<string> ReadProgram()
        {
            using var reader = new StreamReader(new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite));
            return await reader.ReadToEndAsync();
        }
        await using (var writer = new SidePulseDevice.FileWriter(new FileStream(file, FileMode.CreateNew, FileAccess.Write, FileShare.Read, 1, FileOptions.Asynchronous | FileOptions.WriteThrough)))
        {
            await writer.WriteAsync(SignalCalibration.Apply(scene.Programs.Pro, "pro", 1), CancellationToken.None);
            Equal(scene.Programs.Pro, await ReadProgram());
            string dot = SignalCalibration.Apply(scene.Programs.Dot, "dot", 1);
            await writer.WriteAsync(dot, CancellationToken.None); Equal(dot, await ReadProgram());
            await writer.WriteAsync("off", CancellationToken.None); Equal(3L, new FileInfo(file).Length);
        }
        Console.WriteLine("PASS native Pro/Dot WPF allocation pixels and actual calibrated program-file writes/truncation. No physical USB device was written.");
        return 0;
    }
}
