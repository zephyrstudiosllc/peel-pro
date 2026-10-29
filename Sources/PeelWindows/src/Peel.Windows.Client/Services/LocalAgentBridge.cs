using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text.Json;
using System.Windows.Threading;
using Microsoft.Win32.SafeHandles;
using Peel.Windows.Host.Windows;
using Peel.Windows.Protocol;

namespace Peel.Windows.Client.Services;

/// <summary>One bounded request per current-user local pipe; all effects run on the owning dispatcher.</summary>
internal sealed class LocalAgentBridge : IAsyncDisposable
{
    private readonly Dispatcher dispatcher;
    private readonly Func<bool> isAllowed;
    private readonly Func<long> consentVersion;
    private readonly Func<object> diagnostics;
    private readonly Action<string, string> notify;
    private readonly CancellationTokenSource lifetime = new();
    private readonly Task[] workers;
    private readonly Win32WindowEnumerator enumerator = new();
    private readonly Dictionary<uint, WindowDescriptor> windows = new();
    private readonly LocalAppCatalog apps;
    private uint nextId;
    private readonly LocalComputerAccess? localComputer;
    // launchPlatform: launch side effects; tests substitute fakes so no app is launched. Production uses Windows.
    public LocalAgentBridge(Dispatcher dispatcher, Func<bool> isAllowed, Func<object> diagnostics, Action<string, string> notify,
        string? pipeName = null, Func<long>? consentVersion = null, LocalComputerAccess? localComputer = null,
        ILocalAppLaunchPlatform? launchPlatform = null)
    {
        this.dispatcher = dispatcher; this.isAllowed = isAllowed; this.diagnostics = diagnostics; this.notify = notify;
        this.localComputer = localComputer;
        this.consentVersion = consentVersion ?? (() => 0);
        // Windows Terminal is offered only while the person's fresh local-control consent is on.
        apps = new LocalAppCatalog(() => this.localComputer?.ControlReady ?? false, launchPlatform);
        using var identity = WindowsIdentity.GetCurrent();
        string name = pipeName ?? LocalAgentProtocol.PipeName(identity.User!.Value);
        workers = Enumerable.Range(0, 4).Select(_ => Task.Run(() => ServeAsync(name))).ToArray();
    }
    private async Task ServeAsync(string name)
    {
        while (!lifetime.IsCancellationRequested)
        {
            try
            {
                await using var pipe = CreateLocalPipe(name);
                await pipe.WaitForConnectionAsync(lifetime.Token).ConfigureAwait(false);
                long admittedVersion = consentVersion();
                using var deadline = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
                deadline.CancelAfter(TimeSpan.FromSeconds(8));
                byte[] line = await LocalAgentProtocol.ReadLineAsync(pipe, deadline.Token).ConfigureAwait(false) ?? throw new EndOfStreamException();
                if (!GetNamedPipeClientProcessId(pipe.SafePipeHandle, out uint pid) || !GetNamedPipeClientSessionId(pipe.SafePipeHandle, out uint session) ||
                    session != (uint)Process.GetCurrentProcess().SessionId || pid == 0) continue;
                // The pipe rejects remote clients in the kernel and its DACL permits only this user.
                using var client = Process.GetProcessById(checked((int)pid));
                if (client.SessionId != Process.GetCurrentProcess().SessionId) continue;
                // This request lives only as long as its caller: pipe EOF, any byte after the one request line, or
                // the caller process exiting cancels this request's token alone, never other connections.
                await using var caller = new CallerWatch(pipe, pid, deadline);
                using var document = JsonDocument.Parse(line, new JsonDocumentOptions { MaxDepth = 16 });
                JsonElement request = document.RootElement;
                string id = request.GetProperty("id").GetString() ?? "";
                if (!Guid.TryParseExact(id, "D", out _) || request.GetProperty("version").GetInt32() != 1) throw new InvalidDataException();
                string method = request.GetProperty("method").GetString() ?? "";
                var parameters = request.GetProperty("params").Clone();
                object reply;
                try
                {
                    bool control = method is "inspectWindow" or "controlWindow";
                    object? result = await dispatcher.InvokeAsync(() =>
                    {
                        deadline.Token.ThrowIfCancellationRequested();
                        if (!isAllowed() || admittedVersion != consentVersion())
                        {
                            windows.Clear(); apps.Clear(); localComputer?.InvalidateListings();
                            if (control) throw new LocalAgentException("consent_required", "Local agent access is disabled, expired or Windows is locked.");
                            throw new InvalidOperationException("Local agent access is disabled, expired or Windows is locked.");
                        }
                        // Side effects that outlast admission (launch) recheck this exact request's token and admission.
                        return control ? null : Handle(method, parameters,
                            new LocalLaunchAuthority(() => isAllowed() && admittedVersion == consentVersion(), deadline.Token));
                    }, DispatcherPriority.Background, deadline.Token);
                    // Inspect and control run off the dispatcher so capture, input and bounded delays never block
                    // the UI thread. Admission was checked on the dispatcher above; afterwards the consent version
                    // (an interlocked counter) and LocalComputerAccess's own state are rechecked at every boundary.
                    result ??= await HandleControlAsync(method, parameters, () => admittedVersion == consentVersion(), deadline.Token).ConfigureAwait(false);
                    reply = new { version = 1, id, result };
                }
                catch (LocalAgentException e)
                { reply = new { version = 1, id, error = new { code = e.Code, message = Safe(e.Message, 512) } }; }
                catch (Exception e) when (e is InvalidOperationException or ArgumentException or System.ComponentModel.Win32Exception or IOException or UnauthorizedAccessException)
                { reply = new { version = 1, id, error = new { code = "unavailable", message = Safe(e.Message, 512) } }; }
                await pipe.WriteAsync(LocalAgentProtocol.EncodeLine(reply), deadline.Token).ConfigureAwait(false);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or OperationCanceledException or JsonException or
                ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception or OverflowException or KeyNotFoundException or
                InvalidDataException)
            {
                if (!lifetime.IsCancellationRequested) await Task.Delay(100, lifetime.Token).ConfigureAwait(false);
            }
        }
    }
    private object Handle(string method, JsonElement p, LocalLaunchAuthority request)
    {
        string[] names = method switch
        {
            "listDevices" or "getStreamDiagnostics" => [], "listWindows" => ["targetId"],
            "listApps" => ["targetId", "query"], "launchApp" => ["targetId", "appId"],
            "presentWindow" => ["targetId", "windowId"], "notify" => ["targetId", "title", "message"],
            _ => throw new ArgumentException("Unknown local agent method.")
        };
        if (p.ValueKind != JsonValueKind.Object || p.EnumerateObject().Any(v => !names.Contains(v.Name))) throw new ArgumentException("Unexpected method arguments.");
        if (names.Length > 0 && Text(p, "targetId", 256) != "local") throw new ArgumentException("Connected-device agent actions are unavailable in this build. Select the local PC.");
        switch (method)
        {
            case "listDevices":
                // inspectReady/controlReady report the real local consent gate; agents cannot change it.
                bool controlReady = localComputer?.ControlReady ?? false;
                return new { devices = new[] { new { targetId = "local", name = Environment.MachineName, platform = "Windows", kind = "local", agentReady = true,
                    inspectReady = controlReady, controlReady, controlStatus = localComputer?.Status ?? "Local inspect and control are unavailable in this build." } } };
            case "getStreamDiagnostics": return diagnostics();
            case "listApps": return apps.List(p.TryGetProperty("query", out _) ? Text(p, "query", 120) : "");
            case "launchApp": return apps.Launch(Text(p, "appId", 128), request);
            case "listWindows":
                // With local inspect/control wired, LocalComputerAccess owns window identity and tokens.
                if (localComputer is not null) return localComputer.ListWindows();
                windows.Clear();
                var list = enumerator.Enumerate().Where(w => !w.IsDisplay && w.AppLaunchTimeIntervalSince1970 is > 0).Take(129).ToArray();
                foreach (var window in list.Take(128)) windows.Add(checked(++nextId), window);
                return new { windows = windows.Select(w => new { windowId = w.Key, name = Safe(w.Value.ProcessName ?? "App", 120), title = Safe(w.Value.Title, 256),
                    processId = w.Value.ProcessId, width = w.Value.Bounds.Width, height = w.Value.Bounds.Height }), truncated = list.Length > 128 };
            case "presentWindow":
                if (!p.GetProperty("windowId").TryGetUInt32(out uint id)) throw new ArgumentException("List current windows before presenting an exact windowId.");
                WindowDescriptor current;
                if (localComputer is not null) current = localComputer.ResolveListedWindow(id);
                else
                {
                    if (!windows.TryGetValue(id, out var previous)) throw new ArgumentException("List current windows before presenting an exact windowId.");
                    current = enumerator.Enumerate().FirstOrDefault(w => w.Handle == previous.Handle && w.ProcessId == previous.ProcessId &&
                        w.AppLaunchTimeIntervalSince1970 == previous.AppLaunchTimeIntervalSince1970 && w.ClassName == previous.ClassName)
                        ?? throw new InvalidOperationException("The advertised app instance changed. Refresh its window list.");
                }
                if (IsIconic(current.Handle)) ShowWindowAsync(current.Handle, 9);
                if (!SetForegroundWindow(current.Handle)) throw new InvalidOperationException("Windows refused to bring that app forward.");
                return new { status = "opened", windowId = id };
            case "notify": notify(Text(p, "title", 120), Text(p, "message", 2000)); return new { status = "submitted" };
            default: throw new InvalidOperationException();
        }
    }
    private async Task<object> HandleControlAsync(string method, JsonElement p, Func<bool> admitted, CancellationToken token)
    {
        var access = localComputer ?? throw new LocalAgentException("unavailable", "Local inspect and control are unavailable in this build.");
        if (p.ValueKind != JsonValueKind.Object) throw new ArgumentException("Arguments must be an object.");
        if (method == "inspectWindow" && p.EnumerateObject().Any(v => v.Name is not ("targetId" or "windowId" or "windowToken")))
            throw new ArgumentException("Inspect requires only the exact listed window identity.");
        if (Text(p, "targetId", 256) != LocalComputerAccess.TargetId) throw new ArgumentException("Connected-device agent actions are unavailable in this build. Select the local PC.");
        if (!p.TryGetProperty("windowId", out var idValue) || idValue.ValueKind != JsonValueKind.Number || !idValue.TryGetUInt32(out uint windowId) || windowId < 1)
            throw new ArgumentException("windowId must be a positive integer.");
        string windowToken = Text(p, "windowToken", 64);
        if (method == "inspectWindow") return await access.InspectAsync(windowId, windowToken, admitted, token).ConfigureAwait(false);
        string inspectionId = Text(p, "inspectionId", 64);
        LocalControlCommand command = LocalControlCommand.Parse(p);
        return await access.ControlAsync(windowId, windowToken, inspectionId, command, admitted, token).ConfigureAwait(false);
    }
    private static string Text(JsonElement p, string name, int maximum)
    {
        if (!p.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.String || value.GetString() is not { } text ||
            text.Length > maximum || text.Any(c => c < 32 || c == 127)) throw new ArgumentException("Invalid " + name + ".");
        return text;
    }
    private static string Safe(string text, int count) => new(text.Take(count).Select(c => c < 32 || c == 127 ? ' ' : c).ToArray());
    public void Invalidate() { windows.Clear(); apps.Clear(); }
    /// <summary>
    /// Access is granted to this user only. The owner is the token's default owner, which is what
    /// PipeOptions.CurrentUserOnly clients compare against; for an elevated administrator token that is
    /// BUILTIN\Administrators rather than the user. The OWNER RIGHTS entry limits the owner to reading the
    /// descriptor, so ownership never adds WRITE_DAC for anyone.
    /// </summary>
    internal static string PipeSecurityDescriptor(string userSid, string ownerSid) => $"O:{ownerSid}D:P(A;;GA;;;{userSid})(A;;RC;;;OW)";
    private static NamedPipeServerStream CreateLocalPipe(string name)
    {
        using var identity = WindowsIdentity.GetCurrent();
        string sid = identity.User!.Value;
        string owner = (identity.Owner ?? identity.User!).Value;
        if (!ConvertStringSecurityDescriptorToSecurityDescriptor(PipeSecurityDescriptor(sid, owner), 1, out nint descriptor, out _))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        try
        {
            var attributes = new SecurityAttributes { Length = Marshal.SizeOf<SecurityAttributes>(), Descriptor = descriptor };
            // PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED; PIPE_REJECT_REMOTE_CLIENTS, byte mode.
            var handle = CreateNamedPipe(@"\\.\pipe\" + name, 0x40000003, 8, 4, 8192, 8192, 0, ref attributes);
            if (handle.IsInvalid) { int error = Marshal.GetLastWin32Error(); handle.Dispose(); throw new System.ComponentModel.Win32Exception(error); }
            try { return new NamedPipeServerStream(PipeDirection.InOut, true, false, handle); }
            catch { handle.Dispose(); throw; }
        }
        finally { _ = LocalFree(descriptor); }
    }
    public async ValueTask DisposeAsync()
    {
        lifetime.Cancel();
        try { await Task.WhenAll(workers).ConfigureAwait(false); } catch (OperationCanceledException) { }
        lifetime.Dispose();
    }
    /// <summary>Watches one request's caller and cancels only that request's token.</summary>
    private sealed class CallerWatch : IAsyncDisposable
    {
        private const uint Synchronize = 0x00100000;
        private readonly CancellationTokenSource stop = new();
        private readonly Task reader;
        private readonly ProcessExitHandle? exit;
        private readonly RegisteredWaitHandle? exitWait;

        internal CallerWatch(PipeStream pipe, uint processId, CancellationTokenSource request)
        {
            reader = WatchPipeAsync(pipe, request, stop.Token);
            // Best effort: pipe EOF is authoritative; a caller we cannot open for SYNCHRONIZE is watched by EOF alone.
            var handle = OpenProcess(Synchronize, false, processId);
            if (handle.IsInvalid) { handle.Dispose(); return; }
            exit = new ProcessExitHandle(handle);
            exitWait = ThreadPool.RegisterWaitForSingleObject(exit, (_, timedOut) => { if (!timedOut) Cancel(request); }, null, Timeout.Infinite, executeOnlyOnce: true);
        }

        private static async Task WatchPipeAsync(PipeStream pipe, CancellationTokenSource request, CancellationToken stop)
        {
            var one = new byte[1];
            try { _ = await pipe.ReadAsync(one, stop).ConfigureAwait(false); } // 0 is EOF; any byte breaks one-request framing.
            catch (OperationCanceledException) when (stop.IsCancellationRequested) { return; }
            catch (Exception e) when (e is IOException or ObjectDisposedException or OperationCanceledException) { }
            if (!stop.IsCancellationRequested) Cancel(request);
        }

        private static void Cancel(CancellationTokenSource request)
        {
            try { request.Cancel(); } catch (ObjectDisposedException) { } // The request already finished.
        }

        public async ValueTask DisposeAsync()
        {
            stop.Cancel();
            exitWait?.Unregister(null);
            exit?.Dispose();
            try { await reader.ConfigureAwait(false); } catch (Exception e) when (e is IOException or ObjectDisposedException or OperationCanceledException) { }
            stop.Dispose();
        }

        private sealed class ProcessExitHandle : WaitHandle
        {
            internal ProcessExitHandle(SafeWaitHandle handle) => SafeWaitHandle = handle;
        }
    }
    [DllImport("kernel32.dll", SetLastError = true)] private static extern SafeWaitHandle OpenProcess(uint access, bool inherit, uint processId);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe, out uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetNamedPipeClientSessionId(SafePipeHandle pipe, out uint session);
    [StructLayout(LayoutKind.Sequential)] private struct SecurityAttributes { public int Length; public nint Descriptor; public int Inherit; }
    [DllImport("advapi32.dll", EntryPoint = "ConvertStringSecurityDescriptorToSecurityDescriptorW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string descriptor, uint revision, out nint result, out uint size);
    [DllImport("kernel32.dll", EntryPoint = "CreateNamedPipeW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafePipeHandle CreateNamedPipe(string name, uint openMode, uint pipeMode, uint maximumInstances, uint outputBuffer, uint inputBuffer, uint timeout, ref SecurityAttributes attributes);
    [DllImport("kernel32.dll")] private static extern nint LocalFree(nint pointer);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(nint window);
    [DllImport("user32.dll")] private static extern bool IsIconic(nint window);
    [DllImport("user32.dll")] private static extern bool ShowWindowAsync(nint window, int command);
}
