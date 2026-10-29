using System.Runtime.InteropServices;

namespace Peel.Windows.Host.Audio;

/// <summary>
/// Actual state of this computer's current default render endpoint. <see cref="DeviceId"/> is an
/// opaque Windows endpoint identity used only to fence writes; it is never sent on the wire.
/// A null device means no default output; null values mean Windows could not read them.
/// </summary>
internal sealed record SourceVolumeReading(string? DeviceId, double? Volume, bool? Muted, bool CanSetVolume, bool CanSetMute);

internal enum SourceVolumeApplyStatus
{
    /// <summary>Windows accepted every requested write; the reading was re-read afterwards.</summary>
    Applied,
    /// <summary>The default output differs from the admitted endpoint, before or after writing.</summary>
    DeviceChanged,
    NoOutputDevice,
    /// <summary>A requested control cannot be read on this endpoint; nothing was written.</summary>
    NotSettable,
    /// <summary>Windows refused a write; the endpoint may be partially changed.</summary>
    Failed,
}

internal readonly record struct SourceVolumeApplyResult(SourceVolumeApplyStatus Status, SourceVolumeReading? Reading = null);

/// <summary>The source computer's system output volume/mute (the systemOutput scope).</summary>
internal interface ISourceSystemVolume
{
    /// <summary>The current default output endpoint, read fresh; null when none is available.</summary>
    string? CurrentDevice();

    /// <summary>Actual state of the current default output, read fresh.</summary>
    SourceVolumeReading Read();

    /// <summary>Writes only to <paramref name="expectedDevice"/> while it is still the default output.</summary>
    SourceVolumeApplyResult Apply(double? volume, bool? muted, string expectedDevice);
}

/// <summary>
/// Public Windows Core Audio: IMMDeviceEnumerator default render endpoint (eConsole, the endpoint
/// the taskbar volume controls and shared-mode apps use by default) and its IAudioEndpointVolume.
/// No endpoint routing, policy, microphone or key-based approximation. Calls require an MTA thread,
/// which the Host's control session threads are.
/// </summary>
internal sealed class WindowsSystemOutputVolume : ISourceSystemVolume
{
    private const int RenderFlow = 0;
    private const int ConsoleRole = 0;
    private const uint ClsctxAll = 23;
    private static readonly Guid EnumeratorClass = new("BCDE0395-E52F-467C-8E3D-C4579291692E");
    private static readonly Guid EndpointVolumeId = new("5CDF2C82-841E-4546-9722-0CF74078229A");

    public string? CurrentDevice()
    {
        if (!CanCall()) return null;
        object? enumerator = null; IDevice? device = null;
        try
        {
            if (!TryDefault(out enumerator, out device)) return null;
            return device!.GetId(out string? id) >= 0 && !string.IsNullOrEmpty(id) ? id : null;
        }
        catch (Exception error) when (IsComFailure(error)) { return null; }
        finally { Release(device); Release(enumerator); }
    }

    public SourceVolumeReading Read()
    {
        if (!CanCall()) return new(null, null, null, false, false);
        object? enumerator = null; IDevice? device = null; IEndpointVolume? volume = null;
        try
        {
            if (!TryDefault(out enumerator, out device) || device!.GetId(out string? id) < 0 || string.IsNullOrEmpty(id))
                return new(null, null, null, false, false);
            volume = Activate(device);
            return volume is null ? new(id, null, null, false, false) : ReadVolume(id, volume);
        }
        catch (Exception error) when (IsComFailure(error)) { return new(null, null, null, false, false); }
        finally { Release(volume); Release(device); Release(enumerator); }
    }

