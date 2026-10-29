//
//  PeelWindow.swift
//  Peel
//
//  Created by Zach on 1/18/26.
//


//
//  PeelSharedMessages.swift
//  Peel
//
//  Shared message types between the macOS host and the visionOS client.
//
import Foundation
import CryptoKit

#if os(iOS)
import UIKit
#endif

// MARK: - Peel Protocol Versioning

/*
 Peel protocol compatibility guide

 This file is shared between the macOS host and the visionOS client. The host and
 client can update separately, so Peel must not assume both apps are always from
 the same build.

 App version is not protocol version.

 App version:
 - User-facing release/build version.
 - Useful for UI, logs, and support.

 Protocol version:
 - The version of the wire contract between host and client.
 - Only changes when message meanings, required fields, binary packet formats,
   handshake behavior, pairing/auth behavior, or stream semantics change.

 Current rule:
 - Keep protocol changes additive whenever possible.
 - New Codable fields should usually be optional.
 - Do not rename or remove fields used by older builds.
 - Do not silently change the meaning of an existing message type.
 - If a change breaks old behavior, create a new message type or increment
   minimumSupportedProtocolVersion.

 How compatibility works:
 - `currentProtocolVersion` is what this build speaks.
 - `minimumSupportedProtocolVersion` is the oldest peer protocol this build can
   safely talk to.
 - Two peers are compatible when each peer's current protocol is at least the
   other peer's minimum supported protocol.

 Example:
 - Host current=2, minimum=1
 - Client current=1, minimum=1
 - Compatible.

 Example:
 - Host current=3, minimum=2
 - Client current=1, minimum=1
 - Not compatible. Client is too old.

 Capabilities:
 - Use capabilities for optional features.
 - Prefer checking `capabilities.contains(...)` over checking app versions.
 - Example: use "disconnect-reason" instead of "host version >= 1.1".

 When to bump currentProtocolVersion:
 - Binary packet layout changes.
 - Required message fields change.
 - Existing message behavior changes.
 - Stream startup/teardown contract changes.
 - Pairing/authentication contract changes.

 When to bump minimumSupportedProtocolVersion:
 - You intentionally drop support for older peers.
 - Supporting the old behavior would be unsafe, buggy, or too complex.

 Protocol v2 intentionally drops v1 because Peel moved video transport from
 mixed NDJSON/binary on one socket to per-window binary video sockets plus one
 JSON/control socket.
 */
enum PeelProtocol {
    static let currentProtocolVersion = 2
    static let minimumSupportedProtocolVersion = 2

    static let capabilities: Set<String> = [
        PeelCapability.h264Video.rawValue,
        PeelStreamClockReply.capability,
        PeelCapability.hevcVideo.rawValue,
        PeelCapability.windowGeometry.rawValue,
        PeelCapability.hostCommands.rawValue,
        PeelCapability.pairingRevocation.rawValue,
        PeelCapability.clientVisibility.rawValue,
        PeelCapability.perWindowVideoConnections.rawValue,
        PeelCapability.binaryVideoTransportV2.rawValue,
        PeelCapability.clientWindowLoad.rawValue,
        PeelCapability.clientWindowActivity.rawValue,
        PeelCapability.expandedKeyboard.rawValue,
        PeelCapability.keyboardMacros.rawValue,
        PeelCapability.hostPerformance.rawValue,
        PeelCapability.streamQualityHints.rawValue,
        PeelCapability.windowPriority.rawValue,
        PeelCapability.inputCapabilities.rawValue,
        PeelCapability.hostState.rawValue,
        PeelCapability.clientSessionLoad.rawValue,
        PeelCapability.clipboardSync.rawValue,
        PeelCapability.inputFocus.rawValue,
        PeelCapability.spaceSwitching.rawValue,
        PeelCapability.peeledWindowHostingModes.rawValue,
    ]

    /// Capabilities advertised by this client connection after local feature opt-in.
    /// The base set remains stable; platform support and explicit local opt-in
    /// add agent presentation only for clients with an active-scene router.
    static var advertisedClientCapabilities: Set<String> {
        var advertised = capabilities
        advertised.insert(PeelStreamClockReply.capability)
#if os(iOS) || os(visionOS)
        advertised.insert(PeelClientStreamMetricsMessage.capability)
#endif
        if PeelAgentPresentation.isOptedIn {
            advertised.insert(PeelCapability.agentPresentationV1.rawValue)
        }
        if PeelManualAgentControl.isOptedIn { advertised.insert(PeelManualAgentControl.capability) }
        return advertised
    }

    static func isCompatible(
        localCurrent: Int = currentProtocolVersion,
        localMinimum: Int = minimumSupportedProtocolVersion,
        remoteCurrent: Int?,
        remoteMinimum: Int?
    ) -> Bool {
        let peerCurrent = remoteCurrent ?? 1
        let peerMinimum = remoteMinimum ?? 1
        return peerCurrent >= localMinimum && localCurrent >= peerMinimum
    }
}

enum PeelCapability: String, Codable {
    case h264Video = "h264-video"
    case hevcVideo = "hevc-video"
    case windowGeometry = "window-geometry"
    case hostCommands = "host-commands"
    case pairingRevocation = "pairing-revocation"
    case clientVisibility = "client-visibility"
    case perWindowVideoConnections = "per-window-video-connections"
    case binaryVideoTransportV2 = "binary-video-transport-v2"
    case clientWindowLoad = "client-window-load"
    case clientWindowActivity = "client-window-activity"
    case expandedKeyboard = "expanded-keyboard"
    case keyboardMacros = "keyboard-macros"
    case hostPerformance = "host-performance"
    case streamQualityHints = "stream-quality-hints"
    case windowPriority = "window-priority"
    case inputCapabilities = "input-capabilities"
    case hostState = "host-state"
    case clientSessionLoad = "client-session-load"
    case clipboardSync = "clipboard-sync"
    case inputFocus = "input-focus"
    case spaceSwitching = "space-switching"
    case peeledWindowHostingModes = "peeled-window-hosting-modes"
    case agentPresentationV1 = "agent-presentation-v1"
    case macSystemAudioV1 = "mac-system-audio-v1"
    case remoteVoiceV1 = "remote-voice-v1"
    case machineStatusV1 = "machine-status-v1"
    case agentNotificationsV1 = "agent-notifications-v1"
    case videoKeyframeRequestV1 = "video-keyframe-request-v1"
    case disconnectReason = "disconnect-reason"
    case sparkleHostUpdate = "sparkle-host-update"
}

