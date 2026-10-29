namespace Peel.Windows.Host.Capture;

internal readonly record struct CaptureFrameLayout(
    int Width,
    int Height,
    int BytesPerRow,
    int PixelByteCount)
{
    internal const int BytesPerPixel = 4;
    internal const int MaximumD3D11TextureDimension = 16_384;

    internal static CaptureFrameLayout Create(
        int contentWidth,
        int contentHeight,
        uint surfaceWidth,
        uint surfaceHeight,
        uint mappedRowPitch)
    {
        ValidateDimension(contentWidth, nameof(contentWidth));
        ValidateDimension(contentHeight, nameof(contentHeight));

        if (surfaceWidth == 0 || surfaceWidth > MaximumD3D11TextureDimension ||
            surfaceHeight == 0 || surfaceHeight > MaximumD3D11TextureDimension)
        {
            throw new InvalidDataException("The capture surface dimensions are invalid.");
        }

        if ((uint)contentWidth > surfaceWidth || (uint)contentHeight > surfaceHeight)
        {
            throw new InvalidDataException("The captured content exceeds its Direct3D surface.");
        }

        int bytesPerRow;
        int pixelByteCount;
        try
        {
            bytesPerRow = checked(contentWidth * BytesPerPixel);
            pixelByteCount = checked(bytesPerRow * contentHeight);
        }
        catch (OverflowException exception)
        {
            throw new InvalidDataException("The captured frame byte count is too large.", exception);
        }

        if (mappedRowPitch < bytesPerRow || mappedRowPitch > int.MaxValue)
        {
            throw new InvalidDataException("The mapped Direct3D row pitch is invalid.");
        }

        if (pixelByteCount > Array.MaxLength)
        {
            throw new InvalidDataException("The captured frame exceeds the maximum managed buffer size.");
        }

        return new CaptureFrameLayout(
            contentWidth,
            contentHeight,
            bytesPerRow,
            pixelByteCount);
    }

    internal static void ValidateCaptureSize(int width, int height)
    {
        ValidateDimension(width, nameof(width));
        ValidateDimension(height, nameof(height));
    }

    private static void ValidateDimension(int value, string parameterName)
    {
        if (value <= 0 || value > MaximumD3D11TextureDimension)
        {
            throw new InvalidDataException(
                $"Capture dimension '{parameterName}' is outside the Direct3D 11 range.");
        }
    }
}
