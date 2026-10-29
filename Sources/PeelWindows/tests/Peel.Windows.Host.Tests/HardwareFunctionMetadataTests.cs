using System.Text.Json;
using Peel.Windows.Host.Input;
using Peel.Windows.Host.Windows;
using Peel.Windows.Protocol;

namespace Peel.Windows.Host.Tests;

internal static partial class Program
{
    private static async Task<int> RunHardwareFunctionFakeTestsAsync()
    {
        (string Name, Func<Task> Test)[] tests = [
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
        Console.WriteLine($"{tests.Length - failures}/{tests.Length} hardware Function fake tests passed");
        return failures == 0 ? 0 : 1;
    }

    private static async Task HardwareFunctionMetadataIsInformational()
    {
        const string identity = "mac-function-key-client";
        WindowDescriptor window = CreateVideoWindow();
        var gate = new InputPermissionGate();
        gate.SetEnabled(true);
        var injector = new RecordingInputInjector();
        var resolver = new RecordingWindowInputTargetResolver(window.Bounds);
        var factory = new DelegateHostInputSessionFactory(() =>
            new WindowsHostInputSession(gate, resolver, injector));
        var messages = new List<object> {
            PeelHello.CreateClient(identity, "Mac", "macOS"),
            new PeelRequest(PeelMessageType.RequestWindowList),
        };
        var expected = new List<string>();
        // End, Home, PageUp, PageDown, arrows and F1 carry AppKit Function metadata.
        (int Hid, ushort VirtualKey)[] keys = [
            (77, 35), (74, 36), (75, 33), (78, 34), (79, 39),
            (80, 37), (81, 40), (82, 38), (58, 112),
        ];
        foreach ((int hid, ushort virtualKey) in keys)
        {
            foreach (KeyboardCommandAction action in Enum.GetValues<KeyboardCommandAction>())
            {
                messages.Add(new KeyboardHardwareKeyMessage(hid, [KeyboardCommand.Function],
                    WindowId: 1, Characters: hid == 77 ? "\uf72b" : null,
                    CharactersIgnoringModifiers: hid == 77 ? "\uf72b" : null, Action: action));
                expected.Add($"key:{virtualKey}:{action}");
            }
        }
        // Absent action still means Press. Eight raw Function values remain in bounds.
        var omittedAction = new KeyboardHardwareKeyMessage(77, [KeyboardCommand.Function], WindowId: 1);
        using (JsonDocument document = JsonDocument.Parse(PeelJson.Serialize(omittedAction)))
        {
            True(!document.RootElement.TryGetProperty("action", out _));
        }
        messages.Add(omittedAction);
        expected.Add("key:35:Press");
        messages.Add(new KeyboardHardwareKeyMessage(77,
            Enumerable.Repeat(KeyboardCommand.Function, 8).ToArray(), WindowId: 1));
        expected.Add("key:35:Press");
        // Genuine transient modifiers and existing deduplication retain their mappings.
        messages.Add(new KeyboardHardwareKeyMessage(77,
            [KeyboardCommand.Function, KeyboardCommand.Shift, KeyboardCommand.Control,
                KeyboardCommand.Option, KeyboardCommand.Command], WindowId: 1));
        expected.Add("chord:16,17,18,35");
        messages.Add(new KeyboardHardwareKeyMessage(77,
            [KeyboardCommand.Function, KeyboardCommand.Shift,
                KeyboardCommand.Function, KeyboardCommand.Shift], WindowId: 1));
        expected.Add("chord:16,35");

        ScriptedDuplexStream stream = await RunCompletedSessionAsync(CombineLines(messages.ToArray()),
            identity, new FakeWindowEnumerator([window]), inputSessionFactory: factory).ConfigureAwait(false);
        Equal(2, ReadOutputLines(stream).Count);
        True(injector.Calls.SequenceEqual(expected, StringComparer.Ordinal));
        Equal(0, injector.ReleaseCount);
        Equal(keys.Length * 2 + 4, resolver.AcquireForegroundCount);
    }

    private static async Task HardwareFunctionMetadataPreservesModifierOwnership()
    {
        const string identity = "mac-function-held-client";
        WindowDescriptor window = CreateVideoWindow();
        var gate = new InputPermissionGate();
        gate.SetEnabled(true);
        var injector = new RecordingInputInjector();
        var factory = new DelegateHostInputSessionFactory(() => new WindowsHostInputSession(gate,
            new RecordingWindowInputTargetResolver(window.Bounds), injector));
        var messages = new List<object> {
            PeelHello.CreateClient(identity, "Mac", "macOS"),
            new PeelRequest(PeelMessageType.RequestWindowList),
        };
        var expected = new List<string>();
        (int Hid, KeyboardCommand Modifier, ushort VirtualKey)[] modifiers = [
            (225, KeyboardCommand.Shift, 16), (224, KeyboardCommand.Control, 17),
            (226, KeyboardCommand.Option, 18), (227, KeyboardCommand.Command, 17),
        ];
        foreach ((int hid, KeyboardCommand modifier, ushort virtualKey) in modifiers)
        {
            messages.Add(new KeyboardHardwareKeyMessage(hid, [], WindowId: 1, Action: KeyboardCommandAction.Down));
            messages.Add(new KeyboardHardwareKeyMessage(77, [modifier, KeyboardCommand.Function],
                WindowId: 1, Action: KeyboardCommandAction.Down));
            messages.Add(new KeyboardHardwareKeyMessage(77, [modifier, KeyboardCommand.Function],
                WindowId: 1, Action: KeyboardCommandAction.Up));
            messages.Add(new KeyboardHardwareKeyMessage(hid, [], WindowId: 1, Action: KeyboardCommandAction.Up));
            expected.AddRange([$"key:{virtualKey}:Down", "key:35:Down", "key:35:Up", $"key:{virtualKey}:Up"]);
        }
        // A snapshot without its own HID transition still must not invent Option ownership.
        messages.Add(new KeyboardHardwareKeyMessage(77, [KeyboardCommand.Option, KeyboardCommand.Function],
            WindowId: 1, Action: KeyboardCommandAction.Down));
        messages.Add(new KeyboardHardwareKeyMessage(77, [KeyboardCommand.Function],
            WindowId: 1, Action: KeyboardCommandAction.Up));
        expected.AddRange(["key:35:Down", "key:35:Up"]);
        // A disconnected session releases only genuinely injected held keys, once.
        messages.Add(new KeyboardHardwareKeyMessage(225, [], WindowId: 1, Action: KeyboardCommandAction.Down));
        messages.Add(new KeyboardHardwareKeyMessage(77, [KeyboardCommand.Shift, KeyboardCommand.Function],
            WindowId: 1, Action: KeyboardCommandAction.Down));
        expected.AddRange(["key:16:Down", "key:35:Down"]);
        ScriptedDuplexStream stream = await RunCompletedSessionAsync(CombineLines(messages.ToArray()),
            identity, new FakeWindowEnumerator([window]), inputSessionFactory: factory).ConfigureAwait(false);
        Equal(2, ReadOutputLines(stream).Count);
        True(injector.Calls.SequenceEqual(expected, StringComparer.Ordinal));
        Equal(1, injector.ReleaseCount);
        True(injector.ReleasedVirtualKeys.Order().SequenceEqual(new ushort[] { 16, 35 }));

        var revokedInjector = new RecordingInputInjector();
        using var revokedSession = new WindowsHostInputSession(gate,
            new RecordingWindowInputTargetResolver(window.Bounds), revokedInjector);
        True(revokedSession.HandleKeyboardHardwareKey(new KeyboardHardwareKeyMessage(
            225, [], WindowId: 1, Action: KeyboardCommandAction.Down), window).Succeeded);
        True(revokedSession.HandleKeyboardHardwareKey(new KeyboardHardwareKeyMessage(
            77, [KeyboardCommand.Shift, KeyboardCommand.Function],
            WindowId: 1, Action: KeyboardCommandAction.Down), window).Succeeded);
        gate.SetEnabled(false);
        Equal(1, revokedInjector.ReleaseCount);
        True(revokedInjector.ReleasedVirtualKeys.Order().SequenceEqual(new ushort[] { 16, 35 }));
        True(!revokedSession.HandleKeyboardHardwareKey(new KeyboardHardwareKeyMessage(
            77, [KeyboardCommand.Function], WindowId: 1, Action: KeyboardCommandAction.Up), window).Succeeded);
        Equal(1, revokedInjector.ReleaseCount);
        True(revokedInjector.Calls.SequenceEqual(["key:16:Down", "key:35:Down"], StringComparer.Ordinal));
    }

    private static async Task HardwareFunctionMetadataRejectsInvalidLists()
    {
        const string identity = "mac-invalid-function-client";
        WindowDescriptor window = CreateVideoWindow();
        var gate = new InputPermissionGate();
        gate.SetEnabled(true);
        var injector = new RecordingInputInjector();
        var resolver = new RecordingWindowInputTargetResolver(window.Bounds);
        var factory = new DelegateHostInputSessionFactory(() =>
            new WindowsHostInputSession(gate, resolver, injector));
        IReadOnlyList<KeyboardCommand>[] invalid = [
            [KeyboardCommand.Function, KeyboardCommand.F1],
            [KeyboardCommand.Function, KeyboardCommand.ReturnKey],
            Enumerable.Repeat(KeyboardCommand.Function, 9).ToArray(),
            Enumerable.Repeat(KeyboardCommand.Function, 8).Append(KeyboardCommand.Shift).ToArray(),
        ];
        var messages = new List<object> {
            PeelHello.CreateClient(identity, "Mac", "macOS"),
            new PeelRequest(PeelMessageType.RequestWindowList),
        };
        foreach (IReadOnlyList<KeyboardCommand> modifiers in invalid)
        {
            foreach (KeyboardCommandAction action in Enum.GetValues<KeyboardCommandAction>())
            {
                messages.Add(new KeyboardHardwareKeyMessage(77, modifiers, WindowId: 1, Action: action));
            }
        }
        ScriptedDuplexStream stream = await RunCompletedSessionAsync(CombineLines(messages.ToArray()),
            identity, new FakeWindowEnumerator([window]), inputSessionFactory: factory).ConfigureAwait(false);
        IReadOnlyList<byte[]> lines = ReadOutputLines(stream);
        Equal(2 + invalid.Length * Enum.GetValues<KeyboardCommandAction>().Length, lines.Count);
        foreach (byte[] line in lines.Skip(2))
        {
            InputRejectedMessage rejected = PeelJson.Deserialize<InputRejectedMessage>(line);
            Equal<uint>(1, rejected.WindowId);
            Equal("The hardware-key modifiers are invalid or oversized.", rejected.Reason);
        }
        Equal(0, injector.Calls.Count);
        Equal(0, resolver.ResolveCount);
    }

    private static async Task HardwareFunctionMetadataRejectsUnknownWireNames()
    {
        foreach (string modifier in new[] { "numericPad", "capsLock", "fn", "unknownModifier" })
        {
            const string identity = "mac-unknown-function-client";
            var unknown = new {
                type = "keyboardHardwareKey", windowId = 1, keyCode = 77,
                modifiers = new[] { "function", modifier }, action = "down",
            };
            Throws<JsonException>(() => PeelJson.Deserialize<KeyboardHardwareKeyMessage>(PeelJson.SerializeLine(unknown)));
            WindowDescriptor window = CreateVideoWindow();
            var gate = new InputPermissionGate();
            gate.SetEnabled(true);
            var injector = new RecordingInputInjector();
            var resolver = new RecordingWindowInputTargetResolver(window.Bounds);
            var factory = new DelegateHostInputSessionFactory(() =>
                new WindowsHostInputSession(gate, resolver, injector));
            ScriptedDuplexStream stream = await RunCompletedSessionAsync(CombineLines(
                PeelHello.CreateClient(identity, "Mac", "macOS"),
                new PeelRequest(PeelMessageType.RequestWindowList),
                unknown,
                new KeyboardHardwareKeyMessage(77, [KeyboardCommand.Function], WindowId: 1)),
                identity, new FakeWindowEnumerator([window]), inputSessionFactory: factory).ConfigureAwait(false);
            Equal(2, ReadOutputLines(stream).Count);
            Equal(0, injector.Calls.Count);
            Equal(0, resolver.ResolveCount);
        }
    }
}
