using Peel.Windows.Host.Windows;
using Peel.Windows.Protocol;

namespace Peel.Windows.Host.Input;

internal interface IHostInputSessionFactory
{
    IHostInputSession Create();
}

internal interface IHostInputSession : IDisposable
{
    InputInjectionResult HandleClientActiveWindow(WindowDescriptor window);

    InputInjectionResult HandleMouse(PeelRequest request, WindowDescriptor window);

    InputInjectionResult HandleKeyboardText(
        KeyboardTextMessage message,
        WindowDescriptor window);

    InputInjectionResult HandleKeyboardCommand(
        KeyboardCommandMessage message,
        WindowDescriptor window);

    InputInjectionResult HandleKeyboardHardwareKey(
        KeyboardHardwareKeyMessage message,
        WindowDescriptor window);

    InputInjectionResult HandleKeyboardChord(
        KeyboardChordMessage message,
        WindowDescriptor window);

    InputInjectionResult HandleKeyboardMacro(
        KeyboardMacroMessage message,
        WindowDescriptor window);

    /// <summary>Applies the remote-input admission (session, master gate, current window) without an OS effect.</summary>
    InputInjectionResult AdmitSourceInput(WindowDescriptor window) =>
        InputInjectionResult.Rejected("Source controls are not supported by this input session.");

    /// <summary>Posts one source media key at this computer through the same admission as other remote input.</summary>
    InputInjectionResult HandleSourceMediaKey(SourceMediaAction action, WindowDescriptor window) =>
        InputInjectionResult.Rejected("Source media keys are not supported by this input session.");

    /// <summary>
    /// Runs one source system-volume write after the same admission, holding the master input gate
    /// for the duration of the OS effect exactly as SendInput does.
    /// </summary>
    InputInjectionResult HandleSourceVolume(WindowDescriptor window, Func<InputInjectionResult> apply) =>
        InputInjectionResult.Rejected("Source volume is not supported by this input session.");
}

internal sealed class WindowsHostInputSessionFactory(
    InputPermissionGate permissionGate) : IHostInputSessionFactory
{
    private readonly InputPermissionGate permissionGate = permissionGate ??
        throw new ArgumentNullException(nameof(permissionGate));

    public IHostInputSession Create() => new WindowsHostInputSession(
        permissionGate,
        new WindowsWindowInputTargetResolver(),
        new WindowsInputInjector(permissionGate));
}

internal sealed class WindowsHostInputSession : IHostInputSession
{
    private const int MaximumModifierCount = 8;
    private const int MaximumChordKeyCount = 16;
    private const int MaximumHardwareCharacterCount = 8;
    private const int MaximumTextCodeUnits = 4096;
    private const double ScrollScale = 0.5;
    private const int MaximumWheelDeltaMagnitude = 1200;

    // Covers admitted native work through held-state bookkeeping AND release.
    // Permission notifications are invoked outside InputPermissionGate's lock.
    private readonly object lifecycleGate = new();
    private readonly object stateLock = new();
    private readonly InputPermissionGate permissionGate;
    private readonly IWindowInputTargetResolver targetResolver;
    private readonly IHostInputInjector injector;
    private readonly Dictionary<MouseButton, WindowIdentity> heldMouseButtons = [];
    private readonly HashSet<ushort> heldVirtualKeys = [];
    private readonly Dictionary<WindowIdentity, (double X, double Y)> lastPointerByWindow = [];
    private readonly Dictionary<WindowIdentity, (double Horizontal, double Vertical)>
        scrollResidualByWindow = [];
    private bool disposed;

    internal WindowsHostInputSession(
        InputPermissionGate permissionGate,
        IWindowInputTargetResolver targetResolver,
        IHostInputInjector injector)
    {
        this.permissionGate = permissionGate ??
            throw new ArgumentNullException(nameof(permissionGate));
        this.targetResolver = targetResolver ??
            throw new ArgumentNullException(nameof(targetResolver));
        this.injector = injector ?? throw new ArgumentNullException(nameof(injector));
        this.permissionGate.Disabled += HandlePermissionDisabled;
    }

