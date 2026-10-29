using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;

namespace Peel.Windows.Client.Services;

/// <summary>The exact bridge request a launch belongs to: its caller-bound token and the admission it was accepted under.</summary>
internal sealed record LocalLaunchAuthority(Func<bool> Admitted, CancellationToken Request);

/// <summary>Launch side effects, in stages. Production uses Windows; tests fake each stage, so no app is launched.</summary>
internal interface ILocalAppLaunchPlatform
{
    /// <summary>The verified Windows Terminal app ID for this user, or null.</summary>
    string? FindWindowsTerminal(CancellationToken cancellationToken);
    /// <summary>Creates the activation manager. Nothing is activated until <see cref="ILocalPackagedActivator.Activate"/>.</summary>
    ILocalPackagedActivator CreateActivator();
    /// <summary>Opens the fixed <c>ms-settings:</c> URI.</summary>
    void OpenSettings();
    /// <summary>Starts exactly this executable with no arguments and no PATH search; returns its process ID.</summary>
    int StartExecutable(string path, string workingDirectory);
}

internal interface ILocalPackagedActivator : IDisposable
{
    /// <summary>Activates exactly this app ID with no arguments and no elevation request; returns its process ID.</summary>
    uint Activate(string appUserModelId);
}

internal sealed class LocalAppCatalog
{
    private sealed record Entry(string Id, string Name, string Path, FileIdentity? Identity, string? AppUserModelId = null);
    // Settings is a packaged app outside App Paths. This fixed URI takes no agent-supplied text or arguments.
    internal const string SettingsUri = "ms-settings:";
    // Windows Terminal: the Microsoft-published package family, activated by its exact app ID with no arguments.
    internal const string TerminalFamily = "Microsoft.WindowsTerminal_8wekyb3d8bbwe";
    internal const string TerminalAppUserModelId = TerminalFamily + "!App";
    private const string RevokedMessage = "Local agent access is disabled, expired or Windows is locked.";
    private readonly Dictionary<string, Entry> entries = new();
    private readonly Func<bool> terminalAllowed;
    private readonly ILocalAppLaunchPlatform platform;
    /// <param name="terminalAllowed">True only while the person's fresh "Allow AI to see and use apps on this PC" consent is on.</param>
    /// <param name="platform">The launch side effects; tests substitute fakes. Production uses Windows.</param>
    internal LocalAppCatalog(Func<bool>? terminalAllowed = null, ILocalAppLaunchPlatform? platform = null)
    {
        this.terminalAllowed = terminalAllowed ?? (() => false);
        this.platform = platform ?? new Win32LocalAppLaunchPlatform();
    }
    private static readonly HashSet<string> Excluded = new(StringComparer.OrdinalIgnoreCase)
        { "cmd", "powershell", "pwsh", "wscript", "cscript", "mshta", "rundll32", "regsvr32", "reg", "msiexec", "conhost", "wt", "bash", "wsl" };
    public void Clear() => entries.Clear();
    public object List(string query)
    {
        entries.Clear(); var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if ("Settings".Contains(query, StringComparison.OrdinalIgnoreCase))
        {
            var settings = new Entry(Guid.NewGuid().ToString("N"), "Settings", SettingsUri, null);
            entries.Add(settings.Id, settings);
        }
        // Shells stay excluded below; Terminal is offered only as the verified packaged app under fresh control consent.
        if ("Terminal".Contains(query, StringComparison.OrdinalIgnoreCase) && terminalAllowed() &&
            platform.FindWindowsTerminal(CancellationToken.None) is { } terminal)
        {
            var entry = new Entry(Guid.NewGuid().ToString("N"), "Terminal", "", null, terminal);
            entries.Add(entry.Id, entry);
        }
        foreach (var hive in new[] { RegistryHive.CurrentUser, RegistryHive.LocalMachine })
        foreach (var view in new[] { RegistryView.Registry64, RegistryView.Registry32 })
        {
            using var root = RegistryKey.OpenBaseKey(hive, view);
            using var key = root.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\App Paths");
            if (key is null) continue;
            foreach (string name in key.GetSubKeyNames().Take(512))
            {
                using var app = key.OpenSubKey(name);
                if (app?.GetValue(null) is not string path) continue;
                path = Environment.ExpandEnvironmentVariables(path).Trim().Trim('"');
                string display = Path.GetFileNameWithoutExtension(path);
                if (!Path.IsPathFullyQualified(path) || !path.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ||
                    Excluded.Contains(display) || !display.Contains(query, StringComparison.OrdinalIgnoreCase) || paths.Contains(path)) continue;
                try
                {
                    using var file = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read);
                    var entry = new Entry(Guid.NewGuid().ToString("N"), display, path, Identity(file.SafeFileHandle));
                    entries.Add(entry.Id, entry); paths.Add(path);
                    if (entries.Count == 128) break;
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
            }
            if (entries.Count >= 128) break;
        }
        return new { apps = entries.Values.Select(a => new { appId = a.Id, name = a.Name }), truncated = entries.Count == 128 };
    }
    /// <summary>
    /// Launches one listed entry for exactly this request. The request's token and admission (and, for Terminal, fresh
    /// control consent with an owned activity monitor) are rechecked after each validation stage and immediately
    /// before the side effect, so Stop, a lost monitor, revoked connections or this caller leaving launch nothing.
    /// </summary>
    public object Launch(string id, LocalLaunchAuthority authority)
    {
        if (!entries.TryGetValue(id, out var entry)) throw new ArgumentException("List apps first and use an exact current appId.");
        RequireRequest(authority);
        if (entry.AppUserModelId is { } appUserModelId)
        {
            RequireTerminal(authority);
            string? found = platform.FindWindowsTerminal(authority.Request);
            // Package lookup can take a while; consent, the monitor or this caller may have gone meanwhile.
            RequireTerminal(authority);
            if (!string.Equals(found, appUserModelId, StringComparison.Ordinal))
            { entries.Clear(); throw new InvalidOperationException("Windows Terminal changed or is no longer installed. Refresh the app list."); }
            using var activator = platform.CreateActivator();
            RequireTerminal(authority); // Immediately before activation, after the activation manager exists.
            uint processId = activator.Activate(appUserModelId);
            return new { status = "launched", appId = id, processId, nextStep = "List windows again to locate Windows Terminal's window. It opens with the person's default profile." };
        }
        if (entry.Identity is null)
        {
            if (!string.Equals(entry.Path, SettingsUri, StringComparison.Ordinal)) throw new InvalidOperationException("The app changed. Refresh the app list.");
            RequireRequest(authority);
            platform.OpenSettings();
            return new { status = "launched", appId = id, nextStep = "List windows again to locate Settings' current window." };
        }
        using var file = File.Open(entry.Path, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (Identity(file.SafeFileHandle) != entry.Identity) { entries.Clear(); throw new InvalidOperationException("The app changed. Refresh the app list."); }
        RequireRequest(authority); // After identity validation, immediately before CreateProcess.
        // Keep the read handle open without write/delete sharing until CreateProcess has bound the executable.
        int started = platform.StartExecutable(entry.Path, Path.GetDirectoryName(entry.Path)!);
        return new { status = "launched", appId = id, processId = started, nextStep = "List windows again to locate the app's current window." };
    }

