namespace Peel.Windows.Protocol;

public static class PeelProtocol
{
    public const int CurrentProtocolVersion = 2;
    public const int MinimumSupportedProtocolVersion = 2;

    // This is the capability set in the current Apple Host contract. An app must
    // advertise only the subset that its own runtime actually implements.
    public static IReadOnlySet<string> AppleHostCapabilities { get; } = new HashSet<string>(StringComparer.Ordinal)
    {
        PeelCapability.H264Video,
        PeelCapability.HevcVideo,
        PeelCapability.WindowGeometry,
        PeelCapability.HostCommands,
        PeelCapability.PairingRevocation,
        PeelCapability.ClientVisibility,
        PeelCapability.PerWindowVideoConnections,
        PeelCapability.BinaryVideoTransportV2,
        PeelCapability.ClientWindowLoad,
        PeelCapability.ClientWindowActivity,
        PeelCapability.ExpandedKeyboard,
        PeelCapability.KeyboardMacros,
        PeelCapability.HostPerformance,
        PeelCapability.StreamQualityHints,
        PeelCapability.WindowPriority,
        PeelCapability.InputCapabilities,
        PeelCapability.HostState,
        PeelCapability.ClientSessionLoad,
        PeelCapability.ClipboardSync,
        PeelCapability.InputFocus,
        PeelCapability.SpaceSwitching,
    };

    public static bool IsCompatible(
        int? remoteCurrent,
        int? remoteMinimum,
        int localCurrent = CurrentProtocolVersion,
        int localMinimum = MinimumSupportedProtocolVersion)
    {
        // Missing version fields mean protocol v1 in the Apple implementation.
        var peerCurrent = remoteCurrent ?? 1;
        var peerMinimum = remoteMinimum ?? 1;
        return peerCurrent >= localMinimum && localCurrent >= peerMinimum;
    }
}

public static class PeelCapability
{
    public const string H264Video = "h264-video";
    public const string HevcVideo = "hevc-video";
    public const string WindowGeometry = "window-geometry";
    public const string HostCommands = "host-commands";
    public const string PairingRevocation = "pairing-revocation";
    public const string ClientVisibility = "client-visibility";
    public const string PerWindowVideoConnections = "per-window-video-connections";
    public const string BinaryVideoTransportV2 = "binary-video-transport-v2";
    public const string ClientWindowLoad = "client-window-load";
    public const string ClientWindowActivity = "client-window-activity";
    public const string ExpandedKeyboard = "expanded-keyboard";
    public const string KeyboardMacros = "keyboard-macros";
    public const string HostPerformance = "host-performance";
    public const string StreamQualityHints = "stream-quality-hints";
    public const string WindowPriority = "window-priority";
    public const string InputCapabilities = "input-capabilities";
    public const string HostState = "host-state";
    public const string ClientSessionLoad = "client-session-load";
    public const string ClipboardSync = "clipboard-sync";
    public const string InputFocus = "input-focus";
    public const string SpaceSwitching = "space-switching";
    public const string DisconnectReason = "disconnect-reason";
    public const string SparkleHostUpdate = "sparkle-host-update";
}

public static class PeelMessageType
{
    public const string RequestWindowList = "requestWindowList";
    public const string StartStream = "startStream";
    public const string StopStream = "stopStream";
    public const string MouseClick = "mouseClick";
    public const string MouseMove = "mouseMove";
    public const string MouseScroll = "mouseScroll";
    public const string MouseDown = "mouseDown";
    public const string MouseDrag = "mouseDrag";
    public const string MouseUp = "mouseUp";
    public const string WindowList = "windowList";
    public const string WindowFrame = "windowFrame";
    public const string ClientActiveWindow = "clientActiveWindow";
    public const string ClientWindowActivity = "clientWindowActivity";
    public const string ClientWindowLoad = "clientWindowLoad";
    public const string SetCaptureMode = "setCaptureMode";
    public const string KeyboardText = "keyboardText";
    public const string KeyboardCommand = "keyboardCommand";
    public const string KeyboardHardwareKey = "keyboardHardwareKey";
    public const string KeyboardChord = "keyboardChord";
    public const string KeyboardMacro = "keyboardMacro";
    public const string InputCapabilities = "inputCapabilities";
    public const string ClientVisibility = "clientVisibility";
    public const string ClientPing = "clientPing";
    public const string HostCommand = "hostCommand";
    public const string ClipboardText = "clipboardText";
    public const string InputRejected = "inputRejected";
    public const string PairRequest = "pairRequest";
    public const string PairResponse = "pairResponse";
    public const string PairingRevoked = "pairingRevoked";
    public const string WindowGeometry = "windowGeometry";
    public const string WindowFocusState = "windowFocusState";
    public const string HostStreamDebug = "hostStreamDebug";
    public const string ClientHello = "clientHello";
    public const string HostHello = "hostHello";
    public const string ProtocolRejected = "protocolRejected";
    public const string VideoStreamHello = "videoStreamHello";
}
