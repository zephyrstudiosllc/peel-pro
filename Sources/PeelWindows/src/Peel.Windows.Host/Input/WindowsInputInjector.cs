using System.ComponentModel;
using System.Runtime.InteropServices;
using Peel.Windows.Host.Interop;
using Peel.Windows.Host.Windows;

namespace Peel.Windows.Host.Input;

public interface IHostInputInjector
{
    InputInjectionResult MovePointer(
        WindowBounds targetWindow,
        double normalizedX,
        double normalizedY);

    InputInjectionResult SendPointerButton(
        WindowBounds targetWindow,
        double normalizedX,
        double normalizedY,
        MouseButton button,
        MouseButtonAction action);

    InputInjectionResult SendMouseButton(MouseButton button, MouseButtonAction action);

    InputInjectionResult SendMouseWheel(int verticalDelta, int horizontalDelta);

    InputInjectionResult SendVirtualKey(ushort virtualKey, VirtualKeyAction action);

    InputInjectionResult SendVirtualKeyChord(IReadOnlyList<ushort> virtualKeys);

    InputInjectionResult SendText(string? text);

    InputInjectionResult ReleaseHeldInputs(
        IReadOnlyCollection<MouseButton> mouseButtons,
        IReadOnlyCollection<ushort> virtualKeys);

    /// <summary>Posts one down/up pair of an allowlisted media virtual key at this computer.</summary>
    InputInjectionResult SendMediaKey(ushort virtualKey) =>
        InputInjectionResult.Rejected("Source media keys are not supported by this input backend.");
}

public sealed class WindowsInputInjector : IHostInputInjector
{
    private const int MaximumTextCodeUnits = 4096;
    private const int MaximumWheelDeltaMagnitude = 1200;

    private readonly InputPermissionGate _permissionGate;

    public WindowsInputInjector(InputPermissionGate permissionGate)
    {
        _permissionGate = permissionGate;
    }

    public InputInjectionResult MovePointer(
        WindowBounds targetWindow,
        double normalizedX,
        double normalizedY)
    {
        return _permissionGate.ExecuteIfEnabled(() =>
        {
            if (!TryCreatePointerMove(
                    targetWindow,
                    normalizedX,
                    normalizedY,
                    out NativeMethods.Input pointerMove,
                    out string? error))
            {
                return InputInjectionResult.Rejected(error!);
            }

            return Send([pointerMove]);
        });
    }

    public InputInjectionResult SendPointerButton(
        WindowBounds targetWindow,
        double normalizedX,
        double normalizedY,
        MouseButton button,
        MouseButtonAction action)
    {
        return _permissionGate.ExecuteIfEnabled(() =>
        {
            if (!TryCreatePointerMove(
                    targetWindow,
                    normalizedX,
                    normalizedY,
                    out NativeMethods.Input pointerMove,
                    out string? pointerError))
            {
                return InputInjectionResult.Rejected(pointerError!);
            }

            if (!TryCreateMouseButtonInputs(
                    button,
                    out NativeMethods.Input down,
                    out NativeMethods.Input up))
            {
                return InputInjectionResult.Rejected("Unknown mouse button.");
            }

            return action switch
            {
                MouseButtonAction.Down => Send([pointerMove, down]),
                MouseButtonAction.Up => Send([pointerMove, up]),
                MouseButtonAction.Press => Send([pointerMove, down, up]),
                _ => InputInjectionResult.Rejected("Unknown mouse button action."),
            };
        });
    }

    public InputInjectionResult SendMouseButton(MouseButton button, MouseButtonAction action)
    {
        return _permissionGate.ExecuteIfEnabled(() =>
        {
            if (!TryCreateMouseButtonInputs(
                    button,
                    out NativeMethods.Input down,
                    out NativeMethods.Input up))
            {
                return InputInjectionResult.Rejected("Unknown mouse button.");
            }

            return action switch
            {
                MouseButtonAction.Down => Send([down]),
                MouseButtonAction.Up => Send([up]),
                MouseButtonAction.Press => Send([down, up]),
                _ => InputInjectionResult.Rejected("Unknown mouse button action."),
            };
        });
    }

