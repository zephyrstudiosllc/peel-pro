using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using Peel.Windows.Protocol;
using Peel.Windows.Transport;

namespace Peel.Windows.Transport.Tests;

internal static class Program
{
    private static readonly TimeSpan TestTimeout = TimeSpan.FromSeconds(10);

    public static async Task<int> Main()
    {
        var tests = new (string Name, Func<Task> Run)[]
        {
            ("security profile rejects invalid credentials", SecurityProfileRejectsInvalidCredentialsAsync),
            ("authenticated loopback is bidirectional", AuthenticatedLoopbackIsBidirectionalAsync),
            ("wrong PSK is rejected", WrongPskIsRejectedAsync),
            ("unknown identity is rejected", UnknownIdentityIsRejectedAsync),
            ("stalled client handshake cancels", StalledClientHandshakeCancelsAsync),
            ("stalled server handshake cancels", StalledServerHandshakeCancelsAsync),
            ("listener disposal unblocks accept", ListenerDisposalUnblocksAcceptAsync),
            ("pending established read permits hello and cancels", EstablishedReadPermitsWriteAndCancelsAsync),
        };

        try
        {
            foreach (var test in tests)
            {
                await test.Run();
                Console.WriteLine($"PASS {test.Name}");
            }

            Console.WriteLine($"{tests.Length}/{tests.Length} transport tests passed");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine($"FAIL transport: {exception}");
            return 1;
        }
    }

    private static async Task SecurityProfileRejectsInvalidCredentialsAsync()
    {
        var factory = new BouncyCastlePskTransportFactory();
        var unreachable = new DnsEndPoint(IPAddress.Loopback.ToString(), 1);

        await ThrowsAsync<ArgumentException>(() => factory
            .ConnectAsync(
                unreachable,
                new PeelPskCredential(NewIdentity(), RandomNumberGenerator.GetBytes(31)))
            .AsTask());

        await ThrowsAsync<ArgumentException>(() => factory
            .ConnectAsync(
                unreachable,
                new PeelPskCredential($"{NewIdentity()}\0suffix", NewKey()))
            .AsTask());

        await ThrowsAsync<ArgumentException>(() => factory
            .ConnectAsync(
                unreachable,
                new PeelPskCredential(new string('a', 1_025), NewKey()))
            .AsTask());

        Equal(0x00A8, PeelPskSecurityProfile.CipherSuite);
    }

    private static async Task EstablishedReadPermitsWriteAndCancelsAsync()
    {
        var credential = new PeelPskCredential(NewIdentity(), NewKey());
        var factory = new BouncyCastlePskTransportFactory();
        await using var listener = await factory.ListenAsync(new IPEndPoint(IPAddress.Loopback, 0), new SingleCredentialResolver(credential));
        using var timeout = new CancellationTokenSource(TestTimeout);
        var accept = listener.AcceptAsync(timeout.Token).AsTask();
        await using var client = await factory.ConnectAsync(ToDnsEndPoint(listener.LocalEndPoint), credential, timeout.Token);
        await using var server = await accept;
        using var readCancellation = new CancellationTokenSource();
        var beginRead = Task.Run(() => client.ReadAsync(new byte[1].AsMemory(), readCancellation.Token));
        // The invocation itself must return while no data is available. This is the
        // control client's read-before-hello order, not a write-before-read fixture.
        var pendingRead = await beginRead.WaitAsync(TimeSpan.FromSeconds(2));
        var payload = "hello-first"u8.ToArray();
        await client.WriteAsync(payload, timeout.Token);
        EqualBytes(payload, await ReadExactlyAsync(server.Stream, payload.Length, timeout.Token));
        readCancellation.Cancel();
        await ThrowsAsync<OperationCanceledException>(() => pendingRead.AsTask().WaitAsync(TimeSpan.FromSeconds(2)));
        var dispose = Task.Run(() => client.Dispose());
        await dispose.WaitAsync(TimeSpan.FromSeconds(2));
    }

