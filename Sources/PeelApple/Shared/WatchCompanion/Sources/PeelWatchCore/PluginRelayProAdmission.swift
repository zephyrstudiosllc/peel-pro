import Foundation

public enum PluginRelayProError: Error, Equatable, Sendable {
    case required, expired, denied, unavailable, invalidResponse, contextChanged, superseded
}

/// Public context is correlation only. Constructing this value grants nothing.
public struct PluginRelayProBinding: Equatable, Sendable {
    public let provider: CloudAgentProvider
    public let accountGeneration: UUID
    public let enrollmentID: UUID
    public let phoneDeviceID: String
    public let phoneKeySHA256: String
    public let watchKeySHA256: String
    public let pairingGeneration: UUID
    public let localEpoch: UUID
    public let route: PluginRelayReference?
    public let applicationSessionExpiresAt: Int64

    init(provider: CloudAgentProvider, accountGeneration: UUID, enrollmentID: UUID,
         phoneDeviceID: String, phoneKeySHA256: String, watchKeySHA256: String,
         pairingGeneration: UUID, localEpoch: UUID, route: PluginRelayReference?,
         applicationSessionExpiresAt: Int64) {
        self.provider = provider; self.accountGeneration = accountGeneration; self.enrollmentID = enrollmentID
        self.phoneDeviceID = phoneDeviceID; self.phoneKeySHA256 = phoneKeySHA256; self.watchKeySHA256 = watchKeySHA256
        self.pairingGeneration = pairingGeneration; self.localEpoch = localEpoch; self.route = route
        self.applicationSessionExpiresAt = applicationSessionExpiresAt
    }
    func adding(_ fence: PluginRelayFence) throws -> Self {
        guard fence.binding.route.provider == provider, fence.binding.route.accountGeneration == accountGeneration,
              fence.binding.pairingEpoch == pairingGeneration, fence.localEpoch == localEpoch,
              route == nil || route == fence.binding.route else { throw PluginRelayProError.contextChanged }
        return .init(provider: provider, accountGeneration: accountGeneration, enrollmentID: enrollmentID,
            phoneDeviceID: phoneDeviceID, phoneKeySHA256: phoneKeySHA256, watchKeySHA256: watchKeySHA256,
            pairingGeneration: pairingGeneration, localEpoch: localEpoch, route: fence.binding.route,
            applicationSessionExpiresAt: applicationSessionExpiresAt)
    }
    func matches(_ fence: PluginRelayFence) -> Bool {
        route == fence.binding.route && pairingGeneration == fence.binding.pairingEpoch && localEpoch == fence.localEpoch
    }
}

/// Supplies ONLY verified Apple transaction JWS for this live bounded exchange.
/// Implementations must not purchase, restore, prompt or infer a local Pro flag.
public protocol PluginRelayProEvidenceSource: Sendable {
    func signedTransactions(isCurrent: @escaping @Sendable () -> Bool) async throws -> [String]
}

public struct PluginRelayProChallenge: Sendable {
    public let requestID: UUID
    public let nonce: String
    public let pairingID: UUID
    public let sessionID: UUID
    public let expiresAt: Int64
    public let binding: PluginRelayProBinding
    let monotonicDeadline: TimeInterval
}

struct PluginRelayProReadback: Sendable {
    let leaseID: UUID?
    let verifiedAt: Int64
    let expiresAt: Int64
    let binding: PluginRelayProBinding
    let verified: Bool
}

/// A non-Codable, unforgeable local handle. Only the originating live registry
/// can admit it. Its critical section includes the real persistence/read/output
/// effect, so known withdrawal waits for an admitted effect and closes the next.
public struct PluginRelayProPermit: Sendable {
    let id = UUID()
    fileprivate let registry: PluginRelayProRegistry
    fileprivate let epoch: UUID
    fileprivate let binding: PluginRelayProBinding
    public let expiresAt: Date
    fileprivate let monotonicDeadline: TimeInterval
    public func withAdmission<T>(for fence: PluginRelayFence, _ body: () throws -> T) throws -> T {
        guard binding.matches(fence) else { throw PluginRelayProError.contextChanged }
        return try registry.withAdmission(self, body)
    }
    func withAdmission<T>(_ body: () throws -> T) throws -> T { try registry.withAdmission(self, body) }
    public func validate(for fence: PluginRelayFence) throws { try withAdmission(for: fence) {} }
}

