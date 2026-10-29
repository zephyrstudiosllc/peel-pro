using System.Text.Json;
using Peel.Windows.Host.Input;
using Peel.Windows.Host.Networking;
using Peel.Windows.Host.Windows;
using Peel.Windows.Protocol;
using Peel.Windows.Transport;

namespace Peel.Windows.Host.Tests;

internal static partial class Program
{
    private const string FocusCorrelationLowerId = "a1b2c3d4-5e6f-4789-a0bc-d1e2f3a4b5c6";
    private const string FocusCorrelationOtherId = "D4C3B2A1-6F5E-4987-BC0A-6C5B4A3F2E1D";

    // One bounded selector: new protocol/session cases plus the unchanged seven
    // Function cases. Every input resolver/injector below is an in-memory fake.
    private static async Task<int> RunFocusCorrelationFakeTestsAsync()
    {
        (string Name, Func<Task> Test)[] tests = [
            ("focus correlation preserves legacy omission and explicit null", FocusCorrelationLegacyCompatibilityAsync),
            ("focus correlation round-trips and echoes exact D36 case", FocusCorrelationExactRoundTripAsync),
            ("focus correlation invokes fresh focus for consecutive same-window requests", FocusCorrelationFreshSameWindowAsync),
            ("focus correlation rejects malformed strings before focus activation", FocusCorrelationRejectsMalformedStringsAsync),
            ("focus correlation rejects non-string JSON before focus activation", FocusCorrelationRejectsWrongJsonTypesAsync),
            ("focus correlation failure states echo valid request identifiers", FocusCorrelationFailureEchoAsync),
            ("focus correlation legacy requests never reuse prior identifiers", FocusCorrelationLegacyAfterCorrelatedAsync),
            ("focus correlation replacement suppresses in-flight old focus replies", FocusCorrelationReplacementSuppressesOldReplyAsync),
            ("hardware Function metadata remains informational", HardwareFunctionMetadataIsInformational),
            ("hardware Function metadata preserves modifier ownership", HardwareFunctionMetadataPreservesModifierOwnership),
            ("hardware Function metadata rejects invalid and oversized lists", HardwareFunctionMetadataRejectsInvalidLists),
            ("hardware Function metadata rejects unknown wire names", HardwareFunctionMetadataRejectsUnknownWireNames),
            ("Mac held hardware keys accept modifier snapshots", MacHeldHardwareKeysAcceptModifierSnapshots),
            ("hardware modifier snapshots reject non-modifiers", Sync(HardwareModifierSnapshotsRejectNonModifiers)),
            ("held hardware modifiers release on revoke and disconnect", HeldHardwareModifiersReleaseOnRevokeAndDisconnect),
        ];
        var failures = 0;
        foreach ((string name, Func<Task> test) in tests)
        {
            try
            {
                await test().ConfigureAwait(false);
                Console.WriteLine($"PASS {name}");
            }
            catch (Exception exception)
            {
                failures++;
                Console.Error.WriteLine($"FAIL {name}: {exception.Message}");
            }
        }
        Console.WriteLine($"{tests.Length - failures}/{tests.Length} focus correlation and Function fake tests passed");
        return failures == 0 ? 0 : 1;
    }

