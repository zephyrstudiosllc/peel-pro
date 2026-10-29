using Peel.Windows.Protocol;
using System.Net;
using Peel.Windows.Client.Services;
using Peel.Windows.Host.Networking;
using Peel.Windows.Transport;

namespace Peel.Windows.Client.Tests;
internal static partial class Program
{
    private static async Task<int> NativeMachineStatusAsync()
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        var factory = new BouncyCastlePskTransportFactory();
        var keys = new NativeStatusKeys();
        await using var listener = await factory.ListenAsync(new(IPAddress.Loopback, 0), keys, timeout.Token);
        await using var host = new HostControlSessionManager(new HostControlSessionOptions("Windows status test",
            capabilities: [PeelCapability.MachineStatus, PeelCapability.ClientVisibility])
            { MachineStatusProvider = new NativeStatusSource(), MachineStatusCredentials = keys });
        var endpoint = (IPEndPoint)listener.LocalEndPoint;
        var candidate = Candidate("native-status-test", "127.0.0.1", endpoint.Port);
        var credentials = new InMemoryPairedHostCredentialStore();
        credentials.Set(new(candidate.StableHostId, Fixture.PairingId, Fixture.Key));
        await using var client = new ClientSession(factory, credentials, new MutableHostResolver(candidate),
            new("Windows status test", "PC", "Windows", "test"));
        var serving = Task.Run(async () => await host.RunAuthenticatedSessionAsync(await listener.AcceptAsync(timeout.Token), timeout.Token));
        await client.ConnectAsync(candidate, timeout.Token);
        var snapshot = await client.RequestMachineStatusAsync(timeout.Token);
        Equal(.5, snapshot.CpuFraction);
        await client.DisconnectAsync(timeout.Token);
        await serving.WaitAsync(timeout.Token);
        Console.WriteLine("PASS native TLS-PSK Machine Status: request, proof, validated snapshot, disconnect.");
        return 0;
    }
    private sealed class NativeStatusKeys : IPeelPskCredentialResolver
    {
        public bool TryResolve(string id, out PeelPskCredential? credential)
        { credential = id == Fixture.PairingId ? new(id, Fixture.Key) : null; return credential is not null; }
    }
    private sealed class NativeStatusSource : IHostMachineStatusProvider
    {
        public bool Enabled => true;
        public ValueTask<MachineStatusMessage> ReadAsync(string id, CancellationToken token) =>
            ValueTask.FromResult(new MachineStatusMessage(id, DateTimeOffset.UtcNow.ToUnixTimeSeconds(), "Fixture PC", CpuFraction: .5));
    }
    private static async Task MachineStatusClientConsentAsync()
    {
        var stream = new ScriptedDuplexStream();
        var fixture = new Fixture(Candidate("host-1", "fresh.local", 2222), stream);
        await using var session = fixture.CreateSession();
        var connect = session.ConnectAsync(fixture.Resolver.Current, default);
        await stream.WaitForWritesAsync(1);
        stream.EnqueueRead(PeelJson.SerializeLine(PeelHello.CreateHost("Mac", capabilities: [PeelCapability.MachineStatus])));
        await connect; await stream.WaitForWritesAsync(2);
        var challenge = new AgentPairingChallengeMessage(Guid.NewGuid().ToString("D"), Fixture.PairingId,
            Convert.ToBase64String(new byte[32]), DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0 + 30);
        stream.EnqueueRead(PeelJson.SerializeLine(challenge));
        await Task.Delay(30);
        Equal(2, SnapshotWrites(stream).Length);
        var request = session.RequestMachineStatusAsync(default);
        await stream.WaitForWritesAsync(3);
        var sent = DeserializeWrite<MachineStatusRequestMessage>(stream, 2);
        stream.EnqueueRead(PeelJson.SerializeLine(challenge));
        await stream.WaitForWritesAsync(4);
        var proof = DeserializeWrite<AgentPairingProofMessage>(stream, 3);
        True(AgentPairingProof.Verify(proof.Proof, challenge, Fixture.Key), "Proof must match the stored peer key.");
        stream.EnqueueRead(PeelJson.SerializeLine(new MachineStatusMessage(sent.RequestId, 1, "Mac", CpuFraction: .42)));
        Equal(.42, (await request).CpuFraction);
        stream.EnqueueRead(PeelJson.SerializeLine(challenge));
        await Task.Delay(30); Equal(4, SnapshotWrites(stream).Length);
        using var cancel = new CancellationTokenSource();
        var canceled = session.RequestMachineStatusAsync(cancel.Token);
        await stream.WaitForWritesAsync(5); cancel.Cancel();
        await ThrowsAsync<OperationCanceledException>(() => canceled);
        stream.EnqueueRead(PeelJson.SerializeLine(challenge));
        await Task.Delay(30); Equal(5, SnapshotWrites(stream).Length);
    }
}
