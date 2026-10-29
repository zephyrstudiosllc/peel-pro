using System.Security.Cryptography;
using Peel.Windows.Protocol;

namespace Peel.Windows.Host.Networking;

public interface IHostMachineStatusProvider
{
    bool Enabled { get; }
    long ConsentVersion => 0;
    ValueTask<MachineStatusMessage> ReadAsync(string requestId, CancellationToken cancellationToken);
}

/// <summary>Owned exclusively by one authenticated control read loop; never shared across reconnects.</summary>
internal sealed class HostMachineStatus
{
    private readonly IHostMachineStatusProvider provider;
    private readonly IPeelPskCredentialResolver credentials;
    private readonly string pairingId;
    private readonly TimeProvider time;
    private AgentPairingChallengeMessage? challenge;
    private string? pending;
    private bool authorized;
    private double lastRequest = double.NegativeInfinity;
    private double pendingUntil;
    private long consentVersion;
    public HostMachineStatus(IHostMachineStatusProvider provider, IPeelPskCredentialResolver credentials,
        string pairingId, TimeProvider? time = null)
    { this.provider = provider; this.credentials = credentials; this.pairingId = pairingId; this.time = time ?? TimeProvider.System; }
    public void Reset() { challenge = null; pending = null; authorized = false; }
    private double Now => time.GetUtcNow().ToUnixTimeMilliseconds() / 1000.0;

    public async ValueTask<object> RequestAsync(MachineStatusRequestMessage request, bool eligible, CancellationToken token)
    {
        MachineStatusValidation.RequestId(request.RequestId);
        if (consentVersion != provider.ConsentVersion) Reset();
        consentVersion = provider.ConsentVersion;
        if (!eligible || !provider.Enabled) { Reset(); return Error(request.RequestId, "Machine Status sharing is off or the client is hidden."); }
        if (Now - lastRequest < 1 || pending is not null && Now < pendingUntil)
            return Error(request.RequestId, "A status request is already pending. Try again shortly.");
        lastRequest = Now;
        if (authorized) return await SnapshotAsync(request.RequestId, token).ConfigureAwait(false);
        pending = request.RequestId; pendingUntil = Now + 5;
        challenge = new(Guid.NewGuid().ToString("D").ToUpperInvariant(), pairingId,
            Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)), Now + 30);
        return challenge;
    }

    public async ValueTask<object?> ProveAsync(AgentPairingProofMessage proof, bool eligible, CancellationToken token)
    {
        var current = challenge; var requestId = pending;
        challenge = null; pending = null;
        if (current is null || requestId is null) return null;
        if (!eligible || !provider.Enabled || consentVersion != provider.ConsentVersion || Now >= pendingUntil || !AgentPairingProof.IsFresh(current, Now) ||
            proof.RequestId != current.RequestId || proof.PairingId != pairingId ||
            !credentials.TryResolve(pairingId, out var key) || key is null)
        { authorized = false; return Error(requestId, "Machine Status authorization expired or was refused."); }
        byte[] ownedKey = key.PreSharedKey.ToArray();
        try
        {
            authorized = AgentPairingProof.Verify(proof.Proof, current, ownedKey);
            return authorized ? await SnapshotAsync(requestId, token).ConfigureAwait(false)
                : Error(requestId, "Machine Status proof was refused.");
        }
        finally { CryptographicOperations.ZeroMemory(ownedKey); }
    }

    private async ValueTask<object> SnapshotAsync(string id, CancellationToken token)
    {
        // Re-resolve on every response: revocation cannot leave cached authorization usable.
        if (!provider.Enabled || !credentials.TryResolve(pairingId, out var key) || key is null)
        { Reset(); return Error(id, "Machine Status sharing or pairing was revoked."); }
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(TimeSpan.FromSeconds(5));
        var snapshot = await provider.ReadAsync(id, deadline.Token).AsTask().WaitAsync(deadline.Token).ConfigureAwait(false);
        snapshot.Validate();
        return provider.Enabled && consentVersion == provider.ConsentVersion ? snapshot : Error(id, "Machine Status sharing was revoked.");
    }
    private static MachineStatusErrorMessage Error(string id, string reason) => new(id, reason);
}
