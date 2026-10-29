using System.Text;

namespace Peel.Windows.Host.Runtime;

public sealed class WindowsHostIdentityStore
{
    private const int MaximumHostIdCodeUnits = 1024;
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    private readonly string filePath;

    public WindowsHostIdentityStore(string? filePath = null)
    {
        this.filePath = filePath ?? DefaultFilePath();
        if (string.IsNullOrWhiteSpace(this.filePath))
        {
            throw new ArgumentException("A Host identity file path is required.", nameof(filePath));
        }
    }

    public string LoadOrCreate()
    {
        if (File.Exists(filePath))
        {
            return LoadExisting();
        }

        string? directory = Path.GetDirectoryName(filePath);
        if (!string.IsNullOrEmpty(directory))
        {
            Directory.CreateDirectory(directory);
        }

        string hostId = Guid.NewGuid().ToString().ToUpperInvariant();
        byte[] bytes = StrictUtf8.GetBytes(hostId);
        try
        {
            using var stream = new FileStream(
                filePath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.Read,
                bufferSize: 4096,
                FileOptions.WriteThrough);
            stream.Write(bytes);
            stream.Flush(flushToDisk: true);
            return hostId;
        }
        catch (IOException) when (File.Exists(filePath))
        {
            return LoadExisting();
        }
    }

    private string LoadExisting()
    {
        string hostId;
        try
        {
            hostId = File.ReadAllText(filePath, StrictUtf8).Trim();
        }
        catch (DecoderFallbackException exception)
        {
            throw new InvalidDataException("The persisted Host identity is not valid UTF-8.", exception);
        }

        if (hostId.Length is 0 or > MaximumHostIdCodeUnits || hostId.IndexOf('\0') >= 0)
        {
            throw new InvalidDataException(
                "The persisted Host identity is empty or exceeds its bounded text format.");
        }

        return hostId;
    }

    private static string DefaultFilePath() =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Zephyr Studios",
            "Peel",
            "Host",
            "host-id.txt");
}
