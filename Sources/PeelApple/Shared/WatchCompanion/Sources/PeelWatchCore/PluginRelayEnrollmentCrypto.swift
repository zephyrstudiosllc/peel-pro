import Foundation
import CryptoKit

public enum PluginRelayEnrollmentError: Error, Equatable, Sendable {
    case invalidInput, expired, invalidSignature, untrustedBroker, wrongPeer, revoked
}

/// Shared phone/Watch enrollment transcript. These are public inputs, never
/// credentials or authority. Signing proves key possession for this one broker
/// challenge; it does not attest Apple hardware or by itself grant a route.
public struct PluginRelayEnrollmentChallenge: Codable, Equatable, Sendable {
    public let challengeID: UUID
    public let challenge: String
    public let provider: CloudAgentProvider
    public let transactionID: UUID
    public let clientID: String
    public let redirectURI: String
    public let codeChallenge: String
    public let expectedNonce: String
    public let phonePublicKey: String
    public let watchPublicKey: String
    public let localEpoch: UUID
    public let expiresAt: Int64
    public init(challengeID: UUID, challenge: String, provider: CloudAgentProvider, transactionID: UUID,
                clientID: String, redirectURI: String, codeChallenge: String, expectedNonce: String,
                phonePublicKey: String, watchPublicKey: String, localEpoch: UUID, expiresAt: Int64) {
        self.challengeID = challengeID; self.challenge = challenge; self.provider = provider
        self.transactionID = transactionID; self.clientID = clientID; self.redirectURI = redirectURI
        self.codeChallenge = codeChallenge; self.expectedNonce = expectedNonce
        self.phonePublicKey = phonePublicKey; self.watchPublicKey = watchPublicKey
        self.localEpoch = localEpoch; self.expiresAt = expiresAt
    }
    private enum CodingKeys: String, CodingKey { case challengeID, challenge, provider, transactionID, clientID, redirectURI, codeChallenge, expectedNonce, phonePublicKey, watchPublicKey, localEpoch, expiresAt }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(challengeID.uuidString.lowercased(), forKey: .challengeID)
        try values.encode(challenge, forKey: .challenge); try values.encode(provider, forKey: .provider)
        try values.encode(transactionID.uuidString.lowercased(), forKey: .transactionID)
        try values.encode(clientID, forKey: .clientID); try values.encode(redirectURI, forKey: .redirectURI)
        try values.encode(codeChallenge, forKey: .codeChallenge); try values.encode(expectedNonce, forKey: .expectedNonce)
        try values.encode(phonePublicKey, forKey: .phonePublicKey); try values.encode(watchPublicKey, forKey: .watchPublicKey)
        try values.encode(localEpoch.uuidString.lowercased(), forKey: .localEpoch); try values.encode(expiresAt, forKey: .expiresAt)
    }
    public func canonicalBytes(now: Date) throws -> Data {
        let current = try PluginRelayEnrollmentCrypto.unixSeconds(now)
        guard expiresAt > current, expiresAt <= current + 120,
              PluginRelayEnrollmentCrypto.ascii(clientID, maximum: 256),
              PluginRelayEnrollmentCrypto.ascii(redirectURI, maximum: 2_048),
              (43...128).contains(expectedNonce.utf8.count), PluginRelayEnrollmentCrypto.base64Alphabet(expectedNonce),
              (try? PluginRelayEnrollmentCrypto.decodeBase64URL(challenge, maximum: 32).count) == 32,
              (try? PluginRelayEnrollmentCrypto.decodeBase64URL(codeChallenge, maximum: 32).count) == 32 else {
            throw PluginRelayEnrollmentError.invalidInput
        }
        let phone = try PluginRelayEnrollmentCrypto.publicKey(phonePublicKey)
        let watch = try PluginRelayEnrollmentCrypto.publicKey(watchPublicKey)
        guard phone.derRepresentation != watch.derRepresentation else { throw PluginRelayEnrollmentError.invalidInput }
        return Data(["peel-native-enrollment-v1", challengeID.uuidString.lowercased(), challenge,
            provider.rawValue, transactionID.uuidString.lowercased(), clientID, redirectURI, codeChallenge,
            expectedNonce, PluginRelayEnrollmentCrypto.fingerprint(phone.derRepresentation),
            PluginRelayEnrollmentCrypto.fingerprint(watch.derRepresentation), localEpoch.uuidString.lowercased()]
            .joined(separator: "\n").utf8)
    }
}

