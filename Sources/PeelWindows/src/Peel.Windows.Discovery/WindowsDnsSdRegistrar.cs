using System.ComponentModel;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;

namespace Peel.Windows.Discovery;

public sealed class WindowsDnsSdRegistrar : IPeelServiceRegistrar
{
    public async ValueTask<IAsyncDisposable> RegisterAsync(
        PeelServiceAdvertisement advertisement,
        CancellationToken cancellationToken = default)
    {
        PeelDiscoveryPlatform.RequireWindows();
        ArgumentNullException.ThrowIfNull(advertisement);

        var registration = new Registration(advertisement);
        await registration.StartAsync(cancellationToken).ConfigureAwait(false);
        return registration;
    }

    private sealed class Registration : IAsyncDisposable
    {
        private enum RegistrationState
        {
            Created,
            Registering,
            Active,
            Deregistering,
            Cleaned,
        }

        private static readonly WindowsDnsSdNative.RegisterCallback RegisterCallback = OnRegistrationChanged;
        private static readonly UTF8Encoding StrictUtf8 = new(false, true);
        private readonly object gate = new();
        private readonly PeelServiceAdvertisement advertisement;
        private readonly TaskCompletionSource registered = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource deregistered = new(TaskCreationOptions.RunContinuationsAsynchronously);

        private RegistrationState state;
        private GCHandle selfHandle;
        private IntPtr serviceInstance;
        private IntPtr request;

        internal Registration(PeelServiceAdvertisement advertisement)
        {
            if (string.IsNullOrWhiteSpace(advertisement.DisplayName))
            {
                throw new ArgumentException("A DNS-SD display name is required.", nameof(advertisement));
            }

            _ = PeelServiceType.ToQueryName(advertisement.ServiceType);
            if (advertisement.Port == 0)
            {
                throw new ArgumentException("A non-zero TCP port is required.", nameof(advertisement));
            }

            this.advertisement = advertisement;
        }

        internal async Task StartAsync(CancellationToken cancellationToken)
        {
            // DnsServiceRegisterCancel is not guaranteed to deliver a completion
            // callback, so cancellation is honored before native ownership begins.
            // Once submitted, wait for the registration callback to preserve the
            // unmanaged request/instance lifetime without races or leaks.
            cancellationToken.ThrowIfCancellationRequested();

            lock (gate)
            {
                if (state != RegistrationState.Created)
                {
                    throw new InvalidOperationException("This DNS-SD registration was already started.");
                }

                state = RegistrationState.Registering;
                BuildNativeRegistration();
            }

            var status = WindowsDnsSdNative.DnsServiceRegister(request, IntPtr.Zero);
            if (status != WindowsDnsSdNative.DnsRequestPending)
            {
                var exception = new Win32Exception(status, "DnsServiceRegister failed.");
                registered.TrySetException(exception);
                Cleanup();
                throw exception;
            }

            await registered.Task.ConfigureAwait(false);
        }

        public async ValueTask DisposeAsync()
        {
            RegistrationState snapshot;
            lock (gate)
            {
                snapshot = state;
                if (snapshot == RegistrationState.Active)
                {
                    state = RegistrationState.Deregistering;
                }
            }

            if (snapshot is RegistrationState.Created or RegistrationState.Cleaned)
            {
                Cleanup();
                return;
            }

            if (snapshot == RegistrationState.Registering)
            {
                try
                {
                    await registered.Task.ConfigureAwait(false);
                }
                catch (Exception)
                {
                    return;
                }

                await DisposeAsync().ConfigureAwait(false);
                return;
            }

            if (snapshot == RegistrationState.Active)
            {
                var status = WindowsDnsSdNative.DnsServiceDeRegister(request, IntPtr.Zero);
                if (status != WindowsDnsSdNative.DnsRequestPending)
                {
                    var exception = new Win32Exception(status, "DnsServiceDeRegister failed.");
                    deregistered.TrySetException(exception);
                    Cleanup();
                    throw exception;
                }
            }

            await deregistered.Task.ConfigureAwait(false);
        }

