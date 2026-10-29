import XCTest
import CryptoKit
@testable import PeelWatchCore

final class PluginRelayEnrollmentWireTests: XCTestCase {
    func testEnrollmentWireRejectsDuplicateUnknownFieldsAndCourierMismatch() throws {
        let request = try PluginRelayEnrollmentWire(courierID: UUID(), kind: .keyRequest)
        let bytes = try request.encoded(), text = String(decoding: bytes, as: UTF8.self)
        XCTAssertEqual(try PluginRelayEnrollmentWire.decode(bytes, expectedCourierID: request.courierID).kind, .keyRequest)
        XCTAssertThrowsError(try PluginRelayEnrollmentWire.decode(bytes, expectedCourierID: UUID()))
        for altered in [text.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"version\":1"),
                        text.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"bearer\":\"rejected\"")] {
            XCTAssertThrowsError(try PluginRelayEnrollmentWire.decode(Data(altered.utf8)))
        }
    }
    func testChallengeWireEmitsCanonicalLowercaseUUIDAndRetainsExactSignature() throws {
        let phone = P256.Signing.PrivateKey(), watch = P256.Signing.PrivateKey(), now = Date()
        let challenge = PluginRelayEnrollmentChallenge(challengeID: UUID(), challenge: PluginRelayEnrollmentCrypto.base64URL(Data(repeating: 1, count: 32)),
            provider: .dot, transactionID: UUID(), clientID: "oaiapp_wire_test", redirectURI: "com.wire.peel://identity/callback",
            codeChallenge: PluginRelayEnrollmentCrypto.base64URL(Data(repeating: 2, count: 32)), expectedNonce: String(repeating: "N", count: 43),
            phonePublicKey: PluginRelayEnrollmentCrypto.base64URL(phone.publicKey.derRepresentation),
            watchPublicKey: PluginRelayEnrollmentCrypto.base64URL(watch.publicKey.derRepresentation), localEpoch: UUID(),
            expiresAt: Int64(now.timeIntervalSince1970.rounded(.down)) + 120)
        let signature = try PluginRelayEnrollmentCrypto.sign(challenge, role: .phone, key: phone, now: now)
        let request = try PluginRelayEnrollmentWire(courierID: UUID(), kind: .signChallenge, challenge: challenge, phoneSignature: signature)
        let decoded = try PluginRelayEnrollmentWire.decode(request.encoded())
        XCTAssertEqual(decoded.challenge, challenge); XCTAssertEqual(decoded.phoneSignature, signature)
        let text = String(decoding: try request.encoded(), as: UTF8.self)
        XCTAssertTrue(text.contains(challenge.challengeID.uuidString.lowercased()))
    }
    func testEnrollmentChannelIsBoundedSeparateAndProviderSpecificOnInvalidate() throws {
        let request = try PluginRelayEnrollmentWire(courierID: UUID(), kind: .invalidate, provider: .grokBot)
        let bytes = try request.encoded()
        XCTAssertTrue(PluginRelayEnrollmentWire.claims(bytes))
        XCTAssertEqual(try PluginRelayEnrollmentWire.decode(bytes).provider, .grokBot)
        XCTAssertThrowsError(try PluginRelayEnrollmentWire(courierID: UUID(), kind: .invalidate))
        XCTAssertThrowsError(try PluginRelayEnrollmentWire.decode(Data(repeating: 0x20, count: PluginRelayEnrollmentWire.maximumBytes + 1)))
        XCTAssertThrowsError(try PluginRelayEnrollmentWire(courierID: UUID(), kind: .installGrant, routeGrant: String(repeating: "a", count: 8_193)))
        XCTAssertFalse(PluginRelayEnrollmentWire.claims(Data("{\"channel\":\"peel.watch.cloud.v2\"}".utf8)))
    }
}
