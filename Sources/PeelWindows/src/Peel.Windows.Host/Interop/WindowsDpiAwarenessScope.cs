namespace Peel.Windows.Host.Interop;

internal readonly struct WindowsDpiAwarenessScope(nint previousContext) : IDisposable
{
    private static readonly nint PerMonitorAwareV2 = new(-4);

    internal static WindowsDpiAwarenessScope EnterPerMonitorV2()
    {
        nint previous = OperatingSystem.IsWindowsVersionAtLeast(10, 0, 14393)
            ? NativeMethods.SetThreadDpiAwarenessContext(PerMonitorAwareV2)
            : nint.Zero;
        return new WindowsDpiAwarenessScope(previous);
    }

    public void Dispose()
    {
        if (previousContext != nint.Zero)
        {
            _ = NativeMethods.SetThreadDpiAwarenessContext(previousContext);
        }
    }
}
