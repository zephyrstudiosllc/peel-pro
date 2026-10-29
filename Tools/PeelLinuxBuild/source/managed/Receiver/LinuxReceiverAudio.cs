using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using Peel.Windows.Client.Models;
using Peel.Windows.Client.Services;
using Peel.Windows.Protocol;
namespace Peel.Linux;

internal interface IReceiverAudioOutput : IDisposable
{
    /// <summary>1 queued, 0 dropped at the bounded queue, -1 failed or stale.</summary>
    int Push(byte[] pcm);
}

internal interface IReceiverAudioBackend
{
    bool Probe();
    IReceiverAudioOutput? Open(ulong receiverGeneration);
}

/// <summary>The control-session seam the playback owner needs; ClientSession implements it.</summary>
internal interface IReceiverAudioSession
{
    long SessionGeneration { get; }
    event EventHandler<ConnectionStateChangedEventArgs>? StateChanged;
    event EventHandler<AudioStateEventArgs>? AudioStateChanged;
    Task<AudioAuthorization> BeginAudioPlaybackAsync(long generation, CancellationToken token);
    Task EndAudioAsync(string requestId, long generation);
}

internal sealed class NativeReceiverAudioBackend : IReceiverAudioBackend
{
    public bool Probe()
    {
        try { return NativeUI.peel_linux_audio_available() == 1; }
        catch (Exception error) when (error is DllNotFoundException or EntryPointNotFoundException) { return false; }
    }

    public IReceiverAudioOutput? Open(ulong receiverGeneration)
    {
        IntPtr handle = NativeUI.peel_linux_audio_new(receiverGeneration);
        return handle == IntPtr.Zero ? null : new NativeReceiverAudioOutput(handle);
    }
}

/// <summary>Serializes push/free on one native handle as the C contract requires.</summary>
internal sealed class NativeReceiverAudioOutput : IReceiverAudioOutput
{
    private readonly object gate = new();
    private IntPtr handle;
    internal NativeReceiverAudioOutput(IntPtr handle) => this.handle = handle;
    public int Push(byte[] pcm) { lock (gate) return handle == IntPtr.Zero ? -1 : NativeUI.peel_linux_audio_push(handle, pcm, (nuint)pcm.Length); }
    public void Dispose() { lock (gate) { if (handle == IntPtr.Zero) return; NativeUI.peel_linux_audio_free(handle); handle = IntPtr.Zero; } }
}

/// <summary>PEAU v1 downlink timeline. A re-announced format restarts it; a sequence or
/// sample-time regression asks the owner to drain and recreate the native sink.</summary>
internal sealed class PeelAudioTimeline
{
    internal enum Result { Format, Continue, Reset }
    private ulong? lastSequence;
    private long nextSampleTime = -1;

    internal Result Admit(AudioPacket packet)
    {
        if (packet.Direction != 0) throw new InvalidDataException("Audio direction is not source playback.");
        if (packet.Kind == 0) { lastSequence = null; nextSampleTime = -1; return Result.Format; }
        if (packet.Kind != 1 || packet.Payload.Length != AudioPacket.Frames * 2 * 2 || packet.SampleTime < 0 || packet.SampleTime > long.MaxValue - AudioPacket.Frames)
            throw new InvalidDataException("Audio packet is not 20 ms S16LE 48 kHz stereo.");
        bool regressed = lastSequence is { } sequence && packet.Sequence <= sequence || nextSampleTime >= 0 && packet.SampleTime < nextSampleTime;
        lastSequence = packet.Sequence; nextSampleTime = packet.SampleTime + AudioPacket.Frames;
        return regressed ? Result.Reset : Result.Continue;
    }
}

internal enum ReceiverAudioPhase { Idle, Starting, Playing, Failed }

/// <summary>The one current playback owner for one control generation: audioSessionRequest,
/// challenge/HMAC proof, auxiliary TLS audioStreamHello, bounded PEAU reading and native
/// playback. Playback only; never Voice or a microphone. Ticket/key bytes are never logged.</summary>
internal sealed class LinuxReceiverAudio : IAsyncDisposable
{
    internal const int MaximumTimelineResets = 8;
    private readonly IReceiverAudioSession session;
    private readonly IPeelPskTransportFactory transport;
    private readonly IPairedHostCredentialStore credentials;
    private readonly IClientHostResolver resolver;
    private readonly IReceiverAudioBackend backend;
    private readonly ulong receiverGeneration;
    private readonly long controlGeneration;
    private readonly TimeSpan attachTimeout;
    private readonly SemaphoreSlim lifecycle = new(1, 1);
    private readonly object gate = new();
    private CancellationTokenSource? cancellation;
    private Task? receiving;
    private bool disposed;
    private ReceiverAudioPhase phase = ReceiverAudioPhase.Idle;
    private string status = "";
    private string? stopReason;