    private static async Task FocusCorrelationLegacyCompatibilityAsync()
    {
        // Explicit positional Type arguments retain their old constructor meaning.
        var request = new ClientActiveWindowMessage(1, PeelMessageType.ClientActiveWindow);
        Equal("{\"windowId\":1,\"type\":\"clientActiveWindow\"}", PeelJson.SerializeString(request));
        var state = new WindowFocusStateMessage(1, 1, true, PeelMessageType.WindowFocusState);
        Equal("{\"activeWindowId\":1,\"requestedWindowId\":1,\"didActivateRequestedWindow\":true,\"type\":\"windowFocusState\"}",
            PeelJson.SerializeString(state));
        ClientActiveWindowMessage explicitNull = PeelJson.Deserialize<ClientActiveWindowMessage>(
            "{\"type\":\"clientActiveWindow\",\"windowId\":1,\"focusRequestId\":null}"u8);
        WindowFocusStateMessage nullState = PeelJson.Deserialize<WindowFocusStateMessage>(
            "{\"type\":\"windowFocusState\",\"activeWindowId\":1,\"requestedWindowId\":1,\"didActivateRequestedWindow\":true,\"focusRequestId\":null}"u8);
        True(explicitNull.FocusRequestId is null && nullState.FocusRequestId is null);
        Equal(PeelJson.SerializeString(request), PeelJson.SerializeString(explicitNull));
        Equal(PeelJson.SerializeString(state), PeelJson.SerializeString(nullState));
        using (JsonDocument unsolicited = JsonDocument.Parse(PeelJson.Serialize(
            new WindowFocusStateMessage(null, null, false))))
        {
            True(!unsolicited.RootElement.TryGetProperty("focusRequestId", out _));
        }

        WindowDescriptor window = CreateVideoWindow();
        var gate = new InputPermissionGate();
        gate.SetEnabled(true);
        var resolver = new RecordingWindowInputTargetResolver(window.Bounds);
        ScriptedDuplexStream stream = await RunFocusCorrelationSessionAsync([
            request,
            FocusCorrelationRaw("{\"type\":\"clientActiveWindow\",\"windowId\":1,\"focusRequestId\":null}"),
        ], gate, resolver).ConfigureAwait(false);
        IReadOnlyList<byte[]> lines = ReadOutputLines(stream);
        Equal(4, lines.Count);
        AssertFocusCorrelationReply(lines[2], 1, null, true);
        AssertFocusCorrelationReply(lines[3], 1, null, true);
        Equal(2, resolver.AcquireForegroundCount);
    }

    private static async Task FocusCorrelationExactRoundTripAsync()
    {
        string[] identifiers = [
            FocusCorrelationLowerId,
            FocusCorrelationLowerId.ToUpperInvariant(),
            "00000000-0000-0000-0000-000000000000",
            "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF",
            "a1B2c3D4-5E6f-4789-A0bC-d1E2f3A4B5c6",
        ];
        foreach (string identifier in identifiers)
        {
            var request = new ClientActiveWindowMessage(1, FocusRequestId: identifier);
            Equal(identifier, PeelJson.Deserialize<ClientActiveWindowMessage>(PeelJson.Serialize(request)).FocusRequestId);
            var state = new WindowFocusStateMessage(1, 1, true, FocusRequestId: identifier);
            Equal(identifier, PeelJson.Deserialize<WindowFocusStateMessage>(PeelJson.Serialize(state)).FocusRequestId);
        }
        WindowDescriptor window = CreateVideoWindow();
        var gate = new InputPermissionGate();
        gate.SetEnabled(true);
        var resolver = new RecordingWindowInputTargetResolver(window.Bounds);
        ScriptedDuplexStream stream = await RunFocusCorrelationSessionAsync(
            identifiers.Select(static identifier => (object)new ClientActiveWindowMessage(1, FocusRequestId: identifier)).ToArray(),
            gate, resolver).ConfigureAwait(false);
        IReadOnlyList<byte[]> lines = ReadOutputLines(stream);
        Equal(identifiers.Length + 2, lines.Count);
        for (var index = 0; index < identifiers.Length; index++)
            AssertFocusCorrelationReply(lines[index + 2], 1, identifiers[index], true);
        Equal(identifiers.Length, resolver.AcquireForegroundCount);
    }

    private static async Task FocusCorrelationFreshSameWindowAsync()
    {
        WindowDescriptor window = CreateVideoWindow();
        var gate = new InputPermissionGate();
        gate.SetEnabled(true);
        var resolver = new FocusCorrelationFreshResolver(window.Bounds);
        ScriptedDuplexStream stream = await RunFocusCorrelationSessionAsync([
            new ClientActiveWindowMessage(1, FocusRequestId: FocusCorrelationLowerId),
            new ClientActiveWindowMessage(1, FocusRequestId: FocusCorrelationOtherId),
        ], gate, resolver).ConfigureAwait(false);
        IReadOnlyList<byte[]> lines = ReadOutputLines(stream);
        Equal(4, lines.Count);
        AssertFocusCorrelationReply(lines[2], 1, FocusCorrelationLowerId, true);
        // The second attempt is deliberately denied by the fake resolver. A cached
        // successful result for this same window must not acknowledge the new ID.
        AssertFocusCorrelationReply(lines[3], 1, FocusCorrelationOtherId, false);
        Equal(2, resolver.ResolveCount);
    }

