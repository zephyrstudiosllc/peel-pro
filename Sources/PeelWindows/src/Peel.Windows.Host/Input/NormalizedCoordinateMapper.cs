using Peel.Windows.Host.Windows;

namespace Peel.Windows.Host.Input;

public static class NormalizedCoordinateMapper
{
    public static bool TryMapToScreen(
        WindowBounds bounds,
        double normalizedX,
        double normalizedY,
        out ScreenPoint point)
    {
        point = default;

        if (!bounds.IsUsable ||
            !double.IsFinite(normalizedX) ||
            !double.IsFinite(normalizedY))
        {
            return false;
        }

        double clampedX = Math.Clamp(normalizedX, 0.0, 1.0);
        double clampedY = Math.Clamp(normalizedY, 0.0, 1.0);

        long x = (long)bounds.X + (long)Math.Round(
            clampedX * (bounds.Width - 1L),
            MidpointRounding.AwayFromZero);
        long y = (long)bounds.Y + (long)Math.Round(
            clampedY * (bounds.Height - 1L),
            MidpointRounding.AwayFromZero);

        if (x is < int.MinValue or > int.MaxValue ||
            y is < int.MinValue or > int.MaxValue)
        {
            return false;
        }

        point = new ScreenPoint((int)x, (int)y);
        return true;
    }
}
