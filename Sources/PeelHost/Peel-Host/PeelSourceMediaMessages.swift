//
//  PeelSourceMediaMessages.swift
//  Peel
//
//  Source media protocol v1. The Host copy and the Apple Shared/All copy are
//  byte-identical; change both together. Controls act on the streamed source
//  computer, never on the receiver.
//

import Foundation

/// Wire constants and identity rules shared by Host and clients.
///
/// - `source-media-keys-v1`: the source posts OS media keys (play/pause,
///   previous, next). Advertised only by a source with that mechanism.
/// - `source-volume-v1`: advertised only once a volume backend for a stated
///   scope exists. Messages for both scopes are defined; neither is implied.
nonisolated enum PeelSourceMediaProtocol {
    static let version = 1
    static let mediaKeysCapability = "source-media-keys-v1"
    static let volumeCapability = "source-volume-v1"

    static let commandType = "sourceMediaCommand"
    static let volumeQueryType = "sourceVolumeQuery"
    static let volumeSetType = "sourceVolumeSet"
    static let ackType = "sourceMediaAck"
    static let volumeStateType = "sourceVolumeState"

    /// Request types that are ordinary paired-user input on the source.
    static let userInputTypes: Set<String> = [commandType, volumeSetType]
    static let requestTypes: Set<String> = [commandType, volumeQueryType, volumeSetType]

    static let maximumLineBytes = 4096
    static let maximumPairingIDBytes = 256
    static let maximumEnumBytes = 32

    /// Per control session, sliding one-second window.
    static let mediaActionsPerSecond = 5
    static let volumeSetsPerSecond = 20
    static let volumeQueriesPerSecond = 10

    /// Client bookkeeping limits.
    static let clientMaximumPending = 8
    static let clientTimeoutSeconds: Double = 3

    /// Exact ASCII 8-4-4-4-12 hex UUID (36 bytes).
    static func isRequestID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 36 else { return false }
        for (index, byte) in bytes.enumerated() {
            switch index {
            case 8, 13, 18, 23:
                guard byte == UInt8(ascii: "-") else { return false }
            default:
                let isHex = (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x46) ||
                    (byte >= 0x61 && byte <= 0x66)
                guard isHex else { return false }
            }
        }
        return UUID(uuidString: value) != nil
    }

    static func isPairingID(_ value: String) -> Bool {
        let count = value.utf8.count
        return count >= 1 && count <= maximumPairingIDBytes && !value.utf8.contains(0)
    }

    static func isEnumString(_ value: String) -> Bool {
        let count = value.utf8.count
        return count >= 1 && count <= maximumEnumBytes
    }

    static func isVolume(_ value: Double) -> Bool {
        value.isFinite && value >= 0 && value <= 1
    }
}

nonisolated enum PeelSourceMediaAction: String, Codable, Sendable, CaseIterable {
    case playPause
    case previousTrack
    case nextTrack
}

nonisolated enum PeelSourceVolumeScope: String, Codable, Sendable, CaseIterable {
    /// The source computer's actual default output device volume/mute.
    case systemOutput
    /// Only the source's Peel audio stream gain/mute.
    case peelStream
}

nonisolated enum PeelSourceMediaStatus: String, Codable, Sendable, CaseIterable {
    /// The source OS accepted the effect. For media keys this means the key
    /// events were posted, not that an app played or skipped.
    case applied
    case unsupported
    case denied
    case failed
    case stale
    case invalid
}

nonisolated enum PeelSourceMediaReason: String, Codable, Sendable, CaseIterable {
    case controlOff
    case notVisible
    case locked
    case accessibilityMissing
    case scopeUnsupported
    case fixedVolume
    case noOutputDevice
    case staleStream
    case rateLimited
    case osRefused
}

/// Minimal identity every request must carry before any reply is possible.
/// A request whose identity fails validation is dropped without a reply.
nonisolated struct PeelSourceMediaRequestIdentity: Decodable, Sendable {
    let type: String
    let requestId: String
    let pairingId: String
    let windowId: UInt32

    var isValid: Bool {
        PeelSourceMediaProtocol.requestTypes.contains(type) &&
            PeelSourceMediaProtocol.isRequestID(requestId) &&
            PeelSourceMediaProtocol.isPairingID(pairingId)
    }
}

