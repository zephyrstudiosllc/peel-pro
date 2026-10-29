namespace Peel.Windows.Host.Input;

public sealed class InputPermissionGate
{
    public const string DisabledReason =
        "Remote input is disabled by the host master permission gate.";

    private readonly object _lock = new();
    private bool _isEnabled;

    internal event Action? Disabled;

    public bool IsEnabled
    {
        get
        {
            lock (_lock)
            {
                return _isEnabled;
            }
        }
    }

    public void SetEnabled(bool enabled)
    {
        bool becameDisabled;
        lock (_lock)
        {
            becameDisabled = _isEnabled && !enabled;
            _isEnabled = enabled;
        }

        if (becameDisabled)
        {
            Disabled?.Invoke();
        }
    }

    internal InputInjectionResult ExecuteIfEnabled(Func<InputInjectionResult> operation)
    {
        lock (_lock)
        {
            if (!_isEnabled)
            {
                return InputInjectionResult.Rejected(DisabledReason);
            }

            return operation();
        }
    }
}
