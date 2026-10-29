using System.Runtime.InteropServices;
using Windows.Graphics.Capture;
using WinRT;

namespace Peel.Windows.Host.Capture;

internal static unsafe class GraphicsCaptureItemFactory
{
    private const string GraphicsCaptureItemRuntimeClass =
        "Windows.Graphics.Capture.GraphicsCaptureItem";

    private static readonly Guid IidGraphicsCaptureItemInterop =
        new("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356");
    private static readonly Guid IidGraphicsCaptureItem =
        new("79C3F95B-31F7-4EC2-A464-632EF5D30760");

    internal static GraphicsCaptureItem CreateForWindow(
        nint windowHandle,
        uint expectedProcessId)
    {
        if (windowHandle == 0 ||
            expectedProcessId == 0 ||
            !IsExpectedWindow(windowHandle, expectedProcessId))
        {
            throw new ArgumentException(
                "The selected HWND is stale or belongs to a different process.",
                nameof(windowHandle));
        }

        nint runtimeClass = 0;
        nint factory = 0;
        nint itemAbi = 0;
        try
        {
            Marshal.ThrowExceptionForHR(WindowsCreateString(
                GraphicsCaptureItemRuntimeClass,
                (uint)GraphicsCaptureItemRuntimeClass.Length,
                out runtimeClass));

            Guid factoryIid = IidGraphicsCaptureItemInterop;
            Marshal.ThrowExceptionForHR(RoGetActivationFactory(
                runtimeClass,
                ref factoryIid,
                out factory));

            Guid itemIid = IidGraphicsCaptureItem;
            var createForWindow = (delegate* unmanaged[Stdcall]<
                nint,
                nint,
                Guid*,
                nint*,
                int>)GetMethodAddress(factory, 3);
            Marshal.ThrowExceptionForHR(createForWindow(
                factory,
                windowHandle,
                &itemIid,
                &itemAbi));

            GraphicsCaptureItem item = GraphicsCaptureItem.FromAbi(itemAbi);
            if (!IsExpectedWindow(windowHandle, expectedProcessId))
            {
                Dispose(item);
                throw new InvalidOperationException(
                    "The selected HWND changed identity while capture was opening.");
            }

            return item;
        }
        finally
        {
            Release(itemAbi);
            Release(factory);
            if (runtimeClass != 0)
            {
                _ = WindowsDeleteString(runtimeClass);
            }
        }
    }

    internal static GraphicsCaptureItem CreateForMonitor(nint monitorHandle)
    {
        if (!IsExpectedMonitor(monitorHandle))
        {
            throw new ArgumentException(
                "The selected monitor is stale or unavailable.",
                nameof(monitorHandle));
        }

        nint runtimeClass = 0;
        nint factory = 0;
        nint itemAbi = 0;
        try
        {
            Marshal.ThrowExceptionForHR(WindowsCreateString(
                GraphicsCaptureItemRuntimeClass,
                (uint)GraphicsCaptureItemRuntimeClass.Length,
                out runtimeClass));

            Guid factoryIid = IidGraphicsCaptureItemInterop;
            Marshal.ThrowExceptionForHR(RoGetActivationFactory(
                runtimeClass,
                ref factoryIid,
                out factory));

            Guid itemIid = IidGraphicsCaptureItem;
            var createForMonitor = (delegate* unmanaged[Stdcall]<
                nint,
                nint,
                Guid*,
                nint*,
                int>)GetMethodAddress(factory, 4);
            Marshal.ThrowExceptionForHR(createForMonitor(
                factory,
                monitorHandle,
                &itemIid,
                &itemAbi));

            GraphicsCaptureItem item = GraphicsCaptureItem.FromAbi(itemAbi);
            if (!IsExpectedMonitor(monitorHandle))
            {
                Dispose(item);
                throw new InvalidOperationException(
                    "The selected monitor disappeared while capture was opening.");
            }

            return item;
        }
        finally
        {
            Release(itemAbi);
            Release(factory);
            if (runtimeClass != 0)
            {
                _ = WindowsDeleteString(runtimeClass);
            }
        }
    }

    internal static void Dispose(GraphicsCaptureItem item)
    {
        ArgumentNullException.ThrowIfNull(item);
        if ((object)item is IWinRTObject windowsRuntimeObject)
        {
            windowsRuntimeObject.NativeObject.Dispose();
        }
    }

    private static bool IsExpectedWindow(nint windowHandle, uint expectedProcessId) =>
        IsWindow(windowHandle) &&
        GetWindowThreadProcessId(windowHandle, out uint processId) != 0 &&
        processId == expectedProcessId;

    private static bool IsExpectedMonitor(nint monitorHandle)
    {
        var info = new MonitorInfo
        {
            Size = Marshal.SizeOf<MonitorInfo>(),
        };
        return monitorHandle != 0 && GetMonitorInfoW(monitorHandle, ref info);
    }

    private static nint GetMethodAddress(nint instance, int slot)
    {
        if (instance == 0)
        {
            throw new InvalidOperationException("The capture activation factory was not initialized.");
        }

        return (*(nint**)instance)[slot];
    }

    private static void Release(nint instance)
    {
        if (instance != 0)
        {
            var method = (delegate* unmanaged[Stdcall]<nint, uint>)
                GetMethodAddress(instance, 2);
            _ = method(instance);
        }
    }

    [DllImport("combase.dll", CharSet = CharSet.Unicode)]
    private static extern int WindowsCreateString(
        string sourceString,
        uint length,
        out nint hstring);

    [DllImport("combase.dll")]
    private static extern int WindowsDeleteString(nint hstring);

    [DllImport("combase.dll")]
    private static extern int RoGetActivationFactory(
        nint runtimeClassId,
        ref Guid interfaceId,
        out nint factory);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindow(nint windowHandle);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetWindowThreadProcessId(nint windowHandle, out uint processId);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetMonitorInfoW(nint monitorHandle, ref MonitorInfo monitorInfo);

    [StructLayout(LayoutKind.Sequential)]
    private struct Rect
    {
        internal int Left;
        internal int Top;
        internal int Right;
        internal int Bottom;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MonitorInfo
    {
        internal int Size;
        internal Rect Monitor;
        internal Rect Work;
        internal uint Flags;
    }
}
