using System.Runtime.InteropServices;

namespace Peel.Windows.Discovery;

internal static class WindowsDnsSdNative
{
    internal const int ErrorSuccess = 0;
    internal const int ErrorCancelled = 1223;
    internal const int DnsRequestPending = 9506;
    internal const uint DnsQueryRequestVersion1 = 1;
    internal const ushort DnsTypePtr = 12;

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    internal delegate void BrowseCallback(uint status, IntPtr queryContext, IntPtr dnsRecord);

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    internal delegate void ResolveCallback(uint status, IntPtr queryContext, IntPtr instance);

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    internal delegate void RegisterCallback(uint status, IntPtr queryContext, IntPtr instance);

    [StructLayout(LayoutKind.Sequential)]
    internal struct DnsServiceBrowseRequest
    {
        internal uint Version;
        internal uint InterfaceIndex;
        internal IntPtr QueryName;
        internal IntPtr BrowseCallback;
        internal IntPtr QueryContext;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct DnsServiceResolveRequest
    {
        internal uint Version;
        internal uint InterfaceIndex;
        internal IntPtr QueryName;
        internal IntPtr ResolveCompletionCallback;
        internal IntPtr QueryContext;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct DnsServiceRegisterRequest
    {
        internal uint Version;
        internal uint InterfaceIndex;
        internal IntPtr ServiceInstance;
        internal IntPtr RegisterCompletionCallback;
        internal IntPtr QueryContext;
        internal IntPtr Credentials;

        [MarshalAs(UnmanagedType.Bool)]
        internal bool UnicastEnabled;
    }

    // DNS_RECORDW starts with this common header. PTR data is the first pointer
    // in the trailing union, so PtrNameHost maps that union for DNS_TYPE_PTR.
    [StructLayout(LayoutKind.Sequential)]
    internal struct DnsRecordPtr
    {
        internal IntPtr Next;
        internal IntPtr Name;
        internal ushort Type;
        internal ushort DataLength;
        internal uint Flags;
        internal uint Ttl;
        internal uint Reserved;
        internal IntPtr PtrNameHost;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct DnsServiceInstance
    {
        internal IntPtr InstanceName;
        internal IntPtr HostName;
        internal IntPtr Ip4Address;
        internal IntPtr Ip6Address;
        internal ushort Port;
        internal ushort Priority;
        internal ushort Weight;
        internal uint PropertyCount;
        internal IntPtr Keys;
        internal IntPtr Values;
        internal uint InterfaceIndex;
    }

    [DllImport("dnsapi.dll", ExactSpelling = true, CallingConvention = CallingConvention.Winapi)]
    internal static extern int DnsServiceBrowse(IntPtr request, IntPtr cancel);

    [DllImport("dnsapi.dll", ExactSpelling = true, CallingConvention = CallingConvention.Winapi)]
    internal static extern int DnsServiceBrowseCancel(IntPtr cancel);

    [DllImport("dnsapi.dll", ExactSpelling = true, CallingConvention = CallingConvention.Winapi)]
    internal static extern int DnsServiceResolve(IntPtr request, IntPtr cancel);

    [DllImport("dnsapi.dll", ExactSpelling = true, CallingConvention = CallingConvention.Winapi)]
    internal static extern int DnsServiceResolveCancel(IntPtr cancel);

    [DllImport("dnsapi.dll", ExactSpelling = true, CallingConvention = CallingConvention.Winapi)]
    internal static extern IntPtr DnsServiceConstructInstance(
        [MarshalAs(UnmanagedType.LPWStr)] string serviceName,
        [MarshalAs(UnmanagedType.LPWStr)] string hostName,
        IntPtr ip4Address,
        IntPtr ip6Address,
        ushort port,
        ushort priority,
        ushort weight,
        uint propertyCount,
        IntPtr keys,
        IntPtr values);

    [DllImport("dnsapi.dll", ExactSpelling = true, CallingConvention = CallingConvention.Winapi)]
    internal static extern int DnsServiceRegister(IntPtr request, IntPtr cancel);

    [DllImport("dnsapi.dll", ExactSpelling = true, CallingConvention = CallingConvention.Winapi)]
    internal static extern int DnsServiceRegisterCancel(IntPtr cancel);

    [DllImport("dnsapi.dll", ExactSpelling = true, CallingConvention = CallingConvention.Winapi)]
    internal static extern int DnsServiceDeRegister(IntPtr request, IntPtr cancel);

    [DllImport("dnsapi.dll", ExactSpelling = true, CallingConvention = CallingConvention.Winapi)]
    internal static extern void DnsServiceFreeInstance(IntPtr instance);

    [DllImport("dnsapi.dll", ExactSpelling = true, CallingConvention = CallingConvention.Winapi)]
    internal static extern void DnsRecordListFree(IntPtr recordList, int freeType);

    internal static IntPtr AllocateStructure<T>(T value)
        where T : struct
    {
        var pointer = Marshal.AllocHGlobal(Marshal.SizeOf<T>());
        Marshal.StructureToPtr(value, pointer, false);
        return pointer;
    }

    internal static IntPtr AllocateCancel()
    {
        var pointer = Marshal.AllocHGlobal(IntPtr.Size);
        Marshal.WriteIntPtr(pointer, IntPtr.Zero);
        return pointer;
    }
}
