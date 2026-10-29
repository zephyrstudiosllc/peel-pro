using System.Collections.Concurrent;
using Peel.Windows.Host.Audio;
using Peel.Windows.Host.Diagnostics;
using Peel.Windows.Host.Input;
using Peel.Windows.Host.Networking;
using Peel.Windows.Host.Runtime;
using Peel.Windows.Host.Windows;
using Peel.Windows.Protocol;
using Peel.Windows.Transport;

namespace Peel.Windows.Host.Tests;

internal static partial class Program
{
    // Explicit fake-only entry point. Production session and native input owner,
    // but every stream, target resolver, injector, credential and capture is fake.
    private static async Task<int> RunReplacementOrderFakeTestsAsync()
    {
        (string Name, Func<Task> Run)[] cases = [
            ("release before replacement HostHello with blocked observer", ReplacementReleaseBeforeHelloWithBlockedObserver),
            ("release and replacement survive blocked audio cleanup", ReplacementDoesNotAwaitAudioCleanup),
            ("A B C startup waits for old native release", ReplacementAbcWaitsForNativeRelease),
            ("in-flight native dispatch finishes before revoke", ReplacementWaitsForInFlightDispatch),
            ("permission recovery finishes before replacement startup", ReplacementWaitsForPermissionRecovery),
            ("late old HostHello cannot restore input or telemetry", ReplacementRejectsLateOldHello),
            ("cancelled waiting startup does not poison transition", ReplacementCancelledWaiter),
            ("cancelled factory is cleaned and next startup works", ReplacementCancelledFactory),
            ("failed factory is cleaned and next startup works", ReplacementFailedFactory),
            ("dispose releases held keys while observer is blocked", ReplacementDisposeIgnoresBlockedObserver),
            ("stop releases input and awake request before audio cleanup", StopReleasesAwakeBeforeAudioCleanup)];
        int passed = 0;
        foreach (var test in cases)
        {
            try { await test.Run().ConfigureAwait(false); passed++; Console.WriteLine("PASS " + test.Name); }
            catch (Exception e) { Console.Error.WriteLine("FAIL " + test.Name + ": " + e); }
        }
        Console.WriteLine($"{passed}/{cases.Length} isolated fake replacement tests passed");
        return passed == cases.Length ? 0 : 1;
    }

    private static async Task ReplacementReleaseBeforeHelloWithBlockedObserver()
    {
        using var observerRelease = new ManualResetEventSlim(false);
        var observerEntered = ReplacementSignal();
        int block = 0;
        await using var rig = new ReplacementRig(stateChanged: () =>
        {
            if (Volatile.Read(ref block) == 0) return;
            observerEntered.TrySetResult();
            observerRelease.Wait(TimeSpan.FromSeconds(10));
        });
        var a = rig.Client("A", hold: true);
        try
        {
            await (await rig.ProbeAsync(0)).Down.Task.WaitAsync(rig.Token);
            Volatile.Write(ref block, 1);
            a.Stream.EnqueueLines(new ClientVisibilityMessage(false));
            await observerEntered.Task.WaitAsync(rig.Token);
            True(rig.Probes[0].Held);
            var b = rig.Client("B", text: true);
            await b.Hello.Task.WaitAsync(rig.Token); // Hook inspects held state at the write itself.
            True(rig.StartupViolations.IsEmpty);
            await (await rig.ProbeAsync(1)).Text.Task.WaitAsync(rig.Token);
            await a.Run.WaitAsync(rig.Token); // Observer remains blocked during cleanup.
            True(rig.Probes[0].Released.Task.IsCompleted);
            True(!observerRelease.IsSet);
            True(rig.StartupViolations.IsEmpty);
        }
        finally { observerRelease.Set(); }
    }

