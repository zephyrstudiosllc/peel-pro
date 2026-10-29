using System.Buffers.Binary;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Peel.Linux;
using Peel.Windows.Client.Models;
using Peel.Windows.Client.Services;
using Peel.Windows.Protocol;

/// <summary>Pure managed receiver audio/source-media checks with fakes only: no native library,
/// GTK, GStreamer, socket, Secret Service or real source. They prove wire shapes, validation,
/// fences, bookkeeping and lifecycle decisions; not audible playback, latency or any device.</summary>
internal static class ReceiverMediaChecks
{
    private const string Pairing = "pair-1", Host = "host-1";

    internal static async Task<int> RunAsync()
    {
        var cases = new (string Name, Func<Task> Run)[]
        {
            ("PEAU-mirror-round-trip-and-bounds", Sync(PeauMirror)),
            ("PEAU-reader-rejects-PCM-before-format", PeauReaderOrder),
            ("audio-timeline-reset-and-format-validation", Sync(Timeline)),
            ("audio-proof-domain-and-payload", Sync(Proof)),
            ("source-media-wire-shapes", Sync(WireShapes)),
            ("source-media-reply-validation", Sync(ReplyValidation)),
            ("media-unavailable-sends-nothing", MediaUnavailable),
            ("media-ack-matches-request-pairing-window-generation", MediaAckMatching),
            ("media-timeout-then-late-reply-ignored", MediaTimeout),
            ("media-at-most-8-pending", MediaPendingLimit),
            ("volume-scope-pending-sends-nothing", VolumeScopePending),
            ("stale-epoch-send-cancelled-in-writer-wait", StaleSendCancelled),
            ("stale-epoch-write-refused-by-owner-check", StaleWriteRefused),
            ("late-old-set-failure-cannot-release-fresh-owner", LateSetFailureKeepsOwner),
            ("volume-actual-state-only-monotonic-coalesced", VolumeActualState),
            ("preferences-per-pair-off-persists-hashed", Sync(Preferences)),
            ("preferences-unreadable-suppresses-auto-listen", Sync(PreferencesUnreadable)),
            ("audio-owner-attaches-plays-and-ends", AudioOwnerPlays),
            ("audio-owner-honest-no-output", AudioOwnerNoOutput),
            ("audio-owner-stops-on-source-stop-and-disconnect", AudioOwnerSourceStop),
            ("controls-default-listen-explicit-off-on-and-lifecycle", ControlsLifecycle),
            ("controls-read-actual-source-volume-when-current", ControlsVolumeQuery),
            ("controls-queued-click-stale-after-same-window-reopen", ControlsStaleQueuedClick),
        };
        int failures = 0;
        foreach (var (name, run) in cases)
        {
            try { await run().WaitAsync(TimeSpan.FromSeconds(8)); Console.WriteLine("PASS " + name); }
            catch (Exception error) { failures++; Console.WriteLine("FAIL " + name + " " + error.GetType().Name + ": " + error.Message); }
        }
        Console.WriteLine($"{cases.Length - failures}/{cases.Length} receiver media checks passed. Fakes only; no native playback, GUI, socket or source device is proved.");
        return failures;
    }

    private static Func<Task> Sync(Action action) => () => { action(); return Task.CompletedTask; };
    private static void Check(bool value, string what) { if (!value) throw new Exception(what); }
    private static void Rejects<T>(Action action, string what) where T : Exception
    {
        try { action(); } catch (T) { return; }
        throw new Exception("Accepted: " + what);
    }
    private static async Task Eventually(Func<bool> condition, string what)
    {
        for (int i = 0; i < 300; i++) { if (condition()) return; await Task.Delay(10); }
        throw new Exception("Timed out waiting for " + what);
    }
    private static byte[] Pcm(ulong sequence) => new AudioPacket(1, 0, sequence, (long)sequence * AudioPacket.Frames, new byte[3840]).Encode();
    private static byte[] Format() => new AudioPacket(0, 0, 0, 0, []).Encode();
    private static string Id() => Guid.NewGuid().ToString("D").ToUpperInvariant();

    private static void PeauMirror()
    {
        var packet = Pcm(3);
        Check(packet.Length == AudioPacket.HeaderBytes + 3840 && Encoding.ASCII.GetString(packet, 0, 4) == "PEAU", "PEAU header");
        Check(AudioPacket.ValidateHeader(packet.AsSpan(0, AudioPacket.HeaderBytes), 0) == 3840, "stereo payload size");
        Rejects<InvalidDataException>(() => AudioPacket.ValidateHeader(packet.AsSpan(0, AudioPacket.HeaderBytes), 1), "uplink direction for playback");
        var wrongRate = packet[..AudioPacket.HeaderBytes]; BinaryPrimitives.WriteUInt32BigEndian(wrongRate.AsSpan(28), 44100);
        Rejects<InvalidDataException>(() => AudioPacket.ValidateHeader(wrongRate, 0), "44.1 kHz");
        var oversized = packet[..AudioPacket.HeaderBytes]; BinaryPrimitives.WriteUInt32BigEndian(oversized.AsSpan(8), 1 << 20);
        Rejects<InvalidDataException>(() => AudioPacket.ValidateHeader(oversized, 0), "oversized length before allocation");
        Rejects<InvalidDataException>(() => new AudioPacket(1, 0, 0, 0, new byte[1920]).Validate(), "mono payload on stereo downlink");
    }

    private static async Task PeauReaderOrder()
    {
        var reader = new AudioPacketReader(0);
        try { await reader.ReadAsync(new MemoryStream(Pcm(0)), CancellationToken.None); }
        catch (InvalidDataException) { return; }
        throw new Exception("PCM before format accepted.");
    }

