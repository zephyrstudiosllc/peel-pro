using Peel.Windows.Host.Networking;
using Peel.Windows.Protocol;

namespace Peel.Windows.Host.Tests;
internal static partial class Program
{
    private static async Task MachineStatusAuthorizationAsync()
    {
        var source = new StatusSource(); var clock = new StatusClock(); var keys = new StatusKeys();
        var gate = new HostMachineStatus(source, keys, "test-peer", clock);
        string Id() => Guid.NewGuid().ToString("D");
        True(await gate.RequestAsync(new(Id()), true, default) is MachineStatusErrorMessage);
        source.Enabled = true;
        string id = Id();
        var challenge = (AgentPairingChallengeMessage)await gate.RequestAsync(new(id), true, default);
        True(await gate.RequestAsync(new(Id()), true, default) is MachineStatusErrorMessage);
        var proof = new AgentPairingProofMessage(challenge.RequestId, challenge.PairingId, AgentPairingProof.Make(challenge, keys.Key));
        var reply = (MachineStatusMessage)(await gate.ProveAsync(proof, true, default))!;
        Equal(id, reply.RequestId); Equal(1, source.Reads);
        True(await gate.ProveAsync(proof, true, default) is null);
        clock.Advance(2);
        True(await gate.RequestAsync(new(Id()), true, default) is MachineStatusMessage);
        source.ConsentVersion++; clock.Advance(2);
        True(await gate.RequestAsync(new(Id()), true, default) is AgentPairingChallengeMessage);
        gate.Reset(); clock.Advance(2);
        challenge = (AgentPairingChallengeMessage)await gate.RequestAsync(new(Id()), true, default);
        proof = new(challenge.RequestId, challenge.PairingId, AgentPairingProof.Make(challenge, keys.Key));
        clock.Advance(6);
        True(await gate.ProveAsync(proof, true, default) is MachineStatusErrorMessage);
        clock.Advance(2); challenge = (AgentPairingChallengeMessage)await gate.RequestAsync(new(Id()), true, default);
        proof = new(challenge.RequestId, challenge.PairingId, AgentPairingProof.Make(challenge, keys.Key));
        True(await gate.ProveAsync(proof, false, default) is MachineStatusErrorMessage);
        clock.Advance(2); challenge = (AgentPairingChallengeMessage)await gate.RequestAsync(new(Id()), true, default);
        proof = new(challenge.RequestId, challenge.PairingId, AgentPairingProof.Make(challenge, keys.Key));
        keys.Revoked = true;
        True(await gate.ProveAsync(proof, true, default) is MachineStatusErrorMessage);
        Equal(2, source.Reads);
    }
    private sealed class StatusSource : IHostMachineStatusProvider
    {
        public bool Enabled { get; set; }
        public long ConsentVersion { get; set; }
        public int Reads { get; private set; }
        public ValueTask<MachineStatusMessage> ReadAsync(string id, CancellationToken token)
        { Reads++; return ValueTask.FromResult(new MachineStatusMessage(id, 1, "Test PC")); }
    }
    private sealed class StatusClock : TimeProvider
    {
        private DateTimeOffset now = DateTimeOffset.UtcNow;
        public override DateTimeOffset GetUtcNow() => now;
        public void Advance(int seconds) => now = now.AddSeconds(seconds);
    }
    private sealed class StatusKeys : IPeelPskCredentialResolver
    {
        public byte[] Key { get; } = System.Security.Cryptography.RandomNumberGenerator.GetBytes(32);
        public bool Revoked { get; set; }
        public bool TryResolve(string id, out PeelPskCredential? credential)
        { credential = Revoked ? null : new(id, Key); return !Revoked; }
    }
}
