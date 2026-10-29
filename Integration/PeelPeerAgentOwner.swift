//
//  PeelPeerAgentOwner.swift
//  Owner-side projection of local agent sessions into the bounded wire
//  snapshot, the offered-target registry, and per-peer activation admission.
//
//  Pure value logic (no sockets, no SidePulse types) so it can be checked in
//  isolation. The Host adapter converts SidePulse sessions into
//  `PeelPeerAgentLocalSession`; only the fields below are ever projected.
//

import Foundation

/// The neutral, already-reduced view of one local session. Built in process
/// by the Host from SidePulse's runtime; never encoded directly.
nonisolated public struct PeelPeerAgentLocalSession: Equatable, Sendable {
    public var localID: String
    public var provider: String
    public var title: String
    public var project: String
    public var state: PeelPeerAgentState
    public var tool: String?
    public var updatedAt: Date
    public var alert: Bool
    public var activation: PeelPeerActivationSupport
    public var reason: String?
    /// Provider-global cloud task identity, for pair-scoped dedup only.
    public var cloudTaskID: String?
    /// Owner-local fingerprint of what an activation would act on (verified
    /// process/terminal identity or destination). Never sent; any change
    /// gives the target a new `bindingRevision`.
    public var bindingKey: String?

    public init(localID: String, provider: String, title: String, project: String, state: PeelPeerAgentState,
                tool: String?, updatedAt: Date, alert: Bool, activation: PeelPeerActivationSupport,
                reason: String?, cloudTaskID: String?, bindingKey: String? = nil) {
        self.localID = localID
        self.provider = provider
        self.title = title
        self.project = project
        self.state = state
        self.tool = tool
        self.updatedAt = updatedAt
        self.alert = alert
        self.activation = activation
        self.reason = reason
        self.cloudTaskID = cloudTaskID
        self.bindingKey = bindingKey
    }
}

