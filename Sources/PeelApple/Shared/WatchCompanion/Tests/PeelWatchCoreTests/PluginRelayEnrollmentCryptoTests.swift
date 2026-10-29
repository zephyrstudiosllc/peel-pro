import XCTest
import CryptoKit
@testable import PeelWatchCore

final class PluginRelayEnrollmentCryptoTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func key(_ number: UInt8) throws -> P256.Signing.PrivateKey {
        try .init(rawRepresentation: Data(repeating: 0, count: 31) + Data([number]))
    }
    private func challenge() throws -> PluginRelayEnrollmentChallenge {
        .init(challengeID: UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!,
            challenge: PluginRelayEnrollmentCrypto.base64URL(Data(repeating: 7, count: 32)), provider: .dot,
            transactionID: UUID(uuidString: "11223344-5566-7788-99aa-bbccddeeff00")!, clientID: "oaiapp_synthetic_crypto_test",
            redirectURI: "com.synthetic.peel://identity/callback", codeChallenge: PluginRelayEnrollmentCrypto.base64URL(Data(repeating: 8, count: 32)),
            expectedNonce: String(repeating: "N", count: 43),
            phonePublicKey: PluginRelayEnrollmentCrypto.base64URL(try key(1).publicKey.derRepresentation),
            watchPublicKey: PluginRelayEnrollmentCrypto.base64URL(try key(2).publicKey.derRepresentation),
            localEpoch: UUID(uuidString: "22334455-6677-8899-aabb-ccddeeff0011")!, expiresAt: 1_800_000_120)
    }
    private func trust() throws -> PluginRelayBrokerTrust {
        try .init(issuer: "https://relay.invalid", audience: "com.zephyrstudiosllc.Peel.watchkitapp",
            keysSPKI: ["synthetic-key": PluginRelayEnrollmentCrypto.base64URL(try key(3).publicKey.derRepresentation)])
    }
    private func expected(_ challenge: PluginRelayEnrollmentChallenge? = nil) throws -> PluginRelayWatchBootstrapExpectation {
        let value = try challenge ?? self.challenge()
        return try .init(provider: value.provider, localEpoch: value.localEpoch,
            phoneKeySHA256: PluginRelayEnrollmentCrypto.fingerprint(try key(1).publicKey.derRepresentation),
            watchKeySHA256: PluginRelayEnrollmentCrypto.fingerprint(try key(2).publicKey.derRepresentation))
    }
    private func payload() throws -> [String: Any] {
        let expected = try expected()
        return ["iss": "https://relay.invalid", "aud": "com.zephyrstudiosllc.Peel.watchkitapp", "sub": "synthetic_principal",
            "enrollmentID": "33445566-7788-99aa-bbcc-ddeeff001122", "phoneDeviceID": "synthetic_phone",
            "provider": "dot", "accountGeneration": "44556677-8899-aabb-ccdd-eeff00112233",
            "pairingGeneration": "55667788-99aa-bbcc-ddee-ff0011223344", "localEpoch": expected.localEpoch.uuidString.lowercased(),
            "routeGeneration": "66778899-aabb-ccdd-eeff-001122334455", "jti": "778899aa-bbcc-ddee-ff00-112233445566", "routeID": "route_synthetic",
            "audWatchKeySHA256": expected.watchKeySHA256, "phoneKeySHA256": expected.phoneKeySHA256,
            "scopes": ["watch.read", "watch.send"], "iat": 1_800_000_000, "exp": 1_800_000_300]
    }
    private func token(payload: [String: Any]? = nil, header: [String: Any]? = nil,
                       signingKey: UInt8 = 3, rawHeader: Data? = nil, rawPayload: Data? = nil) throws -> String {
        let h = try rawHeader ?? JSONSerialization.data(withJSONObject: header ?? ["alg": "ES256", "kid": "synthetic-key", "typ": "peel-route+jwt"], options: [.sortedKeys])
        let p = try rawPayload ?? JSONSerialization.data(withJSONObject: payload ?? self.payload(), options: [.sortedKeys])
        let input = PluginRelayEnrollmentCrypto.base64URL(h) + "." + PluginRelayEnrollmentCrypto.base64URL(p)
        return input + "." + PluginRelayEnrollmentCrypto.base64URL(try key(signingKey).signature(for: Data(input.utf8)).rawRepresentation)
    }

    func testEnrollmentTranscriptIsExactLowercaseAndHasNoFinalNewline() throws {
        let value = try challenge(), bytes = try value.canonicalBytes(now: now)
        let text = String(decoding: bytes, as: UTF8.self), lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 12); XCTAssertEqual(lines.first, "peel-native-enrollment-v1")
        XCTAssertEqual(lines[1], "00112233-4455-6677-8899-aabbccddeeff")
        XCTAssertEqual(lines.last, "22334455-6677-8899-aabb-ccddeeff0011"); XCTAssertFalse(text.hasSuffix("\n"))
    }
    func testPhoneAndWatchDERSignaturesVerifyOnlyTheirOwnTranscriptRole() throws {
        let value = try challenge()
        for (role, scalar) in [(PluginRelayEnrollmentCrypto.Role.phone, UInt8(1)), (.watch, UInt8(2))] {
            let signature = try PluginRelayEnrollmentCrypto.sign(value, role: role, key: key(scalar), now: now)
            try PluginRelayEnrollmentCrypto.verify(signature, challenge: value, role: role, now: now)
            XCTAssertThrowsError(try PluginRelayEnrollmentCrypto.verify(signature, challenge: value,
                role: scalar == 1 ? .watch : .phone, now: now))
        }
        XCTAssertThrowsError(try PluginRelayEnrollmentCrypto.sign(value, role: .watch, key: key(1), now: now))
        var cloned = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        cloned["watchPublicKey"] = cloned["phonePublicKey"]
        let sameKey = try JSONDecoder().decode(PluginRelayEnrollmentChallenge.self, from: JSONSerialization.data(withJSONObject: cloned))
        XCTAssertThrowsError(try sameKey.canonicalBytes(now: now))
    }
    func testExpiredOrOverlongChallengeCannotBeSigned() throws {
        let value = try challenge()
        XCTAssertThrowsError(try value.canonicalBytes(now: now.addingTimeInterval(120)))
        XCTAssertThrowsError(try value.canonicalBytes(now: now.addingTimeInterval(-1)))
    }
    func testBase64AndSPKIAreCanonicalAndBounded() throws {
        let bytes = Data(repeating: 0xff, count: 32), encoded = PluginRelayEnrollmentCrypto.base64URL(bytes)
        XCTAssertEqual(try PluginRelayEnrollmentCrypto.decodeBase64URL(encoded, maximum: 32), bytes)
        for bad in [encoded + "=", " " + encoded, "A", "AB", String(repeating: "a", count: 1_000)] {
            XCTAssertThrowsError(try PluginRelayEnrollmentCrypto.decodeBase64URL(bad, maximum: 32))
        }
        XCTAssertThrowsError(try PluginRelayEnrollmentCrypto.publicKey(PluginRelayEnrollmentCrypto.base64URL(bytes)))
    }
    func testApprovedPinnedGrantVerifiesEveryFencePartition() throws {
        let grant = try PluginRelayWatchBootstrapVerifier.verify(token(), trust: trust(), expected: expected(), now: now)
        XCTAssertEqual(grant.fence.binding.route.routeID, "route_synthetic")
        XCTAssertEqual(grant.fence.binding.route.accountGeneration.uuidString.lowercased(), "44556677-8899-aabb-ccdd-eeff00112233")
        XCTAssertEqual(grant.fence.binding.pairingEpoch.uuidString.lowercased(), "55667788-99aa-bbcc-ddee-ff0011223344")
        XCTAssertEqual(grant.fence.localEpoch, try expected().localEpoch)
        XCTAssertEqual(grant.expiresAt.timeIntervalSince(grant.issuedAt), 300)
    }
    func testWrongSignerAlgorithmPinOrHeaderFieldsCannotVerify() throws {
        XCTAssertThrowsError(try PluginRelayWatchBootstrapVerifier.verify(token(signingKey: 4), trust: trust(), expected: expected(), now: now))
        for h in [["alg": "HS256", "kid": "synthetic-key", "typ": "peel-route+jwt"],
                  ["alg": "ES256", "kid": "unknown", "typ": "peel-route+jwt"],
                  ["alg": "ES256", "kid": "synthetic-key", "typ": "peel-route+jwt", "jku": "https://untrusted.invalid/key"]] {
            XCTAssertThrowsError(try PluginRelayWatchBootstrapVerifier.verify(token(header: h), trust: trust(), expected: expected(), now: now))
        }
    }
    func testDuplicateUnknownNullAndWrongIntegerClaimsAreRejectedBeforeGrant() throws {
        let rawHeader = Data("{\"alg\":\"ES256\",\"kid\":\"synthetic-key\",\"kid\":\"synthetic-key\",\"typ\":\"peel-route+jwt\"}".utf8)
        XCTAssertThrowsError(try PluginRelayWatchBootstrapVerifier.verify(token(rawHeader: rawHeader), trust: trust(), expected: expected(), now: now))
        for (field, value) in [("extra", "ignored" as Any), ("iat", 1_800_000_000.5 as Any), ("exp", NSNull() as Any)] {
            var p = try payload(); p[field] = value
            XCTAssertThrowsError(try PluginRelayWatchBootstrapVerifier.verify(token(payload: p), trust: trust(), expected: expected(), now: now))
        }
    }
    func testWrongIssuerAudiencePeerLocalEpochAndScopeAreRejected() throws {
        let cases: [(String, Any)] = [("iss", "https://untrusted.invalid"), ("aud", "another.bundle"),
            ("provider", "grokBot"), ("audWatchKeySHA256", String(repeating: "0", count: 64)),
            ("phoneKeySHA256", String(repeating: "0", count: 64)), ("localEpoch", UUID().uuidString.lowercased()),
            ("scopes", ["watch.read", "watch.send", "agent.reply"])]
        for (field, value) in cases {
            var p = try payload(); p[field] = value
            XCTAssertThrowsError(try PluginRelayWatchBootstrapVerifier.verify(token(payload: p), trust: trust(), expected: expected(), now: now), field)
        }
    }
    func testExpiredFutureOverlongAndNoncanonicalUUIDClaimsAreRejected() throws {
        for (field, value) in [("exp", 1_800_000_301 as Any), ("iat", 1_800_000_031 as Any),
                               ("routeGeneration", "66778899-AABB-CCDD-EEFF-001122334455" as Any)] {
            var p = try payload(); p[field] = value
            XCTAssertThrowsError(try PluginRelayWatchBootstrapVerifier.verify(token(payload: p), trust: trust(), expected: expected(), now: now))
        }
        XCTAssertThrowsError(try PluginRelayWatchBootstrapVerifier.verify(token(), trust: trust(), expected: expected(), now: now.addingTimeInterval(300)))
    }
    func testWatchTransactionConsumesGrantOnceAndRevocationIsTerminal() throws {
        let challenge = try challenge(), signature = try PluginRelayEnrollmentCrypto.sign(challenge, role: .phone, key: key(1), now: now)
        let transaction = try PluginRelayWatchEnrollmentTransaction(challenge: challenge, phoneSignature: signature, watchKey: key(2),
            approvedClientID: challenge.clientID, approvedRedirectURI: challenge.redirectURI, now: now)
        let grant = try transaction.consume(token(), trust: trust(), now: now)
        XCTAssertEqual(grant.fence.localEpoch, challenge.localEpoch)
        XCTAssertThrowsError(try transaction.consume(token(), trust: trust(), now: now))
        let revoked = try PluginRelayWatchEnrollmentTransaction(challenge: challenge, phoneSignature: signature, watchKey: key(2),
            approvedClientID: challenge.clientID, approvedRedirectURI: challenge.redirectURI, now: now)
        revoked.revoke(); XCTAssertThrowsError(try revoked.consume(token(), trust: trust(), now: now))
    }
    func testWrongRegistrationAndPhoneSignatureDoNotProduceWatchSignature() throws {
        let challenge = try challenge(), signature = try PluginRelayEnrollmentCrypto.sign(challenge, role: .phone, key: key(1), now: now)
        XCTAssertThrowsError(try PluginRelayWatchEnrollmentTransaction(challenge: challenge, phoneSignature: signature, watchKey: key(2),
            approvedClientID: "another_client", approvedRedirectURI: challenge.redirectURI, now: now))
        XCTAssertThrowsError(try PluginRelayWatchEnrollmentTransaction(challenge: challenge, phoneSignature: "not_a_signature", watchKey: key(2),
            approvedClientID: challenge.clientID, approvedRedirectURI: challenge.redirectURI, now: now))
    }
    func testMonotonicGrantExpiryAndExplicitRevocationCannotBeExtendedByWallClock() throws {
        let current = Date(), seconds = Int64(current.timeIntervalSince1970.rounded(.down))
        var p = try payload(); p["iat"] = seconds; p["exp"] = seconds + 300
        let grant = try PluginRelayWatchBootstrapVerifier.verify(token(payload: p), trust: trust(), expected: expected(), now: current)
        let live = PluginRelayVerifiedWatchAuthority(grant: grant)
        try live.validateCurrent(grant.fence)
        let expiredUptime = PluginRelayVerifiedWatchAuthority(grant: grant, uptime: { ProcessInfo.processInfo.systemUptime + 301 })
        XCTAssertThrowsError(try expiredUptime.validateCurrent(grant.fence))
        live.revoke(); XCTAssertThrowsError(try live.validateCurrent(grant.fence))
    }
    func testBackendPythonP256DERAndRawJOSEInteroperateWithCryptoKit() throws {
        // Public-only vector from the actual backend fixture, SHA256
        // fc50f33eaf28802d63676b268df3e149179f4691beaa09090fcdbcfb7e07712b.
        let data = Data(Self.backendVector.utf8)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let challengeData = try JSONSerialization.data(withJSONObject: object["challenge"]!)
        let challenge = try JSONDecoder().decode(PluginRelayEnrollmentChallenge.self, from: challengeData)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let transcript = try challenge.canonicalBytes(now: now)
        XCTAssertEqual(String(decoding: transcript, as: UTF8.self), object["enrollmentTranscriptUTF8"] as? String)
        XCTAssertEqual(PluginRelayEnrollmentCrypto.fingerprint(transcript), object["enrollmentTranscriptSHA256"] as? String)
        try PluginRelayEnrollmentCrypto.verify(try XCTUnwrap(object["phoneSignatureDER"] as? String), challenge: challenge, role: .phone, now: now)
        try PluginRelayEnrollmentCrypto.verify(try XCTUnwrap(object["watchSignatureDER"] as? String), challenge: challenge, role: .watch, now: now)
        let trust = try PluginRelayBrokerTrust(issuer: "https://relay.example.com", audience: "com.zephyrstudiosllc.Peel.watchkitapp",
            keysSPKI: [try XCTUnwrap(object["brokerKeyID"] as? String): try XCTUnwrap(object["brokerPublicKeySPKI"] as? String)])
        let expected = try PluginRelayWatchBootstrapExpectation(provider: .dot, localEpoch: challenge.localEpoch,
            phoneKeySHA256: PluginRelayEnrollmentCrypto.fingerprint(PluginRelayEnrollmentCrypto.publicKey(challenge.phonePublicKey).derRepresentation),
            watchKeySHA256: PluginRelayEnrollmentCrypto.fingerprint(PluginRelayEnrollmentCrypto.publicKey(challenge.watchPublicKey).derRepresentation))
        let verified = try PluginRelayWatchBootstrapVerifier.verify(try XCTUnwrap(object["routeGrant"] as? String), trust: trust, expected: expected, now: now)
        XCTAssertEqual(verified.fence.binding.route.routeID, "route_fixture")
        XCTAssertEqual(verified.fence.localEpoch, challenge.localEpoch)
    }
    private static let backendVector = #"""
{"brokerKeyID":"fixture-broker-3","brokerPublicKeySPKI":"MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEXsvk0aYzCkTI9--VHUvxZebGtyHvramF-0FmG8bn_WyHNGQMSZj_fjdLBs4aZKLs2CqwNjhPuD2aebEnon1QMg","challenge":{"challenge":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8","challengeID":"00000000-0000-4000-8000-000000000001","clientID":"oaiapp_fixture","codeChallenge":"S0-WMMHEuuumkDoJt044nSxveejcVm4-B681Rl_3cJ4","expectedNonce":"NNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN","expiresAt":1800000120,"localEpoch":"00000000-0000-4000-8000-000000000003","phonePublicKey":"MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEaxfR8uEsQkf4vOblY6RA8ncDfYEt6zOg9KE5RdiYwpZP40Li_hp_m47n60p8D54WK84zV2sxXs7LtkBoN79R9Q","provider":"dot","redirectURI":"peel-fixture://oauth/dot","transactionID":"00000000-0000-4000-8000-000000000002","watchPublicKey":"MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEfPJ7GI0DT36KUjgDBLUaw8CJaeJ38hs1pgtI_EdmmXgHd1UQ247QQCk9msafdDDbun2t5jzpgimeBLedInhz0Q"},"enrollmentTranscriptSHA256":"b7e7881459e2e2013580733cfcc31cd009c6c420c6f5643083340a0a474c3b23","enrollmentTranscriptUTF8":"peel-native-enrollment-v1\n00000000-0000-4000-8000-000000000001\nAAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8\ndot\n00000000-0000-4000-8000-000000000002\noaiapp_fixture\npeel-fixture://oauth/dot\nS0-WMMHEuuumkDoJt044nSxveejcVm4-B681Rl_3cJ4\nNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN\n5cd252fb0ce8932436faf8ccd1040981b89ee4ad6b9fe9e2a2b7e71aacb27cd3\ndc0ce633dbcc913dafafa4b89ac44d8ce683fdfc3f60c8bdf21213b9f2b534ba\n00000000-0000-4000-8000-000000000003","fixtureOnly":true,"phoneSignatureDER":"MEYCIQC9Hm-7aU3iVVUiemEkdNDREtVrKwo-xNOv-sCb6D6OBwIhAOCHL3WjNhS2_zAMk9V9DZzHquockV2X5-bpEf9Yt7YW","routeClaims":{"accountGeneration":"00000000-0000-4000-8000-000000000005","aud":"com.zephyrstudiosllc.Peel.watchkitapp","audWatchKeySHA256":"dc0ce633dbcc913dafafa4b89ac44d8ce683fdfc3f60c8bdf21213b9f2b534ba","enrollmentID":"00000000-0000-4000-8000-000000000004","exp":1800000300,"iat":1800000000,"iss":"https://relay.example.com","jti":"00000000-0000-4000-8000-000000000008","localEpoch":"00000000-0000-4000-8000-000000000003","pairingGeneration":"00000000-0000-4000-8000-000000000006","phoneDeviceID":"phone_fixture","phoneKeySHA256":"5cd252fb0ce8932436faf8ccd1040981b89ee4ad6b9fe9e2a2b7e71aacb27cd3","provider":"dot","routeGeneration":"00000000-0000-4000-8000-000000000007","routeID":"route_fixture","scopes":["watch.read","watch.send"],"sub":"principal_fixture"},"routeGrant":"eyJhbGciOiJFUzI1NiIsImtpZCI6ImZpeHR1cmUtYnJva2VyLTMiLCJ0eXAiOiJwZWVsLXJvdXRlK2p3dCJ9.eyJpc3MiOiJodHRwczovL3JlbGF5LmV4YW1wbGUuY29tIiwiYXVkIjoiY29tLnplcGh5cnN0dWRpb3NsbGMuUGVlbC53YXRjaGtpdGFwcCIsInN1YiI6InByaW5jaXBhbF9maXh0dXJlIiwiZW5yb2xsbWVudElEIjoiMDAwMDAwMDAtMDAwMC00MDAwLTgwMDAtMDAwMDAwMDAwMDA0IiwicGhvbmVEZXZpY2VJRCI6InBob25lX2ZpeHR1cmUiLCJwcm92aWRlciI6ImRvdCIsImFjY291bnRHZW5lcmF0aW9uIjoiMDAwMDAwMDAtMDAwMC00MDAwLTgwMDAtMDAwMDAwMDAwMDA1IiwicGFpcmluZ0dlbmVyYXRpb24iOiIwMDAwMDAwMC0wMDAwLTQwMDAtODAwMC0wMDAwMDAwMDAwMDYiLCJsb2NhbEVwb2NoIjoiMDAwMDAwMDAtMDAwMC00MDAwLTgwMDAtMDAwMDAwMDAwMDAzIiwicm91dGVJRCI6InJvdXRlX2ZpeHR1cmUiLCJyb3V0ZUdlbmVyYXRpb24iOiIwMDAwMDAwMC0wMDAwLTQwMDAtODAwMC0wMDAwMDAwMDAwMDciLCJhdWRXYXRjaEtleVNIQTI1NiI6ImRjMGNlNjMzZGJjYzkxM2RhZmFmYTRiODlhYzQ0ZDhjZTY4M2ZkZmMzZjYwYzhiZGYyMTIxM2I5ZjJiNTM0YmEiLCJwaG9uZUtleVNIQTI1NiI6IjVjZDI1MmZiMGNlODkzMjQzNmZhZjhjY2QxMDQwOTgxYjg5ZWU0YWQ2YjlmZTllMmEyYjdlNzFhYWNiMjdjZDMiLCJzY29wZXMiOlsid2F0Y2gucmVhZCIsIndhdGNoLnNlbmQiXSwiaWF0IjoxODAwMDAwMDAwLCJleHAiOjE4MDAwMDAzMDAsImp0aSI6IjAwMDAwMDAwLTAwMDAtNDAwMC04MDAwLTAwMDAwMDAwMDAwOCJ9.-JBIhgubiCF6_MCynu9JpqoCWwdIWscfO2BKl5y5KvG9cKiyLWhGOIkoFluPeuSrY_DSClbwm8JUGUX51-5Qaw","verificationTime":1800000000,"watchSignatureDER":"MEUCIHSwIDZQmeC3IQ5NVjgrnscMsx60DG8SLf35dWJk1TIkAiEA6d1wIva4KpQEAAC9s0CdB1FRguHW6IaD42E-M1mcQYo"}
"""#

}
