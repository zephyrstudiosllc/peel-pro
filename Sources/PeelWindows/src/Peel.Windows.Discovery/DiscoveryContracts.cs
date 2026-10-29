namespace Peel.Windows.Discovery;

public static class PeelServiceType
{
    public const string Control = "_peel._tcp";
    public const string Pairing = "_peelpair._tcp";
    public const string Domain = "local";

    public static string ToQueryName(string serviceType)
    {
        var cleanType = serviceType.Trim().TrimEnd('.');
        if (!cleanType.StartsWith('_') || !cleanType.EndsWith("._tcp", StringComparison.Ordinal))
        {
            throw new ArgumentException("DNS-SD service types must look like _name._tcp.", nameof(serviceType));
        }

        return $"{cleanType}.{Domain}";
    }
}

public enum PeelServiceChangeKind
{
    Added,
    Removed,
}

public sealed record PeelDiscoveredService(
    PeelServiceChangeKind ChangeKind,
    string InstanceName,
    string DisplayName,
    string ServiceType,
    string? HostName,
    ushort? Port,
    IReadOnlyDictionary<string, byte[]> TxtRecords,
    uint InterfaceIndex = 0)
{
    public string? HostId => GetUtf8Txt("hostId");

    public string? PairingMode => GetUtf8Txt("pairMode");

    public string? TlsPskOrder => GetUtf8Txt("tlsPSKOrder");

    public string? PairingSaltBase64
    {
        get
        {
            string? value = GetUtf8Txt("pinSalt");
            if (value is null)
            {
                return null;
            }

            // Windows DnsServiceResolve normalizes trailing '=' characters out of
            // TXT property values. PIN salts are known Base64, so restore only the
            // unambiguous padding required to reach a four-character boundary.
            int missingPadding = (value.Length % 4) switch
            {
                2 => 2,
                3 => 1,
                _ => 0,
            };
            return missingPadding == 0 ? value : value.PadRight(value.Length + missingPadding, '=');
        }
    }

    public string? GetUtf8Txt(string key) =>
        TxtRecords.TryGetValue(key, out var value) ? System.Text.Encoding.UTF8.GetString(value) : null;
}

public sealed record PeelServiceAdvertisement(
    string DisplayName,
    string ServiceType,
    ushort Port,
    IReadOnlyDictionary<string, byte[]> TxtRecords,
    string? HostName = null);

public interface IPeelServiceBrowser
{
    IAsyncEnumerable<PeelDiscoveredService> BrowseAsync(
        string serviceType,
        CancellationToken cancellationToken = default);
}

public interface IPeelServiceRegistrar
{
    ValueTask<IAsyncDisposable> RegisterAsync(
        PeelServiceAdvertisement advertisement,
        CancellationToken cancellationToken = default);
}

public static class PeelDiscoveryPlatform
{
    public static void RequireWindows()
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10))
        {
            throw new PlatformNotSupportedException(
                "Peel DNS-SD uses Windows dnsapi.dll and requires Windows 10 or later.");
        }
    }
}
