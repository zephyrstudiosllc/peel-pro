using System.Runtime.InteropServices;
using Peel.Windows.Host.Interop;

namespace Peel.Windows.Host.Windows;

internal static class WindowsDisplayCaptureSource
{
    internal const uint SyntheticBase = 0xFFF0_0000;
    internal const uint MaximumSyntheticDisplays = 64;

    internal readonly record struct MonitorSnapshot(
        nint Handle,
        WindowBounds Bounds,
        bool IsPrimary);

    internal static IReadOnlyList<WindowDescriptor> Enumerate()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Display enumeration requires Windows.");
        }

        using WindowsDpiAwarenessScope dpiAwareness =
            WindowsDpiAwarenessScope.EnterPerMonitorV2();
        var monitors = new List<MonitorSnapshot>();
        NativeMethods.MonitorEnumProc callback = (
            nint monitor,
            nint monitorDeviceContext,
            ref NativeMethods.Rect monitorRectangle,
            nint parameter) =>
        {
            _ = monitorDeviceContext;
            _ = monitorRectangle;
            _ = parameter;
            if (TryReadSnapshot(monitor, out MonitorSnapshot snapshot))
            {
                monitors.Add(snapshot);
            }

            return true;
        };

        if (!NativeMethods.EnumDisplayMonitors(0, 0, callback, 0))
        {
            // A monitor-query failure must not suppress ordinary app windows.
            return Array.Empty<WindowDescriptor>();
        }

        return CreateDescriptors(monitors);
    }

    internal static IReadOnlyList<WindowDescriptor> CreateDescriptors(
        IReadOnlyList<MonitorSnapshot> monitors)
    {
        ArgumentNullException.ThrowIfNull(monitors);
        MonitorSnapshot[] sorted = monitors
            .Where(static monitor => monitor.Handle != 0 && monitor.Bounds.IsUsable)
            .DistinctBy(static monitor => monitor.Handle)
            .OrderByDescending(static monitor => monitor.IsPrimary)
            .ThenBy(static monitor => monitor.Bounds.X)
            .ThenBy(static monitor => monitor.Bounds.Y)
            .ThenBy(static monitor => monitor.Handle.ToInt64())
            .Take(checked((int)MaximumSyntheticDisplays))
            .ToArray();

        var result = new List<WindowDescriptor>(sorted.Length);
        for (var index = 0; index < sorted.Length; index++)
        {
            MonitorSnapshot monitor = sorted[index];
            string title = sorted.Length switch
            {
                1 => "Peel Display",
                _ when monitor.IsPrimary => "Peel Display Main",
                _ => $"Peel Display {index + 1}",
            };

            result.Add(new WindowDescriptor(
                monitor.Handle,
                0,
                "Peel Display",
                string.Empty,
                title,
                monitor.Bounds,
                SourceKind: CaptureSourceKind.Display,
                FixedWindowId: SyntheticBase + checked((uint)index),
                StatusSummary: $"{title} — full display stream"));
        }

        return result.AsReadOnly();
    }

    internal static bool TryReadBounds(nint monitor, out WindowBounds bounds)
    {
        if (TryReadSnapshot(monitor, out MonitorSnapshot snapshot))
        {
            bounds = snapshot.Bounds;
            return true;
        }

        bounds = default;
        return false;
    }

    private static bool TryReadSnapshot(nint monitor, out MonitorSnapshot snapshot)
    {
        var info = new NativeMethods.MonitorInfo
        {
            Size = Marshal.SizeOf<NativeMethods.MonitorInfo>(),
        };
        if (monitor == 0 || !NativeMethods.GetMonitorInfoW(monitor, ref info))
        {
            snapshot = default;
            return false;
        }

        long width = (long)info.Monitor.Right - info.Monitor.Left;
        long height = (long)info.Monitor.Bottom - info.Monitor.Top;
        if (width <= 1 || height <= 1 || width > int.MaxValue || height > int.MaxValue)
        {
            snapshot = default;
            return false;
        }

        snapshot = new MonitorSnapshot(
            monitor,
            new WindowBounds(info.Monitor.Left, info.Monitor.Top, (int)width, (int)height),
            (info.Flags & NativeMethods.MonitorInfofPrimary) != 0);
        return true;
    }
}
