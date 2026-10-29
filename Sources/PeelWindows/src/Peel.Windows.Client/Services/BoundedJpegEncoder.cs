using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;

namespace Peel.Windows.Client.Services;

/// <summary>
/// One-shot inspection encoding. The JPEG is at most 120,000 bytes (the Mac adapter's bound), so its
/// base64 and JSON escaping fit one 256 KiB local agent line. The longest edge steps down from 1280 px
/// and quality steps down; if nothing fits, the capture fails closed instead of truncating.
/// </summary>
internal static class BoundedJpegEncoder
{
    internal const int MaximumBytes = 120_000;
    internal const int MaximumSourceEdge = 16384;
    private static readonly int[] EdgeSteps = [1280, 960, 640];
    private static readonly long[] QualitySteps = [80, 65, 50, 35];

    internal sealed record Result(byte[] Jpeg, int Width, int Height, int Quality);

    internal static (int Width, int Height) Fit(int width, int height, int maximumEdge)
    {
        if (width < 1 || height < 1 || maximumEdge < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(width), "Image dimensions must be positive.");
        }

        int longest = Math.Max(width, height);
        if (longest <= maximumEdge)
        {
            return (width, height);
        }

        double scale = (double)maximumEdge / longest;
        return (Math.Max(1, (int)Math.Round(width * scale, MidpointRounding.AwayFromZero)),
            Math.Max(1, (int)Math.Round(height * scale, MidpointRounding.AwayFromZero)));
    }

    internal static unsafe Result Encode(byte[] bgra, int width, int height, int stride, int maximumBytes = MaximumBytes)
    {
        ArgumentNullException.ThrowIfNull(bgra);
        if (width is < 1 or > MaximumSourceEdge || height is < 1 or > MaximumSourceEdge ||
            stride < checked(width * 4) || stride % 4 != 0 || maximumBytes < 1024 ||
            bgra.LongLength < (long)stride * (height - 1) + (long)width * 4)
        {
            throw new ArgumentException("The captured image layout is invalid.");
        }

        ImageCodecInfo codec = ImageCodecInfo.GetImageEncoders().FirstOrDefault(c => c.FormatID == ImageFormat.Jpeg.Guid)
            ?? throw new InvalidOperationException("The Windows JPEG encoder is unavailable.");
        int previousEdge = int.MaxValue;
        foreach (int edge in EdgeSteps)
        {
            (int scaledWidth, int scaledHeight) = Fit(width, height, edge);
            if (Math.Max(scaledWidth, scaledHeight) >= previousEdge) continue; // Already tried this size.
            previousEdge = Math.Max(scaledWidth, scaledHeight);
            using var scaled = new Bitmap(scaledWidth, scaledHeight, PixelFormat.Format24bppRgb);
            fixed (byte* pixels = bgra)
            {
                // Format32bppRgb ignores the alpha byte; captured windows can report zero alpha.
                using var source = new Bitmap(width, height, stride, PixelFormat.Format32bppRgb, (nint)pixels);
                using var graphics = Graphics.FromImage(scaled);
                graphics.InterpolationMode = InterpolationMode.HighQualityBilinear;
                graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
                graphics.CompositingMode = CompositingMode.SourceCopy;
                graphics.DrawImage(source, new Rectangle(0, 0, scaledWidth, scaledHeight));
            }

            foreach (long quality in QualitySteps)
            {
                using var output = new MemoryStream();
                using var parameters = new EncoderParameters(1);
                parameters.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, quality);
                scaled.Save(output, codec, parameters);
                if (output.Length <= maximumBytes)
                {
                    return new Result(output.ToArray(), scaledWidth, scaledHeight, (int)quality);
                }
            }
        }

        throw new LocalAgentException("capture_too_large",
            "The window image could not be encoded within the inspection size limit.");
    }
}
