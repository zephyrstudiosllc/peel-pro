using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
using Peel.Windows.Protocol;

namespace Peel.Windows.Client.Utilities;

public sealed record SidePulseDevice(string Volume, uint Serial, ulong FileId, string Mount, string Kind)
{
    public string Label => $"SidePulse {(Kind == "dot" ? "Dot" : "Pro")} · {Mount}";
    internal static string? Detect(string label)
    {
        string normalized = new(label.ToLowerInvariant().Where(char.IsLetter).ToArray());
        return !normalized.Contains("pulse", StringComparison.Ordinal) ? null : normalized.Contains("dot", StringComparison.Ordinal) ? "dot" : "pro";
    }
    internal void Validate()
    {
        if (Volume is null || Volume.Length != 49 || !Volume.StartsWith(@"\\?\Volume{", StringComparison.OrdinalIgnoreCase) || !Volume.EndsWith(@"}\", StringComparison.Ordinal) ||
            !Guid.TryParseExact(Volume[11..^2], "D", out _) || Kind is not ("pro" or "dot")) throw new InvalidDataException("Invalid SidePulse volume identity.");
    }
    public static IReadOnlyList<SidePulseDevice> Discover()
    {
        var found = new List<SidePulseDevice>();
        foreach (var drive in DriveInfo.GetDrives().Take(26))
        {
            try
            {
                if (drive.DriveType != DriveType.Removable || !drive.IsReady || Detect(drive.VolumeLabel) is not { } kind) continue;
                var volume = new StringBuilder(64);
                if (!Native.GetVolumeNameForVolumeMountPointW(drive.RootDirectory.FullName, volume, volume.Capacity)) continue;
                string path = volume.ToString();
                var candidate = new SidePulseDevice(path, 0, 0, drive.RootDirectory.FullName, kind); candidate.Validate();
                using var handle = Native.Open(path + "LEDS.LED", write: false);
                var info = Native.Info(handle);
                found.Add(candidate with { Serial = info.Serial, FileId = info.FileId });
            }
            catch (Exception e) when (e is IOException or InvalidDataException or UnauthorizedAccessException or Win32Exception) { }
        }
        return found.OrderBy(d => d.Mount, StringComparer.OrdinalIgnoreCase).ToArray();
    }
    internal static ISidePulseWriter Open(SidePulseDevice device)
    {
        device.Validate();
        // The volume GUID and opened handle, never a reusable drive letter, own all writes.
        var handle = Native.Open(device.Volume + "LEDS.LED", write: true);
        try
        {
            var info = Native.Info(handle);
            if (info.Serial != device.Serial || info.FileId != device.FileId) throw new InvalidDataException("The selected SidePulse device changed. Scan and select it again.");
            return new FileWriter(new FileStream(handle, FileAccess.Write, 1, isAsync: true));
        }
        catch { handle.Dispose(); throw; }
    }
    internal sealed class FileWriter(FileStream file) : ISidePulseWriter
    {
        public async Task WriteAsync(string program, CancellationToken token)
        {
            TrustedSignals.ValidateProgram(program); token.ThrowIfCancellationRequested();
            byte[] data = Encoding.UTF8.GetBytes(program);
            file.Position = 0; await file.WriteAsync(data, token).ConfigureAwait(false);
            token.ThrowIfCancellationRequested(); file.SetLength(data.Length);
            // Firmware observes USB sectors, so complete the device write before publishing success.
            file.Flush(flushToDisk: true);
        }
        public ValueTask DisposeAsync() => file.DisposeAsync();
    }
    private static class Native
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct FileInfo
        {
            internal uint Attributes;
            internal System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
            internal uint Serial, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }
        internal static SafeFileHandle Open(string path, bool write)
        {
            var handle = CreateFileW(path, write ? 0x40000000u : 0u, 1, 0, 3, 0x00200000u | (write ? 0xC0000000u : 0u), 0);
            if (!handle.IsInvalid) return handle;
            int error = Marshal.GetLastPInvokeError(); handle.Dispose(); throw new Win32Exception(error, "Could not open the SidePulse program file.");
        }
        internal static (uint Serial, ulong FileId) Info(SafeFileHandle handle)
        {
            if (!GetFileInformationByHandle(handle, out var info)) throw new Win32Exception(Marshal.GetLastPInvokeError());
            if ((info.Attributes & (0x400u | 0x10u)) != 0 || info.SizeHigh != 0 || info.SizeLow > 65536 || info.Links > 1)
                throw new InvalidDataException("SidePulse requires a small, ordinary LEDS.LED file.");
            return (info.Serial, ((ulong)info.IndexHigh << 32) | info.IndexLow);
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern bool GetVolumeNameForVolumeMountPointW(string mount, StringBuilder volume, int length);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafeFileHandle CreateFileW(string path, uint access, uint sharing, nint security, uint creation, uint attributes, nint template);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInfo info);
    }
}

internal interface ISidePulseWriter : IAsyncDisposable { Task WriteAsync(string program, CancellationToken token); }

internal static class SignalCalibration
{
    internal static string Apply(string program, string kind, double brightness)
    {
        TrustedSignals.ValidateProgram(program);
        if (!double.IsFinite(brightness) || brightness is < 0 or > 1 || kind is not ("pro" or "dot")) throw new InvalidDataException("Invalid light calibration.");
        if (program == "off") return program;
        double scale = brightness * (kind == "dot" ? .4 : 1);
        var lines = program.Replace("\r\n", "\n").Split(['\n', '\r', '\v', '\f', '\u0085', '\u2028', '\u2029']).ToList();
        if (scale != 1)
        {
            int index = lines.FindIndex(l => l.StartsWith("brightness ", StringComparison.Ordinal));
            int source = index < 0 ? 255 : int.Parse(lines[index].AsSpan(11), CultureInfo.InvariantCulture);
            string value = "brightness " + (int)Math.Round(source * scale, MidpointRounding.AwayFromZero);
            if (index < 0) lines.Insert(0, value); else lines[index] = value;
        }
        string calibrated = string.Join('\n', lines);
        if (kind == "dot")
        {
            var result = new StringBuilder(calibrated);
            for (int i = 0; i < result.Length; i++)
            {
                if (result[i] != '#') continue;
                uint rgb = uint.Parse(calibrated.AsSpan(i + 1, 6), NumberStyles.HexNumber, CultureInfo.InvariantCulture);
                uint blue = (uint)Math.Round((rgb & 255) * .75, MidpointRounding.AwayFromZero);
                string color = ((rgb & 0xFFFF00) | blue).ToString("X6", CultureInfo.InvariantCulture);
                for (int k = 0; k < 6; k++) result[i + 1 + k] = color[k];
                i += 6;
            }
            calibrated = result.ToString();
        }
        TrustedSignals.ValidateProgram(calibrated); return calibrated;
    }
}
