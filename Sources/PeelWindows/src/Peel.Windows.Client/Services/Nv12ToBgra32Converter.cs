using System.IO;

namespace Peel.Windows.Client.Services;

internal static class Nv12ToBgra32Converter
{
    internal static byte[] Convert(ReadOnlySpan<byte> nv12, int width, int height, bool useSimd = true, bool bt709 = false, bool fullRange = false)
    {
        if (width <= 0 || height <= 0 || (width & 1) != 0 || (height & 1) != 0)
        {
            throw new InvalidDataException("NV12 output requires positive even frame dimensions.");
        }

        int yPlaneBytes;
        int requiredBytes;
        int outputBytes;
        try
        {
            yPlaneBytes = checked(width * height);
            requiredBytes = checked(yPlaneBytes + (yPlaneBytes / 2));
            outputBytes = checked(yPlaneBytes * 4);
        }
        catch (OverflowException exception)
        {
            throw new InvalidDataException("The decoded frame dimensions are oversized.", exception);
        }

        if (nv12.Length < requiredBytes)
        {
            throw new InvalidDataException("The decoded NV12 frame is truncated.");
        }

        var output = new byte[outputBytes];
        int convertedWidth = useSimd && !bt709 && !fullRange && Peel.Windows.Host.Encoding.PixelConversionSimd.IsSupported ? width & ~7 : 0;
        int yScale = fullRange ? 256 : 298;
        int blueScale = fullRange ? (bt709 ? 475 : 454) : (bt709 ? 541 : 516);
        int greenBlue = fullRange ? (bt709 ? 48 : 88) : (bt709 ? 55 : 100);
        int greenRed = fullRange ? (bt709 ? 120 : 183) : (bt709 ? 136 : 208);
        int redScale = fullRange ? (bt709 ? 403 : 359) : (bt709 ? 459 : 409);
        if (convertedWidth != 0) Peel.Windows.Host.Encoding.PixelConversionSimd.Nv12ToBgra(nv12, output, width, height);
        for (var y = 0; y < height; y++)
        {
            int yRow = y * width;
            int uvRow = yPlaneBytes + ((y / 2) * width);
            int outputRow = y * width * 4;
            for (var x = convertedWidth; x < width; x++)
            {
                int luminance = Math.Max(0, nv12[yRow + x] - (fullRange ? 0 : 16));
                int chromaOffset = uvRow + (x & ~1);
                int blueDifference = nv12[chromaOffset] - 128;
                int redDifference = nv12[chromaOffset + 1] - 128;
                int destination = outputRow + (x * 4);

                output[destination] = ClampToByte(
                    (yScale * luminance + blueScale * blueDifference + 128) >> 8);
                output[destination + 1] = ClampToByte(
                    (yScale * luminance - greenBlue * blueDifference - greenRed * redDifference + 128) >> 8);
                output[destination + 2] = ClampToByte(
                    (yScale * luminance + redScale * redDifference + 128) >> 8);
                output[destination + 3] = 255;
            }
        }

        return output;
    }

    private static byte ClampToByte(int value) => (byte)Math.Clamp(value, 0, 255);
}
