using System.IO;
using Peel.Windows.Client.Models;
using Peel.Windows.Protocol;

namespace Peel.Windows.Client.Services;

/// <summary>Exact owner of one tap: control generation, pairing and the owning viewer's streamed window.</summary>
public sealed record SourceMediaBinding(long Epoch, long Generation, string PairingId, uint WindowId, bool MediaKeys, bool Volume);

/// <summary>Whether this owner has an admitted stream and which source capabilities its session advertised.</summary>
public sealed record SourceMediaAvailability(bool Streaming, bool MediaKeys, bool Volume);

/// <summary>Actual source volume state from the latest valid, monotonic reply. Never an optimistic value.</summary>
public sealed record SourceVolumeReading(SourceVolumeScope Scope, bool Supported, bool CanSetVolume, bool CanSetMute,
    double? Volume, bool? Muted, ulong Sequence, SourceMediaReason? Reason);

public enum SourceMediaResultKind
{
    /// <summary>The source answered this exact request.</summary>
    Reply,
    /// <summary>The owner, stream or connection changed; any late reply is ignored.</summary>
    Stale,
    /// <summary>Eight requests are already waiting for the source.</summary>
    Busy,
    TimedOut,
    /// <summary>No connected session, capability or stream; nothing was sent.</summary>
    Unavailable,
}

public sealed record SourceMediaResult(SourceMediaResultKind Kind, SourceMediaStatus? Status = null,
    SourceMediaReason? Reason = null, SourceVolumeReading? Volume = null)
{
    internal static SourceMediaResult Stale { get; } = new(SourceMediaResultKind.Stale);
    internal static SourceMediaResult Busy { get; } = new(SourceMediaResultKind.Busy);
    internal static SourceMediaResult TimedOut { get; } = new(SourceMediaResultKind.TimedOut);
    internal static SourceMediaResult Unavailable { get; } = new(SourceMediaResultKind.Unavailable);
}

/// <summary>
/// Source media for exactly one viewer (the main viewer or one detached window). It is bound to
/// that viewer's own stream, so a detached window can never act on whichever stream is selected
/// elsewhere. Requests are bounded (8 pending, 3 s), fenced by a local epoch that changes on every
/// connection, stream or window change, and only exact current replies are accepted. Without the
/// source's capability nothing is sent; nothing ever falls back to this PC's volume or media keys.
/// </summary>
public sealed class ClientSourceMediaController : IDisposable
{
    /// <summary>
    /// The source volume scope this client uses: the streamed source computer's actual system output
    /// volume/mute (the root's stated, reversible default). Listen separately controls only this PC's
    /// Peel playback. peelStream is not used; nothing ever changes this PC's own volume.
    /// </summary>
    public static SourceVolumeScope? SelectedVolumeScope => SourceVolumeScope.SystemOutput;

    private readonly ClientSession session;
    private readonly IStreamControlService stream;
    private readonly object gate = new();
    private readonly Dictionary<string, Pending> pending = new(StringComparer.OrdinalIgnoreCase);
    private long epoch;
    private uint? boundWindowId;
    private ulong? lastSequence;
    private SourceVolumeReading? volume;
    private bool disposed;

    public ClientSourceMediaController(ClientSession session, IStreamControlService stream)
    {
        this.session = session ?? throw new ArgumentNullException(nameof(session));
        this.stream = stream ?? throw new ArgumentNullException(nameof(stream));
        session.StateChanged += ConnectionChanged;
        session.SourceMediaReplyReceived += ReplyReceived;
        stream.StateChanged += StreamChanged;
    }

    /// <summary>Raised on any thread when availability or actual volume state changes.</summary>
    public event EventHandler? Changed;

    public long Epoch { get { lock (gate) return epoch; } }

    public SourceVolumeReading? Volume { get { lock (gate) return volume; } }

    internal int PendingCount { get { lock (gate) return pending.Count; } }

    /// <summary>Read-only view for presentation; a tap still captures and fences its own binding.</summary>
    public SourceMediaAvailability Availability
    {
        get
        {
            SourceMediaSessionIdentity? identity = session.SourceMediaIdentity;
            bool streaming = identity is not null && stream.State == PeelStreamState.Streaming &&
                stream.StreamingWindowId is > 0;
            lock (gate) streaming &= !disposed;
            return new(streaming, streaming && identity!.MediaKeys, streaming && identity!.Volume);
        }
    }

