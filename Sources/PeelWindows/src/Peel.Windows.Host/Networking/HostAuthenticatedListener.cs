using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using Peel.Windows.Protocol;

namespace Peel.Windows.Host.Networking;

public sealed class HostAuthenticatedListener : IAsyncDisposable
{
    private readonly IPeelPskTransportFactory transportFactory;
    private readonly IPeelPskCredentialResolver credentialResolver;
    private readonly HostControlSessionManager controlSessions;
    private readonly HostVideoSessionManager videoSessions;
    private readonly HostAuthenticatedListenerOptions options;
    private readonly HostAuthenticatedConnectionRouter router;
    private readonly CancellationTokenSource lifetimeCancellation = new();
    private readonly SemaphoreSlim connectionSlots;
    private readonly ConcurrentDictionary<long, Task> activeConnections = new();

    private IPeelPskListener? listener;
    private CancellationTokenRegistration startCancellationRegistration;
    private Task completion = Task.CompletedTask;
    private Exception? fatalConnectionFailure;
    private long nextConnectionId;
    private int started;
    private int disposed;

    public HostAuthenticatedListener(
        IPeelPskTransportFactory transportFactory,
        IPeelPskCredentialResolver credentialResolver,
        HostControlSessionManager controlSessions,
        HostVideoSessionManager videoSessions,
        HostAuthenticatedListenerOptions? options = null)
    {
        this.transportFactory = PeelSecureTransport.Require(transportFactory);
        this.credentialResolver = credentialResolver ??
            throw new ArgumentNullException(nameof(credentialResolver));
        this.controlSessions = controlSessions ??
            throw new ArgumentNullException(nameof(controlSessions));
        this.videoSessions = videoSessions ??
            throw new ArgumentNullException(nameof(videoSessions));
        this.options = options ?? new HostAuthenticatedListenerOptions();
        router = new HostAuthenticatedConnectionRouter(
            controlSessions,
            videoSessions,
            this.options);
        connectionSlots = new SemaphoreSlim(
            this.options.MaximumActiveConnections,
            this.options.MaximumActiveConnections);
    }

    public EndPoint? LocalEndPoint => listener?.LocalEndPoint;

    public Task Completion => completion;

    public async ValueTask StartAsync(
        IPEndPoint endpoint,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(endpoint);
        ObjectDisposedException.ThrowIf(Volatile.Read(ref disposed) != 0, this);
        if (Interlocked.CompareExchange(ref started, 1, 0) != 0)
        {
            throw new InvalidOperationException("The authenticated Host listener was already started.");
        }

        cancellationToken.ThrowIfCancellationRequested();
        IPeelPskListener created = await transportFactory.ListenAsync(
                endpoint,
                credentialResolver,
                cancellationToken)
            .ConfigureAwait(false);
        listener = created;
        if (cancellationToken.CanBeCanceled)
        {
            startCancellationRegistration = cancellationToken.Register(
                static state => ((CancellationTokenSource)state!).Cancel(),
                lifetimeCancellation);
        }

        Task[] workers = Enumerable.Range(0, options.AcceptWorkerCount)
            .Select(_ => RunAcceptWorkerGuardedAsync(created, lifetimeCancellation.Token))
            .ToArray();
        completion = CompleteAsync(workers);
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0)
        {
            return;
        }

        lifetimeCancellation.Cancel();
        IPeelPskListener? activeListener = listener;
        if (activeListener is not null)
        {
            await activeListener.DisposeAsync().ConfigureAwait(false);
        }

        try
        {
            await completion.ConfigureAwait(false);
        }
        catch (Exception exception) when (IsFailSoftConnectionException(exception))
        {
        }