/// Validation outcome for an identity-valid request.
nonisolated enum PeelSourceMediaRequestCheck<Value: Sendable>: Sendable {
    case valid(Value)
    case refused(PeelSourceMediaStatus, PeelSourceMediaReason?)
}

// MARK: - Client → source

nonisolated struct PeelSourceMediaCommand: Codable, Sendable {
    let type: String
    let version: Int
    let requestId: String
    let pairingId: String
    let windowId: UInt32
    /// Raw so an unknown future action decodes and is refused as unsupported.
    let action: String

    init(requestId: UUID, pairingId: String, windowId: UInt32, action: PeelSourceMediaAction) {
        type = PeelSourceMediaProtocol.commandType
        version = PeelSourceMediaProtocol.version
        self.requestId = requestId.uuidString
        self.pairingId = pairingId
        self.windowId = windowId
        self.action = action.rawValue
    }

    func check() -> PeelSourceMediaRequestCheck<PeelSourceMediaAction> {
        guard type == PeelSourceMediaProtocol.commandType,
              PeelSourceMediaProtocol.isRequestID(requestId),
              PeelSourceMediaProtocol.isPairingID(pairingId),
              PeelSourceMediaProtocol.isEnumString(action) else { return .refused(.invalid, nil) }
        guard version == PeelSourceMediaProtocol.version,
              let parsed = PeelSourceMediaAction(rawValue: action) else { return .refused(.unsupported, nil) }
        return .valid(parsed)
    }
}

nonisolated struct PeelSourceVolumeQuery: Codable, Sendable {
    let type: String
    let version: Int
    let requestId: String
    let pairingId: String
    let windowId: UInt32
    let scope: String

    init(requestId: UUID, pairingId: String, windowId: UInt32, scope: PeelSourceVolumeScope) {
        type = PeelSourceMediaProtocol.volumeQueryType
        version = PeelSourceMediaProtocol.version
        self.requestId = requestId.uuidString
        self.pairingId = pairingId
        self.windowId = windowId
        self.scope = scope.rawValue
    }

    func check() -> PeelSourceMediaRequestCheck<PeelSourceVolumeScope> {
        guard type == PeelSourceMediaProtocol.volumeQueryType,
              PeelSourceMediaProtocol.isRequestID(requestId),
              PeelSourceMediaProtocol.isPairingID(pairingId),
              PeelSourceMediaProtocol.isEnumString(scope) else { return .refused(.invalid, nil) }
        guard version == PeelSourceMediaProtocol.version else { return .refused(.unsupported, nil) }
        guard let parsed = PeelSourceVolumeScope(rawValue: scope) else {
            return .refused(.unsupported, .scopeUnsupported)
        }
        return .valid(parsed)
    }
}

nonisolated struct PeelSourceVolumeChange: Equatable, Sendable {
    let scope: PeelSourceVolumeScope
    let volume: Double?
    let muted: Bool?
}

nonisolated struct PeelSourceVolumeSet: Codable, Sendable {
    let type: String
    let version: Int
    let requestId: String
    let pairingId: String
    let windowId: UInt32
    let scope: String
    /// Finite 0...1. Out-of-range values are invalid, never clamped.
    let volume: Double?
    let muted: Bool?

    init(requestId: UUID, pairingId: String, windowId: UInt32, scope: PeelSourceVolumeScope,
         volume: Double?, muted: Bool?) {
        type = PeelSourceMediaProtocol.volumeSetType
        version = PeelSourceMediaProtocol.version
        self.requestId = requestId.uuidString
        self.pairingId = pairingId
        self.windowId = windowId
        self.scope = scope.rawValue
        self.volume = volume
        self.muted = muted
    }

    func check() -> PeelSourceMediaRequestCheck<PeelSourceVolumeChange> {
        guard type == PeelSourceMediaProtocol.volumeSetType,
              PeelSourceMediaProtocol.isRequestID(requestId),
              PeelSourceMediaProtocol.isPairingID(pairingId),
              PeelSourceMediaProtocol.isEnumString(scope),
              volume != nil || muted != nil,
              volume.map(PeelSourceMediaProtocol.isVolume) ?? true else { return .refused(.invalid, nil) }
        guard version == PeelSourceMediaProtocol.version else { return .refused(.unsupported, nil) }
        guard let parsed = PeelSourceVolumeScope(rawValue: scope) else {
            return .refused(.unsupported, .scopeUnsupported)
        }
        return .valid(PeelSourceVolumeChange(scope: parsed, volume: volume, muted: muted))
    }
}

