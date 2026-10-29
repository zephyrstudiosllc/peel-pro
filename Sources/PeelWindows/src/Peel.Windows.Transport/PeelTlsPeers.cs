using System.Text;
using Org.BouncyCastle.Tls;
using Org.BouncyCastle.Tls.Crypto;
using Peel.Windows.Protocol;

namespace Peel.Windows.Transport;

internal sealed class PeelPskTlsClient : PskTlsClient
{
    internal PeelPskTlsClient(TlsCrypto crypto, byte[] identity, byte[] preSharedKey)
        : base(crypto, identity, preSharedKey)
    {
    }

    protected override ProtocolVersion[] GetSupportedVersions() => [ProtocolVersion.TLSv12];

    protected override int[] GetSupportedCipherSuites() => [PeelPskSecurityProfile.CipherSuite];

    public override void NotifyHandshakeComplete()
    {
        base.NotifyHandshakeComplete();
        PeelPskSecurityProfile.VerifyNegotiated(m_context);
    }
}

internal sealed class PeelPskTlsServer : PskTlsServer
{
    internal PeelPskTlsServer(TlsCrypto crypto, TlsPskIdentityManager identityManager)
        : base(crypto, identityManager)
    {
    }

    protected override ProtocolVersion[] GetSupportedVersions() => [ProtocolVersion.TLSv12];

    protected override int[] GetSupportedCipherSuites() => [PeelPskSecurityProfile.CipherSuite];

    protected override bool AllowCertificateStatus() => false;

    public override void NotifyHandshakeComplete()
    {
        base.NotifyHandshakeComplete();
        PeelPskSecurityProfile.VerifyNegotiated(m_context);
    }
}

internal sealed class PeelPskIdentityManager : TlsPskIdentityManager
{
    private readonly IPeelPskCredentialResolver credentialResolver;

    internal PeelPskIdentityManager(IPeelPskCredentialResolver credentialResolver)
    {
        this.credentialResolver = credentialResolver ?? throw new ArgumentNullException(nameof(credentialResolver));
    }

    internal string? AuthenticatedIdentity { get; private set; }

    public byte[] GetHint() => null!;

    public byte[] GetPsk(byte[] identity)
    {
        AuthenticatedIdentity = null;
        if (identity is not { Length: > 0 and <= PeelPskSecurityProfile.MaximumIdentityByteLength })
        {
            return null!;
        }

        string pairingId;
        try
        {
            pairingId = PeelPskSecurityProfile.StrictUtf8.GetString(identity);
        }
        catch (DecoderFallbackException)
        {
            return null!;
        }

        if (pairingId.IndexOf('\0') >= 0 ||
            !PeelPskSecurityProfile.StrictUtf8.GetBytes(pairingId).AsSpan().SequenceEqual(identity) ||
            !credentialResolver.TryResolve(pairingId, out var credential) ||
            credential is null ||
            !StringComparer.Ordinal.Equals(credential.Identity, pairingId) ||
            credential.PreSharedKey.Length != PeelPskSecurityProfile.PreSharedKeyLength)
        {
            return null!;
        }

        AuthenticatedIdentity = pairingId;
        return credential.PreSharedKey.ToArray();
    }
}
