using System.Net;
using System.Text;
using Peel.Linux.Host;
using Peel.Windows.Protocol;

// Fake-only deterministic checks. No GTK, Secret Service, sockets, provider,
// device, real PIN/key, or native encoder is loaded by this executable.
const string HostId = "11111111-1111-4111-8111-111111111111";
var cases = new (string name, Func<Task> run)[] {
    ("outbound-secret-is-not-inbound-trust", () => Run(() => { var v = new Vault(); v.rows["saved-remote-id"] = "outbound"; using var t = Trust(v); Check(!t.TryResolve("saved-remote-id", out _)); })),
    ("missing-secret-denies-persisted-metadata", () => Run(() => { var v = new Vault(); using var t = Trust(v); var p = Enroll(t); v.rows.Clear(); Check(!t.TryResolve(p.PairingId, out _)); Reject(() => t.Capture(p.PairingId)); })),
    ("secret-service-error-never-publishes-peer", () => Run(() => { var v = new Vault { failWrite = true }; using var t = Trust(v); Reject(() => Enroll(t)); Check(t.Count == 0); })),
    ("metadata-error-never-publishes-peer", () => Run(() => { var v = new Vault(); using var t = Trust(v, _ => throw new IOException()); Reject(() => Enroll(t)); Check(t.Count == 0); })),
    ("revocation-closes-before-storage-error", () => Run(() => { var v = new Vault(); using var t = Trust(v); var p = Enroll(t); var old = t.Capture(p.PairingId); v.failWrite = true; Reject(() => t.Revoke(p.PairingId)); Check(!old.IsCurrent && !t.TryResolve(p.PairingId, out _)); })),
    ("replacement-closes-old-credential-revision", () => Run(() => { using var t = Trust(new Vault()); var p = Enroll(t); var old = t.Capture(p.PairingId); var next = Enroll(t); Check(!old.IsCurrent && next.PairingId != p.PairingId && t.Count == 1); })),
    ("pair-proof-bound-to-host-and-client", () => Run(() => { var k = Key(); string proof = PeelPinPairing.CreateProof(k, HostId, "test-client"); Check(PeelPinPairing.VerifyProof(k, HostId, "test-client", proof)); Check(!PeelPinPairing.VerifyProof(k, Guid.NewGuid().ToString("D"), "test-client", proof)); Check(!PeelPinPairing.VerifyProof(k, HostId, "other-client", proof)); })),
    ("pin-cancel-before-visible-never-listens", async () => { var transport = new FakeTransport(); using var t = Trust(new Vault()); var view = new View { show = false }; await using var p = new LinuxHostPinEnrollment(t, transport, view,"Synthetic control",() => true); await RejectAsync(() => p.StartAsync("test-host", new(IPAddress.Loopback, 54322), CancellationToken.None)); Check(transport.listens == 0); }),
    ("valid-visible-pin-proof-persists-before-response", async () => { using var t = Trust(new Vault()); var view = new View(); var transport = new PairTransport(view, false); await using var p = new LinuxHostPinEnrollment(t, transport, view,"Synthetic control",() => true); await p.StartAsync("test-host", new(IPAddress.Loopback,54322), CancellationToken.None); p.PublicationEstablished(); transport.OpenAdmission(); await transport.finished.Task.WaitAsync(TimeSpan.FromSeconds(2)); await p.Finished.WaitAsync(TimeSpan.FromSeconds(2)); Check(t.Count == 1); var peer = t.Snapshot().Single(); Check(t.TryResolve(peer.PairingId,out var credential)); byte[] reply = transport.wire!.ToArray()[transport.requestLength..]; var response = PeelJson.Deserialize<PairResponseMessage>(reply); Check(response.ServiceName == "Synthetic control" && response.Accepted && response.PairingId == peer.PairingId && response.Psk.AsSpan().SequenceEqual(credential!.PreSharedKey)); }),
    ("bad-client-proof-cannot-enroll", async () => { using var t = Trust(new Vault()); var view = new View(); var transport = new PairTransport(view, true); await using var p = new LinuxHostPinEnrollment(t, transport, view,"Synthetic control",() => true); await p.StartAsync("test-host", new(IPAddress.Loopback,54322), CancellationToken.None); p.PublicationEstablished(); transport.OpenAdmission(); await transport.finished.Task.WaitAsync(TimeSpan.FromSeconds(2)); Check(t.Count == 0); }),
    ("cancel-held-after-persist-before-response-launch", async () => { using var t = Trust(new Vault()); var clock = new Clock(); var owner = new LinuxHostPinCompletion(t,clock,clock.GetTimestamp(),() => true); var peer = t.EnrollFromPin("test-client","Synthetic client",Key(),owner.Prepare); var lease = t.Capture(peer.PairingId); var arrived = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously); var release = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously); using var wire = new CountedWriteStream(); Task send = Task.Run(async () => { arrived.TrySetResult(true); await release.Task; await owner.SendAcceptedAsync(peer,wire,"accepted"u8.ToArray(),CancellationToken.None); }); await arrived.Task.WaitAsync(TimeSpan.FromSeconds(1)); owner.Cancel(); Check(!lease.IsCurrent); release.TrySetResult(true); await RejectAsync(() => send.WaitAsync(TimeSpan.FromSeconds(1))); Check(wire.launches == 0 && !owner.Completed); await owner.DrainAsync().WaitAsync(TimeSpan.FromSeconds(2)); Check(!t.TryResolve(peer.PairingId,out _) && t.Count == 0); }),
    ("deadline-after-persist-denies-before-response-launch", async () => { using var t = Trust(new Vault()); var clock = new Clock(); var owner = new LinuxHostPinCompletion(t,clock,clock.GetTimestamp(),() => true); var peer = t.EnrollFromPin("test-client","Synthetic client",Key(),owner.Prepare); var lease = t.Capture(peer.PairingId); clock.Advance(TimeSpan.FromSeconds(120)); using var wire = new CountedWriteStream(); await RejectAsync(() => owner.SendAcceptedAsync(peer,wire,"accepted"u8.ToArray(),CancellationToken.None)); Check(wire.launches == 0 && !lease.IsCurrent); await owner.DrainAsync().WaitAsync(TimeSpan.FromSeconds(2)); Check(t.Count == 0); }),
    ("failed-accepted-response-write-revokes-provisional-peer", async () => { using var t = Trust(new Vault()); var clock = new Clock(); var owner = new LinuxHostPinCompletion(t,clock,clock.GetTimestamp(),() => true); var peer = t.EnrollFromPin("test-client","Synthetic client",Key(),owner.Prepare); var lease = t.Capture(peer.PairingId); using var wire = new CountedWriteStream { fail = true }; await RejectAsync(() => owner.SendAcceptedAsync(peer,wire,"accepted"u8.ToArray(),CancellationToken.None)); Check(wire.launches == 1 && !owner.Completed && !lease.IsCurrent); await owner.DrainAsync().WaitAsync(TimeSpan.FromSeconds(2)); Check(t.Count == 0); }),
    ("cancel-during-launched-response-keeps-denial", async () => { using var t = Trust(new Vault()); var clock = new Clock(); var owner = new LinuxHostPinCompletion(t,clock,clock.GetTimestamp(),() => true); var peer = t.EnrollFromPin("test-client","Synthetic client",Key(),owner.Prepare); var lease = t.Capture(peer.PairingId); using var wire = new HeldWriteStream(); Task send = owner.SendAcceptedAsync(peer,wire,"accepted"u8.ToArray(),CancellationToken.None); await wire.started.Task.WaitAsync(TimeSpan.FromSeconds(1)); owner.Cancel(); Check(owner.Launched && !lease.IsCurrent); wire.release.TrySetResult(true); await RejectAsync(() => send.WaitAsync(TimeSpan.FromSeconds(1))); Check(!owner.Completed); await owner.DrainAsync().WaitAsync(TimeSpan.FromSeconds(2)); Check(t.Count == 0); }),
    ("successful-response-detaches-before-finally-cancel", async () => { using var t = Trust(new Vault()); var clock = new Clock(); var owner = new LinuxHostPinCompletion(t,clock,clock.GetTimestamp(),() => true); var peer = t.EnrollFromPin("test-client","Synthetic client",Key(),owner.Prepare); using var wire = new CountedWriteStream(); await owner.SendAcceptedAsync(peer,wire,"accepted"u8.ToArray(),CancellationToken.None); Check(owner.Completed && wire.launches == 1); owner.Cancel(); await owner.DrainAsync(); Check(t.TryResolve(peer.PairingId,out _) && t.Count == 1); }),
    ("cancel-during-provisional-persistence-cannot-publish-trust", async () => { var vault = new HeldVault(); using var t = new LinuxHostTrust(HostId,vault,[],_ => { }); var clock = new Clock(); var owner = new LinuxHostPinCompletion(t,clock,clock.GetTimestamp(),() => true); LinuxHostPeer? provisional = null; Task commit = Task.Run(() => t.EnrollFromPin("test-client","Synthetic client",Key(),p => { provisional = p; owner.Prepare(p); })); await vault.started.Task.WaitAsync(TimeSpan.FromSeconds(1)); owner.Cancel(); Check(provisional is not null && !t.TryResolve(provisional.PairingId,out _)); vault.release.Set(); await RejectAsync(() => commit.WaitAsync(TimeSpan.FromSeconds(2))); await owner.DrainAsync().WaitAsync(TimeSpan.FromSeconds(2)); Check(t.Count == 0 && !t.TryResolve(provisional!.PairingId,out _)); }),
    ("pin-tls-attempt-bound-and-expiry", async () => { var clock = new Clock(); var transport = new FakeTransport(); using var t = Trust(new Vault()); await using var p = new LinuxHostPinEnrollment(t, transport, new View(),"Synthetic control",() => true,clock); await p.StartAsync("test-host", new(IPAddress.Loopback, 54322), CancellationToken.None); Check(!p.TryResolve(PeelPinPairing.TlsIdentity,out _)); p.PublicationEstablished(); Check(!p.TryResolve("not-pin", out _)); for (int i = 0; i < 8; i++) Check(p.TryResolve(PeelPinPairing.TlsIdentity, out _)); Check(!p.TryResolve(PeelPinPairing.TlsIdentity, out _)); clock.Advance(TimeSpan.FromSeconds(120)); Check(!p.TryResolve(PeelPinPairing.TlsIdentity, out _)); }),
    ("cancelled-pin-generation-cannot-restart", async () => { using var t = Trust(new Vault()); await using var p = new LinuxHostPinEnrollment(t, new FakeTransport(), new View(),"Synthetic control",() => true); p.Cancel(); await RejectAsync(() => p.StartAsync("test-host", new(IPAddress.Loopback, 54322), CancellationToken.None)); }),
    ("pin-object-no-newline-and-control-framing", async () => { using var s = new MemoryStream("{\"type\":\"pairRequest\",\"a\":\"}\\\"\"}\nNEXT\n"u8.ToArray()); byte[] first = await LinuxHostWire.ReadAsync(s, true, CancellationToken.None); using var d = LinuxHostWire.Parse(first); Check(LinuxHostWire.Type(d.RootElement) == "pairRequest"); Check(Encoding.UTF8.GetString(await LinuxHostWire.ReadAsync(s, false, CancellationToken.None)) == ""); Check(Encoding.UTF8.GetString(await LinuxHostWire.ReadAsync(s, false, CancellationToken.None)) == "NEXT"); }),
    ("duplicate-escaped-root-and-nested-keys-rejected", () => Run(() => { Reject(() => LinuxHostWire.Parse("{\"type\":\"a\",\"ty\\u0070e\":\"b\"}"u8.ToArray())); Reject(() => LinuxHostWire.Parse("{\"type\":\"a\",\"nested\":{\"a\":1,\"a\":2}}"u8.ToArray())); })),
    ("bounded-json-line", async () => { using var s = new MemoryStream(Enumerable.Repeat((byte)'x', LinuxHostWire.Limit + 1).ToArray()); await RejectAsync(() => LinuxHostWire.ReadAsync(s, false, CancellationToken.None)); }),
    ("hello-rejects-claimed-pairing-mismatch", () => Run(() => { using var d = LinuxHostWire.Parse(PeelJson.Serialize(PeelHello.CreateClient("another-peer", "test", "Linux", capabilities: LinuxHostWire.VideoCapabilities))); Reject(() => LinuxHostWire.Hello(d.RootElement, "actual-tls-peer", false)); })),
    ("hello-rejects-v1-and-missing-h264", () => Run(() => { using var d = LinuxHostWire.Parse(PeelJson.Serialize(new ClientHelloMessage(null, "test", "Linux", ProtocolVersion: 1, MinimumSupportedProtocolVersion: 1, Capabilities: []))); Reject(() => LinuxHostWire.Hello(d.RootElement, "peer", false)); })),
    ("no-video-before-control-start", () => Run(() => { using var f = new Fixture(); Reject(() => f.a.AttachVideo(f.peer, 1, new MemoryStream())); var c = f.a.AdmitControl(f.peer, new MemoryStream()); Reject(() => f.a.AttachVideo(f.peer, 1, new MemoryStream())); Check(f.a.IsCurrent(c)); })),
    ("reservation-single-use-and-idempotent-start", () => Run(() => { using var f = new Fixture(); var c = f.a.AdmitControl(f.peer, new MemoryStream()); var r = f.a.StartStream(c, 1); Check(ReferenceEquals(r, f.a.StartStream(c, 1))); Check(ReferenceEquals(r, f.a.AttachVideo(f.peer, 1, new MemoryStream()))); Reject(() => f.a.AttachVideo(f.peer, 1, new MemoryStream())); })),
    ("explicit-recovery-new-encoder-accepts-real-static-first-pts", () => Run(() => { using var f = new Fixture(); var (c,r,_) = f.Stream(); using var oldQueue = new LinuxHostVideoQueue(f.a,r); Check(oldQueue.TryEnqueue(Frame(r,100,true))); var next = f.a.StartStream(c,1); Check(next.Operation != r.Operation && !f.a.IsCurrent(r)); f.a.AttachVideo(f.peer,1,new MemoryStream()); f.a.BindEncoder(next,10,() => { }); using var q = new LinuxHostVideoQueue(f.a,next); Check(q.TryEnqueue(Frame(next,100,true))); })),
    ("wrong-peer-cannot-consume-video-reservation", () => Run(() => { using var f = new Fixture(); var c = f.a.AdmitControl(f.peer, new MemoryStream()); var r = f.a.StartStream(c, 1); var p2 = f.t.EnrollFromPin("other", "other", Key(), _ => { }); Reject(() => f.a.AttachVideo(f.t.Capture(p2.PairingId), 1, new MemoryStream())); Check(!r.Consumed); })),
    ("reservation-expires-without-rebind", () => Run(() => { using var f = new Fixture(); var c = f.a.AdmitControl(f.peer, new MemoryStream()); f.a.StartStream(c, 1); f.clock.Advance(TimeSpan.FromSeconds(5)); Reject(() => f.a.AttachVideo(f.peer, 1, new MemoryStream())); })),
    ("control-replacement-terminally-closes-old-reservation", () => Run(() => { using var f = new Fixture(); var (c, r, _) = f.Stream(); var next = f.a.AdmitControl(f.peer, new MemoryStream()); Check(!f.a.IsCurrent(c) && !f.a.IsCurrent(r) && f.a.IsCurrent(next)); })),
    ("resize-and-source-reselection-close-old-work", () => Run(() => { using var f = new Fixture(); var (_, r, _) = f.Stream(); f.a.UpdateCapture(new(7, 1, 800, 600, 0)); Check(!f.a.IsCurrent(r) && f.a.SharedCapture is null); var bootstrap = f.a.AdmitControl(f.peer,new MemoryStream()); Reject(() => f.a.StartStream(bootstrap,1)); f.a.Enable(f.a.Capture!,f.a.SourceInstance,f.clock.GetTimestamp()); var next = f.a.AdmitControl(f.peer, new MemoryStream()); f.a.StartStream(next, 1); f.a.UpdateCapture(new(8, 1, 800, 600, 0)); Check(f.a.IsCurrent(next) && f.a.SharedCapture is null); Reject(() => f.a.StartStream(next,1)); })),
    ("same-size-return-cannot-reuse-old-consent-instance", () => Run(() => { using var f = new Fixture(); var old = f.a.Capture!; var instance = f.a.SourceInstance; f.a.UpdateCapture(new(7,1,800,600,0)); f.a.UpdateCapture(old); Reject(() => f.a.Enable(old,instance,f.clock.GetTimestamp())); })),
    ("actual-revoke-denies-final-dispatch", async () => { using var f = new Fixture(); var (_, r, _) = f.Stream(); f.t.MarkDenied(f.peer.Peer.PairingId); await RejectAsync(() => f.a.Dispatch(r, new byte[] { 1 }, CancellationToken.None, launch => launch()).AsTask()); Check(!f.a.IsCurrent(r)); }),
    ("stop-closes-final-output-before-drain", async () => { using var f = new Fixture(); var (_, r, _) = f.Stream(); f.a.Stop(); await RejectAsync(() => f.a.Dispatch(r, new byte[] { 1 }, CancellationToken.None, launch => launch()).AsTask()); }),
    ("hide-closes-old-stream-and-show-cannot-revive-it", () => Run(() => { using var f = new Fixture(); var (c,r,_) = f.Stream(); f.a.SetVisibility(c,false); Check(f.a.IsCurrent(c) && !f.a.IsCurrent(r)); Reject(() => f.a.StartStream(c,1)); f.a.SetVisibility(c,true); Check(!f.a.IsCurrent(r)); var next = f.a.StartStream(c,1); Check(next.Operation != r.Operation); })),
    ("host-consent-finite-monotonic-deadline", () => Run(() => { using var f = new Fixture(); var (c, r, _) = f.Stream(); f.clock.Advance(TimeSpan.FromMinutes(30)); Check(!f.a.IsCurrent(c) && !f.a.IsCurrent(r)); })),
    ("h264-au-idr-and-length-validation", () => Run(() => { Check(LinuxHostVideoQueue.ValidateAvcc([0,0,0,2,0x65,0x80], true)); Check(!LinuxHostVideoQueue.ValidateAvcc([0,0,0,2,0x41,0x80], true)); Check(!LinuxHostVideoQueue.ValidateAvcc([0,0,1,0,0x65], true)); Check(!LinuxHostVideoQueue.ValidateAvcc([0,0,0,1,0x67], false)); })),
    ("queue-gates-initial-config-and-fresh-idr", () => Run(() => { using var f = new Fixture(); var (_, r, _) = f.Stream(); using var q = new LinuxHostVideoQueue(f.a, r); Check(!q.TryEnqueue(Frame(r, 1, false))); Check(q.TryEnqueue(Frame(r, 2, true))); Check(!q.TryEnqueue(Frame(r, 2, true))); Check(!q.TryEnqueue(Frame(r, 3, true) with { EncoderGeneration = 999 })); })),
    ("queue-overflow-drops-dependent-frames", () => Run(() => { using var f = new Fixture(); var (_, r, _) = f.Stream(); using var q = new LinuxHostVideoQueue(f.a, r); Check(q.TryEnqueue(Frame(r, 1, true))); Check(q.TryEnqueue(Frame(r, 2, false))); Check(!q.TryEnqueue(Frame(r, 3, false))); Check(!q.TryEnqueue(Frame(r, 4, false))); Check(q.TryEnqueue(Frame(r, 5, true))); })),
    ("configuration-never-rolls-back-or-mutates", () => Run(() => { using var f = new Fixture(); var (_, r, _) = f.Stream(); using var q = new LinuxHostVideoQueue(f.a, r); Check(q.TryEnqueue(Frame(r, 1, true) with { ConfigurationGeneration = 2 })); Check(!q.TryEnqueue(Frame(r, 2, true) with { ConfigurationGeneration = 1 })); Check(!q.TryEnqueue(Frame(r, 3, true) with { ConfigurationGeneration = 2, Sps = [0x67,9] })); })),
    ("stop-stream-requires-fresh-operation", () => Run(() => { using var f = new Fixture(); var (c, r, _) = f.Stream(); f.a.StopStream(c, 1); var next = f.a.StartStream(c, 1); Check(next.Operation != r.Operation && !f.a.IsCurrent(r)); })),
    ("recovery-between-config-and-frame-retires-captured-output", async () => { using var f = new Fixture(); var c = f.a.AdmitControl(f.peer,new MemoryStream()); var r = f.a.StartStream(c,1); var wire = new HeldWriteStream(); f.a.AttachVideo(f.peer,1,wire); f.a.BindEncoder(r,9,() => { }); using var q = new LinuxHostVideoQueue(f.a,r); Check(q.TryEnqueue(Frame(r,1,true))); Task writer = q.WriteAsync(CancellationToken.None); await wire.started.Task.WaitAsync(TimeSpan.FromSeconds(1)); q.Recover(); wire.release.TrySetResult(true); await RejectAsync(() => writer.WaitAsync(TimeSpan.FromSeconds(1))); var packets = new PeelBinaryPacketReader().Append(wire.ToArray()); Check(packets.Count == 1 && packets[0] is VideoConfigPacket); }),
    ("config-plus-frame-existing-wire-order", async () => { using var f = new Fixture(); var (_, r, stream) = f.Stream(); using var q = new LinuxHostVideoQueue(f.a, r); Check(q.TryEnqueue(Frame(r, 1, true))); using var cancel = new CancellationTokenSource(); Task writer = q.WriteAsync(cancel.Token); q.Close(); await writer.WaitAsync(TimeSpan.FromSeconds(1)); var packets = new PeelBinaryPacketReader().Append(stream.ToArray()); Check(packets.Count == 2 && packets[0] is VideoConfigPacket && packets[1] is VideoFramePacket); }),
}.Concat(BootstrapChecks.Cases).ToArray();
int failures = 0;
foreach (var c in cases) { try { await c.run(); Console.WriteLine("PASS " + c.name); } catch (Exception e) { failures++; Console.WriteLine("FAIL " + c.name + " " + e.GetType().Name); } }
Console.WriteLine($"{cases.Length - failures}/{cases.Length} host checks passed"); return failures == 0 ? 0 : 1;
static Task Run(Action f) { f(); return Task.CompletedTask; }
static void Check(bool valid) { if (!valid) throw new InvalidOperationException("Synthetic assertion failed."); }
static void Reject(Action f) { try { f(); } catch (Exception e) when (e is InvalidDataException or IOException or InvalidOperationException or System.Text.Json.JsonException or FormatException or OperationCanceledException) { return; } throw new Exception("Expected rejection."); }
static async Task RejectAsync(Func<Task> f) { try { await f(); } catch (Exception e) when (e is InvalidDataException or IOException or InvalidOperationException or System.Text.Json.JsonException or FormatException or OperationCanceledException) { return; } throw new Exception("Expected rejection."); }
static byte[] Key() => Enumerable.Range(1, 32).Select(i => (byte)i).ToArray();
static LinuxHostTrust Trust(Vault vault, Action<IReadOnlyList<LinuxHostPeer>>? persist = null) => new("11111111-1111-4111-8111-111111111111", vault, [], persist ?? (_ => { }));
static LinuxHostPeer Enroll(LinuxHostTrust t) => t.EnrollFromPin("test-client", "Synthetic client", Key(), _ => { });
static LinuxHostEncoded Frame(LinuxHostReservation r, long pts, bool idr) => new(r.Capture.Generation, r.Encoder, 1, 1, r.Capture.Width, r.Capture.Height, 1_000_000_000, pts, 1, idr, [0,0,0,2,idr ? (byte)0x65 : (byte)0x41,0x80], [0x67,0x42], [0x68,0x80]);
sealed class Vault : ILinuxHostSecretVault
{
    internal readonly Dictionary<string,string> rows = []; internal bool failWrite;
    public string? Read(string key) => rows.GetValueOrDefault(key);
    public void Write(string key, string value) { if (failWrite) throw new IOException(); rows[key] = value; }
}
sealed class Clock : TimeProvider
{
    private long ticks; public override long TimestampFrequency => 1000;
    public override long GetTimestamp() => ticks;
    public override DateTimeOffset GetUtcNow() => DateTimeOffset.UnixEpoch.AddSeconds(1_800_000_000).AddMilliseconds(ticks);
    internal void Advance(TimeSpan span) => ticks += (long)span.TotalMilliseconds;
}
sealed class View : ILinuxHostConsentView
{
    internal bool show = true; internal LinuxHostPinPresentation? presentation;
    public Task<bool> ShowPairingAsync(LinuxHostPinPresentation p, Action cancel, CancellationToken token) { presentation = p; return Task.FromResult(show); }
    public Task<bool> ConfirmNetworkHostAsync(LinuxHostNetworkPresentation p, Action stop, CancellationToken token) => Task.FromResult(show);
    public void PairingClosed(Guid generation) { }
}
sealed class FakeTransport : IPeelPskTransportFactory
{
    internal int listens;
    public ValueTask<Stream> ConnectAsync(DnsEndPoint endpoint, PeelPskCredential credential, CancellationToken token = default) => throw new NotSupportedException();
    public ValueTask<IPeelPskListener> ListenAsync(IPEndPoint endpoint, IPeelPskCredentialResolver resolver, CancellationToken token = default) { listens++; return ValueTask.FromResult<IPeelPskListener>(new FakeListener()); }
}
sealed class FakeListener : IPeelPskListener
{
    public EndPoint LocalEndPoint => new IPEndPoint(IPAddress.Loopback, 54322);
    public async ValueTask<PeelPskConnection> AcceptAsync(CancellationToken token = default) { await Task.Delay(Timeout.InfiniteTimeSpan, token); throw new OperationCanceledException(); }
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}
sealed class Fixture : IDisposable
{
    internal readonly Clock clock = new(); internal readonly LinuxHostTrust t; internal readonly LinuxHostPeerLease peer; internal readonly LinuxHostAuthority a;
    internal Fixture() { t = new("11111111-1111-4111-8111-111111111111", new Vault(), [], _ => { }); var p = t.EnrollFromPin("test-client", "Synthetic client", Enumerable.Range(1,32).Select(i => (byte)i).ToArray(), _ => { }); peer = t.Capture(p.PairingId); a = new(clock); a.EnableControl(clock.GetTimestamp()); a.UpdateCapture(new(7,1,640,480,0)); a.Enable(a.Capture!,a.SourceInstance,clock.GetTimestamp()); t.PeerRevoked += a.Revoke; }
    internal (LinuxHostControl c, LinuxHostReservation r, MemoryStream stream) Stream() { var c = a.AdmitControl(peer, new MemoryStream()); var r = a.StartStream(c,1); var s = new MemoryStream(); a.AttachVideo(peer,1,s); a.BindEncoder(r,9,() => { }); return (c,r,s); }
    public void Dispose() { a.Stop(); t.Dispose(); }
}

