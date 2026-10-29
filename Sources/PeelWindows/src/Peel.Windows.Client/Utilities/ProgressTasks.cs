using System.Globalization;
using System.IO;
using System.Text;

namespace Peel.Windows.Client.Utilities;

internal sealed class ProgressCapture
{
    internal const int MaximumLogBytes = 2 * 1024 * 1024, MaximumLineBytes = 16 * 1024;
    private readonly object gate = new();
    private readonly MemoryStream log = new();
    private readonly byte[] line = new byte[MaximumLineBytes];
    private int lineLength;
    private bool discarding, truncated;
    private int? percent;
    internal int? Percent { get { lock (gate) return percent; } }
    internal int LogBytes { get { lock (gate) return (int)log.Length; } }
    internal void Consume(ReadOnlySpan<byte> data, bool stdout)
    {
        lock (gate)
        {
            int retained = Math.Min(data.Length, MaximumLogBytes - (int)log.Length);
            log.Write(data[..retained]); truncated |= retained < data.Length;
            if (!stdout) return;
            foreach (byte value in data)
            {
                if (value == 10) { CompleteLine(); continue; }
                if (discarding) continue;
                if (lineLength < line.Length) line[lineLength++] = value;
                else { lineLength = 0; discarding = true; }
            }
        }
    }
    internal void EndOutput() { lock (gate) CompleteLine(); }
    private void CompleteLine()
    {
        if (!discarding && Parse(Encoding.UTF8.GetString(line.AsSpan(0, lineLength))) is { } value) percent = value;
        lineLength = 0; discarding = false;
    }
    internal string Text(bool tail = true)
    {
        lock (gate)
        {
            var bytes = log.GetBuffer().AsSpan(0, (int)log.Length);
            return (tail && bytes.Length > MaximumLineBytes ? "[Showing the end of retained output]\n" : "") +
                Encoding.UTF8.GetString(tail && bytes.Length > MaximumLineBytes ? bytes[^MaximumLineBytes..] : bytes) +
                (truncated ? "\n[Output retention stopped at 2 MiB; command output continues to be drained.]" : "");
        }
    }
    internal static int? Parse(string line)
    {
        const string prefix = "SIDEPULSE_PROGRESS=";
        if (line.EndsWith('\r')) line = line[..^1];
        if (!line.StartsWith(prefix, StringComparison.Ordinal)) return null;
        var value = line.AsSpan(prefix.Length);
        return value.Length is >= 1 and <= 3 && value.IndexOfAnyExcept("0123456789") < 0 && int.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out int parsed) && parsed <= 100 ? parsed : null;
    }
}

internal sealed record ProgressSnapshot(string Phase, string Title, int? Percent, int? ExitCode, string Detail, bool Owned)
{
    internal static readonly ProgressSnapshot Idle = new("idle", "", null, null, "Run a command or watch an existing process.", false);
}
internal sealed class ProgressTasks : IAsyncDisposable
{
    private readonly object gate = new();
    private Generation? current;
    private bool disposed;
    private sealed class Generation(string title, bool owned)
    {
        internal readonly CancellationTokenSource Cancel = new();
        internal readonly ProgressCapture Capture = new();
        internal ProgressSnapshot State = new("running", title, null, null, "Starting…", owned);
        internal Task Worker = Task.CompletedTask;
    }
    internal ProgressSnapshot Snapshot { get { lock (gate) return current is { } g ? g.State with { Percent = g.Capture.Percent } : ProgressSnapshot.Idle; } }
    internal string Output(bool tail = true) { lock (gate) return current?.Capture.Text(tail) ?? ""; }
    internal bool Running { get { lock (gate) return current is { Worker.IsCompleted: false }; } }
    internal void Run(string command, string directory) => Start(command.Length > 160 ? command[..160] + "…" : command, true, token => ProgressProcess.Start(command, directory, token));
    internal void Watch(int id, long? expectedStart = null) => Start("Process " + id, false, token => { token.ThrowIfCancellationRequested(); return ProgressProcess.Watch(id, expectedStart); });
    private void Start(string title, bool owned, Func<CancellationToken, ProgressProcess> launch)
    {
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (current is { Worker.IsCompleted: false }) throw new InvalidOperationException("A progress task is already running.");
            current?.Cancel.Dispose();
            var next = new Generation(title, owned); current = next;
            next.Worker = Task.Run(() => RunAsync(next, launch));
        }
    }
    internal void Cancel() { lock (gate) current?.Cancel.Cancel(); }
    internal void Clear()
    {
        lock (gate)
        {
            if (current is { Worker.IsCompleted: false }) { current.Cancel.Cancel(); return; }
            current?.Cancel.Dispose(); current = null;
        }
    }
    internal Task Completion { get { lock (gate) return current?.Worker ?? Task.CompletedTask; } }
    private async Task RunAsync(Generation generation, Func<CancellationToken, ProgressProcess> launch)
    {
        ProgressProcess? process = null;
        using var readLifetime = new CancellationTokenSource();
        Task output = Task.CompletedTask, error = Task.CompletedTask;
        string phase = "failed", detail = "Command did not start."; int? exit = null;
        try
        {
            process = launch(generation.Cancel.Token);
            if (process.Output is { } stdout) output = DrainAsync(stdout, true, generation.Capture, readLifetime.Token);
            if (process.Error is { } stderr) error = DrainAsync(stderr, false, generation.Capture, readLifetime.Token);
            lock (gate) if (ReferenceEquals(current, generation)) generation.State = generation.State with { Detail = generation.State.Owned ? $"Running · PID {process.Id}" : $"Watching PID {process.Id} · cancel leaves the process running" };
            while (!process.Exited) await Task.Delay(100, generation.Cancel.Token).ConfigureAwait(false);
            exit = process.ExitCode; phase = exit == 0 ? "completed" : "failed"; detail = $"Process exited with status {exit}.";
        }
        catch (OperationCanceledException) { phase = "cancelled"; detail = generation.State.Owned ? "Command canceled." : "Watch canceled; the process was left running."; }
        catch (Exception e) when (e is IOException or ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception or UnauthorizedAccessException)
        { detail = e.Message; }
        finally
        {
            if (process is not null)
            {
                try { await process.TerminateOwnedAsync().ConfigureAwait(false); }
                catch (Exception e) when (e is IOException or System.ComponentModel.Win32Exception) { phase = "failed"; detail = "Cleanup could not be confirmed: " + e.Message; }
            }
            readLifetime.CancelAfter(TimeSpan.FromMilliseconds(500));
            try { await Task.WhenAll(output, error).ConfigureAwait(false); }
            catch (Exception e) when (e is IOException or OperationCanceledException or ObjectDisposedException) { }
            process?.Dispose();
            lock (gate) if (ReferenceEquals(current, generation)) generation.State = generation.State with { Phase = phase, Detail = detail, ExitCode = exit };
        }
    }
    private static async Task DrainAsync(Stream stream, bool stdout, ProgressCapture capture, CancellationToken token)
    {
        byte[] chunk = new byte[8192];
        try { int read; while ((read = await stream.ReadAsync(chunk, token).ConfigureAwait(false)) > 0) capture.Consume(chunk.AsSpan(0, read), stdout); }
        finally { if (stdout) capture.EndOutput(); }
    }
    public async ValueTask DisposeAsync()
    {
        Task worker;
        lock (gate) { disposed = true; current?.Cancel.Cancel(); worker = current?.Worker ?? Task.CompletedTask; }
        await worker.ConfigureAwait(false);
        lock (gate) { current?.Cancel.Dispose(); current = null; }
    }
}
