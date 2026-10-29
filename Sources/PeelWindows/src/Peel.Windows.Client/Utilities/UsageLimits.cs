using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;

namespace Peel.Windows.Client.Utilities;

public sealed record UsageWindow(string Provider, string Label, double UsedPercent, DateTimeOffset? ResetsAt,
    DateTimeOffset SampledAt, string Source, string WindowId = "")
{
    public string Id => string.IsNullOrEmpty(WindowId) ? Provider + ":" + Label : WindowId;
    public string SampledLabel => SampledAt.ToLocalTime().ToString("g");
    public double RemainingPercent => Math.Clamp(100 - UsedPercent, 0, 100);
    public string RemainingLabel => $"{RemainingPercent:F0}% remaining";
    public string ResetLabel => ResetsAt is { } reset ? $"Resets {reset.ToLocalTime():ddd h:mm tt}" : "Reset unavailable";
}

/// <summary>Read-only account allowance RPC, matching the Mac usage helper's supported CLI path.</summary>
public sealed class CodexUsageProvider
{
    public async Task<IReadOnlyList<UsageWindow>> ReadAsync(CancellationToken token)
    {
        string executable = ResolveExecutable() ?? throw new InvalidOperationException("Install or open Codex and sign in to read its usage limits.");
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(TimeSpan.FromSeconds(20));
        using var process = new Process { StartInfo = new ProcessStartInfo(executable)
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true,
            RedirectStandardOutput = true, RedirectStandardError = true,
        }};
        foreach (string argument in new[] { "-s", "read-only", "-a", "never", "app-server" }) process.StartInfo.ArgumentList.Add(argument);
        if (!process.Start()) throw new InvalidOperationException("The Codex usage helper could not start.");
        // Drain but never persist or expose helper diagnostics, which can include account metadata.
        Task stderr = DrainAsync(process.StandardError, deadline.Token);
        try
        {
            await process.StandardInput.WriteLineAsync("{\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"peel_usage\",\"version\":\"1.0\"}}}".AsMemory(), deadline.Token);
            _ = await ReadResponseAsync(process.StandardOutput, 1, deadline.Token);
            await process.StandardInput.WriteLineAsync("{\"method\":\"initialized\"}".AsMemory(), deadline.Token);
            await process.StandardInput.WriteLineAsync("{\"id\":2,\"method\":\"account/rateLimits/read\"}".AsMemory(), deadline.Token);
            var response = await ReadResponseAsync(process.StandardOutput, 2, deadline.Token);
            return Parse(response, DateTimeOffset.UtcNow);
        }
        finally
        {
            process.StandardInput.Close();
            using var shutdown = new CancellationTokenSource(TimeSpan.FromSeconds(2));
            try { await process.WaitForExitAsync(shutdown.Token); }
            catch (OperationCanceledException) { if (!process.HasExited) process.Kill(entireProcessTree: true); }
            deadline.Cancel();
            try { await stderr; } catch (OperationCanceledException) { }
        }
    }

    public static IReadOnlyList<UsageWindow> Parse(JsonElement result, DateTimeOffset sampledAt)
    {
        var rows = new List<UsageWindow>();
        if (result.TryGetProperty("rateLimitsByLimitId", out var buckets) && buckets.ValueKind == JsonValueKind.Object)
        {
            foreach (var bucket in buckets.EnumerateObject().Take(64)) AddBucket(bucket.Value, bucket.Name);
        }
        if (rows.Count == 0 && result.TryGetProperty("rateLimits", out var legacy)) AddBucket(legacy, "Codex");
        if (rows.Count == 0) throw new InvalidDataException("Codex returned no available allowance windows.");
        return rows;

        void AddBucket(JsonElement bucket, string name)
        {
            if (bucket.ValueKind != JsonValueKind.Object) return;
            string bucketId = name;
            if (bucket.TryGetProperty("limitName", out var label) && label.ValueKind == JsonValueKind.String) name = label.GetString() ?? name;
            if (name.Length > 100) name = name[..100];
            foreach (var key in new[] { "primary", "secondary" })
            {
                if (!bucket.TryGetProperty(key, out var window) || window.ValueKind != JsonValueKind.Object ||
                    !window.TryGetProperty("usedPercent", out var used) || used.ValueKind != JsonValueKind.Number || !used.TryGetDouble(out double percent) || !double.IsFinite(percent)) continue;
                string durationLabel = key == "primary" ? "Primary" : "Weekly";
                if (window.TryGetProperty("windowDurationMins", out var duration) && duration.ValueKind == JsonValueKind.Number && duration.TryGetInt64(out long minutes) && minutes > 0)
                    durationLabel = minutes >= 1440 ? $"{minutes / 1440.0:g} day" : minutes >= 60 ? $"{minutes / 60.0:g} hour" : $"{minutes} minute";
                DateTimeOffset? reset = null;
                if (window.TryGetProperty("resetsAt", out var resetValue) && resetValue.ValueKind == JsonValueKind.Number && resetValue.TryGetInt64(out long unix) && unix is >= 0 and <= 253402300799)
                    reset = DateTimeOffset.FromUnixTimeSeconds(unix);
                rows.Add(new("Codex", $"{name} · {durationLabel}", Math.Clamp(percent, 0, 100), reset, sampledAt, "Local Codex account", $"codex:{bucketId}:{key}"));
            }
        }
    }

    private static string? ResolveExecutable()
    {
        string? path = Environment.GetEnvironmentVariable("PATH");
        foreach (var folder in (path ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            string candidate = Path.Combine(folder.Trim('"'), "codex.exe");
            if (Path.IsPathFullyQualified(candidate) && File.Exists(candidate)) return candidate;
        }
        string installed = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "OpenAI", "Codex", "bin", "codex.exe");
        return File.Exists(installed) ? installed : null;
    }

    private static async Task<JsonElement> ReadResponseAsync(StreamReader reader, int id, CancellationToken token)
    {
        for (int i = 0; i < 128; i++)
        {
            string line = await ReadBoundedLineAsync(reader, token);
            using var doc = JsonDocument.Parse(line, new JsonDocumentOptions { MaxDepth = 32 });
            var root = doc.RootElement;
            if (!root.TryGetProperty("id", out var value) || value.ValueKind != JsonValueKind.Number || !value.TryGetInt32(out int received) || received != id) continue;
            if (root.TryGetProperty("error", out _)) throw new InvalidOperationException("Codex could not read allowance data. Check its account sign-in.");
            if (!root.TryGetProperty("result", out var result)) throw new InvalidDataException("The usage helper returned an invalid response.");
            return result.Clone();
        }
        throw new InvalidDataException("The usage helper exceeded its response limit.");
    }

    internal static async Task<string> ReadBoundedLineAsync(StreamReader reader, CancellationToken token)
    {
        var line = new StringBuilder();
        var buffer = new char[1];
        while (line.Length <= 1024 * 1024)
        {
            if (await reader.ReadAsync(buffer.AsMemory(), token) == 0) throw new EndOfStreamException("The usage helper closed its output.");
            if (buffer[0] == '\n') return line.ToString();
            line.Append(buffer[0]);
        }
        throw new InvalidDataException("The usage response exceeded 1 MiB.");
    }
    private static async Task DrainAsync(StreamReader reader, CancellationToken token)
    {
        var buffer = new char[4096];
        while (await reader.ReadAsync(buffer.AsMemory(), token) > 0) { }
    }
}
