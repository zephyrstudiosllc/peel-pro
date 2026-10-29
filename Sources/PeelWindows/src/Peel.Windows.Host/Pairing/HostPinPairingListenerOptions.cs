namespace Peel.Windows.Host.Pairing;

public sealed record HostPinPairingListenerOptions
{
    public const int DefaultAcceptWorkerCount = 2;
    public const int DefaultMaximumActiveConnections = 4;
    public const int DefaultMaximumRequestBytes = 64 * 1024;

    public HostPinPairingListenerOptions(
        int acceptWorkerCount = DefaultAcceptWorkerCount,
        int maximumActiveConnections = DefaultMaximumActiveConnections,
        int maximumRequestBytes = DefaultMaximumRequestBytes,
        TimeSpan? handshakeTimeout = null,
        TimeSpan? requestTimeout = null)
    {
        if (acceptWorkerCount is < 1 or > 8)
        {
            throw new ArgumentOutOfRangeException(nameof(acceptWorkerCount));
        }

        if (maximumActiveConnections < acceptWorkerCount || maximumActiveConnections > 16)
        {
            throw new ArgumentOutOfRangeException(nameof(maximumActiveConnections));
        }

        if (maximumRequestBytes is < 1024 or > 1024 * 1024)
        {
            throw new ArgumentOutOfRangeException(nameof(maximumRequestBytes));
        }

        TimeSpan boundedHandshakeTimeout = handshakeTimeout ?? TimeSpan.FromSeconds(10);
        TimeSpan boundedRequestTimeout = requestTimeout ?? TimeSpan.FromSeconds(10);
        ValidateTimeout(boundedHandshakeTimeout, nameof(handshakeTimeout));
        ValidateTimeout(boundedRequestTimeout, nameof(requestTimeout));

        AcceptWorkerCount = acceptWorkerCount;
        MaximumActiveConnections = maximumActiveConnections;
        MaximumRequestBytes = maximumRequestBytes;
        HandshakeTimeout = boundedHandshakeTimeout;
        RequestTimeout = boundedRequestTimeout;
    }

    public int AcceptWorkerCount { get; }

    public int MaximumActiveConnections { get; }

    public int MaximumRequestBytes { get; }

    public TimeSpan HandshakeTimeout { get; }

    public TimeSpan RequestTimeout { get; }

    private static void ValidateTimeout(TimeSpan value, string parameterName)
    {
        if (value <= TimeSpan.Zero || value > TimeSpan.FromMinutes(5))
        {
            throw new ArgumentOutOfRangeException(parameterName);
        }
    }
}
