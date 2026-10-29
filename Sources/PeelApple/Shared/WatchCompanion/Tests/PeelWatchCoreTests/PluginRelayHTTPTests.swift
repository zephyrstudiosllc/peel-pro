#if !os(watchOS)
import XCTest
@testable import PeelWatchCore

private final class HTTPTestAuthorizer: PluginRelayHTTPAuthorizer, @unchecked Sendable {
    private let lock = NSLock()
    var context: PluginRelayHTTPContext
    private var revoked = false
    private var expiry = Date().addingTimeInterval(600)
    private var headers = ["Authorization": "Bearer synthetic-fixture"]
    private let lease = UUID()
    private var scopes: [PluginRelayHTTPScope] = []
    private let fixtureFence: PluginRelayFence
    init(_ fence: PluginRelayFence) { self.context = .init(fence: fence); self.fixtureFence = fence }
    func revoke() { lock.lock(); defer { lock.unlock() }; revoked = true }
    func changeContext(_ value: PluginRelayHTTPContext) { lock.lock(); defer { lock.unlock() }; context = value }
    func expire(at date: Date) { lock.lock(); defer { lock.unlock() }; expiry = date }
    func setHeaders(_ value: [String: String]) { lock.lock(); defer { lock.unlock() }; headers = value }
    func requestedScopes() -> [PluginRelayHTTPScope] { lock.lock(); defer { lock.unlock() }; return scopes }
    func authorization(for expected: PluginRelayHTTPContext, scope: PluginRelayHTTPScope, trustedOrigin: URL) throws -> PluginRelayHTTPAuthorization {
        lock.lock(); defer { lock.unlock() }; scopes.append(scope)
        guard !revoked else { throw PluginRelayHTTPError.authorityChanged }
        return .init(context: context, leaseID: lease, expiresAt: expiry, headers: headers, proPermit: try syntheticPaidPermit(for: fixtureFence, routed: scope != .connect))
    }
    func validateCurrent(_ authorization: PluginRelayHTTPAuthorization, scope: PluginRelayHTTPScope) throws {
        lock.lock(); defer { lock.unlock() }
        guard !revoked, authorization.context == context, authorization.leaseID == lease, expiry > Date() else {
            throw PluginRelayHTTPError.authorityChanged
        }
    }
}

