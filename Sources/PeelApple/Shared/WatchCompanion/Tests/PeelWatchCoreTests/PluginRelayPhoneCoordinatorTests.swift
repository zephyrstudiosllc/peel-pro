#if !os(watchOS)
import XCTest
@testable import PeelWatchCore

private struct CoordinatorFixturePeer: PluginRelayPhonePeerEvidence { let id: UUID }
private struct CoordinatorMalformedLeaseAuthority: PluginRelayPhoneAuthority {
    let returnedFence: PluginRelayFence?
    let returnedAction: PluginRelayPhoneAction?
    let expiresAt: Date
    func authorize(_ action: PluginRelayPhoneAction, fence: PluginRelayFence,
                   peer: any PluginRelayPhonePeerEvidence) throws -> PluginRelayPhoneAuthorityLease {
        .init(id: UUID(), fence: returnedFence ?? fence, action: returnedAction ?? action, expiresAt: expiresAt,
              proPermit: action.requiresPro ? try syntheticPaidPermit(for: returnedFence ?? fence) : nil)
    }
    func validateCurrent(_ lease: PluginRelayPhoneAuthorityLease) throws {}
}
private final class CoordinatorFixtureAuthority: PluginRelayPhoneAuthority, @unchecked Sendable {
    let peerID: UUID
    private let lock = NSLock()
    private var enabled = true
    private var leases = Set<UUID>()
    init(peerID: UUID) { self.peerID = peerID }
    func revoke() { lock.lock(); defer { lock.unlock() }; enabled = false; leases.removeAll() }
    func authorize(_ action: PluginRelayPhoneAction, fence: PluginRelayFence,
                   peer: any PluginRelayPhonePeerEvidence) throws -> PluginRelayPhoneAuthorityLease {
        lock.lock(); defer { lock.unlock() }
        guard enabled, let peer = peer as? CoordinatorFixturePeer, peer.id == peerID else {
            throw PluginRelayPhoneCoordinatorError.authorityDenied
        }
        let id = UUID(); leases.insert(id)
        return .init(id: id, fence: fence, action: action, expiresAt: Date().addingTimeInterval(60),
                     proPermit: action.requiresPro ? try syntheticPaidPermit(for: fence) : nil)
    }
    func validateCurrent(_ lease: PluginRelayPhoneAuthorityLease) throws {
        lock.lock(); defer { lock.unlock() }
        guard enabled, leases.contains(lease.id) else { throw PluginRelayPhoneCoordinatorError.authorityDenied }
    }
}

private final class CoordinatorFixturePersistence: PluginRelayPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data?
    private var writes = 0
    private var failingWrite: Int?
    func failAfterAdditionalWrites(_ count: Int) { lock.lock(); defer { lock.unlock() }; failingWrite = writes + count }
    func snapshot() -> Data? { lock.lock(); defer { lock.unlock() }; return bytes }
    func read(maximumBytes: Int) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard bytes.map({ $0.count <= maximumBytes }) ?? true else { throw PluginRelayError.capacity }
        return bytes
    }
    func writeAtomically(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }; writes += 1
        if failingWrite == writes { failingWrite = nil; throw PluginRelayError.storageFailure }
        bytes = data
    }
}

