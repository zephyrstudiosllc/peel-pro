namespace Peel.Windows.Client.Services;

internal sealed class LatestDecodedFrameMailbox
{
    private readonly object _gate = new();
    private DecodedVideoFrame? _pendingFrame;
    private bool _presentationScheduled;
    private bool _closed;

    internal bool Publish(DecodedVideoFrame frame)
    {
        ArgumentNullException.ThrowIfNull(frame);
        lock (_gate)
        {
            if (_closed) return false;
            var owned = frame.Retain();
            _pendingFrame?.Diagnostics?.Record(Peel.Windows.Host.Diagnostics.StreamStage.ReplacedDecoded);
            _pendingFrame?.Dispose();
            _pendingFrame = owned;
            if (_presentationScheduled)
            {
                return false;
            }

            _presentationScheduled = true;
            return true;
        }
    }

    internal DecodedVideoFrame? TakeLatest()
    {
        lock (_gate)
        {
            DecodedVideoFrame? frame = _pendingFrame;
            _pendingFrame = null;
            return frame;
        }
    }

    internal bool CompletePresentation()
    {
        lock (_gate)
        {
            if (_pendingFrame is not null)
            {
                return true;
            }

            _presentationScheduled = false;
            return false;
        }
    }

    internal void Reset()
    {
        lock (_gate)
        {
            _pendingFrame?.Dispose();
            _pendingFrame = null;
            _presentationScheduled = false;
        }
    }
    internal void Close()
    {
        lock (_gate) { _closed = true; Reset(); }
    }
}
