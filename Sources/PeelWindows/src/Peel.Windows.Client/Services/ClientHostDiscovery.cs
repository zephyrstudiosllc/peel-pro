using System.IO;
using Peel.Windows.Client.Models;
using Peel.Windows.Discovery;

namespace Peel.Windows.Client.Services;

public sealed class ClientHostDiscovery : IHostDiscoveryService, IClientHostResolver, IAsyncDisposable
{
    private readonly object gate = new();
    private readonly SemaphoreSlim lifecycle = new(1, 1);
    private readonly IPeelServiceBrowser browser;
    private readonly WindowsPairedHostStore credentials;
    private readonly SavedHostAddressStore addresses;
    private readonly Dictionary<string, PeelDiscoveredService> services = new(StringComparer.Ordinal);
    private CancellationTokenSource? cancellation;
    private Task[] workers = [];
    private HostCandidate? pinnedEndpoint;
    private bool disposed;

    public ClientHostDiscovery(WindowsPairedHostStore credentials, SavedHostAddressStore addresses,
        IPeelServiceBrowser? browser = null)
    {
        this.credentials = credentials;
        this.addresses = addresses;
        this.browser = browser ?? new WindowsDnsSdBrowser();
        addresses.Prune(credentials.Snapshot().Select(p => p.DeviceId).ToHashSet(StringComparer.Ordinal));
    }

    public event EventHandler? HostsChanged;
    public event EventHandler<string>? DiscoveryFailed;

    public IReadOnlyList<HostCandidate> DiscoveredHosts
    {
        get
        {
            lock (gate) return services.Values.Where(s => s.ServiceType == PeelServiceType.Control)
                .OrderBy(s => s.InstanceName, StringComparer.Ordinal)
                .GroupBy(s => s.HostId, StringComparer.Ordinal).Select(g => Candidate(g.First(), false))
                .OrderBy(h => h.DisplayName, StringComparer.OrdinalIgnoreCase).ToArray();
        }
    }

    public IReadOnlyList<HostCandidate> SavedHosts => credentials.Snapshot().Select(p =>
    {
        var direct = addresses.Snapshot().SingleOrDefault(a => a.HostId == p.DeviceId);
        var nearby = DiscoveredHosts.FirstOrDefault(h => h.StableHostId == p.DeviceId);
        return direct is not null
            ? new HostCandidate(p.DeviceId, "", direct.Label, direct.Address, direct.Port, true, true)
            : new HostCandidate(p.DeviceId, nearby?.ServiceInstanceName ?? "", p.DisplayName,
                nearby?.Address ?? "", nearby?.Port ?? 0, true);
    }).ToArray();

    public async Task StartAsync(CancellationToken token)
    {
        await lifecycle.WaitAsync(token).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (cancellation is not null) return;
            cancellation = CancellationTokenSource.CreateLinkedTokenSource(token);
            workers = [WatchAsync(PeelServiceType.Control, cancellation.Token),
                WatchAsync(PeelServiceType.Pairing, cancellation.Token)];
        }
        finally { lifecycle.Release(); }
    }

    public async Task RefreshAsync(CancellationToken token)
    {
        await StopAsync(token).ConfigureAwait(false);
        await StartAsync(token).ConfigureAwait(false);
    }

    public async Task StopAsync(CancellationToken token)
    {
        await lifecycle.WaitAsync(token).ConfigureAwait(false);
        try
        {
            cancellation?.Cancel();
            await Task.WhenAll(workers).ConfigureAwait(false);
            cancellation?.Dispose(); cancellation = null; workers = [];
            lock (gate) services.Clear();
            NotifyChanged();
        }
        finally { lifecycle.Release(); }
    }

    private async Task WatchAsync(string type, CancellationToken token)
    {
        try
        {
            await foreach (var service in browser.BrowseAsync(type, token).ConfigureAwait(false))
            {
                var key = $"{type}|{service.InterfaceIndex}|{service.InstanceName}";
                lock (gate)
                {
                    if (token.IsCancellationRequested) return;
                    if (service.ChangeKind == PeelServiceChangeKind.Removed) services.Remove(key);
                    else if (ValidService(service, type) && (services.ContainsKey(key) || services.Count < 256))
                        services[key] = service;
                    else services.Remove(key);
                }
                NotifyChanged();
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (Exception e) when (e is IOException or InvalidOperationException or System.ComponentModel.Win32Exception
            or PlatformNotSupportedException)
        {
            if (!token.IsCancellationRequested) DiscoveryFailed?.Invoke(this, "Nearby discovery is unavailable. " + e.Message);
        }
    }

    internal static bool ValidService(PeelDiscoveredService s, string type) => s.ServiceType == type
        && Guid.TryParse(s.HostId, out _) && s.Port is > 0 && !string.IsNullOrWhiteSpace(s.HostName)
        && s.HostName.Length <= 253 && !s.HostName.Any(char.IsControl)
        && s.DisplayName.Length is > 0 and <= 256 && !s.DisplayName.Any(char.IsControl)
        && s.InstanceName.Length <= 1024;

    private static HostCandidate Candidate(PeelDiscoveredService s, bool saved) =>
        new(s.HostId!, s.InstanceName, s.DisplayName, s.HostName!, s.Port!.Value, saved);

    internal PeelDiscoveredService PairingService(string hostId)
    {
        lock (gate) return services.Values.FirstOrDefault(s => s.ServiceType == PeelServiceType.Pairing && s.HostId == hostId)
            ?? throw new IOException("This computer has no current PIN pairing advertisement. Open Pair in Peel Pro on that computer.");
    }

    internal void PinEndpoint(HostCandidate selected)
    {
        if (selected.IsDirect)
        {
            var address = addresses.Snapshot().SingleOrDefault(a => a.HostId == selected.StableHostId);
            if (!credentials.IsPaired(selected.StableHostId) || address is null
                || address.Address != selected.Address || address.Port != selected.Port)
                throw new InvalidOperationException("This saved address or pairing has changed. Select it again.");
            lock (gate) pinnedEndpoint = selected;
        }
        else
        {
            var current = DiscoveredHosts.FirstOrDefault(h => h.StableHostId == selected.StableHostId)
                ?? throw new IOException("This computer is offline. Add a private/VPN address for an existing pairing.");
            lock (gate) pinnedEndpoint = current;
        }
    }

    public ValueTask<HostCandidate?> ResolveFreshAsync(string hostId, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        lock (gate) return ValueTask.FromResult(pinnedEndpoint?.StableHostId == hostId ? pinnedEndpoint : null);
    }

    internal void ClearEndpoint() { lock (gate) pinnedEndpoint = null; }
    internal void NotifyChanged() => HostsChanged?.Invoke(this, EventArgs.Empty);

    public async ValueTask DisposeAsync()
    {
        disposed = true;
        await StopAsync(CancellationToken.None).ConfigureAwait(false);
        ClearEndpoint();
    }
}
