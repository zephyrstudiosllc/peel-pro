using System.IO;
using System.Security.Cryptography;
using Peel.Windows.Host.Security;

namespace Peel.Windows.Client.Services;

/// Client metadata and secrets use a separate namespace from the publishing Host.
public sealed class WindowsPairedHostStore : IPairedHostCredentialStore
{
    private readonly WindowsPairedClientStore store;

    public WindowsPairedHostStore() : this(new WindowsPairedClientStore(
        new WindowsCredentialManager(),
        new JsonHostPairedClientMetadataRepository(Path.Combine(ClientDataDirectory, "paired-hosts.json")),
        "ZephyrStudios.Peel.Client.PSK")) { }

    internal WindowsPairedHostStore(WindowsPairedClientStore store) => this.store = store;

    internal static string ClientDataDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Zephyr Studios", "Peel", "Client");

    public IReadOnlyList<HostPairedClient> Snapshot() => store.Snapshot();
    internal bool TryResolveSignal(string pairingId, out Peel.Windows.Protocol.PeelPskCredential? credential) => store.TryResolve(pairingId, out credential);
    public string? LoadError => store.LoadError;
    public bool IsPaired(string hostId) => Snapshot().Any(p => p.DeviceId == hostId);

    public ValueTask<PairedHostCredential?> GetForHostAsync(string stableHostId, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var peer = Snapshot().SingleOrDefault(p => p.DeviceId == stableHostId);
        if (peer is null || !store.TryResolve(peer.PairingId, out var credential) || credential is null)
            return ValueTask.FromResult<PairedHostCredential?>(null);
        try
        {
            return ValueTask.FromResult<PairedHostCredential?>(
                new PairedHostCredential(stableHostId, credential.Identity, credential.PreSharedKey));
        }
        finally { CryptographicOperations.ZeroMemory(credential.PreSharedKey); }
    }

    internal void Save(string hostId, string displayName, string pairingId, byte[] key, string? localDeviceId = null) =>
        store.AddOrReplace(pairingId, displayName, hostId, key, localDeviceId: localDeviceId);

    public void Forget(string hostId)
    {
        foreach (var peer in Snapshot().Where(p => p.DeviceId == hostId)) store.Remove(peer.PairingId);
    }
}