public enum PluginRelayEnrollmentCrypto {
    public enum Role: Sendable { case phone, watch }
    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func decodeBase64URL(_ text: String, maximum: Int) throws -> Data {
        guard !text.isEmpty, text.utf8.count <= ((maximum + 2) / 3) * 4,
              base64Alphabet(text), text.utf8.count % 4 != 1 else { throw PluginRelayEnrollmentError.invalidInput }
        let padding = String(repeating: "=", count: (4 - text.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + padding),
              !data.isEmpty, data.count <= maximum, base64URL(data) == text else { throw PluginRelayEnrollmentError.invalidInput }
        return data
    }
    public static func publicKey(_ spki: String) throws -> P256.Signing.PublicKey {
        let der = try decodeBase64URL(spki, maximum: 256)
        guard let key = try? P256.Signing.PublicKey(derRepresentation: der), key.derRepresentation == der else {
            throw PluginRelayEnrollmentError.invalidInput
        }
        return key
    }
    public static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func sign(_ challenge: PluginRelayEnrollmentChallenge, role: Role,
                            key: P256.Signing.PrivateKey, now: Date) throws -> String {
        let expected = try publicKey(role == .phone ? challenge.phonePublicKey : challenge.watchPublicKey)
        guard expected.derRepresentation == key.publicKey.derRepresentation else { throw PluginRelayEnrollmentError.wrongPeer }
        return base64URL(try key.signature(for: challenge.canonicalBytes(now: now)).derRepresentation)
    }
    public static func verify(_ signature: String, challenge: PluginRelayEnrollmentChallenge,
                              role: Role, now: Date) throws {
        let raw = try decodeBase64URL(signature, maximum: 80)
        guard let value = try? P256.Signing.ECDSASignature(derRepresentation: raw), value.derRepresentation == raw else {
            throw PluginRelayEnrollmentError.invalidSignature
        }
        let key = try publicKey(role == .phone ? challenge.phonePublicKey : challenge.watchPublicKey)
        guard key.isValidSignature(value, for: try challenge.canonicalBytes(now: now)) else { throw PluginRelayEnrollmentError.invalidSignature }
    }
    static func base64Alphabet(_ text: String) -> Bool {
        text.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }
    static func ascii(_ value: String, maximum: Int) -> Bool {
        (1...maximum).contains(value.utf8.count) && value.utf8.allSatisfy { (33...126).contains($0) }
    }
    public static func unixSeconds(_ date: Date) throws -> Int64 {
        let value = date.timeIntervalSince1970
        guard value.isFinite, value >= 0, value < 9_000_000_000_000_000 else { throw PluginRelayEnrollmentError.invalidInput }
        return Int64(value.rounded(.down))
    }
}

/// Operator-provisioned issuer/key pins, NEVER token-header JWK/URL discovery.
/// Constructing public config is not provider registration or account authority.
public struct PluginRelayBrokerTrust: Sendable {
    public let issuer: String
    public let audience: String
    fileprivate let keys: [String: P256.Signing.PublicKey]
    public init(issuer: String, audience: String, keysSPKI: [String: String]) throws {
        guard let url = URLComponents(string: issuer), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              url.percentEncodedPath.isEmpty, url.query == nil, url.fragment == nil,
              url.url?.absoluteString == issuer, PluginRelayEnrollmentCrypto.ascii(issuer, maximum: 2_048),
              audience == "com.zephyrstudiosllc.Peel.watchkitapp", (1...4).contains(keysSPKI.count),
              keysSPKI.keys.allSatisfy({ PluginRelayEnrollmentCrypto.ascii($0, maximum: 128) }) else {
            throw PluginRelayEnrollmentError.untrustedBroker
        }
        self.issuer = issuer; self.audience = audience
        keys = try keysSPKI.mapValues(PluginRelayEnrollmentCrypto.publicKey)
    }
}

/// Exact locally pending enrollment expectation. Supply it only from the actual
/// paired phone's bounded challenge transaction; restored/random JSON is not a
/// native pending transaction. A successful grant consumes that transaction.
public struct PluginRelayWatchBootstrapExpectation: Equatable, Sendable {
    public let provider: CloudAgentProvider
    public let localEpoch: UUID
    public let phoneKeySHA256: String
    public let watchKeySHA256: String
    public init(provider: CloudAgentProvider, localEpoch: UUID, phoneKeySHA256: String, watchKeySHA256: String) throws {
        guard PluginRelayValidation.isDigest(phoneKeySHA256), PluginRelayValidation.isDigest(watchKeySHA256) else {
            throw PluginRelayEnrollmentError.invalidInput
        }
        self.provider = provider; self.localEpoch = localEpoch
        self.phoneKeySHA256 = phoneKeySHA256; self.watchKeySHA256 = watchKeySHA256
    }
}

/// Only the strict cryptographic verifier can construct this value. It is a
/// short-lived broker grant, never automatic Grok wake or hardware attestation.
public struct PluginRelayVerifiedWatchBootstrap: Sendable {
    public let fence: PluginRelayFence
    public let enrollmentID: UUID
    public let phoneDeviceID: String
    public let phoneKeySHA256: String
    public let watchKeySHA256: String
    public let issuedAt: Date
    public let expiresAt: Date
    public let grantID: UUID
    fileprivate let monotonicDeadline: TimeInterval
    fileprivate init(fence: PluginRelayFence, enrollmentID: UUID, phoneDeviceID: String,
                     phoneKeySHA256: String, watchKeySHA256: String, issuedAt: Date, expiresAt: Date, grantID: UUID,
                     monotonicDeadline: TimeInterval) {
        self.fence = fence; self.enrollmentID = enrollmentID; self.phoneDeviceID = phoneDeviceID
        self.phoneKeySHA256 = phoneKeySHA256; self.watchKeySHA256 = watchKeySHA256
        self.issuedAt = issuedAt; self.expiresAt = expiresAt; self.grantID = grantID
        self.monotonicDeadline = monotonicDeadline
    }
}

public enum PluginRelayWatchBootstrapVerifier {
    public static func verify(_ compact: String, trust: PluginRelayBrokerTrust,
                              expected: PluginRelayWatchBootstrapExpectation, now: Date) throws -> PluginRelayVerifiedWatchBootstrap {
        guard compact.utf8.count <= 8_192, compact.utf8.allSatisfy({ (33...126).contains($0) }) else { throw PluginRelayEnrollmentError.invalidInput }
        let parts = compact.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw PluginRelayEnrollmentError.invalidInput }
        let headerData = try PluginRelayEnrollmentCrypto.decodeBase64URL(String(parts[0]), maximum: 1_024)
        let payloadData = try PluginRelayEnrollmentCrypto.decodeBase64URL(String(parts[1]), maximum: 4_096)
        let header = try PluginRelayCourierJSON.parse(headerData).object(keys: ["alg", "kid", "typ"])
        guard try header.required("alg").string() == "ES256", try header.required("typ").string() == "peel-route+jwt",
              let key = trust.keys[try header.required("kid").string()] else { throw PluginRelayEnrollmentError.untrustedBroker }
        let signatureData = try PluginRelayEnrollmentCrypto.decodeBase64URL(String(parts[2]), maximum: 64)
        guard signatureData.count == 64,
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signatureData),
              key.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)) else { throw PluginRelayEnrollmentError.invalidSignature }
        let object = try PluginRelayCourierJSON.parse(payloadData).object(keys: ["iss", "aud", "sub", "enrollmentID", "phoneDeviceID", "provider",
            "accountGeneration", "pairingGeneration", "localEpoch", "routeGeneration", "jti", "routeID", "audWatchKeySHA256", "phoneKeySHA256", "scopes", "iat", "exp"])
        guard try object.required("iss").string() == trust.issuer, try object.required("aud").string() == trust.audience,
              PluginRelayEnrollmentCrypto.ascii(try object.required("sub").string(), maximum: 256),
              let provider = CloudAgentProvider(rawValue: try object.required("provider").string()), provider == expected.provider,
              try object.required("phoneKeySHA256").string() == expected.phoneKeySHA256,
              try object.required("audWatchKeySHA256").string() == expected.watchKeySHA256,
              case .array(let scopes) = try object.required("scopes"), scopes.count == 2,
              try scopes.map({ try $0.string() }) == ["watch.read", "watch.send"] else { throw PluginRelayEnrollmentError.wrongPeer }
        let localEpoch = try uuid(object.required("localEpoch"))
        guard localEpoch == expected.localEpoch else { throw PluginRelayEnrollmentError.wrongPeer }
        let issued = try object.required("iat").integer(), expiry = try object.required("exp").integer()
        let current = try PluginRelayEnrollmentCrypto.unixSeconds(now)
        guard issued >= 0, expiry > issued, expiry - issued <= 300, issued <= current + 30, expiry > current else {
            throw PluginRelayEnrollmentError.expired
        }
        let deviceID = try object.required("phoneDeviceID").string()
        guard PluginRelayEnrollmentCrypto.ascii(deviceID, maximum: 256) else { throw PluginRelayEnrollmentError.invalidInput }
        let route = try PluginRelayReference(provider: provider, routeID: object.required("routeID").string(),
            generation: uuid(object.required("routeGeneration")), accountGeneration: uuid(object.required("accountGeneration")))
        let fence = PluginRelayFence(binding: .init(route: route, pairingEpoch: try uuid(object.required("pairingGeneration"))), localEpoch: localEpoch)
        return .init(fence: fence, enrollmentID: try uuid(object.required("enrollmentID")), phoneDeviceID: deviceID,
            phoneKeySHA256: expected.phoneKeySHA256, watchKeySHA256: expected.watchKeySHA256,
            issuedAt: Date(timeIntervalSince1970: Double(issued)), expiresAt: Date(timeIntervalSince1970: Double(expiry)), grantID: try uuid(object.required("jti")),
            monotonicDeadline: ProcessInfo.processInfo.systemUptime + min(300, Double(expiry) - now.timeIntervalSince1970))
    }
    private static func uuid(_ value: PluginRelayCourierJSON) throws -> UUID {
        let text = try value.string()
        guard let id = UUID(uuidString: text), id.uuidString.lowercased() == text else { throw PluginRelayEnrollmentError.invalidInput }
        return id
    }
}