    public InputInjectionResult HandleMouse(PeelRequest request, WindowDescriptor window)
    {
        lock (lifecycleGate) return HandleMouseCore(request, window);
    }

    public InputInjectionResult HandleClientActiveWindow(WindowDescriptor window)
    {
        lock (lifecycleGate) return HandleClientActiveWindowCore(window);
    }

    public InputInjectionResult HandleKeyboardText(KeyboardTextMessage message, WindowDescriptor window)
    {
        lock (lifecycleGate) return HandleKeyboardTextCore(message, window);
    }

    public InputInjectionResult HandleKeyboardCommand(KeyboardCommandMessage message, WindowDescriptor window)
    {
        lock (lifecycleGate) return HandleKeyboardCommandCore(message, window);
    }

    public InputInjectionResult HandleKeyboardHardwareKey(KeyboardHardwareKeyMessage message, WindowDescriptor window)
    {
        lock (lifecycleGate) return HandleKeyboardHardwareKeyCore(message, window);
    }

    public InputInjectionResult HandleKeyboardChord(KeyboardChordMessage message, WindowDescriptor window)
    {
        lock (lifecycleGate) return HandleKeyboardChordCore(message, window);
    }

    public InputInjectionResult HandleKeyboardMacro(KeyboardMacroMessage message, WindowDescriptor window)
    {
        lock (lifecycleGate) return HandleKeyboardMacroCore(message, window);
    }

    public InputInjectionResult AdmitSourceInput(WindowDescriptor window)
    {
        lock (lifecycleGate) return AdmitSourceInputCore(window);
    }

    public InputInjectionResult HandleSourceMediaKey(SourceMediaAction action, WindowDescriptor window)
    {
        lock (lifecycleGate)
        {
            ushort virtualKey = action switch
            {
                SourceMediaAction.PlayPause => WindowsInputInjector.MediaPlayPause,
                SourceMediaAction.PreviousTrack => WindowsInputInjector.MediaPreviousTrack,
                SourceMediaAction.NextTrack => WindowsInputInjector.MediaNextTrack,
                _ => (ushort)0,
            };
            if (virtualKey == 0)
            {
                return InputInjectionResult.Rejected("The source media action is unsupported.");
            }

            InputInjectionResult admission = AdmitSourceInputCore(window);
            return admission.Succeeded ? injector.SendMediaKey(virtualKey) : admission;
        }
    }

    public InputInjectionResult HandleSourceVolume(WindowDescriptor window, Func<InputInjectionResult> apply)
    {
        ArgumentNullException.ThrowIfNull(apply);
        lock (lifecycleGate)
        {
            InputInjectionResult admission = AdmitSourceInputCore(window);
            return admission.Succeeded ? permissionGate.ExecuteIfEnabled(apply) : admission;
        }
    }

    // Media keys are system-wide on the source: the streamed window must still be the
    // current, same-identity, input-eligible target, but focus is never taken.
    private InputInjectionResult AdmitSourceInputCore(WindowDescriptor window)
    {
        ArgumentNullException.ThrowIfNull(window);
        InputInjectionResult? unavailable = RejectIfUnavailable();
        if (unavailable is not null)
        {
            return unavailable;
        }

        WindowInputTargetResult target = targetResolver.Resolve(window, WindowInputFocusMode.None);
        return target.Succeeded
            ? InputInjectionResult.Success
            : InputInjectionResult.Rejected(target.Error!);
    }

