using System.Runtime.InteropServices;
using Peel.Windows.Client.Utilities;

namespace Peel.Windows.Client.Tests;

internal static partial class Program
{
    private static Task UtilityShutdownAsync() => OnStaAsync(() =>
    {
        var model = new CommandCenterViewModel(System.Windows.Threading.Dispatcher.CurrentDispatcher);
        model.Start();
        Thread.Sleep(150); // Let background work queue to this intentionally unpumped dispatcher.
        True(model.DisposeAsync().AsTask().Wait(TimeSpan.FromSeconds(5)), "Shutdown must cancel queued UI mutations.");
    });
    private static void UsageHistoryIsBounded()
    {
        string root = Path.Combine(Path.GetTempPath(), "Peel-history-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var store = new UsageHistoryStore(root);
            store.SavePreferences(new(false, "codex:missing:primary", "Unavailable saved allowance"));
            Equal("codex:missing:primary", store.LoadPreferences().PinnedId);
            var valid = new UsageWindow("Codex", "Test", 25, null, DateTimeOffset.UtcNow, "Fixture", "codex:test:primary");
            _ = store.Append([valid, valid with { UsedPercent = 101 }, valid with { SampledAt = DateTimeOffset.UtcNow.AddDays(-31) }]);
            Equal(1, store.ReadHistory().Count);
            Equal(75.0, store.ReadHistory()[0].RemainingPercent);
            File.WriteAllText(Path.Combine(root, "usage-settings.json"), "{\"PinnedId\":null,\"PinnedLabel\":null}");
            Equal("", store.LoadPreferences().PinnedId);
            File.WriteAllText(Path.Combine(root, "usage-history.json"), "{broken"); Equal(0, store.ReadHistory().Count);
        }
        finally { Directory.Delete(root, true); }
    }

    private static void LocalHistoryIsReadOnly()
    {
        string root = Path.Combine(Path.GetTempPath(), "Peel-sqlite-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            string path = Path.Combine(root, "state_5.sqlite");
            Equal(0, sqlite_test_open(path, out nint database, 6, 0));
            try
            {
                Equal(0, sqlite_test_exec(database, "CREATE TABLE threads(id TEXT,title TEXT,cwd TEXT,updated_at INTEGER,tokens_used INTEGER,archived INTEGER);" +
                    "INSERT INTO threads VALUES('01234567-89ab-cdef-0123-456789abcdef','Test chat','C:\\Fixture\\Project',1791150000,1234,0);" +
                    "INSERT INTO threads VALUES('not-a-guid','Discarded','C:\\Fixture',1791150001,0,0);", 0, 0, 0));
            }
            finally { Equal(0, sqlite_test_close(database)); }
            byte[] before = File.ReadAllBytes(path);
            var rows = LocalAgentHistory.Read(CancellationToken.None, root);
            Equal(1, rows.Count); Equal("Test chat", rows[0].Title); Equal("Project", rows[0].Project);
            Equal<long?>(1234, rows[0].RecordedTokens); Equal("", rows[0].Model); Equal("Recorded", rows[0].State);
            SequenceEqual(before, File.ReadAllBytes(path));
            using var canceled = new CancellationTokenSource(); canceled.Cancel();
            Throws<OperationCanceledException>(() => LocalAgentHistory.Read(canceled.Token, root));
        }
        finally { Directory.Delete(root, true); }
    }
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_open_v2", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite_test_open([MarshalAs(UnmanagedType.LPUTF8Str)] string path, out nint database, int flags, nint vfs);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_exec", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite_test_exec(nint database, [MarshalAs(UnmanagedType.LPUTF8Str)] string sql, nint callback, nint arg, nint error);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_close", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite_test_close(nint database);
}
