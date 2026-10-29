using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text.Json;
using Peel.Windows.Host.Security;
using Peel.Windows.Protocol;

namespace Peel.Windows.Host.Pairing;

public sealed class HostPinPairingListener : IAsyncDisposable
{
    private const int MaximumClientNameCodeUnits = 256;
    private const int MaximumDeviceIdCodeUnits = 1024;
    private const int MaximumProofCodeUnits = 256;

    private readonly IPeelPskTransportFactory transportFactory;
    private readonly WindowsPairedClientStore pairedClients;
    private readonly string hostId;
    private readonly string hostName;
    private readonly string serviceName;
    private readonly HostPinPairingListenerOptions options;
    private readonly TimeProvider timeProvider;
    private readonly CancellationTokenSource lifetimeCancellation = new();
    private readonly SemaphoreSlim connectionSlots;
    private readonly ConcurrentDictionary<long, Task> activeConnections = new();
    private readonly SinglePairingCredentialResolver credentialResolver;

    private IPeelPskListener? listener;
    private CancellationTokenRegistration startCancellationRegistration;
    private Task completion = Task.CompletedTask;
    private long nextConnectionId;
    private int started;
    private int disposed;

    public HostPinPairingListener(
        IPeelPskTransportFactory transportFactory,
        WindowsPairedClientStore pairedClients,
        string hostId,
        string hostName,
        string serviceName,
        HostPairingPin pairingPin,
        HostPinPairingListenerOptions? options = null)
        : this(
            transportFactory,
            pairedClients,
            hostId,
            hostName,
            serviceName,
            pairingPin,
            options,
            TimeProvider.System)
    {
    }

    internal HostPinPairingListener(
        IPeelPskTransportFactory transportFactory,
        WindowsPairedClientStore pairedClients,
        string hostId,
        string hostName,
        string serviceName,
        HostPairingPin pairingPin,
        HostPinPairingListenerOptions? options,
        TimeProvider timeProvider)
    {
        this.transportFactory = PeelSecureTransport.Require(transportFactory);
        this.pairedClients = pairedClients ?? throw new ArgumentNullException(nameof(pairedClients));
        this.hostId = NormalizeBoundedText(hostId, nameof(hostId), 1024);
        this.hostName = NormalizeBoundedText(hostName, nameof(hostName), 256);
        this.serviceName = NormalizeBoundedText(serviceName, nameof(serviceName), 256);
        PairingPin = pairingPin ?? throw new ArgumentNullException(nameof(pairingPin));
        this.options = options ?? new HostPinPairingListenerOptions();
        this.timeProvider = timeProvider ?? throw new ArgumentNullException(nameof(timeProvider));
        byte[] pinPreSharedKey = PairingPin.DerivePreSharedKey(this.hostId);
        try
        {
            credentialResolver = new SinglePairingCredentialResolver(pinPreSharedKey);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(pinPreSharedKey);
        }

        connectionSlots = new SemaphoreSlim(
            this.options.MaximumActiveConnections,
            this.options.MaximumActiveConnections);
    }

    public HostPairingPin PairingPin { get; }

    public EndPoint? LocalEndPoint => listener?.LocalEndPoint;

    public Task Completion => completion;

    public async ValueTask StartAsync(
        IPEndPoint endpoint,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(endpoint);
        ObjectDisposedException.ThrowIf(Volatile.Read(ref disposed) != 0, this);
        if (Interlocked.CompareExchange(ref started, 1, 0) != 0)
        {
            throw new InvalidOperationException("The PIN pairing listener was already started.");
        }

        cancellationToken.ThrowIfCancellationRequested();
        IPeelPskListener created = await transportFactory.ListenAsync(
                endpoint,
                credentialResolver,
                cancellationToken)
            .ConfigureAwait(false);
        listener = created;
        if (cancellationToken.CanBeCanceled)
        {
            startCancellationRegistration = cancellationToken.Register(
                static state => ((CancellationTokenSource)state!).Cancel(),
                lifetimeCancellation);
        }

        Task[] workers = Enumerable.Range(0, options.AcceptWorkerCount)
            .Select(_ => RunAcceptWorkerGuardedAsync(created, lifetimeCancellation.Token))
            .ToArray();
        completion = CompleteAsync(workers);
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0)
        {
            return;
        }

