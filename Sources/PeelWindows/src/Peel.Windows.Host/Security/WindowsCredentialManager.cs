using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;

namespace Peel.Windows.Host.Security;

internal interface ICurrentUserCredentialVault
{
    void Write(string targetName, ReadOnlySpan<byte> secret);

    bool TryRead(string targetName, out byte[]? secret);

    bool Delete(string targetName);
}

internal sealed class WindowsCredentialManager : ICurrentUserCredentialVault
{
    private const uint CredTypeGeneric = 1;
    private const uint CredPersistLocalMachine = 2;
    private const int ErrorNotFound = 1168;
    private const int MaximumTargetNameCharacters = 32_767;
    private const int MaximumCredentialBlobBytes = 5 * 512;

    public unsafe void Write(string targetName, ReadOnlySpan<byte> secret)
    {
        EnsureWindows();
        ValidateTargetName(targetName);
        if (secret is not { Length: > 0 and <= MaximumCredentialBlobBytes })
        {
            throw new ArgumentOutOfRangeException(nameof(secret));
        }

        byte[] secretCopy = secret.ToArray();
        try
        {
            fixed (byte* secretPointer = secretCopy)
            {
                var credential = new NativeCredential
                {
                    Type = CredTypeGeneric,
                    TargetName = targetName,
                    CredentialBlobSize = checked((uint)secretCopy.Length),
                    CredentialBlob = (nint)secretPointer,
                    Persist = CredPersistLocalMachine,
                    UserName = "Peel",
                };

                if (!CredWriteW(ref credential, 0))
                {
                    throw new Win32Exception(
                        Marshal.GetLastPInvokeError(),
                        "Windows Credential Manager could not store the Peel credential.");
                }
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(secretCopy);
        }
    }

    public bool TryRead(string targetName, out byte[]? secret)
    {
        EnsureWindows();
        ValidateTargetName(targetName);
        if (!CredReadW(targetName, CredTypeGeneric, 0, out nint credentialPointer))
        {
            int error = Marshal.GetLastPInvokeError();
            if (error == ErrorNotFound)
            {
                secret = null;
                return false;
            }

            throw new Win32Exception(
                error,
                "Windows Credential Manager could not read the Peel credential.");
        }

        try
        {
            NativeCredential credential =
                Marshal.PtrToStructure<NativeCredential>(credentialPointer);
            if (credential.Type != CredTypeGeneric ||
                credential.CredentialBlobSize is 0 or > MaximumCredentialBlobBytes ||
                credential.CredentialBlob == nint.Zero)
            {
                secret = null;
                return false;
            }

            secret = new byte[credential.CredentialBlobSize];
            Marshal.Copy(
                credential.CredentialBlob,
                secret,
                0,
                checked((int)credential.CredentialBlobSize));
            return true;
        }
        finally
        {
            CredFree(credentialPointer);
        }
    }

    public bool Delete(string targetName)
    {
        EnsureWindows();
        ValidateTargetName(targetName);
        if (CredDeleteW(targetName, CredTypeGeneric, 0))
        {
            return true;
        }

        int error = Marshal.GetLastPInvokeError();
        if (error == ErrorNotFound)
        {
            return false;
        }

        throw new Win32Exception(
            error,
            "Windows Credential Manager could not delete the Peel credential.");
    }

    private static void EnsureWindows()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "Windows Credential Manager requires Windows.");
        }
    }

    private static void ValidateTargetName(string targetName)
    {
        if (string.IsNullOrWhiteSpace(targetName) ||
            targetName.Length > MaximumTargetNameCharacters ||
            targetName.IndexOf('\0') >= 0)
        {
            throw new ArgumentException(
                "A valid Windows generic-credential target name is required.",
                nameof(targetName));
        }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NativeCredential
    {
        internal uint Flags;
        internal uint Type;
        [MarshalAs(UnmanagedType.LPWStr)]
        internal string? TargetName;
        [MarshalAs(UnmanagedType.LPWStr)]
        internal string? Comment;
        internal long LastWritten;
        internal uint CredentialBlobSize;
        internal nint CredentialBlob;
        internal uint Persist;
        internal uint AttributeCount;
        internal nint Attributes;
        [MarshalAs(UnmanagedType.LPWStr)]
        internal string? TargetAlias;
        [MarshalAs(UnmanagedType.LPWStr)]
        internal string? UserName;
    }

    [DllImport(
        "advapi32.dll",
        EntryPoint = "CredWriteW",
        CharSet = CharSet.Unicode,
        ExactSpelling = true,
        SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredWriteW(ref NativeCredential credential, uint flags);

    [DllImport(
        "advapi32.dll",
        EntryPoint = "CredReadW",
        CharSet = CharSet.Unicode,
        ExactSpelling = true,
        SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredReadW(
        string targetName,
        uint type,
        uint flags,
        out nint credential);

    [DllImport(
        "advapi32.dll",
        EntryPoint = "CredDeleteW",
        CharSet = CharSet.Unicode,
        ExactSpelling = true,
        SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredDeleteW(string targetName, uint type, uint flags);

    [DllImport("advapi32.dll")]
    private static extern void CredFree(nint buffer);
}
