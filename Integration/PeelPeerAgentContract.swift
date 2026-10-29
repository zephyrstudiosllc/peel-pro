//
//  PeelPeerAgentContract.swift
//  Bounded, versioned wire contract for paired-Mac agent session metadata
//  and owner-side session activation.
//
//  Foundation/CryptoKit only. Nothing here imports SidePulse; the local
//  AgentSession model is never serialized. Every value that crosses the
//  paired socket is an explicit field below with a byte bound. There is no
//  field for a working directory, message, transcript, URL, path, process
//  identifier, executable, argument list or account identity.
//

import CryptoKit
import Foundation

nonisolated public enum PeelPeerAgentFeature {
    public static let activate = "activate.v1"
    public static let agents = "agents.v1"
    public static let usage = "usage.v1"
    /// Canonical (sorted) list this build can negotiate.
    public static let all = [activate, agents, usage]
}

nonisolated public enum PeelPeerAgentLimits {
    public static let maximumLineBytes = 12_288
    /// Encoders stay below the line limit with headroom for the newline.
    public static let snapshotBudgetBytes = 11_264
    public static let maximumSessions = 24
    public static let titleBytes = 96
    public static let projectBytes = 64
    public static let toolBytes = 40
    public static let providerBytes = 24
    public static let reasonBytes = 24
    public static let appLabelBytes = 32
    public static let tokenCharacters = 22
    /// An owner snapshot older than a day is not "current" activity.
    public static let maximumAgeSeconds: Double = 86_400 * 7
}

nonisolated public enum PeelPeerAgentContractError: Error, Equatable, Sendable {
    case lineTooLarge(Int)
    case unknownType(String)
    case unsupportedVersion(Int)
    case invalidField(String)
    case tooManyEntries(String)
}

// MARK: - Bounded text

nonisolated public enum PeelPeerAgentText {
    /// Display text for the wire: control/format characters become spaces,
    /// whitespace is collapsed, and the result is cut on a Character boundary
    /// to at most `maxBytes` UTF-8 bytes.
    public static func sanitize(_ value: String, maxBytes: Int) -> String {
        var scalars = String.UnicodeScalarView()
        var lastWasSpace = true
        for scalar in value.unicodeScalars {
            let isSpace = CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.controlCharacters.contains(scalar)
                || scalar.properties.generalCategory == .format
                || scalar.properties.generalCategory == .lineSeparator
                || scalar.properties.generalCategory == .paragraphSeparator
            if isSpace {
                if !lastWasSpace { scalars.append(" ") }
                lastWasSpace = true
            } else {
                scalars.append(scalar)
                lastWasSpace = false
            }
        }
        var result = String(scalars).trimmingCharacters(in: .whitespaces)
        while result.utf8.count > maxBytes, !result.isEmpty {
            result.removeLast()
        }
        // Truncation can expose a trailing space; strict decoding requires the
        // value to be a fixed point of this function.
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Strict decode check: already sanitized and within bounds.
    public static func isValid(_ value: String, maxBytes: Int, allowEmpty: Bool = false) -> Bool {
        guard value.utf8.count <= maxBytes else { return false }
        guard allowEmpty || !value.isEmpty else { return false }
        return sanitize(value, maxBytes: maxBytes) == value
    }

    static func isIdentifier(_ value: String, maxBytes: Int) -> Bool {
        let bytes = Array(value.utf8)
        return !bytes.isEmpty && bytes.count <= maxBytes && bytes.allSatisfy {
            (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x5F || $0 == 0x2D
        }
    }

    static func isToken(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == PeelPeerAgentLimits.tokenCharacters && bytes.allSatisfy {
            (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0)
                || (0x30...0x39).contains($0) || $0 == 0x2D || $0 == 0x5F
        }
    }
}

// MARK: - Opaque identifiers

nonisolated public enum PeelPeerAgentToken {
    /// Owner-local opaque session token. The secret is minted per Host
    /// process and never leaves the owner, so a token cannot be inverted to
    /// the provider session ID and changes on every owner restart.
    public static func derive(secret: Data, provider: String, localID: String) -> String {
        var message = Data()
        append("peel.agent.token.v1", to: &message)
        append(provider, to: &message)
        append(localID, to: &message)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: secret))
        return base64URL(Data(mac).prefix(16))
    }

    /// Pair-scoped tag for values two paired Macs may need to compare
    /// (a cloud task, or an account key in the usage summary). Only holders
    /// of this pairing's PSK can compute or compare it; the raw value is
    /// never sent.
    public static func pairTag(pairKey: Data, domain: String, value: String) -> String {
        var message = Data()
        append(domain, to: &message)
        append(value, to: &message)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: pairKey))
        return base64URL(Data(mac).prefix(16))
    }

    public static func mintSecret() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    static func append(_ value: String, to data: inout Data) {
        let bytes = Array(value.utf8)
        var length = UInt32(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(contentsOf: bytes)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Enumerations with forward-compatible decoding

nonisolated public enum PeelPeerAgentState: String, Codable, Equatable, Sendable, CaseIterable {
    case idle, working, toolRunning, waiting, error, completed, unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PeelPeerAgentState(rawValue: raw) ?? .unknown
    }

    public var priority: Int {
        switch self {
        case .error: 0
        case .waiting: 1
        case .toolRunning: 2
        case .working: 3
        case .completed: 4
        case .unknown: 5
        case .idle: 6
        }
    }
}

nonisolated public enum PeelPeerActivationSupport: String, Codable, Equatable, Sendable {
    /// The owner can address this exact session (a Codex thread URL, or a
    /// verified Terminal.app tab bound to the agent's live process).
    case exactSession
    /// Only the verified owning application can be brought forward.
    case applicationOnly
    case unavailable

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PeelPeerActivationSupport(rawValue: raw) ?? .unavailable
    }
}

