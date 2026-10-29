import XCTest
@testable import PeelWatchCore

private final class WatchCoordinatorDisk: PluginRelayPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data?
    private var fail = false
    func failNextWrite() { lock.lock(); defer { lock.unlock() }; fail = true }
    func read(maximumBytes: Int) throws -> Data? { lock.lock(); defer { lock.unlock() }; return bytes }
    func writeAtomically(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        if fail { fail = false; throw PluginRelayError.storageFailure }
        bytes = data
    }
}
private final class WatchCoordinatorAuthority: PluginRelayWatchAuthority, @unchecked Sendable {
    private let lock = NSLock()
    private let fence: PluginRelayFence
    private var enabled = true
    init(_ fence: PluginRelayFence) { self.fence = fence }
    func revoke() { lock.lock(); defer { lock.unlock() }; enabled = false }
    func validateCurrent(_ fence: PluginRelayFence) throws {
        lock.lock(); defer { lock.unlock() }
        guard enabled, fence == self.fence else { throw PluginRelayError.wrongBinding }
    }
}
private actor WatchCoordinatorTransport: PluginRelayWatchTransport {
    let fence: PluginRelayFence
    var ready = true
    var chunks: [PluginRelayChunk] = []
    var wrongCourier = false
    var wrongFence = false
    var wrongKind = false
    var wrongRequest = false
    var failSend = false
    private var holdSend = false
    private var enteredSend = false
    private var gate: CheckedContinuation<Void, Never>?
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var cancelArrivals: [CheckedContinuation<Void, Never>] = []
    private(set) var requests: [PluginRelayV2Envelope] = []
    private(set) var cancellations: [UUID] = []
    init(_ fence: PluginRelayFence) { self.fence = fence }
    func configure(ready: Bool? = nil, chunks: [PluginRelayChunk]? = nil, wrongCourier: Bool = false,
                   wrongFence: Bool = false, wrongKind: Bool = false, wrongRequest: Bool = false,
                   failSend: Bool = false) {
        if let ready { self.ready = ready }; if let chunks { self.chunks = chunks }
        self.wrongCourier = wrongCourier; self.wrongFence = wrongFence; self.wrongKind = wrongKind
        self.wrongRequest = wrongRequest; self.failSend = failSend
    }
    func hold() { holdSend = true }
    func waitForSend() async {
        if enteredSend { return }
        await withCheckedContinuation { arrivals.append($0) }
    }
    func release() { holdSend = false; gate?.resume(); gate = nil }
    func exchange(_ data: Data, courierID: UUID) async throws -> Data {
        let request = try PluginRelayV2Envelope.decode(data, expectedFence: fence, expectedCourierID: courierID)
        requests.append(request)
        let id = wrongCourier ? UUID() : courierID
        let outputFence = wrongFence ? PluginRelayFence(binding: fence.binding, localEpoch: UUID()) : fence
        if wrongKind { return try PluginRelayV2Envelope(courierID: id, fence: outputFence, kind: .status).encoded() }
        switch request.kind {
        case .status:
            let dot = fence.binding.route.provider == .dot
            return try PluginRelayV2Envelope(courierID: id, fence: outputFence, kind: .statusReport,
                statusReport: .init(state: ready ? (dot ? .connected : .manualReady) : .authorizePlugin,
                    remoteReady: ready, deliveryMode: dot ? .events : .manual,
                    automaticDeliveryReady: ready && dot, minimumRoutineIntervalSeconds: dot ? nil : 300,
                    nextReply: nil)).encoded()
        case .send:
            enteredSend = true; arrivals.forEach { $0.resume() }; arrivals = []
            if holdSend { await withCheckedContinuation { gate = $0 } }
            if failSend { throw PluginRelayWatchCoordinatorError.unavailable }
            let receipt = try PluginRelayReceipt(requestID: wrongRequest ? UUID() : request.message!.messageID,
                route: outputFence.binding.route, receiptID: "receipt_watch_fixture", state: .accepted, agentReplyReceived: false)
            return try PluginRelayV2Envelope(courierID: id, fence: outputFence, kind: .receipt, receipt: receipt).encoded()
        case .replyRefresh:
            if let first = chunks.first { return try PluginRelayV2Envelope(courierID: id, fence: outputFence, kind: .chunk, chunk: first).encoded() }
            return try PluginRelayV2Envelope(courierID: id, fence: outputFence, kind: .replyRefresh).encoded()
        case .chunkRequest:
            guard let value = chunks.first(where: { $0.index == request.chunkIndex }) else { throw PluginRelayError.unknownMessage }
            return try PluginRelayV2Envelope(courierID: id, fence: outputFence, kind: .chunk, chunk: value).encoded()
        case .acknowledge: return data
        default: throw PluginRelayWatchCoordinatorError.invalidResponse
        }
    }
    func waitForCancellation() async {
        if !cancellations.isEmpty { return }
        await withCheckedContinuation { cancelArrivals.append($0) }
    }
    func cancel(courierID: UUID) async {
        cancellations.append(courierID); cancelArrivals.forEach { $0.resume() }; cancelArrivals = []
    }
}