        lifetimeCancellation.Cancel();
        try
        {
            if (listener is not null)
            {
                await listener.DisposeAsync().ConfigureAwait(false);
            }

            try
            {
                await completion.ConfigureAwait(false);
            }
            catch (Exception exception) when (IsFailSoftConnectionException(exception))
            {
            }
        }
        finally
        {
            credentialResolver.Dispose();
            startCancellationRegistration.Dispose();
            connectionSlots.Dispose();
            lifetimeCancellation.Dispose();
        }
    }

    private async Task RunAcceptWorkerAsync(
        IPeelPskListener activeListener,
        CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            PeelPskConnection connection;
            using var handshakeCancellation = CancellationTokenSource.CreateLinkedTokenSource(
                cancellationToken);
            handshakeCancellation.CancelAfter(options.HandshakeTimeout);
            try
            {
                connection = await activeListener.AcceptAsync(handshakeCancellation.Token)
                    .ConfigureAwait(false);
            }
            catch (Exception exception) when (
                IsFailSoftConnectionException(exception) ||
                cancellationToken.IsCancellationRequested)
            {
                if (cancellationToken.IsCancellationRequested)
                {
                    return;
                }

                continue;
            }

            if (!connectionSlots.Wait(0))
            {
                await connection.DisposeAsync().ConfigureAwait(false);
                continue;
            }

            long connectionId = checked(Interlocked.Increment(ref nextConnectionId));
            Task handled = HandleAndReleaseAsync(connection, cancellationToken);
            activeConnections[connectionId] = handled;
            _ = handled.ContinueWith(
                (completed, state) =>
                {
                    _ = completed;
                    var (connections, id) =
                        ((ConcurrentDictionary<long, Task>, long))state!;
                    connections.TryRemove(id, out Task? _);
                },
                (activeConnections, connectionId),
                CancellationToken.None,
                TaskContinuationOptions.ExecuteSynchronously,
                TaskScheduler.Default);
        }
    }

    private async Task RunAcceptWorkerGuardedAsync(
        IPeelPskListener activeListener,
        CancellationToken cancellationToken)
    {
        try
        {
            await RunAcceptWorkerAsync(activeListener, cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            lifetimeCancellation.Cancel();
            throw;
        }
    }

    private async Task HandleAndReleaseAsync(
        PeelPskConnection connection,
        CancellationToken cancellationToken)
    {
        try
        {
            await HandlePairingConnectionAsync(connection, cancellationToken)
                .ConfigureAwait(false);
        }
        catch (Exception exception) when (IsFailSoftConnectionException(exception))
        {
        }
        finally
        {
            try
            {
                await connection.DisposeAsync().ConfigureAwait(false);
            }
            finally
            {
                connectionSlots.Release();
            }
        }
    }

    private async Task HandlePairingConnectionAsync(
        PeelPskConnection connection,
        CancellationToken cancellationToken)
    {
        if (!StringComparer.Ordinal.Equals(
                connection.PeerIdentity,
                PeelPinPairing.TlsIdentity))
        {
            return;
        }

        using var requestCancellation = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken);
        requestCancellation.CancelAfter(options.RequestTimeout);
        PairRequestMessage request = await ReadPairingRequestAsync(
                connection.Stream,
                requestCancellation.Token)
            .ConfigureAwait(false);

        if (timeProvider.GetUtcNow() >= PairingPin.ExpiresAt)
        {
            await SendRejectionAsync(
                    connection.Stream,
                    "Pairing PIN expired. Generate a new PIN and try again.",
                    requestCancellation.Token)
                .ConfigureAwait(false);
            return;
        }

        string clientName;
        string clientDeviceId;
        try
        {
            clientName = NormalizeBoundedText(
                request.ClientName,
                nameof(request.ClientName),
                MaximumClientNameCodeUnits);
            clientDeviceId = NormalizeBoundedText(
                request.ClientDeviceId,
                nameof(request.ClientDeviceId),
                MaximumDeviceIdCodeUnits);
        }
        catch (ArgumentException)
        {
            await SendRejectionAsync(
                    connection.Stream,
                    "Pairing request was missing device identity. Restart the client and try again.",
                    requestCancellation.Token)
                .ConfigureAwait(false);
            return;
        }

        string proof = request.PinProof?.Trim() ?? string.Empty;
        if (proof.Length is 0 or > MaximumProofCodeUnits)
        {
            await SendIncorrectPinAsync(connection.Stream, requestCancellation.Token)
                .ConfigureAwait(false);
            return;
        }

        byte[] pinPreSharedKey = PairingPin.DerivePreSharedKey(hostId);
        try
        {
            if (!PeelPinPairing.VerifyProof(
                    pinPreSharedKey,
                    hostId,
                    clientDeviceId,
                    proof))
            {
                await SendIncorrectPinAsync(connection.Stream, requestCancellation.Token)
                    .ConfigureAwait(false);
                return;
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(pinPreSharedKey);
        }

        byte[] pairedPreSharedKey = RandomNumberGenerator.GetBytes(
            WindowsPairedClientStore.PreSharedKeyBytes);
        string pairingId = Guid.NewGuid().ToString().ToUpperInvariant();
        try
        {
            try
            {
                _ = pairedClients.AddOrReplace(
                    pairingId,
                    clientName,
                    clientDeviceId,
                    pairedPreSharedKey);
            }
            catch (Exception exception) when (
                exception is IOException or
                    UnauthorizedAccessException or
                    InvalidDataException or
                    InvalidOperationException or
                    System.ComponentModel.Win32Exception)
            {
                await SendRejectionAsync(
                        connection.Stream,
                        "Pairing could not be saved on this PC. Try again.",
                        requestCancellation.Token)
                    .ConfigureAwait(false);
                return;
            }

            var response = new PairResponseMessage(
                hostName,
                serviceName,
                pairingId,
                pairedPreSharedKey,
                Accepted: true);
            await SendResponseAsync(connection.Stream, response, requestCancellation.Token)
                .ConfigureAwait(false);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(pairedPreSharedKey);
        }
    }

    private async Task<PairRequestMessage> ReadPairingRequestAsync(
        Stream stream,
        CancellationToken cancellationToken)
    {
        using var buffer = new MemoryStream(options.MaximumRequestBytes);
        byte[] chunk = new byte[4096];
        while (true)
        {
            int read = await stream.ReadAsync(chunk, cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                throw new EndOfStreamException("The pairing connection closed before a request arrived.");
            }

            if (buffer.Length + read > options.MaximumRequestBytes)
            {
                throw new InvalidDataException("The pairing request exceeded its byte limit.");
            }

            buffer.Write(chunk, 0, read);
            ReadOnlyMemory<byte> json = buffer.GetBuffer().AsMemory(0, checked((int)buffer.Length));
            try
            {
                using JsonDocument document = JsonDocument.Parse(json);
                if (document.RootElement.ValueKind != JsonValueKind.Object ||
                    !document.RootElement.TryGetProperty("type", out JsonElement type) ||
                    type.ValueKind != JsonValueKind.String ||
                    !StringComparer.Ordinal.Equals(type.GetString(), PeelMessageType.PairRequest))
                {
                    throw new InvalidDataException("The pairing request discriminator is invalid.");
                }

                PairRequestMessage request = PeelJson.Deserialize<PairRequestMessage>(json.Span);
                if (!StringComparer.Ordinal.Equals(request.Type, PeelMessageType.PairRequest))
                {
                    throw new InvalidDataException("The pairing request discriminator is invalid.");
                }

                return request;
            }
            catch (JsonException) when (buffer.Length < options.MaximumRequestBytes)
            {
            }
        }
    }

    private Task SendIncorrectPinAsync(Stream stream, CancellationToken cancellationToken) =>
        SendRejectionAsync(
            stream,
            "Incorrect PIN. Check the 6-digit code and try again.",
            cancellationToken);

    private Task SendRejectionAsync(
        Stream stream,
        string reason,
        CancellationToken cancellationToken) =>
        SendResponseAsync(
            stream,
            new PairResponseMessage(
                hostName,
                serviceName,
                string.Empty,
                [],
                Accepted: false,
                Reason: reason),
            cancellationToken);

    private static async Task SendResponseAsync(
        Stream stream,
        PairResponseMessage response,
        CancellationToken cancellationToken)
    {
        byte[] data = PeelJson.Serialize(response);
        try
        {
            await stream.WriteAsync(data, cancellationToken).ConfigureAwait(false);
            await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(data);
        }
    }

    private async Task CompleteAsync(Task[] workers)
    {
        try
        {
            await Task.WhenAll(workers).ConfigureAwait(false);
        }
        finally
        {
            lifetimeCancellation.Cancel();
            Task[] sessions = activeConnections.Values.ToArray();
            if (sessions.Length != 0)
            {
                await Task.WhenAll(sessions).ConfigureAwait(false);
            }
        }
    }

    private static string NormalizeBoundedText(
        string value,
        string parameterName,
        int maximumCodeUnits)
    {
        if (value is null)
        {
            throw new ArgumentNullException(parameterName);
        }

        string normalized = value.Trim();
        if (normalized.Length == 0 ||
            normalized.Length > maximumCodeUnits ||
            normalized.IndexOf('\0') >= 0)
        {
            throw new ArgumentException(
                $"A non-empty value of at most {maximumCodeUnits} UTF-16 code units is required.",
                parameterName);
        }

        return normalized;
    }

    private static bool IsFailSoftConnectionException(Exception exception) =>
        exception is IOException or
            SocketException or
            InvalidDataException or
            JsonException or
            ObjectDisposedException or
            OperationCanceledException or
            InvalidOperationException or
            ArgumentException or
            NotSupportedException or
            OverflowException;

    private sealed class SinglePairingCredentialResolver :
        IPeelPskCredentialResolver,
        IDisposable
    {
        private readonly byte[] preSharedKey;

        internal SinglePairingCredentialResolver(ReadOnlySpan<byte> preSharedKey)
        {
            if (preSharedKey.Length != PeelPinPairing.PreSharedKeyBytes)
            {
                throw new ArgumentException("The pairing PIN key length is invalid.", nameof(preSharedKey));
            }

            this.preSharedKey = preSharedKey.ToArray();
        }

        public bool TryResolve(string identity, out PeelPskCredential? credential)
        {
            if (!StringComparer.Ordinal.Equals(identity, PeelPinPairing.TlsIdentity))
            {
                credential = null;
                return false;
            }

            credential = new PeelPskCredential(PeelPinPairing.TlsIdentity, preSharedKey);
            return true;
        }

        public void Dispose() => CryptographicOperations.ZeroMemory(preSharedKey);
    }
}