    private static void Timeline()
    {
        var timeline = new PeelAudioTimeline();
        Check(timeline.Admit(new AudioPacket(0, 0, 0, 0, [])) == PeelAudioTimeline.Result.Format, "format");
        Check(timeline.Admit(new AudioPacket(1, 0, 1, 960, new byte[3840])) == PeelAudioTimeline.Result.Continue, "first");
        Check(timeline.Admit(new AudioPacket(1, 0, 5, 4800, new byte[3840])) == PeelAudioTimeline.Result.Continue, "forward gap is not a reset");
        Check(timeline.Admit(new AudioPacket(1, 0, 5, 5760, new byte[3840])) == PeelAudioTimeline.Result.Reset, "repeated sequence");
        Check(timeline.Admit(new AudioPacket(1, 0, 6, 0, new byte[3840])) == PeelAudioTimeline.Result.Reset, "sample time regression");
        Check(timeline.Admit(new AudioPacket(0, 0, 0, 0, [])) == PeelAudioTimeline.Result.Format, "re-announced format");
        Check(timeline.Admit(new AudioPacket(1, 0, 1, 0, new byte[3840])) == PeelAudioTimeline.Result.Continue, "timeline restarts after format");
        Rejects<InvalidDataException>(() => timeline.Admit(new AudioPacket(1, 0, 9, 9000, new byte[1920])), "short payload");
        Rejects<InvalidDataException>(() => timeline.Admit(new AudioPacket(1, 1, 10, 9960, new byte[1920])), "microphone direction");
        Rejects<InvalidDataException>(() => timeline.Admit(new AudioPacket(1, 0, 11, long.MaxValue - 10, new byte[3840])), "sample time overflow");
    }

    private static void Proof()
    {
        byte[] key = Enumerable.Range(1, 32).Select(i => (byte)i).ToArray(), nonce = Enumerable.Range(100, 32).Select(i => (byte)i).ToArray();
        string request = "6f1c2b0e-6a43-4d57-9c3b-2e8a1f4d9b70";
        var challenge = new AudioPairingChallengeMessage(request, Pairing, Convert.ToBase64String(nonce), 1_800_000_000.5, "playback");
        using var payload = new MemoryStream();
        payload.Write(Encoding.UTF8.GetBytes("peel.audio-pairing-proof.v1\0"));
        payload.Write(Encoding.UTF8.GetBytes(request.ToUpperInvariant())); payload.WriteByte(0);
        payload.Write(Encoding.UTF8.GetBytes(Pairing)); payload.WriteByte(0); payload.Write(nonce);
        var expiry = new byte[8]; BinaryPrimitives.WriteInt64BigEndian(expiry, BitConverter.DoubleToInt64Bits(1_800_000_000.5)); payload.Write(expiry);
        string expected = Convert.ToBase64String(HMACSHA256.HashData(key, payload.ToArray()));
        Check(AudioPairingProof.Make(challenge, key) == expected, "playback proof matches documented payload");
        Check(AudioPairingProof.Make(challenge with { Mode = null }, key) == expected, "missing mode is playback");
        Check(AudioPairingProof.Make(challenge with { Mode = "voice" }, key) != expected, "voice uses a separate domain");
        Rejects<InvalidDataException>(() => AudioPairingProof.Make(challenge with { Mode = "record" }, key), "unknown mode");
        Rejects<InvalidDataException>(() => AudioPairingProof.Make(challenge, new byte[16]), "short key");
        string hello = PeelJson.SerializeString(new AudioStreamHelloMessage(request, Pairing, "dGlja2V0"));
        using var document = JsonDocument.Parse(hello);
        Check(document.RootElement.GetProperty("type").GetString() == "audioStreamHello" && document.RootElement.GetProperty("version").GetInt32() == 1, "hello shape");
        Check(new AudioAuthorization(request, Pairing, "dGlja2V0", Host, 3).ToString() == "AudioAuthorization { Generation = 3 }", "authorization never prints its ticket");
    }

    private static void WireShapes()
    {
        var id = Guid.Parse("6F1C2B0E-6A43-4D57-9C3B-2E8A1F4D9B70");
        using (var command = JsonDocument.Parse(PeelJson.SerializeString(SourceMediaCommandMessage.Create(id, "example-pairing-id", 42, SourceMediaAction.NextTrack))))
        {
            var root = command.RootElement;
            Check(root.EnumerateObject().Select(p => p.Name).Order(StringComparer.Ordinal).SequenceEqual(new[] { "action", "pairingId", "requestId", "type", "version", "windowId" }), "command fields");
            Check(root.GetProperty("type").GetString() == "sourceMediaCommand" && root.GetProperty("version").GetInt32() == 1 && root.GetProperty("windowId").GetUInt32() == 42 &&
                  root.GetProperty("requestId").GetString() == "6F1C2B0E-6A43-4D57-9C3B-2E8A1F4D9B70" && root.GetProperty("action").GetString() == "nextTrack", "command values");
        }
        using (var set = JsonDocument.Parse(PeelJson.SerializeString(SourceVolumeSetMessage.Create(id, "example-pairing-id", 42, SourceVolumeScope.PeelStream, 0.5, null))))
            Check(set.RootElement.GetProperty("scope").GetString() == "peelStream" && set.RootElement.GetProperty("volume").GetDouble() == 0.5 && !set.RootElement.TryGetProperty("muted", out _), "set omits unset mute");
        using (var query = JsonDocument.Parse(PeelJson.SerializeString(SourceVolumeQueryMessage.Create(id, "example-pairing-id", 42, SourceVolumeScope.SystemOutput))))
            Check(query.RootElement.GetProperty("type").GetString() == "sourceVolumeQuery" && query.RootElement.GetProperty("scope").GetString() == "systemOutput", "query shape");
        string valid = "6F1C2B0E-6A43-4D57-9C3B-2E8A1F4D9B70";
        Check(new SourceMediaCommandMessage(valid, "p", 42, "playPause", 1, "sourceMediaCommand").Check().IsValid, "valid command");
        Check(new SourceMediaCommandMessage("not-a-uuid", "p", 42, "playPause", 1, "sourceMediaCommand").Check().RefusalStatus == SourceMediaStatus.Invalid, "bad request ID");
        Check(new SourceMediaCommandMessage(valid, "p\0q", 42, "playPause", 1, "sourceMediaCommand").Check().RefusalStatus == SourceMediaStatus.Invalid, "NUL pairing");
        Check(new SourceMediaCommandMessage(valid, new string('x', 257), 42, "playPause", 1, "sourceMediaCommand").Check().RefusalStatus == SourceMediaStatus.Invalid, "257-byte pairing");
        Check(new SourceMediaCommandMessage(valid, "p", 42, "space", 1, "sourceMediaCommand").Check().RefusalStatus == SourceMediaStatus.Unsupported, "non-media action refused");
        Rejects<ArgumentException>(() => SourceVolumeSetMessage.Create(id, "p", 42, SourceVolumeScope.PeelStream, null, null), "set without values");
        Rejects<ArgumentOutOfRangeException>(() => SourceVolumeSetMessage.Create(id, "p", 42, SourceVolumeScope.PeelStream, 1.5, null), "volume above 1 is not clamped");
        Rejects<ArgumentOutOfRangeException>(() => SourceVolumeSetMessage.Create(id, "p", 42, SourceVolumeScope.PeelStream, double.NaN, null), "NaN volume");
        Check(new SourceVolumeQueryMessage(valid, "p", 42, "receiverOutput", 1, "sourceVolumeQuery").Check().RefusalReason == SourceMediaReason.ScopeUnsupported, "unknown scope");
    }