sealed class PairTransport(View view, bool badProof) : IPeelPskTransportFactory
{
    internal MemoryStream? wire; internal int requestLength;
    internal readonly TaskCompletionSource<bool> finished = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public ValueTask<Stream> ConnectAsync(DnsEndPoint endpoint, PeelPskCredential credential, CancellationToken token = default) => throw new NotSupportedException();
    private readonly TaskCompletionSource<bool> admission = new(TaskCreationOptions.RunContinuationsAsynchronously);
    internal void OpenAdmission() => admission.TrySetResult(true);
    public ValueTask<IPeelPskListener> ListenAsync(IPEndPoint endpoint, IPeelPskCredentialResolver resolver, CancellationToken token = default)
    {
        // No TLS credential is resolved during bind. The fake handshake occurs
        // only after explicit matching publication readiness, like actual TLS.
        async Task<Stream> Handshake(CancellationToken acceptToken)
        {
            await admission.Task.WaitAsync(acceptToken);
            var p = view.presentation ?? throw new Exception();
            if (!resolver.TryResolve(PeelPinPairing.TlsIdentity,out var credential)) throw new IOException("Unpublished PIN cannot authenticate.");
            string proof = PeelPinPairing.CreateProof(credential!.PreSharedKey,p.HostId,badProof ? "wrong-device" : "test-client");
            byte[] request=PeelJson.Serialize(new PairRequestMessage("Synthetic client","test-client",proof));
            wire=new TrackingStream(finished); wire.Write(request); wire.Position=0; requestLength=request.Length; return wire;
        }
        return ValueTask.FromResult<IPeelPskListener>(new PairListener(Handshake));
    }
}
sealed class PairListener(Func<CancellationToken,Task<Stream>> handshake) : IPeelPskListener
{
    private bool sent;
    public EndPoint LocalEndPoint => new IPEndPoint(IPAddress.Loopback,54322);
    public async ValueTask<PeelPskConnection> AcceptAsync(CancellationToken token = default)
    { if (!sent) { sent = true; return new(await handshake(token),PeelPinPairing.TlsIdentity); } await Task.Delay(Timeout.InfiniteTimeSpan,token); throw new OperationCanceledException(); }
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}

