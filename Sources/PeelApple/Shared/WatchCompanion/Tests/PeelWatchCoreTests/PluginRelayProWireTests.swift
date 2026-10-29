#if !os(watchOS)
import XCTest
@testable import PeelWatchCore

final class PluginRelayProWireTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func fixture() throws -> (PluginRelayProBinding, [String: Any], [String: Any]) {
        let f = PluginRelayFence(binding: .init(route: try .init(provider: .dot, routeID: "route_wire_pro", generation: UUID(), accountGeneration: UUID()), pairingEpoch: UUID()), localEpoch: UUID())
        let b = syntheticProBinding(for: f, expiry: 1_800_001_000)
        let binding: [String: Any] = ["provider": b.provider.rawValue, "accountGeneration": b.accountGeneration.uuidString.lowercased(),
            "enrollmentID": b.enrollmentID.uuidString.lowercased(), "phoneDeviceID": b.phoneDeviceID,
            "phoneKeySHA256": b.phoneKeySHA256, "watchKeySHA256": b.watchKeySHA256,
            "pairingGeneration": b.pairingGeneration.uuidString.lowercased(), "localEpoch": b.localEpoch.uuidString.lowercased(),
            "routeID": b.route!.routeID, "routeGeneration": b.route!.generation.uuidString.lowercased(), "applicationSessionExpiresAt": b.applicationSessionExpiresAt]
        let challenge: [String: Any] = ["schema": 1, "binding": binding,
            "challenge": ["type": "proEntitlementChallenge", "requestId": UUID().uuidString.lowercased(),
                "nonce": Data(repeating: 7, count: 32).base64EncodedString(), "pairingId": b.enrollmentID.uuidString.lowercased(),
                "sessionId": UUID().uuidString.lowercased(), "expiresAt": 1_800_000_030] as [String: Any]]
        return (b, binding, challenge)
    }
    private func parse(_ object: [String: Any]) throws -> PluginRelayJSON {
        try .parse(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }
    private func response(_ c: PluginRelayProChallenge, binding: [String: Any], state: String = "verified") -> [String: Any] {
        ["schema": 1, "requestId": c.requestID.uuidString.lowercased(), "sessionId": c.sessionID.uuidString.lowercased(),
         "binding": binding, "state": state, "reason": state == "verified" ? "active" : "no_entitlement",
         "leaseID": state == "verified" ? UUID().uuidString.lowercased() as Any : NSNull(),
         "verifiedAt": 1_800_000_000, "expiresAt": state == "verified" ? 1_800_000_300 : 1_800_000_000]
    }
    func testExactChallengeReadbackAndFiniteSkewContract() throws {
        let (b, binding, object) = try fixture()
        var skewed = object, fields = try XCTUnwrap(object["challenge"] as? [String: Any]); fields["expiresAt"] = 1_800_000_031; skewed["challenge"] = fields
        let c = try PluginRelayProWire.challenge(parse(skewed), expected: b, now: now, uptime: 100)
        XCTAssertEqual(c.monotonicDeadline, 130)
        var r = response(c, binding: binding); r["verifiedAt"] = 1_800_000_001; r["expiresAt"] = 1_800_000_301
        let readback = try PluginRelayProWire.readback(parse(r), challenge: c, now: now, uptime: 101)
        XCTAssertTrue(readback.verified)
        XCTAssertThrowsError(try PluginRelayProWire.readback(parse(r), challenge: c, now: now, uptime: 130))
        fields["expiresAt"] = 1_800_000_061; skewed["challenge"] = fields
        XCTAssertThrowsError(try PluginRelayProWire.challenge(parse(skewed), expected: b, now: now, uptime: 100))
    }
    func testUnknownDuplicateOrNoncanonicalChallengeFieldsNeverInstallAuthority() throws {
        let (b, _, object) = try fixture()
        var unknown = object; unknown["verified"] = true
        XCTAssertThrowsError(try PluginRelayProWire.challenge(parse(unknown), expected: b, now: now, uptime: 100))
        for replacement in ["nonce": "not-base64", "requestId": UUID().uuidString.uppercased(), "expiresAt": true] as [String: Any] {
            var malformed = object, fields = try XCTUnwrap(object["challenge"] as? [String: Any]); fields[replacement.key] = replacement.value; malformed["challenge"] = fields
            XCTAssertThrowsError(try PluginRelayProWire.challenge(parse(malformed), expected: b, now: now, uptime: 100))
        }
        XCTAssertThrowsError(try PluginRelayJSON.parse(Data("{\"schema\":1,\"\\u0073chema\":1}".utf8)))
    }
    func testEveryReadbackCorrelationAndBindingMustMatchOriginatingExchange() throws {
        let (b, binding, object) = try fixture(), c = try PluginRelayProWire.challenge(parse(object), expected: b, now: now, uptime: 100)
        for key in ["requestId", "sessionId"] {
            var wrong = response(c, binding: binding); wrong[key] = UUID().uuidString.lowercased()
            XCTAssertThrowsError(try PluginRelayProWire.readback(parse(wrong), challenge: c, now: now, uptime: 101))
        }
        for key in ["accountGeneration", "enrollmentID", "pairingGeneration", "localEpoch", "routeGeneration"] {
            var changed = binding; changed[key] = UUID().uuidString.lowercased()
            XCTAssertThrowsError(try PluginRelayProWire.readback(parse(response(c, binding: changed)), challenge: c, now: now, uptime: 101))
        }
        for key in ["phoneDeviceID", "phoneKeySHA256", "watchKeySHA256", "routeID", "provider"] {
            var changed = binding; changed[key] = key.contains("SHA") ? String(repeating: "c", count: 64) : key == "provider" ? "grokBot" : "changed"
            XCTAssertThrowsError(try PluginRelayProWire.readback(parse(response(c, binding: changed)), challenge: c, now: now, uptime: 101))
        }
    }
    func testDenialIsExactAndNeverCarriesLeaseOrFutureExpiry() throws {
        let (b, binding, object) = try fixture(), c = try PluginRelayProWire.challenge(parse(object), expected: b, now: now, uptime: 100)
        let denied = response(c, binding: binding, state: "denied")
        XCTAssertFalse(try PluginRelayProWire.readback(parse(denied), challenge: c, now: now, uptime: 101).verified)
        for pair in [("leaseID", UUID().uuidString.lowercased() as Any), ("expiresAt", 1_800_000_001 as Any), ("reason", "active" as Any)] {
            var invalid = denied; invalid[pair.0] = pair.1
            XCTAssertThrowsError(try PluginRelayProWire.readback(parse(invalid), challenge: c, now: now, uptime: 101))
        }
        var tooLong = response(c, binding: binding); tooLong["expiresAt"] = 1_800_000_301
        XCTAssertThrowsError(try PluginRelayProWire.readback(parse(tooLong), challenge: c, now: now, uptime: 101))
    }
    func testInitialRouteBindingMustUseBothNullsAndCannotTrustMetadataClaim() throws {
        let (b, binding, object) = try fixture()
        var changed = binding; changed["routeID"] = NSNull()
        var malformed = object; malformed["binding"] = changed
        XCTAssertThrowsError(try PluginRelayProWire.challenge(parse(malformed), expected: b, now: now, uptime: 100))
        var arbitrary = binding; arbitrary["pro"] = true; malformed["binding"] = arbitrary
        XCTAssertThrowsError(try PluginRelayProWire.challenge(parse(malformed), expected: b, now: now, uptime: 100))
    }
}

private final class ProSubmissionURLFixture: URLProtocol, @unchecked Sendable {
    static let started = ProSubmissionCounter()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.started.increment(); client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
private final class ProSubmissionCounter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
final class PluginRelayProSubmissionTests: XCTestCase {
    func testClosedCapturedPermitPreventsActualURLSessionTaskResume() async throws {
        let f = PluginRelayFence(binding: .init(route: try .init(provider: .dot, routeID: "route_submission", generation: UUID(), accountGeneration: UUID()), pairingEpoch: UUID()), localEpoch: UUID())
        let permit = try syntheticPaidPermit(for: f)
        permit.closeOnTrustedDenial()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ProSubmissionURLFixture.self]
        var request = URLRequest(url: URL(string: "https://no-live-network.invalid/v1/watch/send")!); request.httpMethod = "POST"
        let before = ProSubmissionURLFixture.started.value
        do { _ = try await PluginRelayHTTPOperation().perform(request, configuration: config, timeout: 1, submission: permit, validateAuthority: {}); XCTFail("closed submission dispatched") }
        catch { XCTAssertEqual(error as? PluginRelayProError, .superseded) }
        XCTAssertEqual(ProSubmissionURLFixture.started.value, before)
    }
}
#endif
