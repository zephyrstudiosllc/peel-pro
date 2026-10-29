using System.Text;
using System.Text.Json;
namespace Peel.Linux.Host;
internal static class LinuxHostPersistence
{
    internal static LinuxHostTrust OpenDefault()
    {
        if (!OperatingSystem.IsLinux()) throw new PlatformNotSupportedException();
        string parent = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (!Path.IsPathFullyQualified(parent)) throw new IOException("A private local application directory is required.");
        string root = Path.Combine(parent, "PeelPro", "Host");
        NoLinks(root); Directory.CreateDirectory(root); NoLinks(root);
        File.SetUnixFileMode(root, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        string identityPath = Path.Combine(root, "host-id"), metadataPath = Path.Combine(root, "inbound-peers.json");
        NoLinks(identityPath);
        string hostId;
        if (File.Exists(identityPath))
        {
            if (new FileInfo(identityPath).Length > 64) throw new InvalidDataException("Host identity is invalid.");
            hostId = File.ReadAllText(identityPath);
            if (!Guid.TryParseExact(hostId, "D", out _)) throw new InvalidDataException("Host identity is invalid.");
        }
        else
        {
            hostId = Guid.NewGuid().ToString("D");
            using var f = new FileStream(identityPath, new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write,
                UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite });
            f.Write(Encoding.UTF8.GetBytes(hostId)); f.Flush(true);
        }
        NoLinks(metadataPath);
        IReadOnlyList<LinuxHostPeer> peers = [];
        if (File.Exists(metadataPath))
        {
            if (new FileInfo(metadataPath).Length > 16384) throw new InvalidDataException("Inbound metadata exceeds its limit.");
            byte[] bytes = File.ReadAllBytes(metadataPath);
            using var document = LinuxHostWire.Parse(bytes);
            if (document.RootElement.ValueKind != JsonValueKind.Array) throw new InvalidDataException();
            foreach (var row in document.RootElement.EnumerateArray()) LinuxHostWire.Exact(row, "PairingId", "DeviceId", "Name", "Revision", "KeySHA256");
            peers = JsonSerializer.Deserialize<LinuxHostPeer[]>(bytes) ?? throw new InvalidDataException();
        }
        return new(hostId, new LinuxHostSecretServiceVault(), peers, rows => Save(metadataPath, rows));
    }
    internal static LinuxHostServiceIdentity OpenServiceIdentity(string hostId,string currentComputerName)
    {
        if (!OperatingSystem.IsLinux()) throw new PlatformNotSupportedException();
        if (!Guid.TryParseExact(hostId,"D",out _) || !LinuxHostWire.Text(currentComputerName,256)) throw new InvalidDataException();
        string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"PeelPro","Host");
        string path = Path.Combine(root,"service-identity.json"); NoLinks(path);
        if (File.Exists(path))
        {
            if (new FileInfo(path).Length > 2048) throw new InvalidDataException();
            using var d = LinuxHostWire.Parse(File.ReadAllBytes(path)); var r = d.RootElement;
            LinuxHostWire.Exact(r,"schema","hostId","controlServiceName","pairServiceName");
            if (r.GetProperty("schema").GetInt32() != 1 || r.GetProperty("hostId").GetString() != hostId) throw new InvalidDataException();
            return LinuxHostServiceIdentity.Validate(currentComputerName,r.GetProperty("controlServiceName").GetString() ?? "",r.GetProperty("pairServiceName").GetString() ?? "");
        }
        string suffix = LinuxHostServiceIdentity.ShortName(currentComputerName,40);
        var identity = LinuxHostServiceIdentity.Validate(currentComputerName,"Peel Pro on " + suffix,"Peel Pair on " + suffix);
        byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(new { schema=1,hostId,controlServiceName=identity.ControlServiceName,pairServiceName=identity.PairServiceName });
        using var file = new FileStream(path,new FileStreamOptions { Mode=FileMode.CreateNew,Access=FileAccess.Write,UnixCreateMode=UnixFileMode.UserRead|UnixFileMode.UserWrite });
        file.Write(bytes); file.Flush(true); return identity;
    }
    private static void Save(string path, IReadOnlyList<LinuxHostPeer> rows)
    {
        if (!OperatingSystem.IsLinux()) throw new PlatformNotSupportedException();
        NoLinks(path); byte[] data = JsonSerializer.SerializeToUtf8Bytes(rows);
        if (data.Length > 16384) throw new InvalidDataException();
        string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var f = new FileStream(temporary, new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write,
                UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite })) { f.Write(data); f.Flush(true); }
            NoLinks(path); File.Move(temporary, path, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    private static void NoLinks(string path)
    {
        for (string? current = Path.GetFullPath(path); current is not null; current = Path.GetDirectoryName(current))
        {
            var info = new FileInfo(current);
            if (info.LinkTarget is not null) throw new IOException("Symlinked host storage is not supported.");
        }
    }
}