    private static async Task ReplacementDoesNotAwaitAudioCleanup()
    {
        var capture = new ReplacementBlockingCapture();
        var keys = new StatusKeys();
        var sharing = new HostAudioSharing(true, () => capture);
        sharing.SetEnabled(true);
        var options = new HostControlSessionOptions("Fake Host", capabilities: ["mac-system-audio-v1"])
            { AudioSharing = sharing, AudioCredentials = keys };
        await using var rig = new ReplacementRig(options: options);
        var a = rig.Client("A", hold: true, capabilities: ["mac-system-audio-v1"]);
        Task? audio = null;
        try
        {
            await (await rig.ProbeAsync(0)).Down.Task.WaitAsync(rig.Token);
            string id = Guid.NewGuid().ToString("D");
            var challenge = await rig.Reply<AudioPairingChallengeMessage>(a,
                new AudioSessionRequestMessage(id, true), "audioPairingChallenge");
            var ready = await rig.Reply<AudioSessionStateMessage>(a,
                new AudioPairingProofMessage(id, ReplacementRig.Peer, AudioPairingProof.Make(challenge, keys.Key)), "audioSessionState");
            Equal("ready", ready.Status);
            var stream = new InteractiveDuplexStream();
            stream.EnqueueLines(new AudioStreamHelloMessage(id, ReplacementRig.Peer, ready.Ticket!));
            audio = rig.Manager.RunAuthenticatedAudioSessionAsync(new PeelPskConnection(stream, ReplacementRig.Peer), rig.Token);
            await capture.Started.Task.WaitAsync(rig.Token);
            var b = rig.Client("B", text: true);
            await capture.DisposeEntered.Task.WaitAsync(rig.Token);
            await b.Hello.Task.WaitAsync(rig.Token);
            await (await rig.ProbeAsync(1)).Text.Task.WaitAsync(rig.Token);
            True(rig.Probes[0].Released.Task.IsCompleted);
            True(!a.Run.IsCompleted); // Old unrelated media teardown is deliberately blocked.
            True(!capture.AllowDispose.Task.IsCompleted);
            True(rig.StartupViolations.IsEmpty);
        }
        finally
        {
            capture.AllowDispose.TrySetResult();
            if (audio is not null) await audio.WaitAsync(rig.Token);
        }
    }

    private static async Task ReplacementAbcWaitsForNativeRelease()
    {
        using var allowRelease = new ManualResetEventSlim(false);
        await using var rig = new ReplacementRig(onCreate: (index, probe) =>
        { if (index == 0) probe.AllowRelease = allowRelease; });
        var a = rig.Client("A", hold: true);
        try
        {
            await (await rig.ProbeAsync(0)).Down.Task.WaitAsync(rig.Token);
            var b = rig.Client("B", text: true);
            await rig.Probes[0].ReleaseEntered.Task.WaitAsync(rig.Token);
            True(!b.Hello.Task.IsCompleted);
            Equal(2, rig.Probes.Count);
            // RunAuthenticatedSessionAsync reaches transitionGate.WaitAsync BEFORE
            // its first yield. Returning from Client while A release is blocked
            // allows the production pending-admission counter to acknowledge C.
            var c = rig.Client("C", text: true);
            await WaitForMinimumAsync(() => rig.Manager.WaitingTransitionCount, 1, rig.Token);
            Equal(1, rig.Manager.WaitingTransitionCount);
            True(!c.Run.IsCompleted && !c.Hello.Task.IsCompleted);
            Equal(2, rig.Probes.Count); // C factory must not run through the barrier.
            True(rig.Probes[0].Held);
            allowRelease.Set();
            await c.Hello.Task.WaitAsync(rig.Token);
            await (await rig.ProbeAsync(2)).Text.Task.WaitAsync(rig.Token);
            await Task.WhenAll(a.Run, b.Run).WaitAsync(rig.Token);
            True(rig.Probes[0].Released.Task.IsCompleted);
            True(rig.Probes[1].Released.Task.IsCompleted);
            True(rig.StartupViolations.IsEmpty);
        }
        finally { allowRelease.Set(); }
    }