    /// <summary>Captures the exact owner at tap time, or null when no admitted stream exists.</summary>
    public SourceMediaBinding? CaptureBinding()
    {
        SourceMediaSessionIdentity? identity = session.SourceMediaIdentity;
        if (identity is null || stream.State != PeelStreamState.Streaming ||
            stream.StreamingWindowId is not uint windowId || windowId == 0) return null;
        Pending[]? fenced = null;
        SourceMediaBinding binding;
        lock (gate)
        {
            if (disposed) return null;
            if (boundWindowId != windowId) { fenced = BumpLocked(); boundWindowId = windowId; }
            binding = new(epoch, identity.Generation, identity.PairingId, windowId, identity.MediaKeys, identity.Volume);
        }
        if (fenced is not null) { CancelTransport(fenced); RaiseChanged(); }
        return binding;
    }

    public Task<SourceMediaResult> SendMediaAsync(SourceMediaBinding binding, SourceMediaAction action, CancellationToken token)
    {
        if (!binding.MediaKeys) return Task.FromResult(SourceMediaResult.Unavailable);
        return SendAsync(binding, PendingKind.Media, null,
            id => SourceMediaCommandMessage.Create(id, binding.PairingId, binding.WindowId, action), token);
    }

    public Task<SourceMediaResult> QueryVolumeAsync(SourceMediaBinding binding, SourceVolumeScope scope, CancellationToken token)
    {
        if (!binding.Volume) return Task.FromResult(SourceMediaResult.Unavailable);
        return SendAsync(binding, PendingKind.VolumeQuery, scope,
            id => SourceVolumeQueryMessage.Create(id, binding.PairingId, binding.WindowId, scope), token);
    }

    public Task<SourceMediaResult> SetVolumeAsync(SourceMediaBinding binding, SourceVolumeScope scope,
        double? level, bool? muted, CancellationToken token)
    {
        if (!binding.Volume) return Task.FromResult(SourceMediaResult.Unavailable);
        // Invalid values are refused here exactly as the source would; never clamped.
        if (level is null && muted is null || level is { } value && !SourceMediaProtocol.IsVolume(value))
            throw new ArgumentOutOfRangeException(nameof(level), "Volume must be a finite value from 0 to 1.");
        return SendAsync(binding, PendingKind.VolumeSet, scope,
            id => SourceVolumeSetMessage.Create(id, binding.PairingId, binding.WindowId, scope, level, muted), token);
    }

    private async Task<SourceMediaResult> SendAsync<TMessage>(SourceMediaBinding binding, PendingKind kind,
        SourceVolumeScope? scope, Func<Guid, TMessage> create, CancellationToken token)
    {
        Guid requestId = Guid.NewGuid();
        string id = requestId.ToString("D").ToUpperInvariant();
        var entry = new Pending(binding, kind, scope);
        lock (gate)
        {
            if (disposed || binding.Epoch != epoch) return SourceMediaResult.Stale;
            if (pending.Count >= SourceMediaProtocol.ClientMaximumPending) return SourceMediaResult.Busy;
            pending.Add(id, entry);
        }
        try
        {
            // The owner's transport token reaches the writer-gate wait itself, and the final check
            // runs with that gate held: a request fenced by a newer epoch never leaves this PC.
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token, entry.Transport.Token);
            deadline.CancelAfter(SourceMediaProtocol.ClientTimeout);
            await session.SendClientMessageAsync(create(requestId), binding.Generation, deadline.Token,
                () => IsCurrent(id, entry)).ConfigureAwait(false);
            return await entry.Completion.Task.WaitAsync(deadline.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested)
        {
            if (entry.Completion.Task.IsCompletedSuccessfully) return entry.Completion.Task.Result;
            return session.SourceMediaIdentity?.Generation == binding.Generation && Epoch == binding.Epoch
                ? SourceMediaResult.TimedOut
                : SourceMediaResult.Stale;
        }
        catch (Exception exception) when (exception is InvalidOperationException or IOException or ObjectDisposedException)
        {
            return SourceMediaResult.Stale;
        }
        finally
        {
            lock (gate)
            {
                if (pending.TryGetValue(id, out Pending? current) && ReferenceEquals(current, entry)) pending.Remove(id);
            }
        }
    }

    private bool IsCurrent(string id, Pending entry)
    {
        lock (gate)
        {
            return !disposed && entry.Binding.Epoch == epoch && !entry.Transport.IsCancellationRequested &&
                pending.TryGetValue(id, out Pending? current) && ReferenceEquals(current, entry);
        }
    }

