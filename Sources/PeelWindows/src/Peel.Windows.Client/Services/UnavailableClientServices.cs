using Peel.Windows.Client.Models;

namespace Peel.Windows.Client.Services;

public sealed class UnavailableClientServices :
    IHostDiscoveryService,
    ISecureConnectionService,
    IWindowListService,
    IStreamControlService,
    INormalizedInputService
{
    private readonly string _reason;

    public UnavailableClientServices(string reason)
    {
        _reason = reason;
    }

    public event EventHandler? HostsChanged
    {
        add { }
        remove { }
    }

    public event EventHandler<ConnectionStateChangedEventArgs>? StateChanged
    {
        add { }
        remove { }
    }

    public event EventHandler? WindowsChanged
    {
        add { }
        remove { }
    }

    event EventHandler<StreamStateChangedEventArgs>? IStreamControlService.StateChanged
    {
        add { }
        remove { }
    }

    public event EventHandler<DecodedVideoFrameEventArgs>? FrameAvailable
    {
        add { }
        remove { }
    }

    public IReadOnlyList<HostCandidate> DiscoveredHosts { get; } = Array.Empty<HostCandidate>();

    public IReadOnlyList<HostCandidate> SavedHosts { get; } = Array.Empty<HostCandidate>();

    public PeelConnectionState State => PeelConnectionState.Error;

    public HostCandidate? ConnectedHost => null;

    public IReadOnlyList<RemoteWindowDescriptor> Windows { get; } = Array.Empty<RemoteWindowDescriptor>();

    PeelStreamState IStreamControlService.State => PeelStreamState.Error;

    public uint? StreamingWindowId => null;

    public Task StartAsync(CancellationToken cancellationToken) => Unavailable();

    Task IWindowListService.StartAsync(CancellationToken cancellationToken) => Unavailable();

    Task IStreamControlService.StartAsync(
        RemoteWindowDescriptor window,
        CancellationToken cancellationToken) => Unavailable();

    public Task RefreshAsync(CancellationToken cancellationToken) => Unavailable();

    Task IHostDiscoveryService.StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;

    Task IWindowListService.StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;

    Task IStreamControlService.StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;

    public Task ConnectAsync(HostCandidate host, CancellationToken cancellationToken) => Unavailable();

    public Task DisconnectAsync(CancellationToken cancellationToken) => Task.CompletedTask;

    public Task SendPointerAsync(
        NormalizedPointerInput input,
        CancellationToken cancellationToken) => Unavailable();

    public Task SendKeyAsync(
        NormalizedKeyInput input,
        CancellationToken cancellationToken) => Unavailable();

    private Task Unavailable() => Task.FromException(new ClientCapabilityUnavailableException(_reason));
}
