using Peel.Windows.Host.Interop;
using Peel.Windows.Host.Windows;
using Windows.Graphics;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;

namespace Peel.Windows.Host.Capture;

public sealed class WindowsGraphicsCaptureBackend : IWindowCaptureBackend
{
    public ValueTask<IWindowCaptureSession> OpenAsync(
        WindowDescriptor window,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(window);
        cancellationToken.ThrowIfCancellationRequested();

        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
        {
            throw new PlatformNotSupportedException(
                "Window capture requires Windows 10 version 2004 or later.");
        }

        if (!window.Bounds.IsUsable)
        {
            throw new ArgumentException("The selected window has invalid bounds.", nameof(window));
        }

        if (!GraphicsCaptureSession.IsSupported())
        {
            throw new PlatformNotSupportedException(
                "Windows.Graphics.Capture is not supported on this device.");
        }

        // WGC keeps an existing window stream alive across minimize/restore, but an
        // item opened while already minimized does not produce an initial frame.
        // Display sources have no HWND and must never enter this path.
        if (!window.IsDisplay && NativeMethods.IsIconic(window.Handle))
        {
            _ = NativeMethods.ShowWindowAsync(window.Handle, NativeMethods.SwRestore);
        }

        D3D11CaptureDevice? captureDevice = null;
        GraphicsCaptureItem? captureItem = null;
        try
        {
            captureDevice = D3D11CaptureDevice.Create();
            captureItem = window.IsDisplay
                ? GraphicsCaptureItemFactory.CreateForMonitor(window.Handle)
                : GraphicsCaptureItemFactory.CreateForWindow(
                    window.Handle,
                    window.ProcessId);
            CaptureFrameLayout.ValidateCaptureSize(
                captureItem.Size.Width,
                captureItem.Size.Height);

            IWindowCaptureSession session = new WindowsGraphicsCaptureSession(
                window,
                captureItem,
                captureDevice);
            captureItem = null;
            captureDevice = null;
            return ValueTask.FromResult(session);
        }
        finally
        {
            if (captureItem is not null)
            {
                GraphicsCaptureItemFactory.Dispose(captureItem);
            }
            captureDevice?.Dispose();
        }
    }
}

internal sealed class WindowsGraphicsCaptureSession : IWindowCaptureSession, IGpuWindowCaptureSession
{
    private const int FramePoolBufferCount = 2;

    private readonly object stateLock = new();
    private readonly object framePoolLock = new();
    private readonly GraphicsCaptureItem captureItem;
    private readonly D3D11CaptureDevice captureDevice;
    private readonly Direct3D11CaptureFramePool framePool;
    private readonly GraphicsCaptureSession captureSession;
    private readonly LatestFramePump<Direct3D11CaptureFrame> framePump = new();
    private readonly CaptureTimestampClock timestampClock = new();
    private readonly CancellationTokenSource lifetimeCancellation = new();
    private SizeInt32 captureSize;
    private SizeInt32? requestedResize;
    private Task? runTask;
    private Task? disposeTask;
    private bool disposed;

    internal WindowsGraphicsCaptureSession(
        WindowDescriptor window,
        GraphicsCaptureItem captureItem,
        D3D11CaptureDevice captureDevice)
    {
        Window = window;
        this.captureItem = captureItem;
        this.captureDevice = captureDevice;
        captureSize = captureItem.Size;
        InitialWidth = captureSize.Width;
        InitialHeight = captureSize.Height;

        Direct3D11CaptureFramePool createdFramePool =
            Direct3D11CaptureFramePool.CreateFreeThreaded(
            captureDevice.WindowsRuntimeDevice,
            DirectXPixelFormat.B8G8R8A8UIntNormalized,
            FramePoolBufferCount,
            captureSize);
        try
        {
            GraphicsCaptureSession createdCaptureSession =
                createdFramePool.CreateCaptureSession(captureItem);
            try
            {
                createdFramePool.FrameArrived += HandleFrameArrived;
                captureItem.Closed += HandleCaptureItemClosed;
            }
            catch
            {
                createdCaptureSession.Dispose();
                throw;
            }

            framePool = createdFramePool;
            captureSession = createdCaptureSession;
        }
        catch
        {
            createdFramePool.Dispose();
            throw;
        }
    }

    public WindowDescriptor Window { get; }

    public int InitialWidth { get; }

    public int InitialHeight { get; }
    public nint GpuDevice => captureDevice.Device;
    public void SetGpuFramesEnabled(bool enabled) => captureDevice.UseGpuFrames = enabled;

    public Task RunAsync(
        CapturedFrameHandler frameHandler,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(frameHandler);

        lock (stateLock)
        {
            ObjectDisposedException.ThrowIf(Volatile.Read(ref disposed), this);
            if (runTask is not null)
            {
                throw new InvalidOperationException("A window capture session can only run once.");
            }

            runTask = RunCoreAsync(frameHandler, cancellationToken);
            return runTask;
        }
    }

