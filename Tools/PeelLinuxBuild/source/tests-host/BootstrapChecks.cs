using System.Net;
using System.Text;
using Peel.Linux.Host;
using Peel.Windows.Protocol;

// Pure fake-only bootstrap coverage. No native/GTK/vault/socket is loaded.
internal static class BootstrapChecks
{
    internal static readonly (string name,Func<Task> run)[] Cases = [
        ("bootstrap-control-empty-before-portal-grant", () => Run(() => {
            using var f=new Fixture(); f.a.Stop(); var a=new LinuxHostAuthority(f.clock);
            a.EnableControl(f.clock.GetTimestamp()); var c=a.AdmitControl(f.peer,new MemoryStream());
            Check(a.IsCurrent(c) && a.Capture is null && a.SharedCapture is null); Reject(() => a.StartStream(c,1)); a.Stop();
        })),
        ("capture-alone-never-grants-network-media", () => Run(() => {
            using var f=new Fixture(); f.a.Stop(); var a=new LinuxHostAuthority(f.clock); a.EnableControl(f.clock.GetTimestamp());
            var c=a.AdmitControl(f.peer,new MemoryStream()); a.UpdateCapture(new(1,1,800,600,0));
            Check(a.IsCurrent(c) && a.Capture is { Ready:true } && a.SharedCapture is null); Reject(() => a.StartStream(c,1)); a.Stop();
        })),
        ("portal-revoke-preserves-control-denies-video", () => Run(() => {
            using var f=new Fixture(); var(c,r,_)=f.Stream(); f.a.UpdateCapture(null);
            Check(f.a.IsCurrent(c) && !f.a.IsCurrent(r) && f.a.SharedCapture is null); Reject(() => f.a.StartStream(c,1));
        })),
        ("control-presence-cannot-renew-itself", () => Run(() => {
            using var f=new Fixture(); Reject(() => f.a.EnableControl(f.clock.GetTimestamp()));
            f.clock.Advance(TimeSpan.FromMinutes(30)); Reject(() => f.a.AdmitControl(f.peer,new MemoryStream()));
        })),
        ("default-bind-policy-matches-dual-wildcard-registration", () => Run(() => {
            var p=LinuxHostBindPlan.DefaultDualStack(); Check(p.Address.Equals(IPAddress.IPv6Any)&&p.DualStack&&p.InterfaceIndex==-1&&p.AvahiProtocol==-1);
        })),
        ("discovery-admission-denies-late-native-submission", () => Run(() => {
            var clock=new Clock(); using var lease=Lease(clock); int launches=0;
            Check(lease.Admit(_ => ++launches)==1); lease.Invalidate(); Reject(() => lease.Admit(_ => ++launches)); Check(launches==1&&lease.Lifetime.IsCancellationRequested);
        })),
        ("discovery-monotonic-expiry-no-owner-refresh", () => Run(() => {
            var clock=new Clock(); using var lease=Lease(clock); clock.Advance(TimeSpan.FromMinutes(30));
            Check(!lease.IsCurrent); Reject(() => lease.Admit(_ => true));
        })),
        ("discovery-owner-replacement-denies-old-lease", () => Run(() => {
            var clock=new Clock(); bool current=true; using var lease=Lease(clock,() => current); current=false;
            Check(!lease.IsCurrent); Reject(() => lease.Admit(_ => true));
        })),
        ("discovery-pair-expiry-does-not-revoke-control-lease", () => Run(() => {
            var clock=new Clock(); var c=Control(clock); var pair=new LinuxHostBoundPair(Guid.NewGuid(),"Synthetic Pair","::",54322,Convert.ToBase64String(new byte[16]),clock.GetUtcNow().AddSeconds(120));
            using var lease=new LinuxHostDiscoveryLease(new(Guid.NewGuid(),c,pair),clock,TimeSpan.FromMinutes(30),() => true);
            clock.Advance(TimeSpan.FromSeconds(120)); Check(lease.IsCurrent&&lease.Snapshot.Pair!.ExpiresAt<=clock.GetUtcNow());
            // The backend's Closed callback removes metadata; this lease itself
            // remains valid so Replace can preserve/roll back existing control.
            Check(lease.Admit(s => s.Control.Port)==54321);
        })),
        ("discovery-endpoints-are-immutable-value-snapshots", () => Run(() => {
            var clock=new Clock(); var c=Control(clock); var exposed=c.EndPoint; exposed.Port=1; exposed.Address=IPAddress.Loopback;
            Check(c.EndPoint.Port==54321&&c.EndPoint.Address.Equals(IPAddress.IPv6Any));
        })),
        ("discovery-refuses-fictitious-or-duplicate-bound-ports", () => Run(() => {
            var clock=new Clock(); Reject(() => new LinuxHostDiscoveryLease(new(Guid.NewGuid(),Control(clock) with {Port=0},null),clock,TimeSpan.FromMinutes(1),() => true));
            var pair=new LinuxHostBoundPair(Guid.NewGuid(),"Pair","::",54321,Convert.ToBase64String(new byte[16]),clock.GetUtcNow().AddSeconds(120));
            Reject(() => new LinuxHostDiscoveryLease(new(Guid.NewGuid(),Control(clock),pair),clock,TimeSpan.FromMinutes(1),() => true));
        })),
        ("service-names-byte-bound-and-exact-not-generic", () => Run(() => {
            var suffix=LinuxHostServiceIdentity.ShortName(string.Concat(Enumerable.Repeat("🖥",30)),40);
            var value=LinuxHostServiceIdentity.Validate("Synthetic host","Peel Pro on "+suffix,"Peel Pair on "+suffix);
            Check(Encoding.UTF8.GetByteCount(value.ControlServiceName)<=63&&Encoding.UTF8.GetByteCount(suffix)<=40);
            Reject(() => LinuxHostServiceIdentity.Validate("host",new string('é',40),"Pair"));
            Reject(() => LinuxHostServiceIdentity.Validate("host","Same","Same")); Check(LinuxHostDiscoveryLease.TlsPskOrder=="psk-identity");
        })),
        ("pin-publication-and-control-currentness-required", async () => {
            using var t=new LinuxHostTrust("11111111-1111-4111-8111-111111111111",new Vault(),[],_ => { });
            bool current=true; await using var pin=new LinuxHostPinEnrollment(t,new FakeTransport(),new View(),"Synthetic control",() => current);
            await pin.StartAsync("Synthetic host",new(IPAddress.Loopback,54322),CancellationToken.None);
            Check(!pin.TryResolve(PeelPinPairing.TlsIdentity,out _)); pin.PublicationEstablished(); Check(pin.TryResolve(PeelPinPairing.TlsIdentity,out _));
            current=false; Check(!pin.TryResolve(PeelPinPairing.TlsIdentity,out _)); Reject(pin.PublicationEstablished);
        }),
        ("pin-close-notification-after-synchronous-denial", async () => {
            using var t=new LinuxHostTrust("11111111-1111-4111-8111-111111111111",new Vault(),[],_ => { });
            await using var pin=new LinuxHostPinEnrollment(t,new FakeTransport(),new View(),"Synthetic control",() => true);
            await pin.StartAsync("Synthetic host",new(IPAddress.Loopback,54322),CancellationToken.None); pin.PublicationEstablished(); int closed=0;
            pin.Closed+=generation => { Check(generation==pin.Generation&&!pin.IsPairCurrent&&!pin.TryResolve(PeelPinPairing.TlsIdentity,out _)); closed++; };
            pin.Cancel(); pin.Cancel(); Check(closed==1);
        }),
        ("runtime-initialize-never-listens-and-pair-bootstrap-needs-no-source", async () => {
            using var t=new LinuxHostTrust("11111111-1111-4111-8111-111111111111",new Vault(),[],_ => { });
            var transport=new BootstrapTransport(); var native=new BootstrapNative(); await using var runtime=new LinuxHostRuntime(t,transport,native,"Synthetic host");
            await runtime.InitializeAsync(); Check(native.initialized&&transport.listens==0&&runtime.BoundControl is null);
            var c=await runtime.StartControlPresenceAsync(LinuxHostBindPlan.DefaultDualStack(),"Synthetic control",CancellationToken.None);
            Check(c.Port==54321&&c.ServiceName=="Synthetic control"&&c.EndPoint.Address.Equals(IPAddress.IPv6Any)&&runtime.IsPresenceCurrent&&!runtime.IsSharing&&runtime.ReadyCapture is null);
            Check(!transport.resolver!.TryResolve("unknown",out _));
            await RejectAsync(() => runtime.StartVisibleShareAsync(new View(),CancellationToken.None));
        }),
        ("runtime-invalid-actual-bind-fails-without-public-metadata", async () => {
            using var t=new LinuxHostTrust("11111111-1111-4111-8111-111111111111",new Vault(),[],_ => { });
            var transport=new BootstrapTransport { endpoint=new(IPAddress.Loopback,54321) }; var native=new BootstrapNative();
            await using var runtime=new LinuxHostRuntime(t,transport,native,"Synthetic host"); await runtime.InitializeAsync();
            await RejectAsync(() => runtime.StartControlPresenceAsync(LinuxHostBindPlan.DefaultDualStack(),"Synthetic control",CancellationToken.None));
            Check(runtime.IsStopped&&runtime.BoundControl is null&&transport.listener!.disposed);
        }),
    ];
    private static LinuxHostBoundControl Control(Clock c) => new(Guid.NewGuid(),"11111111-1111-4111-8111-111111111111","Synthetic host","Synthetic control","::",54321,-1,-1,true,c.GetUtcNow().AddMinutes(30));
    private static LinuxHostDiscoveryLease Lease(Clock c,Func<bool>? current=null) => new(new(Guid.NewGuid(),Control(c),null),c,TimeSpan.FromMinutes(30),current??(() => true));
    private static Task Run(Action a) { a(); return Task.CompletedTask; }
    private static void Check(bool b) { if(!b) throw new InvalidOperationException("Synthetic bootstrap assertion failed."); }
    private static void Reject(Action a) { try { a(); } catch(Exception e) when(e is InvalidDataException or IOException or OperationCanceledException or InvalidOperationException or ArgumentException) { return; } throw new Exception("Expected synthetic rejection."); }
    private static async Task RejectAsync(Func<Task> a) { try { await a(); } catch(Exception e) when(e is InvalidDataException or IOException or OperationCanceledException or InvalidOperationException or ArgumentException) { return; } throw new Exception("Expected synthetic rejection."); }
}
internal sealed class BootstrapTransport : IPeelPskTransportFactory
{
    internal int listens; internal IPEndPoint endpoint=new(IPAddress.IPv6Any,54321); internal BootstrapListener? listener; internal IPeelPskCredentialResolver? resolver;
    public ValueTask<Stream> ConnectAsync(DnsEndPoint endpoint,PeelPskCredential credential,CancellationToken token=default) => throw new NotSupportedException();
    public ValueTask<IPeelPskListener> ListenAsync(IPEndPoint requested,IPeelPskCredentialResolver resolver,CancellationToken token=default)
    { if(!requested.Address.Equals(IPAddress.IPv6Any)||requested.Port!=0) throw new IOException(); listens++; this.resolver=resolver; listener=new(endpoint); return ValueTask.FromResult<IPeelPskListener>(listener); }
}
internal sealed class BootstrapListener(IPEndPoint endpoint) : IPeelPskListener
{
    internal bool disposed;
    public EndPoint LocalEndPoint => endpoint;
    public async ValueTask<PeelPskConnection> AcceptAsync(CancellationToken token=default) { await Task.Delay(Timeout.InfiniteTimeSpan,token); throw new OperationCanceledException(); }
    public ValueTask DisposeAsync() { disposed=true; return ValueTask.CompletedTask; }
}
internal sealed class BootstrapNative : ILinuxHostNative
{
    internal bool initialized; public bool Available=>true;
    public Task InitializeAsync(Action<LinuxHostCapture?> changed) { initialized=true; changed(null); return Task.CompletedTask; }
    public Task<ulong> StartAsync(LinuxHostAuthority authority,LinuxHostReservation reservation,LinuxHostVideoQueue queue,CancellationToken token) => throw new NotSupportedException();
    public Task StopAsync(ulong source,ulong encoder) => Task.CompletedTask;
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}
