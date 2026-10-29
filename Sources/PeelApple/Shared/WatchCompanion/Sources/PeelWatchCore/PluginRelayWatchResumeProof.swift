import Foundation
import CryptoKit

/// Persistable PUBLIC expectation from a previously verified enrollment. It
/// grants nothing when restored. Current peer proof + online authority + a fresh
/// pinned broker JWS are required before the same fence can resume admission.
public struct PluginRelayWatchResumeContext: Codable, Equatable, Sendable {
    public let issuer: String
    public let enrollmentID: UUID
    public let phoneDeviceID: String
    public let fence: PluginRelayFence
    public let phonePublicKey: String
    public let watchPublicKey: String
    public init(issuer: String, enrollmentID: UUID, phoneDeviceID: String, fence: PluginRelayFence,
                phonePublicKey: String, watchPublicKey: String) throws {
        self.issuer = issuer; self.enrollmentID = enrollmentID; self.phoneDeviceID = phoneDeviceID; self.fence = fence
        self.phonePublicKey = phonePublicKey; self.watchPublicKey = watchPublicKey; try validate()
    }
    public func validate() throws {
        guard let url = URLComponents(string: issuer), url.scheme == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil, url.percentEncodedPath.isEmpty, url.query == nil, url.fragment == nil,
              url.port == nil || url.port == 443, PluginRelayEnrollmentCrypto.ascii(phoneDeviceID, maximum: 256) else {
            throw PluginRelayEnrollmentError.invalidInput
        }
        try fence.binding.route.validate()
        let phone = try PluginRelayEnrollmentCrypto.publicKey(phonePublicKey), watch = try PluginRelayEnrollmentCrypto.publicKey(watchPublicKey)
        guard phone.derRepresentation != watch.derRepresentation else { throw PluginRelayEnrollmentError.invalidInput }
    }
    public func matches(_ grant: PluginRelayVerifiedWatchBootstrap) throws {
        try validate()
        guard grant.fence == fence, grant.enrollmentID == enrollmentID, grant.phoneDeviceID == phoneDeviceID,
              grant.phoneKeySHA256 == (try PluginRelayEnrollmentCrypto.fingerprint(PluginRelayEnrollmentCrypto.publicKey(phonePublicKey).derRepresentation)),
              grant.watchKeySHA256 == (try PluginRelayEnrollmentCrypto.fingerprint(PluginRelayEnrollmentCrypto.publicKey(watchPublicKey).derRepresentation)) else {
            throw PluginRelayEnrollmentError.wrongPeer
        }
    }
}

