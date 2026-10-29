using System.Net;
namespace Peel.Linux.Host;
// Root-approved normal policy: actual IPv6Any dual-mode TLS bind; matching
// Avahi unspecified interface/family. No endpoint setup fields in ordinary UI.
internal sealed class LinuxHostBindPlan
{
    private LinuxHostBindPlan() { }
    internal static LinuxHostBindPlan DefaultDualStack() => new();
    internal IPAddress Address => IPAddress.IPv6Any;
    internal int InterfaceIndex => -1;
    internal int AvahiProtocol => -1;
    internal bool DualStack => true;
}
internal sealed record LinuxHostBoundControl(Guid Generation, string HostId, string HostName, string ServiceName,
    string BindAddress, ushort Port, int InterfaceIndex, int AvahiProtocol, bool DualStack, DateTimeOffset ExpiresAt)
{
    internal IPEndPoint EndPoint => new(IPAddress.Parse(BindAddress), Port);
}
internal sealed record LinuxHostBoundPair(Guid Generation, string ServiceName, string BindAddress, ushort Port,
    string SaltBase64, DateTimeOffset ExpiresAt)
{
    internal IPEndPoint EndPoint => new(IPAddress.Parse(BindAddress), Port);
}
internal sealed record LinuxHostDiscoverySnapshot(Guid PublicationId, LinuxHostBoundControl Control, LinuxHostBoundPair? Pair);
// Public discovery metadata is NEVER TLS/media authority. Only backend creates
// this lease after actual successful ListenAsync/LocalEndPoint validation.
internal sealed class LinuxHostDiscoveryLease : IDisposable
{
    internal const string TlsPskOrder = "psk-identity";
    private readonly object gate = new();
    private readonly CancellationTokenSource lifetime;
    private readonly TimeProvider clock;
    private readonly long created;
    private readonly TimeSpan duration;
    private readonly Func<bool> ownerCurrent;
    private bool valid = true, disposed;
    internal Guid Id => Snapshot.PublicationId;
    internal LinuxHostDiscoverySnapshot Snapshot { get; }
    internal CancellationToken Lifetime => lifetime.Token;
    internal LinuxHostDiscoveryLease(LinuxHostDiscoverySnapshot snapshot, TimeProvider clock, TimeSpan duration, Func<bool> ownerCurrent)
    {
        if (snapshot.PublicationId == Guid.Empty || snapshot.Control.Generation == Guid.Empty || snapshot.Control.Port == 0
            || duration <= TimeSpan.Zero || duration > TimeSpan.FromMinutes(30)) throw new ArgumentException("Finite actual bound discovery lease required.");
        if (snapshot.Pair is { } pair && (pair.Generation == Guid.Empty || pair.Port == 0 || pair.Port == snapshot.Control.Port)) throw new ArgumentException("Distinct actual Pair bind required.");
        Snapshot = snapshot; this.clock = clock; this.duration = duration; this.ownerCurrent = ownerCurrent; created = clock.GetTimestamp();
        lifetime = new CancellationTokenSource(duration);
    }
    private bool Current => valid && !disposed && !lifetime.IsCancellationRequested && ownerCurrent()
        && clock.GetElapsedTime(created) >= TimeSpan.Zero && clock.GetElapsedTime(created) < duration;
    internal bool IsCurrent { get { lock (gate) return Current; } }
    // Registrar calls this ON GTK at the actual native/GIO submission boundary,
    // not before queuing a later unguarded callback. Submit must return promptly.
    internal T Admit<T>(Func<LinuxHostDiscoverySnapshot, T> submit)
    { lock (gate) { if (!Current) throw new OperationCanceledException("Discovery owner expired/replaced."); return submit(Snapshot); } }
    internal void Invalidate()
    {
        lock (gate) { if (!valid) return; valid = false; }
        // Registrations must only queue cancellation/cleanup, never block here.
        lifetime.Cancel();
    }
    public void Dispose()
    { Invalidate(); lock (gate) { if (disposed) return; disposed = true; } lifetime.Dispose(); }
}
internal interface ILinuxHostPublishedServices : IAsyncDisposable
{
    Guid PublicationId { get; }
    bool IsEstablished { get; }
    event Action? Lost;
}
internal interface ILinuxHostDiscoveryRegistrar
{
    // Returns ONLY after the exact matching Avahi group is established.
    Task<ILinuxHostPublishedServices> PublishAsync(LinuxHostDiscoveryLease lease, CancellationToken token);
    // Same control generation/name/endpoint ONLY. Transfer native ownership and
    // detach old lifetime handlers only after confirmed transaction success.
    // Failure preserves previous control registration/ownership or reports Lost.
    Task<ILinuxHostPublishedServices> ReplaceAsync(ILinuxHostPublishedServices previous, LinuxHostDiscoveryLease lease, CancellationToken token);
}
internal sealed record LinuxHostUiState(long Revision, bool Initialized, bool Busy, int PairedCount,
    LinuxHostCapture? ReadyCapture, bool IsSharing, bool Discoverable, string Status);
internal interface ILinuxHostUiBackend : IAsyncDisposable
{
    event Action<LinuxHostUiState>? Changed;
    Task InitializeAfterGtkActivationAsync();
    Task PairAsync(CancellationToken token);
    Task ShareAsync(CancellationToken token);
    void CancelPairing();
    void StopHost();
}
