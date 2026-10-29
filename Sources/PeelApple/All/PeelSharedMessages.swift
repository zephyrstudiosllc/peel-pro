//
//  PeelSharedMessages.swift
//  Peel
//
//  Shared message types between the macOS host and the visionOS client.
//

import Foundation

/// Basic description of a Mac window that Peel can stream.
struct PeelWindow: Codable, Identifiable, Hashable {
    let windowId: UInt32
    let appName: String
    let title: String
    let width: Int
    let height: Int
    let statusSummary: String?


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

/// Commands for non-text keys we care about (backspace, enter, arrows, etc.)
enum KeyboardCommand: String, Codable {
    case backspace
    case enter
    case escape
    case leftArrow
    case rightArrow
    case upArrow
    case downArrow
}

/// Text typed on the client that should be injected on the Mac.
struct KeyboardTextMessage: Codable {
    let type: String
    let text: String

    init(text: String) {
        self.type = "keyboardText"
        self.text = text
    }
}

/// Non-text keypresses from the client (backspace, arrows, etc.)
struct KeyboardCommandMessage: Codable {
    let type: String
    let command: KeyboardCommand

    init(command: KeyboardCommand) {
        self.type = "keyboardCommand"
        self.command = command
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

    init() {
        self.type = "clientPing"
    }
}

public struct MessageEnvelope: Codable {
    public let type: String
}

// MARK: - InputRejectedMessage

/// Sent by the host when it refuses to execute an input event (fail-closed).
struct InputRejectedMessage: Codable {
    let windowId: UInt32
    let reason: String
    let timestamp: Date

    init(windowId: UInt32, reason: String, timestamp: Date = Date()) {
        self.windowId = windowId
        self.reason = reason
        self.timestamp = timestamp
    }
}

// MARK: - Pairing

/// Client → Host (pairing port): asks to pair and identifies itself.
struct PairRequestMessage: Codable {
    let type: String
    let clientName: String
    let clientDeviceId: String   // stable-ish UUID stored on client

    init(clientName: String, clientDeviceId: String) {
        self.type = "pairRequest"
        self.clientName = clientName
        self.clientDeviceId = clientDeviceId
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

/// Client → Mac: identify the connected client device (for labeling in host UI/logs).
struct ClientHelloMessage: Codable {
    let type: String
    let pairingID: String?
    let deviceName: String
    let deviceModel: String?
    let platform: String
    let osVersion: String?
    let appVersion: String?

    init(pairingID: String?,
         deviceName: String,
         deviceModel: String? = nil,
         platform: String,
         osVersion: String? = nil,
         appVersion: String? = nil)
    {
        self.type = "clientHello"
        self.pairingID = pairingID
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.platform = platform
        self.osVersion = osVersion
        self.appVersion = appVersion
    }
}