/// Result of an activation. Owner-produced cases travel on the wire; the
/// viewer-only cases are produced locally and never accepted from a peer.
nonisolated public enum PeelPeerActivationOutcome: String, Codable, Equatable, Sendable, CaseIterable {
    // Owner results.
    case focusedExactSession      // verified: the target tab is selected in the frontmost window
    case exactSessionRequested    // delivered to the app's own session URL; visual focus not verified
    case applicationOnly          // only the verified owning app was brought forward
    case unsupported              // no deterministic destination for this session
    case sessionEnded             // token not in the owner's current inventory, or process ended
    case staleEpoch               // owner restarted since the viewer's snapshot
    case ownerLocked
    case notAllowed               // owner disabled activation from paired Macs
    case rateLimited
    case launchFailed
    case automationDenied         // macOS Automation consent for Terminal is not granted
    case ambiguousTarget          // more than one tab/session matches; nothing was selected
    case terminalNotRunning
    case requestConflict          // request ID reused with a different payload; nothing done
    case targetChanged            // target not currently offered, or its binding changed since the viewer's row
    case unknownResult            // decoder fallback for a newer owner
    // Viewer-only results.
    case timedOut
    case ownerOffline
    case revoked
    case peerTooOld

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PeelPeerActivationOutcome(rawValue: raw) ?? .unknownResult
    }

    public static let viewerOnly: Set<PeelPeerActivationOutcome> = [.timedOut, .ownerOffline, .revoked, .peerTooOld]

    public var isSuccess: Bool {
        switch self {
        case .focusedExactSession, .exactSessionRequested, .applicationOnly: true
        default: false
        }
    }
}

// MARK: - Session snapshot (owner → viewer)

