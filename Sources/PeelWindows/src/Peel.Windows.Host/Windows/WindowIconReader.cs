using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using Peel.Windows.Host.Interop;

namespace Peel.Windows.Host.Windows;

internal static class WindowIconReader
{
    private const int OutputSize = 64;
    private const uint IconMessageTimeoutMilliseconds = 50;

    internal static string? TryReadPngBase64(nint window, uint processId)
    {
        try
        {
            nint iconHandle = TryReadWindowIconHandle(window);
            if (iconHandle != nint.Zero)
            {
                using Icon sharedIcon = Icon.FromHandle(iconHandle);
                return EncodePng(sharedIcon);
            }

            using Process process = Process.GetProcessById(checked((int)processId));
            string? executablePath = process.MainModule?.FileName;
            if (string.IsNullOrWhiteSpace(executablePath))
            {
                return null;
            }

            using Icon? executableIcon = Icon.ExtractAssociatedIcon(executablePath);
            return executableIcon is null ? null : EncodePng(executableIcon);
        }
        catch (ArgumentException)
        {
            return null;
        }
        catch (InvalidOperationException)
        {
            return null;
        }
        catch (SystemException)
        {
            return null;
        }
    }

    private static nint TryReadWindowIconHandle(nint window)
    {
        foreach (nuint iconKind in new[]
                 {
                     NativeMethods.IconSmall2,
                     NativeMethods.IconSmall,
                     NativeMethods.IconBig,
                 })
        {
            if (NativeMethods.SendMessageTimeout(
                    window,
                    NativeMethods.WmGetIcon,
                    iconKind,
                    nint.Zero,
                    NativeMethods.SmtoBlock | NativeMethods.SmtoAbortIfHung,
                    IconMessageTimeoutMilliseconds,
                    out nuint result) != nint.Zero &&
                result != 0)
            {
                return unchecked((nint)result);
            }
        }

        nint classIcon = NativeMethods.GetClassLongPtr(window, NativeMethods.GclpHiconSmall);
        return classIcon != nint.Zero
            ? classIcon
            : NativeMethods.GetClassLongPtr(window, NativeMethods.GclpHicon);
    }

    private static string EncodePng(Icon icon)
    {
        using Bitmap source = icon.ToBitmap();
        using var output = new Bitmap(OutputSize, OutputSize, PixelFormat.Format32bppArgb);
        using (Graphics graphics = Graphics.FromImage(output))
        {
            graphics.Clear(Color.Transparent);
            graphics.CompositingMode = CompositingMode.SourceCopy;
            graphics.CompositingQuality = CompositingQuality.HighQuality;
            graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
            graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
            graphics.SmoothingMode = SmoothingMode.HighQuality;
            graphics.DrawImage(source, 0, 0, OutputSize, OutputSize);
        }

        using var stream = new MemoryStream();
        output.Save(stream, ImageFormat.Png);
        return Convert.ToBase64String(stream.GetBuffer(), 0, checked((int)stream.Length));
    }
}
