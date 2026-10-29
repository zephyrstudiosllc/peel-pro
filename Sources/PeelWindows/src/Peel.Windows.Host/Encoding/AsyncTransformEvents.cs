using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Peel.Windows.Host.Encoding;

/// <summary>Consumes each asynchronous MFT input/output ticket exactly once on its codec worker.</summary>
internal sealed unsafe class AsyncTransformEvents : IDisposable
{
    private static readonly Guid EventGeneratorInterface = new("2cd0bd52-bcd5-4b89-b62c-eadc0c031e7d");
    internal static readonly Guid Unlock = new("e5666d6b-3422-4eb6-a421-da7db1f8e207");
    private nint generator;
    internal int InputTickets { get; private set; }
    internal int OutputTickets { get; private set; }
    internal AsyncTransformEvents(nint transform)
    {
        Guid iid = EventGeneratorInterface;
        Marshal.ThrowExceptionForHR(Marshal.QueryInterface(transform, in iid, out generator));
    }
    internal void TakeInput() { if (InputTickets <= 0) throw new InvalidOperationException("Encoder did not request input."); InputTickets--; }
    internal void TakeOutput() { if (OutputTickets <= 0) throw new InvalidOperationException("Encoder has no output ticket."); OutputTickets--; }
    internal void Poll()
    {
        var getEvent = (delegate* unmanaged[Stdcall]<nint, uint, nint*, int>)(*(nint**)generator)[3];
        for (int i = 0; i < 64; i++)
        {
            nint mediaEvent = 0;
            int hr = getEvent(generator, 1, &mediaEvent);
            if (hr == unchecked((int)0xC00D3E80)) return;
            Marshal.ThrowExceptionForHR(hr);
            try
            {
                int type = 0, status = 0;
                nint* table = *(nint**)mediaEvent;
                Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, int*, int>)table[33])(mediaEvent, &type));
                Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, int*, int>)table[35])(mediaEvent, &status));
                Marshal.ThrowExceptionForHR(status);
                if (type == 601) InputTickets++;
                if (type == 602) OutputTickets++;
                if (InputTickets > 64 || OutputTickets > 64) throw new InvalidDataException("Codec exceeded its bounded event queue.");
            }
            finally { if (mediaEvent != 0) _ = Marshal.Release(mediaEvent); }
        }
    }
    internal void WaitForProgress(Func<bool> ready, CancellationToken token)
    {
        var timeout = Stopwatch.StartNew();
        while (!ready())
        {
            token.ThrowIfCancellationRequested(); Poll();
            if (ready()) return;
            if (timeout.Elapsed > TimeSpan.FromSeconds(5)) throw new TimeoutException("The hardware video codec stopped responding.");
            Thread.Sleep(1);
        }
    }
    public void Dispose() => MediaFoundationNative.Release(ref generator);
    [DllImport("mf.dll", ExactSpelling = true)] internal static extern int MFShutdownObject(nint unknown);
}
