using System.Text.Json;
using Peel.Windows.Client.Services;
using Peel.Windows.Protocol;
namespace Peel.Linux;

/// <summary>Receiving-side source volume scope adapter. Root's stated default
/// (work/peel248-media-controls/volume-implementation-choice.md) is systemOutput: the
/// streamed SOURCE computer's actual output volume/mute. Listen is separate and only
/// controls playback here. Nothing is enabled unless the source ALSO advertises
/// source-volume-v1, and there is never a receiver-volume or other-scope fallback.
/// Set this to null to disable source volume entirely.</summary>
internal static class LinuxSourceVolumeScope
{
    internal static SourceVolumeScope? Selected => SourceVolumeScope.SystemOutput;
}

/// <summary>Actual source volume state only; never an optimistic echo of a request.</summary>
internal sealed record SourceVolumeView(bool Supported, bool CanSetVolume, bool CanSetMute, double? Volume, bool? Muted)
{
    internal static readonly SourceVolumeView Unsupported = new(false, false, false, null, null);
}

/// <summary>The seam the source-media client needs; ClientSession implements it.
/// <paramref name="token"/> must cancel the writer wait; <paramref name="stillOwned"/>
/// is rechecked after that wait, immediately before writing.</summary>
internal interface ISourceMediaChannel
{
    bool HostSupports(string capability);
    event EventHandler<SourceMediaReplyEventArgs>? SourceMediaReplyReceived;
    Task SendSourceMediaAsync<T>(T message, long generation, Func<bool> stillOwned, CancellationToken token);
}

/// <summary>Source media v1 requests bound to one control generation, its captured pairing
/// and one stream epoch. Every stream admission (even a reopened same window ID) begins a
/// new epoch; ending or replacing it cancels the old epoch's queued sends, drops its pending
/// records and ignores its late replies. At most 8 pending, each expiring after 3 s. One
/// volume set is in flight, owned by its requestId and epoch; only that owner may release
/// the slot and pump the latest coalesced value. Commands act only on the source.</summary>
internal sealed class LinuxSourceMediaClient : IDisposable
{
    private enum Kind { Media, Query, Set }

    private sealed class Pending(Kind kind, uint window, ulong epoch, string label)
    {
        internal Kind Kind { get; } = kind;
        internal uint Window { get; } = window;
        internal ulong Epoch { get; } = epoch;
        internal string Label { get; } = label;
        internal ITimer? Timer { get; set; }
    }

    private readonly ISourceMediaChannel channel;
    private readonly long generation;
    private readonly string pairingId;
    private readonly SourceVolumeScope? volumeScope;
    private readonly bool usable;
    private readonly TimeSpan timeout;
    private readonly TimeProvider time;
    private readonly object gate = new();
    private readonly Dictionary<string, Pending> pending = new(StringComparer.Ordinal);
    private CancellationTokenSource epochCancellation = new();
    private ulong epoch;
    private uint currentWindow;
    private SourceVolumeView volume = SourceVolumeView.Unsupported;
    private ulong? lastSequence;
    private string? note;
    private double? desiredVolume;
    private bool? desiredMuted;
    private string? setOwner;
    private bool disposed;

    internal LinuxSourceMediaClient(ISourceMediaChannel channel, long generation, string pairingId, SourceVolumeScope? volumeScope,
        TimeSpan? timeout = null, TimeProvider? time = null)
    {
        // A pairing the wire cannot carry leaves the controls honestly unavailable.
        usable = SourceMediaProtocol.IsPairingId(pairingId);
        this.channel = channel; this.generation = generation; this.pairingId = pairingId;
        this.volumeScope = volumeScope is { } scope && Enum.IsDefined(scope) ? scope : null;
        this.timeout = timeout ?? SourceMediaProtocol.ClientTimeout; this.time = time ?? TimeProvider.System;
        channel.SourceMediaReplyReceived += OnReply;
    }

    internal event Action? Changed;
    internal bool MediaAvailable => usable && channel.HostSupports(SourceMediaProtocol.MediaKeysCapability);
    internal bool VolumeOffered => usable && volumeScope is not null && channel.HostSupports(SourceMediaProtocol.VolumeCapability);
    internal SourceVolumeView Volume { get { bool offered = VolumeOffered; lock (gate) return offered ? volume : SourceVolumeView.Unsupported; } }
    internal string? Note { get { lock (gate) return note; } }
    internal int PendingCount { get { lock (gate) return pending.Count; } }
    internal ulong StreamEpoch { get { lock (gate) return epoch; } }

    /// <summary>A newly admitted stream (same window ID or not): fresh epoch, old work cancelled.</summary>
    internal ulong BeginStream(uint window) => Advance(window);

    /// <summary>Stream closure: the old epoch is cancelled and nothing is current.</summary>
    internal void EndStream() => Advance(0);

    private ulong Advance(uint window)
    {
        CancellationTokenSource old; ulong current;
        lock (gate)
        {
            old = epochCancellation;
            epochCancellation = new CancellationTokenSource();
            current = ++epoch; currentWindow = window;
            foreach (var entry in pending.Values) entry.Timer?.Dispose();
            pending.Clear(); setOwner = null; desiredVolume = null; desiredMuted = null; note = null;
            volume = SourceVolumeView.Unsupported; lastSequence = null;
        }
        old.Cancel(); // Old sends still waiting for the writer abandon it; their owner checks also fail.
        Raise();
        return current;
    }