    public InputInjectionResult SendMouseWheel(int delta)
        => SendMouseWheel(delta, 0);

    public InputInjectionResult SendMouseWheel(int verticalDelta, int horizontalDelta)
    {
        return _permissionGate.ExecuteIfEnabled(() =>
        {
            int clampedVertical = Math.Clamp(
                verticalDelta,
                -MaximumWheelDeltaMagnitude,
                MaximumWheelDeltaMagnitude);
            int clampedHorizontal = Math.Clamp(
                horizontalDelta,
                -MaximumWheelDeltaMagnitude,
                MaximumWheelDeltaMagnitude);

            if (clampedVertical == 0 && clampedHorizontal == 0)
            {
                return InputInjectionResult.Success;
            }

            var inputs = new List<NativeMethods.Input>(2);
            if (clampedVertical != 0)
            {
                inputs.Add(MouseInput(
                    0,
                    0,
                    unchecked((uint)clampedVertical),
                    NativeMethods.MouseeventfWheel));
            }

            if (clampedHorizontal != 0)
            {
                inputs.Add(MouseInput(
                    0,
                    0,
                    unchecked((uint)clampedHorizontal),
                    NativeMethods.MouseeventfHwheel));
            }

            return Send(inputs.ToArray());
        });
    }

    public InputInjectionResult SendVirtualKey(ushort virtualKey, VirtualKeyAction action)
    {
        return _permissionGate.ExecuteIfEnabled(() =>
        {
            if (virtualKey == 0)
            {
                return InputInjectionResult.Rejected("Virtual key 0 is not valid input.");
            }

            NativeMethods.Input down = KeyboardInput(virtualKey, 0, 0);
            NativeMethods.Input up = KeyboardInput(virtualKey, 0, NativeMethods.KeyeventfKeyUp);

            return action switch
            {
                VirtualKeyAction.Down => Send([down]),
                VirtualKeyAction.Up => Send([up]),
                VirtualKeyAction.Press => Send([down, up]),
                _ => InputInjectionResult.Rejected("Unknown virtual key action."),
            };
        });
    }

    public InputInjectionResult SendText(string? text)
    {
        return _permissionGate.ExecuteIfEnabled(() =>
        {
            if (text is null)
            {
                return InputInjectionResult.Rejected("Text input is missing.");
            }

            if (text.Length == 0)
            {
                return InputInjectionResult.Success;
            }

            if (text.Length > MaximumTextCodeUnits)
            {
                return InputInjectionResult.Rejected(
                    $"Text exceeds the {MaximumTextCodeUnits}-code-unit input limit.");
            }

            var inputs = new NativeMethods.Input[text.Length * 2];
            int inputIndex = 0;

            // KEYEVENTF_UNICODE consumes UTF-16 code units. Sending both halves of a
            // surrogate pair preserves supplementary Unicode characters.
            foreach (char codeUnit in text)
            {
                inputs[inputIndex++] = KeyboardInput(0, codeUnit, NativeMethods.KeyeventfUnicode);
                inputs[inputIndex++] = KeyboardInput(
                    0,
                    codeUnit,
                    NativeMethods.KeyeventfUnicode | NativeMethods.KeyeventfKeyUp);
            }

            return Send(inputs);
        });
    }

    public InputInjectionResult SendVirtualKeyChord(IReadOnlyList<ushort> virtualKeys)
    {
        ArgumentNullException.ThrowIfNull(virtualKeys);
        return _permissionGate.ExecuteIfEnabled(() =>
        {
            if (virtualKeys.Count is < 1 or > 16 || virtualKeys.Any(static key => key == 0))
            {
                return InputInjectionResult.Rejected("The keyboard chord is invalid or oversized.");
            }

            var inputs = new NativeMethods.Input[checked(virtualKeys.Count * 2)];
            for (var index = 0; index < virtualKeys.Count; index++)
            {
                inputs[index] = KeyboardInput(virtualKeys[index], 0, 0);
                inputs[inputs.Length - index - 1] = KeyboardInput(
                    virtualKeys[index],
                    0,
                    NativeMethods.KeyeventfKeyUp);
            }

            return Send(inputs);
        });
    }