    private InputInjectionResult HandleMouseCore(PeelRequest request, WindowDescriptor window)
    {
        ArgumentNullException.ThrowIfNull(request);
        InputInjectionResult? unavailable = RejectIfUnavailable();
        if (unavailable is not null)
        {
            return unavailable;
        }

        if (StringComparer.Ordinal.Equals(request.Type, PeelMessageType.MouseScroll))
        {
            return HandleScroll(request, window);
        }

        if (request.NormX is not double normalizedX ||
            request.NormY is not double normalizedY ||
            !double.IsFinite(normalizedX) ||
            !double.IsFinite(normalizedY))
        {
            return InputInjectionResult.Rejected(
                "Pointer input requires finite normalized coordinates.");
        }

        if (StringComparer.Ordinal.Equals(request.Type, PeelMessageType.MouseMove))
        {
            WindowInputTargetResult moveTarget = targetResolver.Resolve(
                window,
                WindowInputFocusMode.None);
            InputInjectionResult moveResult = moveTarget.Succeeded
                ? injector.MovePointer(moveTarget.Bounds, normalizedX, normalizedY)
                : InputInjectionResult.Rejected(moveTarget.Error!);
            if (moveResult.Succeeded)
            {
                TrackPointer(window, normalizedX, normalizedY);
            }

            return moveResult;
        }

        if (!TryParseMouseButton(request.Button, out MouseButton button))
        {
            return InputInjectionResult.Rejected("The requested mouse button is unsupported.");
        }

        MouseButtonAction action;
        WindowInputFocusMode focusMode;
        if (StringComparer.Ordinal.Equals(request.Type, PeelMessageType.MouseClick))
        {
            action = MouseButtonAction.Press;
            focusMode = WindowInputFocusMode.AcquireForeground;
        }
        else if (StringComparer.Ordinal.Equals(request.Type, PeelMessageType.MouseDown))
        {
            action = MouseButtonAction.Down;
            focusMode = WindowInputFocusMode.AcquireForeground;
        }
        else if (StringComparer.Ordinal.Equals(request.Type, PeelMessageType.MouseUp))
        {
            action = MouseButtonAction.Up;
            focusMode = WindowInputFocusMode.None;

            WindowIdentity requestedIdentity = WindowIdentity.For(window);
            bool recoverWithoutMoving;
            lock (stateLock)
            {
                recoverWithoutMoving =
                    heldMouseButtons.TryGetValue(button, out WindowIdentity heldIdentity) &&
                    heldIdentity != requestedIdentity;
            }

            if (recoverWithoutMoving)
            {
                InputInjectionResult recovery = injector.SendMouseButton(
                    button,
                    MouseButtonAction.Up);
                if (recovery.Succeeded)
                {
                    lock (stateLock)
                    {
                        heldMouseButtons.Remove(button);
                    }
                }

                return recovery;
            }
        }
        else if (StringComparer.Ordinal.Equals(request.Type, PeelMessageType.MouseDrag))
        {
            lock (stateLock)
            {
                if (!heldMouseButtons.TryGetValue(button, out WindowIdentity heldIdentity) ||
                    heldIdentity != WindowIdentity.For(window))
                {
                    return InputInjectionResult.Rejected(
                        "A mouse drag was received without a matching held button and window.");
                }
            }

            WindowInputTargetResult dragTarget = targetResolver.Resolve(
                window,
                WindowInputFocusMode.RequireForeground);
            InputInjectionResult dragResult = dragTarget.Succeeded
                ? injector.MovePointer(dragTarget.Bounds, normalizedX, normalizedY)
                : InputInjectionResult.Rejected(dragTarget.Error!);
            if (dragResult.Succeeded)
            {
                TrackPointer(window, normalizedX, normalizedY);
            }

            return dragResult;
        }
        else
        {
            return InputInjectionResult.Rejected("The requested pointer action is unsupported.");
        }

        WindowInputTargetResult target = targetResolver.Resolve(window, focusMode);
        if (!target.Succeeded)
        {
            return InputInjectionResult.Rejected(target.Error!);
        }

        InputInjectionResult result = injector.SendPointerButton(
            target.Bounds,
            normalizedX,
            normalizedY,
            button,
            action);
        if (result.Succeeded)
        {
            TrackPointer(window, normalizedX, normalizedY);
        }

        if (result.Succeeded && action == MouseButtonAction.Down)
        {
            TrackHeldMouseButton(button, window);
        }
        else if (result.Succeeded && action == MouseButtonAction.Up)
        {
            lock (stateLock)
            {
                heldMouseButtons.Remove(button);
            }
        }

        return result;
    }

