import Foundation

public enum WatchStreamError: Error, Equatable, LocalizedError {
    case invalid, oversized, expired, wrongSession, controlDenied, staleFrame, replay
    public var errorDescription: String? {
        switch self {
        case .invalid: return "The watch request was invalid."
        case .oversized: return "The watch message was too large."
        case .expired: return "Open Peel Pro on both devices and start sharing again."
        case .wrongSession: return "The shared window changed. Start viewing again."
        case .controlDenied: return "Allow Watch Control on iPhone first."
        case .staleFrame: return "Wait for a fresh view before controlling this window."
        case .replay: return "This input was already handled."
        }
    }
}

/// A crop of the original source, not a scaled screenshot of the phone UI.
public struct WatchViewport: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public static let full = WatchViewport(x: 0, y: 0, width: 1, height: 1)
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public func validate() throws {
        guard [x,y,width,height].allSatisfy(\.isFinite), x >= 0, y >= 0,
              width >= 0.125, height >= 0.125, width <= 1, height <= 1,
              x + width <= 1.000001, y + height <= 1.000001 else { throw WatchStreamError.invalid }
    }
    public static func centered(zoom: Double, centerX: Double, centerY: Double) -> Self {
        let z = zoom.isFinite ? min(8, max(1, zoom)) : 1
        let size = 1 / z
        return Self(x: min(1-size, max(0, centerX-size/2)),
                    y: min(1-size, max(0, centerY-size/2)), width: size, height: size)
    }
}

public struct WatchStreamInput: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case click, text, enter, backspace, scrollUp, scrollDown }
    public let kind: Kind
    public let x: Double?
    public let y: Double?
    public let text: String?
    public init(kind: Kind, x: Double? = nil, y: Double? = nil, text: String? = nil) {
        self.kind = kind; self.x = x; self.y = y; self.text = text
    }
    public func validate() throws {
        if kind == .click {
            guard let x, let y, x.isFinite, y.isFinite,
                  (0...1).contains(x), (0...1).contains(y), text == nil else { throw WatchStreamError.invalid }
        } else if kind == .text {
            guard let text, !text.isEmpty, text.count <= 500, text.utf8.count <= 2_000,
                  !text.unicodeScalars.contains(where: { $0.value == 0 }), x == nil, y == nil else { throw WatchStreamError.invalid }
        } else if x != nil || y != nil || text != nil { throw WatchStreamError.invalid }
    }
}

public struct WatchStreamRequest: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case status, frame, input, stop }
    public let version: Int
    public let channel: String
    public let requestID: UUID
    public let kind: Kind
    public let sessionID: UUID?
    public let viewport: WatchViewport?
    public let frameSequence: UInt64?
    public let controlToken: UUID?
    public let inputSequence: UInt64?
    public let input: WatchStreamInput?
    public init(kind: Kind, sessionID: UUID? = nil, viewport: WatchViewport? = nil,
                frameSequence: UInt64? = nil, controlToken: UUID? = nil,
                inputSequence: UInt64? = nil, input: WatchStreamInput? = nil, requestID: UUID = UUID()) {
        self.version = 1; self.channel = "peel.watch.stream.v1"; self.requestID = requestID; self.kind = kind; self.sessionID = sessionID
        self.viewport = viewport; self.frameSequence = frameSequence; self.controlToken = controlToken
        self.inputSequence = inputSequence; self.input = input
    }
    public func validate() throws {
        guard version == 1, channel == "peel.watch.stream.v1" else { throw WatchStreamError.invalid }
        if kind != .status, sessionID == nil { throw WatchStreamError.invalid }
        if kind == .frame { try (viewport ?? .full).validate() }
        if kind == .input {
            guard let input, let sequence = inputSequence, sequence > 0,
                  let frameSequence, frameSequence > 0, controlToken != nil else { throw WatchStreamError.invalid }
            try input.validate()
        } else if input != nil || controlToken != nil || inputSequence != nil { throw WatchStreamError.invalid }
    }
    public func encoded() throws -> Data { try WatchStreamWire.encode(self) }
    public static func decode(_ data: Data) throws -> Self {
        let value: Self = try WatchStreamWire.decode(data); try value.validate(); return value
    }
}

public struct WatchStreamInfo: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let hostName: String
    public let windowTitle: String
    public let controlToken: UUID?
    public init(sessionID: UUID, hostName: String, windowTitle: String, controlToken: UUID?) {
        self.sessionID = sessionID; self.hostName = String(hostName.prefix(100))
        self.windowTitle = String(windowTitle.prefix(160)); self.controlToken = controlToken
    }
}