    public InputInjectionResult ReleaseHeldInputs(
        IReadOnlyCollection<MouseButton> mouseButtons,
        IReadOnlyCollection<ushort> virtualKeys)
    {
        ArgumentNullException.ThrowIfNull(mouseButtons);
        ArgumentNullException.ThrowIfNull(virtualKeys);
        if (mouseButtons.Count > 5 || virtualKeys.Count > 32)
        {
            return InputInjectionResult.Rejected("The held-input recovery set is oversized.");
        }

        var inputs = new List<NativeMethods.Input>(mouseButtons.Count + virtualKeys.Count);
        foreach (MouseButton button in mouseButtons.Distinct())
        {
            if (TryCreateMouseButtonInputs(button, out _, out NativeMethods.Input up))
            {
                inputs.Add(up);
            }
        }

        foreach (ushort virtualKey in virtualKeys.Where(static key => key != 0).Distinct())
        {
            inputs.Add(KeyboardInput(virtualKey, 0, NativeMethods.KeyeventfKeyUp));
        }

        return inputs.Count == 0 ? InputInjectionResult.Success : Send(inputs.ToArray());
    }

    public InputInjectionResult SendMediaKey(ushort virtualKey)
    {
        return _permissionGate.ExecuteIfEnabled(() =>
        {
            // Only the three transport keys; never a general virtual-key path.
            if (virtualKey is not (MediaNextTrack or MediaPreviousTrack or MediaPlayPause))
            {
                return InputInjectionResult.Rejected("The media key is not allowed.");
            }

            NativeMethods.Input down = KeyboardInput(virtualKey, 0, NativeMethods.KeyeventfExtendedKey);
            NativeMethods.Input up = KeyboardInput(
                virtualKey,
                0,
                NativeMethods.KeyeventfExtendedKey | NativeMethods.KeyeventfKeyUp);
            InputInjectionResult result = Send([down, up]);
            if (!result.Succeeded)
            {
                // A partially accepted batch must not leave the media key held.
                _ = Send([up]);
            }

            return result;
        });
    }

    internal const ushort MediaNextTrack = 0xB0;
    internal const ushort MediaPreviousTrack = 0xB1;
    internal const ushort MediaPlayPause = 0xB3;

    private static bool TryCreatePointerMove(
        WindowBounds targetWindow,
        double normalizedX,
        double normalizedY,
        out NativeMethods.Input pointerMove,
        out string? error)
    {
        using WindowsDpiAwarenessScope dpiAwareness =
            WindowsDpiAwarenessScope.EnterPerMonitorV2();

        if (!NormalizedCoordinateMapper.TryMapToScreen(
                targetWindow,
                normalizedX,
                normalizedY,
                out ScreenPoint screenPoint))
        {
            pointerMove = default;
            error = "Pointer coordinates or target window bounds are invalid.";
            return false;
        }

        if (!TryMapToAbsoluteVirtualDesktop(screenPoint, out int absoluteX, out int absoluteY))
        {
            pointerMove = default;
            error = "The Windows virtual desktop has invalid bounds.";
            return false;
        }

        pointerMove = MouseInput(
            absoluteX,
            absoluteY,
            0,
            NativeMethods.MouseeventfMove |
            NativeMethods.MouseeventfAbsolute |
            NativeMethods.MouseeventfVirtualDesk);
        error = null;
        return true;
    }

    private static bool TryCreateMouseButtonInputs(
        MouseButton button,
        out NativeMethods.Input down,
        out NativeMethods.Input up)
    {
        (uint Down, uint Up, uint Data)? buttonInput = button switch
        {
            MouseButton.Left =>
                (NativeMethods.MouseeventfLeftDown, NativeMethods.MouseeventfLeftUp, 0),
            MouseButton.Right =>
                (NativeMethods.MouseeventfRightDown, NativeMethods.MouseeventfRightUp, 0),
            MouseButton.Middle =>
                (NativeMethods.MouseeventfMiddleDown, NativeMethods.MouseeventfMiddleUp, 0),
            MouseButton.X1 =>
                (NativeMethods.MouseeventfXDown, NativeMethods.MouseeventfXUp, 1),
            MouseButton.X2 =>
                (NativeMethods.MouseeventfXDown, NativeMethods.MouseeventfXUp, 2),
            _ => null,
        };
        if (buttonInput is null)
        {
            down = default;
            up = default;
            return false;
        }

        down = MouseInput(0, 0, buttonInput.Value.Data, buttonInput.Value.Down);
        up = MouseInput(0, 0, buttonInput.Value.Data, buttonInput.Value.Up);
        return true;
    }

