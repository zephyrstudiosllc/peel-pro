#if !os(watchOS)
import Foundation

public enum PluginRelayPhoneCoordinatorError: Error, Equatable, Sendable {
    case inactive, busy, authorityDenied, cancelled, staleOperation, invalidRequest, invalidResponse
}

/// Opaque evidence supplied by the trusted native peer/enrollment adapter, never
/// decoded from a Watch envelope. This marker alone proves nothing; the required
/// authority adapter must independently verify the actual broker session and
/// enrolled phone/Watch peer, scopes, expiry, revocation and current full fence.
public protocol PluginRelayPhonePeerEvidence: Sendable {}

public enum PluginRelayPhoneAction: String, Sendable {
    case status, send, readReplies, readChunk, acknowledge, localStop, disconnect
    var requiresPro: Bool { self != .localStop && self != .disconnect }
}

/// A non-Codable local lease handle, not credentials or authority by construction.
/// validateCurrent must check the trusted adapter's live verified lease registry.
public struct PluginRelayPhoneAuthorityLease: Sendable {
    public let id: UUID
    public let fence: PluginRelayFence
    public let action: PluginRelayPhoneAction
    public let expiresAt: Date
    public let proPermit: PluginRelayProPermit?
    public init(id: UUID, fence: PluginRelayFence, action: PluginRelayPhoneAction, expiresAt: Date,
                proPermit: PluginRelayProPermit? = nil) {
        self.id = id; self.fence = fence; self.action = action; self.expiresAt = expiresAt; self.proPermit = proPermit
    }
}

/// Required composition; no implementation/default is supplied. Both methods
/// must be bounded, synchronous, thread-safe and nonblocking. Admission must bind
/// peer evidence to this account/provider/route/pairing/local generation and the
/// requested action. WC flags, identity metadata, UUIDs and restored data alone
/// cannot admit a request. No online computer, Host or video stream is required.
public protocol PluginRelayPhoneAuthority: Sendable {
    func authorize(_ action: PluginRelayPhoneAction, fence: PluginRelayFence,
                   peer: any PluginRelayPhonePeerEvidence) throws -> PluginRelayPhoneAuthorityLease
    func validateCurrent(_ lease: PluginRelayPhoneAuthorityLease) throws
}

/// Exclusive to one coordinator. Implementations must retain the accepted HTTP
/// client's bounded deadline/cancellation/schema/authentication behavior. This
/// protocol grants no runtime and must never become an unbounded polling loop.
public protocol PluginRelayPhoneTransport: Sendable {
    func status(using fence: PluginRelayFence) async throws -> PluginRelayHTTPStatus
    func send(_ message: PluginRelayMessage, using fence: PluginRelayFence) async throws -> PluginRelayReceipt
    func replies(after cursor: Int64, using fence: PluginRelayFence) async throws -> PluginRelayReplyPage
    func disconnect(using fence: PluginRelayFence) async throws
    func cancelCurrent() async
}

extension PluginRelayHTTPClient: PluginRelayPhoneTransport {}

