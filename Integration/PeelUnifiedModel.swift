import AppKit
import Combine
import Foundation
import Observation
import OSLog
import SwiftUI

/// Remote Desktop has two jobs: connect to another computer, or share this one.
enum PeelRemoteDesktopTab: String, Hashable, CaseIterable, Identifiable {
    case connect, share
    var id: Self { self }
    var title: String {
        switch self {
        case .connect: "Connect"
        case .share: "Share This Mac"
        }
    }
}

@MainActor
@Observable
final class PeelUnifiedModel {
    let sidePulse: CommandCenterStore
    let usage: PeelUsageStore
    let sampler: ProcessSampler
    let systemMetrics: SystemMetricsStore
    private(set) var remoteMacViewer: PeelRemoteMacViewerController?
    private(set) var remoteMacPresentation: PeelRemoteMacWindowPresentation?
    let isPreview = ProcessInfo.processInfo.arguments.contains("--peel-preview")
    static let systemAlertsOnIdleIndicatorsDefaultsKey = "peel.bar.systemAlertsOnIdleIndicators"
    var systemAlertsOnIdleIndicators = false
    /// Runtime navigation state only; not persisted.
    var remoteDesktopTab: PeelRemoteDesktopTab = .connect

    @ObservationIgnored private var controller: SidePulseMenuBarController?
    @ObservationIgnored private var host: PeelHost?
    @ObservationIgnored private var trustedSignalService: PeelTrustedSidePulseService?
    /// Paired-Mac agent sessions, owner activation and usage summaries.
    let peerAgents = PeelPeerAgentStore()
    @ObservationIgnored private var peerUsageTimer: Timer?
    @ObservationIgnored private var lastPublishedStates: [String: AgentState] = [:]
    @ObservationIgnored private var systemPressureCancellables: Set<AnyCancellable> = []
    /// Fixed public startup codes only, readable with `log show`; no names,
    /// identifiers, counts, keys or error text.
    private let signalStartupLog = Logger(subsystem: "com.zephyrstudiosllc.Peel-Host", category: "SignalStartup")
    private let signalStartupLogGate = NearbySignalStartupLogGate()

    init() {
        if !isPreview {
            Self.migrateGaugePreferences()
            PeelSidePulsePreferenceMigration.migrateIfNeeded(
                source: UserDefaults(suiteName: PeelSidePulsePreferenceMigration.sourceBundleIdentifier))
        }
        sidePulse = CommandCenterStore()
        usage = PeelUsageStore()
        sampler = ProcessSampler()
        systemMetrics = SystemMetricsStore()
        systemAlertsOnIdleIndicators = !isPreview && UserDefaults.standard.bool(
            forKey: Self.systemAlertsOnIdleIndicatorsDefaultsKey
        )
        sidePulse.selectedSection = .host
        // The inert preview disables controls; this lets window QA show Share This Mac.
        if isPreview, ProcessInfo.processInfo.arguments.contains("--peel-preview-share") {
            remoteDesktopTab = .share
        }
        AppDelegate.processSampler = sampler
        if !isPreview {
            observeSystemPressure()
            PeelAccountHostAdapter.start(model: self)
        }
    }

    func registerWindow(_ window: NSWindow) {
        window.identifier = PeelUtilityWindowPolicy.identifier
        PeelUtilityWindowPolicy.attach(window)
        ensureController()
        controller?.registerCommandCenter(window)
    }

