namespace Peel.Windows.Host.Audio;

/// <summary>Session-only consent and a process-wide capture lease, shared across Host reconnects.</summary>
public sealed class HostAudioSharing
{
    private readonly object sync = new();
    private readonly Func<IHostAudioCapture> factory;
    private CancellationTokenSource permission = new();
    private bool enabled, reserved;
    private string status = "System audio sharing is off.";
    public HostAudioSharing() : this(WindowsLoopbackAudioCapture.Available, () => new WindowsLoopbackAudioCapture()) { }
    internal HostAudioSharing(bool supported, Func<IHostAudioCapture> factory)
    { Supported = supported; this.factory = factory; permission.Cancel(); }
    public bool Supported { get; }
    public bool Enabled { get { lock (sync) return enabled; } }
    public string Status { get { lock (sync) return status; } }
    internal CancellationToken Permission { get { lock (sync) return permission.Token; } }
    public void SetEnabled(bool value)
    {
        CancellationTokenSource previous;
        lock (sync)
        {
            value &= Supported;
            if (value == enabled) return;
            previous = permission; permission = new(); enabled = value;
            if (!value) permission.Cancel();
            status = value ? "Ready to share this PC's system audio with a paired client." : "System audio sharing is off.";
        }
        previous.Cancel(); previous.Dispose();
    }
    internal IHostAudioCapture? TryReserve(CancellationToken consent)
    {
        lock (sync)
        {
            if (!enabled || consent.IsCancellationRequested || consent != permission.Token || reserved) return null;
            reserved = true;
            try { return new CaptureLease(factory(), this); }
            catch { reserved = false; throw; }
        }
    }
    internal void SetStatus(string value, CancellationToken consent)
    { lock (sync) if (enabled && consent == permission.Token && !consent.IsCancellationRequested) status = value; }
    private sealed class CaptureLease(IHostAudioCapture inner, HostAudioSharing owner) : IHostAudioCapture
    {
        private readonly SemaphoreSlim disposal = new(1, 1);
        private bool disposed;
        public Task Completion => inner.Completion;
        public ValueTask StartAsync(Action<Peel.Windows.Protocol.AudioPacket> onPacket, CancellationToken token) => inner.StartAsync(onPacket, token);
        public async ValueTask DisposeAsync()
        {
            await disposal.WaitAsync().ConfigureAwait(false);
            try
            {
                if (disposed) return;
                // A failed stop keeps the lease reserved: a replacement must never overlap capture.
                await inner.DisposeAsync().ConfigureAwait(false);
                disposed = true;
                lock (owner.sync) owner.reserved = false;
            }
            finally { disposal.Release(); }
        }
    }
}
