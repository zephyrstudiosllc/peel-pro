using Peel.Windows.Host.Audio;
using Peel.Windows.Host.Diagnostics;
using Peel.Windows.Host.Input;
using Peel.Windows.Host.Networking;
using Peel.Windows.Protocol;
using Peel.Windows.Transport;

namespace Peel.Windows.Host.Tests;

internal static partial class Program
{
    // This explicit runner uses only injected in-memory streams, windows, input,
    // credentials, clocks and capture. It never dispatches a --native-* path.
    private static async Task<int> RunCapabilityRefreshFakeTestsAsync()
    {
        (string Name, Func<Task> Run)[] cases = [
            ("Mac hardware modifier snapshots", MacHeldHardwareKeysAcceptModifierSnapshots),
            ("invalid hardware modifier snapshots", Sync(HardwareModifierSnapshotsRejectNonModifiers)),
            ("held hardware release", HeldHardwareModifiersReleaseOnRevokeAndDisconnect),
            ("silent same-peer refresh", SamePeerHelloRefreshPreservesSessionAndHiddenState),
            ("invalid hello refresh cleanup", HelloRefreshRejectsIdentityAndProtocolChanges),
            ("diagnostics refresh ownership/replay/cadence", Sync(DiagnosticsRefreshRetainsOwnershipAndGuards)),
            ("control refresh bilateral telemetry consent", ControlRefreshUpdatesDiagnosticsConsent),
            ("audio refresh pending/active revocation", AudioRefreshRevokesPendingAndActive),
            ("Machine Status refresh requires fresh proof", MachineStatusRefreshRequiresFreshProof),
            ("old asynchronous status proof cannot cross replacement", OldStatusProofCannotCrossReplacement)];
        int passed = 0;
        foreach (var test in cases)
        {
            try { await test.Run().ConfigureAwait(false); passed++; Console.WriteLine("PASS " + test.Name); }
            catch (Exception e) { Console.Error.WriteLine("FAIL " + test.Name + ": " + e.Message); }
        }
        Console.WriteLine($"{passed}/{cases.Length} isolated fake compatibility tests passed");
        return passed == cases.Length ? 0 : 1;
    }

    private static void DiagnosticsRefreshRetainsOwnershipAndGuards()
    {
        double now = 10;
        var diagnostics = new StreamDiagnostics(() => now);
        diagnostics.SetEnabled(true);
        Guid first = Guid.NewGuid(), next = Guid.NewGuid();
        var report = new ClientStreamMetricsMessage(5, 100, []);
        diagnostics.SetPeerSession(first, true);
        True(diagnostics.AcceptPeer(first, report));
        True(diagnostics.RefreshPeerSession(first, true));
        True(ReferenceEquals(report, diagnostics.Snapshot().PeerReceiver.Report));
        True(diagnostics.RefreshPeerSession(first, false));
        True(diagnostics.Snapshot().PeerReceiver.Report is null);
        True(!diagnostics.AcceptPeer(first, report with { Sequence = 6 }));
        True(diagnostics.RefreshPeerSession(first, true));
        True(!diagnostics.AcceptPeer(first, report)); // Same connection's replay guard.
        True(!diagnostics.AcceptPeer(first, report with { Sequence = 6 })); // Same cadence guard.
        now += 1;
        True(diagnostics.AcceptPeer(first, report with { Sequence = 6 }));
        diagnostics.SetPeerSession(next, true);
        True(diagnostics.AcceptPeer(next, report));
        True(!diagnostics.RefreshPeerSession(first, false));
        True(!diagnostics.RefreshPeerSession(first, true));
        True(diagnostics.Snapshot().PeerReceiver.CapabilityNegotiated);
        True(diagnostics.Snapshot().PeerReceiver.Report?.Sequence == 5);
        diagnostics.ClearPeer(first, end: true);
        now += 1;
        True(diagnostics.AcceptPeer(next, report with { Sequence = 6 }));
        diagnostics.ClearPeer(next, end: true);
        True(!diagnostics.RefreshPeerSession(next, true)); // Ended ownership cannot be rebound.
    }

