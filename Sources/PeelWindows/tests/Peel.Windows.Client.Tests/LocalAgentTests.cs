using System.IO.Pipes;
using System.Text.Json;
using System.Windows.Threading;
using Peel.Windows.Client.Services;
using Peel.Windows.Protocol;

namespace Peel.Windows.Client.Tests;
internal static partial class Program
{
    private static async Task<int> NativeLocalAgentBridgeAsync()
    {
        var ready = new TaskCompletionSource<(Dispatcher Dispatcher, LocalAgentBridge Bridge)>(TaskCreationOptions.RunContinuationsAsynchronously);
        string pipeName = "Peel.AgentBridge.Validation." + Guid.NewGuid().ToString("N");
        int allowed = 0;
        var thread = new Thread(() =>
        {
            var dispatcher = Dispatcher.CurrentDispatcher;
            var bridge = new LocalAgentBridge(dispatcher, () => Volatile.Read(ref allowed) == 1,
                () => new { hosting = false, fixture = true }, (_, _) => throw new InvalidOperationException("Notifications are not part of this fixture."), pipeName);
            ready.SetResult((dispatcher, bridge)); Dispatcher.Run();
        });
        thread.SetApartmentState(ApartmentState.STA); thread.Start();
        var context = await ready.Task;
        try
        {
            async Task<JsonElement> Request(string method, object parameters)
            {
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(12));
                await using var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await pipe.ConnectAsync(timeout.Token);
                string id = Guid.NewGuid().ToString("D");
                byte[] bytes = LocalAgentProtocol.EncodeLine(new { version = 1, id, method, @params = parameters });
                // Exercise partial reads, not just one complete JSON write.
                await pipe.WriteAsync(bytes.AsMemory(0, 7), timeout.Token);
                await pipe.WriteAsync(bytes.AsMemory(7), timeout.Token);
                byte[] reply = await LocalAgentProtocol.ReadLineAsync(pipe, timeout.Token) ?? throw new EndOfStreamException();
                using var document = JsonDocument.Parse(reply); Equal(id, document.RootElement.GetProperty("id").GetString());
                return document.RootElement.Clone();
            }
            True((await Request("listDevices", new { })).TryGetProperty("error", out _), "Disabled bridge must disclose no inventory.");
            Volatile.Write(ref allowed, 1);
            var devices = await Request("listDevices", new { });
            Equal("local", devices.GetProperty("result").GetProperty("devices")[0].GetProperty("targetId").GetString());
            var windows = await Request("listWindows", new { targetId = "local" });
            True(windows.GetProperty("result").GetProperty("windows").GetArrayLength() <= 128, "Window inventory must remain bounded.");
            var apps = await Request("listApps", new { targetId = "local", query = "" });
            True(apps.GetProperty("result").GetProperty("apps").GetArrayLength() <= 128, "App inventory must remain bounded.");
            True((await Request("launchApp", new { targetId = "local", appId = "guessed" })).TryGetProperty("error", out _), "Guessed executable IDs must fail before launch.");
            True((await Request("notify", new { targetId = "other", title = "test", message = "test" })).TryGetProperty("error", out _), "Remote targets must remain unavailable.");
            Volatile.Write(ref allowed, 0);
            True((await Request("getStreamDiagnostics", new { })).TryGetProperty("error", out _), "Consent revocation must apply to the next request.");
            Console.WriteLine("PASS native local AgentBridge: current-user pipe, partial messages, disabled/revoked access, bounded inventory, rejected guessed IDs and remote targets.");
            return 0;
        }
        finally
        {
            await context.Bridge.DisposeAsync();
            context.Dispatcher.BeginInvokeShutdown(DispatcherPriority.Send); thread.Join(3000);
        }
    }
}
