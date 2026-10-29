import Foundation

/// Carries the proved target across the local transport's queue hop to the UI.
nonisolated final class PeelAgentTargetSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var session: PeelControlSession?

    func set(_ value: PeelControlSession?) {
        lock.lock()
        session = value
        lock.unlock()
    }

    func current() -> PeelControlSession? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }
}