    private static async Task ControlRefreshUpdatesDiagnosticsConsent()
    {
        StreamDiagnostics.Shared.SetEnabled(true);
        try
        {
            foreach (bool hostAllows in new[] { true, false })
            {
                await using var fixture = new RefreshFixture(new HostControlSessionOptions("Fake Host",
                    capabilities: hostAllows ? [ClientStreamMetricsMessage.Capability] : []));
                await fixture.StartAsync([ClientStreamMetricsMessage.Capability]);
                var report = new ClientStreamMetricsMessage(1, 100, []);
                await fixture.BarrierAsync(report);
                Equal(hostAllows, StreamDiagnostics.Shared.Snapshot().PeerReceiver.Report is not null);
                await fixture.BarrierAsync(fixture.Hello([ClientStreamMetricsMessage.Capability]));
                Equal(hostAllows, StreamDiagnostics.Shared.Snapshot().PeerReceiver.Report is not null);
                await fixture.BarrierAsync(fixture.Hello([]), report with { Sequence = 2 });
                True(!StreamDiagnostics.Shared.Snapshot().PeerReceiver.CapabilityNegotiated);
                True(StreamDiagnostics.Shared.Snapshot().PeerReceiver.Report is null);
                await fixture.BarrierAsync(fixture.Hello([ClientStreamMetricsMessage.Capability]), report);
                Equal(hostAllows, StreamDiagnostics.Shared.Snapshot().PeerReceiver.CapabilityNegotiated);
                True(StreamDiagnostics.Shared.Snapshot().PeerReceiver.Report is null); // No replay on re-add.
                Equal(1, fixture.Count(PeelMessageType.HostHello));
            }
        }
        finally { StreamDiagnostics.Shared.SetEnabled(false); }
    }

    private static async Task AudioRefreshRevokesPendingAndActive()
    {
        const string capability = "mac-system-audio-v1";
        foreach (string phase in new[] { "challenge", "ticket", "active" })
        {
            var capture = new RefreshCapture();
            var sharing = new HostAudioSharing(true, () => capture);
            sharing.SetEnabled(true);
            var keys = new StatusKeys();
            await using var fixture = new RefreshFixture(new HostControlSessionOptions("Fake Host", capabilities: [capability])
                { AudioSharing = sharing, AudioCredentials = keys });
            await fixture.StartAsync([capability]);
            string id = Guid.NewGuid().ToString("D");
            var challenge = await fixture.ReplyAsync<AudioPairingChallengeMessage>(new AudioSessionRequestMessage(id, true), "audioPairingChallenge");
            var proof = new AudioPairingProofMessage(id, fixture.Identity, AudioPairingProof.Make(challenge, keys.Key));
            AudioSessionStateMessage? ready = null;
            Task? attached = null;
            if (phase != "challenge")
            {
                // Unchanged capability must not cancel the pending proof.
                await fixture.BarrierAsync(fixture.Hello([capability]));
                ready = await fixture.ReplyAsync<AudioSessionStateMessage>(proof, "audioSessionState");
                Equal("ready", ready.Status);
                if (phase == "active")
                {
                    var transport = new InteractiveDuplexStream();
                    transport.EnqueueLines(new AudioStreamHelloMessage(id, fixture.Identity, ready.Ticket!));
                    attached = fixture.Manager.RunAuthenticatedAudioSessionAsync(new PeelPskConnection(transport, fixture.Identity), fixture.Token);
                    await WaitForMinimumAsync(() => capture.Started ? 1 : 0, 1, fixture.Token);
                    await fixture.BarrierAsync(fixture.Hello([capability]));
                    True(!capture.Disposed && !attached.IsCompleted);
                }
            }
            await fixture.BarrierAsync(fixture.Hello([])); // Stop is awaited before this barrier.
            if (attached is not null)
            {
                await attached.WaitAsync(fixture.Token);
                True(capture.Disposed);
                Equal(1, capture.DisposeCount);
            }
            int previousReady = fixture.AudioReadyCount;
            await fixture.BarrierAsync(fixture.Hello([capability]), proof);
            Equal(previousReady, fixture.AudioReadyCount); // Late old proof cannot resurrect consent.
            if (ready is not null)
            {
                var late = new InteractiveDuplexStream();
                late.EnqueueLines(new AudioStreamHelloMessage(id, fixture.Identity, ready.Ticket!));
                await fixture.Manager.RunAuthenticatedAudioSessionAsync(new PeelPskConnection(late, fixture.Identity), fixture.Token);
                Equal(0, late.WrittenBytes.Length); // Old ticket cannot reserve capture after re-add.
            }
            var fresh = await fixture.ReplyAsync<AudioPairingChallengeMessage>(
                new AudioSessionRequestMessage(Guid.NewGuid().ToString("D"), true), "audioPairingChallenge");
            var freshReady = await fixture.ReplyAsync<AudioSessionStateMessage>(new AudioPairingProofMessage(
                fresh.RequestId, fixture.Identity, AudioPairingProof.Make(fresh, keys.Key)), "audioSessionState");
            Equal("ready", freshReady.Status);
            Equal(1, fixture.Count(PeelMessageType.HostHello));
        }
    }