public struct WatchStreamFrame: Codable, Sendable {
    public let sequence: UInt64
    public let jpeg: Data
    public let width: Int
    public let height: Int
    public let viewport: WatchViewport
    public init(sequence: UInt64, jpeg: Data, width: Int, height: Int, viewport: WatchViewport) {
        self.sequence = sequence; self.jpeg = jpeg; self.width = width; self.height = height; self.viewport = viewport
    }
    public func validate() throws {
        guard sequence > 0, !jpeg.isEmpty, jpeg.count <= 32 * 1_024,
              (1...512).contains(width), (1...512).contains(height) else { throw WatchStreamError.invalid }
        try viewport.validate()
    }
}

public struct WatchStreamResponse: Codable, Sendable {
    public let version: Int
    public let channel: String
    public let requestID: UUID
    public let info: WatchStreamInfo?
    public let frame: WatchStreamFrame?
    public let message: String
    public let accepted: Bool
    public init(requestID: UUID, info: WatchStreamInfo? = nil, frame: WatchStreamFrame? = nil,
                message: String, accepted: Bool) {
        self.version = 1; self.channel = "peel.watch.stream.v1"; self.requestID = requestID; self.info = info; self.frame = frame
        self.message = String(message.prefix(240)); self.accepted = accepted
    }
    public func encoded() throws -> Data { try WatchStreamWire.encode(self) }
    public static func decode(_ data: Data) throws -> Self {
        let value: Self = try WatchStreamWire.decode(data)
        guard value.version == 1, value.channel == "peel.watch.stream.v1", value.message.count <= 240,
              (value.info?.hostName.count ?? 0) <= 100,
              (value.info?.windowTitle.count ?? 0) <= 160 else { throw WatchStreamError.invalid }
        if let frame = value.frame { guard value.info != nil else { throw WatchStreamError.invalid }; try frame.validate() }
        return value
    }
}

public enum WatchStreamWire {
    public static let maximumBytes = 60 * 1_024
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximumBytes else { throw WatchStreamError.oversized }; return data
    }
    public static func decode<T: Decodable>(_ data: Data) throws -> T {
        guard !data.isEmpty, data.count <= maximumBytes else { throw WatchStreamError.oversized }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw WatchStreamError.invalid }
    }
}

public enum WatchStreamSourcePolicy {
    /// Reserved display IDs shared by the existing Mac and Windows Host wire.
    /// Window titles and application names never grant input authority.
    public static func hasInputFocus(windowID: UInt32, activeWindowID: UInt32?, hostConfirmedWindowID: UInt32?) -> Bool {
        guard activeWindowID == windowID else { return false }
        let displayID = windowID >= 0xFFF0_0000 && windowID < 0xFFF0_0040
        return displayID || hostConfirmedWindowID == windowID
    }
}

/// Phone-owned authorization. Uses one monotonic clock; peer wall clocks grant no authority.
public struct WatchStreamLease: Sendable {
    public let id: UUID
    public private(set) var controlToken: UUID?
    public private(set) var frameSequence: UInt64 = 0
    private var lastInputSequence: UInt64 = 0
    private var lastPoll: TimeInterval
    private var lastFrame: TimeInterval?
    private var hasPolled = false
    public init(now: TimeInterval, id: UUID = UUID()) { self.id = id; self.lastPoll = now }
    public mutating func setControlAllowed(_ allowed: Bool) { controlToken = allowed ? UUID() : nil; lastInputSequence = 0 }
    public func check(sessionID: UUID?, now: TimeInterval) throws {
        guard sessionID == id else { throw WatchStreamError.wrongSession }
        guard now.isFinite, now >= lastPoll, now-lastPoll <= (hasPolled ? 6 : 60) else { throw WatchStreamError.expired }
    }
    public mutating func poll(sessionID: UUID?, now: TimeInterval) throws {
        try check(sessionID: sessionID, now: now); lastPoll = now; hasPolled = true
    }
    public mutating func issuedFrame(now: TimeInterval) -> UInt64 {
        frameSequence += 1; lastFrame = now; return frameSequence
    }
    public mutating func admit(_ request: WatchStreamRequest, now: TimeInterval) throws {
        try request.validate(); try check(sessionID: request.sessionID, now: now)
        guard request.kind == .input, let token = controlToken, request.controlToken == token else { throw WatchStreamError.controlDenied }
        guard let lastFrame, now >= lastFrame, now-lastFrame <= 3,
              request.frameSequence == frameSequence else { throw WatchStreamError.staleFrame }
        guard let sequence = request.inputSequence, sequence > lastInputSequence else { throw WatchStreamError.replay }
        lastInputSequence = sequence
    }
}
