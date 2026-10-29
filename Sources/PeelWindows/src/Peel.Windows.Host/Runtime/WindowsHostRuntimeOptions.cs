using System.Net;
using Peel.Windows.Host.Encoding;

namespace Peel.Windows.Host.Runtime;

public sealed class WindowsHostRuntimeOptions
{
    public Peel.Windows.Host.Audio.HostAudioSharing? AudioSharing { get; init; }
    public Peel.Windows.Host.Networking.IHostMachineStatusProvider? MachineStatusProvider { get; init; }
    public const int DefaultFramesPerSecond = 30;
    public const int DefaultTargetBitrate = 4_000_000;

    public WindowsHostRuntimeOptions(
        string? hostName = null,
        string? appVersion = null,
        IPAddress? listenAddress = null,
        int controlPort = 0,
        int pairingPort = 0,
        int framesPerSecond = DefaultFramesPerSecond,
        int targetBitrate = DefaultTargetBitrate,
        bool enableHevc = false,
        bool hardwareEncoding = false)
    {
        string boundedHostName = (hostName ?? Environment.MachineName).Trim();
        if (boundedHostName.Length is 0 or > 256 || boundedHostName.IndexOf('\0') >= 0)
        {
            throw new ArgumentException(
                "A non-empty Host name of at most 256 UTF-16 code units is required.",
                nameof(hostName));
        }

        if (appVersion is { Length: > 256 } || appVersion?.IndexOf('\0') >= 0)
        {
            throw new ArgumentException(
                "The application version exceeds its bounded text format.",
                nameof(appVersion));
        }

        ValidatePort(controlPort, nameof(controlPort));
        ValidatePort(pairingPort, nameof(pairingPort));
        if (framesPerSecond is < 1 or > 240)
        {
            throw new ArgumentOutOfRangeException(nameof(framesPerSecond));
        }

        if (targetBitrate <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(targetBitrate));
        }

        HostName = boundedHostName;
        ServiceName = $"Peel on {boundedHostName}";
        PairingServiceName = $"Peel Pair on {boundedHostName}";
        AppVersion = string.IsNullOrWhiteSpace(appVersion) ? null : appVersion.Trim();
        ListenAddress = listenAddress ?? IPAddress.IPv6Any;
        ControlPort = controlPort;
        PairingPort = pairingPort;
        EnableHevc = enableHevc;
        VideoSettings = new VideoEncodingSettings(
            VideoCodec.H264,
            1280,
            720,
            framesPerSecond,
            targetBitrate,
            hardwareEncoding);
    }

    public string HostName { get; }

    public string ServiceName { get; }

    public string PairingServiceName { get; }

    public string? AppVersion { get; }

    public IPAddress ListenAddress { get; }

    public int ControlPort { get; }

    public int PairingPort { get; }

    public VideoEncodingSettings VideoSettings { get; }
    public bool EnableHevc { get; }

    private static void ValidatePort(int value, string parameterName)
    {
        if (value is < IPEndPoint.MinPort or > IPEndPoint.MaxPort)
        {
            throw new ArgumentOutOfRangeException(parameterName);
        }
    }
}
