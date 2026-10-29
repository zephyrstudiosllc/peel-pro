#if !os(watchOS)
import Foundation

public enum PluginRelayNativeBrokerGateError: Error, Equatable, Sendable { case busy, cancelled }

/// Local exclusion only, never account or peer authority. The native connector
/// acquires one lease BEFORE entering its shared broker or mutating a refresh
/// checkpoint. No await occurs between admission and reserving cancellation.
public final class PluginRelayNativeBrokerOperationGate: @unchecked Sendable {
    public struct Operation: Sendable {
        public let provider: CloudAgentProvider
        fileprivate let id: UUID
    }
    public struct Cancellation: Sendable {
        fileprivate let id: UUID
        fileprivate let operationID: UUID
        fileprivate let provider: CloudAgentProvider
    }
    private struct Active { let lease: Operation; var cancelled = false }
    private let lock = NSLock()
    private var active: Active?
    private var cancellations: [UUID: Cancellation] = [:]
    public init() {}
    public func begin(_ provider: CloudAgentProvider) throws -> Operation {
        lock.lock(); defer { lock.unlock() }
        guard active == nil, cancellations.isEmpty else { throw PluginRelayNativeBrokerGateError.busy }
        let lease = Operation(provider: provider, id: UUID()); active = Active(lease: lease); return lease
    }
    public func validate(_ operation: Operation) throws {
        lock.lock(); defer { lock.unlock() }
        guard let active, active.lease.id == operation.id, active.lease.provider == operation.provider,
              !active.cancelled else { throw PluginRelayNativeBrokerGateError.cancelled }
    }
    public func finish(_ operation: Operation) {
        lock.lock(); defer { lock.unlock() }
        guard active?.lease.id == operation.id, active?.lease.provider == operation.provider else { return }
        active = nil
        // Outstanding cancellation leases deliberately remain. They prevent a
        // stale awaited cancel from reaching a newly admitted other provider.
    }
    public func beginCancellation(_ provider: CloudAgentProvider) -> Cancellation? {
        lock.lock(); defer { lock.unlock() }
        guard let value = active, value.lease.provider == provider else { return nil }
        active?.cancelled = true
        let lease = Cancellation(id: UUID(), operationID: value.lease.id, provider: provider)
        cancellations[lease.id] = lease; return lease
    }
    public func finishCancellation(_ cancellation: Cancellation) {
        lock.lock(); defer { lock.unlock() }
        guard let saved = cancellations[cancellation.id], saved.operationID == cancellation.operationID,
              saved.provider == cancellation.provider else { return }
        cancellations[cancellation.id] = nil
    }
}
#endif
