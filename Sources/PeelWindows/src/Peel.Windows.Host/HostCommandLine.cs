namespace Peel.Windows.Host;

internal sealed record HostCommandLine(bool DryRun, bool ShowHelp)
{
    public static HostCommandLine Parse(IEnumerable<string> arguments)
    {
        bool dryRun = true;
        bool showHelp = false;

        foreach (string argument in arguments)
        {
            switch (argument)
            {
                case "--dry-run":
                case "--list-windows":
                    dryRun = true;
                    break;

                case "--run":
                    dryRun = false;
                    break;

                case "--help":
                case "-h":
                case "/?":
                    showHelp = true;
                    break;

                default:
                    throw new ArgumentException($"unknown argument '{argument}'");
            }
        }

        return new HostCommandLine(dryRun, showHelp);
    }

    public static void PrintHelp(TextWriter writer)
    {
        writer.WriteLine("Usage: Peel.Windows.Host.exe [--dry-run]");
        writer.WriteLine();
        writer.WriteLine("  --dry-run, --list-windows  List capturable user windows without injecting input.");
        writer.WriteLine("  --run                      Show where to start the production Host.");
        writer.WriteLine("  --help                     Show this help.");
        writer.WriteLine();
        writer.WriteLine("No arguments is equivalent to --dry-run.");
        writer.WriteLine("Production hosting runs in the Peel Pro app (Peel.Windows.exe).");
    }

    public static void PrintLiveHostGuidance(TextWriter writer)
    {
        writer.WriteLine("Peel Pro: live hosting runs in Peel.Windows.exe.");
        writer.WriteLine(
            "This console executable is a window-discovery diagnostic; " +
            "use --dry-run or --list-windows.");
    }
}
