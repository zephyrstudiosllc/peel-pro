using System.Net;

namespace Peel.Windows.Protocol;

public sealed record PeelPskCredential
{
    public PeelPskCredential(string identity, byte[] preSharedKey)
    {
        if (string.IsNullOrWhiteSpace(identity))
        {
            throw new ArgumentException("A non-empty TLS-PSK identity is required.", nameof(identity));
        }

        if (preSharedKey is not { Length: > 0 })
        {
            throw new ArgumentException("A non-empty TLS pre-shared key is required.", nameof(preSharedKey));
        }

        Identity = identity;
        PreSharedKey = preSharedKey.ToArray();
    }

    public string Identity { get; }

    public byte[] PreSharedKey { get; }
}

/// The control and every per-window video connection must be authenticated with
/// TLS-PSK. No plaintext or certificate-only fallback is part of protocol v2.
public interface IPeelPskTransportFactory
{
    ValueTask<Stream> ConnectAsync(
        DnsEndPoint endpoint,
        PeelPskCredential credential,
        CancellationToken cancellationToken = default);

    ValueTask<IPeelPskListener> ListenAsync(
        IPEndPoint endpoint,
        IPeelPskCredentialResolver credentialResolver,
        CancellationToken cancellationToken = default);
}

public interface IPeelPskCredentialResolver
{
    bool TryResolve(string identity, out PeelPskCredential? credential);
}

public interface IPeelPskListener : IAsyncDisposable
{
    EndPoint LocalEndPoint { get; }

    ValueTask<PeelPskConnection> AcceptAsync(CancellationToken cancellationToken = default);
}

public sealed class PeelPskConnection : IAsyncDisposable
{
    public PeelPskConnection(Stream stream, string peerIdentity)
    {
        Stream = stream ?? throw new ArgumentNullException(nameof(stream));
        if (string.IsNullOrWhiteSpace(peerIdentity))
        {
            throw new ArgumentException("An authenticated TLS-PSK peer identity is required.", nameof(peerIdentity));
        }

        PeerIdentity = peerIdentity;
    }

    public Stream Stream { get; }

    public string PeerIdentity { get; }

    public ValueTask DisposeAsync() => Stream.DisposeAsync();
}

public static class PeelSecureTransport
{
    public static IPeelPskTransportFactory Require(IPeelPskTransportFactory? factory) =>
        factory ?? throw new PlatformNotSupportedException(
            "No verified TLS-PSK provider is installed. Peel refuses to open a plaintext transport.");
}