    private static void ReplyValidation()
    {
        const string head = "\"version\":1,\"requestId\":\"6F1C2B0E-6A43-4D57-9C3B-2E8A1F4D9B70\",\"pairingId\":\"example-pairing-id\",\"windowId\":42";
        static SourceMediaAckMessage ParseAck(string json) => PeelJson.Deserialize<SourceMediaAckMessage>(Encoding.UTF8.GetBytes(json));
        static SourceVolumeStateMessage ParseState(string json) => PeelJson.Deserialize<SourceVolumeStateMessage>(Encoding.UTF8.GetBytes(json));
        Check(ParseAck("{\"type\":\"sourceMediaAck\"," + head + ",\"status\":\"applied\"}").TryParse(out var status, out var reason) && status == SourceMediaStatus.Applied && reason is null, "applied");
        Check(ParseAck("{\"type\":\"sourceMediaAck\"," + head + ",\"status\":\"denied\",\"reason\":\"futureCode\"}").TryParse(out status, out reason) && status == SourceMediaStatus.Denied && reason is null, "unknown bounded reason reads as null");
        Check(!ParseAck("{\"type\":\"sourceMediaAck\"," + head + ",\"status\":\"maybe\"}").TryParse(out _, out _), "unknown status");
        Check(!ParseAck("{\"type\":\"sourceMediaAck\"," + head.Replace("\"version\":1", "\"version\":2") + ",\"status\":\"applied\"}").TryParse(out _, out _), "version 2");
        Rejects<JsonException>(() => ParseAck("{\"type\":\"sourceMediaAck\"," + head.Replace(":42", ":4294967296") + ",\"status\":\"applied\"}"), "windowId overflow");
        Check(ParseState("{\"type\":\"sourceVolumeState\"," + head + ",\"scope\":\"systemOutput\",\"supported\":false,\"canSetVolume\":false,\"canSetMute\":false,\"sequence\":1,\"reason\":\"scopeUnsupported\"}").IsValid, "unsupported state");
        Check(!ParseState("{\"type\":\"sourceVolumeState\"," + head + ",\"scope\":\"systemOutput\",\"supported\":false,\"canSetVolume\":false,\"canSetMute\":false,\"volume\":0.5,\"sequence\":1}").IsValid, "unsupported with a value");
        Check(!ParseState("{\"type\":\"sourceVolumeState\"," + head + ",\"scope\":\"systemOutput\",\"supported\":true,\"canSetVolume\":true,\"canSetMute\":true,\"volume\":1.5,\"sequence\":1}").IsValid, "volume above 1");
        Rejects<JsonException>(() => ParseState("{\"type\":\"sourceVolumeState\"," + head + ",\"scope\":\"systemOutput\",\"supported\":true,\"canSetVolume\":true,\"canSetMute\":true,\"volume\":NaN,\"sequence\":1}"), "NaN literal");
    }

    private sealed class FakeChannel : ISourceMediaChannel
    {
        internal readonly HashSet<string> Capabilities = new(StringComparer.Ordinal);
        internal readonly List<string> Sent = [];
        internal long Generation = 9;
        public bool HostSupports(string capability) => Capabilities.Contains(capability);
        public event EventHandler<SourceMediaReplyEventArgs>? SourceMediaReplyReceived;
        internal void Reply(string type, string json, long? generation = null) =>
            SourceMediaReplyReceived?.Invoke(this, new(type, Encoding.UTF8.GetBytes(json), generation ?? Generation));
        private readonly Queue<(TaskCompletionSource<bool> Gate, bool IgnoresCancellation)> gates = new();
        internal int Entered;
        /// <summary>Blocks the next send in the fake writer wait until released: true writes,
        /// false fails with IOException. A cancellation-ignoring gate models a write already
        /// past the wait whose failure arrives late.</summary>
        internal TaskCompletionSource<bool> HoldNext(bool ignoresCancellation = false)
        {
            var gate = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            lock (gates) gates.Enqueue((gate, ignoresCancellation));
            return gate;
        }
        // Mirrors ClientSession: generation check, cancellable writer wait, then the owner check, then the write.
        public async Task SendSourceMediaAsync<T>(T message, long generation, Func<bool> stillOwned, CancellationToken token)
        {
            if (generation != Generation) throw new OperationCanceledException("stale");
            Interlocked.Increment(ref Entered);
            (TaskCompletionSource<bool> Gate, bool IgnoresCancellation)? held;
            lock (gates) held = gates.Count > 0 ? gates.Dequeue() : null;
            if (held is { } next && !(next.IgnoresCancellation ? await next.Gate.Task : await next.Gate.Task.WaitAsync(token)))
                throw new IOException("synthetic write failure");
            if (held is not { IgnoresCancellation: true }) token.ThrowIfCancellationRequested();
            if (!stillOwned()) throw new OperationCanceledException("owner changed before write");
            lock (Sent) Sent.Add(PeelJson.SerializeString(message));
        }
        internal JsonElement Last { get { lock (Sent) return JsonDocument.Parse(Sent[^1]).RootElement.Clone(); } }
        internal int Count { get { lock (Sent) return Sent.Count; } }
    }