    internal LinuxReceiverAudio(IReceiverAudioSession session, IPeelPskTransportFactory transport, IPairedHostCredentialStore credentials,
        IClientHostResolver resolver, IReceiverAudioBackend backend, ulong receiverGeneration, long controlGeneration, TimeSpan? attachTimeout = null)
    {
        this.session = session; this.transport = PeelSecureTransport.Require(transport); this.credentials = credentials; this.resolver = resolver;
        this.backend = backend; this.receiverGeneration = receiverGeneration; this.controlGeneration = controlGeneration;
        this.attachTimeout = attachTimeout ?? TimeSpan.FromSeconds(5);
        session.StateChanged += ConnectionChanged; session.AudioStateChanged += AudioChanged;
    }

    internal event Action? Changed;
    internal (ReceiverAudioPhase Phase, string Status) Snapshot { get { lock (gate) return (phase, status); } }
    internal bool Running { get { lock (gate) return receiving is { IsCompleted: false }; } }

    private void ConnectionChanged(object? sender, ConnectionStateChangedEventArgs e)
    {
        if (e.State != PeelConnectionState.Connected) Cancel("Disconnected.");
    }

    private void AudioChanged(object? sender, AudioStateEventArgs e)
    {
        if (e.Generation != controlGeneration) return;
        if (e.State.Status is "stopped" or "unavailable") Cancel(Bounded(e.State.Reason) ?? "The source stopped sharing audio.");
    }

    private void Cancel(string? reason)
    {
        lock (gate) { if (reason is not null) stopReason ??= reason; cancellation?.Cancel(); }
    }

    /// <summary>Starts playback unless this owner is already running. Never replaces another source's owner.</summary>
    internal async Task StartAsync()
    {
        await lifecycle.WaitAsync().ConfigureAwait(false);
        try
        {
            if (disposed || Running || session.SessionGeneration != controlGeneration) return;
            await StopCoreAsync().ConfigureAwait(false);
            var owned = new CancellationTokenSource();
            lock (gate) { cancellation = owned; stopReason = null; }
            SetPhase(ReceiverAudioPhase.Starting, "Connecting to the source's audio…");
            lock (gate) receiving = Task.Run(() => ReceiveAsync(owned.Token));
        }
        finally { lifecycle.Release(); }
    }

    internal async Task StopAsync(string finalStatus = "")
    {
        Cancel(null);
        await lifecycle.WaitAsync().ConfigureAwait(false);
        try { await StopCoreAsync().ConfigureAwait(false); SetPhase(ReceiverAudioPhase.Idle, finalStatus); }
        finally { lifecycle.Release(); }
    }

    private async Task StopCoreAsync()
    {
        Task? running; CancellationTokenSource? owned;
        lock (gate) { owned = cancellation; owned?.Cancel(); running = receiving; }
        // ReceiveAsync classifies its own failures; teardown must still finish if one escapes.
        if (running is not null) await running.ContinueWith(static _ => { }, TaskScheduler.Default).ConfigureAwait(false);
        lock (gate) { cancellation = null; receiving = null; }
        owned?.Dispose();
    }

