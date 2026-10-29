using System.Diagnostics;
using System.IO;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;

namespace Peel.Windows.Client.Utilities;

public sealed record ProcessReading(int Id, long StartedUtcTicks, string Name, double CpuPercent,
    long MemoryBytes, bool HasWindow, int SessionId, bool IsHeld = false)
{
    public string CpuLabel => $"{CpuPercent:F1}%";
    public string MemoryLabel => $"{MemoryBytes / 1048576.0:N0} MB";
    public string StateLabel => IsHeld ? "Held" : "Running";
}

public sealed record SystemReading(DateTimeOffset SampledAt, double? CpuPercent, long MemoryUsedBytes,
    long MemoryTotalBytes, long StorageFreeBytes, long StorageTotalBytes, double? BatteryPercent,
    double ReceiveBytesPerSecond, double SendBytesPerSecond, IReadOnlyList<ProcessReading> Processes,
    HardwareReading? Hardware = null, bool? ExternallyPowered = null, bool? Charging = null)
{
    public double MemoryPercent => MemoryTotalBytes > 0 ? 100.0 * MemoryUsedBytes / MemoryTotalBytes : 0;
}

/// <summary>One serial sampler; cumulative counters are differenced against monotonic time.</summary>
public sealed class SystemMonitor : IDisposable
{
    private PerformanceCounters? counters;
    private Dictionary<int, (long Start, long Cpu)> previousProcesses = new();
    private readonly Dictionary<string, (long Receive, long Send)> previousNetwork = new();
    private long previousTimestamp;
    private ulong previousIdle, previousKernel, previousUser;

    public SystemReading Sample()
    {
        long timestamp = Stopwatch.GetTimestamp();
        double elapsed = previousTimestamp == 0 ? 0 : Stopwatch.GetElapsedTime(previousTimestamp, timestamp).TotalSeconds;
        double? cpu = null;
        if (GetSystemTimes(out ulong idle, out ulong kernel, out ulong user))
        {
            if (previousTimestamp != 0 && kernel >= previousKernel && user >= previousUser && idle >= previousIdle)
            {
                ulong total = (kernel - previousKernel) + (user - previousUser);
                if (total > 0) cpu = Math.Clamp(100.0 * (1 - (double)(idle - previousIdle) / total), 0, 100);
            }
            previousIdle = idle; previousKernel = kernel; previousUser = user;
        }
        var memory = new MemoryStatus { Length = (uint)Marshal.SizeOf<MemoryStatus>() };
        if (!GlobalMemoryStatusEx(ref memory)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        long free = 0, totalStorage = 0;
        string volume = Path.GetPathRoot(Environment.GetFolderPath(Environment.SpecialFolder.Windows)) ?? "C:\\";
        var drive = new DriveInfo(volume);
        if (drive.IsReady) { free = drive.AvailableFreeSpace; totalStorage = drive.TotalSize; }
        bool powerAvailable = GetSystemPowerStatus(out var power);
        double? battery = powerAvailable && power.BatteryLifePercent <= 100 && power.BatteryFlag != 255
            && (power.BatteryFlag & 128) == 0 ? power.BatteryLifePercent : null;
        bool? externallyPowered = powerAvailable && power.AcLineStatus <= 1 ? power.AcLineStatus == 1 : null;
        bool? charging = powerAvailable && power.BatteryFlag != 255 && (power.BatteryFlag & 128) == 0 ? (power.BatteryFlag & 8) != 0 : null;
        double rx = 0, tx = 0;
        var currentNetwork = new HashSet<string>(StringComparer.Ordinal);
        foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (nic.OperationalStatus != OperationalStatus.Up || nic.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
            try
            {
                var counters = nic.GetIPStatistics();
                currentNetwork.Add(nic.Id);
                if (elapsed > 0 && previousNetwork.TryGetValue(nic.Id, out var old))
                {
                    rx += Math.Max(0, counters.BytesReceived - old.Receive) / elapsed;
                    tx += Math.Max(0, counters.BytesSent - old.Send) / elapsed;
                }
                previousNetwork[nic.Id] = (counters.BytesReceived, counters.BytesSent);
            }
            catch (NetworkInformationException) { }
        }
        foreach (var id in previousNetwork.Keys.Where(id => !currentNetwork.Contains(id)).ToArray()) previousNetwork.Remove(id);
        var readings = new List<ProcessReading>();
        var next = new Dictionary<int, (long Start, long Cpu)>();
        foreach (var process in Process.GetProcesses())
        {
            using (process)
            {
                try
                {
                    long start = process.StartTime.ToUniversalTime().Ticks;
                    long used = process.TotalProcessorTime.Ticks;
                    double processCpu = 0;
                    if (elapsed > 0 && previousProcesses.TryGetValue(process.Id, out var old) && old.Start == start)
                        processCpu = Math.Clamp((used - old.Cpu) / (elapsed * TimeSpan.TicksPerSecond * Environment.ProcessorCount) * 100, 0, 100);
                    readings.Add(new(process.Id, start, process.ProcessName, processCpu,
                        process.WorkingSet64, process.MainWindowHandle != 0, process.SessionId));
                    next[process.Id] = (start, used);
                }
                catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException or NotSupportedException) { }
            }
        }
        previousTimestamp = timestamp;
        previousProcesses = next;
        return new(DateTimeOffset.UtcNow, cpu, checked((long)(memory.TotalPhysical - memory.AvailablePhysical)),
            checked((long)memory.TotalPhysical), free, totalStorage, battery, rx, tx,
            readings.OrderByDescending(p => p.CpuPercent).ThenByDescending(p => p.MemoryBytes).ToArray(), (counters ??= new()).Sample(), externallyPowered, charging);
    }
    public void Dispose() => counters?.Dispose();

    [StructLayout(LayoutKind.Sequential)] private struct MemoryStatus
    {
        public uint Length, Load;
        public ulong TotalPhysical, AvailablePhysical, TotalPageFile, AvailablePageFile, TotalVirtual, AvailableVirtual, AvailableExtendedVirtual;
    }
    [StructLayout(LayoutKind.Sequential)] private struct PowerStatus
    {
        public byte AcLineStatus, BatteryFlag, BatteryLifePercent, SystemStatusFlag;
        public uint BatteryLifeTime, BatteryFullLifeTime;
    }
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GlobalMemoryStatusEx(ref MemoryStatus status);
    [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetSystemTimes(out ulong idle, out ulong kernel, out ulong user);
    [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetSystemPowerStatus(out PowerStatus status);
}
