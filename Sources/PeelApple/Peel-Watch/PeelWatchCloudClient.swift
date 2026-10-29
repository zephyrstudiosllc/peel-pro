import Foundation
import Combine
import WatchConnectivity
import PeelWatchCore

/// Uses WCSession.default without replacing PeelCompanionModel's delegate.
/// One foreground request only; no transferUserInfo/polling or token crosses WC.
@MainActor
final class PeelWatchCloudCourier: PluginRelayWatchTransport {
    private var pending: (id: UUID, continuation: CheckedContinuation<Data, Error>, timeout: Task<Void, Never>)?

    func exchange(_ data: Data, courierID: UUID) async throws -> Data {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= WatchStreamWire.maximumBytes,
              WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isReachable else { throw PluginRelayWatchCoordinatorError.unavailable }
        guard pending == nil else { throw PluginRelayWatchCoordinatorError.busy }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
                    self?.finish(courierID, result: .failure(PluginRelayWatchCoordinatorError.unavailable))
                }
                pending = (courierID, continuation, timeout)
                WCSession.default.sendMessageData(data, replyHandler: { [weak self] bytes in
                    Task { @MainActor in
                        guard !bytes.isEmpty, bytes.count <= WatchStreamWire.maximumBytes else {
                            self?.finish(courierID, result: .failure(PluginRelayWatchCoordinatorError.invalidResponse)); return
                        }
                        self?.finish(courierID, result: .success(bytes))
                    }
                }, errorHandler: { [weak self] _ in
                    Task { @MainActor in self?.finish(courierID, result: .failure(PluginRelayWatchCoordinatorError.unavailable)) }
                })
            }
        } onCancel: { Task { @MainActor [weak self] in await self?.cancel(courierID: courierID) } }
    }
    func cancel(courierID: UUID) async {
        finish(courierID, result: .failure(PluginRelayWatchCoordinatorError.cancelled))
    }
    private func finish(_ id: UUID, result: Result<Data, Error>) {
        guard let active = pending, active.id == id else { return }
        pending = nil; active.timeout.cancel(); active.continuation.resume(with: result)
    }
}

/// Immutable admission context captured by the view before creating a Task.
/// Public route/provider metadata alone is never sufficient to authorize it.
struct PeelWatchCloudActionContext: Equatable, Sendable {
    let generation: UUID
    let provider: CloudAgentProvider
}

/// Visible app composition. Only trusted native enrollment may install a route.
/// Neither v1 identity metadata, JSON/status, nor WC reachability invokes install.
@MainActor
final class PeelWatchCloudClient: ObservableObject {
    static let shared = PeelWatchCloudClient()
    @Published private(set) var provider: CloudAgentProvider = .dot
    @Published private(set) var ready = false
    @Published private(set) var busy = false
    @Published private(set) var status = "Connect your agent in Peel Pro on iPhone."
    @Published private(set) var replies: [PluginRelayReply] = []
    @Published private(set) var outgoing: [PluginRelaySendRecord] = []
    @Published private(set) var lastSentText: String?
    private var coordinator: PluginRelayWatchCoordinator?
    @Published private(set) var actionContext = PeelWatchCloudActionContext(generation: UUID(), provider: .dot)
    private var generation: UUID { actionContext.generation }
    private var installationID = UUID()
    private var providerInstallations: [CloudAgentProvider: UUID] = [:]
    private let routes = PluginRelayWatchProviderRoutes()
    private struct CachedView {
        var pending: PluginRelayMessage?; var lastText: String?
        var replies: [PluginRelayReply]; var outgoing: [PluginRelaySendRecord]
        var status: String
    }
    private var views: [CloudAgentProvider: CachedView] = [:]
    private var renewals: [CloudAgentProvider: @MainActor (PluginRelayFence) async throws -> Void] = [:]
    private var nativeAuthority: (any PluginRelayWatchAuthority)?
    private var currentFence: PluginRelayFence?
    private var pendingMessage: PluginRelayMessage?
    private var renewLease: (@MainActor (PluginRelayFence) async throws -> Void)?