        private void BuildNativeRegistration()
        {
            var serviceType = advertisement.ServiceType.Trim().TrimEnd('.');
            var serviceName = $"{advertisement.DisplayName}.{serviceType}.{PeelServiceType.Domain}";
            var hostName = advertisement.HostName;
            if (string.IsNullOrWhiteSpace(hostName))
            {
                hostName = $"{Dns.GetHostName()}.{PeelServiceType.Domain}";
            }
            else if (!hostName.EndsWith($".{PeelServiceType.Domain}", StringComparison.OrdinalIgnoreCase))
            {
                hostName = $"{hostName.TrimEnd('.')}.{PeelServiceType.Domain}";
            }

            var orderedProperties = advertisement.TxtRecords.OrderBy(pair => pair.Key, StringComparer.Ordinal).ToArray();
            var keys = orderedProperties.Select(pair => pair.Key).ToArray();
            var values = orderedProperties.Select(pair => StrictUtf8.GetString(pair.Value)).ToArray();

            using var nativeKeys = new NativeStringArray(keys);
            using var nativeValues = new NativeStringArray(values);
            serviceInstance = WindowsDnsSdNative.DnsServiceConstructInstance(
                serviceName,
                hostName,
                IntPtr.Zero,
                IntPtr.Zero,
                advertisement.Port,
                0,
                0,
                checked((uint)orderedProperties.Length),
                nativeKeys.Pointer,
                nativeValues.Pointer);

            if (serviceInstance == IntPtr.Zero)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "DnsServiceConstructInstance failed.");
            }

            selfHandle = GCHandle.Alloc(this);
            request = WindowsDnsSdNative.AllocateStructure(new WindowsDnsSdNative.DnsServiceRegisterRequest
            {
                Version = WindowsDnsSdNative.DnsQueryRequestVersion1,
                InterfaceIndex = 0,
                ServiceInstance = serviceInstance,
                RegisterCompletionCallback = Marshal.GetFunctionPointerForDelegate(RegisterCallback),
                QueryContext = GCHandle.ToIntPtr(selfHandle),
                Credentials = IntPtr.Zero,
                UnicastEnabled = false,
            });
        }

        private static void OnRegistrationChanged(uint status, IntPtr queryContext, IntPtr callbackInstance)
        {
            var registration = GCHandle.FromIntPtr(queryContext).Target as Registration;
            if (registration is null)
            {
                return;
            }

            try
            {
                registration.HandleRegistrationChanged((int)status);
            }
            finally
            {
                if (callbackInstance != IntPtr.Zero)
                {
                    WindowsDnsSdNative.DnsServiceFreeInstance(callbackInstance);
                }
            }
        }

        private void HandleRegistrationChanged(int status)
        {
            RegistrationState snapshot;
            lock (gate)
            {
                snapshot = state;
                if (snapshot == RegistrationState.Registering && status == WindowsDnsSdNative.ErrorSuccess)
                {
                    state = RegistrationState.Active;
                }
            }

            if (snapshot == RegistrationState.Registering)
            {
                if (status == WindowsDnsSdNative.ErrorSuccess)
                {
                    registered.TrySetResult();
                    return;
                }

                if (status == WindowsDnsSdNative.ErrorCancelled)
                {
                    registered.TrySetCanceled();
                }
                else
                {
                    registered.TrySetException(new Win32Exception(status, "DNS-SD registration callback failed."));
                }

                Cleanup();
                return;
            }

            if (snapshot == RegistrationState.Deregistering)
            {
                if (status == WindowsDnsSdNative.ErrorSuccess)
                {
                    deregistered.TrySetResult();
                }
                else
                {
                    deregistered.TrySetException(new Win32Exception(status, "DNS-SD deregistration callback failed."));
                }

                Cleanup();
            }
        }

        private void Cleanup()
        {
            lock (gate)
            {
                if (state == RegistrationState.Cleaned)
                {
                    return;
                }

                state = RegistrationState.Cleaned;

                if (request != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(request);
                    request = IntPtr.Zero;
                }

                if (serviceInstance != IntPtr.Zero)
                {
                    WindowsDnsSdNative.DnsServiceFreeInstance(serviceInstance);
                    serviceInstance = IntPtr.Zero;
                }

                if (selfHandle.IsAllocated)
                {
                    selfHandle.Free();
                }
            }
        }
    }

    private sealed class NativeStringArray : IDisposable
    {
        private readonly IntPtr[] strings;

        internal NativeStringArray(IReadOnlyList<string> values)
        {
            strings = new IntPtr[values.Count];
            if (values.Count == 0)
            {
                return;
            }

            Pointer = Marshal.AllocHGlobal(checked(values.Count * IntPtr.Size));
            for (var index = 0; index < values.Count; index++)
            {
                strings[index] = Marshal.StringToHGlobalUni(values[index]);
                Marshal.WriteIntPtr(Pointer, index * IntPtr.Size, strings[index]);
            }
        }

        internal IntPtr Pointer { get; }

        public void Dispose()
        {
            foreach (var value in strings)
            {
                if (value != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(value);
                }
            }

            if (Pointer != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(Pointer);
            }
        }
    }
}
