using System.Diagnostics;
using Peel.Windows.Protocol;

namespace Peel.Windows.Host.Diagnostics;

public enum StreamStage { Captured, Submitted, Encoded, Sent, Received, Decoded, Presented, ReplacedRaw, ReplacedDecoded, PresentationSkipped }
public sealed record StageReading(string Stage, long TotalEvents, long TotalBytes, double EventsPerSecond, double MegabitsPerSecond,
    double WindowSeconds, double? MeanCallMilliseconds, double? P95CallMilliseconds, double? LastEventAgeSeconds);
public sealed record StreamReading(Guid Generation, string Role, uint WindowId, bool Active, int Width, int Height, string Codec,
    string Path, int? TargetFps, int? TargetBitrate, IReadOnlyList<StageReading> Stages);
public sealed record PeerReceiverReading(bool CapabilityNegotiated, double? ReportAgeSeconds, bool Stale, ClientStreamMetricsMessage? Report);
public sealed record StreamingDiagnosticsSnapshot(int SchemaVersion, bool Enabled, DateTimeOffset SampledAt, IReadOnlyList<StreamReading> Streams,
    PeerReceiverReading PeerReceiver, string MeasurementNotes);

/// <summary>Opt-in process-local counters. No content, peer identities, window titles or file paths.</summary>
public sealed class StreamDiagnostics
{
    public static StreamDiagnostics Shared { get; } = new();
    private readonly object sync = new();
    private readonly Dictionary<Guid, Entry> streams = [];
    private readonly Func<double> uptime;
    private bool enabled;
    private Guid? peerSession;
    private bool peerNegotiated;
    private ulong peerSequence;
    private double? peerAt;
    private ClientStreamMetricsMessage? peerReport;
    public StreamDiagnostics() : this(() => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency) { }
    internal StreamDiagnostics(Func<double> uptime) => this.uptime = uptime;
    public bool Enabled { get { lock (sync) return enabled; } }
    public void SetEnabled(bool value)
    {
        lock (sync)
        {
            if (value == enabled) return;
            enabled = value; double now = uptime();
            foreach (var row in streams.Values) { row.Counters.Clear(); row.Started = now; }
            peerReport = null; // Keep connection replay/cadence guards when toggling observation.
        }
    }
    public Lease? Begin(string role, uint windowId, string codec, int? targetFps = null, int? targetBitrate = null)
    {
        lock (sync)
        {
            if (streams.Count >= 32)
            {
                var retired = streams.FirstOrDefault(x => !x.Value.Active);
                if (retired.Value is null) return null;
                streams.Remove(retired.Key);
            }
            Guid id = Guid.NewGuid(); streams[id] = new(role, windowId, codec, targetFps, targetBitrate, uptime());
            return new(this, id);
        }
    }
    public StreamingDiagnosticsSnapshot Snapshot()
    {
        lock (sync)
        {
            double now = uptime(); double? age = peerReport is null || peerAt is null ? null : Math.Max(0, now - peerAt.Value);
            return new(1, enabled, DateTimeOffset.UtcNow, enabled ? streams.Select(x => x.Value.Read(x.Key, now)).ToArray() : [],
                new(peerNegotiated, age, age is null or > 10, enabled ? peerReport : null),
                "Rates cover up to five seconds; bytes count encoded payload only. Codec call duration is not per-frame end-to-end latency. WPF presentation means an accepted viewer update, not physical scanout. Apple receiver observations are peer-reported. Client and Host uptime clocks cannot measure one-way latency.");
        }
    }
    internal void SetPeerSession(Guid session, bool negotiated)
    {
        lock (sync)
        {
            if (peerSession != session) { peerSequence = 0; peerAt = null; peerReport = null; }
            peerSession = session; peerNegotiated = negotiated;
            if (!negotiated) peerReport = null;
        }
    }
    internal bool RefreshPeerSession(Guid session, bool negotiated)
    {
        lock (sync)
        {
            // Only initial negotiation binds ownership. A late old refresh must
            // not replace the collector's current session or replay guards.
            if (peerSession != session) return false;
            peerNegotiated = negotiated;
            if (!negotiated) peerReport = null;
            return true;
        }
    }
    internal void ClearPeer(Guid session, bool end = false)
    {
        lock (sync) if (peerSession == session) { peerReport = null; if (end) { peerSession = null; peerNegotiated = false; } }
    }
    internal bool AcceptPeer(Guid session, ClientStreamMetricsMessage message)
    {
        if (!message.IsValid) return false;
        lock (sync)
        {
            double now = uptime();
            if (!enabled || !peerNegotiated || peerSession != session || message.Sequence <= peerSequence || peerAt is { } previous && now - previous < 1) return false;
            peerSequence = message.Sequence; peerAt = now; peerReport = message; return true;
        }
    }
    public sealed class Lease : IDisposable
    {
        private readonly StreamDiagnostics owner;
        private readonly Guid id;
        internal Lease(StreamDiagnostics owner, Guid id) { this.owner = owner; this.id = id; }
        public void Configure(int width, int height, string path)
        {
            lock (owner.sync) if (owner.streams.TryGetValue(id, out var row) && row.Active)
            { row.Width = width; row.Height = height; row.Path = path.Length <= 80 ? path : path[..80]; }
        }
        public void Record(StreamStage stage, long bytes = 0, double? callMilliseconds = null)
        {
            lock (owner.sync)
            {
                if (!owner.enabled || bytes < 0 || callMilliseconds is { } ms && (!double.IsFinite(ms) || ms < 0) || !Enum.IsDefined(stage) ||
                    !owner.streams.TryGetValue(id, out var row) || !row.Active) return;
                if (!row.Counters.TryGetValue(stage, out var counter)) row.Counters[stage] = counter = new();
                counter.Count = Math.Min(9_000_000_000_000, counter.Count + 1); counter.Bytes = Math.Min(9_000_000_000_000, counter.Bytes + Math.Min(bytes, 9_000_000_000_000));
                double now = owner.uptime(); counter.Samples.Enqueue(new(now, bytes, callMilliseconds));
                while (counter.Samples.Count > 1024 || counter.Samples.Count > 1 && now - counter.Samples.Peek().At > 5) counter.Samples.Dequeue();
            }
        }
        public void Dispose() { lock (owner.sync) if (owner.streams.TryGetValue(id, out var row)) row.Active = false; }
    }
    private sealed class Entry(string role, uint window, string codec, int? targetFps, int? targetBitrate, double started)
    {
        internal bool Active = true;
        internal int Width, Height;
        internal string Path = "Waiting for configuration";
        internal double Started = started;
        internal readonly Dictionary<StreamStage, Counter> Counters = [];
        internal StreamReading Read(Guid id, double now)
        {
            return new(id, role, window, Active, Width, Height, codec, Path, targetFps, targetBitrate, Counters.Select(x =>
            {
                var samples = x.Value.Samples.Where(s => now - s.At <= 5).ToArray();
                double seconds = Math.Clamp(now - Started, .001, 5);
                int skip = 0;
                if (samples.Length == 1024 && now - samples[0].At < seconds)
                { seconds = Math.Max(.001, now - samples[0].At); skip = 1; }
                var times = samples.Where(s => s.CallMilliseconds is not null).Select(s => s.CallMilliseconds!.Value).Order().ToArray();
                return new StageReading(x.Key.ToString(), x.Value.Count, x.Value.Bytes, (samples.Length - skip) / seconds,
                    samples.Skip(skip).Sum(s => (double)s.Bytes) * 8 / seconds / 1_000_000, seconds, times.Length == 0 ? null : times.Average(),
                    times.Length == 0 ? null : times[(int)Math.Ceiling(times.Length * .95) - 1], x.Value.Samples.Count == 0 ? null : Math.Max(0, now - x.Value.Samples.Last().At));
            }).ToArray());
        }
    }
    private readonly record struct Sample(double At, long Bytes, double? CallMilliseconds);
    private sealed class Counter { internal long Count, Bytes; internal readonly Queue<Sample> Samples = new(); }
}
