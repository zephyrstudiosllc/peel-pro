using System.Diagnostics;
using System.Text;
using System.Threading.Channels;
using Peel.Windows.Client.Utilities;

namespace Peel.Windows.Client.Tests;
internal static partial class Program
{
    private sealed class LightWriter : ISidePulseWriter
    {
        internal readonly Channel<string> Writes = Channel.CreateUnbounded<string>();
        internal bool Disposed;
        internal bool FailNext;
        public Task WriteAsync(string program, CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            True(!Disposed, "A retired writer cannot receive output.");
            if (FailNext) { FailNext = false; throw new IOException("Fixture device removed."); }
            Writes.Writer.TryWrite(program); return Task.CompletedTask;
        }
        public ValueTask DisposeAsync() { Disposed = true; return ValueTask.CompletedTask; }
        internal async Task<string> NextAsync() => await Writes.Reader.ReadAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(3));
    }
    private static SidePulseDevice LightDevice(string kind = "pro") => new(@"\\?\Volume{" + Guid.NewGuid().ToString("D") + @"}\", 123, 456, "Fixture USB", kind);
    private static async Task SidePulseOutputOwnershipAsync()
    {
        var device = LightDevice(); device.Validate();
        Throws<InvalidDataException>(() => (device with { Volume = @"C:\" }).Validate());
        Throws<InvalidDataException>(() => (device with { Kind = "unknown" }).Validate());
        Equal("pro", SidePulseDevice.Detect("SidePulse 2")); Equal("dot", SidePulseDevice.Detect("PULSE_DOT")); Equal<string?>(null, SidePulseDevice.Detect("External"));
        Equal("brightness 42\n#0018BF", SignalCalibration.Apply("brightness 106\n#0018FF", "dot", 1));
        Equal("brightness 102\n#000017", SignalCalibration.Apply("#00001E", "dot", 1));
        Equal("brightness 128\n#FFFFFF", SignalCalibration.Apply("#FFFFFF", "pro", .5));
        Equal("off", SignalCalibration.Apply("off", "dot", 1));
        Throws<InvalidDataException>(() => SignalCalibration.Apply("off", "pro", double.NaN));
        Throws<InvalidDataException>(() => SignalCalibration.Apply(string.Join('\n', Enumerable.Repeat("#FFFFFF", 20)), "dot", 1));
        var writer = new LightWriter();
        await using (var output = new SidePulseOutput(_ => writer))
        {
            output.Update("#FF0000", "#0000FF", Stopwatch.GetTimestamp() + Stopwatch.Frequency / 4, 1);
            await output.StartAsync(device, CancellationToken.None);
            Equal("#FF0000", await writer.NextAsync());
            Equal("off", await writer.NextAsync()); // Freshness expires without another producer update.
            await output.StopAsync(); Equal("off", await writer.NextAsync()); True(writer.Disposed && !output.Enabled, "Stop awaits light-off and closes the owned writer.");
        }
        var dotWriter = new LightWriter();
        await using (var output = new SidePulseOutput(_ => dotWriter))
        {
            output.Update("#FF0000", "#0000FF", Stopwatch.GetTimestamp() + Stopwatch.Frequency * 10, 1);
            await output.StartAsync(LightDevice("dot"), CancellationToken.None);
            Equal("brightness 102\n#0000BF", await dotWriter.NextAsync());
            dotWriter.FailNext = true; output.Update("off", "#00FF00", Stopwatch.GetTimestamp() + Stopwatch.Frequency * 10, 1);
            Equal("off", await dotWriter.NextAsync());
            await output.StopAsync(); True(dotWriter.Disposed && output.Status.Contains("Fixture device removed"), "A removed device stops without finding a replacement drive.");
        }
        var late = new LightWriter(); var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await using (var output = new SidePulseOutput(_ => { entered.TrySetResult(); release.Task.GetAwaiter().GetResult(); return late; }))
        {
            var start = output.StartAsync(device, CancellationToken.None); await entered.Task.WaitAsync(TimeSpan.FromSeconds(3));
            output.Cancel(); release.TrySetResult();
            try { await start; throw new InvalidOperationException("Canceled device open restored output."); } catch (OperationCanceledException) { }
            True(late.Disposed && !late.Writes.Reader.TryRead(out _) && !output.Enabled, "Late device open cannot restore revoked consent.");
        }
    }
    private static async Task<int> NativeLightFileAsync()
    {
        string path = Path.Combine(Path.GetTempPath(), "peel-light-file-" + Guid.NewGuid().ToString("N") + ".tmp");
        File.WriteAllText(path, new string('x', 512));
        try
        {
            string Read()
            {
                using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
                using var reader = new StreamReader(stream); return reader.ReadToEnd();
            }
            await using (var writer = new SidePulseDevice.FileWriter(new FileStream(path, FileMode.Open, FileAccess.Write, FileShare.Read, 1, FileOptions.Asynchronous | FileOptions.WriteThrough)))
            {
                await writer.WriteAsync("brightness 128\n#FF0000", CancellationToken.None);
                Equal("brightness 128\n#FF0000", Read());
                await writer.WriteAsync("off", CancellationToken.None); Equal("off", Read());
                using var cancel = new CancellationTokenSource(); cancel.Cancel();
                try { await writer.WriteAsync("#FF0000", cancel.Token); throw new InvalidOperationException("Canceled write ran."); } catch (OperationCanceledException) { }
                Equal(3L, new FileInfo(path).Length);
            }
            Console.WriteLine($"PASS native program-file async write, truncation, flush and cancellation; read-only USB discovery found {SidePulseDevice.Discover().Count} eligible device(s). No USB device was written.");
        }
        finally { File.Delete(path); }
        return 0;
    }
}