/// Live local registry for the cryptographically verified grant. Native pairing,
/// account replacement and sign-out revoke it synchronously before awaits.
/// Reinstallation/renewal still needs a current verified enrollment transaction;
/// storing an old token or creating an expectation is not a restoration grant.
public final class PluginRelayVerifiedWatchAuthority: PluginRelayWatchAuthority, @unchecked Sendable {
    private let lock = NSLock()
    private var grant: PluginRelayVerifiedWatchBootstrap
    private let uptime: @Sendable () -> TimeInterval
    private var enabled = true
    private var seen: Set<UUID>
    public init(grant: PluginRelayVerifiedWatchBootstrap) { self.grant = grant; seen = [grant.grantID]; uptime = { ProcessInfo.processInfo.systemUptime } }
    init(grant: PluginRelayVerifiedWatchBootstrap, uptime: @escaping @Sendable () -> TimeInterval) { self.grant = grant; seen = [grant.grantID]; self.uptime = uptime }
    public func revoke() { lock.lock(); defer { lock.unlock() }; enabled = false }
    public func validateCurrent(_ fence: PluginRelayFence) throws {
        lock.lock(); defer { lock.unlock() }
        guard enabled, grant.fence == fence else { throw PluginRelayEnrollmentError.revoked }
        guard grant.expiresAt > Date(), grant.issuedAt <= Date().addingTimeInterval(30),
              uptime() < grant.monotonicDeadline else { throw PluginRelayEnrollmentError.expired }
    }
    /// Only a newly verified same-context grant can renew this existing object.
    /// Neither the coordinator, store epoch, pending logical IDs nor local fence
    /// changes. Keep prior grant IDs for this finite application session so an
    /// old token cannot extend uptime after a wall-clock rollback.
    public func renew(_ next: PluginRelayVerifiedWatchBootstrap) throws {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { throw PluginRelayEnrollmentError.revoked }
        guard next.fence == grant.fence, next.enrollmentID == grant.enrollmentID,
              next.phoneDeviceID == grant.phoneDeviceID, next.phoneKeySHA256 == grant.phoneKeySHA256,
              next.watchKeySHA256 == grant.watchKeySHA256, next.issuedAt >= grant.issuedAt,
              next.expiresAt >= grant.expiresAt, !seen.contains(next.grantID), seen.count < 4_096 else {
            throw PluginRelayEnrollmentError.wrongPeer
        }
        guard next.expiresAt > Date(), next.issuedAt <= Date().addingTimeInterval(30), uptime() < next.monotonicDeadline else {
            throw PluginRelayEnrollmentError.expired
        }
        seen.insert(next.grantID); grant = next
    }
}