    private InputInjectionResult HandleClientActiveWindowCore(WindowDescriptor window)
    {
        ArgumentNullException.ThrowIfNull(window);
        InputInjectionResult? unavailable = RejectIfUnavailable();
        if (unavailable is not null)
        {
            return unavailable;
        }

        return permissionGate.ExecuteIfEnabled(() =>
        {
            WindowInputTargetResult target = targetResolver.Resolve(
                window,
                WindowInputFocusMode.AcquireForeground);
            return target.Succeeded
                ? InputInjectionResult.Success
                : InputInjectionResult.Rejected(target.Error!);
        });
    }

    private InputInjectionResult HandleKeyboardTextCore(
        KeyboardTextMessage message,
        WindowDescriptor window)
    {
        ArgumentNullException.ThrowIfNull(message);
        InputInjectionResult? unavailable = RejectIfUnavailable();
        if (unavailable is not null)
        {
            return unavailable;
        }

        if (message.Text is null || message.Text.Length > MaximumTextCodeUnits)
        {
            return InputInjectionResult.Rejected(
                $"Keyboard text must not exceed {MaximumTextCodeUnits} UTF-16 code units.");
        }

        WindowInputTargetResult target = targetResolver.Resolve(
            window,
            WindowInputFocusMode.AcquireForeground);
        return target.Succeeded
            ? injector.SendText(message.Text)
            : InputInjectionResult.Rejected(target.Error!);
    }

    private InputInjectionResult HandleKeyboardCommandCore(
        KeyboardCommandMessage message,
        WindowDescriptor window)
    {
        ArgumentNullException.ThrowIfNull(message);
        InputInjectionResult? unavailable = RejectIfUnavailable();
        if (unavailable is not null)
        {
            return unavailable;
        }

        if (!TryMapCommand(message.Command, out ushort virtualKey))
        {
            return InputInjectionResult.Rejected("The requested keyboard command is unsupported.");
        }

        IReadOnlyList<KeyboardCommand> modifiers = message.Modifiers ?? [];
        if (modifiers.Count > MaximumModifierCount ||
            !TryMapCommands(modifiers, out IReadOnlyList<ushort> modifierKeys))
        {
            return InputInjectionResult.Rejected("The keyboard modifier set is invalid or oversized.");
        }

        KeyboardCommandAction action = message.Action ?? KeyboardCommandAction.Press;
        if (action != KeyboardCommandAction.Press && modifierKeys.Count != 0)
        {
            return InputInjectionResult.Rejected(
                "Held keyboard commands cannot carry transient modifiers.");
        }

        WindowInputTargetResult target = targetResolver.Resolve(
            window,
            action == KeyboardCommandAction.Up
                ? WindowInputFocusMode.None
                : WindowInputFocusMode.AcquireForeground);
        if (!target.Succeeded)
        {
            return InputInjectionResult.Rejected(target.Error!);
        }

        if (action == KeyboardCommandAction.Press && modifierKeys.Count != 0)
        {
            ushort[] chord = [.. modifierKeys.Where(key => key != virtualKey), virtualKey];
            return injector.SendVirtualKeyChord(chord);
        }

        VirtualKeyAction virtualKeyAction = ToVirtualKeyAction(action);
        InputInjectionResult result = injector.SendVirtualKey(virtualKey, virtualKeyAction);
        UpdateHeldVirtualKey(virtualKey, virtualKeyAction, result.Succeeded);
        return result;
    }

