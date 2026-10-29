using System.Text;
using System.Text.Json;
using Peel.Linux;
using Peel.Windows.Client.Models;
using Peel.Windows.Client.Services;
using Peel.Windows.Transport;
using Peel.Linux.Host;
using Peel.Linux.HostUI;

if (!OperatingSystem.IsLinux()) { Console.Error.WriteLine("Peel Pro Linux requires a native Linux GTK/portal session."); return 2; }
if (args.Length > 0) return await LinuxPairing.Run(args);
using var app = new LinuxApplication();
return app.Run();

internal sealed class LinuxApplication : IDisposable
{
    private readonly object state = new();
    private readonly SemaphoreSlim lifecycle = new(1, 1);
    private CancellationTokenSource lifetime = new();
    private ulong generation;
    private bool shuttingDown;
    private readonly LinuxHostUIController hostUI;
    private ClientSession? control;
    private ClientStreamController? streaming;
    private LinuxDecoder? decoder;
    private CancellationTokenSource? sessionLease;
    private CancellationTokenSource? streamLease;
    private LinuxReceiverControls? media; // current connection's audio/source-control owner; read under state
    private readonly LinuxReceiverPreferences preferences = LinuxReceiverPreferences.OpenDefault();
    private readonly IReceiverAudioBackend audioBackend = new NativeReceiverAudioBackend();
    private readonly NativeUI.ViewerControl viewerControl;
    private readonly NativeUI.Connect connect;
    private readonly NativeUI.OpenWindow open;
    private readonly NativeUI.Disconnect disconnect;
    private readonly NativeUI.CloseWindow close;
    public LinuxApplication() { connect = Connect; open = Open; disconnect = Disconnect; close = CloseWindow; viewerControl = ViewerCommand;
        hostUI=new(new LinuxHostUIChannel(),view=>new LinuxHostComposition(view,new LinuxHostDiscoveryRegistrar(new LinuxAvahiNative()),LinuxHostBindPlan.DefaultDualStack()),FenceReceiver,DrainReceiver); }
    public int Run()
    {
        hostUI.Register();
        NativeUI.peel_linux_viewer_register(viewerControl, IntPtr.Zero);
        NativeUI.peel_linux_viewer_visibility(preferences.ShowVolume ? 1 : 0, preferences.ShowMedia ? 1 : 0);
        int code=NativeUI.peel_linux_run(connect, open, disconnect, close, IntPtr.Zero);hostUI.AfterRun();return code;
    }
    private (ulong generation, CancellationToken token) Replace()
    {
        lock (state) { lifetime.Cancel(); lifetime.Dispose(); lifetime = new(); return (++generation, lifetime.Token); }
    }
    private bool Current(ulong value) { lock (state) return value == generation && !lifetime.IsCancellationRequested; }
    private void Connect(string id, string address, int port, IntPtr unused)
    {
        lock(state)if(shuttingDown)return;
        if (string.IsNullOrWhiteSpace(id) || id.Length > 1024 || string.IsNullOrWhiteSpace(address) || address.Length > 1024
            || address.Contains('/') || address.Any(char.IsControl) || id.Any(char.IsControl) || port is < 1 or > 65535)
        { NativeUI.peel_linux_status("Enter the existing paired computer ID and its private-network/VPN address."); return; }
        var operation = Replace(); NativeUI.peel_linux_receiver_generation(operation.generation); NativeUI.peel_linux_windows("[]", operation.generation);
        NativeUI.peel_linux_status("Connecting to the paired computer…");
        _ = Task.Run(async () =>
        {
            await lifecycle.WaitAsync();
            try
            {
                if (!Current(operation.generation)) return;
                await CloseCurrent(); if (!Current(operation.generation)) return;
                var host = new HostCandidate(id, id, id, address, port, true);
                var saved = new SavedComputer(host); var tls = new BouncyCastlePskTransportFactory();
                // Playback is advertised only when an actual native output reached READY now.
                bool audioReady = audioBackend.Probe();
                var next = new ClientSession(tls, saved, saved,
                    new ClientHelloProfile(Environment.MachineName, "Linux desktop", Environment.OSVersion.VersionString, "2.0.0"),
                    new ClientSessionOptions { SupportsAudioPlayback = audioReady });
                control = next;
                next.WindowsChanged += (_, _) =>
                {
                    if (!Current(operation.generation)) return;
                    NativeUI.peel_linux_windows(JsonSerializer.Serialize(next.Windows.Select(w => new { id = w.Id, title = $"{w.OwnerName} — {w.Title}" })), operation.generation);
                };
                sessionLease = CancellationTokenSource.CreateLinkedTokenSource(operation.token); sessionLease.CancelAfter(TimeSpan.FromSeconds(15));
                await next.ConnectAsync(host, sessionLease.Token);
                sessionLease.CancelAfter(Timeout.InfiniteTimeSpan);
                if (!Current(operation.generation)) return;
                await ((IWindowListService)next).StartAsync(operation.token);
                decoder = new LinuxDecoder(operation.generation);
                var video = new ClientVideoSocketSession(tls, saved, saved, decoder,
                    new ClientVideoSocketOptions { MaximumPacketBytes = 8 * 1024 * 1024 + 31, MaximumDimension = 8192 });
                streaming = new ClientStreamController(next, next, next, video, Peel.Windows.Protocol.PeelVideoCodec.H264);
                string pairing = next.ActivePairingId ?? throw new InvalidOperationException("The paired session has no pairing.");
                long controlGeneration = next.SessionGeneration;
                bool sourceAudio = next.HostSupports(ClientSession.AudioPlaybackCapability);
                var playback = audioReady ? new LinuxReceiverAudio(next, tls, saved, saved, audioBackend, operation.generation, controlGeneration) : null;
                var coordinator = new LinuxReceiverControls(pairing, playback, sourceAudio,
                    new LinuxSourceMediaClient(next, controlGeneration, pairing, LinuxSourceVolumeScope.Selected), preferences,
                    (window, snapshot) => PublishViewer(operation.generation, window, snapshot));
                lock (state) media = coordinator;
                decoder.FirstFrameAdmitted += window => { if (Current(operation.generation)) Forget(coordinator.VideoAdmittedAsync(window)); };
                streaming.StateChanged += (_, change) =>
                {
                    if (change.State is PeelStreamState.Stopped or PeelStreamState.Error && Current(operation.generation)) Forget(coordinator.StreamEndedAsync());
                };
                string audioLine = !audioReady ? " Audio playback isn't available: no working audio output was found on this computer."
                    : !sourceAudio ? " That computer doesn't share audio with this one."
                    : preferences.IsAudioOff(pairing) ? " Listen is off for this computer; turn it on in the viewer."
                    : " Its audio plays here while a window is open.";
                NativeUI.peel_linux_status("Connected. Select one of its windows below to open it in its own viewer." + audioLine + " Keyboard, pointer and clipboard are not sent.");
            }
            catch (Exception error) when (error is IOException or InvalidDataException or OperationCanceledException or InvalidOperationException or JsonException or FormatException)
            { if (Current(operation.generation)) NativeUI.peel_linux_status("Connection unavailable. Check the existing pairing, Secret Service and saved endpoint."); await CloseCurrent(); }
            finally { lifecycle.Release(); }
        });
    }
    private void Open(uint window, ulong displayedGeneration, IntPtr unused)
    {
        if (!Current(displayedGeneration)) return;
        _ = Task.Run(async () =>
        {
            await lifecycle.WaitAsync();
            try
            {
                if (!Current(displayedGeneration) || control is null || streaming is null) return;
                var source = control.Windows.FirstOrDefault(w => w.Id == window);
                if (source is null) return;
                CancellationToken token; lock (state) token = lifetime.Token;
                streamLease?.Cancel(); streamLease?.Dispose();
                streamLease = CancellationTokenSource.CreateLinkedTokenSource(token); streamLease.CancelAfter(TimeSpan.FromSeconds(15));
                await streaming.StartAsync(source, streamLease.Token);
                streamLease.CancelAfter(Timeout.InfiniteTimeSpan);
            }
            catch (Exception error) when (error is IOException or InvalidDataException or OperationCanceledException or InvalidOperationException)
            { if (Current(displayedGeneration)) NativeUI.peel_linux_status("That window’s video stream could not start. Select it again, or Disconnect and Connect."); }
            finally { lifecycle.Release(); }
        });
    }
    private void CloseWindow(uint window, ulong displayedGeneration, IntPtr unused)
    {
        if (!Current(displayedGeneration)) return;
        _ = Task.Run(async () =>
        {
            await lifecycle.WaitAsync();
            try {
                if (Current(displayedGeneration) && streaming?.StreamingWindowId == window)
                    await streaming.StopAsync(CancellationToken.None);
            }
            catch (Exception error) when (error is IOException or InvalidOperationException) { }
            finally { lifecycle.Release(); }
        });
    }
    private void Disconnect(IntPtr unused)
    {
        lock(state)if(shuttingDown)return;
        var operation = Replace(); NativeUI.peel_linux_receiver_generation(operation.generation); NativeUI.peel_linux_windows("[]", operation.generation);
        _ = Task.Run(async () =>
        {
            await lifecycle.WaitAsync();
            try { if (Current(operation.generation)) { await CloseCurrent(); NativeUI.peel_linux_status("Disconnected."); } }
            finally { lifecycle.Release(); }
        });
    }
    private async Task CloseCurrent()
    {
        // Audio and source controls go first so their end-of-audio request can still use the live session.
        LinuxReceiverControls? owned; lock (state) { owned = media; media = null; }
        if (owned is not null) await owned.DisposeAsync();
        streamLease?.Cancel();
        if (streaming is not null) { await streaming.DisposeAsync(); streaming = null; }
        streamLease?.Dispose(); streamLease = null;
        decoder?.Dispose(); decoder = null;
        sessionLease?.Cancel();
        if (control is not null) { await control.DisposeAsync(); control = null; }
        sessionLease?.Dispose(); sessionLease = null;
    }
    /// <summary>GTK-main viewer callback: copy and queue only. Settings carry window 0.</summary>
    private void ViewerCommand(uint window, ulong displayedGeneration, int command, double value, IntPtr unused)
    {
        if (command is 9 or 10)
        {
            // Presentation only: never touches playback, the source or grants.
            preferences.SetVisibility(command == 9 ? value != 0 : null, command == 10 ? value != 0 : null);
            Forget(Task.Run(preferences.Save));
            return;
        }
        LinuxReceiverControls? target;
        lock (state) { if (shuttingDown || displayedGeneration != generation || lifetime.IsCancellationRequested) return; target = media; }
        if (target is null || window == 0) return;
        // Bind now, on the GTK thread, to the exact stream this viewer shows. A click that waits
        // in the serialized queue across close/reopen of the same window ID is then stale.
        if (target.Capture(window) is not { } binding) return;
        target.Enqueue(binding, command, value);
    }
    private void PublishViewer(ulong displayedGeneration, uint window, ViewerSnapshot snapshot)
    {
        if (!Current(displayedGeneration)) return;
        var native = new NativeUI.ViewerState
        {
            Audio = snapshot.Audio, ListenEnabled = snapshot.ListenEnabled ? 1 : 0, MediaEnabled = snapshot.MediaEnabled ? 1 : 0,
            VolumeSupported = snapshot.Volume.Supported ? 1 : 0, CanSetVolume = snapshot.Volume.CanSetVolume ? 1 : 0,
            CanSetMute = snapshot.Volume.CanSetMute ? 1 : 0, Muted = snapshot.Volume.Muted is { } muted ? (muted ? 1 : 0) : -1,
            Volume = snapshot.Volume.Volume ?? -1,
        };
        string note = snapshot.Note;
        while (Encoding.UTF8.GetByteCount(note) > 500) note = note[..^1];
        NativeUI.peel_linux_viewer_state(displayedGeneration, window, ref native, note);
    }
    private static void Forget(Task task) => task.ContinueWith(static t => _ = t.Exception, CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted, TaskScheduler.Default);
    private void FenceReceiver()
    {
        ulong next;lock(state){if(shuttingDown)return;shuttingDown=true;lifetime.Cancel();next=++generation;}
        NativeUI.peel_linux_receiver_generation(next);NativeUI.peel_linux_windows("[]",next);
    }
    private async Task DrainReceiver(){await lifecycle.WaitAsync().ConfigureAwait(false);try{await CloseCurrent().ConfigureAwait(false);}finally{lifecycle.Release();}}
    public void Dispose()
    {
        lock (state) lifetime.Cancel();
        hostUI.AfterRun();
        // Native callback tasks serialize through lifecycle; wait for ownership
        // before releasing decoder/transport resources after the GTK loop exits.
        lifecycle.Wait();
        try { CloseCurrent().GetAwaiter().GetResult(); }
        finally { lifecycle.Release(); lifetime.Dispose(); }
        GC.KeepAlive(connect); GC.KeepAlive(open); GC.KeepAlive(disconnect); GC.KeepAlive(close); GC.KeepAlive(viewerControl);
    }
}
