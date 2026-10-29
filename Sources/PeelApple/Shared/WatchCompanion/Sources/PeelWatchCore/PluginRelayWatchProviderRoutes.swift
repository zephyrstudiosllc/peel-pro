import Foundation

/// Mutable authority indirection for ONE immutable full fence. Replacing a
/// lease after trusted verification does not replace its coordinator/store.
public final class PluginRelayWatchAuthoritySlot: PluginRelayWatchAuthority, @unchecked Sendable {
    public let fence: PluginRelayFence
    private let lock = NSLock()
    private var authority: any PluginRelayWatchAuthority
    private var enabled = true
    public init(fence: PluginRelayFence, authority: any PluginRelayWatchAuthority) throws {
        try authority.validateCurrent(fence); self.fence = fence; self.authority = authority
    }
    public func validateCurrent(_ fence: PluginRelayFence) throws {
        lock.lock(); defer { lock.unlock() }
        guard enabled, fence == self.fence else { throw PluginRelayEnrollmentError.revoked }
        try authority.validateCurrent(fence)
    }
    public func replaceVerifiedAuthority(_ authority: any PluginRelayWatchAuthority) throws {
        try authority.validateCurrent(fence)
        lock.lock(); defer { lock.unlock() }
        guard enabled else { throw PluginRelayEnrollmentError.revoked }; self.authority = authority
    }
    public func revoke() { lock.lock(); defer { lock.unlock() }; enabled = false }
}

/// Owns separate exact routes for Dot and Grok. Selection only stops/drains the
/// old local courier; it never rotates an epoch or destroys another provider.
/// Terminal invalidation is reserved for actual route/account/pair replacement.
public actor PluginRelayWatchProviderRoutes {
    public struct Entry: Sendable {
        public let fence: PluginRelayFence
        public let coordinator: PluginRelayWatchCoordinator
        public let authority: PluginRelayWatchAuthoritySlot
        public init(fence: PluginRelayFence, coordinator: PluginRelayWatchCoordinator, authority: PluginRelayWatchAuthoritySlot) {
            self.fence = fence; self.coordinator = coordinator; self.authority = authority
        }
    }
    public struct Selection: Equatable, Sendable { public let provider: CloudAgentProvider; public let generation: UUID }
    private var entries: [CloudAgentProvider: Entry] = [:]
    private var installations: [CloudAgentProvider: UUID] = [:]
    private var stops: [CloudAgentProvider: (id: UUID, task: Task<Void, Never>)] = [:]
    private var selection = Selection(provider: .dot, generation: UUID())
    public init() {}
    public func entry(for provider: CloudAgentProvider) -> Entry? { entries[provider] }
    public func currentSelection() -> Selection { selection }
    public func isCurrent(_ value: Selection) -> Bool { selection == value }
    public func install(_ entry: Entry) async throws {
        let provider = entry.fence.binding.route.provider, operation = UUID()
        installations[provider] = operation
        if let old = entries[provider] {
            if old.fence == entry.fence {
                // The native owner renews the existing slot in place instead.
                guard old.coordinator === entry.coordinator, old.authority === entry.authority else {
                    throw PluginRelayEnrollmentError.wrongPeer
                }
                return
            }
            old.authority.revoke(); entries[provider] = nil
            await stop(provider, coordinator: old.coordinator)
            try await old.coordinator.invalidate()
        }
        guard installations[provider] == operation else { throw PluginRelayWatchCoordinatorError.cancelled }
        try entry.authority.validateCurrent(entry.fence); entries[provider] = entry
    }
    public func select(_ provider: CloudAgentProvider) async throws -> (Selection, Entry?) {
        let oldProvider = selection.provider, old = entries[selection.provider]
        let next = Selection(provider: provider, generation: UUID()); selection = next
        if let old { await stop(oldProvider, coordinator: old.coordinator) }
        if let target = stops[provider] { await target.task.value }
        guard selection == next else { throw PluginRelayWatchCoordinatorError.cancelled }
        return (next, entries[provider])
    }
    public func invalidate(_ provider: CloudAgentProvider) async throws {
        installations[provider] = UUID()
        if selection.provider == provider { selection = .init(provider: provider, generation: UUID()) }
        let old = entries.removeValue(forKey: provider); old?.authority.revoke()
        if let old { await stop(provider, coordinator: old.coordinator); try await old.coordinator.invalidate() }
    }
    private func stop(_ provider: CloudAgentProvider, coordinator: PluginRelayWatchCoordinator) async {
        if let pending = stops[provider] { await pending.task.value; return }
        let id = UUID(), task = Task { await coordinator.stop() }
        stops[provider] = (id, task)
        await task.value
        if stops[provider]?.id == id { stops[provider] = nil }
    }
    public func invalidateAll() async throws {
        let old = entries
        entries.removeAll()
        selection = .init(provider: selection.provider, generation: UUID())
        // All slots are closed before the FIRST await. Actual pair replacement
        // cannot leave one provider admitted while another courier drains.
        for provider in [CloudAgentProvider.dot, .grokBot] {
            installations[provider] = UUID(); old[provider]?.authority.revoke()
        }
        var failure: Error?
        for provider in [CloudAgentProvider.dot, .grokBot] {
            guard let entry = old[provider] else { continue }
            await stop(provider, coordinator: entry.coordinator)
            do { try await entry.coordinator.invalidate() } catch { failure = error }
        }
        if let failure { throw failure }
    }
}