/// Retains the captured paid permit through actor hops to the actual native WC
/// callback. The caller submits inside this critical section, not after merely
/// checking a Boolean. Only identity-only cleanup responses may omit a permit.
public struct PluginRelayPhoneOutput: Sendable {
    private let bytes: Data
    private let permit: PluginRelayProPermit?
    init(bytes: Data, permit: PluginRelayProPermit?) { self.bytes = bytes; self.permit = permit }
    public func submit(_ callback: (Data) -> Void) throws {
        if let permit { try permit.withAdmission { callback(bytes) } }
        else { callback(bytes) }
    }
    func copyBytes() throws -> Data {
        var value = Data(); try submit { value = $0 }; return value
    }
}

/// No serialization, persisted verdict, Boolean fallback or public grant method.
/// The broker client installs a lease only from its own authenticated HTTPS
/// operation after matching the challenge and the complete live session context.
final class PluginRelayProRegistry: @unchecked Sendable {
    private struct Lease {
        let id: UUID
        var binding: PluginRelayProBinding
        let expiry: Date
        let deadline: TimeInterval
    }
    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private let uptime: @Sendable () -> TimeInterval
    private var epoch = UUID()
    private var pending: UUID?
    private var lease: Lease?
    private var withdrawalRevision: UUID?
    init(now: @escaping @Sendable () -> Date = Date.init,
         uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now; self.uptime = uptime
    }
    func begin() throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        guard withdrawalRevision == nil else { throw PluginRelayProError.superseded }
        let id = UUID(); pending = id; return id
    }
    func isPending(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }; return pending == id
    }
    func finish(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }; if pending == id { pending = nil }
    }
    func install(_ result: PluginRelayProReadback, operation: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard pending == operation, withdrawalRevision == nil else { throw PluginRelayProError.superseded }
        pending = nil
        guard result.verified, let id = result.leaseID else {
            epoch = UUID(); lease = nil; throw PluginRelayProError.denied
        }
        let expiry = Date(timeIntervalSince1970: Double(result.expiresAt))
        let remaining = expiry.timeIntervalSince(max(now(), Date(timeIntervalSince1970: Double(result.verifiedAt))))
        guard remaining > 0, remaining <= 300,
              result.expiresAt <= result.binding.applicationSessionExpiresAt else { throw PluginRelayProError.expired }
        // A fresh proof is not a revocation. Preserve uninterrupted same-context
        // admissions, whose permits still retain their ORIGINAL deadlines.
        if lease?.binding != result.binding || (lease.flatMap { try? validate($0) }) == nil { epoch = UUID() }
        lease = .init(id: id, binding: result.binding, expiry: expiry, deadline: uptime() + min(300, remaining))
    }
    func bind(_ fence: PluginRelayFence) throws {
        lock.lock(); defer { lock.unlock() }
        guard var value = lease else { return } // Identity restore is not paid admission.
        value.binding = try value.binding.adding(fence); lease = value
    }
    func permit(binding: PluginRelayProBinding, maximumSeconds: TimeInterval = 20) throws -> PluginRelayProPermit {
        lock.lock(); defer { lock.unlock() }
        guard let value = lease else { throw PluginRelayProError.required }
        guard value.binding == binding else { throw PluginRelayProError.contextChanged }
        try validate(value)
        guard maximumSeconds.isFinite, maximumSeconds > 0 else { throw PluginRelayProError.invalidResponse }
        let duration = min(20, maximumSeconds)
        return .init(registry: self, epoch: epoch, binding: binding,
            expiresAt: min(value.expiry, now().addingTimeInterval(duration)),
            monotonicDeadline: min(value.deadline, uptime() + duration))
    }
    func hasLease(binding: PluginRelayProBinding, minimumRemaining: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let value = lease, value.binding == binding, (try? validate(value)) != nil else { return false }
        return value.expiry.timeIntervalSince(now()) > minimumRemaining && value.deadline - uptime() > minimumRemaining
    }
    /// Refreshing application/peer authority retires old action/output handles
    /// without extending or replacing the existing finite commerce lease.
    func retirePermits() {
        lock.lock(); defer { lock.unlock() }; epoch = UUID(); pending = nil
    }
    @discardableResult
    func withdraw(needsRemoteAcknowledgement: Bool = false) -> UUID? {
        lock.lock(); defer { lock.unlock() }; epoch = UUID(); pending = nil; lease = nil
        if needsRemoteAcknowledgement { withdrawalRevision = UUID() }
        return withdrawalRevision
    }
    func pendingWithdrawal() -> UUID? {
        lock.lock(); defer { lock.unlock() }; return withdrawalRevision
    }
    func acknowledgeWithdrawal(_ revision: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard withdrawalRevision == revision else { throw PluginRelayProError.superseded }
        withdrawalRevision = nil
    }
    func withPendingSubmission(_ id: UUID, _ body: () -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard pending == id, withdrawalRevision == nil else { throw PluginRelayProError.superseded }
        body()
    }
    func withWithdrawalSubmission(_ revision: UUID, _ body: () -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard withdrawalRevision == revision else { throw PluginRelayProError.superseded }
        body()
    }
    func deny(_ permit: PluginRelayProPermit) {
        lock.lock(); defer { lock.unlock() }
        guard permit.registry === self, permit.epoch == epoch else { return }
        epoch = UUID(); pending = nil; lease = nil
    }
    fileprivate func withAdmission<T>(_ permit: PluginRelayProPermit, _ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard permit.registry === self, permit.epoch == epoch, let value = lease,
              value.binding == permit.binding else { throw PluginRelayProError.superseded }
        try validate(value)
        guard permit.expiresAt > now(), uptime() < permit.monotonicDeadline else { throw PluginRelayProError.expired }
        return try body()
    }
    private func validate(_ value: Lease) throws {
        let wall = now(), monotonic = uptime()
        guard wall.timeIntervalSince1970.isFinite, monotonic.isFinite,
              value.expiry > wall, monotonic < value.deadline else {
            // An observed expiry is terminal for this epoch. A later grant must
            // never revive an old queued effect, even after wall-clock rollback.
            epoch = UUID(); lease = nil; throw PluginRelayProError.expired
        }
    }
}

