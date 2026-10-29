using Peel.Windows.Host.Input;
using Peel.Windows.Host.Windows;

namespace Peel.Windows.Host;

internal static class Program
{
    public static int Main(string[] args)
    {
        HostCommandLine options;

        try
        {
            options = HostCommandLine.Parse(args);
        }
        catch (ArgumentException exception)
        {
            Console.Error.WriteLine($"Peel Pro: {exception.Message}");
            Console.Error.WriteLine();
            HostCommandLine.PrintHelp(Console.Error);
            return 2;
        }

        if (options.ShowHelp)
        {
            HostCommandLine.PrintHelp(Console.Out);
            return 0;
        }

        if (!OperatingSystem.IsWindows())
        {
            Console.Error.WriteLine("Peel Pro requires Windows.");
            return 1;
        }

        // Dry-run is intentionally the only runnable mode in this foundation. The
        // input gate remains closed, and no capture or network backend is constructed.
        var inputPermission = new InputPermissionGate();
        inputPermission.SetEnabled(false);

        if (options.DryRun)
        {
            return RunDryRun(new Win32WindowEnumerator(), inputPermission);
        }

        HostCommandLine.PrintLiveHostGuidance(Console.Error);
        return 2;
    }

    private static int RunDryRun(
        IWindowEnumerator windowEnumerator,
        InputPermissionGate inputPermission)
    {
        IReadOnlyList<WindowDescriptor> windows;

        try
        {
            windows = windowEnumerator.Enumerate();
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(
                $"Peel Pro: window enumeration failed: {exception.Message}");
            return 1;
        }

        Console.WriteLine("Peel Pro dry run");
        Console.WriteLine($"Input injection: {(inputPermission.IsEnabled ? "enabled" : "disabled")}");
        Console.WriteLine($"User windows: {windows.Count}");
        Console.WriteLine();

        foreach (WindowDescriptor window in windows)
        {
            Console.WriteLine(
                $"0x{window.Handle.ToInt64():X}  " +
                $"pid={window.ProcessId,-7} " +
                $"bounds={window.Bounds,-24} " +
                $"process={window.ProcessName ?? "?"}");
            Console.WriteLine($"    {window.Title}");
        }

        return 0;
    }
}
