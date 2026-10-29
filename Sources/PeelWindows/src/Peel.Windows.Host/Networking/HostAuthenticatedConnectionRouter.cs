using System.Text.Json;
using Peel.Windows.Protocol;

namespace Peel.Windows.Host.Networking;

internal sealed class HostAuthenticatedConnectionRouter
{
    private const int ReadBufferBytes = 4 * 1024;

    private readonly Func<PeelPskConnection, CancellationToken, Task> runControlSession;
    private readonly Func<PeelPskConnection, CancellationToken, Task> runVideoSession;
    private readonly Func<PeelPskConnection, CancellationToken, Task>? runAudioSession;
    private readonly HostAuthenticatedListenerOptions options;

    internal HostAuthenticatedConnectionRouter(
        HostControlSessionManager controlSessions,
        HostVideoSessionManager videoSessions,
        HostAuthenticatedListenerOptions options)
        : this(
            controlSessions.RunAuthenticatedSessionAsync,
            videoSessions.RunAuthenticatedVideoSessionAsync,
            options,
            controlSessions.RunAuthenticatedAudioSessionAsync)
    {
    }

    internal HostAuthenticatedConnectionRouter(
        Func<PeelPskConnection, CancellationToken, Task> runControlSession,
        Func<PeelPskConnection, CancellationToken, Task> runVideoSession,
        HostAuthenticatedListenerOptions options,
        Func<PeelPskConnection, CancellationToken, Task>? runAudioSession = null)
    {
        this.runControlSession = runControlSession ??
            throw new ArgumentNullException(nameof(runControlSession));
        this.runVideoSession = runVideoSession ??
            throw new ArgumentNullException(nameof(runVideoSession));
        this.options = options ?? throw new ArgumentNullException(nameof(options));
        this.runAudioSession = runAudioSession;
    }

    internal async Task RouteAsync(
        PeelPskConnection connection,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(connection);
        bool ownershipTransferred = false;
        try
        {
            ClassifiedPrefix classified = await ReadClassifiedPrefixAsync(
                    connection.Stream,
                    cancellationToken)
                .ConfigureAwait(false);
            var replay = new PrefixReplayStream(classified.Bytes, connection.Stream);
            var routedConnection = new PeelPskConnection(replay, connection.PeerIdentity);
            Task session;
            try
            {
                session = classified.Envelope.Type == "audioStreamHello" && runAudioSession is not null
                    ? runAudioSession(routedConnection, cancellationToken)
                    : StringComparer.Ordinal.Equals(
                        classified.Envelope.Type,
                        PeelMessageType.VideoStreamHello)
                    ? runVideoSession(routedConnection, cancellationToken)
                    : runControlSession(routedConnection, cancellationToken);
                ownershipTransferred = true;
            }
            catch
            {
                await routedConnection.DisposeAsync().ConfigureAwait(false);
                throw;
            }

            await session.ConfigureAwait(false);
        }
        finally
        {
            if (!ownershipTransferred)
            {
                await connection.DisposeAsync().ConfigureAwait(false);
            }
        }
    }

    private async ValueTask<ClassifiedPrefix> ReadClassifiedPrefixAsync(
        Stream stream,
        CancellationToken cancellationToken)
    {
        using var timeoutCancellation = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken);
        timeoutCancellation.CancelAfter(options.ClassificationTimeout);
        var reader = new BoundedNdjsonLineReader(options.MaximumClassificationLineBytes);
        using var prefix = new MemoryStream();
        var readBuffer = new byte[ReadBufferBytes];

        while (true)
        {
            int byteCount = await stream.ReadAsync(
                    readBuffer,
                    timeoutCancellation.Token)
                .ConfigureAwait(false);
            if (byteCount == 0)
            {
                throw new InvalidDataException(
                    "The authenticated connection ended before its first message.");
            }

            prefix.Write(readBuffer, 0, byteCount);
            bool hasLine = reader.TryAppend(
                readBuffer.AsSpan(0, byteCount),
                out _,
                out ReadOnlyMemory<byte> line);
            if (!hasLine)
            {
                continue;
            }

            if (line.IsEmpty)
            {
                throw new InvalidDataException(
                    "The authenticated connection began with an empty message.");
            }

            MessageEnvelope envelope = PeelJson.ReadEnvelope(line.Span);
            return new ClassifiedPrefix(prefix.ToArray(), envelope);
        }
    }

    private sealed record ClassifiedPrefix(byte[] Bytes, MessageEnvelope Envelope);
}

internal sealed class PrefixReplayStream : Stream
{
    private readonly Stream inner;
    private readonly byte[] prefix;
    private int prefixOffset;
    private int disposed;

    internal PrefixReplayStream(byte[] prefix, Stream inner)
    {
        this.prefix = prefix?.ToArray() ?? throw new ArgumentNullException(nameof(prefix));
        this.inner = inner ?? throw new ArgumentNullException(nameof(inner));
    }

    public override bool CanRead => inner.CanRead;

    public override bool CanSeek => false;

    public override bool CanWrite => inner.CanWrite;

    public override long Length => throw new NotSupportedException();

    public override long Position
    {
        get => throw new NotSupportedException();
        set => throw new NotSupportedException();
    }

    public override void Flush() => inner.Flush();

    public override Task FlushAsync(CancellationToken cancellationToken) =>
        inner.FlushAsync(cancellationToken);

    public override int Read(byte[] buffer, int offset, int count)
    {
        int replayed = ReadPrefix(buffer.AsSpan(offset, count));
        return replayed != 0 ? replayed : inner.Read(buffer, offset, count);
    }

    public override int Read(Span<byte> buffer)
    {
        int replayed = ReadPrefix(buffer);
        return replayed != 0 ? replayed : inner.Read(buffer);
    }

    public override async ValueTask<int> ReadAsync(
        Memory<byte> buffer,
        CancellationToken cancellationToken = default)
    {
        int replayed = ReadPrefix(buffer.Span);
        return replayed != 0
            ? replayed
            : await inner.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
    }

    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();

    public override void SetLength(long value) => throw new NotSupportedException();

    public override void Write(byte[] buffer, int offset, int count) =>
        inner.Write(buffer, offset, count);

    public override void Write(ReadOnlySpan<byte> buffer) => inner.Write(buffer);

    public override ValueTask WriteAsync(
        ReadOnlyMemory<byte> buffer,
        CancellationToken cancellationToken = default) =>
        inner.WriteAsync(buffer, cancellationToken);

    protected override void Dispose(bool disposing)
    {
        if (disposing && Interlocked.Exchange(ref disposed, 1) == 0)
        {
            inner.Dispose();
        }

        base.Dispose(disposing);
    }

    public override async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) == 0)
        {
            await inner.DisposeAsync().ConfigureAwait(false);
        }

        GC.SuppressFinalize(this);
    }

    private int ReadPrefix(Span<byte> destination)
    {
        int available = prefix.Length - prefixOffset;
        int byteCount = Math.Min(available, destination.Length);
        if (byteCount == 0)
        {
            return 0;
        }

        prefix.AsSpan(prefixOffset, byteCount).CopyTo(destination);
        prefixOffset += byteCount;
        return byteCount;
    }
}