    public ValueTask DisposeAsync()
    {
        lock (stateLock)
        {
            if (disposeTask is not null)
            {
                return new ValueTask(disposeTask);
            }

            Volatile.Write(ref disposed, true);
            lifetimeCancellation.Cancel();
            framePump.Complete();
            disposeTask = DisposeCoreAsync(runTask);
            return new ValueTask(disposeTask);
        }
    }

    private async Task RunCoreAsync(
        CapturedFrameHandler frameHandler,
        CancellationToken cancellationToken)
    {
        using CancellationTokenSource runCancellation =
            CancellationTokenSource.CreateLinkedTokenSource(
                cancellationToken,
                lifetimeCancellation.Token);
        using CancellationTokenRegistration cancellationRegistration =
            runCancellation.Token.Register(static state =>
            {
                ((LatestFramePump<Direct3D11CaptureFrame>)state!).Complete();
            }, framePump);

        captureSession.StartCapture();
        await framePump.RunAsync(
            async (frame, frameCancellationToken) =>
            {
                SizeInt32 contentSize = frame.ContentSize;
                if (contentSize.Width == 0 || contentSize.Height == 0)
                {
                    // WGC can briefly report an empty surface while a window is
                    // minimized. Keep the capture generation alive so restore can
                    // deliver a usable size instead of terminating the video socket.
                    return;
                }

                CaptureFrameLayout.ValidateCaptureSize(contentSize.Width, contentSize.Height);
                if (contentSize.Width != captureSize.Width ||
                    contentSize.Height != captureSize.Height)
                {
                    requestedResize = contentSize;
                    return;
                }

                long timestamp = timestampClock.Next(frame.SystemRelativeTime);
                CapturedFrame? capturedFrame = captureDevice.TryCopyFrame(
                    frame.Surface,
                    contentSize.Width,
                    contentSize.Height,
                    timestamp);
                if (capturedFrame is null)
                {
                    return;
                }

                await frameHandler(capturedFrame, frameCancellationToken).ConfigureAwait(false);
            },
            runCancellation.Token,
            ApplyRequestedResize).ConfigureAwait(false);

        runCancellation.Token.ThrowIfCancellationRequested();
    }

    private void HandleFrameArrived(Direct3D11CaptureFramePool sender, object arguments)
    {
        try
        {
            lock (framePoolLock)
            {
                if (Volatile.Read(ref disposed))
                {
                    return;
                }

                Direct3D11CaptureFrame? newestFrame = null;
                while (sender.TryGetNextFrame() is Direct3D11CaptureFrame frame)
                {
                    newestFrame?.Dispose();
                    newestFrame = frame;
                }

                if (newestFrame is not null)
                {
                    framePump.Publish(newestFrame);
                }
            }
        }
        catch (ObjectDisposedException) when (Volatile.Read(ref disposed))
        {
        }
        catch (Exception exception)
        {
            framePump.Complete(exception);
        }
    }

    private void HandleCaptureItemClosed(GraphicsCaptureItem sender, object arguments) =>
        framePump.Complete();

    private void ApplyRequestedResize()
    {
        if (requestedResize is not SizeInt32 newSize)
        {
            return;
        }

        requestedResize = null;
        lock (framePoolLock)
        {
            if (Volatile.Read(ref disposed))
            {
                return;
            }

            framePump.DropPending();
            framePool.Recreate(
                captureDevice.WindowsRuntimeDevice,
                DirectXPixelFormat.B8G8R8A8UIntNormalized,
                FramePoolBufferCount,
                newSize);
            captureDevice.ResetStagingTexture();
            captureSize = newSize;
        }
    }

    private async Task DisposeCoreAsync(Task? runningTask)
    {
        if (runningTask is not null)
        {
            try
            {
                await runningTask.ConfigureAwait(false);
            }
            catch (Exception) when (lifetimeCancellation.IsCancellationRequested)
            {
            }
        }

        TryCleanup(() => framePool.FrameArrived -= HandleFrameArrived);
        TryCleanup(() => captureItem.Closed -= HandleCaptureItemClosed);

        lock (framePoolLock)
        {
            TryCleanup(captureSession.Dispose);
            TryCleanup(framePool.Dispose);
        }

        TryCleanup(() => GraphicsCaptureItemFactory.Dispose(captureItem));
        TryCleanup(captureDevice.Dispose);
        TryCleanup(framePump.Dispose);
        TryCleanup(lifetimeCancellation.Dispose);
    }

    private static void TryCleanup(Action cleanup)
    {
        try
        {
            cleanup();
        }
        catch (Exception)
        {
        }
    }
}
