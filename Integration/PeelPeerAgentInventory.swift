//
//  PeelPeerAgentInventory.swift
//  Viewer-side reducer for paired owners' agent snapshots, usage summaries
//  and pending activation requests.
//
//  Pure value logic. The owner identity is always the authenticated host ID
//  of the socket that delivered a message; labels are display-only and never
//  select a route. Snapshots are full state: a missing token is a removed
//  session, and losing the connection never turns a session into Done.
//

import Foundation

nonisolated public struct PeelPeerAgentKey: Hashable, Sendable {
    public var ownerHostID: UUID
    public var provider: String
    public var token: String

    public init(ownerHostID: UUID, provider: String, token: String) {
        self.ownerHostID = ownerHostID
        self.provider = provider
        self.token = token
    }

    /// Row identity namespaced away from every local `AgentSession.id`.
    public var rowID: String { "peer:\(ownerHostID.uuidString.lowercased()):\(provider):\(token)" }
}

nonisolated public enum PeelPeerOwnerConnection: Equatable, Sendable {
    case live
    case reconnecting(since: Date)
    case offline(since: Date)
}

nonisolated public struct PeelPeerAgentRowModel: Equatable, Sendable {
    public var key: PeelPeerAgentKey
    public var ownerLabel: String
    public var session: PeelPeerAgentSession
    /// Owner event time translated onto the viewer's clock.
    public var estimatedUpdatedAt: Date
    public var connection: PeelPeerOwnerConnection
    public var bootEpoch: UUID
    public var revision: UInt64
    /// The same cloud task is already shown as a local row on this Mac.
    public var duplicatesLocalCloudTask: Bool
}

