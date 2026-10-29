using System.Runtime.Intrinsics;
using System.Runtime.Intrinsics.X86;

namespace Peel.Windows.Host.Encoding;

/// <summary>Eight-pixel BT.601 limited-range conversion, bit-identical to the scalar paths.
/// Callers validate complete planes before entering; every native load stays within one row.</summary>
internal static unsafe class PixelConversionSimd
{
    internal static bool IsSupported => Avx2.IsSupported && Ssse3.IsSupported && Sse41.IsSupported;

    internal static void BgraToNv12(ReadOnlySpan<byte> source, Span<byte> output, int width, int height, int stride)
    {
        int vectorWidth = width & ~7, yBytes = width * height;
        var mask = Vector256.Create(255);
        var pairs = Vector256.Create(0, 1, 4, 5, 0, 1, 4, 5);
        fixed (byte* src = source)
        fixed (byte* dst = output)
        {
            for (int y = 0; y < height; y += 2)
            {
                for (int x = 0; x < vectorWidth; x += 8)
                {
                    var top = Avx.LoadVector256((int*)(src + y * stride + x * 4));
                    var bottom = Avx.LoadVector256((int*)(src + (y + 1) * stride + x * 4));
                    var bt = top & mask; var bb = bottom & mask;
                    var gt = Avx2.ShiftRightLogical(top, 8) & mask; var gb = Avx2.ShiftRightLogical(bottom, 8) & mask;
                    var rt = Avx2.ShiftRightLogical(top, 16) & mask; var rb = Avx2.ShiftRightLogical(bottom, 16) & mask;
                    var yt = ((rt * Vector256.Create(66) + gt * Vector256.Create(129) + bt * Vector256.Create(25) + Vector256.Create(128)) >> 8) + Vector256.Create(16);
                    var yb = ((rb * Vector256.Create(66) + gb * Vector256.Create(129) + bb * Vector256.Create(25) + Vector256.Create(128)) >> 8) + Vector256.Create(16);
                    StoreLuma(dst + y * width + x, yt); StoreLuma(dst + (y + 1) * width + x, yb);
                    var r = Avx2.PermuteVar8x32(Avx2.HorizontalAdd(rt + rb, Vector256<int>.Zero), pairs);
                    var g = Avx2.PermuteVar8x32(Avx2.HorizontalAdd(gt + gb, Vector256<int>.Zero), pairs);
                    var b = Avx2.PermuteVar8x32(Avx2.HorizontalAdd(bt + bb, Vector256<int>.Zero), pairs);
                    var u = ((r * Vector256.Create(-38) + g * Vector256.Create(-74) + b * Vector256.Create(112) + Vector256.Create(512)) >> 10) + Vector256.Create(128);
                    var v = ((r * Vector256.Create(112) + g * Vector256.Create(-94) + b * Vector256.Create(-18) + Vector256.Create(512)) >> 10) + Vector256.Create(128);
                    var uv = (u | (v << 8)).GetLower();
                    Sse2.StoreScalar((ulong*)(dst + yBytes + (y / 2) * width + x), Sse41.PackUnsignedSaturate(uv, Vector128<int>.Zero).AsUInt64());
                }
            }
        }
    }

    private static void StoreLuma(byte* destination, Vector256<int> values)
    {
        var words = Sse2.PackSignedSaturate(values.GetLower(), values.GetUpper());
        Sse2.StoreScalar((ulong*)destination, Sse2.PackUnsignedSaturate(words, Vector128<short>.Zero).AsUInt64());
    }

    internal static void Nv12ToBgra(ReadOnlySpan<byte> source, Span<byte> output, int width, int height)
    {
        int vectorWidth = width & ~7, yBytes = width * height;
        var uShuffle = Vector128.Create((byte)0, 0, 2, 2, 4, 4, 6, 6, 0, 0, 0, 0, 0, 0, 0, 0);
        var vShuffle = Vector128.Create((byte)1, 1, 3, 3, 5, 5, 7, 7, 0, 0, 0, 0, 0, 0, 0, 0);
        fixed (byte* src = source)
        fixed (byte* dst = output)
        {
            for (int y = 0; y < height; y++)
            {
                for (int x = 0; x < vectorWidth; x += 8)
                {
                    var luma = Avx2.Max(Avx2.ConvertToVector256Int32(src + y * width + x) - Vector256.Create(16), Vector256<int>.Zero) * Vector256.Create(298);
                    var chroma = Sse2.LoadScalarVector128((ulong*)(src + yBytes + (y / 2) * width + x)).AsByte();
                    var u = Avx2.ConvertToVector256Int32(Ssse3.Shuffle(chroma, uShuffle)) - Vector256.Create(128);
                    var v = Avx2.ConvertToVector256Int32(Ssse3.Shuffle(chroma, vShuffle)) - Vector256.Create(128);
                    var b = Clamp((luma + u * Vector256.Create(516) + Vector256.Create(128)) >> 8);
                    var g = Clamp((luma - u * Vector256.Create(100) - v * Vector256.Create(208) + Vector256.Create(128)) >> 8);
                    var r = Clamp((luma + v * Vector256.Create(409) + Vector256.Create(128)) >> 8);
                    Avx.Store((int*)(dst + (y * width + x) * 4), b | (g << 8) | (r << 16) | Vector256.Create(unchecked((int)0xff000000)));
                }
            }
        }
    }
    private static Vector256<int> Clamp(Vector256<int> value) => Avx2.Min(Avx2.Max(value, Vector256<int>.Zero), Vector256.Create(255));
}
