import Foundation
import XCTest
@testable import PeelWatchCore

private final class CloudAgentFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value.addTimeInterval(seconds); lock.unlock() }
}

private final class CloudAgentFixtureProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        var status = 200
        var json: [String: Any] = ["ok": true]
        var data: Data?
        var headers: [String: String] = [:]
        var responseURL: URL?
        var hold = false
        var failure = false
    }
    private static let lock = NSLock()
    private static var queued: [String: [Response]] = [:]
    private static var recorded: [URLRequest] = []
    private static var started: (() -> Void)?
    static func reset() { lock.lock(); queued = [:]; recorded = []; started = nil; lock.unlock() }
    static func enqueue(_ path: String, _ responses: Response...) { lock.lock(); queued[path, default: []] += responses; lock.unlock() }
    static func onStart(_ handler: @escaping () -> Void) { lock.lock(); started = handler; lock.unlock() }
    static func requests(_ path: String? = nil) -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded.filter { path == nil || $0.url?.lastPathComponent == path }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.lastPathComponent ?? ""
        Self.lock.lock(); Self.recorded.append(request)
        let handler = Self.started
        let response: Response
        if var queue = Self.queued[path], !queue.isEmpty {
            response = queue.removeFirst(); Self.queued[path] = queue
        } else {
            switch path {
            case "auth.test": response = Response(json: ["ok": true, "team_id": "TTEAM123", "user_id": "UHUMAN123"])
            case "users.info": response = Response(json: ["ok": true, "user": ["id": "UAGENT123", "team_id": "TTEAM123", "is_bot": true]])
            case "conversations.info": response = Response(json: ["ok": true, "channel": ["id": "CROOM123", "is_member": true]])
            case "conversations.members": response = Response(json: ["ok": true, "members": ["UHUMAN123", "UAGENT123"]])
            case "chat.postMessage": response = Response(json: ["ok": true, "channel": "CROOM123", "ts": "1800000000.000001"])
            case "conversations.replies": response = Response(json: ["ok": true, "messages": [], "has_more": false])
            default: response = Response(status: 404, json: ["ok": false])
            }
        }
        Self.lock.unlock(); handler?()
        if response.hold { return }
        if response.failure { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
        let http = HTTPURLResponse(url: response.responseURL ?? request.url!, statusCode: response.status,
                                   httpVersion: "HTTP/1.1", headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data ?? (try! JSONSerialization.data(withJSONObject: response.json)))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class CloudAgentTransportTests: XCTestCase {
    private let fakeToken = "xoxp-fixture-only-not-a-real-token"
    private var directory: URL!
    private var clock: CloudAgentFixtureClock!
    private var store: CloudAgentStateStore!
    private var config: CloudAgentSlackConfiguration!
    private var transport: CloudAgentSlackTransport!

    override func setUpWithError() throws {
        CloudAgentFixtureProtocol.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PeelCloudAgentTests-\(UUID())", isDirectory: true)
        clock = CloudAgentFixtureClock()
        store = try CloudAgentStateStore(fileURL: directory.appendingPathComponent("state.json"))
        config = try CloudAgentSlackConfiguration(provider: .dot, teamID: "TTEAM123", channelID: "CROOM123", targetBotUserID: "UAGENT123")
        transport = makeTransport()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func makeTransport(configuration: CloudAgentSlackConfiguration? = nil, token: String? = "xoxp-fixture-only-not-a-real-token",
                               store: CloudAgentStateStore? = nil) -> CloudAgentSlackTransport {
        let clock = self.clock!
        return CloudAgentSlackTransport(configuration: configuration ?? config,
                                       tokenProvider: { token }, stateStore: store ?? self.store,
                                       networkConfiguration: {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [CloudAgentFixtureProtocol.self]
            return config
        }, now: { clock.now() })
    }
    private func rootConversation(_ configuration: CloudAgentSlackConfiguration? = nil) throws -> CloudAgentConversation {
        try CloudAgentConversation(configuration: configuration ?? config, threadTimestamp: "1800000000.000001")
    }
    private func body(_ request: URLRequest) throws -> [String: Any] {
        if request.httpMethod == "GET" {
            return Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map {
                let value: Any = $0.name == "limit" ? (Int($0.value ?? "") ?? -1) as Any : ($0.value ?? "") as Any
                return ($0.name, value)
            })
        }
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var output = Data(); var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; output.append(bytes, count: n) }
            data = output
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
    }
    private func message(_ ts: String, text: String, user: String = "UAGENT123", thread: String = "1800000000.000001") -> [String: Any] {
        ["type": "message", "user": user, "text": text, "ts": ts, "thread_ts": thread]
    }
    private func checkEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
    private func checkNil<T>(_ actual: T?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(actual, file: file, line: line)
    }
    private func assertError<T>(_ expected: CloudAgentError, operation: () async throws -> T,
                                file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch let error as CloudAgentError { checkEqual(error, expected, file: file, line: line) }
        catch { XCTFail("Unexpected error type", file: file, line: line) }
    }

    func testConfigurationAndAvailabilityNeverImplyConnectionOrSendNetwork() async throws {
        checkEqual(await transport.availability(), .needsVerification)
        XCTAssertTrue(CloudAgentFixtureProtocol.requests().isEmpty)
        let missing = CloudAgentSlackTransport(configuration: nil, tokenProvider: { nil }, stateStore: store)
        checkEqual(await missing.availability(), .needsConfiguration)
        checkEqual(await makeTransport(token: nil).availability(), .needsConfiguration)
        checkEqual(await makeTransport(token: "xoxb-fixture-not-supported").availability(), .needsConfiguration)
        checkEqual(await makeTransport(token: "xoxp-fixture\r\nAuthorization: evil").availability(), .needsConfiguration)
        XCTAssertTrue(CloudAgentFixtureProtocol.requests().isEmpty)
    }

    func testConfigurationDecodeRejectsURLsIdentifiersAndInvalidTimestamps() throws {
        for channel in ["https://example.com", "CROOM/../../", "UAGENT123", "CROOM\n123"] {
            XCTAssertThrowsError(try CloudAgentSlackConfiguration(provider: .dot, teamID: "TTEAM123", channelID: channel, targetBotUserID: "UAGENT123"))
        }
        XCTAssertThrowsError(try CloudAgentSlackConfiguration(provider: .dot, teamID: "TTEAM123", channelID: "CROOM123", targetBotUserID: "UAGENT123", threadTimestamp: "1.2"))
        let valid = try JSONEncoder().encode(config)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any]); object["teamID"] = "https://evil.test"
        XCTAssertThrowsError(try JSONDecoder().decode(CloudAgentSlackConfiguration.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func testVerificationChecksUserTokenWorkspaceBotAndChannelBeforeReady() async throws {
        checkEqual(try await transport.verifyConfiguration(), .ready)
        checkEqual(await transport.availability(), .ready)
        checkEqual(CloudAgentFixtureProtocol.requests().map { $0.url!.lastPathComponent }, ["auth.test", "users.info", "conversations.info", "conversations.members"])
        for request in CloudAgentFixtureProtocol.requests() {
            checkEqual(request.url?.scheme, "https"); checkEqual(request.url?.host, "slack.com")
            checkEqual(request.httpMethod, request.url!.lastPathComponent == "auth.test" ? "POST" : "GET")
            checkEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(fakeToken)")
            XCTAssertFalse(String(data: try JSONSerialization.data(withJSONObject: body(request)), encoding: .utf8)!.contains(fakeToken))
        }
    }

    func testWrongWorkspaceAndNonBotNeverBecomeReady() async throws {
        CloudAgentFixtureProtocol.enqueue("auth.test", .init(json: ["ok": true, "team_id": "TOTHER123", "user_id": "UHUMAN123"]))
        await assertError(.wrongWorkspace) { try await self.transport.verifyConfiguration() }
        checkEqual(CloudAgentFixtureProtocol.requests().count, 1)
        clock.advance(1)
        CloudAgentFixtureProtocol.enqueue("users.info", .init(json: ["ok": true, "user": ["id": "UAGENT123", "team_id": "TTEAM123", "is_bot": false]]))
        await assertError(.wrongBot) { try await self.transport.verifyConfiguration() }
        checkEqual(await transport.availability(), .needsVerification)
    }

    func testBotTokenIdentityAndWrongDMParticipantAreRejected() async throws {
        CloudAgentFixtureProtocol.enqueue("auth.test", .init(json: ["ok": true, "team_id": "TTEAM123", "user_id": "UHUMAN123", "bot_id": "BBOT123"]))
        await assertError(.invalidConfiguration) { try await self.transport.verifyConfiguration() }
        clock.advance(1)
        let dm = try CloudAgentSlackConfiguration(provider: .grokBot, teamID: "TTEAM123", channelID: "DROOM123", targetBotUserID: "UAGENT123")
        CloudAgentFixtureProtocol.enqueue("conversations.info", .init(json: ["ok": true, "channel": ["id": "DROOM123", "is_im": true, "user": "UOTHER123"]]))
        await assertError(.wrongConversation) { try await self.makeTransport(configuration: dm).verifyConfiguration() }
    }

    func testSendMentionsOnlyConfiguredBotAndPersistsReceiptWithoutToken() async throws {
        let id = UUID()
        let receipt = try await transport.send(text: "Please inspect <@UOTHER123> & <!channel>", requestID: id)
        checkEqual(receipt.requestID, id); checkEqual(receipt.conversation, try rootConversation())
        let requests = CloudAgentFixtureProtocol.requests("chat.postMessage")
        checkEqual(requests.count, 1)
        let payload = try body(XCTUnwrap(requests.first))
        checkEqual(payload["channel"] as? String, "CROOM123")
        checkEqual(payload["text"] as? String, "<@UAGENT123> Please inspect &lt;@UOTHER123&gt; &amp; &lt;!channel&gt;")
        checkEqual(payload["unfurl_links"] as? Bool, false)
        checkNil(payload["thread_ts"])
        checkEqual(try await transport.send(text: "Please inspect <@UOTHER123> & <!channel>", requestID: id), receipt)
        checkEqual(CloudAgentFixtureProtocol.requests("chat.postMessage").count, 1)
        await assertError(.reusedRequestID) { try await self.transport.send(text: "different", requestID: id) }
        let text = try String(contentsOf: directory.appendingPathComponent("state.json"), encoding: .utf8)
        XCTAssertFalse(text.contains(fakeToken)); XCTAssertFalse(text.contains("Please inspect"))
        let attrs = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("state.json").path)
        checkEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        clock.advance(1)
        let reloaded = try CloudAgentStateStore(fileURL: directory.appendingPathComponent("state.json"))
        let next = makeTransport(store: reloaded)
        checkEqual(try await next.send(text: "Please inspect <@UOTHER123> & <!channel>", requestID: id), receipt)
        checkEqual(CloudAgentFixtureProtocol.requests("chat.postMessage").count, 1)
    }

    func testExistingThreadAndForeignConversationIsolation() async throws {
        let threadConfig = try CloudAgentSlackConfiguration(provider: .dot, teamID: "TTEAM123", channelID: "CROOM123", targetBotUserID: "UAGENT123", threadTimestamp: "1799999999.000001")
        let threadTransport = makeTransport(configuration: threadConfig)
        let result = try await threadTransport.send(text: "Continue our task", requestID: UUID())
        checkEqual(result.conversation.threadTimestamp, "1799999999.000001")
        checkEqual(try body(XCTUnwrap(CloudAgentFixtureProtocol.requests("chat.postMessage").last))["thread_ts"] as? String, "1799999999.000001")
        let foreign = try CloudAgentSlackConfiguration(provider: .grokBot, teamID: "TTEAM123", channelID: "CROOM123", targetBotUserID: "UAGENT123")
        let foreignConversation = try rootConversation(foreign)
        let count = CloudAgentFixtureProtocol.requests().count
        await assertError(.wrongConversation) { try await self.transport.send(text: "wrong route", requestID: UUID(), conversation: foreignConversation) }
        await assertError(.wrongConversation) { try await self.transport.replies(in: foreignConversation) }
        checkEqual(CloudAgentFixtureProtocol.requests().count, count)
    }

    func testAmbiguousNetworkSendIsDurableAndNeverAutomaticallyReplayed() async throws {
        CloudAgentFixtureProtocol.enqueue("chat.postMessage", .init(failure: true))
        let id = UUID()
        await assertError(.deliveryUnknown) { try await self.transport.send(text: "One message", requestID: id) }
        clock.advance(1)
        let loaded = try CloudAgentStateStore(fileURL: directory.appendingPathComponent("state.json"))
        let next = makeTransport(store: loaded)
        await assertError(.deliveryUnknown) { try await next.send(text: "One message", requestID: id) }
        checkEqual(CloudAgentFixtureProtocol.requests("chat.postMessage").count, 1)
    }

    func testDefinitiveRejectedSendCanRetryButInternalErrorCannot() async throws {
        CloudAgentFixtureProtocol.enqueue("chat.postMessage", .init(json: ["ok": false, "error": "missing_scope"]), .init(json: ["ok": false, "error": "internal_error"]))
        let id = UUID()
        await assertError(.serviceRejected("missing_scope")) { try await self.transport.send(text: "One message", requestID: id) }
        clock.advance(1)
        await assertError(.deliveryUnknown) { try await self.transport.send(text: "One message", requestID: id) }
        clock.advance(1)
        await assertError(.deliveryUnknown) { try await self.transport.send(text: "One message", requestID: id) }
        checkEqual(CloudAgentFixtureProtocol.requests("chat.postMessage").count, 2)
    }

    func testRetryAfterAndPollMinimumSurviveStoreReload() async throws {
        CloudAgentFixtureProtocol.enqueue("chat.postMessage", .init(status: 429, headers: ["Retry-After": "120"]))
        let id = UUID(); let deadline = clock.now().addingTimeInterval(120)
        await assertError(.rateLimited(retryAt: deadline)) { try await self.transport.send(text: "Rate bound", requestID: id) }
        clock.advance(60)
        let loaded = try CloudAgentStateStore(fileURL: directory.appendingPathComponent("state.json"))
        let next = makeTransport(store: loaded)
        await assertError(.rateLimited(retryAt: deadline)) { try await next.send(text: "Rate bound", requestID: id) }
        checkEqual(CloudAgentFixtureProtocol.requests("chat.postMessage").count, 1)
        clock.advance(60)
        _ = try await next.send(text: "Rate bound", requestID: id)
        checkEqual(CloudAgentFixtureProtocol.requests("chat.postMessage").count, 2)
        let conversation = try rootConversation()
        _ = try await next.replies(in: conversation)
        let pollDeadline = clock.now().addingTimeInterval(60)
        await assertError(.rateLimited(retryAt: pollDeadline)) { try await next.replies(in: conversation) }
        checkEqual(try body(XCTUnwrap(CloudAgentFixtureProtocol.requests("conversations.replies").first))["limit"] as? Int, 15)
    }

    func testReplyPagesFilterExactBotThreadDeduplicateAndPersistOnlyAfterAcknowledgment() async throws {
        let conversation = try rootConversation()
        CloudAgentFixtureProtocol.enqueue("conversations.replies", .init(json: ["ok": true, "messages": [
            message("1800000000.000001", text: "root", user: "UHUMAN123"),
            message("1800000000.000002", text: "not our bot", user: "UOTHER123"),
            message("1800000000.000003", text: "first"),
            message("1800000999.000001", text: "wrong thread", thread: "1800000999.000001")
        ], "has_more": true, "response_metadata": ["next_cursor": "PAGE2"]]))
        let first = try await transport.replies(in: conversation)
        checkEqual(first.messages.map(\.text), ["first"])
        checkEqual(first.cursor.oldestTimestamp, conversation.threadTimestamp)
        checkEqual(first.cursor.pageCursor, "PAGE2")
        checkNil(await store.cursor(for: conversation))
        try await transport.acknowledge(first)
        clock.advance(60)
        CloudAgentFixtureProtocol.enqueue("conversations.replies", .init(json: ["ok": true, "messages": [
            message("1800000000.000003", text: "first"), message("1800000000.000004", text: "second")
        ], "has_more": false]))
        let second = try await transport.replies(in: conversation)
        checkEqual(second.messages.map(\.text), ["second"])
        checkNil(second.cursor.pageCursor)
        checkEqual(second.cursor.batchMaximumTimestamp, "1800000000.000004")
        checkEqual(try body(XCTUnwrap(CloudAgentFixtureProtocol.requests("conversations.replies").last))["cursor"] as? String, "PAGE2")
        try await transport.acknowledge(second)
        let loaded = try CloudAgentStateStore(fileURL: directory.appendingPathComponent("state.json"))
        checkEqual(await loaded.cursor(for: conversation), second.cursor)
        clock.advance(60)
        CloudAgentFixtureProtocol.enqueue("conversations.replies", .init(json: ["ok": true, "messages": [
            message("1800000000.000003", text: "first — edited final response"), message("1800000000.000004", text: "second")
        ], "has_more": false]))
        let updated = try await transport.replies(in: conversation)
        checkEqual(updated.messages.map(\.text), ["first — edited final response"])
        checkEqual(updated.messages.first?.id, first.messages.first?.id)
    }

    func testMissingPaginationCursorCannotAdvanceOrAcknowledge() async throws {
        let conversation = try rootConversation()
        CloudAgentFixtureProtocol.enqueue("conversations.replies", .init(json: ["ok": true, "messages": [message("1800000000.000002", text: "one")], "has_more": true]))
        await assertError(.invalidResponse) { try await self.transport.replies(in: conversation) }
        checkNil(await store.cursor(for: conversation))
    }

    func testTokenRevocationRemovesVerifiedAvailability() async throws {
        _ = try await transport.verifyConfiguration()
        CloudAgentFixtureProtocol.enqueue("conversations.replies", .init(json: ["ok": false, "error": "token_revoked"]))
        await assertError(.serviceRejected("token_revoked")) { try await self.transport.replies(in: self.rootConversation()) }
        checkEqual(await transport.availability(), .needsVerification)
    }

    func testResponseURLAndStreamingByteCapAreEnforced() async throws {
        _ = try await transport.verifyConfiguration()
        let conversation = try rootConversation()
        CloudAgentFixtureProtocol.enqueue("conversations.replies", .init(responseURL: URL(string: "https://evil.example/api/conversations.replies")))
        await assertError(.invalidResponse) { try await self.transport.replies(in: conversation) }
        clock.advance(60)
        CloudAgentFixtureProtocol.enqueue("conversations.replies", .init(data: Data(repeating: 65, count: CloudAgentHTTPOperation.maximumBytes + 1)))
        await assertError(.responseTooLarge) { try await self.transport.replies(in: conversation) }
        XCTAssertTrue(CloudAgentFixtureProtocol.requests().allSatisfy { $0.url?.host == "slack.com" })
    }

    func testLocalCancellationStopsPollWithoutClaimingRemoteStop() async throws {
        _ = try await transport.verifyConfiguration()
        CloudAgentFixtureProtocol.enqueue("conversations.replies", .init(hold: true))
        let expectation = expectation(description: "poll network started")
        CloudAgentFixtureProtocol.onStart { expectation.fulfill() }
        let id = UUID(); let conversation = try rootConversation()
        let task = Task { try await transport.replies(in: conversation, requestID: id) }
        await fulfillment(of: [expectation], timeout: 2)
        await transport.cancel(requestID: id)
        await assertError(.cancelled) { try await task.value }
        checkNil(await store.cursor(for: conversation))
        XCTAssertTrue(CloudAgentError.cancelled.localizedDescription.contains("does not stop"))
    }

    func testCancelledSendRemainsUncertainAcrossNewTransport() async throws {
        _ = try await transport.verifyConfiguration()
        CloudAgentFixtureProtocol.enqueue("chat.postMessage", .init(hold: true))
        let expectation = expectation(description: "send network started")
        CloudAgentFixtureProtocol.onStart { expectation.fulfill() }
        let id = UUID()
        let task = Task { try await transport.send(text: "Cancel safely", requestID: id) }
        await fulfillment(of: [expectation], timeout: 2)
        await transport.cancel(requestID: id)
        await assertError(.deliveryUnknown) { try await task.value }
        CloudAgentFixtureProtocol.onStart {}
        clock.advance(1)
        let next = makeTransport()
        await assertError(.deliveryUnknown) { try await next.send(text: "Cancel safely", requestID: id) }
        checkEqual(CloudAgentFixtureProtocol.requests("chat.postMessage").count, 1)
    }

    func testCorruptAndOversizedCheckpointFailWithoutOverwritingEvidence() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("bad.json")
        let corrupt = Data("not json".utf8); try corrupt.write(to: file)
        XCTAssertThrowsError(try CloudAgentStateStore(fileURL: file)); checkEqual(try Data(contentsOf: file), corrupt)
        try Data(repeating: 65, count: 512 * 1_024 + 1).write(to: file)
        XCTAssertThrowsError(try CloudAgentStateStore(fileURL: file))
    }

    func testBotMustBelongToDedicatedChannelBeforeAnySend() async throws {
        CloudAgentFixtureProtocol.enqueue("conversations.members", .init(json: ["ok": true, "members": ["UHUMAN123", "UOTHER123"], "response_metadata": ["next_cursor": "MORE"]]))
        await assertError(.wrongConversation) { try await self.transport.send(text: "Do not send without the target", requestID: UUID()) }
        XCTAssertTrue(CloudAgentFixtureProtocol.requests("chat.postMessage").isEmpty)
        checkEqual(await transport.availability(), .needsVerification)
    }

    func testRedirectDelegateRefusesForwardingAuthorization() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CloudAgentFixtureProtocol.self]
        let operation = CloudAgentHTTPOperation(configuration: config)
        let original = URLRequest(url: URL(string: "https://slack.com/api/auth.test")!)
        let task = URLSession.shared.dataTask(with: original) // Intentionally never resumed.
        let redirect = HTTPURLResponse(url: original.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": "https://evil.example/"])!
        var accepted: URLRequest?
        operation.urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: redirect,
                             newRequest: URLRequest(url: URL(string: "https://evil.example/")!)) { accepted = $0 }
        checkNil(accepted)
        await assertError(.invalidResponse) { try await operation.run(original) }
        XCTAssertTrue(CloudAgentFixtureProtocol.requests().isEmpty)
        task.cancel()
    }

    func testChangingTokenAfterVerificationCannotCrossAccountBoundary() async throws {
        final class Counter: @unchecked Sendable {
            let lock = NSLock(); var count = 0
            func token() -> String { lock.lock(); defer { lock.unlock() }; count += 1
                return count <= 2 ? "xoxp-fixture-account-one" : "xoxp-fixture-account-two" }
        }
        let counter = Counter(); let clock = self.clock!
        let transport = CloudAgentSlackTransport(configuration: config, tokenProvider: { counter.token() }, stateStore: store,
                                                networkConfiguration: { let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [CloudAgentFixtureProtocol.self]; return c },
                                                now: { clock.now() })
        await assertError(.deliveryUnknown) { try await transport.send(text: "No crossed account", requestID: UUID()) }
        XCTAssertTrue(CloudAgentFixtureProtocol.requests("chat.postMessage").isEmpty)
        checkEqual(await transport.availability(), .needsVerification)
    }

    func testUnusualRetryAfterCannotOverflowOrShortenServerDeadline() async throws {
        _ = try await transport.verifyConfiguration()
        CloudAgentFixtureProtocol.enqueue("conversations.replies", .init(status: 429, headers: ["Retry-After": "NaN"]))
        let expected = clock.now().addingTimeInterval(60)
        await assertError(.rateLimited(retryAt: expected)) { try await self.transport.replies(in: self.rootConversation()) }
        clock.advance(60)
        CloudAgentFixtureProtocol.enqueue("conversations.replies", .init(status: 429, headers: ["Retry-After": "172800"]))
        let longExpected = clock.now().addingTimeInterval(172800)
        await assertError(.rateLimited(retryAt: longExpected)) { try await self.transport.replies(in: self.rootConversation()) }
    }
}