    private static async Task StopReleasesAwakeBeforeAudioCleanup()
    {
        var capture = new ReplacementBlockingCapture();
        var keys = new StatusKeys();
        var sharing = new HostAudioSharing(true, () => capture);
        sharing.SetEnabled(true);
        var options = new HostControlSessionOptions("Fake Host", capabilities: ["mac-system-audio-v1"])
            { AudioSharing = sharing, AudioCredentials = keys };
        var awake = new RecordingHostAwakeController();
        await using var rig = new ReplacementRig(options: options, awakeController: awake);
        using var controlLifetime = new CancellationTokenSource();
        var a = rig.Client("A", hold: true, capabilities: ["mac-system-audio-v1"], cancellation: controlLifetime.Token);
        Task? audio = null, stopping = null;
        try
        {
            var input = await rig.ProbeAsync(0);
            await input.Down.Task.WaitAsync(rig.Token);
            True(await awake.ReadUpdateAsync());
            True(rig.Manager.IsActiveClientVisible && rig.Manager.IsPreventingSleep);
            string id = Guid.NewGuid().ToString("D");
            var challenge = await rig.Reply<AudioPairingChallengeMessage>(a,
                new AudioSessionRequestMessage(id, true), "audioPairingChallenge");
            var ready = await rig.Reply<AudioSessionStateMessage>(a,
                new AudioPairingProofMessage(id, ReplacementRig.Peer, AudioPairingProof.Make(challenge, keys.Key)), "audioSessionState");
            Equal("ready", ready.Status);
            var stream = new InteractiveDuplexStream();
            stream.EnqueueLines(new AudioStreamHelloMessage(id, ReplacementRig.Peer, ready.Ticket!));
            audio = rig.Manager.RunAuthenticatedAudioSessionAsync(new PeelPskConnection(stream, ReplacementRig.Peer), rig.Token);
            await capture.Started.Task.WaitAsync(rig.Token);

            // External cancellation models the listener's linked control token.
            // No listener is instantiated here. Audio disposal stays blocked.
            controlLifetime.Cancel();
            await input.Released.Task.WaitAsync(rig.Token);
            await capture.DisposeEntered.Task.WaitAsync(rig.Token);
            True(!await awake.ReadUpdateAsync());
            True(!input.Held);
            True(!awake.IsHolding && !rig.Manager.IsActiveClientVisible);
            True(!a.Run.IsCompleted && !capture.AllowDispose.Task.IsCompleted);
            True(!awake.IsDisposed); // Cancellation alone has not invoked manager Dispose.

            // Direct manager shutdown must also dispose its power owner BEFORE
            // awaiting that same blocked routed-session/audio completion.
            stopping = rig.Manager.DisposeAsync().AsTask();
            True(awake.IsDisposed && !rig.Manager.IsPreventingSleep);
            True(!stopping.IsCompleted && !a.Run.IsCompleted);
            True(!capture.AllowDispose.Task.IsCompleted);
        }
        finally
        {
            capture.AllowDispose.TrySetResult();
            if (audio is not null) await audio.WaitAsync(rig.Token);
            if (stopping is not null) await stopping.WaitAsync(rig.Token);
            await a.Run.WaitAsync(rig.Token);
        }
    }

