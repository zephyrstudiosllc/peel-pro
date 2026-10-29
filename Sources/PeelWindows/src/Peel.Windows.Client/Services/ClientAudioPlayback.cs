using System.IO;
using System.Net;
using System.Security.Cryptography;
using Peel.Windows.Client.Models;
using Peel.Windows.Protocol;

namespace Peel.Windows.Client.Services;

/// <summary>Owns the auxiliary TLS channel and native playback until Stop, hide, disconnect or shutdown.</summary>
public sealed class ClientAudioPlayback : IAsyncDisposable
{
    private readonly ClientSession session;
    private readonly IPeelPskTransportFactory transport;
    private readonly IPairedHostCredentialStore credentials;
    private readonly IClientHostResolver resolver;
    private readonly Func<IMicrophoneCapture> microphoneFactory;
    private readonly SemaphoreSlim lifecycle = new(1, 1);
    private readonly object gate = new();
    private CancellationTokenSource? cancellation;
    private Task? receiving;
    private bool disposed;
    private string status = "Audio off";
    private string? stopReason;
    private string? hostDetail;
    private bool playing;
    public string Status { get { lock (gate) return status + (string.IsNullOrEmpty(hostDetail) ? "" : " · " + hostDetail); } }
    /// <summary>True only after the native output accepted actual host PCM in this receive.</summary>
    public bool IsPlaying { get { lock (gate) return playing; } }
    /// <summary>A receive (starting, attached or playing) currently owns this client's audio.</summary>
    public bool IsActive => Volatile.Read(ref receiving) is { IsCompleted: false };
    public event EventHandler<string>? StatusChanged;
    public ClientAudioPlayback(ClientSession session, IPeelPskTransportFactory transport, IPairedHostCredentialStore credentials, IClientHostResolver resolver)
        : this(session, transport, credentials, resolver, () => new WaveMicrophoneCapture()) { }
    internal ClientAudioPlayback(ClientSession session, IPeelPskTransportFactory transport, IPairedHostCredentialStore credentials, IClientHostResolver resolver, Func<IMicrophoneCapture> microphoneFactory)
    {
        this.session = session; this.transport = transport; this.credentials = credentials; this.resolver = resolver;
        this.microphoneFactory = microphoneFactory;
        session.StateChanged += ConnectionChanged; session.AudioStateChanged += AudioChanged;
    }
    private void ConnectionChanged(object? sender, ConnectionStateChangedEventArgs e) { if (e.State != PeelConnectionState.Connected) Cancel(); }
    private void AudioChanged(object? sender, AudioSessionStateMessage e)
    {
        if (e.Status is "stopped" or "unavailable") { lock (gate) stopReason = e.Reason ?? "Host audio stopped."; Cancel(); }
        else if (e.Status == "streaming") { lock (gate) hostDetail = e.Reason; StatusChanged?.Invoke(this, Status); }
    }
    public void Cancel() { lock (gate) cancellation?.Cancel(); }
    public Task StartAsync(CancellationToken token) => StartCoreAsync(false, null, token);
    public Task StartVoiceAsync(CancellationToken token) => StartCoreAsync(true, null, token);
    /// <summary>
    /// Default Listen: playback only, never voice or microphone, and only when nothing already owns
    /// audio and the control session is still the generation that admitted the video.
    /// </summary>
    internal Task<bool> StartDefaultAsync(long generation, CancellationToken token) =>
        StartCoreAsync(false, () => !IsActive && session.SessionGeneration == generation, token);
    private async Task<bool> StartCoreAsync(bool voice, Func<bool>? admit, CancellationToken token)
    {
        await lifecycle.WaitAsync(token).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (admit is not null && !admit()) return false;
            await StopCoreAsync().ConfigureAwait(false);
            lock (gate) { stopReason = null; hostDetail = null; cancellation = CancellationTokenSource.CreateLinkedTokenSource(token); }
            var ownedCancellation = cancellation;
            var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            receiving = Task.Run(() => ReceiveAsync(ownedCancellation.Token, ready, voice));
            await ready.Task.WaitAsync(token).ConfigureAwait(false);
            return true;
        }
        finally { lifecycle.Release(); }
    }
    private async Task ReceiveAsync(CancellationToken token, TaskCompletionSource ready, bool voice)
    {
        AudioAuthorization? authorization = null;
        try
        {
            SetStatus(voice ? "Authorizing microphone forwarding…" : "Authorizing host audio…");
            authorization = voice ? await session.BeginVoiceAsync(token).ConfigureAwait(false) : await session.BeginAudioPlaybackAsync(token).ConfigureAwait(false);
            var host = await resolver.ResolveFreshAsync(authorization.HostId, token).ConfigureAwait(false);
            var key = await credentials.GetForHostAsync(authorization.HostId, token).ConfigureAwait(false);
            if (host is null || host.StableHostId != authorization.HostId || key?.PairingId != authorization.PairingId || key.StableHostId != authorization.HostId || session.SessionGeneration != authorization.Generation)
                throw new InvalidOperationException("The paired audio session changed.");
            byte[] secret = key.CopyPreSharedKey();
            Stream stream;
            try
            {
                using var connectTimeout = CancellationTokenSource.CreateLinkedTokenSource(token); connectTimeout.CancelAfter(TimeSpan.FromSeconds(5));
                stream = await transport.ConnectAsync(new DnsEndPoint(host.Address, host.Port), new(authorization.PairingId, secret), connectTimeout.Token).ConfigureAwait(false);
            }
            finally { CryptographicOperations.ZeroMemory(secret); }
            await using (stream)
            using (token.Register(() => stream.Dispose()))
            using (var playback = new WaveAudioPlayback())
            using (var duplex = CancellationTokenSource.CreateLinkedTokenSource(token))
            {
                await stream.WriteAsync(PeelJson.SerializeLine(new AudioStreamHelloMessage(authorization.RequestId, authorization.PairingId, authorization.Ticket)), token).ConfigureAwait(false);
                await stream.FlushAsync(token).ConfigureAwait(false);
                // The Mac rejects bytes trailing its attachment hello. Its downlink format packet
                // confirms attachment before we send any uplink bytes or open the microphone.
                var reader = new AudioPacketReader(0);
                using (var attach = CancellationTokenSource.CreateLinkedTokenSource(token))
                {
                    attach.CancelAfter(TimeSpan.FromSeconds(5));
                    if ((await reader.ReadAsync(stream, attach.Token).ConfigureAwait(false)).Kind != 0)
                        throw new InvalidDataException("The host did not acknowledge its audio format.");
                }
                SetStatus(voice ? "Voice connected; starting microphone…" : "Connected; waiting for host audio…");
                using var microphone = voice ? microphoneFactory() : null;
                var download = Task.Run(async () =>
                {
                    bool first = true;
                    while (true)
                    {
                        var packet = await reader.ReadAsync(stream, duplex.Token).ConfigureAwait(false);
                        if (packet.Kind == 0) continue;
                        if (session.SessionGeneration != authorization.Generation) throw new OperationCanceledException("Audio session changed.");
                        if (playback.Offer(packet.Payload) && first)
                        {
                            first = false; lock (gate) playing = true;
                            if (!voice) SetStatus("Playing host audio · 48 kHz stereo"); else StatusChanged?.Invoke(this, Status);
                        }
                    }
                });
                Task? upload = microphone is null ? null : SendMicrophoneAsync(microphone, stream, authorization.Generation, duplex.Token);
                ready.TrySetResult();
                try
                {
                    if (upload is null) await download.ConfigureAwait(false);
                    else await (await Task.WhenAny(download, upload).ConfigureAwait(false)).ConfigureAwait(false);
                }
                finally
                {
                    duplex.Cancel(); stream.Dispose();
                    try { await Task.WhenAll(upload is null ? [download] : [download, upload]).ConfigureAwait(false); }
                    catch (Exception e) when (e is IOException or OperationCanceledException or ObjectDisposedException or InvalidOperationException) { }
                }
            }
        }
        catch (OperationCanceledException) { ready.TrySetCanceled(token); SetStatus(stopReason ?? "Audio off"); }
        catch (Exception e) when (e is IOException or InvalidOperationException or ObjectDisposedException or System.ComponentModel.Win32Exception)
        { ready.TrySetException(e); SetStatus(stopReason ?? (token.IsCancellationRequested ? "Audio off" : e.Message)); }
        finally
        {
            lock (gate) playing = false;
            if (authorization is not null) await session.EndAudioAsync(authorization.RequestId, authorization.Generation).ConfigureAwait(false);
        }
    }
    private async Task SendMicrophoneAsync(IMicrophoneCapture microphone, Stream stream, long generation, CancellationToken token)
    {
        async Task Send(AudioPacket packet, CancellationToken cancellation)
        {
            if (session.SessionGeneration != generation) throw new OperationCanceledException("Voice session changed.");
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation); deadline.CancelAfter(TimeSpan.FromSeconds(3));
            await stream.WriteAsync(packet.Encode(), deadline.Token).ConfigureAwait(false);
            await stream.FlushAsync(deadline.Token).ConfigureAwait(false);
        }
        await Send(new(0, 1, 0, 0, []), token).ConfigureAwait(false);
        ulong sequence = 0; long samples = 0;
        await microphone.RunAsync(async (pcm, cancellation) =>
        {
            await Send(new(1, 1, sequence++, samples, pcm), cancellation).ConfigureAwait(false);
            samples += AudioPacket.Frames;
            if (sequence == 1) SetStatus("Microphone forwarding ON · 48 kHz mono · host audio playback enabled");
        }, token).ConfigureAwait(false);
    }
    public async Task StopAsync()
    {
        Cancel(); await lifecycle.WaitAsync().ConfigureAwait(false);
        try { await StopCoreAsync().ConfigureAwait(false); lock (gate) hostDetail = null; SetStatus("Audio off"); }
        finally { lifecycle.Release(); }
    }
    private async Task StopCoreAsync()
    {
        Cancel(); if (receiving is not null) await receiving.ConfigureAwait(false);
        lock (gate) { cancellation?.Dispose(); cancellation = null; }
        receiving = null;
    }
    private void SetStatus(string text) { lock (gate) status = text; StatusChanged?.Invoke(this, Status); }
    public async ValueTask DisposeAsync()
    {
        disposed = true; session.StateChanged -= ConnectionChanged; session.AudioStateChanged -= AudioChanged;
        await StopAsync().ConfigureAwait(false);
    }
}