/// Verified StoreKit access is process-local and never inferred from pairing or
/// persisted as a Boolean. Development builds expose the unreleased preview.
nonisolated enum PeelAIFeatureAccess {
    static let didChangeNotification = Notification.Name("PeelAIFeatureAccessDidChange")
    private static let storage = Storage()

    private nonisolated final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var expiration: Date?
    }

    static var isDevelopmentPreview: Bool {
#if DEBUG
        true
#else
        false
#endif
    }

    static var isAllowed: Bool {
        if isDevelopmentPreview { return true }
        storage.lock.lock()
        let expiration = storage.expiration
        storage.lock.unlock()
        return expiration.map { $0 > Date() } ?? false
    }

    static func update(subscriptionExpiration: Date?) {
        storage.lock.lock()
        let changed = storage.expiration != subscriptionExpiration
        storage.expiration = subscriptionExpiration
        storage.lock.unlock()
        if changed { NotificationCenter.default.post(name: didChangeNotification, object: nil) }
    }
}

enum PeelAgentPresentation {
    static let optInDefaultsKey = "peel.ai.allowAgentPresentation"

#if os(iOS)
    // Ephemeral scene readiness, never persisted as user consent. The phone's
    // actual full-screen route must register before its capability is offered.
    static private(set) var isPhoneRouteRegistered = false

    static func setPhoneRouteRegistered(_ registered: Bool) {
        isPhoneRouteRegistered = registered
    }
#endif

    static var isOptedIn: Bool {
#if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .pad ||
                (UIDevice.current.userInterfaceIdiom == .phone && isPhoneRouteRegistered)
        else { return false }
        return PeelAIFeatureAccess.isAllowed && UserDefaults.standard.bool(forKey: optInDefaultsKey)
#elseif os(visionOS)
        return PeelAIFeatureAccess.isAllowed && UserDefaults.standard.bool(forKey: optInDefaultsKey)
#else
        return false
#endif
    }
}

enum PeelAgentNotifications {
    static let optInDefaultsKey = "peel.ai.allowAgentNotifications"
    static var isOptedIn: Bool {
#if os(iOS)
        (UIDevice.current.userInterfaceIdiom == .pad ||
            UIDevice.current.userInterfaceIdiom == .phone) &&
            PeelAIFeatureAccess.isAllowed && UserDefaults.standard.bool(forKey: optInDefaultsKey)
#elseif os(visionOS)
        PeelAIFeatureAccess.isAllowed && UserDefaults.standard.bool(forKey: optInDefaultsKey)
#else
        false
#endif
    }
}

nonisolated struct PeelVideoKeyframeRequestMessage: Codable {
    var type = "requestVideoKeyframe"
    let windowId: UInt32
}

nonisolated struct PeelAgentNotificationMessage: Codable {
    var type = "agentNotification"
    let requestId: String
    let pairingId: String
    let title: String
    let message: String
    let expiresAt: Double
}

nonisolated struct PeelAgentNotificationResultMessage: Codable {
    var type = "agentNotificationResult"
    let requestId: String
    let pairingId: String
    let status: String
}

/// How the host should capture a window.
enum CaptureMode: String, Codable {
    case isolated      // window only
    case composited    // include windows above (menus/popups)
}

/// Where the host should keep a Mac window while Peel is using it.
enum PeeledWindowHostingMode: String, Codable, Hashable {
    case inPlace
    case peelDisplay
    case restorePreviousMacContext
}

/// Basic description of a Mac window that Peel can stream.
struct PeelWindow: Codable, Identifiable, Hashable {
    let windowId: UInt32
    let appName: String
    let title: String
    let width: Int
    let height: Int
    let statusSummary: String?
    let appIconPNGBase64: String?
    let appLaunchTimeIntervalSince1970: TimeInterval?

    var id: UInt32 { windowId }

    static func == (lhs: PeelWindow, rhs: PeelWindow) -> Bool {
        lhs.windowId == rhs.windowId
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(windowId)
    }
}

/// Vision → Mac: generic request.
/// type:
///   - "requestWindowList"
///   - "startStream"
///   - "stopStream"
///   - "mouseClick"
struct PeelRequest: Codable {
    let type: String                 // e.g. "mouseClick", "mouseDown", "mouseDrag", "mouseUp"
    let windowId: UInt32?
    let normX: Double?
    let normY: Double?
    let button: String?              // "left" or "right" (optional)

    init(type: String,
         windowId: UInt32? = nil,
         normX: Double? = nil,
         normY: Double? = nil,
         button: String? = nil) {
        self.type = type
        self.windowId = windowId
        self.normX = normX
        self.normY = normY
        self.button = button
    }
}

/// Mac → Vision: list of windows.
struct WindowListMessage: Codable {
    let type: String
    let windows: [PeelWindow]

    init(windows: [PeelWindow]) {
        self.type = "windowList"
        self.windows = windows
    }
}

/// Mac → Vision: JPEG frame for a single window.
/// We use base64-encoded JPEG for better perf vs. PNG.
struct WindowFrameMessage: Codable {
    let type: String
    let windowId: UInt32
    let jpegBase64: String

    init(windowId: UInt32, jpegBase64: String) {
        self.type = "windowFrame"
        self.windowId = windowId
        self.jpegBase64 = jpegBase64
    }
}

/// A focus correlation ID is an opaque, strictly bounded D36 UUID string.
/// Preserve its original spelling so every host can echo the actual request.
enum PeelFocusRequestID {
    static func isValid(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 36 else { return false }
        for (index, byte) in bytes.enumerated() {
            if index == 8 || index == 13 || index == 18 || index == 23 {
                guard byte == 45 else { return false }
            } else {
                guard (48...57).contains(byte) || (65...70).contains(byte) ||
                        (97...102).contains(byte) else { return false }
            }
        }
        return true
    }

    static func decode<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>, forKey key: Key
    ) throws -> String? {
        let value = try container.decodeIfPresent(String.self, forKey: key)
        if let value, !isValid(value) {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: container, debugDescription: "Invalid focus request ID"
            )
        }
        return value
    }
}

/// Legacy client-to-host hint that a single client window became active.
///
/// New clients should send `ClientWindowActivityMessage` so the host can also
/// throttle or pause windows that are no longer visible/active.
struct ClientActiveWindowMessage: Codable {
    let type: String
    let windowId: UInt32
    let focusRequestId: String?