nonisolated public struct PeelPeerAgentOwnerState: Sendable {
    public static let cloudTagDomain = "peel.agent.cloud.v1"
    /// Same-length stand-in used only to size cloud tags while selecting rows.
    private static let sizingKey = Data(repeating: 0, count: 32)

    public enum TargetCheck: Equatable, Sendable {
        case current(localID: String)
        /// Not in the rows this owner currently offers (ended, never offered,
        /// or dropped by the bound).
        case notOffered
        /// Offered, but its binding revision differs from the request's.
        case bindingChanged
    }

    public let bootEpoch: UUID
    private let secret: Data
    /// Inventory revision: advances whenever the offered projection changes.
    public private(set) var revision: UInt64 = 0
    private var sessions: [PeelPeerAgentLocalSession] = []
    private var integrations: [PeelPeerProviderIntegration] = []
    /// Exactly the rows (in order) the last snapshot offers.
    private var offered: [PeelPeerAgentLocalSession] = []
    private var offeredTruncated = 0
    private var offeredTargets: [String: (localID: String, bindingRevision: UInt64)] = [:]
    private var bindings: [String: (fingerprint: String, revision: UInt64)] = [:]
    private var nextBindingRevision: UInt64 = 1

    public init(bootEpoch: UUID = UUID(), secret: Data = PeelPeerAgentToken.mintSecret()) {
        self.bootEpoch = bootEpoch
        self.secret = secret
    }

    /// Replaces the local inventory. Returns true when the offered projection
    /// changed (and the inventory revision advanced).
    @discardableResult
    public mutating func update(_ next: [PeelPeerAgentLocalSession],
                                integrations nextIntegrations: [PeelPeerProviderIntegration] = []) -> Bool {
        let sanitized = next.compactMap(Self.sanitized)
        var unique: [PeelPeerAgentLocalSession] = []
        var seen = Set<String>()
        for session in sanitized where seen.insert(session.localID).inserted { unique.append(session) }
        let integrationsBounded = Array(nextIntegrations.filter {
            PeelPeerAgentText.isIdentifier($0.provider, maxBytes: PeelPeerAgentLimits.providerBytes)
        }.prefix(PeelPeerProviderIntegration.maximumCount))

        // Binding revisions: a target keeps its revision until ITS activation
        // binding changes; unrelated rows never affect it.
        var nextBindings: [String: (fingerprint: String, revision: UInt64)] = [:]
        for session in unique {
            let fingerprint = Self.bindingFingerprint(session)
            if let existing = bindings[session.localID], existing.fingerprint == fingerprint {
                nextBindings[session.localID] = existing
            } else {
                nextBindings[session.localID] = (fingerprint, nextBindingRevision)
                nextBindingRevision &+= 1
            }
        }
        let bindingsChanged = nextBindings.count != bindings.count || nextBindings.contains { id, value in
            bindings[id]?.revision != value.revision
        }
        guard unique != sessions || integrationsBounded != integrations || bindingsChanged else { return false }
        sessions = unique
        integrations = integrationsBounded
        bindings = nextBindings
        selectOffered()
        revision &+= 1
        return true
    }

    public func token(provider: String, localID: String) -> String {
        PeelPeerAgentToken.derive(secret: secret, provider: provider, localID: localID)
    }

    /// Resolves only rows CURRENTLY offered, at the binding revision the
    /// viewer saw. Future, stale or never-offered targets are refused.
    public func check(token: String, bindingRevision: UInt64) -> TargetCheck {
        guard let target = offeredTargets[token] else { return .notOffered }
        return target.bindingRevision == bindingRevision ? .current(localID: target.localID) : .bindingChanged
    }

    public var sessionCount: Int { sessions.count }
    public var offeredCount: Int { offered.count }

    /// Builds the per-socket snapshot of exactly the offered rows. Cloud tags
    /// depend on that socket's pairing key; all else is identical per viewer.
    public func snapshot(now: Date, pairKey: Data?) -> PeelPeerAgentSnapshot {
        PeelPeerAgentSnapshot(bootEpoch: bootEpoch, revision: revision, generatedAt: now.timeIntervalSince1970,
                              truncated: offeredTruncated,
                              sessions: offered.map { wire($0, now: now, pairKey: pairKey) },
                              integrations: integrations.isEmpty ? nil : integrations)
    }

    private func wire(_ session: PeelPeerAgentLocalSession, now: Date, pairKey: Data?) -> PeelPeerAgentSession {
        PeelPeerAgentSession(
            token: token(provider: session.provider, localID: session.localID),
            provider: session.provider,
            title: session.title,
            project: session.project,
            state: session.state,
            tool: session.tool,
            ageSeconds: min(PeelPeerAgentLimits.maximumAgeSeconds, max(0, now.timeIntervalSince(session.updatedAt))),
            alert: session.alert,
            activation: session.activation,
            reason: session.reason,
            cloudTag: session.cloudTaskID.flatMap { id in
                pairKey.map { PeelPeerAgentToken.pairTag(pairKey: $0, domain: Self.cloudTagDomain, value: id) }
            },
            bindingRevision: bindings[session.localID]?.revision ?? 0)
    }

    /// Deterministic selection: attention first, then most recent; then
    /// drop lowest-priority rows until the encoded line fits. Sizing uses the
    /// worst case (maximum age digits, same-length cloud tag).
    private mutating func selectOffered() {
        let ordered = sessions.sorted {
            if $0.state.priority != $1.state.priority { return $0.state.priority < $1.state.priority }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.localID < $1.localID
        }
        var chosen = Array(ordered.prefix(PeelPeerAgentLimits.maximumSessions))
        let sizingDate = Date(timeIntervalSince1970: 9_999_999_999.123_456)
        while !chosen.isEmpty {
            var probe = PeelPeerAgentSnapshot(bootEpoch: bootEpoch, revision: UInt64.max,
                                              generatedAt: sizingDate.timeIntervalSince1970,
                                              truncated: ordered.count,
                                              sessions: chosen.map { wire($0, now: sizingDate, pairKey: Self.sizingKey) },
                                              integrations: integrations.isEmpty ? nil : integrations)
            for index in probe.sessions.indices {
                probe.sessions[index].ageSeconds = PeelPeerAgentLimits.maximumAgeSeconds - 0.123_456_789
                probe.sessions[index].bindingRevision = UInt64.max
            }
            if let data = try? JSONEncoder().encode(probe), data.count <= PeelPeerAgentLimits.snapshotBudgetBytes {
                break
            }
            chosen.removeLast()
        }
        offered = chosen
        offeredTruncated = ordered.count - chosen.count
        var targets: [String: (localID: String, bindingRevision: UInt64)] = [:]
        for session in chosen {
            targets[token(provider: session.provider, localID: session.localID)] =
                (session.localID, bindings[session.localID]?.revision ?? 0)
        }
        offeredTargets = targets
    }

    static func bindingFingerprint(_ session: PeelPeerAgentLocalSession) -> String {
        [session.provider, session.activation.rawValue, session.reason ?? "", session.bindingKey ?? ""]
            .map { "\($0.utf8.count):\($0)" }.joined()
    }

    static func sanitized(_ session: PeelPeerAgentLocalSession) -> PeelPeerAgentLocalSession? {
        let provider = session.provider.lowercased()
        guard !session.localID.isEmpty, session.localID.utf8.count <= 512,
              PeelPeerAgentText.isIdentifier(provider, maxBytes: PeelPeerAgentLimits.providerBytes) else { return nil }
        var copy = session
        copy.provider = provider
        let title = PeelPeerAgentText.sanitize(session.title, maxBytes: PeelPeerAgentLimits.titleBytes)
        copy.title = title.isEmpty ? provider : title
        // Project is a display basename only; a path never crosses the wire.
        let base = session.project.split(separator: "/").last.map(String.init) ?? ""
        copy.project = PeelPeerAgentText.sanitize(base, maxBytes: PeelPeerAgentLimits.projectBytes)
        copy.tool = session.tool.map { PeelPeerAgentText.sanitize($0, maxBytes: PeelPeerAgentLimits.toolBytes) }
            .flatMap { $0.isEmpty ? nil : $0 }
        copy.reason = session.reason.flatMap {
            PeelPeerAgentText.isIdentifier($0, maxBytes: PeelPeerAgentLimits.reasonBytes) ? $0 : nil
        }
        return copy
    }
}