    private static async Task MachineStatusRefreshRequiresFreshProof()
    {
        var source = new StatusSource { Enabled = true };
        var keys = new StatusKeys();
        // Reset must preserve the existing request cadence even without wall-clock waits.
        var clock = new StatusClock();
        var state = new HostMachineStatus(source, keys, "fake-status-peer", clock);
        _ = await state.RequestAsync(new(Guid.NewGuid().ToString("D")), true, default);
        state.Reset();
        True(await state.RequestAsync(new(Guid.NewGuid().ToString("D")), true, default) is MachineStatusErrorMessage);
        clock.Advance(2);
        True(await state.RequestAsync(new(Guid.NewGuid().ToString("D")), true, default) is AgentPairingChallengeMessage);

        await using var fixture = new RefreshFixture(new HostControlSessionOptions("Fake Host", capabilities: [PeelCapability.MachineStatus])
            { MachineStatusProvider = source, MachineStatusCredentials = keys });
        await fixture.StartAsync([PeelCapability.MachineStatus]);
        var challenge = await fixture.ReplyAsync<AgentPairingChallengeMessage>(
            new MachineStatusRequestMessage(Guid.NewGuid().ToString("D")), "agentPairingChallenge");
        var proof = new AgentPairingProofMessage(challenge.RequestId, fixture.Identity, AgentPairingProof.Make(challenge, keys.Key));
        await fixture.BarrierAsync(fixture.Hello([PeelCapability.MachineStatus]));
        _ = await fixture.ReplyAsync<MachineStatusMessage>(proof, "machineStatus");
        Equal(1, source.Reads); // Unchanged capabilities retain a pending authorization.
        await fixture.BarrierAsync(fixture.Hello([]), fixture.Hello([PeelCapability.MachineStatus]), proof);
        Equal(1, source.Reads);
        // The production status gate intentionally retains its one-second request cadence.
        await Task.Delay(1100, fixture.Token);
        var fresh = await fixture.ReplyAsync<AgentPairingChallengeMessage>(
            new MachineStatusRequestMessage(Guid.NewGuid().ToString("D")), "agentPairingChallenge");
        True(fresh.RequestId != challenge.RequestId);
        // Old proof against the fresh pending challenge must fail without reading status.
        _ = await fixture.ReplyAsync<MachineStatusErrorMessage>(proof, "machineStatusError");
        Equal(1, source.Reads);
        await Task.Delay(1100, fixture.Token);
        var final = await fixture.ReplyAsync<AgentPairingChallengeMessage>(
            new MachineStatusRequestMessage(Guid.NewGuid().ToString("D")), "agentPairingChallenge");
        _ = await fixture.ReplyAsync<MachineStatusMessage>(new AgentPairingProofMessage(
            final.RequestId, fixture.Identity, AgentPairingProof.Make(final, keys.Key)), "machineStatus");
        Equal(2, source.Reads);
        Equal(1, fixture.Count(PeelMessageType.HostHello));
    }

    private static async Task OldStatusProofCannotCrossReplacement()
    {
        var source = new DeferredRefreshStatus();
        var keys = new StatusKeys();
        await using var fixture = new RefreshFixture(new HostControlSessionOptions("Fake Host", capabilities: [PeelCapability.MachineStatus])
            { MachineStatusProvider = source, MachineStatusCredentials = keys });
        await fixture.StartAsync([PeelCapability.MachineStatus]);
        var challenge = await fixture.ReplyAsync<AgentPairingChallengeMessage>(
            new MachineStatusRequestMessage(Guid.NewGuid().ToString("D")), "agentPairingChallenge");
        fixture.Stream.EnqueueLines(new AgentPairingProofMessage(challenge.RequestId, fixture.Identity,
            AgentPairingProof.Make(challenge, keys.Key)));
        await source.Entered.Task.WaitAsync(fixture.Token);
        long? previous = fixture.Manager.ActiveGeneration;
        var next = new InteractiveDuplexStream();
        Task nextSession = fixture.Manager.RunAuthenticatedSessionAsync(new PeelPskConnection(next, fixture.Identity));
        next.EnqueueLines(fixture.Hello([PeelCapability.MachineStatus]),
            new MachineStatusRequestMessage(Guid.NewGuid().ToString("D")));
        await WaitForMinimumAsync(() => ReadOutputLines(next.WrittenBytes).Count, 2, fixture.Token);
        True(fixture.Manager.ActiveGeneration != previous);
        True(ReadOutputLines(next.WrittenBytes).Select(line => PeelJson.ReadEnvelope(line)).Any(e => e.Type == "agentPairingChallenge"));
        source.Complete();
        await fixture.Session.WaitAsync(fixture.Token);
        True(!ReadOutputLines(fixture.Stream.WrittenBytes).Any(line => PeelJson.ReadEnvelope(line).Type == "machineStatus"));
        True(!ReadOutputLines(next.WrittenBytes).Any(line => PeelJson.ReadEnvelope(line).Type == "machineStatus"));
        next.CompleteInput();
        await nextSession.WaitAsync(fixture.Token);
    }