    func configureWindowOpener(host: PeelHost, _ open: @escaping () -> Void) {
        self.host = host
        if !isPreview { PeelAccountHostAdapter.configure(model: self, host: host) }
        if remoteMacViewer == nil, let localID = UUID(uuidString: host.stableHostIdentifier) {
            let viewer = PeelRemoteMacViewerController(pairingStore: host.pairingStore, localHostID: localID)
            remoteMacViewer = viewer
            remoteMacPresentation = PeelRemoteMacWindowPresentation(controller: viewer,
                openComputers: { [weak self] in self?.openRemoteDesktop(.connect) })
        }
        // Keep the Host-only overview summary in the existing SidePulse store
        // seam. The summary reads this model from the inherited environment,
        // so the AnyView does not retain the model and form a cycle.
        sidePulse.hostOverviewSummary = AnyView(PeelOverviewSummary())
        host.machineStatusSnapshotProvider = { [weak self] requestId in
            guard let self else { return nil }
            return PeelRemoteMachineStatusProvider.snapshot(requestId: requestId, model: self)
        }
        if !isPreview, trustedSignalService == nil {
            sidePulse.openPeelPairing = { [weak self] in self?.openRemoteDesktop(.share) }
            let startupLog = signalStartupLog
            let startupGate = signalStartupLogGate
            sidePulse.installTrustedSignalService { [weak self] nodeID, displayName, onPeers, onSignal, onStatus, forwardSnapshot in
                // Each install has its own token; callbacks from older installs never log.
                let install = startupGate.beginInstall()
                if let code = startupGate.admit(.notStarted, install: install) {
                    startupLog.notice("startup \(code.rawValue, privacy: .public)")
                }
                let onSnapshot: @Sendable (NearbySignalServiceSnapshot) -> Void = { snapshot in
                    if let code = startupGate.admit(snapshot.startup, install: install) {
                        startupLog.notice("startup \(code.rawValue, privacy: .public)")
                    }
                    forwardSnapshot(snapshot)
                }
                guard let localNodeID = UUID(uuidString: nodeID),
                      let localHostID = UUID(uuidString: host.stableHostIdentifier) else {
                    return PeelUnavailableSignalService(onStatus: onStatus, onSnapshot: onSnapshot)
                }
                let service = PeelTrustedSidePulseService(nodeID: localNodeID, hostID: localHostID,
                    displayName: displayName, pairingStore: host.pairingStore, onPeers: onPeers,
                    onSignal: onSignal, onStatus: onStatus, onSnapshot: onSnapshot)
                self?.trustedSignalService = service
                self?.installPeerAgents(on: service)
                return service
            }
        }
        ensureController()
        controller?.createCommandCenter = open
        controller?.installUnifiedPresentation(
            menu: AnyView(PeelUnifiedMenuView(model: self, host: host)),
            notch: AnyView(PeelUnifiedNotchView(model: self, host: host, sampler: sampler)),
            label: AnyView(PeelUnifiedBarLabel(sampler: sampler, usage: usage))
        )
    }

    /// Legacy routes (`.settings`, `.hostSettings`, `.usageSettings`,
    /// `.mechanicSettings`, `.lighting`, `.usageProvider`) are resolved by the
    /// store to the page and tab that now own them.
    func open(_ section: CommandCenterSection) {
        sidePulse.selectedSection = section == .remoteMac ? .host : section
        controller?.openCommandCenter()
    }

    /// Opens the single Settings page on `tab`, or on its last-selected tab.
    func openSettings(_ tab: CommandCenterSettingsTab? = nil) {
        sidePulse.openSettings(tab)
        controller?.openCommandCenter()
    }

    /// Opens Remote Desktop on a specific tab. The stream window, if any, is
    /// unaffected; navigation never connects, disconnects or selects a window.
    func openRemoteDesktop(_ tab: PeelRemoteDesktopTab) {
        remoteDesktopTab = tab
        open(.host)
    }

    var accountLocallyTrustedDiscoveryIDs: Set<String> {
        guard let host else { return [] }
        return Set(host.pairingStore.paired.compactMap { peer -> String? in
            guard host.pairingStore.psk(for: peer.id)?.count == 32 else { return nil }
            return peer.stableHostId.flatMap { UUID(uuidString: $0)?.uuidString }
        })
    }

    func switchToMenuBar() {
        controller?.switchToUnifiedMenuBar()
    }

    func switchToNotch() {
        controller?.switchToUnifiedNotch()
    }

    func setSystemAlertsOnIdleIndicators(_ enabled: Bool) {
        guard !isPreview, systemAlertsOnIdleIndicators != enabled else { return }
        systemAlertsOnIdleIndicators = enabled
        UserDefaults.standard.set(enabled, forKey: Self.systemAlertsOnIdleIndicatorsDefaultsKey)
        refreshSystemPressureIndicator()
    }

    func shutdown() {
        if !isPreview { PeelAccountController.shared.stopAutomaticSync() }
        remoteMacPresentation?.shutdown()
        remoteMacViewer?.stop()
        peerUsageTimer?.invalidate()
        peerUsageTimer = nil
        trustedSignalService?.stop()
        usage.stopPresentation()
        sampler.resumeAllHeldForTermination()
        sampler.stop()
    }