nonisolated public struct PeelPeerAgentSession: Codable, Equatable, Sendable {
    public var token: String
    public var provider: String
    public var title: String
    public var project: String
    public var state: PeelPeerAgentState
    public var tool: String?
    /// Owner-side age of the last event, measured on the owner's own clock.
    public var ageSeconds: Double
    public var alert: Bool
    public var activation: PeelPeerActivationSupport
    /// Short code explaining `unavailable`/`applicationOnly`, e.g. "headless".
    public var reason: String?
    /// Pair-scoped tag for a cloud task visible to both Macs; nil otherwise.
    public var cloudTag: String?
    /// Owner-assigned revision of THIS target's activation binding (process,
    /// terminal, destination, capability). It changes only when that binding
    /// changes, so unrelated rows updating never invalidate a click.
    public var bindingRevision: UInt64

    public init(token: String, provider: String, title: String, project: String,
                state: PeelPeerAgentState, tool: String?, ageSeconds: Double, alert: Bool,
                activation: PeelPeerActivationSupport, reason: String?, cloudTag: String?,
                bindingRevision: UInt64 = 0) {
        self.token = token
        self.provider = provider
        self.title = title
        self.project = project
        self.state = state
        self.tool = tool
        self.ageSeconds = ageSeconds
        self.alert = alert
        self.activation = activation
        self.reason = reason
        self.cloudTag = cloudTag
        self.bindingRevision = bindingRevision
    }

    func validate() throws {
        guard PeelPeerAgentText.isToken(token) else { throw PeelPeerAgentContractError.invalidField("token") }
        guard PeelPeerAgentText.isIdentifier(provider, maxBytes: PeelPeerAgentLimits.providerBytes) else {
            throw PeelPeerAgentContractError.invalidField("provider")
        }
        guard PeelPeerAgentText.isValid(title, maxBytes: PeelPeerAgentLimits.titleBytes) else {
            throw PeelPeerAgentContractError.invalidField("title")
        }
        guard PeelPeerAgentText.isValid(project, maxBytes: PeelPeerAgentLimits.projectBytes, allowEmpty: true) else {
            throw PeelPeerAgentContractError.invalidField("project")
        }
        if let tool, !PeelPeerAgentText.isValid(tool, maxBytes: PeelPeerAgentLimits.toolBytes) {
            throw PeelPeerAgentContractError.invalidField("tool")
        }
        guard ageSeconds.isFinite, ageSeconds >= 0, ageSeconds <= PeelPeerAgentLimits.maximumAgeSeconds else {
            throw PeelPeerAgentContractError.invalidField("ageSeconds")
        }
        if let reason, !PeelPeerAgentText.isIdentifier(reason, maxBytes: PeelPeerAgentLimits.reasonBytes) {
            throw PeelPeerAgentContractError.invalidField("reason")
        }
        if let cloudTag, !PeelPeerAgentText.isToken(cloudTag) {
            throw PeelPeerAgentContractError.invalidField("cloudTag")
        }
    }
}

nonisolated public struct PeelPeerAgentSnapshot: Codable, Equatable, Sendable {
    public static let messageType = "peelAgentSnapshot"
    public static let version = 1

    public var type: String
    public var v: Int
    public var bootEpoch: UUID
    public var revision: UInt64
    /// Owner clock, for display only; freshness uses the viewer's clock.
    public var generatedAt: Double
    public var truncated: Int
    public var sessions: [PeelPeerAgentSession]
    /// Whether this owner's agent harnesses actually report to it (e.g.
    /// Claude Code hooks installed or not). Optional; older owners omit it.
    public var integrations: [PeelPeerProviderIntegration]?

    public init(bootEpoch: UUID, revision: UInt64, generatedAt: Double, truncated: Int,
                sessions: [PeelPeerAgentSession], integrations: [PeelPeerProviderIntegration]? = nil) {
        type = Self.messageType
        v = Self.version
        self.bootEpoch = bootEpoch
        self.revision = revision
        self.generatedAt = generatedAt
        self.truncated = truncated
        self.sessions = sessions
        self.integrations = integrations
    }

    func validate() throws {
        guard type == Self.messageType else { throw PeelPeerAgentContractError.unknownType(type) }
        guard v == Self.version else { throw PeelPeerAgentContractError.unsupportedVersion(v) }
        guard generatedAt.isFinite, truncated >= 0, truncated <= 10_000 else {
            throw PeelPeerAgentContractError.invalidField("snapshot")
        }
        guard sessions.count <= PeelPeerAgentLimits.maximumSessions else {
            throw PeelPeerAgentContractError.tooManyEntries("sessions")
        }
        var seen = Set<String>()
        for session in sessions {
            try session.validate()
            guard seen.insert(session.token).inserted else {
                throw PeelPeerAgentContractError.invalidField("duplicate token")
            }
        }
        if let integrations {
            guard integrations.count <= PeelPeerProviderIntegration.maximumCount else {
                throw PeelPeerAgentContractError.tooManyEntries("integrations")
            }
            try integrations.forEach { try $0.validate() }
        }
    }
}