final class PluginRelayWatchCoordinatorTests: XCTestCase {
    private struct Fixture {
        let fence: PluginRelayFence
        let disk: WatchCoordinatorDisk
        let authority: WatchCoordinatorAuthority
        let transport: WatchCoordinatorTransport
        let store: PluginRelayWatchStore
        let client: PluginRelayWatchCoordinator
    }
    private func fixture(provider: CloudAgentProvider = .dot) throws -> Fixture {
        let route = try PluginRelayReference(provider: provider, routeID: "route_watch_fixture", generation: UUID(), accountGeneration: UUID())
        let fence = PluginRelayFence(binding: .init(route: route, pairingEpoch: UUID()), localEpoch: UUID())
        let disk = WatchCoordinatorDisk(), authority = WatchCoordinatorAuthority(fence), transport = WatchCoordinatorTransport(fence)
        let store = try PluginRelayWatchStore(persistence: disk, fence: fence)
        return try Fixture(fence: fence, disk: disk, authority: authority, transport: transport, store: store,
            client: PluginRelayWatchCoordinator(fence: fence, store: store, transport: transport, authority: authority))
    }
    private func message() throws -> PluginRelayMessage { try .init(messageID: UUID(), text: "Watch fixture message") }
    private func expectFailure<T>(_ action: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await action(); XCTFail("Expected rejection", file: file, line: line) } catch {}
    }
    func testStatusIsOneExchangeAndPendingCannotSend() async throws {
        let f = try fixture(); await f.transport.configure(ready: false)
        let state = try await f.client.status(); XCTAssertEqual(state.report?.state, .authorizePlugin)
        await expectFailure { try await f.client.send(self.message()) }
        let requests = await f.transport.requests; XCTAssertEqual(requests.map(\.kind), [.status])
    }
    func testGrokManualDoesNotBecomeAutomatic() async throws {
        let f = try fixture(provider: .grokBot)
        let state = try await f.client.status()
        XCTAssertEqual(state.report?.state, .manualReady)
        XCTAssertEqual(state.report?.automaticDeliveryReady, false)
        XCTAssertEqual(state.report?.minimumRoutineIntervalSeconds, 300)
    }
    func testPersistenceFailureBeforeSendMakesNoTransportCall() async throws {
        let f = try fixture(); _ = try await f.client.status(); f.disk.failNextWrite()
        await expectFailure { try await f.client.send(self.message()) }
        let requests = await f.transport.requests; XCTAssertEqual(requests.count, 1)
    }
    func testUncertainSendRestoresExactIDAndBodyWithNewCourier() async throws {
        let f = try fixture(); _ = try await f.client.status(); let message = try message()
        await f.transport.configure(failSend: true)
        await expectFailure { try await f.client.send(message) }
        let restoredStore = try PluginRelayWatchStore(persistence: f.disk, fence: f.fence)
        let saved = try await restoredStore.outgoingMessages(using: f.fence)
        XCTAssertEqual(saved.first?.message, message); XCTAssertEqual(saved.first?.state, .uncertain)
        let restored = try PluginRelayWatchCoordinator(fence: f.fence, store: restoredStore, transport: f.transport, authority: f.authority)
        await f.transport.configure(); _ = try await restored.status(); _ = try await restored.send(saved[0].message)
        let requests = await f.transport.requests.filter { $0.kind == .send }
        XCTAssertEqual(requests.map(\.message), [message, message]); XCTAssertNotEqual(requests[0].courierID, requests[1].courierID)
        XCTAssertNotEqual(requests[0].courierID, message.messageID)
    }
    func testSameLogicalIDRejectsChangedBytes() async throws {
        let f = try fixture(); _ = try await f.client.status(); let message = try message()
        _ = try await f.client.send(message)
        let changed = try PluginRelayMessage(messageID: message.messageID, text: message.text + "!")
        await expectFailure { try await f.client.send(changed) }
        let sends = await f.transport.requests.filter { $0.kind == .send }; XCTAssertEqual(sends.count, 1)
    }
    func testWrongCourierAndFenceAndResponseDirectionAreRejected() async throws {
        for failure in 0..<3 {
            let f = try fixture()
            await f.transport.configure(wrongCourier: failure == 0, wrongFence: failure == 1, wrongKind: failure == 2)
            await expectFailure { try await f.client.status() }
            let state = try await f.client.snapshot(); XCTAssertNil(state.report)
        }
    }
    func testReceiptMustNameTheLogicalMessage() async throws {
        let f = try fixture(); _ = try await f.client.status(); await f.transport.configure(wrongRequest: true)
        await expectFailure { try await f.client.send(self.message()) }
        let records = try await f.store.outgoingMessages(using: f.fence); XCTAssertEqual(records.first?.state, .uncertain)
    }
    func testEmptyRefreshEndsAfterExactlyOneExchange() async throws {
        let f = try fixture(); _ = try await f.client.status(); _ = try await f.client.refreshReply()
        let requests = await f.transport.requests; XCTAssertEqual(requests.map(\.kind), [.status, .replyRefresh])
    }
    func testMultichunkReplyPersistsBeforeAcknowledgment() async throws {
        let f = try fixture(); _ = try await f.client.status(); let message = try message(); _ = try await f.client.send(message)
        let reply = try PluginRelayReply(requestID: message.messageID, replyID: "reply_eight", text: String(repeating: "😀", count: 8_000))
        let chunks = try PluginRelayChunk.split(reply, route: f.fence.binding.route)
        XCTAssertLessThanOrEqual(chunks.count, 8)
        await f.transport.configure(chunks: chunks)
        let state = try await f.client.refreshReply(); XCTAssertEqual(state.replies, [reply])
        let requests = await f.transport.requests
        XCTAssertEqual(requests.filter { $0.kind == .chunkRequest }.count, chunks.count - 1)
        XCTAssertEqual(requests.last?.kind, .acknowledge)
        let restoredStore = try PluginRelayWatchStore(persistence: f.disk, fence: f.fence)
        let restored = try await restoredStore.completeReplies(using: f.fence); XCTAssertEqual(restored, [reply])
    }
    func testReplyWriteFailureCannotAcknowledge() async throws {
        let f = try fixture(); _ = try await f.client.status(); let message = try message(); _ = try await f.client.send(message)
        let reply = try PluginRelayReply(requestID: message.messageID, replyID: "reply_failure", text: "Real fixture reply")
        await f.transport.configure(chunks: try PluginRelayChunk.split(reply, route: f.fence.binding.route))
        f.disk.failNextWrite(); await expectFailure { try await f.client.refreshReply() }
        let requests = await f.transport.requests; XCTAssertFalse(requests.contains { $0.kind == .acknowledge })
    }
    func testRevokedLateReceiptCannotCommit() async throws {
        let f = try fixture(); _ = try await f.client.status(); await f.transport.hold()
        let work = Task { try await f.client.send(self.message()) }
        await f.transport.waitForSend(); f.authority.revoke(); await f.transport.release()
        await expectFailure { try await work.value }
        let records = try await f.store.outgoingMessages(using: f.fence); XCTAssertEqual(records.first?.state, .uncertain)
    }
    func testStopWaitsForOldOperationAndRejectsLateReceipt() async throws {
        let f = try fixture(); _ = try await f.client.status(); await f.transport.hold()
        let work = Task { try await f.client.send(self.message()) }
        await f.transport.waitForSend()
        let stop = Task { await f.client.stop() }
        // Exact cancellation entry is a deterministic gate; no sleeps/polling.
        await f.transport.waitForCancellation()
        await expectFailure { try await f.client.status() }
        await f.transport.release(); await stop.value
        await expectFailure { try await work.value }
        let records = try await f.store.outgoingMessages(using: f.fence); XCTAssertEqual(records.first?.state, .uncertain)
        _ = try await f.client.status()
    }
    func testInvalidateIsTerminalAndPreservesSavedMessages() async throws {
        let f = try fixture(); _ = try await f.client.status(); let message = try message(); _ = try await f.client.send(message)
        try await f.client.invalidate()
        await expectFailure { try await f.client.status() }
        await expectFailure { try await f.store.outgoingMessages(using: f.fence) }
        let restored = try PluginRelayWatchStore(persistence: f.disk, fence: f.fence)
        let records = try await restored.outgoingMessages(using: f.fence); XCTAssertEqual(records.first?.message, message)
    }
}
