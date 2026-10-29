using System.ComponentModel;
using System.Runtime.InteropServices;
using Peel.Windows.Host.Interop;

namespace Peel.Windows.Host.Input;

internal static class WindowsProcessIntegrityLevel
{
    internal static bool TryReadCurrent(out uint integrityLevel, out string? error) =>
        TryRead(checked((uint)Environment.ProcessId), out integrityLevel, out error);

    internal static bool TryReadProcess(
        uint processId,
        out uint integrityLevel,
        out string? error) =>
        TryRead(processId, out integrityLevel, out error);

    private static bool TryRead(uint processId, out uint integrityLevel, out string? error)
    {
        if (!OperatingSystem.IsWindows())
        {
            integrityLevel = 0;
            error = "Process integrity validation requires Windows.";
            return false;
        }

        using var process = NativeMethods.OpenProcess(
            NativeMethods.ProcessQueryLimitedInformation,
            inheritHandle: false,
            processId);
        if (process.IsInvalid)
        {
            integrityLevel = 0;
            error = Win32Error("Windows could not open the input target process");
            return false;
        }

        if (!NativeMethods.OpenProcessToken(
                process,
                NativeMethods.TokenQuery,
                out Microsoft.Win32.SafeHandles.SafeAccessTokenHandle token))
        {
            integrityLevel = 0;
            error = Win32Error("Windows could not open the input target token");
            return false;
        }

        using (token)
        {
            _ = NativeMethods.GetTokenInformation(
                token,
                NativeMethods.TokenIntegrityLevel,
                nint.Zero,
                0,
                out int bufferLength);
            if (bufferLength <= 0)
            {
                integrityLevel = 0;
                error = Win32Error("Windows could not size the input target integrity label");
                return false;
            }

            nint buffer = Marshal.AllocHGlobal(bufferLength);
            try
            {
                if (!NativeMethods.GetTokenInformation(
                        token,
                        NativeMethods.TokenIntegrityLevel,
                        buffer,
                        bufferLength,
                        out _))
                {
                    integrityLevel = 0;
                    error = Win32Error("Windows could not read the input target integrity label");
                    return false;
                }

                NativeMethods.TokenMandatoryLabel label =
                    Marshal.PtrToStructure<NativeMethods.TokenMandatoryLabel>(buffer);
                nint countPointer = NativeMethods.GetSidSubAuthorityCount(label.Label.Sid);
                if (countPointer == nint.Zero)
                {
                    integrityLevel = 0;
                    error = "Windows returned an invalid input target integrity label.";
                    return false;
                }

                byte subAuthorityCount = Marshal.ReadByte(countPointer);
                if (subAuthorityCount == 0)
                {
                    integrityLevel = 0;
                    error = "Windows returned an empty input target integrity label.";
                    return false;
                }

                nint levelPointer = NativeMethods.GetSidSubAuthority(
                    label.Label.Sid,
                    checked((uint)(subAuthorityCount - 1)));
                if (levelPointer == nint.Zero)
                {
                    integrityLevel = 0;
                    error = "Windows returned an invalid input target integrity level.";
                    return false;
                }

                integrityLevel = unchecked((uint)Marshal.ReadInt32(levelPointer));
                error = null;
                return true;
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }
    }

    private static string Win32Error(string prefix)
    {
        int error = Marshal.GetLastWin32Error();
        return error == 0
            ? $"{prefix}; Windows did not provide an error code."
            : $"{prefix}: {new Win32Exception(error).Message}";
    }
}