    init(windowId: UInt32, focusRequestId: String? = nil) {
        self.type = "clientActiveWindow"
        self.windowId = windowId
        self.focusRequestId = focusRequestId
    }

    private enum CodingKeys: String, CodingKey { case type, windowId, focusRequestId }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        windowId = try container.decode(UInt32.self, forKey: .windowId)
        focusRequestId = try PeelFocusRequestID.decode(from: container, forKey: .focusRequestId)
    }
}

/// Client → Host: tells the host whether a streamed window is actively visible/important on the client.
///
/// This is intentionally separate from `startStream` / `stopStream`. A window may
/// still exist and keep its video connection warm while the host temporarily
/// throttles or pauses capture for inactive client windows.
struct ClientWindowActivityMessage: Codable {
    let type: String
    let windowId: UInt32
    let isActive: Bool

    init(windowId: UInt32, isActive: Bool) {
        self.type = "clientWindowActivity"
        self.windowId = windowId
        self.isActive = isActive
    }
}

/// Client → Host: selects the opt-in placement behavior for one peeled window.
///
/// Peers that do not advertise `peeled-window-hosting-modes` keep the existing
/// in-place behavior and never receive this message.
struct SetPeeledWindowHostingModeMessage: Codable {
    let type: String
    let windowId: UInt32
    let mode: PeeledWindowHostingMode

    init(windowId: UInt32, mode: PeeledWindowHostingMode) {
        self.type = "setPeeledWindowHostingMode"
        self.windowId = windowId
        self.mode = mode
    }
}

/// Client → Host: tells the host how much window work this client currently has open.
///
/// The host can use this as a coarse stream-pressure hint. For example, if the
/// client has many windows open across multiple hosts, each host can reduce
/// inactive-window frame rate/bitrate instead of assuming it should stream every
/// requested window at full quality.
struct ClientWindowLoadMessage: Codable {
    let type: String
    let openWindowCount: Int
    let activeWindowCount: Int?

    init(openWindowCount: Int, activeWindowCount: Int? = nil) {
        self.type = "clientWindowLoad"
        self.openWindowCount = openWindowCount
        self.activeWindowCount = activeWindowCount
    }
}

/// Client-to-host request to change capture mode for a specific window.
/// Default is `.composited`.
struct SetCaptureModeMessage: Codable {
    let type: String
    let windowId: UInt32
    let captureMode: CaptureMode

    init(windowId: UInt32, captureMode: CaptureMode) {
        self.type = "setCaptureMode"
        self.windowId = windowId
        self.captureMode = captureMode
    }
}

/// Commands for non-text keys we care about (backspace, enter, arrows, modifiers, function keys, etc.)
enum KeyboardCommand: String, Codable {
    case backspace
    case delete
    case forwardDelete

    case enter
    case returnKey
    case space
    case tab
    case escape

    case leftArrow
    case rightArrow
    case upArrow
    case downArrow

    case home
    case end
    case pageUp
    case pageDown

    case command
    case option
    case control
    case shift
    case function

    case f1
    case f2
    case f3
    case f4
    case f5
    case f6
    case f7
    case f8
    case f9
    case f10
    case f11
    case f12
}

/// How the host should apply a keyboard command.
enum KeyboardCommandAction: String, Codable {
    case press
    case down
    case up
}

/// Text typed on the client that should be injected on the Mac.
struct KeyboardTextMessage: Codable {
    let type: String
    let windowId: UInt32?
    let text: String

    init(text: String, windowId: UInt32? = nil) {
        self.type = "keyboardText"
        self.windowId = windowId
        self.text = text
    }
}

/// Non-text key events from the client (backspace, arrows, modifiers, function keys, etc.)
struct KeyboardCommandMessage: Codable {
    let type: String
    let windowId: UInt32?
    let command: KeyboardCommand
    let modifiers: [KeyboardCommand]?
    let action: KeyboardCommandAction?

    init(
        command: KeyboardCommand,
        windowId: UInt32? = nil,
        modifiers: [KeyboardCommand]? = nil,
        action: KeyboardCommandAction? = nil
    ) {
        self.type = "keyboardCommand"
        self.windowId = windowId
        self.command = command
        self.modifiers = modifiers
        self.action = action
    }
}

/// Physical/external keyboard key event from the client.
///
/// This is intentionally separate from `KeyboardTextMessage` and `KeyboardCommandMessage`:
/// - `KeyboardTextMessage` is committed text insertion.
/// - `KeyboardCommandMessage` is named non-text controls.
/// - `KeyboardHardwareKeyMessage` preserves a real external/MVD key press plus modifiers
///   so shortcuts like Command-C, Command-Shift-5, and Option-Arrow can be forwarded.
struct KeyboardHardwareKeyMessage: Codable {
    let type: String
    let windowId: UInt32?
    let keyCode: Int
    let characters: String?
    let charactersIgnoringModifiers: String?
    let modifiers: [KeyboardCommand]
    let action: KeyboardCommandAction?

    init(
        windowId: UInt32? = nil,
        keyCode: Int,
        characters: String? = nil,
        charactersIgnoringModifiers: String? = nil,
        modifiers: [KeyboardCommand],
        action: KeyboardCommandAction? = nil
    ) {
        self.type = "keyboardHardwareKey"
        self.windowId = windowId
        self.keyCode = keyCode
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
        self.modifiers = modifiers
        self.action = action
    }
}

/// A set of keys that should be treated as one held-together shortcut/chord.
///
/// Example: `.command + .shift + .f4` should be sent as one chord, not as three
/// independent key presses.
struct KeyboardChord: Codable {
    let keys: [KeyboardCommand]

    init(keys: [KeyboardCommand]) {
        self.keys = keys
    }
}

/// Client → Host: one instant keyboard chord/shortcut.
struct KeyboardChordMessage: Codable {
    let type: String
    let windowId: UInt32?
    let chord: KeyboardChord

    init(windowId: UInt32? = nil, chord: KeyboardChord) {
        self.type = "keyboardChord"
        self.windowId = windowId
        self.chord = chord
    }
}

/// One step in a client-defined keyboard macro.
enum KeyboardMacroStep: Codable {
    case chord(KeyboardChord)
    case key(KeyboardCommandMessage)
    case text(String)
    case delayMilliseconds(Int)

    private enum CodingKeys: String, CodingKey {
        case kind
        case chord
        case key
        case text
        case delayMilliseconds
    }