    private void ReplyReceived(object? sender, SourceMediaReply reply)
    {
        bool changed = false;
        lock (gate)
        {
            if (disposed) return;
            string? requestId = reply.Ack?.RequestId ?? reply.VolumeState?.RequestId;
            // Unsolicited state updates are not part of v1; late or foreign replies are ignored.
            if (requestId is null || !pending.TryGetValue(requestId, out Pending? entry) ||
                entry.Binding.Epoch != epoch || entry.Binding.Generation != reply.Generation) return;
            string? pairingId = reply.Ack?.PairingId ?? reply.VolumeState?.PairingId;
            uint? windowId = reply.Ack?.WindowId ?? reply.VolumeState?.WindowId;
            if (!StringComparer.Ordinal.Equals(pairingId, entry.Binding.PairingId) || windowId != entry.Binding.WindowId) return;

            if (reply.Ack is { } ack)
            {
                if (!ack.TryParse(out SourceMediaStatus status, out SourceMediaReason? reason)) return;
                entry.Completion.TrySetResult(new(SourceMediaResultKind.Reply, status, reason));
            }
            else if (reply.VolumeState is { } state)
            {
                if (entry.Kind == PendingKind.Media ||
                    !SourceMediaProtocol.TryParseScope(state.Scope, out SourceVolumeScope scope) || scope != entry.Scope) return;
                ulong sequence = state.Sequence!.Value;
                if (lastSequence is { } last && sequence <= last) return;
                lastSequence = sequence;
                SourceMediaReason? reason = SourceMediaProtocol.TryParseReason(state.Reason, out var parsed) ? parsed : null;
                bool supported = state.Supported == true;
                volume = new(scope, supported, supported && state.CanSetVolume == true, supported && state.CanSetMute == true,
                    supported ? state.Volume : null, supported ? state.Muted : null, sequence, reason);
                entry.Completion.TrySetResult(new(SourceMediaResultKind.Reply,
                    supported ? SourceMediaStatus.Applied : SourceMediaStatus.Unsupported, reason, volume));
                changed = true;
            }
        }
        if (changed) RaiseChanged();
    }

    private void ConnectionChanged(object? sender, ConnectionStateChangedEventArgs e) => Invalidate(clearWindow: true);

    // Fires once per decoded frame while streaming: the unchanged case must stay a cheap no-op.
    private void StreamChanged(object? sender, StreamStateChangedEventArgs e)
    {
        uint? windowId = e.State == PeelStreamState.Streaming ? stream.StreamingWindowId : null;
        bool changed;
        Pending[] fenced;
        lock (gate)
        {
            if (disposed || windowId is not null && windowId == boundWindowId) return;
            changed = boundWindowId is not null || windowId is not null || pending.Count != 0;
            fenced = BumpLocked();
            boundWindowId = windowId;
        }
        CancelTransport(fenced);
        if (changed) RaiseChanged();
    }

    private void Invalidate(bool clearWindow)
    {
        Pending[] fenced;
        lock (gate)
        {
            if (disposed) return;
            fenced = BumpLocked();
            if (clearWindow) boundWindowId = null;
        }
        CancelTransport(fenced);
        RaiseChanged();
    }

    /// <summary>New epoch: every pending request is answered stale and returned for transport cancellation.</summary>
    private Pending[] BumpLocked()
    {
        epoch++;
        Pending[] fenced = [.. pending.Values];
        foreach (Pending entry in fenced) entry.Completion.TrySetResult(SourceMediaResult.Stale);
        pending.Clear();
        volume = null;
        lastSequence = null;
        return fenced;
    }

    // Outside the gate: cancellation callbacks (writer-gate waiters, deadlines) never run under it.
    private static void CancelTransport(Pending[] fenced)
    {
        foreach (Pending entry in fenced)
        {
            try { entry.Transport.Cancel(); }
            catch (AggregateException) { }
        }
    }

    private void RaiseChanged()
    {
        try { Changed?.Invoke(this, EventArgs.Empty); }
        catch (InvalidOperationException) { }
    }

    public void Dispose()
    {
        Pending[] fenced;
        lock (gate)
        {
            if (disposed) return;
            fenced = BumpLocked();
            boundWindowId = null;
            disposed = true;
        }
        CancelTransport(fenced);
        session.StateChanged -= ConnectionChanged;
        session.SourceMediaReplyReceived -= ReplyReceived;
        stream.StateChanged -= StreamChanged;
    }

    private enum PendingKind { Media, VolumeQuery, VolumeSet }

    private sealed class Pending(SourceMediaBinding binding, PendingKind kind, SourceVolumeScope? scope)
    {
        internal SourceMediaBinding Binding { get; } = binding;
        internal PendingKind Kind { get; } = kind;
        internal SourceVolumeScope? Scope { get; } = scope;
        internal TaskCompletionSource<SourceMediaResult> Completion { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        // Cancelled when the owner's epoch ends; never disposed, so a late Cancel cannot throw.
        internal CancellationTokenSource Transport { get; } = new();
    }
}