    private InputInjectionResult HandleKeyboardHardwareKeyCore(
        KeyboardHardwareKeyMessage message,
        WindowDescriptor window)
    {
        ArgumentNullException.ThrowIfNull(message);
        InputInjectionResult? unavailable = RejectIfUnavailable();
        if (unavailable is not null)
        {
            return unavailable;
        }

        if (message.KeyCode is < 0 or > ushort.MaxValue ||
            message.Characters is { Length: > MaximumHardwareCharacterCount } ||
            message.CharactersIgnoringModifiers is { Length: > MaximumHardwareCharacterCount } ||
            !TryMapHardwareKey(message, out ushort virtualKey))
        {
            return InputInjectionResult.Rejected(
                "The hardware key cannot be mapped safely to a Windows virtual key.");
        }

        IReadOnlyList<KeyboardCommand> modifiers = message.Modifiers ?? [];
        // AppKit also marks navigation/F keys with Function. It is metadata,
        // not a Windows modifier; validate the raw count before filtering it.
        if (modifiers.Count > MaximumModifierCount ||
            modifiers.Any(static modifier => modifier is not (
                KeyboardCommand.Shift or KeyboardCommand.Control or
                KeyboardCommand.Command or KeyboardCommand.Option or
                KeyboardCommand.Function)) ||
            !TryMapCommands(
                modifiers.Where(static modifier => modifier != KeyboardCommand.Function).ToArray(),
                out IReadOnlyList<ushort> modifierKeys))
        {
            return InputInjectionResult.Rejected("The hardware-key modifiers are invalid or oversized.");
        }

        KeyboardCommandAction action = message.Action ?? KeyboardCommandAction.Press;
        // Apple receivers send modifier HID transitions separately. On held-key
        // events this list is an aggregate snapshot, not a transient chord.
        // Only the actual key owns a down/up transition and held-input cleanup.

        WindowInputTargetResult target = targetResolver.Resolve(
            window,
            action == KeyboardCommandAction.Up
                ? WindowInputFocusMode.None
                : WindowInputFocusMode.AcquireForeground);
        if (!target.Succeeded)
        {
            return InputInjectionResult.Rejected(target.Error!);
        }

        if (action == KeyboardCommandAction.Press && modifierKeys.Count != 0)
        {
            ushort[] chord = [.. modifierKeys.Where(key => key != virtualKey), virtualKey];
            return injector.SendVirtualKeyChord(chord);
        }

        VirtualKeyAction virtualKeyAction = ToVirtualKeyAction(action);
        InputInjectionResult result = injector.SendVirtualKey(virtualKey, virtualKeyAction);
        UpdateHeldVirtualKey(virtualKey, virtualKeyAction, result.Succeeded);
        return result;
    }

    private InputInjectionResult HandleKeyboardChordCore(
        KeyboardChordMessage message,
        WindowDescriptor window)
    {
        ArgumentNullException.ThrowIfNull(message);
        InputInjectionResult? unavailable = RejectIfUnavailable();
        if (unavailable is not null)
        {
            return unavailable;
        }

        IReadOnlyList<KeyboardCommand>? keys = message.Chord?.Keys;
        if (keys is null ||
            keys.Count is < 1 or > MaximumChordKeyCount ||
            !TryMapCommands(keys, out IReadOnlyList<ushort> virtualKeys))
        {
            return InputInjectionResult.Rejected("The keyboard chord is invalid or oversized.");
        }

        WindowInputTargetResult target = targetResolver.Resolve(
            window,
            WindowInputFocusMode.AcquireForeground);
        return target.Succeeded
            ? injector.SendVirtualKeyChord(virtualKeys)
            : InputInjectionResult.Rejected(target.Error!);
    }

    private InputInjectionResult HandleKeyboardMacroCore(
        KeyboardMacroMessage message,
        WindowDescriptor window)
    {
        _ = message;
        _ = window;
        return InputInjectionResult.Rejected(
            "Keyboard macros are not advertised or enabled by this Windows Host.");
    }

    public void Dispose()
    {
        lock (lifecycleGate) DisposeCore();
    }

    private void DisposeCore()
    {
        lock (stateLock)
        {
            if (disposed)
            {
                return;
            }

            disposed = true;
        }

        permissionGate.Disabled -= HandlePermissionDisabled;
        ReleaseHeldInputs();
    }