    private enum Kind: String, Codable {
        case chord
        case key
        case text
        case delayMilliseconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)

        switch kind {
        case .chord:
            self = .chord(try container.decode(KeyboardChord.self, forKey: .chord))
        case .key:
            self = .key(try container.decode(KeyboardCommandMessage.self, forKey: .key))
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        case .delayMilliseconds:
            self = .delayMilliseconds(try container.decode(Int.self, forKey: .delayMilliseconds))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .chord(let chord):
            try container.encode(Kind.chord, forKey: .kind)
            try container.encode(chord, forKey: .chord)
        case .key(let message):
            try container.encode(Kind.key, forKey: .kind)
            try container.encode(message, forKey: .key)
        case .text(let text):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(text, forKey: .text)
        case .delayMilliseconds(let milliseconds):
            try container.encode(Kind.delayMilliseconds, forKey: .kind)
            try container.encode(milliseconds, forKey: .delayMilliseconds)
        }
    }
}

/// Client → Host: ordered keyboard/text/delay/chord steps for shortcuts and small macros.
///
/// If `executeAtomically` is true, the host should treat this as a single burst of
/// input and avoid interleaving other input while it is executing. Chord steps are
/// still the right way to express keys that must be held at the same time.
struct KeyboardMacroMessage: Codable {
    let type: String
    let windowId: UInt32?
    let steps: [KeyboardMacroStep]
    let executeAtomically: Bool?

    init(windowId: UInt32? = nil, steps: [KeyboardMacroStep], executeAtomically: Bool? = nil) {
        self.type = "keyboardMacro"
        self.windowId = windowId
        self.steps = steps
        self.executeAtomically = executeAtomically
    }
}

/// Either side → other side: explicit input feature support.
///
/// This is useful when app/protocol versions are compatible but a specific input
/// feature should be hidden or disabled in UI.
struct InputCapabilitiesMessage: Codable {
    let type: String
    let supportsModifiers: Bool
    let supportsMacros: Bool
    let supportsMouseButtons: Bool
    let supportsScroll: Bool
    let supportsFunctionKeys: Bool

    init(
        supportsModifiers: Bool,
        supportsMacros: Bool,
        supportsMouseButtons: Bool,
        supportsScroll: Bool,
        supportsFunctionKeys: Bool
    ) {
        self.type = "inputCapabilities"
        self.supportsModifiers = supportsModifiers
        self.supportsMacros = supportsMacros
        self.supportsMouseButtons = supportsMouseButtons
        self.supportsScroll = supportsScroll
        self.supportsFunctionKeys = supportsFunctionKeys
    }
}

/// Client → Host: tells the host whether the client is currently able to show content (unlocked/foreground).
struct ClientVisibilityMessage: Codable {
    let type: String
    let isVisible: Bool

    init(isVisible: Bool) {
        self.type = "clientVisibility"
        self.isVisible = isVisible
    }
}

/// Client → Host: lightweight keepalive so host can auto-suspend if the client goes silent.
struct ClientPingMessage: Codable {
    let type: String
    let streamClockProbe: PeelStreamClockProbe?

    init(streamClockProbe: PeelStreamClockProbe? = nil) {
        self.type = "clientPing"
        self.streamClockProbe = streamClockProbe
    }
}

/// Semantic commands sent from client to host for host-level actions.
enum HostCommandKind: String, Codable {
    case openLauncherFolder
    case openPath
    case closeWindow
    case minimizeWindow
    case switchSpaceLeft
    case switchSpaceRight
}

/// Client → Host: semantic host-level command channel.
///
/// - `openLauncherFolder`: host opens its configured launcher folder.
/// - `openPath`: host opens the supplied file-system path.
/// - `closeWindow`: host closes the supplied window id.
/// - `switchSpaceLeft` / `switchSpaceRight`: host invokes the corresponding
///   configured Mission Control Space shortcut.
struct HostCommandMessage: Codable {
    let type: String
    let command: HostCommandKind
    let path: String?
    let windowId: UInt32?

    init(command: HostCommandKind,
         path: String? = nil,
         windowId: UInt32? = nil) {
        self.type = "hostCommand"
        self.command = command
        self.path = path
        self.windowId = windowId
    }
}

// MARK: - Clipboard

/// Either side → other side: simple text clipboard payload reserved for future clipboard sync.
///
/// This is intentionally text-only for now. Rich clipboard formats can be added
/// later with new optional fields or a new message type.
struct ClipboardTextMessage: Codable {
    let type: String
    let text: String

    init(text: String) {
        self.type = "clipboardText"
        self.text = text
    }
}

public struct MessageEnvelope: Codable {
    public let type: String
}

// MARK: - InputRejectedMessage

/// Sent by the host when it refuses to execute an input event (fail-closed).
struct InputRejectedMessage: Codable {
    let type: String
    let windowId: UInt32
    let reason: String
    let timestamp: Date

    init(windowId: UInt32, reason: String, timestamp: Date = Date()) {
        self.type = "inputRejected"
        self.windowId = windowId
        self.reason = reason
        self.timestamp = timestamp
    }
}

// MARK: - Pairing

/// Client → Host (pairing port): asks to pair and identifies itself.
/// `pinProof` is an app-layer proof that the client derived this request from the currently displayed 6-digit PIN.
struct PairRequestMessage: Codable {
    let type: String
    let clientName: String
    let clientDeviceId: String   // stable-ish UUID stored on client
    let pinProof: String?

    init(clientName: String, clientDeviceId: String, pinProof: String? = nil) {
        self.type = "pairRequest"
        self.clientName = clientName
        self.clientDeviceId = clientDeviceId
        self.pinProof = pinProof
    }
}

/// Host → Client (pairing port): pairing material.
struct PairResponseMessage: Codable {
    let type: String
    let hostName: String
    let serviceName: String
    let pairingId: String
    let psk: Data   // base64 in JSON automatically
    let accepted: Bool
    let reason: String?

    init(hostName: String, serviceName: String, pairingId: String, psk: Data, accepted: Bool, reason: String? = nil) {
        self.type = "pairResponse"
        self.hostName = hostName
        self.serviceName = serviceName
        self.pairingId = pairingId
        self.psk = psk
        self.accepted = accepted
        self.reason = reason
    }
}

/// Either side → other side: tells the peer this pairing was removed and should no longer be trusted.
struct PairingRevokedMessage: Codable {
    let type: String
    let pairingId: String
    let deviceId: String?
    let reason: String?
    
