using Peel.Windows.Transport;
namespace Peel.Linux.Host;
// Ordinary UI uses only this typed backend; no listener starts at construction
// or Initialize. Explicit Pair/Share actions own every actual bind/publication.
internal sealed class LinuxHostComposition : ILinuxHostUiBackend
{
    private readonly object state = new();
    private readonly ILinuxHostConsentView view;
    private readonly ILinuxHostDiscoveryRegistrar discovery;
    private readonly LinuxHostBindPlan bindPlan;
    private readonly SemaphoreSlim lifecycle = new(1,1);
    private readonly CancellationTokenSource closing = new();
    private CancellationTokenSource epochStop = new();
    private Task retired = Task.CompletedTask;
    private readonly List<Task> pairDrains = [];
    private LinuxHostTrust? trust;
    private LinuxHostServiceIdentity? identity;
    private LinuxHostRuntime? host;
    private LinuxHostPinEnrollment? pairing;
    private LinuxHostDiscoveryLease? publicationLease;
    private ILinuxHostPublishedServices? published;
    private long epoch,revision;
    private int closed,busy;
    private bool initialized,discoverable;
    private string status = "Starting…";
    public event Action<LinuxHostUiState>? Changed;
    internal LinuxHostComposition(ILinuxHostConsentView view,ILinuxHostDiscoveryRegistrar discovery,LinuxHostBindPlan bindPlan)
    { this.view=view; this.discovery=discovery; this.bindPlan=bindPlan; }
    private bool Current(long expected) => Volatile.Read(ref closed)==0 && Interlocked.Read(ref epoch)==expected;
    private void Notify(string? message=null)
    {
        LinuxHostUiState snapshot;
        lock(state)
        {
            if(message is not null) status=message;
            snapshot=new(++revision,initialized,Volatile.Read(ref busy)!=0,trust?.Count??0,host?.ReadyCapture,host?.IsSharing==true,discoverable,status);
        }
        Changed?.Invoke(snapshot);
    }
    public async Task InitializeAfterGtkActivationAsync()
    {
        await lifecycle.WaitAsync(closing.Token).ConfigureAwait(false);
        long expected=Interlocked.Read(ref epoch);
        try
        {
            lock(state) if(initialized) return;
            if(trust is null) { var loaded=await Task.Run(() =>
            {
                var t=LinuxHostPersistence.OpenDefault();
                try { return (trust:t,identity:LinuxHostPersistence.OpenServiceIdentity(t.HostId,Environment.MachineName)); }
                catch { t.Dispose(); throw; }
            },closing.Token).ConfigureAwait(false);
            if(!Current(expected)) { loaded.trust.Dispose(); throw new OperationCanceledException(); }
            lock(state) { trust=loaded.trust; identity=loaded.identity; } }
            await EnsureRuntimeAsync(expected).ConfigureAwait(false);
            if(!Current(expected)) throw new OperationCanceledException();
            lock(state) initialized=true;
            Notify("Ready. Pair a device or choose a source.");
        }
        finally { lifecycle.Release(); }
    }
    private async Task<LinuxHostRuntime> EnsureRuntimeAsync(long expected)
    {
        await retired.ConfigureAwait(false);
        if(!Current(expected) || trust is null || identity is null) throw new OperationCanceledException();
        LinuxHostRuntime? existing; lock(state) existing=host;
        if(existing is { IsStopped:false }) return existing;
        if(existing is not null)
        {
            lock(state) if(ReferenceEquals(host,existing)) host=null;
            await existing.DisposeAsync().ConfigureAwait(false);
        }
        var next=new LinuxHostRuntime(trust,new BouncyCastlePskTransportFactory(),new LinuxHostNativeBridge(),identity.ComputerName);
        next.Changed+=RuntimeChanged;
        lock(state) { if(!Current(expected)) { next.Stop(); } else host=next; }
        if(!Current(expected)) { await next.DisposeAsync().ConfigureAwait(false); throw new OperationCanceledException(); }
        try { await next.InitializeAsync().ConfigureAwait(false); }
        catch { next.Stop(); throw; }
        if(!Current(expected)) throw new OperationCanceledException();
        return next;
    }
    private void RuntimeChanged()
    {
        LinuxHostRuntime? current; lock(state) current=host;
        // An exhausted/failed serving generation must retire its publication
        // and observer before a later explicit Pair/Share can start a new one.
        if(current?.IsStopped==true) { StopHost(); return; }
        Notify();
    }
    private async Task<(long expected,CancellationTokenSource token)> EnterCommandAsync(CancellationToken token)
    {
        if(Interlocked.CompareExchange(ref busy,1,0)!=0) throw new InvalidOperationException("Another host action is in progress.");
        try
        {
            CancellationToken epochToken; long expected;
            lock(state) { epochToken=epochStop.Token; expected=Interlocked.Read(ref epoch); }
            var linked=CancellationTokenSource.CreateLinkedTokenSource(token,epochToken,closing.Token);
            try { await lifecycle.WaitAsync(linked.Token).ConfigureAwait(false); }
            catch { linked.Dispose(); throw; }
            if(!Current(expected) || !initialized) { lifecycle.Release(); linked.Dispose(); throw new InvalidOperationException("Host setup is not ready."); }
            Notify(); return(expected,linked);
        }
        catch { Interlocked.Exchange(ref busy,0); Notify(); throw; }
    }
    private void ExitCommand(CancellationTokenSource token)
    { token.Dispose(); Interlocked.Exchange(ref busy,0); lifecycle.Release(); Notify(); }
    public async Task PairAsync(CancellationToken token)
    {
        var command=await EnterCommandAsync(token).ConfigureAwait(false);
        LinuxHostRuntime? active=null; LinuxHostPinEnrollment? next=null; bool createdPresence=false;
        try
        {
            active=await EnsureRuntimeAsync(command.expected).ConfigureAwait(false);
            createdPresence=active.BoundControl is null;
            var bound=active.BoundControl ?? await active.StartControlPresenceAsync(bindPlan,identity!.ControlServiceName,command.token.Token).ConfigureAwait(false);
            // Remove an old finite Pair before adding a same-name replacement.
            await RemovePairLockedAsync(null,command.expected,command.token.Token).ConfigureAwait(false);
            next=new LinuxHostPinEnrollment(trust!,new BouncyCastlePskTransportFactory(),view,identity!.ControlServiceName,() => active.IsPresenceCurrent);
            var captured=next; next.Closed+=_ => PairClosed(captured);
            lock(state) { if(!Current(command.expected)) throw new OperationCanceledException(); pairing=next; }
            var secret=await next.StartAsync(identity.ComputerName,new(bindPlan.Address,0),command.token.Token).ConfigureAwait(false);
            var endpoint=next.BoundEndPoint ?? throw new IOException("The actual Pair endpoint is unavailable.");
            if(endpoint.Port==bound.Port) throw new IOException("Pair and control must use distinct actual ports.");
            var pair=new LinuxHostBoundPair(next.Generation,identity.PairServiceName,endpoint.Address.ToString(),checked((ushort)endpoint.Port),secret.SaltBase64,secret.ExpiresAt);
            using var publishing=CancellationTokenSource.CreateLinkedTokenSource(command.token.Token,next.Lifetime);
            await PublishLockedAsync(active,pair,() => captured.IsPairCurrent,command.expected,publishing.Token).ConfigureAwait(false);
            if(!Current(command.expected) || !ReferenceEquals(pairing,next)) throw new OperationCanceledException();
            next.PublicationEstablished(); // exact established control service first
            Notify("Enter this code on your device.");
        }
        catch
        {
            next?.Cancel();
            if(next is not null) OwnDrain(next.DisposeAsync().AsTask());
            if(createdPresence && active is not null) await RetireFailedNewPresenceLockedAsync(active).ConfigureAwait(false);
            else if(next is not null && active is not null && Current(command.expected))
            {
                try { await RemovePairLockedAsync(next,command.expected,CancellationToken.None).ConfigureAwait(false); }
                catch { lock(state) discoverable=false; }
            }
            throw;
        }
        finally { ExitCommand(command.token); }
    }
    public async Task ShareAsync(CancellationToken token)
    {
        var command=await EnterCommandAsync(token).ConfigureAwait(false);
        LinuxHostRuntime? active=null; bool createdPresence=false;
        try
        {
            if(trust?.Count is not >0) throw new InvalidOperationException("Pair a device first.");
            active=await EnsureRuntimeAsync(command.expected).ConfigureAwait(false);
            if(active.IsSharing) return;
            if(active.ReadyCapture is not { Ready:true }) throw new InvalidOperationException("Choose a source first.");
            createdPresence=active.BoundControl is null;
            _=active.BoundControl ?? await active.StartControlPresenceAsync(bindPlan,identity!.ControlServiceName,command.token.Token).ConfigureAwait(false);
            bool needPublication; lock(state) needPublication=published is null || !discoverable;
            if(needPublication) await PublishLockedAsync(active,null,() => true,command.expected,command.token.Token).ConfigureAwait(false);
            await active.StartVisibleShareAsync(view,command.token.Token).ConfigureAwait(false);
            if(!Current(command.expected)) throw new OperationCanceledException();
            Notify("Sharing the selected source. Remote input is unavailable.");
        }
        catch { if(createdPresence && active is not null) await RetireFailedNewPresenceLockedAsync(active).ConfigureAwait(false); throw; }
        finally { ExitCommand(command.token); }
    }
    private async Task PublishLockedAsync(LinuxHostRuntime active,LinuxHostBoundPair? pair,Func<bool> pairCurrent,long expected,CancellationToken token)
    {
        var bound=active.BoundControl ?? throw new IOException("No successful control bind.");
        if(pair is not null && !pairCurrent()) throw new OperationCanceledException();
        // A discovery lease is CONTROL presence even when it includes finite
        // Pair metadata. Pair cancellation uses the actual submission token and
        // independent PIN authority; it cannot revoke transferred control.
        var lease=new LinuxHostDiscoveryLease(new(Guid.NewGuid(),bound,pair),TimeProvider.System,active.RemainingPresence(),
            () => Current(expected) && active.IsPresenceCurrent);
        ILinuxHostPublishedServices? previous; LinuxHostDiscoveryLease? previousLease;
        lock(state) { previous=published; previousLease=publicationLease; }
        ILinuxHostPublishedServices? next=null; bool installed=false;
        try
        {
            if(previous is not null && previousLease?.Snapshot.Control.Generation!=bound.Generation) throw new InvalidOperationException("A different control generation must retire first.");
            if(previousLease?.Snapshot.Pair is not null && pair is not null) throw new InvalidOperationException("Remove the previous Pair publication first.");
            next=previous is null
                ? await discovery.PublishAsync(lease,token).ConfigureAwait(false)
                : await discovery.ReplaceAsync(previous,lease,token).ConfigureAwait(false);
            if(!Current(expected) || !lease.IsCurrent || next.PublicationId!=lease.Id || !next.IsEstablished) throw new OperationCanceledException("Discovery was not established for this attempt.");
            var captured=next;
            next.Lost+=() => PublicationLost(captured);
            lock(state)
            {
                if(!Current(expected) || !next.IsEstablished) throw new OperationCanceledException();
                published=next; publicationLease=lease; discoverable=true; installed=true;
            }
            // Replace transferred ownership before returning. Old cancellation
            // callbacks/result cleanup can no longer close the stable control.
            previousLease?.Invalidate();
            // Transfer is committed. A retired wrapper's cleanup failure must
            // not roll back/dispose the new established serving publication.
            if(previous is not null) OwnDrain(RetirePublicationAsync(previous,previousLease));
            else previousLease?.Dispose();
            next=null; // ownership moved into published; catch no longer owns it
            Notify();
        }
        catch
        {
            if(!installed)
            {
                lease.Invalidate();
                if(next is not null) await next.DisposeAsync().ConfigureAwait(false);
                lease.Dispose();
            }
            throw;
        }
    }
    private void OwnDrain(Task task)
    {
        lock(state) pairDrains.Add(task);
        _=task.ContinueWith(t => { _=t.Exception; },CancellationToken.None,TaskContinuationOptions.OnlyOnFaulted,TaskScheduler.Default);
    }
    private static async Task RetirePublicationAsync(ILinuxHostPublishedServices value,LinuxHostDiscoveryLease? lease)
    { try { await value.DisposeAsync().ConfigureAwait(false); } finally { lease?.Dispose(); } }
    private void PublicationLost(ILinuxHostPublishedServices source)
    {
        LinuxHostPinEnrollment? pin;
        lock(state) { if(!ReferenceEquals(published,source)) return; discoverable=false; pin=pairing; }
        pin?.Cancel();
        // Discovery loss never silently revokes a still-authorized established
        // TLS/media session. New readiness is unavailable until explicit retry.
        Notify("Local discovery is unavailable. Existing connections remain active.");
    }
    private void PairClosed(LinuxHostPinEnrollment pin)
    {
        // Cancel/expiry already closed PIN authority synchronously. This is the
        // one owner that removes finite Pair TXT; never wait for vault cleanup.
        OwnDrain(RemovePairAfterCloseAsync(pin));
    }
    private async Task RemovePairAfterCloseAsync(LinuxHostPinEnrollment pin)
    {
        try { await lifecycle.WaitAsync(closing.Token).ConfigureAwait(false); }
        catch(OperationCanceledException) { return; }
        try
        {
            long expected=Interlocked.Read(ref epoch);
            if(!Current(expected)) return;
            lock(state) if(!ReferenceEquals(pairing,pin)) return;
            await RemovePairLockedAsync(pin,expected,closing.Token).ConfigureAwait(false);
            Notify(pin.Succeeded ? "Device paired. Choose a source to share." : "Pairing closed.");
        }
        catch(Exception e) when(e is IOException or OperationCanceledException or InvalidOperationException)
        { lock(state) discoverable=false; Notify("Pairing closed. Local discovery is unavailable."); }
        finally { lifecycle.Release(); }
    }
    private async Task RemovePairLockedAsync(LinuxHostPinEnrollment? expectedPin,long expected,CancellationToken token)
    {
        LinuxHostPinEnrollment? old; LinuxHostRuntime? active; bool hasPair;
        lock(state)
        {
            old=pairing; active=host; hasPair=publicationLease?.Snapshot.Pair is not null;
            if(expectedPin is not null && !ReferenceEquals(expectedPin,old)) return;
            pairing=null;
        }
        old?.Cancel();
        try
        {
            if(hasPair && active?.IsPresenceCurrent==true) await PublishLockedAsync(active,null,() => true,expected,token).ConfigureAwait(false);
        }
        finally { if(old is not null) OwnDrain(old.DisposeAsync().AsTask()); }
    }
    private async Task RetireFailedNewPresenceLockedAsync(LinuxHostRuntime active)
    {
        ILinuxHostPublishedServices? oldPub=null; LinuxHostDiscoveryLease? oldLease=null; LinuxHostPinEnrollment? oldPin=null;
        lock(state)
        {
            if(!ReferenceEquals(host,active)) return;
            host=null; oldPin=pairing; pairing=null; oldPub=published; published=null; oldLease=publicationLease; publicationLease=null; discoverable=false;
        }
        oldPin?.Cancel(); oldLease?.Invalidate(); active.Stop();
        if(oldPin is not null) OwnDrain(oldPin.DisposeAsync().AsTask());
        try { if(oldPub is not null) await RetirePublicationAsync(oldPub,oldLease).ConfigureAwait(false); else oldLease?.Dispose(); }
        finally { await active.DisposeAsync().ConfigureAwait(false); }
        Notify();
    }
    public void CancelPairing() { LinuxHostPinEnrollment? pin; lock(state) pin=pairing; pin?.Cancel(); }
    public void StopHost()
    {
        LinuxHostRuntime? old; LinuxHostPinEnrollment? pin; ILinuxHostPublishedServices? pub; LinuxHostDiscoveryLease? lease; CancellationTokenSource oldEpoch; Task prior;
        var completion=new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock(state)
        {
            Interlocked.Increment(ref epoch); oldEpoch=epochStop; epochStop=new(); prior=retired;
            // Publish the retirement barrier BEFORE another command can capture
            // this epoch: no second native observer until old drain completes.
            retired=completion.Task;
            old=host; host=null; pin=pairing; pairing=null; pub=published; published=null; lease=publicationLease; publicationLease=null; discoverable=false;
        }
        // No I/O await before exact authority/publication admission closes.
        pin?.Cancel(); old?.Stop(); lease?.Invalidate();
        _=Task.Run(async () =>
        {
            var errors=new List<Exception>();
            async Task Attempt(Func<Task> action) { try { await action().ConfigureAwait(false); } catch(Exception e) { errors.Add(e); } }
            try
            {
                oldEpoch.Cancel();
                await Attempt(() => prior).ConfigureAwait(false);
                if(pub is not null) await Attempt(() => RetirePublicationAsync(pub,lease)).ConfigureAwait(false); else lease?.Dispose();
                if(pin is not null) await Attempt(() => pin.DisposeAsync().AsTask()).ConfigureAwait(false);
                if(old is not null) await Attempt(() => old.DisposeAsync().AsTask()).ConfigureAwait(false);
                if(errors.Count==0) completion.TrySetResult(true); else completion.TrySetException(new AggregateException(errors));
            }
            catch(Exception e) { completion.TrySetException(e); }
            finally { oldEpoch.Dispose(); }
        });
        _=completion.Task.ContinueWith(t => { _=t.Exception; },CancellationToken.None,TaskContinuationOptions.OnlyOnFaulted,TaskScheduler.Default);
        Notify("Sharing stopped.");
    }
    public async ValueTask DisposeAsync()
    {
        if(Interlocked.Exchange(ref closed,1)!=0) return;
        StopHost(); closing.Cancel(); await lifecycle.WaitAsync().ConfigureAwait(false);
        try
        {
            await retired.ConfigureAwait(false); Task[] pairs; lock(state) pairs=pairDrains.ToArray();
            await Task.WhenAll(pairs).ConfigureAwait(false);
        }
        finally { trust?.Dispose(); lifecycle.Release(); closing.Dispose(); epochStop.Dispose(); }
    }
}
