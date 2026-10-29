using System.Text;
using Org.BouncyCastle.Tls;
using Peel.Windows.Protocol;

namespace Peel.Windows.Transport;

public static class PeelPskSecurityProfile
{
    public const int PreSharedKeyLength = 32;
    public const int MaximumIdentityByteLength = 1024;
    public const int CipherSuite = Org.BouncyCastle.Tls.CipherSuite.TLS_PSK_WITH_AES_128_GCM_SHA256;

    internal static readonly UTF8Encoding StrictUtf8 = new(false, true);

    internal static byte[] GetIdentityBytes(PeelPskCredential credential)
    {
        ArgumentNullException.ThrowIfNull(credential);
        ValidatePreSharedKey(credential.PreSharedKey, nameof(credential));

        if (credential.Identity.IndexOf('\0') >= 0)
        {
            throw new ArgumentException("The TLS-PSK identity cannot contain a null character.", nameof(credential));
        }

        var identity = StrictUtf8.GetBytes(credential.Identity);
        if (identity.Length is < 1 or > MaximumIdentityByteLength)
        {
            throw new ArgumentException(
                $"The UTF-8 TLS-PSK identity must be 1 to {MaximumIdentityByteLength} bytes.",
                nameof(credential));
        }

        return identity;
    }

    internal static void ValidatePreSharedKey(byte[] preSharedKey, string parameterName)
    {
        if (preSharedKey is not { Length: PreSharedKeyLength })
        {
            throw new ArgumentException(
                $"Peel TLS-PSK credentials must contain exactly {PreSharedKeyLength} key bytes.",
                parameterName);
        }
    }

    internal static void VerifyNegotiated(TlsContext context)
    {
        var securityParameters = context.SecurityParameters;
        if (!ProtocolVersion.TLSv12.Equals(securityParameters.NegotiatedVersion) ||
            securityParameters.CipherSuite != CipherSuite)
        {
            throw new TlsFatalAlert(AlertDescription.handshake_failure);
        }
    }
}
