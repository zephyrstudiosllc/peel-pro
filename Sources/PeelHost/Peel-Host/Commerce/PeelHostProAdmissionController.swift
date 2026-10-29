import Foundation
import Security

@MainActor
final class PeelHostProAdmissionController {
    private var state = PeelHostProAdmissionState()
    private var verification: Task<Void, Never>?
    private var challengeExpiry: Task<Void, Never>?
    private var leaseExpiry: Task<Void, Never>?
    private var refresh: Task<Void, Never>?
    private var admissionPermit: PeelHostProAdmissionPermit?
    private var knownControlSession: PeelControlSession?
    private var hostSessionID = UUID().uuidString
    private let verifier: any PeelCommerceAuthorityVerifying
    private let isEligible: (PeelControlSession) -> Bool
    private let sendChallenge: (PeelProEntitlementChallenge, PeelControlSession) -> Void
    private let sendStatus: (PeelProEntitlementStatus, PeelControlSession) -> Void
    private let onAdmissionEnded: () -> Void
    private let clock: () -> PeelHostProAdmissionState.Clock

    init(verifier: any PeelCommerceAuthorityVerifying,
         isEligible: @escaping (PeelControlSession) -> Bool,
         sendChallenge: @escaping (PeelProEntitlementChallenge, PeelControlSession) -> Void,
         sendStatus: @escaping (PeelProEntitlementStatus, PeelControlSession) -> Void,
         onAdmissionEnded: @escaping () -> Void,
         clock: @escaping () -> PeelHostProAdmissionState.Clock = {
             .init(wall: Date().timeIntervalSince1970, monotonic: ProcessInfo.processInfo.systemUptime)
         }) {
        self.verifier = verifier
        self.isEligible = isEligible
        self.sendChallenge = sendChallenge
        self.sendStatus = sendStatus
        self.onAdmissionEnded = onAdmissionEnded
        self.clock = clock
    }

    deinit {
        admissionPermit?.invalidate()
        verification?.cancel()
        challengeExpiry?.cancel()
        leaseExpiry?.cancel()
        refresh?.cancel()
    }

    func bind(_ session: PeelControlSession?, supportsEvidence: Bool) {
        invalidate()
        guard supportsEvidence, let session, isEligible(session) else { return }
        if knownControlSession != session {
            knownControlSession = session
            hostSessionID = UUID().uuidString
        }
        state.bind(pairingID: session.pairingID, generation: session.generation, sessionID: hostSessionID)
        requestEvidence()
    }

    func invalidate() {
        admissionPermit?.invalidate(); admissionPermit = nil
        verification?.cancel(); verification = nil
        challengeExpiry?.cancel(); challengeExpiry = nil
        leaseExpiry?.cancel(); leaseExpiry = nil
        refresh?.cancel(); refresh = nil
        state.invalidate() // Cancellation alone cannot fence late completion.
        onAdmissionEnded()
    }

    func allows(_ session: PeelControlSession) -> Bool {
        let now = clock()
        if state.expireLease(now: now) {
            // A wall-clock change can reveal expiry before the timer wakes.
            // Fence renewal operations too, then use a new nonce to retry.
            let bound = state.binding.map { PeelControlSession(pairingID: $0.pairingID, generation: $0.generation) }
            bind(bound, supportsEvidence: true)
            return false
        }
        return isEligible(session) && state.allows(pairingID: session.pairingID,
            generation: session.generation, now: now) && admissionPermit?.allows(session, clock: clock) == true
    }

    func permit(for session: PeelControlSession) -> PeelHostProAdmissionPermit? {
        allows(session) ? admissionPermit : nil
    }

    func challengeDeliveryFailed(_ challenge: PeelProEntitlementChallenge, session: PeelControlSession) {
        guard let operation = state.pending ?? state.verifying,
              state.binding == operation.binding, state.epoch == operation.epoch,
              operation.binding.pairingID == session.pairingID,
              operation.binding.generation == session.generation,
              operation.challenge == challenge else { return }
        invalidate()
    }

    func deadlineUptimeNanoseconds(for session: PeelControlSession) -> UInt64? {
        guard allows(session), let lease = state.lease else { return nil }
        let dispatchNow = DispatchTime.now().uptimeNanoseconds
        let now = clock()
        let remaining = min(300, min(lease.monotonicExpiry - now.monotonic, lease.wallExpiry - now.wall))
        guard remaining.isFinite, remaining > 0 else { return nil }
        return dispatchNow + UInt64(remaining * 1_000_000_000)
    }

