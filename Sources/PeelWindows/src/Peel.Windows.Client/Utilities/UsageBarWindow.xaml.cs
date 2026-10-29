using System.Windows;
using System.Windows.Input;

namespace Peel.Windows.Client.Utilities;

public partial class UsageBarWindow : Window
{
    private readonly Action open;
    public UsageBarWindow(CommandCenterViewModel model, Action open)
    {
        InitializeComponent(); DataContext = model; this.open = open;
        Left = SystemParameters.WorkArea.Right - Width - 24;
        Top = SystemParameters.WorkArea.Top + 24;
    }
    private void OpenPeel(object sender, RoutedEventArgs e) => open();
    private void DragBar(object sender, MouseButtonEventArgs e)
    {
        if (e.LeftButton == MouseButtonState.Pressed) DragMove();
    }
}