    private static async Task FocusCorrelationRejectsMalformedStringsAsync()
    {
        string[] invalid = [
            "", FocusCorrelationLowerId.Replace("-", ""),
            "{" + FocusCorrelationLowerId + "}",
            " " + FocusCorrelationLowerId, FocusCorrelationLowerId + " ",
            FocusCorrelationLowerId[..^1], FocusCorrelationLowerId + "0",
            "g" + FocusCorrelationLowerId[1..], FocusCorrelationLowerId.Replace('-', '_'),
            "\uFF21" + FocusCorrelationLowerId[1..], FocusCorrelationLowerId.Replace('-', '\u2010'),
            FocusCorrelationLowerId[..^1] + "\u00E9",
            FocusCorrelationLowerId[..^1] + "\0", FocusCorrelationLowerId[..^1] + "\n",
            new string('a', 4096),
        ];
        foreach (string value in invalid)
        {
            // Anonymous raw documents bypass the DTO's outbound converter, so the
            // actual malformed value reaches the real session deserializer.
            object request = new { type = PeelMessageType.ClientActiveWindow, windowId = 1, focusRequestId = value };
            object reply = new { type = PeelMessageType.WindowFocusState, activeWindowId = 1,
                requestedWindowId = 1, didActivateRequestedWindow = true, focusRequestId = value };
            Throws<JsonException>(() => PeelJson.Deserialize<ClientActiveWindowMessage>(PeelJson.Serialize(request)));
            Throws<JsonException>(() => PeelJson.Deserialize<WindowFocusStateMessage>(PeelJson.Serialize(reply)));
            Throws<JsonException>(() => PeelJson.Serialize(new ClientActiveWindowMessage(1, FocusRequestId: value)));
            Throws<JsonException>(() => PeelJson.Serialize(new WindowFocusStateMessage(1, 1, true, FocusRequestId: value)));
            await AssertMalformedFocusCorrelationSessionAsync(request).ConfigureAwait(false);
        }
    }

    private static async Task FocusCorrelationRejectsWrongJsonTypesAsync()
    {
        object[] invalid = [true, false, 0, 1.5, Array.Empty<object>(),
            new object[] { FocusCorrelationLowerId }, new { value = FocusCorrelationLowerId }];
        foreach (object value in invalid)
        {
            object request = new { type = PeelMessageType.ClientActiveWindow, windowId = 1, focusRequestId = value };
            object reply = new { type = PeelMessageType.WindowFocusState, activeWindowId = 1,
                requestedWindowId = 1, didActivateRequestedWindow = true, focusRequestId = value };
            Throws<JsonException>(() => PeelJson.Deserialize<ClientActiveWindowMessage>(PeelJson.Serialize(request)));
            Throws<JsonException>(() => PeelJson.Deserialize<WindowFocusStateMessage>(PeelJson.Serialize(reply)));
            await AssertMalformedFocusCorrelationSessionAsync(request).ConfigureAwait(false);
        }
    }

