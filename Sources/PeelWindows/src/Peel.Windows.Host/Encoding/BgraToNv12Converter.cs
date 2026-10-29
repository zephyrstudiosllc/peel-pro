using Peel.Windows.Host.Capture;

namespace Peel.Windows.Host.Encoding;

internal static class BgraToNv12Converter
{
    internal static ReadOnlyMemory<byte> EncoderInput(CapturedFrame frame)
    {
        if (frame.PixelFormat != CapturePixelFormat.Nv12) return Convert(frame);
        CaptureFrameLayout.ValidateCaptureSize(frame.Width, frame.Height);
        if ((frame.Width & 1) != 0 || (frame.Height & 1) != 0 || frame.BytesPerRow != frame.Width ||
            frame.Pixels.Length != checked(frame.Width * frame.Height * 3 / 2))
            throw new InvalidDataException("NV12 capture requires exact packed, even-sized planes.");
        return frame.Pixels;
    }
    internal static byte[] Convert(CapturedFrame frame, bool useSimd = true)
    {
        ArgumentNullException.ThrowIfNull(frame);
        if (frame.PixelFormat != CapturePixelFormat.Bgra8)
        {
            throw new InvalidDataException("Media Foundation H.264 input requires BGRA8 capture frames.");
        }

        if (frame.Width <= 0 || frame.Height <= 0 ||
            (frame.Width & 1) != 0 || (frame.Height & 1) != 0)
        {
            throw new InvalidDataException("NV12 conversion requires positive even frame dimensions.");
        }

        int packedBytesPerRow;
        int yPlaneBytes;
        int outputBytes;
        int requiredInputBytes;
        try
        {
            packedBytesPerRow = checked(frame.Width * CaptureFrameLayout.BytesPerPixel);
            yPlaneBytes = checked(frame.Width * frame.Height);
            outputBytes = checked(yPlaneBytes + (yPlaneBytes / 2));
            requiredInputBytes = checked(((frame.Height - 1) * frame.BytesPerRow) + packedBytesPerRow);
        }
        catch (OverflowException exception)
        {
            throw new InvalidDataException("The captured frame is too large for NV12 conversion.", exception);
        }

        if (frame.BytesPerRow < packedBytesPerRow || frame.Pixels.Length < requiredInputBytes)
        {
            throw new InvalidDataException("The captured BGRA8 frame buffer is truncated.");
        }

        var output = new byte[outputBytes];
        ReadOnlySpan<byte> source = frame.Pixels.Span;
        Span<byte> yPlane = output.AsSpan(0, yPlaneBytes);
        Span<byte> uvPlane = output.AsSpan(yPlaneBytes);
        int convertedWidth = useSimd && PixelConversionSimd.IsSupported ? frame.Width & ~7 : 0;
        if (convertedWidth != 0) PixelConversionSimd.BgraToNv12(source, output, frame.Width, frame.Height, frame.BytesPerRow);

        for (var y = 0; y < frame.Height; y += 2)
        {
            int firstRow = y * frame.BytesPerRow;
            int secondRow = firstRow + frame.BytesPerRow;
            int firstY = y * frame.Width;
            int secondY = firstY + frame.Width;
            int uvRow = (y / 2) * frame.Width;

            for (var x = convertedWidth; x < frame.Width; x += 2)
            {
                int firstPixel = firstRow + (x * CaptureFrameLayout.BytesPerPixel);
                int secondPixel = firstPixel + CaptureFrameLayout.BytesPerPixel;
                int thirdPixel = secondRow + (x * CaptureFrameLayout.BytesPerPixel);
                int fourthPixel = thirdPixel + CaptureFrameLayout.BytesPerPixel;

                WriteLuma(source, firstPixel, yPlane, firstY + x);
                WriteLuma(source, secondPixel, yPlane, firstY + x + 1);
                WriteLuma(source, thirdPixel, yPlane, secondY + x);
                WriteLuma(source, fourthPixel, yPlane, secondY + x + 1);

                int blue = source[firstPixel] + source[secondPixel] +
                    source[thirdPixel] + source[fourthPixel];
                int green = source[firstPixel + 1] + source[secondPixel + 1] +
                    source[thirdPixel + 1] + source[fourthPixel + 1];
                int red = source[firstPixel + 2] + source[secondPixel + 2] +
                    source[thirdPixel + 2] + source[fourthPixel + 2];

                uvPlane[uvRow + x] = ClampToByte(
                    ((-38 * red - 74 * green + 112 * blue + 512) >> 10) + 128);
                uvPlane[uvRow + x + 1] = ClampToByte(
                    ((112 * red - 94 * green - 18 * blue + 512) >> 10) + 128);
            }
        }

        return output;
    }

    private static void WriteLuma(
        ReadOnlySpan<byte> source,
        int sourceOffset,
        Span<byte> destination,
        int destinationOffset)
    {
        int blue = source[sourceOffset];
        int green = source[sourceOffset + 1];
        int red = source[sourceOffset + 2];
        destination[destinationOffset] = ClampToByte(
            ((66 * red + 129 * green + 25 * blue + 128) >> 8) + 16);
    }

    private static byte ClampToByte(int value) => (byte)Math.Clamp(value, 0, 255);
}
