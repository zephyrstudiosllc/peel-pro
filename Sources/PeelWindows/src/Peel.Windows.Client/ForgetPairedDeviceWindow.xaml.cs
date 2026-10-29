using System.Windows;

namespace Peel.Windows.Client;

public partial class ForgetPairedDeviceWindow : Window
{
    internal ForgetPairedDeviceWindow(string displayName)
    {
        InitializeComponent();
        ConfirmationMessage.Text =
            $"This will revoke access for “{displayName}”. " +
            "If it’s currently connected, it will be disconnected immediately.";
    }

    private void Confirm_Click(object sender, RoutedEventArgs e)
    {
        _ = sender;
        _ = e;
        DialogResult = true;
    }
}
