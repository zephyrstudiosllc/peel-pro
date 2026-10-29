import Foundation

/// In-memory admission only. The authority transport is the only producer of
/// decisions; peer capability flags and peer-relayed verdicts never enter here.
nonisolated struct PeelHostProAdmissionState {
    struct Binding: Equatable, Sendable {
        let pairingID: String
        let generation: UInt64
        let sessionID: String
    }
    struct Clock: Sendable {
        let wall: TimeInterval
        let monotonic: TimeInterval
        var isValid: Bool { wall.isFinite && monotonic.isFinite && monotonic >= 0 }
    }
    struct Operation: Equatable, Sendable {
        let id: UUID
        let epoch: UUID
        let binding: Binding
        let challenge: PeelProEntitlementChallenge
        let startedAt: TimeInterval
        let deadline: TimeInterval
    }
    struct Lease: Sendable {
        let binding: Binding
        let wallExpiry: TimeInterval
        let monotonicExpiry: TimeInterval
    }

    private(set) var binding: Binding?
    private(set) var pending: Operation?
    private(set) var verifying: Operation?
    private(set) var lease: Lease?
    private(set) var epoch = UUID()

    mutating func bind(pairingID: String, generation: UInt64, sessionID: String = UUID().uuidString) {
        invalidate()
        guard !pairingID.isEmpty, pairingID.utf8.count <= 256,
              UUID(uuidString: sessionID) != nil else { return }
        binding = Binding(pairingID: pairingID, generation: generation, sessionID: sessionID)
    }

    mutating func invalidate() {
        epoch = UUID()
        binding = nil
        pending = nil
        verifying = nil
        lease = nil
    }

    mutating func challenge(now: Clock, nonce: String) -> Operation? {
        guard now.isValid, let binding, Self.isCanonicalNonce(nonce) else { return nil }
        // Replacement fences any prior completion without extending a lease.
        epoch = UUID()
        verifying = nil
        let message = PeelProEntitlementChallenge(requestId: UUID().uuidString,
            nonce: nonce, pairingId: binding.pairingID, sessionId: binding.sessionID,
            expiresAt: now.wall + 30)
        let operation = Operation(id: UUID(), epoch: epoch, binding: binding,
            challenge: message, startedAt: now.wall, deadline: now.monotonic + 30)
        pending = operation
        return operation
    }

    mutating func consume(_ proof: PeelProEntitlementProof, generation: UInt64, now: Clock) -> Operation? {
        guard now.isValid, let operation = pending,
              binding == operation.binding, epoch == operation.epoch,
              generation == operation.binding.generation,
              proof.type == "proEntitlementProof",
              proof.requestId == operation.challenge.requestId,
              proof.nonce == operation.challenge.nonce,
              proof.sessionId == operation.binding.sessionID,
              proof.pairingId == operation.binding.pairingID,
              now.wall >= operation.startedAt - 5,
              now.wall < operation.challenge.expiresAt,
              now.monotonic < operation.deadline else { return nil }
        // A matching response uses the nonce once, even if its evidence is bad.
        pending = nil
        guard proof.signedTransactions.count <= 4,
              proof.signedTransactions.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 32_768 }),
              proof.signedTransactions.reduce(0, { $0 + $1.utf8.count }) <= 131_072 else {
            lease = nil
            return nil
        }
        verifying = operation
        return operation
    }

    func isCurrent(_ operation: Operation, now: Clock) -> Bool {
        now.isValid && binding == operation.binding && epoch == operation.epoch &&
            verifying == operation && now.monotonic < operation.deadline &&
            now.wall >= operation.startedAt - 5 && now.wall < operation.challenge.expiresAt
    }

    mutating func complete(_ response: PeelCommerceAuthorityResponse, operation: Operation, now: Clock) -> Bool {
        guard isCurrent(operation, now: now) else { return false }
        verifying = nil
        guard response.matches(operation.challenge),
              response.verifiedAt >= operation.startedAt - 5,
              response.verifiedAt <= now.wall + 5,
              now.wall - response.verifiedAt <= 30,
              response.expiresAt >= response.verifiedAt,
              response.expiresAt <= response.verifiedAt + 300 else {
            lease = nil
            return false
        }
        guard response.decision == "granted" else {
            lease = nil
            return false
        }
        let duration = min(300, response.expiresAt - max(now.wall, response.verifiedAt))
        guard duration > 0 else { lease = nil; return false }
        lease = Lease(binding: operation.binding, wallExpiry: response.expiresAt,
            monotonicExpiry: now.monotonic + duration)
        return true
    }

    mutating func unavailable(operation: Operation) {
        guard verifying == operation, epoch == operation.epoch else { return }
        verifying = nil // An outage cannot create or extend a previous lease.
    }

    mutating func expirePending(_ operation: Operation) {
        if pending == operation { pending = nil }
        if verifying == operation { verifying = nil }
    }

    mutating func expireLease(now: Clock) -> Bool {
        guard let lease, !now.isValid || now.wall >= lease.wallExpiry || now.monotonic >= lease.monotonicExpiry else { return false }
        self.lease = nil
        return true
    }

    func allows(pairingID: String, generation: UInt64, now: Clock) -> Bool {
        guard now.isValid, let binding, let lease,
              lease.binding == binding, binding.pairingID == pairingID,
              binding.generation == generation else { return false }
        return now.wall < lease.wallExpiry && now.monotonic < lease.monotonicExpiry
    }

    static func isCanonicalNonce(_ value: String) -> Bool {
        guard let data = Data(base64Encoded: value), data.count == 32 else { return false }
        return data.base64EncodedString() == value
    }
}
