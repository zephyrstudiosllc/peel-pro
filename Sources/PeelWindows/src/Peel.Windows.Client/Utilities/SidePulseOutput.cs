using System.Diagnostics;
using System.IO;
using Peel.Windows.Protocol;

namespace Peel.Windows.Client.Utilities;

/// <summary>One explicitly selected USB device, one writer, and session-only output consent.</summary>
internal sealed class SidePulseOutput : IAsyncDisposable
{
    private readonly Func<SidePulseDevice, ISidePulseWriter> open;
    private readonly object gate = new();
    private readonly SemaphoreSlim lifecycle = new(1, 1);
    private Generation? current;
    private long epoch;
    private bool disposed;
    private string pro = "off", dot = "off", status = "USB light output is off.";
    private long validUntil;
    private double brightness = 1;
    private bool flashlight;
    private sealed class Generation(SidePulseDevice device, ISidePulseWriter writer)
    {
        internal readonly SidePulseDevice Device = device;
        internal readonly ISidePulseWriter Writer = writer;
        internal readonly CancellationTokenSource Cancel = new();
        internal Task Worker = Task.CompletedTask;
    }
    internal SidePulseOutput(Func<SidePulseDevice, ISidePulseWriter>? open = null) => this.open = open ?? SidePulseDevice.Open;
    internal bool Enabled { get { lock (gate) return current is { Cancel.IsCancellationRequested: false, Worker.IsCompleted: false }; } }
    internal string Status { get { lock (gate) return status; } }
    internal void Update(string pro, string dot, long validUntil, double brightness, bool flashlight = false)
    {
        TrustedSignals.ValidateProgram(pro); TrustedSignals.ValidateProgram(dot);
        if (!double.IsFinite(brightness) || brightness is < 0 or > 1) throw new InvalidDataException("Invalid light brightness.");
        lock (gate) { this.pro = pro; this.dot = dot; this.validUntil = validUntil; this.brightness = brightness; this.flashlight = flashlight; }
    }
    internal async Task StartAsync(SidePulseDevice device, CancellationToken token)
    {
        long startedEpoch; lock (gate) startedEpoch = epoch;
        await lifecycle.WaitAsync(token).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            await StopCoreAsync().ConfigureAwait(false); token.ThrowIfCancellationRequested();
            var writer = await Task.Run(() => open(device), token).ConfigureAwait(false);
            Generation? next = null;
            try
            {
                lock (gate)
                {
                    token.ThrowIfCancellationRequested();
                    if (epoch != startedEpoch) throw new OperationCanceledException("USB light output was stopped.");
                    next = new(device, writer); current = next; status = "Starting " + device.Label + "…";
                    next.Worker = Task.Run(() => RunAsync(next));
                }
            }
            finally { if (next is null) await writer.DisposeAsync().ConfigureAwait(false); }
        }
        finally { lifecycle.Release(); }
    }
    internal void Cancel()
    {
        lock (gate) { epoch++; current?.Cancel.Cancel(); }
    }
    internal async Task StopAsync()
    {
        Cancel(); await lifecycle.WaitAsync().ConfigureAwait(false);
        try { await StopCoreAsync().ConfigureAwait(false); } finally { lifecycle.Release(); }
    }
    private async Task StopCoreAsync()
    {
        Generation? old; lock (gate) { old = current; old?.Cancel.Cancel(); }
        if (old is null) return;
        await old.Worker.ConfigureAwait(false);
        lock (gate) { if (ReferenceEquals(current, old)) current = null; old.Cancel.Dispose(); }
    }
    private async Task RunAsync(Generation generation)
    {
        string? last = null; long writtenAt = 0; string? error = null;
        try
        {
            using var timer = new PeriodicTimer(TimeSpan.FromMilliseconds(100));
            do
            {
                generation.Cancel.Token.ThrowIfCancellationRequested();
                string program; double level; bool fullWhite;
                lock (gate) { program = Stopwatch.GetTimestamp() <= validUntil ? generation.Device.Kind == "dot" ? dot : pro : "off"; level = brightness; fullWhite = flashlight; }
                program = SignalCalibration.Apply(program, fullWhite ? "pro" : generation.Device.Kind, fullWhite ? 1 : level);
                double refresh = program.Split('\n').Contains("repeat") ? 5 : 15;
                if (last == program && (program == "off" || Stopwatch.GetElapsedTime(writtenAt).TotalSeconds < refresh)) continue;
                using var deadline = CancellationTokenSource.CreateLinkedTokenSource(generation.Cancel.Token); deadline.CancelAfter(TimeSpan.FromSeconds(3));
                await generation.Writer.WriteAsync(program, deadline.Token).ConfigureAwait(false);
                last = program; writtenAt = Stopwatch.GetTimestamp();
                lock (gate) if (ReferenceEquals(current, generation)) status = generation.Device.Label + " · " + (program == "off" ? "waiting for activity" : "output active");
            } while (await timer.WaitForNextTickAsync(generation.Cancel.Token).ConfigureAwait(false));
        }
        catch (OperationCanceledException) { if (!generation.Cancel.IsCancellationRequested) error = "USB write timed out; output stopped."; }
        catch (Exception e) when (e is IOException or InvalidDataException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        { error = "USB output stopped: " + e.Message; }
        finally
        {
            try
            {
                using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(3));
                await generation.Writer.WriteAsync("off", deadline.Token).ConfigureAwait(false);
            }
            catch (Exception e) when (e is IOException or OperationCanceledException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
            { error ??= "USB output stopped; the device could not confirm lights off."; }
            try { await generation.Writer.DisposeAsync().ConfigureAwait(false); }
            catch (IOException) { error ??= "USB output stopped; closing the device failed."; }
            lock (gate) if (ReferenceEquals(current, generation)) status = error ?? "USB light output is off.";
        }
    }
    public async ValueTask DisposeAsync()
    {
        Cancel(); await lifecycle.WaitAsync().ConfigureAwait(false);
        try { disposed = true; await StopCoreAsync().ConfigureAwait(false); } finally { lifecycle.Release(); }
    }
}