sealed class TrackingStream(TaskCompletionSource<bool> finished) : MemoryStream
{
    public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken token = default)
    { var result = base.WriteAsync(buffer,token); finished.TrySetResult(true); return result; }
    protected override void Dispose(bool disposing) { if (disposing) finished.TrySetResult(true); base.Dispose(disposing); }
}

sealed class HeldWriteStream : MemoryStream
{
    internal readonly TaskCompletionSource<bool> started = new(TaskCreationOptions.RunContinuationsAsynchronously);
    internal readonly TaskCompletionSource<bool> release = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken token = default) => new(WriteHeldAsync(buffer,token));
    private async Task WriteHeldAsync(ReadOnlyMemory<byte> buffer, CancellationToken token)
    { started.TrySetResult(true); await release.Task.WaitAsync(token); await base.WriteAsync(buffer,token); }
}

sealed class CountedWriteStream : MemoryStream
{
    internal int launches; internal bool fail;
    public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken token = default)
    { launches++; if (fail) throw new IOException("Synthetic write failure."); return base.WriteAsync(buffer,token); }
}
sealed class HeldVault : ILinuxHostSecretVault
{
    private readonly System.Collections.Concurrent.ConcurrentDictionary<string,string> rows = new();
    private int writes;
    internal readonly TaskCompletionSource<bool> started = new(TaskCreationOptions.RunContinuationsAsynchronously);
    internal readonly ManualResetEventSlim release = new(false);
    public string? Read(string key) => rows.GetValueOrDefault(key);
    public void Write(string key, string value)
    {
        if (Interlocked.Increment(ref writes) == 1) { started.TrySetResult(true); if (!release.Wait(TimeSpan.FromSeconds(2))) throw new IOException("Synthetic hold expired."); }
        rows[key] = value;
    }
}
