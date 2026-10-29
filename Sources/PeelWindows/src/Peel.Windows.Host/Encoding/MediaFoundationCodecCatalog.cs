using System.Runtime.InteropServices;

namespace Peel.Windows.Host.Encoding;

public sealed record VideoTransformInfo(string Name, bool Hardware);

/// <summary>Uses installed Media Foundation transforms; no bundled codec or machine configuration changes.</summary>
public static unsafe class MediaFoundationCodecCatalog
{
    public static readonly Guid HevcSubtype = new("43564548-0000-0010-8000-00aa00389b71");
    private static readonly Guid VideoMajor = new("73646976-0000-0010-8000-00aa00389b71");
    private static readonly Guid H264Subtype = new("34363248-0000-0010-8000-00aa00389b71");
    private static readonly Guid EncoderCategory = new("f79eac7d-e545-4387-bdee-d647d7bde42a");
    private static readonly Guid DecoderCategory = new("d6c02d4b-6833-45b4-971a-05a4b04bab91");
    private static readonly Guid TransformInterface = new("bf94c121-5b05-4e6f-8000-ba598961414d");
    private static readonly Guid FriendlyName = new("314ffbae-5b41-4c95-9c19-4e7d586face3");

    public static IReadOnlyList<VideoTransformInfo> Inspect(VideoCodec codec, bool encoder)
    {
        int com = CoInitializeEx(0, 0);
        bool started = false;
        try
        {
            Marshal.ThrowExceptionForHR(MFStartup(0x00020070, 0)); started = true;
            var list = new List<VideoTransformInfo>();
            foreach (bool hardware in new[] { false, true })
                Enumerate(codec, encoder, hardware, activate => { list.Add(new(Name(activate), hardware)); return false; });
            return list;
        }
        finally { if (started) _ = MFShutdown(); if (com >= 0) CoUninitialize(); }
    }

    public static bool CanActivateSynchronous(VideoCodec codec, bool encoder)
    {
        int com = CoInitializeEx(0, 0);
        bool started = false;
        nint transform = 0;
        try
        {
            Marshal.ThrowExceptionForHR(MFStartup(0x00020070, 0)); started = true;
            transform = CreateSynchronous(codec, encoder);
            return transform != 0;
        }
        catch (Exception e) when (e is COMException or PlatformNotSupportedException) { return false; }
        finally { if (transform != 0) _ = Marshal.Release(transform); if (started) _ = MFShutdown(); if (com >= 0) CoUninitialize(); }
    }

    internal static nint CreateSynchronous(VideoCodec codec, bool encoder)
        => Create(codec, encoder, hardware: false);

    internal static nint CreateHardware(VideoCodec codec, bool encoder)
        => Create(codec, encoder, hardware: true);

    private static nint Create(VideoCodec codec, bool encoder, bool hardware)
    {
        nint result = 0;
        Enumerate(codec, encoder, hardware, activate =>
        {
            nint* table = *(nint**)activate;
            var method = (delegate* unmanaged[Stdcall]<nint, Guid*, nint*, int>)table[33];
            Guid iid = TransformInterface;
            nint transform = 0;
            int hr = method(activate, &iid, &transform);
            if (hr < 0 || transform == 0) return false;
            result = transform;
            return true;
        });
        return result != 0 ? result : throw new PlatformNotSupportedException($"No installed synchronous {codec} {(encoder ? "encoder" : "decoder")} is available.");
    }

    private static void Enumerate(VideoCodec codec, bool encoder, bool hardware, Func<nint, bool> action)
    {
        Guid category = encoder ? EncoderCategory : DecoderCategory;
        var type = new RegisterType { Major = VideoMajor, Subtype = codec == VideoCodec.Hevc ? HevcSubtype : H264Subtype };
        nint activates = 0; uint count = 0;
        try
        {
            Marshal.ThrowExceptionForHR(MFTEnumEx(category, hardware ? 0x44u : 0x51u,
                encoder ? null : &type, encoder ? &type : null, out activates, out count));
            if (count > 256) throw new InvalidDataException("Windows returned too many codec transforms.");
            for (int i = 0; i < count; i++) if (action(Marshal.ReadIntPtr(activates, i * IntPtr.Size))) break;
        }
        finally
        {
            if (activates != 0)
            {
                for (int i = 0; i < count; i++) { nint activate = Marshal.ReadIntPtr(activates, i * IntPtr.Size); if (activate != 0) _ = Marshal.Release(activate); }
                Marshal.FreeCoTaskMem(activates);
            }
        }
    }
    private static string Name(nint attributes)
    {
        Guid key = FriendlyName; nint value = 0; uint length = 0;
        var method = (delegate* unmanaged[Stdcall]<nint, Guid*, nint*, uint*, int>)(*(nint**)attributes)[13];
        try { return method(attributes, &key, &value, &length) >= 0 && value != 0 ? Marshal.PtrToStringUni(value, (int)Math.Min(length, 256)) ?? "Media Foundation codec" : "Media Foundation codec"; }
        finally { if (value != 0) Marshal.FreeCoTaskMem(value); }
    }
    [StructLayout(LayoutKind.Sequential)] private struct RegisterType { public Guid Major, Subtype; }
    [DllImport("mfplat.dll", ExactSpelling = true)] private static extern int MFTEnumEx(Guid category, uint flags, RegisterType* input, RegisterType* output, out nint activates, out uint count);
    [DllImport("mfplat.dll", ExactSpelling = true)] private static extern int MFStartup(int version, uint flags);
    [DllImport("mfplat.dll", ExactSpelling = true)] private static extern int MFShutdown();
    [DllImport("ole32.dll", ExactSpelling = true)] private static extern int CoInitializeEx(nint reserved, uint flags);
    [DllImport("ole32.dll", ExactSpelling = true)] private static extern void CoUninitialize();
}