/// One native-attributed Watch enrollment transaction. The phone signature and
/// approved app registration are checked before signing; the actual local Watch
/// private key supplies the expected audience fingerprint. A route grant is
/// consumed once. This object creates no peer trust or WC dispatch by itself.
public final class PluginRelayWatchEnrollmentTransaction: @unchecked Sendable {
    private let lock = NSLock()
    private let expectation: PluginRelayWatchBootstrapExpectation
    public let watchSignature: String
    private var active = true
    private let monotonicDeadline: TimeInterval
    public init(challenge: PluginRelayEnrollmentChallenge, phoneSignature: String,
                watchKey: P256.Signing.PrivateKey, approvedClientID: String,
                approvedRedirectURI: String, now: Date) throws {
        guard challenge.clientID == approvedClientID, challenge.redirectURI == approvedRedirectURI else {
            throw PluginRelayEnrollmentError.untrustedBroker
        }
        try PluginRelayEnrollmentCrypto.verify(phoneSignature, challenge: challenge, role: .phone, now: now)
        watchSignature = try PluginRelayEnrollmentCrypto.sign(challenge, role: .watch, key: watchKey, now: now)
        monotonicDeadline = ProcessInfo.processInfo.systemUptime + 300
        expectation = try .init(provider: challenge.provider, localEpoch: challenge.localEpoch,
            phoneKeySHA256: PluginRelayEnrollmentCrypto.fingerprint(try PluginRelayEnrollmentCrypto.publicKey(challenge.phonePublicKey).derRepresentation),
            watchKeySHA256: PluginRelayEnrollmentCrypto.fingerprint(watchKey.publicKey.derRepresentation))
    }
    public func revoke() { lock.lock(); defer { lock.unlock() }; active = false }
    public func consume(_ compact: String, trust: PluginRelayBrokerTrust, now: Date) throws -> PluginRelayVerifiedWatchBootstrap {
        lock.lock(); defer { lock.unlock() }
        guard active else { throw PluginRelayEnrollmentError.revoked }
        guard ProcessInfo.processInfo.systemUptime < monotonicDeadline else {
            active = false; throw PluginRelayEnrollmentError.expired
        }
        // Consume on this exact attempt, including a rejected grant. A new
        // signing transaction is required after an invalid or stale response.
        active = false
        return try PluginRelayWatchBootstrapVerifier.verify(compact, trust: trust, expected: expectation, now: now)
    }
}
