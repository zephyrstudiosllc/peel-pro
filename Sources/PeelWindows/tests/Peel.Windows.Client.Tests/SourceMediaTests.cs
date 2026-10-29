using Peel.Windows.Client.Models;
using Peel.Windows.Client.Services;
using Peel.Windows.Client.ViewModels;
using Peel.Windows.Protocol;

namespace Peel.Windows.Client.Tests;

// In-memory scripted control sockets only: no audio device, media key or volume API is used.
internal static partial class Program
{
    private static async Task SourceMediaControllerBindsOwnerAndFencesRepliesAsync()
    {
        var connected = await ConnectSourceMediaAsync(SourceMediaProtocol.MediaKeysCapability);
        await using var session = connected.Session;
        var stream = connected.Stream;
        var viewer = new FakeViewerStream();
        using var controller = new ClientSourceMediaController(session, viewer);
        True(controller.CaptureBinding() is null, "Without an admitted stream there is no source binding.");

        viewer.Set(PeelStreamState.Streaming, 5);
        var binding = controller.CaptureBinding() ?? throw new InvalidOperationException("Missing binding.");
        True(binding is { MediaKeys: true, Volume: false, WindowId: 5, PairingId: Fixture.PairingId },
            "A tap binds this viewer's window, pairing and the source's advertised capability.");
        Equal(SourceMediaResultKind.Unavailable, (await controller.QueryVolumeAsync(binding, SourceVolumeScope.PeelStream, default)).Kind);
        Equal(2, SnapshotWrites(stream).Length);

        var play = controller.SendMediaAsync(binding, SourceMediaAction.PlayPause, default);
        await stream.WaitForWritesAsync(3);
        var command = DeserializeWrite<SourceMediaCommandMessage>(stream, 2);
        True(command.Check() is { IsValid: true, Value: SourceMediaAction.PlayPause } && command.WindowId == 5 &&
            command.PairingId == Fixture.PairingId && command.RequestId == command.RequestId!.ToUpperInvariant(),
            "The command carries the exact owner and a canonical request ID.");
        // Another window, another pairing and an unknown status are ignored and never end the session.
        stream.EnqueueRead(SourceAck(command.RequestId!, Fixture.PairingId, 6, "applied"));
        stream.EnqueueRead(SourceAck(command.RequestId!, "someone-else", 5, "applied"));
        stream.EnqueueRead(SourceAck(command.RequestId!, Fixture.PairingId, 5, "queued"));
        await Task.Delay(60);
        True(!play.IsCompleted && session.State == PeelConnectionState.Connected, "Foreign replies cannot complete or disconnect.");
        stream.EnqueueRead(SourceAck(command.RequestId!.ToLowerInvariant(), Fixture.PairingId, 5, "denied", "controlOff"));
        True(await play.WaitAsync(TimeSpan.FromSeconds(2)) is
            { Kind: SourceMediaResultKind.Reply, Status: SourceMediaStatus.Denied, Reason: SourceMediaReason.ControlOff },
            "The source's actual refusal is reported, never a local fallback.");

        // A stream change makes an in-flight tap stale; its late answer and the old binding are ignored.
        var late = controller.SendMediaAsync(binding, SourceMediaAction.NextTrack, default);
        await stream.WaitForWritesAsync(4);
        var lateCommand = DeserializeWrite<SourceMediaCommandMessage>(stream, 3);
        viewer.Set(PeelStreamState.Streaming, 6);
        Equal(SourceMediaResultKind.Stale, (await late.WaitAsync(TimeSpan.FromSeconds(2))).Kind);
        stream.EnqueueRead(SourceAck(lateCommand.RequestId!, Fixture.PairingId, 5, "applied"));
        Equal(SourceMediaResultKind.Stale, (await controller.SendMediaAsync(binding, SourceMediaAction.NextTrack, default)).Kind);
        Equal(4, SnapshotWrites(stream).Length);

        // At most eight pending; unanswered requests time out after three seconds.
        var current = controller.CaptureBinding() ?? throw new InvalidOperationException("Missing binding.");
        Equal<uint>(6, current.WindowId);
        var pending = Enumerable.Range(0, 8)
            .Select(_ => controller.SendMediaAsync(current, SourceMediaAction.NextTrack, default)).ToArray();
        await stream.WaitForWritesAsync(12);
        Equal(SourceMediaResultKind.Busy, (await controller.SendMediaAsync(current, SourceMediaAction.PreviousTrack, default)).Kind);
        Equal(12, SnapshotWrites(stream).Length);
        foreach (var task in pending) Equal(SourceMediaResultKind.TimedOut, (await task.WaitAsync(TimeSpan.FromSeconds(8))).Kind);
        Equal(0, controller.PendingCount);

        // Disconnect fences the owner: pending work is stale and no binding remains.
        var beforeDisconnect = controller.SendMediaAsync(current, SourceMediaAction.PlayPause, default);
        await stream.WaitForWritesAsync(13);
        await session.DisconnectAsync(default);
        Equal(SourceMediaResultKind.Stale, (await beforeDisconnect.WaitAsync(TimeSpan.FromSeconds(2))).Kind);
        True(controller.CaptureBinding() is null, "A disconnected session has no source binding.");
    }

