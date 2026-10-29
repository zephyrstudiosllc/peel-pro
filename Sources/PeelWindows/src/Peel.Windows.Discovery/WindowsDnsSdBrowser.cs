using System.Collections.Concurrent;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Channels;

namespace Peel.Windows.Discovery;

public sealed class WindowsDnsSdBrowser : IPeelServiceBrowser
{
    public async IAsyncEnumerable<PeelDiscoveredService> BrowseAsync(
        string serviceType,
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        PeelDiscoveryPlatform.RequireWindows();

        await using var session = new BrowseSession(serviceType);
        session.Start();

        await foreach (var service in session.Results.ReadAllAsync(cancellationToken).ConfigureAwait(false))
        {
            yield return service;
        }
    }

    private sealed class BrowseSession : IAsyncDisposable
    {
        private static readonly WindowsDnsSdNative.BrowseCallback BrowseCallback = OnBrowse;
        private readonly string serviceType;
        private readonly string queryName;
        private readonly Channel<PeelDiscoveredService> results = Channel.CreateUnbounded<PeelDiscoveredService>(
            new UnboundedChannelOptions { SingleReader = true, SingleWriter = false });
        private readonly ConcurrentDictionary<string, ResolveOperation> resolves =
            new(StringComparer.OrdinalIgnoreCase);

        private GCHandle selfHandle;
        private IntPtr request;
        private IntPtr queryNamePointer;
        private IntPtr cancel;
        private int started;
        private int cleanupStarted;

        internal BrowseSession(string serviceType)
        {
            this.serviceType = serviceType.Trim().TrimEnd('.');
            queryName = PeelServiceType.ToQueryName(this.serviceType);
        }

        internal ChannelReader<PeelDiscoveredService> Results => results.Reader;

        internal void Start()
        {
            if (Interlocked.Exchange(ref started, 1) != 0)
            {
                throw new InvalidOperationException("This DNS-SD browse session was already started.");
            }

            selfHandle = GCHandle.Alloc(this);
            queryNamePointer = Marshal.StringToHGlobalUni(queryName);
            cancel = WindowsDnsSdNative.AllocateCancel();
            request = WindowsDnsSdNative.AllocateStructure(new WindowsDnsSdNative.DnsServiceBrowseRequest
            {
                Version = WindowsDnsSdNative.DnsQueryRequestVersion1,
                InterfaceIndex = 0,
                QueryName = queryNamePointer,
                BrowseCallback = Marshal.GetFunctionPointerForDelegate(BrowseCallback),
                QueryContext = GCHandle.ToIntPtr(selfHandle),
            });

            var status = WindowsDnsSdNative.DnsServiceBrowse(request, cancel);
            if (status != WindowsDnsSdNative.DnsRequestPending)
            {
                Cleanup();
                throw new Win32Exception(status, $"DnsServiceBrowse failed for {queryName}.");
            }
        }

        public ValueTask DisposeAsync()
        {
            foreach (var operation in resolves.Values)
            {
                operation.SuppressResult();
            }

            if (Volatile.Read(ref started) == 0 || Volatile.Read(ref cleanupStarted) != 0)
            {
                results.Writer.TryComplete();
                return ValueTask.CompletedTask;
            }

            var status = WindowsDnsSdNative.DnsServiceBrowseCancel(cancel);
            if (status != WindowsDnsSdNative.ErrorSuccess)
            {
                Cleanup();
            }

            results.Writer.TryComplete();
            return ValueTask.CompletedTask;
        }