    private InputInjectionResult HandleScroll(PeelRequest request, WindowDescriptor window)
    {
        double horizontal = request.NormX ?? 0;
        if (request.NormY is not double vertical ||
            !double.IsFinite(horizontal) ||
            !double.IsFinite(vertical))
        {
            return InputInjectionResult.Rejected(
                "Scroll input requires a finite vertical delta and an optional finite horizontal delta.");
        }

        (int horizontalDelta, int verticalDelta) = TakeWheelDeltas(window, horizontal, vertical);
        WindowInputTargetResult target = targetResolver.Resolve(
            window,
            WindowInputFocusMode.AcquireForeground);
        if (!target.Succeeded)
        {
            return InputInjectionResult.Rejected(target.Error!);
        }

        (double X, double Y) pointer = GetLastPointer(window);
        InputInjectionResult move = injector.MovePointer(target.Bounds, pointer.X, pointer.Y);
        if (!move.Succeeded || horizontalDelta == 0 && verticalDelta == 0)
        {
            return move;
        }

        return injector.SendMouseWheel(verticalDelta, horizontalDelta);
    }

    private InputInjectionResult? RejectIfUnavailable()
    {
        lock (stateLock)
        {
            if (disposed)
            {
                return InputInjectionResult.Rejected("The remote input session has ended.");
            }
        }

        return permissionGate.IsEnabled
            ? null
            : InputInjectionResult.Rejected(InputPermissionGate.DisabledReason);
    }

    private void TrackHeldMouseButton(MouseButton button, WindowDescriptor window)
    {
        bool releaseImmediately;
        lock (stateLock)
        {
            releaseImmediately = disposed || !permissionGate.IsEnabled;
            if (!releaseImmediately)
            {
                heldMouseButtons[button] = WindowIdentity.For(window);
            }
        }

        if (releaseImmediately)
        {
            _ = injector.ReleaseHeldInputs([button], []);
        }
    }

    private void TrackPointer(
        WindowDescriptor window,
        double normalizedX,
        double normalizedY)
    {
        lock (stateLock)
        {
            lastPointerByWindow[WindowIdentity.For(window)] =
                (Math.Clamp(normalizedX, 0, 1), Math.Clamp(normalizedY, 0, 1));
        }
    }

    private (double X, double Y) GetLastPointer(WindowDescriptor window)
    {
        lock (stateLock)
        {
            return lastPointerByWindow.TryGetValue(
                WindowIdentity.For(window),
                out (double X, double Y) pointer)
                ? pointer
                : (0.5, 0.5);
        }
    }

    private void UpdateHeldVirtualKey(
        ushort virtualKey,
        VirtualKeyAction action,
        bool succeeded)
    {
        if (!succeeded || action == VirtualKeyAction.Press)
        {
            return;
        }

        bool releaseImmediately = false;
        lock (stateLock)
        {
            if (action == VirtualKeyAction.Down)
            {
                releaseImmediately = disposed || !permissionGate.IsEnabled;
                if (!releaseImmediately)
                {
                    heldVirtualKeys.Add(virtualKey);
                }
            }
            else
            {
                heldVirtualKeys.Remove(virtualKey);
            }
        }

        if (releaseImmediately)
        {
            _ = injector.ReleaseHeldInputs([], [virtualKey]);
        }
    }

    private void HandlePermissionDisabled()
    {
        // A replacement must wait for recovery already in flight even if its
        // tracked sets were cleared before the native key-up call returned.
        lock (lifecycleGate) ReleaseHeldInputs();
    }

    private void ReleaseHeldInputs()
    {
        MouseButton[] mouseButtons;
        ushort[] virtualKeys;
        lock (stateLock)
        {
            mouseButtons = heldMouseButtons.Keys.ToArray();
            virtualKeys = heldVirtualKeys.ToArray();
            heldMouseButtons.Clear();
            heldVirtualKeys.Clear();
            scrollResidualByWindow.Clear();
        }

        if (mouseButtons.Length != 0 || virtualKeys.Length != 0)
        {
            _ = injector.ReleaseHeldInputs(mouseButtons, virtualKeys);
        }
    }

