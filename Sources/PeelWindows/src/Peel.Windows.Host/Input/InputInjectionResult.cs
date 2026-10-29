namespace Peel.Windows.Host.Input;

public sealed record InputInjectionResult(bool Succeeded, string? Error)
{
    public static InputInjectionResult Success { get; } = new(true, null);

    public static InputInjectionResult Rejected(string error) => new(false, error);
}

public enum MouseButton
{
    Left,
    Right,
    Middle,
    X1,
    X2,
}

public enum MouseButtonAction
{
    Down,
    Up,
    Press,
}

public enum VirtualKeyAction
{
    Down,
    Up,
    Press,
}
