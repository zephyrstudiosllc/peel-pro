using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

namespace Peel.Windows.Client.Utilities;

public sealed record HardwareReading(double? GpuPercent, double? DedicatedBytes, double? SharedBytes,
    double? DiskReadBytesPerSecond, double? DiskWriteBytesPerSecond, double? DiskBusyPercent = null);

/// <summary>Windows PDH counters; missing driver counters stay unavailable.</summary>
internal sealed class PerformanceCounters : IDisposable
{
    private nint query;
    private readonly nint gpu, dedicated, shared, diskRead, diskWrite, diskIdle;
    public PerformanceCounters()
    {
        if (PdhOpenQuery(null, 0, out query) != 0) { query = 0; return; }
        gpu = Add(@"\GPU Engine(*)\Utilization Percentage");
        dedicated = Add(@"\GPU Adapter Memory(*)\Dedicated Usage");
        shared = Add(@"\GPU Adapter Memory(*)\Shared Usage");
        diskRead = Add(@"\PhysicalDisk(_Total)\Disk Read Bytes/sec");
        diskWrite = Add(@"\PhysicalDisk(_Total)\Disk Write Bytes/sec");
        diskIdle = Add(@"\PhysicalDisk(_Total)\% Idle Time");
    }
    private nint Add(string path) => PdhAddEnglishCounter(query, path, 0, out nint counter) == 0 ? counter : 0;
    public HardwareReading Sample()
    {
        if (query == 0 || PdhCollectQueryData(query) != 0) return new(null, null, null, null, null);
        var engines = Values(gpu);
        // Per-process instances share an engine; sum within that engine, then use the busiest engine.
        double? busy = engines.Count == 0 ? null : engines.GroupBy(x => Regex.Replace(x.Name, @"^pid_\d+_", "", RegexOptions.CultureInvariant))
            .Max(g => Math.Clamp(g.Sum(x => x.Value), 0, 100));
        double? idle = Single(diskIdle);
        return new(busy, Sum(dedicated), Sum(shared), Single(diskRead), Single(diskWrite), idle is { } n ? Math.Clamp(100 - n, 0, 100) : null);
    }
    private static double? Single(nint counter)
    {
        if (counter == 0 || PdhGetFormattedCounterValue(counter, 0x200, out _, out var value) != 0 || value.Status > 1 || !double.IsFinite(value.Value)) return null;
        return Math.Max(0, value.Value);
    }
    private static double? Sum(nint counter) { var values = Values(counter); return values.Count == 0 ? null : values.Sum(v => v.Value); }
    private static List<(string Name, double Value)> Values(nint counter)
    {
        var values = new List<(string, double)>();
        if (counter == 0) return values;
        uint size = 0;
        _ = PdhGetFormattedCounterArray(counter, 0x200, ref size, out _, 0);
        if (size is 0 or > 4 * 1024 * 1024) return values;
        nint buffer = Marshal.AllocHGlobal((int)size);
        try
        {
            if (PdhGetFormattedCounterArray(counter, 0x200, ref size, out uint count, buffer) != 0 || count > 16384 || count * (ulong)Marshal.SizeOf<CounterItem>() > size) return values;
            for (int i = 0; i < count; i++)
            {
                var item = Marshal.PtrToStructure<CounterItem>(buffer + i * Marshal.SizeOf<CounterItem>());
                if (item.Value.Status <= 1 && double.IsFinite(item.Value.Value) && item.Value.Value >= 0)
                    values.Add((Marshal.PtrToStringUni(item.Name) ?? "", item.Value.Value));
            }
        }
        finally { Marshal.FreeHGlobal(buffer); }
        return values;
    }
    public void Dispose() { nint old = Interlocked.Exchange(ref query, 0); if (old != 0) _ = PdhCloseQuery(old); }
    [StructLayout(LayoutKind.Sequential)] private struct CounterValue { public uint Status; public double Value; }
    [StructLayout(LayoutKind.Sequential)] private struct CounterItem { public nint Name; public CounterValue Value; }
    [DllImport("pdh.dll", EntryPoint = "PdhOpenQueryW", CharSet = CharSet.Unicode)] private static extern uint PdhOpenQuery(string? source, nuint user, out nint query);
    [DllImport("pdh.dll", EntryPoint = "PdhAddEnglishCounterW", CharSet = CharSet.Unicode)] private static extern uint PdhAddEnglishCounter(nint query, string path, nuint user, out nint counter);
    [DllImport("pdh.dll")] private static extern uint PdhCollectQueryData(nint query);
    [DllImport("pdh.dll", EntryPoint = "PdhGetFormattedCounterArrayW")] private static extern uint PdhGetFormattedCounterArray(nint counter, uint format, ref uint bytes, out uint count, nint buffer);
    [DllImport("pdh.dll")] private static extern uint PdhGetFormattedCounterValue(nint counter, uint format, out uint type, out CounterValue value);
    [DllImport("pdh.dll")] private static extern uint PdhCloseQuery(nint query);
}
