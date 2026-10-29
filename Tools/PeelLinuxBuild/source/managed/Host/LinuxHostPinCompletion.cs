namespace Peel.Linux.Host;
// One owner for provisional persistence, accepted-response launch and Cancel.
// No default live grant. Caller supplies its exact visible PIN-generation fence.
internal sealed class LinuxHostPinCompletion
{
    private readonly object gate = new();
    private readonly LinuxHostTrust trust;
    private readonly TimeProvider clock;
    private readonly long created;
    private readonly Func<bool> generationCurrent;
    private LinuxHostPeer? provisional;
    private bool cancelled, completed, launched;
    private Task cleanup = Task.CompletedTask;
    private bool cleanupStarted;
    internal LinuxHostPinCompletion(LinuxHostTrust trust, TimeProvider clock, long created, Func<bool> generationCurrent)
    { this.trust = trust; this.clock = clock; this.created = created; this.generationCurrent = generationCurrent; }
    private bool Current => !cancelled && generationCurrent() && clock.GetElapsedTime(created) >= TimeSpan.Zero
        && clock.GetElapsedTime(created) < TimeSpan.FromSeconds(120);
    internal bool Completed { get { lock (gate) return completed; } }
    internal bool Launched { get { lock (gate) return launched; } }
    internal void Prepare(LinuxHostPeer peer)
    {
        lock (gate)
        {
            if (provisional is not null) throw new InvalidOperationException("Only one provisional enrollment is allowed.");
            provisional = peer;
            if (!Current) { DenyLocked(); throw new OperationCanceledException(); }
        }
    }
    // response is already serialized/bounded off GTK. The actual WriteAsync call,
    // not a check before a later async hop, is atomic with cancellation admission.
    internal async Task SendAcceptedAsync(LinuxHostPeer peer, Stream wire, byte[] response, CancellationToken token)
    {
        try
        {
            ValueTask write;
            lock (gate)
            {
                if (response.Length is 0 or > LinuxHostWire.Limit || provisional != peer || completed || launched || !Current || token.IsCancellationRequested)
                { DenyLocked(); throw new OperationCanceledException(); }
                launched = true;
                write = wire.WriteAsync(response, token);
            }
            // Already-launched bytes cannot be unsent. Loss before completion
            // still denies the provisional credential, even if a peer saw them.
            await write.ConfigureAwait(false);
            lock (gate)
            {
                if (!Current || token.IsCancellationRequested) { DenyLocked(); throw new OperationCanceledException(); }
                completed = true; // normal RunAsync finally/Cancel must retain it
            }
        }
        catch { Cancel(); throw; }
    }
    internal void Cancel()
    {
        lock (gate) { cancelled = true; if (!completed) DenyLocked(); }
    }
    private void DenyLocked()
    {
        if (completed || provisional is null) return;
        trust.MarkDenied(provisional.PairingId); // synchronous, no secure-store I/O
        if (cleanupStarted) return;
        cleanupStarted = true; string id = provisional.PairingId;
        // Trust's mutation owner orders tombstone AFTER any in-progress commit.
        // A vault failure remains an owned fault reported by DrainAsync; no claim
        // of durable revocation is made until this actual operation completes.
        cleanup = Task.Run(() => trust.Revoke(id));
    }
    internal Task DrainAsync() { lock (gate) return cleanup; }
}
