import Foundation

public enum PluginRelayWatchCoordinatorError: Error, Equatable, Sendable {
    case inactive, busy, unavailable, notReady, cancelled, invalidResponse
}

/// Required trusted native enrollment/session composition, not decoded route data.
/// Implementations check their current live registry, including the account,
/// selected actual agent route, enrolled paired phone and local operation epoch.
/// Bounded synchronous/thread-safe checks must fail after expiry/revoke/pair change.
public protocol PluginRelayWatchAuthority: Sendable {
    func validateCurrent(_ fence: PluginRelayFence) throws
}

/// One bounded foreground WC exchange. Implementations must enforce a deadline,
/// cap input/output at 60 KiB and remove only the exact cancelled courier. A WC
/// callback or reachable phone is transport evidence, not account authority.
public protocol PluginRelayWatchTransport: Sendable {
    func exchange(_ data: Data, courierID: UUID) async throws -> Data
    func cancel(courierID: UUID) async
}

public struct PluginRelayWatchSnapshot: Equatable, Sendable {
    public let report: PluginRelayStatusReport?
    public let outgoing: [PluginRelaySendRecord]
    public let replies: [PluginRelayReply]
}

/// A route-bound Watch courier. It persists before sending, never creates retry
/// message IDs and performs no timers, hidden polling or credential restoration.
public actor PluginRelayWatchCoordinator {
    public let fence: PluginRelayFence
    private let store: PluginRelayWatchStore
    private let transport: any PluginRelayWatchTransport
    private let authority: any PluginRelayWatchAuthority
    private struct Operation { let nonce: UUID; var courierID: UUID?; var cancelled = false }
    private var operation: Operation?
    private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var terminal = false
    private var stopping = false
    private var report: PluginRelayStatusReport?
    private var invalidationTask: Task<Void, Error>?

    public init(fence: PluginRelayFence, store: PluginRelayWatchStore,
                transport: any PluginRelayWatchTransport, authority: any PluginRelayWatchAuthority) throws {
        try fence.binding.route.validate()
        self.fence = fence; self.store = store; self.transport = transport; self.authority = authority
    }

    public func snapshot() async throws -> PluginRelayWatchSnapshot {
        try current()
        let outgoing = try await store.outgoingMessages(using: fence); try current()
        let replies = try await store.completeReplies(using: fence); try current()
        return PluginRelayWatchSnapshot(report: report, outgoing: outgoing, replies: replies)
    }

    public func status() async throws -> PluginRelayWatchSnapshot {
        let nonce = try begin(); defer { finish(nonce) }
        let response = try await exchange(kind: .status, nonce: nonce)
        guard response.kind == .statusReport, let next = response.statusReport else { throw PluginRelayWatchCoordinatorError.invalidResponse }
        try check(nonce); report = next
        let result = try await state(nonce); try check(nonce); return result
    }

    /// The caller chooses an ID once. The same ID/body is retained for explicit
    /// retry after a timeout or restart; a courier UUID is always separate.
    public func send(_ message: PluginRelayMessage) async throws -> PluginRelayWatchSnapshot {
        let nonce = try begin(); defer { finish(nonce) }
        guard report?.remoteReady == true else { throw PluginRelayWatchCoordinatorError.notReady }
        let saved = try await store.reserve(message, using: fence); try check(nonce)
        if saved.receipt == nil {
            try await store.markUncertain(message.messageID, using: fence); try check(nonce)
        }
        let response = try await exchange(kind: .send, message: message, nonce: nonce)
        try check(nonce)
        guard response.kind == .receipt, let receipt = response.receipt,
              receipt.requestID == message.messageID else { throw PluginRelayWatchCoordinatorError.invalidResponse }
        try await store.record(receipt, using: fence); try check(nonce)
        let result = try await state(nonce); try check(nonce); return result
    }

    /// One broker page, at most one complete reply (eight bounded chunks), then
    /// its durable acknowledgment. Empty refresh ends this check immediately.
    public func refreshReply() async throws -> PluginRelayWatchSnapshot {
        let nonce = try begin(); defer { finish(nonce) }
        guard report?.remoteReady == true else { throw PluginRelayWatchCoordinatorError.notReady }
        let first = try await exchange(kind: .replyRefresh, nonce: nonce)
        try check(nonce)
        if first.kind == .replyRefresh { let result = try await state(nonce); try check(nonce); return result }
        guard first.kind == .chunk, let initial = first.chunk, initial.index == 0 else {
            throw PluginRelayWatchCoordinatorError.invalidResponse
        }
        var complete = try await store.receive(initial, using: fence); try check(nonce)
        if complete == nil && initial.count > 1 {
            for index in 1..<initial.count {
                let response = try await exchange(kind: .chunkRequest, requestID: initial.requestID,
                                                  replyID: initial.replyID, chunkIndex: index, nonce: nonce)
                try check(nonce)
                guard response.kind == .chunk, let chunk = response.chunk,
                      chunk.sameAssembly(as: initial), chunk.index == index else {
                    throw PluginRelayWatchCoordinatorError.invalidResponse
                }
                complete = try await store.receive(chunk, using: fence); try check(nonce)
            }
        }
        guard let complete else { throw PluginRelayWatchCoordinatorError.invalidResponse }
        // Generated from the saved complete reply, never from a transport receipt.
        let courier = UUID()
        let acknowledgment = try await store.acknowledgment(requestID: complete.requestID, courierID: courier, using: fence)
        try check(nonce)
        let echoed = try await roundTrip(acknowledgment, nonce: nonce)
        try check(nonce)
        guard echoed == acknowledgment else { throw PluginRelayWatchCoordinatorError.invalidResponse }
        let result = try await state(nonce); try check(nonce); return result
    }

    /// Stops local checking and cancels the exact local WC courier. It
    /// does not revoke an account or prove that remote agent work was cancelled.
    public func stop() async {
        guard !stopping else { return }
        stopping = true; defer { stopping = false }
        guard var old = operation else { return }
        old.cancelled = true; operation = old
        if let courier = old.courierID { await transport.cancel(courierID: courier) }
        await drain(old.nonce)
    }

    /// Trusted account/pair/route replacement must await this before exposing a
    /// replacement coordinator or reusing its transport/store. History stays in
    /// the old exact partition; it is never rebound to the replacement account.
    public func invalidate() async throws {
        if let invalidationTask { return try await invalidationTask.value }
        terminal = true; report = nil
        let task = Task { try await self.finishInvalidation() }
        invalidationTask = task
        try await task.value
    }
    private func finishInvalidation() async throws {
        if var old = operation {
            old.cancelled = true; operation = old
            if let courier = old.courierID { await transport.cancel(courierID: courier) }
            await drain(old.nonce)
        }
        _ = try await store.invalidate(using: fence, newLocalEpoch: UUID())
    }

    private func current() throws {
        guard !terminal else { throw PluginRelayWatchCoordinatorError.inactive }
        guard !Task.isCancelled else { throw PluginRelayWatchCoordinatorError.cancelled }
        try authority.validateCurrent(fence)
    }
    private func begin() throws -> UUID {
        try current()
        guard operation == nil, !stopping else { throw PluginRelayWatchCoordinatorError.busy }
        let nonce = UUID(); operation = Operation(nonce: nonce); return nonce
    }
    private func check(_ nonce: UUID) throws {
        try current()
        guard let active = operation, active.nonce == nonce, !active.cancelled else {
            throw PluginRelayWatchCoordinatorError.cancelled
        }
    }
    private func finish(_ nonce: UUID) {
        if operation?.nonce == nonce { operation = nil }
        waiters.removeValue(forKey: nonce)?.forEach { $0.resume() }
    }
    private func drain(_ nonce: UUID) async {
        guard operation?.nonce == nonce else { return }
        await withCheckedContinuation { waiters[nonce, default: []].append($0) }
    }
    private func state(_ nonce: UUID) async throws -> PluginRelayWatchSnapshot {
        try check(nonce)
        let outgoing = try await store.outgoingMessages(using: fence); try check(nonce)
        let replies = try await store.completeReplies(using: fence); try check(nonce)
        return PluginRelayWatchSnapshot(report: report, outgoing: outgoing, replies: replies)
    }
    private func exchange(kind: PluginRelayV2Envelope.Kind, message: PluginRelayMessage? = nil,
                          requestID: UUID? = nil, replyID: String? = nil, chunkIndex: Int? = nil,
                          nonce: UUID) async throws -> PluginRelayV2Envelope {
        let request = try PluginRelayV2Envelope(courierID: UUID(), fence: fence, kind: kind,
                                               message: message, requestID: requestID,
                                               replyID: replyID, chunkIndex: chunkIndex)
        let result = try await roundTrip(request, nonce: nonce)
        try check(nonce); return result
    }
    private func roundTrip(_ request: PluginRelayV2Envelope, nonce: UUID) async throws -> PluginRelayV2Envelope {
        try check(nonce)
        let bytes = try request.encoded()
        operation?.courierID = request.courierID
        let response = try await transport.exchange(bytes, courierID: request.courierID)
        try check(nonce)
        let value = try PluginRelayV2Envelope.decode(response, expectedFence: fence, expectedCourierID: request.courierID)
        try check(nonce)
        return value
    }
}
