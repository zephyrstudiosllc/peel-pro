using System.Text;
using Peel.Windows.Client.Utilities;

namespace Peel.Windows.Client.Tests;
internal static partial class Program
{
    private static void ProgressParsing()
    {
        Equal<int?>(0, ProgressCapture.Parse("SIDEPULSE_PROGRESS=0")); Equal<int?>(100, ProgressCapture.Parse("SIDEPULSE_PROGRESS=100\r"));
        foreach (string invalid in new[] { "SIDEPULSE_PROGRESS=101", "SIDEPULSE_PROGRESS=-1", "SIDEPULSE_PROGRESS=1.5", "SIDEPULSE_PROGRESS=１", "SIDEPULSE_PROGRESS= 5", "xSIDEPULSE_PROGRESS=5", "SIDEPULSE_PROGRESS=", "SIDEPULSE_PROGRESS=1000" })
            Equal<int?>(null, ProgressCapture.Parse(invalid));
        var capture = new ProgressCapture(); capture.Consume("SIDEPULSE_PRO"u8, true); capture.Consume("GRESS=42\r\n"u8, true); Equal<int?>(42, capture.Percent);
        capture.Consume("SIDEPULSE_PROGRESS=99\n"u8, false); Equal<int?>(42, capture.Percent);
        capture.Consume(new byte[ProgressCapture.MaximumLineBytes + 1], true); capture.Consume("SIDEPULSE_PROGRESS=90\n"u8, true); Equal<int?>(42, capture.Percent);
        capture.Consume("SIDEPULSE_PROGRESS=60"u8, true); capture.EndOutput(); Equal<int?>(60, capture.Percent);
        capture.Consume(new byte[ProgressCapture.MaximumLogBytes + 100], false); Equal(ProgressCapture.MaximumLogBytes, capture.LogBytes);
        capture.Consume("SIDEPULSE_PROGRESS=100\n"u8, true); Equal<int?>(100, capture.Percent); True(capture.Text().Length < 17000, "Displayed output remains bounded after the log fills.");
    }
    private static async Task<int> NativeProgressTasksAsync()
    {
        string directory = Path.GetTempPath();
        await using var tasks = new ProgressTasks();
        tasks.Run("Write-Output 'SIDEPULSE_PROGRESS=25'; [Console]::Error.WriteLine('fixture stderr'); Write-Output 'SIDEPULSE_PROGRESS=100'; exit 0", directory);
        await tasks.Completion.WaitAsync(TimeSpan.FromSeconds(15));
        Equal("completed", tasks.Snapshot.Phase); Equal<int?>(0, tasks.Snapshot.ExitCode); Equal<int?>(100, tasks.Snapshot.Percent);
        True(tasks.Output().Contains("fixture stderr"), "Both streams are drained.");
        tasks.Run("Write-Output 'SIDEPULSE_PROGRESS=10'; exit 7", directory); await tasks.Completion.WaitAsync(TimeSpan.FromSeconds(15));
        Equal("failed", tasks.Snapshot.Phase); Equal<int?>(7, tasks.Snapshot.ExitCode);
        tasks.Run("$child = Start-Process -FilePath ([Environment]::GetFolderPath('System') + '\\WindowsPowerShell\\v1.0\\powershell.exe') -ArgumentList '-NoLogo','-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 60' -WindowStyle Hidden -PassThru; Write-Output ('CHILD_ID=' + $child.Id); Start-Sleep -Seconds 60", directory);
        int childId = 0;
        for (int i = 0; i < 100 && childId == 0; i++)
        {
            var line = tasks.Output(false).Split('\n').FirstOrDefault(l => l.StartsWith("CHILD_ID=", StringComparison.Ordinal));
            if (line is not null) int.TryParse(line[9..].Trim(), out childId);
            if (childId == 0) await Task.Delay(100);
        }
        True(childId > 0, "Fixture must observe its directly spawned child.");
        using (var child = ProgressProcess.Watch(childId))
        {
            tasks.Cancel(); await tasks.Completion.WaitAsync(TimeSpan.FromSeconds(10));
            Equal("cancelled", tasks.Snapshot.Phase); True(child.Exited, "Cancel must stop the owned job's child, not only its leader.");
        }
        using (var fixture = ProgressProcess.Start("Start-Sleep -Seconds 60", directory, CancellationToken.None))
        {
            Throws<InvalidOperationException>(() => ProgressProcess.Watch((int)fixture.Id, fixture.StartedUtcTicks + 1));
            tasks.Watch((int)fixture.Id, fixture.StartedUtcTicks);
            await Task.Delay(250); tasks.Cancel(); await tasks.Completion.WaitAsync(TimeSpan.FromSeconds(5));
            True(!fixture.Exited, "Canceling a watch must not stop its process."); Equal("cancelled", tasks.Snapshot.Phase);
            await fixture.TerminateOwnedAsync();
        }
        tasks.Run("Start-Sleep -Seconds 60", directory); tasks.Cancel(); await tasks.Completion.WaitAsync(TimeSpan.FromSeconds(10));
        Equal("cancelled", tasks.Snapshot.Phase);
        tasks.Clear(); Equal("idle", tasks.Snapshot.Phase); Equal("", tasks.Output());
        Console.WriteLine("PASS native PowerShell progress, stderr, exit codes, suspended Job Object launch, descendant cancellation, exact process watch identity, read-only watch cancellation and startup cancellation.");
        return 0;
    }
}