    private sealed class DeferredRefreshStatus : IHostMachineStatusProvider
    {
        internal TaskCompletionSource Entered { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource<MachineStatusMessage> result = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private string? requestId;
        public bool Enabled => true;
        public ValueTask<MachineStatusMessage> ReadAsync(string id, CancellationToken token)
        { requestId = id; Entered.TrySetResult(); return new(result.Task); } // Deliberately ignores cancellation to test stale-result suppression.
        internal void Complete() => result.TrySetResult(new(requestId ?? throw new InvalidOperationException("No status request is pending."), 1, "Fake PC"));
    }

    private sealed class RefreshCapture : IHostAudioCapture
    {
        private readonly TaskCompletionSource completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private int started, disposed;
        internal bool Started => Volatile.Read(ref started) != 0;
        internal bool Disposed => Volatile.Read(ref disposed) != 0;
        internal int DisposeCount => Volatile.Read(ref disposed);
        public Task Completion => completion.Task;
        public ValueTask StartAsync(Action<AudioPacket> offer, CancellationToken token)
        { Interlocked.Exchange(ref started, 1); return ValueTask.CompletedTask; }
        public ValueTask DisposeAsync()
        { Interlocked.Increment(ref disposed); completion.TrySetResult(); return ValueTask.CompletedTask; }
    }

    private sealed class RefreshFixture : IAsyncDisposable
    {
        internal const string Peer = "refresh-policy-peer";
        private readonly CancellationTokenSource timeout = new(TimeSpan.FromSeconds(12));
        private int focusReplies;
        internal string Identity => Peer;
        internal CancellationToken Token => timeout.Token;
        internal InteractiveDuplexStream Stream { get; } = new();
        internal HostControlSessionManager Manager { get; }
        internal Task Session { get; }
        internal RefreshFixture(HostControlSessionOptions options)
        {
            var window = CreateVideoWindow();
            var gate = new InputPermissionGate();
            var input = new DelegateHostInputSessionFactory(() => new WindowsHostInputSession(gate,
                new RecordingWindowInputTargetResolver(window.Bounds), new RecordingInputInjector()));
            Manager = new(new FakeWindowEnumerator([window]), input, options);
            Session = Manager.RunAuthenticatedSessionAsync(new PeelPskConnection(Stream, Identity));
        }
        internal ClientHelloMessage Hello(IReadOnlyList<string> capabilities) =>
            PeelHello.CreateClient(Identity, "Fake Mac", "macOS", capabilities: capabilities);
        internal async Task StartAsync(IReadOnlyList<string> capabilities)
        {
            Stream.EnqueueLines(Hello(capabilities), new PeelRequest(PeelMessageType.RequestWindowList));
            await WaitForMinimumAsync(() => ReadOutputLines(Stream.WrittenBytes).Count, 2, Token);
        }
        internal int Count(string type) => ReadOutputLines(Stream.WrittenBytes).Count(line => PeelJson.ReadEnvelope(line).Type == type);
        internal int AudioReadyCount => ReadOutputLines(Stream.WrittenBytes).Where(line => PeelJson.ReadEnvelope(line).Type == "audioSessionState")
            .Count(line => PeelJson.Deserialize<AudioSessionStateMessage>(line).Status == "ready");
        internal async Task BarrierAsync(params object[] messages)
        {
            focusReplies++;
            Stream.EnqueueLines([.. messages, new ClientActiveWindowMessage(1)]);
            await WaitForMinimumAsync(() => Count(PeelMessageType.WindowFocusState), focusReplies, Token);
        }
        internal async Task<T> ReplyAsync<T>(object message, string type)
        {
            int count = Count(type);
            Stream.EnqueueLines(message);
            await WaitForMinimumAsync(() => Count(type), count + 1, Token);
            return PeelJson.Deserialize<T>(ReadOutputLines(Stream.WrittenBytes).Last(line => PeelJson.ReadEnvelope(line).Type == type));
        }
        public async ValueTask DisposeAsync()
        {
            Stream.CompleteInput();
            await Manager.DisposeAsync();
            await Session.WaitAsync(Token);
            timeout.Dispose();
        }
    }
}