    private static func migrateGaugePreferences() {
        let defaults = UserDefaults.standard
        let marker = "peel.migration.mechanicGauge.v1"
        guard !defaults.bool(forKey: marker) else { return }
        let source = defaults.persistentDomain(forName: "com.zephyrstudiosllc.Mac-Mechanic") ?? [:]
        if defaults.object(forKey: "menuBarGaugeMask") == nil,
           let mask = source["menuBarGaugeMask"] as? Int,
           (0...SystemGaugeSelection.allMask).contains(mask) {
            defaults.set(mask, forKey: "menuBarGaugeMask")
        }
        if defaults.object(forKey: "popupGaugeDisplayMode") == nil,
           let raw = source["popupGaugeDisplayMode"] as? String,
           PopupGaugeDisplayMode(rawValue: raw) != nil {
            defaults.set(raw, forKey: "popupGaugeDisplayMode")
        }
        if defaults.object(forKey: "peel.bar.showTopApp") == nil,
           let show = source["showsTopAppInMenuBar"] as? Bool {
            defaults.set(show, forKey: "peel.bar.showTopApp")
        }
        defaults.set(true, forKey: marker)
    }

    /// Paired-Mac agent metadata rides the existing authenticated signal
    /// transport and pairing keys. It is independent of LED sharing/follow.
    private func installPeerAgents(on service: PeelTrustedSidePulseService) {
        let store = peerAgents
        let sidePulse = self.sidePulse
        service.onPeerAgentEvent = { [weak store] event in store?.handle(event) }
        service.activationHandler = { [weak sidePulse] localID, requester, stillAuthorized, completion in
            guard let sidePulse else { completion(.launchFailed, nil); return }
            sidePulse.performPeerActivation(localID: localID, requesterLabel: requester,
                                            stillAuthorized: stillAuthorized) { outcome, appLabel in
                completion(PeelPeerActivationOutcome(rawValue: outcome.rawValue) ?? .launchFailed, appLabel)
            }
        }
        store.attach(service: service, sidePulse: sidePulse, usage: usage)

        let settings = PeelPeerAgentSettings.load()
        sidePulse.peerAgentSettings = settings
        sidePulse.updatePeerAgentSettings = { [weak self, weak service] next in
            PeelPeerAgentSettings.save(next)
            self?.sidePulse.peerAgentSettings = next
            service?.configurePeerAgents(PeelPeerAgentSettings.configuration(next))
        }
        sidePulse.onLocalAgentsPublished = { [weak self] agents in self?.publishLocalAgents(agents) }
        service.configurePeerAgents(PeelPeerAgentSettings.configuration(settings))
        publishLocalAgents(sidePulse.agents)

        peerUsageTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.publishLocalUsage() }
        }
        timer.tolerance = 3
        peerUsageTimer = timer
        publishLocalUsage()
    }

    /// Owner side: reduce local sessions to the neutral projection. Only the
    /// listed fields are used; cwd, message and openURL never leave here.
    private func publishLocalAgents(_ agents: [AgentSession]) {
        guard let service = trustedSignalService else { return }
        let sessions = agents.map { agent -> PeelPeerAgentLocalSession in
            let (support, reason) = sidePulse.activationSupport(for: agent)
            return PeelPeerAgentLocalSession(
                localID: agent.id,
                provider: agent.provider.rawValue,
                title: agent.name,
                project: agent.project,
                state: PeelPeerAgentState(rawValue: agent.state.rawValue) ?? .unknown,
                tool: agent.toolName,
                updatedAt: agent.updatedAt,
                alert: agent.isAcknowledgableAlert,
                activation: PeelPeerActivationSupport(rawValue: support.rawValue) ?? .unavailable,
                reason: reason,
                cloudTaskID: agent.id.hasPrefix("codex:cloud:") ? agent.sessionID : nil,
                bindingKey: bindingKey(for: agent))
        }
        let integrations = sidePulse.integrations.map { status -> PeelPeerProviderIntegration in
            let state: PeelPeerProviderIntegration.State = switch status.state {
            case .active: .active
            case .ready: .ready
            case .needsSetup: .needsSetup
            }
            return PeelPeerProviderIntegration(provider: status.provider.rawValue, state: state)
        }
        service.updateLocalAgents(sessions, integrations: integrations)
        // A turn just finished: refresh this Mac's observed tokens (spaced by the usage lane).
        if agents.contains(where: { $0.state == .completed && lastPublishedStates[$0.id] != .completed }) {
            usage.requestObservedTokenRefresh()
        }
        lastPublishedStates = Dictionary(agents.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
        let claudeNeedsSetup = sidePulse.integrations.contains { $0.provider == .claude && $0.state == .needsSetup }
        sidePulse.agentHookGuidance = claudeNeedsSetup
            ? "Claude Code hooks aren't set up on this Mac, so its Claude sessions can't appear here or on paired Macs. Setup: Tools/PeelAgentHooks/README.md"
            : nil
        peerAgents.updateLocalCloudTasks(Set(agents.filter { $0.id.hasPrefix("codex:cloud:") }.map(\.sessionID)))
    }

    /// Owner-local fingerprint of what an open would act on. Any change gives
    /// the target a new binding revision, so stale clicks are refused.
    private func bindingKey(for agent: AgentSession) -> String {
        var parts: [String] = []
        switch sidePulse.terminalBinding(for: agent.id) {
        case .bound(let binding)?:
            parts.append("b:\(binding.agent.pid).\(binding.agent.startSeconds).\(binding.agent.startMicroseconds)")
            parts.append("t:\(binding.ttyDevice)")
            parts.append("h:\(binding.host.app.pid).\(binding.host.app.startSeconds).\(binding.host.app.startMicroseconds)")
        case .unavailable(let reason)?:
            parts.append("u:\(reason.rawValue)")
        case nil:
            parts.append("n")
        }
        parts.append("d:\(AgentOpenRouting.allowedDestination(for: agent)?.absoluteString ?? "")")
        return parts.joined(separator: "|")
    }

    private func publishLocalUsage() {
        trustedSignalService?.updateLocalUsage(PeelPeerUsageInputAdapter.input(from: usage, now: .now))
    }

    private func ensureController() {
        guard controller == nil, !isPreview else { return }
        controller = SidePulseMenuBarController(store: sidePulse)
        controller?.prepareCommandCenter = { PeelUtilityWindowPolicy.normalize($0) }
    }

    private func observeSystemPressure() {
        sampler.$systemMemoryPressureState
            .combineLatest(sampler.$heldProcesses)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.refreshSystemPressureIndicator()
            }
            .store(in: &systemPressureCancellables)
    }

    private func refreshSystemPressureIndicator() {
        guard !isPreview, systemAlertsOnIdleIndicators else {
            sidePulse.setSystemPressureIndicator(nil)
            return
        }

        if let heldApp = sampler.heldProcesses.first {
            sidePulse.setSystemPressureIndicator(.heldApp(heldApp.appName))
            return
        }

        switch sampler.systemMemoryPressureState {
        case .normal:
            sidePulse.setSystemPressureIndicator(nil)
        case .warning:
            sidePulse.setSystemPressureIndicator(.memoryWarning)
        case .critical:
            sidePulse.setSystemPressureIndicator(.memoryCritical)
        }
    }
}