    private void RequireRequest(LocalLaunchAuthority authority)
    {
        authority.Request.ThrowIfCancellationRequested();
        if (!authority.Admitted()) { entries.Clear(); throw new InvalidOperationException(RevokedMessage); }
    }

    private void RequireTerminal(LocalLaunchAuthority authority)
    {
        RequireRequest(authority);
        if (!terminalAllowed())
        { entries.Clear(); throw new LocalAgentException("consent_required", "Turn on \"Allow AI to see and use apps on this PC\" in Peel Pro to open Windows Terminal. Agents cannot turn it on."); }
    }

    private readonly record struct FileIdentity(uint Volume, ulong Index, ulong Size, ulong Written);
    private static FileIdentity Identity(SafeFileHandle handle)
    {
        if (!GetFileInformationByHandle(handle, out var info)) throw new IOException("App identity is unavailable.");
        return new(info.Volume, ((ulong)info.IndexHigh << 32) | info.IndexLow, ((ulong)info.SizeHigh << 32) | info.SizeLow, info.Write);
    }
    [StructLayout(LayoutKind.Sequential, Pack = 4)] private struct FileInfoNative
    { public uint Attributes; public uint CreationLow, CreationHigh, AccessLow, AccessHigh; public ulong Write; public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow; }
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInfoNative info);
}