// MARK: - Activation admission (owner side, one per authenticated peer)

/// Replay and rate authority for one authenticated paired Mac. The Host keeps
/// one per peer for the owner process lifetime; it survives socket reconnects
/// and is discarded only when that peer's trust/key changes.
///
/// Guarantee: within `retentionSeconds`, a request ID is executed at most
/// once. Every remembered admission (successful or not) counts against
/// `admissionsPerSecond`, so capacity (`capacity`) always exceeds what can be
/// admitted inside the retention window; if it were ever full of unexpired
/// entries, new requests are refused rather than evicting anything.
nonisolated public struct PeelPeerActivationGuard: Sendable {
    public enum Decision: Equatable, Sendable {
        /// Execute exactly once for this request ID.
        case execute(localID: String)
        /// Already finished with the same payload: resend the cached result.
        case replay(PeelPeerActivationOutcome)
        /// Already executing with the same payload: stay silent; one result follows.
        case inFlight
        /// Remembered rejection: the ID is now spent for the retention window.
        case reject(PeelPeerActivationOutcome)
        /// Not admitted and not remembered (rate/capacity/conflict); no effect.
        case refuse(PeelPeerActivationOutcome)
    }

    public struct Fingerprint: Equatable, Sendable {
        public var token: String
        public var bootEpoch: UUID
        public var bindingRevision: UInt64

        public init(_ request: PeelPeerAgentActivate) {
            token = request.token
            bootEpoch = request.bootEpoch
            bindingRevision = request.revision
        }
    }

    public static let retentionSeconds: TimeInterval = 120
    public static let admissionsPerSecond = 2
    public static let maximumInFlight = 4
    /// 2/s × 120 s = 240 remembered admissions, plus pinned in-flight entries.
    public static let capacity = 256

    private struct Entry: Sendable {
        var fingerprint: Fingerprint
        var outcome: PeelPeerActivationOutcome?
        var at: Date
    }

    private var entries: [UUID: Entry] = [:]
    private var recentAdmissions: [Date] = []

    public init() {}

    public var rememberedCount: Int { entries.count }

    public mutating func admit(_ request: PeelPeerAgentActivate, owner: PeelPeerAgentOwnerState,
                               now: Date) -> Decision {
        prune(now: now)
        let fingerprint = Fingerprint(request)
        if let existing = entries[request.requestId] {
            // A reused ID must carry the identical payload; it never changes
            // or reveals the original request's result.
            guard existing.fingerprint == fingerprint else { return .refuse(.requestConflict) }
            return existing.outcome.map(Decision.replay) ?? .inFlight
        }
        guard recentAdmissions.count < Self.admissionsPerSecond, entries.count < Self.capacity else {
            return .refuse(.rateLimited)
        }
        recentAdmissions.append(now)

        let decision: Decision
        if request.bootEpoch != owner.bootEpoch {
            decision = .reject(.staleEpoch)
        } else if entries.values.filter({ $0.outcome == nil }).count >= Self.maximumInFlight {
            decision = .reject(.rateLimited)
        } else {
            switch owner.check(token: request.token, bindingRevision: request.revision) {
            case .current(let localID): decision = .execute(localID: localID)
            case .notOffered: decision = .reject(.sessionEnded)
            case .bindingChanged: decision = .reject(.targetChanged)
            }
        }
        switch decision {
        case .execute:
            entries[request.requestId] = Entry(fingerprint: fingerprint, outcome: nil, at: now)
        case .reject(let outcome):
            entries[request.requestId] = Entry(fingerprint: fingerprint, outcome: outcome, at: now)
        case .replay, .inFlight, .refuse:
            break
        }
        return decision
    }

    /// Records the single result. Returns false if the request is unknown or
    /// already completed, so a caller can never send two results.
    @discardableResult
    public mutating func complete(_ requestID: UUID, outcome: PeelPeerActivationOutcome, now: Date) -> Bool {
        guard var entry = entries[requestID], entry.outcome == nil else { return false }
        entry.outcome = outcome
        entry.at = now
        entries[requestID] = entry
        return true
    }

    private mutating func prune(now: Date) {
        recentAdmissions.removeAll { now.timeIntervalSince($0) >= 1 }
        // Only expired, completed entries are dropped; in-flight stay pinned.
        entries = entries.filter { _, entry in
            entry.outcome == nil || now.timeIntervalSince(entry.at) <= Self.retentionSeconds
        }
    }
}

// MARK: - Writer turns (owner side, one per authenticated socket)

/// The owner-side lanes that share one socket writer. Control replies are
/// not a lane: their small bounded queue always drains first.
nonisolated public enum PeelPeerWriterLane: CaseIterable, Sendable {
    case frame, agents, usage
}

/// A socket has one write in flight at a time. Each time the writer is free,
/// every lane is offered a turn starting after the lane that wrote last, so
/// a lane that is always due (LED frames, a constantly changing agent list)
/// can never starve the others. Each lane keeps its own rate gate; a lane
/// with nothing due declines and the next lane is offered.
nonisolated public enum PeelPeerWriterTurns {
    /// Returns the lane that wrote, or nil when no lane had anything due.
    public static func next(after last: PeelPeerWriterLane?,
                            write: (PeelPeerWriterLane) -> Bool) -> PeelPeerWriterLane? {
        let lanes = PeelPeerWriterLane.allCases
        let start = last.flatMap { lanes.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        for offset in lanes.indices {
            let lane = lanes[(start + offset) % lanes.count]
            if write(lane) { return lane }
        }
        return nil
    }
}