    init(pairingId: String, deviceId: String? = nil, reason: String? = nil) {
        self.type = "pairingRevoked"
        self.pairingId = pairingId
        self.deviceId = deviceId
        self.reason = reason
    }
}

struct WindowGeometryMessage: Codable {
    let type: String              // "windowGeometry"
    let windowId: UInt32

    // Window bounds in Mac global screen space (host authoritative)
    let boundsX: Double
    let boundsY: Double
    let boundsW: Double
    let boundsH: Double

    // Captured content inset inside those bounds (because of .boundsIgnoreFraming)
    // If you don’t want to deal with it yet, send zeros.
    let insetX: Double
    let insetY: Double

    // Optional debug info (actual captured frame size you sent)
    let capturePxW: Int?
    let capturePxH: Int?

    // Make the protocol explicit so nobody “helpfully flips Y” later.
    let origin: String            // "topLeft" (recommended) or "bottomLeft"

    init(windowId: UInt32,
         bounds: CGRect,
         inset: CGSize,
         capturePx: CGSize? = nil,
         origin: String = "topLeft") {
        self.type = "windowGeometry"
        self.windowId = windowId
        self.boundsX = Double(bounds.origin.x)
        self.boundsY = Double(bounds.origin.y)
        self.boundsW = Double(bounds.size.width)
        self.boundsH = Double(bounds.size.height)
        self.insetX = Double(inset.width)
        self.insetY = Double(inset.height)
        self.capturePxW = capturePx.map { Int($0.width) }
        self.capturePxH = capturePx.map { Int($0.height) }
        self.origin = origin
    }
}

struct WindowFocusStateMessage: Codable {
    let type: String
    let activeWindowId: UInt32?
    let requestedWindowId: UInt32?
    let didActivateRequestedWindow: Bool
    let focusRequestId: String?

    init(
        activeWindowId: UInt32?,
        requestedWindowId: UInt32?,
        didActivateRequestedWindow: Bool,
        focusRequestId: String? = nil
    ) {
        self.type = "windowFocusState"
        self.activeWindowId = activeWindowId
        self.requestedWindowId = requestedWindowId
        self.didActivateRequestedWindow = didActivateRequestedWindow
        self.focusRequestId = focusRequestId
    }

    private enum CodingKeys: String, CodingKey {
        case type, activeWindowId, requestedWindowId, didActivateRequestedWindow, focusRequestId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        activeWindowId = try container.decodeIfPresent(UInt32.self, forKey: .activeWindowId)
        requestedWindowId = try container.decodeIfPresent(UInt32.self, forKey: .requestedWindowId)
        didActivateRequestedWindow = try container.decode(Bool.self, forKey: .didActivateRequestedWindow)
        focusRequestId = try PeelFocusRequestID.decode(from: container, forKey: .focusRequestId)
    }
}

// MARK: - Host Stream Diagnostics

/// Host → Client: lightweight stream pipeline breadcrumbs used to diagnose where video startup stalls.
struct HostStreamDebugMessage: Codable {
    let type: String
    let windowId: UInt32
    let stage: String
    let detail: String?
    let timestamp: Date

    init(windowId: UInt32, stage: String, detail: String? = nil, timestamp: Date = Date()) {
        self.type = "hostStreamDebug"
        self.windowId = windowId
        self.stage = stage
        self.detail = detail
        self.timestamp = timestamp
    }
}

/// Client → Mac: identify the connected client device and protocol support.
struct ClientHelloMessage: Codable {
    let type: String
    let pairingID: String?
    let deviceName: String
    let deviceModel: String?
    let platform: String
    let osVersion: String?
    let appVersion: String?

    /// Wire protocol version this client currently speaks.
    let protocolVersion: Int?

    /// Oldest wire protocol version this client can safely talk to.
    let minimumSupportedProtocolVersion: Int?

    /// Optional feature flags supported by this client.
    let capabilities: [String]?

    init(pairingID: String?,
         deviceName: String,
         deviceModel: String? = nil,
         platform: String,
         osVersion: String? = nil,
         appVersion: String? = nil,
         protocolVersion: Int = PeelProtocol.currentProtocolVersion,
         minimumSupportedProtocolVersion: Int = PeelProtocol.minimumSupportedProtocolVersion,
         capabilities: Set<String> = PeelProtocol.capabilities)
    {
        self.type = "clientHello"
        self.pairingID = pairingID
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.platform = platform
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.protocolVersion = protocolVersion
        self.minimumSupportedProtocolVersion = minimumSupportedProtocolVersion
        self.capabilities = Array(capabilities).sorted()
    }
}

/// Mac → Client: identifies host app/protocol support after a client connects.
///
/// This should be sent shortly after the host receives `clientHello`.
/// The client can use this to warn, disconnect, or disable unsupported features.
struct HostHelloMessage: Codable {
    let type: String
    let hostName: String
    let platform: String
    let osVersion: String?
    let appVersion: String?
    let protocolVersion: Int?
    let minimumSupportedProtocolVersion: Int?
    let capabilities: [String]?

    init(hostName: String,
         platform: String = "macOS",
         osVersion: String? = nil,
         appVersion: String? = nil,
         protocolVersion: Int = PeelProtocol.currentProtocolVersion,
         minimumSupportedProtocolVersion: Int = PeelProtocol.minimumSupportedProtocolVersion,
         capabilities: Set<String> = PeelProtocol.capabilities)
    {
        self.type = "hostHello"
        self.hostName = hostName
        self.platform = platform
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.protocolVersion = protocolVersion
        self.minimumSupportedProtocolVersion = minimumSupportedProtocolVersion
        self.capabilities = Array(capabilities).sorted()
    }
}

/// Authorizes new agent actions without changing existing TLS pairing semantics.
struct PeelAgentPairingChallengeMessage: Codable {
    let type: String
    let requestId: String
    let pairingId: String
    let nonce: String
    let expiresAt: Double

    init(requestId: String, pairingId: String, nonce: String, expiresAt: Double) {
        type = "agentPairingChallenge"
        self.requestId = requestId
        self.pairingId = pairingId
        self.nonce = nonce
        self.expiresAt = expiresAt
    }
}

struct PeelAgentPairingProofMessage: Codable {
    let type: String
    let requestId: String
    let pairingId: String
    let proof: String

    init(requestId: String, pairingId: String, proof: String) {
        type = "agentPairingProof"
        self.requestId = requestId
        self.pairingId = pairingId
        self.proof = proof
    }
}

