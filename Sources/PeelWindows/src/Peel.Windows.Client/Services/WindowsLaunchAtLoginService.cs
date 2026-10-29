using Microsoft.Win32;

namespace Peel.Windows.Client.Services;

internal sealed class WindowsLaunchAtLoginService
{
    internal const string BackgroundArgument = "--background";
    internal const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    internal const string RunValueName = "Peel for Windows";

    private readonly string registryPath;
    private readonly string valueName;
    private readonly string commandLine;

    internal WindowsLaunchAtLoginService(
        string? executablePath = null,
        string registryPath = RunKeyPath,
        string valueName = RunValueName)
    {
        executablePath ??= Environment.ProcessPath;
        if (string.IsNullOrWhiteSpace(executablePath))
        {
            throw new InvalidOperationException("The Peel executable path is unavailable.");
        }
        if (executablePath.Contains('"'))
        {
            throw new ArgumentException("The Peel executable path contains an invalid quote.", nameof(executablePath));
        }
        if (string.IsNullOrWhiteSpace(registryPath))
        {
            throw new ArgumentException("A launch-at-login registry path is required.", nameof(registryPath));
        }
        if (string.IsNullOrWhiteSpace(valueName) || valueName.Contains('\\'))
        {
            throw new ArgumentException("A valid launch-at-login value name is required.", nameof(valueName));
        }

        this.registryPath = registryPath;
        this.valueName = valueName;
        commandLine = $"\"{executablePath}\" {BackgroundArgument}";
    }

    internal string CommandLine => commandLine;

    internal bool IsEnabled
    {
        get
        {
            using RegistryKey? key = Registry.CurrentUser.OpenSubKey(registryPath, writable: false);
            return key?.GetValue(valueName, null, RegistryValueOptions.DoNotExpandEnvironmentNames)
                is string stored && StringComparer.Ordinal.Equals(stored, commandLine);
        }
    }

    internal void SetEnabled(bool enabled)
    {
        if (enabled)
        {
            using RegistryKey key = Registry.CurrentUser.CreateSubKey(registryPath, writable: true) ??
                throw new InvalidOperationException("The Windows sign-in settings key is unavailable.");
            key.SetValue(valueName, commandLine, RegistryValueKind.String);
            return;
        }

        using RegistryKey? existing = Registry.CurrentUser.OpenSubKey(registryPath, writable: true);
        existing?.DeleteValue(valueName, throwOnMissingValue: false);
    }

    internal static bool IsBackgroundStart(IEnumerable<string> arguments)
    {
        ArgumentNullException.ThrowIfNull(arguments);
        return arguments.Any(argument => StringComparer.OrdinalIgnoreCase.Equals(
            argument,
            BackgroundArgument));
    }
}
