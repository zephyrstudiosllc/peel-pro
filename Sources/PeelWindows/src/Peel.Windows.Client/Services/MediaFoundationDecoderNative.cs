using System.IO;
using System.Runtime.InteropServices;

namespace Peel.Windows.Client.Services;

internal static unsafe class MediaFoundationDecoderNative
{
    internal const int TransformStreamChange = unchecked((int)0xC00D6D61);
    internal const int TransformNeedsMoreInput = unchecked((int)0xC00D6D72);
    internal const int NotImplemented = unchecked((int)0x80004001);
    internal const int RpcChangedMode = unchecked((int)0x80010106);

    private const uint CoInitMultithreaded = 0;
    private const uint ClassContextInProcessServer = 1;
    private const int MediaFoundationVersion = 0x0002_0070;

    internal const uint OutputProvidesSamples = 0x100;
    internal const uint OutputCanProvideSamples = 0x200;

    internal const uint MessageCommandFlush = 0x0000_0000;
    internal const uint MessageCommandDrain = 0x0000_0001;
    internal const uint MessageNotifyBeginStreaming = 0x1000_0000;
    internal const uint MessageNotifyEndStreaming = 0x1000_0001;
    internal const uint MessageNotifyEndOfStream = 0x1000_0002;
    internal const uint MessageNotifyStartOfStream = 0x1000_0003;

    private static readonly Guid H264DecoderClass =
        new("62ce7e72-4c71-4d20-b15d-452831a87d9d");
    private static readonly Guid TransformInterface =
        new("bf94c121-5b05-4e6f-8000-ba598961414d");

    internal static readonly Guid MediaTypeVideo =
        new("73646976-0000-0010-8000-00aa00389b71");
    internal static readonly Guid VideoFormatH264 =
        new("34363248-0000-0010-8000-00aa00389b71");
    internal static readonly Guid VideoFormatNv12 =
        new("3231564e-0000-0010-8000-00aa00389b71");

