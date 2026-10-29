#if !os(watchOS)
import XCTest
import CryptoKit
@testable import PeelWatchCore

private final class ContinuityDisk: PluginRelayContinuityPersistence, @unchecked Sendable {
    private let lock = NSLock(); private var bytes: Data?; private var writes = 0
    var failWrite: Int?
    init(_ record: PluginRelayContinuityRecord) throws { bytes = try JSONEncoder().encode(record) }
    func read(maximumBytes: Int) throws -> Data? { lock.lock(); defer { lock.unlock() }; return bytes }
    func writeAtomically(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }; writes += 1
        if failWrite == writes { throw PluginRelayContinuityError.storageUnavailable }; bytes = data
    }
    func remove() throws { lock.lock(); defer { lock.unlock() }; bytes = nil }
    func record() throws -> PluginRelayContinuityRecord { try JSONDecoder().decode(PluginRelayContinuityRecord.self, from: read(maximumBytes: 32768)!) }
}
private final class ContinuityPeer: PluginRelayNativePeerVerifier, @unchecked Sendable {
    private let lock = NSLock(); private var enabled = true
    func revoke() { lock.lock(); defer { lock.unlock() }; enabled = false }
    func validateCurrent() throws { lock.lock(); defer { lock.unlock() }; if !enabled { throw PluginRelayEnrollmentError.revoked } }
    func validate(_ callback: any PluginRelayNativePeerCallback) throws { try validateCurrent() }
}
private actor ContinuityTransport: PluginRelayContinuityTransport {
    let disk: ContinuityDisk; let brokerKey: P256.Signing.PrivateKey
    var failRotation = false; var changeContext = false
    var rotations = 0; var grants = 0; var sawUncertain = false
    init(disk: ContinuityDisk, brokerKey: P256.Signing.PrivateKey) { self.disk = disk; self.brokerKey = brokerKey }
    func configure(fail: Bool = false, change: Bool = false) { failRotation = fail; changeContext = change }
    func rotate(_ input: PluginRelayContinuityRotationInput, phoneKey: P256.Signing.PrivateKey) async throws -> PluginRelayVerifiedContinuityRotation {
        rotations += 1; sawUncertain = try disk.record().state == .rotationUncertain
        if failRotation { throw PluginRelayHTTPError.timeout }
        var value = input.record
        value.accessToken = PluginRelayEnrollmentCrypto.base64URL(Data(repeating: UInt8(rotations + 10), count: 32))
        value.refreshToken = PluginRelayEnrollmentCrypto.base64URL(Data(repeating: UInt8(rotations + 20), count: 32))
        value.accessExpiresAt = Int64(Date().timeIntervalSince1970) + 900
        if changeContext { value.fence = PluginRelayFence(binding: value.fence!.binding, localEpoch: UUID()) }
        return .init(value)
    }
    func routeGrant(using session: PluginRelayEnrolledPhoneSession, fence: PluginRelayFence) async throws -> String {
        try session.validateSession(); grants += 1
        return try continuityJWT(fence: fence, session: session, signingKey: brokerKey)
    }
}
private func continuityJWT(fence: PluginRelayFence, session: PluginRelayEnrolledPhoneSession, signingKey: P256.Signing.PrivateKey,
                           issuedAt: Int64 = Int64(Date().timeIntervalSince1970), grantID: UUID = UUID()) throws -> String {
    let p: [String: Any] = ["iss": "https://relay.invalid", "aud": "com.zephyrstudiosllc.Peel.watchkitapp", "sub": "synthetic_principal",
        "enrollmentID": session.enrollmentID.uuidString.lowercased(), "phoneDeviceID": session.phoneDeviceID,
        "provider": fence.binding.route.provider.rawValue, "accountGeneration": fence.binding.route.accountGeneration.uuidString.lowercased(),
        "pairingGeneration": fence.binding.pairingEpoch.uuidString.lowercased(), "localEpoch": fence.localEpoch.uuidString.lowercased(),
        "routeGeneration": fence.binding.route.generation.uuidString.lowercased(), "jti": grantID.uuidString.lowercased(), "routeID": fence.binding.route.routeID,
        "audWatchKeySHA256": session.watchKeySHA256, "phoneKeySHA256": session.phoneKeySHA256,
        "scopes": ["watch.read", "watch.send"], "iat": issuedAt, "exp": issuedAt + 300]
    let h = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": "unit-broker", "typ": "peel-route+jwt"], options: .sortedKeys)
    let b = try JSONSerialization.data(withJSONObject: p, options: .sortedKeys)
    let input = PluginRelayEnrollmentCrypto.base64URL(h) + "." + PluginRelayEnrollmentCrypto.base64URL(b)
    return input + "." + PluginRelayEnrollmentCrypto.base64URL(try signingKey.signature(for: Data(input.utf8)).rawRepresentation)
}
final class PluginRelayContinuityTests: XCTestCase {
    private struct Fixture {
        let controller: PluginRelayPhoneContinuityController; let disk: ContinuityDisk; let transport: ContinuityTransport
        let peer: ContinuityPeer; let record: PluginRelayContinuityRecord; let phone: P256.Signing.PrivateKey
        let watch: P256.Signing.PrivateKey; let broker: P256.Signing.PrivateKey; let trust: PluginRelayBrokerTrust
    }
    private func fixture(expiredApp: Bool = false) throws -> Fixture {
        let now = Int64(Date().timeIntervalSince1970), phone = P256.Signing.PrivateKey(), watch = P256.Signing.PrivateKey(), broker = P256.Signing.PrivateKey()
        let config = try CloudAgentIdentityConfiguration(provider: .dot, values: ["ClientID": "oaiapp_unit_test_client", "RedirectURI": "com.peel.unit.oauth://signin/callback",
            "BundleID": "com.peel.unit", "ClientType": "public-native", "TokenEndpointAuthMethod": "none", "ApprovalReference": "unit-test-only-registration"],
            bundleID: "com.peel.unit", registeredURLSchemes: ["com.peel.unit.oauth"])
        let identity = try CloudAgentVerifiedIdentity(provider: .dot, issuer: "https://auth.openai.com", clientID: "oaiapp_unit_test_client", subject: "unit-subject",
            verifiedAt: Date(timeIntervalSince1970: Double(now - 3600)), identityExpiresAt: Date(timeIntervalSince1970: Double(now - 3000)))
        let route = try PluginRelayReference(provider: .dot, routeID: "route_continuity_test", generation: UUID(), accountGeneration: UUID())
        let fence = PluginRelayFence(binding: .init(route: route, pairingEpoch: UUID()), localEpoch: UUID())
        let deadline = expiredApp ? now - 1 : now + 3600
        let record = PluginRelayContinuityRecord(state: .ready, accessToken: PluginRelayEnrollmentCrypto.base64URL(Data(repeating: 1, count: 32)),
            accessExpiresAt: now - 1, refreshToken: PluginRelayEnrollmentCrypto.base64URL(Data(repeating: 2, count: 32)), refreshExpiresAt: deadline,
            applicationExpiresAt: deadline, provider: .dot, enrollmentID: UUID(), phoneDeviceID: "unit_phone",
            accountGeneration: route.accountGeneration, pairingGeneration: fence.binding.pairingEpoch, localEpoch: fence.localEpoch,
            phoneKeySHA256: PluginRelayEnrollmentCrypto.fingerprint(phone.publicKey.derRepresentation),
            watchKeySHA256: PluginRelayEnrollmentCrypto.fingerprint(watch.publicKey.derRepresentation), watchPublicKey: PluginRelayEnrollmentCrypto.base64URL(watch.publicKey.derRepresentation),
            origin: "https://relay.invalid", identity: identity, fence: fence)
        let disk = try ContinuityDisk(record), transport = ContinuityTransport(disk: disk, brokerKey: broker)
        let trust = try PluginRelayBrokerTrust(issuer: record.origin, audience: "com.zephyrstudiosllc.Peel.watchkitapp",
            keysSPKI: ["unit-broker": PluginRelayEnrollmentCrypto.base64URL(broker.publicKey.derRepresentation)])
        return try .init(controller: PluginRelayPhoneContinuityController(persistence: disk, transport: transport, trustedOrigin: URL(string: record.origin)!, registration: config,
            phoneKey: phone, trust: trust), disk: disk, transport: transport, peer: ContinuityPeer(), record: record, phone: phone, watch: watch, broker: broker, trust: trust)
    }
    private func rejects<T>(_ action: () async throws -> T) async { do { _ = try await action(); XCTFail("Expected closed admission") } catch {} }
    func testColdMetadataReadGrantsNothingAndMakesNoNetworkCall() async throws {
        let f = try fixture(), value = try await f.controller.descriptor()
        XCTAssertEqual(value.fence, f.record.fence)
        XCTAssertLessThan(value.identity.identityExpiresAt, Date()) // historical provider proof is not app expiry
        let rotations = await f.transport.rotations, grants = await f.transport.grants
        XCTAssertEqual(rotations, 0); XCTAssertEqual(grants, 0)
    }
    func testColdRestorePersistsUncertainBeforeOnlineRotationAndRequiresFreshPeer() async throws {
        let f = try fixture(); f.peer.revoke()
        await rejects { try await f.controller.refreshAuthority(from: f.peer) }
        let calls = await f.transport.rotations; XCTAssertEqual(calls, 0)
        let peer = ContinuityPeer(), result = try await f.controller.refreshAuthority(from: peer)
        let marked = await f.transport.sawUncertain, rotations = await f.transport.rotations
        XCTAssertTrue(marked); XCTAssertEqual(rotations, 1)
        XCTAssertEqual(result.fence, f.record.fence); XCTAssertEqual(result.identity, f.record.identity)
        XCTAssertEqual(result.session.applicationSessionExpiresAt.timeIntervalSince1970, Double(f.record.applicationExpiresAt))
        try result.session.validateSession(); XCTAssertEqual(try f.disk.record().state, .ready)
        peer.revoke(); XCTAssertThrowsError(try result.session.validateSession())
    }
    func testUncertainRotationIsNeverRetriedAndSavedIDsPartitionIsUnchanged() async throws {
        let f = try fixture(); await f.transport.configure(fail: true)
        await rejects { try await f.controller.refreshAuthority(from: f.peer) }
        XCTAssertEqual(try f.disk.record().state, .rotationUncertain); XCTAssertEqual(try f.disk.record().fence, f.record.fence)
        await rejects { try await f.controller.refreshAuthority(from: f.peer) }
        let calls = await f.transport.rotations; XCTAssertEqual(calls, 1)
    }
    func testCheckpointWriteFailurePreventsHTTPAndReplacementWriteFailureRequiresConnect() async throws {
        let f = try fixture(); f.disk.failWrite = 1
        await rejects { try await f.controller.refreshAuthority(from: f.peer) }
        let calls = await f.transport.rotations; XCTAssertEqual(calls, 0)
        let second = try fixture(); second.disk.failWrite = 2
        await rejects { try await second.controller.refreshAuthority(from: second.peer) }
        XCTAssertEqual(try second.disk.record().state, .rotationUncertain)
        await rejects { try await second.controller.refreshAuthority(from: second.peer) }
        let secondCalls = await second.transport.rotations; XCTAssertEqual(secondCalls, 1)
    }
    func testFixedAppDeadlineAndContextReplacementCannotRenewAuthority() async throws {
        let expired = try fixture(expiredApp: true)
        await rejects { try await expired.controller.refreshAuthority(from: expired.peer) }
        let calls = await expired.transport.rotations; XCTAssertEqual(calls, 0)
        let changed = try fixture(); await changed.transport.configure(change: true)
        await rejects { try await changed.controller.refreshAuthority(from: changed.peer) }
        XCTAssertEqual(try changed.disk.record().state, .rotationUncertain)
    }
    func testSameFenceFreshGrantRetainsLivePhoneSessionObjectAndInvalidationIsTerminal() async throws {
        let f = try fixture(), first = try await f.controller.refreshAuthority(from: f.peer)
        let second = try await f.controller.refreshAuthority(from: ContinuityPeer())
        XCTAssertTrue(first.session === second.session); XCTAssertEqual(first.fence, second.fence)
        XCTAssertNotEqual(first.watchGrant.grantID, second.watchGrant.grantID)
        let calls = await f.transport.rotations; XCTAssertEqual(calls, 1)
        try await f.controller.invalidate(removeCredential: true)
        XCTAssertThrowsError(try second.session.validateSession()); XCTAssertNil(try f.disk.read(maximumBytes: 32768))
        await rejects { try await f.controller.refreshAuthority(from: ContinuityPeer()) }
    }
    func testMutualResumeProofCannotSwitchFenceAndConsumesFreshJWSOnce() async throws {
        let f = try fixture(), restored = try await f.controller.refreshAuthority(from: f.peer)
        let context = try PluginRelayWatchResumeContext(issuer: f.record.origin, enrollmentID: f.record.enrollmentID, phoneDeviceID: f.record.phoneDeviceID,
            fence: restored.fence, phonePublicKey: PluginRelayEnrollmentCrypto.base64URL(f.phone.publicKey.derRepresentation), watchPublicKey: f.record.watchPublicKey)
        let challenge = PluginRelayWatchResumeChallenge(challengeID: UUID(), nonce: PluginRelayEnrollmentCrypto.base64URL(Data(repeating: 4, count: 32)),
            expiresAt: Int64(Date().timeIntervalSince1970) + 30, context: context)
        let phoneSignature = try challenge.sign(role: .phone, key: f.phone, now: Date())
        let transaction = try PluginRelayWatchResumeTransaction(challenge: challenge, phoneSignature: phoneSignature, expected: context, watchKey: f.watch, now: Date())
        try challenge.verify(transaction.watchSignature, role: .watch, now: Date())
        XCTAssertFalse(String(decoding: try challenge.canonicalBytes(now: Date()), as: UTF8.self).hasSuffix("\n"))
        let grant = try transaction.consume(restored.compactGrant, trust: f.trust, now: Date()); XCTAssertEqual(grant.fence, restored.fence)
        XCTAssertThrowsError(try transaction.consume(restored.compactGrant, trust: f.trust, now: Date()))
        XCTAssertThrowsError(try PluginRelayWatchResumeTransaction(challenge: challenge, phoneSignature: phoneSignature, expected: context, watchKey: f.phone, now: Date()))
    }
    func testWatchLeaseRenewalIsInPlaceAndRejectsReplayOrChangedFence() async throws {
        let f = try fixture(), first = try await f.controller.refreshAuthority(from: f.peer)
        let authority = PluginRelayVerifiedWatchAuthority(grant: first.watchGrant)
        let second = try await f.controller.refreshAuthority(from: ContinuityPeer())
        try authority.renew(second.watchGrant); try authority.validateCurrent(first.fence)
        XCTAssertThrowsError(try authority.renew(second.watchGrant))
        authority.revoke(); XCTAssertThrowsError(try authority.renew(first.watchGrant))
    }
    func testEnrollmentLiteralInsideValidV2MessageTextDoesNotChangeItsChannel() throws {
        let f = try fixture(), message = try PluginRelayMessage(messageID: UUID(), text: "Explain peel.watch.cloud.enrollment.v1 to me")
        let packet = try PluginRelayV2Envelope(courierID: UUID(), fence: f.record.fence!, kind: .send, message: message).encoded()
        XCTAssertFalse(PluginRelayEnrollmentWire.claims(packet))
        XCTAssertEqual(try PluginRelayV2Envelope.decode(packet, expectedFence: f.record.fence!).message, message)
        let enrollment = try PluginRelayEnrollmentWire(courierID: UUID(), kind: .keyRequest).encoded()
        XCTAssertTrue(PluginRelayEnrollmentWire.claims(enrollment))
    }
    func testInitialChallengeEncodingRoundTripsItsOwnCanonicalUUIDsAndRenewalHasNoCredentials() throws {
        let f = try fixture(), challenge = PluginRelayEnrollmentChallenge(challengeID: UUID(), challenge: PluginRelayEnrollmentCrypto.base64URL(Data(repeating: 5, count: 32)), provider: .dot,
            transactionID: UUID(), clientID: "oaiapp_unit_test_client", redirectURI: "com.peel.unit.oauth://signin/callback", codeChallenge: PluginRelayEnrollmentCrypto.base64URL(Data(repeating: 6, count: 32)),
            expectedNonce: String(repeating: "N", count: 43), phonePublicKey: PluginRelayEnrollmentCrypto.base64URL(f.phone.publicKey.derRepresentation), watchPublicKey: f.record.watchPublicKey,
            localEpoch: UUID(), expiresAt: Int64(Date().timeIntervalSince1970) + 120)
        let wire = try PluginRelayEnrollmentWire(courierID: UUID(), kind: .signChallenge, challenge: challenge,
            phoneSignature: PluginRelayEnrollmentCrypto.sign(challenge, role: .phone, key: f.phone, now: Date()))
        let decoded = try PluginRelayEnrollmentWire.decode(wire.encoded()); XCTAssertEqual(decoded.challenge, challenge)
        let context = try PluginRelayWatchResumeContext(issuer: f.record.origin, enrollmentID: f.record.enrollmentID, phoneDeviceID: f.record.phoneDeviceID,
            fence: f.record.fence!, phonePublicKey: challenge.phonePublicKey, watchPublicKey: challenge.watchPublicKey)
        let packet = try PluginRelayEnrollmentWire(courierID: UUID(), kind: .renewChallengeRequest, resumeContext: context).encoded()
        XCTAssertEqual(try PluginRelayEnrollmentWire.decode(packet).resumeContext, context)
        let text = String(decoding: packet, as: UTF8.self)
        for secret in [f.record.accessToken, f.record.refreshToken, "sessionToken", "refreshToken", "codeVerifier"] { XCTAssertFalse(text.contains(secret)) }
        XCTAssertFalse(String(reflecting: f.record).contains(f.record.refreshToken))
    }
}
#endif