    func receive(_ proof: PeelProEntitlementProof, generation: UInt64) {
        guard let binding = state.binding else { return }
        let session = PeelControlSession(pairingID: binding.pairingID, generation: binding.generation)
        guard isEligible(session) else { return }
        let previouslyAllowed = state.allows(pairingID: session.pairingID, generation: session.generation, now: clock())
        guard let operation = state.consume(proof, generation: generation, now: clock()) else {
            if previouslyAllowed && !state.allows(pairingID: session.pairingID, generation: session.generation, now: clock()) {
                admissionPermit?.invalidate(); admissionPermit = nil
                onAdmissionEnded()
            }
            return
        }
        verification?.cancel()
        sendStatus(PeelProEntitlementStatus(requestId: proof.requestId, sessionId: binding.sessionID,
            state: "pending", expiresAt: nil, reason: "pending"), session)
        verification = Task { [weak self, verifier] in
            do {
                let response = try await verifier.verify(proof)
                guard !Task.isCancelled, let self, self.isEligible(session),
                      self.state.isCurrent(operation, now: self.clock()) else { return }
                let granted = self.state.complete(response, operation: operation, now: self.clock())
                guard !Task.isCancelled else { return }
                self.verification = nil
                self.challengeExpiry?.cancel(); self.challengeExpiry = nil
                if granted {
                    let previous = self.admissionPermit
                    previous?.invalidate()
                    self.admissionPermit = nil
                    if previous != nil { self.onAdmissionEnded() }
                    self.admissionPermit = self.state.lease.map(PeelHostProAdmissionPermit.init(lease:))
                    self.sendStatus(PeelProEntitlementStatus(requestId: proof.requestId,
                        sessionId: binding.sessionID, state: "verified", expiresAt: response.expiresAt,
                        reason: "active"), session)
                    self.scheduleLeaseExpiry()
                } else {
                    self.admissionPermit?.invalidate(); self.admissionPermit = nil
                    self.leaseExpiry?.cancel(); self.leaseExpiry = nil
                    self.onAdmissionEnded()
                    self.sendStatus(PeelProEntitlementStatus(requestId: proof.requestId,
                        sessionId: binding.sessionID, state: "denied", expiresAt: nil,
                        reason: "no_entitlement"), session)
                }
                self.scheduleRefresh(session: session)
            } catch {
                guard !Task.isCancelled, let self, self.isEligible(session),
                      self.state.isCurrent(operation, now: self.clock()) else { return }
                self.state.unavailable(operation: operation)
                self.verification = nil
                self.challengeExpiry?.cancel(); self.challengeExpiry = nil
                self.sendStatus(PeelProEntitlementStatus(requestId: proof.requestId,
                    sessionId: binding.sessionID, state: "unavailable", expiresAt: nil,
                    reason: "unavailable"), session)
                self.scheduleRefresh(session: session)
            }
        }
    }

    func receive(_ withdrawal: PeelProEntitlementWithdrawal, generation: UInt64) {
        guard let binding = state.binding, withdrawal.type == "proEntitlementWithdraw",
              withdrawal.pairingId == binding.pairingID, withdrawal.sessionId == binding.sessionID,
              generation == binding.generation else { return }
        let session = PeelControlSession(pairingID: binding.pairingID, generation: binding.generation)
        // Reissue with a new nonce in the same authenticated Host control-session
        // UUID, so a later purchase can supply new evidence immediately.
        bind(session, supportsEvidence: true)
    }

    private func requestEvidence() {
        guard let binding = state.binding else { return }
        let session = PeelControlSession(pairingID: binding.pairingID, generation: binding.generation)
        guard isEligible(session) else { invalidate(); return }
        var bytes = Data(count: 32)
        guard bytes.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }) == errSecSuccess else {
            invalidate(); return
        }
        verification?.cancel(); verification = nil
        challengeExpiry?.cancel(); challengeExpiry = nil
        refresh?.cancel(); refresh = nil
        guard let operation = state.challenge(now: clock(), nonce: bytes.base64EncodedString()) else { return }
        sendChallenge(operation.challenge, session)
        challengeExpiry = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
            guard !Task.isCancelled, let self, self.state.binding == binding,
                  self.state.epoch == operation.epoch else { return }
            self.verification?.cancel(); self.verification = nil
            self.state.expirePending(operation)
            guard self.isEligible(session) else { self.invalidate(); return }
            self.sendStatus(PeelProEntitlementStatus(requestId: operation.challenge.requestId,
                sessionId: binding.sessionID, state: "unavailable", expiresAt: nil,
                reason: "unavailable"), session)
            self.scheduleRefresh(session: session)
        }
    }

    private func scheduleRefresh(session: PeelControlSession) {
        refresh?.cancel()
        let binding = state.binding
        refresh = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 120_000_000_000) } catch { return }
            guard !Task.isCancelled, let self, self.state.binding == binding,
                  self.isEligible(session) else { return }
            self.requestEvidence()
        }
    }

    private func scheduleLeaseExpiry() {
        leaseExpiry?.cancel()
        guard let lease = state.lease else { return }
        let duration = max(0, min(300, lease.monotonicExpiry - clock().monotonic))
        leaseExpiry = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000)) } catch { return }
            guard !Task.isCancelled, let self, self.state.lease?.binding == lease.binding else { return }
            if self.state.expireLease(now: self.clock()) {
                self.bind(PeelControlSession(pairingID: lease.binding.pairingID,
                    generation: lease.binding.generation), supportsEvidence: true)
            }
        }
    }
}
