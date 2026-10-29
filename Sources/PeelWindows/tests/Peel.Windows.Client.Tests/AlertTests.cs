using System.Diagnostics;
using System.Windows.Threading;
using Peel.Windows.Client.Utilities;

namespace Peel.Windows.Client.Tests;
internal static partial class Program
{
    private static void AlertRulesRequireSustainedIdentity()
    {
        var engine = new AlertEvaluator();
        var policy = new AlertPolicy { CpuThreshold = 50, MemoryThresholdMb = 200, ConsecutiveSamples = 2, MemoryProtectionMb = 256, MemoryProtectionApp = "Fixture" };
        var app = new ProcessReading(23456, 100, "Fixture", 80, 600 * 1048576L, true, 1);
        var sample = new SystemReading(DateTimeOffset.UtcNow, 80, 1000, 2000, 10, 20, null, 0, 0, [app]);
        Equal(0, engine.Evaluate(sample, policy, true, 1).Notices.Count);
        var high = engine.Evaluate(sample with { SampledAt = sample.SampledAt.AddSeconds(2) }, policy, true, 1);
        Equal(2, high.Notices.Count); Equal(0, high.HoldCandidates.Count);
        Equal(0, engine.Evaluate(sample with { SampledAt = sample.SampledAt.AddSeconds(4) }, policy, true, 1).Notices.Count);
        policy.MemoryProtectionEnabled = true;
        Equal(0, engine.Evaluate(sample, policy, false, 1).HoldCandidates.Count);
        Equal(1, engine.Evaluate(sample with { SampledAt = sample.SampledAt.AddSeconds(6) }, policy, false, 1).HoldCandidates.Count);
        // Reused PID does not inherit the previous app instance's sustained match.
        Equal(0, engine.Evaluate(sample with { Processes = [app with { StartedUtcTicks = 200 }] }, policy, false, 1).HoldCandidates.Count);
        policy.MemoryThresholdMb = double.NaN;
        Throws<ArgumentException>(() => engine.Evaluate(sample, policy, true, 1));
    }

    private static async Task<int> ProcessActionFixtureAsync()
    {
        await OnStaAsync(() =>
        {
            var window = new System.Windows.Window { Title = "Peel owned process-action validation", Width = 340, Height = 120,
                Content = "Temporary validation app. It closes after the test." };
            var timer = new DispatcherTimer(TimeSpan.FromMilliseconds(30), DispatcherPriority.Normal,
                (_, _) => Console.WriteLine("tick"), Dispatcher.CurrentDispatcher);
            window.Closed += (_, _) => { timer.Stop(); Dispatcher.CurrentDispatcher.InvokeShutdown(); };
            window.Show(); Console.WriteLine("ready"); Dispatcher.Run();
        });
        return 0;
    }

    private static async Task<int> NativeProcessActionsAsync()
    {
        string dotnet = Environment.ProcessPath ?? throw new InvalidOperationException();
        var start = new ProcessStartInfo(dotnet) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
        if (Path.GetFileNameWithoutExtension(dotnet).Equals("dotnet", StringComparison.OrdinalIgnoreCase)) start.ArgumentList.Add(typeof(Program).Assembly.Location);
        start.ArgumentList.Add("--process-action-fixture");
        using var child = Process.Start(start) ?? throw new InvalidOperationException();
        using var actions = new ProcessActions();
        int ticks = 0;
        var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        Task reader = Task.Run(async () =>
        {
            while (await child.StandardOutput.ReadLineAsync() is { } line)
            { if (line == "ready") ready.TrySetResult(); if (line == "tick") Interlocked.Increment(ref ticks); }
        });
        try
        {
            await ready.Task.WaitAsync(TimeSpan.FromSeconds(8));
            await WaitUntilAsync(() => Volatile.Read(ref ticks) >= 2);
            child.Refresh();
            var reading = new ProcessReading(child.Id, child.StartTime.ToUniversalTime().Ticks, child.ProcessName, 0, child.WorkingSet64, child.MainWindowHandle != 0, child.SessionId);
            actions.Hold(reading); await Task.Delay(100); int stopped = Volatile.Read(ref ticks); await Task.Delay(180);
            Equal(stopped, Volatile.Read(ref ticks)); True(actions.IsHeld(reading), "Fixture should be held.");
            actions.Resume(reading); await WaitUntilAsync(() => Volatile.Read(ref ticks) > stopped);
            Throws<InvalidOperationException>(() => actions.Hold(reading with { StartedUtcTicks = reading.StartedUtcTicks + 1 }));
            actions.Hold(reading); actions.Dispose(); int resumed = Volatile.Read(ref ticks);
            await WaitUntilAsync(() => Volatile.Read(ref ticks) > resumed);
            actions.Close(reading, false); await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5)); await reader;
            Console.WriteLine("PASS native App Mechanic: owned fixture Hold freezes heartbeat, Resume and disposal restore it, stale identity rejected, Close exits cleanly.");
            return 0;
        }
        finally { if (!child.HasExited) { actions.Dispose(); child.Kill(); await child.WaitForExitAsync(); } }
    }
}
