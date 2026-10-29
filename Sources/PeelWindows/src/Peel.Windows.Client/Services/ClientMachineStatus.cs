using System.IO;
using System.Security.Cryptography;
using Peel.Windows.Client.Models;
using Peel.Windows.Protocol;

namespace Peel.Windows.Client.Services;

public sealed partial class ClientSession
{
    private TaskCompletionSource<MachineStatusMessage>? _statusCompletion;
    private string? _statusRequestId;
    private bool _statusProofSent;

    // Calling this method is explicit one-snapshot consent; unsolicited challenges are ignored.
    public async Task<MachineStatusMessage> RequestMachineStatusAsync(CancellationToken token)
    {
        string id = Guid.NewGuid().ToString("D").ToUpperInvariant();
        TaskCompletionSource<MachineStatusMessage> completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
        long generation;
        lock (_stateGate)
        {
            if (_state != PeelConnectionState.Connected || _negotiatedHost?.Capabilities.Contains(PeelCapability.MachineStatus) != true)
                throw new InvalidOperationException("Connect to a host that supports Machine Status first.");
            if (_statusCompletion is not null) throw new InvalidOperationException("A status request is already pending.");
            _statusCompletion = completion; _statusRequestId = id; _statusProofSent = false; generation = _generation;
        }
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(TimeSpan.FromSeconds(8));
        try
        {
            await SendClientMessageAsync(new MachineStatusRequestMessage(id), generation, deadline.Token).ConfigureAwait(false);
            return await completion.Task.WaitAsync(deadline.Token).ConfigureAwait(false);
        }
        finally
        {
            lock (_stateGate) if (ReferenceEquals(_statusCompletion, completion))
            { _statusCompletion = null; _statusRequestId = null; }
        }
    }

    private async Task HandleStatusChallengeAsync(AgentPairingChallengeMessage challenge, long generation, CancellationToken token)
    {
        string hostId; TaskCompletionSource<MachineStatusMessage> pending;
        lock (_stateGate)
        {
            EnsureGenerationLocked(generation);
            if (_statusCompletion is null || _statusProofSent || _state != PeelConnectionState.Connected ||
                challenge.PairingId != _activePairingId || _connectedHost is null) return;
            if (!AgentPairingProof.IsFresh(challenge, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0))
                throw new InvalidDataException("Expired Machine Status challenge.");
            pending = _statusCompletion; _statusProofSent = true; hostId = _connectedHost.StableHostId;
        }
        var credential = await GetAndValidateCredentialAsync(hostId, token).ConfigureAwait(false);
        byte[] key = credential.CopyPreSharedKey();
        try
        {
            lock (_stateGate)
            {
                EnsureGenerationLocked(generation);
                if (!ReferenceEquals(pending, _statusCompletion) || credential.PairingId != challenge.PairingId) return;
            }
            await SendClientMessageAsync(new AgentPairingProofMessage(challenge.RequestId, challenge.PairingId,
                AgentPairingProof.Make(challenge, key)), generation, token).ConfigureAwait(false);
        }
        finally { CryptographicOperations.ZeroMemory(key); }
    }

    private void HandleMachineStatus(MachineStatusMessage message, long generation)
    {
        message.Validate();
        lock (_stateGate)
        {
            EnsureGenerationLocked(generation);
            if (message.RequestId == _statusRequestId) _statusCompletion?.TrySetResult(message);
        }
    }
    private void HandleMachineStatusError(MachineStatusErrorMessage message, long generation)
    {
        MachineStatusValidation.RequestId(message.RequestId); MachineStatusValidation.Text(message.Reason);
        lock (_stateGate)
        {
            EnsureGenerationLocked(generation);
            if (message.RequestId == _statusRequestId) _statusCompletion?.TrySetException(new InvalidOperationException(message.Reason));
        }
    }
}
