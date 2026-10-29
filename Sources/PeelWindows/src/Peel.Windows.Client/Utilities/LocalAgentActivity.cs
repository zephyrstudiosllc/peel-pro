using System.Diagnostics;
using System.IO;
using System.Text.Json;

namespace Peel.Windows.Client.Utilities;

public sealed record AgentActivityReading(string Id, string Project, string State, string Tool, DateTimeOffset EventAt)
{
    public string StateLabel => State switch { "working" => "Thinking", "toolRunning" => "Tool running", "waiting" => "Needs input", "completed" => "Done", "error" => "Interrupted / error", _ => "Unknown" };
    public string EventLabel => EventAt.ToLocalTime().ToString("h:mm:ss tt");
    public int Priority => State switch { "error" => 0, "waiting" => 1, "toolRunning" => 2, "working" => 3, "completed" => 4, _ => 5 };
}

/// <summary>Read-only Codex activity fallback. Caches metadata/state, never message or tool text.</summary>
public sealed class LocalAgentActivity
{
    private const int MaximumCandidates = 32, TailBytes = 256 * 1024, MetadataBytes = 64 * 1024;
    private readonly string? root;
    private readonly Dictionary<string, Cached> cache = new(StringComparer.OrdinalIgnoreCase);
    private Dictionary<string, (long Length, DateTime ChangedAt)> observedSizes = new(StringComparer.OrdinalIgnoreCase);
    private sealed record Cached(long Length, DateTime Modified, AgentActivityReading? Reading);
    public LocalAgentActivity(string? codexRoot = null)
    {
        codexRoot ??= Environment.GetEnvironmentVariable("CODEX_HOME") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
        try { if (Path.IsPathFullyQualified(codexRoot)) root = Path.Combine(Path.GetFullPath(codexRoot), "sessions"); }
        catch (ArgumentException) { }
    }
    public IReadOnlyList<AgentActivityReading> Read(CancellationToken token, DateTimeOffset? sampledAt = null)
    {
        token.ThrowIfCancellationRequested(); DateTimeOffset now = sampledAt ?? DateTimeOffset.UtcNow;
        if (root is null || !Directory.Exists(root)) { cache.Clear(); observedSizes.Clear(); return []; }
        var watch = Stopwatch.StartNew(); var files = new List<(FileInfo File, DateTime ChangedAt)>();
        var sizes = new Dictionary<string, (long Length, DateTime ChangedAt)>(StringComparer.OrdinalIgnoreCase);
        var options = new EnumerationOptions { RecurseSubdirectories = true, MaxRecursionDepth = 5, IgnoreInaccessible = true, AttributesToSkip = FileAttributes.ReparsePoint };
        // Search original date folders too: resuming an old chat does not move its transcript.
        foreach (string path in Directory.EnumerateFiles(root, "*.jsonl", options).Take(8192))
        {
            token.ThrowIfCancellationRequested(); if (watch.Elapsed > TimeSpan.FromMilliseconds(500)) break;
            try
            {
                var info = new FileInfo(path);
                long length = info.Length;
                // Windows may defer LastWriteTime until Codex closes its writer. Size changes
                // detect resumed activity even when that open file has an old creation-date folder.
                DateTime changed = observedSizes.TryGetValue(path, out var previous)
                    ? previous.Length != length ? now.UtcDateTime : previous.ChangedAt : info.LastWriteTimeUtc;
                sizes[path] = (length, changed); files.Add((info, changed));
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
        observedSizes = sizes;
        var candidates = files.OrderByDescending(f => f.ChangedAt).Take(MaximumCandidates).Select(f => f.File).ToArray();
        var retained = candidates.Select(f => f.FullName).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (string path in cache.Keys.Where(k => !retained.Contains(k)).ToArray()) cache.Remove(path);
        var readings = new List<AgentActivityReading>();
        foreach (var file in candidates)
        {
            token.ThrowIfCancellationRequested();
            try
            {
                if (!cache.TryGetValue(file.FullName, out var cached) || cached.Length != file.Length || cached.Modified != file.LastWriteTimeUtc)
                {
                    var reading = ReadFile(file.FullName, token);
                    cache[file.FullName] = cached = new(file.Length, file.LastWriteTimeUtc, reading);
                }
                if (cached.Reading is { } row && row.EventAt >= now.AddMinutes(-15) && row.EventAt <= now.AddMinutes(5)) readings.Add(row);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or InvalidOperationException) { cache.Remove(file.FullName); }
        }
        return readings.DistinctBy(r => r.Id).OrderBy(r => r.Priority).ThenByDescending(r => r.EventAt).ToArray();
    }
    private static AgentActivityReading? ReadFile(string path, CancellationToken token)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        long size = stream.Length;
        byte[] first = new byte[(int)Math.Min(MetadataBytes, size)]; int headerLength = ReadBounded(stream, first, token);
        int newline = Array.IndexOf(first, (byte)'\n', 0, headerLength); if (newline < 0) return null;
        using var header = JsonDocument.Parse(first.AsMemory(0, newline), new JsonDocumentOptions { MaxDepth = 32 });
        var record = header.RootElement;
        if (String(record, "type") != "session_meta" || !record.TryGetProperty("payload", out var metadata)) return null;
        string? id = String(metadata, "id") ?? String(metadata, "session_id");
        if (!Guid.TryParseExact(id, "D", out _) || String(metadata, "thread_source") == "subagent" ||
            metadata.TryGetProperty("source", out var source) && source.ValueKind == JsonValueKind.Object && source.TryGetProperty("subagent", out _)) return null;
        string cwd = String(metadata, "cwd") ?? "";
        if (cwd.Length > 1024) cwd = "";
        string project = Path.GetFileName(cwd.TrimEnd('/', '\\')); if (project.Length == 0) project = "Codex";
        project = new string(project.Take(128).Select(c => char.IsControl(c) ? ' ' : c).ToArray());
        long start = Math.Max(0, size - TailBytes); stream.Position = start;
        byte[] tail = new byte[(int)Math.Min(TailBytes, size)]; int length = ReadBounded(stream, tail, token);
        var observation = ParseTail(tail.AsSpan(0, length), start > 0, token);
        return observation is null ? null : new(id!, project, observation.Value.State, observation.Value.Tool, observation.Value.At);
    }
    private static int ReadBounded(Stream stream, byte[] buffer, CancellationToken token)
    {
        int read = 0;
        while (read < buffer.Length) { token.ThrowIfCancellationRequested(); int count = stream.Read(buffer, read, buffer.Length - read); if (count == 0) break; read += count; }
        return read;
    }
    internal static (string State, string Tool, DateTimeOffset At)? ParseTail(ReadOnlySpan<byte> bytes, bool partialStart, CancellationToken token)
    {
        int start = 0;
        if (partialStart) { int first = bytes.IndexOf((byte)'\n'); if (first < 0) return null; start = first + 1; }
        int end = bytes.LastIndexOf((byte)'\n'); if (end < start) return null;
        while (end > start)
        {
            token.ThrowIfCancellationRequested();
            int previous = bytes[start..end].LastIndexOf((byte)'\n'); int lineStart = previous < 0 ? start : start + previous + 1;
            try
            {
                using var document = JsonDocument.Parse(bytes[lineStart..end].ToArray(), new JsonDocumentOptions { MaxDepth = 32 });
                var record = document.RootElement;
                if (record.TryGetProperty("timestamp", out var timestamp) && timestamp.ValueKind == JsonValueKind.String && timestamp.TryGetDateTimeOffset(out var at) &&
                    record.TryGetProperty("payload", out var payload) && payload.ValueKind == JsonValueKind.Object)
                {
                    string? type = String(record, "type"), kind = String(payload, "type");
                    if (type == "event_msg")
                    {
                        string? state = kind switch { "task_started" => "working", "task_complete" => "completed", "turn_aborted" => "error", _ => null };
                        if (state is not null) return (state, "", at);
                    }
                    if (type == "response_item")
                    {
                        if (kind is "custom_tool_call" or "function_call" or "local_shell_call")
                        {
                            string name = String(payload, "name") ?? String(payload, "tool_name") ?? "Tool";
                            bool waiting = name is "request_user_input" or "functions.request_user_input";
                            return (waiting ? "waiting" : "toolRunning", waiting ? "Waiting for you" : FriendlyTool(name), at);
                        }
                        if (kind is "custom_tool_call_output" or "function_call_output" or "local_shell_call_output" or "reasoning") return ("working", "", at);
                        if (kind == "message") return (String(payload, "role") == "assistant" && String(payload, "phase") == "final" ? "completed" : "working", "", at);
                    }
                }
            }
            catch (Exception e) when (e is JsonException or InvalidOperationException) { }
            end = lineStart - 1;
        }
        return null; // No recognized activity is not evidence that a task is working.
    }
    private static string? String(JsonElement value, string key) => value.ValueKind == JsonValueKind.Object && value.TryGetProperty(key, out var item) && item.ValueKind == JsonValueKind.String ? item.GetString() : null;
    private static string FriendlyTool(string name) => name switch
    {
        "exec" or "exec_command" or "functions.exec" => "Command",
        "apply_patch" or "functions.apply_patch" => "Editing code",
        "web__run" => "Web research",
        _ => new string(name.Take(100).Select(c => char.IsControl(c) ? ' ' : c).ToArray()).Replace("__", " · ").Replace('_', ' ')
    };
}
