import XCTest
@testable import PeelWatchCore

private final class RelayMemoryPersistence: PluginRelayPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var fail = false
    init(_ data: Data? = nil) { self.data = data }
    func failNextWrite() { lock.lock(); defer { lock.unlock() }; fail = true }
    func bytes() -> Data? { lock.lock(); defer { lock.unlock() }; return data }
    func read(maximumBytes: Int) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard data.map({ $0.count <= maximumBytes }) ?? true else { throw PluginRelayError.capacity }; return data
    }
    func writeAtomically(_ value: Data) throws {
        lock.lock(); defer { lock.unlock() }
        if fail { fail = false; throw PluginRelayError.storageFailure }; data = value
    }
}

final class PluginRelayCoreTests: XCTestCase {
    private func fence(provider: CloudAgentProvider = .dot, routeID: String = "route_fixture",
                       generation: UUID = UUID(), account: UUID = UUID(), pair: UUID = UUID()) throws -> PluginRelayFence {
        PluginRelayFence(binding: .init(route: try .init(provider: provider, routeID: routeID,
            generation: generation, accountGeneration: account), pairingEpoch: pair), localEpoch: UUID())
    }
    private func message(_ text: String = "New request") throws -> PluginRelayMessage { try .init(messageID: UUID(), text: text) }
    private func equal<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
    private func isTrue(_ actual: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(actual, file: file, line: line) }
    private func expect(_ expected: PluginRelayError, file: StaticString = #filePath, line: UInt = #line,
                        _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? PluginRelayError, expected, file: file, line: line) }
    }

    func testExplicitReferenceAndLocalEpochAreNotNativeConversationOrAuthority() throws {
        let current = try fence(), request = try message()
        let first = try PluginRelayV2Envelope(courierID: UUID(), fence: current, kind: .send, message: request)
        let second = try PluginRelayV2Envelope(courierID: UUID(), fence: current, kind: .send, message: request)
        XCTAssertNotEqual(first.courierID, second.courierID)
        XCTAssertEqual(first.message?.messageID, second.message?.messageID)
        let data = try first.encoded()
        XCTAssertEqual(try PluginRelayV2Envelope.decode(data, expectedFence: current), first)
        XCTAssertThrowsError(try WatchCloudRequest.decode(data))
        XCTAssertThrowsError(try PluginRelayV2Envelope.decode(WatchCloudRequest(kind: .status, provider: .dot).encoded(), expectedFence: current))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(current.binding.route)) as? [String: Any])
        object["kind"] = "providerNative"
        XCTAssertThrowsError(try JSONDecoder().decode(PluginRelayReference.self, from: JSONSerialization.data(withJSONObject: object)))
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["ready", "conversationID", "token", "challenge", "subject", "endpoint"] { XCTAssertFalse(text.contains(forbidden)) }
        XCTAssertThrowsError(try PluginRelayV2Envelope(courierID: UUID(), fence: current, kind: .status, message: request))
    }

    func testCodePointAndUTF8LimitsMatchServiceRatherThanGraphemeCount() throws {
        XCTAssertNoThrow(try message(String(repeating: "😀", count: 4_000)))
        XCTAssertThrowsError(try message(String(repeating: "e\u{301}", count: 2_001)))
        XCTAssertThrowsError(try message(String(repeating: "x", count: 4_001)))
        XCTAssertThrowsError(try message("a\u{0}b"))
        XCTAssertThrowsError(try message("a\u{7f}b"))
        XCTAssertThrowsError(try message(" \n\t "))
        XCTAssertNoThrow(try message("a\n\tb"))
        XCTAssertThrowsError(try PluginRelayReply(requestID: UUID(), replyID: "r", text: String(repeating: "😀", count: 8_001)))
    }

    func testRestoredUncertainSendRetainsLogicalIDAndContentWithNewCourierID() async throws {
        let current = try fence(), disk = RelayMemoryPersistence(), request = try message()
        let watch = try PluginRelayWatchStore(persistence: disk, fence: current)
        try await watch.reserve(request, using: current)
        try await watch.markUncertain(request.messageID, using: current)
        let restoredFence = PluginRelayFence(binding: current.binding, localEpoch: UUID())
        let restored = try PluginRelayWatchStore(persistence: disk, fence: restoredFence)
        let record = try await restored.reserve(request, using: restoredFence)
        XCTAssertEqual(record.state, .uncertain)
        XCTAssertEqual(record.message, request)
        await expect(.reusedMessageID) { try await restored.reserve(.init(messageID: request.messageID, text: "Changed"), using: restoredFence) }
        let phoneDisk = RelayMemoryPersistence()
        let phone = try PluginRelayPhoneStore(persistence: phoneDisk, fence: restoredFence, limits: .init())
        try await phone.reserve(request, using: restoredFence, permit: try syntheticPaidPermit(for: restoredFence))
        try await phone.markUncertain(request.messageID, using: restoredFence, permit: try syntheticPaidPermit(for: restoredFence))
        let phoneRestored = try PluginRelayPhoneStore(persistence: phoneDisk, fence: restoredFence, limits: .init())
        equal(try await phoneRestored.reserve(request, using: restoredFence, permit: try syntheticPaidPermit(for: restoredFence)).state, .uncertain)
        let receipt = try PluginRelayReceipt(requestID: request.messageID, route: current.binding.route,
            receiptID: "request_1", state: .replied, agentReplyReceived: true)
        try await phoneRestored.record(receipt, using: restoredFence, permit: try syntheticPaidPermit(for: restoredFence))
        try await restored.record(receipt, using: restoredFence)
        let complete = try await restored.completeReplies(using: restoredFence)
        let pending = try await phoneRestored.pendingReplies(using: restoredFence, permit: try syntheticPaidPermit(for: restoredFence))
        XCTAssertTrue(complete.isEmpty); XCTAssertTrue(pending.isEmpty)
    }

    func testReplyArrivalOrderAndFailureDoNotSkipAnOlderRequest() async throws {
        let current = try fence(), disk = RelayMemoryPersistence()
        let store = try PluginRelayPhoneStore(persistence: disk, fence: current, limits: .init())
        let a = try message("A first"), b = try message("B second")
        try await store.reserve(a, using: current, permit: try syntheticPaidPermit(for: current)); try await store.reserve(b, using: current, permit: try syntheticPaidPermit(for: current))
        let replyB = try PluginRelayReply(requestID: b.messageID, replyID: "same-id-is-route-request-scoped", text: "B answered first")
        let replyA = try PluginRelayReply(requestID: a.messageID, replyID: "same-id-is-route-request-scoped", text: "A answered later")
        let pageB = try PluginRelayReplyPage(route: current.binding.route, replies: [replyB], cursor: 7)
        let previousBytes = disk.bytes(); disk.failNextWrite()
        await expect(.storageFailure) { try await store.ingest(pageB, after: 0, using: current, permit: try syntheticPaidPermit(for: current)) }
        let failedCursor = try await store.cursor(using: current, permit: try syntheticPaidPermit(for: current))
        XCTAssertEqual(failedCursor, 0); XCTAssertEqual(disk.bytes(), previousBytes)
        try await store.ingest(pageB, after: 0, using: current, permit: try syntheticPaidPermit(for: current))
        try await store.ingest(.init(route: current.binding.route, replies: [replyA], cursor: 12), after: 7, using: current, permit: try syntheticPaidPermit(for: current))
        let pending = try await store.pendingReplies(using: current, permit: try syntheticPaidPermit(for: current))
        XCTAssertEqual(pending, [replyB, replyA])
        await expect(.staleCursor) { try await store.ingest(pageB, after: 0, using: current, permit: try syntheticPaidPermit(for: current)) }
        let restored = try PluginRelayPhoneStore(persistence: disk, fence: current, limits: .init())
        let cursor = try await restored.cursor(using: current, permit: try syntheticPaidPermit(for: current))
        XCTAssertEqual(cursor, 12)
        equal(try await restored.pendingReplies(using: current, permit: try syntheticPaidPermit(for: current)), pending)
    }

    func testCapacityAndEncodedByteFailurePreserveCursorAndUnacknowledgedWork() async throws {
        let current = try fence(), store = try PluginRelayPhoneStore(persistence: RelayMemoryPersistence(), fence: current,
            limits: .init(maximumReplies: 1))
        let a = try message("A"), b = try message("B")
        try await store.reserve(a, using: current, permit: try syntheticPaidPermit(for: current)); try await store.reserve(b, using: current, permit: try syntheticPaidPermit(for: current))
        let ra = try PluginRelayReply(requestID: a.messageID, replyID: "a", text: "A")
        let rb = try PluginRelayReply(requestID: b.messageID, replyID: "b", text: "B")
        try await store.ingest(.init(route: current.binding.route, replies: [ra], cursor: 1), after: 0, using: current, permit: try syntheticPaidPermit(for: current))
        await expect(.capacity) { try await store.ingest(.init(route: current.binding.route, replies: [rb], cursor: 2), after: 1, using: current, permit: try syntheticPaidPermit(for: current)) }
        let cursor = try await store.cursor(using: current, permit: try syntheticPaidPermit(for: current)), pending = try await store.pendingReplies(using: current, permit: try syntheticPaidPermit(for: current))
        XCTAssertEqual(cursor, 1); XCTAssertEqual(pending, [ra])
        let small = try PluginRelayPhoneStore(persistence: RelayMemoryPersistence(), fence: current,
            limits: .init(maximumBytes: 1_024))
        try await small.reserve(a, using: current, permit: try syntheticPaidPermit(for: current))
        let large = try PluginRelayReply(requestID: a.messageID, replyID: "a", text: String(repeating: "\"", count: 16_000))
        await expect(.capacity) { try await small.ingest(.init(route: current.binding.route, replies: [large], cursor: 1), after: 0, using: current, permit: try syntheticPaidPermit(for: current)) }
        equal(try await small.cursor(using: current, permit: try syntheticPaidPermit(for: current)), 0)
    }

    func testAccountRouteProviderAndPairMismatchCannotRestoreOrCommit() async throws {
        let current = try fence(), disk = RelayMemoryPersistence(), request = try message()
        let store = try PluginRelayPhoneStore(persistence: disk, fence: current, limits: .init())
        try await store.reserve(request, using: current, permit: try syntheticPaidPermit(for: current))
        let r = current.binding.route
        let wrong = [try fence(provider: .grokBot, generation: r.generation, account: r.accountGeneration, pair: current.binding.pairingEpoch),
            try fence(generation: UUID(), account: r.accountGeneration, pair: current.binding.pairingEpoch),
            try fence(generation: r.generation, account: UUID(), pair: current.binding.pairingEpoch),
            try fence(routeID: "route_other", generation: r.generation, account: r.accountGeneration, pair: current.binding.pairingEpoch),
            try fence(generation: r.generation, account: r.accountGeneration, pair: UUID())]
        for other in wrong {
            XCTAssertThrowsError(try PluginRelayPhoneStore(persistence: disk, fence: other, limits: .init()))
            await expect(.wrongBinding) { _ = try await store.reserve(request, using: other, permit: try syntheticPaidPermit(for: other)) }
        }
        let rotated = try await store.invalidate(using: current, newLocalEpoch: UUID())
        await expect(.wrongBinding) { _ = try await store.reserve(request, using: current, permit: try syntheticPaidPermit(for: current)) }
        let record = try await store.sendRecord(request.messageID, using: rotated, permit: try syntheticPaidPermit(for: rotated))
        XCTAssertEqual(record?.message, request)
        XCTAssertEqual(rotated.binding.route.accountGeneration, current.binding.route.accountGeneration)
    }

    func testLongEscapedUnicodeReplyChunksFitAndRestoreWithoutTruncation() async throws {
        let current = try fence(), disk = RelayMemoryPersistence()
        let reply = try PluginRelayReply(requestID: UUID(), replyID: "reply", text: String(repeating: "😀\"\\\n", count: 4_500))
        let chunks = try PluginRelayChunk.split(reply, route: current.binding.route)
        XCTAssertGreaterThan(chunks.count, 1); XCTAssertLessThanOrEqual(chunks.count, 8)
        let watch = try PluginRelayWatchStore(persistence: disk, fence: current)
        try await watch.reserve(.init(messageID: reply.requestID, text: "Request for long reply"), using: current)
        for chunk in chunks {
            let wire = try PluginRelayV2Envelope(courierID: UUID(), fence: current, kind: .chunk, chunk: chunk)
            let data = try wire.encoded()
            XCTAssertLessThanOrEqual(data.count, 60 * 1_024)
            XCTAssertEqual(try PluginRelayV2Envelope.decode(data, expectedFence: current).chunk, chunk)
        }
        try await watch.receive(chunks.last!, using: current)
        try await watch.receive(chunks.last!, using: current)
        let restored = try PluginRelayWatchStore(persistence: disk, fence: current)
        await expect(.unknownMessage) { _ = try await restored.acknowledgment(requestID: reply.requestID, courierID: UUID(), using: current) }
        for chunk in chunks.dropLast() { try await restored.receive(chunk, using: current) }
        let complete = try await restored.completeReplies(using: current)
        XCTAssertEqual(complete, [reply])
        try await restored.receive(chunks[0], using: current)
        let ack = try await restored.acknowledgment(requestID: reply.requestID, courierID: UUID(), using: current)
        XCTAssertEqual(ack.digest, PluginRelayValidation.digest(reply.text))
        XCTAssertThrowsError(try PluginRelayV2Envelope.decode(Data(repeating: 32, count: 60 * 1_024 + 1), expectedFence: current))
    }

    func testConflictingDuplicateAndCorruptDigestNeverProduceReplyOrAck() async throws {
        let current = try fence(), watch = try PluginRelayWatchStore(persistence: RelayMemoryPersistence(), fence: current)
        let reply = try PluginRelayReply(requestID: UUID(), replyID: "reply", text: String(repeating: "a", count: 9_000))
        let chunks = try PluginRelayChunk.split(reply, route: current.binding.route), first = chunks[0]
        try await watch.reserve(.init(messageID: reply.requestID, text: "Request for chunk reply"), using: current)
        try await watch.receive(first, using: current)
        let conflict = try PluginRelayChunk(route: first.route, requestID: first.requestID, replyID: first.replyID,
            index: first.index, count: first.count, totalUTF8Bytes: first.totalUTF8Bytes, digest: first.digest, text: "changed")
        await expect(.conflict) { _ = try await watch.receive(conflict, using: current) }
        let last = chunks[1]
        let badDigest = try PluginRelayChunk(route: last.route, requestID: last.requestID, replyID: last.replyID,
            index: last.index, count: last.count, totalUTF8Bytes: last.totalUTF8Bytes, digest: String(repeating: "0", count: 64), text: last.text)
        await expect(.conflict) { _ = try await watch.receive(badDigest, using: current) }
        let complete = try await watch.completeReplies(using: current)
        XCTAssertTrue(complete.isEmpty)
        await expect(.unknownMessage) { _ = try await watch.acknowledgment(requestID: reply.requestID, courierID: UUID(), using: current) }
        try await watch.receive(last, using: current)
        equal(try await watch.completeReplies(using: current), [reply])
    }

    func testPhoneRetainsReplyUntilDurableWatchAckAndAckFailureIsRetryable() async throws {
        let current = try fence(), disk = RelayMemoryPersistence()
        let phone = try PluginRelayPhoneStore(persistence: disk, fence: current, limits: .init())
        let request = try message(), reply = try PluginRelayReply(requestID: request.messageID, replyID: "r", text: "Actual Dot text")
        try await phone.reserve(request, using: current, permit: try syntheticPaidPermit(for: current))
        try await phone.ingest(.init(route: current.binding.route, replies: [reply], cursor: 4), after: 0, using: current, permit: try syntheticPaidPermit(for: current))
        let watchDisk = RelayMemoryPersistence(), watch = try PluginRelayWatchStore(persistence: watchDisk, fence: current)
        try await watch.reserve(request, using: current)
        let chunk = try await phone.chunks(requestID: request.messageID, using: current, permit: try syntheticPaidPermit(for: current))[0]
        watchDisk.failNextWrite()
        await expect(.storageFailure) { _ = try await watch.receive(chunk, using: current) }
        await expect(.unknownMessage) { _ = try await watch.acknowledgment(requestID: request.messageID, courierID: UUID(), using: current) }
        try await watch.receive(chunk, using: current)
        let ack = try await watch.acknowledgment(requestID: request.messageID, courierID: UUID(), using: current)
        disk.failNextWrite()
        await expect(.storageFailure) { try await phone.acknowledge(requestID: request.messageID, replyID: "r", digest: ack.digest!, using: current, permit: try syntheticPaidPermit(for: current)) }
        equal(try await phone.pendingReplies(using: current, permit: try syntheticPaidPermit(for: current)), [reply])
        try await phone.acknowledge(requestID: request.messageID, replyID: "r", digest: ack.digest!, using: current, permit: try syntheticPaidPermit(for: current))
        try await phone.acknowledge(requestID: request.messageID, replyID: "r", digest: ack.digest!, using: current, permit: try syntheticPaidPermit(for: current))
        isTrue(try await phone.pendingReplies(using: current, permit: try syntheticPaidPermit(for: current)).isEmpty)
        equal(try await phone.cursor(using: current, permit: try syntheticPaidPermit(for: current)), 4)
    }

    func testBoundedServicePageAndFileRestartPreserveReplyCursor() async throws {
        let current = try fence(), request = try message()
        let reply = try PluginRelayReply(requestID: request.messageID, replyID: "r", text: "actual reply")
        let page = try PluginRelayReplyPage(route: current.binding.route, replies: [reply], cursor: 81)
        let pageData = try JSONEncoder().encode(page)
        XCTAssertEqual(try PluginRelayReplyPage.decode(pageData, expectedRoute: current.binding.route), page)
        XCTAssertThrowsError(try PluginRelayReplyPage.decode(pageData, expectedRoute: fence().binding.route))
        XCTAssertThrowsError(try PluginRelayReplyPage.decode(Data(repeating: 32, count: 256 * 1_024 + 1), expectedRoute: current.binding.route))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = try PluginRelayFilePersistence(fileURL: directory.appendingPathComponent("state.json"))
        let store = try PluginRelayPhoneStore(persistence: persistence, fence: current, limits: .init())
        try await store.reserve(request, using: current, permit: try syntheticPaidPermit(for: current)); try await store.ingest(page, after: 0, using: current, permit: try syntheticPaidPermit(for: current))
        let restored = try PluginRelayPhoneStore(persistence: persistence, fence: current, limits: .init())
        equal(try await restored.cursor(using: current, permit: try syntheticPaidPermit(for: current)), 81)
        equal(try await restored.pendingReplies(using: current, permit: try syntheticPaidPermit(for: current)), [reply])
        XCTAssertThrowsError(try PluginRelayPhoneStore(persistence: RelayMemoryPersistence(Data("{}".utf8)), fence: current, limits: .init()))
    }

    func testContractValidSlashPageUsesActualInputByteBudget() throws {
        let current = try fence()
        let replies = try (0..<8).map { index in
            try PluginRelayReply(requestID: UUID(), replyID: "reply_\(index)", text: String(repeating: "/", count: 32_000))
        }
        let page = try PluginRelayReplyPage(route: current.binding.route, replies: replies, cursor: 8)
        let brokerCompatible = JSONEncoder(); brokerCompatible.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try brokerCompatible.encode(page)
        XCTAssertLessThan(bytes.count, 256 * 1_024)
        XCTAssertGreaterThan(try JSONEncoder().encode(page).count, 256 * 1_024)
        XCTAssertEqual(try PluginRelayReplyPage.decode(bytes, expectedRoute: current.binding.route), page)
    }

    func testCanonicalEquivalentTextCannotReuseLogicalIDWithDifferentUTF8() async throws {
        let current = try fence(), id = UUID()
        let composed = try PluginRelayMessage(messageID: id, text: "é")
        let decomposed = try PluginRelayMessage(messageID: id, text: "e\u{301}")
        XCTAssertEqual(composed.text, decomposed.text)
        XCTAssertNotEqual(composed, decomposed)
        let phone = try PluginRelayPhoneStore(persistence: RelayMemoryPersistence(), fence: current, limits: .init())
        let watch = try PluginRelayWatchStore(persistence: RelayMemoryPersistence(), fence: current)
        try await phone.reserve(composed, using: current, permit: try syntheticPaidPermit(for: current)); try await watch.reserve(composed, using: current)
        await expect(.reusedMessageID) { _ = try await phone.reserve(decomposed, using: current, permit: try syntheticPaidPermit(for: current)) }
        await expect(.reusedMessageID) { _ = try await watch.reserve(decomposed, using: current) }
    }

    func testUnknownWatchReplyAndCapacityCannotReplaceRetainedWork() async throws {
        let current = try fence(), disk = RelayMemoryPersistence()
        let watch = try PluginRelayWatchStore(persistence: disk, fence: current, maximumReplies: 1)
        let a = try message("A"), b = try message("B")
        let ra = try PluginRelayReply(requestID: a.messageID, replyID: "r", text: "A reply")
        let rb = try PluginRelayReply(requestID: b.messageID, replyID: "r", text: "B reply")
        let first = try PluginRelayChunk.split(ra, route: current.binding.route)[0]
        await expect(.unknownMessage) { _ = try await watch.receive(first, using: current) }
        XCTAssertNil(disk.bytes())
        try await watch.reserve(a, using: current); try await watch.reserve(b, using: current)
        try await watch.receive(first, using: current)
        let saved = disk.bytes()
        let second = try PluginRelayChunk.split(rb, route: current.binding.route)[0]
        await expect(.capacity) { _ = try await watch.receive(second, using: current) }
        XCTAssertEqual(disk.bytes(), saved)
        equal(try await watch.completeReplies(using: current), [ra])
    }
}