    private static async Task ReplacementWaitsForInFlightDispatch()
    {
        using var allowDown = new ManualResetEventSlim(false);
        await using var rig = new ReplacementRig(onCreate: (index, probe) =>
        { if (index == 0) probe.AllowDown = allowDown; });
        var a = rig.Client("A", hold: true);
        try
        {
            await (await rig.ProbeAsync(0)).Down.Task.WaitAsync(rig.Token);
            var b = rig.Client("B", text: true);
            // B is published while A's native operation is blocked before held
            // bookkeeping returns. Its hello cannot pass the native admission gate.
            await WaitForMinimumAsync(() => rig.Manager.ActiveGeneration == 2 ? 1 : 0, 1, rig.Token);
            True(!b.Hello.Task.IsCompleted);
            True(!rig.Probes[0].ReleaseEntered.Task.IsCompleted);
            allowDown.Set();
            await b.Hello.Task.WaitAsync(rig.Token);
            await (await rig.ProbeAsync(1)).Text.Task.WaitAsync(rig.Token);
            await a.Run.WaitAsync(rig.Token);
            True(rig.Probes[0].ReleasedKeyCount == 1);
            True(rig.StartupViolations.IsEmpty);
        }
        finally { allowDown.Set(); }
    }

    private static async Task ReplacementRejectsLateOldHello()
    {
        using var allowOldHello = new ManualResetEventSlim(false);
        var oldHelloEntered = ReplacementSignal();
        StreamDiagnostics.Shared.SetEnabled(true);
        await using var rig = new ReplacementRig(options: new HostControlSessionOptions("Fake Host",
            capabilities: [ClientStreamMetricsMessage.Capability]));
        var a = rig.Client("A", text: true, capabilities: [ClientStreamMetricsMessage.Capability], helloHook: () =>
        { oldHelloEntered.TrySetResult(); allowOldHello.Wait(TimeSpan.FromSeconds(10)); }, ignoreFlushCancellation: true);
        try
        {
            await oldHelloEntered.Task.WaitAsync(rig.Token);
            var b = rig.Client("B", text: true, capabilities: [ClientStreamMetricsMessage.Capability]);
            await (await rig.ProbeAsync(1)).Text.Task.WaitAsync(rig.Token);
            var report = new ClientStreamMetricsMessage(1, 100, []);
            await rig.Reply<WindowFocusStateMessage>(b, report, PeelMessageType.WindowFocusState, addFocus: true);
            True(StreamDiagnostics.Shared.Snapshot().PeerReceiver.Report is not null);
            allowOldHello.Set();
            await a.Run.WaitAsync(rig.Token);
            True(!rig.Probes[0].Text.Task.IsCompleted);
            True(StreamDiagnostics.Shared.Snapshot().PeerReceiver.Report?.Sequence == 1);
            True(rig.Manager.ActiveGeneration == 2);
        }
        finally { allowOldHello.Set(); StreamDiagnostics.Shared.SetEnabled(false); }
    }

    private static async Task ReplacementWaitsForPermissionRecovery()
    {
        using var allowRelease = new ManualResetEventSlim(false);
        await using var rig = new ReplacementRig(onCreate: (index, probe) =>
        { if (index == 0) probe.AllowRelease = allowRelease; });
        _ = rig.Client("A", hold: true);
        Task? permissionOff = null;
        try
        {
            await (await rig.ProbeAsync(0)).Down.Task.WaitAsync(rig.Token);
            permissionOff = Task.Run(() => rig.Consent.SetEnabled(false));
            await rig.Probes[0].ReleaseEntered.Task.WaitAsync(rig.Token);
            // At this point native tracked sets have been cleared, but the fake
            // recovery injector is still blocked before old key-up completion.
            var b = rig.Client("B");
            await WaitForMinimumAsync(() => rig.Manager.ActiveGeneration == 2 ? 1 : 0, 1, rig.Token);
            True(!b.Hello.Task.IsCompleted);
            True(!permissionOff.IsCompleted);
            True(rig.Probes[0].Held);
            allowRelease.Set();
            await permissionOff.WaitAsync(rig.Token);
            await b.Hello.Task.WaitAsync(rig.Token);
            rig.Consent.SetEnabled(true);
            b.Stream.EnqueueLines(new KeyboardHardwareKeyMessage(225, [], WindowId: 1, Action: KeyboardCommandAction.Down));
            await (await rig.ProbeAsync(1)).Down.Task.WaitAsync(rig.Token);
            True(rig.Probes[1].Held); // No delayed old key-up remains after this Down.
            True(rig.Probes[0].ReleasedKeyCount == 1);
            True(rig.StartupViolations.IsEmpty);
        }
        finally
        {
            allowRelease.Set();
            if (permissionOff is not null) await permissionOff.WaitAsync(rig.Token);
        }
    }