    private async Task ReceiveAsync(CancellationToken token)
    {
        AudioAuthorization? authorization = null;
        IReceiverAudioOutput? output = null;
        try
        {
            authorization = await session.BeginAudioPlaybackAsync(controlGeneration, token).ConfigureAwait(false);
            var host = await resolver.ResolveFreshAsync(authorization.HostId, token).ConfigureAwait(false);
            var key = await credentials.GetForHostAsync(authorization.HostId, token).ConfigureAwait(false);
            if (host is null || host.StableHostId != authorization.HostId || key is null || key.PairingId != authorization.PairingId ||
                key.StableHostId != authorization.HostId || session.SessionGeneration != authorization.Generation)
                throw new InvalidOperationException("The paired audio session changed.");
            Stream stream;
            byte[] secret = key.CopyPreSharedKey();
            PeelPskCredential? credential = null;
            try
            {
                credential = new PeelPskCredential(authorization.PairingId, secret);
                using var connect = CancellationTokenSource.CreateLinkedTokenSource(token); connect.CancelAfter(attachTimeout);
                stream = await transport.ConnectAsync(new DnsEndPoint(host.Address, host.Port), credential, connect.Token).ConfigureAwait(false);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(secret);
                if (credential is not null) CryptographicOperations.ZeroMemory(credential.PreSharedKey);
            }
            await using (stream)
            using (token.Register(() => stream.Dispose()))
            {
                await stream.WriteAsync(PeelJson.SerializeLine(new AudioStreamHelloMessage(authorization.RequestId, authorization.PairingId, authorization.Ticket)), token).ConfigureAwait(false);
                await stream.FlushAsync(token).ConfigureAwait(false);
                var reader = new AudioPacketReader(0);
                var timeline = new PeelAudioTimeline();
                using (var attach = CancellationTokenSource.CreateLinkedTokenSource(token))
                {
                    attach.CancelAfter(attachTimeout);
                    if (timeline.Admit(await reader.ReadAsync(stream, attach.Token).ConfigureAwait(false)) != PeelAudioTimeline.Result.Format)
                        throw new InvalidDataException("The source did not announce its audio format.");
                }
                output = backend.Open(receiverGeneration) ?? throw new IOException("No working audio output on this computer.");
                SetPhase(ReceiverAudioPhase.Starting, "Connected; waiting for the source's audio…");
                int resets = 0; bool playing = false;
                while (true)
                {
                    var packet = await reader.ReadAsync(stream, token).ConfigureAwait(false);
                    if (session.SessionGeneration != authorization.Generation) throw new InvalidOperationException("The connection changed, so audio stopped.");
                    var admitted = timeline.Admit(packet);
                    if (admitted == PeelAudioTimeline.Result.Format) continue;
                    if (admitted == PeelAudioTimeline.Result.Reset)
                    {
                        if (++resets > MaximumTimelineResets) throw new InvalidDataException("The source's audio timeline kept regressing.");
                        // Drain/stop/recreate: a regressed timeline never feeds the old live sink.
                        output.Dispose(); output = null;
                        output = backend.Open(receiverGeneration) ?? throw new IOException("No working audio output on this computer.");
                    }
                    int result = output.Push(packet.Payload);
                    if (result < 0) throw new IOException("Audio output on this computer stopped.");
                    if (result == 1 && !playing) { playing = true; SetPhase(ReceiverAudioPhase.Playing, "Playing the source's audio · 48 kHz stereo"); }
                }
            }
        }
        catch (Exception error) when (token.IsCancellationRequested && error is OperationCanceledException or IOException or InvalidOperationException or SocketException)
        {
            // Cancellation disposes the stream, so a read may surface as ObjectDisposed/IO.
            string? reason; lock (gate) reason = stopReason;
            SetPhase(reason is null ? ReceiverAudioPhase.Idle : ReceiverAudioPhase.Failed, reason ?? "");
        }
        catch (Exception error) when (error is OperationCanceledException or IOException or InvalidDataException or InvalidOperationException or SocketException or TimeoutException)
        {
            string? reason; lock (gate) reason = stopReason;
            SetPhase(ReceiverAudioPhase.Failed, reason ?? Describe(error));
        }
        finally
        {
            output?.Dispose();
            if (authorization is not null) await session.EndAudioAsync(authorization.RequestId, authorization.Generation).ConfigureAwait(false);
        }
    }

    /// <summary>Fixed text only, so no transport or ticket detail can reach the UI.</summary>
    private static string Describe(Exception error) => error switch
    {
        InvalidDataException => "The source's audio was malformed, so it was stopped.",
        ObjectDisposedException => "The source's audio connection ended.",
        // Our own session messages or the source's bounded audioSessionState reason; never ticket/key data.
        InvalidOperationException => Bounded(error.Message) ?? "The source didn't start audio for this session.",
        OperationCanceledException or TimeoutException => "The source didn't answer in time.",
        EndOfStreamException => "The source's audio ended.",
        _ when error.Message == "No working audio output on this computer." || error.Message == "Audio output on this computer stopped." => error.Message,
        _ => "The source's audio connection ended.",
    };

    private static string? Bounded(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var clean = new string(text.Where(c => !char.IsControl(c)).Take(160).ToArray()).Trim();
        return clean.Length == 0 ? null : clean;
    }

    private void SetPhase(ReceiverAudioPhase next, string text)
    {
        lock (gate) { phase = next; status = text; }
        Changed?.Invoke();
    }

    public async ValueTask DisposeAsync()
    {
        session.StateChanged -= ConnectionChanged; session.AudioStateChanged -= AudioChanged;
        Cancel(null);
        await lifecycle.WaitAsync().ConfigureAwait(false);
        try { disposed = true; await StopCoreAsync().ConfigureAwait(false); }
        finally { lifecycle.Release(); }
    }
}
