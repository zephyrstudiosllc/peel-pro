using System.Net.Sockets;

namespace Peel.Windows.Transport;

internal sealed class OwnedTlsStream : Stream
{
    private readonly Stream inner;
    private readonly TcpClient owner;
    private int disposed;
    private readonly object ioGate = new();
    private int activeIo;

    internal OwnedTlsStream(Stream inner, TcpClient owner)
    {
        this.inner = inner ?? throw new ArgumentNullException(nameof(inner));
        this.owner = owner ?? throw new ArgumentNullException(nameof(owner));
    }

    public override bool CanRead => inner.CanRead;
    public override bool CanSeek => false;
    public override bool CanTimeout => inner.CanTimeout;
    public override bool CanWrite => inner.CanWrite;
    public override long Length => throw new NotSupportedException();

    public override long Position
    {
        get => throw new NotSupportedException();
        set => throw new NotSupportedException();
    }

    public override int ReadTimeout
    {
        get => inner.ReadTimeout;
        set => inner.ReadTimeout = value;
    }

    public override int WriteTimeout
    {
        get => inner.WriteTimeout;
        set => inner.WriteTimeout = value;
    }

    public override void Flush() => inner.Flush();

    public override Task FlushAsync(CancellationToken cancellationToken) =>
        RunIoAsync(inner.Flush, cancellationToken);

    public override int Read(byte[] buffer, int offset, int count) => inner.Read(buffer, offset, count);

    public override int Read(Span<byte> buffer) => inner.Read(buffer);

    public override async ValueTask<int> ReadAsync(
        Memory<byte> buffer,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        BeginIo();
        // Bouncy Castle's TLS stream is synchronous. Start its read off the caller's
        // thread so a pending read cannot prevent that same session from sending hello.
        using var registration = cancellationToken.Register(static state => ((TcpClient)state!).Dispose(), owner);
        try { return await Task.Run(() => inner.Read(buffer.Span), CancellationToken.None).ConfigureAwait(false); }
        catch (Exception) when (cancellationToken.IsCancellationRequested) { throw new OperationCanceledException(cancellationToken); }
        finally { EndIo(); }
    }

    public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
        ReadAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();

    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();

    public override void SetLength(long value) => throw new NotSupportedException();

    public override void Write(byte[] buffer, int offset, int count) => inner.Write(buffer, offset, count);

    public override void Write(ReadOnlySpan<byte> buffer) => inner.Write(buffer);

    public override ValueTask WriteAsync(
        ReadOnlyMemory<byte> buffer,
        CancellationToken cancellationToken = default) =>
        new(RunIoAsync(() => inner.Write(buffer.Span), cancellationToken));

    public override Task WriteAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
        WriteAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();

    private async Task RunIoAsync(Action action, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        BeginIo();
        using var registration = token.Register(static state => ((TcpClient)state!).Dispose(), owner);
        try { await Task.Run(action, CancellationToken.None).ConfigureAwait(false); }
        catch (Exception) when (token.IsCancellationRequested) { throw new OperationCanceledException(token); }
        finally { EndIo(); }
    }

    private void BeginIo()
    {
        lock (ioGate)
        {
            ObjectDisposedException.ThrowIf(disposed != 0, this);
            activeIo++;
        }
    }

    private void EndIo() { lock (ioGate) activeIo--; }

    private void CloseOwnedStream()
    {
        bool abort;
        lock (ioGate)
        {
            if (disposed != 0) return;
            disposed = 1;
            abort = activeIo != 0;
        }
        // A pending synchronous TLS read needs socket closure to unblock. Otherwise
        // preserve close_notify so peers can safely consume final pairing responses.
        if (abort) owner.Dispose();
        try { inner.Dispose(); }
        catch (IOException) when (abort || !owner.Connected) { }
        catch (ObjectDisposedException) { }
        finally { owner.Dispose(); }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) CloseOwnedStream();

        base.Dispose(disposing);
    }

    public override ValueTask DisposeAsync()
    {
        CloseOwnedStream();
        GC.SuppressFinalize(this);
        return ValueTask.CompletedTask;
    }
}