#if !os(watchOS)
extension PluginRelayProPermit: PluginRelayHTTPSubmissionAdmission {
    func submit(_ body: @Sendable () -> Void) throws { try withAdmission { body() } }
    func closeOnTrustedDenial() { registry.deny(self) }
    func validateHTTP(context: PluginRelayHTTPContext, routeID: String?, generation: String?) throws {
        guard binding.provider == context.provider, binding.accountGeneration == context.accountGeneration,
              binding.pairingGeneration == context.pairingEpoch, binding.localEpoch == context.localEpoch else {
            throw PluginRelayProError.contextChanged
        }
        if let routeID {
            guard binding.route?.routeID == routeID,
                  generation == nil || generation == binding.route?.generation.uuidString.lowercased() else { throw PluginRelayProError.contextChanged }
        } else if binding.route != nil { throw PluginRelayProError.contextChanged }
        try withAdmission {}
    }
}
struct PluginRelayProPendingSubmission: PluginRelayHTTPSubmissionAdmission {
    let registry: PluginRelayProRegistry
    let operation: UUID
    func submit(_ body: @Sendable () -> Void) throws { try registry.withPendingSubmission(operation, body) }
}
struct PluginRelayProWithdrawalSubmission: PluginRelayHTTPSubmissionAdmission {
    let registry: PluginRelayProRegistry
    let revision: UUID
    func submit(_ body: @Sendable () -> Void) throws { try registry.withWithdrawalSubmission(revision, body) }
}
enum PluginRelayProWire {
    static func challenge(_ value: PluginRelayJSON, expected: PluginRelayProBinding,
                          now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> PluginRelayProChallenge {
        guard now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 >= 0,
              now.timeIntervalSince1970 < 9_000_000_000_000_000, uptime.isFinite else { throw PluginRelayProError.invalidResponse }
        let outer = try value.object(keys: ["schema", "challenge", "binding"])
        guard try outer.required("schema").integer() == 1 else { throw PluginRelayProError.invalidResponse }
        let binding = try binding(outer.required("binding")); guard binding == expected else { throw PluginRelayProError.contextChanged }
        let fields = try outer.required("challenge").object(keys: ["type", "requestId", "nonce", "pairingId", "sessionId", "expiresAt"])
        let expiry = try fields.required("expiresAt").integer(), nonce = try fields.required("nonce").string()
        guard try fields.required("type").string() == "proEntitlementChallenge",
              try uuid(fields.required("pairingId")) == expected.enrollmentID,
              nonce.utf8.count == 44, let bytes = Data(base64Encoded: nonce), bytes.count == 32,
              bytes.base64EncodedString() == nonce,
              expiry > Int64(now.timeIntervalSince1970.rounded(.down)),
              // Accept at most 30 seconds of server clock skew; the local
              // monotonic challenge lifetime is still capped at 30 seconds.
              Double(expiry) <= now.timeIntervalSince1970 + 60,
              expiry <= expected.applicationSessionExpiresAt, uptime.isFinite else { throw PluginRelayProError.invalidResponse }
        return .init(requestID: try uuid(fields.required("requestId")), nonce: nonce,
            pairingID: expected.enrollmentID, sessionID: try uuid(fields.required("sessionId")), expiresAt: expiry,
            binding: binding, monotonicDeadline: uptime + min(30, Double(expiry) - now.timeIntervalSince1970))
    }
    static func readback(_ value: PluginRelayJSON, challenge: PluginRelayProChallenge,
                         now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> PluginRelayProReadback {
        let fields = try value.object(keys: ["schema", "requestId", "sessionId", "binding", "state", "reason", "leaseID", "verifiedAt", "expiresAt"])
        let binding = try binding(fields.required("binding")), verifiedAt = try fields.required("verifiedAt").integer()
        let expiry = try fields.required("expiresAt").integer(), state = try fields.required("state").string(), reason = try fields.required("reason").string()
        guard try fields.required("schema").integer() == 1,
              try uuid(fields.required("requestId")) == challenge.requestID,
              try uuid(fields.required("sessionId")) == challenge.sessionID,
              binding == challenge.binding, now.timeIntervalSince1970.isFinite, uptime.isFinite,
              uptime < challenge.monotonicDeadline, Double(challenge.expiresAt) > now.timeIntervalSince1970,
              verifiedAt >= 0, abs(now.timeIntervalSince1970 - Double(verifiedAt)) <= 30 else { throw PluginRelayProError.contextChanged }
        let leaseID: UUID?
        if case .null = try fields.required("leaseID") { leaseID = nil } else { leaseID = try uuid(fields.required("leaseID")) }
        if state == "verified" {
            guard reason == "active", leaseID != nil, expiry > verifiedAt, expiry - verifiedAt <= 300,
                  Double(expiry) > now.timeIntervalSince1970, expiry <= binding.applicationSessionExpiresAt else { throw PluginRelayProError.invalidResponse }
        } else {
            guard state == "denied", ["no_entitlement", "invalid_evidence", "revoked", "expired", "unsupported_environment"].contains(reason),
                  leaseID == nil, expiry == verifiedAt else { throw PluginRelayProError.invalidResponse }
        }
        return .init(leaseID: leaseID, verifiedAt: verifiedAt, expiresAt: expiry, binding: binding, verified: state == "verified")
    }
    private static func binding(_ value: PluginRelayJSON) throws -> PluginRelayProBinding {
        let fields = try value.object(keys: ["provider", "accountGeneration", "enrollmentID", "phoneDeviceID", "phoneKeySHA256", "watchKeySHA256", "pairingGeneration", "localEpoch", "routeID", "routeGeneration", "applicationSessionExpiresAt"])
        guard let provider = CloudAgentProvider(rawValue: try fields.required("provider").string()) else { throw PluginRelayProError.invalidResponse }
        let account = try uuid(fields.required("accountGeneration")), device = try fields.required("phoneDeviceID").string()
        let phoneHash = try fields.required("phoneKeySHA256").string(), watchHash = try fields.required("watchKeySHA256").string()
        guard PluginRelayEnrollmentCrypto.ascii(device, maximum: 256), validHash(phoneHash), validHash(watchHash) else { throw PluginRelayProError.invalidResponse }
        let route: PluginRelayReference?
        if case .null = try fields.required("routeID") {
            guard case .null = try fields.required("routeGeneration") else { throw PluginRelayProError.invalidResponse }; route = nil
        } else {
            route = try .init(provider: provider, routeID: fields.required("routeID").string(),
                generation: uuid(fields.required("routeGeneration")), accountGeneration: account)
        }
        let appExpiry = try fields.required("applicationSessionExpiresAt").integer()
        guard appExpiry > 0 else { throw PluginRelayProError.invalidResponse }
        return .init(provider: provider, accountGeneration: account, enrollmentID: try uuid(fields.required("enrollmentID")),
            phoneDeviceID: device, phoneKeySHA256: phoneHash, watchKeySHA256: watchHash,
            pairingGeneration: try uuid(fields.required("pairingGeneration")), localEpoch: try uuid(fields.required("localEpoch")),
            route: route, applicationSessionExpiresAt: appExpiry)
    }
    private static func uuid(_ value: PluginRelayJSON) throws -> UUID {
        let raw = try value.string()
        guard let id = UUID(uuidString: raw), id.uuidString.lowercased() == raw else { throw PluginRelayProError.invalidResponse }; return id
    }
    private static func validHash(_ raw: String) -> Bool {
        raw.utf8.count == 64 && raw.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
#endif