    private static string Ack(JsonElement request, string status, string? reason = null, string? pairing = null, uint? window = null) =>
        JsonSerializer.Serialize(new Dictionary<string, object?>
        {
            ["type"] = "sourceMediaAck", ["version"] = 1, ["requestId"] = request.GetProperty("requestId").GetString(),
            ["pairingId"] = pairing ?? Pairing, ["windowId"] = window ?? request.GetProperty("windowId").GetUInt32(), ["status"] = status, ["reason"] = reason,
        });

    private static string State(JsonElement? request, uint window, ulong sequence, double? volume, bool? muted, string scope = "systemOutput") =>
        JsonSerializer.Serialize(new Dictionary<string, object?>
        {
            ["type"] = "sourceVolumeState", ["version"] = 1, ["requestId"] = request?.GetProperty("requestId").GetString(), ["pairingId"] = Pairing,
            ["windowId"] = window, ["scope"] = scope, ["supported"] = true, ["canSetVolume"] = true, ["canSetMute"] = true,
            ["volume"] = volume, ["muted"] = muted, ["sequence"] = sequence,
        });

    private static async Task MediaUnavailable()
    {
        var channel = new FakeChannel();
        using var client = new LinuxSourceMediaClient(channel, 9, Pairing, null);
        ulong epoch = client.BeginStream(42);
        Check(!await client.SendMediaAsync(42, epoch, SourceMediaAction.PlayPause) && channel.Count == 0, "no media keys capability, nothing sent");
        Check(client.Note is not null, "honest unavailable note");
    }

    private static async Task MediaAckMatching()
    {
        var channel = new FakeChannel(); channel.Capabilities.Add(SourceMediaProtocol.MediaKeysCapability);
        using var client = new LinuxSourceMediaClient(channel, 9, Pairing, null);
        ulong epoch = client.BeginStream(42);
        Check(!await client.SendMediaAsync(43, epoch, SourceMediaAction.NextTrack) && !await client.SendMediaAsync(42, epoch + 1, SourceMediaAction.NextTrack) && channel.Count == 0,
            "a window or epoch that is not the current stream sends nothing");
        Check(await client.SendMediaAsync(42, epoch, SourceMediaAction.NextTrack), "sent");
        var sent = channel.Last;
        Check(sent.GetProperty("type").GetString() == "sourceMediaCommand" && sent.GetProperty("action").GetString() == "nextTrack" &&
              sent.GetProperty("pairingId").GetString() == Pairing && sent.GetProperty("windowId").GetUInt32() == 42 &&
              SourceMediaProtocol.IsRequestId(sent.GetProperty("requestId").GetString()), "captured pairing/window/request");
        channel.Reply(SourceMediaProtocol.AckType, Ack(sent, "applied", pairing: "other-pair"));
        channel.Reply(SourceMediaProtocol.AckType, Ack(sent, "applied", window: 43));
        channel.Reply(SourceMediaProtocol.AckType, Ack(sent, "applied"), generation: 8);
        Check(client.PendingCount == 1, "wrong pairing, window and generation are ignored");
        channel.Reply(SourceMediaProtocol.AckType, Ack(sent, "applied"));
        Check(client.PendingCount == 0 && client.Note == "Next track sent to the source computer.", "exact ack completes");
        Check(await client.SendMediaAsync(42, epoch, SourceMediaAction.PlayPause), "second");
        channel.Reply(SourceMediaProtocol.AckType, Ack(channel.Last, "denied", "accessibilityMissing"));
        Check(client.Note == "The source computer hasn't allowed Peel to send media keys.", "refusal reason shown");
        channel.Generation = 10;
        Check(!await client.SendMediaAsync(42, epoch, SourceMediaAction.PlayPause) && client.PendingCount == 0, "stale control generation is not sent");
    }

    private static async Task MediaTimeout()
    {
        var channel = new FakeChannel(); channel.Capabilities.Add(SourceMediaProtocol.MediaKeysCapability);
        using var client = new LinuxSourceMediaClient(channel, 9, Pairing, null, TimeSpan.FromMilliseconds(100));
        ulong epoch = client.BeginStream(42);
        await client.SendMediaAsync(42, epoch, SourceMediaAction.PreviousTrack);
        var sent = channel.Last;
        await Eventually(() => client.PendingCount == 0, "timeout");
        Check(client.Note == "The source computer didn't answer.", "timeout note");
        channel.Reply(SourceMediaProtocol.AckType, Ack(sent, "applied"));
        Check(client.Note == "The source computer didn't answer.", "late ack ignored");
    }

    private static async Task MediaPendingLimit()
    {
        var channel = new FakeChannel(); channel.Capabilities.Add(SourceMediaProtocol.MediaKeysCapability);
        using var client = new LinuxSourceMediaClient(channel, 9, Pairing, null);
        ulong epoch = client.BeginStream(42);
        for (int i = 0; i < 8; i++) Check(await client.SendMediaAsync(42, epoch, SourceMediaAction.PlayPause), "within limit");
        Check(!await client.SendMediaAsync(42, epoch, SourceMediaAction.PlayPause) && channel.Count == 8 && client.PendingCount == 8, "ninth refused locally");
        epoch = client.BeginStream(42); // close and reopen the same window ID
        Check(client.PendingCount == 0 && await client.SendMediaAsync(42, epoch, SourceMediaAction.PlayPause), "stream change clears pending");
    }

    private static async Task VolumeScopePending()
    {
        Check(LinuxSourceVolumeScope.Selected == SourceVolumeScope.SystemOutput, "root-stated default scope is the source's system output");
        var channel = new FakeChannel(); channel.Capabilities.Add(SourceMediaProtocol.VolumeCapability);
        using var disabled = new LinuxSourceMediaClient(channel, 9, Pairing, null);
        ulong epoch = disabled.BeginStream(42);
        Check(!await disabled.QueryVolumeAsync(42, epoch), "no query without a scope");
        await disabled.SetVolumeAsync(42, epoch, 0.5, null);
        Check(channel.Count == 0 && disabled.Volume == SourceVolumeView.Unsupported, "no set and no local fallback");
        using var scoped = new LinuxSourceMediaClient(new FakeChannel(), 9, Pairing, SourceVolumeScope.SystemOutput);
        Check(!await scoped.QueryVolumeAsync(42, scoped.BeginStream(42)) && scoped.Volume == SourceVolumeView.Unsupported, "a chosen scope still requires source-volume-v1");
    }