/// Whether an agent harness reports to its owner. Display only.
nonisolated public struct PeelPeerProviderIntegration: Codable, Equatable, Sendable {
    public static let maximumCount = 6
    public enum State: String, Codable, Equatable, Sendable {
        case active, ready, needsSetup, unknown
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = State(rawValue: raw) ?? .unknown
        }
    }
    public var provider: String
    public var state: State

    public init(provider: String, state: State) {
        self.provider = provider
        self.state = state
    }

    func validate() throws {
        guard PeelPeerAgentText.isIdentifier(provider, maxBytes: PeelPeerAgentLimits.providerBytes) else {
            throw PeelPeerAgentContractError.invalidField("integration")
        }
    }
}

nonisolated public struct PeelPeerAgentKeepalive: Codable, Equatable, Sendable {
    public static let messageType = "peelAgentKeepalive"
    public var type: String
    public var bootEpoch: UUID
    public var revision: UInt64

    public init(bootEpoch: UUID, revision: UInt64) {
        type = Self.messageType
        self.bootEpoch = bootEpoch
        self.revision = revision
    }
}

// MARK: - Activation (viewer → owner → viewer)

/// The only activation input an owner accepts: an opaque token it minted,
/// the owner boot epoch and the target's `bindingRevision` the viewer last
/// saw. No URL, path, PID, executable, argument, command, owner identity or
/// label is accepted.
nonisolated public struct PeelPeerAgentActivate: Codable, Equatable, Sendable {
    public static let messageType = "peelAgentActivate"
    public var type: String
    public var requestId: UUID
    public var token: String
    public var bootEpoch: UUID
    public var revision: UInt64

    public init(requestId: UUID, token: String, bootEpoch: UUID, revision: UInt64) {
        type = Self.messageType
        self.requestId = requestId
        self.token = token
        self.bootEpoch = bootEpoch
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey { case type, requestId, token, bootEpoch, revision }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Reject any message carrying keys beyond the fixed schema, so a
        // future or hostile peer cannot smuggle a destination alongside.
        let extra = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
        guard Set(extra).isSubset(of: ["type", "requestId", "token", "bootEpoch", "revision"]) else {
            throw PeelPeerAgentContractError.invalidField("unexpected key")
        }
        type = try values.decode(String.self, forKey: .type)
        requestId = try values.decode(UUID.self, forKey: .requestId)
        token = try values.decode(String.self, forKey: .token)
        bootEpoch = try values.decode(UUID.self, forKey: .bootEpoch)
        revision = try values.decode(UInt64.self, forKey: .revision)
        guard type == Self.messageType else { throw PeelPeerAgentContractError.unknownType(type) }
        guard PeelPeerAgentText.isToken(token) else { throw PeelPeerAgentContractError.invalidField("token") }
    }
}

