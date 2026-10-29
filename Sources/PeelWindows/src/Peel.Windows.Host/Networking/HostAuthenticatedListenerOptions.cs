namespace Peel.Windows.Host.Networking;

public sealed record HostAuthenticatedListenerOptions
{
    public const int DefaultAcceptWorkerCount = 4;
    public const int DefaultMaximumActiveConnections = 16;
    public const int DefaultMaximumClassificationLineBytes = 16 * 1024;

    public HostAuthenticatedListenerOptions(
        int acceptWorkerCount = DefaultAcceptWorkerCount,
        int maximumActiveConnections = DefaultMaximumActiveConnections,
        int maximumClassificationLineBytes = DefaultMaximumClassificationLineBytes,
        TimeSpan? handshakeTimeout = null,
        TimeSpan? classificationTimeout = null)
    {
        if (acceptWorkerCount is < 1 or > 16)
        {
            throw new ArgumentOutOfRangeException(nameof(acceptWorkerCount));
        }

        if (maximumActiveConnections < acceptWorkerCount || maximumActiveConnections > 64)
        {
            throw new ArgumentOutOfRangeException(nameof(maximumActiveConnections));
        }

        if (maximumClassificationLineBytes is < 1 or > 1024 * 1024)
        {
            throw new ArgumentOutOfRangeException(nameof(maximumClassificationLineBytes));
        }

        TimeSpan boundedHandshakeTimeout = handshakeTimeout ?? TimeSpan.FromSeconds(10);
        TimeSpan boundedClassificationTimeout = classificationTimeout ?? TimeSpan.FromSeconds(5);
        ValidateTimeout(boundedHandshakeTimeout, nameof(handshakeTimeout));
        ValidateTimeout(boundedClassificationTimeout, nameof(classificationTimeout));

        AcceptWorkerCount = acceptWorkerCount;
        MaximumActiveConnections = maximumActiveConnections;
        MaximumClassificationLineBytes = maximumClassificationLineBytes;
        HandshakeTimeout = boundedHandshakeTimeout;
        ClassificationTimeout = boundedClassificationTimeout;
    }

    public int AcceptWorkerCount { get; }

    public int MaximumActiveConnections { get; }

    public int MaximumClassificationLineBytes { get; }

    public TimeSpan HandshakeTimeout { get; }

    public TimeSpan ClassificationTimeout { get; }

    private static void ValidateTimeout(TimeSpan value, string parameterName)
    {
        if (value <= TimeSpan.Zero || value > TimeSpan.FromMinutes(5))
        {
            throw new ArgumentOutOfRangeException(parameterName);
        }
    }
}
