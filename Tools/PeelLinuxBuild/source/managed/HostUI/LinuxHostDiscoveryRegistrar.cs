using System.Globalization;
using System.Net;
using System.Text;
using System.Text.Json;
using Peel.Linux.Host;
namespace Peel.Linux.HostUI;
internal sealed record LinuxAvahiRecord(string Name,string Type,ushort Port,int InterfaceIndex,int Protocol,string Txt);
internal interface ILinuxAvahiNative
{
    Task<int> Begin(ulong operation,LinuxAvahiRecord record,LinuxHostUIWire.Discovery callback,Func<Func<int>,int> admission);
    Task<int> Update(ulong operation,ulong transaction,string txt,LinuxHostUIWire.Discovery callback,Func<Func<int>,int> admission);
    Task Stop(ulong operation);
}
internal sealed class LinuxAvahiNative : ILinuxAvahiNative
{
    public Task<int> Begin(ulong o,LinuxAvahiRecord r,LinuxHostUIWire.Discovery callback,Func<Func<int>,int> admission)
        => LinuxHostGtk.InvokeAsync(()=>admission(()=>LinuxHostUIWire.peel_linux_discovery_publish(o,r.Name,r.Type,r.Port,r.InterfaceIndex,r.Protocol,r.Txt,callback,IntPtr.Zero)));
    public Task<int> Update(ulong o,ulong t,string txt,LinuxHostUIWire.Discovery callback,Func<Func<int>,int> admission)=>LinuxHostGtk.InvokeAsync(()=>admission(()=>LinuxHostUIWire.peel_linux_discovery_update(o,t,txt,callback,IntPtr.Zero)));
    public Task Stop(ulong o)=>LinuxHostGtk.InvokeAsync(()=>{LinuxHostUIWire.peel_linux_discovery_stop(o);return true;});
}
internal sealed class LinuxHostDiscoveryRegistrar(ILinuxAvahiNative native) : ILinuxHostDiscoveryRegistrar
{
    internal static IReadOnlyList<LinuxAvahiRecord> Records(LinuxHostDiscoverySnapshot s,DateTimeOffset now)
    {
        static bool Name(string v)=>!string.IsNullOrWhiteSpace(v)&&Encoding.UTF8.GetByteCount(v)<=63&&!v.Any(char.IsControl);
        var c=s.Control;
        if(!Name(c.ServiceName)||!Guid.TryParse(c.HostId,out var host)||host==Guid.Empty||c.Port==0||c.ExpiresAt<=now||c.InterfaceIndex!=-1||c.AvahiProtocol!=-1||!c.DualStack||!IPAddress.Parse(c.BindAddress).Equals(IPAddress.IPv6Any))throw new InvalidDataException("Actual dual-stack bound control required.");
        Dictionary<string,string> txt=new(){{"hostId",c.HostId},{"tlsPSKOrder",LinuxHostDiscoveryLease.TlsPskOrder}};
        if(s.Pair is {} p)
        {
            byte[] salt=Convert.FromBase64String(p.SaltBase64);
            if(!Name(p.ServiceName)||p.ServiceName==c.ServiceName||p.Port==0||p.Port==c.Port||p.ExpiresAt<=now||p.ExpiresAt>c.ExpiresAt||!IPAddress.Parse(p.BindAddress).Equals(IPAddress.IPv6Any)||salt.Length!=16||Convert.ToBase64String(salt)!=p.SaltBase64)throw new InvalidDataException("Current distinct bound Pair required.");
            txt.Add("pairMode","pin");txt.Add("pinSalt",p.SaltBase64);txt.Add("pinExp",p.ExpiresAt.ToUnixTimeSeconds().ToString(CultureInfo.InvariantCulture));txt.Add("pairPort",p.Port.ToString(CultureInfo.InvariantCulture));
        }
        string json=JsonSerializer.Serialize(txt);List<LinuxAvahiRecord> result=[new(c.ServiceName,"_peel._tcp",c.Port,c.InterfaceIndex,c.AvahiProtocol,json)];
        if(s.Pair is {} pair)result.Add(new(pair.ServiceName,"_peelpair._tcp",pair.Port,c.InterfaceIndex,c.AvahiProtocol,json));
        return result;
    }
    public async Task<ILinuxHostPublishedServices> PublishAsync(LinuxHostDiscoveryLease lease,CancellationToken token)
    {
        var records=lease.Admit(s=>Records(s,DateTimeOffset.UtcNow));var publication=new Publication(lease,native,token);
        try { foreach(var r in records)await publication.Add(r,token).ConfigureAwait(false);publication.CommitSetup();return publication; }
        catch { await publication.DisposeAsync().ConfigureAwait(false);throw; }
    }
    public async Task<ILinuxHostPublishedServices> ReplaceAsync(ILinuxHostPublishedServices previous,LinuxHostDiscoveryLease lease,CancellationToken token)
    {
        if(previous is not Publication old||!ReferenceEquals(old.Native,native))throw new InvalidOperationException("Owned serving publication required.");
        var nextRecords=lease.Admit(s=>Records(s,DateTimeOffset.UtcNow));var before=old.Snapshot;var after=lease.Snapshot;
        if(before.Control!=after.Control||before.Pair is not null&&after.Pair is not null)throw new InvalidOperationException("Same control and removed prior Pair required.");
        var next=new Publication(lease,native,token);bool acquired=false;
        try
        {
            await old.Replacement.WaitAsync(token).ConfigureAwait(false);acquired=true;
            if(!old.ControlAvailable)throw new IOException("Prior control discovery is unavailable.");
            if(nextRecords.Count==2)await next.Add(nextRecords[1],token).ConfigureAwait(false);
            var control=old.Control;string oldTxt=control.Record.Txt;bool changed=false;
            await old.RetirePairs().ConfigureAwait(false);
            try
            {
                changed=true;await control.Update(nextRecords[0].Txt,lease,token).ConfigureAwait(false);token.ThrowIfCancellationRequested();
                // One non-awaiting commit vs setup cancellation. Once it wins,
                // Pair end cannot close committed metadata before adoption; its
                // backend Closed path performs the control-only replacement.
                next.CommitSetup(()=>{control.Transfer(old.Lease,lease);old.Detach(control);next.Take(control);});
                return next;
            }
            catch
            {
                if(changed){try{await control.Update(oldTxt,old.Lease,CancellationToken.None).ConfigureAwait(false);}catch{old.ReportLost();}}
                throw;
            }
        }
        catch{if(before.Pair is not null)old.ReportLost();await next.DisposeAsync().ConfigureAwait(false);throw;}
        finally{if(acquired)old.Replacement.Release();}
    }
    private sealed class Publication : ILinuxHostPublishedServices
    {
        internal LinuxHostDiscoveryLease Lease{get;}internal LinuxHostDiscoverySnapshot Snapshot=>Lease.Snapshot;
        internal ILinuxAvahiNative Native{get;}internal readonly SemaphoreSlim Replacement=new(1,1);
        private readonly List<Registration> entries=[];private bool closed,lost,setupCancelled,committed;
        private readonly CancellationToken setupToken;private CancellationTokenRegistration setupCancellation;
        public Guid PublicationId=>Lease.Id;
        public bool IsEstablished{get{lock(entries)return !closed&&!lost&&Lease.IsCurrent&&entries.Count>0&&entries.All(x=>x.Established);}}
        public event Action? Lost;
        internal bool ControlAvailable {get{lock(entries)return !closed&&Lease.IsCurrent&&entries.Any(x=>x.Record.Type=="_peel._tcp"&&x.Established);}}
        internal Registration Control{get{lock(entries)return entries.Single(x=>x.Record.Type=="_peel._tcp");}}
        internal Publication(LinuxHostDiscoveryLease lease,ILinuxAvahiNative native,CancellationToken token)
        {
            Lease=lease;Native=native;setupToken=token;
            // This is SETUP ownership only. Individual registrations retain
            // CONTROL lease cancellation, never the shorter Pair command token.
            setupCancellation=token.Register(CancelSetup);
        }
        private void CancelSetup()
        {
            Registration[] pending;lock(entries){if(committed||closed)return;setupCancelled=true;pending=entries.ToArray();}
            foreach(var entry in pending)entry.CancelSetup();
        }
        internal void CommitSetup(Action? transfer=null)
        {
            lock(entries)
            {
                if(closed||setupCancelled||setupToken.IsCancellationRequested||!Lease.IsCurrent||(transfer is null&&entries.Count==0)||entries.Any(x=>!x.Established))throw new OperationCanceledException();
                transfer?.Invoke();committed=true;
                // A cancellation callback already dispatched waits on entries,
                // then sees committed and cannot retire the committed owner.
                setupCancellation.Unregister();
            }
        }
        internal void ReportLost(){lock(entries)lost=true;Lost?.Invoke();}
        internal async Task RetirePairs(){Registration[] old;lock(entries){old=entries.Where(x=>x.Record.Type=="_peelpair._tcp").ToArray();foreach(var r in old){entries.Remove(r);r.Lost-=ReportLost;}}try{foreach(var r in old)await r.DisposeAsync().ConfigureAwait(false);}catch{ReportLost();throw;}}
        internal void Take(Registration entry){lock(entries){if(closed||setupCancelled)throw new OperationCanceledException();entries.Add(entry);entry.Lost+=ReportLost;}}
        internal void Detach(Registration entry){lock(entries){entries.Remove(entry);entry.Lost-=ReportLost;}}
        internal async Task Add(LinuxAvahiRecord record,CancellationToken token){var entry=new Registration(Lease,Native,record);Take(entry);await entry.Start(token).ConfigureAwait(false);}
        internal async Task RetireRemaining(){Registration[] old;lock(entries){closed=true;setupCancellation.Unregister();old=entries.ToArray();entries.Clear();}foreach(var r in old){r.Lost-=ReportLost;await r.DisposeAsync().ConfigureAwait(false);}}
        public async ValueTask DisposeAsync(){await Replacement.WaitAsync().ConfigureAwait(false);try{await RetireRemaining().ConfigureAwait(false);}finally{Replacement.Release();}}
    }
    private sealed class Registration : IAsyncDisposable
    {
        private static long next;private static long nextUpdate;
        private readonly object gate=new();private LinuxHostDiscoveryLease lease;private readonly ILinuxAvahiNative native;private readonly ulong id;
        internal LinuxAvahiRecord Record{get;private set;}internal event Action? Lost;
        private readonly LinuxHostUIWire.Discovery callback;private readonly TaskCompletionSource<bool> ready=new(TaskCreationOptions.RunContinuationsAsynchronously),retired=new(TaskCreationOptions.RunContinuationsAsynchronously);
        private Task? start,stop;private bool closing,begun,established;private long ownerRevision;private CancellationTokenRegistration leaseCancel;
        internal bool Established{get{lock(gate)return established&&!closing;}}
        internal Registration(LinuxHostDiscoveryLease l,ILinuxAvahiNative n,LinuxAvahiRecord r){lease=l;native=n;Record=r;long value=Interlocked.Increment(ref next);if(value<=0)throw new InvalidOperationException();id=(ulong)value;callback=(op,state,user)=>{try{Result(op,state,user);}catch(Exception){Close();}};}
        private void CloseOwned(long revision){lock(gate){if(revision!=ownerRevision)return;Close();}}
        internal Task Start(CancellationToken token)
        {
            lock(gate){if(start is not null)throw new InvalidOperationException();start=StartCore(token);leaseCancel=lease.Lifetime.Register(()=>CloseOwned(0));}return ready.Task;
        }
        private async Task StartCore(CancellationToken token)
        {
            try
            {
                int admitted=await native.Begin(id,Record,callback,launch=>{lock(gate){if(closing||token.IsCancellationRequested)return 0;return lease.Admit(_=>{begun=true;try{int result=launch();if(result!=1)begun=false;return result;}catch{begun=false;throw;}});}}).ConfigureAwait(false);
                if(admitted!=1){ready.TrySetException(new IOException("Local discovery unavailable."));retired.TrySetResult(true);}
            }
            catch(Exception e){ready.TrySetException(e);retired.TrySetResult(true);}
        }
        internal async Task Update(string txt,LinuxHostDiscoveryLease admission,CancellationToken token)
        {
            long number=Interlocked.Increment(ref nextUpdate);if(number<=0)throw new InvalidOperationException();ulong transaction=(ulong)number;
            var done=new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            LinuxHostUIWire.Discovery response=(id,result,_)=>{if(id==transaction)done.TrySetResult(result==1);};
            int submitted=await native.Update(id,transaction,txt,response,launch=>{lock(gate){token.ThrowIfCancellationRequested();if(closing||!established)throw new IOException();return admission.Admit(_=>launch());}}).ConfigureAwait(false);
            if(submitted!=1)throw new IOException("Discovery TXT update not admitted.");
            // Never abandon an uncertain native mutation; await its finite IPC
            // completion before rollback/transfer and retain callback until then.
            if(!await done.Task.ConfigureAwait(false))throw new IOException("Discovery TXT update unconfirmed.");GC.KeepAlive(response);Record=Record with{Txt=txt};
        }
        internal void Transfer(LinuxHostDiscoveryLease expected,LinuxHostDiscoveryLease next)
        {
            lock(gate)
            {
                if(closing||!established||!ReferenceEquals(lease,expected)||!next.IsCurrent)throw new OperationCanceledException();
                leaseCancel.Unregister();lease=next;long revision=++ownerRevision;
                leaseCancel=next.Lifetime.Register(()=>CloseOwned(revision));if(closing)throw new OperationCanceledException();
            }
        }
        private void Result(ulong operation,int result,IntPtr unused)
        {
            bool notify=false;lock(gate){if(operation!=id)return;if(result==2){established=false;retired.TrySetResult(true);ready.TrySetException(new IOException("Discovery retired before readiness."));return;}if(result==1&&!closing&&lease.IsCurrent){established=true;ready.TrySetResult(true);return;}if(result==0){notify=established;established=false;ready.TrySetException(new IOException("Local discovery unavailable."));}}
            if(notify)Lost?.Invoke();if(result==0)Close();
        }
        internal void CancelSetup()=>Close();
        private void Close(){lock(gate){if(closing)return;closing=true;established=false;ready.TrySetException(new OperationCanceledException());stop=StopCore();}}
        private async Task StopCore(){if(start is not null)await start.ConfigureAwait(false);bool send;lock(gate)send=begun;if(send)await native.Stop(id).ConfigureAwait(false);else retired.TrySetResult(true);}
        public async ValueTask DisposeAsync(){Close();Task? drain;lock(gate)drain=stop;if(drain is not null)await drain.ConfigureAwait(false);await retired.Task.ConfigureAwait(false);leaseCancel.Unregister();GC.KeepAlive(callback);}
    }
}
