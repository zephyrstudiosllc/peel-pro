using System.Text.Json.Serialization;

namespace Peel.Windows.Protocol;

[JsonConverter(typeof(PeelStringEnumConverter<CaptureMode>))]
public enum CaptureMode
{
    Isolated,
    Composited,
}

[JsonConverter(typeof(PeelStringEnumConverter<KeyboardCommand>))]
public enum KeyboardCommand
{
    Backspace,
    Delete,
    ForwardDelete,
    Enter,
    ReturnKey,
    Space,
    Tab,
    Escape,
    LeftArrow,
    RightArrow,
    UpArrow,
    DownArrow,
    Home,
    End,
    PageUp,
    PageDown,
    Command,
    Option,
    Control,
    Shift,
    Function,
    F1,
    F2,
    F3,
    F4,
    F5,
    F6,
    F7,
    F8,
    F9,
    F10,
    F11,
    F12,
}

[JsonConverter(typeof(PeelStringEnumConverter<KeyboardCommandAction>))]
public enum KeyboardCommandAction
{
    Press,
    Down,
    Up,
}

[JsonConverter(typeof(PeelStringEnumConverter<HostCommandKind>))]
public enum HostCommandKind
{
    OpenLauncherFolder,
    OpenPath,
    CloseWindow,
    MinimizeWindow,
    SwitchSpaceLeft,
    SwitchSpaceRight,
}

[JsonConverter(typeof(PeelStringEnumConverter<KeyboardMacroStepKind>))]
public enum KeyboardMacroStepKind
{
    Chord,
    Key,
    Text,
    DelayMilliseconds,
}

public sealed record MessageEnvelope(
    [property: JsonPropertyName("type")] string Type);

public sealed record PeelWindow(
    [property: JsonPropertyName("windowId")] uint WindowId,
    [property: JsonPropertyName("appName")] string AppName,
    [property: JsonPropertyName("title")] string Title,
    [property: JsonPropertyName("width")] int Width,
    [property: JsonPropertyName("height")] int Height,
    [property: JsonPropertyName("statusSummary")] string? StatusSummary = null,
    [property: JsonPropertyName("appIconPNGBase64")] string? AppIconPngBase64 = null,
    [property: JsonPropertyName("appLaunchTimeIntervalSince1970")] double? AppLaunchTimeIntervalSince1970 = null);

public sealed record PeelRequest(
    [property: JsonPropertyName("type")] string Type,
    [property: JsonPropertyName("windowId")] uint? WindowId = null,
    [property: JsonPropertyName("normX")] double? NormX = null,
    [property: JsonPropertyName("normY")] double? NormY = null,
    [property: JsonPropertyName("button")] string? Button = null);

public sealed record WindowListMessage(
    [property: JsonPropertyName("windows")] IReadOnlyList<PeelWindow> Windows,
    [property: JsonPropertyName("type")] string Type = PeelMessageType.WindowList);

public sealed record WindowFrameMessage(
    [property: JsonPropertyName("windowId")] uint WindowId,
    [property: JsonPropertyName("jpegBase64")] string JpegBase64,
    [property: JsonPropertyName("type")] string Type = PeelMessageType.WindowFrame);

public sealed record ClientActiveWindowMessage(
    [property: JsonPropertyName("windowId")] uint WindowId,
    [property: JsonPropertyName("type")] string Type = PeelMessageType.ClientActiveWindow,
    [property: JsonPropertyName("focusRequestId"), JsonConverter(typeof(FocusRequestIdJsonConverter))] string? FocusRequestId = null);

public sealed record ClientWindowActivityMessage(
    [property: JsonPropertyName("windowId")] uint WindowId,
    [property: JsonPropertyName("isActive")] bool IsActive,
    [property: JsonPropertyName("type")] string Type = PeelMessageType.ClientWindowActivity);

public sealed record ClientWindowLoadMessage(
    [property: JsonPropertyName("openWindowCount")] int OpenWindowCount,
    [property: JsonPropertyName("activeWindowCount")] int? ActiveWindowCount = null,
    [property: JsonPropertyName("type")] string Type = PeelMessageType.ClientWindowLoad);

public sealed record SetCaptureModeMessage(
    [property: JsonPropertyName("windowId")] uint WindowId,
    [property: JsonPropertyName("captureMode")] CaptureMode CaptureMode,
    [property: JsonPropertyName("type")] string Type = PeelMessageType.SetCaptureMode);