    private static async Task ReplacementCancelledWaiter()
    {
        using var allowRelease = new ManualResetEventSlim(false);
        await using var rig = new ReplacementRig(onCreate: (index, probe) =>
        { if (index == 0) probe.AllowRelease = allowRelease; });
        _ = rig.Client("A", hold: true);
        try
        {
            await (await rig.ProbeAsync(0)).Down.Task.WaitAsync(rig.Token);
            var b = rig.Client("B", text: true);
            await rig.Probes[0].ReleaseEntered.Task.WaitAsync(rig.Token);
            using var cancelled = new CancellationTokenSource();
            var c = rig.Client("C", text: true, cancellation: cancelled.Token);
            cancelled.Cancel();
            await ReplacementExpectCancellation(c.Run, rig.Token);
            Equal(2, rig.Probes.Count);
            Equal(0, c.Stream.WrittenBytes.Length);
            allowRelease.Set();
            await b.Hello.Task.WaitAsync(rig.Token);
            var d = rig.Client("D", text: true);
            await d.Hello.Task.WaitAsync(rig.Token);
            await (await rig.ProbeAsync(2)).Text.Task.WaitAsync(rig.Token);
            True(rig.StartupViolations.IsEmpty);
        }
        finally { allowRelease.Set(); }
    }

    private static async Task ReplacementCancelledFactory()
    {
        using var allowFactory = new ManualResetEventSlim(false);
        using var allowCleanup = new ManualResetEventSlim(false);
        var factoryEntered = ReplacementSignal();
        await using var rig = new ReplacementRig(onCreate: (index, probe) =>
        {
            if (index == 0)
            {
                probe.AllowDispose = allowCleanup;
                factoryEntered.TrySetResult();
                allowFactory.Wait(TimeSpan.FromSeconds(10));
            }
        });
        using var cancelled = new CancellationTokenSource();
        var a = rig.Client("A", text: true, cancellation: cancelled.Token);
        try
        {
            await factoryEntered.Task.WaitAsync(rig.Token);
            cancelled.Cancel();
            var b = rig.Client("B", text: true);
            True(!b.Hello.Task.IsCompleted);
            allowFactory.Set();
            await rig.Probes[0].DisposeEntered.Task.WaitAsync(rig.Token);
            await WaitForMinimumAsync(() => rig.Manager.WaitingTransitionCount, 1, rig.Token);
            Equal(1, rig.Probes.Count); // No B factory before A ownership cleanup.
            True(!b.Hello.Task.IsCompleted && !a.Run.IsCompleted);
            allowCleanup.Set();
            await ReplacementExpectCancellation(a.Run, rig.Token);
            await b.Hello.Task.WaitAsync(rig.Token);
            await (await rig.ProbeAsync(1)).Text.Task.WaitAsync(rig.Token);
            Equal(0, a.Stream.WrittenBytes.Length);
            True(rig.Probes[0].Released.Task.IsCompleted);
            True(rig.StartupViolations.IsEmpty);
        }
        finally { allowFactory.Set(); allowCleanup.Set(); }
    }

    private static async Task ReplacementFailedFactory()
    {
        int attempts = 0;
        await using var rig = new ReplacementRig(beforeCreate: () =>
        { if (Interlocked.Increment(ref attempts) == 1) throw new InvalidOperationException("fake factory failure"); });
        var a = rig.Client("A", text: true);
        try { await a.Run.WaitAsync(rig.Token); throw new Exception("Factory failure was hidden."); }
        catch (InvalidOperationException e) when (e.Message == "fake factory failure") { }
        Equal(0, a.Stream.WrittenBytes.Length);
        var b = rig.Client("B", text: true);
        await b.Hello.Task.WaitAsync(rig.Token);
        await (await rig.ProbeAsync(0)).Text.Task.WaitAsync(rig.Token);
        True(rig.StartupViolations.IsEmpty);
    }