        await videoSessions.DisposeAsync().ConfigureAwait(false);
        await controlSessions.DisposeAsync().ConfigureAwait(false);
        startCancellationRegistration.Dispose();
        connectionSlots.Dispose();
        lifetimeCancellation.Dispose();
    }

    private async Task RunAcceptWorkerGuardedAsync(
        IPeelPskListener activeListener,
        CancellationToken cancellationToken)
    {
        try
        {
            await RunAcceptWorkerAsync(activeListener, cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            lifetimeCancellation.Cancel();
            throw;
        }
    }

    private async Task RunAcceptWorkerAsync(
        IPeelPskListener activeListener,
        CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            PeelPskConnection connection;
            using var handshakeCancellation = CancellationTokenSource.CreateLinkedTokenSource(
                cancellationToken);
            handshakeCancellation.CancelAfter(options.HandshakeTimeout);
            try
            {
                connection = await activeListener.AcceptAsync(handshakeCancellation.Token)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                return;
            }
            catch (SocketException) when (cancellationToken.IsCancellationRequested)
            {
                return;
            }
            catch (OperationCanceledException)
            {
                continue;
            }
            catch (IOException)
            {
                continue;
            }

            if (!connectionSlots.Wait(0))
            {
                await connection.DisposeAsync().ConfigureAwait(false);
                continue;
            }

            long connectionId = checked(Interlocked.Increment(ref nextConnectionId));
            // Established Bouncy Castle TLS reads are not reliably released by token
            // cancellation alone. Closing the accepted transport is the listener's
            // fail-safe for classification and routed-session teardown.
            CancellationTokenRegistration transportAbortRegistration =
                cancellationToken.Register(
                    static state => AbortTransport((PeelPskConnection)state!),
                    connection);
            Task routed = RouteAndReleaseAsync(
                connection,
                cancellationToken,
                transportAbortRegistration);
            activeConnections[connectionId] = routed;
            _ = routed.ContinueWith(
                (completed, state) =>
                {
                    _ = completed;
                    var (connections, id) =
                        ((ConcurrentDictionary<long, Task>, long))state!;
                    connections.TryRemove(id, out Task? _);
                },
                (activeConnections, connectionId),
                CancellationToken.None,
                TaskContinuationOptions.ExecuteSynchronously,
                TaskScheduler.Default);
        }
    }

    private async Task RouteAndReleaseAsync(
        PeelPskConnection connection,
        CancellationToken cancellationToken,
        CancellationTokenRegistration transportAbortRegistration)
    {
        try
        {
            await router.RouteAsync(connection, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception exception) when (IsFailSoftConnectionException(exception))
        {
            // One malformed, stalled, or disconnected authenticated peer never stops
            // the listener or another active Host session.
        }
        catch (Exception exception)
        {
            Interlocked.CompareExchange(ref fatalConnectionFailure, exception, null);
            lifetimeCancellation.Cancel();
            throw;
        }
        finally
        {
            transportAbortRegistration.Dispose();
            connectionSlots.Release();
        }
    }

    private async Task CompleteAsync(Task[] workers)
    {
        try
        {
            await Task.WhenAll(workers).ConfigureAwait(false);
        }
        finally
        {
            lifetimeCancellation.Cancel();
            Task[] sessions = activeConnections.Values.ToArray();
            if (sessions.Length != 0)
            {
                await Task.WhenAll(sessions).ConfigureAwait(false);
            }

            if (Volatile.Read(ref fatalConnectionFailure) is Exception fatalFailure)
            {
                throw new HostAuthenticatedListenerException(
                    "An authenticated Host connection failed outside its fail-soft boundary.",
                    fatalFailure);
            }
        }
    }

    private static bool IsFailSoftConnectionException(Exception exception) =>
        exception is IOException or
            SocketException or
            InvalidDataException or
            JsonException or
            ObjectDisposedException or
            OperationCanceledException or
            InvalidOperationException or
            ArgumentException or
            NotSupportedException or
            OverflowException;

    private static void AbortTransport(PeelPskConnection connection)
    {
        try
        {
            connection.Stream.Dispose();
        }
        catch (Exception exception) when (IsFailSoftConnectionException(exception))
        {
        }
    }

    private sealed class HostAuthenticatedListenerException(
        string message,
        Exception innerException) : Exception(message, innerException);
}
