using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Peel.Windows.Host.Runtime;

internal interface IHostAwakeController : IDisposable
{
    bool IsHolding { get; }

    string? LastError { get; }

    void SetClientVisible(bool visible);
}

internal sealed class NullHostAwakeController : IHostAwakeController
{
    public bool IsHolding => false;

    public string? LastError => null;

    public void SetClientVisible(bool visible) => _ = visible;

    public void Dispose()
    {
    }
}

internal sealed class WindowsHostAwakeController : IHostAwakeController
{
    private const uint PowerRequestContextVersion = 0;
    private const uint PowerRequestContextSimpleString = 0x00000001;
    private readonly string requestReason;
    private readonly bool displayRequired;

    internal WindowsHostAwakeController(bool displayRequired = true, string reason = "Peel streaming active")
    { this.displayRequired = displayRequired; requestReason = reason; }

    private readonly object stateLock = new();
    private SafeFileHandle? requestHandle;
    private nint reasonString;
    private string? lastError;
    private bool isHolding;
    private bool disposed;

    public bool IsHolding
    {
        get
        {
            lock (stateLock)
            {
                return isHolding;
            }
        }
    }

    public string? LastError
    {
        get
        {
            lock (stateLock)
            {
                return lastError;
            }
        }
    }

    public void SetClientVisible(bool visible)
    {
        lock (stateLock)
        {
            if (disposed || visible == isHolding)
            {
                return;
            }

            if (visible)
            {
                AcquireLocked();
            }
            else
            {
                ReleaseLocked();
            }
        }
    }

    public void Dispose()
    {
        lock (stateLock)
        {
            if (disposed)
            {
                return;
            }

            disposed = true;
            ReleaseLocked();
            ResetRequestHandleLocked();
            if (reasonString != 0)
            {
                Marshal.FreeHGlobal(reasonString);
                reasonString = 0;
            }
        }
    }

    private void AcquireLocked()
    {
        try
        {
            SafeFileHandle handle = EnsureRequestHandleLocked();
            if (!NativeMethods.PowerSetRequest(handle, PowerRequestType.SystemRequired))
            {
                RecordErrorLocked(
                    "Windows could not keep this PC awake.",
                    Marshal.GetLastPInvokeError());
                ResetRequestHandleLocked();
                return;
            }

            if (displayRequired && !NativeMethods.PowerSetRequest(handle, PowerRequestType.DisplayRequired))
            {
                int error = Marshal.GetLastPInvokeError();
                _ = NativeMethods.PowerClearRequest(handle, PowerRequestType.SystemRequired);
                RecordErrorLocked(
                    "Windows could not keep this PC's display awake.",
                    error);
                ResetRequestHandleLocked();
                return;
            }

            isHolding = true;
            lastError = null;
        }
        catch (Exception exception) when (
            exception is Win32Exception or
                DllNotFoundException or
                EntryPointNotFoundException or
                PlatformNotSupportedException)
        {
            isHolding = false;
            lastError = "Windows power requests are unavailable.";
            ResetRequestHandleLocked();
        }
    }

    private void ReleaseLocked()
    {
        SafeFileHandle? handle = requestHandle;
        if (!isHolding || handle is null || handle.IsInvalid || handle.IsClosed)
        {
            isHolding = false;
            return;
        }

        bool displayCleared = !displayRequired || NativeMethods.PowerClearRequest(
            handle,
            PowerRequestType.DisplayRequired);
        int displayError = displayCleared ? 0 : Marshal.GetLastPInvokeError();
        bool systemCleared = NativeMethods.PowerClearRequest(
            handle,
            PowerRequestType.SystemRequired);
        int systemError = systemCleared ? 0 : Marshal.GetLastPInvokeError();
        isHolding = false;

        if (!displayCleared || !systemCleared)
        {
            int error = displayError != 0 ? displayError : systemError;
            lastError = new Win32Exception(error, "Windows could not release Peel's power request.")
                .Message;
            ResetRequestHandleLocked();
        }
        else
        {
            lastError = null;
        }
    }

    private SafeFileHandle EnsureRequestHandleLocked()
    {
        if (requestHandle is { IsInvalid: false, IsClosed: false } existing)
        {
            return existing;
        }

        if (reasonString == 0)
        {
            reasonString = Marshal.StringToHGlobalUni(requestReason);
        }

        var context = new NativeMethods.ReasonContext
        {
            Version = PowerRequestContextVersion,
            Flags = PowerRequestContextSimpleString,
            Reason = new NativeMethods.ReasonContextUnion
            {
                SimpleReasonString = reasonString,
            },
        };
        SafeFileHandle created = NativeMethods.PowerCreateRequest(ref context);
        if (created.IsInvalid)
        {
            int error = Marshal.GetLastPInvokeError();
            created.Dispose();
            throw new Win32Exception(error, "Windows could not create Peel's power request.");
        }

        requestHandle = created;
        return created;
    }

    private void RecordErrorLocked(string message, int error)
    {
        isHolding = false;
        lastError = new Win32Exception(error, message).Message;
    }

    private void ResetRequestHandleLocked()
    {
        requestHandle?.Dispose();
        requestHandle = null;
        isHolding = false;
    }

    private enum PowerRequestType
    {
        DisplayRequired = 0,
        SystemRequired = 1,
    }

    private static class NativeMethods
    {
        [StructLayout(LayoutKind.Sequential)]
        internal struct ReasonContext
        {
            internal uint Version;
            internal uint Flags;
            internal ReasonContextUnion Reason;
        }

        [StructLayout(LayoutKind.Explicit)]
        internal struct ReasonContextUnion
        {
            [FieldOffset(0)]
            internal DetailedReasonContext Detailed;

            [FieldOffset(0)]
            internal nint SimpleReasonString;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct DetailedReasonContext
        {
            internal nint LocalizedReasonModule;
            internal uint LocalizedReasonId;
            internal uint ReasonStringCount;
            internal nint ReasonStrings;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern SafeFileHandle PowerCreateRequest(ref ReasonContext context);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool PowerSetRequest(
            SafeFileHandle powerRequest,
            PowerRequestType requestType);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool PowerClearRequest(
            SafeFileHandle powerRequest,
            PowerRequestType requestType);
    }
}
