namespace Peel.Windows.Client.Models;

public sealed record HostCandidate(
    string StableHostId,
    string ServiceInstanceName,
    string DisplayName,
    string Address,
    int Port,
    bool IsSaved,
    bool IsDirect = false)
{
    public string Id => StableHostId;

    public string EndpointLabel => Port == 0 ? "Offline · add a private address" :
        $"{(Address.Contains(':') ? "[" + Address + "]" : Address)}:{Port}{(IsDirect ? " · saved address" : "")}";
}

public sealed record RemoteWindowDescriptor(
    uint Id,
    string Title,
    string OwnerName,
    int PixelWidth,
    int PixelHeight,
    double? AppLaunchTimeIntervalSince1970 = null)
{
    public bool IsDesktop => OwnerName == "Peel Display" && Id is >= 0xFFF00000 and < 0xFFF00040;
}

public enum PeelConnectionState
{
    Disconnected,
    Connecting,
    Connected,
    Disconnecting,
    Error
}

public enum PeelStreamState
{
    Stopped,
    Starting,
    Streaming,
    Stopping,
    Error
}

public enum NormalizedPointerButton
{
    None,
    Primary,
    Secondary,
    Middle
}

public enum NormalizedPointerAction
{
    Move,
    Down,
    Up,
    Scroll
}

public readonly record struct NormalizedPoint
{
    private NormalizedPoint(double x, double y)
    {
        X = x;
        Y = y;
    }

    public double X { get; }

    public double Y { get; }

    public static bool TryCreate(double x, double y, out NormalizedPoint point)
    {
        if (!double.IsFinite(x) || !double.IsFinite(y))
        {
            point = default;
            return false;
        }

        point = new NormalizedPoint(Math.Clamp(x, 0, 1), Math.Clamp(y, 0, 1));
        return true;
    }
}

public sealed record NormalizedPointerInput(
    uint WindowId,
    NormalizedPointerAction Action,
    NormalizedPoint Position,
    NormalizedPointerButton Button,
    double ScrollDeltaX,
    double ScrollDeltaY);

public sealed record NormalizedKeyInput(
    uint WindowId,
    ushort VirtualKey,
    bool IsDown,
    bool IsRepeat,
    bool Shift,
    bool Control,
    bool Alt,
    bool Meta);