enum PeelAgentPairingProof {
    static func isFresh(_ challenge: PeelAgentPairingChallengeMessage, now: Double) -> Bool {
        challenge.expiresAt.isFinite && now.isFinite &&
            challenge.expiresAt > now && challenge.expiresAt <= now + 60
    }

    static func make(_ challenge: PeelAgentPairingChallengeMessage, key: Data) -> String? {
        guard key.count >= 32, let payload = payload(challenge) else { return nil }
        let code = HMAC<SHA256>.authenticationCode(for: payload, using: SymmetricKey(data: key))
        return Data(code).base64EncodedString()
    }

    static func verify(_ proof: String, challenge: PeelAgentPairingChallengeMessage, key: Data) -> Bool {
        guard key.count >= 32, let code = Data(base64Encoded: proof), code.count == 32,
              let payload = payload(challenge) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: payload,
                                                     using: SymmetricKey(data: key))
    }

    private static func payload(_ challenge: PeelAgentPairingChallengeMessage) -> Data? {
        guard let id = UUID(uuidString: challenge.requestId),
              let nonce = Data(base64Encoded: challenge.nonce), nonce.count == 32,
              !challenge.pairingId.isEmpty, challenge.pairingId.utf8.count <= 256,
              !challenge.pairingId.utf8.contains(0), challenge.expiresAt.isFinite,
              challenge.expiresAt > 0 else { return nil }
        var data = Data("peel.agent-pairing-proof.v1\0".utf8)
        data.append(contentsOf: id.uuidString.utf8)
        data.append(0)
        data.append(contentsOf: challenge.pairingId.utf8)
        data.append(0)
        data.append(nonce)
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: challenge.expiresAt.bitPattern >> shift))
        }
        return data
    }
}

nonisolated struct PeelAudioPairingChallengeMessage: Codable {
    let type: String
    let requestId: String
    let pairingId: String
    let nonce: String
    let expiresAt: Double
    let mode: String?

    init(requestId: String, pairingId: String, nonce: String, expiresAt: Double, mode: String? = nil) {
        type = "audioPairingChallenge"
        self.requestId = requestId
        self.pairingId = pairingId
        self.nonce = nonce
        self.expiresAt = expiresAt
        self.mode = mode
    }
}

nonisolated struct PeelAudioPairingProofMessage: Codable {
    let type: String
    let requestId: String
    let pairingId: String
    let proof: String

    init(requestId: String, pairingId: String, proof: String) {
        type = "audioPairingProof"
        self.requestId = requestId
        self.pairingId = pairingId
        self.proof = proof
    }
}

nonisolated enum PeelAudioPairingProof {
    static func isFresh(_ challenge: PeelAudioPairingChallengeMessage, now: Double) -> Bool {
        challenge.expiresAt.isFinite && now.isFinite &&
            challenge.expiresAt > now && challenge.expiresAt <= now + 60
    }

    static func make(_ challenge: PeelAudioPairingChallengeMessage, key: Data) -> String? {
        guard key.count >= 32, let payload = payload(challenge) else { return nil }
        let code = HMAC<SHA256>.authenticationCode(for: payload, using: SymmetricKey(data: key))
        return Data(code).base64EncodedString()
    }

    static func verify(_ proof: String, challenge: PeelAudioPairingChallengeMessage, key: Data) -> Bool {
        guard key.count >= 32, let code = Data(base64Encoded: proof), code.count == 32,
              let payload = payload(challenge) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: payload,
                                                     using: SymmetricKey(data: key))
    }

    private static func payload(_ challenge: PeelAudioPairingChallengeMessage) -> Data? {
        guard let id = UUID(uuidString: challenge.requestId),
              let nonce = Data(base64Encoded: challenge.nonce), nonce.count == 32,
              !challenge.pairingId.isEmpty, challenge.pairingId.utf8.count <= 256,
              !challenge.pairingId.utf8.contains(0), challenge.expiresAt.isFinite,
              challenge.expiresAt > 0 else { return nil }
        guard challenge.mode == nil || challenge.mode == "playback" || challenge.mode == "voice" else { return nil }
        let domain = challenge.mode == "voice" ? "peel.voice-pairing-proof.v1\0" : "peel.audio-pairing-proof.v1\0"
        var data = Data(domain.utf8)
        data.append(contentsOf: id.uuidString.utf8)
        data.append(0)
        data.append(contentsOf: challenge.pairingId.utf8)
        data.append(0)
        data.append(nonce)
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: challenge.expiresAt.bitPattern >> shift))
        }
        return data
    }
}

/// Optional audio messages are sent only after mac-system-audio-v1 negotiation.
nonisolated struct PeelAudioSessionRequest: Codable {
    var type = "audioSessionRequest"
    let requestId: String
    let enabled: Bool
    var mode: String? = nil
}

nonisolated struct PeelAudioSessionState: Codable {
    var type = "audioSessionState"
    let requestId: String
    let pairingId: String
    let status: String
    var reason: String? = nil
    var ticket: String? = nil
}

nonisolated struct PeelAudioStreamHello: Codable {
    var type = "audioStreamHello"
    var version = 1
    let requestId: String
    let pairingId: String
    let ticket: String
}

/// Host → iPad client: asks the opted-in client to present one current Mac window.
/// The client must validate the pairing, expiry, and authoritative window identity
/// before dispatching this request to its scene-opening path.
struct PresentWindowMessage: Codable, Hashable {
    let type: String
    let requestId: String
    let pairingId: String
    let window: PeelWindow
    let issuedAt: Double
    let expiresAt: Double
    let context: String?

    init(
        requestId: String,
        pairingId: String,
        window: PeelWindow,
        issuedAt: Double,
        expiresAt: Double,
        context: String? = nil
    ) {
        self.type = "presentWindow"
        self.requestId = requestId
        self.pairingId = pairingId
        self.window = window
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.context = context
    }
}

/// iPad client → Host: result of an agent-driven presentation request.
/// `status` is one of `opened`, `declined`, or `unavailable`.
struct AgentPresentationResultMessage: Codable, Hashable {
    let type: String
    let requestId: String
    let status: String
    let reason: String?

    init(requestId: String, status: String, reason: String? = nil) {
        self.type = "agentPresentationResult"
        self.requestId = requestId
        self.status = status
        self.reason = reason
    }
}

