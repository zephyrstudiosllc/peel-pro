using System.Windows.Automation.Peers;
using System.Windows.Controls;

namespace Peel.Windows.Client.Utilities;

public sealed class StudioPageHost : System.Windows.Controls.TabControl
{
    protected override AutomationPeer OnCreateAutomationPeer() => new PageHostAutomationPeer(this);

    protected override void OnSelectionChanged(SelectionChangedEventArgs e)
    {
        base.OnSelectionChanged(e);
        if (ReferenceEquals(e.Source, this))
            Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Loaded, new Action(() =>
            {
                if (UIElementAutomationPeer.FromElement(this) is not { } peer) return;
                peer.ResetChildrenCache();
                peer.RaiseAutomationEvent(AutomationEvents.StructureChanged);
            }));
    }

    // The sidebar owns navigation. Expose the visible page rather than nonexistent tab headers.
    private sealed class PageHostAutomationPeer(StudioPageHost owner) : FrameworkElementAutomationPeer(owner)
    {
        protected override string GetClassNameCore() => nameof(StudioPageHost);
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Pane;
    }
}
