#if !os(watchOS)
import Foundation
import CryptoKit

public enum PluginRelayContinuityError: Error, Equatable, Sendable {
    case explicitConnectRequired, rotationUncertain, expired, invalidRecord, authorityChanged, busy, storageUnavailable
}
public protocol PluginRelayContinuityPersistence: Sendable {
    func read(maximumBytes: Int) throws -> Data?
    func writeAtomically(_ data: Data) throws
    func remove() throws
}

/// Secret phone-only checkpoint. Decoding it grants no account/peer authority.
/// A restored checkpoint must rotate online and pass a fresh actual Watch proof
/// and current pinned broker grant before native admission is restored.
struct PluginRelayContinuityRecord: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    enum State: String, Codable, Sendable { case ready, rotationUncertain }
    var state: State
    var accessToken: String
    var accessExpiresAt: Int64
    var refreshToken: String
    var refreshExpiresAt: Int64
    let applicationExpiresAt: Int64
    let provider: CloudAgentProvider
    let enrollmentID: UUID
    let phoneDeviceID: String
    let accountGeneration: UUID
    let pairingGeneration: UUID
    let localEpoch: UUID
    let phoneKeySHA256: String
    let watchKeySHA256: String
    let watchPublicKey: String
    let origin: String
    let identity: CloudAgentVerifiedIdentity
    var fence: PluginRelayFence?
    var context: PluginRelayHTTPContext { .init(provider: provider, accountGeneration: accountGeneration, pairingEpoch: pairingGeneration, localEpoch: localEpoch) }
    var description: String { "PluginRelayContinuityRecord(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["provider": provider, "state": state]) }
    func validate(origin: URL, registration: CloudAgentIdentityConfiguration, phoneKey: P256.Signing.PrivateKey, now: Date) throws {
        guard self.origin == origin.absoluteString, provider == registration.registration.provider,
              identity.provider == provider, identity.isCurrent(for: registration, now: identity.verifiedAt),
              phoneKeySHA256 == PluginRelayEnrollmentCrypto.fingerprint(phoneKey.publicKey.derRepresentation),
              watchKeySHA256 == PluginRelayEnrollmentCrypto.fingerprint(try PluginRelayEnrollmentCrypto.publicKey(watchPublicKey).derRepresentation),
              (try? PluginRelayEnrollmentCrypto.decodeBase64URL(accessToken, maximum: 32).count) == 32,
              (try? PluginRelayEnrollmentCrypto.decodeBase64URL(refreshToken, maximum: 32).count) == 32,
              applicationExpiresAt > 604_800, refreshExpiresAt <= applicationExpiresAt,
              accessExpiresAt <= applicationExpiresAt, refreshExpiresAt > 0, accessExpiresAt > 0,
              applicationExpiresAt <= (try PluginRelayEnrollmentCrypto.unixSeconds(now)) + 604_800 + 30,
              PluginRelayEnrollmentCrypto.ascii(phoneDeviceID, maximum: 256) else { throw PluginRelayContinuityError.invalidRecord }
        if let fence {
            try fence.binding.route.validate()
            guard fence.binding.route.provider == provider, fence.binding.route.accountGeneration == accountGeneration,
                  fence.binding.pairingEpoch == pairingGeneration, fence.localEpoch == localEpoch else { throw PluginRelayContinuityError.invalidRecord }
        }
    }
}

/// Public expectation only. A typed descriptor read from Keychain is not a grant.
public struct PluginRelayPhoneContinuityDescriptor: Sendable {
    public let provider: CloudAgentProvider
    public let enrollmentID: UUID
    public let phoneDeviceID: String
    public let fence: PluginRelayFence
    public let phoneKeySHA256: String
    public let watchKeySHA256: String
    public let watchPublicKey: String
    public let applicationSessionExpiresAt: Date
    public let identity: CloudAgentVerifiedIdentity
    init(_ record: PluginRelayContinuityRecord, fence: PluginRelayFence) {
        provider = record.provider; enrollmentID = record.enrollmentID; phoneDeviceID = record.phoneDeviceID
        self.fence = fence; phoneKeySHA256 = record.phoneKeySHA256; watchKeySHA256 = record.watchKeySHA256
        watchPublicKey = record.watchPublicKey; applicationSessionExpiresAt = Date(timeIntervalSince1970: Double(record.applicationExpiresAt))
        identity = record.identity
    }
}
public struct PluginRelayContinuityRotationInput: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let record: PluginRelayContinuityRecord
    init(_ record: PluginRelayContinuityRecord) { self.record = record }
    public var description: String { "PluginRelayContinuityRotationInput(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public struct PluginRelayVerifiedContinuityRotation: Sendable {
    let record: PluginRelayContinuityRecord
    init(_ record: PluginRelayContinuityRecord) { self.record = record }
}
/// REQUIRED actual trusted HTTPS implementation; no metadata/default verifier.
public protocol PluginRelayContinuityTransport: Sendable {
    func rotate(_ input: PluginRelayContinuityRotationInput, phoneKey: P256.Signing.PrivateKey) async throws -> PluginRelayVerifiedContinuityRotation
    func routeGrant(using session: PluginRelayEnrolledPhoneSession, fence: PluginRelayFence) async throws -> String
}

