using System.Windows;

namespace Peel.Windows.Client.Utilities;

public partial class LightingStudioView : System.Windows.Controls.UserControl
{
    public LightingStudioView() => InitializeComponent();

    private void ChooseColor_Click(object sender, RoutedEventArgs e)
    {
        if (DataContext is not CommandCenterViewModel model) return;
        bool secondary = sender is System.Windows.Controls.Button { Tag: "secondary" };
        using var picker = new System.Windows.Forms.ColorDialog { FullOpen = true };
        try { picker.Color = System.Drawing.ColorTranslator.FromHtml(secondary ? model.ProfileSecondaryColor : model.ProfileColor); }
        catch (ArgumentException) { /* A partially edited hex value can still be replaced with the picker. */ }
        var owner = new ColorDialogOwner(new System.Windows.Interop.WindowInteropHelper(Window.GetWindow(this)).Handle);
        if (picker.ShowDialog(owner) != System.Windows.Forms.DialogResult.OK) return;
        string color = $"#{picker.Color.R:X2}{picker.Color.G:X2}{picker.Color.B:X2}";
        if (secondary) model.ProfileSecondaryColor = color; else model.ProfileColor = color;
    }

    private sealed record ColorDialogOwner(IntPtr Handle) : System.Windows.Forms.IWin32Window;
}
