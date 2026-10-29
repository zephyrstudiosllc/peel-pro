using Peel.Linux.Host;
namespace Peel.Linux.HostUI;
internal sealed class LinuxHostConsentView : ILinuxHostConsentView,IAsyncDisposable
{
    private sealed record Pending(ulong Id,Guid? Pair,Action Cancel,TaskCompletionSource<bool> Completion,CancellationTokenRegistration Registration);
    private readonly object gate=new();private readonly ILinuxHostUIChannel channel;private readonly ulong epoch;
    private readonly List<Task> dismissals=[];private ulong next;private Pending? pending,sharing;private bool closed;
    internal LinuxHostConsentView(ILinuxHostUIChannel channel,ulong epoch){this.channel=channel;this.epoch=epoch;}
    public Task<bool> ShowPairingAsync(LinuxHostPinPresentation p,Action cancel,CancellationToken token)
    {
        if(p.Pin.Length!=6||p.Pin.Any(c=>c<'0'||c>'9')||p.ExpiresAt<=DateTimeOffset.UtcNow)throw new InvalidOperationException();
        return Present(1,p.Generation,p.HostName,$"{p.Pin}\nEnter this code on your other device. Expires {p.ExpiresAt.ToLocalTime():t}.",cancel,token);
    }
    public Task<bool> ConfirmNetworkHostAsync(LinuxHostNetworkPresentation p,Action stop,CancellationToken token)
        => Present(2,null,p.HostName,$"Share the selected {(p.PortalSourceKind==1?"display":p.PortalSourceKind==2?"window":"source")} · {p.Width}×{p.Height}\nPaired computers can view it until you stop sharing or this grant expires.",stop,token);
    private void DismissLocked(ulong id)=>dismissals.Add(channel.Dismiss(epoch,id));
    private async Task<bool> Present(int kind,Guid? pair,string name,string detail,Action cancel,CancellationToken token)
    {
        Pending item;lock(gate){if(closed||pending is not null||kind==2&&sharing is not null||token.IsCancellationRequested||next==ulong.MaxValue)throw new OperationCanceledException();item=new(++next,pair,cancel,new(TaskCreationOptions.RunContinuationsAsynchronously),default);pending=item;}
        var registration=token.Register(()=>Cancel(item.Id));
        lock(gate){if(pending?.Id==item.Id)pending=item with{Registration=registration};else registration.Unregister();}
        try
        {
            bool shown=await channel.Present(epoch,item.Id,kind,name,detail,launch=>{lock(gate)return !closed&&pending?.Id==item.Id&&!token.IsCancellationRequested&&launch();}).ConfigureAwait(false);
            if(!shown)Cancel(item.Id);return await item.Completion.Task.ConfigureAwait(false);
        }
        catch{Cancel(item.Id);throw;}
    }
    internal void Answer(ulong operation,int result)
    {
        if(result!=1){Cancel(operation);return;}
        lock(gate)
        {
            var item=pending;if(closed||item?.Id!=operation)return;
            if(item.Pair is null){sharing=item;pending=null;DismissLocked(item.Id);}
            item.Completion.TrySetResult(true);
        }
    }
    private void Cancel(ulong id)
    {
        Pending? item;lock(gate){item=pending?.Id==id?pending:sharing?.Id==id?sharing:null;if(item is null)return;if(pending?.Id==id)pending=null;if(sharing?.Id==id)sharing=null;DismissLocked(id);}
        item.Registration.Unregister();item.Completion.TrySetResult(false);item.Cancel();
    }
    public void PairingClosed(Guid generation)
    {
        Pending? item;lock(gate){item=pending;if(item?.Pair!=generation)return;pending=null;DismissLocked(item.Id);}
        item.Registration.Unregister();item.Completion.TrySetResult(false);
    }
    // Capture while accepting the exact backend revision, then clear only that
    // already-retired context. Do not call Stop again: authority closed media.
    internal ulong SharingContext(){lock(gate)return sharing?.Id??(pending is{Pair:null}?pending.Id:0);}
    internal void RetireSharing(ulong id)
    {
        if(id==0)return;Pending? item;
        lock(gate){item=sharing?.Id==id?sharing:pending is{Pair:null} candidate&&candidate.Id==id?candidate:null;if(item is null)return;if(sharing?.Id==id)sharing=null;if(pending?.Id==id)pending=null;DismissLocked(id);}
        item.Registration.Unregister();item.Completion.TrySetResult(false);
    }
    internal void CancelSharing(){ulong id;lock(gate){id=sharing?.Id??0;if(id==0&&pending is{Pair:null})id=pending.Id;}if(id!=0)Cancel(id);}
    internal void CancelCurrent(){ulong p,s;lock(gate){p=pending?.Id??0;s=sharing?.Id??0;}if(p!=0)Cancel(p);if(s!=0)Cancel(s);}
    internal void StopNow(){lock(gate){if(closed)return;closed=true;}CancelCurrent();}
    public async ValueTask DisposeAsync(){StopNow();Task[] tasks;lock(gate)tasks=dismissals.ToArray();await Task.WhenAll(tasks).ConfigureAwait(false);}
}