    private static async Task ReplacementDisposeIgnoresBlockedObserver()
    {
        using var releaseObserver = new ManualResetEventSlim(false);
        var observerEntered = ReplacementSignal();
        await using var rig = new ReplacementRig(peerAuthenticated: _ =>
        { observerEntered.TrySetResult(); releaseObserver.Wait(TimeSpan.FromSeconds(10)); });
        var a = rig.Client("A", hold: true);
        try
        {
            await observerEntered.Task.WaitAsync(rig.Token);
            await (await rig.ProbeAsync(0)).Down.Task.WaitAsync(rig.Token);
            await rig.Manager.DisposeAsync().AsTask().WaitAsync(rig.Token);
            await a.Run.WaitAsync(rig.Token);
            True(rig.Probes[0].Released.Task.IsCompleted);
            True(!releaseObserver.IsSet);
        }
        finally { releaseObserver.Set(); }
    }

    private static async Task ReplacementExpectCancellation(Task task, CancellationToken timeout)
    {
        try { await task.WaitAsync(timeout); throw new Exception("Expected startup cancellation."); }
        catch (OperationCanceledException) when (!timeout.IsCancellationRequested) { }
    }

    private static TaskCompletionSource ReplacementSignal() => new(TaskCreationOptions.RunContinuationsAsynchronously);

    private sealed record ReplacementClient(InteractiveDuplexStream Stream, Task Run, TaskCompletionSource Hello);
    private sealed class ReplacementClientOwner { internal int NativeIndex = -1; }

