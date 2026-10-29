using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using Peel.Windows.Discovery;
using Peel.Windows.Protocol;

namespace Peel.Windows.Client.Services;

public sealed class ClientPinPairing
{
    private readonly IPeelPskTransportFactory transport;
    private readonly WindowsPairedHostStore store;

    public ClientPinPairing(IPeelPskTransportFactory transport, WindowsPairedHostStore store)
    { this.transport = PeelSecureTransport.Require(transport); this.store = store; }

    public async Task PairAsync(PeelDiscoveredService service, string pin, CancellationToken token)
    {
        if (!ClientHostDiscovery.ValidService(service, PeelServiceType.Pairing)
            || service.PairingMode != "pin" || service.TlsPskOrder != "psk-identity")
            throw new InvalidDataException("Pairing requires a current Peel PIN service using standard TLS-PSK order.");
        byte[] salt;
        try { salt = Convert.FromBase64String(service.PairingSaltBase64 ?? ""); }
        catch (FormatException) { throw new InvalidDataException("The computer sent an invalid pairing salt."); }
        if (salt.Length != 16) throw new InvalidDataException("The computer sent an invalid pairing salt.");
        var key = PeelPinPairing.DerivePreSharedKey(pin, salt, service.HostId!);
        var credential = new PeelPskCredential(PeelPinPairing.TlsIdentity, key);
        byte[]? responseKey = null;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeout.CancelAfter(TimeSpan.FromSeconds(20));
        try
        {
            await using var stream = await transport.ConnectAsync(new DnsEndPoint(service.HostName!, service.Port!.Value),
                credential, timeout.Token).ConfigureAwait(false);
            var deviceId = Guid.NewGuid().ToString().ToUpperInvariant();
            // A fresh identity on each pairing avoids replacing an existing Mac listener's key in place.
            var request = new PairRequestMessage(Environment.MachineName, deviceId,
                PeelPinPairing.CreateProof(key, service.HostId!, deviceId));
            await stream.WriteAsync(PeelJson.SerializeLine(request), timeout.Token).ConfigureAwait(false);
            await stream.FlushAsync(timeout.Token).ConfigureAwait(false);
            var reader = new NdjsonReader(16 * 1024);
            var buffer = new byte[2048];
            while (true)
            {
                int count = await stream.ReadAsync(buffer, timeout.Token).ConfigureAwait(false);
                if (count == 0) throw new IOException("The computer closed pairing before accepting it.");
                foreach (var line in reader.Append(buffer.AsSpan(0, count)))
                {
                    var utf8 = Encoding.UTF8.GetBytes(line);
                    if (PeelJson.ReadEnvelope(utf8).Type != PeelMessageType.PairResponse)
                        throw new InvalidDataException("The computer sent an unexpected pairing message.");
                    var response = PeelJson.Deserialize<PairResponseMessage>(utf8);
                    responseKey = response.Psk;
                    if (!response.Accepted) throw new InvalidOperationException("Pairing was declined. Check the PIN and try again.");
                    if (!Guid.TryParse(response.PairingId, out _) || responseKey is not { Length: 32 }
                        || string.IsNullOrWhiteSpace(response.HostName) || response.HostName.Length > 256
                        || response.HostName.Any(char.IsControl))
                        throw new InvalidDataException("The computer sent invalid pairing credentials.");
                    token.ThrowIfCancellationRequested();
                    store.Save(service.HostId!, response.HostName, response.PairingId, responseKey, deviceId);
                    return;
                }
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(key);
            CryptographicOperations.ZeroMemory(credential.PreSharedKey);
            if (responseKey is not null) CryptographicOperations.ZeroMemory(responseKey);
        }
    }
}