    private static async Task StaleSendCancelled()
    {
        var channel = new FakeChannel(); channel.Capabilities.Add(SourceMediaProtocol.MediaKeysCapability);
        using var client = new LinuxSourceMediaClient(channel, 9, Pairing, null);
        ulong epoch = client.BeginStream(42);
        var gate = channel.HoldNext();
        var old = client.SendMediaAsync(42, epoch, SourceMediaAction.PlayPause);
        await Eventually(() => channel.Entered == 1, "old send waiting for the writer");
        client.EndStream(); // viewer closed
        Check(!await old.WaitAsync(TimeSpan.FromSeconds(2)) && channel.Count == 0 && client.PendingCount == 0, "stream end cancels the queued send; nothing is written");
        gate.TrySetResult(true);
        epoch = client.BeginStream(42);
        Check(await client.SendMediaAsync(42, epoch, SourceMediaAction.PlayPause) && channel.Count == 1, "the reopened stream sends normally");
    }

    private static async Task StaleWriteRefused()
    {
        var channel = new FakeChannel(); channel.Capabilities.Add(SourceMediaProtocol.MediaKeysCapability);
        using var client = new LinuxSourceMediaClient(channel, 9, Pairing, null);
        ulong epoch = client.BeginStream(42);
        var gate = channel.HoldNext(ignoresCancellation: true);
        var old = client.SendMediaAsync(42, epoch, SourceMediaAction.NextTrack);
        await Eventually(() => channel.Entered == 1, "old send past cancellation");
        client.BeginStream(42); // close and reopen the same window ID while the old write is pending
        gate.TrySetResult(true);
        Check(!await old.WaitAsync(TimeSpan.FromSeconds(2)) && channel.Count == 0, "write-time owner check refuses the old epoch's bytes");
    }

    private static async Task LateSetFailureKeepsOwner()
    {
        var channel = new FakeChannel(); channel.Capabilities.Add(SourceMediaProtocol.VolumeCapability);
        using var client = new LinuxSourceMediaClient(channel, 9, Pairing, SourceVolumeScope.SystemOutput);
        ulong first = client.BeginStream(42);
        var oldGate = channel.HoldNext(ignoresCancellation: true);
        var oldSet = client.SetVolumeAsync(42, first, 0.5, null);
        await Eventually(() => channel.Entered == 1, "old set held");
        ulong second = client.BeginStream(42); // CancelPending equivalent: same window ID, new stream
        var freshGate = channel.HoldNext();
        var freshSet = client.SetVolumeAsync(42, second, 0.7, null);
        await Eventually(() => channel.Entered == 2, "fresh set held");
        oldGate.TrySetResult(false); // the old send now fails late
        await oldSet.WaitAsync(TimeSpan.FromSeconds(2));
        await client.SetVolumeAsync(42, second, 0.9, null);
        Check(channel.Entered == 2 && client.PendingCount == 1, "old failure did not release the fresh owner; no concurrent second set");
        freshGate.TrySetResult(true);
        await freshSet.WaitAsync(TimeSpan.FromSeconds(2));
        var fresh = channel.Last;
        Check(channel.Count == 1 && fresh.GetProperty("volume").GetDouble() == 0.7, "only the fresh set was written");
        channel.Reply(SourceMediaProtocol.VolumeStateType, State(fresh, 42, 3, 0.7, false));
        await Eventually(() => channel.Count == 2, "owner's answer pumps the coalesced value");
        Check(channel.Last.GetProperty("volume").GetDouble() == 0.9 && client.Volume.Volume == 0.7, "latest value follows; state stays actual");
    }

    private static async Task VolumeActualState()
    {
        var channel = new FakeChannel(); channel.Capabilities.Add(SourceMediaProtocol.VolumeCapability);
        using var client = new LinuxSourceMediaClient(channel, 9, Pairing, SourceVolumeScope.SystemOutput);
        ulong epoch = client.BeginStream(42);
        Check(await client.QueryVolumeAsync(42, epoch), "query sent");
        var query = channel.Last;
        channel.Reply(SourceMediaProtocol.VolumeStateType, State(query, 42, 5, 0.4, false));
        Check(client.Volume.Supported && client.Volume.Volume == 0.4 && client.Volume.Muted == false, "actual state applied");
        await client.SetVolumeAsync(42, epoch, 0.7, null);
        var set = channel.Last;
        Check(set.GetProperty("type").GetString() == "sourceVolumeSet" && set.GetProperty("volume").GetDouble() == 0.7 && !set.TryGetProperty("muted", out _), "set shape");
        Check(client.Volume.Volume == 0.4, "no optimistic volume");
        await client.SetVolumeAsync(42, epoch, 0.8, null);
        await client.SetVolumeAsync(42, epoch, null, true);
        Check(channel.Count == 2, "one set in flight; later values coalesce");
        channel.Reply(SourceMediaProtocol.VolumeStateType, State(set, 42, 4, 0.1, false));
        Check(client.Volume.Volume == 0.4, "older sequence never overwrites newer state");
        await Eventually(() => channel.Count == 3, "coalesced set after the first answer");
        var coalesced = channel.Last;
        Check(coalesced.GetProperty("volume").GetDouble() == 0.8 && coalesced.GetProperty("muted").GetBoolean(), "latest volume and mute coalesced");
        channel.Reply(SourceMediaProtocol.VolumeStateType, State(coalesced, 42, 6, 0.75, true));
        Check(client.Volume.Volume == 0.75 && client.Volume.Muted == true, "source's actual answer, not the requested 0.8");
        await client.SetVolumeAsync(42, epoch, 1.5, null);
        Check(channel.Count == 3, "invalid volume never sent or clamped");
        channel.Reply(SourceMediaProtocol.VolumeStateType, State(null, 42, 7, 0.2, false, "peelStream"));
        Check(client.Volume.Volume == 0.75, "other scope ignored");
    }

