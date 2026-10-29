using System.Text;
using System.Text.Json;
using Peel.Windows.Client.Utilities;

namespace Peel.Windows.Client.Tests;
internal static partial class Program
{
    private static void LocalActivityObservations()
    {
        var now = DateTimeOffset.UtcNow;
        string Event(string kind, string type = "event_msg", string? name = null, string? role = null, string? phase = null) =>
            JsonSerializer.Serialize(new { timestamp = now, type, payload = new { type = kind, name, role, phase, content = "PRIVATE_BODY_SENTINEL" } }) + "\n";
        foreach (var (kind, state) in new[] { ("task_started", "working"), ("task_complete", "completed"), ("turn_aborted", "error") })
            Equal(state, LocalAgentActivity.ParseTail(Encoding.UTF8.GetBytes(Event(kind)), false, CancellationToken.None)!.Value.State);
        Equal("waiting", LocalAgentActivity.ParseTail(Encoding.UTF8.GetBytes(Event("function_call", "response_item", "request_user_input")), false, CancellationToken.None)!.Value.State);
        Equal("toolRunning", LocalAgentActivity.ParseTail(Encoding.UTF8.GetBytes(Event("function_call", "response_item", "functions.request_user_input_async")), false, CancellationToken.None)!.Value.State);
        Equal("completed", LocalAgentActivity.ParseTail(Encoding.UTF8.GetBytes(Event("message", "response_item", role: "assistant", phase: "final")), false, CancellationToken.None)!.Value.State);
        Equal("working", LocalAgentActivity.ParseTail(Encoding.UTF8.GetBytes(Event("function_call_output", "response_item")), false, CancellationToken.None)!.Value.State);
        Equal("completed", LocalAgentActivity.ParseTail(Encoding.UTF8.GetBytes("cut partial line\n" + Event("task_complete") + "{partial"), true, CancellationToken.None)!.Value.State);
        True(LocalAgentActivity.ParseTail("partial-only"u8, true, CancellationToken.None) is null, "An incomplete record must not infer working.");
        True(LocalAgentActivity.ParseTail(Encoding.UTF8.GetBytes(Event("unknown")), false, CancellationToken.None) is null, "Unknown records stay unavailable.");
        Equal("working", LocalAgentActivity.ParseTail(Encoding.UTF8.GetBytes(Event("task_started") + "{invalid}\n"), false, CancellationToken.None)!.Value.State);
        using var canceled = new CancellationTokenSource(); canceled.Cancel();
        Throws<OperationCanceledException>(() => LocalAgentActivity.ParseTail(Encoding.UTF8.GetBytes(Event("task_started")), false, canceled.Token));
        string root = Path.Combine(Path.GetTempPath(), "peel-agent-activity-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path.Combine(root, "sessions", "2020", "01", "01"));
        try
        {
            string id = Guid.NewGuid().ToString();
            string path = Path.Combine(root, "sessions", "2020", "01", "01", "rollout.jsonl");
            string header = JsonSerializer.Serialize(new { type = "session_meta", payload = new { id, cwd = @"C:\Projects\Fixture", source = "cli" } }) + "\n";
            File.WriteAllText(path, header + Event("task_started"));
            File.SetLastWriteTimeUtc(path, now.UtcDateTime.AddYears(-2)); // An open Windows writer can leave this stale.
            byte[] before = File.ReadAllBytes(path);
            var reader = new LocalAgentActivity(root); var rows = reader.Read(CancellationToken.None, now.AddSeconds(1));
            Equal(1, rows.Count); Equal("Fixture", rows[0].Project); Equal(id, rows[0].Id); Equal("working", rows[0].State);
            True(!rows[0].ToString().Contains("PRIVATE_BODY_SENTINEL"), "Readings must not retain chat or tool text.");
            SequenceEqual(before, File.ReadAllBytes(path));
            File.AppendAllText(path, Event("task_complete"));
            Equal("completed", reader.Read(CancellationToken.None, now.AddSeconds(2)).Single().State);
            Equal(0, reader.Read(CancellationToken.None, now.AddMinutes(16)).Count);
            // Replacing/truncating a file invalidates the parsed-tail cache.
            File.WriteAllText(path, header + Event("turn_aborted"));
            Equal("error", reader.Read(CancellationToken.None, now.AddSeconds(3)).Single().State);
            File.WriteAllText(path, JsonSerializer.Serialize(new { type = "session_meta", payload = new { id, cwd = "Fixture", source = new { subagent = new { thread_spawn = new { } } } } }) + "\n" + Event("task_started"));
            Equal(0, reader.Read(CancellationToken.None, now.AddSeconds(4)).Count);
            Throws<OperationCanceledException>(() => reader.Read(canceled.Token));
            Equal(0, new LocalAgentActivity("relative-invalid-root").Read(CancellationToken.None).Count);
        }
        finally { Directory.Delete(root, recursive: true); }
    }
}