        private static void OnBrowse(uint status, IntPtr queryContext, IntPtr dnsRecord)
        {
            BrowseSession? session = null;
            try
            {
                session = GCHandle.FromIntPtr(queryContext).Target as BrowseSession;
                if (session is null)
                {
                    return;
                }

                if (status == WindowsDnsSdNative.ErrorCancelled)
                {
                    session.results.Writer.TryComplete();
                    session.Cleanup();
                    return;
                }

                if (status != WindowsDnsSdNative.ErrorSuccess)
                {
                    session.results.Writer.TryComplete(new Win32Exception((int)status, "DNS-SD browse callback failed."));
                    session.Cleanup();
                    return;
                }

                session.HandleRecords(dnsRecord);
            }
            catch (Exception exception)
            {
                session?.results.Writer.TryComplete(exception);
            }
            finally
            {
                if (dnsRecord != IntPtr.Zero)
                {
                    WindowsDnsSdNative.DnsRecordListFree(dnsRecord, 1);
                }
            }
        }

        private void HandleRecords(IntPtr firstRecord)
        {
            var current = firstRecord;
            while (current != IntPtr.Zero)
            {
                var record = Marshal.PtrToStructure<WindowsDnsSdNative.DnsRecordPtr>(current);
                if (record.Type == WindowsDnsSdNative.DnsTypePtr && record.PtrNameHost != IntPtr.Zero)
                {
                    var instanceName = Marshal.PtrToStringUni(record.PtrNameHost);
                    if (!string.IsNullOrWhiteSpace(instanceName))
                    {
                        // RFC 6762 section 10.1 uses an RR TTL of zero for a
                        // goodbye packet. DNS_RECORD_FLAGS.Delete is reserved
                        // by the Windows API, so it is not a supported removal
                        // signal here.
                        if (record.Ttl == 0)
                        {
                            PublishRemoved(instanceName);
                        }
                        else
                        {
                            StartResolve(instanceName);
                        }
                    }
                }

                current = record.Next;
            }
        }

        private void StartResolve(string instanceName)
        {
            var operation = new ResolveOperation(this, instanceName, serviceType);
            if (!resolves.TryAdd(instanceName, operation))
            {
                operation.ReleaseWithoutStarting();
                return;
            }

            try
            {
                operation.Start();
            }
            catch
            {
                resolves.TryRemove(instanceName, out _);
                operation.ReleaseWithoutStarting();
                throw;
            }
        }

        internal void PublishResolved(PeelDiscoveredService service) => results.Writer.TryWrite(service);

        internal void ResolveFinished(string instanceName) => resolves.TryRemove(instanceName, out _);

        private void PublishRemoved(string instanceName)
        {
            if (resolves.TryRemove(instanceName, out var resolve))
            {
                resolve.SuppressResult();
            }

            results.Writer.TryWrite(new PeelDiscoveredService(
                PeelServiceChangeKind.Removed,
                instanceName,
                GetDisplayName(instanceName, serviceType),
                serviceType,
                null,
                null,
                new Dictionary<string, byte[]>(StringComparer.Ordinal)));
        }

        private void Cleanup()
        {
            if (Interlocked.Exchange(ref cleanupStarted, 1) != 0)
            {
                return;
            }

            if (request != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(request);
                request = IntPtr.Zero;
            }

            if (queryNamePointer != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(queryNamePointer);
                queryNamePointer = IntPtr.Zero;
            }

            if (cancel != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(cancel);
                cancel = IntPtr.Zero;
            }

            if (selfHandle.IsAllocated)
            {
                selfHandle.Free();
            }
        }
    }

    private sealed class ResolveOperation
    {
        private static readonly WindowsDnsSdNative.ResolveCallback ResolveCallback = OnResolve;
        private readonly BrowseSession owner;
        private readonly string instanceName;
        private readonly string serviceType;

        private GCHandle selfHandle;
        private IntPtr request;
        private IntPtr queryNamePointer;
        private IntPtr cancel;
        private int cleanupStarted;
        private int resultSuppressed;

        internal ResolveOperation(BrowseSession owner, string instanceName, string serviceType)
        {
            this.owner = owner;
            this.instanceName = instanceName;
            this.serviceType = serviceType;
        }

