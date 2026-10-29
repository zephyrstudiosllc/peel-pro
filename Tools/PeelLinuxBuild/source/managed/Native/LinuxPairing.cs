using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Peel.Windows.Protocol;
using Peel.Windows.Transport;
namespace Peel.Linux;
internal static class LinuxPairing
{
    // Public discovery metadata only in args. The PIN is typed locally with no
    // echo; it is never accepted from argv/env/logs or stored. Uses the existing
    // PSK PIN derivation, identity and proof; no plaintext network fallback.
    internal static async Task<int> Run(string[] args)
    {
        if (args is not ["--pair", var address, var portText, var hostId, var saltText]
            || !int.TryParse(portText, out int port) || port is < 1 or > 65535 || string.IsNullOrWhiteSpace(hostId)
            || hostId.Length > 1024 || hostId.Any(char.IsControl) || string.IsNullOrWhiteSpace(address)
            || address.Length > 1024 || address.Any(char.IsControl) || address.Contains('/') || Console.IsInputRedirected)
        { Console.Error.WriteLine("Usage: peel-pro --pair ADDRESS PAIR_PORT HOST_ID ADVERTISED_BASE64_SALT (interactive terminal required)"); return 2; }
        byte[] key = Array.Empty<byte>(), salt = Array.Empty<byte>(); byte[]? received = null;
        PeelPskCredential? credential = null;
        try
        {
            salt = Convert.FromBase64String(saltText);
            if (salt.Length is < 1 or > 64 || Convert.ToBase64String(salt) != saltText) throw new InvalidDataException();
            Console.Write("Enter the six-digit PIN shown by Peel Pro on that computer: ");
            var digits = new StringBuilder(6);
            while (true)
            {
                var input = Console.ReadKey(intercept: true);
                if (input.Key == ConsoleKey.Enter) break;
                if (input.Key == ConsoleKey.Backspace) { if (digits.Length > 0) digits.Length--; continue; }
                if (input.KeyChar is >= '0' and <= '9' && digits.Length < 6) digits.Append(input.KeyChar);
            }
            Console.WriteLine();
            key = PeelPinPairing.DerivePreSharedKey(digits.ToString(), salt, hostId); digits.Clear();
            string deviceId = DeviceId();
            credential = new PeelPskCredential(PeelPinPairing.TlsIdentity, key);
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
            await using var stream = await new BouncyCastlePskTransportFactory().ConnectAsync(new DnsEndPoint(address, port), credential, timeout.Token);
            using var abortRead = timeout.Token.Register(stream.Dispose);
            var request = new PairRequestMessage(Environment.MachineName, deviceId, PeelPinPairing.CreateProof(key, hostId, deviceId));
            await stream.WriteAsync(PeelJson.SerializeLine(request), timeout.Token); await stream.FlushAsync(timeout.Token);
            using var response = new MemoryStream(); byte[] one = new byte[1];
            while (response.Length < 16_384)
            {
                if (await stream.ReadAsync(one, timeout.Token) == 0) throw new IOException();
                if (one[0] == 10) break;
                response.WriteByte(one[0]);
            }
            if (response.Length == 16_384) throw new InvalidDataException();
            var value = PeelJson.Deserialize<PairResponseMessage>(response.ToArray()); received = value.Psk;
            if (value.Type != PeelMessageType.PairResponse || !value.Accepted || string.IsNullOrWhiteSpace(value.PairingId)
                || Encoding.UTF8.GetByteCount(value.PairingId) > 1024 || value.PairingId.Any(char.IsControl) || received is not { Length: 32 }) throw new InvalidDataException();
            var secret = JsonSerializer.Serialize(new { stableHostId = hostId, pairingId = value.PairingId, preSharedKeyBase64 = Convert.ToBase64String(received) });
            if (NativeUI.peel_linux_secret_store(hostId, secret) != 1) throw new IOException("Secret Service did not save pairing.");
            Console.WriteLine("Pairing saved in Secret Service. Open Peel Pro and connect using this computer’s saved ID and normal streaming port."); return 0;
        }
        catch (Exception error) when (error is IOException or InvalidDataException or ArgumentException or OperationCanceledException or JsonException or InvalidOperationException)
        { Console.Error.WriteLine("Pairing failed or could not be saved. Check the displayed PIN, advertised metadata and Secret Service."); return 1; }
        finally
        {
            CryptographicOperations.ZeroMemory(key); CryptographicOperations.ZeroMemory(salt);
            if (received is not null) CryptographicOperations.ZeroMemory(received);
            if (credential is not null) CryptographicOperations.ZeroMemory(credential.PreSharedKey);
        }
    }
    private static string DeviceId()
    {
        if (!OperatingSystem.IsLinux()) throw new PlatformNotSupportedException();
        string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PeelPro");
        Directory.CreateDirectory(directory); File.SetUnixFileMode(directory, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        string path = Path.Combine(directory, "device-id");
        if (File.Exists(path)) {
            var info = new FileInfo(path); if (info.LinkTarget is not null || info.Length > 64) throw new IOException("Device identity unavailable.");
            string existing = File.ReadAllText(path); if (!Guid.TryParseExact(existing, "D", out _)) throw new IOException("Device identity unavailable."); return existing;
        }
        string value = Guid.NewGuid().ToString("D");
        using var file = new FileStream(path, new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write, UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite });
        file.Write(Encoding.UTF8.GetBytes(value)); file.Flush(flushToDisk: true); return value;
    }
}
