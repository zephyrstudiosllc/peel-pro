using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Peel.Windows.Host.Interop;

namespace Peel.Windows.Host.Windows;

public sealed class Win32WindowEnumerator : IWindowEnumerator
{
    private readonly Dictionary<WindowIdentity, string?> appIconsByWindow = [];

    private static readonly HashSet<string> ExcludedWindowClasses = new(StringComparer.OrdinalIgnoreCase)
    {
        "DV2ControlHost",
        "IME",
        "MsgrIMEWindowClass",
        "Progman",
        "Shell_SecondaryTrayWnd",
        "Shell_TrayWnd",
        "WorkerW",
    };

    public IReadOnlyList<WindowDescriptor> Enumerate()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Win32 window enumeration requires Windows.");
        }

        var windows = new List<WindowDescriptor>();
        var currentIdentities = new HashSet<WindowIdentity>();
        uint currentProcessId = checked((uint)Environment.ProcessId);
        nint shellWindow = NativeMethods.GetShellWindow();

        NativeMethods.EnumWindowsProc callback = (window, _) =>
        {
            try
            {
                WindowDescriptor? descriptor = TryDescribeWindow(
                    window,
                    shellWindow,
                    currentProcessId);

                if (descriptor is not null)
                {
                    windows.Add(descriptor);
                    currentIdentities.Add(new WindowIdentity(
                        descriptor.Handle,
                        descriptor.ProcessId));
                }
            }
            catch
            {
                // Windows can disappear between EnumWindows and inspection. One
                // racing process must not prevent the rest of the list from loading.
            }

            return true;
        };

        if (!NativeMethods.EnumWindows(callback, nint.Zero))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "EnumWindows failed");
        }

        foreach (WindowIdentity staleIdentity in
                 appIconsByWindow.Keys.Where(identity => !currentIdentities.Contains(identity)).ToArray())
        {
            appIconsByWindow.Remove(staleIdentity);
        }

        windows.AddRange(WindowsDisplayCaptureSource.Enumerate());
        return windows;
    }

    private WindowDescriptor? TryDescribeWindow(
        nint window,
        nint shellWindow,
        uint currentProcessId)
    {
        if (window == nint.Zero ||
            window == shellWindow ||
            !NativeMethods.IsWindowVisible(window) ||
            NativeMethods.IsIconic(window) ||
            NativeMethods.GetAncestor(window, NativeMethods.GaRoot) != window)
        {
            return null;
        }

        NativeMethods.GetWindowThreadProcessId(window, out uint processId);
        if (processId == 0 || processId == currentProcessId)
        {
            return null;
        }

        string title = ReadWindowTitle(window);
        if (string.IsNullOrWhiteSpace(title))
        {
            return null;
        }

        string className = ReadClassName(window);
        if (ExcludedWindowClasses.Contains(className))
        {
            return null;
        }

        long extendedStyle = NativeMethods.GetWindowLongPtr(window, NativeMethods.GwlExStyle).ToInt64();
        bool isToolWindow = (extendedStyle & NativeMethods.WsExToolWindow) != 0;
        bool isAppWindow = (extendedStyle & NativeMethods.WsExAppWindow) != 0;
        if (isToolWindow && !isAppWindow)
        {
            return null;
        }

        int cloakedResult = NativeMethods.DwmGetWindowAttribute(
            window,
            NativeMethods.DwmwaCloaked,
            out uint cloaked,
            sizeof(uint));
        if (cloakedResult == 0 && cloaked != 0)
        {
            return null;
        }

        if (!TryReadBounds(window, out WindowBounds bounds))
        {
            return null;
        }

        var identity = new WindowIdentity(window, processId);
        if (!appIconsByWindow.TryGetValue(identity, out string? appIconPngBase64))
        {
            appIconPngBase64 = WindowIconReader.TryReadPngBase64(window, processId);
            appIconsByWindow.Add(identity, appIconPngBase64);
        }

        (string? processName, double? appLaunchTimeIntervalSince1970) =
            TryReadProcessMetadata(processId);

        return new WindowDescriptor(
            window,
            processId,
            processName,
            className,
            title,
            bounds,
            appIconPngBase64,
            appLaunchTimeIntervalSince1970);
    }

    internal static bool TryReadBounds(nint window, out WindowBounds bounds)
    {
        int result = NativeMethods.DwmGetWindowAttribute(
            window,
            NativeMethods.DwmwaExtendedFrameBounds,
            out NativeMethods.Rect rectangle,
            Marshal.SizeOf<NativeMethods.Rect>());

        if (result != 0 && !NativeMethods.GetWindowRect(window, out rectangle))
        {
            bounds = default;
            return false;
        }

        long width = (long)rectangle.Right - rectangle.Left;
        long height = (long)rectangle.Bottom - rectangle.Top;
        if (width <= 1 || height <= 1 || width > int.MaxValue || height > int.MaxValue)
        {
            bounds = default;
            return false;
        }

        bounds = new WindowBounds(rectangle.Left, rectangle.Top, (int)width, (int)height);
        return true;
    }

    private static string ReadWindowTitle(nint window)
    {
        int titleLength = NativeMethods.GetWindowTextLengthW(window);
        if (titleLength <= 0)
        {
            return string.Empty;
        }

        var title = new StringBuilder(titleLength + 1);
        int charactersCopied = NativeMethods.GetWindowTextW(window, title, title.Capacity);
        return charactersCopied > 0 ? title.ToString() : string.Empty;
    }

    private static string ReadClassName(nint window)
    {
        var className = new StringBuilder(256);
        int charactersCopied = NativeMethods.GetClassNameW(window, className, className.Capacity);
        return charactersCopied > 0 ? className.ToString() : string.Empty;
    }

    private static (string? ProcessName, double? LaunchTimeIntervalSince1970)
        TryReadProcessMetadata(uint processId)
    {
        try
        {
            using Process process = Process.GetProcessById(checked((int)processId));
            return (
                process.ProcessName,
                new DateTimeOffset(process.StartTime).ToUnixTimeMilliseconds() / 1000.0);
        }
        catch (ArgumentException)
        {
            return (null, null);
        }
        catch (InvalidOperationException)
        {
            return (null, null);
        }
        catch (SystemException)
        {
            return (null, null);
        }
    }

    private readonly record struct WindowIdentity(nint Handle, uint ProcessId);
}
