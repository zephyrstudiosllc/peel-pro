using System.IO;
using System.Runtime.InteropServices;

namespace Peel.Windows.Client.Utilities;

public sealed record AgentHistoryEntry(string Id, string Title, string Project, DateTimeOffset UpdatedAt,
    long? RecordedTokens, string Model, bool Archived)
{
    public string UpdatedLabel => UpdatedAt.ToLocalTime().ToString("g");
    public string TokensLabel => RecordedTokens?.ToString("N0") ?? "Unavailable";
    public string State => Archived ? "Archived" : "Recorded";
}

/// <summary>Read-only, bounded metadata queries using Windows' built-in SQLite. Never reads chat bodies or credentials.</summary>
public static class LocalAgentHistory
{
    public static IReadOnlyList<AgentHistoryEntry> Read(CancellationToken token, string? root = null)
    {
        token.ThrowIfCancellationRequested();
        root ??= Environment.GetEnvironmentVariable("CODEX_SQLITE_HOME") ?? Environment.GetEnvironmentVariable("CODEX_HOME")
            ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
        if (!Path.IsPathFullyQualified(root) || !Directory.Exists(root)) throw new InvalidOperationException("Local Codex history is unavailable.");
        string? path = Directory.EnumerateFiles(root, "state_*.sqlite", SearchOption.TopDirectoryOnly)
            .Select(p => (Path: p, Version: int.TryParse(Path.GetFileNameWithoutExtension(p).AsSpan(6), out int n) ? n : -1))
            .Where(p => p.Version >= 0)
            .OrderByDescending(p => p.Version).Select(p => p.Path).FirstOrDefault();
        if (path is null) throw new InvalidOperationException("No local Codex chat catalog was found.");
        int opened = sqlite3_open_v2(path, out nint database, 1, 0); // SQLITE_OPEN_READONLY; never CREATE/READWRITE.
        if (opened != 0) { if (database != 0) _ = sqlite3_close(database); throw new IOException("The local chat catalog could not be opened read-only."); }
        try
        {
            _ = sqlite3_busy_timeout(database, 100);
            using var interrupt = token.Register(() => sqlite3_interrupt(database));
            string[] queries = [
                "SELECT id,substr(title,1,256),substr(cwd,1,1024),updated_at,tokens_used,substr(coalesce(model,''),1,100),archived FROM threads ORDER BY updated_at DESC LIMIT 128",
                "SELECT id,substr(title,1,256),substr(cwd,1,1024),updated_at,tokens_used,'',archived FROM threads ORDER BY updated_at DESC LIMIT 128"
            ];
            nint statement = 0;
            foreach (string query in queries)
            {
                if (sqlite3_prepare_v2(database, query, -1, out statement, 0) == 0) break;
                if (statement != 0) _ = sqlite3_finalize(statement); statement = 0;
            }
            if (statement == 0) throw new InvalidOperationException("This local chat catalog version is not supported yet.");
            try
            {
                var entries = new List<AgentHistoryEntry>(); int result;
                while ((result = sqlite3_step(statement)) == 100 && entries.Count < 128)
                {
                    token.ThrowIfCancellationRequested();
                    string id = Text(statement, 0, 128); if (!Guid.TryParse(id, out _)) continue;
                    long updated = sqlite3_column_int64(statement, 3), tokens = sqlite3_column_int64(statement, 4);
                    if (updated is < 0 or > 253402300799) continue;
                    string project = Path.GetFileName(Text(statement, 2, 4096).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
                    entries.Add(new(id, Text(statement, 1, 1024), project, DateTimeOffset.FromUnixTimeSeconds(updated),
                        sqlite3_column_type(statement, 4) == 1 && tokens is >= 0 and < 1_000_000_000_000 ? tokens : null,
                        Text(statement, 5, 400), sqlite3_column_int64(statement, 6) != 0));
                }
                token.ThrowIfCancellationRequested();
                if (result != 101 && entries.Count < 128) throw new IOException("Local history is busy or unreadable. Try refreshing again.");
                return entries;
            }
            finally { _ = sqlite3_finalize(statement); }
        }
        finally { _ = sqlite3_close(database); }
    }
    private static string Text(nint statement, int column, int maximumBytes)
    {
        int bytes = sqlite3_column_bytes(statement, column);
        if (bytes <= 0 || bytes > maximumBytes) return "";
        return new((Marshal.PtrToStringUTF8(sqlite3_column_text(statement, column), bytes) ?? "").Select(c => char.IsControl(c) ? ' ' : c).ToArray());
    }
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_open_v2([MarshalAs(UnmanagedType.LPUTF8Str)] string path, out nint database, int flags, nint vfs);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_close(nint database);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_busy_timeout(nint database, int ms);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)] private static extern void sqlite3_interrupt(nint database);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_prepare_v2(nint database, [MarshalAs(UnmanagedType.LPUTF8Str)] string sql, int bytes, out nint statement, nint tail);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_step(nint statement);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_finalize(nint statement);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)] private static extern nint sqlite3_column_text(nint statement, int index);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_column_bytes(nint statement, int index);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)] private static extern long sqlite3_column_int64(nint statement, int index);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_column_type(nint statement, int index);
}