    internal static readonly Guid MajorType =
        new("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
    internal static readonly Guid Subtype =
        new("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
    internal static readonly Guid FrameSize =
        new("1652c33d-d6b2-4012-b834-72030849a37d");
    internal static readonly Guid FrameRate =
        new("c459a2e8-3d2c-4e44-b132-fee5156c7bb0");
    internal static readonly Guid PixelAspectRatio =
        new("c6376a1e-8d0a-4027-be45-6d9a0ad39bb6");
    internal static readonly Guid InterlaceMode =
        new("e2724bb8-e676-4806-b4b2-a8d6efb44ccd");
    internal static readonly Guid MpegSequenceHeader =
        new("3c036de7-3ad0-4c9e-9216-ee6d6ac21cb3");
    internal static readonly Guid DefaultStride =
        new("644b4e48-1e02-4516-b0eb-c01ca9d49ac6");
    internal static readonly Guid LowLatency =
        new("9c27891a-ed7a-40e1-88e8-b22727a024ee");

    [StructLayout(LayoutKind.Sequential)]
    internal struct OutputStreamInfo
    {
        internal uint Flags;
        internal uint Size;
        internal uint Alignment;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct OutputDataBuffer
    {
        internal uint StreamId;
        internal nint Sample;
        internal uint Status;
        internal nint Events;
    }

    internal static void Check(int result, string operation)
    {
        if (result < 0)
        {
            throw new COMException($"{operation} failed with HRESULT 0x{result:X8}.", result);
        }
    }

    internal static int InitializeCom() => CoInitializeEx(0, CoInitMultithreaded);

    internal static void UninitializeCom() => CoUninitialize();

    internal static void Startup() => Check(MFStartup(MediaFoundationVersion, 0), "MFStartup");

    internal static void Shutdown() => Check(MFShutdown(), "MFShutdown");

    internal static nint CreateH264Decoder()
    {
        Guid classId = H264DecoderClass;
        Guid interfaceId = TransformInterface;
        Check(CoCreateInstance(
            &classId,
            0,
            ClassContextInProcessServer,
            &interfaceId,
            out nint transform), "CoCreateInstance(H.264 decoder)");
        return transform;
    }

    internal static nint CreateMediaType()
    {
        Check(MFCreateMediaType(out nint mediaType), "MFCreateMediaType");
        return mediaType;
    }

    internal static void Release(ref nint value)
    {
        nint releasing = value;
        value = 0;
        if (releasing != 0)
        {
            _ = Marshal.Release(releasing);
        }
    }

    internal static void SetUInt32(nint attributes, Guid key, uint value)
    {
        Guid localKey = key;
        nint* table = *(nint**)attributes;
        var method = (delegate* unmanaged[Stdcall]<nint, Guid*, uint, int>)table[21];
        Check(method(attributes, &localKey, value), "IMFAttributes.SetUINT32");
    }

    internal static void SetUInt64(nint attributes, Guid key, ulong value)
    {
        Guid localKey = key;
        nint* table = *(nint**)attributes;
        var method = (delegate* unmanaged[Stdcall]<nint, Guid*, ulong, int>)table[22];
        Check(method(attributes, &localKey, value), "IMFAttributes.SetUINT64");
    }

    internal static void SetGuid(nint attributes, Guid key, Guid value)
    {
        Guid localKey = key;
        Guid localValue = value;
        nint* table = *(nint**)attributes;
        var method = (delegate* unmanaged[Stdcall]<nint, Guid*, Guid*, int>)table[24];
        Check(method(attributes, &localKey, &localValue), "IMFAttributes.SetGUID");
    }

    internal static void SetBlob(nint attributes, Guid key, ReadOnlySpan<byte> value)
    {
        if (value.IsEmpty)
        {
            throw new InvalidDataException("Media Foundation attributes cannot receive an empty blob.");
        }

        Guid localKey = key;
        fixed (byte* source = value)
        {
            nint* table = *(nint**)attributes;
            var method = (delegate* unmanaged[Stdcall]<nint, Guid*, byte*, uint, int>)table[26];
            Check(method(attributes, &localKey, source, checked((uint)value.Length)),
                "IMFAttributes.SetBlob");
        }
    }

    internal static void SetSize(nint attributes, Guid key, uint width, uint height) =>
        SetUInt64(attributes, key, ((ulong)width << 32) | height);

    internal static void SetRatio(
        nint attributes,
        Guid key,
        uint numerator,
        uint denominator) =>
        SetUInt64(attributes, key, ((ulong)numerator << 32) | denominator);

    internal static void GetStreamIds(nint transform, out uint inputId, out uint outputId)
    {
        uint input = 0;
        uint output = 0;
        nint* table = *(nint**)transform;
        var method = (delegate* unmanaged[Stdcall]<nint, uint, uint*, uint, uint*, int>)table[5];
        int result = method(transform, 1, &input, 1, &output);
        if (result != NotImplemented)
        {
            Check(result, "IMFTransform.GetStreamIDs");
        }

        inputId = input;
        outputId = output;
    }

    internal static nint GetTransformAttributes(nint transform)
    {
        nint attributes = 0;
        nint* table = *(nint**)transform;
        var method = (delegate* unmanaged[Stdcall]<nint, nint*, int>)table[8];
        Check(method(transform, &attributes), "IMFTransform.GetAttributes");
        return attributes;
    }

    internal static void SetInputType(nint transform, uint streamId, nint mediaType)
    {
        nint* table = *(nint**)transform;
        var method = (delegate* unmanaged[Stdcall]<nint, uint, nint, uint, int>)table[15];
        Check(method(transform, streamId, mediaType, 0), "IMFTransform.SetInputType");
    }

    internal static void SetOutputType(nint transform, uint streamId, nint mediaType)
    {
        nint* table = *(nint**)transform;
        var method = (delegate* unmanaged[Stdcall]<nint, uint, nint, uint, int>)table[16];
        Check(method(transform, streamId, mediaType, 0), "IMFTransform.SetOutputType");
    }

    internal static OutputStreamInfo GetOutputStreamInfo(nint transform, uint streamId)
    {
        OutputStreamInfo info = default;
        nint* table = *(nint**)transform;
        var method = (delegate* unmanaged[Stdcall]<nint, uint, OutputStreamInfo*, int>)table[7];
        Check(method(transform, streamId, &info), "IMFTransform.GetOutputStreamInfo");
        return info;
    }

    internal static void ProcessMessage(nint transform, uint message, nuint parameter = 0)
    {
        nint* table = *(nint**)transform;
        var method = (delegate* unmanaged[Stdcall]<nint, uint, nuint, int>)table[23];
        Check(method(transform, message, parameter), "IMFTransform.ProcessMessage");
    }

    internal static void TryProcessMessage(nint transform, uint message)
    {
        try
        {
            ProcessMessage(transform, message);
        }
        catch (COMException)
        {
        }
    }

    internal static nint CreateInputSample(
        ReadOnlySpan<byte> bytes,
        long timestamp,
        long duration)
    {
        nint buffer = 0;
        nint sample = 0;
        try
        {
            Check(MFCreateMemoryBuffer(checked((uint)bytes.Length), out buffer),
                "MFCreateMemoryBuffer");
            LockBuffer(buffer, out byte* destination, out uint maximumLength, out _);
            try
            {
                if (maximumLength < bytes.Length)
                {
                    throw new InvalidDataException("Media Foundation allocated a short decoder buffer.");
                }

                bytes.CopyTo(new Span<byte>(destination, bytes.Length));
            }
            finally
            {
                UnlockBuffer(buffer);
            }

            SetBufferCurrentLength(buffer, checked((uint)bytes.Length));
            Check(MFCreateSample(out sample), "MFCreateSample");
            AddSampleBuffer(sample, buffer);
            SetSampleTime(sample, timestamp);
            SetSampleDuration(sample, duration);
            return sample;
        }
        catch
        {
            Release(ref sample);
            throw;
        }
        finally
        {
            Release(ref buffer);
        }
    }

    internal static nint CreateOutputSample(uint byteCount)
    {
        if (byteCount == 0 || byteCount > int.MaxValue)
        {
            throw new InvalidDataException("The H.264 decoder returned an invalid output size.");
        }

        nint buffer = 0;
        nint sample = 0;
        try
        {
            Check(MFCreateMemoryBuffer(byteCount, out buffer), "MFCreateMemoryBuffer(output)");
            Check(MFCreateSample(out sample), "MFCreateSample(output)");
            AddSampleBuffer(sample, buffer);
            return sample;
        }
        catch
        {
            Release(ref sample);
            throw;
        }
        finally
        {
            Release(ref buffer);
        }
    }

    internal static void ProcessInput(nint transform, uint streamId, nint sample)
    {
        nint* table = *(nint**)transform;
        var method = (delegate* unmanaged[Stdcall]<nint, uint, nint, uint, int>)table[24];
        Check(method(transform, streamId, sample, 0), "IMFTransform.ProcessInput");
    }

    internal static int ProcessOutput(
        nint transform,
        ref OutputDataBuffer output,
        out uint status)
    {
        uint localStatus = 0;
        nint* table = *(nint**)transform;
        var method = (delegate* unmanaged[Stdcall]<nint, uint, uint, OutputDataBuffer*, uint*, int>)table[25];
        fixed (OutputDataBuffer* outputPointer = &output)
        {
            int result = method(transform, 0, 1, outputPointer, &localStatus);
            status = localStatus;
            return result;
        }
    }

    internal static byte[] ReadSampleBytes(nint sample)
    {
        nint buffer = 0;
        try
        {
            nint* table = *(nint**)sample;
            var convert = (delegate* unmanaged[Stdcall]<nint, nint*, int>)table[41];
            Check(convert(sample, &buffer), "IMFSample.ConvertToContiguousBuffer");
            LockBuffer(buffer, out byte* source, out _, out uint currentLength);
            try
            {
                if (currentLength == 0 || currentLength > Array.MaxLength)
                {
                    throw new InvalidDataException("The H.264 decoder returned an empty or oversized sample.");
                }

                return new ReadOnlySpan<byte>(source, checked((int)currentLength)).ToArray();
            }
            finally
            {
                UnlockBuffer(buffer);
            }
        }
        finally
        {
            Release(ref buffer);
        }
    }

    internal static bool HasDxgiBuffer(nint sample)
    {
        nint buffer = 0, dxgi = 0;
        try
        {
            var get = (delegate* unmanaged[Stdcall]<nint, uint, nint*, int>)(*(nint**)sample)[40];
            if (get(sample, 0, &buffer) < 0 || buffer == 0) return false;
            Guid iid = new("e7174cfa-1c9e-48b1-8866-626226bfc258");
            return Marshal.QueryInterface(buffer, in iid, out dxgi) >= 0;
        }
        finally { Release(ref dxgi); Release(ref buffer); }
    }

    internal static nint GetDxgiTexture(nint sample, out uint subresource)
    {
        nint buffer = 0, dxgi = 0, texture = 0;
        subresource = 0;
        try
        {
            Check(((delegate* unmanaged[Stdcall]<nint, uint, nint*, int>)(*(nint**)sample)[40])(sample, 0, &buffer), "IMFSample.GetBufferByIndex");
            Guid iid = new("e7174cfa-1c9e-48b1-8866-626226bfc258");
            if (Marshal.QueryInterface(buffer, in iid, out dxgi) < 0) return 0;
            iid = new("6f15aaf2-d208-4e89-9ab4-489535d34f9c");
            Check(((delegate* unmanaged[Stdcall]<nint, Guid*, nint*, int>)(*(nint**)dxgi)[3])(dxgi, &iid, &texture), "IMFDXGIBuffer.GetResource");
            uint index = 0;
            Check(((delegate* unmanaged[Stdcall]<nint, uint*, int>)(*(nint**)dxgi)[4])(dxgi, &index), "IMFDXGIBuffer.GetSubresourceIndex");
            subresource = index; return texture;
        }
        catch { Release(ref texture); throw; }
        finally { Release(ref dxgi); Release(ref buffer); }
    }

    internal static uint GetUInt32OrDefault(nint attributes, Guid key)
    {
        uint value = 0;
        return ((delegate* unmanaged[Stdcall]<nint, Guid*, uint*, int>)(*(nint**)attributes)[7])(attributes, &key, &value) >= 0 ? value : 0;
    }

    internal static (bool Bt709, bool FullRange) GetOutputColor(nint transform, uint stream)
    {
        nint type = 0;
        try
        {
            // Available type carries bitstream VUI colorimetry when a sequence changes.
            if (((delegate* unmanaged[Stdcall]<nint, uint, uint, nint*, int>)(*(nint**)transform)[14])(transform, stream, 0, &type) < 0) return default;
            uint matrix = GetUInt32OrDefault(type, new("3e23d450-2c75-4d25-a00e-b91670d12327"));
            uint range = GetUInt32OrDefault(type, new("c21b8ee5-b956-4071-8daf-325edf5cab11"));
            if (matrix > 2 || range > 2) throw new InvalidDataException("This stream uses an unsupported video color matrix or nominal range.");
            return (matrix == 1, range == 1);
        }
        finally { Release(ref type); }
    }

    internal static bool TryGetSampleTime(nint sample, out long value)
    {
        long localValue = 0;
        nint* table = *(nint**)sample;
        var method = (delegate* unmanaged[Stdcall]<nint, long*, int>)table[35];
        int result = method(sample, &localValue);
        value = localValue;
        return result >= 0;
    }

    private static void AddSampleBuffer(nint sample, nint buffer)
    {
        nint* table = *(nint**)sample;
        var method = (delegate* unmanaged[Stdcall]<nint, nint, int>)table[42];
        Check(method(sample, buffer), "IMFSample.AddBuffer");
    }

    private static void SetSampleTime(nint sample, long value)
    {
        nint* table = *(nint**)sample;
        var method = (delegate* unmanaged[Stdcall]<nint, long, int>)table[36];
        Check(method(sample, value), "IMFSample.SetSampleTime");
    }

    private static void SetSampleDuration(nint sample, long value)
    {
        nint* table = *(nint**)sample;
        var method = (delegate* unmanaged[Stdcall]<nint, long, int>)table[38];
        Check(method(sample, value), "IMFSample.SetSampleDuration");
    }

    private static void LockBuffer(
        nint buffer,
        out byte* data,
        out uint maximumLength,
        out uint currentLength)
    {
        byte* localData = null;
        uint localMaximum = 0;
        uint localCurrent = 0;
        nint* table = *(nint**)buffer;
        var method = (delegate* unmanaged[Stdcall]<nint, byte**, uint*, uint*, int>)table[3];
        Check(method(buffer, &localData, &localMaximum, &localCurrent), "IMFMediaBuffer.Lock");
        data = localData;
        maximumLength = localMaximum;
        currentLength = localCurrent;
    }

    private static void UnlockBuffer(nint buffer)
    {
        nint* table = *(nint**)buffer;
        var method = (delegate* unmanaged[Stdcall]<nint, int>)table[4];
        Check(method(buffer), "IMFMediaBuffer.Unlock");
    }

    private static void SetBufferCurrentLength(nint buffer, uint byteCount)
    {
        nint* table = *(nint**)buffer;
        var method = (delegate* unmanaged[Stdcall]<nint, uint, int>)table[6];
        Check(method(buffer, byteCount), "IMFMediaBuffer.SetCurrentLength");
    }

    [DllImport("ole32.dll", ExactSpelling = true)]
    private static extern int CoInitializeEx(nint reserved, uint coInit);

    [DllImport("ole32.dll", ExactSpelling = true)]
    private static extern void CoUninitialize();

    [DllImport("ole32.dll", ExactSpelling = true)]
    private static extern int CoCreateInstance(
        Guid* classId,
        nint outer,
        uint classContext,
        Guid* interfaceId,
        out nint instance);

    [DllImport("mfplat.dll", ExactSpelling = true)]
    private static extern int MFStartup(int version, uint flags);

    [DllImport("mfplat.dll", ExactSpelling = true)]
    private static extern int MFShutdown();

    [DllImport("mfplat.dll", ExactSpelling = true)]
    private static extern int MFCreateMediaType(out nint mediaType);

    [DllImport("mfplat.dll", ExactSpelling = true)]
    private static extern int MFCreateSample(out nint sample);

    [DllImport("mfplat.dll", ExactSpelling = true)]
    private static extern int MFCreateMemoryBuffer(uint maximumLength, out nint buffer);
}