    private static async Task SourceVolumeTransportUsesActualMonotonicStateAsync()
    {
        var connected = await ConnectSourceMediaAsync(SourceMediaProtocol.MediaKeysCapability, SourceMediaProtocol.VolumeCapability);
        await using var session = connected.Session;
        var stream = connected.Stream;
        var viewer = new FakeViewerStream();
        using var controller = new ClientSourceMediaController(session, viewer);
        viewer.Set(PeelStreamState.Streaming, 3);
        var binding = controller.CaptureBinding() ?? throw new InvalidOperationException("Missing binding.");
        True(binding.Volume, "The source advertised source-volume-v1.");

        var query = controller.QueryVolumeAsync(binding, SourceVolumeScope.PeelStream, default);
        await stream.WaitForWritesAsync(3);
        var request = DeserializeWrite<SourceVolumeQueryMessage>(stream, 2);
        Equal("peelStream", request.Scope);
        stream.EnqueueRead(SourceState(request.RequestId!, 3, "systemOutput", true, 0.9, false, 10));
        stream.EnqueueRead(SourceState(request.RequestId!, 3, "peelStream", true, 0.4, false, 10));
        True((await query.WaitAsync(TimeSpan.FromSeconds(2))).Volume is
            { Scope: SourceVolumeScope.PeelStream, Supported: true, Volume: 0.4, Muted: false, Sequence: 10 },
            "Only the requested scope's actual state is accepted.");

        var other = controller.QueryVolumeAsync(binding, SourceVolumeScope.SystemOutput, default);
        await stream.WaitForWritesAsync(4);
        var otherRequest = DeserializeWrite<SourceVolumeQueryMessage>(stream, 3);
        Equal("systemOutput", otherRequest.Scope);
        stream.EnqueueRead(SourceState(otherRequest.RequestId!, 3, "systemOutput", true, 0.1, true, 9));
        stream.EnqueueRead(SourceState(otherRequest.RequestId!, 3, "systemOutput", false, null, null, 11));
        True(await other.WaitAsync(TimeSpan.FromSeconds(2)) is
            { Status: SourceMediaStatus.Unsupported, Volume: { Supported: false, Volume: null, Muted: null, Sequence: 11 } },
            "An older sequence is ignored and unsupported state carries no value.");

        var set = controller.SetVolumeAsync(binding, SourceVolumeScope.PeelStream, 0.7, null, default);
        await stream.WaitForWritesAsync(5);
        var setRequest = DeserializeWrite<SourceVolumeSetMessage>(stream, 4);
        True(setRequest.Check().IsValid && setRequest.Volume == 0.7 && setRequest.Muted is null, "A set carries only the changed value.");
        stream.EnqueueRead(SourceAck(setRequest.RequestId!, Fixture.PairingId, 3, "unsupported", "scopeUnsupported"));
        True(await set.WaitAsync(TimeSpan.FromSeconds(2)) is
            { Status: SourceMediaStatus.Unsupported, Reason: SourceMediaReason.ScopeUnsupported },
            "The source's refusal is reported.");
        True(controller.Volume is { Supported: false, Volume: null }, "A requested level is never shown as actual state.");
        Throws<ArgumentOutOfRangeException>(() => controller.SetVolumeAsync(binding, SourceVolumeScope.PeelStream, 1.01, null, default));
        Throws<ArgumentOutOfRangeException>(() => controller.SetVolumeAsync(binding, SourceVolumeScope.PeelStream, null, null, default));
        Equal(5, SnapshotWrites(stream).Length);
    }

