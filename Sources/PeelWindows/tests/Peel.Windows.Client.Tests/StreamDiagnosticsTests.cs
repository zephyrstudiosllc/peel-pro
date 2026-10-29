using Peel.Windows.Host.Diagnostics;
using Peel.Windows.Protocol;

namespace Peel.Windows.Client.Tests;
internal static partial class Program
{
    private static async Task<int> NativeClientDiagnosticsAsync()
    {
        StreamDiagnostics.Shared.SetEnabled(true);
        try
        {
            int result = await NativeClientReceiveSmokeAsync(true, true);
            var row = StreamDiagnostics.Shared.Snapshot().Streams.Single(s => s.Role == "client");
            True(row.Stages.Single(s => s.Stage == "Received").TotalEvents >= 10, "Native TLS frames must be counted.");
            True(row.Stages.Single(s => s.Stage == "Decoded").TotalEvents >= 10, "Native decoded outputs must be counted.");
            Equal(1L, row.Stages.Single(s => s.Stage == "Presented").TotalEvents);
            True(!row.Active, "Stopped decoder generation must be retired.");
            Console.WriteLine("PASS native 5K TLS/GPU/WPF diagnostics: actual receive/decode counts and one accepted compositor update, not scanout FPS.");
            return result;
        }
        finally { StreamDiagnostics.Shared.SetEnabled(false); }
    }

