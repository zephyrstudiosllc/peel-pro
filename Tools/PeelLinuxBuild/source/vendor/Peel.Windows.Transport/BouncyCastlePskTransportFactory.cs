using System.Net;
using System.Net.Sockets;
using Org.BouncyCastle.Tls;
using Org.BouncyCastle.Tls.Crypto.Impl.BC;
using Peel.Windows.Protocol;

namespace Peel.Windows.Transport;

public sealed class BouncyCastlePskTransportFactory : IPeelPskTransportFactory
{
    public async ValueTask<Stream> ConnectAsync(
        DnsEndPoint endpoint,
        PeelPskCredential credential,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(endpoint);
        var identity = PeelPskSecurityProfile.GetIdentityBytes(credential);
        var preSharedKey = credential.PreSharedKey.ToArray();
        cancellationToken.ThrowIfCancellationRequested();

        var tcpClient = new TcpClient();
        try
        {
            await tcpClient.ConnectAsync(endpoint.Host, endpoint.Port, cancellationToken).ConfigureAwait(false);
            var protocol = new TlsClientProtocol(tcpClient.GetStream());
            var peer = new PeelPskTlsClient(new BcTlsCrypto(), identity, preSharedKey);
            await RunHandshakeAsync(
                () => protocol.Connect(peer),
                tcpClient,
                cancellationToken,
                "TLS-PSK client handshake failed.").ConfigureAwait(false);
            return new OwnedTlsStream(protocol.Stream, tcpClient);
        }
        catch
        {
            tcpClient.Dispose();
            throw;
        }
        finally
        {
            Array.Clear(preSharedKey);
        }
    }

    public ValueTask<IPeelPskListener> ListenAsync(
        IPEndPoint endpoint,
        IPeelPskCredentialResolver credentialResolver,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(endpoint);
        ArgumentNullException.ThrowIfNull(credentialResolver);
        cancellationToken.ThrowIfCancellationRequested();

        IPeelPskListener listener = new BouncyCastlePskListener(endpoint, credentialResolver);
        return ValueTask.FromResult(listener);
    }

    internal static async Task RunHandshakeAsync(
        Action handshake,
        TcpClient tcpClient,
        CancellationToken cancellationToken,
        string failureMessage)
    {
        var handshakeTask = Task.Run(handshake, CancellationToken.None);
        using var cancellationRegistration = cancellationToken.Register(
            static state => ((TcpClient)state!).Dispose(),
            tcpClient);

        try
        {
            await handshakeTask.WaitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            ObserveFault(handshakeTask);
            throw;
        }
        catch (Exception exception)
        {
            throw new IOException(failureMessage, exception);
        }
    }

    private static void ObserveFault(Task task)
    {
        _ = task.ContinueWith(
            static completed => _ = completed.Exception,
            CancellationToken.None,
            TaskContinuationOptions.ExecuteSynchronously | TaskContinuationOptions.OnlyOnFaulted,
            TaskScheduler.Default);
    }
}

internal sealed class BouncyCastlePskListener : IPeelPskListener
{
    private readonly TcpListener listener;
    private readonly IPeelPskCredentialResolver credentialResolver;
    private readonly CancellationTokenSource disposal = new();
    private int disposed;

    internal BouncyCastlePskListener(IPEndPoint endpoint, IPeelPskCredentialResolver credentialResolver)
    {
        this.credentialResolver = credentialResolver;
        listener = new TcpListener(endpoint);
        if (endpoint.Address.Equals(IPAddress.IPv6Any))
        {
            listener.Server.DualMode = true;
        }
        listener.Start();
    }

    public EndPoint LocalEndPoint => listener.LocalEndpoint;

    public async ValueTask<PeelPskConnection> AcceptAsync(CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(Volatile.Read(ref disposed) != 0, this);
        using var linkedCancellation = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken,
            disposal.Token);
        var tcpClient = await listener.AcceptTcpClientAsync(linkedCancellation.Token).ConfigureAwait(false);

        try
        {
            var identityManager = new PeelPskIdentityManager(credentialResolver);
            var protocol = new TlsServerProtocol(tcpClient.GetStream());
            var peer = new PeelPskTlsServer(new BcTlsCrypto(), identityManager);
            await BouncyCastlePskTransportFactory.RunHandshakeAsync(
                () => protocol.Accept(peer),
                tcpClient,
                linkedCancellation.Token,
                "TLS-PSK server handshake failed.").ConfigureAwait(false);

            var peerIdentity = identityManager.AuthenticatedIdentity;
            if (string.IsNullOrEmpty(peerIdentity))
            {
                throw new IOException("TLS-PSK server handshake completed without an authenticated identity.");
            }

            return new PeelPskConnection(new OwnedTlsStream(protocol.Stream, tcpClient), peerIdentity);
        }
        catch
        {
            tcpClient.Dispose();
            throw;
        }
    }

    public ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) == 0)
        {
            disposal.Cancel();
            listener.Stop();
            disposal.Dispose();
        }

        return ValueTask.CompletedTask;
    }
}