public sealed record KeyboardTextMessage(
    [property: JsonPropertyName("text")] string Text,
    [property: JsonPropertyName("windowId")] uint? WindowId = null,
    [property: JsonPropertyName("type")] string Type = PeelMessageType.KeyboardText);

public sealed record KeyboardCommandMessage(
    [property: JsonPropertyName("command")] KeyboardCommand Command,
    [property: JsonPropertyName("windowId")] uint? WindowId = null,
    [property: JsonPropertyName("modifiers")] IReadOnlyList<KeyboardCommand>? Modifiers = null,
    [property: JsonPropertyName("action")] KeyboardCommandAction? Action = null,
    [property: JsonPropertyName("type")] string Type = PeelMessageType.KeyboardCommand);

public sealed record KeyboardHardwareKeyMessage(
    [property: JsonPropertyName("keyCode")] int KeyCode,
    [property: JsonPropertyName("modifiers")] IReadOnlyList<KeyboardCommand> Modifiers,
    [property: JsonPropertyName("windowId")] uint? WindowId = null,
    [property: JsonPropertyName("characters")] string? Characters = null,
    [property: JsonPropertyName("charactersIgnoringModifiers")] string? CharactersIgnoringModifiers = null,
    [property: JsonPropertyName("action")] KeyboardCommandAction? Action = null,
    [property: JsonPropertyName("type")] string Type = PeelMessageType.KeyboardHardwareKey);

public sealed record KeyboardChord(
    [property: JsonPropertyName("keys")] IReadOnlyList<KeyboardCommand> Keys);

public sealed record KeyboardChordMessage(
    [property: JsonPropertyName("chord")] KeyboardChord Chord,
    [property: JsonPropertyName("windowId")] uint? WindowId = null,
    [property: JsonPropertyName("type")] string Type = PeelMessageType.KeyboardChord);

public sealed record KeyboardMacroStep(
    [property: JsonPropertyName("kind")] KeyboardMacroStepKind Kind,
    [property: JsonPropertyName("chord")] KeyboardChord? Chord = null,
    [property: JsonPropertyName("key")] KeyboardCommandMessage? Key = null,
    [property: JsonPropertyName("text")] string? Text = null,
    [property: JsonPropertyName("delayMilliseconds")] int? DelayMilliseconds = null)
{
    public static KeyboardMacroStep ForChord(KeyboardChord chord) =>
        new(KeyboardMacroStepKind.Chord, Chord: chord);

    public static KeyboardMacroStep ForKey(KeyboardCommandMessage key) =>
        new(KeyboardMacroStepKind.Key, Key: key);

    public static KeyboardMacroStep ForText(string text) =>
        new(KeyboardMacroStepKind.Text, Text: text);

    public static KeyboardMacroStep ForDelay(int milliseconds) =>
        new(KeyboardMacroStepKind.DelayMilliseconds, DelayMilliseconds: milliseconds);
}

public sealed record KeyboardMacroMessage(
    [property: JsonPropertyName("steps")] IReadOnlyList<KeyboardMacroStep> Steps,
    [property: JsonPropertyName("windowId")] uint? WindowId = null,
    [property: JsonPropertyName("executeAtomically")] bool? ExecuteAtomically = null,
    [property: JsonPropertyName("type")] string Type = PeelMessageType.KeyboardMacro);

public sealed record InputCapabilitiesMessage(
    [property: JsonPropertyName("supportsModifiers")] bool SupportsModifiers,
    [property: JsonPropertyName("supportsMacros")] bool SupportsMacros,
    [property: JsonPropertyName("supportsMouseButtons")] bool SupportsMouseButtons,
    [property: JsonPropertyName("supportsScroll")] bool SupportsScroll,
    [property: JsonPropertyName("supportsFunctionKeys")] bool SupportsFunctionKeys,
    [property: JsonPropertyName("type")] string Type = PeelMessageType.InputCapabilities);

public sealed record ClientVisibilityMessage(
    [property: JsonPropertyName("isVisible")] bool IsVisible,
    [property: JsonPropertyName("type")] string Type = PeelMessageType.ClientVisibility);

public sealed record ClientPingMessage(
    [property: JsonPropertyName("type")] string Type = PeelMessageType.ClientPing);

