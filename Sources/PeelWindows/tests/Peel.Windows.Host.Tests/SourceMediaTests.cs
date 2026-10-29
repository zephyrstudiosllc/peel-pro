using System.Diagnostics;
using System.Threading.Channels;
using Peel.Windows.Host.Audio;
using Peel.Windows.Host.Encoding;
using Peel.Windows.Host.Input;
using Peel.Windows.Host.Networking;
using Peel.Windows.Host.Windows;
using Peel.Windows.Protocol;

namespace Peel.Windows.Host.Tests;

internal static partial class Program
{
    // In-memory control and video sockets, recording input and scripted capture only.
    // No SendInput, media key or OS volume call is made by this test.
    private static async Task SourceMediaKeysRequireAdmittedStreamAndInputGateAsync()
    {
        const string identity = "source-media-client";
        WindowDescriptor window = CreateVideoWindow();
        var gate = new InputPermissionGate();
        gate.SetEnabled(true);
        var resolver = new RecordingWindowInputTargetResolver(window.Bounds);
        var injector = new RecordingInputInjector();
        Channel<byte[]> replies = Channel.CreateUnbounded<byte[]>();
        var windowList = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var controlStream = new InteractiveDuplexStream(written =>
        {
            ReadOnlySpan<byte> line = written.Span;
            if (line.IsEmpty || line[^1] != (byte)'\n') return;
            string type = PeelJson.ReadEnvelope(line[..^1]).Type;
            if (type == PeelMessageType.WindowList) windowList.TrySetResult();
            else if (type is SourceMediaProtocol.AckType or SourceMediaProtocol.VolumeStateType)
                replies.Writer.TryWrite(line[..^1].ToArray());
        });
        await using var controlManager = new HostControlSessionManager(
            new FakeWindowEnumerator([window]),
            new DelegateHostInputSessionFactory(() => new WindowsHostInputSession(gate, resolver, injector)),
            new HostControlSessionOptions("Test Host", "Test OS", "1.0"));
        var captureEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var capture = new ScriptedCaptureSession(window, async (_, cancellationToken) =>
        {
            captureEntered.TrySetResult();
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken).ConfigureAwait(false);
        });
        var encoder = new ScriptedVideoEncoder((_, _) => ValueTask.FromResult<EncodedVideoFrame?>(null));
        await using var videoManager = new HostVideoSessionManager(
            controlManager,
            new SequencedCaptureBackend(capture),
            new SequencedEncoderFactory(encoder),
            CreateVideoOptions());

