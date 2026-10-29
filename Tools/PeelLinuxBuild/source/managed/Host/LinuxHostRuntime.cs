using System.Collections.Concurrent;
using System.Net;
using System.Text.Json;
using Peel.Windows.Protocol;
namespace Peel.Linux.Host;
internal sealed class LinuxHostRuntime : IAsyncDisposable
{
    private readonly LinuxHostTrust trust;
    private readonly IPeelPskTransportFactory transport;
    private readonly ILinuxHostNative native;
    private readonly string hostName;
    private readonly LinuxHostAuthority authority = new();
    private readonly CancellationTokenSource lifetime = new();
    private readonly SemaphoreSlim encoderSlot = new(1, 1);
    private readonly ConcurrentDictionary<Stream, byte> accepted = new();
    private readonly ConcurrentDictionary<long, Task> sessions = new();
    private readonly object lifecycle = new();
    private IPeelPskListener? listener;
    private Task[] workers = [];
    private Task stopTask = Task.CompletedTask;
    private int sessionCount, stopped;
    private long sessionId;
    private bool started;
    private long presenceAt;
    private DateTimeOffset presenceExpiresAt;
    private readonly Guid presenceGeneration = Guid.NewGuid();
    internal event Action? Changed;
    internal LinuxHostBoundControl? BoundControl { get; private set; }
    internal LinuxHostCapture? ReadyCapture => native.Available ? authority.Capture : null;
    internal bool IsSharing => authority.IsEnabled;
    // Used by discovery lease predicates: no backend/authority lock inversion.
    internal bool IsPresenceCurrent => Volatile.Read(ref stopped) == 0 && BoundControl is not null
        && TimeProvider.System.GetElapsedTime(presenceAt) < TimeSpan.FromMinutes(30);