/// Only this controller can construct a verified same-fence restoration result,
/// after online authority and fresh native peer checks plus a pinned fresh JWS.
public struct PluginRelayVerifiedPhoneRestoration: Sendable {
    public let session: PluginRelayEnrolledPhoneSession
    public let fence: PluginRelayFence
    public let compactGrant: String
    public let watchGrant: PluginRelayVerifiedWatchBootstrap
    public let identity: CloudAgentVerifiedIdentity
    fileprivate init(session: PluginRelayEnrolledPhoneSession, fence: PluginRelayFence, compactGrant: String, watchGrant: PluginRelayVerifiedWatchBootstrap, identity: CloudAgentVerifiedIdentity) {
        self.session = session; self.fence = fence; self.compactGrant = compactGrant; self.watchGrant = watchGrant; self.identity = identity
    }
}

/// One owner per provider/enrollment. Persist-before-dispatch rotation is single
/// owner and never retries an uncertain credential. Durable message/reply stores
/// are separate and untouched. The caller pauses its existing route owner before
/// refreshAuthority, then resumes exactly that owner/fence on success.
public actor PluginRelayPhoneContinuityController {
    private let persistence: any PluginRelayContinuityPersistence
    private let transport: any PluginRelayContinuityTransport
    private let origin: URL
    private let registration: CloudAgentIdentityConfiguration
    private let phoneKey: P256.Signing.PrivateKey
    private let trust: PluginRelayBrokerTrust
    private var record: PluginRelayContinuityRecord?
    private var liveSession: PluginRelayEnrolledPhoneSession?
    private var refreshing = false
    private var terminal = false
    public init(persistence: any PluginRelayContinuityPersistence, transport: any PluginRelayContinuityTransport,
                trustedOrigin: URL, registration: CloudAgentIdentityConfiguration, phoneKey: P256.Signing.PrivateKey,
                trust: PluginRelayBrokerTrust) throws {
        guard trust.issuer == trustedOrigin.absoluteString else { throw PluginRelayContinuityError.authorityChanged }
        self.persistence = persistence; self.transport = transport; origin = trustedOrigin
        self.registration = registration; self.phoneKey = phoneKey; self.trust = trust
    }
    public func install(_ enrollment: PluginRelayNativeEnrollment) throws {
        guard !terminal, !refreshing else { throw PluginRelayContinuityError.busy }
        let value = enrollment.continuity
        try value.validate(origin: origin, registration: registration, phoneKey: phoneKey, now: Date())
        try save(value); record = value; liveSession = enrollment.session
    }
    public func bind(_ fence: PluginRelayFence) throws {
        guard !terminal, !refreshing else { throw PluginRelayContinuityError.busy }
        var value = try load()
        guard value.fence == nil || value.fence == fence,
              fence.binding.route.provider == value.provider, fence.binding.route.accountGeneration == value.accountGeneration,
              fence.binding.pairingEpoch == value.pairingGeneration, fence.localEpoch == value.localEpoch else { throw PluginRelayContinuityError.authorityChanged }
        value.fence = fence; try save(value); record = value
    }
    /// A public descriptor is only enough to prepare a fresh key-possession
    /// challenge. It does not install any HTTP/coordinator/Watch authority.
    public func descriptor() throws -> PluginRelayPhoneContinuityDescriptor {
        let value = try load()
        guard let fence = value.fence else { throw PluginRelayContinuityError.explicitConnectRequired }
        return .init(value, fence: fence)
    }
    public func refreshAuthority(from peer: any PluginRelayNativePeerVerifier) async throws -> PluginRelayVerifiedPhoneRestoration {
        guard !terminal else { throw PluginRelayContinuityError.explicitConnectRequired }
        guard !refreshing else { throw PluginRelayContinuityError.busy }
        refreshing = true; defer { refreshing = false }
        try Task.checkCancellation(); try peer.validateCurrent()
        var value = try load()
        guard let fence = value.fence else { throw PluginRelayContinuityError.explicitConnectRequired }
        let cold = liveSession == nil
        let currentUnixSeconds = try PluginRelayEnrollmentCrypto.unixSeconds(Date())
        if cold || value.accessExpiresAt <= currentUnixSeconds + 60 {
            // This save MUST complete before dispatch. A failure/timeout/cancel
            // after the marker leaves no reusable refresh credential.
            value.state = .rotationUncertain; try save(value); record = value
            liveSession?.suspendForContinuity()
            let rotation: PluginRelayVerifiedContinuityRotation
            do { rotation = try await transport.rotate(.init(value), phoneKey: phoneKey) }
            catch { throw PluginRelayContinuityError.rotationUncertain }
            try Task.checkCancellation(); guard !terminal else { throw PluginRelayContinuityError.explicitConnectRequired }
            try peer.validateCurrent()
            try sameContext(rotation.record, value)
            var replacement = rotation.record; replacement.state = .ready
            do { try save(replacement) }
            catch { throw PluginRelayContinuityError.rotationUncertain }
            value = replacement; record = replacement
        }
        guard !terminal else { throw PluginRelayContinuityError.explicitConnectRequired }
        try peer.validateCurrent()
        let session: PluginRelayEnrolledPhoneSession
        if let current = liveSession {
            try current.applyContinuity(value, peer: peer); session = current
        } else {
            session = PluginRelayEnrolledPhoneSession(context: value.context, trustedOrigin: origin,
                actualAgentReference: value.provider == .dot ? "Dot" : "Grok Bot", token: value.accessToken,
                expiry: Date(timeIntervalSince1970: Double(value.accessExpiresAt)), enrollmentID: value.enrollmentID,
                phoneDeviceID: value.phoneDeviceID, phoneKey: phoneKey, watchKeySHA256: value.watchKeySHA256,
                peer: peer, applicationSessionExpiresAt: Date(timeIntervalSince1970: Double(value.applicationExpiresAt)))
            try session.bind(fence)
        }
        let compact = try await transport.routeGrant(using: session, fence: fence)
        try Task.checkCancellation(); guard !terminal else { throw PluginRelayContinuityError.explicitConnectRequired }
        try peer.validateCurrent(); try session.validateSession()
        let expected = try PluginRelayWatchBootstrapExpectation(provider: value.provider, localEpoch: value.localEpoch,
            phoneKeySHA256: value.phoneKeySHA256, watchKeySHA256: value.watchKeySHA256)
        let grant = try PluginRelayWatchBootstrapVerifier.verify(compact, trust: trust, expected: expected, now: Date())
        guard grant.fence == fence, grant.enrollmentID == value.enrollmentID, grant.phoneDeviceID == value.phoneDeviceID else {
            session.suspendForContinuity(); throw PluginRelayContinuityError.authorityChanged
        }
        liveSession = session
        return .init(session: session, fence: fence, compactGrant: compact, watchGrant: grant, identity: value.identity)
    }
    public func invalidate(removeCredential: Bool) throws {
        terminal = true; liveSession?.revokeLocal(); liveSession = nil; record = nil
        if removeCredential { do { try persistence.remove() } catch { throw PluginRelayContinuityError.storageUnavailable } }
    }
    private func load() throws -> PluginRelayContinuityRecord {
        guard !terminal else { throw PluginRelayContinuityError.explicitConnectRequired }
        let value: PluginRelayContinuityRecord
        if let record { value = record }
        else {
            guard let bytes = try persistence.read(maximumBytes: 32_768), !bytes.isEmpty, bytes.count <= 32_768,
                  let decoded = try? JSONDecoder().decode(PluginRelayContinuityRecord.self, from: bytes) else {
                throw PluginRelayContinuityError.explicitConnectRequired
            }
            value = decoded
        }
        try value.validate(origin: origin, registration: registration, phoneKey: phoneKey, now: Date())
        guard value.state == .ready else { throw PluginRelayContinuityError.rotationUncertain }
        guard value.applicationExpiresAt > (try PluginRelayEnrollmentCrypto.unixSeconds(Date())),
              value.refreshExpiresAt > (try PluginRelayEnrollmentCrypto.unixSeconds(Date())) else { throw PluginRelayContinuityError.expired }
        return value
    }
    private func save(_ value: PluginRelayContinuityRecord) throws {
        let bytes = try JSONEncoder().encode(value)
        guard bytes.count <= 32_768 else { throw PluginRelayContinuityError.storageUnavailable }
        do { try persistence.writeAtomically(bytes) } catch { throw PluginRelayContinuityError.storageUnavailable }
    }
    private func sameContext(_ new: PluginRelayContinuityRecord, _ old: PluginRelayContinuityRecord) throws {
        try new.validate(origin: origin, registration: registration, phoneKey: phoneKey, now: Date())
        guard new.provider == old.provider, new.context == old.context, new.enrollmentID == old.enrollmentID,
              new.phoneDeviceID == old.phoneDeviceID, new.phoneKeySHA256 == old.phoneKeySHA256,
              new.watchKeySHA256 == old.watchKeySHA256, new.watchPublicKey == old.watchPublicKey,
              new.fence == old.fence, new.origin == old.origin, new.identity == old.identity,
              new.applicationExpiresAt == old.applicationExpiresAt, new.refreshToken != old.refreshToken,
              new.accessToken != old.accessToken else { throw PluginRelayContinuityError.authorityChanged }
    }
}
#endif