    /// Trusted composition must verify the selected broker route and enrolled
    /// phone before this call and keep authority current thereafter. A partition
    /// is exact per provider/account/route/pair, never a generic user cache.
    func install(fence: PluginRelayFence, authority: any PluginRelayWatchAuthority,
                 renewLease: (@MainActor (PluginRelayFence) async throws -> Void)? = nil) async throws {
        try authority.validateCurrent(fence)
        let target = fence.binding.route.provider, operation = UUID()
        providerInstallations[target] = operation
        let entry: PluginRelayWatchProviderRoutes.Entry
        if let existing = await routes.entry(for: target), existing.fence == fence {
            await existing.coordinator.stop()
            try existing.authority.replaceVerifiedAuthority(authority)
            entry = existing
        } else {
            if target == provider { advanceActionContext(); ready = false; busy = false }
            let binding = fence.binding
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PeelPluginRelay", isDirectory: true)
                .appendingPathComponent(binding.route.provider.rawValue, isDirectory: true)
                .appendingPathComponent(binding.route.accountGeneration.uuidString, isDirectory: true)
                .appendingPathComponent(binding.route.generation.uuidString, isDirectory: true)
                .appendingPathComponent(binding.pairingEpoch.uuidString, isDirectory: true)
            let persistence = try PluginRelayFilePersistence(fileURL: directory.appendingPathComponent("watch.json"))
            let store = try PluginRelayWatchStore(persistence: persistence, fence: fence)
            let slot = try PluginRelayWatchAuthoritySlot(fence: fence, authority: authority)
            let next = try PluginRelayWatchCoordinator(fence: fence, store: store, transport: PeelWatchCloudCourier(), authority: slot)
            entry = .init(fence: fence, coordinator: next, authority: slot)
            try await routes.install(entry)
            views[target] = nil
        }
        guard providerInstallations[target] == operation else { throw PluginRelayWatchCoordinatorError.cancelled }
        try authority.validateCurrent(fence)
        renewals[target] = renewLease
        guard target == provider else { return }
        coordinator = entry.coordinator; nativeAuthority = entry.authority; currentFence = entry.fence
        self.renewLease = renewLease
        advanceActionContext(); status = "Checking your agent connection…"
        await refreshStatus()
    }
    func select(_ value: CloudAgentProvider) async {
        saveVisible()
        let selection = UUID(); installationID = selection
        provider = value; advanceActionContext(); ready = false; busy = true
        coordinator = nil; nativeAuthority = nil; currentFence = nil; renewLease = nil
        do {
            let (_, entry) = try await routes.select(value)
            guard installationID == selection else { return }
            restoreVisible(value)
            coordinator = entry?.coordinator; nativeAuthority = entry?.authority; currentFence = entry?.fence
            renewLease = renewals[value]; busy = false
            await refreshStatus()
        } catch { if installationID == selection { busy = false } }
    }
    private func saveVisible() {
        views[provider] = .init(pending: pendingMessage, lastText: lastSentText, replies: replies, outgoing: outgoing, status: status)
    }
    private func restoreVisible(_ provider: CloudAgentProvider) {
        let saved = views[provider]
        pendingMessage = saved?.pending; lastSentText = saved?.lastText
        replies = saved?.replies ?? []; outgoing = saved?.outgoing ?? []
        status = saved?.status ?? "Connect \(provider == .dot ? "Dot with ChatGPT" : "Grok Bot with X") in Peel Pro on iPhone."
    }
    func refreshStatus() async {
        if coordinator == nil {
            do { try await PeelWatchCloudEnrollment.shared.resume(provider) }
            catch { ready = false; status = "Reconnect your agent in Peel Pro on iPhone. Your saved messages keep their IDs." }
            return
        }
        await perform { try await $0.status() }
    }
    func refreshReply(context: PeelWatchCloudActionContext, selectedProvider: CloudAgentProvider) async {
        guard accepts(context, selectedProvider: selectedProvider) else { return }
        await perform(context: context, selectedProvider: selectedProvider) { try await $0.refreshReply() }
    }
    func refreshStatus(context: PeelWatchCloudActionContext, selectedProvider: CloudAgentProvider) async {
        guard accepts(context, selectedProvider: selectedProvider) else { return }
        await perform(context: context, selectedProvider: selectedProvider) { try await $0.status() }
    }
    func send(_ text: String, context: PeelWatchCloudActionContext, selectedProvider: CloudAgentProvider) async {
        guard accepts(context, selectedProvider: selectedProvider), ready, !busy else { return }
        do {
            // Retain this exact ID/body even if reserve/send throws. The core
            // commits it before dispatch; explicit retries reuse the same value.
            let message = try PluginRelayMessage(messageID: UUID(), text: text)
            pendingMessage = message; lastSentText = text
            await perform(context: context, selectedProvider: selectedProvider) { try await $0.send(message) }
        } catch { status = "The message is too long or contains unsupported text." }
    }
    func retry(_ record: PluginRelaySendRecord, context: PeelWatchCloudActionContext,
               selectedProvider: CloudAgentProvider) async {
        guard accepts(context, selectedProvider: selectedProvider), ready, !busy,
              outgoing.contains(record) else { return }
        pendingMessage = record.message; lastSentText = record.message.text
        await perform(context: context, selectedProvider: selectedProvider) { try await $0.send(record.message) }
    }
    func retryPending(context: PeelWatchCloudActionContext, selectedProvider: CloudAgentProvider) async {
        guard accepts(context, selectedProvider: selectedProvider),
              let message = pendingMessage, ready, !busy else { return }
        await perform(context: context, selectedProvider: selectedProvider) { try await $0.send(message) }
    }
    func stop(context: PeelWatchCloudActionContext, selectedProvider: CloudAgentProvider) async {
        guard accepts(context, selectedProvider: selectedProvider) else { return }
        await stop(expectedContext: context)
    }
    private func accepts(_ context: PeelWatchCloudActionContext, selectedProvider: CloudAgentProvider) -> Bool {
        context == actionContext && context.provider == provider && selectedProvider == provider
    }
    private func advanceActionContext() {
        actionContext = PeelWatchCloudActionContext(generation: UUID(), provider: provider)
    }
    func stop() async { await stop(expectedContext: nil) }
    private func stop(expectedContext: PeelWatchCloudActionContext?) async {
        if let expectedContext, expectedContext != actionContext { return }
        advanceActionContext(); let active = generation; busy = true
        await coordinator?.stop()
        guard generation == active else { return }
        busy = false; status = "Checking stopped here. Your remote agent may keep working."
    }
    func invalidate() async {
        installationID = UUID(); providerInstallations.removeAll(); advanceActionContext()
        ready = false; busy = false; coordinator = nil; nativeAuthority = nil; currentFence = nil
        pendingMessage = nil; renewLease = nil; replies = []; outgoing = []; lastSentText = nil
        views.removeAll(); renewals.removeAll()
        status = "Connect your agent in Peel Pro on iPhone."
        try? await routes.invalidateAll()
    }
    func invalidate(_ value: CloudAgentProvider) async {
        providerInstallations[value] = UUID()
        views[value] = nil; renewals[value] = nil
        if provider == value {
            installationID = UUID(); advanceActionContext(); ready = false; busy = false
            coordinator = nil; nativeAuthority = nil; currentFence = nil; renewLease = nil
            pendingMessage = nil; replies = []; outgoing = []; lastSentText = nil
            status = "Connect your agent in Peel Pro on iPhone."
        }
        try? await routes.invalidate(value)
    }
    private func ensureAuthority(_ authority: any PluginRelayWatchAuthority, fence: PluginRelayFence,
                                 allowRenewal: Bool) async throws -> Bool {
        do { try authority.validateCurrent(fence); return false }
        catch PluginRelayEnrollmentError.expired {
            guard allowRenewal, let renewLease else { throw PluginRelayEnrollmentError.expired }
            // One bounded same-fence refresh. No action is admitted while the
            // old grant is expired, and the remote action is never retried here.
            try await renewLease(fence)
            try authority.validateCurrent(fence); return true
        }
    }
    private func perform(context: PeelWatchCloudActionContext? = nil,
                         selectedProvider: CloudAgentProvider? = nil, _ action: @escaping @Sendable (PluginRelayWatchCoordinator) async throws -> PluginRelayWatchSnapshot) async {
        if let context {
            guard let selectedProvider, accepts(context, selectedProvider: selectedProvider) else { return }
        }
        guard !busy, let coordinator, let authority = nativeAuthority, let fence = currentFence else {
            if self.coordinator == nil { ready = false; status = "Connect your agent in Peel Pro on iPhone." }
            return
        }
        let active = generation; busy = true; var renewed = false
        defer { if active == generation { busy = false } }
        do {
            renewed = try await ensureAuthority(authority, fence: fence, allowRenewal: true)
            guard active == generation, currentFence == fence else { return }
            let result = try await action(coordinator)
            guard active == generation else { return }
            try authority.validateCurrent(fence)
            outgoing = result.outgoing; replies = result.replies
            if let report = result.report {
                ready = report.remoteReady
                switch report.state {
                case .authorizePlugin: status = "Finish connecting your agent in Peel Pro on iPhone."
                case .connected: status = "Your dot is connected."
                case .manualReady: status = "Grok Bot is connected. Ask it to check Peel for new messages."
                }
            }
            if let pendingMessage, result.outgoing.contains(where: { $0.message == pendingMessage && $0.receipt != nil }) {
                self.pendingMessage = nil
            }
        } catch {
            guard active == generation else { return }
            if (error as? PluginRelayEnrollmentError) == .revoked { await invalidate(provider); return }
            do {
                _ = try await ensureAuthority(authority, fence: fence, allowRenewal: !renewed)
                guard active == generation, currentFence == fence else { return }
            } catch {
                if (error as? PluginRelayEnrollmentError) == .revoked { await invalidate(provider); return }
                ready = false
                status = "Connection needs a fresh check on iPhone. Your saved messages keep their IDs."
                return
            }
            status = "Connection interrupted. Your saved message keeps its ID; retry it to check delivery."
            // A lease renewal never repeats a send/read action. Recover only
            // already durable state, with the existing coordinator and epoch.
            if let saved = try? await coordinator.snapshot(), active == generation,
               (try? authority.validateCurrent(fence)) != nil {
                outgoing = saved.outgoing; replies = saved.replies
                if let report = saved.report { ready = report.remoteReady }
            }
        }
    }
}
