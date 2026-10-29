using Peel.Windows.Protocol;
namespace Peel.Linux;

/// <summary>What one viewer toolbar shows; only actual states, mapped 1:1 to PeelViewerState.</summary>
internal sealed record ViewerSnapshot(int Audio, bool ListenEnabled, bool MediaEnabled, SourceVolumeView Volume, string Note);

/// <summary>The exact stream a viewer callback belonged to, captured on the GTK thread.</summary>
internal readonly record struct ViewerBinding(uint Window, ulong Epoch);

/// <summary>Per-connection receiver media coordinator. Default Listen starts once the first
/// valid video of the current stream is admitted, when the native backend was ready, the
/// source offers playback audio and this pairing has no explicit Off. Explicit Off persists
/// per pairing; explicit On clears it. Lifecycle stops (stream end, disconnect, error) never
/// write Off. Every admitted stream gets a new epoch, even when the same window ID reopens.
/// Viewer commands carry the window+epoch captured at callback time through one bounded
/// serialized queue, and act only if that exact binding is still current.</summary>
internal sealed class LinuxReceiverControls : IAsyncDisposable
{
    internal const int AudioUnavailable = 0, AudioOff = 1, AudioIdle = 2, AudioStarting = 3, AudioPlaying = 4, AudioFailed = 5;
    internal const int ListenOn = 1, ListenOff = 2, PlayPause = 3, Previous = 4, Next = 5, VolumeQuery = 6, VolumeSet = 7, MuteSet = 8, Shown = 11;
    internal const int MaximumQueuedCommands = 32;
    private readonly object gate = new();
    private readonly string pairingId;
    private readonly LinuxReceiverAudio? audio;
    private readonly bool sourceOffersAudio;
    private readonly LinuxSourceMediaClient media;
    private readonly LinuxReceiverPreferences preferences;
    private readonly Action<uint, ViewerSnapshot> publish;
    private ViewerBinding? current;
    private Task queue = Task.CompletedTask;
    private int queued;
    private bool disposed;

    /// <param name="audio">null when the native playback backend was not ready at connect.</param>
    internal LinuxReceiverControls(string pairingId, LinuxReceiverAudio? audio, bool sourceOffersAudio, LinuxSourceMediaClient media,
        LinuxReceiverPreferences preferences, Action<uint, ViewerSnapshot> publish)
    {
        this.pairingId = pairingId; this.audio = audio; this.sourceOffersAudio = sourceOffersAudio; this.media = media;
        this.preferences = preferences; this.publish = publish;
        if (audio is not null) audio.Changed += Publish;
        media.Changed += Publish;
    }

    internal uint? Window { get { lock (gate) return current?.Window; } }
    /// <summary>Completes when every command queued so far has run (tests and teardown).</summary>
    internal Task Idle { get { lock (gate) return queue; } }
    private bool CanListen => audio is not null && sourceOffersAudio;
    private bool IsCurrent(ViewerBinding binding) { lock (gate) return !disposed && current == binding; }

    /// <summary>First access unit of a newly configured stream was accepted by the native decoder.
    /// Always a new stream epoch, so clicks captured for any earlier stream of this ID go stale.</summary>
    internal Task VideoAdmittedAsync(uint admitted)
    {
        ViewerBinding binding;
        lock (gate)
        {
            if (disposed) return Task.CompletedTask;
            binding = new(admitted, media.BeginStream(admitted));
            current = binding;
        }
        Publish();
        // Read actual source volume once the controls are current (sends nothing unless offered).
        var query = media.QueryVolumeAsync(binding.Window, binding.Epoch);
        var listen = CanListen && !preferences.IsAudioOff(pairingId) ? StartListeningAsync(binding) : Task.CompletedTask;
        return Task.WhenAll(query, listen);
    }

    /// <summary>The last (only) stream closed or failed: stop audio this stream owned.</summary>
    internal async Task StreamEndedAsync()
    {
        lock (gate) { if (current is null) return; current = null; media.EndStream(); }
        if (audio is not null) await audio.StopAsync().ConfigureAwait(false);
    }

    /// <summary>GTK thread: binds a viewer callback to the stream it belongs to right now, or nothing.</summary>
    internal ViewerBinding? Capture(uint window)
    {
        lock (gate) return !disposed && current is { } binding && binding.Window == window ? binding : null;
    }