private final class RelayHTTPFixture: URLProtocol, @unchecked Sendable {
    struct Plan {
        var status = 200
        var body = Data()
        var headers: [String: String] = [:]
        var chunks: [Data]?
        var hang = false
        var redirect: URL?
        var responseURL: URL?
        var onStart: (() -> Void)?
    }
    private static let lock = NSLock()
    private static var plans: [Plan] = []
    private static var requests: [URLRequest] = []
    static func reset(_ values: [Plan]) { lock.lock(); defer { lock.unlock() }; plans = values; requests = [] }
    static func captured() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // URLSession may expose a POST body as an InputStream to URLProtocol.
        // Consume it as the fixture server would, with the same bounded budget.
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open(); defer { stream.close() }
            var body = Data(), buffer = [UInt8](repeating: 0, count: 8_192)
            while true {
                let count = buffer.withUnsafeMutableBufferPointer { stream.read($0.baseAddress!, maxLength: $0.count) }
                guard count >= 0, count <= 256 * 1_024 - body.count else {
                    client?.urlProtocol(self, didFailWithError: URLError(.cannotDecodeRawData)); return
                }
                if count == 0 { break }; body.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = body
        }
        Self.lock.lock(); Self.requests.append(captured)
        let plan = Self.plans.isEmpty ? nil : Self.plans.removeFirst(); Self.lock.unlock()
        guard let plan else { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        plan.onStart?()
        if plan.hang { return }
        var headers = ["Content-Type": "application/json", "Cache-Control": "no-store"]
        for (name, value) in plan.headers { headers[name] = value }
        if let target = plan.redirect {
            headers["Location"] = target.absoluteString
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response); return
        }
        let response = HTTPURLResponse(url: plan.responseURL ?? request.url!, statusCode: plan.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in plan.chunks ?? [plan.body] { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class PluginRelayHTTPTests: XCTestCase {
    private let origin = URL(string: "https://relay.example.test")!
    private func fence(provider: CloudAgentProvider = .dot) throws -> PluginRelayFence {
        .init(binding: .init(route: try .init(provider: provider, routeID: "route_http", generation: UUID(), accountGeneration: UUID()),
                            pairingEpoch: UUID()), localEpoch: UUID())
    }
    private func client(_ fence: PluginRelayFence, timeout: TimeInterval = 1) throws -> (PluginRelayHTTPClient, HTTPTestAuthorizer) {
        let auth = HTTPTestAuthorizer(fence), config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RelayHTTPFixture.self]
        return (try .init(trustedOrigin: origin, allowedAuthorizationHeaderNames: ["Authorization"], authorizer: auth,
                          timeout: timeout, configuration: config), auth)
    }
    private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) }
    private func route(_ fence: PluginRelayFence) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(fence.binding.route)) as? [String: Any])
    }
    private func status(_ fence: PluginRelayFence, ready: Bool = false) throws -> [String: Any] {
        let dot = fence.binding.route.provider == .dot
        return ["route": try route(fence), "ready": ready, "state": ready ? (dot ? "connected" : "manualReady") : "authorizePlugin",
                "deliveryMode": dot ? "events" : "manual", "automaticDeliveryReady": ready && dot,
                "minimumRoutineIntervalSeconds": dot ? NSNull() : 300]
    }
    private func expect(_ expected: PluginRelayHTTPError, file: StaticString = #filePath, line: UInt = #line,
                        _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? PluginRelayHTTPError, expected, file: file, line: line) }
    }
    private func waitForRequest() async throws {
        for _ in 0..<100 {
            if !RelayHTTPFixture.captured().isEmpty { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Fixture did not receive request")
    }

    func testOnlyTrustedOriginAndApprovedAttachmentHeadersAreAllowed() async throws {
        let f = try fence(), (http, auth) = try client(f)
        for raw in ["http://relay.example.test", "https://user@relay.example.test", "https://relay.example.test/path", "https://relay.example.test?x=1", "https://relay.example.test:444"] {
            XCTAssertThrowsError(try PluginRelayHTTPClient(trustedOrigin: URL(string: raw)!, allowedAuthorizationHeaderNames: ["Authorization"], authorizer: auth))
        }
        XCTAssertThrowsError(try PluginRelayHTTPClient(trustedOrigin: origin, allowedAuthorizationHeaderNames: ["Cookie"], authorizer: auth))
        RelayHTTPFixture.reset([.init(body: try json(status(f)))])
        let result = try await http.status(using: f)
        XCTAssertFalse(result.remoteReady)
        let request = try XCTUnwrap(RelayHTTPFixture.captured().first)
        XCTAssertEqual(request.url?.absoluteString, "https://relay.example.test/v1/watch/status")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-fixture")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(auth.requestedScopes(), [.read])
        auth.setHeaders(["Authorization": "Bearer synthetic\r\nCookie: value"])
        RelayHTTPFixture.reset([])
        await expect(.invalidConfiguration) { _ = try await http.status(using: f) }
        XCTAssertTrue(RelayHTTPFixture.captured().isEmpty)
    }

    func testConnectPendingAndGrokManualStatusAreNotAutomaticReadiness() async throws {
        let f = try fence(), (http, _) = try client(f)
        let challenge = "synthetic-confirmation-challenge"
        RelayHTTPFixture.reset([.init(body: try json(["route": route(f), "confirmationChallenge": challenge,
            "state": "authorizePlugin", "minimumRoutineIntervalSeconds": NSNull()]))])
        let connected = try await http.connect(agentReference: "Selected real Dot", context: .init(fence: f))
        XCTAssertEqual(connected.confirmationChallenge, challenge)
        XCTAssertFalse(String(describing: connected).contains(challenge))
        let g = try fence(provider: .grokBot), (grok, _) = try client(g)
        RelayHTTPFixture.reset([.init(body: try json(status(g, ready: true)))])
        let manual = try await grok.status(using: g)
        XCTAssertEqual(manual.state, .manualReady); XCTAssertFalse(manual.automaticDeliveryReady)
        XCTAssertEqual(manual.minimumRoutineIntervalSeconds, 300)
        var inconsistent = try status(g, ready: true); inconsistent["automaticDeliveryReady"] = true
        RelayHTTPFixture.reset([.init(body: try json(inconsistent))])
        await expect(.invalidResponse) { _ = try await grok.status(using: g) }
    }

    func testStableSendIDAndExactRequestBodyAreNotChangedOrRetried() async throws {
        let f = try fence(), (http, auth) = try client(f)
        let message = try PluginRelayMessage(messageID: UUID(), text: "Type 😀\n\ttext")
        let receipt: [String: Any] = ["requestID": message.messageID.uuidString.lowercased(), "route": try route(f),
            "receiptID": "request_9", "state": "accepted", "agentReplyReceived": false]
        RelayHTTPFixture.reset([.init(body: try json(receipt)), .init(body: try json(receipt))])
        let first = try await http.send(message, using: f), second = try await http.send(message, using: f)
        XCTAssertEqual(first, second); XCTAssertFalse(first.agentReplyReceived)
        let requests = RelayHTTPFixture.captured(); XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].httpBody, requests[1].httpBody)
        XCTAssertEqual(auth.requestedScopes(), [.send, .send])
        if let body = requests[0].httpBody {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(Set(object.keys), ["route_id", "generation", "request_id", "text"])
            XCTAssertEqual(object["request_id"] as? String, message.messageID.uuidString.lowercased())
            XCTAssertEqual(object["text"] as? String, message.text)
        } else { XCTFail("Expected exact request body") }
        XCTAssertThrowsError(try PluginRelayMessage(messageID: UUID(), text: String(repeating: "e\u{301}", count: 2_001)))
    }

    func testReplyPageAndDisconnectExactSchemas() async throws {
        let f = try fence(), (http, auth) = try client(f), id = UUID()
        let reply: [String: Any] = ["requestID": id.uuidString, "replyID": "reply", "text": String(repeating: "/", count: 32_000)]
        RelayHTTPFixture.reset([.init(body: try json(["route": route(f), "replies": [reply], "cursor": 91])),
                                .init(body: try json(["disconnected": true]))])
        let page = try await http.replies(after: 2, using: f)
        XCTAssertEqual(page.cursor, 91); XCTAssertEqual(page.replies[0].requestID, id)
        try await http.disconnect(using: f)
        XCTAssertEqual(auth.requestedScopes(), [.read, .connect])
    }

    func testDuplicateDecodedKeysMalformedNumbersAndUnicodeAreRejected() throws {
        for text in ["{\"a\":1,\"a\":2}", "{\"a\":1,\"\\u0061\":2}", "{\"route\":{\"a\":1,\"a\":2}}",
            "{\"a\":1.0}", "{\"a\":1e2}", "{\"a\":01}", "{\"a\":NaN}", "{\"a\":\"\\uD800\"}",
            String(repeating: "[", count: 18) + "0" + String(repeating: "]", count: 18)] {
            XCTAssertThrowsError(try PluginRelayJSON.parse(Data(text.utf8)), text)
        }
        XCTAssertThrowsError(try PluginRelayJSON.parse(Data([123, 34, 120, 34, 58, 34, 255, 34, 125])))
    }

    func testUnknownTopNestedFieldsAndBoolCursorFailBeforeTrust() async throws {
        let f = try fence(), (http, _) = try client(f)
        var top = try status(f); top["secret"] = "unexpected"
        var nested = try status(f), r = try route(f); r["extra"] = true; nested["route"] = r
        for object in [top, nested] {
            RelayHTTPFixture.reset([.init(body: try json(object))])
            await expect(.invalidResponse) { _ = try await http.status(using: f) }
        }
        RelayHTTPFixture.reset([.init(body: try json(["route": route(f), "replies": [], "cursor": true]))])
        await expect(.invalidResponse) { _ = try await http.replies(after: 0, using: f) }
    }

    func testResponseRouteAccountProviderAndCurrentPairMustMatch() async throws {
        let f = try fence(), (http, auth) = try client(f)
        var object = try status(f), r = try route(f); r["accountGeneration"] = UUID().uuidString; object["route"] = r
        RelayHTTPFixture.reset([.init(body: try json(object))])
        await expect(.authorityChanged) { _ = try await http.status(using: f) }
        let wrong = PluginRelayHTTPContext(provider: .dot, accountGeneration: f.binding.route.accountGeneration, pairingEpoch: UUID(), localEpoch: f.localEpoch)
        auth.changeContext(wrong); RelayHTTPFixture.reset([])
        await expect(.authorityChanged) { _ = try await http.status(using: f) }
        XCTAssertTrue(RelayHTTPFixture.captured().isEmpty)
    }

    func testRevocationAndExpiryCancelWaitingIOWithoutTrustingLateData() async throws {
        let f = try fence(), (http, auth) = try client(f)
        RelayHTTPFixture.reset([.init(hang: true, onStart: { auth.revoke() })])
        await expect(.authorityChanged) { _ = try await http.status(using: f) }
        let (expired, grant) = try client(f)
        grant.expire(at: Date().addingTimeInterval(0.08))
        RelayHTTPFixture.reset([.init(hang: true)])
        await expect(.authorityChanged) { _ = try await expired.status(using: f) }
    }

    func testRedirectDoesNotDispatchToTargetOrForwardCredentials() async throws {
        let f = try fence(), (http, _) = try client(f)
        RelayHTTPFixture.reset([.init(redirect: URL(string: "https://other.example.test/steal")!)])
        await expect(.redirectRejected) { _ = try await http.status(using: f) }
        let requests = RelayHTTPFixture.captured(); XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.host, "relay.example.test")
    }

    func testDeclaredAndIncrementalOversizeAreBounded() async throws {
        let f = try fence(), (http, _) = try client(f)
        RelayHTTPFixture.reset([.init(body: Data("{}".utf8), headers: ["Content-Length": "262145"])])
        await expect(.responseTooLarge) { _ = try await http.status(using: f) }
        RelayHTTPFixture.reset([.init(headers: ["Content-Length": "1"], chunks: [Data(repeating: 32, count: 200_000), Data(repeating: 32, count: 62_145)])])
        await expect(.responseTooLarge) { _ = try await http.status(using: f) }
    }

    func testAbsoluteDeadlineTaskCancelAndBusyAreLocalOnly() async throws {
        let f = try fence(), (short, _) = try client(f, timeout: 0.1)
        RelayHTTPFixture.reset([.init(hang: true)])
        let start = DispatchTime.now().uptimeNanoseconds
        await expect(.timeout) { _ = try await short.status(using: f) }
        XCTAssertLessThan(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9, 1)
        let (http, _) = try client(f)
        RelayHTTPFixture.reset([.init(hang: true)])
        let task = Task { try await http.status(using: f) }
        try await waitForRequest()
        await expect(.busy) { _ = try await http.status(using: f) }
        task.cancel()
        await expect(.cancelled) { _ = try await task.value }
        XCTAssertEqual(RelayHTTPFixture.captured().count, 1)
    }

    func testErrorCodesAreBoundedAndUnexpectedURLOrTypeRejected() async throws {
        let f = try fence(), (http, _) = try client(f)
        RelayHTTPFixture.reset([.init(status: 401, body: try json(["error": "authentication_required"]))])
        await expect(.serviceRejected("authentication_required")) { _ = try await http.status(using: f) }
        RelayHTTPFixture.reset([.init(status: 500, body: try json(["error": "do_not_expose_remote_secret"]))])
        await expect(.serviceRejected("service_rejected")) { _ = try await http.status(using: f) }
        RelayHTTPFixture.reset([.init(body: try json(status(f)), responseURL: URL(string: "https://other.example.test/v1/watch/status"))])
        await expect(.invalidResponse) { _ = try await http.status(using: f) }
        RelayHTTPFixture.reset([.init(body: try json(status(f)), headers: ["Content-Type": "text/html"])])
        await expect(.invalidResponse) { _ = try await http.status(using: f) }
    }
}
#endif