/// Either side → other side: sent when the peer is too old/new to safely talk to.
struct ProtocolRejectedMessage: Codable {
    let type: String
    let reason: String
    let localProtocolVersion: Int
    let localMinimumSupportedProtocolVersion: Int
    let remoteProtocolVersion: Int?
    let remoteMinimumSupportedProtocolVersion: Int?

    init(reason: String,
         remoteProtocolVersion: Int?,
         remoteMinimumSupportedProtocolVersion: Int?)
    {
        self.type = "protocolRejected"
        self.reason = reason
        self.localProtocolVersion = PeelProtocol.currentProtocolVersion
        self.localMinimumSupportedProtocolVersion = PeelProtocol.minimumSupportedProtocolVersion
        self.remoteProtocolVersion = remoteProtocolVersion
        self.remoteMinimumSupportedProtocolVersion = remoteMinimumSupportedProtocolVersion
    }
}


/// A snapshot of the screen currently owning the conventional video layer.
/// These are display capabilities, not decoder limits or measured presentation.
nonisolated struct PeelReceiverDisplayCapabilities: Codable, Equatable, Sendable {
    let pixelWidth: Int
    let pixelHeight: Int
    let maximumFPS: Int

    var isValid: Bool {
        (1...16_384).contains(pixelWidth) && (1...16_384).contains(pixelHeight)
            && (1...240).contains(maximumFPS)
    }
}

/// Optional, per-video-socket experiment. Old peers omit or ignore this field.
/// No field grants pairing, input, capture, or device authorization.
nonisolated struct PeelVideoStreamRequest: Codable, Equatable, Sendable {
    static let capability = "nativeStreamRequestV1"
    let version: Int
    let nativeResolution: Bool
    let maximumFPS: Int
    let receiverDisplay: PeelReceiverDisplayCapabilities?
    /// A requested content cadence, not a physical screen-capability claim.
    let visionOS90Experiment: Bool?

    init(maximumFPS: Int, receiverDisplay: PeelReceiverDisplayCapabilities?, visionOS90Experiment: Bool? = nil) {
        version = 1
        nativeResolution = true
        self.maximumFPS = maximumFPS
        self.receiverDisplay = receiverDisplay
        self.visionOS90Experiment = visionOS90Experiment
    }

    var isValid: Bool {
        version == 1 && nativeResolution && (1...120).contains(maximumFPS)
            && (receiverDisplay?.isValid == true ||
                (visionOS90Experiment == true && receiverDisplay == nil && maximumFPS <= 90))
    }
}

/// Client -> Host: first line sent on a dedicated per-window video connection.
///
/// After this NDJSON hello is accepted, that socket becomes binary-only and must
/// carry only `VideoConfigPacket` / `VideoFramePacket` data for `windowId`.
struct VideoStreamHelloMessage: Codable {
    let type: String
    let pairingID: String?
    let windowId: UInt32
    let protocolVersion: Int
    let minimumSupportedProtocolVersion: Int
    let capabilities: [String]?

    let streamRequest: PeelVideoStreamRequest?

    init(windowId: UInt32,
         pairingID: String? = nil,
         protocolVersion: Int = PeelProtocol.currentProtocolVersion,
         minimumSupportedProtocolVersion: Int = PeelProtocol.minimumSupportedProtocolVersion,
         capabilities: Set<String> = PeelProtocol.capabilities,
         streamRequest: PeelVideoStreamRequest? = nil)
    {
        self.type = "videoStreamHello"
        self.pairingID = pairingID
        self.windowId = windowId
        self.protocolVersion = protocolVersion
        self.minimumSupportedProtocolVersion = minimumSupportedProtocolVersion
        self.capabilities = Array(capabilities).sorted()
        self.streamRequest = streamRequest
    }
}

enum PeelBinaryPacketType: UInt8 {
    case jpegFrame = 0x02
    case videoConfig = 0x10
    case videoFrame = 0x11
    case hevcVideoConfig = 0x12
}

enum PeelVideoCodec: UInt8, Codable {
    case h264 = 1
    case hevc = 2
}

struct VideoConfigPacket {
    let windowId: UInt32
    let codec: PeelVideoCodec
    let width: UInt32
    let height: UInt32
    let timescale: UInt32
    let nalUnitHeaderLength: UInt8
    let sps: Data
    let pps: Data
    let vps: Data?

    init(
        windowId: UInt32,
        codec: PeelVideoCodec,
        width: UInt32,
        height: UInt32,
        timescale: UInt32,
        nalUnitHeaderLength: UInt8,
        sps: Data,
        pps: Data,
        vps: Data? = nil
    ) {
        self.windowId = windowId
        self.codec = codec
        self.width = width
        self.height = height
        self.timescale = timescale
        self.nalUnitHeaderLength = nalUnitHeaderLength
        self.sps = sps
        self.pps = pps
        self.vps = vps
    }

    func encode() -> Data {
        var data = Data()
        data.append(codec == .hevc
            ? PeelBinaryPacketType.hevcVideoConfig.rawValue
            : PeelBinaryPacketType.videoConfig.rawValue)
        data.appendLE(windowId)
        data.append(codec.rawValue)
        data.appendLE(width)
        data.appendLE(height)
        data.appendLE(timescale)
        data.append(nalUnitHeaderLength)
        if codec == .hevc {
            data.appendLE(UInt32(vps?.count ?? 0))
        }
        data.appendLE(UInt32(sps.count))
        data.appendLE(UInt32(pps.count))
        if codec == .hevc, let vps {
            data.append(vps)
        }
        data.append(sps)
        data.append(pps)
        return data
    }
}