    private static async Task AuthenticatedLoopbackIsBidirectionalAsync()
    {
        var identity = NewIdentity();
        var credential = new PeelPskCredential(identity, NewKey());
        var factory = new BouncyCastlePskTransportFactory();

        await using var listener = await factory.ListenAsync(
            new IPEndPoint(IPAddress.Loopback, 0),
            new SingleCredentialResolver(credential));
        using var timeout = new CancellationTokenSource(TestTimeout);

        var acceptTask = listener.AcceptAsync(timeout.Token).AsTask();
        var connectTask = factory.ConnectAsync(
            ToDnsEndPoint(listener.LocalEndPoint),
            credential,
            timeout.Token).AsTask();

        await using var client = await connectTask;
        await using var server = await acceptTask;
        Equal(identity, server.PeerIdentity);

        var clientPayload = RandomNumberGenerator.GetBytes(4_097);
        await client.WriteAsync(clientPayload, timeout.Token);
        await client.FlushAsync(timeout.Token);
        var serverReceived = await ReadExactlyAsync(server.Stream, clientPayload.Length, timeout.Token);
        EqualBytes(clientPayload, serverReceived);

        var serverPayload = RandomNumberGenerator.GetBytes(8_193);
        await server.Stream.WriteAsync(serverPayload, timeout.Token);
        await server.Stream.FlushAsync(timeout.Token);
        var clientReceived = await ReadExactlyAsync(client, serverPayload.Length, timeout.Token);
        EqualBytes(serverPayload, clientReceived);
    }

    private static async Task WrongPskIsRejectedAsync()
    {
        var identity = NewIdentity();
        var serverCredential = new PeelPskCredential(identity, NewKey());
        var clientCredential = new PeelPskCredential(identity, NewKey());
        await AssertHandshakeRejectedAsync(serverCredential, clientCredential);
    }

    private static async Task UnknownIdentityIsRejectedAsync()
    {
        var key = NewKey();
        var serverCredential = new PeelPskCredential(NewIdentity(), key);
        var clientCredential = new PeelPskCredential(NewIdentity(), key);
        await AssertHandshakeRejectedAsync(serverCredential, clientCredential);
    }

    private static async Task AssertHandshakeRejectedAsync(
        PeelPskCredential serverCredential,
        PeelPskCredential clientCredential)
    {
        var factory = new BouncyCastlePskTransportFactory();
        await using var listener = await factory.ListenAsync(
            new IPEndPoint(IPAddress.Loopback, 0),
            new SingleCredentialResolver(serverCredential));
        using var timeout = new CancellationTokenSource(TestTimeout);

        var serverFailureTask = CaptureFailureAsync(listener.AcceptAsync(timeout.Token).AsTask());
        var clientFailureTask = CaptureFailureAsync(factory
            .ConnectAsync(ToDnsEndPoint(listener.LocalEndPoint), clientCredential, timeout.Token)
            .AsTask());

        await Task.WhenAll(serverFailureTask, clientFailureTask);
        if (timeout.IsCancellationRequested)
        {
            throw new TimeoutException("The rejected TLS-PSK handshake did not terminate in time.");
        }

        HandshakeFailure(
            await serverFailureTask,
            "The TLS-PSK server unexpectedly accepted rejected credentials.");
        HandshakeFailure(
            await clientFailureTask,
            "The TLS-PSK client unexpectedly accepted rejected credentials.");
    }

    private static async Task StalledClientHandshakeCancelsAsync()
    {
        using var rawListener = new TcpListener(IPAddress.Loopback, 0);
        rawListener.Start();
        var endpoint = (IPEndPoint)rawListener.LocalEndpoint;
        var rawAcceptTask = rawListener.AcceptTcpClientAsync();
        var factory = new BouncyCastlePskTransportFactory();
        using var cancellation = new CancellationTokenSource(TimeSpan.FromMilliseconds(300));
        var stopwatch = Stopwatch.StartNew();

        var connectTask = factory.ConnectAsync(
            new DnsEndPoint(endpoint.Address.ToString(), endpoint.Port),
            new PeelPskCredential(NewIdentity(), NewKey()),
            cancellation.Token).AsTask();

        using var rawPeer = await rawAcceptTask.WaitAsync(TestTimeout);
        await ThrowsAsync<OperationCanceledException>(() => connectTask);
        stopwatch.Stop();

        if (stopwatch.Elapsed >= TimeSpan.FromSeconds(3))
        {
            throw new InvalidOperationException(
                $"A cancelled TLS-PSK handshake took {stopwatch.Elapsed.TotalSeconds:F2} seconds to stop.");
        }
    }