    private static string TemporaryPath()
    {
        string folder = Path.Combine(Path.GetTempPath(), "peel-receiver-checks-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder); return Path.Combine(folder, "preferences.json");
    }

    private static void Preferences()
    {
        string path = TemporaryPath();
        var first = new LinuxReceiverPreferences(path);
        Check(first.ShowVolume && first.ShowMedia && !first.IsAudioOff(Pairing), "defaults: both groups shown, Listen default on");
        first.SetAudioOff(Pairing, true);
        first.SetVisibility(false, null); first.Save();
        var relaunched = new LinuxReceiverPreferences(path);
        Check(relaunched.IsAudioOff(Pairing) && !relaunched.IsAudioOff("pair-2") && !relaunched.ShowVolume && relaunched.ShowMedia, "explicit Off and visibility persist per pair");
        string text = File.ReadAllText(path);
        Check(!text.Contains(Pairing, StringComparison.Ordinal) && text.Contains(LinuxReceiverPreferences.Key(Pairing), StringComparison.Ordinal), "pairing stored only as a hash");
        Check(text.Contains(LinuxReceiverPreferences.ShowVolumeKey, StringComparison.Ordinal) && text.Contains(LinuxReceiverPreferences.ShowMediaKey, StringComparison.Ordinal), "contract keys");
        relaunched.SetAudioOff(Pairing, false);
        Check(!new LinuxReceiverPreferences(path).IsAudioOff(Pairing), "explicit On clears Off");
    }

    private static void PreferencesUnreadable()
    {
        string path = TemporaryPath(); File.WriteAllText(path, "{not json");
        var preferences = new LinuxReceiverPreferences(path);
        Check(preferences.IsAudioOff(Pairing) && preferences.IsAudioOff("any"), "unreadable choice suppresses automatic Listen");
        preferences.SetVisibility(false, false); preferences.Save();
        Check(File.ReadAllText(path) == "{not json", "presentation toggles do not overwrite the unreadable file");
        preferences.SetAudioOff(Pairing, false);
        Check(!new LinuxReceiverPreferences(path).IsAudioOff(Pairing), "explicit Listen choice rewrites it");
    }

    private sealed class FakeSession : IReceiverAudioSession
    {
        internal long Generation = 4;
        internal int Begins;
        internal readonly List<string> Ended = [];
        internal string? LastRequest;
        public long SessionGeneration => Generation;
        public event EventHandler<ConnectionStateChangedEventArgs>? StateChanged;
        public event EventHandler<AudioStateEventArgs>? AudioStateChanged;
        internal void Disconnect() => StateChanged?.Invoke(this, new(PeelConnectionState.Disconnected));
        internal void SourceStopped() => AudioStateChanged?.Invoke(this, new(new AudioSessionStateMessage(LastRequest ?? Id(), Pairing, "stopped", "Mac audio sharing was turned off."), Generation));
        public Task<AudioAuthorization> BeginAudioPlaybackAsync(long generation, CancellationToken token)
        {
            if (generation != Generation) throw new InvalidOperationException("stale");
            Interlocked.Increment(ref Begins); LastRequest = Id();
            return Task.FromResult(new AudioAuthorization(LastRequest, Pairing, Convert.ToBase64String(new byte[32]), Host, generation));
        }
        public Task EndAudioAsync(string requestId, long generation) { lock (Ended) Ended.Add(requestId); return Task.CompletedTask; }
        internal int EndedCount { get { lock (Ended) return Ended.Count; } }
    }

    private sealed class FakeStore : IPairedHostCredentialStore, IClientHostResolver
    {
        public ValueTask<PairedHostCredential?> GetForHostAsync(string id, CancellationToken token) => ValueTask.FromResult<PairedHostCredential?>(new(Host, Pairing, new byte[32]));
        public ValueTask<HostCandidate?> ResolveFreshAsync(string id, CancellationToken token) => ValueTask.FromResult<HostCandidate?>(new(Host, Host, Host, "192.0.2.1", 54321, true));
    }

    private sealed class ScriptedStream(byte[] incoming) : Stream
    {
        private readonly MemoryStream input = new(incoming);
        private readonly TaskCompletionSource closed = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal readonly MemoryStream Written = new();
        public override bool CanRead => true;
        public override bool CanWrite => true;
        public override bool CanSeek => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken token)
        {
            int count; lock (input) count = input.Read(buffer.Span);
            if (count > 0) return count;
            await closed.Task.WaitAsync(token);
            throw new ObjectDisposedException(nameof(ScriptedStream));
        }
        public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken token) => ReadAsync(buffer.AsMemory(offset, count), token).AsTask();
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override ValueTask WriteAsync(ReadOnlyMemory<byte> data, CancellationToken token) { lock (Written) Written.Write(data.Span); return ValueTask.CompletedTask; }
        public override Task WriteAsync(byte[] buffer, int offset, int count, CancellationToken token) { lock (Written) Written.Write(buffer, offset, count); return Task.CompletedTask; }
        public override void Write(byte[] buffer, int offset, int count) { lock (Written) Written.Write(buffer, offset, count); }
        public override Task FlushAsync(CancellationToken token) => Task.CompletedTask;
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        protected override void Dispose(bool disposing) { closed.TrySetResult(); base.Dispose(disposing); }
        public override ValueTask DisposeAsync() { closed.TrySetResult(); return ValueTask.CompletedTask; }
        internal string WrittenText { get { lock (Written) return Encoding.UTF8.GetString(Written.ToArray()); } }
    }

    private sealed class FakeTransport(Func<byte[]> script) : IPeelPskTransportFactory
    {
        internal ScriptedStream? Last;
        internal int Connects;
        public ValueTask<Stream> ConnectAsync(DnsEndPoint endpoint, PeelPskCredential credential, CancellationToken token)
        {
            if (credential.Identity != Pairing || credential.PreSharedKey.Length != 32) throw new IOException("wrong credential");
            Interlocked.Increment(ref Connects); Last = new ScriptedStream(script());
            return ValueTask.FromResult<Stream>(Last);
        }
        public ValueTask<IPeelPskListener> ListenAsync(IPEndPoint endpoint, IPeelPskCredentialResolver resolver, CancellationToken token) => throw new NotSupportedException();
    }

    private sealed class FakeBackend : IReceiverAudioBackend
    {
        internal bool Openable = true;
        internal int Opens, Pushes, Closed;
        public bool Probe() => Openable;
        public IReceiverAudioOutput? Open(ulong generation) { if (!Openable) return null; Interlocked.Increment(ref Opens); return new Output(this); }
        private sealed class Output(FakeBackend owner) : IReceiverAudioOutput
        {
            public int Push(byte[] pcm) { if (pcm.Length != 3840) return -1; Interlocked.Increment(ref owner.Pushes); return 1; }
            public void Dispose() => Interlocked.Increment(ref owner.Closed);
        }
    }

    private static byte[] Script(params byte[][] packets) => packets.SelectMany(p => p).ToArray();

    private static async Task AudioOwnerPlays()
    {
        var session = new FakeSession(); var store = new FakeStore(); var backend = new FakeBackend();
        var transport = new FakeTransport(() => Script(Format(), Pcm(1), Pcm(2), Pcm(3)));
        await using var audio = new LinuxReceiverAudio(session, transport, store, store, backend, 7, session.Generation, TimeSpan.FromSeconds(2));
        await audio.StartAsync();
        await Eventually(() => backend.Pushes == 3 && audio.Snapshot.Phase == ReceiverAudioPhase.Playing, "three admitted packets and Playing");
        await audio.StartAsync();
        Check(session.Begins == 1 && transport.Connects == 1, "one current owner; a second Start does not open another");
        string hello = transport.Last!.WrittenText;
        Check(hello.EndsWith('\n') && hello.Count(c => c == '\n') == 1, "exactly one hello line, nothing trailing");
        using (var document = JsonDocument.Parse(hello))
            Check(document.RootElement.GetProperty("type").GetString() == "audioStreamHello" && document.RootElement.GetProperty("requestId").GetString() == session.LastRequest &&
                  document.RootElement.GetProperty("pairingId").GetString() == Pairing, "hello carries the authorized request and pairing");
        Check(!audio.Snapshot.Status.Contains(Convert.ToBase64String(new byte[32]), StringComparison.Ordinal), "ticket never reaches status text");
        await audio.StopAsync();
        Check(!audio.Running && audio.Snapshot.Phase == ReceiverAudioPhase.Idle && backend.Closed == 1 && session.EndedCount == 1 && session.Ended[0] == session.LastRequest, "stop releases output and ends the exact request");
    }

    private static async Task AudioOwnerNoOutput()
    {
        var session = new FakeSession(); var store = new FakeStore(); var backend = new FakeBackend { Openable = false };
        var transport = new FakeTransport(() => Script(Format(), Pcm(1)));
        await using var audio = new LinuxReceiverAudio(session, transport, store, store, backend, 7, session.Generation, TimeSpan.FromSeconds(2));
        await audio.StartAsync();
        await Eventually(() => audio.Snapshot.Phase == ReceiverAudioPhase.Failed, "Failed");
        Check(audio.Snapshot.Status == "No working audio output on this computer." && backend.Pushes == 0 && session.EndedCount == 1, "honest unavailable output, request ended");
        var pcmFirst = new FakeTransport(() => Script(Pcm(1)));
        var other = new FakeSession();
        await using var malformed = new LinuxReceiverAudio(other, pcmFirst, store, store, new FakeBackend(), 7, other.Generation, TimeSpan.FromSeconds(2));
        await malformed.StartAsync();
        await Eventually(() => malformed.Snapshot.Phase == ReceiverAudioPhase.Failed, "malformed Failed");
        Check(other.EndedCount == 1, "PCM before format fails closed and ends the request");
        var stale = new FakeSession(); stale.Generation = 5;
        await using var fenced = new LinuxReceiverAudio(stale, transport, store, store, new FakeBackend(), 7, 4, TimeSpan.FromSeconds(2));
        await fenced.StartAsync();
        Check(!fenced.Running && stale.Begins == 0, "stale control generation never requests audio");
    }

    private static async Task AudioOwnerSourceStop()
    {
        var session = new FakeSession(); var store = new FakeStore(); var backend = new FakeBackend();
        var transport = new FakeTransport(() => Script(Format(), Pcm(1)));
        await using var audio = new LinuxReceiverAudio(session, transport, store, store, backend, 7, session.Generation, TimeSpan.FromSeconds(2));
        await audio.StartAsync();
        await Eventually(() => audio.Snapshot.Phase == ReceiverAudioPhase.Playing, "Playing");
        session.SourceStopped();
        await Eventually(() => !audio.Running, "source stop ends playback");
        Check(audio.Snapshot.Phase == ReceiverAudioPhase.Failed && audio.Snapshot.Status == "Mac audio sharing was turned off." && session.EndedCount == 1, "source reason shown");
        await audio.StartAsync();
        await Eventually(() => audio.Snapshot.Phase == ReceiverAudioPhase.Playing, "restart");
        session.Disconnect();
        await Eventually(() => !audio.Running, "disconnect ends playback");
        Check(session.EndedCount == 2 && backend.Closed == 2, "each owner released");
    }

    private static Task Command(LinuxReceiverControls controls, uint window, int command, double value) =>
        controls.Capture(window) is { } binding ? controls.CommandAsync(binding, command, value) : Task.CompletedTask;

    private static async Task ControlsStaleQueuedClick()
    {
        var channel = new FakeChannel(); channel.Capabilities.Add(SourceMediaProtocol.MediaKeysCapability);
        await using var controls = new LinuxReceiverControls(Pairing, null, false, new LinuxSourceMediaClient(channel, 9, Pairing, null),
            new LinuxReceiverPreferences(TemporaryPath()), (_, _) => { });
        await controls.VideoAdmittedAsync(42);
        var old = controls.Capture(42) ?? throw new Exception("current viewer not bound");
        var gate = channel.HoldNext();
        Check(controls.Enqueue(old, LinuxReceiverControls.Next, 0) && controls.Enqueue(old, LinuxReceiverControls.PlayPause, 0), "clicks queued at GTK time");
        await Eventually(() => channel.Entered == 1, "first queued click waiting for the writer");
        await controls.StreamEndedAsync();          // viewer closed
        Check(controls.Capture(42) is null, "no binding while nothing streams");
        await controls.VideoAdmittedAsync(42);       // same window ID reopened: new epoch
        gate.TrySetResult(true);
        await controls.Idle.WaitAsync(TimeSpan.FromSeconds(2));
        Check(channel.Count == 0 && channel.Entered == 1, "old queued clicks did nothing after close/reopen of the same ID");
        var fresh = controls.Capture(42) ?? throw new Exception("reopened viewer not bound");
        Check(fresh.Window == 42 && fresh.Epoch != old.Epoch, "reopened stream has a new epoch");
        Check(controls.Enqueue(fresh, LinuxReceiverControls.PlayPause, 0), "fresh click queued");
        await controls.Idle.WaitAsync(TimeSpan.FromSeconds(2));
        Check(channel.Count == 1 && channel.Last.GetProperty("action").GetString() == "playPause" && channel.Last.GetProperty("windowId").GetUInt32() == 42, "fresh click works");
        Check(controls.Capture(43) is null, "another window ID never binds");
    }

    private static async Task ControlsVolumeQuery()
    {
        var channel = new FakeChannel(); channel.Capabilities.Add(SourceMediaProtocol.VolumeCapability);
        var preferences = new LinuxReceiverPreferences(TemporaryPath());
        await using var controls = new LinuxReceiverControls(Pairing, null, false, new LinuxSourceMediaClient(channel, 9, Pairing, SourceVolumeScope.SystemOutput), preferences, (_, _) => { });
        Check(controls.Compose().Volume == SourceVolumeView.Unsupported, "unknown until the source answers");
        await controls.VideoAdmittedAsync(42);
        var query = channel.Last;
        Check(channel.Count == 1 && query.GetProperty("type").GetString() == "sourceVolumeQuery" && query.GetProperty("scope").GetString() == "systemOutput" &&
              query.GetProperty("windowId").GetUInt32() == 42, "current viewer reads the source's system output");
        channel.Reply(SourceMediaProtocol.VolumeStateType, State(query, 42, 1, 0.3, false));
        Check(controls.Compose().Volume is { Supported: true, CanSetVolume: true, Volume: 0.3, Muted: false }, "actual source state reaches the toolbar");
        await Command(controls, 42, LinuxReceiverControls.MuteSet, 1);
        Check(channel.Last.GetProperty("type").GetString() == "sourceVolumeSet" && channel.Last.GetProperty("muted").GetBoolean() && controls.Compose().Volume.Muted == false, "mute is sent to the source, not assumed");
        await Command(controls, 42, LinuxReceiverControls.VolumeSet, 2);
        Check(channel.Count == 2, "out-of-range volume never leaves the toolbar");
    }

    private static async Task ControlsLifecycle()
    {
        var session = new FakeSession(); var store = new FakeStore(); var backend = new FakeBackend();
        var transport = new FakeTransport(() => Script(Format(), Pcm(1), Pcm(2)));
        var channel = new FakeChannel(); channel.Capabilities.Add(SourceMediaProtocol.MediaKeysCapability);
        string path = TemporaryPath();
        var preferences = new LinuxReceiverPreferences(path);
        var published = new List<(uint Window, ViewerSnapshot Snapshot)>();
        var audio = new LinuxReceiverAudio(session, transport, store, store, backend, 7, session.Generation, TimeSpan.FromSeconds(2));
        await using var controls = new LinuxReceiverControls(Pairing, audio, true, new LinuxSourceMediaClient(channel, 9, Pairing, null), preferences,
            (window, snapshot) => { lock (published) published.Add((window, snapshot)); });
        await Command(controls, 42, LinuxReceiverControls.PlayPause, 0);
        Check(channel.Count == 0, "no command before this window's video is admitted");
        await controls.VideoAdmittedAsync(42);
        await Eventually(() => audio.Snapshot.Phase == ReceiverAudioPhase.Playing, "default Listen after first admitted video");
        Check(controls.Compose() is { Audio: LinuxReceiverControls.AudioPlaying, ListenEnabled: true, MediaEnabled: true } snapshot && !snapshot.Volume.Supported, "actual state; volume stays unsupported");
        await Command(controls, 43, LinuxReceiverControls.ListenOff, 0);
        await Command(controls, 43, LinuxReceiverControls.Next, 0);
        Check(audio.Running && !preferences.IsAudioOff(Pairing) && channel.Count == 0, "other window's commands are ignored");
        await Command(controls, 42, LinuxReceiverControls.Previous, 0);
        Check(channel.Last.GetProperty("action").GetString() == "previousTrack" && channel.Last.GetProperty("windowId").GetUInt32() == 42, "media goes to the source for this window");
        preferences.SetVisibility(false, false);
        Check(audio.Running, "hiding control groups never stops audio");
        await Command(controls, 42, LinuxReceiverControls.ListenOff, 0);
        Check(!audio.Running && preferences.IsAudioOff(Pairing) && new LinuxReceiverPreferences(path).IsAudioOff(Pairing), "explicit Off stops and persists");
        Check(controls.Compose().Audio == LinuxReceiverControls.AudioOff, "Off shown");
        await controls.StreamEndedAsync();
        int begins = session.Begins;
        await controls.VideoAdmittedAsync(42);
        Check(session.Begins == begins && !audio.Running, "explicit Off respected on the next stream/reconnect");
        await Command(controls, 42, LinuxReceiverControls.ListenOn, 0);
        await Eventually(() => audio.Snapshot.Phase == ReceiverAudioPhase.Playing, "explicit On");
        Check(!preferences.IsAudioOff(Pairing), "explicit On clears Off");
        await controls.StreamEndedAsync();
        Check(!audio.Running && !preferences.IsAudioOff(Pairing), "last stream closure stops audio without writing Off");
        lock (published) Check(published.All(p => p.Window == 42), "only the current viewer is updated");
        var unavailable = new LinuxReceiverControls(Pairing, null, true, new LinuxSourceMediaClient(new FakeChannel(), 9, Pairing, null), preferences, (_, _) => { });
        await unavailable.VideoAdmittedAsync(42);
        Check(unavailable.Compose() is { Audio: LinuxReceiverControls.AudioUnavailable, ListenEnabled: false, MediaEnabled: false }, "no backend: honest unavailable, nothing enabled");
        await unavailable.DisposeAsync();
    }
}