/// Persisted paired-Mac agent switches. Defaults are on: PIN pairing already
/// established these Macs as the user's own, and each switch stays visible in
/// the Agent Hub's Paired Macs panel. LED sharing/follow keys are untouched.
enum PeelPeerAgentSettings {
    static let sharesKey = "peel.peerAgents.share.v1"
    static let receivesKey = "peel.peerAgents.receive.v1"
    static let activationKey = "peel.peerAgents.activation.v1"
    static let usageKey = "peel.peerAgents.usage.v1"

    static func load(from defaults: UserDefaults = .standard) -> PeerAgentSharingSettings {
        func value(_ key: String) -> Bool { defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key) }
        return PeerAgentSharingSettings(sharesAgents: value(sharesKey), receivesAgents: value(receivesKey),
                                        allowsPeerActivation: value(activationKey), sharesUsage: value(usageKey))
    }

    static func save(_ settings: PeerAgentSharingSettings, to defaults: UserDefaults = .standard) {
        defaults.set(settings.sharesAgents, forKey: sharesKey)
        defaults.set(settings.receivesAgents, forKey: receivesKey)
        defaults.set(settings.allowsPeerActivation, forKey: activationKey)
        defaults.set(settings.sharesUsage, forKey: usageKey)
    }

    static func configuration(_ settings: PeerAgentSharingSettings) -> PeelPeerAgentConfiguration {
        PeelPeerAgentConfiguration(sharesAgents: settings.sharesAgents, receivesAgents: settings.receivesAgents,
                                   allowsPeerActivation: settings.sharesAgents && settings.allowsPeerActivation,
                                   sharesUsage: settings.sharesAgents && settings.sharesUsage)
    }
}
