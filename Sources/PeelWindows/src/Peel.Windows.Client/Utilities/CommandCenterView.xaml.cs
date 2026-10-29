using System.Windows;
using System.Windows.Controls;

namespace Peel.Windows.Client.Utilities;

public partial class CommandCenterView : System.Windows.Controls.UserControl
{
    public CommandCenterView()
    {
        InitializeComponent();
        Sections.SelectionChanged += (_, e) => { if (ReferenceEquals(e.Source, Sections)) RefreshSelectedPage(); };
        RefreshSelectedPage();
    }
    public event Action<int>? SectionChanged;
    public void SelectSection(int index)
    {
        int selected = Math.Clamp(index, 0, Sections.Items.Count - 1);
        if (Sections.SelectedIndex == selected) RefreshSelectedPage();
        else Sections.SelectedIndex = selected;
    }
    private void RefreshSelectedPage()
    {
        PageTitle.Text = Sections.SelectedIndex switch
        {
            0 => "App Mechanic", 1 => "Usage Limits", 2 => "Agents", 3 => "Alerts",
            4 => "Peel Settings", 5 => "Remote Machine", 6 => "Audio", 7 => "Notch Pulse",
            8 => "Metric History", 9 => "App Mechanic Settings", 10 => "Hardware",
            11 => "Notch Pulse Settings", 12 => "Progress", 13 => "ON AIR", 14 => "Battery", _ => "Lighting"
        };
        SystemGauges.Visibility = Sections.SelectedIndex == 0 ? Visibility.Visible : Visibility.Collapsed;
        PageStatus.Visibility = Sections.SelectedIndex is 0 or 15 ? Visibility.Visible : Visibility.Collapsed;
        PageStatus.SetBinding(TextBlock.TextProperty, new System.Windows.Data.Binding(Sections.SelectedIndex == 15 ? "ProfileStatus" : "Notice"));
        SectionChanged?.Invoke(Sections.SelectedIndex);
    }
    private void UtilityPage_Click(object sender, RoutedEventArgs e)
    {
        if (sender is System.Windows.Controls.Button { Tag: string tag } && int.TryParse(tag, out int section)) SelectSection(section);
    }
    private void CopyDiagnostics_Click(object sender, RoutedEventArgs e)
    {
        if (DataContext is not CommandCenterViewModel model || !model.StreamingDiagnosticsEnabled) return;
        try { System.Windows.Clipboard.SetText(System.Text.Json.JsonSerializer.Serialize(model.ReadStreamingDiagnostics(), new System.Text.Json.JsonSerializerOptions { WriteIndented = true, PropertyNamingPolicy = System.Text.Json.JsonNamingPolicy.CamelCase })); }
        catch (System.Runtime.InteropServices.COMException) { System.Windows.MessageBox.Show("The clipboard is busy. Try again.", "Peel Pro"); }
    }
    private void CopyAgentConfiguration_Click(object sender, RoutedEventArgs e)
    {
        if (DataContext is not CommandCenterViewModel model) return;
        try { System.Windows.Clipboard.SetText(model.AgentConfiguration); }
        catch (System.Runtime.InteropServices.COMException) { System.Windows.MessageBox.Show("The clipboard is busy. Try again.", "Peel Pro"); }
    }
    private void ProcessAction_Click(object sender, RoutedEventArgs e)
    {
        if (DataContext is not CommandCenterViewModel model || sender is not System.Windows.Controls.Button { Tag: string action }) return;
        if (model.SelectedProcess is { } process && action is "kill" or "hold")
        {
            string detail = action == "kill" ? "Unsaved work can be lost." : "The app will stop responding until you resume it or exit Peel Pro.";
            if (System.Windows.MessageBox.Show(Window.GetWindow(this), $"{(action == "kill" ? "Force quit" : "Hold")} {process.Name} (PID {process.Id})?\n\n{detail}", "App Mechanic", MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK) return;
        }
        model.ActOnSelected(action);
    }
}