extension VideoConfigPacket {
    init?(data: Data) {
        guard let leadByte = data.first,
              let packetType = PeelBinaryPacketType(rawValue: leadByte) else { return nil }
        let isHEVC = packetType == .hevcVideoConfig
        guard packetType == .videoConfig || isHEVC else { return nil }

        let minimumHeader = isHEVC ? 31 : 27
        guard data.count >= minimumHeader else { return nil }

        let windowId = data.readUInt32LE(at: 1)
        let codecRaw = data[5]
        guard let codec = PeelVideoCodec(rawValue: codecRaw) else { return nil }
        guard (isHEVC && codec == .hevc) || (!isHEVC && codec == .h264) else { return nil }

        let width = data.readUInt32LE(at: 6)
        let height = data.readUInt32LE(at: 10)
        let timescale = data.readUInt32LE(at: 14)
        let nalUnitHeaderLength = data[18]
        let vpsLength = isHEVC ? Int(data.readUInt32LE(at: 19)) : 0
        let spsLengthOffset = isHEVC ? 23 : 19
        let ppsLengthOffset = isHEVC ? 27 : 23
        let spsLength = Int(data.readUInt32LE(at: spsLengthOffset))
        let ppsLength = Int(data.readUInt32LE(at: ppsLengthOffset))

        let expected = minimumHeader + vpsLength + spsLength + ppsLength
        guard data.count >= expected else { return nil }

        let parameterSetsStart = minimumHeader
        let vpsEnd = parameterSetsStart + vpsLength
        let spsStart = vpsEnd
        let spsEnd = spsStart + spsLength
        let ppsEnd = spsEnd + ppsLength

        self.init(
            windowId: windowId,
            codec: codec,
            width: width,
            height: height,
            timescale: timescale,
            nalUnitHeaderLength: nalUnitHeaderLength,
            sps: data.subdata(in: spsStart..<spsEnd),
            pps: data.subdata(in: spsEnd..<ppsEnd),
            vps: isHEVC ? data.subdata(in: parameterSetsStart..<vpsEnd) : nil
        )
    }

    var encodedLength: Int {
        if codec == .hevc {
            return 31 + (vps?.count ?? 0) + sps.count + pps.count
        }
        return 27 + sps.count + pps.count
    }
}
struct VideoFramePacket {
    let windowId: UInt32
    let isKeyframe: Bool
    let ptsValue: Int64
    let durationValue: Int64
    let payload: Data

    func encode() -> Data {
        var data = Data()
        data.append(PeelBinaryPacketType.videoFrame.rawValue)
        data.appendLE(windowId)
        data.append(isKeyframe ? 1 : 0)
        data.appendLE(ptsValue)
        data.appendLE(durationValue)
        data.appendLE(UInt32(payload.count))
        data.append(payload)
        return data
    }
}
extension VideoFramePacket {
    init?(data: Data) {
        let minimumHeader = 26
        guard data.count >= minimumHeader else { return nil }
        guard data[0] == PeelBinaryPacketType.videoFrame.rawValue else { return nil }

        let windowId = data.readUInt32LE(at: 1)
        let isKeyframe = data[5] != 0
        let ptsValue = data.readInt64LE(at: 6)
        let durationValue = data.readInt64LE(at: 14)
        let payloadLength = Int(data.readUInt32LE(at: 22))

        let expected = minimumHeader + payloadLength
        guard data.count >= expected else { return nil }

        self.init(
            windowId: windowId,
            isKeyframe: isKeyframe,
            ptsValue: ptsValue,
            durationValue: durationValue,
            payload: data.subdata(in: 26..<expected)
        )
    }

    var encodedLength: Int {
        26 + payload.count
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { buffer in
            append(buffer.bindMemory(to: UInt8.self))
        }
    }
}

private extension Data {
    func readUInt32LE(at offset: Int) -> UInt32 {
        precondition(offset + 4 <= count)
        return withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: offset)
            return base.assumingMemoryBound(to: UInt32.self).pointee.littleEndian
        }
    }

    func readInt64LE(at offset: Int) -> Int64 {
        precondition(offset + 8 <= count)
        return withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: offset)
            return base.assumingMemoryBound(to: Int64.self).pointee.littleEndian
        }
    }
}


/// Consent for local agents acting only through an already visible manual stream.
/// Separate from paid automatic window presentation and its authorization proof.
nonisolated enum PeelManualAgentControl {
    static let capability = "manual-agent-control-v1"
    static let optInDefaultsKey = "peel.ai.allowManualVisibleWindowControl"
    static func allows(platformSupported: Bool, optedIn: Bool) -> Bool { platformSupported && optedIn }
    static var isOptedIn: Bool {
#if os(iOS) || os(visionOS)
        allows(platformSupported: true, optedIn: UserDefaults.standard.bool(forKey: optInDefaultsKey))
#else
        false
#endif
    }
}

nonisolated struct PeelManualAgentControlChallenge: Codable, Sendable {
    let type: String
    let requestId: String
    let pairingId: String
    let nonce: String
    let expiresAt: Double
    init(requestId: String, pairingId: String, nonce: String, expiresAt: Double) {
        type = "manualAgentControlChallenge"; self.requestId = requestId; self.pairingId = pairingId
        self.nonce = nonce; self.expiresAt = expiresAt
    }
}
nonisolated struct PeelManualAgentControlProofMessage: Codable, Sendable {
    let type: String
    let requestId: String
    let pairingId: String
    let proof: String
    init(requestId: String, pairingId: String, proof: String) {
        type = "manualAgentControlProof"; self.requestId = requestId; self.pairingId = pairingId; self.proof = proof
    }
}
nonisolated enum PeelManualAgentControlProof {
    static func isFresh(_ challenge: PeelManualAgentControlChallenge, now: Double) -> Bool {
        challenge.type == "manualAgentControlChallenge" && challenge.expiresAt.isFinite && now.isFinite &&
            challenge.expiresAt > now && challenge.expiresAt <= now + 60
    }
    static func make(_ challenge: PeelManualAgentControlChallenge, key: Data) -> String? {
        guard key.count >= 32, let payload = payload(challenge) else { return nil }
        return Data(HMAC<SHA256>.authenticationCode(for: payload, using: SymmetricKey(data: key))).base64EncodedString()
    }
    static func verify(_ proof: String, challenge: PeelManualAgentControlChallenge, key: Data) -> Bool {
        guard key.count >= 32, let code = Data(base64Encoded: proof), code.count == 32,
              let payload = payload(challenge) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: payload, using: SymmetricKey(data: key))
    }
    private static func payload(_ challenge: PeelManualAgentControlChallenge) -> Data? {
        guard challenge.type == "manualAgentControlChallenge", let id = UUID(uuidString: challenge.requestId),
              let nonce = Data(base64Encoded: challenge.nonce), nonce.count == 32,
              !challenge.pairingId.isEmpty, challenge.pairingId.utf8.count <= 256,
              !challenge.pairingId.utf8.contains(0), challenge.expiresAt.isFinite, challenge.expiresAt > 0 else { return nil }
        var data = Data("peel.manual-agent-control-proof.v1\0".utf8)
        data.append(contentsOf: id.uuidString.utf8); data.append(0)
        data.append(contentsOf: challenge.pairingId.utf8); data.append(0); data.append(nonce)
        for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: challenge.expiresAt.bitPattern >> shift)) }
        return data
    }
}