/// One externally bound route; a restored store does not create this authority.
/// The future iOS owner selects explicit phone-policy persistence before creating
/// the store. This actor neither changes file/Keychain policy nor runs on Watch.
/// Exactly one owner must use the store and transport; do not share them with a
/// replacement coordinator until local invalidation/cancellation has completed.
public actor PluginRelayPhoneCoordinator {
    public let fence: PluginRelayFence
    private let store: PluginRelayPhoneStore
    private let transport: any PluginRelayPhoneTransport
    private let authority: any PluginRelayPhoneAuthority
    private struct Operation {
        let nonce: UUID
        let courierID: UUID
        let lease: PluginRelayPhoneAuthorityLease
        var cancelled = false
    }
    private struct Prepared {
        let envelope: PluginRelayV2Envelope
        let lease: PluginRelayPhoneAuthorityLease
    }
    private var operation: Operation?
    private var completionWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var cancellationInProgress = false
    private var closing = false
    private var terminal = false
    private var invalidationTask: Task<Void, Error>?
    private var epochRotationTask: Task<Void, Error>?
    private var authorityRenewal: UUID?
    private var authorityPauseTask: Task<UUID, Error>?

    public init(fence: PluginRelayFence, store: PluginRelayPhoneStore,
                transport: any PluginRelayPhoneTransport, authority: any PluginRelayPhoneAuthority) throws {
        try fence.binding.route.validate()
        self.fence = fence; self.store = store; self.transport = transport; self.authority = authority
    }

    /// Caller supplies peer evidence from the native callback, never from JSON.
    public func handle(_ data: Data, from peer: any PluginRelayPhonePeerEvidence) async throws -> Data {
        try await handleOutput(data, from: peer).copyBytes()
    }
    /// Native submission retains this paid permit until the actual WC callback.
    public func handleOutput(_ data: Data, from peer: any PluginRelayPhonePeerEvidence) async throws -> PluginRelayPhoneOutput {
        let request = try PluginRelayV2Envelope.decode(data, expectedFence: fence)
        let prepared = try await perform(request, from: peer)
        try checkDelivery(prepared, expectedCourierID: request.courierID)
        let bytes = try prepared.envelope.encoded()
        try checkDelivery(prepared, expectedCourierID: request.courierID)
        return .init(bytes: bytes, permit: prepared.lease.proPermit)
    }

    /// Trusted native/fixture overload. Untrusted raw WC bytes must use the Data
    /// overload above so duplicates/unknown JSON keys cannot be erased upstream.
    public func handle(_ request: PluginRelayV2Envelope, from peer: any PluginRelayPhonePeerEvidence) async throws -> PluginRelayV2Envelope {
        let prepared = try await perform(request, from: peer)
        try checkDelivery(prepared, expectedCourierID: request.courierID)
        if let paid = prepared.lease.proPermit { return try paid.withAdmission(for: fence) { prepared.envelope } }
        return prepared.envelope
    }

    /// status -> statusReport; replyRefresh -> first durable chunk or empty
    /// replyRefresh; send -> receipt; chunkRequest -> chunk. acknowledge/localStop
    /// echo the exact validated request only after local commit/cancel handling.
    /// Empty refresh is a terminal response for that courier, never a new poll.
    private func perform(_ request: PluginRelayV2Envelope, from peer: any PluginRelayPhonePeerEvidence) async throws -> Prepared {
        guard authorityRenewal == nil else { throw PluginRelayPhoneCoordinatorError.busy }
        try request.validate(); _ = try request.encoded()
        guard request.fence == fence else { throw PluginRelayError.wrongBinding }
        if request.kind == .localStop {
            let prepared = try await stop(request, peer: peer)
            try checkDelivery(prepared, expectedCourierID: request.courierID)
            return prepared
        }
        let action: PluginRelayPhoneAction
        switch request.kind {
        case .status: action = .status
        case .send: action = .send
        case .replyRefresh: action = .readReplies
        case .chunkRequest: action = .readChunk
        case .acknowledge: action = .acknowledge
        case .receipt, .chunk, .statusReport, .localStop: throw PluginRelayPhoneCoordinatorError.invalidRequest
        }
        let current = try begin(request.courierID, action: action, peer: peer)
        defer { finish(current) }
        switch request.kind {
        case .status:
            let remote = try await step(current) { try await transport.status(using: fence) }
            guard remote.route == fence.binding.route,
                  let state = PluginRelayStatusReport.State(rawValue: remote.state.rawValue),
                  let mode = PluginRelayStatusReport.DeliveryMode(rawValue: remote.deliveryMode.rawValue) else {
                throw PluginRelayPhoneCoordinatorError.invalidResponse
            }
            let initial = PluginRelayStatusReport(state: state, remoteReady: remote.remoteReady, deliveryMode: mode,
                automaticDeliveryReady: remote.automaticDeliveryReady,
                minimumRoutineIntervalSeconds: remote.minimumRoutineIntervalSeconds, nextReply: nil)
            try initial.validate(provider: fence.binding.route.provider)
            let next: PluginRelayReplyNotice?
            if remote.remoteReady { next = try await nextNotice(current) } else { next = nil }
            let report = PluginRelayStatusReport(state: state, remoteReady: remote.remoteReady, deliveryMode: mode,
                automaticDeliveryReady: remote.automaticDeliveryReady,
                minimumRoutineIntervalSeconds: remote.minimumRoutineIntervalSeconds, nextReply: next)
            return try output(request, current: current, kind: .statusReport, statusReport: report)
        case .send:
            guard let message = request.message else { throw PluginRelayPhoneCoordinatorError.invalidRequest }
            let record = try await step(current) { try await store.reserve(message, using: fence, permit: paid(current)) }
            if let receipt = record.receipt { return try output(request, current: current, kind: .receipt, receipt: receipt) }
            // A crash, timeout, cancellation or lost response after dispatch must
            // already have a durable uncertain record; never repair this using
            // stale authority after an await. Retrying requires this SAME ID/body.
            if record.state != .uncertain {
                try await step(current) { try await store.markUncertain(message.messageID, using: fence, permit: paid(current)) }
            }
            let receipt = try await step(current) { try await transport.send(message, using: fence) }
            try receipt.validate()
            guard receipt.requestID == message.messageID, receipt.route == fence.binding.route else {
                throw PluginRelayPhoneCoordinatorError.invalidResponse
            }
            try await step(current) { try await store.record(receipt, using: fence, permit: paid(current)) }
            return try output(request, current: current, kind: .receipt, receipt: receipt)
        case .replyRefresh:
            let after = try await step(current) { try await store.cursor(using: fence, permit: paid(current)) }
            let page = try await step(current) { try await transport.replies(after: after, using: fence) }
            try page.validate()
            guard page.route == fence.binding.route else { throw PluginRelayPhoneCoordinatorError.invalidResponse }
            // Store atomically commits the whole page and broker arrival cursor.
            // Nothing may be exposed to Watch if this transaction fails.
            try await step(current) { try await store.ingest(page, after: after, using: fence, permit: paid(current)) }
            let pending = try await step(current) { try await store.pendingReplies(using: fence, permit: paid(current)) }
            guard let reply = pending.first else { return try output(request, current: current, kind: .replyRefresh) }
            let chunks = try await step(current) { try await store.chunks(requestID: reply.requestID, using: fence, permit: paid(current)) }
            guard let first = chunks.first else { throw PluginRelayPhoneCoordinatorError.invalidResponse }
            return try output(request, current: current, kind: .chunk, chunk: first)
        case .chunkRequest:
            guard let id = request.requestID, let replyID = request.replyID, let index = request.chunkIndex else {
                throw PluginRelayPhoneCoordinatorError.invalidRequest
            }
            let chunks = try await step(current) { try await store.chunks(requestID: id, using: fence, permit: paid(current)) }
            guard chunks.indices.contains(index), PluginRelayValidation.sameBytes(chunks[index].replyID, replyID) else {
                throw PluginRelayPhoneCoordinatorError.invalidRequest
            }
            return try output(request, current: current, kind: .chunk, chunk: chunks[index])
        case .acknowledge:
            guard let id = request.requestID, let replyID = request.replyID, let digest = request.digest else {
                throw PluginRelayPhoneCoordinatorError.invalidRequest
            }
            try await step(current) { try await store.acknowledge(requestID: id, replyID: replyID, digest: digest, using: fence, permit: paid(current)) }
            return Prepared(envelope: request, lease: current.lease) // Durable Watch ack, not a WC callback.
        case .receipt, .chunk, .statusReport, .localStop: throw PluginRelayPhoneCoordinatorError.invalidRequest
        }
    }

    /// Trusted phone-owner cleanup after revoke/account/route/pair change. Stops
    /// admission immediately, then cancels local IO and rotates the store epoch.
    /// No remote task, subscription or account revocation is claimed by this API.
    public func invalidate() async throws {
        if let invalidationTask { try await invalidationTask.value; return }
        terminal = true
        let nonce = operation?.nonce
        operation?.cancelled = true; cancellationInProgress = true
        let cleanup = Task { try await completeInvalidation(nonce) }
        invalidationTask = cleanup
        defer { cancellationInProgress = false }
        try await cleanup.value
    }
    private func completeInvalidation(_ nonce: UUID?) async throws {
        await transport.cancelCurrent()
        if let nonce { await waitForFinish(nonce) }
        try await rotateStoreEpoch()
    }
    private func rotateStoreEpoch() async throws {
        if let epochRotationTask { try await epochRotationTask.value; return }
        let store = self.store, fence = self.fence
        let rotation = Task { _ = try await store.invalidate(using: fence, newLocalEpoch: UUID()) }
        epochRotationTask = rotation
        try await rotation.value
    }

    /// Exact route disconnect only. Once admitted, the local coordinator becomes
    /// terminal even if the HTTP result is uncertain. Account-wide sign-out and
    /// credential deletion belong to the trusted composition outside this core.
    public func disconnect(courierID: UUID, from peer: any PluginRelayPhonePeerEvidence) async throws {
        let current = try begin(courierID, action: .disconnect, peer: peer)
        closing = true
        defer { terminal = true; finish(current) }
        do { try await step(current) { try await transport.disconnect(using: fence) } }
        catch {
            terminal = true
            try? await rotateStoreEpoch()
            throw error
        }
        terminal = true
        try await rotateStoreEpoch()
        guard operation?.nonce == current.nonce, operation?.cancelled == false, !Task.isCancelled else {
            throw PluginRelayPhoneCoordinatorError.cancelled
        }
        try validate(current.lease)
    }

    private func nextNotice(_ current: Operation) async throws -> PluginRelayReplyNotice? {
        let pending = try await step(current) { try await store.pendingReplies(using: fence, permit: paid(current)) }
        guard let reply = pending.first else { return nil }
        let chunks = try await step(current) { try await store.chunks(requestID: reply.requestID, using: fence, permit: paid(current)) }
        guard let first = chunks.first else { throw PluginRelayPhoneCoordinatorError.invalidResponse }
        return try PluginRelayReplyNotice(requestID: reply.requestID, replyID: reply.replyID,
            chunkCount: first.count, totalUTF8Bytes: first.totalUTF8Bytes, digest: first.digest)
    }

    private func output(_ request: PluginRelayV2Envelope, current: Operation, kind: PluginRelayV2Envelope.Kind,
                        receipt: PluginRelayReceipt? = nil, chunk: PluginRelayChunk? = nil,
                        statusReport: PluginRelayStatusReport? = nil) throws -> Prepared {
        try check(current)
        let result = try PluginRelayV2Envelope(courierID: request.courierID, fence: fence, kind: kind,
            receipt: receipt, chunk: chunk, statusReport: statusReport)
        _ = try result.encoded() // Complete envelope, not just text, must fit60KiB.
        try check(current)
        return Prepared(envelope: result, lease: current.lease)
    }

    private func begin(_ id: UUID, action: PluginRelayPhoneAction, peer: any PluginRelayPhonePeerEvidence) throws -> Operation {
        guard !terminal, !closing else { throw PluginRelayPhoneCoordinatorError.inactive }
        guard operation == nil, !cancellationInProgress else { throw PluginRelayPhoneCoordinatorError.busy }
        guard !Task.isCancelled else { throw PluginRelayPhoneCoordinatorError.cancelled }
        let lease = try admit(action, peer: peer)
        let value = Operation(nonce: UUID(), courierID: id, lease: lease)
        operation = value; return value
    }
    private func admit(_ action: PluginRelayPhoneAction, peer: any PluginRelayPhonePeerEvidence) throws -> PluginRelayPhoneAuthorityLease {
        let lease: PluginRelayPhoneAuthorityLease
        do { lease = try authority.authorize(action, fence: fence, peer: peer) }
        catch let paid as PluginRelayProError { throw paid }
        catch { throw PluginRelayPhoneCoordinatorError.authorityDenied }
        guard lease.fence == fence, lease.action == action else { throw PluginRelayPhoneCoordinatorError.authorityDenied }
        try validate(lease); return lease
    }
    private func validate(_ lease: PluginRelayPhoneAuthorityLease) throws {
        guard lease.fence == fence, lease.expiresAt.timeIntervalSinceReferenceDate.isFinite, lease.expiresAt > Date() else {
            throw PluginRelayPhoneCoordinatorError.authorityDenied
        }
        do { try authority.validateCurrent(lease) }
        catch let paid as PluginRelayProError { throw paid }
        catch { throw PluginRelayPhoneCoordinatorError.authorityDenied }
        if lease.action.requiresPro {
            guard let permit = lease.proPermit else { throw PluginRelayProError.required }
            try permit.validate(for: fence)
        }
    }
    private func paid(_ current: Operation) throws -> PluginRelayProPermit {
        guard let permit = current.lease.proPermit else { throw PluginRelayProError.required }
        try permit.validate(for: fence); return permit
    }
    private func check(_ current: Operation) throws {
        guard !terminal else { throw PluginRelayPhoneCoordinatorError.inactive }
        guard operation?.nonce == current.nonce else { throw PluginRelayPhoneCoordinatorError.staleOperation }
        guard operation?.cancelled == false, !Task.isCancelled else { throw PluginRelayPhoneCoordinatorError.cancelled }
        try validate(current.lease)
    }
    private func step<T: Sendable>(_ current: Operation, _ body: () async throws -> T) async throws -> T {
        try check(current)
        let value: T
        do { value = try await body() }
        catch { try check(current); throw error }
        try check(current); return value
    }
    private func finish(_ current: Operation) {
        if operation?.nonce == current.nonce { operation = nil }
        let waiting = completionWaiters.removeValue(forKey: current.nonce) ?? []
        for continuation in waiting { continuation.resume() }
    }
    private func waitForFinish(_ nonce: UUID) async {
        guard operation?.nonce == nonce else { return }
        await withCheckedContinuation { completionWaiters[nonce, default: []].append($0) }
    }
    private func stop(_ request: PluginRelayV2Envelope, peer: any PluginRelayPhonePeerEvidence) async throws -> Prepared {
        guard !terminal, !closing else { throw PluginRelayPhoneCoordinatorError.inactive }
        guard !Task.isCancelled else { throw PluginRelayPhoneCoordinatorError.cancelled }
        let lease = try admit(.localStop, peer: peer)
        guard let target = request.cancelCourierID else { throw PluginRelayPhoneCoordinatorError.invalidRequest }
        if let current = operation, current.courierID == target {
            guard !cancellationInProgress else { throw PluginRelayPhoneCoordinatorError.busy }
            operation?.cancelled = true; cancellationInProgress = true
            defer { cancellationInProgress = false }
            await transport.cancelCurrent()
            await waitForFinish(current.nonce)
            guard !terminal else { throw PluginRelayPhoneCoordinatorError.inactive }
            guard !Task.isCancelled else { throw PluginRelayPhoneCoordinatorError.cancelled }
            try validate(lease)
        }
        // This acknowledges handling the LOCAL request. It does not assert that
        // a target existed, a message wasn't accepted, or remote work was stopped.
        return Prepared(envelope: request, lease: lease)
    }
    private func checkDelivery(_ prepared: Prepared, expectedCourierID: UUID) throws {
        guard authorityRenewal == nil else { throw PluginRelayPhoneCoordinatorError.busy }
        guard !terminal, !closing else { throw PluginRelayPhoneCoordinatorError.inactive }
        guard !Task.isCancelled else { throw PluginRelayPhoneCoordinatorError.cancelled }
        guard prepared.envelope.fence == fence, prepared.envelope.courierID == expectedCourierID else {
            throw PluginRelayPhoneCoordinatorError.staleOperation
        }
        try validate(prepared.lease)
    }

    /// Trusted finite lease renewal barrier. It cancels/drains an old local
    /// courier without rotating the durable store epoch or changing the fence.
    /// Only the native owner resumes after a fresh same-fence verified authority.
    public func pauseForAuthorityRenewal() async throws -> UUID {
        guard !terminal, !closing else { throw PluginRelayPhoneCoordinatorError.inactive }
        if let authorityPauseTask { return try await authorityPauseTask.value }
        let token = UUID(); authorityRenewal = token
        let old = operation
        if old != nil { operation?.cancelled = true }
        let task = Task { [self] in
            await transport.cancelCurrent()
            if let old { await waitForFinish(old.nonce) }
            guard !terminal, !closing, authorityRenewal == token else { throw PluginRelayPhoneCoordinatorError.inactive }
            return token
        }
        authorityPauseTask = task
        return try await task.value
    }
    public func resumeAfterAuthorityRenewal(_ token: UUID) throws {
        guard !terminal, !closing, authorityRenewal == token else { throw PluginRelayPhoneCoordinatorError.inactive }
        authorityRenewal = nil; authorityPauseTask = nil
    }
}
#endif