    private sealed class ReplacementRig : IAsyncDisposable
    {
        internal const string Peer = "replacement-fake-peer";
        private readonly CancellationTokenSource timeout = new(TimeSpan.FromSeconds(8));
        private readonly List<ReplacementClient> clients = [];
        private readonly AsyncLocal<ReplacementClientOwner?> factoryClient = new();
        internal ConcurrentDictionary<int, ReplacementProbe> Probes { get; } = new();
        internal ConcurrentQueue<string> StartupViolations { get; } = new();
        internal CancellationToken Token => timeout.Token;
        internal HostControlSessionManager Manager { get; }
        internal InputPermissionGate Consent { get; } = new();
        internal ReplacementRig(HostControlSessionOptions? options = null, Action? stateChanged = null,
            Action<string>? peerAuthenticated = null, Action<int, ReplacementProbe>? onCreate = null, Action? beforeCreate = null,
            IHostAwakeController? awakeController = null)
        {
            var window = CreateVideoWindow();
            Consent.SetEnabled(true); // In-memory gate; no production/UI consent change.
            Manager = new(new FakeWindowEnumerator([window]), new DelegateHostInputSessionFactory(() =>
            {
                beforeCreate?.Invoke();
                int index = Probes.Count;
                var probe = new ReplacementProbe();
                Probes[index] = probe;
                var owner = factoryClient.Value ?? throw new InvalidOperationException("Missing fake factory client context.");
                Volatile.Write(ref owner.NativeIndex, index);
                var input = new ReplacementInputOwner(new WindowsHostInputSession(Consent,
                    new RecordingWindowInputTargetResolver(window.Bounds), probe), probe);
                onCreate?.Invoke(index, probe);
                return input;
            }), options ?? new HostControlSessionOptions("Fake Host"), peerAuthenticated, awakeController, stateChanged);
        }
        internal ReplacementClient Client(string name, bool hold = false, bool text = false,
            IReadOnlyList<string>? capabilities = null, Action? helloHook = null, CancellationToken cancellation = default,
            bool ignoreFlushCancellation = false)
        {
            var hello = ReplacementSignal();
            var owner = new ReplacementClientOwner();
            var stream = new InteractiveDuplexStream(bytes =>
            {
                if (PeelJson.ReadEnvelope(bytes.Span).Type != PeelMessageType.HostHello) return;
                // Check exactly at HostHello publication, before any new input.
                int activeIndex = Volatile.Read(ref owner.NativeIndex);
                if (activeIndex < 0) throw new InvalidOperationException("Hello preceded its own fake native owner.");
                foreach (var pair in Probes)
                    if (pair.Key < activeIndex && (!pair.Value.Released.Task.IsCompleted || pair.Value.Held))
                        StartupViolations.Enqueue(name + ":prior-native-input-not-released");
                helloHook?.Invoke();
                hello.TrySetResult();
            }, ignoreFlushCancellation);
            List<object> messages = [PeelHello.CreateClient(Peer, name, "macOS", capabilities: capabilities ?? []),
                new PeelRequest(PeelMessageType.RequestWindowList)];
            if (hold) messages.Add(new KeyboardHardwareKeyMessage(225, [], WindowId: 1, Action: KeyboardCommandAction.Down));
            if (text) messages.Add(new KeyboardTextMessage(name, WindowId: 1));
            stream.EnqueueLines([.. messages]);
            // Async execution context ties factory creation to THIS client even
            // when a later factory exists before this client's HostHello write.
            var previous = factoryClient.Value;
            factoryClient.Value = owner;
            Task run;
            try { run = Manager.RunAuthenticatedSessionAsync(new PeelPskConnection(stream, Peer), cancellation); }
            finally { factoryClient.Value = previous; }
            var client = new ReplacementClient(stream, run, hello);
            clients.Add(client);
            return client;
        }
        internal async Task<ReplacementProbe> ProbeAsync(int index)
        {
            await WaitForMinimumAsync(() => Probes.ContainsKey(index) ? 1 : 0, 1, Token);
            return Probes[index];
        }
        internal async Task<T> Reply<T>(ReplacementClient client, object message, string type, bool addFocus = false)
        {
            int Count() => ReadOutputLines(client.Stream.WrittenBytes).Count(line => PeelJson.ReadEnvelope(line).Type == type);
            int count = Count();
            if (addFocus) client.Stream.EnqueueLines(message, new ClientActiveWindowMessage(1));
            else client.Stream.EnqueueLines(message);
            await WaitForMinimumAsync(Count, count + 1, Token);
            return PeelJson.Deserialize<T>(ReadOutputLines(client.Stream.WrittenBytes).Last(line => PeelJson.ReadEnvelope(line).Type == type));
        }
        public async ValueTask DisposeAsync()
        {
            try
            {
                await Manager.DisposeAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(5));
                foreach (var client in clients)
                    try { await client.Run.WaitAsync(TimeSpan.FromSeconds(5)); } catch (OperationCanceledException) { } catch (InvalidOperationException) { }
            }
            finally { timeout.Dispose(); }
        }
    }

    // Records completed native Dispose even when there were no held keys to send.
    // All behavior remains in the production WindowsHostInputSession.
    private sealed class ReplacementInputOwner(WindowsHostInputSession native, ReplacementProbe probe) : IHostInputSession
    {
        public InputInjectionResult HandleClientActiveWindow(WindowDescriptor window) => native.HandleClientActiveWindow(window);
        public InputInjectionResult HandleMouse(PeelRequest request, WindowDescriptor window) => native.HandleMouse(request, window);
        public InputInjectionResult HandleKeyboardText(KeyboardTextMessage message, WindowDescriptor window) => native.HandleKeyboardText(message, window);
        public InputInjectionResult HandleKeyboardCommand(KeyboardCommandMessage message, WindowDescriptor window) => native.HandleKeyboardCommand(message, window);
        public InputInjectionResult HandleKeyboardHardwareKey(KeyboardHardwareKeyMessage message, WindowDescriptor window) => native.HandleKeyboardHardwareKey(message, window);
        public InputInjectionResult HandleKeyboardChord(KeyboardChordMessage message, WindowDescriptor window) => native.HandleKeyboardChord(message, window);
        public InputInjectionResult HandleKeyboardMacro(KeyboardMacroMessage message, WindowDescriptor window) => native.HandleKeyboardMacro(message, window);
        public void Dispose()
        {
            probe.DisposeEntered.TrySetResult();
            probe.AllowDispose?.Wait(TimeSpan.FromSeconds(10));
            native.Dispose();
            probe.Released.TrySetResult();
        }
    }

    private sealed class ReplacementProbe : IHostInputInjector
    {
        private int held;
        internal bool Held => Volatile.Read(ref held) != 0;
        internal int ReleasedKeyCount;
        internal TaskCompletionSource DisposeEntered { get; } = ReplacementSignal();
        internal TaskCompletionSource Down { get; } = ReplacementSignal();
        internal TaskCompletionSource Text { get; } = ReplacementSignal();
        internal TaskCompletionSource ReleaseEntered { get; } = ReplacementSignal();
        internal TaskCompletionSource Released { get; } = ReplacementSignal();
        internal ManualResetEventSlim? AllowRelease, AllowDown, AllowDispose;
        public InputInjectionResult SendVirtualKey(ushort key, VirtualKeyAction action)
        {
            if (action == VirtualKeyAction.Down)
            {
                Volatile.Write(ref held, 1); Down.TrySetResult();
                AllowDown?.Wait(TimeSpan.FromSeconds(10));
            }
            else if (action == VirtualKeyAction.Up) Volatile.Write(ref held, 0);
            return InputInjectionResult.Success;
        }
        public InputInjectionResult SendText(string? text) { Text.TrySetResult(); return InputInjectionResult.Success; }
        public InputInjectionResult ReleaseHeldInputs(IReadOnlyCollection<MouseButton> buttons, IReadOnlyCollection<ushort> keys)
        {
            ReleaseEntered.TrySetResult();
            AllowRelease?.Wait(TimeSpan.FromSeconds(10));
            ReleasedKeyCount = keys.Count;
            Volatile.Write(ref held, 0); Released.TrySetResult();
            return InputInjectionResult.Success;
        }
        public InputInjectionResult MovePointer(WindowBounds bounds, double x, double y) => InputInjectionResult.Success;
        public InputInjectionResult SendPointerButton(WindowBounds bounds, double x, double y, MouseButton button, MouseButtonAction action) => InputInjectionResult.Success;
        public InputInjectionResult SendMouseButton(MouseButton button, MouseButtonAction action) => InputInjectionResult.Success;
        public InputInjectionResult SendMouseWheel(int vertical, int horizontal) => InputInjectionResult.Success;
        public InputInjectionResult SendVirtualKeyChord(IReadOnlyList<ushort> keys) => InputInjectionResult.Success;
    }

    private sealed class ReplacementBlockingCapture : IHostAudioCapture
    {
        internal TaskCompletionSource Started { get; } = ReplacementSignal();
        internal TaskCompletionSource DisposeEntered { get; } = ReplacementSignal();
        internal TaskCompletionSource AllowDispose { get; } = ReplacementSignal();
        private readonly TaskCompletionSource completion = ReplacementSignal();
        public Task Completion => completion.Task;
        public ValueTask StartAsync(Action<AudioPacket> offer, CancellationToken token)
        { Started.TrySetResult(); return ValueTask.CompletedTask; }
        public async ValueTask DisposeAsync()
        { DisposeEntered.TrySetResult(); await AllowDispose.Task; completion.TrySetResult(); }
    }
}
