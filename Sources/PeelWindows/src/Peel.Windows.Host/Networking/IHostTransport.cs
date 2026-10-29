using Peel.Windows.Host.Encoding;
using Peel.Windows.Host.Windows;

namespace Peel.Windows.Host.Networking;

public interface IHostTransport : IAsyncDisposable
{
    ValueTask PublishWindowListAsync(
        IReadOnlyList<WindowDescriptor> windows,
        CancellationToken cancellationToken);

    // Completion is the backpressure boundary: callers must not submit another
    // encoded frame for this stream until the returned ValueTask completes.
    ValueTask SendVideoFrameAsync(
        nint windowHandle,
        EncodedVideoFrame frame,
        CancellationToken cancellationToken);
}
