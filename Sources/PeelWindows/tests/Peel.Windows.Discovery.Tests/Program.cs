using System.Text;
using Peel.Windows.Discovery;

namespace Peel.Windows.Discovery.Tests;

internal static class Program
{
    private const string TestServiceType = "_peeltest._tcp";

    public static async Task<int> Main()
    {
        try
        {
            Equal("_peel._tcp.local", PeelServiceType.ToQueryName(PeelServiceType.Control));
            Equal("_peelpair._tcp.local", PeelServiceType.ToQueryName(PeelServiceType.Pairing));
            Throws<ArgumentException>(() => PeelServiceType.ToQueryName("peel._tcp"));
            Equal(
                "AAECAwQFBgcICQoLDA0ODw==",
                new PeelDiscoveredService(
                    PeelServiceChangeKind.Added,
                    "Test",
                    "Test",
                    PeelServiceType.Pairing,
                    null,
                    null,
                    new Dictionary<string, byte[]>(StringComparer.Ordinal)
                    {
                        ["pinSalt"] = Encoding.UTF8.GetBytes("AAECAwQFBgcICQoLDA0ODw"),
                    }).PairingSaltBase64);
            Console.WriteLine("PASS service type validation");

            if (!OperatingSystem.IsWindows())
            {
                Console.WriteLine("SKIP native DNS-SD smoke requires Windows");
                return 0;
            }

            await NativeRegisterBrowseDeregisterAsync();
            Console.WriteLine("PASS native DNS-SD register/browse/deregister");
            Console.WriteLine("2/2 discovery tests passed");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine($"FAIL discovery: {exception}");
            return 1;
        }
    }

    private static async Task NativeRegisterBrowseDeregisterAsync()
    {
        var uniqueId = Guid.NewGuid().ToString("N");
        var displayName = $"Peel Windows Smoke {uniqueId}";
        var hostId = $"smoke-{uniqueId}";
        const ushort port = 44_444;

        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        var browser = new WindowsDnsSdBrowser();
        await using var results = browser
            .BrowseAsync(TestServiceType, timeout.Token)
            .GetAsyncEnumerator(timeout.Token);

        var firstResult = results.MoveNextAsync().AsTask();
        await Task.Delay(250, timeout.Token);

        var advertisement = new PeelServiceAdvertisement(
            displayName,
            TestServiceType,
            port,
            new Dictionary<string, byte[]>(StringComparer.Ordinal)
            {
                ["hostId"] = Encoding.UTF8.GetBytes(hostId),
                ["purpose"] = Encoding.UTF8.GetBytes("runtime-smoke"),
            });

        IAsyncDisposable? registration = null;
        try
        {
            registration = await new WindowsDnsSdRegistrar()
                .RegisterAsync(advertisement, timeout.Token);

            PeelDiscoveredService? added = null;
            var hasResult = await firstResult;
            while (hasResult)
            {
                var candidate = results.Current;
                if (candidate.ChangeKind == PeelServiceChangeKind.Added &&
                    candidate.DisplayName == displayName)
                {
                    added = candidate;
                    break;
                }

                hasResult = await results.MoveNextAsync();
            }

            if (added is null)
            {
                throw new InvalidOperationException("The registered DNS-SD service was not discovered.");
            }

            Equal(hostId, added.HostId);
            Equal(port, added.Port);
            Equal("runtime-smoke", added.GetUtf8Txt("purpose"));

            await registration.DisposeAsync();
            registration = null;

            var removed = false;
            while (await results.MoveNextAsync())
            {
                var candidate = results.Current;
                if (candidate.ChangeKind == PeelServiceChangeKind.Removed &&
                    candidate.DisplayName == displayName)
                {
                    removed = true;
                    break;
                }
            }

            if (!removed)
            {
                throw new InvalidOperationException("The DNS-SD browser did not observe service removal.");
            }

            // Also verify that deregistration cleared the service for a new
            // browser rather than only changing the existing browse session.
            await Task.Delay(1_000, timeout.Token);
            using var absenceTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(3));
            await AssertServiceAbsentAsync(displayName, absenceTimeout.Token);
        }
        finally
        {
            if (registration is not null)
            {
                await registration.DisposeAsync();
            }
        }
    }

    private static async Task AssertServiceAbsentAsync(
        string displayName,
        CancellationToken cancellationToken)
    {
        var browser = new WindowsDnsSdBrowser();
        try
        {
            await foreach (var candidate in browser
                .BrowseAsync(TestServiceType, cancellationToken)
                .WithCancellation(cancellationToken))
            {
                if (candidate.ChangeKind == PeelServiceChangeKind.Added &&
                    candidate.DisplayName == displayName)
                {
                    throw new InvalidOperationException(
                        "The deregistered DNS-SD service was still visible to a fresh browser.");
                }
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            // No matching service appeared during the bounded observation window.
        }
    }

    private static void Equal<T>(T expected, T actual)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
        {
            throw new InvalidOperationException($"Expected '{expected}', got '{actual}'.");
        }
    }

    private static void Throws<TException>(Action action)
        where TException : Exception
    {
        try
        {
            action();
        }
        catch (TException)
        {
            return;
        }

        throw new InvalidOperationException($"Expected {typeof(TException).Name}.");
    }
}
