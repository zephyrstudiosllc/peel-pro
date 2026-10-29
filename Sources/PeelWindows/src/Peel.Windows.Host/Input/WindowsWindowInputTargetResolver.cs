using Peel.Windows.Host.Interop;
using Peel.Windows.Host.Windows;

namespace Peel.Windows.Host.Input;

internal sealed record WindowInputTargetResult(
    bool Succeeded,
    WindowBounds Bounds,
    string? Error)
{
    internal static WindowInputTargetResult Success(WindowBounds bounds) =>
        new(true, bounds, null);

    internal static WindowInputTargetResult Rejected(string error) =>
        new(false, default, error);
}

internal interface IWindowInputTargetResolver
{
    WindowInputTargetResult Resolve(
        WindowDescriptor expectedWindow,
        WindowInputFocusMode focusMode);
}

internal enum WindowInputFocusMode
{
    None,
    RequireForeground,
    AcquireForeground,
}

internal sealed class WindowsWindowInputTargetResolver : IWindowInputTargetResolver
{
    private const int MaximumCachedProcessCount = 64;

    private readonly object integrityLock = new();
    private readonly Dictionary<uint, (bool Succeeded, uint Level, string? Error)>
        integrityByProcess = [];
    private readonly bool currentIntegritySucceeded;
    private readonly uint currentIntegrityLevel;
    private readonly string? currentIntegrityError;

    internal WindowsWindowInputTargetResolver()
    {
        currentIntegritySucceeded = WindowsProcessIntegrityLevel.TryReadCurrent(
            out currentIntegrityLevel,
            out currentIntegrityError);
    }

    public WindowInputTargetResult Resolve(
        WindowDescriptor expectedWindow,
        WindowInputFocusMode focusMode)
    {
        ArgumentNullException.ThrowIfNull(expectedWindow);
        if (!OperatingSystem.IsWindows())
        {
            return WindowInputTargetResult.Rejected(
                "Remote input target validation requires Windows.");
        }

        using WindowsDpiAwarenessScope dpiAwareness =
            WindowsDpiAwarenessScope.EnterPerMonitorV2();

        if (expectedWindow.IsDisplay)
        {
            if (expectedWindow.ProcessId != 0 ||
                expectedWindow.FixedWindowId is null ||
                !WindowsDisplayCaptureSource.TryReadBounds(
                    expectedWindow.Handle,
                    out WindowBounds displayBounds))
            {
                return WindowInputTargetResult.Rejected(
                    "The selected display is no longer available.");
            }

            // A display stream is a synthetic Peel source, not a focusable HWND.
            // Pointer clicks naturally activate the real window under the cursor;
            // keyboard input remains directed to Windows' current foreground app.
            return WindowInputTargetResult.Success(displayBounds);
        }

        nint window = expectedWindow.Handle;
        if (window == nint.Zero ||
            !NativeMethods.IsWindow(window) ||
            !NativeMethods.IsWindowVisible(window))
        {
            return WindowInputTargetResult.Rejected(
                "The selected window is no longer available.");
        }

        _ = NativeMethods.GetWindowThreadProcessId(window, out uint processId);
        if (processId == 0 || processId != expectedWindow.ProcessId)
        {
            return WindowInputTargetResult.Rejected(
                "The selected window identity changed before input was applied.");
        }

        if (!currentIntegritySucceeded)
        {
            return WindowInputTargetResult.Rejected(
                $"{currentIntegrityError} Remote input was dropped.");
        }

        (bool Succeeded, uint Level, string? Error) targetIntegrity =
            ReadTargetIntegrity(processId);
        if (!targetIntegrity.Succeeded)
        {
            return WindowInputTargetResult.Rejected(
                $"{targetIntegrity.Error} Remote input was dropped.");
        }

        if (targetIntegrity.Level > currentIntegrityLevel)
        {
            return WindowInputTargetResult.Rejected(
                "The selected window belongs to a higher-integrity process. " +
                "Windows integrity-level isolation (UIPI) blocks remote input.");
        }

        if (focusMode != WindowInputFocusMode.None &&
            NativeMethods.GetForegroundWindow() != window)
        {
            if (focusMode == WindowInputFocusMode.RequireForeground)
            {
                return WindowInputTargetResult.Rejected(
                    "The selected window is no longer foreground; the input was dropped.");
            }

            if (NativeMethods.IsIconic(window))
            {
                _ = NativeMethods.ShowWindowAsync(window, NativeMethods.SwRestore);
            }

            if (!TryAcquireForeground(window))
            {
                return WindowInputTargetResult.Rejected(
                    "Windows did not allow Peel to focus the selected window. " +
                    "The foreground-app policy or integrity-level isolation (UIPI) may be blocking it.");
            }
        }

        if (!Win32WindowEnumerator.TryReadBounds(window, out WindowBounds currentBounds))
        {
            return WindowInputTargetResult.Rejected(
                "The selected window no longer has usable screen bounds.");
        }

        return WindowInputTargetResult.Success(currentBounds);
    }

    private (bool Succeeded, uint Level, string? Error) ReadTargetIntegrity(uint processId)
    {
        lock (integrityLock)
        {
            if (integrityByProcess.TryGetValue(processId, out var cached))
            {
                return cached;
            }
        }

        bool succeeded = WindowsProcessIntegrityLevel.TryReadProcess(
            processId,
            out uint level,
            out string? error);
        var result = (succeeded, level, error);
        lock (integrityLock)
        {
            if (integrityByProcess.Count >= MaximumCachedProcessCount)
            {
                integrityByProcess.Clear();
            }

            integrityByProcess[processId] = result;
        }

        return result;
    }

    private static bool TryAcquireForeground(nint window)
    {
        _ = NativeMethods.SetForegroundWindow(window);
        if (NativeMethods.GetForegroundWindow() == window)
        {
            return true;
        }

        nint previousForeground = NativeMethods.GetForegroundWindow();
        uint currentThreadId = NativeMethods.GetCurrentThreadId();
        uint targetThreadId = NativeMethods.GetWindowThreadProcessId(window, out _);
        uint foregroundThreadId = previousForeground == nint.Zero
            ? 0
            : NativeMethods.GetWindowThreadProcessId(previousForeground, out _);
        bool attachedToForeground = false;
        bool attachedToTarget = false;

        try
        {
            if (foregroundThreadId != 0 && foregroundThreadId != currentThreadId)
            {
                attachedToForeground = NativeMethods.AttachThreadInput(
                    currentThreadId,
                    foregroundThreadId,
                    attach: true);
            }

            if (targetThreadId != 0 &&
                targetThreadId != currentThreadId &&
                targetThreadId != foregroundThreadId)
            {
                attachedToTarget = NativeMethods.AttachThreadInput(
                    currentThreadId,
                    targetThreadId,
                    attach: true);
            }

            _ = NativeMethods.BringWindowToTop(window);
            _ = NativeMethods.SetForegroundWindow(window);
        }
        finally
        {
            if (attachedToTarget)
            {
                _ = NativeMethods.AttachThreadInput(
                    currentThreadId,
                    targetThreadId,
                    attach: false);
            }

            if (attachedToForeground)
            {
                _ = NativeMethods.AttachThreadInput(
                    currentThreadId,
                    foregroundThreadId,
                    attach: false);
            }
        }

        return NativeMethods.GetForegroundWindow() == window;
    }
}