nonisolated public struct PeelPeerAgentInventory: Sendable {
    public static let reconnectingSeconds: TimeInterval = 60
    public static let offlineRetentionSeconds: TimeInterval = 15 * 60
    public static let liveSilenceSeconds: TimeInterval = 15

    public enum ApplyResult: Equatable, Sendable {
        case applied
        case unchanged
        /// Protocol violation on this socket; the caller closes it.
        case violation(String)
    }

    public struct Owner: Sendable {
        public var hostID: UUID
        public var label: String
        public var socketID: UUID?
        public var bootEpoch: UUID
        public var revision: UInt64
        public var sessions: [PeelPeerAgentSession]
        public var truncated: Int
        public var snapshotReceivedAt: Date
        public var lastMessageAt: Date
        public var connection: PeelPeerOwnerConnection
        public var usage: PeelPeerUsageSummary?
        public var usageReceivedAt: Date?
        /// Owner-reported harness instrumentation (display only).
        public var integrations: [PeelPeerProviderIntegration] = []
    }

    public private(set) var owners: [UUID: Owner] = [:]

    public init() {}

    public mutating func applySnapshot(_ snapshot: PeelPeerAgentSnapshot, hostID: UUID, label: String,
                                       socketID: UUID, now: Date) -> ApplyResult {
        if var owner = owners[hostID] {
            if owner.socketID == socketID {
                guard snapshot.bootEpoch == owner.bootEpoch else { return .violation("epoch changed on socket") }
                guard snapshot.revision >= owner.revision else { return .violation("revision regressed") }
                if snapshot.revision == owner.revision, snapshot.sessions != owner.sessions {
                    return .violation("same revision, different rows")
                }
            } else if snapshot.bootEpoch == owner.bootEpoch, snapshot.revision < owner.revision {
                return .violation("stale revision on new socket")
            }
            let changed = owner.socketID != socketID || snapshot.revision != owner.revision
                || owner.sessions != snapshot.sessions || owner.connection != .live
            owner.label = label
            owner.socketID = socketID
            owner.bootEpoch = snapshot.bootEpoch
            owner.revision = snapshot.revision
            owner.sessions = snapshot.sessions
            owner.integrations = snapshot.integrations ?? []
            owner.truncated = snapshot.truncated
            owner.snapshotReceivedAt = now
            owner.lastMessageAt = now
            owner.connection = .live
            if owner.usage?.bootEpoch != snapshot.bootEpoch {
                owner.usage = nil
                owner.usageReceivedAt = nil
            }
            owners[hostID] = owner
            return changed ? .applied : .unchanged
        }
        owners[hostID] = Owner(hostID: hostID, label: label, socketID: socketID, bootEpoch: snapshot.bootEpoch,
                               revision: snapshot.revision, sessions: snapshot.sessions,
                               truncated: snapshot.truncated, snapshotReceivedAt: now, lastMessageAt: now,
                               connection: .live, usage: nil, usageReceivedAt: nil,
                               integrations: snapshot.integrations ?? [])
        return .applied
    }

    public mutating func applyKeepalive(_ keepalive: PeelPeerAgentKeepalive, hostID: UUID, socketID: UUID,
                                        now: Date) -> ApplyResult {
        guard var owner = owners[hostID], owner.socketID == socketID else { return .unchanged }
        guard keepalive.bootEpoch == owner.bootEpoch, keepalive.revision == owner.revision else {
            return .violation("keepalive does not match snapshot")
        }
        owner.lastMessageAt = now
        let changed = owner.connection != .live
        owner.connection = .live
        owners[hostID] = owner
        return changed ? .applied : .unchanged
    }

    public mutating func applyUsage(_ usage: PeelPeerUsageSummary, hostID: UUID, socketID: UUID,
                                    now: Date) -> ApplyResult {
        guard var owner = owners[hostID], owner.socketID == socketID else { return .unchanged }
        guard usage.bootEpoch == owner.bootEpoch else { return .violation("usage epoch mismatch") }
        if let previous = owner.usage, usage.revision < previous.revision {
            return .violation("usage revision regressed")
        }
        let changed = owner.usage != usage
        owner.usage = usage
        owner.usageReceivedAt = now
        owner.lastMessageAt = now
        owners[hostID] = owner
        return changed ? .applied : .unchanged
    }

    /// A closed socket keeps the last states, marked as reconnecting. Late
    /// messages from that socket are ignored because the socket ID no longer
    /// matches.
    @discardableResult
    public mutating func socketClosed(hostID: UUID, socketID: UUID, now: Date) -> Bool {
        guard var owner = owners[hostID], owner.socketID == socketID else { return false }
        owner.socketID = nil
        owner.connection = .reconnecting(since: now)
        owners[hostID] = owner
        return true
    }

    /// Revocation or key replacement: everything from removed owners goes.
    @discardableResult
    public mutating func retainOnly(trustedHostIDs: Set<UUID>) -> Bool {
        let removed = owners.keys.filter { !trustedHostIDs.contains($0) }
        for id in removed { owners[id] = nil }
        return !removed.isEmpty
    }

    public mutating func relabel(hostID: UUID, label: String) {
        owners[hostID]?.label = label
    }

    /// Advances freshness on the viewer clock. Returns true if anything changed.
    @discardableResult
    public mutating func tick(now: Date) -> Bool {
        var changed = false
        for (id, owner) in owners {
            switch owner.connection {
            case .live:
                if now.timeIntervalSince(owner.lastMessageAt) > Self.liveSilenceSeconds {
                    owners[id]?.connection = .reconnecting(since: owner.lastMessageAt)
                    changed = true
                }
            case .reconnecting(let since):
                if now.timeIntervalSince(since) > Self.reconnectingSeconds {
                    owners[id]?.connection = .offline(since: since)
                    changed = true
                }
            case .offline(let since):
                if now.timeIntervalSince(since) > Self.offlineRetentionSeconds {
                    owners[id] = nil
                    changed = true
                }
            }
        }
        return changed
    }

    /// Current rows. `isLocalCloudTask(hostID, tag)` lets the caller mark a
    /// remote cloud task that is already shown locally (pair-scoped tag).
    public func rows(isLocalCloudTask: (UUID, String) -> Bool = { _, _ in false }) -> [PeelPeerAgentRowModel] {
        owners.values.sorted {
            switch $0.label.localizedCaseInsensitiveCompare($1.label) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: $0.hostID.uuidString < $1.hostID.uuidString
            }
        }.flatMap { owner in
            owner.sessions.map { session in
                PeelPeerAgentRowModel(
                    key: PeelPeerAgentKey(ownerHostID: owner.hostID, provider: session.provider, token: session.token),
                    ownerLabel: owner.label,
                    session: session,
                    estimatedUpdatedAt: owner.snapshotReceivedAt.addingTimeInterval(-session.ageSeconds),
                    connection: owner.connection,
                    bootEpoch: owner.bootEpoch,
                    revision: owner.revision,
                    duplicatesLocalCloudTask: session.cloudTag.map { isLocalCloudTask(owner.hostID, $0) } ?? false)
            }
        }
    }

    public func row(for key: PeelPeerAgentKey) -> PeelPeerAgentRowModel? {
        guard let owner = owners[key.ownerHostID],
              let session = owner.sessions.first(where: { $0.token == key.token && $0.provider == key.provider })
        else { return nil }
        return PeelPeerAgentRowModel(key: key, ownerLabel: owner.label, session: session,
                                     estimatedUpdatedAt: owner.snapshotReceivedAt.addingTimeInterval(-session.ageSeconds),
                                     connection: owner.connection, bootEpoch: owner.bootEpoch,
                                     revision: owner.revision, duplicatesLocalCloudTask: false)
    }

    /// What this Mac currently holds from one owner, on the viewer clock.
    /// Only accepted snapshot/usage messages set the dates; keepalives never
    /// do. Counts describe the received payload, not what is displayed.
    public struct OwnerReceipt: Equatable, Sendable {
        public var snapshotReceivedAt: Date
        /// Sessions in the applied snapshot (may be 0).
        public var sessionsInSnapshot: Int
        /// Sessions the owner had but could not fit (`truncated`).
        public var sessionsNotIncluded: Int
        /// Snapshot sessions hidden because the same cloud task is local.
        public var sessionsAlsoLocal: Int
        public var connection: PeelPeerOwnerConnection
        /// Nil when no usage summary is held for the current boot epoch.
        public var usageReceivedAt: Date?
        /// Quota plus observed entries in the summary (not displayed lines).
        public var usageRowsIncluded: Int
        public var usageRowsNotIncluded: Int
    }

    /// Nil when no applied snapshot is currently retained for `hostID`.
    public func receipt(for hostID: UUID,
                        isLocalCloudTask: (UUID, String) -> Bool = { _, _ in false }) -> OwnerReceipt? {
        guard let owner = owners[hostID] else { return nil }
        let alsoLocal = owner.sessions.filter { session in
            session.cloudTag.map { isLocalCloudTask(hostID, $0) } ?? false
        }.count
        var receipt = OwnerReceipt(snapshotReceivedAt: owner.snapshotReceivedAt,
                                   sessionsInSnapshot: owner.sessions.count,
                                   sessionsNotIncluded: owner.truncated, sessionsAlsoLocal: alsoLocal,
                                   connection: owner.connection, usageReceivedAt: nil,
                                   usageRowsIncluded: 0, usageRowsNotIncluded: 0)
        if let usage = owner.usage, let receivedAt = owner.usageReceivedAt {
            receipt.usageReceivedAt = receivedAt
            receipt.usageRowsIncluded = usage.quotas.count + usage.observed.count
            receipt.usageRowsNotIncluded = usage.omittedQuotas + usage.omittedObserved
        }
        return receipt
    }
}

