import Foundation

/// Watch-local viewing intent and request sequencing. This does not extend the
/// phone's lease, authorize control, or retain an input for automatic retry.
public struct WatchViewingState: Sendable {
    public enum Reply: Equatable, Sendable {
        case retired
        case retry
        case accepted(WatchStreamInfo)
    }

    /// Both discovery retries and frame polls yield between requests.
    public static let pollIntervalNanoseconds: UInt64 = 1_000_000_000

    public private(set) var generation = UUID()
    public private(set) var isWanted = false
    public private(set) var sessionID: UUID?
    private var inputSessionID: UUID?
    private var inputSequence: UInt64 = 0

    public init() {}

    @discardableResult
    public mutating func start() -> UUID {
        generation = UUID()
        isWanted = true
        sessionID = nil
        return generation
    }

    public mutating func stop() {
        generation = UUID()
        isWanted = false
        sessionID = nil
        // A reconnect may confirm the same phone lease. Keep its next input
        // strictly greater than every attempted input, including lost replies.
    }

    public func isCurrent(_ expectedGeneration: UUID) -> Bool {
        isWanted && generation == expectedGeneration
    }

    public func nextRequest(generation: UUID, viewport: WatchViewport) -> WatchStreamRequest? {
        guard isCurrent(generation) else { return nil }
        if let sessionID {
            return WatchStreamRequest(kind: .frame, sessionID: sessionID, viewport: viewport)
        }
        return WatchStreamRequest(kind: .status)
    }

    /// Only an accepted status reply can select a lease. A failed frame reply
    /// returns to discovery instead of silently adopting a replacement window.
    public mutating func receive(_ response: WatchStreamResponse?, to request: WatchStreamRequest,
                                 generation: UUID) -> Reply {
        guard isCurrent(generation) else { return .retired }
        guard let response, response.requestID == request.requestID,
              response.accepted, let info = response.info else {
            sessionID = nil
            return .retry
        }
        if request.kind == .status {
            sessionID = info.sessionID
            if inputSessionID != info.sessionID {
                inputSessionID = info.sessionID
                inputSequence = 0
            }
            return .accepted(info)
        }
        guard request.kind == .frame, request.sessionID == sessionID,
              info.sessionID == sessionID else {
            sessionID = nil
            return .retry
        }
        return .accepted(info)
    }

    public mutating func requireStatus(generation: UUID) {
        guard isCurrent(generation) else { return }
        sessionID = nil
    }

    /// Consume once before transport. A missing input reply is ambiguous, so
    /// recovery must never resend it or reuse its sequence number.
    public mutating func nextInputSequence(sessionID: UUID, generation: UUID) -> UInt64? {
        guard isCurrent(generation), self.sessionID == sessionID,
              inputSessionID == sessionID, inputSequence < UInt64.max else { return nil }
        inputSequence += 1
        return inputSequence
    }
}