public sealed record HostCommandMessage(
    [property: JsonPropertyName("command")] HostCommandKind Command,
    [property: JsonPropertyName("path")] string? Path = null,
    [property: JsonPropertyName("windowId")] uint? WindowId = null,
    [property: JsonPropertyName("type")] string Type = PeelMessageType.HostCommand);

public sealed record ClipboardTextMessage(
    [property: JsonPropertyName("text")] string Text,
    [property: JsonPropertyName("type")] string Type = PeelMessageType.ClipboardText);

public sealed record InputRejectedMessage(
    [property: JsonPropertyName("windowId")] uint WindowId,
    [property: JsonPropertyName("reason")] string Reason,
    [property: JsonPropertyName("timestamp")] DateTimeOffset Timestamp,
    [property: JsonPropertyName("type")] string Type = PeelMessageType.InputRejected);

public sealed record PairRequestMessage(
    [property: JsonPropertyName("clientName")] string ClientName,
    [property: JsonPropertyName("clientDeviceId")] string ClientDeviceId,
    [property: JsonPropertyName("pinProof")] string? PinProof = null,
    [property: JsonPropertyName("type")] string Type = PeelMessageType.PairRequest);

public sealed record PairResponseMessage(
    [property: JsonPropertyName("hostName")] string HostName,
    [property: JsonPropertyName("serviceName")] string ServiceName,
    [property: JsonPropertyName("pairingId")] string PairingId,
    [property: JsonPropertyName("psk")] byte[] Psk,
    [property: JsonPropertyName("accepted")] bool Accepted,
    [property: JsonPropertyName("reason")] string? Reason = null,
    [property: JsonPropertyName("type")] string Type = PeelMessageType.PairResponse);

public sealed record PairingRevokedMessage(
    [property: JsonPropertyName("pairingId")] string PairingId,
    [property: JsonPropertyName("deviceId")] string? DeviceId = null,
    [property: JsonPropertyName("reason")] string? Reason = null,
    [property: JsonPropertyName("type")] string Type = PeelMessageType.PairingRevoked);

public sealed record WindowGeometryMessage(
    [property: JsonPropertyName("windowId")] uint WindowId,
    [property: JsonPropertyName("boundsX")] double BoundsX,
    [property: JsonPropertyName("boundsY")] double BoundsY,
    [property: JsonPropertyName("boundsW")] double BoundsW,
    [property: JsonPropertyName("boundsH")] double BoundsH,
    [property: JsonPropertyName("insetX")] double InsetX,
    [property: JsonPropertyName("insetY")] double InsetY,
    [property: JsonPropertyName("capturePxW")] int? CapturePxW = null,
    [property: JsonPropertyName("capturePxH")] int? CapturePxH = null,
    [property: JsonPropertyName("origin")] string Origin = "topLeft",
    [property: JsonPropertyName("type")] string Type = PeelMessageType.WindowGeometry);

public sealed record WindowFocusStateMessage(
    [property: JsonPropertyName("activeWindowId")] uint? ActiveWindowId,
    [property: JsonPropertyName("requestedWindowId")] uint? RequestedWindowId,
    [property: JsonPropertyName("didActivateRequestedWindow")] bool DidActivateRequestedWindow,
    [property: JsonPropertyName("type")] string Type = PeelMessageType.WindowFocusState,
    [property: JsonPropertyName("focusRequestId"), JsonConverter(typeof(FocusRequestIdJsonConverter))] string? FocusRequestId = null);

public sealed record HostStreamDebugMessage(
    [property: JsonPropertyName("windowId")] uint WindowId,
    [property: JsonPropertyName("stage")] string Stage,
    [property: JsonPropertyName("timestamp")] DateTimeOffset Timestamp,
    [property: JsonPropertyName("detail")] string? Detail = null,
    [property: JsonPropertyName("type")] string Type = PeelMessageType.HostStreamDebug);

