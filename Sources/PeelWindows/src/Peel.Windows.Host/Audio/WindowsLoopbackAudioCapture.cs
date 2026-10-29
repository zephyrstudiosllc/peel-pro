using System.Runtime.InteropServices;
using Peel.Windows.Protocol;

namespace Peel.Windows.Host.Audio;

/// <summary>WASAPI process loopback, excluding Peel and its children. No microphone or audio driver is opened.</summary>
public sealed class WindowsLoopbackAudioCapture : IHostAudioCapture
{
    public static bool Available => OperatingSystem.IsWindowsVersionAtLeast(10, 0, 20348);
    private readonly uint processId;
    private readonly bool includeProcess;
    private readonly object gate = new();
    private readonly TaskCompletionSource ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TaskCompletionSource completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private CancellationTokenSource? cancel;
    private bool started, disposed;
    public Task Completion => completion.Task;
    public WindowsLoopbackAudioCapture() : this((uint)Environment.ProcessId, false) { }
    // Native fixtures include only their own generated audio; they never capture other apps.
    internal WindowsLoopbackAudioCapture(uint processId, bool includeProcess) { this.processId = processId; this.includeProcess = includeProcess; }
    public async ValueTask StartAsync(Action<AudioPacket> onPacket, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(onPacket); cancellationToken.ThrowIfCancellationRequested();
        if (!Available) throw new PlatformNotSupportedException("System audio sharing requires Windows build 20348 or later.");
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (started) throw new InvalidOperationException("This audio capture was already started.");
            started = true; cancel = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            var thread = new Thread(() => Run(onPacket, cancel.Token)) { IsBackground = true, Name = "Peel system audio capture" };
            try { thread.SetApartmentState(ApartmentState.MTA); thread.Start(); }
            catch { started = false; cancel.Dispose(); cancel = null; throw; }
        }
        await ready.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
    }
    private unsafe void Run(Action<AudioPacket> onPacket, CancellationToken token)
    {
        nint audio = 0, capture = 0;
        int com = Native.CoInitializeEx(0, 0); bool running = false;
        Exception? failure = null;
        using var samples = new AutoResetEvent(false);
        try
        {
            Native.Check(com);
            audio = Native.Activate(processId, includeProcess, token);
            var format = new Native.WaveFormat { Tag = 1, Channels = 2, Samples = 48000, BytesPerSecond = 192000, BlockAlign = 4, Bits = 16 };
            Native.Check(((delegate* unmanaged[Stdcall]<nint, int, uint, long, long, Native.WaveFormat*, nint, int>)Native.Slot(audio, 3))
                (audio, 0, 0x20000 | 0x40000 | 0x80000000, 0, 0, &format, 0)); // LOOPBACK, EVENTCALLBACK, AUTOCONVERTPCM.
            Guid iid = new("c8adbd64-e71e-48a0-a4de-185c395cd317");
            nint local = 0;
            Native.Check(((delegate* unmanaged[Stdcall]<nint, Guid*, nint*, int>)Native.Slot(audio, 14))(audio, &iid, &local)); capture = local;
            Native.Check(((delegate* unmanaged[Stdcall]<nint, nint, int>)Native.Slot(audio, 13))(audio, samples.SafeWaitHandle.DangerousGetHandle()));
            Native.Check(((delegate* unmanaged[Stdcall]<nint, int>)Native.Slot(audio, 10))(audio)); running = true;
            ready.TrySetResult();
            var framer = new HostPcmFramer(onPacket);
            var wait = new[] { token.WaitHandle, samples };
            byte[] silence = new byte[48000 * 4];
            long samplePosition = 0;
            while (!token.IsCancellationRequested)
            {
                int signaled = WaitHandle.WaitAny(wait, 1000);
                if (signaled == 0) break;
                if (signaled == WaitHandle.WaitTimeout) continue;
                for (int drained = 0; drained < 256 && !token.IsCancellationRequested; drained++)
                {
                    uint available = 0;
                    Native.Check(((delegate* unmanaged[Stdcall]<nint, uint*, int>)Native.Slot(capture, 5))(capture, &available));
                    if (available == 0) break;
                    if (available > 48000) throw new InvalidDataException("The audio driver returned an oversized packet.");
                    byte* data = null; uint frames = 0, flags = 0; ulong position = 0, qpc = 0;
                    Native.Check(((delegate* unmanaged[Stdcall]<nint, byte**, uint*, uint*, ulong*, ulong*, int>)Native.Slot(capture, 3))
                        (capture, &data, &frames, &flags, &position, &qpc));
                    try
                    {
                        if (frames > 48000 || frames > available || position > long.MaxValue) throw new InvalidDataException("Invalid captured audio layout.");
                        int size = checked((int)frames * 4);
                        // Process loopback can report position=0 for every packet without TIMESTAMP_ERROR.
                        // PEAU uses a sample clock; count our configured 48 kHz frames monotonically.
                        ReadOnlySpan<byte> pcm = (flags & 2) != 0 ? silence.AsSpan(0, size)
                            : data != null ? new ReadOnlySpan<byte>(data, size) : throw new InvalidDataException("The audio driver returned no PCM buffer.");
                        framer.Append(pcm, samplePosition, (flags & 1) != 0);
                        samplePosition = checked(samplePosition + frames);
                    }
                    finally { Native.Check(((delegate* unmanaged[Stdcall]<nint, uint, int>)Native.Slot(capture, 4))(capture, frames)); }
                }
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { ready.TrySetCanceled(token); }
        catch (Exception e) { failure = e; ready.TrySetException(e); }
        finally
        {
            if (running) _ = ((delegate* unmanaged[Stdcall]<nint, int>)Native.Slot(audio, 11))(audio);
            // IAudioCaptureClient must be released on the same MTA worker that obtained it.
            Native.Release(ref capture); Native.Release(ref audio);
            if (com >= 0) Native.CoUninitialize();
            if (failure is null) completion.TrySetResult(); else completion.TrySetException(failure);
        }
    }
    public async ValueTask DisposeAsync()
    {
        Task pending;
        lock (gate)
        {
            if (!disposed) { disposed = true; cancel?.Cancel(); }
            pending = started ? completion.Task : Task.CompletedTask;
        }
        try { await pending.ConfigureAwait(false); }
        finally { lock (gate) { cancel?.Dispose(); cancel = null; } }
    }

    [ComVisible(true), Guid("41D949AB-9862-444A-80F6-C261334DA5EB"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IActivationCompletion { [PreserveSig] int ActivateCompleted(nint operation); }

    private static unsafe class Native
    {
        private static readonly Guid AudioClient = new("1cb9ad4c-dbfa-4c32-b178-c2f568a703b2");
        internal static nint Slot(nint value, int index) => (*(nint**)value)[index];
        internal static void Check(int result) => Marshal.ThrowExceptionForHR(result);
        internal static void Release(ref nint value) { if (value != 0) { Marshal.Release(value); value = 0; } }
        internal static nint Activate(uint process, bool include, CancellationToken token)
        {
            var callback = new ActivationCompletion();
            var parameters = new ActivationParameters { Type = 1, Process = process, Mode = include ? 0u : 1u };
            // Keep the native input storage alive through a late activation callback after cancellation.
            nint handler = 0, operation = 0;
            bool accepted = false;
            try
            {
                nint blob = callback.Parameters = Marshal.AllocHGlobal(sizeof(ActivationParameters)); *(ActivationParameters*)blob = parameters;
                nint variant = callback.Variant = Marshal.AllocHGlobal(sizeof(PropVariant));
                *(PropVariant*)variant = new PropVariant { Type = 65, Blob = new Blob { Size = (uint)sizeof(ActivationParameters), Data = blob } };
                handler = Marshal.GetComInterfaceForObject<ActivationCompletion, IActivationCompletion>(callback);
                Guid iid = AudioClient;
                Check(ActivateAudioInterfaceAsync("VAD\\Process_Loopback", &iid, variant, handler, out operation)); accepted = true;
                try { return callback.Completed.Task.WaitAsync(TimeSpan.FromSeconds(5), token).GetAwaiter().GetResult(); }
                catch
                {
                    // A late native result still owns an IUnknown reference; release it even after cancellation.
                    _ = callback.Completed.Task.ContinueWith(t =>
                    {
                        if (t.Status == TaskStatus.RanToCompletion) { nint late = t.Result; Release(ref late); }
                        else _ = t.Exception;
                    }, CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
                    throw;
                }
            }
            finally
            {
                Release(ref operation); Release(ref handler);
                if (!accepted) callback.CallbackFinished();
                callback.ApiReturned();
                GC.KeepAlive(callback);
            }
        }
        [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
        private sealed class ActivationCompletion : IActivationCompletion, ICustomQueryInterface
        {
            internal readonly TaskCompletionSource<nint> Completed = new(TaskCreationOptions.RunContinuationsAsynchronously);
            internal nint Parameters, Variant;
            private int parameterOwners = 2, callbackFinished, apiReturned;
            public int ActivateCompleted(nint operation)
            {
                nint unknown = 0, client = 0;
                try
                {
                    int activated = 0;
                    Check(((delegate* unmanaged[Stdcall]<nint, int*, nint*, int>)Slot(operation, 3))(operation, &activated, &unknown)); Check(activated);
                    if (unknown == 0) throw new InvalidDataException("Windows returned no loopback audio interface.");
                    Guid iid = AudioClient; Check(Marshal.QueryInterface(unknown, in iid, out client));
                    if (Completed.TrySetResult(client)) client = 0;
                }
                catch (Exception e) { Completed.TrySetException(e); }
                finally { Release(ref client); Release(ref unknown); CallbackFinished(); }
                return 0;
            }
            internal void CallbackFinished() { if (Interlocked.Exchange(ref callbackFinished, 1) == 0) ReleaseParameters(); }
            internal void ApiReturned() { if (Interlocked.Exchange(ref apiReturned, 1) == 0) ReleaseParameters(); }
            private void ReleaseParameters()
            {
                if (Interlocked.Decrement(ref parameterOwners) != 0) return;
                nint value = Interlocked.Exchange(ref Parameters, 0); if (value != 0) Marshal.FreeHGlobal(value);
                value = Interlocked.Exchange(ref Variant, 0); if (value != 0) Marshal.FreeHGlobal(value);
            }
            public CustomQueryInterfaceResult GetInterface(ref Guid iid, out nint value)
            {
                value = 0;
                if (iid != new Guid("94ea2b94-e9cc-49e0-c0ff-ee64ca8f5b90")) return CustomQueryInterfaceResult.NotHandled;
                value = Marshal.GetIUnknownForObject(this); return CustomQueryInterfaceResult.Handled; // IAgileObject: all callback state is synchronized.
            }
        }
        [StructLayout(LayoutKind.Sequential, Pack = 2)] internal struct WaveFormat { public ushort Tag, Channels; public uint Samples, BytesPerSecond; public ushort BlockAlign, Bits, Extra; }
        [StructLayout(LayoutKind.Sequential)] private struct ActivationParameters { public uint Type, Process, Mode; }
        [StructLayout(LayoutKind.Sequential)] private struct Blob { public uint Size; public nint Data; }
        [StructLayout(LayoutKind.Sequential)] private struct PropVariant { public ushort Type, Reserved1, Reserved2, Reserved3; public Blob Blob; }
        [DllImport("ole32.dll")] internal static extern int CoInitializeEx(nint reserved, uint flags);
        [DllImport("ole32.dll")] internal static extern void CoUninitialize();
        [DllImport("Mmdevapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)] private static extern int ActivateAudioInterfaceAsync(string path, Guid* iid, nint parameters, nint callback, out nint operation);
    }
}
