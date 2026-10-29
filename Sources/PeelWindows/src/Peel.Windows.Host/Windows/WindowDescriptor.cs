namespace Peel.Windows.Host.Windows;

public sealed record WindowDescriptor(
    nint Handle,
    uint ProcessId,
    string? ProcessName,
    string ClassName,
    string Title,
    WindowBounds Bounds,
    string? AppIconPngBase64 = null,
    double? AppLaunchTimeIntervalSince1970 = null,
    CaptureSourceKind SourceKind = CaptureSourceKind.Window,
    uint? FixedWindowId = null,
    string? StatusSummary = null)
{
    public bool IsDisplay => SourceKind == CaptureSourceKind.Display;
}

public enum CaptureSourceKind
{
    Window,
    Display,
}

public readonly record struct WindowBounds(int X, int Y, int Width, int Height)
{
    public bool IsUsable => Width > 1 && Height > 1;

    public override string ToString() => $"{Width}x{Height}+{X}+{Y}";
}

public readonly record struct ScreenPoint(int X, int Y);
