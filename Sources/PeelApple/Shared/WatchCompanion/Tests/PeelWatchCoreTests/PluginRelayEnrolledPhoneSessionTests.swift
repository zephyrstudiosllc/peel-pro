#if !os(watchOS)
import XCTest
import CryptoKit
@testable import PeelWatchCore

private struct EnrolledSessionCallback: PluginRelayNativePeerCallback { let accepted: Bool }
private final class EnrolledSessionPeerVerifier: PluginRelayNativePeerVerifier, @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = true
    func revoke() { lock.lock(); defer { lock.unlock() }; enabled = false }
    func validateCurrent() throws {
        lock.lock(); defer { lock.unlock() }; guard enabled else { throw PluginRelayEnrollmentError.revoked }
    }
    func validate(_ callback: any PluginRelayNativePeerCallback) throws {
        try validateCurrent()
        guard (callback as? EnrolledSessionCallback)?.accepted == true else { throw PluginRelayEnrollmentError.wrongPeer }
    }
}
final class PluginRelayEnrolledPhoneSessionTests: XCTestCase {
    private func fixture() throws -> (PluginRelayEnrolledPhoneSession, P256.Signing.PrivateKey, EnrolledSessionPeerVerifier, PluginRelayFence) {
        let key = P256.Signing.PrivateKey(), peer = EnrolledSessionPeerVerifier()
        let route = try PluginRelayReference(provider: .dot, routeID: "route_session_test", generation: UUID(), accountGeneration: UUID())
        let context = PluginRelayHTTPContext(provider: .dot, accountGeneration: route.accountGeneration, pairingEpoch: UUID(), localEpoch: UUID())
        let session = PluginRelayEnrolledPhoneSession(context: context, trustedOrigin: URL(string: "https://relay.invalid")!,
            actualAgentReference: "Dot", token: "SYNTHETIC_NOT_A_LIVE_CREDENTIAL", expiry: Date().addingTimeInterval(600),
            enrollmentID: UUID(), phoneDeviceID: "synthetic_phone", phoneKey: key,
            watchKeySHA256: String(repeating: "a", count: 64), peer: peer)
        let fence = PluginRelayFence(binding: .init(route: route, pairingEpoch: context.pairingEpoch), localEpoch: context.localEpoch)
        return (session, key, peer, fence)
    }
    func testExactSignedBodyPathAndNonceVerifyWithEnrolledPhonePublicKey() throws {
        let (session, key, _, _) = try fixture()
        try installSyntheticPro(session)
        let request = try PluginRelayHTTPRequestProof(method: "POST", path: "/v1/watch/send", body: Data("{\"text\":\"hello\"}".utf8))
        let grant = try session.authorization(for: session.context, scope: .send, trustedOrigin: session.trustedOrigin, request: request)
        let timestamp = try XCTUnwrap(grant.headers["x-peel-timestamp"].flatMap(Int64.init))
        let nonce = try XCTUnwrap(grant.headers["x-peel-nonce"]), signature = try XCTUnwrap(grant.headers["x-peel-signature"])
        let canonical = try request.canonicalBytes(enrollmentID: session.enrollmentID.uuidString.lowercased(), unixSeconds: timestamp, nonce: nonce)
        let value = try P256.Signing.ECDSASignature(derRepresentation: PluginRelayEnrollmentCrypto.decodeBase64URL(signature, maximum: 80))
        XCTAssertTrue(key.publicKey.isValidSignature(value, for: canonical))
        let changed = try PluginRelayHTTPRequestProof(method: "POST", path: "/v1/watch/replies", body: Data("{\"text\":\"hello\"}".utf8))
        XCTAssertFalse(key.publicKey.isValidSignature(value, for: try changed.canonicalBytes(enrollmentID: session.enrollmentID.uuidString.lowercased(), unixSeconds: timestamp, nonce: nonce)))
        try session.validateCurrent(grant, scope: .send)
    }
    func testBearerOnlyWrongOriginContextAndScopeCannotAuthorize() throws {
        let (session, _, _, _) = try fixture()
        let request = try PluginRelayHTTPRequestProof(method: "POST", path: "/v1/watch/send", body: Data("{}".utf8))
        XCTAssertThrowsError(try session.authorization(for: session.context, scope: .send, trustedOrigin: session.trustedOrigin))
        XCTAssertThrowsError(try session.authorization(for: session.context, scope: .read, trustedOrigin: session.trustedOrigin, request: request))
        XCTAssertThrowsError(try session.authorization(for: session.context, scope: .send, trustedOrigin: URL(string: "https://other.invalid")!, request: request))
    }
    func testForgedAttachmentCannotReuseLiveLeaseWithChangedHeaders() throws {
        let (session, _, _, _) = try fixture()
        try installSyntheticPro(session)
        let request = try PluginRelayHTTPRequestProof(method: "POST", path: "/v1/watch/status", body: Data("{}".utf8))
        let grant = try session.authorization(for: session.context, scope: .read, trustedOrigin: session.trustedOrigin, request: request)
        var headers = grant.headers; headers["x-peel-nonce"] = PluginRelayEnrollmentCrypto.base64URL(Data(repeating: 1, count: 32))
        let forged = PluginRelayHTTPAuthorization(context: grant.context, leaseID: grant.leaseID, expiresAt: grant.expiresAt, headers: headers)
        XCTAssertThrowsError(try session.validateCurrent(forged, scope: .read))
        session.revokeLocal(); XCTAssertThrowsError(try session.validateCurrent(grant, scope: .read))
    }
    func testOnlyBoundFenceAndAttributedPeerCanCreatePhoneActionLease() throws {
        let (session, _, _, fence) = try fixture()
        XCTAssertThrowsError(try session.peerEvidence(for: EnrolledSessionCallback(accepted: true)))
        try session.bind(fence)
        try installSyntheticPro(session, fence: fence)
        XCTAssertThrowsError(try session.peerEvidence(for: EnrolledSessionCallback(accepted: false)))
        let peer = try session.peerEvidence(for: EnrolledSessionCallback(accepted: true))
        let lease = try session.authorize(.send, fence: fence, peer: peer); try session.validateCurrent(lease)
        let wrong = PluginRelayFence(binding: fence.binding, localEpoch: UUID())
        XCTAssertThrowsError(try session.authorize(.send, fence: wrong, peer: peer))
        session.revokeLocal(); XCTAssertThrowsError(try session.validateCurrent(lease))
    }
    func testActualPeerRevocationInvalidatesCurrentSessionAndInFlightLeases() throws {
        let (session, _, peer, _) = try fixture()
        try installSyntheticPro(session)
        let request = try PluginRelayHTTPRequestProof(method: "POST", path: "/v1/watch/status", body: Data("{}".utf8))
        let grant = try session.authorization(for: session.context, scope: .read, trustedOrigin: session.trustedOrigin, request: request)
        peer.revoke(); XCTAssertThrowsError(try session.validateSession()); XCTAssertThrowsError(try session.validateCurrent(grant, scope: .read))
    }
    func testProLossClosesCloudActionsButKeepsIdentityEvidenceAndCleanupAvailable() throws {
        let (session, _, _, fence) = try fixture()
        try session.bind(fence)
        let peer = try session.peerEvidence(for: EnrolledSessionCallback(accepted: true))
        XCTAssertThrowsError(try session.authorize(.send, fence: fence, peer: peer)) { XCTAssertEqual($0 as? PluginRelayProError, .required) }
        try session.validateSession()
        for path in ["/v1/native/pro/challenge", "/v1/native/pro/evidence", "/v1/native/pro/withdraw"] {
            let request = try PluginRelayHTTPRequestProof(method: "POST", path: path, body: Data("{}".utf8))
            let authorization = try session.authorization(for: session.context, scope: .read, trustedOrigin: session.trustedOrigin, request: request)
            XCTAssertNil(authorization.proPermit); try session.validateCurrent(authorization, scope: .read)
        }
        for action in [PluginRelayPhoneAction.localStop, .disconnect] {
            let lease = try session.authorize(action, fence: fence, peer: peer)
            XCTAssertNil(lease.proPermit); try session.validateCurrent(lease)
        }
        try installSyntheticPro(session, fence: fence)
        let old = try session.authorize(.send, fence: fence, peer: peer)
        _ = session.withdrawProLocally()
        XCTAssertThrowsError(try session.validateCurrent(old)); try session.validateSession()
        let stop = try session.authorize(.localStop, fence: fence, peer: peer); try session.validateCurrent(stop)
    }
    func testRequestCanonicalBytesAreBoundedAndSecretsAreRedacted() throws {
        let (session, _, _, _) = try fixture()
        XCTAssertFalse(String(reflecting: session).contains("SYNTHETIC_NOT_A_LIVE_CREDENTIAL"))
        XCTAssertFalse(Mirror(reflecting: session).children.contains(where: { $0.label == "credential" || $0.label == "phoneKey" }))
        let request = try PluginRelayHTTPRequestProof(method: "POST", path: "/v1/watch/status", body: Data("{}".utf8))
        XCTAssertThrowsError(try request.canonicalBytes(enrollmentID: "one\ntwo", unixSeconds: 1, nonce: String(repeating: "a", count: 43)))
        XCTAssertThrowsError(try PluginRelayHTTPRequestProof(method: "GET", path: "/v1/watch/status", body: Data("{}".utf8)))
        XCTAssertThrowsError(try PluginRelayHTTPRequestProof(method: "POST", path: "/v1/watch/status?route=other", body: Data("{}".utf8)))
    }
}
#endif
