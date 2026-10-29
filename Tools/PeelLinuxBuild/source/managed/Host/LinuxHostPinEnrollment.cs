using System.Net;
using System.Security.Cryptography;
using Peel.Windows.Protocol;
namespace Peel.Linux.Host;
internal sealed record LinuxHostPinPresentation(Guid Generation, string HostId, string HostName, string Pin, string SaltBase64,
    string BindAddress, int Port, DateTimeOffset ExpiresAt)
{ public override string ToString() => "Linux pairing presentation (PIN redacted)"; }
// A concrete view must display the exact presentation before returning true, retain
// Cancel/Stop, and synchronously call Cancel when closed. Not supplied by headless code.
internal sealed record LinuxHostNetworkPresentation(string HostId, string HostName, string BindAddress, int Port,
    uint Width, uint Height, uint PortalSourceKind, DateTimeOffset ExpiresAt);
internal interface ILinuxHostConsentView
{
    Task<bool> ShowPairingAsync(LinuxHostPinPresentation presentation, Action cancel, CancellationToken token);
    Task<bool> ConfirmNetworkHostAsync(LinuxHostNetworkPresentation presentation, Action stop, CancellationToken token);
    void PairingClosed(Guid generation);
}
internal sealed class LinuxHostPinEnrollment : IPeelPskCredentialResolver, IAsyncDisposable
{
    private readonly object gate = new();
    private readonly LinuxHostTrust trust;
    private readonly IPeelPskTransportFactory transport;
    private readonly ILinuxHostConsentView view;
    private readonly TimeProvider clock;
    private readonly string controlServiceName;
    private readonly Func<bool> controlCurrent;
    private int publicationReady;
    internal event Action<Guid>? Closed;
    internal IPEndPoint? BoundEndPoint { get; private set; }
    internal bool IsPairCurrent => started && Volatile.Read(ref cancelled)==0 && controlCurrent() && clock.GetElapsedTime(start)<TimeSpan.FromSeconds(120);
    internal Task Finished => runner ?? Task.CompletedTask;
    internal bool Succeeded => completion?.Completed == true;
    internal CancellationToken Lifetime => stop.Token;
    private readonly CancellationTokenSource stop = new();
    private readonly HashSet<Stream> connections = [];
    private IPeelPskListener? listener;
    private Task? runner;
    private Task closeTask = Task.CompletedTask;
    private Task? disposal;
    private LinuxHostPinCompletion? completion;
    private byte[] pinKey = [];
    private long start;
    private int attempts, cancelled;
    private volatile bool visible, consumed;
    private volatile bool started;
    internal Guid Generation { get; } = Guid.NewGuid();
    internal LinuxHostPinEnrollment(LinuxHostTrust trust, IPeelPskTransportFactory transport, ILinuxHostConsentView view, string controlServiceName, Func<bool> controlCurrent, TimeProvider? clock = null)
    {
        if (!LinuxHostWire.Text(controlServiceName,63) || System.Text.Encoding.UTF8.GetByteCount(controlServiceName)>63) throw new ArgumentException("Actual stable control service name required.");
        this.trust=trust; this.transport=PeelSecureTransport.Require(transport); this.view=view; this.controlServiceName=controlServiceName; this.controlCurrent=controlCurrent; this.clock=clock ?? TimeProvider.System;
    }
    internal void PublicationEstablished()
    {
        if (!IsPairCurrent) throw new OperationCanceledException();
        Volatile.Write(ref publicationReady,1);
    }
    internal async Task<LinuxHostPinPresentation> StartAsync(string hostName, IPEndPoint endpoint, CancellationToken token)
    {
        if (!LinuxHostWire.Text(hostName, 256) || (endpoint.Port != 0 && endpoint.Port < 1024) || endpoint.Port > 65535) throw new ArgumentException("Explicit unprivileged pairing port required.");
        lock (gate) { if (started || cancelled != 0) throw new InvalidOperationException("Pairing generations cannot restart."); started = true; start = clock.GetTimestamp();
            completion = new(trust, clock, start, () => Volatile.Read(ref cancelled) == 0 && visible && consumed && Volatile.Read(ref publicationReady)==1 && controlCurrent());
        } string pin = RandomNumberGenerator.GetInt32(0, 1_000_000).ToString("D6", System.Globalization.CultureInfo.InvariantCulture);
        byte[] salt = RandomNumberGenerator.GetBytes(16); byte[] derived = PeelPinPairing.DerivePreSharedKey(pin, salt, trust.HostId);
        lock (gate) { if (cancelled != 0) { CryptographicOperations.ZeroMemory(derived); throw new OperationCanceledException(); } pinKey = derived; }
        var p = new LinuxHostPinPresentation(Generation, trust.HostId, hostName, pin, Convert.ToBase64String(salt), endpoint.Address.ToString(), endpoint.Port, clock.GetUtcNow().AddSeconds(120));
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(token, stop.Token);
        try
        {
            if (!await view.ShowPairingAsync(p, Cancel, linked.Token).ConfigureAwait(false)) throw new OperationCanceledException();
            lock (gate) { if (!Current(false,false)) throw new OperationCanceledException(); visible = true; }
            listener = await Task.Run(async () => await transport.ListenAsync(endpoint, this, linked.Token).ConfigureAwait(false), linked.Token).ConfigureAwait(false);
            if (listener.LocalEndPoint is not IPEndPoint actual || actual.Port is < 1 or > 65535 || !actual.Address.Equals(endpoint.Address))
            { await listener.DisposeAsync().ConfigureAwait(false); throw new IOException("Actual Pair bind unavailable."); }
            BoundEndPoint = new(actual.Address,actual.Port);
            p = p with { Port=actual.Port, BindAddress=actual.Address.ToString() };
            if (Volatile.Read(ref cancelled) != 0) { await listener.DisposeAsync().ConfigureAwait(false); throw new OperationCanceledException(); }
            runner = Task.Run(() => RunAsync(hostName)); return p;
        }
        catch { Cancel(); throw; }
    }
    private bool Current(bool requireVisible = true,bool requirePublication=true) => Volatile.Read(ref cancelled) == 0 && !consumed && (!requireVisible || visible) && (!requirePublication || Volatile.Read(ref publicationReady)==1) && controlCurrent()
        && clock.GetElapsedTime(start) < TimeSpan.FromSeconds(120);
    public bool TryResolve(string identity, out PeelPskCredential? credential)
    {
        credential = null;
        lock (gate)
        {
            if (identity != PeelPinPairing.TlsIdentity || !Current() || ++attempts > 8) return false;
            credential = new(identity, pinKey); return true;
        }
    }
    private async Task RunAsync(string hostName)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(stop.Token);
        TimeSpan remaining = TimeSpan.FromSeconds(120) - clock.GetElapsedTime(start);
        using var expireGeneration = deadline.Token.Register(Cancel);
        deadline.CancelAfter(remaining > TimeSpan.Zero ? remaining : TimeSpan.Zero);
        try
        {
            while (!deadline.IsCancellationRequested)
            {
                PeelPskConnection? connection = null;
                try
                {
                    using var accept = CancellationTokenSource.CreateLinkedTokenSource(deadline.Token); accept.CancelAfter(TimeSpan.FromSeconds(10));
                    connection = await listener!.AcceptAsync(accept.Token).ConfigureAwait(false);
                    lock (gate) { if (!Current()) throw new OperationCanceledException(); connections.Add(connection.Stream); }
                    using var request = CancellationTokenSource.CreateLinkedTokenSource(deadline.Token); request.CancelAfter(TimeSpan.FromSeconds(5));
                    Stream wire = connection.Stream;
                    using var closeOnCancel = request.Token.Register(Cancel);
                    byte[] bytes = await LinuxHostWire.ReadAsync(connection.Stream, true, request.Token).ConfigureAwait(false);
                    using var json = LinuxHostWire.Parse(bytes); var r = json.RootElement;
                    LinuxHostWire.Exact(r, "type", "clientName", "clientDeviceId", "pinProof");
                    var message = PeelJson.Deserialize<PairRequestMessage>(bytes);
                    LinuxHostPeer peer;
                    byte[] key = RandomNumberGenerator.GetBytes(32);
                    try
                    {
                        lock (gate)
                        {
                            if (!Current() || connection.PeerIdentity != PeelPinPairing.TlsIdentity || message.Type != PeelMessageType.PairRequest
                                || !LinuxHostWire.Text(message.ClientName, 256) || !LinuxHostWire.Text(message.ClientDeviceId, 1024)
                                || message.ClientDeviceId.Trim() != message.ClientDeviceId
                                || !PeelPinPairing.VerifyProof(pinKey, trust.HostId, message.ClientDeviceId, message.PinProof)) throw new InvalidDataException("Pairing proof rejected.");
                            // Exactly one successful proof consumes this visible generation.
                            consumed = true;
                        }
                        peer = await Task.Run(() => trust.EnrollFromPin(message.ClientDeviceId, message.ClientName, key, completion!.Prepare), request.Token).ConfigureAwait(false);
                        byte[] response = PeelJson.SerializeLine(new PairResponseMessage(hostName, controlServiceName, peer.PairingId, key, true));
                        try { await completion!.SendAcceptedAsync(peer, wire, response, request.Token).ConfigureAwait(false); }
                        finally { CryptographicOperations.ZeroMemory(response); }
                        break;
                    }
                    finally { CryptographicOperations.ZeroMemory(key); }
                }
                catch (Exception e) when (e is IOException or OperationCanceledException or InvalidDataException or System.Text.Json.JsonException or FormatException or InvalidOperationException) { }
                finally { if (connection is not null) { lock (gate) connections.Remove(connection.Stream); await connection.DisposeAsync().ConfigureAwait(false); } }
                lock (gate) if (consumed || attempts >= 8) break;
            }
        }
        finally { Cancel(); if (listener is not null) await listener.DisposeAsync().ConfigureAwait(false); }
    }
    internal void Cancel()
    {
        // Publish exact cleanup ownership under the same gate before another
        // disposer can observe cancelled. No secure-store/network wait on GTK.
        var done=new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock(gate) { if(cancelled!=0) return; Volatile.Write(ref cancelled,1); closeTask=done.Task; }
        completion?.Cancel(); // deny provisional authority BEFORE deferred abort
        Stream[] close; lock(gate) { visible=false; close=connections.ToArray(); CryptographicOperations.ZeroMemory(pinKey); pinKey=[]; }
        _=Task.Run(async () =>
        {
            try
            {
                try { stop.Cancel(); }
                finally
                {
                    foreach(var s in close) { try { s.Dispose(); } catch(IOException) { } }
                    if(listener is not null) await listener.DisposeAsync().ConfigureAwait(false);
                }
                done.TrySetResult(true);
            }
            catch(Exception e) { done.TrySetException(e); }
        });
        _=done.Task.ContinueWith(t => { _=t.Exception; },CancellationToken.None,TaskContinuationOptions.OnlyOnFaulted,TaskScheduler.Default);
        view.PairingClosed(Generation);
        Closed?.Invoke(Generation);
    }
    public ValueTask DisposeAsync()
    {
        TaskCompletionSource<bool> done;
        lock(gate)
        {
            if(disposal is not null) return new(disposal);
            done=new(TaskCreationOptions.RunContinuationsAsynchronously); disposal=done.Task;
        }
        Cancel(); _=DisposeOwnedAsync(done); return new(done.Task);
    }
    private async Task DisposeOwnedAsync(TaskCompletionSource<bool> done)
    {
        var errors=new List<Exception>();
        async Task Attempt(Task task) { try { await task.ConfigureAwait(false); } catch(Exception e) { errors.Add(e); } }
        try
        {
            if(runner is not null) await Attempt(runner).ConfigureAwait(false);
            Task close; lock(gate) close=closeTask; await Attempt(close).ConfigureAwait(false);
            if(completion is not null) await Attempt(completion.DrainAsync()).ConfigureAwait(false);
        }
        catch(Exception e) { errors.Add(e); }
        finally
        {
            lock(gate) { CryptographicOperations.ZeroMemory(pinKey); pinKey=[]; }
            stop.Dispose();
        }
        if(errors.Count==0) done.TrySetResult(true); else done.TrySetException(new AggregateException(errors));
    }
}