    private static async Task StalledServerHandshakeCancelsAsync()
    {
        var factory = new BouncyCastlePskTransportFactory();
        var credential = new PeelPskCredential(NewIdentity(), NewKey());
        await using var listener = await factory.ListenAsync(
            new IPEndPoint(IPAddress.Loopback, 0),
            new SingleCredentialResolver(credential));
        using var cancellation = new CancellationTokenSource(TimeSpan.FromMilliseconds(300));
        var stopwatch = Stopwatch.StartNew();
        var acceptTask = listener.AcceptAsync(cancellation.Token).AsTask();

        using var rawPeer = new TcpClient();
        await rawPeer.ConnectAsync(ToIPEndPoint(listener.LocalEndPoint), cancellation.Token);
        await ThrowsAsync<OperationCanceledException>(() => acceptTask);
        stopwatch.Stop();

        if (stopwatch.Elapsed >= TimeSpan.FromSeconds(3))
        {
            throw new InvalidOperationException(
                $"A cancelled TLS-PSK server handshake took {stopwatch.Elapsed.TotalSeconds:F2} seconds to stop.");
        }
    }

    private static async Task ListenerDisposalUnblocksAcceptAsync()
    {
        var factory = new BouncyCastlePskTransportFactory();
        var credential = new PeelPskCredential(NewIdentity(), NewKey());
        var listener = await factory.ListenAsync(
            new IPEndPoint(IPAddress.Loopback, 0),
            new SingleCredentialResolver(credential));
        var acceptTask = listener.AcceptAsync().AsTask();

        await listener.DisposeAsync();
        var failure = await CaptureFailureAsync(acceptTask).WaitAsync(TestTimeout);
        NotNull(failure, "Disposing the TLS-PSK listener unexpectedly completed an accept.");
    }

    private static async Task<Exception?> CaptureFailureAsync<T>(Task<T> task)
        where T : IAsyncDisposable
    {
        try
        {
            await using var unexpected = await task;
            return null;
        }
        catch (Exception exception)
        {
            return exception;
        }
    }

    private static async Task<byte[]> ReadExactlyAsync(
        Stream stream,
        int byteCount,
        CancellationToken cancellationToken)
    {
        var result = new byte[byteCount];
        var offset = 0;
        while (offset < result.Length)
        {
            var read = await stream.ReadAsync(result.AsMemory(offset), cancellationToken);
            if (read == 0)
            {
                throw new EndOfStreamException(
                    $"TLS-PSK stream ended after {offset} of {byteCount} expected bytes.");
            }

            offset += read;
        }

        return result;
    }

    private static DnsEndPoint ToDnsEndPoint(EndPoint endpoint)
    {
        var ipEndpoint = ToIPEndPoint(endpoint);
        return new DnsEndPoint(ipEndpoint.Address.ToString(), ipEndpoint.Port);
    }

    private static IPEndPoint ToIPEndPoint(EndPoint endpoint) =>
        endpoint as IPEndPoint ??
        throw new InvalidOperationException("The TLS-PSK listener did not expose an IP endpoint.");

    private static string NewIdentity() => $"peel-transport-test-{Guid.NewGuid():N}";

    private static byte[] NewKey() => RandomNumberGenerator.GetBytes(PeelPskSecurityProfile.PreSharedKeyLength);

    private static async Task ThrowsAsync<TException>(Func<Task> action)
        where TException : Exception
    {
        try
        {
            await action();
        }
        catch (TException)
        {
            return;
        }

        throw new InvalidOperationException($"Expected {typeof(TException).Name}.");
    }

    private static void Equal<T>(T expected, T actual)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
        {
            throw new InvalidOperationException($"Expected '{expected}', got '{actual}'.");
        }
    }

    private static void EqualBytes(byte[] expected, byte[] actual)
    {
        if (!CryptographicOperations.FixedTimeEquals(expected, actual))
        {
            throw new InvalidOperationException("TLS-PSK stream payload did not round-trip exactly.");
        }
    }

    private static void NotNull(object? value, string message)
    {
        if (value is null)
        {
            throw new InvalidOperationException(message);
        }
    }

    private static void HandshakeFailure(Exception? exception, string acceptedMessage)
    {
        if (exception is null)
        {
            throw new InvalidOperationException(acceptedMessage);
        }

        if (exception is not IOException || exception is OperationCanceledException)
        {
            throw new InvalidOperationException(
                $"Expected a TLS handshake IOException, got {exception.GetType().Name}.",
                exception);
        }
    }

    private sealed class SingleCredentialResolver : IPeelPskCredentialResolver
    {
        private readonly PeelPskCredential credential;

        internal SingleCredentialResolver(PeelPskCredential credential)
        {
            this.credential = credential;
        }

        public bool TryResolve(string identity, out PeelPskCredential? resolved)
        {
            if (StringComparer.Ordinal.Equals(identity, credential.Identity))
            {
                resolved = credential;
                return true;
            }

            resolved = null;
            return false;
        }
    }
}