    private static async Task DefaultListenIsPlaybackOnlyAndGenerationFencedAsync()
    {
        var stream = new ScriptedDuplexStream();
        var fixture = new Fixture(Candidate("listen-host", "fresh.local", 2222), stream);
        await using var session = new ClientSession(fixture.Transport, fixture.Credentials, fixture.Resolver,
            new("Test", "PC", "Windows", "test"),
            new ClientSessionOptions { SupportsAudioPlayback = true, SupportsMicrophone = true, PingInterval = TimeSpan.FromHours(1) });
        var connect = session.ConnectAsync(fixture.Resolver.Current, default);
        await stream.WaitForWritesAsync(1);
        stream.EnqueueRead(PeelJson.SerializeLine(PeelHello.CreateHost("Mac", capabilities: ["mac-system-audio-v1", "remote-voice-v1"])));
        await connect; await stream.WaitForWritesAsync(2);
        bool microphoneOpened = false;
        await using var audio = new ClientAudioPlayback(session, fixture.Transport, fixture.Credentials, fixture.Resolver,
            () => { microphoneOpened = true; throw new InvalidOperationException("Default Listen must never open a microphone."); });

        long generation = session.SessionGeneration;
        True(!await audio.StartDefaultAsync(generation + 1, default), "A different control generation cannot adopt playback.");
        Equal(2, SnapshotWrites(stream).Length);

        var starting = audio.StartDefaultAsync(generation, default);
        await stream.WaitForWritesAsync(3);
        var request = DeserializeWrite<AudioSessionRequestMessage>(stream, 2);
        True(request.Enabled && request.Mode == "playback", "Default Listen requests playback only, never voice.");
        True(audio.IsActive && !audio.IsPlaying, "Playing requires actual admitted PCM, not a request.");
        // The Host keeps its own consent: unavailable sharing leaves audio off, with the Host's reason.
        stream.EnqueueRead(PeelJson.SerializeLine(new AudioSessionStateMessage(request.RequestId, Fixture.PairingId, "unavailable", "System audio sharing is off.")));
        // The Host refusal and the resulting local cancel race; either way nothing starts.
        Exception? refused = null;
        try { await starting.WaitAsync(TimeSpan.FromSeconds(5)); }
        catch (Exception error) when (error is InvalidOperationException or OperationCanceledException) { refused = error; }
        True(refused is not null, "Unavailable Host sharing never reports a started playback.");
        await WaitUntilAsync(() => !audio.IsActive);
        True(!audio.IsPlaying && !microphoneOpened, "Failure leaves audio and microphone off.");
        True(audio.Status.Contains("System audio sharing is off.", StringComparison.Ordinal), "The Host's reason is shown.");
    }