        controlStream.EnqueueLines(
            PeelHello.CreateClient(identity, "Media Client", "Windows", capabilities: VideoCapabilities()),
            new PeelRequest(PeelMessageType.RequestWindowList));
        Task controlTask = controlManager.RunAuthenticatedSessionAsync(new PeelPskConnection(controlStream, identity));
        await windowList.Task.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);

        // Listed but not streamed: no admitted video socket means no authority.
        SourceMediaCommandMessage beforeVideo = MediaCommand(identity, SourceMediaAction.PlayPause);
        controlStream.EnqueueLines(beforeVideo);
        AssertSourceAck(await NextSourceReplyAsync(replies).ConfigureAwait(false), beforeVideo.RequestId!, identity, "stale", "staleStream");
        Equal(0, injector.Calls.Count);

        var videoStream = new ScriptedDuplexStream(CombineLines(CreateVideoHello(identity)));
        Task videoTask = videoManager.RunAuthenticatedVideoSessionAsync(new PeelPskConnection(videoStream, identity));
        await captureEntered.Task.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        long generation = controlManager.ActiveGeneration ?? throw new InvalidOperationException("No control generation.");
        True(videoManager.HasActiveVideo(generation, identity, 1));
        True(!videoManager.HasActiveVideo(generation + 1, identity, 1));
        True(!videoManager.HasActiveVideo(generation, "other-peer", 1));
        True(!videoManager.HasActiveVideo(generation, identity, 2));

        // Foreign pairing and malformed identity get no reply at all; a future version is refused.
        SourceMediaCommandMessage foreign = MediaCommand("other-peer", SourceMediaAction.NextTrack);
        var malformed = new SourceMediaCommandMessage("not-a-request-id", identity, 1, "nextTrack", 1, SourceMediaProtocol.CommandType);
        var future = new SourceMediaCommandMessage(Guid.NewGuid().ToString("D"), identity, 1, "nextTrack", 2, SourceMediaProtocol.CommandType);
        SourceMediaCommandMessage play = MediaCommand(identity, SourceMediaAction.PlayPause);
        var query = SourceVolumeQueryMessage.Create(Guid.NewGuid(), identity, 1, SourceVolumeScope.SystemOutput);
        var set = SourceVolumeSetMessage.Create(Guid.NewGuid(), identity, 1, SourceVolumeScope.PeelStream, 0.5, null);
        controlStream.EnqueueLines(foreign, malformed, future, play, query, set);
        AssertSourceAck(await NextSourceReplyAsync(replies).ConfigureAwait(false), future.RequestId!, identity, "unsupported", null);
        AssertSourceAck(await NextSourceReplyAsync(replies).ConfigureAwait(false), play.RequestId!, identity, "applied", null);
        var state = PeelJson.Deserialize<SourceVolumeStateMessage>(await NextSourceReplyAsync(replies).ConfigureAwait(false));
        True(state.IsValid && state.Supported == false && state.Volume is null && state.Muted is null &&
            state.RequestId == query.RequestId && state.Scope == "systemOutput" && state.Reason == "scopeUnsupported");
        // Admitted, but without a selected volume backend a set is never reported as applied.
        AssertSourceAck(await NextSourceReplyAsync(replies).ConfigureAwait(false), set.RequestId!, identity, "unsupported", "scopeUnsupported");
        True(injector.Calls.SequenceEqual(["media:179"], StringComparer.Ordinal));
        Equal(0, resolver.AcquireForegroundCount);

        // The master input gate applies exactly as for other remote input.
        gate.SetEnabled(false);
        SourceMediaCommandMessage blocked = MediaCommand(identity, SourceMediaAction.NextTrack);
        controlStream.EnqueueLines(blocked);
        AssertSourceAck(await NextSourceReplyAsync(replies).ConfigureAwait(false), blocked.RequestId!, identity, "denied", "controlOff");
        gate.SetEnabled(true);

        SourceMediaCommandMessage hidden = MediaCommand(identity, SourceMediaAction.PreviousTrack);
        controlStream.EnqueueLines(new ClientVisibilityMessage(false), hidden, new ClientVisibilityMessage(true));
        AssertSourceAck(await NextSourceReplyAsync(replies).ConfigureAwait(false), hidden.RequestId!, identity, "denied", "notVisible");

        SourceMediaCommandMessage next = MediaCommand(identity, SourceMediaAction.NextTrack);
        SourceMediaCommandMessage previous = MediaCommand(identity, SourceMediaAction.PreviousTrack);
        controlStream.EnqueueLines(next, previous);
        AssertSourceAck(await NextSourceReplyAsync(replies).ConfigureAwait(false), next.RequestId!, identity, "applied", null);
        AssertSourceAck(await NextSourceReplyAsync(replies).ConfigureAwait(false), previous.RequestId!, identity, "applied", null);
        True(injector.Calls.SequenceEqual(["media:179", "media:176", "media:177"], StringComparer.Ordinal));

        // Stopping the stream removes its authority before the video socket even finishes closing.
        SourceMediaCommandMessage afterStop = MediaCommand(identity, SourceMediaAction.PlayPause);
        controlStream.EnqueueLines(new PeelRequest(PeelMessageType.StopStream, WindowId: 1), afterStop);
        AssertSourceAck(await NextSourceReplyAsync(replies).ConfigureAwait(false), afterStop.RequestId!, identity, "stale", "staleStream");
        await videoTask.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        True(!videoManager.HasActiveVideo(generation, identity, 1));
        Equal(3, injector.Calls.Count);
        Equal(0, resolver.AcquireForegroundCount);

        controlStream.CompleteInput();
        await controlTask.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        True(!replies.Reader.TryRead(out _));
    }

    private static void SourceMediaLimiterIsSlidingAndPerKind()
    {
        long now = 0;
        var limiter = new HostSourceMediaLimiter(() => now);
        for (int index = 0; index < 5; index++) True(limiter.TryAdmit(HostSourceMediaLimit.Media));
        True(!limiter.TryAdmit(HostSourceMediaLimit.Media));
        for (int index = 0; index < 10; index++) True(limiter.TryAdmit(HostSourceMediaLimit.VolumeQuery));
        True(!limiter.TryAdmit(HostSourceMediaLimit.VolumeQuery));
        for (int index = 0; index < 20; index++) True(limiter.TryAdmit(HostSourceMediaLimit.VolumeSet));
        True(!limiter.TryAdmit(HostSourceMediaLimit.VolumeSet));
        now = Stopwatch.Frequency - 1;
        True(!limiter.TryAdmit(HostSourceMediaLimit.Media));
        now = Stopwatch.Frequency;
        for (int index = 0; index < 5; index++) True(limiter.TryAdmit(HostSourceMediaLimit.Media));
        True(!limiter.TryAdmit(HostSourceMediaLimit.Media));
        ulong first = HostSourceMedia.NextVolumeSequence();
        True(HostSourceMedia.NextVolumeSequence() > first);
    }

    // Only rejected paths are exercised, so no native input is ever posted by this test.
    private static void SourceMediaKeysAreAllowlistedAndGated()
    {
        var gate = new InputPermissionGate();
        var native = new WindowsInputInjector(gate);
        Equal(InputPermissionGate.DisabledReason, native.SendMediaKey(WindowsInputInjector.MediaPlayPause).Error);
        gate.SetEnabled(true);
        // Volume keys, stop, Space, Enter and arbitrary keys are never reachable through this path.
        foreach (ushort key in new ushort[] { 0, 0x0D, 0x20, 0xAD, 0xAE, 0xAF, 0xB2, 0xB4, 0xFF })
            True(!native.SendMediaKey(key).Succeeded);

        WindowDescriptor window = CreateVideoWindow();
        var injector = new RecordingInputInjector();
        var resolver = new RecordingWindowInputTargetResolver(window.Bounds);
        using var session = new WindowsHostInputSession(gate, resolver, injector);
        True(!session.HandleSourceMediaKey((SourceMediaAction)99, window).Succeeded);
        Equal(0, injector.Calls.Count);
        True(session.HandleSourceMediaKey(SourceMediaAction.NextTrack, window).Succeeded);
        True(injector.Calls.SequenceEqual(["media:176"], StringComparer.Ordinal));
        Equal(0, resolver.AcquireForegroundCount);
        gate.SetEnabled(false);
        Equal(InputPermissionGate.DisabledReason, session.HandleSourceMediaKey(SourceMediaAction.PlayPause, window).Error);
        Equal(InputPermissionGate.DisabledReason, session.AdmitSourceInput(window).Error);
        Equal(1, injector.Calls.Count);
    }

    private static async Task SourceSystemVolumeIsGatedFencedAndActualAsync()
    {
        const string identity = "source-volume-client";
        WindowDescriptor window = CreateVideoWindow();
        var gate = new InputPermissionGate();
        gate.SetEnabled(true);
        var resolver = new RecordingWindowInputTargetResolver(window.Bounds);
        var injector = new RecordingInputInjector();
        var volume = new FakeSourceVolume();
        var options = new HostControlSessionOptions("Test Host", "Test OS", "1.0") { SourceVolume = volume };
        var host = await StartSourceMediaHostAsync(identity, window, options,
            new DelegateHostInputSessionFactory(() => new WindowsHostInputSession(gate, resolver, injector))).ConfigureAwait(false);
        await using HostControlSessionManager controlManager = host.Control;
        await using HostVideoSessionManager videoManager = host.Video;

        // Query: actual state of the default output, echoing the request; peelStream is unsupported.
        var query = SourceVolumeQueryMessage.Create(Guid.NewGuid(), identity, 1, SourceVolumeScope.SystemOutput);
        var streamQuery = SourceVolumeQueryMessage.Create(Guid.NewGuid(), identity, 1, SourceVolumeScope.PeelStream);
        host.Stream.EnqueueLines(query, streamQuery);
        SourceVolumeStateMessage first = await NextSourceStateAsync(host.Replies).ConfigureAwait(false);
        True(first.RequestId == query.RequestId && first.Scope == "systemOutput" && first.Supported == true &&
            first.CanSetVolume == true && first.CanSetMute == true && first.Volume == 0.25 && first.Muted == false && first.Reason is null);
        SourceVolumeStateMessage unsupported = await NextSourceStateAsync(host.Replies).ConfigureAwait(false);
        True(unsupported.RequestId == streamQuery.RequestId && unsupported.Supported == false && unsupported.Reason == "scopeUnsupported");

        // Set: the reply is the re-read actual state after the write, with a newer sequence.
        var set = SourceVolumeSetMessage.Create(Guid.NewGuid(), identity, 1, SourceVolumeScope.SystemOutput, 0.6, null);
        host.Stream.EnqueueLines(set);
        SourceVolumeStateMessage after = await NextSourceStateAsync(host.Replies).ConfigureAwait(false);
        True(after.RequestId == set.RequestId && after.Volume == 0.6 && after.Muted == false && after.Sequence > first.Sequence);
        True(volume.Writes.SequenceEqual(["endpoint-a:0.6:"], StringComparer.Ordinal));

        var peelStreamSet = SourceVolumeSetMessage.Create(Guid.NewGuid(), identity, 1, SourceVolumeScope.PeelStream, null, true);
        host.Stream.EnqueueLines(peelStreamSet);
        AssertSourceAck(await NextSourceReplyAsync(host.Replies).ConfigureAwait(false), peelStreamSet.RequestId!, identity, "unsupported", "scopeUnsupported");

        // Control Off: ordinary user input is refused and nothing is written.
        gate.SetEnabled(false);
        var blocked = SourceVolumeSetMessage.Create(Guid.NewGuid(), identity, 1, SourceVolumeScope.SystemOutput, null, true);
        host.Stream.EnqueueLines(blocked);
        AssertSourceAck(await NextSourceReplyAsync(host.Replies).ConfigureAwait(false), blocked.RequestId!, identity, "denied", "controlOff");
        gate.SetEnabled(true);

        // A newly selected output between admission and the write is never changed.
        volume.DeviceAtApply = "endpoint-b";
        var moved = SourceVolumeSetMessage.Create(Guid.NewGuid(), identity, 1, SourceVolumeScope.SystemOutput, 0.1, null);
        host.Stream.EnqueueLines(moved);
        AssertSourceAck(await NextSourceReplyAsync(host.Replies).ConfigureAwait(false), moved.RequestId!, identity, "stale", null);
        volume.DeviceAtApply = null;

        volume.Device = null;
        var noOutput = SourceVolumeSetMessage.Create(Guid.NewGuid(), identity, 1, SourceVolumeScope.SystemOutput, 0.1, null);
        host.Stream.EnqueueLines(noOutput);
        AssertSourceAck(await NextSourceReplyAsync(host.Replies).ConfigureAwait(false), noOutput.RequestId!, identity, "failed", "noOutputDevice");
        volume.Device = "endpoint-a";

        foreach ((SourceVolumeApplyStatus failure, string status, string reason) in new[]
        {
            (SourceVolumeApplyStatus.NotSettable, "unsupported", "fixedVolume"),
            (SourceVolumeApplyStatus.Failed, "failed", "osRefused"),
            (SourceVolumeApplyStatus.NoOutputDevice, "failed", "noOutputDevice"),
        })
        {
            volume.Fail = failure;
            var refused = SourceVolumeSetMessage.Create(Guid.NewGuid(), identity, 1, SourceVolumeScope.SystemOutput, 0.2, null);
            host.Stream.EnqueueLines(refused);
            AssertSourceAck(await NextSourceReplyAsync(host.Replies).ConfigureAwait(false), refused.RequestId!, identity, status, reason);
        }
        volume.Fail = null;
        True(volume.Writes.Count == 1);

        // Honest unreadable and read-only outputs, and no output at all.
        foreach ((SourceVolumeReading reading, bool supported, string? reason) in new (SourceVolumeReading, bool, string?)[]
        {
            (new SourceVolumeReading("endpoint-a", null, null, false, false), false, "fixedVolume"),
            (new SourceVolumeReading("endpoint-a", 0.3, false, false, false), true, "fixedVolume"),
            (new SourceVolumeReading(null, null, null, false, false), false, "noOutputDevice"),
        })
        {
            volume.Reading = reading;
            var check = SourceVolumeQueryMessage.Create(Guid.NewGuid(), identity, 1, SourceVolumeScope.SystemOutput);
            host.Stream.EnqueueLines(check);
            SourceVolumeStateMessage state = await NextSourceStateAsync(host.Replies).ConfigureAwait(false);
            True(state.IsValid && state.Supported == supported && state.Reason == reason &&
                state.CanSetVolume == false && state.CanSetMute == false && state.Volume == reading.Volume);
        }
        volume.Reading = new SourceVolumeReading("endpoint-a", 0.6, false, true, true);

        var hidden = SourceVolumeSetMessage.Create(Guid.NewGuid(), identity, 1, SourceVolumeScope.SystemOutput, 0.9, null);
        host.Stream.EnqueueLines(new ClientVisibilityMessage(false), hidden, new ClientVisibilityMessage(true));
        AssertSourceAck(await NextSourceReplyAsync(host.Replies).ConfigureAwait(false), hidden.RequestId!, identity, "denied", "notVisible");

        var afterStop = SourceVolumeQueryMessage.Create(Guid.NewGuid(), identity, 1, SourceVolumeScope.SystemOutput);
        host.Stream.EnqueueLines(new PeelRequest(PeelMessageType.StopStream, WindowId: 1), afterStop);
        AssertSourceAck(await NextSourceReplyAsync(host.Replies).ConfigureAwait(false), afterStop.RequestId!, identity, "stale", "staleStream");
        await host.VideoTask.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);

        True(volume.Writes.Count == 1 && injector.Calls.Count == 0);
        Equal(0, resolver.AcquireForegroundCount);
        host.Stream.CompleteInput();
        await host.ControlTask.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
    }

    private sealed record SourceMediaHost(HostControlSessionManager Control, HostVideoSessionManager Video,
        InteractiveDuplexStream Stream, Channel<byte[]> Replies, Task ControlTask, Task VideoTask);

    // A control session plus one admitted, idle video socket for window 1, all in memory.
    private static async Task<SourceMediaHost> StartSourceMediaHostAsync(string identity, WindowDescriptor window,
        HostControlSessionOptions options, IHostInputSessionFactory inputs)
    {
        Channel<byte[]> replies = Channel.CreateUnbounded<byte[]>();
        var windowList = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var stream = new InteractiveDuplexStream(written =>
        {
            ReadOnlySpan<byte> line = written.Span;
            if (line.IsEmpty || line[^1] != (byte)'\n') return;
            string type = PeelJson.ReadEnvelope(line[..^1]).Type;
            if (type == PeelMessageType.WindowList) windowList.TrySetResult();
            else if (type is SourceMediaProtocol.AckType or SourceMediaProtocol.VolumeStateType)
                replies.Writer.TryWrite(line[..^1].ToArray());
        });
        var control = new HostControlSessionManager(new FakeWindowEnumerator([window]), inputs, options);
        var captureEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var capture = new ScriptedCaptureSession(window, async (_, cancellationToken) =>
        {
            captureEntered.TrySetResult();
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken).ConfigureAwait(false);
        });
        var video = new HostVideoSessionManager(control, new SequencedCaptureBackend(capture),
            new SequencedEncoderFactory(new ScriptedVideoEncoder((_, _) => ValueTask.FromResult<EncodedVideoFrame?>(null))),
            CreateVideoOptions());
        stream.EnqueueLines(
            PeelHello.CreateClient(identity, "Volume Client", "Windows", capabilities: VideoCapabilities()),
            new PeelRequest(PeelMessageType.RequestWindowList));
        Task controlTask = control.RunAuthenticatedSessionAsync(new PeelPskConnection(stream, identity));
        await windowList.Task.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        Task videoTask = video.RunAuthenticatedVideoSessionAsync(
            new PeelPskConnection(new ScriptedDuplexStream(CombineLines(CreateVideoHello(identity))), identity));
        await captureEntered.Task.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        return new(control, video, stream, replies, controlTask, videoTask);
    }

    private static async Task<SourceVolumeStateMessage> NextSourceStateAsync(Channel<byte[]> replies)
    {
        byte[] line = await NextSourceReplyAsync(replies).ConfigureAwait(false);
        Equal(SourceMediaProtocol.VolumeStateType, PeelJson.ReadEnvelope(line).Type);
        var state = PeelJson.Deserialize<SourceVolumeStateMessage>(line);
        True(state.IsValid);
        return state;
    }

    // Fake executor only: never touches Windows Core Audio.
    private sealed class FakeSourceVolume : ISourceSystemVolume
    {
        internal string? Device { get; set; } = "endpoint-a";
        internal string? DeviceAtApply { get; set; }
        internal SourceVolumeReading Reading { get; set; } = new("endpoint-a", 0.25, false, true, true);
        internal SourceVolumeApplyStatus? Fail { get; set; }
        internal List<string> Writes { get; } = [];

        public string? CurrentDevice() => Device;

        public SourceVolumeReading Read() => Reading;

        public SourceVolumeApplyResult Apply(double? level, bool? muted, string expectedDevice)
        {
            if (Fail is { } failure) return new(failure);
            if (!StringComparer.Ordinal.Equals(DeviceAtApply ?? Device, expectedDevice))
                return new(SourceVolumeApplyStatus.DeviceChanged);
            Writes.Add(FormattableString.Invariant($"{expectedDevice}:{level}:{muted}"));
            Reading = Reading with { Volume = level ?? Reading.Volume, Muted = muted ?? Reading.Muted };
            return new(SourceVolumeApplyStatus.Applied, Reading);
        }
    }

    // Read-only: one Core Audio read of the default output on an MTA thread. Never writes volume or
    // mute and never prints endpoint names or identifiers.
    private static async Task<int> NativeSourceVolumeReadSmokeAsync()
    {
        SourceVolumeReading reading = await Task.Run(() => new WindowsSystemOutputVolume().Read()).ConfigureAwait(false);
        Console.WriteLine(reading.DeviceId is null
            ? "Source volume read: no default output endpoint was available."
            : $"Source volume read: default output found; volume {(reading.Volume is { } v ? FormattableString.Invariant($"{v:F2}") : "unreadable")}, " +
              $"mute {(reading.Muted is { } m ? (m ? "on" : "off") : "unreadable")}. Nothing was changed.");
        return reading.DeviceId is not null && (reading.Volume is not null || reading.Muted is not null) ? 0 : 1;
    }

    private static SourceMediaCommandMessage MediaCommand(string pairingId, SourceMediaAction action) =>
        SourceMediaCommandMessage.Create(Guid.NewGuid(), pairingId, 1, action);

    private static async Task<byte[]> NextSourceReplyAsync(Channel<byte[]> replies) =>
        await replies.Reader.ReadAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);

    private static void AssertSourceAck(byte[] line, string requestId, string pairingId, string status, string? reason)
    {
        var ack = PeelJson.Deserialize<SourceMediaAckMessage>(line);
        True(ack.TryParse(out _, out _));
        Equal(requestId, ack.RequestId);
        Equal(pairingId, ack.PairingId);
        Equal<uint?>(1, ack.WindowId);
        Equal(status, ack.Status);
        Equal(reason, ack.Reason);
    }
}