        internal void Start()
        {
            selfHandle = GCHandle.Alloc(this);
            queryNamePointer = Marshal.StringToHGlobalUni(instanceName);
            cancel = WindowsDnsSdNative.AllocateCancel();
            request = WindowsDnsSdNative.AllocateStructure(new WindowsDnsSdNative.DnsServiceResolveRequest
            {
                Version = WindowsDnsSdNative.DnsQueryRequestVersion1,
                InterfaceIndex = 0,
                QueryName = queryNamePointer,
                ResolveCompletionCallback = Marshal.GetFunctionPointerForDelegate(ResolveCallback),
                QueryContext = GCHandle.ToIntPtr(selfHandle),
            });
            var status = WindowsDnsSdNative.DnsServiceResolve(request, cancel);
            if (status != WindowsDnsSdNative.DnsRequestPending)
            {
                Cleanup();
                throw new Win32Exception(status, $"DnsServiceResolve failed for {instanceName}.");
            }
        }

        internal void SuppressResult()
        {
            // Resolve cancellation does not document the final-callback guarantee
            // that browse cancellation provides. Keep native state alive until its
            // normal callback and suppress a stale result instead of risking a
            // delegate/request lifetime race.
            Volatile.Write(ref resultSuppressed, 1);
        }

        internal void ReleaseWithoutStarting() => Cleanup();

        private static void OnResolve(uint status, IntPtr queryContext, IntPtr instance)
        {
            var operation = GCHandle.FromIntPtr(queryContext).Target as ResolveOperation;
            if (operation is null)
            {
                return;
            }

            try
            {
                if (status == WindowsDnsSdNative.ErrorSuccess &&
                    instance != IntPtr.Zero &&
                    Volatile.Read(ref operation.resultSuppressed) == 0)
                {
                    operation.owner.PublishResolved(ReadInstance(instance, operation.serviceType));
                }
            }
            finally
            {
                if (instance != IntPtr.Zero)
                {
                    WindowsDnsSdNative.DnsServiceFreeInstance(instance);
                }

                operation.owner.ResolveFinished(operation.instanceName);
                operation.Cleanup();
            }
        }

        private void Cleanup()
        {
            if (Interlocked.Exchange(ref cleanupStarted, 1) != 0)
            {
                return;
            }

            if (request != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(request);
                request = IntPtr.Zero;
            }

            if (queryNamePointer != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(queryNamePointer);
                queryNamePointer = IntPtr.Zero;
            }

            if (cancel != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(cancel);
                cancel = IntPtr.Zero;
            }

            if (selfHandle.IsAllocated)
            {
                selfHandle.Free();
            }
        }
    }

    private static PeelDiscoveredService ReadInstance(IntPtr pointer, string serviceType)
    {
        var native = Marshal.PtrToStructure<WindowsDnsSdNative.DnsServiceInstance>(pointer);
        var instanceName = Marshal.PtrToStringUni(native.InstanceName) ?? string.Empty;
        var properties = new Dictionary<string, byte[]>(StringComparer.Ordinal);

        for (var index = 0u; index < native.PropertyCount; index++)
        {
            var byteOffset = checked((int)index * IntPtr.Size);
            var keyPointer = Marshal.ReadIntPtr(native.Keys, byteOffset);
            var valuePointer = Marshal.ReadIntPtr(native.Values, byteOffset);
            var key = Marshal.PtrToStringUni(keyPointer);
            var value = Marshal.PtrToStringUni(valuePointer);
            if (!string.IsNullOrEmpty(key) && value is not null)
            {
                properties[key] = Encoding.UTF8.GetBytes(value);
            }
        }

        return new PeelDiscoveredService(
            PeelServiceChangeKind.Added,
            instanceName,
            GetDisplayName(instanceName, serviceType),
            serviceType,
            Marshal.PtrToStringUni(native.HostName),
            native.Port,
            properties,
            native.InterfaceIndex);
    }

    private static string GetDisplayName(string instanceName, string serviceType)
    {
        var suffix = $".{serviceType}.{PeelServiceType.Domain}";
        return instanceName.EndsWith(suffix, StringComparison.OrdinalIgnoreCase)
            ? instanceName[..^suffix.Length]
            : instanceName;
    }
}