    private static void ClientAudioPreferencesPreserveExplicitOff()
    {
        string root = Path.Combine(Path.GetTempPath(), "peel-audio-preferences-" + Guid.NewGuid().ToString("N"));
        try
        {
            string path = Path.Combine(root, "audio-preferences.json");
            var store = new ClientAudioPreferenceStore(path);
            True(!store.IsExplicitOff("pair-a"), "Listen defaults on when never chosen.");
            True(store.SetExplicitOff("pair-a", true), "Explicit Off is saved.");
            True(new ClientAudioPreferenceStore(path).IsExplicitOff("pair-a"), "Explicit Off survives relaunch.");
            True(!new ClientAudioPreferenceStore(path).IsExplicitOff("pair-b"), "Off belongs to one pairing.");
            True(store.SetExplicitOff("pair-a", false), "Explicit On is saved.");
            True(!new ClientAudioPreferenceStore(path).IsExplicitOff("pair-a"), "Explicit On clears Off.");

            File.WriteAllText(path, "{not json");
            var unreadable = new ClientAudioPreferenceStore(path);
            True(unreadable.IsExplicitOff("pair-c"), "An unreadable file never turns automatic playback on.");
            True(unreadable.SetExplicitOff("pair-c", false), "An explicit choice replaces unknown state.");
            True(!new ClientAudioPreferenceStore(path).IsExplicitOff("pair-c"), "The explicit choice is saved.");

            var bounded = new ClientAudioPreferenceStore(path);
            for (int index = 0; index < 70; index++) bounded.SetExplicitOff("pair-" + index, true);
            var reloaded = new ClientAudioPreferenceStore(path);
            True(!reloaded.IsExplicitOff("pair-0") && reloaded.IsExplicitOff("pair-69"), "Saved choices are bounded to the newest 64.");
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }

    private static void SourceControlsHideOnlyPresentation()
    {
        var preferences = new SourceControlPreferences();
        using var model = new SourceControlsViewModel(null, preferences);
        True(model.ShowVolumeGroup && model.ShowMediaGroup, "Both groups default to shown.");
        True(!model.CanUseMedia && !model.CanUseVolume && !model.PlayPauseCommand.CanExecute(null) &&
            !model.ToggleMuteCommand.CanExecute(null), "Without a source stream nothing is enabled.");
        True(model.PlayPauseToolTip == model.MediaHint && model.MediaHint.Length != 0, "Disabled controls explain why.");
        True(ClientSourceMediaController.SelectedVolumeScope == SourceVolumeScope.SystemOutput,
            "Volume targets the streamed computer's actual system output, never peelStream or this PC.");

        model.IsVolumeOpen = true;
        True(model.IsVolumeOpen && !model.IsVolumeClosed && model.VolumeHint.Length != 0 && !model.CanSetVolume,
            "The popover opens to explain unavailable volume and offers no local fallback.");
        preferences.ShowVolume = false;
        True(!model.ShowVolumeGroup && !model.IsVolumeOpen && model.ShowMediaGroup, "Hiding volume hides only that group.");
        preferences.ShowMediaControls = false;
        True(!model.ShowMediaGroup, "Hiding media hides that group.");

        Equal("Sent to the streamed computer.", SourceControlsViewModel.Describe(
            new SourceMediaResult(SourceMediaResultKind.Reply, SourceMediaStatus.Applied)));
        Equal("Turn on remote control on the streamed computer to use these controls.", SourceControlsViewModel.Describe(
            new SourceMediaResult(SourceMediaResultKind.Reply, SourceMediaStatus.Denied, SourceMediaReason.ControlOff)));
        Equal("Waiting for the streamed computer to answer earlier presses.", SourceControlsViewModel.Describe(
            new SourceMediaResult(SourceMediaResultKind.Busy)));
    }

    // An old command queued behind the session writer must never be written after its owner's epoch
    // ends, even when the same window ID is closed and reopened; the fresh owner's command is.
    private static async Task SourceMediaFencedCommandNeverLeavesBlockedWriterAsync()
    {
        var hold = new ManualResetEventSlim(false);
        var holding = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        int holdNext = 0;
        var connected = await ConnectSourceMediaAsync(_ => new ScriptedDuplexStream(onWrite: written =>
        {
            if (Interlocked.Exchange(ref holdNext, 0) == 1) { holding.TrySetResult(); hold.Wait(TimeSpan.FromSeconds(5)); }
        }), SourceMediaProtocol.MediaKeysCapability);
        await using var session = connected.Session;
        var stream = connected.Stream;
        var viewer = new FakeViewerStream();
        using var controller = new ClientSourceMediaController(session, viewer);
        viewer.Set(PeelStreamState.Streaming, 5);
        var old = controller.CaptureBinding() ?? throw new InvalidOperationException("Missing binding.");

        // An unrelated control write holds the session writer gate.
        Volatile.Write(ref holdNext, 1);
        var blocker = Task.Run(() => session.RefreshWindowsAsync(default));
        await holding.Task.WaitAsync(TimeSpan.FromSeconds(2));
        var oldSend = controller.SendMediaAsync(old, SourceMediaAction.PlayPause, default);
        await Task.Delay(50);
        True(!oldSend.IsCompleted, "The old command is waiting behind the writer gate.");

        // Close and reopen the same window ID: a new epoch owns window 5 now.
        viewer.Set(PeelStreamState.Stopped, null);
        viewer.Set(PeelStreamState.Streaming, 5);
        Equal(SourceMediaResultKind.Stale, (await oldSend.WaitAsync(TimeSpan.FromSeconds(2))).Kind);
        var fresh = controller.CaptureBinding() ?? throw new InvalidOperationException("Missing binding.");
        True(fresh.Epoch != old.Epoch && fresh.WindowId == old.WindowId, "Same window ID, new owner epoch.");
        var freshSend = controller.SendMediaAsync(fresh, SourceMediaAction.NextTrack, default);

        hold.Set();
        await blocker.WaitAsync(TimeSpan.FromSeconds(2));
        await stream.WaitForWritesAsync(4);
        await Task.Delay(50);
        var commands = SnapshotWrites(stream).Where(w => ReadType(w) == SourceMediaProtocol.CommandType)
            .Select(w => PeelJson.Deserialize<SourceMediaCommandMessage>(TrimLine(w))).ToArray();
        True(commands.Length == 1 && commands[0].Action == "nextTrack" && commands[0].WindowId == 5,
            "Only the fresh owner's command was written; no old bytes followed the gate release.");
        stream.EnqueueRead(SourceAck(commands[0].RequestId!, Fixture.PairingId, 5, "applied"));
        True(await freshSend.WaitAsync(TimeSpan.FromSeconds(2)) is { Kind: SourceMediaResultKind.Reply, Status: SourceMediaStatus.Applied },
            "The fresh command completes normally.");
        True(session.State == PeelConnectionState.Connected, "Fencing never disconnects the session.");
    }

    // A slider gesture belongs to the owner and value captured at gesture time.
    private static async Task SourceVolumeGestureBindsOwnerAndIntendedValueAsync()
    {
        var connected = await ConnectSourceMediaAsync(SourceMediaProtocol.MediaKeysCapability, SourceMediaProtocol.VolumeCapability);
        await using var session = connected.Session;
        var stream = connected.Stream;
        var viewer = new FakeViewerStream();
        using var controller = new ClientSourceMediaController(session, viewer);
        viewer.Set(PeelStreamState.Streaming, 3);
        var time = new ManualDelayTime();
        var model = new SourceControlsViewModel(controller, new SourceControlPreferences(), null, time);

        model.IsVolumeOpen = true;
        await stream.WaitForWritesAsync(3);
        var queryA = DeserializeWrite<SourceVolumeQueryMessage>(stream, 2);
        stream.EnqueueRead(SourceState(queryA.RequestId!, 3, "systemOutput", true, 0.4, false, 20));
        await WaitUntilAsync(() => model.CanSetVolume && model.VolumeSliderValue == 40);

        // Gesture on owner A, then switch to owner B before the delay elapses: nothing reaches B.
        model.VolumeSliderValue = 70;
        Equal(1, time.Pending);
        viewer.Set(PeelStreamState.Streaming, 4);
        time.FireAll();
        await Task.Delay(100);
        Equal(3, SnapshotWrites(stream).Length);

        // Owner B: the intended value survives an intervening actual-state readback before the send.
        model.IsVolumeOpen = false; model.IsVolumeOpen = true;
        await stream.WaitForWritesAsync(4);
        var queryB = DeserializeWrite<SourceVolumeQueryMessage>(stream, 3);
        Equal<uint?>(4, queryB.WindowId);
        stream.EnqueueRead(SourceState(queryB.RequestId!, 4, "systemOutput", true, 0.5, false, 21));
        await WaitUntilAsync(() => model.CanSetVolume && model.VolumeSliderValue == 50);
        model.VolumeSliderValue = 80;
        model.IsVolumeOpen = false; model.IsVolumeOpen = true;
        await stream.WaitForWritesAsync(5);
        var readback = DeserializeWrite<SourceVolumeQueryMessage>(stream, 4);
        stream.EnqueueRead(SourceState(readback.RequestId!, 4, "systemOutput", true, 0.1, false, 22));
        await WaitUntilAsync(() => controller.Volume?.Sequence == 22UL);
        True(model.VolumeSliderValue == 80, "Readback does not replace a gesture that is waiting to be sent.");
        time.FireAll();
        await stream.WaitForWritesAsync(6);
        var set = DeserializeWrite<SourceVolumeSetMessage>(stream, 5);
        True(set.WindowId == 4 && set.Scope == "systemOutput" && set.Volume == 0.8 && set.Muted is null,
            "The captured owner receives the captured intended value.");

        // Dispose cancels a pending commit.
        stream.EnqueueRead(SourceState(set.RequestId!, 4, "systemOutput", true, 0.8, false, 23));
        await WaitUntilAsync(() => controller.Volume?.Sequence == 23UL && model.VolumeSliderValue == 80);
        model.VolumeSliderValue = 20;
        Equal(1, time.Pending);
        model.Dispose();
        time.FireAll();
        await Task.Delay(100);
        Equal(6, SnapshotWrites(stream).Length);
    }

    private static Task<(ClientSession Session, ScriptedDuplexStream Stream)> ConnectSourceMediaAsync(params string[] capabilities) =>
        ConnectSourceMediaAsync(_ => new ScriptedDuplexStream(), capabilities);

    private static async Task<(ClientSession Session, ScriptedDuplexStream Stream)> ConnectSourceMediaAsync(
        Func<object?, ScriptedDuplexStream> createStream, params string[] capabilities)
    {
        var stream = createStream(null);
        var fixture = new Fixture(Candidate("source-host", "fresh.local", 2222), stream);
        var session = new ClientSession(fixture.Transport, fixture.Credentials, fixture.Resolver,
            new("Test", "PC", "Windows", "test"), new ClientSessionOptions { PingInterval = TimeSpan.FromHours(1) });
        var connect = session.ConnectAsync(fixture.Resolver.Current, default);
        await stream.WaitForWritesAsync(1);
        stream.EnqueueRead(PeelJson.SerializeLine(PeelHello.CreateHost("Source", capabilities: capabilities)));
        await connect;
        await stream.WaitForWritesAsync(2);
        return (session, stream);
    }

    private static byte[] SourceAck(string requestId, string pairingId, uint windowId, string status, string? reason = null) =>
        PeelJson.SerializeLine(new SourceMediaAckMessage(requestId, pairingId, windowId, status, reason,
            SourceMediaProtocol.Version, SourceMediaProtocol.AckType));

    private static byte[] SourceState(string requestId, uint windowId, string scope, bool supported, double? volume,
        bool? muted, ulong sequence) =>
        PeelJson.SerializeLine(new SourceVolumeStateMessage(requestId, Fixture.PairingId, windowId, scope, supported,
            supported, supported, volume, muted, sequence, supported ? null : "scopeUnsupported",
            SourceMediaProtocol.Version, SourceMediaProtocol.VolumeStateType));

    // Delays complete only when the test fires them.
    private sealed class ManualDelayTime : TimeProvider
    {
        private readonly List<ManualTimer> timers = [];

        public int Pending { get { lock (timers) return timers.Count(t => !t.Disposed && !t.Fired); } }

        public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
        {
            var timer = new ManualTimer(callback, state);
            lock (timers) timers.Add(timer);
            return timer;
        }

        public void FireAll()
        {
            ManualTimer[] due;
            lock (timers) due = timers.Where(t => !t.Disposed && !t.Fired).ToArray();
            foreach (var timer in due) timer.Fire();
        }

        private sealed class ManualTimer(TimerCallback callback, object? state) : ITimer
        {
            public volatile bool Disposed, Fired;
            public bool Change(TimeSpan dueTime, TimeSpan period) => !Disposed;
            public void Fire() { Fired = true; callback(state); }
            public void Dispose() => Disposed = true;
            public ValueTask DisposeAsync() { Disposed = true; return ValueTask.CompletedTask; }
        }
    }

    private sealed class FakeViewerStream : IStreamControlService
    {
        public event EventHandler<StreamStateChangedEventArgs>? StateChanged;
        public event EventHandler<DecodedVideoFrameEventArgs>? FrameAvailable { add { } remove { } }
        public PeelStreamState State { get; private set; } = PeelStreamState.Stopped;
        public uint? StreamingWindowId { get; private set; }
        public Task StartAsync(RemoteWindowDescriptor window, CancellationToken cancellationToken) => Task.CompletedTask;
        public Task StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;

        public void Set(PeelStreamState state, uint? windowId)
        {
            State = state;
            StreamingWindowId = windowId;
            StateChanged?.Invoke(this, new StreamStateChangedEventArgs(state, null));
        }
    }
}
