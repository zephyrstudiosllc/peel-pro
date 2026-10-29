using Peel.Linux.Host;
namespace Peel.Linux.HostUI;
// Registered before Run. Backend is created only by the real GTK activation.
internal sealed class LinuxHostUIController
{
    private readonly object gate=new();private readonly ILinuxHostUIChannel channel;
    private readonly Func<ILinuxHostConsentView,ILinuxHostUiBackend> factory;
    private readonly Action fenceReceiver;private readonly Func<Task> drainReceiver;
    private readonly CancellationTokenSource lifetime=new();
    private readonly LinuxHostUIWire.Event action;private readonly LinuxHostUIWire.Answer answer;
    private ILinuxHostUiBackend? backend;private LinuxHostConsentView? view;
    private Task? initialize,operation,close;private LinuxHostUiState? state;
    private ulong epoch,render;private long revision=-1;private bool closing,busy,activated,drained,disposed;
    internal LinuxHostUIController(ILinuxHostUIChannel channel,Func<ILinuxHostConsentView,ILinuxHostUiBackend> factory,Action fenceReceiver,Func<Task> drainReceiver)
    {this.channel=channel;this.factory=factory;this.fenceReceiver=fenceReceiver;this.drainReceiver=drainReceiver;action=(kind,epoch,user)=>{try{Event(kind,epoch,user);}catch(Exception){_=Error("This computer is unavailable.");}};answer=(id,result,_)=>{try{view?.Answer(id,result);}catch(Exception){try{backend?.StopHost();}catch(Exception){}}};}
    internal void Register()=>LinuxHostUIWire.peel_linux_host_ui_register(action,answer,IntPtr.Zero);
    // Also used by fake-only lifecycle tests, without Register/PInvoke.
    internal void Event(int kind,ulong eventEpoch,IntPtr unused)
    {
        if(kind==5){Close(eventEpoch);return;}
        if(kind==4){ILinuxHostUiBackend? b;LinuxHostConsentView? v;lock(gate){if(closing||eventEpoch!=epoch)return;b=backend;v=view;}b?.StopHost();v?.CancelCurrent();return;}
        lock(gate)
        {
            if(closing)return;
            if(kind==1){if(activated)return;activated=true;epoch=eventEpoch;view=new(channel,epoch);backend=factory(view);var owned=backend;owned.Changed+=s=>Changed(owned,s);initialize=Task.Run(()=>Initialize(owned));return;}
            if(!activated||eventEpoch!=epoch||backend is null)return;
            if((kind!=2&&kind!=3)||busy||state is not{Initialized:true,Busy:false}||kind==3&&(state.ReadyCapture is not{Ready:true}||state.PairedCount==0))return;
            busy=true;_=Render();var current=backend;operation=Task.Run(()=>Command(current,kind));
        }
    }
    private async Task Initialize(ILinuxHostUiBackend owned)
    {try{await owned.InitializeAfterGtkActivationAsync().ConfigureAwait(false);}catch(Exception){await Error("This computer is unavailable. Check the desktop session and secure storage.").ConfigureAwait(false);}}
    private void Changed(ILinuxHostUiBackend owned,LinuxHostUiState next)
    {LinuxHostConsentView? retiredView=null;ulong retiredContext=0;lock(gate){if(closing||!ReferenceEquals(owned,backend)||next.Revision<=revision)return;revision=next.Revision;if(state?.IsSharing==true&&!next.IsSharing){retiredView=view;retiredContext=view?.SharingContext()??0;}state=next;_=Render();}retiredView?.RetireSharing(retiredContext);}
    private Task Render()
    {
        var s=state;bool pair=!closing&&!busy&&s is{Initialized:true,Busy:false};
        return channel.State(epoch,++render,s?.Status??"Preparing this computer…",pair,pair&&s is{PairedCount:>0,ReadyCapture:{Ready:true}},!closing&&(busy||s?.IsSharing==true||s?.Busy==true||s?.Discoverable==true));
    }
    private async Task Command(ILinuxHostUiBackend owned,int kind)
    {
        try {if(kind==2)await owned.PairAsync(lifetime.Token).ConfigureAwait(false);else await owned.ShareAsync(lifetime.Token).ConfigureAwait(false);}
        catch(OperationCanceledException) { }
        catch(Exception){await Error("Could not start. Check local discovery, secure storage and the selected source.").ConfigureAwait(false);}
        finally{lock(gate){busy=false;if(!closing)_=Render();}}
    }
    private Task Error(string text){lock(gate)return channel.State(epoch,++render,text,false,false,false);}
    private void Close(ulong eventEpoch)
    {
        ILinuxHostUiBackend? b;LinuxHostConsentView? v;var fenced=new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock(gate){if(closing||!activated||eventEpoch!=epoch)return;closing=true;b=backend;v=view;close=Task.Run(async()=>{await fenced.Task.ConfigureAwait(false);await Drain().ConfigureAwait(false);});}
        try{b?.StopHost();}
        finally{try{v?.StopNow();}finally{try{fenceReceiver();}finally{try{lifetime.Cancel();}finally{fenced.TrySetResult(true);}}}}
    }
    private async Task Drain()
    {
        try
        {
            if(initialize is not null)await initialize.ConfigureAwait(false);
            if(operation is not null)await operation.ConfigureAwait(false);
            if(backend is not null)await backend.DisposeAsync().ConfigureAwait(false);
            await drainReceiver().ConfigureAwait(false);
            if(view is not null)await view.DisposeAsync().ConfigureAwait(false);
            lock(gate)drained=true;
            await channel.FinishClose(epoch).ConfigureAwait(false);
        }
        catch(Exception){await Error("Disconnect did not finish. Sharing is stopped; Peel is still closing.").ConfigureAwait(false);}
    }
    internal Task ClosingTask {get{lock(gate)return close??Task.CompletedTask;}}
    internal void AfterRun()
    {lock(gate){if(activated&&!drained)throw new InvalidOperationException("GTK exited before the owned shutdown drain completed.");if(!disposed){disposed=true;lifetime.Dispose();}}GC.KeepAlive(action);GC.KeepAlive(answer);}
}