    public SourceVolumeApplyResult Apply(double? level, bool? muted, string expectedDevice)
    {
        if (level is null && muted is null || level is { } requested && !(double.IsFinite(requested) && requested is >= 0 and <= 1))
            return new(SourceVolumeApplyStatus.NotSettable);
        if (!CanCall()) return new(SourceVolumeApplyStatus.Failed);
        object? enumerator = null; IDevice? device = null; IEndpointVolume? volume = null;
        try
        {
            if (!TryDefault(out enumerator, out device) || device!.GetId(out string? id) < 0 || string.IsNullOrEmpty(id))
                return new(SourceVolumeApplyStatus.NoOutputDevice);
            // Never act on a newly selected output: the endpoint must still be the one admitted.
            if (!StringComparer.Ordinal.Equals(id, expectedDevice)) return new(SourceVolumeApplyStatus.DeviceChanged);
            volume = Activate(device);
            if (volume is null) return new(SourceVolumeApplyStatus.NotSettable);
            SourceVolumeReading before = ReadVolume(id, volume);
            if (level is not null && before.Volume is null || muted is not null && before.Muted is null)
                return new(SourceVolumeApplyStatus.NotSettable);
            // A null event context: Windows notifies every listener, including its own volume UI.
            if (level is { } scalar && volume.SetMasterVolumeLevelScalar((float)scalar, 0) < 0)
                return new(SourceVolumeApplyStatus.Failed);
            if (muted is { } mute && volume.SetMute(mute ? 1 : 0, 0) < 0)
                return new(SourceVolumeApplyStatus.Failed);
            // Re-check identity after the effect, then report the actual re-read state.
            if (!StringComparer.Ordinal.Equals(CurrentDevice(), expectedDevice)) return new(SourceVolumeApplyStatus.DeviceChanged);
            return new(SourceVolumeApplyStatus.Applied, ReadVolume(id, volume));
        }
        catch (Exception error) when (IsComFailure(error)) { return new(SourceVolumeApplyStatus.Failed); }
        finally { Release(volume); Release(device); Release(enumerator); }
    }

    private static SourceVolumeReading ReadVolume(string id, IEndpointVolume volume)
    {
        double? level = volume.GetMasterVolumeLevelScalar(out float scalar) >= 0 && float.IsFinite(scalar) && scalar is >= 0 and <= 1
            ? Math.Round(scalar, 4) : null;
        bool? muted = volume.GetMute(out int mute) >= 0 ? mute != 0 : null;
        // Windows provides software endpoint volume when hardware has none; a readable control is
        // writable through the same interface, and any refused write is reported as failed.
        return new(id, level, muted, level is not null, muted is not null);
    }

    private static bool CanCall() =>
        OperatingSystem.IsWindows() && Thread.CurrentThread.GetApartmentState() == ApartmentState.MTA;

    private static bool TryDefault(out object? enumerator, out IDevice? device)
    {
        device = null;
        Type type = Type.GetTypeFromCLSID(EnumeratorClass, throwOnError: true)!;
        enumerator = Activator.CreateInstance(type);
        if (enumerator is not IDeviceEnumerator devices) return false;
        // E_NOTFOUND when there is no default output: reported as no device, never guessed.
        if (devices.GetDefaultAudioEndpoint(RenderFlow, ConsoleRole, out IDevice? found) < 0 || found is null) return false;
        device = found;
        return true;
    }

    private static IEndpointVolume? Activate(IDevice device) =>
        device.Activate(in EndpointVolumeId, ClsctxAll, 0, out object value) >= 0 ? value as IEndpointVolume : null;

    private static bool IsComFailure(Exception error) =>
        error is COMException or InvalidCastException or InvalidComObjectException or TypeLoadException or
            PlatformNotSupportedException or UnauthorizedAccessException;

    private static void Release(object? value)
    {
        if (value is not null && Marshal.IsComObject(value)) _ = Marshal.ReleaseComObject(value);
    }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(int flow, uint states, out nint collection);
        [PreserveSig] int GetDefaultAudioEndpoint(int flow, int role, out IDevice? device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IDevice
    {
        [PreserveSig] int Activate(in Guid iid, uint context, nint parameters, [MarshalAs(UnmanagedType.IUnknown)] out object value);
        [PreserveSig] int OpenPropertyStore(uint access, out nint store);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string? id);
    }

    [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IEndpointVolume
    {
        [PreserveSig] int RegisterControlChangeNotify(nint notify);
        [PreserveSig] int UnregisterControlChangeNotify(nint notify);
        [PreserveSig] int GetChannelCount(out uint count);
        [PreserveSig] int SetMasterVolumeLevel(float level, nint context);
        [PreserveSig] int SetMasterVolumeLevelScalar(float level, nint context);
        [PreserveSig] int GetMasterVolumeLevel(out float level);
        [PreserveSig] int GetMasterVolumeLevelScalar(out float level);
        [PreserveSig] int SetChannelVolumeLevel(uint channel, float level, nint context);
        [PreserveSig] int SetChannelVolumeLevelScalar(uint channel, float level, nint context);
        [PreserveSig] int GetChannelVolumeLevel(uint channel, out float level);
        [PreserveSig] int GetChannelVolumeLevelScalar(uint channel, out float level);
        [PreserveSig] int SetMute(int muted, nint context);
        [PreserveSig] int GetMute(out int muted);
    }
}
