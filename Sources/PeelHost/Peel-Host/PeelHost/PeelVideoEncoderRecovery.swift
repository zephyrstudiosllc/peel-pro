import Foundation

/// Session-local recovery. A transient failure must not permanently blacklist a
/// working codec. Exhausting all candidates pauses retries instead of recreating
/// an unusable encoder once per incoming frame. Owned by the encoder queue.
nonisolated struct PeelVideoEncoderRecovery {
    enum Candidate: String, Sendable {
        case hevcLowLatency, h264LowLatency, h264Legacy
    }

    static let failuresBeforeFallback = 2
    static let cooldownSeconds: TimeInterval = 5

    private let candidates: [Candidate]
    private var index = 0
    private(set) var consecutiveRuntimeFailures = 0
    private(set) var retryAfterUptime: TimeInterval?

    init(prefersHEVC: Bool) {
        candidates = prefersHEVC ? [.hevcLowLatency, .h264LowLatency, .h264Legacy]
            : [.h264LowLatency, .h264Legacy]
    }

    var candidate: Candidate { candidates[index] }

    mutating func canAttempt(at uptime: TimeInterval) -> Bool {
        guard let retryAfterUptime else { return true }
        guard uptime >= retryAfterUptime else { return false }
        self.retryAfterUptime = nil
        return true
    }

    mutating func creationFailed(at uptime: TimeInterval) {
        advance(at: uptime)
    }

    mutating func runtimeFailed(at uptime: TimeInterval) {
        consecutiveRuntimeFailures += 1
        if consecutiveRuntimeFailures >= Self.failuresBeforeFallback {
            advance(at: uptime)
        }
    }

    mutating func producedValidOutput() {
        consecutiveRuntimeFailures = 0
    }

    private mutating func advance(at uptime: TimeInterval) {
        consecutiveRuntimeFailures = 0
        index += 1
        if index == candidates.count {
            index = 0
            retryAfterUptime = uptime + Self.cooldownSeconds
        }
    }
}