    internal LinuxHostRuntime(LinuxHostTrust trust, IPeelPskTransportFactory transport, ILinuxHostNative native, string hostName)
    {
        if (!LinuxHostWire.Text(hostName, 256)) throw new ArgumentException(nameof(hostName));
        this.trust = trust; this.transport = PeelSecureTransport.Require(transport); this.native = native; this.hostName = hostName;
        trust.PeerRevoked += PeerRevoked;
    }
    // Initialize after GTK activation, off its thread. Never opens a listener.
    internal Task InitializeAsync() => native.InitializeAsync(CaptureChanged);
    private void CaptureChanged(LinuxHostCapture? capture)
    {
        authority.UpdateCapture(capture); // media retires; paired control stays
        Changed?.Invoke();
    }
    internal bool IsStopped => Volatile.Read(ref stopped) != 0;
    internal async Task<LinuxHostBoundControl> StartControlPresenceAsync(LinuxHostBindPlan plan, string serviceName, CancellationToken token)
    {
        if (!LinuxHostWire.Text(serviceName,63) || System.Text.Encoding.UTF8.GetByteCount(serviceName) > 63) throw new ArgumentException("A stable DNS-SD service name is required.");
        lock (lifecycle) { if (started || stopped != 0) throw new InvalidOperationException("Host generations cannot restart."); started = true; presenceAt = TimeProvider.System.GetTimestamp(); presenceExpiresAt = DateTimeOffset.UtcNow.AddMinutes(30); }
        try
        {
            using var opening = CancellationTokenSource.CreateLinkedTokenSource(token,lifetime.Token);
            var created = await Task.Run(async () => await transport.ListenAsync(new(plan.Address,0),trust,opening.Token).ConfigureAwait(false),opening.Token).ConfigureAwait(false);
            if (created.LocalEndPoint is not IPEndPoint endpoint || !endpoint.Address.Equals(IPAddress.IPv6Any) || endpoint.Port is < 1 or > 65535)
            { await created.DisposeAsync().ConfigureAwait(false); throw new IOException("The actual dual-stack control bind is unavailable."); }
            LinuxHostBoundControl bound;
            try { lock (lifecycle)
            {
                if (stopped != 0) throw new OperationCanceledException();
                authority.EnableControl(presenceAt); listener = created;
                BoundControl = bound = new(presenceGeneration,trust.HostId,hostName,serviceName,endpoint.Address.ToString(),checked((ushort)endpoint.Port),plan.InterfaceIndex,plan.AvahiProtocol,plan.DualStack,presenceExpiresAt);
                workers = Enumerable.Range(0,4).Select(_ => AcceptAsync()).ToArray();
            } }
            catch { await created.DisposeAsync().ConfigureAwait(false); throw; }
            _ = ExpireAsync(); Changed?.Invoke(); return bound;
        }
        catch { Stop(); throw; }
    }
    internal async Task StartVisibleShareAsync(ILinuxHostConsentView view,CancellationToken token)
    {
        var bound = BoundControl;
        if (!IsPresenceCurrent || bound is null || !native.Available || authority.Capture is not { Ready: true } || trust.Count == 0)
            throw new IOException("A paired device, current source and actual H264 encoder are required.");
        var capture = authority.Capture!; Guid instance = authority.SourceInstance; long consentStart = authority.Timestamp;
        var presentation = new LinuxHostNetworkPresentation(trust.HostId,hostName,bound.BindAddress,bound.Port,capture.Width,capture.Height,capture.Kind,bound.ExpiresAt);
        if (!await view.ConfirmNetworkHostAsync(presentation,Stop,token).ConfigureAwait(false)) throw new OperationCanceledException();
        token.ThrowIfCancellationRequested(); if (!IsPresenceCurrent) throw new OperationCanceledException();
        authority.Enable(capture,instance,consentStart); Changed?.Invoke();
    }
    internal TimeSpan RemainingPresence()
    { var remaining = TimeSpan.FromMinutes(30) - TimeProvider.System.GetElapsedTime(presenceAt); return remaining > TimeSpan.Zero ? remaining : TimeSpan.Zero; }
    private async Task ExpireAsync()
    { try { await Task.Delay(RemainingPresence(), lifetime.Token).ConfigureAwait(false); Stop(); } catch (OperationCanceledException) { } }
    private async Task AcceptAsync()
    {
        while (!lifetime.IsCancellationRequested)
        {
            PeelPskConnection? c = null;
            try
            {
                using var handshake = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token); handshake.CancelAfter(TimeSpan.FromSeconds(10));
                c = await listener!.AcceptAsync(handshake.Token).ConfigureAwait(false);
                if (Interlocked.Increment(ref sessionCount) > 8) { Interlocked.Decrement(ref sessionCount); await c.DisposeAsync().ConfigureAwait(false); continue; }
                var owned = c; c = null; long id = Interlocked.Increment(ref sessionId);
                Task task = ServeAsync(owned); sessions[id] = task;
                _ = task.ContinueWith(t => { sessions.TryRemove(id, out _); _ = t.Exception; }, CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
            }
            catch (Exception e) when (e is IOException or OperationCanceledException or InvalidOperationException) { if (c is not null) await c.DisposeAsync().ConfigureAwait(false); }
        }
    }
    private async Task ServeAsync(PeelPskConnection c)
    {
        accepted.TryAdd(c.Stream, 0);
        try
        {
            using var classify = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token); classify.CancelAfter(TimeSpan.FromSeconds(5));
            using var close = classify.Token.Register(c.Stream.Dispose);
            byte[] first = await LinuxHostWire.ReadAsync(c.Stream, false, classify.Token).ConfigureAwait(false);
            using var json = LinuxHostWire.Parse(first); var r = json.RootElement; string type = LinuxHostWire.Type(r);
            var peer = trust.Capture(c.PeerIdentity); // Real current inbound key, never claimed hello pairing ID.
            if (type == PeelMessageType.ClientHello) { LinuxHostWire.Hello(r, c.PeerIdentity, false); classify.CancelAfter(Timeout.InfiniteTimeSpan); await ControlAsync(c.Stream, peer).ConfigureAwait(false); }
            else if (type == PeelMessageType.VideoStreamHello) { LinuxHostWire.Hello(r, c.PeerIdentity, true); uint window = r.GetProperty("windowId").GetUInt32(); classify.CancelAfter(Timeout.InfiniteTimeSpan); await VideoAsync(c.Stream, peer, window).ConfigureAwait(false); }
            else throw new InvalidDataException("Only authenticated current control/video channels are supported.");
        }
        catch (Exception e) when (e is IOException or OperationCanceledException or JsonException or InvalidOperationException or FormatException or OverflowException) { }
        finally { accepted.TryRemove(c.Stream, out _); await c.DisposeAsync().ConfigureAwait(false); Interlocked.Decrement(ref sessionCount); }
    }
    private async Task ControlAsync(Stream stream, LinuxHostPeerLease peer)
    {
        var control = authority.AdmitControl(peer, stream);
        using var session = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token, control.Lifetime.Token);
        try
        {
            await SendAsync(control, PeelHello.CreateHost(hostName, "Linux", Environment.OSVersion.VersionString, "2.0.0", (native.Available ? LinuxHostWire.VideoCapabilities : Array.Empty<string>()).Concat([PeelCapability.InputCapabilities, PeelCapability.ClientVisibility])), session.Token).ConfigureAwait(false);
            // The input-capabilities reporting channel explicitly reports all input unavailable.
            await SendAsync(control, new InputCapabilitiesMessage(false, false, false, false, false), session.Token).ConfigureAwait(false);
            while (authority.IsCurrent(control))
            {
                using var read = CancellationTokenSource.CreateLinkedTokenSource(session.Token); read.CancelAfter(TimeSpan.FromSeconds(60));
                byte[] bytes = await LinuxHostWire.ReadAsync(stream, false, read.Token).ConfigureAwait(false);
                using var d = LinuxHostWire.Parse(bytes); var r = d.RootElement;
                switch (LinuxHostWire.Type(r))
                {
                    case PeelMessageType.RequestWindowList:
                        LinuxHostWire.Exact(r, "type"); var capture = authority.SharedCapture;
                        var rows = capture is { Ready: true } ? new[] { new PeelWindow(1, "Peel Pro", "Shared portal source", checked((int)capture.Width), checked((int)capture.Height), "View only · portal consent active") } : Array.Empty<PeelWindow>();
                        await SendAsync(control, new WindowListMessage(rows), session.Token).ConfigureAwait(false); break;
                    case PeelMessageType.StartStream:
                        LinuxHostWire.Exact(r, "type", "windowId"); authority.StartStream(control, r.GetProperty("windowId").GetUInt32()); break;
                    case PeelMessageType.StopStream:
                        LinuxHostWire.Exact(r, "type", "windowId"); authority.StopStream(control, r.GetProperty("windowId").GetUInt32()); break;
                    case PeelMessageType.ClientPing: LinuxHostWire.Exact(r, "type"); break;
                    case PeelMessageType.ClientHello:
                        // Current Apple sends the same hello again on foreground.
                        // It never replaces the control generation or grants input.
                        LinuxHostWire.Hello(r, peer.Peer.PairingId, false); break;
                    case PeelMessageType.ClientVisibility:
                        LinuxHostWire.Exact(r, "type", "isVisible"); authority.SetVisibility(control, r.GetProperty("isVisible").GetBoolean()); break;
                    case PeelMessageType.MouseClick: case PeelMessageType.MouseMove: case PeelMessageType.MouseScroll:
                    case PeelMessageType.MouseDown: case PeelMessageType.MouseDrag: case PeelMessageType.MouseUp:
                    case PeelMessageType.KeyboardText: case PeelMessageType.KeyboardCommand: case PeelMessageType.KeyboardHardwareKey:
                    case PeelMessageType.KeyboardChord: case PeelMessageType.KeyboardMacro: case PeelMessageType.ClientActiveWindow: case PeelMessageType.HostCommand: case PeelMessageType.ClipboardText:
                        await SendAsync(control, new InputRejectedMessage(1, "Linux host input is unavailable in this build.", DateTimeOffset.UtcNow), session.Token).ConfigureAwait(false); break;
                    default: throw new InvalidDataException("Unsupported control operation.");
                }
            }
        }
        finally { authority.EndControl(control); }
    }
    private async Task SendAsync<T>(LinuxHostControl control, T value, CancellationToken token)
    {
        using var write = CancellationTokenSource.CreateLinkedTokenSource(token); write.CancelAfter(TimeSpan.FromSeconds(3));
        await authority.Dispatch(control, PeelJson.SerializeLine(value), write.Token).ConfigureAwait(false);
    }
    private async Task VideoAsync(Stream stream, LinuxHostPeerLease peer, uint window)
    {
        var reservation = authority.AttachVideo(peer, window, stream);
        using var queue = new LinuxHostVideoQueue(authority, reservation);
        using var video = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token, reservation.Lifetime.Token);
        ulong encoder = 0; bool slot = false;
        try
        {
            using var startup = CancellationTokenSource.CreateLinkedTokenSource(video.Token); startup.CancelAfter(TimeSpan.FromSeconds(5));
            await encoderSlot.WaitAsync(startup.Token).ConfigureAwait(false); slot = true;
            startup.Token.ThrowIfCancellationRequested();
            Task<ulong> pending = native.StartAsync(authority, reservation, queue, startup.Token);
            try { encoder = await pending.WaitAsync(startup.Token).ConfigureAwait(false); }
            catch
            {
                authority.EndVideo(reservation);
                // Retain and retire a late native completion; timeout cannot orphan
                // a started encoder or release its callbacks before exact stop.
                _ = pending.ContinueWith(async t => { if (t.IsCompletedSuccessfully) await native.StopAsync(reservation.Capture.Generation, t.Result).ConfigureAwait(false); else _ = t.Exception; },
                    CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default).Unwrap();
                throw;
            }
            await queue.WriteAsync(video.Token).ConfigureAwait(false);
        }
        finally
        {
            authority.EndVideo(reservation); queue.Close();
            if (encoder != 0) await native.StopAsync(reservation.Capture.Generation, encoder).ConfigureAwait(false);
            if (slot) encoderSlot.Release();
        }
    }
    private void PeerRevoked(string pairing) => authority.Revoke(pairing);
    internal void Stop()
    {
        var done = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (lifecycle) { if (stopped != 0) return; stopped = 1; authority.Stop(); stopTask=done.Task; }
        // Publish the drain barrier before callbacks/new lifecycle code observe
        // Stop. Native observer retirement remains owned by DisposeAsync.
        _ = Task.Run(async () =>
        {
            try
            {
                lifetime.Cancel();
                try { if (listener is not null) await listener.DisposeAsync().ConfigureAwait(false); }
                finally { foreach (var s in accepted.Keys) { try { s.Dispose(); } catch (IOException) { } } }
                done.TrySetResult(true);
            }
            catch(Exception e) { done.TrySetException(e); }
        });
        _=done.Task.ContinueWith(t => { _=t.Exception; },CancellationToken.None,TaskContinuationOptions.OnlyOnFaulted,TaskScheduler.Default);
        Changed?.Invoke();
    }
    public async ValueTask DisposeAsync()
    {
        Stop(); trust.PeerRevoked -= PeerRevoked;
        var errors = new List<Exception>();
        async Task Attempt(Task task) { try { await task.ConfigureAwait(false); } catch(Exception e) { errors.Add(e); } }
        try
        {
            await Attempt(stopTask).ConfigureAwait(false);
            await Attempt(Task.WhenAll(workers)).ConfigureAwait(false);
            await Attempt(Task.WhenAll(sessions.Values.ToArray())).ConfigureAwait(false);
        }
        finally { try { await native.DisposeAsync().ConfigureAwait(false); } finally { lifetime.Dispose(); } }
        if(errors.Count!=0) throw new AggregateException(errors);
    }
}
