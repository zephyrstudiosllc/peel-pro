import Foundation

/// Immutable lease bounds plus a synchronous revocation bit. Capture the permit
/// when accepting an action and check it on the outbound queue immediately
/// before submission. A later grant creates a different permit; it cannot revive
/// work captured under a withdrawn/replaced lease.
nonisolated final class PeelHostProAdmissionPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var invalidated = false
    private let lease: PeelHostProAdmissionState.Lease

    init(lease: PeelHostProAdmissionState.Lease) { self.lease = lease }

    func invalidate() {
        lock.lock()
        invalidated = true
        lock.unlock()
    }

    func allows(_ session: PeelControlSession) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return valid(session, now: .init(wall: Date().timeIntervalSince1970,
            monotonic: ProcessInfo.processInfo.systemUptime))
    }

    func allows(_ session: PeelControlSession, now: PeelHostProAdmissionState.Clock) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return valid(session, now: now)
    }

    func allows(_ session: PeelControlSession, clock: () -> PeelHostProAdmissionState.Clock) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return valid(session, now: clock())
    }

    /// `submit` must only submit the immediate effect. It must not wait for a
    /// callback or reenter this permit. Invalidation cannot return between the
    /// final check and that submission; once invalidation returns, no old queued
    /// work can begin a submission through this permit.
    @discardableResult
    func withValidAdmission(for session: PeelControlSession, _ submit: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = PeelHostProAdmissionState.Clock(wall: Date().timeIntervalSince1970,
            monotonic: ProcessInfo.processInfo.systemUptime)
        guard valid(session, now: now) else { return false }
        submit()
        return true
    }

    @discardableResult
    func withValidAdmission(for session: PeelControlSession, now: PeelHostProAdmissionState.Clock,
                            _ submit: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard valid(session, now: now) else { return false }
        submit()
        return true
    }

    private func valid(_ session: PeelControlSession, now: PeelHostProAdmissionState.Clock) -> Bool {
        !invalidated && now.isValid &&
            lease.binding.pairingID == session.pairingID && lease.binding.generation == session.generation &&
            now.wall < lease.wallExpiry && now.monotonic < lease.monotonicExpiry
    }
}