// MARK: - Viewer activation ledger

nonisolated public struct PeelPeerActivationLedger: Sendable {
    public static let timeoutSeconds: TimeInterval = 25
    public static let maximumPending = 4

    public struct Pending: Equatable, Sendable {
        public var requestID: UUID
        public var key: PeelPeerAgentKey
        public var socketID: UUID
        public var deadline: Date
    }

    public private(set) var pending: [UUID: Pending] = [:]

    public init() {}

    /// Starts one request for a row. A second click on a pending row is
    /// refused rather than queued, so no action is ever repeated.
    public mutating func begin(key: PeelPeerAgentKey, socketID: UUID, now: Date,
                               requestID: UUID = UUID()) -> Result<UUID, PeelPeerActivationError> {
        guard !pending.values.contains(where: { $0.key == key }) else { return .failure(.alreadyPending) }
        guard pending.count < Self.maximumPending else { return .failure(.tooManyPending) }
        pending[requestID] = Pending(requestID: requestID, key: key, socketID: socketID,
                                     deadline: now.addingTimeInterval(Self.timeoutSeconds))
        return .success(requestID)
    }

    /// Accepts only the first result for a pending request, and only from the
    /// socket the request was written to.
    public mutating func resolve(requestID: UUID, socketID: UUID,
                                 outcome: PeelPeerActivationOutcome) -> (PeelPeerAgentKey, PeelPeerActivationOutcome)? {
        guard let entry = pending[requestID], entry.socketID == socketID,
              !PeelPeerActivationOutcome.viewerOnly.contains(outcome) else { return nil }
        pending[requestID] = nil
        return (entry.key, outcome)
    }

    /// Cancels a request that could not be written. No result is expected.
    public mutating func cancel(requestID: UUID) {
        pending[requestID] = nil
    }

    public mutating func expire(now: Date) -> [(PeelPeerAgentKey, PeelPeerActivationOutcome)] {
        let expired = pending.values.filter { $0.deadline <= now }
        for entry in expired { pending[entry.requestID] = nil }
        return expired.map { ($0.key, .timedOut) }
    }

    /// The request was written but the socket closed before a result: the
    /// owner may or may not have acted, so report "no confirmation".
    public mutating func socketClosed(_ socketID: UUID) -> [(PeelPeerAgentKey, PeelPeerActivationOutcome)] {
        let closed = pending.values.filter { $0.socketID == socketID }
        for entry in closed { pending[entry.requestID] = nil }
        return closed.map { ($0.key, .timedOut) }
    }

    public mutating func revoke(keepingOwners trusted: Set<UUID>) -> [(PeelPeerAgentKey, PeelPeerActivationOutcome)] {
        let revoked = pending.values.filter { !trusted.contains($0.key.ownerHostID) }
        for entry in revoked { pending[entry.requestID] = nil }
        return revoked.map { ($0.key, .revoked) }
    }

    public var pendingKeys: Set<PeelPeerAgentKey> { Set(pending.values.map(\.key)) }
}

nonisolated public enum PeelPeerActivationError: Error, Equatable, Sendable {
    case alreadyPending
    case tooManyPending
}
