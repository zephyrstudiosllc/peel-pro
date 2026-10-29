using System.Text.Json;
using Peel.Windows.Client.Utilities;

namespace Peel.Windows.Client.Tests;

internal static partial class Program
{
    private static void AgentConfigurationStartsInstalledCompanion()
    {
        string root = Path.Combine(Path.GetTempPath(), "Peel.AgentConfiguration." + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            // Self-contained publish layout: the companion apphost and dll sit beside Peel; no dotnet host is needed.
            string exe = Path.Combine(root, "Peel.Windows.Mcp.exe"), dll = Path.Combine(root, "Peel.Windows.Mcp.dll");
            File.WriteAllBytes(exe, Array.Empty<byte>()); File.WriteAllBytes(dll, Array.Empty<byte>());
            var (command, args) = ReadAgentServer(CommandCenterViewModel.FormatAgentConfiguration(root, File.Exists));
            Equal(exe, command); Equal(0, args.Length);
            True(Path.IsPathFullyQualified(command), "The companion command must be absolute.");

            // Framework-dependent layout without the apphost keeps the dotnet host and exact sibling dll.
            File.Delete(exe);
            (command, args) = ReadAgentServer(CommandCenterViewModel.FormatAgentConfiguration(root, File.Exists));
            True(command == "dotnet" || (Path.IsPathFullyQualified(command) && Path.GetFileName(command).Equals("dotnet.exe", StringComparison.OrdinalIgnoreCase)),
                "Fallback must name the dotnet host.");
            SequenceEqual(new[] { dll }, args);

            // A companion anywhere other than the exact sibling path is never chosen.
            string elsewhere = Path.Combine(root, "old", "Peel.Windows.Mcp.exe");
            (command, args) = ReadAgentServer(CommandCenterViewModel.FormatAgentConfiguration(root, path => path == elsewhere));
            Equal("dotnet", command); SequenceEqual(new[] { dll }, args);
        }
        finally { Directory.Delete(root, recursive: true); }
    }

    private static (string Command, string[] Args) ReadAgentServer(string json)
    {
        using var document = JsonDocument.Parse(json);
        SequenceEqual(new[] { "mcpServers" }, document.RootElement.EnumerateObject().Select(p => p.Name));
        var servers = document.RootElement.GetProperty("mcpServers");
        SequenceEqual(new[] { "peel" }, servers.EnumerateObject().Select(p => p.Name));
        var peel = servers.GetProperty("peel");
        SequenceEqual(new[] { "command", "args" }, peel.EnumerateObject().Select(p => p.Name));
        return (peel.GetProperty("command").GetString()!, peel.GetProperty("args").EnumerateArray().Select(a => a.GetString()!).ToArray());
    }
}