// MARK: - Source → client

/// Targeted only to the requesting current paired control session.
nonisolated struct PeelSourceMediaAck: Codable, Sendable {
    let type: String
    let version: Int
    let requestId: String
    let pairingId: String
    let windowId: UInt32
    let status: String
    let reason: String?

    init(requestId: String, pairingId: String, windowId: UInt32,
         status: PeelSourceMediaStatus, reason: PeelSourceMediaReason? = nil) {
        type = PeelSourceMediaProtocol.ackType
        version = PeelSourceMediaProtocol.version
        self.requestId = requestId
        self.pairingId = pairingId
        self.windowId = windowId
        self.status = status.rawValue
        self.reason = reason?.rawValue
    }

    /// Client-side check. Unknown statuses are rejected; an unknown reason
    /// code reads as nil so a newer source cannot break an older client.
    var parsed: (status: PeelSourceMediaStatus, reason: PeelSourceMediaReason?)? {
        guard type == PeelSourceMediaProtocol.ackType,
              version == PeelSourceMediaProtocol.version,
              PeelSourceMediaProtocol.isRequestID(requestId),
              PeelSourceMediaProtocol.isPairingID(pairingId),
              let status = PeelSourceMediaStatus(rawValue: status) else { return nil }
        return (status, reason.flatMap(PeelSourceMediaReason.init(rawValue:)))
    }
}

/// Actual source state, never an optimistic echo of a requested value.
/// Values the source cannot read stay nil.
nonisolated struct PeelSourceVolumeState: Codable, Sendable {
    let type: String
    let version: Int
    /// Present on every query/set response; nil only for a future unsolicited update.
    let requestId: String?
    let pairingId: String
    let windowId: UInt32
    let scope: String
    let supported: Bool
    let canSetVolume: Bool
    let canSetMute: Bool
    let volume: Double?
    let muted: Bool?
    /// Monotonic per source process.
    let sequence: UInt64
    let reason: String?

    init(requestId: String?, pairingId: String, windowId: UInt32, scope: PeelSourceVolumeScope,
         supported: Bool, canSetVolume: Bool, canSetMute: Bool, volume: Double?, muted: Bool?,
         sequence: UInt64, reason: PeelSourceMediaReason? = nil) {
        type = PeelSourceMediaProtocol.volumeStateType
        version = PeelSourceMediaProtocol.version
        self.requestId = requestId
        self.pairingId = pairingId
        self.windowId = windowId
        self.scope = scope.rawValue
        self.supported = supported
        self.canSetVolume = supported && canSetVolume
        self.canSetMute = supported && canSetMute
        self.volume = supported ? volume.flatMap { PeelSourceMediaProtocol.isVolume($0) ? $0 : nil } : nil
        self.muted = supported ? muted : nil
        self.sequence = sequence
        self.reason = reason?.rawValue
    }

    /// Unsupported scope state: everything unreadable stays nil.
    static func unsupported(requestId: String, pairingId: String, windowId: UInt32,
                            scope: PeelSourceVolumeScope, sequence: UInt64,
                            reason: PeelSourceMediaReason = .scopeUnsupported) -> PeelSourceVolumeState {
        PeelSourceVolumeState(requestId: requestId, pairingId: pairingId, windowId: windowId, scope: scope,
                              supported: false, canSetVolume: false, canSetMute: false,
                              volume: nil, muted: nil, sequence: sequence, reason: reason)
    }

    /// Client-side check of a decoded state.
    var isValid: Bool {
        guard type == PeelSourceMediaProtocol.volumeStateType,
              version == PeelSourceMediaProtocol.version,
              requestId.map(PeelSourceMediaProtocol.isRequestID) ?? true,
              PeelSourceMediaProtocol.isPairingID(pairingId),
              PeelSourceVolumeScope(rawValue: scope) != nil,
              volume.map(PeelSourceMediaProtocol.isVolume) ?? true else { return false }
        if !supported {
            return !canSetVolume && !canSetMute && volume == nil && muted == nil
        }
        return true
    }
}
