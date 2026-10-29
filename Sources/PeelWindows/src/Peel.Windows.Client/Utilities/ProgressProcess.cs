using System.ComponentModel;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Peel.Windows.Client.Utilities;

/// <summary>A suspended launch enters its private job before any user command executes.</summary>
internal sealed class ProgressProcess : IDisposable
{
    private readonly SafeFileHandle process;
    private readonly SafeFileHandle? job;
    internal Stream? Output { get; }
    internal Stream? Error { get; }
    internal uint Id { get; }
    internal long StartedUtcTicks { get; }
    private ProgressProcess(SafeFileHandle process, uint id, SafeFileHandle? job = null, Stream? output = null, Stream? error = null)
    {
        this.process = process; this.job = job; Id = id; Output = output; Error = error;
        Check(Native.GetProcessTimes(process, out long created, out _, out _, out _)); StartedUtcTicks = DateTime.FromFileTimeUtc(created).Ticks;
    }
    internal bool Exited
    {
        get { uint result = Native.WaitForSingleObject(process, 0); if (result == uint.MaxValue) throw Failure(); return result == 0; }
    }
    internal int ExitCode { get { Check(Native.GetExitCodeProcess(process, out uint code)); return unchecked((int)code); } }
    internal static ProgressProcess Watch(int id, long? expectedStart = null)
    {
        if (id <= 0) throw new ArgumentException("Enter an existing process ID.");
        var handle = Native.OpenProcess(0x00101000, false, (uint)id); // Synchronize + query-limited-information, never terminate.
        if (handle.IsInvalid) { var error = Failure(); handle.Dispose(); throw error; }
        try
        {
            var watched = new ProgressProcess(handle, (uint)id);
            if (expectedStart is { } start && watched.StartedUtcTicks != start) throw new InvalidOperationException("The selected process has been replaced.");
            return watched;
        }
        catch { handle.Dispose(); throw; }
    }
    internal static ProgressProcess Start(string command, string directory, CancellationToken token)
    {
        if (string.IsNullOrWhiteSpace(command) || command.Length > 8192 || command.Contains('\0')) throw new ArgumentException("Enter a PowerShell command of at most 8192 characters.");
        if (!Path.IsPathFullyQualified(directory) || !Directory.Exists(directory)) throw new ArgumentException("Choose an existing absolute working directory.");
        token.ThrowIfCancellationRequested();
        string executable = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
        string script = "[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false);\n" + command;
        var commandLine = new StringBuilder('"' + executable + "\" -NoLogo -NoProfile -NonInteractive -OutputFormat Text -EncodedCommand " + Convert.ToBase64String(Encoding.Unicode.GetBytes(script)));
        var security = new Native.SecurityAttributes { Length = (uint)Marshal.SizeOf<Native.SecurityAttributes>(), Inherit = 1 };
        SafeFileHandle? input = null, job = null, process = null, thread = null;
        NamedPipeClientStream? outputWrite = null, errorWrite = null;
        nint attributes = 0, handles = 0; bool initialized = false, transferred = false;
        NamedPipeServerStream? stdout = null, stderr = null;
        try
        {
            (stdout, outputWrite) = CreateOutputPipe(token); (stderr, errorWrite) = CreateOutputPipe(token);
            input = Native.CreateFileW("NUL", 0x80000000, 3, ref security, 3, 128, 0); if (input.IsInvalid) throw Failure();
            job = Native.CreateJobObjectW(0, null); if (job.IsInvalid) throw Failure();
            var limits = new Native.ExtendedLimits { Basic = new() { Flags = 0x2000 } }; // Kill-on-close; no breakaway.
            Check(Native.SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf<Native.ExtendedLimits>()));
            nuint size = 0; _ = Native.InitializeProcThreadAttributeList(0, 1, 0, ref size);
            if (size == 0 || size > 65536) throw new IOException("Windows could not size the process attribute list.");
            attributes = Marshal.AllocHGlobal((int)size); Check(Native.InitializeProcThreadAttributeList(attributes, 1, 0, ref size)); initialized = true;
            handles = Marshal.AllocHGlobal(IntPtr.Size * 3);
            Marshal.WriteIntPtr(handles, 0, input.DangerousGetHandle()); Marshal.WriteIntPtr(handles, IntPtr.Size, outputWrite.SafePipeHandle.DangerousGetHandle()); Marshal.WriteIntPtr(handles, IntPtr.Size * 2, errorWrite.SafePipeHandle.DangerousGetHandle());
            Check(Native.UpdateProcThreadAttribute(attributes, 0, 0x20002, handles, (nuint)(IntPtr.Size * 3), 0, 0));
            var startup = new Native.StartupInfoEx { Attributes = attributes, Startup = new() { Size = (uint)Marshal.SizeOf<Native.StartupInfoEx>(), Flags = 0x100, Input = input.DangerousGetHandle(), Output = outputWrite.SafePipeHandle.DangerousGetHandle(), Error = errorWrite.SafePipeHandle.DangerousGetHandle() } };
            Check(Native.CreateProcessW(executable, commandLine, 0, 0, true, 0x08080004, 0, directory, ref startup, out var created)); // Hidden, extended startup, suspended.
            process = new(created.Process, true); thread = new(created.Thread, true);
            Check(Native.AssignProcessToJobObject(job, process));
            var owned = new ProgressProcess(process, created.ProcessId, job, stdout, stderr);
            token.ThrowIfCancellationRequested(); if (Native.ResumeThread(thread) == uint.MaxValue) throw Failure();
            transferred = true; return owned;
        }
        finally
        {
            if (!transferred)
            {
                if (process is { IsInvalid: false }) _ = Native.TerminateProcess(process, 1);
                job?.Dispose(); stdout?.Dispose(); stderr?.Dispose(); process?.Dispose();
            }
            thread?.Dispose(); input?.Dispose(); outputWrite?.Dispose(); errorWrite?.Dispose();
            if (initialized) Native.DeleteProcThreadAttributeList(attributes);
            if (attributes != 0) Marshal.FreeHGlobal(attributes); if (handles != 0) Marshal.FreeHGlobal(handles);
        }
    }
    private static (NamedPipeServerStream Reader, NamedPipeClientStream Writer) CreateOutputPipe(CancellationToken token)
    {
        string name = "peel-progress-" + Guid.NewGuid().ToString("N");
        var server = new NamedPipeServerStream(name, PipeDirection.In, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly, 8192, 8192);
        NamedPipeClientStream? client = null;
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token); deadline.CancelAfter(TimeSpan.FromSeconds(3));
        try
        {
            var connected = server.WaitForConnectionAsync(deadline.Token);
            client = new NamedPipeClientStream(".", name, PipeDirection.Out, PipeOptions.None, TokenImpersonationLevel.Identification, HandleInheritability.Inheritable);
            client.Connect(3000); connected.GetAwaiter().GetResult(); return (server, client);
        }
        catch { deadline.Cancel(); client?.Dispose(); server.Dispose(); throw; }
    }
    internal async Task TerminateOwnedAsync()
    {
        if (job is null) return;
        Check(Native.TerminateJobObject(job, 1));
        for (int i = 0; i < 100; i++)
        {
            Check(Native.QueryInformationJobObject(job, 1, out var accounting, (uint)Marshal.SizeOf<Native.Accounting>(), 0));
            if (accounting.ActiveProcesses == 0) return;
            await Task.Delay(50).ConfigureAwait(false);
        }
        throw new IOException("Windows has not confirmed that the command's job finished stopping.");
    }
    public void Dispose() { job?.Dispose(); Output?.Dispose(); Error?.Dispose(); process.Dispose(); }
    private static void Check(bool result) { if (!result) throw Failure(); }
    private static Win32Exception Failure() => new(Marshal.GetLastPInvokeError());
    private static class Native
    {
        [StructLayout(LayoutKind.Sequential)] internal struct SecurityAttributes { internal uint Length; internal nint Descriptor; internal int Inherit; }
        [StructLayout(LayoutKind.Sequential)] internal struct StartupInfo
        {
            internal uint Size; internal nint Reserved, Desktop, Title;
            internal uint X, Y, Width, Height, XChars, YChars, Fill, Flags;
            internal ushort Show, ReservedCount; internal nint ReservedBytes, Input, Output, Error;
        }
        [StructLayout(LayoutKind.Sequential)] internal struct StartupInfoEx { internal StartupInfo Startup; internal nint Attributes; }
        [StructLayout(LayoutKind.Sequential)] internal struct ProcessInformation { internal nint Process, Thread; internal uint ProcessId, ThreadId; }
        [StructLayout(LayoutKind.Sequential)] internal struct BasicLimits
        { internal long ProcessTime, JobTime; internal uint Flags; internal nuint MinimumWorkingSet, MaximumWorkingSet; internal uint ActiveLimit; internal nuint Affinity; internal uint Priority, Scheduling; }
        [StructLayout(LayoutKind.Sequential)] internal struct IoCounters { internal ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes; }
        [StructLayout(LayoutKind.Sequential)] internal struct ExtendedLimits { internal BasicLimits Basic; internal IoCounters Io; internal nuint ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory; }
        [StructLayout(LayoutKind.Sequential)] internal struct Accounting { internal long User, Kernel, PeriodUser, PeriodKernel; internal uint Faults, TotalProcesses, ActiveProcesses, Terminated; }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern SafeFileHandle CreateFileW(string path, uint access, uint sharing, ref SecurityAttributes security, uint creation, uint attributes, nint template);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern SafeFileHandle CreateJobObjectW(nint security, string? name);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool SetInformationJobObject(SafeFileHandle job, int type, ref ExtendedLimits limits, uint size);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool QueryInformationJobObject(SafeFileHandle job, int type, out Accounting accounting, uint size, nint returned);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool InitializeProcThreadAttributeList(nint attributes, uint count, uint flags, ref nuint size);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool UpdateProcThreadAttribute(nint attributes, uint flags, nuint kind, nint value, nuint size, nint previous, nint returned);
        [DllImport("kernel32.dll")] internal static extern void DeleteProcThreadAttributeList(nint attributes);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern bool CreateProcessW(string executable, StringBuilder command, nint processSecurity, nint threadSecurity, bool inherit, uint flags, nint environment, string directory, ref StartupInfoEx startup, out ProcessInformation created);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool AssignProcessToJobObject(SafeFileHandle job, SafeFileHandle process);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern uint ResumeThread(SafeFileHandle thread);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool TerminateProcess(SafeFileHandle process, uint code);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool TerminateJobObject(SafeFileHandle job, uint code);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool GetExitCodeProcess(SafeFileHandle process, out uint code);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern uint WaitForSingleObject(SafeFileHandle handle, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern SafeFileHandle OpenProcess(uint access, bool inherit, uint id);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool GetProcessTimes(SafeFileHandle process, out long creation, out long exit, out long kernel, out long user);
    }
}
