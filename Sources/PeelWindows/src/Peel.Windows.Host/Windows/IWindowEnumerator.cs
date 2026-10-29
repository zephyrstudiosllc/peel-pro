namespace Peel.Windows.Host.Windows;

public interface IWindowEnumerator
{
    IReadOnlyList<WindowDescriptor> Enumerate();
}
