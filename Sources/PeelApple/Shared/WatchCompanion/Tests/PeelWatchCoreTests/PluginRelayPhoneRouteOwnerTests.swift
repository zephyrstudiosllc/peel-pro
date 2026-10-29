#if !os(watchOS)
import XCTest
@testable import PeelWatchCore

private struct RouteOwnerCallback: PluginRelayNativePeerCallback { let id: UUID }
private struct RouteOwnerPeer: PluginRelayPhonePeerEvidence { let id: UUID }
private final class RouteOwnerDisk: PluginRelayPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data?
    var failsRead = false
    func read(maximumBytes: Int) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if failsRead { throw PluginRelayError.storageFailure }; return bytes
    }
    func writeAtomically(_ data: Data) throws { lock.lock(); defer { lock.unlock() }; bytes = data }
}
/// Explicit fixture verifier; this grants no production account/device access.
private final class RouteOwnerSession: PluginRelayPhoneVerifiedSession, @unchecked Sendable {
    let context: PluginRelayHTTPContext
    let trustedOrigin = URL(string: "https://relay.invalid")!
    let actualAgentReference = "selected_actual_dot"
    let callbackID = UUID()
    private let lock = NSLock()
    private var enabled = true
    private var bound: PluginRelayFence?
    private var leases = Set<UUID>()
    init(provider: CloudAgentProvider = .dot) {
        context = .init(provider: provider, accountGeneration: UUID(), pairingEpoch: UUID(), localEpoch: UUID())
    }
    func validateSession() throws {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { throw PluginRelayPhoneRouteOwnerError.authorityChanged }
    }
    func bind(_ fence: PluginRelayFence) throws {
        lock.lock(); defer { lock.unlock() }
        guard enabled, fence.binding.route.provider == context.provider,
              fence.binding.route.accountGeneration == context.accountGeneration,
              fence.binding.pairingEpoch == context.pairingEpoch, fence.localEpoch == context.localEpoch else {
            throw PluginRelayPhoneRouteOwnerError.authorityChanged
        }
        bound = fence
    }
    func revokeLocal() { lock.lock(); defer { lock.unlock() }; enabled = false; leases.removeAll() }
    func peerEvidence(for callback: any PluginRelayNativePeerCallback) throws -> any PluginRelayPhonePeerEvidence {
        lock.lock(); defer { lock.unlock() }
        guard enabled, bound != nil, let callback = callback as? RouteOwnerCallback, callback.id == callbackID else {
            throw PluginRelayPhoneRouteOwnerError.authorityChanged
        }
        return RouteOwnerPeer(id: callback.id)
    }
    func authorize(_ action: PluginRelayPhoneAction, fence: PluginRelayFence,
                   peer: any PluginRelayPhonePeerEvidence) throws -> PluginRelayPhoneAuthorityLease {
        lock.lock(); defer { lock.unlock() }
        guard enabled, fence == bound, let peer = peer as? RouteOwnerPeer, peer.id == callbackID else {
            throw PluginRelayPhoneCoordinatorError.authorityDenied
        }
        let id = UUID(); leases.insert(id)
        return .init(id: id, fence: fence, action: action, expiresAt: Date().addingTimeInterval(60),
                     proPermit: action.requiresPro ? try syntheticPaidPermit(for: fence) : nil)
    }
    func validateCurrent(_ lease: PluginRelayPhoneAuthorityLease) throws {
        lock.lock(); defer { lock.unlock() }
        guard enabled, leases.contains(lease.id), lease.fence == bound else { throw PluginRelayPhoneCoordinatorError.authorityDenied }
    }
    func authorization(for context: PluginRelayHTTPContext, scope: PluginRelayHTTPScope,
                       trustedOrigin: URL) throws -> PluginRelayHTTPAuthorization {
        // This test transport never executes HTTP or receives a real credential.
        throw PluginRelayHTTPError.authorityChanged
    }
    func authorization(for context: PluginRelayHTTPContext, scope: PluginRelayHTTPScope,
                       trustedOrigin: URL, request: PluginRelayHTTPRequestProof) throws -> PluginRelayHTTPAuthorization {
        throw PluginRelayHTTPError.authorityChanged
    }
    func validateCurrent(_ authorization: PluginRelayHTTPAuthorization, scope: PluginRelayHTTPScope) throws {
        throw PluginRelayHTTPError.authorityChanged
    }
}
private actor RouteOwnerTransport: PluginRelayPhoneConnectingTransport {
    enum Gate: Hashable { case connect, status, send, cancel }
    let route: PluginRelayReference
    private var held = Set<Gate>(), entered = Set<Gate>()
    private var waiting: [Gate: CheckedContinuation<Void, Never>] = [:]
    private var arrivals: [Gate: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var connections = 0, statuses = 0, sends = 0, cancellations = 0
    var ready = false
    init(route: PluginRelayReference) { self.route = route }
    func hold(_ value: Gate) { held.insert(value); entered.remove(value) }
    func release(_ value: Gate) { held.remove(value); waiting.removeValue(forKey: value)?.resume() }
    func waitFor(_ value: Gate) async {
        if entered.contains(value) { return }
        await withCheckedContinuation { arrivals[value, default: []].append($0) }
    }
    private func gate(_ value: Gate) async {
        entered.insert(value)
        for continuation in arrivals.removeValue(forKey: value) ?? [] { continuation.resume() }
        if held.contains(value) { await withCheckedContinuation { waiting[value] = $0 } }
    }
    func connect(agentReference: String, context: PluginRelayHTTPContext) async throws -> PluginRelayConnectResponse {
        connections += 1; await gate(.connect)
        return .init(route: route, confirmationChallenge: "fixture_challenge_not_a_credential",
                     minimumRoutineIntervalSeconds: route.provider == .dot ? nil : 300)
    }
    func status(using fence: PluginRelayFence) async throws -> PluginRelayHTTPStatus {
        statuses += 1; await gate(.status)
        return .init(route: route, remoteReady: ready, state: ready ? (route.provider == .dot ? .connected : .manualReady) : .authorizePlugin,
            deliveryMode: route.provider == .dot ? .events : .manual, automaticDeliveryReady: ready && route.provider == .dot,
            minimumRoutineIntervalSeconds: route.provider == .dot ? nil : 300)
    }
    func send(_ message: PluginRelayMessage, using fence: PluginRelayFence) async throws -> PluginRelayReceipt {
        sends += 1; await gate(.send)
        return try .init(requestID: message.messageID, route: route, receiptID: "fixture_receipt", state: .accepted, agentReplyReceived: false)
    }
    func replies(after cursor: Int64, using fence: PluginRelayFence) async throws -> PluginRelayReplyPage {
        try .init(route: route, replies: [], cursor: cursor)
    }
    func disconnect(using fence: PluginRelayFence) async throws {}
    func cancelCurrent() async { cancellations += 1; await gate(.cancel) }
}

final class PluginRelayPhoneRouteOwnerTests: XCTestCase {
    private struct Fixture {
        let session: RouteOwnerSession
        let disk: RouteOwnerDisk
        let transport: RouteOwnerTransport
        let owner: PluginRelayPhoneRouteOwner
    }
    private func fixture(provider: CloudAgentProvider = .dot, wrongAccount: Bool = false) throws -> Fixture {
        let session = RouteOwnerSession(provider: provider), disk = RouteOwnerDisk()
        let route = try PluginRelayReference(provider: provider, routeID: "route_owner_fixture", generation: UUID(),
            accountGeneration: wrongAccount ? UUID() : session.context.accountGeneration)
        let transport = RouteOwnerTransport(route: route)
        return .init(session: session, disk: disk, transport: transport,
            owner: .init(persistence: { _ in disk }, transport: { _ in transport }))
    }
    private func assertFails<T>(_ body: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await body(); XCTFail("Expected rejection", file: file, line: line) } catch {}
    }

    func testConstructionAndRevokedSessionCannotCreateRoute() async throws {
        let f = try fixture()
        await assertFails { try await f.owner.currentFence() }
        f.session.revokeLocal()
        await assertFails { try await f.owner.connect(using: f.session) }
        let calls = await f.transport.connections; XCTAssertEqual(calls, 0)
    }
    func testConnectUsesBrokerAccountGenerationAndDoesNotInferReadiness() async throws {
        let f = try fixture()
        let response = try await f.owner.connect(using: f.session), fence = try await f.owner.currentFence()
        XCTAssertEqual(fence.binding.route, response.route)
        XCTAssertEqual(fence.binding.route.accountGeneration, f.session.context.accountGeneration)
        XCTAssertEqual(fence.binding.pairingEpoch, f.session.context.pairingEpoch)
        XCTAssertEqual(fence.localEpoch, f.session.context.localEpoch)
        let report = try await f.owner.status()
        XCTAssertFalse(report.remoteReady); XCTAssertFalse(report.automaticDeliveryReady)
        await assertFails { try await f.owner.connect(using: f.session) }
        try await f.owner.invalidate()
    }
    func testWrongBrokerAccountResponseRevokesSessionAndCannotPublishFence() async throws {
        let f = try fixture(wrongAccount: true)
        await assertFails { try await f.owner.connect(using: f.session) }
        XCTAssertThrowsError(try f.session.validateSession())
        await assertFails { try await f.owner.currentFence() }
        let calls = await f.transport.cancellations; XCTAssertEqual(calls, 1)
    }
    func testProtectedOrCorruptPersistenceNeverCreatesFreshReadyRoute() async throws {
        let f = try fixture(); f.disk.failsRead = true
        await assertFails { try await f.owner.connect(using: f.session) }
        XCTAssertThrowsError(try f.session.validateSession())
        await assertFails { try await f.owner.currentFence() }
    }
    func testCallbackAndStrictOriginalBytesAreRequiredBeforeAnyStatusDispatch() async throws {
        let f = try fixture(); _ = try await f.owner.connect(using: f.session)
        let fence = try await f.owner.currentFence()
        let request = try PluginRelayV2Envelope(courierID: UUID(), fence: fence, kind: .status)
        await assertFails { try await f.owner.handle(request.encoded(), from: RouteOwnerCallback(id: UUID())) }
        let text = String(decoding: try request.encoded(), as: UTF8.self)
        let malformed = Data(text.replacingOccurrences(of: "\"kind\":\"status\"", with: "\"kind\":\"status\",\"kind\":\"status\"").utf8)
        await assertFails { try await f.owner.handle(malformed, from: RouteOwnerCallback(id: f.session.callbackID)) }
        let calls = await f.transport.statuses; XCTAssertEqual(calls, 0)
        let result = try await f.owner.handle(request.encoded(), from: RouteOwnerCallback(id: f.session.callbackID))
        XCTAssertEqual(try PluginRelayV2Envelope.decode(result, expectedFence: fence, expectedCourierID: request.courierID).kind, .statusReport)
        try await f.owner.invalidate()
    }
    func testInvalidationClosesAdmissionAndDrainsPendingConnectBeforeReplacement() async throws {
        let f = try fixture(); await f.transport.hold(.connect)
        let connect = Task { try await f.owner.connect(using: f.session) }
        await f.transport.waitFor(.connect)
        let closing = Task { try await f.owner.invalidate() }
        await f.transport.waitFor(.cancel)
        XCTAssertThrowsError(try f.session.validateSession())
        await assertFails { try await f.owner.currentFence() }
        await f.transport.release(.connect)
        await assertFails { try await connect.value }
        try await closing.value
        await assertFails { try await f.owner.connect(using: f.session) }
    }
    func testLateSetupStatusAfterInvalidationCannotReturnReady() async throws {
        let f = try fixture(); _ = try await f.owner.connect(using: f.session)
        await f.transport.hold(.status)
        let status = Task { try await f.owner.status() }
        await f.transport.waitFor(.status)
        let closing = Task { try await f.owner.invalidate() }
        await f.transport.waitFor(.cancel)
        await f.transport.release(.status)
        await assertFails { try await status.value }
        try await closing.value
    }
    func testCancelledConnectRevokesSessionAndNeverPublishesFence() async throws {
        let f = try fixture(); await f.transport.hold(.connect)
        let connect = Task { try await f.owner.connect(using: f.session) }
        await f.transport.waitFor(.connect); connect.cancel(); await f.transport.release(.connect)
        await assertFails { try await connect.value }
        XCTAssertThrowsError(try f.session.validateSession())
        await assertFails { try await f.owner.currentFence() }
    }
}
#endif
