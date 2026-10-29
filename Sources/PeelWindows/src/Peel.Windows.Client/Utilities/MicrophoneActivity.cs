using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Peel.Windows.Client.Utilities;

internal sealed record InputDeviceActivity(string Name, bool Active, bool? Muted, bool HardwareMute);
internal sealed record MicrophoneActivitySnapshot(string State, string Devices, string Detail, long SampledAt)
{
    internal static MicrophoneActivitySnapshot Unavailable(string detail) => new("unavailable", "", detail, Stopwatch.GetTimestamp());
    internal bool Fresh => Stopwatch.GetElapsedTime(SampledAt) <= TimeSpan.FromSeconds(3.5);
}

/// <summary>Read-only Core Audio session and endpoint queries. Never opens a capture stream or changes mute.</summary>
internal static class MicrophoneActivity
{
    internal static MicrophoneActivitySnapshot Reduce(IReadOnlyList<InputDeviceActivity> devices, bool complete, long sampledAt)
    {
        var active = devices.Where(d => d.Active).ToArray();
        string names = string.Join(", ", (active.Length > 0 ? active : devices).Take(4).Select(d => d.Name));
        if (active.Any(d => d.Muted != true)) return new("active", names, "Windows capture session active" + (active.Any(d => d.Muted is null) ? " · endpoint mute unavailable" : " · endpoint unmuted"), sampledAt);
        if (!complete) return new("unavailable", names, "Some input-session observations are unavailable.", sampledAt);
        if (active.Length > 0) return new("muted", names, active.All(d => d.HardwareMute) ? "Active input endpoints report hardware mute." : "Active input endpoints report Windows mute; physical switches may be separate.", sampledAt);
        return new(devices.Count > 0 ? "idle" : "unavailable", names, devices.Count > 0 ? "No active Windows capture sessions observed." : "No active Windows input endpoint is available.", sampledAt);
    }
    internal static MicrophoneActivitySnapshot Read()
    {
        if (Thread.CurrentThread.GetApartmentState() != ApartmentState.MTA) return MicrophoneActivitySnapshot.Unavailable("Input observation requires a background COM thread.");
        long sampledAt = Stopwatch.GetTimestamp();
        object? enumeratorObject = null; IDeviceCollection? collection = null;
        var devices = new List<InputDeviceActivity>(); bool complete = true;
        try
        {
            var type = Type.GetTypeFromCLSID(new("BCDE0395-E52F-467C-8E3D-C4579291692E"), throwOnError: true)!;
            enumeratorObject = Activator.CreateInstance(type)!;
            var enumerator = (IDeviceEnumerator)enumeratorObject;
            Marshal.ThrowExceptionForHR(enumerator.EnumAudioEndpoints(1, 1, out collection)); // Capture only; active endpoints only.
            Marshal.ThrowExceptionForHR(collection.GetCount(out uint count)); complete &= count <= 32;
            for (uint i = 0; i < Math.Min(count, 32); i++)
            {
                if (Stopwatch.GetElapsedTime(sampledAt) > TimeSpan.FromMilliseconds(500)) { complete = false; break; }
                IDevice? device = null; object? managerObject = null, volumeObject = null; ISessionEnumerator? sessions = null;
                try
                {
                    Marshal.ThrowExceptionForHR(collection.Item(i, out device)); string name = Name(device, (int)i);
                    Guid managerId = typeof(ISessionManager).GUID;
                    Marshal.ThrowExceptionForHR(device.Activate(in managerId, 23, 0, out managerObject));
                    Marshal.ThrowExceptionForHR(((ISessionManager)managerObject).GetSessionEnumerator(out sessions));
                    Marshal.ThrowExceptionForHR(sessions.GetCount(out int sessionCount));
                    if (sessionCount is < 0 or > 256) { complete = false; sessionCount = Math.Clamp(sessionCount, 0, 256); }
                    bool active = false;
                    for (int n = 0; n < sessionCount; n++)
                    {
                        if (Stopwatch.GetElapsedTime(sampledAt) > TimeSpan.FromMilliseconds(500)) { complete = false; break; }
                        ISessionControl? session = null;
                        try
                        {
                            Marshal.ThrowExceptionForHR(sessions.GetSession(n, out session));
                            Marshal.ThrowExceptionForHR(session.GetState(out int state)); active |= state == 1; complete &= state is >= 0 and <= 2;
                        }
                        catch (COMException) { complete = false; }
                        finally { Release(session); }
                    }
                    bool? muted = null; bool hardware = false; Guid volumeId = typeof(IEndpointVolume).GUID;
                    if (device.Activate(in volumeId, 23, 0, out volumeObject) >= 0 && volumeObject is IEndpointVolume volume)
                    {
                        if (volume.GetMute(out int isMuted) >= 0) muted = isMuted != 0;
                        if (volume.QueryHardwareSupport(out uint support) >= 0) hardware = (support & 2) != 0;
                    }
                    devices.Add(new(name, active, muted, hardware));
                }
                catch (Exception e) when (e is COMException or InvalidCastException) { complete = false; }
                finally { Release(volumeObject); Release(sessions); Release(managerObject); Release(device); }
            }
        }
        catch (Exception e) when (e is COMException or InvalidCastException or TypeLoadException) { complete = false; }
        finally { Release(collection); Release(enumeratorObject); }
        return Reduce(devices, complete, sampledAt);
    }
    private static string Name(IDevice device, int index)
    {
        IPropertyStore? properties = null; PropertyValue value = default;
        try
        {
            if (device.OpenPropertyStore(0, out properties) < 0) return "Input device " + (index + 1);
            var key = new PropertyKey { Format = new("A45C254E-DF1C-4EFD-8020-67D146A850E0"), Id = 14 };
            if (properties.GetValue(in key, out value) >= 0 && value.Type == 31 && value.Text != 0)
            {
                string name = Marshal.PtrToStringUni(value.Text) ?? "";
                return new string(name.Where(c => !char.IsControl(c)).Take(160).ToArray());
            }
        }
        finally { _ = PropVariantClear(ref value); Release(properties); }
        return "Input device " + (index + 1);
    }
    private static void Release(object? value) { if (value is not null && Marshal.IsComObject(value)) _ = Marshal.ReleaseComObject(value); }
    [StructLayout(LayoutKind.Sequential)] private struct PropertyKey { internal Guid Format; internal uint Id; }
    [StructLayout(LayoutKind.Explicit, Size = 24)] private struct PropertyValue { [FieldOffset(0)] internal ushort Type; [FieldOffset(8)] internal nint Text; }
    [DllImport("ole32.dll")] private static extern int PropVariantClear(ref PropertyValue value);
    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] private interface IDeviceEnumerator
    { [PreserveSig] int EnumAudioEndpoints(int flow, uint states, out IDeviceCollection collection); }
    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] private interface IDeviceCollection
    { [PreserveSig] int GetCount(out uint count); [PreserveSig] int Item(uint index, out IDevice device); }
    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] private interface IDevice
    { [PreserveSig] int Activate(in Guid iid, uint context, nint parameters, [MarshalAs(UnmanagedType.IUnknown)] out object value); [PreserveSig] int OpenPropertyStore(uint mode, out IPropertyStore store); }
    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] private interface IPropertyStore
    { [PreserveSig] int GetCount(out uint count); [PreserveSig] int GetAt(uint index, out PropertyKey key); [PreserveSig] int GetValue(in PropertyKey key, out PropertyValue value); }
    [ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] private interface ISessionManager
    {
        [PreserveSig] int GetAudioSessionControl(nint id, uint flags, out nint control);
        [PreserveSig] int GetSimpleAudioVolume(nint id, uint flags, out nint volume);
        [PreserveSig] int GetSessionEnumerator(out ISessionEnumerator enumerator);
    }
    [ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] private interface ISessionEnumerator
    { [PreserveSig] int GetCount(out int count); [PreserveSig] int GetSession(int index, out ISessionControl control); }
    [ComImport, Guid("F4B1A599-7266-4319-A8CA-E70ACB11E8CD"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] private interface ISessionControl
    { [PreserveSig] int GetState(out int state); }
    [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] private interface IEndpointVolume
    {
        [PreserveSig] int RegisterControlChangeNotify(nint notify); [PreserveSig] int UnregisterControlChangeNotify(nint notify);
        [PreserveSig] int GetChannelCount(out uint count);
        [PreserveSig] int SetMasterVolumeLevel(float level, nint context); [PreserveSig] int SetMasterVolumeLevelScalar(float level, nint context);
        [PreserveSig] int GetMasterVolumeLevel(out float level); [PreserveSig] int GetMasterVolumeLevelScalar(out float level);
        [PreserveSig] int SetChannelVolumeLevel(uint channel, float level, nint context); [PreserveSig] int SetChannelVolumeLevelScalar(uint channel, float level, nint context);
        [PreserveSig] int GetChannelVolumeLevel(uint channel, out float level); [PreserveSig] int GetChannelVolumeLevelScalar(uint channel, out float level);
        [PreserveSig] int SetMute(int muted, nint context); [PreserveSig] int GetMute(out int muted);
        [PreserveSig] int GetVolumeStepInfo(out uint step, out uint count); [PreserveSig] int VolumeStepUp(nint context); [PreserveSig] int VolumeStepDown(nint context);
        [PreserveSig] int QueryHardwareSupport(out uint support);
    }
}