    /// <summary>GTK thread: queues one captured command behind earlier ones. Bounded; never blocks.</summary>
    internal bool Enqueue(ViewerBinding binding, int command, double value)
    {
        lock (gate)
        {
            if (disposed || queued >= MaximumQueuedCommands) return false;
            queued++;
            queue = queue.ContinueWith(async _ =>
            {
                try { await CommandAsync(binding, command, value).ConfigureAwait(false); }
                finally { lock (gate) queued--; }
            }, CancellationToken.None, TaskContinuationOptions.None, TaskScheduler.Default).Unwrap();
            return true;
        }
    }

    internal async Task CommandAsync(ViewerBinding binding, int command, double value)
    {
        if (!IsCurrent(binding)) return; // closed, replaced or reopened since the click
        switch (command)
        {
            case ListenOn:
                if (!CanListen) break;
                preferences.SetAudioOff(pairingId, false);
                await StartListeningAsync(binding).ConfigureAwait(false);
                break;
            case ListenOff:
                if (audio is null) break;
                preferences.SetAudioOff(pairingId, true);
                await audio.StopAsync().ConfigureAwait(false);
                break;
            case PlayPause: await media.SendMediaAsync(binding.Window, binding.Epoch, SourceMediaAction.PlayPause).ConfigureAwait(false); break;
            case Previous: await media.SendMediaAsync(binding.Window, binding.Epoch, SourceMediaAction.PreviousTrack).ConfigureAwait(false); break;
            case Next: await media.SendMediaAsync(binding.Window, binding.Epoch, SourceMediaAction.NextTrack).ConfigureAwait(false); break;
            case VolumeQuery or Shown: await media.QueryVolumeAsync(binding.Window, binding.Epoch).ConfigureAwait(false); break;
            case VolumeSet when double.IsFinite(value) && value is >= 0 and <= 1: await media.SetVolumeAsync(binding.Window, binding.Epoch, value, null).ConfigureAwait(false); break;
            case MuteSet when value is 0 or 1: await media.SetVolumeAsync(binding.Window, binding.Epoch, null, value == 1).ConfigureAwait(false); break;
            default: return;
        }
        Publish();
    }

    /// <summary>Starts this connection's playback only for a still-current stream; if every stream
    /// ended while starting, stops it again. A newer stream of the same connection keeps it.</summary>
    private async Task StartListeningAsync(ViewerBinding binding)
    {
        if (!IsCurrent(binding)) return;
        await audio!.StartAsync().ConfigureAwait(false);
        bool ended; lock (gate) ended = disposed || current is null;
        if (ended) await audio.StopAsync().ConfigureAwait(false);
    }

    internal ViewerSnapshot Compose()
    {
        bool shown; lock (gate) shown = current is not null;
        int state; string note;
        if (audio is null) { state = AudioUnavailable; note = "Audio playback isn't available: no working audio output was found on this computer."; }
        else if (!sourceOffersAudio) { state = AudioUnavailable; note = "This source doesn't share audio with this computer."; }
        else
        {
            var (phase, status) = audio.Snapshot;
            state = phase switch
            {
                ReceiverAudioPhase.Starting => AudioStarting,
                ReceiverAudioPhase.Playing => AudioPlaying,
                ReceiverAudioPhase.Failed => AudioFailed,
                _ => preferences.IsAudioOff(pairingId) ? AudioOff : AudioIdle,
            };
            note = state == AudioOff ? "Listen is off for this computer." : status;
        }
        // The latest source-control answer follows the audio line until the stream changes.
        if (media.Note is { } latest) note = string.IsNullOrEmpty(note) ? latest : note + " · " + latest;
        return new(state, shown && CanListen, shown && media.MediaAvailable, media.Volume, note);
    }

    private void Publish()
    {
        uint? target; lock (gate) { if (disposed) return; target = current?.Window; }
        if (target is { } shown) publish(shown, Compose());
    }

    public async ValueTask DisposeAsync()
    {
        Task pendingCommands;
        lock (gate) { disposed = true; current = null; pendingCommands = queue; }
        await pendingCommands.ContinueWith(static _ => { }, TaskScheduler.Default).ConfigureAwait(false);
        media.Changed -= Publish;
        if (audio is not null) { audio.Changed -= Publish; await audio.DisposeAsync().ConfigureAwait(false); }
        media.Dispose();
    }
}