    private static async Task FocusCorrelationFailureEchoAsync()
    {
        WindowDescriptor window = CreateVideoWindow();
        var disabledResolver = new RecordingWindowInputTargetResolver(window.Bounds);
        ScriptedDuplexStream disabled = await RunFocusCorrelationSessionAsync([
            new ClientActiveWindowMessage(1, FocusRequestId: FocusCorrelationLowerId),
        ], new InputPermissionGate(), disabledResolver).ConfigureAwait(false);
        Equal(3, ReadOutputLines(disabled).Count);
        AssertFocusCorrelationReply(ReadOutputLines(disabled)[2], 1, FocusCorrelationLowerId, false);
        Equal(0, disabledResolver.ResolveCount);

        var gate = new InputPermissionGate();
        gate.SetEnabled(true);
        var resolver = new RecordingWindowInputTargetResolver(window.Bounds);
        ScriptedDuplexStream invalidWindows = await RunFocusCorrelationSessionAsync([
            new ClientActiveWindowMessage(0, FocusRequestId: FocusCorrelationLowerId),
            new ClientActiveWindowMessage(99, FocusRequestId: FocusCorrelationOtherId),
        ], gate, resolver).ConfigureAwait(false);
        IReadOnlyList<byte[]> invalidLines = ReadOutputLines(invalidWindows);
        Equal(4, invalidLines.Count);
        AssertFocusCorrelationReply(invalidLines[2], 0, FocusCorrelationLowerId, false);
        AssertFocusCorrelationReply(invalidLines[3], 99, FocusCorrelationOtherId, false);
        Equal(0, resolver.ResolveCount);

        // ID1 was real in the first list, then disappears in a refreshed list.
        var removedWindow = new FocusCorrelationRemovedWindowEnumerator(window);
        ScriptedDuplexStream stale = await RunFocusCorrelationSessionAsync([
            new PeelRequest(PeelMessageType.RequestWindowList),
            new ClientActiveWindowMessage(1, FocusRequestId: FocusCorrelationOtherId),
        ], gate, resolver, removedWindow).ConfigureAwait(false);
        IReadOnlyList<byte[]> staleLines = ReadOutputLines(stale);
        Equal(4, staleLines.Count);
        Equal(PeelMessageType.WindowList, PeelJson.ReadEnvelope(staleLines[2]).Type);
        AssertFocusCorrelationReply(staleLines[3], 1, FocusCorrelationOtherId, false);
        Equal(2, removedWindow.CallCount);
        Equal(0, resolver.ResolveCount);
    }

    private static async Task FocusCorrelationLegacyAfterCorrelatedAsync()
    {
        WindowDescriptor window = CreateVideoWindow();
        var gate = new InputPermissionGate();
        gate.SetEnabled(true);
        var resolver = new RecordingWindowInputTargetResolver(window.Bounds);
        ScriptedDuplexStream stream = await RunFocusCorrelationSessionAsync([
            new ClientActiveWindowMessage(1, FocusRequestId: FocusCorrelationLowerId),
            new ClientActiveWindowMessage(1),
            new ClientActiveWindowMessage(1, FocusRequestId: FocusCorrelationOtherId),
            FocusCorrelationRaw("{\"type\":\"clientActiveWindow\",\"windowId\":1,\"focusRequestId\":null}"),
        ], gate, resolver).ConfigureAwait(false);
        IReadOnlyList<byte[]> lines = ReadOutputLines(stream);
        Equal(6, lines.Count);
        AssertFocusCorrelationReply(lines[2], 1, FocusCorrelationLowerId, true);
        AssertFocusCorrelationReply(lines[3], 1, null, true);
        AssertFocusCorrelationReply(lines[4], 1, FocusCorrelationOtherId, true);
        AssertFocusCorrelationReply(lines[5], 1, null, true);
        Equal(4, resolver.AcquireForegroundCount);
    }