    /// <summary>Exact binding check: this window is the current stream of this exact epoch.</summary>
    private bool BoundLocked(uint window, ulong expected) => !disposed && window != 0 && window == currentWindow && expected == epoch;

    internal Task<bool> SendMediaAsync(uint window, ulong streamEpoch, SourceMediaAction action)
    {
        if (!Enum.IsDefined(action)) throw new ArgumentOutOfRangeException(nameof(action));
        lock (gate) if (!BoundLocked(window, streamEpoch)) return Task.FromResult(false);
        if (!MediaAvailable) { SetNote("The source computer doesn't offer media keys."); return Task.FromResult(false); }
        var message = SourceMediaCommandMessage.Create(Guid.NewGuid(), pairingId, window, action);
        string label = action switch { SourceMediaAction.PlayPause => "Play/pause", SourceMediaAction.PreviousTrack => "Previous track", _ => "Next track" };
        return SendAsync(message.RequestId!, new Pending(Kind.Media, window, streamEpoch, label), message);
    }

    /// <summary>Read-only; sent when the controls become current or the popover opens. Never without an offered scope.</summary>
    internal Task<bool> QueryVolumeAsync(uint window, ulong streamEpoch)
    {
        if (!VolumeOffered || volumeScope is not { } scope) return Task.FromResult(false);
        lock (gate) if (!BoundLocked(window, streamEpoch) || pending.Values.Any(p => p.Kind == Kind.Query)) return Task.FromResult(false);
        var message = SourceVolumeQueryMessage.Create(Guid.NewGuid(), pairingId, window, scope);
        return SendAsync(message.RequestId!, new Pending(Kind.Query, window, streamEpoch, "Volume"), message);
    }

    /// <summary>Invalid values are refused, never clamped. Latest value wins while one set is in flight.</summary>
    internal Task SetVolumeAsync(uint window, ulong streamEpoch, double? value, bool? muted)
    {
        if (value is null && muted is null || value is { } v && !SourceMediaProtocol.IsVolume(v)) return Task.CompletedTask;
        if (!VolumeOffered) { SetNote("The source computer doesn't offer volume control."); return Task.CompletedTask; }
        lock (gate)
        {
            if (!BoundLocked(window, streamEpoch)) return Task.CompletedTask;
            desiredVolume = value ?? desiredVolume; desiredMuted = muted ?? desiredMuted;
        }
        return PumpSetAsync();
    }

    private async Task PumpSetAsync()
    {
        SourceVolumeSetMessage message; uint window; ulong owned; string id;
        lock (gate)
        {
            if (disposed || setOwner is not null || volumeScope is not { } scope || currentWindow == 0 || desiredVolume is null && desiredMuted is null) return;
            window = currentWindow; owned = epoch;
            message = SourceVolumeSetMessage.Create(Guid.NewGuid(), pairingId, window, scope, desiredVolume, desiredMuted);
            id = message.RequestId!;
            desiredVolume = null; desiredMuted = null; setOwner = id;
        }
        // A refused send (pending limit) releases the slot only if this request still owns it.
        if (!await SendAsync(id, new Pending(Kind.Set, window, owned, "Volume"), message).ConfigureAwait(false))
            lock (gate) if (setOwner == id && !pending.ContainsKey(id)) setOwner = null;
    }

    private async Task<bool> SendAsync<T>(string id, Pending entry, T message)
    {
        bool full; CancellationToken stream;
        lock (gate)
        {
            if (!BoundLocked(entry.Window, entry.Epoch)) return false;
            stream = epochCancellation.Token;
            full = pending.Count >= SourceMediaProtocol.ClientMaximumPending;
            if (full) note = "Waiting for the source computer to answer earlier requests.";
            else
            {
                pending.Add(id, entry);
                entry.Timer = time.CreateTimer(_ => Complete(id, entry.Epoch, "The source computer didn't answer."), null, timeout, Timeout.InfiniteTimeSpan);
            }
        }
        if (full) { Raise(); return false; }
        try
        {
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(stream);
            linked.CancelAfter(timeout);
            await channel.SendSourceMediaAsync(message, generation, () => Owns(id, entry.Epoch), linked.Token).ConfigureAwait(false);
            return true;
        }
        catch (Exception error) when (error is IOException or OperationCanceledException or ObjectDisposedException or InvalidOperationException)
        {
            // A cancelled epoch already dropped this record, so this is a no-op for it.
            Complete(id, entry.Epoch, "The source computer couldn't be reached.");
            return false;
        }
    }

    private bool Owns(string id, ulong owned)
    {
        lock (gate) return !disposed && owned == epoch && pending.TryGetValue(id, out var entry) && entry.Epoch == owned;
    }

