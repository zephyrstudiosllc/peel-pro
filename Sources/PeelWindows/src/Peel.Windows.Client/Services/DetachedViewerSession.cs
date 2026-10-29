using Peel.Windows.Client.Models;
using Peel.Windows.Protocol;
using Peel.Windows.Transport;

namespace Peel.Windows.Client.Services;

public sealed class DetachedViewerSession : IAsyncDisposable
{
    private readonly MediaFoundationH264DecoderSink decoder = new(gpuPresentation: true);
    private readonly Action<DetachedViewerSession> onClosed;
    private int disposed;
    public ClientStreamController Streams { get; }
    public ClientInputController Input { get; }
    /// <summary>Source media bound to this window's own stream, never to another viewer's selection.</summary>
    public ClientSourceMediaController SourceMedia { get; }
    public RemoteWindowDescriptor Window { get; }
    public bool IsVisible { get; set; } = true;

    internal DetachedViewerSession(RemoteWindowDescriptor window, ClientSession control,
        IPeelPskTransportFactory transport, IPairedHostCredentialStore credentials,
        IClientHostResolver resolver, Action<DetachedViewerSession> onClosed)
    {
        Window = window; this.onClosed = onClosed;
        var video = new ClientVideoSocketSession(transport, credentials, resolver, decoder);
        Streams = new(control, control, control, video, PeelVideoCodec.H264, preferHevc: true);
        Input = new(control, Streams);
        SourceMedia = new(control, Streams);
    }
    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        IsVisible = false; Input.Dispose(); SourceMedia.Dispose();
        try { await Streams.DisposeAsync().ConfigureAwait(false); }
        finally { await decoder.DisposeAsync().ConfigureAwait(false); onClosed(this); }
    }
}