nonisolated public struct PeelPeerAgentActivateResult: Codable, Equatable, Sendable {
    public static let messageType = "peelAgentActivateResult"
    public var type: String
    public var requestId: UUID
    public var outcome: PeelPeerActivationOutcome
    /// Owner's label for the app that handled the request ("Terminal",
    /// "Codex"). Display only.
    public var appLabel: String?

    public init(requestId: UUID, outcome: PeelPeerActivationOutcome, appLabel: String? = nil) {
        type = Self.messageType
        self.requestId = requestId
        self.outcome = outcome
        self.appLabel = appLabel.map { PeelPeerAgentText.sanitize($0, maxBytes: PeelPeerAgentLimits.appLabelBytes) }
    }

    func validate() throws {
        guard type == Self.messageType else { throw PeelPeerAgentContractError.unknownType(type) }
        guard !PeelPeerActivationOutcome.viewerOnly.contains(outcome) else {
            throw PeelPeerAgentContractError.invalidField("outcome")
        }
        if let appLabel, !PeelPeerAgentText.isValid(appLabel, maxBytes: PeelPeerAgentLimits.appLabelBytes) {
            throw PeelPeerAgentContractError.invalidField("appLabel")
        }
    }
}

nonisolated struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.stringValue = "\(intValue)"; self.intValue = intValue }
}

// MARK: - Line codec

nonisolated public enum PeelPeerAgentMessage: Equatable, Sendable {
    case snapshot(PeelPeerAgentSnapshot)
    case keepalive(PeelPeerAgentKeepalive)
    case activate(PeelPeerAgentActivate)
    case activateResult(PeelPeerAgentActivateResult)
    case usage(PeelPeerUsageSummary)
}

nonisolated public enum PeelPeerAgentWire {
    private struct TypeProbe: Decodable { let type: String }

    public static let messageTypes: Set<String> = [
        PeelPeerAgentSnapshot.messageType, PeelPeerAgentKeepalive.messageType,
        PeelPeerAgentActivate.messageType, PeelPeerAgentActivateResult.messageType,
        PeelPeerUsageSummary.messageType,
    ]

    /// Returns the `type` of a JSON line without decoding its body.
    public static func messageType(of line: Data) -> String? {
        guard line.count <= PeelPeerAgentLimits.maximumLineBytes else { return nil }
        return (try? JSONDecoder().decode(TypeProbe.self, from: line))?.type
    }

    public static func decode(_ line: Data) throws -> PeelPeerAgentMessage {
        guard line.count <= PeelPeerAgentLimits.maximumLineBytes else {
            throw PeelPeerAgentContractError.lineTooLarge(line.count)
        }
        let decoder = JSONDecoder()
        let type = try decoder.decode(TypeProbe.self, from: line).type
        switch type {
        case PeelPeerAgentSnapshot.messageType:
            let value = try decoder.decode(PeelPeerAgentSnapshot.self, from: line)
            try value.validate()
            return .snapshot(value)
        case PeelPeerAgentKeepalive.messageType:
            return .keepalive(try decoder.decode(PeelPeerAgentKeepalive.self, from: line))
        case PeelPeerAgentActivate.messageType:
            return .activate(try decoder.decode(PeelPeerAgentActivate.self, from: line))
        case PeelPeerAgentActivateResult.messageType:
            let value = try decoder.decode(PeelPeerAgentActivateResult.self, from: line)
            try value.validate()
            return .activateResult(value)
        case PeelPeerUsageSummary.messageType:
            let value = try decoder.decode(PeelPeerUsageSummary.self, from: line)
            try value.validate()
            return .usage(value)
        default:
            throw PeelPeerAgentContractError.unknownType(type)
        }
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let data = try JSONEncoder().encode(value)
        guard data.count < PeelPeerAgentLimits.maximumLineBytes else {
            throw PeelPeerAgentContractError.lineTooLarge(data.count)
        }
        return data
    }

    /// The feature a message requires on the socket that carries it.
    public static func requiredFeature(for message: PeelPeerAgentMessage) -> String {
        switch message {
        case .snapshot, .keepalive: PeelPeerAgentFeature.agents
        case .activate, .activateResult: PeelPeerAgentFeature.activate
        case .usage: PeelPeerAgentFeature.usage
        }
    }
}
