using Peel.Windows.Host.Security;
using Peel.Windows.Protocol;

namespace Peel.Windows.Client.Services;

internal sealed record SignalPublisherPeer(string PairingId, string PublisherId, string SubscriberId, bool IsHostPairing);

/// <summary>Uses each pairing's recorded identities. No identity migration or credential copying.</summary>
internal sealed class SignalPublisherTrust(WindowsPairedHostStore hosts, Func<WindowsPairedClientStore> clients, string hostId) : IPeelPskCredentialResolver
{
    internal IReadOnlyList<SignalPublisherPeer> Snapshot()
    {
        var peers = hosts.Snapshot().Take(128)
            .Where(p => Valid(p.LocalDeviceId) && Valid(p.DeviceId) && Valid(p.PairingId))
            .Select(p => new SignalPublisherPeer(p.PairingId, p.LocalDeviceId!, p.DeviceId, false))
            .Concat(clients().Snapshot().Take(128).Where(p => Valid(hostId) && Valid(p.DeviceId) && Valid(p.PairingId))
                .Select(p => new SignalPublisherPeer(p.PairingId, hostId, p.DeviceId, true)))
            .Where(p => TrustedSignals.Uuid(p.PublisherId) != TrustedSignals.Uuid(p.SubscriberId))
            .GroupBy(p => p.PairingId, StringComparer.Ordinal).Where(g => g.Count() == 1).Select(g => g.Single())
            .OrderBy(p => p.PublisherId, StringComparer.Ordinal).ThenBy(p => p.PairingId, StringComparer.Ordinal).Take(128).ToArray();
        var advertised = peers.Select(p => p.PublisherId).Distinct(StringComparer.OrdinalIgnoreCase).Take(16).ToHashSet(StringComparer.OrdinalIgnoreCase);
        return peers.Where(p => advertised.Contains(p.PublisherId)).ToArray();
    }
    public bool TryResolve(string identity, out PeelPskCredential? credential)
    {
        credential = null;
        var peer = Snapshot().SingleOrDefault(p => p.PairingId == identity);
        if (peer is null) return false;
        return peer.IsHostPairing ? clients().TryResolve(identity, out credential) : hosts.TryResolveSignal(identity, out credential);
    }
    private static bool Valid(string? value)
    {
        try { _ = TrustedSignals.Uuid(value); return true; }
        catch (System.IO.InvalidDataException) { return false; }
    }
}
