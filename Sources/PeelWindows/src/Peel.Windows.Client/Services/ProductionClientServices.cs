using System.IO;
using Peel.Windows.Client.Models;
using Peel.Windows.Protocol;
using Peel.Windows.Transport;
using Peel.Windows.Discovery;

namespace Peel.Windows.Client.Services;

public sealed class ProductionClientServices : IHostDiscoveryService, ISecureConnectionService,
    IWindowListService, IStreamControlService, INormalizedInputService, IAsyncDisposable
{
    private readonly WindowsPairedHostStore credentials;
    private readonly SavedHostAddressStore addresses;
    private readonly ClientHostDiscovery discovery;
    private readonly ClientPinPairing pairing;
    private readonly ClientSession session;
    private readonly MediaFoundationH264DecoderSink decoder;
    private readonly ClientStreamController streams;
    private readonly IPeelPskTransportFactory transport;
    private readonly object viewerGate = new();
    private readonly SemaphoreSlim controlGate = new(1, 1);
    private readonly HashSet<DetachedViewerSession> viewers = new();
    private readonly ClientAudioPreferenceStore audioPreferences;
    private readonly CancellationTokenSource lifetime = new();
    private bool mainVisible = true;
    private bool aggregateVisible = true;
    // 1 while this connection may still adopt default Listen; consumed by the first admitted video.
    private int defaultListenArmed;
    public ClientInputController Input { get; }
    public ClientAudioPlayback Audio { get; }
    /// <summary>Source media for the main viewer's own stream; each detached viewer owns its own.</summary>
    public ClientSourceMediaController MainSourceMedia { get; }
    public TrustedSignalReceiver Signals { get; }
    public TrustedSignalPublisher SignalPublisher { get; }

    public ProductionClientServices() : this(new WindowsPairedHostStore(), new SavedHostAddressStore()) { }

    internal ProductionClientServices(WindowsPairedHostStore credentials, SavedHostAddressStore addresses,
        IPeelServiceBrowser? browser = null, IPeelPskTransportFactory? transport = null, bool useGpuPresentation = true,
        ClientAudioPreferenceStore? audioPreferences = null)
    {
        this.audioPreferences = audioPreferences ?? new ClientAudioPreferenceStore();
        this.credentials = credentials; this.addresses = addresses; discovery = new(credentials, addresses, browser);
        transport ??= new BouncyCastlePskTransportFactory();
        this.transport = transport;
        Signals = new(credentials, transport: transport);
        SignalPublisher = new(credentials, transport: transport);
        pairing = new(transport, credentials);
        decoder = new(gpuPresentation: useGpuPresentation);
        session = new(transport, credentials, discovery, new ClientHelloProfile(
            Environment.MachineName, "PC", Environment.OSVersion.VersionString, "2.0-preview"),
            new ClientSessionOptions { SupportsHevc = decoder.SupportedCodecs.Contains(PeelVideoCodec.Hevc), SupportsAudioPlayback = WaveAudioPlayback.Available, SupportsMicrophone = WaveMicrophoneCapture.Available });
        Audio = new(session, transport, credentials, discovery);
        var video = new ClientVideoSocketSession(transport, credentials, discovery, decoder);
        streams = new(session, session, session, video, PeelVideoCodec.H264, preferHevc: true);
        Input = new(session, streams);
        MainSourceMedia = new(session, streams);
        session.StateChanged += (_, e) => { if (e.State is PeelConnectionState.Disconnected or PeelConnectionState.Error) discovery.ClearEndpoint(); };
        session.StateChanged += (_, e) => Volatile.Write(ref defaultListenArmed, e.State == PeelConnectionState.Connected ? 1 : 0);
        streams.StateChanged += ViewerStreamChanged;
    }

    public event EventHandler? HostsChanged { add => discovery.HostsChanged += value; remove => discovery.HostsChanged -= value; }
    public event EventHandler<string>? DiscoveryFailed { add => discovery.DiscoveryFailed += value; remove => discovery.DiscoveryFailed -= value; }
    public event EventHandler<ConnectionStateChangedEventArgs>? StateChanged { add => session.StateChanged += value; remove => session.StateChanged -= value; }
    public event EventHandler? WindowsChanged { add => session.WindowsChanged += value; remove => session.WindowsChanged -= value; }
    event EventHandler<StreamStateChangedEventArgs>? IStreamControlService.StateChanged { add => streams.StateChanged += value; remove => streams.StateChanged -= value; }
    public event EventHandler<DecodedVideoFrameEventArgs>? FrameAvailable { add => streams.FrameAvailable += value; remove => streams.FrameAvailable -= value; }
    public IReadOnlyList<HostCandidate> DiscoveredHosts => discovery.DiscoveredHosts;
    public IReadOnlyList<HostCandidate> SavedHosts => discovery.SavedHosts;
    public PeelConnectionState State => session.State;
    public HostCandidate? ConnectedHost => session.ConnectedHost;
    public IReadOnlyList<RemoteWindowDescriptor> Windows => session.Windows;
    PeelStreamState IStreamControlService.State => streams.State;
    public uint? StreamingWindowId => streams.StreamingWindowId;
    public bool IsPaired(string hostId) => credentials.IsPaired(hostId);
    public string? LoadError => credentials.LoadError;
    public Task StartAsync(CancellationToken token) => discovery.StartAsync(token);
    public Task RefreshAsync(CancellationToken token) => discovery.RefreshAsync(token);
    public Task StopAsync(CancellationToken token) => discovery.StopAsync(token);
    Task IWindowListService.StartAsync(CancellationToken token) => ((IWindowListService)session).StartAsync(token);
    Task IWindowListService.StopAsync(CancellationToken token) => ((IWindowListService)session).StopAsync(token);
    Task IStreamControlService.StartAsync(RemoteWindowDescriptor window, CancellationToken token)
    {
        lock (viewerGate) if (viewers.Any(v => v.Window.Id == window.Id))
            throw new InvalidOperationException("This app is already open in its own peeled window.");
        Input.Disable(); return streams.StartAsync(window, token);
    }
    Task IStreamControlService.StopAsync(CancellationToken token)
    { Input.Disable(); return streams.StopAsync(token); }

    public async Task ConnectAsync(HostCandidate host, CancellationToken token)
    {
        Input.Disable(); discovery.PinEndpoint(host);
        try { await session.ConnectAsync(host, token).ConfigureAwait(false); }
        catch { discovery.ClearEndpoint(); throw; }
    }

    public async Task DisconnectAsync(CancellationToken token)
    {
        Audio.Cancel();
        DisableAllInputs();
        await session.DisconnectAsync(token).ConfigureAwait(false);
        await Audio.StopAsync().ConfigureAwait(false);
        DetachedViewerSession[] owned; lock (viewerGate) owned = viewers.ToArray();
        foreach (var viewer in owned) await viewer.DisposeAsync().ConfigureAwait(false);
    }

    public async Task PairAsync(HostCandidate host, string pin, CancellationToken token)
    {
        await Signals.StopAsync().ConfigureAwait(false);
        await SignalPublisher.StopAsync().ConfigureAwait(false);
        await DisconnectAsync(token).ConfigureAwait(false);
        await pairing.PairAsync(discovery.PairingService(host.StableHostId), pin, token).ConfigureAwait(false);
        discovery.NotifyChanged();
        // The Mac replaces its listener asynchronously after pairing. Connect is an explicit subsequent action.
    }

    public async Task ForgetAsync(HostCandidate host, CancellationToken token)
    {
        await Signals.StopAsync().ConfigureAwait(false);
        await SignalPublisher.StopAsync().ConfigureAwait(false);
        if (session.ConnectedHost?.StableHostId == host.StableHostId) await DisconnectAsync(token).ConfigureAwait(false);
        credentials.Forget(host.StableHostId); addresses.Remove(host.StableHostId); discovery.NotifyChanged();
    }

    public async Task SaveAddressAsync(HostCandidate host, string address, int port, CancellationToken token)
    {
        if (!credentials.IsPaired(host.StableHostId)) throw new InvalidOperationException("Pair nearby before saving a remote address.");
        var record = new SavedHostAddress(host.StableHostId, host.DisplayName, address, port);
        SavedHostAddressStore.Validate(record);
        if (session.ConnectedHost?.StableHostId == host.StableHostId) await DisconnectAsync(token).ConfigureAwait(false);
        addresses.Save(record); discovery.NotifyChanged();
    }

    public async Task RemoveAddressAsync(HostCandidate host, CancellationToken token)
    {
        if (session.ConnectedHost?.StableHostId == host.StableHostId) await DisconnectAsync(token).ConfigureAwait(false);
        addresses.Remove(host.StableHostId); discovery.NotifyChanged();
    }

    public Task RefreshWindowsAsync(CancellationToken token) => session.RefreshWindowsAsync(token);
    public Task<MachineStatusMessage> RequestMachineStatusAsync(CancellationToken token) => session.RequestMachineStatusAsync(token);
    public async Task<DetachedViewerSession> OpenViewerAsync(RemoteWindowDescriptor window, CancellationToken token)
    {
        if (streams.StreamingWindowId == window.Id) await streams.StopAsync(token).ConfigureAwait(false);
        DetachedViewerSession viewer;
        lock (viewerGate)
        {
            if (viewers.Count >= 8) throw new InvalidOperationException("At most eight detached windows can receive at once.");
            if (viewers.Any(v => v.Window.Id == window.Id)) throw new InvalidOperationException("This app is already open in a peeled window.");
            viewer = new(window, session, transport, credentials, discovery, v =>
            {
                v.Streams.StateChanged -= ViewerStreamChanged;
                lock (viewerGate) viewers.Remove(v);
            });
            viewers.Add(viewer);
            viewer.Streams.StateChanged += ViewerStreamChanged;
        }
        try { await viewer.Streams.StartAsync(window, token).ConfigureAwait(false); return viewer; }
        catch { await viewer.DisposeAsync().ConfigureAwait(false); throw; }
    }
    public async Task EnableViewerControlAsync(ClientInputController selected, CancellationToken token)
    {
        await controlGate.WaitAsync(token).ConfigureAwait(false);
        try
        {
            ClientInputController[] inputs;
            lock (viewerGate) inputs = [Input, .. viewers.Select(v => v.Input)];
            if (!inputs.Contains(selected)) throw new InvalidOperationException("This viewer is no longer connected.");
            foreach (var input in inputs) await input.ReleaseAsync(token).ConfigureAwait(false);
            await selected.EnableAsync(token).ConfigureAwait(false);
        }
        finally { controlGate.Release(); }
    }
    public void DisableAllInputs()
    {
        Input.Disable(); lock (viewerGate) foreach (var viewer in viewers) viewer.Input.Disable();
    }
    public Task UpdateViewerVisibilityAsync(CancellationToken token) => SendAggregateVisibilityAsync(token);
    public Task SetVisibilityAsync(bool visible, CancellationToken token)
    {
        mainVisible = visible;
        if (!visible) Input.Disable();
        return SendAggregateVisibilityAsync(token);
    }
    private Task SendAggregateVisibilityAsync(CancellationToken token)
    {
        bool visible, returned;
        lock (viewerGate)
        {
            visible = mainVisible || viewers.Any(v => v.IsVisible);
            returned = visible && !aggregateVisible;
            aggregateVisible = visible;
        }
        // Hiding stops audio without recording an Off; showing again may adopt default Listen once more.
        if (!visible) Audio.Cancel();
        else if (returned && session.State == PeelConnectionState.Connected) Volatile.Write(ref defaultListenArmed, 1);
        return session.State == PeelConnectionState.Connected
            ? session.SendClientMessageAsync(new ClientVisibilityMessage(visible), session.SessionGeneration, token)
            : Task.CompletedTask;
    }

    /// <summary>Explicit Listen: clears this pairing's saved Off, then starts playback (never voice).</summary>
    public Task StartListeningAsync(CancellationToken token)
    {
        if (session.ActivePairingId is { } pairingId) audioPreferences.SetExplicitOff(pairingId, false);
        return Audio.StartAsync(token);
    }

    /// <summary>Explicit Stop: saves Off for this pairing so reconnect and relaunch keep it off.</summary>
    public Task StopListeningAsync()
    {
        if (session.ActivePairingId is { } pairingId) audioPreferences.SetExplicitOff(pairingId, true);
        Volatile.Write(ref defaultListenArmed, 0);
        return Audio.StopAsync();
    }

    // Raised once per decoded frame while streaming: the armed check is the only per-frame work.
    private void ViewerStreamChanged(object? sender, StreamStateChangedEventArgs e)
    {
        if (e.State != PeelStreamState.Streaming || Volatile.Read(ref defaultListenArmed) == 0 ||
            Interlocked.Exchange(ref defaultListenArmed, 0) == 0) return;
        // Off the video receive path: the first preference read may touch disk.
        _ = Task.Run(AdoptDefaultListenAsync);
    }

    /// <summary>
    /// The first admitted actual video of a paired source adopts playback once, unless that pairing
    /// was explicitly turned Off. One ClientAudioPlayback is the only owner; voice and microphone
    /// stay explicit; Host consent, proof, ticket and generation checks are unchanged.
    /// </summary>
    private async Task AdoptDefaultListenAsync()
    {
        if (session.AudioPlaybackIdentity is not { } identity) return;
        bool visible; lock (viewerGate) visible = mainVisible || viewers.Any(v => v.IsVisible);
        if (!visible || Audio.IsActive || audioPreferences.IsExplicitOff(identity.PairingId)) return;
        try { await Audio.StartDefaultAsync(identity.Generation, lifetime.Token).ConfigureAwait(false); }
        catch (Exception error) when (error is IOException or InvalidOperationException or OperationCanceledException or
            ObjectDisposedException or InvalidDataException or System.ComponentModel.Win32Exception)
        {
            // Unavailable Host sharing, a changed session or teardown leave audio off; Status explains.
        }
    }

    public Task SendPointerAsync(NormalizedPointerInput input, CancellationToken token) => Input.SendPointerAsync(input, token);
    public Task SendKeyAsync(NormalizedKeyInput input, CancellationToken token) => Input.SendKeyAsync(input, token);

    public async ValueTask DisposeAsync()
    {
        Volatile.Write(ref defaultListenArmed, 0);
        lifetime.Cancel();
        streams.StateChanged -= ViewerStreamChanged;
        MainSourceMedia.Dispose();
        await Signals.DisposeAsync().ConfigureAwait(false);
        await SignalPublisher.DisposeAsync().ConfigureAwait(false);
        await Audio.DisposeAsync().ConfigureAwait(false);
        Input.Dispose();
        DetachedViewerSession[] owned; lock (viewerGate) owned = viewers.ToArray();
        foreach (var viewer in owned) await viewer.DisposeAsync().ConfigureAwait(false);
        await streams.DisposeAsync().ConfigureAwait(false);
        await session.DisposeAsync().ConfigureAwait(false);
        await decoder.DisposeAsync().ConfigureAwait(false);
        await discovery.DisposeAsync().ConfigureAwait(false);
        lifetime.Dispose();
    }
}