/// Explicitly intercepted typed transport, with deterministic continuation
/// gates. It deliberately permits a late response after cancel to test fences.
private actor CoordinatorFixtureTransport: PluginRelayPhoneTransport {
    enum Gate: Hashable { case send, replies, cancel }
    let route: PluginRelayReference
    var ready = true
    var sendError: PluginRelayHTTPError?
    var disconnectError: PluginRelayHTTPError?
    var page: PluginRelayReplyPage?
    private var held = Set<Gate>()
    private var entered = Set<Gate>()
    private var waiting: [Gate: CheckedContinuation<Void, Never>] = [:]
    private var arrivals: [Gate: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var messages: [PluginRelayMessage] = []
    private(set) var afters: [Int64] = []
    private(set) var statusCalls = 0
    private(set) var cancelCalls = 0
    private(set) var disconnectCalls = 0
    init(route: PluginRelayReference) { self.route = route }
    func hold(_ gate: Gate) { held.insert(gate); entered.remove(gate) }
    func waitForEntry(_ gate: Gate) async {
        if entered.contains(gate) { return }
        await withCheckedContinuation { arrivals[gate, default: []].append($0) }
    }
    func release(_ gate: Gate) { held.remove(gate); waiting.removeValue(forKey: gate)?.resume() }
    private func gate(_ value: Gate) async {
        entered.insert(value)
        let notifications = arrivals.removeValue(forKey: value) ?? []
        for item in notifications { item.resume() }
        if held.contains(value) { await withCheckedContinuation { waiting[value] = $0 } }
    }
    func configure(ready: Bool? = nil, sendError: PluginRelayHTTPError? = nil,
                   page: PluginRelayReplyPage? = nil, disconnectError: PluginRelayHTTPError? = nil) {
        if let ready { self.ready = ready }; self.sendError = sendError
        self.page = page; self.disconnectError = disconnectError
    }
    func status(using fence: PluginRelayFence) async throws -> PluginRelayHTTPStatus {
        statusCalls += 1
        let dot = route.provider == .dot
        return .init(route: route, remoteReady: ready,
            state: ready ? (dot ? .connected : .manualReady) : .authorizePlugin,
            deliveryMode: dot ? .events : .manual, automaticDeliveryReady: ready && dot,
            minimumRoutineIntervalSeconds: dot ? nil : 300)
    }
    func send(_ message: PluginRelayMessage, using fence: PluginRelayFence) async throws -> PluginRelayReceipt {
        messages.append(message); await gate(.send)
        if let sendError { throw sendError }
        return try .init(requestID: message.messageID, route: route, receiptID: "receipt_coordinator_fixture",
                         state: .accepted, agentReplyReceived: false)
    }
    func replies(after cursor: Int64, using fence: PluginRelayFence) async throws -> PluginRelayReplyPage {
        afters.append(cursor); await gate(.replies)
        return try page ?? .init(route: route, replies: [], cursor: cursor)
    }
    func disconnect(using fence: PluginRelayFence) async throws {
        disconnectCalls += 1; if let disconnectError { throw disconnectError }
    }
    func cancelCurrent() async { cancelCalls += 1; await gate(.cancel) }
}

final class PluginRelayPhoneCoordinatorTests: XCTestCase {
    private struct Fixture {
        let fence: PluginRelayFence
        let peer: CoordinatorFixturePeer
        let authority: CoordinatorFixtureAuthority
        let disk: CoordinatorFixturePersistence
        let store: PluginRelayPhoneStore
        let transport: CoordinatorFixtureTransport
        let coordinator: PluginRelayPhoneCoordinator
    }
    private func fixture(provider: CloudAgentProvider = .dot) throws -> Fixture {
        let route = try PluginRelayReference(provider: provider, routeID: "route_coordinator_fixture",
            generation: UUID(), accountGeneration: UUID())
        let fence = PluginRelayFence(binding: .init(route: route, pairingEpoch: UUID()), localEpoch: UUID())
        let peer = CoordinatorFixturePeer(id: UUID()), authority = CoordinatorFixtureAuthority(peerID: peer.id)
        let disk = CoordinatorFixturePersistence(), transport = CoordinatorFixtureTransport(route: route)
        let store = try PluginRelayPhoneStore(persistence: disk, fence: fence, limits: .init())
        return Fixture(fence: fence, peer: peer, authority: authority, disk: disk, store: store, transport: transport,
            coordinator: try .init(fence: fence, store: store, transport: transport, authority: authority))
    }
    private func request(_ fixture: Fixture, kind: PluginRelayV2Envelope.Kind,
                         message: PluginRelayMessage? = nil, cancel: UUID? = nil) throws -> PluginRelayV2Envelope {
        try .init(courierID: UUID(), fence: fixture.fence, kind: kind, message: message, cancelCourierID: cancel)
    }
    private func expect(_ expected: PluginRelayPhoneCoordinatorError, _ body: () async throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? PluginRelayPhoneCoordinatorError, expected, file: file, line: line) }
    }

    func testAuthorityRenewalPausesAdmissionWithoutRotatingStoreOrLogicalID() async throws {
        let f = try fixture(), message = try PluginRelayMessage(messageID: UUID(), text: "same ID after renewal")
        let initial = try await f.coordinator.handle(request(f, kind: .send, message: message), from: f.peer)
        let token = try await f.coordinator.pauseForAuthorityRenewal()
        do { _ = try await f.coordinator.handle(request(f, kind: .status), from: f.peer); XCTFail("Paused authority admitted request") } catch {}
        try await f.coordinator.resumeAfterAuthorityRenewal(token)
        let retry = try await f.coordinator.handle(request(f, kind: .send, message: message), from: f.peer)
        XCTAssertEqual(initial.receipt, retry.receipt)
        let sent = await f.transport.messages; XCTAssertEqual(sent, [message])
        let restored = try PluginRelayPhoneStore(persistence: f.disk, fence: f.fence, limits: .init())
        let record = try await restored.sendRecord(message.messageID, using: f.fence, permit: try syntheticPaidPermit(for: f.fence)); XCTAssertEqual(record?.receipt, initial.receipt)
    }

    func testConcurrentRenewalCallersJoinTheSameFullCancellationDrain() async throws {
        actor Probe { var completed = false; func finish() { completed = true } }
        let f = try fixture(), probe = Probe(), message = try PluginRelayMessage(messageID: UUID(), text: "renewal drain")
        await f.transport.hold(.send); await f.transport.hold(.cancel)
        let sending = Task { try await f.coordinator.handle(request(f, kind: .send, message: message), from: f.peer) }
        await f.transport.waitForEntry(.send)
        let first = Task { try await f.coordinator.pauseForAuthorityRenewal() }
        await f.transport.waitForEntry(.cancel)
        let second = Task { let token = try await f.coordinator.pauseForAuthorityRenewal(); await probe.finish(); return token }
        // A bounded negative assertion while cancellation is deliberately held.
        try await Task.sleep(nanoseconds: 50_000_000)
        let returnedEarly = await probe.completed; XCTAssertFalse(returnedEarly)
        await f.transport.release(.send)
        do { _ = try await sending.value; XCTFail("Old send returned after pause") } catch {}
        await f.transport.release(.cancel)
        let a = try await first.value, b = try await second.value; XCTAssertEqual(a, b)
        try await f.coordinator.resumeAfterAuthorityRenewal(a)
        let saved = try await f.store.sendRecord(message.messageID, using: f.fence, permit: try syntheticPaidPermit(for: f.fence))
        XCTAssertEqual(saved?.state, .uncertain); XCTAssertEqual(saved?.message.messageID, message.messageID)
    }

    func testMetadataOrWrongPeerCannotSendOrReadCachedState() async throws {
        let f = try fixture(), message = try PluginRelayMessage(messageID: UUID(), text: "do not admit")
        await expect(.authorityDenied) {
            _ = try await f.coordinator.handle(request(f, kind: .send, message: message), from: CoordinatorFixturePeer(id: UUID()))
        }
        f.authority.revoke()
        await expect(.authorityDenied) { _ = try await f.coordinator.handle(request(f, kind: .status), from: f.peer) }
        let messages = await f.transport.messages, statuses = await f.transport.statusCalls
        XCTAssertTrue(messages.isEmpty); XCTAssertEqual(statuses, 0); XCTAssertNil(f.disk.snapshot())
    }

    func testRawCourierEntryPreservesCorrelationAndRejectsMalformedBeforeHTTP() async throws {
        let f = try fixture(), request = try request(f, kind: .status)
        let response = try await f.coordinator.handle(request.encoded(), from: f.peer)
        let decoded = try PluginRelayV2Envelope.decode(response, expectedFence: f.fence, expectedCourierID: request.courierID)
        XCTAssertEqual(decoded.kind, .statusReport)
        let text = String(decoding: try request.encoded(), as: UTF8.self)
        let duplicate = text.replacingOccurrences(of: "\"kind\":\"status\"", with: "\"kind\":\"status\",\"kind\":\"status\"")
        do { _ = try await f.coordinator.handle(Data(duplicate.utf8), from: f.peer); XCTFail("Expected duplicate rejection") }
        catch { XCTAssertEqual(error as? PluginRelayError, .invalidPayload) }
        let calls = await f.transport.statusCalls; XCTAssertEqual(calls, 1)
    }

    func testMalformedOrExpiredExternalLeaseCannotBypassCoreFenceChecks() async throws {
        let f = try fixture()
        let cases = [
            CoordinatorMalformedLeaseAuthority(returnedFence: .init(binding: f.fence.binding, localEpoch: UUID()), returnedAction: nil, expiresAt: .distantFuture),
            CoordinatorMalformedLeaseAuthority(returnedFence: nil, returnedAction: .send, expiresAt: .distantFuture),
            CoordinatorMalformedLeaseAuthority(returnedFence: nil, returnedAction: nil, expiresAt: .distantPast)
        ]
        for malformed in cases {
            let coordinator = try PluginRelayPhoneCoordinator(fence: f.fence, store: f.store, transport: f.transport, authority: malformed)
            await expect(.authorityDenied) { _ = try await coordinator.handle(request(f, kind: .status), from: f.peer) }
        }
        let statusCalls = await f.transport.statusCalls; XCTAssertEqual(statusCalls, 0)
    }

    func testReservationAndUncertainStorageFailuresPreventAnyHTTPDispatch() async throws {
        for offset in [1, 2] {
            let f = try fixture(), message = try PluginRelayMessage(messageID: UUID(), text: "reserve before dispatch")
            f.disk.failAfterAdditionalWrites(offset)
            do { _ = try await f.coordinator.handle(request(f, kind: .send, message: message), from: f.peer); XCTFail("Expected storage failure") }
            catch { XCTAssertEqual(error as? PluginRelayError, .storageFailure) }
            let sent = await f.transport.messages
            XCTAssertTrue(sent.isEmpty)
        }
    }

    func testExplicitSameIDRetryAndNewCourierUseOneStoredReceipt() async throws {
        let f = try fixture(), message = try PluginRelayMessage(messageID: UUID(), text: "same logical request")
        let first = try await f.coordinator.handle(request(f, kind: .send, message: message), from: f.peer)
        let second = try await f.coordinator.handle(request(f, kind: .send, message: message), from: f.peer)
        XCTAssertNotEqual(first.courierID, second.courierID); XCTAssertEqual(first.receipt, second.receipt)
        let sent = await f.transport.messages
        XCTAssertEqual(sent, [message]); XCTAssertEqual(first.kind, .receipt)
        XCTAssertNil(first.chunk); XCTAssertEqual(first.receipt?.agentReplyReceived, false)
        let changed = try PluginRelayMessage(messageID: message.messageID, text: "different bytes")
        do { _ = try await f.coordinator.handle(request(f, kind: .send, message: changed), from: f.peer); XCTFail("Expected ID conflict") }
        catch { XCTAssertEqual(error as? PluginRelayError, .reusedMessageID) }
        let unchanged = await f.transport.messages; XCTAssertEqual(unchanged, [message])
    }

    func testTimeoutRemainsUncertainAcrossCoordinatorRestartAndExplicitRetry() async throws {
        let f = try fixture(), message = try PluginRelayMessage(messageID: UUID(), text: "uncertain survives")
        await f.transport.configure(sendError: .timeout)
        do { _ = try await f.coordinator.handle(request(f, kind: .send, message: message), from: f.peer); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? PluginRelayHTTPError, .timeout) }
        let record = try await f.store.sendRecord(message.messageID, using: f.fence, permit: try syntheticPaidPermit(for: f.fence))
        XCTAssertEqual(record?.state, .uncertain); XCTAssertNil(record?.receipt)
        let restoredStore = try PluginRelayPhoneStore(persistence: f.disk, fence: f.fence, limits: .init())
        let restored = try PluginRelayPhoneCoordinator(fence: f.fence, store: restoredStore, transport: f.transport, authority: f.authority)
        await f.transport.configure()
        let response = try await restored.handle(request(f, kind: .send, message: message), from: f.peer)
        let sent = await f.transport.messages
        XCTAssertEqual(sent, [message, message]); XCTAssertEqual(response.receipt?.requestID, message.messageID)
    }

    func testLateReceiptAfterAuthorityRevocationNeverCommitsOrReturns() async throws {
        let f = try fixture(), message = try PluginRelayMessage(messageID: UUID(), text: "revoke while waiting")
        await f.transport.hold(.send)
        let operation = Task { try await f.coordinator.handle(request(f, kind: .send, message: message), from: f.peer) }
        await f.transport.waitForEntry(.send)
        let before = f.disk.snapshot(); f.authority.revoke(); await f.transport.release(.send)
        await expect(.authorityDenied) { _ = try await operation.value }
        XCTAssertEqual(f.disk.snapshot(), before)
        let record = try await f.store.sendRecord(message.messageID, using: f.fence, permit: try syntheticPaidPermit(for: f.fence))
        XCTAssertEqual(record?.state, .uncertain); XCTAssertNil(record?.receipt)
    }

    func testStopCancellationBarrierCannotCancelALaterOperation() async throws {
        let f = try fixture(), message = try PluginRelayMessage(messageID: UUID(), text: "stop local wait")
        let send = try request(f, kind: .send, message: message)
        await f.transport.hold(.send); await f.transport.hold(.cancel)
        let sending = Task { try await f.coordinator.handle(send, from: f.peer) }
        await f.transport.waitForEntry(.send)
        let stop = try request(f, kind: .localStop, cancel: send.courierID)
        let stopping = Task { try await f.coordinator.handle(stop, from: f.peer) }
        await f.transport.waitForEntry(.cancel)
        await f.transport.release(.send)
        await expect(.cancelled) { _ = try await sending.value }
        await expect(.busy) { _ = try await f.coordinator.handle(request(f, kind: .status), from: f.peer) }
        await f.transport.release(.cancel)
        let stopResponse = try await stopping.value
        XCTAssertEqual(stopResponse, stop)
        let next = try await f.coordinator.handle(request(f, kind: .status), from: f.peer)
        XCTAssertEqual(next.kind, .statusReport)
        let cancellations = await f.transport.cancelCalls; XCTAssertEqual(cancellations, 1)
        let record = try await f.store.sendRecord(message.messageID, using: f.fence, permit: try syntheticPaidPermit(for: f.fence))
        XCTAssertEqual(record?.state, .uncertain); XCTAssertNil(record?.receipt)
    }

    func testMismatchedStopDoesNotCancelAnotherCourier() async throws {
        let f = try fixture(), message = try PluginRelayMessage(messageID: UUID(), text: "another courier")
        await f.transport.hold(.send)
        let operation = Task { try await f.coordinator.handle(request(f, kind: .send, message: message), from: f.peer) }
        await f.transport.waitForEntry(.send)
        _ = try await f.coordinator.handle(request(f, kind: .localStop, cancel: UUID()), from: f.peer)
        let cancellations = await f.transport.cancelCalls; XCTAssertEqual(cancellations, 0)
        await f.transport.release(.send)
        let response = try await operation.value; XCTAssertEqual(response.receipt?.requestID, message.messageID)
    }

    func testCallerCancellationKeepsDurableUncertaintyAndRejectsLateReceipt() async throws {
        let f = try fixture(), message = try PluginRelayMessage(messageID: UUID(), text: "caller cancelled")
        await f.transport.hold(.send)
        let operation = Task { try await f.coordinator.handle(request(f, kind: .send, message: message), from: f.peer) }
        await f.transport.waitForEntry(.send)
        let before = f.disk.snapshot(); operation.cancel(); await f.transport.release(.send)
        await expect(.cancelled) { _ = try await operation.value }
        XCTAssertEqual(f.disk.snapshot(), before)
        let record = try await f.store.sendRecord(message.messageID, using: f.fence, permit: try syntheticPaidPermit(for: f.fence))
        XCTAssertEqual(record?.state, .uncertain); XCTAssertNil(record?.receipt)
    }

    func testInvalidationFencesLateReplyPageAndOldPeerRequests() async throws {
        let f = try fixture(), message = try PluginRelayMessage(messageID: UUID(), text: "old peer")
        try await f.store.reserve(message, using: f.fence, permit: try syntheticPaidPermit(for: f.fence))
        let reply = try PluginRelayReply(requestID: message.messageID, replyID: "late_reply", text: "never cross pairing fence")
        await f.transport.configure(page: try .init(route: f.fence.binding.route, replies: [reply], cursor: 9))
        await f.transport.hold(.replies)
        let operation = Task { try await f.coordinator.handle(request(f, kind: .replyRefresh), from: f.peer) }
        await f.transport.waitForEntry(.replies)
        let before = f.disk.snapshot()
        let invalidating = Task { try await f.coordinator.invalidate() }
        await f.transport.waitForEntry(.cancel)
        await f.transport.release(.replies)
        try await invalidating.value
        await expect(.inactive) { _ = try await operation.value }
        XCTAssertEqual(f.disk.snapshot(), before)
        await expect(.inactive) { _ = try await f.coordinator.handle(request(f, kind: .status), from: f.peer) }
        let restoredFence = PluginRelayFence(binding: f.fence.binding, localEpoch: UUID())
        // Restored data creates no authenticated coordinator or peer authority.
        let matched = try PluginRelayPhoneStore(persistence: f.disk, fence: restoredFence, limits: .init())
        let cursor = try await matched.cursor(using: restoredFence, permit: try syntheticPaidPermit(for: restoredFence)); XCTAssertEqual(cursor, 0)
    }

    func testFailedPageCommitNeverAdvancesCursorOrExposesChunkThenAckIsDurable() async throws {
        let f = try fixture(), message = try PluginRelayMessage(messageID: UUID(), text: "page commit")
        try await f.store.reserve(message, using: f.fence, permit: try syntheticPaidPermit(for: f.fence))
        let reply = try PluginRelayReply(requestID: message.messageID, replyID: "reply_commit", text: String(repeating: "x", count: 12_000))
        await f.transport.configure(page: try .init(route: f.fence.binding.route, replies: [reply], cursor: 51))
        let before = f.disk.snapshot(); f.disk.failAfterAdditionalWrites(1)
        do { _ = try await f.coordinator.handle(request(f, kind: .replyRefresh), from: f.peer); XCTFail("Expected storage failure") }
        catch { XCTAssertEqual(error as? PluginRelayError, .storageFailure) }
        let failedCursor = try await f.store.cursor(using: f.fence, permit: try syntheticPaidPermit(for: f.fence))
        XCTAssertEqual(failedCursor, 0); XCTAssertEqual(f.disk.snapshot(), before)
        let response = try await f.coordinator.handle(request(f, kind: .replyRefresh), from: f.peer)
        let first = try XCTUnwrap(response.chunk)
        XCTAssertEqual(response.kind, .chunk); XCTAssertEqual(first.requestID, message.messageID)
        XCTAssertLessThanOrEqual(try response.encoded().count, 60 * 1_024)
        let part = try PluginRelayV2Envelope(courierID: UUID(), fence: f.fence, kind: .chunkRequest,
            requestID: message.messageID, replyID: reply.replyID, chunkIndex: 1)
        let last = try await f.coordinator.handle(part, from: f.peer); XCTAssertEqual(last.chunk?.index, 1)
        let wrongReply = try PluginRelayV2Envelope(courierID: UUID(), fence: f.fence, kind: .chunkRequest,
            requestID: message.messageID, replyID: "wrong_reply_id", chunkIndex: 1)
        await expect(.invalidRequest) { _ = try await f.coordinator.handle(wrongReply, from: f.peer) }
        let status = try await f.coordinator.handle(request(f, kind: .status), from: f.peer)
        XCTAssertEqual(status.statusReport?.nextReply?.requestID, message.messageID)
        XCTAssertEqual(status.statusReport?.nextReply?.chunkCount, 2)
        let wrong = try PluginRelayV2Envelope(courierID: UUID(), fence: f.fence, kind: .acknowledge,
            requestID: message.messageID, replyID: reply.replyID, digest: String(repeating: "0", count: 64))
        do { _ = try await f.coordinator.handle(wrong, from: f.peer); XCTFail("Expected digest conflict") }
        catch { XCTAssertEqual(error as? PluginRelayError, .conflict) }
        let ack = try PluginRelayV2Envelope(courierID: UUID(), fence: f.fence, kind: .acknowledge,
            requestID: message.messageID, replyID: reply.replyID, digest: first.digest)
        f.disk.failAfterAdditionalWrites(1)
        do { _ = try await f.coordinator.handle(ack, from: f.peer); XCTFail("Expected failed ack commit") }
        catch { XCTAssertEqual(error as? PluginRelayError, .storageFailure) }
        let stillPending = try await f.store.pendingReplies(using: f.fence, permit: try syntheticPaidPermit(for: f.fence)); XCTAssertEqual(stillPending, [reply])
        let ackResponse = try await f.coordinator.handle(ack, from: f.peer); XCTAssertEqual(ackResponse, ack)
        let pending = try await f.store.pendingReplies(using: f.fence, permit: try syntheticPaidPermit(for: f.fence)), cursor = try await f.store.cursor(using: f.fence, permit: try syntheticPaidPermit(for: f.fence))
        XCTAssertTrue(pending.isEmpty); XCTAssertEqual(cursor, 51)
        let reads = await f.transport.afters; XCTAssertEqual(reads, [0, 0])
    }

    func testUnknownPageRequestCannotAdvanceCursorAndEmptyRefreshEndsItsCourier() async throws {
        let f = try fixture(), unknown = try PluginRelayReply(requestID: UUID(), replyID: "unknown", text: "unknown")
        await f.transport.configure(page: try .init(route: f.fence.binding.route, replies: [unknown], cursor: 3))
        do { _ = try await f.coordinator.handle(request(f, kind: .replyRefresh), from: f.peer); XCTFail("Expected unknown message") }
        catch { XCTAssertEqual(error as? PluginRelayError, .unknownMessage) }
        let cursor = try await f.store.cursor(using: f.fence, permit: try syntheticPaidPermit(for: f.fence)); XCTAssertEqual(cursor, 0)
        await f.transport.configure()
        let empty = try request(f, kind: .replyRefresh)
        let response = try await f.coordinator.handle(empty, from: f.peer)
        XCTAssertEqual(response, empty)
        let reads = await f.transport.afters; XCTAssertEqual(reads, [0, 0]) // No recursive poll.
    }

    func testPendingAndGrokManualStatusRemainReportsNotGrants() async throws {
        let dot = try fixture(); await dot.transport.configure(ready: false)
        let pending = try await dot.coordinator.handle(request(dot, kind: .status), from: dot.peer)
        XCTAssertEqual(pending.statusReport?.state, .authorizePlugin)
        XCTAssertEqual(pending.statusReport?.remoteReady, false); XCTAssertNil(pending.statusReport?.nextReply)
        let grok = try fixture(provider: .grokBot)
        let manual = try await grok.coordinator.handle(request(grok, kind: .status), from: grok.peer)
        XCTAssertEqual(manual.statusReport?.state, .manualReady)
        XCTAssertEqual(manual.statusReport?.automaticDeliveryReady, false)
        XCTAssertEqual(manual.statusReport?.minimumRoutineIntervalSeconds, 300)
        let dotReads = await dot.transport.afters, grokReads = await grok.transport.afters
        XCTAssertTrue(dotReads.isEmpty); XCTAssertTrue(grokReads.isEmpty)
    }

    func testDisconnectFailureClosesOnlyThisLocalRoute() async throws {
        let f = try fixture(); await f.transport.configure(disconnectError: .timeout)
        do { try await f.coordinator.disconnect(courierID: UUID(), from: f.peer); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? PluginRelayHTTPError, .timeout) }
        await expect(.inactive) { _ = try await f.coordinator.handle(request(f, kind: .status), from: f.peer) }
        let calls = await f.transport.disconnectCalls; XCTAssertEqual(calls, 1)
    }

    func testInboundResponseKindsAndEveryStaleFencePartitionAreRejected() async throws {
        let f = try fixture(), id = UUID()
        let receipt = try PluginRelayReceipt(requestID: id, route: f.fence.binding.route,
            receiptID: "incoming_receipt", state: .accepted, agentReplyReceived: false)
        let reply = try PluginRelayReply(requestID: id, replyID: "incoming_reply", text: "response direction")
        let chunk = try PluginRelayChunk.split(reply, route: f.fence.binding.route)[0]
        let report = PluginRelayStatusReport(state: .connected, remoteReady: true, deliveryMode: .events,
            automaticDeliveryReady: true, minimumRoutineIntervalSeconds: nil, nextReply: nil)
        let responses = [
            try PluginRelayV2Envelope(courierID: UUID(), fence: f.fence, kind: .receipt, receipt: receipt),
            try PluginRelayV2Envelope(courierID: UUID(), fence: f.fence, kind: .chunk, chunk: chunk),
            try PluginRelayV2Envelope(courierID: UUID(), fence: f.fence, kind: .statusReport, statusReport: report)
        ]
        for response in responses {
            await expect(.invalidRequest) { _ = try await f.coordinator.handle(response, from: f.peer) }
        }
        let route = f.fence.binding.route
        let wrongRoutes = [
            try PluginRelayReference(provider: .grokBot, routeID: route.routeID, generation: route.generation, accountGeneration: route.accountGeneration),
            try PluginRelayReference(provider: .dot, routeID: "route_other", generation: route.generation, accountGeneration: route.accountGeneration),
            try PluginRelayReference(provider: .dot, routeID: route.routeID, generation: UUID(), accountGeneration: route.accountGeneration),
            try PluginRelayReference(provider: .dot, routeID: route.routeID, generation: route.generation, accountGeneration: UUID())
        ]
        var wrong = wrongRoutes.map { PluginRelayFence(binding: .init(route: $0, pairingEpoch: f.fence.binding.pairingEpoch), localEpoch: f.fence.localEpoch) }
        wrong.append(.init(binding: .init(route: route, pairingEpoch: UUID()), localEpoch: f.fence.localEpoch))
        wrong.append(.init(binding: f.fence.binding, localEpoch: UUID()))
        for stale in wrong {
            let request = try PluginRelayV2Envelope(courierID: UUID(), fence: stale, kind: .status)
            do { _ = try await f.coordinator.handle(request, from: f.peer); XCTFail("Expected stale partition") }
            catch { XCTAssertEqual(error as? PluginRelayError, .wrongBinding) }
        }
        let statusCalls = await f.transport.statusCalls; XCTAssertEqual(statusCalls, 0); XCTAssertNil(f.disk.snapshot())
    }
}
#endif