    private static bool TryMapToAbsoluteVirtualDesktop(
        ScreenPoint point,
        out int absoluteX,
        out int absoluteY)
    {
        int left = NativeMethods.GetSystemMetrics(NativeMethods.SmXVirtualScreen);
        int top = NativeMethods.GetSystemMetrics(NativeMethods.SmYVirtualScreen);
        int width = NativeMethods.GetSystemMetrics(NativeMethods.SmCxVirtualScreen);
        int height = NativeMethods.GetSystemMetrics(NativeMethods.SmCyVirtualScreen);

        if (width <= 1 || height <= 1)
        {
            absoluteX = 0;
            absoluteY = 0;
            return false;
        }

        long right = (long)left + width - 1;
        long bottom = (long)top + height - 1;
        long clampedX = Math.Clamp((long)point.X, left, right);
        long clampedY = Math.Clamp((long)point.Y, top, bottom);

        absoluteX = (int)Math.Round(
            (clampedX - left) * 65535.0 / (width - 1),
            MidpointRounding.AwayFromZero);
        absoluteY = (int)Math.Round(
            (clampedY - top) * 65535.0 / (height - 1),
            MidpointRounding.AwayFromZero);
        return true;
    }

    private static InputInjectionResult Send(NativeMethods.Input[] inputs)
    {
        if (!OperatingSystem.IsWindows())
        {
            return InputInjectionResult.Rejected("SendInput requires Windows.");
        }

        uint sent = NativeMethods.SendInput(
            checked((uint)inputs.Length),
            inputs,
            Marshal.SizeOf<NativeMethods.Input>());

        if (sent == inputs.Length)
        {
            return InputInjectionResult.Success;
        }

        int error = Marshal.GetLastWin32Error();
        string detail = error == 0
            ? "Windows did not provide an error code"
            : new Win32Exception(error).Message;

        // UIPI blocks injection into higher-integrity processes. Microsoft documents
        // that SendInput and GetLastError do not reliably identify UIPI as the cause.
        return InputInjectionResult.Rejected(
            $"SendInput accepted {sent} of {inputs.Length} events ({detail}). " +
            "The target may be blocked by Windows integrity-level isolation (UIPI).");
    }

    private static NativeMethods.Input MouseInput(int x, int y, uint data, uint flags)
    {
        return new NativeMethods.Input
        {
            Type = NativeMethods.InputMouse,
            Data = new NativeMethods.InputUnion
            {
                Mouse = new NativeMethods.MouseInput
                {
                    Dx = x,
                    Dy = y,
                    MouseData = data,
                    Flags = flags,
                },
            },
        };
    }

    private static NativeMethods.Input KeyboardInput(ushort virtualKey, ushort scanCode, uint flags)
    {
        if (IsExtendedVirtualKey(virtualKey))
        {
            flags |= NativeMethods.KeyeventfExtendedKey;
        }

        return new NativeMethods.Input
        {
            Type = NativeMethods.InputKeyboard,
            Data = new NativeMethods.InputUnion
            {
                Keyboard = new NativeMethods.KeyboardInput
                {
                    VirtualKey = virtualKey,
                    ScanCode = scanCode,
                    Flags = flags,
                },
            },
        };
    }

    private static bool IsExtendedVirtualKey(ushort virtualKey) =>
        virtualKey is 0x21 or 0x22 or 0x23 or 0x24 or 0x25 or 0x26 or 0x27 or 0x28 or
            0x2D or 0x2E or 0xA3 or 0xA5;
}
