using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using Peel.Windows.Client.Models;
using Peel.Windows.Client.Services;
namespace Peel.Linux;
internal sealed class SavedComputer(HostCandidate host) : IClientHostResolver, IPairedHostCredentialStore
{
    public ValueTask<HostCandidate?> ResolveFreshAsync(string id, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        // Explicit user-entered saved private/VPN endpoint only. TLS proof still
        // requires the exact stable host's secure-store PSK; address is not trust.
        return ValueTask.FromResult<HostCandidate?>(StringComparer.Ordinal.Equals(id, host.StableHostId) ? host : null);
    }
    public ValueTask<PairedHostCredential?> GetForHostAsync(string id, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        if (!StringComparer.Ordinal.Equals(id, host.StableHostId)) throw new InvalidDataException("Saved identity mismatch.");
        IntPtr secret = NativeUI.peel_linux_secret_lookup(id);
        if (secret == IntPtr.Zero) throw new IOException("This computer is not paired, or Secret Service is locked/unavailable.");
        byte[] key = Array.Empty<byte>();
        try
        {
            string text = Marshal.PtrToStringUTF8(secret) ?? throw new IOException("Invalid secure pairing.");
            using var document = JsonDocument.Parse(text);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || root.EnumerateObject().Count() != 3
                || !root.EnumerateObject().Select(p => p.Name).ToHashSet(StringComparer.Ordinal).SetEquals(new[] { "stableHostId", "pairingId", "preSharedKeyBase64" })
                || !StringComparer.Ordinal.Equals(root.GetProperty("stableHostId").GetString(), id)) throw new InvalidDataException("Secure pairing belongs to another computer.");
            var pairing = root.GetProperty("pairingId").GetString();
            var encoded = root.GetProperty("preSharedKeyBase64").GetString();
            if (string.IsNullOrWhiteSpace(pairing) || pairing.Length > 1024 || encoded is null) throw new InvalidDataException("Invalid stored pairing.");
            key = Convert.FromBase64String(encoded);
            if (key.Length != 32 || Convert.ToBase64String(key) != encoded) throw new InvalidDataException("Invalid stored pairing key.");
            return ValueTask.FromResult<PairedHostCredential?>(new(id, pairing, key));
        }
        finally { CryptographicOperations.ZeroMemory(key); NativeUI.peel_linux_secret_free(secret); }
    }
}
