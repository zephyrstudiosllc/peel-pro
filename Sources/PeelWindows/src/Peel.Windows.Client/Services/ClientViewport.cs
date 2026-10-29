using Peel.Windows.Client.Models;

namespace Peel.Windows.Client.Services;

public static class ClientViewport
{
    public static bool TryNormalize(double x, double y, double width, double height,
        int pixelWidth, int pixelHeight, bool clampCapturedDrag, out NormalizedPoint point)
    {
        point = default;
        if (!double.IsFinite(x) || !double.IsFinite(y) || !double.IsFinite(width) || !double.IsFinite(height)
            || width <= 0 || height <= 0 || pixelWidth <= 0 || pixelHeight <= 0) return false;
        double scale = Math.Min(width / pixelWidth, height / pixelHeight);
        double renderedWidth = pixelWidth * scale, renderedHeight = pixelHeight * scale;
        double nx = (x - (width - renderedWidth) / 2) / renderedWidth;
        double ny = (y - (height - renderedHeight) / 2) / renderedHeight;
        if (!clampCapturedDrag && (nx < 0 || nx > 1 || ny < 0 || ny > 1)) return false;
        return NormalizedPoint.TryCreate(nx, ny, out point);
    }
}
