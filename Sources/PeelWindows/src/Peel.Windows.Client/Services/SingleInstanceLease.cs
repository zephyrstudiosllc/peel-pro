using System.IO;

namespace Peel.Windows.Client.Services;

internal sealed class SingleInstanceLease : IDisposable
{
    private const int ErrorSharingViolation = 32;
    private const int ErrorLockViolation = 33;

    private readonly string filePath;
    private FileStream? stream;

    private SingleInstanceLease(string filePath, FileStream stream)
    {
        this.filePath = filePath;
        this.stream = stream;
    }

    internal static SingleInstanceLease? TryAcquire(string? filePath = null)
    {
        filePath ??= DefaultFilePath();
        if (string.IsNullOrWhiteSpace(filePath))
        {
            throw new ArgumentException("A single-instance lease path is required.", nameof(filePath));
        }

        string? directory = Path.GetDirectoryName(filePath);
        if (string.IsNullOrEmpty(directory))
        {
            throw new ArgumentException(
                "The single-instance lease path must have a directory.",
                nameof(filePath));
        }

        Directory.CreateDirectory(directory);
        try
        {
            var leaseStream = new FileStream(
                filePath,
                FileMode.OpenOrCreate,
                FileAccess.ReadWrite,
                FileShare.None);
            return new SingleInstanceLease(filePath, leaseStream);
        }
        catch (IOException exception) when (IsSharingViolation(exception))
        {
            return null;
        }
    }

    public void Dispose()
    {
        FileStream? ownedStream = Interlocked.Exchange(ref stream, null);
        if (ownedStream is null)
        {
            return;
        }

        ownedStream.Dispose();
        try
        {
            File.Delete(filePath);
        }
        catch (IOException)
        {
            // A replacement process may already own the same persistent lease path.
        }
        catch (UnauthorizedAccessException)
        {
            // Releasing the handle is the ownership boundary; stale empty files are safe.
        }
    }

    private static bool IsSharingViolation(IOException exception)
    {
        int win32Error = exception.HResult & 0xFFFF;
        return win32Error is ErrorSharingViolation or ErrorLockViolation;
    }

    private static string DefaultFilePath() =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Zephyr Studios",
            "Peel",
            "app-instance.lock");
}
