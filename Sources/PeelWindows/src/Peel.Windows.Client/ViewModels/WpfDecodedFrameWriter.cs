using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Peel.Windows.Client.Services;

namespace Peel.Windows.Client.ViewModels;

internal static class WpfDecodedFrameWriter
{
    // Match the decoder's dimension limits while retaining the 64 MiB frame budget.
    private const int MaximumWidth = 8192;
    private const int MaximumHeight = 8192;
    private const int MaximumPixelBytes = 64 * 1024 * 1024;

    internal static WriteableBitmap Write(
        WriteableBitmap? current,
        DecodedVideoFrame frame)
    {
        ArgumentNullException.ThrowIfNull(frame);
        Validate(frame);

        WriteableBitmap bitmap = current is not null &&
            current.PixelWidth == frame.PixelWidth &&
            current.PixelHeight == frame.PixelHeight &&
            current.Format == PixelFormats.Bgra32
                ? current
                : new WriteableBitmap(
                    frame.PixelWidth,
                    frame.PixelHeight,
                    96,
                    96,
                    PixelFormats.Bgra32,
                    null);

        ArraySegment<byte> pixels;
        if (!MemoryMarshal.TryGetArray(frame.Bgra32Pixels, out pixels) || pixels.Array is null)
        {
            byte[] copy = frame.Bgra32Pixels.ToArray();
            pixels = new ArraySegment<byte>(copy);
        }

        bitmap.WritePixels(
            new Int32Rect(0, 0, frame.PixelWidth, frame.PixelHeight),
            pixels.Array,
            frame.Stride,
            pixels.Offset);
        return bitmap;
    }

    private static void Validate(DecodedVideoFrame frame)
    {
        if (frame.PixelWidth is <= 0 or > MaximumWidth ||
            frame.PixelHeight is <= 0 or > MaximumHeight ||
            frame.Stride <= 0)
        {
            throw new InvalidDataException("The decoded frame dimensions are invalid.");
        }

        int minimumStride;
        int requiredBytes;
        try
        {
            minimumStride = checked(frame.PixelWidth * 4);
            requiredBytes = checked(frame.Stride * frame.PixelHeight);
        }
        catch (OverflowException exception)
        {
            throw new InvalidDataException("The decoded frame dimensions are oversized.", exception);
        }

        if (frame.Stride < minimumStride ||
            requiredBytes > MaximumPixelBytes ||
            frame.Bgra32Pixels.Length < requiredBytes)
        {
            throw new InvalidDataException("The decoded BGRA32 frame buffer is invalid.");
        }
    }
}