    private void OnReply(object? sender, SourceMediaReplyEventArgs e)
    {
        if (e.Generation != generation) return;
        try
        {
            if (e.Type == SourceMediaProtocol.AckType)
            {
                var ack = PeelJson.Deserialize<SourceMediaAckMessage>(e.Utf8);
                if (!ack.TryParse(out var status, out var reason) || ack.PairingId != pairingId) return;
                string id = ack.RequestId!;
                Pending? entry;
                lock (gate) entry = pending.TryGetValue(id, out var found) && found.Window == ack.WindowId && found.Epoch == epoch ? found : null;
                if (entry is null) return;
                // Only an explicit unsupported answer disables volume; transient refusals keep the last actual state.
                if (entry.Kind is Kind.Query or Kind.Set && status == SourceMediaStatus.Unsupported)
                    lock (gate) if (entry.Epoch == epoch) volume = SourceVolumeView.Unsupported;
                Complete(id, entry.Epoch, Describe(entry, status, reason));
                // An applied set is checked against the source's actual state, never assumed.
                if (entry.Kind == Kind.Set && status == SourceMediaStatus.Applied) _ = QueryVolumeAsync(entry.Window, entry.Epoch);
            }
            else if (e.Type == SourceMediaProtocol.VolumeStateType)
            {
                var state = PeelJson.Deserialize<SourceVolumeStateMessage>(e.Utf8);
                if (!state.IsValid || state.PairingId != pairingId || !SourceMediaProtocol.TryParseScope(state.Scope, out var scope) || scope != volumeScope) return;
                bool supported = state.Supported == true;
                ulong answeredEpoch;
                lock (gate)
                {
                    bool matches = state.RequestId is { } requested
                        ? pending.TryGetValue(requested, out var entry) && entry.Window == state.WindowId && entry.Epoch == epoch
                        : currentWindow != 0 && state.WindowId == currentWindow;
                    if (!matches) return;
                    answeredEpoch = epoch;
                    // Monotonic per source process: an older state never overwrites a newer one.
                    if (lastSequence is not { } seen || state.Sequence > seen)
                    {
                        lastSequence = state.Sequence;
                        volume = new(supported, supported && state.CanSetVolume == true, supported && state.CanSetMute == true,
                            supported ? state.Volume : null, supported ? state.Muted : null);
                    }
                }
                if (state.RequestId is { } answered)
                    Complete(answered, answeredEpoch, supported ? null : "The source computer doesn't offer that volume control.");
                else Raise();
            }
        }
        catch (Exception error) when (error is JsonException or InvalidDataException) { /* Dropped; its request expires. */ }
    }

    /// <summary>Only the exact pending record of this epoch completes; only the set slot's owner releases it and pumps.</summary>
    private void Complete(string id, ulong owned, string? message)
    {
        bool pump;
        lock (gate)
        {
            if (!pending.TryGetValue(id, out var entry) || entry.Epoch != owned || owned != epoch) return;
            pending.Remove(id);
            entry.Timer?.Dispose();
            if (message is not null) note = message;
            pump = entry.Kind == Kind.Set && setOwner == id;
            if (pump) setOwner = null;
        }
        Raise();
        if (pump) _ = PumpSetAsync();
    }

    private static string Describe(Pending entry, SourceMediaStatus status, SourceMediaReason? reason) => (status, reason) switch
    {
        (SourceMediaStatus.Applied, _) when entry.Kind == Kind.Media => entry.Label + " sent to the source computer.",
        (SourceMediaStatus.Applied, _) => "The source computer applied the change.",
        (_, SourceMediaReason.ControlOff) => "The source computer has remote control turned off.",
        (_, SourceMediaReason.NotVisible) => "The source computer isn't accepting controls right now.",
        (_, SourceMediaReason.Locked) => "The source computer is locked.",
        (_, SourceMediaReason.AccessibilityMissing) => "The source computer hasn't allowed Peel to send media keys.",
        (_, SourceMediaReason.RateLimited) => "Too many requests. Try again in a moment.",
        (_, SourceMediaReason.StaleStream) or (SourceMediaStatus.Stale, _) => "That stream is no longer current.",
        (_, SourceMediaReason.ScopeUnsupported) => "The source computer doesn't offer that volume control.",
        (_, SourceMediaReason.FixedVolume) => "The source's audio output has a fixed volume.",
        (_, SourceMediaReason.NoOutputDevice) => "The source computer has no audio output device.",
        (_, SourceMediaReason.OsRefused) or (SourceMediaStatus.Failed, _) => "The source computer couldn't apply that.",
        (SourceMediaStatus.Unsupported, _) => "The source computer doesn't support that.",
        _ => "The source computer refused that request.",
    };

    private void SetNote(string text) { lock (gate) note = text; Raise(); }
    private void Raise() => Changed?.Invoke();

    public void Dispose()
    {
        channel.SourceMediaReplyReceived -= OnReply;
        CancellationTokenSource cancellation;
        lock (gate)
        {
            disposed = true; epoch++; currentWindow = 0; setOwner = null;
            foreach (var entry in pending.Values) entry.Timer?.Dispose();
            pending.Clear();
            cancellation = epochCancellation;
        }
        cancellation.Cancel(); // Queued sends abandon the writer wait.
    }
}