public struct PluginRelayWatchResumeChallenge: Codable, Equatable, Sendable {
    public let challengeID: UUID
    public let nonce: String
    public let expiresAt: Int64
    public let context: PluginRelayWatchResumeContext
    public init(challengeID: UUID, nonce: String, expiresAt: Int64, context: PluginRelayWatchResumeContext) {
        self.challengeID = challengeID; self.nonce = nonce; self.expiresAt = expiresAt; self.context = context
    }
    public func canonicalBytes(now: Date) throws -> Data {
        try context.validate()
        let current = try PluginRelayEnrollmentCrypto.unixSeconds(now)
        guard expiresAt > current, expiresAt <= current + 30,
              (try? PluginRelayEnrollmentCrypto.decodeBase64URL(nonce, maximum: 32).count) == 32 else { throw PluginRelayEnrollmentError.expired }
        let route = context.fence.binding.route
        return Data(["peel-watch-resume-v1", context.issuer, challengeID.uuidString.lowercased(), nonce, String(expiresAt),
            context.enrollmentID.uuidString.lowercased(), context.phoneDeviceID, route.provider.rawValue, route.routeID,
            route.generation.uuidString.lowercased(), route.accountGeneration.uuidString.lowercased(),
            context.fence.binding.pairingEpoch.uuidString.lowercased(), context.fence.localEpoch.uuidString.lowercased(),
            PluginRelayEnrollmentCrypto.fingerprint(try PluginRelayEnrollmentCrypto.publicKey(context.phonePublicKey).derRepresentation),
            PluginRelayEnrollmentCrypto.fingerprint(try PluginRelayEnrollmentCrypto.publicKey(context.watchPublicKey).derRepresentation)]
            .joined(separator: "\n").utf8)
    }
    public func sign(role: PluginRelayEnrollmentCrypto.Role, key: P256.Signing.PrivateKey, now: Date) throws -> String {
        let expected = try PluginRelayEnrollmentCrypto.publicKey(role == .phone ? context.phonePublicKey : context.watchPublicKey)
        guard expected.derRepresentation == key.publicKey.derRepresentation else { throw PluginRelayEnrollmentError.wrongPeer }
        return PluginRelayEnrollmentCrypto.base64URL(try key.signature(for: canonicalBytes(now: now)).derRepresentation)
    }
    public func verify(_ signature: String, role: PluginRelayEnrollmentCrypto.Role, now: Date) throws {
        let raw = try PluginRelayEnrollmentCrypto.decodeBase64URL(signature, maximum: 80)
        guard let value = try? P256.Signing.ECDSASignature(derRepresentation: raw), value.derRepresentation == raw else { throw PluginRelayEnrollmentError.invalidSignature }
        let key = try PluginRelayEnrollmentCrypto.publicKey(role == .phone ? context.phonePublicKey : context.watchPublicKey)
        guard key.isValidSignature(value, for: try canonicalBytes(now: now)) else { throw PluginRelayEnrollmentError.invalidSignature }
    }
}

/// This transaction signs only a fresh paired-phone challenge for the known
/// context. The response cannot authorize another account/pair/route/local epoch.
/// An expired initial enrollment transaction is never reused for renewal.
public final class PluginRelayWatchResumeTransaction: @unchecked Sendable {
    public let watchSignature: String
    public let challengeID: UUID
    private let lock = NSLock()
    private let context: PluginRelayWatchResumeContext
    private let deadline: TimeInterval
    private var active = true
    public init(challenge: PluginRelayWatchResumeChallenge, phoneSignature: String,
                expected: PluginRelayWatchResumeContext, watchKey: P256.Signing.PrivateKey, now: Date) throws {
        guard challenge.context == expected else { throw PluginRelayEnrollmentError.wrongPeer }
        try challenge.verify(phoneSignature, role: .phone, now: now)
        watchSignature = try challenge.sign(role: .watch, key: watchKey, now: now)
        context = expected; challengeID = challenge.challengeID
        deadline = ProcessInfo.processInfo.systemUptime + min(30, Double(challenge.expiresAt) - now.timeIntervalSince1970)
    }
    public func revoke() { lock.lock(); defer { lock.unlock() }; active = false }
    public func consume(_ compact: String, trust: PluginRelayBrokerTrust, now: Date) throws -> PluginRelayVerifiedWatchBootstrap {
        lock.lock(); defer { lock.unlock() }
        guard active, ProcessInfo.processInfo.systemUptime < deadline, trust.issuer == context.issuer else { throw PluginRelayEnrollmentError.expired }
        active = false
        let expected = try PluginRelayWatchBootstrapExpectation(provider: context.fence.binding.route.provider, localEpoch: context.fence.localEpoch,
            phoneKeySHA256: PluginRelayEnrollmentCrypto.fingerprint(PluginRelayEnrollmentCrypto.publicKey(context.phonePublicKey).derRepresentation),
            watchKeySHA256: PluginRelayEnrollmentCrypto.fingerprint(PluginRelayEnrollmentCrypto.publicKey(context.watchPublicKey).derRepresentation))
        let grant = try PluginRelayWatchBootstrapVerifier.verify(compact, trust: trust, expected: expected, now: now)
        try context.matches(grant); return grant
    }
}