    private (int Horizontal, int Vertical) TakeWheelDeltas(
        WindowDescriptor window,
        double horizontal,
        double vertical)
    {
        var identity = WindowIdentity.For(window);
        lock (stateLock)
        {
            (double previousHorizontal, double previousVertical) =
                scrollResidualByWindow.GetValueOrDefault(identity);
            double accumulatedHorizontal = previousHorizontal + ScaleWheelDelta(horizontal);
            double accumulatedVertical = previousVertical + ScaleWheelDelta(vertical);
            int wholeHorizontal = checked((int)Math.Truncate(accumulatedHorizontal));
            int wholeVertical = checked((int)Math.Truncate(accumulatedVertical));
            scrollResidualByWindow[identity] = (
                accumulatedHorizontal - wholeHorizontal,
                accumulatedVertical - wholeVertical);
            return (wholeHorizontal, wholeVertical);
        }
    }

    private static double ScaleWheelDelta(double value) =>
        Math.Clamp(
            value * ScrollScale,
            -MaximumWheelDeltaMagnitude,
            MaximumWheelDeltaMagnitude);

    private static bool TryParseMouseButton(string? value, out MouseButton button)
    {
        switch (value)
        {
            case null:
            case "left":
                button = MouseButton.Left;
                return true;
            case "right":
                button = MouseButton.Right;
                return true;
            case "middle":
                button = MouseButton.Middle;
                return true;
            case "x1":
                button = MouseButton.X1;
                return true;
            case "x2":
                button = MouseButton.X2;
                return true;
            default:
                button = default;
                return false;
        }
    }

    private static bool TryMapCommands(
        IReadOnlyList<KeyboardCommand> commands,
        out IReadOnlyList<ushort> virtualKeys)
    {
        var mapped = new List<ushort>(commands.Count);
        foreach (KeyboardCommand command in commands)
        {
            if (!TryMapCommand(command, out ushort virtualKey))
            {
                virtualKeys = [];
                return false;
            }

            if (!mapped.Contains(virtualKey))
            {
                mapped.Add(virtualKey);
            }
        }

        virtualKeys = mapped;
        return true;
    }

    private static bool TryMapCommand(KeyboardCommand command, out ushort virtualKey)
    {
        virtualKey = command switch
        {
            KeyboardCommand.Backspace or KeyboardCommand.Delete => 0x08,
            KeyboardCommand.ForwardDelete => 0x2E,
            KeyboardCommand.Enter or KeyboardCommand.ReturnKey => 0x0D,
            KeyboardCommand.Space => 0x20,
            KeyboardCommand.Tab => 0x09,
            KeyboardCommand.Escape => 0x1B,
            KeyboardCommand.LeftArrow => 0x25,
            KeyboardCommand.UpArrow => 0x26,
            KeyboardCommand.RightArrow => 0x27,
            KeyboardCommand.DownArrow => 0x28,
            KeyboardCommand.Home => 0x24,
            KeyboardCommand.End => 0x23,
            KeyboardCommand.PageUp => 0x21,
            KeyboardCommand.PageDown => 0x22,
            KeyboardCommand.Command => 0x11,
            KeyboardCommand.Option => 0x12,
            KeyboardCommand.Control => 0x11,
            KeyboardCommand.Shift => 0x10,
            KeyboardCommand.F1 => 0x70,
            KeyboardCommand.F2 => 0x71,
            KeyboardCommand.F3 => 0x72,
            KeyboardCommand.F4 => 0x73,
            KeyboardCommand.F5 => 0x74,
            KeyboardCommand.F6 => 0x75,
            KeyboardCommand.F7 => 0x76,
            KeyboardCommand.F8 => 0x77,
            KeyboardCommand.F9 => 0x78,
            KeyboardCommand.F10 => 0x79,
            KeyboardCommand.F11 => 0x7A,
            KeyboardCommand.F12 => 0x7B,
            _ => 0,
        };
        return virtualKey != 0;
    }