public sealed record ClientHelloMessage(
    [property: JsonPropertyName("pairingID")] string? PairingId,
    [property: JsonPropertyName("deviceName")] string DeviceName,
    [property: JsonPropertyName("platform")] string Platform,
    [property: JsonPropertyName("deviceModel")] string? DeviceModel = null,
    [property: JsonPropertyName("osVersion")] string? OsVersion = null,
    [property: JsonPropertyName("appVersion")] string? AppVersion = null,
    [property: JsonPropertyName("protocolVersion")] int? ProtocolVersion = null,
    [property: JsonPropertyName("minimumSupportedProtocolVersion")] int? MinimumSupportedProtocolVersion = null,
    [property: JsonPropertyName("capabilities")] IReadOnlyList<string>? Capabilities = null,
    [property: JsonPropertyName("type")] string Type = PeelMessageType.ClientHello);

public sealed record HostHelloMessage(
    [property: JsonPropertyName("hostName")] string HostName,
    [property: JsonPropertyName("platform")] string Platform = "Windows",
    [property: JsonPropertyName("osVersion")] string? OsVersion = null,
    [property: JsonPropertyName("appVersion")] string? AppVersion = null,
    [property: JsonPropertyName("protocolVersion")] int? ProtocolVersion = null,
    [property: JsonPropertyName("minimumSupportedProtocolVersion")] int? MinimumSupportedProtocolVersion = null,
    [property: JsonPropertyName("capabilities")] IReadOnlyList<string>? Capabilities = null,
    [property: JsonPropertyName("type")] string Type = PeelMessageType.HostHello);

public sealed record ProtocolRejectedMessage(
    [property: JsonPropertyName("reason")] string Reason,
    [property: JsonPropertyName("localProtocolVersion")] int LocalProtocolVersion,
    [property: JsonPropertyName("localMinimumSupportedProtocolVersion")] int LocalMinimumSupportedProtocolVersion,
    [property: JsonPropertyName("remoteProtocolVersion")] int? RemoteProtocolVersion,
    [property: JsonPropertyName("remoteMinimumSupportedProtocolVersion")] int? RemoteMinimumSupportedProtocolVersion,
    [property: JsonPropertyName("type")] string Type = PeelMessageType.ProtocolRejected)
{
    public static ProtocolRejectedMessage Create(
        string reason,
        int? remoteProtocolVersion,
        int? remoteMinimumSupportedProtocolVersion) =>
        new(
            reason,
            PeelProtocol.CurrentProtocolVersion,
            PeelProtocol.MinimumSupportedProtocolVersion,
            remoteProtocolVersion,
            remoteMinimumSupportedProtocolVersion);
}

public sealed record VideoStreamHelloMessage(
    [property: JsonPropertyName("windowId")] uint WindowId,
    [property: JsonPropertyName("protocolVersion")] int ProtocolVersion,
    [property: JsonPropertyName("minimumSupportedProtocolVersion")] int MinimumSupportedProtocolVersion,
    [property: JsonPropertyName("pairingID")] string? PairingId = null,
    [property: JsonPropertyName("capabilities")] IReadOnlyList<string>? Capabilities = null,
    [property: JsonPropertyName("type")] string Type = PeelMessageType.VideoStreamHello);

public static class PeelHello
{
    public static IReadOnlyList<string> SortedCapabilities(IEnumerable<string> capabilities) =>
        capabilities.Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray();

    public static ClientHelloMessage CreateClient(
        string? pairingId,
        string deviceName,
        string platform,
        string? deviceModel = null,
        string? osVersion = null,
        string? appVersion = null,
        IEnumerable<string>? capabilities = null) =>
        new(
            pairingId,
            deviceName,
            platform,
            deviceModel,
            osVersion,
            appVersion,
            PeelProtocol.CurrentProtocolVersion,
            PeelProtocol.MinimumSupportedProtocolVersion,
            SortedCapabilities(capabilities ?? []));

    public static HostHelloMessage CreateHost(
        string hostName,
        string platform = "Windows",
        string? osVersion = null,
        string? appVersion = null,
        IEnumerable<string>? capabilities = null) =>
        new(
            hostName,
            platform,
            osVersion,
            appVersion,
            PeelProtocol.CurrentProtocolVersion,
            PeelProtocol.MinimumSupportedProtocolVersion,
            SortedCapabilities(capabilities ?? []));

    public static VideoStreamHelloMessage CreateVideoStream(
        uint windowId,
        string? pairingId = null,
        IEnumerable<string>? capabilities = null) =>
        new(
            windowId,
            PeelProtocol.CurrentProtocolVersion,
            PeelProtocol.MinimumSupportedProtocolVersion,
            pairingId,
            SortedCapabilities(capabilities ?? []));
}