    private static async Task FocusCorrelationReplacementSuppressesOldReplyAsync()
    {
        const string peer = "focus-correlation-replacement-peer";
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(8));
        using var allowOldFocus = new ManualResetEventSlim(false);
        WindowDescriptor window = CreateVideoWindow();
        var gate = new InputPermissionGate();
        gate.SetEnabled(true);
        var oldResolver = new FocusCorrelationBlockingResolver(window.Bounds, allowOldFocus);
        var replacementResolver = new RecordingWindowInputTargetResolver(window.Bounds);
        var created = 0;
        var factory = new DelegateHostInputSessionFactory(() => new WindowsHostInputSession(gate,
            Interlocked.Increment(ref created) == 1 ? (IWindowInputTargetResolver)oldResolver : replacementResolver,
            new RecordingInputInjector()));
        var manager = new HostControlSessionManager(new FakeWindowEnumerator([window]), factory,
            new HostControlSessionOptions("Focus Fake Host"));
        var replacementHello = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var replacementFocus = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var oldStream = new InteractiveDuplexStream();
        using var replacementStream = new InteractiveDuplexStream(bytes =>
        {
            string type = PeelJson.ReadEnvelope(bytes.Span).Type;
            if (type == PeelMessageType.HostHello) replacementHello.TrySetResult();
            if (type == PeelMessageType.WindowFocusState &&
                PeelJson.Deserialize<WindowFocusStateMessage>(bytes.Span).FocusRequestId == FocusCorrelationOtherId)
                replacementFocus.TrySetResult();
        });
        Task? oldRun = null;
        Task? replacementRun = null;
        try
        {
            oldStream.EnqueueLines(PeelHello.CreateClient(peer, "Old Focus", "macOS"),
                new PeelRequest(PeelMessageType.RequestWindowList),
                new ClientActiveWindowMessage(1, FocusRequestId: FocusCorrelationLowerId));
            oldRun = manager.RunAuthenticatedSessionAsync(new PeelPskConnection(oldStream, peer), timeout.Token);
            await oldResolver.Entered.Task.WaitAsync(timeout.Token).ConfigureAwait(false);
            Equal(1, oldResolver.ResolveCount);
            // Old focus is already admitted, inside its fake platform resolver.
            // Publish B while A is blocked; B must wait for that native-owner gate.
            replacementStream.EnqueueLines(PeelHello.CreateClient(peer, "New Focus", "macOS"),
                new PeelRequest(PeelMessageType.RequestWindowList),
                new ClientActiveWindowMessage(1),
                new ClientActiveWindowMessage(1, FocusRequestId: FocusCorrelationOtherId));
            replacementRun = manager.RunAuthenticatedSessionAsync(new PeelPskConnection(replacementStream, peer), timeout.Token);
            await WaitForMinimumAsync(() => manager.ActiveGeneration == 2 ? 1 : 0, 1, timeout.Token).ConfigureAwait(false);
            True(!replacementHello.Task.IsCompleted);
            allowOldFocus.Set();
            await oldRun.WaitAsync(timeout.Token).ConfigureAwait(false);
            await replacementFocus.Task.WaitAsync(timeout.Token).ConfigureAwait(false);

            IReadOnlyList<byte[]> oldLines = ReadOutputLines(oldStream.WrittenBytes);
            IReadOnlyList<byte[]> newLines = ReadOutputLines(replacementStream.WrittenBytes);
            Equal(2, oldLines.Count);
            True(oldLines.All(static line => PeelJson.ReadEnvelope(line).Type != PeelMessageType.WindowFocusState));
            byte[][] replies = newLines.Where(static line => PeelJson.ReadEnvelope(line).Type == PeelMessageType.WindowFocusState).ToArray();
            Equal(2, replies.Length);
            AssertFocusCorrelationReply(replies[0], 1, null, true);
            AssertFocusCorrelationReply(replies[1], 1, FocusCorrelationOtherId, true);
            True(replies.All(static line => PeelJson.Deserialize<WindowFocusStateMessage>(line).FocusRequestId != FocusCorrelationLowerId));
            Equal(2, replacementResolver.AcquireForegroundCount);
            replacementStream.CompleteInput();
            await replacementRun.WaitAsync(timeout.Token).ConfigureAwait(false);
        }
        finally
        {
            allowOldFocus.Set();
            oldStream.CompleteInput();
            replacementStream.CompleteInput();
            await manager.DisposeAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
            if (oldRun is not null) await oldRun.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
            if (replacementRun is not null) await replacementRun.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        }
    }

    private static async Task<ScriptedDuplexStream> RunFocusCorrelationSessionAsync(
        IReadOnlyList<object> requests,
        InputPermissionGate gate,
        IWindowInputTargetResolver resolver,
        IWindowEnumerator? enumerator = null,
        RecordingInputInjector? injector = null)
    {
        const string peer = "focus-correlation-fake-peer";
        List<object> messages = [PeelHello.CreateClient(peer, "Focus Fake", "macOS"),
            new PeelRequest(PeelMessageType.RequestWindowList)];
        messages.AddRange(requests);
        var factory = new DelegateHostInputSessionFactory(() => new WindowsHostInputSession(
            gate, resolver, injector ?? new RecordingInputInjector()));
        return await RunCompletedSessionAsync(CombineLines(messages.ToArray()), peer,
            enumerator ?? new FakeWindowEnumerator([CreateVideoWindow()]), inputSessionFactory: factory).ConfigureAwait(false);
    }

    private static async Task AssertMalformedFocusCorrelationSessionAsync(object malformedRequest)
    {
        WindowDescriptor window = CreateVideoWindow();
        var gate = new InputPermissionGate();
        gate.SetEnabled(true);
        var resolver = new RecordingWindowInputTargetResolver(window.Bounds);
        var injector = new RecordingInputInjector();
        ScriptedDuplexStream stream = await RunFocusCorrelationSessionAsync([
            malformedRequest,
            new ClientActiveWindowMessage(1, FocusRequestId: FocusCorrelationLowerId),
        ], gate, resolver, injector: injector).ConfigureAwait(false);
        // The valid request queued AFTER malformed data must never be handled.
        Equal(2, ReadOutputLines(stream).Count);
        Equal(0, resolver.ResolveCount);
        Equal(0, injector.Calls.Count);
    }

    private static void AssertFocusCorrelationReply(byte[] line, uint windowId, string? identifier, bool activated)
    {
        WindowFocusStateMessage state = PeelJson.Deserialize<WindowFocusStateMessage>(line);
        Equal(PeelMessageType.WindowFocusState, state.Type);
        Equal<uint?>(windowId, state.RequestedWindowId);
        Equal(activated, state.DidActivateRequestedWindow);
        Equal<uint?>(activated ? windowId : null, state.ActiveWindowId);
        Equal(identifier, state.FocusRequestId);
        using JsonDocument json = JsonDocument.Parse(line);
        if (identifier is null) True(!json.RootElement.TryGetProperty("focusRequestId", out _));
        else Equal(identifier, json.RootElement.GetProperty("focusRequestId").GetString());
    }

    private static JsonElement FocusCorrelationRaw(string json)
    {
        using JsonDocument document = JsonDocument.Parse(json);
        return document.RootElement.Clone();
    }

    private sealed class FocusCorrelationFreshResolver(WindowBounds bounds) : IWindowInputTargetResolver
    {
        internal int ResolveCount { get; private set; }
        public WindowInputTargetResult Resolve(WindowDescriptor window, WindowInputFocusMode focusMode)
        {
            _ = window;
            Equal(WindowInputFocusMode.AcquireForeground, focusMode);
            ResolveCount++;
            return ResolveCount == 1 ? WindowInputTargetResult.Success(bounds) : WindowInputTargetResult.Rejected("Synthetic focus denial.");
        }
    }

    private sealed class FocusCorrelationRemovedWindowEnumerator(WindowDescriptor window) : IWindowEnumerator
    {
        internal int CallCount { get; private set; }
        public IReadOnlyList<WindowDescriptor> Enumerate() => ++CallCount == 1 ? [window] : [];
    }

    private sealed class FocusCorrelationBlockingResolver(WindowBounds bounds, ManualResetEventSlim allowFocus) : IWindowInputTargetResolver
    {
        internal TaskCompletionSource Entered { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal int ResolveCount { get; private set; }
        public WindowInputTargetResult Resolve(WindowDescriptor window, WindowInputFocusMode focusMode)
        {
            _ = window;
            Equal(WindowInputFocusMode.AcquireForeground, focusMode);
            ResolveCount++;
            Entered.TrySetResult();
            if (!allowFocus.Wait(TimeSpan.FromSeconds(6))) throw new InvalidOperationException("Fake focus release barrier timed out.");
            return WindowInputTargetResult.Success(bounds);
        }
    }
}