    private static bool TryMapHardwareKey(
        KeyboardHardwareKeyMessage message,
        out ushort virtualKey)
    {
        if (ShouldPreferKeyboardHidUsage(message.KeyCode) &&
            TryMapKeyboardHidUsage(message.KeyCode, out virtualKey))
        {
            return true;
        }

        if (message.CharactersIgnoringModifiers is { Length: 1 } charactersIgnoringModifiers &&
            TryMapHardwareCharacter(charactersIgnoringModifiers[0], out virtualKey))
        {
            return true;
        }

        if (message.Characters is { Length: 1 } characters &&
            TryMapHardwareCharacter(characters[0], out virtualKey))
        {
            return true;
        }

        return TryMapKeyboardHidUsage(message.KeyCode, out virtualKey);
    }

    private static bool ShouldPreferKeyboardHidUsage(int usage) =>
        usage is >= 40 and <= 44 or
            >= 58 and <= 69 or
            >= 73 and <= 82 or
            >= 224 and <= 231;

    private static bool TryMapKeyboardHidUsage(int usage, out ushort virtualKey)
    {
        virtualKey = usage switch
        {
            >= 4 and <= 29 => checked((ushort)('A' + usage - 4)),
            >= 30 and <= 38 => checked((ushort)('1' + usage - 30)),
            39 => '0',
            40 => 0x0D,
            41 => 0x1B,
            42 => 0x08,
            43 => 0x09,
            44 => 0x20,
            45 => 0xBD,
            46 => 0xBB,
            47 => 0xDB,
            48 => 0xDD,
            49 => 0xDC,
            51 => 0xBA,
            52 => 0xDE,
            53 => 0xC0,
            54 => 0xBC,
            55 => 0xBE,
            56 => 0xBF,
            57 => 0x14,
            >= 58 and <= 69 => checked((ushort)(0x70 + usage - 58)),
            73 => 0x2D,
            74 => 0x24,
            75 => 0x21,
            76 => 0x2E,
            77 => 0x23,
            78 => 0x22,
            79 => 0x27,
            80 => 0x25,
            81 => 0x28,
            82 => 0x26,
            224 or 228 or 227 or 231 => 0x11,
            225 or 229 => 0x10,
            226 or 230 => 0x12,
            _ => 0,
        };
        return virtualKey != 0;
    }

    private static bool TryMapHardwareCharacter(char character, out ushort virtualKey)
    {
        char upper = char.ToUpperInvariant(character);
        if (upper is >= 'A' and <= 'Z' or >= '0' and <= '9')
        {
            virtualKey = upper;
            return true;
        }

        virtualKey = character switch
        {
            ' ' => 0x20,
            '-' or '_' => 0xBD,
            '=' or '+' => 0xBB,
            '[' or '{' => 0xDB,
            ']' or '}' => 0xDD,
            '\\' or '|' => 0xDC,
            ';' or ':' => 0xBA,
            '\'' or '"' => 0xDE,
            '`' or '~' => 0xC0,
            ',' or '<' => 0xBC,
            '.' or '>' => 0xBE,
            '/' or '?' => 0xBF,
            _ => 0,
        };
        return virtualKey != 0;
    }

    private static VirtualKeyAction ToVirtualKeyAction(KeyboardCommandAction action) =>
        action switch
        {
            KeyboardCommandAction.Down => VirtualKeyAction.Down,
            KeyboardCommandAction.Up => VirtualKeyAction.Up,
            _ => VirtualKeyAction.Press,
        };

    private readonly record struct WindowIdentity(
        CaptureSourceKind SourceKind,
        nint Handle,
        uint ProcessId)
    {
        internal static WindowIdentity For(WindowDescriptor window) =>
            new(window.SourceKind, window.Handle, window.ProcessId);
    }
}
