namespace Peel.Linux.Host;
internal sealed record LinuxHostCapture(ulong Generation, uint SourceId, uint Width, uint Height, uint Kind)
{
    internal bool Ready => Generation != 0 && SourceId == 1 && Width is > 0 and <= 8192 && Height is > 0 and <= 8192 && (ulong)Width * Height <= 33_554_432;
}
internal sealed class LinuxHostControl
{
    internal Guid Generation { get; } = Guid.NewGuid();
    internal LinuxHostPeerLease Peer { get; }
    internal Stream Stream { get; }
    internal CancellationTokenSource Lifetime { get; } = new();
    internal LinuxHostReservation? Reservation;
    internal bool Visible = true;
    internal LinuxHostControl(LinuxHostPeerLease peer, Stream stream) { Peer = peer; Stream = stream; }
}
internal sealed class LinuxHostReservation
{
    internal Guid Operation { get; } = Guid.NewGuid();
    internal LinuxHostControl Control { get; }
    internal LinuxHostCapture Capture { get; }
    internal Guid SourceInstance { get; }
    internal long Created { get; }
    internal bool Consumed, Closed;
    internal Stream? Video;
    internal ulong Encoder;
    internal CancellationTokenSource Lifetime { get; } = new();
    internal Action? DropQueued;
    internal LinuxHostReservation(LinuxHostControl control, LinuxHostCapture capture, Guid sourceInstance, long created)
    { Control = control; Capture = capture; SourceInstance = sourceInstance; Created = created; }
}
// Authority is process-local; never accepts a client-supplied "ticket". A video
// hello consumes the one reservation created by the current control startStream.
internal sealed class LinuxHostAuthority
{
    private readonly object gate = new();
    private readonly TimeProvider clock;
    private LinuxHostCapture? capture;
    private Guid sourceInstance;
    private LinuxHostControl? control;
    private bool enabled, controlEnabled;
    private long enabledAt, controlAt;
    internal LinuxHostAuthority(TimeProvider? clock = null) { this.clock = clock ?? TimeProvider.System; }
    internal void UpdateCapture(LinuxHostCapture? next)
    {
        lock (gate)
        {
            if (next == capture) return;
            CloseReservation(control?.Reservation); enabled = false; capture = next is { Ready: true } ? next : null; sourceInstance = Guid.NewGuid();
        }
    }
    internal LinuxHostCapture? Capture { get { lock (gate) return capture; } }
    internal Guid SourceInstance { get { lock (gate) return sourceInstance; } }
    internal long Timestamp => clock.GetTimestamp();
    internal void EnableControl(long consentStart)
    {
        lock (gate)
        {
            if (controlEnabled || clock.GetElapsedTime(consentStart) < TimeSpan.Zero || clock.GetElapsedTime(consentStart) >= TimeSpan.FromMinutes(30)) throw new InvalidOperationException("Fresh explicit control presence required.");
            controlEnabled = true; controlAt = consentStart;
        }
    }
    private bool ControlEnabled => controlEnabled && clock.GetElapsedTime(controlAt) >= TimeSpan.Zero && clock.GetElapsedTime(controlAt) < TimeSpan.FromMinutes(30);
    internal void Enable(LinuxHostCapture expected, Guid expectedInstance, long consentStart)
    {
        lock (gate)
        {
            if (!ControlEnabled || capture is not { Ready: true } || capture != expected || sourceInstance != expectedInstance || enabled
                || clock.GetElapsedTime(consentStart) < TimeSpan.Zero || clock.GetElapsedTime(consentStart) >= TimeSpan.FromMinutes(30)) throw new InvalidOperationException("Fresh consent for the exact current portal source is required.");
            enabled = true; enabledAt = consentStart;
        }
    }
    private bool Enabled => ControlEnabled && enabled && capture is { Ready: true } && clock.GetElapsedTime(enabledAt) < TimeSpan.FromMinutes(30);
    internal bool IsEnabled { get { lock (gate) return Enabled; } }
    internal LinuxHostCapture? SharedCapture { get { lock (gate) return Enabled ? capture : null; } }
    internal LinuxHostControl AdmitControl(LinuxHostPeerLease peer, Stream stream)
    {
        lock (gate)
        {
            if (!ControlEnabled || !peer.IsCurrent) throw new InvalidDataException("Current inbound pairing and explicit control presence required.");
            CloseControl(); control = new(peer, stream); return control;
        }
    }
    private bool Current(LinuxHostControl c) => ControlEnabled && ReferenceEquals(control, c) && !c.Lifetime.IsCancellationRequested && c.Peer.IsCurrent;
    private bool Current(LinuxHostReservation r) => Enabled && Current(r.Control) && r.Control.Visible && ReferenceEquals(r.Control.Reservation, r) && !r.Closed
        && r.SourceInstance == sourceInstance && r.Capture == capture && !r.Lifetime.IsCancellationRequested;
    internal bool IsCurrent(LinuxHostControl c) { lock (gate) return Current(c); }
    internal bool IsCurrent(LinuxHostReservation r) { lock (gate) return Current(r); }
    internal LinuxHostReservation StartStream(LinuxHostControl c, uint window)
    {
        lock (gate)
        {
            if (!Enabled || !Current(c) || !c.Visible || window != 1 || capture is null) throw new InvalidDataException("No current shared source.");
            if (c.Reservation is { Closed: false } existing)
            {
                if (!existing.Consumed) return existing; // Coalesce duplicate pending starts.
                // Explicit recovery after attachment retires the entire old video
                // epoch. Static content then starts a NEW encoder with real PTS.
                CloseReservation(existing);
            }
            return c.Reservation = new(c, capture, sourceInstance, clock.GetTimestamp());
        }
    }
    internal LinuxHostReservation AttachVideo(LinuxHostPeerLease peer, uint window, Stream stream)
    {
        lock (gate)
        {
            var r = control?.Reservation;
            if (r is null || !Current(r) || !peer.IsCurrent || peer.Peer != r.Control.Peer.Peer || window != 1 || r.Consumed
                || clock.GetElapsedTime(r.Created) >= TimeSpan.FromSeconds(5)) throw new InvalidDataException("No current unconsumed video reservation.");
            r.Consumed = true; r.Video = stream; return r;
        }
    }
    internal void BindEncoder(LinuxHostReservation r, ulong encoder, Action drop)
    {
        lock (gate) { if (!Current(r) || !r.Consumed || encoder == 0 || r.Encoder != 0) throw new InvalidDataException(); r.Encoder = encoder; r.DropQueued = drop; }
    }
    // Launching WriteAsync happens under the same lock as stop/revoke. No lock is
    // held over network I/O; loss closes admission and schedules transport abort.
    internal ValueTask Dispatch(LinuxHostReservation r, ReadOnlyMemory<byte> bytes, CancellationToken token, Func<Func<ValueTask>, ValueTask> outputAdmission)
    { lock (gate) { if (!Current(r) || r.Encoder == 0 || r.Video is null) throw new OperationCanceledException(); return outputAdmission(() => r.Video.WriteAsync(bytes, token)); } }
    internal ValueTask Dispatch(LinuxHostControl c, ReadOnlyMemory<byte> bytes, CancellationToken token)
    { lock (gate) { if (!Current(c)) throw new OperationCanceledException(); return c.Stream.WriteAsync(bytes, token); } }
    internal void SetVisibility(LinuxHostControl c, bool visible)
    { lock (gate) { if (!Current(c)) throw new OperationCanceledException(); c.Visible = visible; if (!visible) CloseReservation(c.Reservation); } }
    internal void StopStream(LinuxHostControl c, uint window)
    { lock (gate) { if (!Current(c) || window != 1) throw new InvalidDataException(); CloseReservation(c.Reservation); } }
    internal void EndVideo(LinuxHostReservation r) { lock (gate) CloseReservation(r); }
    internal void EndControl(LinuxHostControl c) { lock (gate) { if (ReferenceEquals(c, control)) CloseControl(); } }
    internal void Revoke(string pairing) { lock (gate) { if (control?.Peer.Peer.PairingId == pairing) CloseControl(); } }
    internal void Stop() { lock (gate) { controlEnabled = false; enabled = false; CloseControl(); } }
    private void CloseControl()
    {
        var old = control; control = null;
        if (old is null) return;
        CloseReservation(old.Reservation); CancelAndAbort(old.Lifetime, old.Stream);
    }
    private static void CloseReservation(LinuxHostReservation? r)
    {
        if (r is null || r.Closed) return;
        r.Closed = true; r.DropQueued?.Invoke(); CancelAndAbort(r.Lifetime, r.Video);
    }
    private static void CancelAndAbort(CancellationTokenSource lifetime, Stream? stream)
    {
        // Cancellation registrations may dispose a TLS stream. Never execute them
        // on GTK: authority/queue are already synchronously closed at this point.
        _ = Task.Run(() => { lifetime.Cancel(); try { stream?.Dispose(); } catch (IOException) { } });
    }
}