/// <summary>Production launch stages: package lookup, packaged activation, the fixed Settings URI and exact executables.</summary>
internal sealed class Win32LocalAppLaunchPlatform : ILocalAppLaunchPlatform
{
    /// <summary>
    /// The installed Windows Terminal app ID for this user, or null. Accepts only the Microsoft package family with a
    /// Store or system signature, not in development mode, in a healthy state and exposing exactly that app entry.
    /// </summary>
    public string? FindWindowsTerminal(CancellationToken cancellationToken)
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041)) return null;
        try
        {
            foreach (var package in new global::Windows.Management.Deployment.PackageManager().FindPackagesForUser(string.Empty, LocalAppCatalog.TerminalFamily))
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (package.IsDevelopmentMode || !package.Status.VerifyIsOK() ||
                    package.SignatureKind is not (global::Windows.ApplicationModel.PackageSignatureKind.Store or global::Windows.ApplicationModel.PackageSignatureKind.System))
                    continue;
                if (package.GetAppListEntries().Any(e => string.Equals(e.AppUserModelId, LocalAppCatalog.TerminalAppUserModelId, StringComparison.Ordinal)))
                    return LocalAppCatalog.TerminalAppUserModelId;
            }
        }
        catch (Exception e) when (e is COMException or UnauthorizedAccessException or InvalidOperationException or ArgumentException) { }
        return null;
    }

    public ILocalPackagedActivator CreateActivator() => new ActivationManager();

    public void OpenSettings()
    {
        using var settings = Process.Start(new ProcessStartInfo(LocalAppCatalog.SettingsUri) { UseShellExecute = true });
    }

    public int StartExecutable(string path, string workingDirectory)
    {
        using var process = Process.Start(new ProcessStartInfo(path) { UseShellExecute = false, WorkingDirectory = workingDirectory });
        if (process is null) throw new InvalidOperationException("Windows did not launch the app.");
        return process.Id;
    }

    /// <summary>Packaged-app activation with no arguments, no path search and no elevation request.</summary>
    private sealed class ActivationManager : ILocalPackagedActivator
    {
        private object? instance;

        internal ActivationManager()
        {
            try
            {
                var type = Type.GetTypeFromCLSID(new Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C"), throwOnError: true)!;
                instance = Activator.CreateInstance(type)!;
            }
            catch (COMException e) { throw new InvalidOperationException("Windows did not open Windows Terminal: " + e.Message); }
        }

        public uint Activate(string appUserModelId)
        {
            var manager = (IApplicationActivationManager)(instance ?? throw new ObjectDisposedException(nameof(ActivationManager)));
            try
            {
                int result = manager.ActivateApplication(appUserModelId, null, 0, out uint processId);
                if (result < 0) throw new InvalidOperationException($"Windows did not open Windows Terminal (0x{result:X8}).");
                return processId;
            }
            catch (COMException e) { throw new InvalidOperationException("Windows did not open Windows Terminal: " + e.Message); }
        }

        public void Dispose()
        {
            if (instance is not null && Marshal.IsComObject(instance)) _ = Marshal.ReleaseComObject(instance);
            instance = null;
        }
    }

    [ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IApplicationActivationManager
    {
        [PreserveSig] int ActivateApplication([MarshalAs(UnmanagedType.LPWStr)] string appUserModelId, [MarshalAs(UnmanagedType.LPWStr)] string? arguments, int options, out uint processId);
    }
}