    private static async Task<int> NativePeerDiagnosticsAsync()
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(25));
        var transport = new Peel.Windows.Transport.BouncyCastlePskTransportFactory();
        await using var listener = await transport.ListenAsync(new(System.Net.IPAddress.Loopback, 0), new NativeStatusKeys(), timeout.Token);
        var endpoint = (System.Net.IPEndPoint)listener.LocalEndPoint;
        StreamDiagnostics.Shared.SetEnabled(true);
        try
        {
            foreach (string scenario in new[] { "valid", "no-negotiation", "malformed", "oversized", "partial-cancel", "invalid-range" })
            {
                await using var host = new Peel.Windows.Host.Networking.HostControlSessionManager(new Peel.Windows.Host.Networking.HostControlSessionOptions("Diagnostic fixture", capabilities: [ClientStreamMetricsMessage.Capability]));
                using var sessionStop = CancellationTokenSource.CreateLinkedTokenSource(timeout.Token);
                var serving = Task.Run(async () => await host.RunAuthenticatedSessionAsync(await listener.AcceptAsync(timeout.Token), sessionStop.Token));
                await using var client = await transport.ConnectAsync(new("127.0.0.1", endpoint.Port), new(Fixture.PairingId, Fixture.Key), timeout.Token);
                await client.WriteAsync(PeelJson.SerializeLine(PeelHello.CreateClient(Fixture.PairingId, "Diagnostics fixture", "Windows", "fixture-device",
                    capabilities: scenario == "no-negotiation" ? [] : [ClientStreamMetricsMessage.Capability])), timeout.Token);
                _ = await LocalAgentProtocol.ReadLineAsync(client, timeout.Token);
                var message = new ClientStreamMetricsMessage(1, 12345, [new(7, Guid.NewGuid().ToString(), "displayLayer", 5120, 2880, 100, 20000)]);
                byte[] bytes = scenario switch
                {
                    "malformed" => "{broken}\n"u8.ToArray(), "oversized" => Enumerable.Repeat((byte)'a', 65537).ToArray(),
                    "partial-cancel" => "{\"type\":\"clientStreamMetrics\""u8.ToArray(),
                    "invalid-range" => PeelJson.SerializeLine(message with { Streams = [message.Streams[0] with { QueuedBytes = -1 }] }),
                    _ => PeelJson.SerializeLine(message),
                };
                await client.WriteAsync(bytes, timeout.Token);
                if (scenario == "valid")
                {
                    await WaitUntilAsync(() => StreamDiagnostics.Shared.Snapshot().PeerReceiver.Report is not null);
                    Equal(100L, StreamDiagnostics.Shared.Snapshot().PeerReceiver.Report!.Streams[0].ReceivedFrames);
                    await client.WriteAsync(PeelJson.SerializeLine(message with { Sequence = 2 }), timeout.Token);
                    await Task.Delay(40, timeout.Token); Equal(1UL, StreamDiagnostics.Shared.Snapshot().PeerReceiver.Report!.Sequence);
                    await client.WriteAsync(PeelJson.SerializeLine(new ClientVisibilityMessage(false)), timeout.Token);
                    await WaitUntilAsync(() => StreamDiagnostics.Shared.Snapshot().PeerReceiver.Report is null);
                }
                else { await Task.Delay(40, timeout.Token); True(StreamDiagnostics.Shared.Snapshot().PeerReceiver.Report is null, scenario); }
                sessionStop.Cancel(); await serving.WaitAsync(timeout.Token);
            }
            Console.WriteLine("PASS real TLS receiver diagnostics: negotiated Apple fields, cadence, hidden-state purge, malformed/oversized/range rejection and partial-read cancellation.");
            return 0;
        }
        finally { StreamDiagnostics.Shared.SetEnabled(false); }
    }
    private static void StreamDiagnosticsOwnership()
    {
        double now = 0; var diagnostics = new StreamDiagnostics(() => now);
        using var first = diagnostics.Begin("host", 1, "Hevc")!;
        first.Record(StreamStage.Encoded, 100); True(diagnostics.Snapshot().Streams.Count == 0, "Diagnostics start off.");
        diagnostics.SetEnabled(true);
        for (int i = 1; i <= 100; i++) { now = i / 20d; first.Record(StreamStage.Encoded, 1000, i / 10d); }
        var measured = diagnostics.Snapshot().Streams.Single().Stages.Single();
        Equal(100L, measured.TotalEvents); Equal(20d, measured.EventsPerSecond); Equal(100000L, measured.TotalBytes); Equal(9.5, measured.P95CallMilliseconds!.Value);
        first.Dispose(); first.Record(StreamStage.Encoded, 99); Equal(100L, diagnostics.Snapshot().Streams.Single().Stages.Single().TotalEvents);
        using var second = diagnostics.Begin("client", 1, "Hevc")!;
        second.Record(StreamStage.Received, 10); Equal(2, diagnostics.Snapshot().Streams.Count);
        Guid peer = Guid.NewGuid(); diagnostics.SetPeerSession(peer, true);
        var report = new ClientStreamMetricsMessage(1, 999, []);
        True(diagnostics.AcceptPeer(peer, report), "Current negotiated report must be retained.");
        True(!diagnostics.AcceptPeer(peer, report with { Sequence = 2 }), "Reports are capped at one per second.");
        now += 1; True(!diagnostics.AcceptPeer(peer, report), "Sequence replay must be rejected.");
        True(diagnostics.AcceptPeer(peer, report with { Sequence = 2 }), "Fresh report advances sequence.");
        diagnostics.ClearPeer(peer); True(diagnostics.Snapshot().PeerReceiver.Stale, "Hidden clients lose cached observations.");
        True(!diagnostics.AcceptPeer(peer, report with { Sequence = 2 }), "Hiding does not reset replay protection.");
        var replacement = Guid.NewGuid(); diagnostics.SetPeerSession(replacement, true); diagnostics.ClearPeer(peer, true);
        True(!diagnostics.AcceptPeer(peer, report), "Old connection cannot publish after replacement.");
        True(diagnostics.AcceptPeer(replacement, report), "Replacement has its own sequence space.");
        now += 11; True(diagnostics.Snapshot().PeerReceiver.Stale, "Old reported health is stale.");
        diagnostics.SetEnabled(false); True(diagnostics.Snapshot().PeerReceiver.Report is null, "Turning off purges peer telemetry.");
        diagnostics.SetEnabled(true); Equal(0, diagnostics.Snapshot().Streams.SelectMany(s => s.Stages).Count());
        var leases = new List<StreamDiagnostics.Lease>();
        for (int i = 0; i < 40; i++) if (diagnostics.Begin("host", (uint)i, "H264") is { } lease) leases.Add(lease);
        True(diagnostics.Snapshot().Streams.Count <= 32, "Active observations are bounded.");
        foreach (var lease in leases) lease.Dispose();
    }
}
