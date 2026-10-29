import Foundation
import SwiftUI
import Combine
import AppKit
import ApplicationServices
import CoreMedia

import OSLog

@MainActor
final class StreamDiagnosticsStore: ObservableObject {
    @Published var activeStreamCount: Int = 0
    @Published var estimatedVideoMbps: Double = 0.0
    @Published var outstandingVideoBytes: Int = 0
    @Published var droppedRawFramesPerSecond: Int = 0
    @Published var encodedFramesPerSecond: Int = 0
    @Published var encodeInFlightCount: Int = 0
    @Published var sentFramesPerSecond: Int = 0
    @Published var hostPipelineSummary: String = "SCK -- | Sub -- | Out -- | Send -- | Drop --"
    @Published var lastDisconnectReason: String = ""

    func resetSessionMetrics() {
        activeStreamCount = 0
        estimatedVideoMbps = 0.0
        outstandingVideoBytes = 0
        droppedRawFramesPerSecond = 0
        encodedFramesPerSecond = 0
        encodeInFlightCount = 0
        sentFramesPerSecond = 0
        hostPipelineSummary = "SCK -- | Sub -- | Out -- | Send -- | Drop --"
    }

    func noteDisconnect(reason: String) {
        lastDisconnectReason = reason
        resetSessionMetrics()
    }
}

final class PeelHost: NSObject, ObservableObject, HostNetworkServerDelegate {
    @Published var statusText: String = "Starting…"
    @Published private(set) var discoveryState: HostDiscoveryState = .disabled
    let streamDiagnostics = StreamDiagnosticsStore()
    let receiverDiagnostics = PeelReceiverDiagnostics()
    private var lastStreamClockReplyAt: TimeInterval = 0

    private static let launcherFolderPathDefaultsKey = "PeelHost.launcherFolderPath"
    private static let hostIdDefaultsKey = "PeelHost.hostId"
    private static let discoverableDefaultsKey = "PeelHost.isDiscoverable"
    private static let allowControlThisMacDefaultsKey = "allowControlThisMac"
    private static let hostRenderedCursorCapability = "host-rendered-cursor"

    var launcherFolderPath: String {
        get {
            let stored = UserDefaults.standard.string(forKey: Self.launcherFolderPathDefaultsKey)
            if let stored, !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return stored
            }
            return "/Applications"
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                UserDefaults.standard.removeObject(forKey: Self.launcherFolderPathDefaultsKey)
            } else {
                UserDefaults.standard.set(trimmed, forKey: Self.launcherFolderPathDefaultsKey)
            }
        }
    }

    private lazy var hostId: String = {
        if let existing = UserDefaults.standard.string(forKey: Self.hostIdDefaultsKey),
           !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: Self.hostIdDefaultsKey)
        return fresh
    }()

    let pairingStore = PeelPairingStore(role: .host)
    var stableHostIdentifier: String {
#if PEEL_HOST_INTEGRATION
        if ProcessInfo.processInfo.arguments.contains("--peel-preview") {
            return "00000000-0000-4000-8000-000000000001"
        }
#endif
        return hostId
    }
    lazy var trustedPeerPairing = PeelTrustedPeerPairingController(
        pairingStore: pairingStore, localHostID: hostId,
        localDisplayName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
        onForgetPeer: { [weak self] pairingID in self?.forgetPairedClient(pairingID: pairingID) })

    lazy var iCloudPairing = PeelICloudHostPairingController(
        pairingStore: pairingStore, hostID: stableHostIdentifier,
        hostName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
        revokePeer: { [weak self] pairingID in
            self?.forgetPairedClient(pairingID: pairingID, blockAccountReenrollment: false)
        })

    var lastPairingToken: String? { network.lastPairingToken }
    var pairingPIN: String { network.pairingPIN }
    var pairingPinExpiresAt: Date { network.pairingPinExpiresAt }
    var connectedClientPairingID: String? { network.connectedClientPairingID }
    var listeningPort: UInt16? { network.listeningPort }
    var preferredListeningPort: UInt16? { network.preferredListeningPort }

    func setPreferredListeningPort(_ port: UInt16?) {
        network.setPreferredListeningPort(port)
        objectWillChange.send()
    }


    @Published var isDiscoverable: Bool = true {
        didSet {
            UserDefaults.standard.set(isDiscoverable, forKey: Self.discoverableDefaultsKey)
            network.setDiscoverable(isDiscoverable)
            iCloudPairing.updateHostAvailability(controlPort: network.listeningPort, discoverable: isDiscoverable)
        }
    }

    @Published var windowEnumerationScope: WindowEnumerationScope = WindowEnumerator.enumerationScope {
        didSet {
            WindowEnumerator.enumerationScope = windowEnumerationScope
            streamer.requestSendWindowList()
        }
    }

    private let log = Logger(subsystem: "com.zephyrstudiosllc.Peel-Host", category: "Host")

    private let focusStateQueue = DispatchQueue(label: "peel.host.focusState")
    private var lastClientActiveWindowId: UInt32?
    private var pendingFocusRequestID = UUID()
    private let clientFocusDebounce: TimeInterval = 0.075
    private var captureModeByWindow: [UInt32: CaptureMode] = [:]

    @Published private(set) var agentBridgeEnabled = UserDefaults.standard.bool(forKey: "peel.ai.allowAgentBridge")
    @Published private(set) var remoteStatusAllowed = UserDefaults.standard.bool(forKey: "peel.ai.allowRemoteStatus")
    var machineStatusSnapshotProvider: ((String) -> PeelMachineStatusMessage?)?
    private var pendingMachineStatus: (request: PeelMachineStatusRequest, session: PeelControlSession, deadline: UInt64)?
    private var lastMachineStatusRequestUptime: UInt64 = 0
    @Published private(set) var agentAuthorizationStatus = "Disabled"
    @Published private(set) var agentBridgeStatus = "Disabled"
    @Published private(set) var agentControlAllowed = false
    @Published private(set) var agentControlStatus = "Agent Control off"
    private lazy var agentWindowControl: PeelAgentWindowControl = {
        let control = PeelAgentWindowControl()
        control.onStatus = { [weak self] in self?.agentControlStatus = $0 }
        return control
    }()

    func setAgentControlAllowed(_ allowed: Bool) {
        guard !ProcessInfo.processInfo.arguments.contains("--peel-preview") else { return }
        agentControlAllowed = allowed
        clearManualAgentAuthorization(reason: allowed ? "Waiting for manual-control permission on the paired client" : "Agent Control stopped")
        if allowed { beginManualAgentAuthorization() }
    }

    /// Local-computer AI access: runtime-only, off at launch, settable only from
    /// Peel's own UI. The bridge reads readiness but has no setter.
    let localComputerAccess = PeelLocalComputerAccess()
    private let localComputerActivity = PeelLocalComputerActivity()
    /// Separate leases, inventory and app IDs: local and paired listings never
    /// replace or validate each other's tokens.
    private lazy var localWindowControl: PeelAgentWindowControl = {
        let control = PeelAgentWindowControl()
        control.onStatus = { [weak self] in self?.localComputerAccess.noteActivity($0) }
        return control
    }()
    private var localAgentWindowInventory = PeelAgentAdvertisedWindowInventory()
    private let localAgentAppCatalog = PeelAgentAppCatalog()
    private var localComputerAccessConfigured = false
    /// The single local control request currently driving input, if any, with
    /// its exact authority. Only that request's deadline may cancel its input.
    private var localControlOwner: (owner: UUID, authority: () -> Bool)?

    func setLocalComputerAccessAllowed(_ allowed: Bool) {
        guard !ProcessInfo.processInfo.arguments.contains("--peel-preview") else { return }
        configureLocalComputerAccess()
        if allowed {
            guard agentBridgeEnabled, !hostIsLockedOrAsleep else { return }
            localComputerAccess.setAllowed(true)
        } else {
            localComputerAccess.setAllowed(false)
        }
        localComputerActivity.update(access: localComputerAccess) { [weak self] in
            self?.setLocalComputerAccessAllowed(false)
        }
    }

    private func configureLocalComputerAccess() {
        guard !localComputerAccessConfigured else { return }
        localComputerAccessConfigured = true
        localComputerAccess.onRevoked = { [weak self] reason in
            guard let self else { return }
            self.localControlOwner = nil
            self.localWindowControl.cancel(input: self.input, reason: "AI access stopped: \(reason)")
            self.localAgentAppCatalog.cancelLaunch()
            self.localAgentAppCatalog.cancelInventory()
            self.localAgentWindowInventory.clear()
            self.localComputerActivity.update(access: self.localComputerAccess) { [weak self] in
                self?.setLocalComputerAccessAllowed(false)
            }
        }
        localComputerActivity.onExternalInput = { [weak self] in
            self?.interruptLocalAgentRequests(reason: "Stopped by your keyboard or mouse; list and inspect again")
        }
    }

    private func revokeLocalComputerAccess(reason: String) {
        guard localComputerAccess.isAllowed else { return }
        configureLocalComputerAccess()
        localComputerAccess.revoke(reason: reason)
    }

    /// A person's input takes precedence. Every pending local request loses its
    /// authority (staged focus stops, inspections and listed tokens are dropped,
    /// an active local operation is cancelled with held input released).
    /// Consent stays on and the person's own input is never blocked.
    private func interruptLocalAgentRequests(reason: String) {
        guard localComputerAccess.isAllowed else { return }
        localComputerAccess.interruptRequests()
        localControlOwner = nil
        localWindowControl.cancel(input: input, reason: reason)
    }

    /// Readiness for the active local control request only, under its own authority.
    private func localControlWindowIsReady(_ windowId: UInt32) -> Bool {
        guard let control = localControlOwner, control.authority() else { return false }
        return accessibility.isExactWindowFocusedForAgentInput(windowId: windowId, authorized: control.authority)
    }

    private var localAgentServer: PeelLocalAgentServer?
    private var localAgentEpoch = UUID()
    private let localAgentLifecycleQueue = DispatchQueue(label: "peel.agent.lifecycle", qos: .utility)
    private let agentTargetSnapshot = PeelAgentTargetSnapshot()
    private let manualAgentTargetSnapshot = PeelAgentTargetSnapshot()
    private var manualAgentAuthorizedSession: PeelControlSession?
    private var pendingManualAgentChallenge: (message: PeelManualAgentControlChallenge, session: PeelControlSession, key: Data)?
    private var agentClientSession: PeelControlSession?
    private var agentClientCapabilities: Set<String> = []
    private lazy var proAdmission: PeelHostProAdmissionController = PeelHostProAdmissionController(
        verifier: PeelCommerceAuthorityClient(origin: Bundle.main.object(forInfoDictionaryKey: "PeelCommerceAuthorityOrigin") as? String),
        isEligible: { [weak self] session in
            guard let self else { return false }
            return !self.hostIsLockedOrAsleep && self.clientIsVisible &&
                self.agentClientSession == session && self.network.isCurrentControlSession(session) &&
                self.agentClientCapabilities.contains(PeelProEntitlementProtocol.capability) &&
                self.pairingStore.paired.contains(where: { $0.id == session.pairingID })
        }, sendChallenge: { [weak self] message, session in
            self?.network.sendTargetedJSONLine(message, session: session) { [weak self] sent in
                if !sent { self?.proAdmission.challengeDeliveryFailed(message, session: session) }
            }
        }, sendStatus: { [weak self] message, session in
            self?.network.sendTargetedJSONLine(message, session: session) { _ in }
        }, onAdmissionEnded: { [weak self] in self?.cancelPaidAgentOperations() })
    private var agentAuthorizedSession: PeelControlSession?
    private var pendingAgentChallenge: (message: PeelAgentPairingChallengeMessage, session: PeelControlSession, key: Data)?
    private lazy var notificationDelivery = PeelAgentNotificationDelivery(network: network) { [weak self] session in
        guard let self else { return false }
        return PeelConnectedAgentAvailability.allows(.notify) && self.commerceAllows(session) &&
            self.agentBridgeEnabled && !self.hostIsLockedOrAsleep && self.clientIsVisible &&
            self.agentAuthorizedSession == session && self.network.isCurrentControlSession(session) &&
            self.agentClientCapabilities.contains(PeelCapability.agentNotificationsV1.rawValue) &&
            self.pairingStore.paired.contains(where: { $0.id == session.pairingID })
    }
    private var agentWindowInventory = PeelAgentAdvertisedWindowInventory()
    private let agentAppCatalog = PeelAgentAppCatalog()
    private var agentAppCatalogScope: PeelControlSession?
    private var pendingAgentPresentations = PeelAgentPendingPresentationTracker()
    private var pendingAgentPresentationContexts: [UUID: AgentPresentationContext] = [:]
    private var agentPresentationExpiryTimer: DispatchSourceTimer?
    private static let agentPresentationDeadlineSafetyNanoseconds: UInt64 = 100_000_000

    private struct AgentPresentationContext {
        let epoch: UUID
        let session: PeelControlSession
        let windowID: UInt32
        let originalDeadlineUptimeNanoseconds: UInt64
        let admissionPermit: PeelHostProAdmissionPermit
        let completion: PeelLocalAgentServer.Completion
    }

    @Published private(set) var systemAudioAllowed = PeelHost.initialSystemAudioAllowed()
    @Published private(set) var systemAudioStatus = "Off"
    @Published private(set) var remoteVoiceAllowed = UserDefaults.standard.bool(forKey: "peel.audio.allowRemoteVoice")
    @Published private(set) var remoteVoiceStatus = PeelHost.initialRemoteVoiceStatus()

    /// Paired-device playback is on unless the user has turned it off. Only an
    /// unset key defaults on; an explicit false stays off. Nothing is written
    /// here, and capture still starts only from a proved client request using
    /// the existing Screen Recording grant. Voice keeps its own opt-in.
    private static func initialSystemAudioAllowed() -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "peel.audio.allowSystemAudio") != nil else { return true }
        return defaults.bool(forKey: "peel.audio.allowSystemAudio")
    }

    private static func initialRemoteVoiceStatus() -> String {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "peel.audio.allowRemoteVoice") else { return "Off" }
        return initialSystemAudioAllowed()
            ? "Not checked"
            : "Off — enable Mac audio in Peel Pro."
    }

    private lazy var audioController = PeelHostAudioController(network: network,
        keyForSession: { [weak self] session in
            guard let self, self.systemAudioAllowed, !self.hostIsLockedOrAsleep,
                  self.clientIsVisible, self.agentClientSession == session,
                  self.agentClientCapabilities.contains(PeelCapability.macSystemAudioV1.rawValue),
                  self.network.isCurrentControlSession(session),
                  self.pairingStore.paired.contains(where: { $0.id == session.pairingID }),
                  let key = self.pairingStore.psk(for: session.pairingID), key.count >= 32 else { return nil }
            return key
        }, voiceAllowed: { [weak self] session in
            guard let self else { return false }
            return self.remoteVoiceAllowed && self.systemAudioAllowed &&
                  self.agentClientSession == session &&
                  self.agentClientCapabilities.contains(PeelCapability.remoteVoiceV1.rawValue)
        }, onStatus: { [weak self] in self?.systemAudioStatus = $0 },
        onVoiceStatus: { [weak self] in self?.remoteVoiceStatus = $0 })

    func setRemoteVoiceAllowed(_ allowed: Bool) {
        remoteVoiceAllowed = allowed
        UserDefaults.standard.set(allowed, forKey: "peel.audio.allowRemoteVoice")
        if allowed {
            remoteVoiceStatus = systemAudioAllowed
                ? "Not checked"
                : "Off — enable Mac audio in Peel Pro."
        } else {
            remoteVoiceStatus = "Off"
            audioController.stop(reason: "Remote microphone input is off")
        }
    }

    func setSystemAudioAllowed(_ allowed: Bool) {
        systemAudioAllowed = allowed
        UserDefaults.standard.set(allowed, forKey: "peel.audio.allowSystemAudio")
        if !allowed {
            audioController.stop(reason: "Off")
            remoteVoiceStatus = remoteVoiceAllowed
                ? "Off — enable Mac audio in Peel Pro."
                : "Off"
        } else if remoteVoiceAllowed {
            remoteVoiceStatus = "Not checked"
        }
    }

    /// Source media keys from the current paired user. Authority facts are
    /// re-read at receipt and immediately before posting.
    private lazy var sourceMedia = PeelSourceMediaController(
        gate: { [weak self] generation in
            guard let self else {
                return PeelSourceMediaGate(session: nil, lockedOrAsleep: true, clientVisible: false,
                                           controlEnabled: false, accessibilityTrusted: false)
            }
            let session = self.agentClientSession.flatMap { session in
                session.generation == generation && self.network.isCurrentControlSession(session) &&
                    self.pairingStore.paired.contains(where: { $0.id == session.pairingID }) ? session : nil
            }
            return PeelSourceMediaGate(session: session, lockedOrAsleep: self.hostIsLockedOrAsleep,
                clientVisible: self.clientIsVisible,
                controlEnabled: UserDefaults.standard.bool(forKey: PeelHost.allowControlThisMacDefaultsKey),
                accessibilityTrusted: AXIsProcessTrusted())
        },
        keys: PeelSourceMediaKeys(),
        volume: PeelSourceVolume(),
        send: { [weak self] reply, session in
            guard let self else { return }
            switch reply {
            case .ack(let message): self.network.sendTargetedJSONLine(message, session: session) { _ in }
            case .volumeState(let message): self.network.sendTargetedJSONLine(message, session: session) { _ in }
            }
        })

    func hostNetworkServer(_ server: HostNetworkServer, audioAttached requestID: String, session: PeelControlSession) {
        audioController.attached(requestID, session: session)
    }

    func hostNetworkServer(_ server: HostNetworkServer, audioClosed requestID: String, session: PeelControlSession) {
        audioController.closed(requestID, session: session)
    }

    private var clientIsVisible: Bool = true
    private var clientHasReportedVisibility: Bool = false
    private var lastClientPingAt: Date = Date()
    private var clientPingMonitor: DispatchSourceTimer?
    private let clientPingMonitorQueue = DispatchQueue(label: "peel.host.clientPingMonitor", qos: .utility)

    private let pingTimeoutSeconds: TimeInterval = 30.0
    private let pingMonitorInterval: TimeInterval = 5.0

    private let awake = HostAwakeController()
    private var preventSleepEnabled = true
    private var lastAwakeShouldHold: Bool = false
    private var lastAwakeKeepDisplay: Bool = false

    private let powerLockObserver = HostPowerLockObserver()
    private var inputPermissionObservation: AnyCancellable?
    private var inputTerminationObservation: AnyCancellable?
    private var hostIsLockedOrAsleep: Bool = false {
        didSet {
            if hostIsLockedOrAsleep {
                proAdmission.invalidate()
                revokeLocalComputerAccess(reason: "Mac locked or asleep")
                input.resetSessionState(reason: .hostLockedOrAsleep)
                clearAgentAuthorization(); audioController.stop(reason: "Mac is locked or asleep")
                sourceMedia.invalidate(clearStreams: false)
            }
            else {
                refreshProAdmission()
                if agentBridgeEnabled || remoteStatusAllowed { beginAgentAuthorization() }
            }
            updateAwakePolicy()
        }
    }

    private let network: HostNetworkServer
    private let accessibility = AccessibilityManager()
    private lazy var input = InputSynthesizer(accessibility: accessibility, eventSink: { event, tap in
        // Source metadata lets the local-access monitor tell Peel's own posts
        // from a person's input. It does not change event type, location or flags.
        event.setIntegerValueField(.eventSourceUserData, value: PeelLocalComputerWindowPolicy.postedEventMarker)
        event.post(tap: tap)
    })
    private let streamer = WindowStreamer()

    override init() {
#if PEEL_HOST_INTEGRATION
        let isPreview = ProcessInfo.processInfo.arguments.contains("--peel-preview")
#else
        let isPreview = false
#endif
        self.network = HostNetworkServer(pairingStore: pairingStore, hostId: {
            if isPreview { return "peel-preview" }
            if let existing = UserDefaults.standard.string(forKey: Self.hostIdDefaultsKey), !existing.isEmpty {
                return existing
            }
            let fresh = UUID().uuidString
            UserDefaults.standard.set(fresh, forKey: Self.hostIdDefaultsKey)
            return fresh
        }(), observesPairing: !isPreview)

        super.init()
        if isPreview {
            statusText = "Preview · Connections paused"
            return
        }

        if UserDefaults.standard.object(forKey: Self.discoverableDefaultsKey) != nil {
            isDiscoverable = UserDefaults.standard.bool(forKey: Self.discoverableDefaultsKey)
        }

        network.delegate = self
        network.setDiscoverable(isDiscoverable)

        wireControllers()
        inputPermissionObservation = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification,
            object: UserDefaults.standard).receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self else { return }
                if self.localWindowControl.isBusy && !self.isLocalControlAllowed() {
                    self.interruptLocalAgentRequests(reason: "Control permission changed; list and inspect again")
                }
                guard !self.isRemoteControlAllowed() else { return }
                // Paired source media queued before the change never applies.
                self.sourceMedia.invalidate(clearStreams: false)
                // With no visible paired client, any defaults write would reset input.
                // A still-authorized local agent operation is not a paired-session
                // permission change; its own predicate is rechecked at every event.
                guard !(self.localWindowControl.isBusy && self.isLocalControlAllowed()) else { return }
                self.input.resetSessionState(reason: .permissionChanged)
            }
        // AppKit posts normal termination on the main thread; release before
        // returning from the notification rather than queuing work after exit.
        inputTerminationObservation = NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                self?.input.resetSessionState(reason: .hostTermination)
                self?.iCloudPairing.shutdown()
            }
        streamer.setTransportMode(.h264Video)
        configurePowerLockObserver()
        network.start()
        if agentBridgeEnabled || remoteStatusAllowed {
            agentAuthorizationStatus = "Waiting for an opted-in Peel client"
        }
        if agentBridgeEnabled { startLocalAgentBridge() }

        print("PeelHost PID:", ProcessInfo.processInfo.processIdentifier)
        print("Bundle:", Bundle.main.bundleURL.path)
        print("Executable:", Bundle.main.executableURL?.path ?? "nil")
    }

    private func wireControllers() {
        configureLocalComputerAccess()
        accessibility.isRemoteControlAllowed = { [weak self] in
            self?.isRemoteControlAllowed() ?? false
        }

        accessibility.sendInputRejected = { [weak self] windowId, reason in
            self?.network.sendJSONLine(InputRejectedMessage(windowId: windowId, reason: reason))
        }

        input.isRemoteControlAllowed = { [weak self] in
            self?.isRemoteControlAllowed() ?? false
        }

        input.isLocalControlAllowed = { [weak self] in
            self?.isLocalControlAllowed() ?? false
        }

        input.isLocalWindowReadyForInput = { [weak self] windowId, _ in
            self?.localControlWindowIsReady(windowId) ?? false
        }

        input.isControlGenerationCurrent = { [weak self] generation in
            self?.inputControlGenerationIsCurrent(generation) ?? false
        }

        input.activeWindowProvider = { [weak self] in
            self?.focusStateQueue.sync { self?.lastClientActiveWindowId }
        }

        input.activeWindowSetter = { [weak self] windowId in
            self?.noteClientActiveWindow(windowId: windowId, reason: "input")
        }

        input.markInput = { [weak self] windowId in
            self?.streamer.markInput(windowId: windowId)
        }

        streamer.sendJSONLine = { [weak self] value in
            self?.network.sendJSONLine(AnyEncodable(value))
        }

        streamer.sendBinaryPacket = { [weak self] windowId, data in
            self?.network.sendVideoPacket(windowId: windowId, data)
        }

        streamer.canAcceptVideoFrame = { [weak self] windowId in
            self?.network.canAcceptVideoFrame(windowId: windowId) ?? false
        }

        streamer.activeWindowProvider = { [weak self] in
            self?.focusStateQueue.sync { self?.lastClientActiveWindowId }
        }

        streamer.captureModeProvider = { [weak self] windowId in
            self?.focusStateQueue.sync { self?.captureModeByWindow[windowId] ?? .composited } ?? .composited
        }

        streamer.focusKick = { [weak self] windowId in
            self?.accessibility.focusAuthoritativeWindowIfNeeded(windowId: windowId, force: true)
        }

        streamer.videoTransportIsAvailable = { [weak self] windowId in
            self?.network.hasVideoTransport(windowId: windowId) ?? false
        }

        network.streamDiagnostics = streamDiagnostics
        streamer.streamDiagnostics = streamDiagnostics
    }

    @discardableResult
    func generatePairingToken(clientLabel: String = "New Client") -> String {
        network.generatePairingToken(clientLabel: clientLabel)
    }

    func refreshPairingPIN() {
        network.refreshPairingPIN()
    }

    func forgetPairedClient(pairingID: String, blockAccountReenrollment: Bool = true) {
        let id = pairingID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, let peer = pairingStore.paired.first(where: { $0.id == id }) else { return }
        PeelICloudMacPairingController.noteExplicitForget(hostID: peer.stableHostId)
        if blockAccountReenrollment { iCloudPairing.noteExplicitRevocation(peer) }
        if agentClientSession?.pairingID == id { proAdmission.invalidate(); sourceMedia.invalidate(clearStreams: false) }

        let shouldDisconnectNow: Bool = {
            if connectedClientPairingID == id { return true }
            if connectedClientPairingID == nil { return true }
            return false
        }()

        if shouldDisconnectNow {
            network.sendJSONLineThenDisconnect(
                PairingRevokedMessage(
                    pairingId: id,
                    deviceId: hostId,
                    reason: "Host unpaired device"
                ),
                reason: "Unpaired device revoked"
            )
        }

        pairingStore.removePeer(pairingID: id)
    }

    private func isRemoteControlAllowed() -> Bool {
        !hostIsLockedOrAsleep && clientIsVisible &&
            UserDefaults.standard.bool(forKey: Self.allowControlThisMacDefaultsKey) && AXIsProcessTrusted()
    }

    /// Local generations are owned only by the current local grant; network
    /// generations only by the current paired control connection.
    private func inputControlGenerationIsCurrent(_ generation: UInt64) -> Bool {
        if InputSynthesizer.isLocalControlGeneration(generation) {
            return localComputerAccess.isCurrentInputGeneration(generation)
        }
        return network.isCurrentControlGeneration(generation)
    }

    /// The same master input gate and Accessibility trust as paired control,
    /// without paired-client visibility, plus the runtime local consent.
    private func isLocalControlAllowed() -> Bool {
        localComputerAccess.isAllowed && agentBridgeEnabled && !hostIsLockedOrAsleep &&
            UserDefaults.standard.bool(forKey: Self.allowControlThisMacDefaultsKey) && AXIsProcessTrusted()
    }

    private func noteClientActiveWindow(windowId: UInt32, reason: String) {
        focusStateQueue.async {
            self.lastClientActiveWindowId = windowId
        }

        streamer.clientActiveWindowDidChange(windowId: windowId)
    }

    private func isCurrentFocusRequest(windowId: UInt32, generation: UInt64, requestID: UUID) -> Bool {
        guard network.isCurrentControlGeneration(generation) else {
            log.notice("Focus discarded reason=staleControlGeneration windowId=\(windowId) generation=\(generation) request=\(requestID.uuidString, privacy: .public)")
            return false
        }
        let isCurrent = focusStateQueue.sync {
            self.pendingFocusRequestID == requestID && self.lastClientActiveWindowId == windowId
        }
        if !isCurrent {
            log.notice("Focus discarded reason=supersededRequest windowId=\(windowId) generation=\(generation) request=\(requestID.uuidString, privacy: .public)")
        }
        return isCurrent
    }

    private func handleClientActiveWindow(_ message: ClientActiveWindowMessage, generation: UInt64) {
        guard network.isCurrentControlGeneration(generation) else { return }
        noteClientActiveWindow(windowId: message.windowId, reason: "clientActiveWindow")
        let requestID = UUID()
        let focusRequestId = message.focusRequestId
        focusStateQueue.sync {
            self.pendingFocusRequestID = requestID
        }
        let controlEnabled = UserDefaults.standard.bool(forKey: Self.allowControlThisMacDefaultsKey)
        let axTrusted = AXIsProcessTrusted()
        log.notice("Focus request windowId=\(message.windowId) generation=\(generation) request=\(requestID.uuidString, privacy: .public) lockedOrAsleep=\(self.hostIsLockedOrAsleep) clientVisible=\(self.clientIsVisible) controlEnabled=\(controlEnabled) axTrusted=\(axTrusted)")

        if WindowEnumerator.isDisplayCaptureWindowId(message.windowId) {
            sendWindowFocusState(
                activeWindowId: message.windowId,
                requestedWindowId: message.windowId,
                didActivateRequestedWindow: true,
                generation: generation,
                requestID: requestID,
                focusRequestId: focusRequestId
            )

            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + clientFocusDebounce) { [weak self] in
            guard let self else { return }
            guard self.isCurrentFocusRequest(windowId: message.windowId, generation: generation, requestID: requestID) else { return }

            let interactionPoint = self.accessibility.authoritativePointFallback(for: message.windowId)

            self.accessibility.bringWindowToFront(
                windowId: message.windowId,
                interactionPoint: interactionPoint
            ) { [weak self] in
                guard let self else { return }

                self.confirmWindowReadyForInput(
                    windowId: message.windowId,
                    interactionPoint: interactionPoint,
                    requestedWindowId: message.windowId,
                    generation: generation,
                    requestID: requestID,
                    focusRequestId: focusRequestId
                )
            }
        }
    }

    private func sendWindowFocusState(
        activeWindowId: UInt32?,
        requestedWindowId: UInt32,
        didActivateRequestedWindow: Bool,
        generation: UInt64,
        requestID: UUID,
        focusRequestId: String? = nil
    ) {
        guard isCurrentFocusRequest(windowId: requestedWindowId, generation: generation, requestID: requestID) else { return }
        let message = WindowFocusStateMessage(
            activeWindowId: activeWindowId,
            requestedWindowId: requestedWindowId,
            didActivateRequestedWindow: didActivateRequestedWindow,
            focusRequestId: focusRequestId
        )
        log.notice("Focus result windowId=\(requestedWindowId) generation=\(generation) request=\(requestID.uuidString, privacy: .public) confirmed=\(didActivateRequestedWindow)")
        network.sendJSONLine(message, generation: generation)
    }
    

    private func confirmWindowReadyForInput(
        windowId: UInt32,
        interactionPoint: CGPoint?,
        requestedWindowId: UInt32,
        generation: UInt64,
        requestID: UUID,
        focusRequestId: String? = nil,
        attempt: Int = 0
    ) {
        guard isCurrentFocusRequest(windowId: windowId, generation: generation, requestID: requestID) else { return }
        let didActivate = accessibility.isWindowReadyForInput(
            windowId: windowId,
            interactionPoint: interactionPoint
        )

        if didActivate || attempt >= 3 {
            let activeWindowId: UInt32? = didActivate ? windowId : nil
            if !didActivate {
                let targetPID = WindowEnumerator.ownerPID(for: windowId) ?? -1
                let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
                let controlEnabled = UserDefaults.standard.bool(forKey: Self.allowControlThisMacDefaultsKey)
                let axTrusted = AXIsProcessTrusted()
                log.notice("Focus rejected windowId=\(windowId) generation=\(generation) request=\(requestID.uuidString, privacy: .public) lockedOrAsleep=\(self.hostIsLockedOrAsleep) clientVisible=\(self.clientIsVisible) controlEnabled=\(controlEnabled) axTrusted=\(axTrusted) targetPID=\(targetPID) frontmostPID=\(frontmostPID)")
            }

            sendWindowFocusState(
                activeWindowId: activeWindowId,
                requestedWindowId: requestedWindowId,
                didActivateRequestedWindow: didActivate,
                generation: generation,
                requestID: requestID,
                focusRequestId: focusRequestId
            )
            return
        }

        let delay: TimeInterval
        switch attempt {
        case 0:
            delay = 0.08
        case 1:
            delay = 0.16
        default:
            delay = 0.28
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.confirmWindowReadyForInput(
                windowId: windowId,
                interactionPoint: interactionPoint,
                requestedWindowId: requestedWindowId,
                generation: generation,
                requestID: requestID,
                focusRequestId: focusRequestId,
                attempt: attempt + 1
            )
        }
    }
    private func ensureWindowIsFrontmostBeforeInput(windowId: UInt32, inputType: String, generation: UInt64) -> Bool {
        guard network.isCurrentControlGeneration(generation) else { return false }
        if WindowEnumerator.isDisplayCaptureWindowId(windowId) {
            return true
        }

        let interactionPoint = accessibility.authoritativePointFallback(for: windowId)

        if accessibility.isWindowReadyForInput(windowId: windowId, interactionPoint: interactionPoint) {
            return true
        }

        print("PeelHost: delaying \(inputType) for window \(windowId); requesting focus first")
        noteClientActiveWindow(windowId: windowId, reason: "preInputFocus")
        let requestID = UUID()
        focusStateQueue.sync {
            self.pendingFocusRequestID = requestID
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            guard self.isCurrentFocusRequest(windowId: windowId, generation: generation, requestID: requestID) else { return }
            self.accessibility.bringWindowToFront(
                windowId: windowId,
                interactionPoint: interactionPoint
            ) { [weak self] in
                guard let self else { return }

                self.confirmWindowReadyForInput(
                    windowId: windowId,
                    interactionPoint: interactionPoint,
                    requestedWindowId: windowId,
                    generation: generation,
                    requestID: requestID,
                    focusRequestId: nil
                )
            }
        }

        return false
    }


    // MARK: - HostNetworkServerDelegate

    func hostNetworkServer(_ server: HostNetworkServer, didReceiveLine line: String) {
        handleLine(line)
    }

    func hostNetworkServer(_ server: HostNetworkServer, didReceiveLine line: String, generation: UInt64) {
        handleLine(line, generation: generation)
    }

    func hostNetworkServerDidConnect(_ server: HostNetworkServer) {
        proAdmission.invalidate()
        input.resetSessionState(reason: .controlConnected)
        receiverDiagnostics.setSession(generation: nil, negotiated: false)
        audioController.stop(reason: "Audio session ended")
        sourceMedia.invalidate(clearStreams: true)
        remoteVoiceStatus = remoteVoiceAllowed
            ? (systemAudioAllowed ? "Not checked" : "Off — enable Mac audio in Peel Pro.")
            : "Off"
        agentClientSession = nil
        agentClientCapabilities = []
        clearAgentAuthorization()
        streamer.resetSessionState()
        Task { @MainActor in
            self.streamDiagnostics.resetSessionMetrics()
            self.streamDiagnostics.lastDisconnectReason = ""
        }
        clientIsVisible = true
        clientHasReportedVisibility = false
        lastClientPingAt = Date()
        startClientPingMonitor()
        updateAwakePolicy()

        // New control connection = new session. Send a fresh enumeration from the host side
        // so the client is not dependent on one lifecycle-timed request.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.streamer.requestSendWindowList()
        }
    }

    func hostNetworkServerDidDisconnect(_ server: HostNetworkServer) {
        proAdmission.invalidate()
        receiverDiagnostics.setSession(generation: nil, negotiated: false)
        audioController.stop(reason: "Audio session ended")
        sourceMedia.invalidate(clearStreams: true)
        remoteVoiceStatus = remoteVoiceAllowed ? "Disconnected" : "Off"
        agentClientSession = nil
        agentClientCapabilities = []
        clearAgentAuthorization()
        streamer.resetSessionState()
        input.resetSessionState(reason: .controlDisconnected)
        Task { @MainActor in
            self.streamDiagnostics.noteDisconnect(reason: self.statusText)
        }
        stopClientPingMonitor()
        clientIsVisible = false
        clientHasReportedVisibility = false
        updateAwakePolicy()
    }

    func hostNetworkServer(_ server: HostNetworkServer, didUpdateStatus status: String) {
        DispatchQueue.main.async {
            self.statusText = status
            self.iCloudPairing.updateHostAvailability(controlPort: server.listeningPort, discoverable: self.isDiscoverable)
        }
    }

    func hostNetworkServer(_ server: HostNetworkServer, didUpdateDiscoveryState state: HostDiscoveryState) {
        DispatchQueue.main.async {
            self.discoveryState = state
        }
    }

    func hostNetworkServer(
        _ server: HostNetworkServer,
        didOpenVideoStreamForWindow windowId: UInt32,
        capabilities: Set<String>,
        streamRequest: PeelVideoStreamRequest?
    ) {
        // Video sockets are torn down with their control connection, so an open
        // socket is a stream of the current session.
        sourceMedia.noteStreamOpened(windowId: windowId)
        guard hostIsLockedOrAsleep == false else { return }
        guard clientIsVisible else { return }

        streamer.setVideoCapabilities(capabilities, windowId: windowId, streamRequest: streamRequest)

        network.sendJSONLine(HostStreamDebugMessage(
            windowId: windowId,
            stage: "host_video_socket_open",
            detail: "requesting snapshot"
        ))

        streamer.requestSnapshot(windowId: windowId)
    }

    func hostNetworkServer(_ server: HostNetworkServer, didCloseVideoStreamForWindow windowId: UInt32) {
        sourceMedia.noteStreamClosed(windowId: windowId)
        streamer.stopStreaming(windowId: windowId)

        network.sendJSONLine(HostStreamDebugMessage(
            windowId: windowId,
            stage: "host_video_socket_closed",
            detail: "stopped stream"
        ))
    }

    // MARK: - Message decode / routing

    private func handleLine(_ line: String, generation: UInt64? = nil) {
        input.withReceivedControlGeneration(generation) {
            handleLineInReceivedSession(line, generation: generation)
        }
    }

    private func logRejectedClientFocusLine(_ line: String, generation: UInt64?, reason: String) {
        guard let data = line.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(MessageEnvelope.self, from: data),
              envelope.type == "clientActiveWindow",
              let message = try? JSONDecoder().decode(ClientActiveWindowMessage.self, from: data) else { return }
        let controlEnabled = UserDefaults.standard.bool(forKey: Self.allowControlThisMacDefaultsKey)
        let axTrusted = AXIsProcessTrusted()
        log.notice("Focus discarded reason=\(reason, privacy: .public) windowId=\(message.windowId) generation=\(generation.map(String.init) ?? "nil", privacy: .public) lockedOrAsleep=\(self.hostIsLockedOrAsleep) clientVisible=\(self.clientIsVisible) controlEnabled=\(controlEnabled) axTrusted=\(axTrusted)")
    }

    private func handleLineInReceivedSession(_ line: String, generation: UInt64?) {
        if let generation, !network.isCurrentControlGeneration(generation) {
            logRejectedClientFocusLine(line, generation: generation, reason: "staleControlGenerationAtReceive")
            return
        }
        guard hostIsLockedOrAsleep == false else {
            logRejectedClientFocusLine(line, generation: generation, reason: "hostLockedOrAsleepAtReceive")
            return
        }
        guard let data = line.data(using: .utf8) else { return }

        let decoder = JSONDecoder()

        do {
            let envelope = try decoder.decode(MessageEnvelope.self, from: data)

            // Treat any valid control message as liveness. Relying only on the explicit
            // ping makes reconnects vulnerable to main-run-loop stalls while the client is
            // actively sending input/window requests.
            lastClientPingAt = Date()

            let isRemoteControlMessage: Bool = {
                switch envelope.type {
                case "mouseClick", "mouseMove", "mouseScroll", "mouseDown", "mouseDrag", "mouseUp",
                     "keyboardText", "keyboardCommand", "keyboardHardwareKey", "keyboardChord", "keyboardMacro",
                     "sourceMediaCommand", "sourceVolumeSet":
                    return true
                default:
                    return false
                }
            }()

            if isRemoteControlMessage, generation == nil { return }
            if isRemoteControlMessage, agentControlAllowed {
                agentWindowControl.cancel(input: input, reason: "Agent stopped by paired user input")
            }
            if isRemoteControlMessage {
                interruptLocalAgentRequests(reason: "Stopped by paired user input; list and inspect again")
            }
            if isRemoteControlMessage && !isRemoteControlAllowed() {
                input.resetSessionState(reason: .controlBlocked)
                print("PeelHost: remote control blocked for message type:", envelope.type)
                // Source media gets a targeted refusal with its exact gate reason.
                if let generation, PeelSourceMediaProtocol.userInputTypes.contains(envelope.type) {
                    sourceMedia.receive(type: envelope.type, data: data, generation: generation, inputBlocked: true)
                }
                return
            }

            switch envelope.type {
            case "requestWindowList",
                 "requestWindowSnapshot",
                 "startStream",
                 "stopStream",
                 "mouseClick",
                 "mouseMove",
                 "mouseScroll",
                 "mouseDown",
                 "mouseDrag",
                 "mouseUp":
                let request = try decoder.decode(PeelRequest.self, from: data)
                handle(request: request)

            case "keyboardText":
                let msg = try decoder.decode(KeyboardTextMessage.self, from: data)
                input.noteDecodedKeyboardText(msg)
                input.handleKeyboardText(msg)

            case "keyboardCommand":
                let msg = try decoder.decode(KeyboardCommandMessage.self, from: data)
                input.handleKeyboardCommand(msg)

            case "keyboardHardwareKey":
                let msg = try decoder.decode(KeyboardHardwareKeyMessage.self, from: data)
                input.handleKeyboardHardwareKey(msg)

            case "keyboardChord":
                let msg = try decoder.decode(KeyboardChordMessage.self, from: data)
                input.handleKeyboardChord(msg)

            case "keyboardMacro":
                let msg = try decoder.decode(KeyboardMacroMessage.self, from: data)
                input.handleKeyboardMacro(msg)

            case "clientVisibility":
                let msg = try decoder.decode(ClientVisibilityMessage.self, from: data)
                let becameVisible = !clientIsVisible && msg.isVisible
                clientHasReportedVisibility = true
                clientIsVisible = msg.isVisible
                if !msg.isVisible { receiverDiagnostics.clearObservation(); input.resetSessionState(reason: .clientHidden) }
                if !msg.isVisible { proAdmission.invalidate(); clearAgentAuthorization(); audioController.stop(reason: "iPad is inactive"); sourceMedia.invalidate(clearStreams: false) }
                else {
                    if becameVisible { refreshProAdmission() }
                    if agentAuthorizedSession == nil, pendingAgentChallenge == nil { beginAgentAuthorization() }
                    if manualAgentAuthorizedSession == nil, pendingManualAgentChallenge == nil { beginManualAgentAuthorization() }
                }
                lastClientPingAt = Date()
                updateAwakePolicy()

            case "clientPing":
                let receivedAt = ProcessInfo.processInfo.systemUptime
                let message = try decoder.decode(ClientPingMessage.self, from: data)
                lastClientPingAt = Date()
                if let probe = message.streamClockProbe, probe.isValid,
                   clientIsVisible, let generation, network.isCurrentControlGeneration(generation),
                   receivedAt - lastStreamClockReplyAt >= 1,
                   agentClientCapabilities.contains(PeelStreamClockReply.capability) {
                    lastStreamClockReplyAt = receivedAt
                    // The media read is inside the uptime bracket. The receiver
                    // retains the full bracket as clock-bridge uncertainty.
                    let mediaSample = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
                    let sentAt = ProcessInfo.processInfo.systemUptime
                    network.sendJSONLine(PeelStreamClockReply(type: "hostStreamClock", probe: probe,
                        hostReceived: receivedAt, hostSent: sentAt,
                        hostMediaClockMinusUptime: mediaSample - receivedAt,
                        verifiedSourceWindowIds: streamer.streamingDiagnostics.verifiedSourceWindowIds()),
                        generation: generation)
                }

            case "clientStreamMetrics":
                guard data.count <= PeelClientStreamMetricsMessage.maximumPayloadBytes,
                      clientIsVisible, let generation, let session = agentClientSession,
                      session.generation == generation, network.isCurrentControlSession(session),
                      agentClientCapabilities.contains(PeelClientStreamMetricsMessage.capability) else { return }
                let message = try decoder.decode(PeelClientStreamMetricsMessage.self, from: data)
                receiverDiagnostics.accept(message, generation: generation)

            case "clientHello":
                let msg = try decoder.decode(ClientHelloMessage.self, from: data)
                guard let generation else { return }
                handleClientHello(msg, generation: generation)

            case "requestVideoKeyframe":
                let msg = try decoder.decode(PeelVideoKeyframeRequestMessage.self, from: data)
                guard clientIsVisible else { return }
                streamer.requestRecoveryKeyframe(windowId: msg.windowId)

            case "sourceMediaCommand", "sourceVolumeQuery", "sourceVolumeSet":
                guard let generation else { return }
                sourceMedia.receive(type: envelope.type, data: data, generation: generation)

            case "audioSessionRequest":
                let msg = try decoder.decode(PeelAudioSessionRequest.self, from: data)
                guard let generation, let session = agentClientSession, session.generation == generation else { return }
                audioController.receive(msg, session: session)

            case "audioPairingProof":
                let msg = try decoder.decode(PeelAudioPairingProofMessage.self, from: data)
                guard let generation else { return }
                audioController.receive(msg, generation: generation)

            case "proEntitlementProof":
                guard let generation,
                      let proof = try? PeelProEntitlementWire.decodeProof(data) else { return }
                proAdmission.receive(proof, generation: generation)

            case "proEntitlementWithdraw":
                guard let generation,
                      let withdrawal = try? PeelProEntitlementWire.decodeWithdrawal(data) else { return }
                proAdmission.receive(withdrawal, generation: generation)

            case "manualAgentControlProof":
                let msg = try decoder.decode(PeelManualAgentControlProofMessage.self, from: data)
                guard let generation else { return }
                handleManualAgentProof(msg, generation: generation)

            case "agentPairingProof":
                let msg = try decoder.decode(PeelAgentPairingProofMessage.self, from: data)
                guard let generation else { return }
                handleAgentPairingProof(msg, generation: generation)

            case "machineStatusRequest":
                let msg = try decoder.decode(PeelMachineStatusRequest.self, from: data)
                guard let generation else { return }
                receiveMachineStatusRequest(msg, generation: generation)

            case "agentNotificationResult":
                let msg = try decoder.decode(PeelAgentNotificationResultMessage.self, from: data)
                guard let generation else { return }
                notificationDelivery.receive(msg, generation: generation)

            case "agentPresentationResult":
                let msg = try decoder.decode(AgentPresentationResultMessage.self, from: data)
                guard let generation else { return }
                handleAgentPresentationResult(msg, generation: generation)

            case "protocolRejected":
                let msg = try decoder.decode(ProtocolRejectedMessage.self, from: data)
                handleProtocolRejected(msg)

            case "pairingRevoked":
                let msg = try decoder.decode(PairingRevokedMessage.self, from: data)
                handlePairingRevoked(msg)

            case "clientActiveWindow":
                guard let generation else {
                    logRejectedClientFocusLine(line, generation: nil, reason: "missingControlGenerationAtReceive")
                    return
                }
                let msg = try decoder.decode(ClientActiveWindowMessage.self, from: data)
                handleClientActiveWindow(msg, generation: generation)

            case "setCaptureMode":
                let msg = try decoder.decode(SetCaptureModeMessage.self, from: data)
                focusStateQueue.async {
                    self.captureModeByWindow[msg.windowId] = msg.captureMode
                }

            case "hostCommand":
                let msg = try decoder.decode(HostCommandMessage.self, from: data)
                handleHostCommand(msg, generation: generation)

            default:
                print("PeelHost: unknown message type:", envelope.type)
            }
        } catch {
            print("PeelHost: failed to decode incoming message:", error.localizedDescription)
        }
    }

    private func handle(request: PeelRequest) {
        guard hostIsLockedOrAsleep == false else { return }

        // Legacy clients may enumerate to repair a missed foreground lifecycle event.
        // Once this control session reports visibility, catalog refreshes must honor it.
        if request.type == "requestWindowList" {
            if !clientHasReportedVisibility {
                clientIsVisible = true
            }
            lastClientPingAt = Date()
            updateAwakePolicy()
            streamer.requestSendWindowList()
            return
        }

        if request.type == "stopStream" {

            if let id = request.windowId {

                sourceMedia.noteStreamStopped(windowId: id)
                streamer.stopStreaming(windowId: id)

            }

            return

        }
        guard clientIsVisible else { return }

        let isUserInput = (request.type == "mouseClick" || request.type == "mouseMove" || request.type == "mouseScroll" || request.type == "mouseDown" || request.type == "mouseDrag" || request.type == "mouseUp")
        if isUserInput && !isRemoteControlAllowed() {
            input.resetSessionState(reason: .controlBlocked)
            if let wid = request.windowId {
                let reason = "Remote control is disabled on this Mac (enable ‘Allow Peel Pro to control this Mac’ and grant Accessibility)."
                network.sendJSONLine(InputRejectedMessage(windowId: wid, reason: reason))
            }
            return
        }

        
        switch request.type {
        case "requestWindowList":
            streamer.requestSendWindowList()

        case "requestWindowSnapshot":
            if let id = request.windowId {
                network.sendJSONLine(HostStreamDebugMessage(
                    windowId: id,
                    stage: "host_received_requestWindowSnapshot",
                    detail: "requesting snapshot"
                ))

                streamer.requestSnapshot(windowId: id)
            }

        case "startStream":
            if let id = request.windowId {
                sourceMedia.noteStreamStarted(windowId: id)
                network.sendJSONLine(HostStreamDebugMessage(
                    windowId: id,
                    stage: "host_received_startStream_control_only",
                    detail: "waiting for per-window video socket"
                ))
            }

        case "stopStream":
            if let id = request.windowId {
                sourceMedia.noteStreamStopped(windowId: id)
                streamer.stopStreaming(windowId: id)
            }
        case "mouseClick":
            if let id = request.windowId, let nx = request.normX, let ny = request.normY {
                input.performClick(windowId: id, normX: nx, normY: ny, button: request.button ?? "left")
            }

        case "mouseMove":
            if let id = request.windowId, let nx = request.normX, let ny = request.normY {
                input.performMouseMove(windowId: id, normX: nx, normY: ny)
            }

        case "mouseScroll":
            if let dy = request.normY {
                let dx = request.normX ?? 0.0
                streamer.markInput(windowId: request.windowId)
                input.performScroll(windowId: request.windowId, deltaX: dx, deltaY: dy)
            }

        case "mouseDown":
            if let id = request.windowId, let nx = request.normX, let ny = request.normY {
                input.performMouseDown(windowId: id, normX: nx, normY: ny, button: request.button ?? "left")
            }

        case "mouseDrag":
            if let id = request.windowId, let nx = request.normX, let ny = request.normY {
                input.performMouseDragged(windowId: id, normX: nx, normY: ny, button: request.button ?? "left")
            }

        case "mouseUp":
            if let id = request.windowId, let nx = request.normX, let ny = request.normY {
                input.performMouseUp(windowId: id, normX: nx, normY: ny, button: request.button ?? "left")
            }

        default:
            print("PeelHost: unknown request type:", request.type)
        }
    }

    // MARK: - Host commands

    private func handleHostCommand(_ message: HostCommandMessage, generation: UInt64?) {
        switch message.command {
        case .openLauncherFolder:
            openLauncherFolder()

        case .openPath:
            guard let path = message.path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
                return
            }
            openPath(path)

        case .closeWindow:
            guard let windowId = message.windowId, let generation else { return }
            DispatchQueue.main.async {
                // Paired authority at the effect: the sending session must still be current.
                guard self.network.isCurrentControlGeneration(generation), self.isRemoteControlAllowed() else { return }
                self.accessibility.closeWindow(windowId: windowId)
                self.refreshWindowListAfterHostWindowAction()
            }

        case .minimizeWindow:
            guard let windowId = message.windowId, let generation else { return }
            DispatchQueue.main.async {
                guard self.network.isCurrentControlGeneration(generation), self.isRemoteControlAllowed() else { return }
                self.accessibility.minimizeWindow(windowId: windowId)
                self.refreshWindowListAfterHostWindowAction()
            }

        case .switchSpaceLeft:
            input.switchSpace(.left)

        case .switchSpaceRight:
            input.switchSpace(.right)
        }
    }

    private func openLauncherFolder() {
        openPath(launcherFolderPath)
    }

    private func openPath(_ path: String) {
        let url = URL(fileURLWithPath: path)

        guard FileManager.default.fileExists(atPath: url.path) else {
            print("PeelHost: openPath failed, path does not exist: \(path)")
            return
        }

        DispatchQueue.main.async {
            if url.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                    print("PeelHost: openApplication \(url.path) error=\(error?.localizedDescription ?? "nil")")
                }
            } else {
                _ = NSWorkspace.shared.open(url)
            }

            self.streamer.requestSendWindowList()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                self.streamer.requestSendWindowList()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.60) {
                self.streamer.requestSendWindowList()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.20) {
                self.streamer.requestSendWindowList()
            }
        }
    }

    private func refreshWindowListAfterHostWindowAction() {
        streamer.requestSendWindowList()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.streamer.requestSendWindowList()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            self.streamer.requestSendWindowList()
        }
    }

    func setAgentBridgeEnabled(_ enabled: Bool) {
        guard !ProcessInfo.processInfo.arguments.contains("--peel-preview") else { return }
        agentBridgeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "peel.ai.allowAgentBridge")
        clearAgentAuthorization()
        stopLocalAgentBridge()
        if enabled { startLocalAgentBridge() }
        if enabled || remoteStatusAllowed { beginAgentAuthorization() }
        if enabled { beginManualAgentAuthorization() }
    }

    func setRemoteStatusAllowed(_ allowed: Bool) {
        guard !ProcessInfo.processInfo.arguments.contains("--peel-preview") else { return }
        remoteStatusAllowed = allowed
        UserDefaults.standard.set(allowed, forKey: "peel.ai.allowRemoteStatus")
        clearAgentAuthorization()
        if agentBridgeEnabled || allowed { beginAgentAuthorization() }
        beginManualAgentAuthorization()
    }

    private func clearAgentAuthorization() {
        clearManualAgentAuthorization(reason: agentControlAllowed ? "Waiting for a visible paired client" : "Agent Control off")
        if let pending = pendingMachineStatus {
            sendMachineStatusError(pending.request.requestId, session: pending.session,
                                   reason: "Mac Status authorization ended. Refresh after reconnecting.")
        }
        pendingMachineStatus = nil
        lastMachineStatusRequestUptime = 0
        agentAppCatalogScope = nil
        agentAppCatalog.cancelLaunch()
        notificationDelivery.cancelAll()
        cancelPendingAgentPresentations(
            code: "target_unavailable",
            message: "Agent presentation authorization ended."
        )
        agentWindowInventory.clear()
        pendingAgentChallenge = nil
        agentAuthorizedSession = nil
        agentTargetSnapshot.set(nil)
        agentAuthorizationStatus = (agentBridgeEnabled || remoteStatusAllowed) ? "Waiting for an opted-in Peel client" : "Disabled"
    }

    /// Product admission is separate from pairing and ordinary user consent.
    /// Ending it cancels paid requests without disturbing existing media streams
    /// or the free Mac Status/audio/paired-user input paths.
    private func cancelPaidAgentOperations() {
        agentAppCatalogScope = nil
        agentAppCatalog.cancelLaunch()
        notificationDelivery.cancelAll()
        cancelPendingAgentPresentations(code: "pro_required", message: "Peel Pro verification is required for this action.")
        agentWindowControl.cancel(input: input, reason: "Peel Pro verification ended")
    }

    private func refreshProAdmission() {
        proAdmission.bind(agentClientSession,
            supportsEvidence: agentClientCapabilities.contains(PeelProEntitlementProtocol.capability))
    }

    private func commerceAllows(_ session: PeelControlSession) -> Bool {
        proAdmission.allows(session)
    }

    private func clearManualAgentAuthorization(reason: String) {
        pendingManualAgentChallenge = nil
        manualAgentAuthorizedSession = nil
        manualAgentTargetSnapshot.set(nil)
        agentWindowControl.cancel(input: input, reason: reason)
    }

    private func beginManualAgentAuthorization() {
        guard agentBridgeEnabled, agentControlAllowed, !hostIsLockedOrAsleep, clientIsVisible,
              agentClientCapabilities.contains(PeelManualAgentControl.capability),
              pendingManualAgentChallenge == nil, manualAgentAuthorizedSession == nil,
              let session = agentClientSession, network.isCurrentControlSession(session),
              pairingStore.paired.contains(where: { $0.id == session.pairingID }),
              let key = pairingStore.psk(for: session.pairingID), key.count >= 32 else { return }
        var nonce = Data(count: 32)
        guard nonce.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }) == errSecSuccess else { return }
        let message = PeelManualAgentControlChallenge(requestId: UUID().uuidString, pairingId: session.pairingID,
            nonce: nonce.base64EncodedString(), expiresAt: Date().timeIntervalSince1970 + 30)
        pendingManualAgentChallenge = (message, session, key)
        agentControlStatus = "Verifying visible-window control permission"
        network.sendTargetedJSONLine(message, session: session) { [weak self] sent in
            guard let self, !sent, self.pendingManualAgentChallenge?.message.requestId == message.requestId else { return }
            self.clearManualAgentAuthorization(reason: "Manual-control proof could not be delivered")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.pendingManualAgentChallenge?.message.requestId == message.requestId else { return }
            self.clearManualAgentAuthorization(reason: "Manual-control proof expired; reconnect to retry")
        }
    }

    private func handleManualAgentProof(_ proof: PeelManualAgentControlProofMessage, generation: UInt64) {
        guard agentBridgeEnabled, agentControlAllowed, !hostIsLockedOrAsleep, clientIsVisible,
              agentClientCapabilities.contains(PeelManualAgentControl.capability),
              let pending = pendingManualAgentChallenge,
              pending.session.generation == generation, pending.session.pairingID == proof.pairingId,
              pending.message.requestId == proof.requestId, agentClientSession == pending.session,
              network.isCurrentControlSession(pending.session),
              pairingStore.paired.contains(where: { $0.id == proof.pairingId }) else { return }
        pendingManualAgentChallenge = nil
        guard proof.type == "manualAgentControlProof", PeelManualAgentControlProof.isFresh(pending.message, now: Date().timeIntervalSince1970),
              PeelManualAgentControlProof.verify(proof.proof, challenge: pending.message, key: pending.key) else {
            clearManualAgentAuthorization(reason: "Manual-control proof failed"); return
        }
        manualAgentAuthorizedSession = pending.session
        manualAgentTargetSnapshot.set(pending.session)
        agentControlStatus = "Agent Control ready — select and stream a window, then inspect"
    }

    private func manualAgentTargetPolicyAllows(epoch: UUID, target: PeelControlSession, deadlineUptimeNanoseconds: UInt64) -> Bool {
        commerceAllows(target) && agentBridgeEnabled && agentControlAllowed && localAgentEpoch == epoch && agentBridgeStatus == "Ready" &&
            !hostIsLockedOrAsleep && clientIsVisible && agentClientSession == target &&
            manualAgentAuthorizedSession == target && manualAgentTargetSnapshot.current() == target &&
            agentClientCapabilities.contains(PeelManualAgentControl.capability) &&
            pairingStore.paired.contains(where: { $0.id == target.pairingID }) && network.isCurrentControlSession(target) &&
            DispatchTime.now().uptimeNanoseconds < deadlineUptimeNanoseconds
    }

    private func beginAgentAuthorization() {
        guard (agentBridgeEnabled || remoteStatusAllowed), !hostIsLockedOrAsleep, clientIsVisible,
              ((agentBridgeEnabled &&
                (agentClientCapabilities.contains(PeelCapability.agentPresentationV1.rawValue) ||
                 agentClientCapabilities.contains(PeelCapability.agentNotificationsV1.rawValue))) ||
               (remoteStatusAllowed && agentClientCapabilities.contains(PeelCapability.machineStatusV1.rawValue))),
              let session = agentClientSession, network.isCurrentControlSession(session),
              pairingStore.paired.contains(where: { $0.id == session.pairingID }),
              let key = pairingStore.psk(for: session.pairingID), key.count >= 32 else { return }
        var nonce = Data(count: 32)
        let randomStatus = nonce.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
        }
        guard randomStatus == errSecSuccess else { return }
        let challenge = PeelAgentPairingChallengeMessage(requestId: UUID().uuidString,
            pairingId: session.pairingID, nonce: nonce.base64EncodedString(),
            expiresAt: Date().timeIntervalSince1970 + 30)
        pendingAgentChallenge = (challenge, session, key)
        agentAuthorizationStatus = "Verifying paired device"
        network.sendTargetedJSONLine(challenge, session: session) { [weak self] sent in
            guard let self, !sent,
                  self.pendingAgentChallenge?.message.requestId == challenge.requestId else { return }
            self.clearAgentAuthorization()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.pendingAgentChallenge?.message.requestId == challenge.requestId else { return }
            self.clearAgentAuthorization()
            self.agentAuthorizationStatus = "Pairing verification expired"
        }
    }

    private func handleAgentPairingProof(_ proof: PeelAgentPairingProofMessage, generation: UInt64) {
        guard (agentBridgeEnabled || remoteStatusAllowed), !hostIsLockedOrAsleep, clientIsVisible,
              let pending = pendingAgentChallenge,
              pending.session.generation == generation,
              pending.session.pairingID == proof.pairingId,
              pending.message.requestId == proof.requestId,
              network.isCurrentControlSession(pending.session),
              pairingStore.paired.contains(where: { $0.id == proof.pairingId }) else { return }
        pendingAgentChallenge = nil
        guard PeelAgentPairingProof.isFresh(pending.message, now: Date().timeIntervalSince1970),
              PeelAgentPairingProof.verify(proof.proof, challenge: pending.message, key: pending.key) else {
            agentAuthorizationStatus = "Pairing verification failed"
            return
        }
        agentAuthorizedSession = pending.session
        agentTargetSnapshot.set(pending.session)
        agentAuthorizationStatus = "Paired device verified"
        completePendingMachineStatus()
    }

    private func machineStatusSessionIsEligible(_ session: PeelControlSession) -> Bool {
        remoteStatusAllowed && !hostIsLockedOrAsleep && clientIsVisible &&
            agentClientSession == session && network.isCurrentControlSession(session) &&
            agentClientCapabilities.contains(PeelCapability.machineStatusV1.rawValue) &&
            pairingStore.paired.contains(where: { $0.id == session.pairingID })
    }

    private func sendMachineStatusError(_ requestID: String, session: PeelControlSession, reason: String) {
        guard network.isCurrentControlSession(session),
              let reply = try? PeelMachineStatusErrorMessage(requestId: requestID, reason: reason) else { return }
        network.sendTargetedJSONLine(reply, session: session) { _ in }
    }

    private func receiveMachineStatusRequest(_ request: PeelMachineStatusRequest, generation: UInt64) {
        guard let session = agentClientSession, session.generation == generation,
              network.isCurrentControlSession(session) else { return }
        guard machineStatusSessionIsEligible(session) else {
            sendMachineStatusError(request.requestId, session: session,
                reason: "Enable Mac Status on both devices, and keep this Peel connection active.")
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        guard pendingMachineStatus == nil else {
            sendMachineStatusError(request.requestId, session: session, reason: "A Mac Status request is already in progress.")
            return
        }
        guard lastMachineStatusRequestUptime == 0 || now &- lastMachineStatusRequestUptime >= 1_000_000_000 else {
            sendMachineStatusError(request.requestId, session: session, reason: "Wait a moment before refreshing Mac Status again.")
            return
        }
        lastMachineStatusRequestUptime = now
        pendingMachineStatus = (request, session, now + 5_000_000_000)
        if agentAuthorizedSession == session {
            completePendingMachineStatus()
        } else {
            if pendingAgentChallenge == nil { beginAgentAuthorization() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, let pending = self.pendingMachineStatus,
                      pending.request.requestId == request.requestId, pending.session == session else { return }
                self.pendingMachineStatus = nil
                self.sendMachineStatusError(request.requestId, session: session,
                    reason: "Pairing verification timed out. Refresh Mac Status to try again.")
            }
        }
    }

    private func completePendingMachineStatus() {
        guard let pending = pendingMachineStatus else { return }
        pendingMachineStatus = nil
        guard machineStatusSessionIsEligible(pending.session),
              agentAuthorizedSession == pending.session,
              DispatchTime.now().uptimeNanoseconds < pending.deadline else {
            sendMachineStatusError(pending.request.requestId, session: pending.session,
                                   reason: "Mac Status authorization expired. Refresh to try again.")
            return
        }
        guard let reply = machineStatusSnapshotProvider?(pending.request.requestId),
              reply.requestId == pending.request.requestId else {
            sendMachineStatusError(pending.request.requestId, session: pending.session,
                reason: "Mac measurements are not available yet. Open Mechanic or Usage on your Mac and refresh.")
            return
        }
        network.sendTargetedJSONLine(reply, session: pending.session,
                                     deadlineUptimeNanoseconds: pending.deadline) { _ in }
    }

    // A short endpoint also fits sockaddr_un when HOME is the app sandbox container.
    var agentBridgeSocketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".peel", isDirectory: true)
            .appendingPathComponent("bridge.sock").path
    }

    private func startLocalAgentBridge() {
        guard localAgentServer == nil, agentBridgeEnabled else { return }
        let epoch = UUID()
        localAgentEpoch = epoch
        let targetSnapshot = agentTargetSnapshot
        let manualSnapshot = manualAgentTargetSnapshot
        let server = PeelLocalAgentServer(configuration: .init(
            socketURL: URL(fileURLWithPath: agentBridgeSocketPath),
            readTimeout: 3, handlerTimeout: 4, writeTimeout: 1
        )) { [weak self] request, completion in
            let target = targetSnapshot.current()
            let manualTarget = manualSnapshot.current()
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    completion(.failure(.init(code: "unavailable", message: "The Mac app has closed.")))
                    return
                }
                self.handleLocalAgentRequest(request, epoch: epoch, target: target, manualTarget: manualTarget, completion: completion)
            }
        }
        localAgentServer = server
        agentBridgeStatus = "Starting"
        localAgentLifecycleQueue.async { [weak self] in
            let failure: String?
            do { try server.start(); failure = nil }
            catch { failure = error.localizedDescription }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.localAgentEpoch == epoch else { return }
                self.agentBridgeStatus = failure.map { "Unavailable: \($0)" } ?? "Ready"
            }
        }
    }

    func stopLocalAgentBridge() {
        revokeLocalComputerAccess(reason: "Agent connection turned off")
        clearManualAgentAuthorization(reason: "Agent bridge stopped")
        localAgentEpoch = UUID()
        agentAppCatalogScope = nil
        agentAppCatalog.cancelLaunch()
        agentTargetSnapshot.set(nil)
        cancelPendingAgentPresentations(
            code: "unavailable",
            message: "The Peel agent connection was disabled."
        )
        agentWindowInventory.clear()
        let server = localAgentServer
        localAgentServer = nil
        agentBridgeStatus = "Disabled"
        localAgentLifecycleQueue.async { try? server?.stop() }
    }

    private func handleLocalAgentRequest(
        _ request: PeelLocalAgentRequest, epoch: UUID, target: PeelControlSession?,
        manualTarget: PeelControlSession? = nil, completion: @escaping PeelLocalAgentServer.Completion
    ) {
        func fail(_ code: String, _ message: String) {
            completion(.failure(.init(code: code, message: message)))
        }
        guard agentBridgeEnabled, localAgentEpoch == epoch,
              agentBridgeStatus == "Ready", !hostIsLockedOrAsleep,
              DispatchTime.now().uptimeNanoseconds < request.deadlineUptimeNanoseconds else {
            fail("unavailable", "The Peel agent connection is disabled, locked or expired.")
            return
        }
        guard PeelConnectedAgentAvailability.allows(request.method) else {
            fail("unavailable", PeelConnectedAgentAvailability.unavailableMessage)
            return
        }
        if request.method == .getStreamDiagnostics {
            guard request.params.isEmpty else { fail("invalid_params", "This tool takes no arguments."); return }
            guard case .object(var snapshot) = streamer.streamingDiagnostics.snapshot() else {
                fail("unavailable", "Streaming measurements are unavailable."); return
            }
            snapshot["schemaVersion"] = .integer(2)
            snapshot["scope"] = .string("host_encoder_local_send_and_receiver")
            snapshot["localVideoTransport"] = network.streamingSendDiagnostics.snapshot()
            snapshot["receiver"] = receiverDiagnostics.snapshot()
            snapshot.removeValue(forKey: "clientReceiveMetrics")
            snapshot.removeValue(forKey: "clientPresentationMetrics")
            completion(.success(.object(snapshot)))
            return
        }
        if request.method == .listDevices {
            guard request.params.isEmpty else { fail("invalid_params", "This tool takes no arguments."); return }
            // Receivers only. A peer can never be addressed by the reserved local
            // target ID; this Mac is reported separately as `localComputer`.
            let devices = pairingStore.paired.prefix(256)
                .filter { !PeelLocalComputerAccess.isLocalTarget($0.id) }.map { peer in
                PeelLocalAgentJSONValue.object([
                    "targetPairingId": .string(peer.id),
                    "name": .string(String(peer.displayName.prefix(120))),
                    "connected": .bool(network.controlSession(pairingID: peer.id) != nil),
                    "controlReady": .bool(agentControlAllowed && isRemoteControlAllowed() && (manualAgentAuthorizedSession.map {
                        $0.pairingID == peer.id && clientIsVisible && network.isCurrentControlSession($0) && commerceAllows($0)
                    } ?? false)),
                    "controlStatus": .string(agentControlStatus),
                    "agentReady": .bool(PeelConnectedAgentAvailability.allows(.presentWindow) && (agentAuthorizedSession.map {
                        $0.pairingID == peer.id && clientIsVisible && network.isCurrentControlSession($0) && commerceAllows($0)
                    } ?? false))
                ])
            }
            completion(.success(.object([
                "devices": .array(devices),
                "sourceHost": agentSourceHostJSON,
                "localComputer": localComputerDeviceJSON,
                "supportedMethods": .array(PeelLocalAgentMethod.allCases
                    .filter { method in
                        PeelConnectedAgentAvailability.allows(method) &&
                            (method == .listDevices || method == .getStreamDiagnostics ||
                             (agentClientSession.map { commerceAllows($0) } ?? false))
                    }
                    .map { .string($0.rawValue) })
            ])))
            return
        }
        if case .string(let requested) = request.params["targetPairingId"],
           PeelLocalComputerAccess.isLocalTarget(requested) {
            // Explicit local-computer route: no receiver, peer proof, renderer
            // telemetry or paid admission is involved, and none is implied.
            handleLocalComputerRequest(request, epoch: epoch, completion: completion)
            return
        }
        guard case .string(let pairingID) = request.params["targetPairingId"],
              !pairingID.isEmpty, pairingID.utf8.count <= 256 else {
            fail("invalid_params", "Specify a paired target device."); return
        }
        let manualScope = request.method == .inspectWindow || request.method == .controlWindow ||
            (request.method == .listWindows && manualTarget != nil)
        let selectedTarget = manualScope ? manualTarget : target
        guard let target = selectedTarget, target.pairingID == pairingID,
              clientIsVisible, network.isCurrentControlSession(target),
              pairingStore.paired.contains(where: { $0.id == pairingID }) else {
            fail("target_unavailable", "Connect this paired Peel device and enable its permission for the requested feature."); return
        }
        guard commerceAllows(target), let admissionPermit = proAdmission.permit(for: target),
              let admissionDeadline = proAdmission.deadlineUptimeNanoseconds(for: target) else {
            fail("pro_required", "Peel Pro verification is required for this action."); return
        }
        // Queued delivery and every later manual/launch policy are bounded by
        // the current admission lease, even when the caller requested more time.
        let request = PeelLocalAgentRequest(version: request.version, id: request.id, method: request.method,
            params: request.params, deadlineUptimeNanoseconds: min(request.deadlineUptimeNanoseconds, admissionDeadline),
            lifetime: request.lifetime)
        if manualScope {
            guard manualAgentTargetPolicyAllows(epoch: epoch, target: target, deadlineUptimeNanoseconds: request.deadlineUptimeNanoseconds) else {
                fail("consent_required", "Enable the separate Visible Window Agent Control permission on both devices and reconnect. Old clients cannot authorize this feature."); return
            }
        } else {
            guard target == agentAuthorizedSession else { fail("target_unavailable", "The agent pairing proof is unavailable."); return }
            if request.method != .notify, !agentClientCapabilities.contains(PeelCapability.agentPresentationV1.rawValue) {
                fail("target_unavailable", "Enable agent window presentation on this paired Peel device."); return
            }
        }
        switch request.method {
        case .listApps:
            guard Set(request.params.keys).isSubset(of: ["targetPairingId", "query"]) else {
                fail("invalid_params", "Use targetPairingId and an optional app-name query."); return
            }
            let query: String
            if let value = request.params["query"] {
                guard case .string(let raw) = value, raw.count <= 120, raw.utf8.count <= 480,
                      !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    fail("invalid_params", "Use an app-name query up to 120 characters."); return
                }
                query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            } else { query = "" }
            switch agentAppCatalog.inventory() {
            case .failure:
                fail("busy", "App inventory is unavailable while another app is opening.")
            case .success(let inventory):
                guard admissionPermit.allows(target), agentTargetPolicyAllows(epoch: epoch, target: target,
                    deadlineUptimeNanoseconds: request.deadlineUptimeNanoseconds) else {
                    agentAppCatalogScope = nil
                    fail("target_unavailable", "The target changed while listing apps."); return
                }
                agentAppCatalogScope = target
                let matches = inventory.applications.filter { app in
                    query.isEmpty || app.displayName.localizedCaseInsensitiveContains(query) ||
                        app.bundleIdentifier.localizedCaseInsensitiveContains(query)
                }
                completion(.success(.object([
                    "apps": .array(matches.prefix(128).map { app in .object([
                        "appId": .string(app.id), "name": .string(String(app.displayName.prefix(120))),
                        "bundleIdentifier": .string(app.bundleIdentifier),
                        "runningPID": app.runningProcessIdentifier.map { .integer(Int64($0)) } ?? .null
                    ]) }),
                    "truncated": .bool(inventory.isTruncated || matches.count > 128)
                ])))
            }
        case .launchApp:
            guard Set(request.params.keys) == ["targetPairingId", "appId"],
                  case .string(let appID) = request.params["appId"],
                  !appID.isEmpty, appID.utf8.count <= 128 else {
                fail("invalid_params", "Specify a listed appId and targetPairingId."); return
            }
            guard agentAppCatalogScope == target, admissionPermit.allows(target),
                  agentPresentationPolicyAllows(epoch: epoch, target: target,
                    deadlineUptimeNanoseconds: request.deadlineUptimeNanoseconds) else {
                fail("app_not_listed", "List apps for this paired device before launching."); return
            }
            agentAppCatalog.launch(applicationID: appID,
                deadlineUptimeNanoseconds: request.deadlineUptimeNanoseconds) { [weak self] result in
                guard let self, admissionPermit.allows(target), self.agentAppCatalogScope == target,
                      self.agentPresentationPolicyAllows(epoch: epoch, target: target,
                        deadlineUptimeNanoseconds: request.deadlineUptimeNanoseconds) else {
                    completion(.failure(.init(code: "target_unavailable", message: "The target changed before launch completed."))); return
                }
                switch result {
                case .launched(let id, let pid):
                    completion(.success(.object([
                        "status": .string("launched"), "appId": .string(id),
                        "processId": pid.map { .integer(Int64($0)) } ?? .null,
                        "nextStep": .string("List windows, then present the matching current window. Launch alone does not open a Peel scene.")
                    ])))
                case .failure(let error):
                    let code: String
                    switch error {
                    case .deadlineExpired, .deadlineExceeded, .deadlineTooFar: code = "timeout"
                    case .applicationIdentityChanged: code = "app_changed"
                    case .applicationIDNotInCurrentInventory, .inventoryUnavailable: code = "app_not_listed"
                    case .launchInProgress: code = "busy"
                    case .cancelled: code = "target_unavailable"
                    case .workspaceFailure, .workspaceReturnedNoApplication: code = "launch_failed"
                    }
                    completion(.failure(.init(code: code, message: "The app could not be opened. Refresh the app list before trying again.")))
                }
            }
        case .listWindows:
            guard Set(request.params.keys) == ["targetPairingId"] else {
                fail("invalid_params", "Only targetPairingId is supported."); return
            }
            let enumeratedWindows = WindowEnumerator.enumerateWindows()
                .sorted { WindowEnumerator.isDisplayCaptureWindowId($0.windowId) && !WindowEnumerator.isDisplayCaptureWindowId($1.windowId) }
            let currentWindows = Array(enumeratedWindows.prefix(PeelAgentAdvertisedWindowInventory.maximumWindows))
            guard admissionPermit.allows(target), (manualScope ? manualAgentTargetPolicyAllows(epoch: epoch, target: target, deadlineUptimeNanoseconds: request.deadlineUptimeNanoseconds) :
                agentTargetPolicyAllows(epoch: epoch, target: target, deadlineUptimeNanoseconds: request.deadlineUptimeNanoseconds)) else {
                fail("target_unavailable", "The device connection changed or the request expired."); return
            }
            let scope = PeelAgentPresentationScope(
                pairingID: target.pairingID,
                generation: target.generation
            )
            agentWindowInventory.replace(
                scope: scope,
                instances: currentWindows.map { agentWindowFingerprint($0) }
            )
            agentWindowControl.replace(scope: scope, instances: currentWindows.map { agentWindowFingerprint($0) })
            completion(.success(.object([
                "windows": .array(currentWindows.map { agentWindowJSON($0) }),
                "targetPairingId": .string(target.pairingID),
                "sourceHost": agentSourceHostJSON,
                "truncated": .bool(enumeratedWindows.count > currentWindows.count)
            ])))
        case .inspectWindow, .controlWindow:
            handleAgentWindowControl(request, epoch: epoch, target: target, admissionPermit: admissionPermit, completion: completion)
        case .presentWindow:
            handleAgentPresentWindow(
                request,
                epoch: epoch,
                target: target,
                admissionPermit: admissionPermit,
                completion: completion
            )
        case .notify:
            notificationDelivery.send(request, session: target, admissionPermit: admissionPermit, completion: completion)
        case .listDevices, .getStreamDiagnostics:
            break
        }
    }

    private func handleAgentWindowControl(_ request: PeelLocalAgentRequest, epoch: UUID,
                                          target: PeelControlSession, admissionPermit: PeelHostProAdmissionPermit,
                                          completion: @escaping PeelLocalAgentServer.Completion) {
        func fail(_ code: String, _ message: String) { completion(.failure(.init(code: code, message: message))) }
        guard agentControlAllowed else { fail("consent_required", "Enable Agent Control in Peel Pro. It is off at every launch and Stop revokes it immediately."); return }
        guard isRemoteControlAllowed() else { fail("permission_required", "Enable Allow Peel Pro to control this Mac and grant Accessibility in macOS Settings."); return }
        guard CGPreflightScreenCaptureAccess() else { fail("permission_required", "Screen Recording permission is required to inspect the exact window."); return }
        guard case .integer(let raw) = request.params["windowId"], raw > 0, raw <= Int64(UInt32.max) else {
            fail("invalid_params", "Use an exact listed uint32 windowId."); return
        }
        let windowID = UInt32(raw)
        guard !WindowEnumerator.isDisplayCaptureWindowId(windowID),
              let window = WindowEnumerator.enumerateWindows().first(where: { $0.windowId == windowID }),
              let bounds = WindowEnumerator.bounds(for: windowID), !bounds.isEmpty,
              agentControlWindowIsOnScreen(windowID: windowID, bounds: bounds) else {
            fail("window_unavailable", "Only an on-screen app window fully within an active display can be controlled. Desktop/offscreen targets are unsupported."); return
        }
        let fingerprint = agentWindowFingerprint(window)
        guard fingerprint.hasDurableIdentity else { fail("window_changed", "This window has no durable app identity."); return }
        let renderer = receiverDiagnostics.agentControlRenderer(windowID: windowID, generation: target.generation)
        guard let rendererID = renderer.id else { fail("presentation_unavailable", renderer.reason); return }
        let context = PeelAgentControlContext(session: target, fingerprint: fingerprint, bounds: bounds, renderer: rendererID,
            validate: { [weak self] in
                guard let self, admissionPermit.allows(target), self.agentControlAllowed,
                      self.manualAgentTargetPolicyAllows(epoch: epoch, target: target, deadlineUptimeNanoseconds: request.deadlineUptimeNanoseconds),
                      self.isRemoteControlAllowed(), CGPreflightScreenCaptureAccess(),
                      self.focusStateQueue.sync(execute: { self.lastClientActiveWindowId }) == windowID,
                      self.network.hasVideoTransport(windowId: windowID),
                      self.receiverDiagnostics.agentControlRenderer(windowID: windowID, generation: target.generation).id == rendererID,
                      WindowEnumerator.ownerPID(for: windowID) == fingerprint.ownerProcessID,
                      WindowEnumerator.bounds(for: windowID) == bounds,
                      self.agentControlWindowIsOnScreen(windowID: windowID, bounds: bounds),
                      let pid = fingerprint.ownerProcessID, let application = NSRunningApplication(processIdentifier: pid),
                      application.bundleIdentifier == fingerprint.appBundleIdentifier,
                      application.launchDate?.timeIntervalSince1970.bitPattern == fingerprint.appLaunchTimeBitPattern,
                      self.accessibility.isExactWindowFocusedForAgentInput(windowId: windowID) else { return false }
                return true
            }, validateEvent: { [weak self] event in
                guard let self, admissionPermit.allows(target) else { return false }
                switch event.type {
                case .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged, .scrollWheel:
                    return bounds.contains(event.location) && self.accessibility.isExactWindowTopmostForAgentInput(windowId: windowID, point: event.location)
                default: return self.accessibility.isExactWindowFocusedForAgentInput(windowId: windowID)
                }
            })
        agentWindowControl.handle(request, context: context, input: input, completion: completion)
    }

    private func agentControlWindowIsOnScreen(windowID: UInt32, bounds: CGRect) -> Bool {
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard rows.contains(where: { ($0[kCGWindowNumber as String] as? UInt32) == windowID &&
            ($0[kCGWindowIsOnscreen as String] as? Bool) == true && ($0[kCGWindowLayer as String] as? Int) == 0 }) else { return false }
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(32, &displayIDs, &count) == .success else { return false }
        return displayIDs.prefix(Int(count)).contains { CGDisplayBounds($0).contains(bounds) }
    }

    // MARK: - Local-computer route (targetPairingId "local")

    private static let localComputerSupportedMethods: [PeelLocalAgentMethod] =
        [.listWindows, .listApps, .launchApp, .presentWindow, .inspectWindow, .controlWindow]

    private func localScreenCaptureAllowed() -> Bool { CGPreflightScreenCaptureAccess() }

    private func localControlPermissions() -> (masterGate: Bool, accessibility: Bool) {
        (UserDefaults.standard.bool(forKey: Self.allowControlThisMacDefaultsKey), AXIsProcessTrusted())
    }

    private var localComputerName: String {
        String((Host.current().localizedName ?? "This Mac").prefix(120))
    }

    /// Readiness reflects the real gates checked on every request. It is
    /// candidate readiness only; each call rechecks identity and permissions.
    private var localComputerDeviceJSON: PeelLocalAgentJSONValue {
        let permissions = localControlPermissions()
        let capture = localScreenCaptureAllowed()
        let route = localComputerAccess.isAllowed && agentBridgeEnabled &&
            agentBridgeStatus == "Ready" && !hostIsLockedOrAsleep
        var missing: [PeelLocalAgentJSONValue] = []
        if !localComputerAccess.isAllowed { missing.append(.string("localAccessConsent")) }
        if hostIsLockedOrAsleep { missing.append(.string("unlocked")) }
        if !capture { missing.append(.string("screenRecording")) }
        if !permissions.masterGate { missing.append(.string("allowControlThisMac")) }
        if !permissions.accessibility { missing.append(.string("accessibility")) }
        return .object([
            "targetPairingId": .string(PeelLocalComputerAccess.targetID),
            "kind": .string("local"),
            "platform": .string("macOS"),
            "name": .string(localComputerName),
            "accessReady": .bool(route),
            "inspectReady": .bool(route && capture),
            "controlReady": .bool(route && capture && permissions.masterGate && permissions.accessibility),
            "missing": .array(missing),
            "status": .string(localComputerAccess.status),
            "supportedMethods": .array(Self.localComputerSupportedMethods.map { .string($0.rawValue) })
        ])
    }

    /// Every local admission and effect boundary: bridge, epoch, unlocked,
    /// current grant, request deadline and a still-open caller. A supported
    /// SHUT_WR request half-close keeps the lifetime active.
    private func localAgentPolicyAllows(epoch: UUID, scope: PeelAgentPresentationScope,
                                        request: PeelLocalAgentRequest) -> Bool {
        agentBridgeEnabled && localAgentEpoch == epoch && agentBridgeStatus == "Ready" &&
            !hostIsLockedOrAsleep && localComputerAccess.isCurrent(scope: scope) &&
            DispatchTime.now().uptimeNanoseconds < request.deadlineUptimeNanoseconds &&
            request.lifetime.isActive
    }

    /// The exact authority of one local request: its policy plus its own owner.
    private func localRequestAuthority(owner: UUID, epoch: UUID, scope: PeelAgentPresentationScope,
                                       request: PeelLocalAgentRequest, requiresControl: Bool) -> () -> Bool {
        { [weak self] in
            guard let self else { return false }
            return self.localAgentPolicyAllows(epoch: epoch, scope: scope, request: request) &&
                self.localComputerAccess.isAuthorityCurrent(owner) &&
                (!requiresControl || self.isLocalControlAllowed())
        }
    }

    /// One local focus request's authority bound to the exact advertised window:
    /// still eligible, the same window-server row and fingerprint, and the same
    /// owning PID, bundle and launch. Checked at entry, before preselect,
    /// activation and every raise or stage, and again by the completion.
    private func localFocusAuthority(_ requestAuthority: @escaping () -> Bool, windowID: UInt32,
                                     advertised: PeelAgentWindowInstanceFingerprint) -> () -> Bool {
        { [weak self] in
            guard let self, requestAuthority(), self.localWindowIsEligible(advertised),
                  let row = self.localFocusWindowRow(windowID: windowID),
                  self.agentWindowFingerprint(row) == advertised else { return false }
            return self.localApplicationMatches(advertised)
        }
    }

    /// The current window-server row of one window, shaped like its listing
    /// entry but without the full enumeration's AX and pixel passes, so it is
    /// cheap enough to recheck before every staged focus effect.
    private func localFocusWindowRow(windowID: UInt32) -> PeelWindow? {
        guard let row = PeelLocalWindowInventory.row(windowID: windowID) else { return nil }
        return PeelLocalWindowInventory.entry(row, application: PeelLocalWindowInventory.runningApplication)?.window
    }

    /// The local listing: one on-screen window-server metadata read and
    /// running-app lookups, parsed like `localFocusWindowRow`. The remote
    /// enumeration's global AX, per-window pixel and icon passes are not run.
    private func localWindowListing() -> [PeelLocalWindowInventory.Entry] {
        PeelLocalWindowInventory.entries(PeelLocalWindowInventory.onScreenRows(),
                                         application: PeelLocalWindowInventory.runningApplication)
    }

    private func localWindowIsEligible(_ fingerprint: PeelAgentWindowInstanceFingerprint) -> Bool {
        PeelLocalComputerWindowPolicy.isEligible(fingerprint,
            ownProcessID: ProcessInfo.processInfo.processIdentifier,
            ownBundleIdentifier: Bundle.main.bundleIdentifier)
    }

    private func localApplicationMatches(_ fingerprint: PeelAgentWindowInstanceFingerprint) -> Bool {
        guard let pid = fingerprint.ownerProcessID,
              let application = NSRunningApplication(processIdentifier: pid) else { return false }
        return application.bundleIdentifier == fingerprint.appBundleIdentifier &&
            application.launchDate?.timeIntervalSince1970.bitPattern == fingerprint.appLaunchTimeBitPattern
    }

    private func localWindowJSON(_ window: PeelWindow, fingerprint: PeelAgentWindowInstanceFingerprint,
                                 inspectable: Bool) -> PeelLocalAgentJSONValue {
        .object([
            "windowId": .integer(Int64(window.windowId)),
            "appName": .string(String(window.appName.prefix(120))),
            "title": .string(String(window.title.prefix(256))),
            "width": .integer(Int64(window.width)),
            "height": .integer(Int64(window.height)),
            "kind": .string("window"),
            "canPresent": .bool(true),
            "canInspect": .bool(inspectable),
            "windowToken": localWindowControl.token(windowID: window.windowId).map { .string($0) } ?? .null,
            "controlRequires": .string("Local AI access, Allow Peel Pro to control this Mac, Accessibility, Screen Recording, presentWindow focus and a fresh inspectWindow"),
            "appBundleIdentifier": fingerprint.appBundleIdentifier.map { .string($0) } ?? .null
        ])
    }

    private static func localLaunchErrorCode(_ error: PeelAgentAppLaunchError) -> String {
        switch error {
        case .deadlineExpired, .deadlineExceeded, .deadlineTooFar: return "timeout"
        case .applicationIdentityChanged: return "app_changed"
        case .applicationIDNotInCurrentInventory, .inventoryUnavailable: return "app_not_listed"
        case .launchInProgress: return "busy"
        case .cancelled: return "target_unavailable"
        case .workspaceFailure, .workspaceReturnedNoApplication: return "launch_failed"
        }
    }

    /// Completes on the main actor exactly once and always releases this
    /// request's own authority. Its deadline cancels only this request's own
    /// authority and, if it is the active local control owner, its own input.
    private func localRequestFinisher(owner: UUID, deadlineUptimeNanoseconds: UInt64,
                                      completion: @escaping PeelLocalAgentServer.Completion) -> PeelLocalAgentServer.Completion {
        let once = PeelLocalRequestCompletion()
        let finish: PeelLocalAgentServer.Completion = { [weak self] result in
            let deliver: @Sendable () -> Void = { [weak self] in
                MainActor.assumeIsolated {
                    guard once.claim() else { return }
                    self?.endLocalRequest(owner)
                    completion(result)
                }
            }
            if Thread.isMainThread { deliver() } else { DispatchQueue.main.async(execute: deliver) }
        }
        let now = DispatchTime.now().uptimeNanoseconds
        let remaining = deadlineUptimeNanoseconds > now ? deadlineUptimeNanoseconds - now : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(min(remaining, 30_000_000_000)))) { [weak self] in
            MainActor.assumeIsolated {
                guard !once.isCompleted, let self else { return }
                self.localComputerAccess.endAuthority(owner)
                if self.localControlOwner?.owner == owner {
                    // Only this request's own input; another request is never touched.
                    self.localControlOwner = nil
                    self.localWindowControl.cancel(input: self.input, reason: "Local request deadline reached; inspect before retrying")
                }
            }
            finish(.failure(.init(code: "timeout", message: "The local request did not finish before its deadline. Inspect before retrying.")))
        }
        return finish
    }

    private func endLocalRequest(_ owner: UUID) {
        localComputerAccess.endAuthority(owner)
        if localControlOwner?.owner == owner { localControlOwner = nil }
    }

    private func handleLocalComputerRequest(_ request: PeelLocalAgentRequest, epoch: UUID,
                                            completion: @escaping PeelLocalAgentServer.Completion) {
        func fail(_ code: String, _ message: String) { completion(.failure(.init(code: code, message: message))) }
        guard localComputerAccess.isAllowed else {
            fail("consent_required", "Turn on “Allow AI to use apps on this Mac” in Peel Pro › Remote Desktop › Share This Mac. It is off at every launch and an agent cannot turn it on.")
            return
        }
        let scope = localComputerAccess.scope
        let deadline = request.deadlineUptimeNanoseconds
        guard localAgentPolicyAllows(epoch: epoch, scope: scope, request: request) else {
            fail("target_unavailable", "Local AI access changed, the Mac is locked or the request expired."); return
        }
        let params = request.params
        switch request.method {
        case .listWindows:
            guard Set(params.keys) == ["targetPairingId"] else {
                fail("invalid_params", "Only targetPairingId is supported."); return
            }
            let eligible = localWindowListing()
                .filter { localWindowIsEligible($0.1) }
            let current = Array(eligible.prefix(PeelAgentAdvertisedWindowInventory.maximumWindows))
            guard localAgentPolicyAllows(epoch: epoch, scope: scope, request: request) else {
                fail("target_unavailable", "Local AI access changed while listing windows."); return
            }
            localAgentWindowInventory.replace(scope: scope, instances: current.map(\.1))
            localWindowControl.replace(scope: scope, instances: current.map(\.1))
            let inspectable = localScreenCaptureAllowed()
            completion(.success(.object([
                "windows": .array(current.map { localWindowJSON($0.0, fingerprint: $0.1, inspectable: inspectable) }),
                "targetPairingId": .string(PeelLocalComputerAccess.targetID),
                "sourceHost": agentSourceHostJSON,
                "truncated": .bool(eligible.count > current.count)
            ])))
        case .listApps:
            guard Set(params.keys).isSubset(of: ["targetPairingId", "query"]) else {
                fail("invalid_params", "Use targetPairingId and an optional app-name query."); return
            }
            var query = ""
            if let value = params["query"] {
                guard case .string(let raw) = value, raw.count <= 120, raw.utf8.count <= 480,
                      !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    fail("invalid_params", "Use an app-name query up to 120 characters."); return
                }
                query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // Filesystem and bundle reads run off the main actor; IDs are
            // published only while this request's policy still holds.
            localAgentAppCatalog.inventory(query: query, deadlineUptimeNanoseconds: deadline, isCurrent: { [weak self] in
                self?.localAgentPolicyAllows(epoch: epoch, scope: scope, request: request) ?? false
            }) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(.launchInProgress), .failure(.identifierGenerationFailed):
                    fail("busy", "App inventory is unavailable while another app is opening.")
                case .failure(.scanCapacityExhausted):
                    fail("busy", "Earlier app scans have not finished yet. Try again shortly.")
                case .failure(.deadlineExpired):
                    self.localComputerAccess.replaceAdvertisedApps([])
                    fail("timeout", "The app list did not finish before the request deadline.")
                case .failure(.cancelled):
                    self.localComputerAccess.replaceAdvertisedApps([])
                    fail("target_unavailable", "Local AI access changed while listing apps.")
                case .success(let inventory):
                    guard self.localAgentPolicyAllows(epoch: epoch, scope: scope, request: request) else {
                        self.localComputerAccess.replaceAdvertisedApps([])
                        fail("target_unavailable", "Local AI access changed while listing apps."); return
                    }
                    let ownBundle = Bundle.main.bundleIdentifier
                    let matches = inventory.applications.filter { app in
                        PeelLocalComputerWindowPolicy.isEligibleApplication(bundleIdentifier: app.bundleIdentifier,
                                                                           ownBundleIdentifier: ownBundle) &&
                        (query.isEmpty || app.displayName.localizedCaseInsensitiveContains(query) ||
                            app.bundleIdentifier.localizedCaseInsensitiveContains(query))
                    }
                    let returned = Array(matches.prefix(128))
                    // Only IDs actually returned to the agent are launchable.
                    self.localComputerAccess.replaceAdvertisedApps(returned.map(\.id))
                    completion(.success(.object([
                        "apps": .array(returned.map { app in .object([
                            "appId": .string(app.id), "name": .string(String(app.displayName.prefix(120))),
                            "bundleIdentifier": .string(app.bundleIdentifier),
                            "runningPID": app.runningProcessIdentifier.map { .integer(Int64($0)) } ?? .null
                        ]) }),
                        "targetPairingId": .string(PeelLocalComputerAccess.targetID),
                        "truncated": .bool(inventory.isTruncated || matches.count > returned.count)
                    ])))
                }
            }
        case .launchApp:
            guard Set(params.keys) == ["targetPairingId", "appId"],
                  case .string(let appID) = params["appId"], !appID.isEmpty, appID.utf8.count <= 128 else {
                fail("invalid_params", "Specify targetPairingId \"local\" and a listed appId."); return
            }
            guard localComputerAccess.isAdvertisedApp(appID) else {
                fail("app_not_listed", "List apps for the local target before launching."); return
            }
            guard localAgentPolicyAllows(epoch: epoch, scope: scope, request: request) else {
                fail("target_unavailable", "The local request closed or expired before launch."); return
            }
            localComputerAccess.noteActivity("Opening an app")
            localAgentAppCatalog.launch(applicationID: appID, deadlineUptimeNanoseconds: deadline) { [weak self] result in
                guard let self, self.localAgentPolicyAllows(epoch: epoch, scope: scope, request: request) else {
                    completion(.failure(.init(code: "target_unavailable", message: "Local AI access changed before launch completed."))); return
                }
                switch result {
                case .launched(let id, let pid):
                    completion(.success(.object([
                        "status": .string("launched"), "appId": .string(id),
                        "processId": pid.map { .integer(Int64($0)) } ?? .null,
                        "targetPairingId": .string(PeelLocalComputerAccess.targetID),
                        "nextStep": .string("List windows for the local target, present the matching window to focus it, then inspect it.")
                    ])))
                case .failure(let error):
                    completion(.failure(.init(code: Self.localLaunchErrorCode(error),
                        message: "The app could not be opened. Refresh the app list before trying again.")))
                }
            }
        case .presentWindow:
            let keys = Set(params.keys)
            if keys.contains("title") || keys.contains("customTitle") || keys.contains("displayId") {
                fail("unsupported", "Custom titles and display IDs are not supported."); return
            }
            guard keys.isSubset(of: ["targetPairingId", "windowId", "context"]),
                  keys.isSuperset(of: ["targetPairingId", "windowId"]),
                  case .integer(let raw) = params["windowId"], raw > 0, raw <= Int64(UInt32.max) else {
                fail("invalid_params", "Specify targetPairingId \"local\", a listed windowId and optional context."); return
            }
            var contextText: String?
            if let value = params["context"] {
                guard case .string(let text) = value, text.count <= 1000, text.utf8.count <= 4000,
                      text.unicodeScalars.allSatisfy({ $0.value >= 32 || $0 == "\n" || $0 == "\t" }) else {
                    fail("invalid_params", "Context must be plain text up to 1000 characters."); return
                }
                contextText = text
            }
            let windowID = UInt32(raw)
            guard let advertised = localAgentWindowInventory.advertisedInstance(windowID: windowID, scope: scope) else {
                fail("window_not_listed", "List windows for the local target before presenting this window."); return
            }
            let permissions = localControlPermissions()
            guard isLocalControlAllowed(), permissions.masterGate, permissions.accessibility else {
                fail("permission_required", "Bringing a window forward needs “Allow Peel Pro to control this Mac” and Accessibility permission."); return
            }
            guard let fresh = localFocusWindowRow(windowID: windowID),
                  agentWindowFingerprint(fresh) == advertised, localWindowIsEligible(advertised) else {
                fail("window_changed", "The listed window changed. List windows and try again."); return
            }
            guard localAgentPolicyAllows(epoch: epoch, scope: scope, request: request) else {
                fail("target_unavailable", "The local request closed or expired before focusing."); return
            }
            let owner = localComputerAccess.beginAuthority()
            let requestAuthority = localRequestAuthority(owner: owner, epoch: epoch, scope: scope, request: request, requiresControl: true)
            let authority = localFocusAuthority(requestAuthority, windowID: windowID, advertised: advertised)
            let finish = localRequestFinisher(owner: owner, deadlineUptimeNanoseconds: deadline, completion: completion)
            let summary = contextText.map { "AI: " + $0.replacingOccurrences(of: "\n", with: " ") }
            localComputerAccess.noteActivity(summary ?? "AI is focusing \(advertised.appName)")
            // Every staged activation/raise rechecks this request's own authority
            // and the exact advertised window and app instance; a person's input,
            // Stop, close, deadline, revocation or a replaced window ends it.
            accessibility.bringWindowToFrontForLocalAgent(windowId: windowID, authorized: authority) { [weak self] focused in
                guard let self else { return }
                guard authority(),
                      let current = self.localFocusWindowRow(windowID: windowID),
                      self.agentWindowFingerprint(current) == advertised else {
                    finish(.failure(.init(code: "target_unavailable", message: "Local AI access, your input or the window changed while focusing.")))
                    return
                }
                guard focused else {
                    finish(.failure(.init(code: "focus_refused", message: "macOS did not bring this exact window forward. It may be on another Space, minimized, or the app refused focus. Click the window to bring it forward, then inspect it.")))
                    return
                }
                finish(.success(.object([
                    "status": .string("focused"), "windowId": .integer(Int64(windowID)),
                    "targetPairingId": .string(PeelLocalComputerAccess.targetID),
                    "nextStep": .string("Inspect this window, then perform one bounded action with its inspectionId.")
                ])))
            }
        case .inspectWindow, .controlWindow:
            handleLocalWindowControl(request, epoch: epoch, scope: scope, completion: completion)
        case .notify:
            fail("unsupported", "Notifications go to paired devices only; the local Mac target has no notify method.")
        case .listDevices, .getStreamDiagnostics:
            fail("invalid_params", "This method takes no target.")
        }
    }

    private func handleLocalWindowControl(_ request: PeelLocalAgentRequest, epoch: UUID, scope: PeelAgentPresentationScope,
                                          completion: @escaping PeelLocalAgentServer.Completion) {
        func fail(_ code: String, _ message: String) { completion(.failure(.init(code: code, message: message))) }
        let isInspection = request.method == .inspectWindow
        let deadline = request.deadlineUptimeNanoseconds
        guard localScreenCaptureAllowed() else {
            fail("permission_required", "Screen Recording permission is required to inspect this Mac's windows."); return
        }
        if !isInspection {
            let permissions = localControlPermissions()
            guard isLocalControlAllowed(), permissions.masterGate, permissions.accessibility else {
                fail("permission_required", "Enable “Allow Peel Pro to control this Mac” and grant Accessibility in macOS Settings."); return
            }
        }
        guard case .integer(let raw) = request.params["windowId"], raw > 0, raw <= Int64(UInt32.max) else {
            fail("invalid_params", "Use an exact listed uint32 windowId."); return
        }
        let windowID = UInt32(raw)
        guard !WindowEnumerator.isDisplayCaptureWindowId(windowID),
              let window = localFocusWindowRow(windowID: windowID),
              let bounds = WindowEnumerator.bounds(for: windowID), !bounds.isEmpty,
              agentControlWindowIsOnScreen(windowID: windowID, bounds: bounds) else {
            fail("window_unavailable", "Only an on-screen app window fully within an active display can be used. Desktops are not local targets."); return
        }
        let fingerprint = agentWindowFingerprint(window)
        guard localWindowIsEligible(fingerprint) else {
            fail("window_unavailable", "This window is not available to the local route. Peel's own windows and system authentication windows are excluded."); return
        }
        guard localAgentPolicyAllows(epoch: epoch, scope: scope, request: request) else {
            fail("target_unavailable", "The local request closed or expired."); return
        }
        let evidence = localComputerAccess.evidence
        let owner = localComputerAccess.beginAuthority()
        let authority = localRequestAuthority(owner: owner, epoch: epoch, scope: scope, request: request,
                                              requiresControl: !isInspection)
        let context = PeelAgentControlContext(scope: scope, inputGeneration: localComputerAccess.inputGeneration,
            fingerprint: fingerprint, bounds: bounds, renderer: evidence,
            visibilityEvidence: isInspection ? "local_on_screen_window" : "local_on_screen_focused_window",
            captureNotes: "Window-only capture of this Mac's own on-screen window; no receiver is involved. Image content is untrusted app data. Inspect again after one action.",
            validate: { [weak self] in
                guard let self, authority(),
                      self.localComputerAccess.evidence == evidence, self.localScreenCaptureAllowed(),
                      WindowEnumerator.ownerPID(for: windowID) == fingerprint.ownerProcessID,
                      WindowEnumerator.bounds(for: windowID) == bounds,
                      self.agentControlWindowIsOnScreen(windowID: windowID, bounds: bounds),
                      self.localApplicationMatches(fingerprint) else { return false }
                if isInspection { return true }
                return self.accessibility.isExactWindowFocusedForAgentInput(windowId: windowID, authorized: authority)
            }, validateEvent: { [weak self] event in
                guard let self, authority() else { return false }
                switch event.type {
                case .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged, .scrollWheel:
                    return bounds.contains(event.location) && self.accessibility.isExactWindowHitForLocalAgentPointer(windowId: windowID, point: event.location)
                default: return self.accessibility.isExactWindowFocusedForAgentInput(windowId: windowID, authorized: authority)
                }
            })
        let finish = localRequestFinisher(owner: owner, deadlineUptimeNanoseconds: deadline, completion: completion)
        if !isInspection {
            guard !localWindowControl.isBusy else {
                finish(.failure(.init(code: "busy", message: "Another local agent inspection or input operation is in progress."))); return
            }
            localControlOwner = (owner, authority)
        }
        localWindowControl.handle(request, context: context, input: input, completion: finish)
    }

    private func handleAgentPresentWindow(
        _ request: PeelLocalAgentRequest,
        epoch: UUID,
        target: PeelControlSession,
        admissionPermit: PeelHostProAdmissionPermit,
        completion: @escaping PeelLocalAgentServer.Completion
    ) {
        func fail(_ code: String, _ message: String) {
            completion(.failure(.init(code: code, message: message)))
        }

        let parameterKeys = Set(request.params.keys)
        if parameterKeys.contains("title") || parameterKeys.contains("customTitle") {
            fail("unsupported", "Custom presentation titles are not supported.")
            return
        }
        if parameterKeys.contains("displayId") {
            fail("unsupported", "Display presentation IDs are not supported.")
            return
        }
        guard parameterKeys.isSubset(of: ["targetPairingId", "windowId", "context"]),
              parameterKeys.isSuperset(of: ["targetPairingId", "windowId"]),
              let windowIDValue = request.params["windowId"],
              case .integer(let rawWindowID) = windowIDValue,
              rawWindowID >= 0,
              rawWindowID <= Int64(UInt32.max) else {
            fail("invalid_params", "Specify targetPairingId, a listed windowId and optional context.")
            return
        }
        if let value = request.params["context"] {
            guard case .string(let context) = value, context.count <= 1000, context.utf8.count <= 4000,
                  context.unicodeScalars.allSatisfy({ $0.value >= 32 || $0 == "\n" || $0 == "\t" }) else {
                fail("invalid_params", "Context must be plain text up to 1000 characters."); return
            }
        }

        let windowID = UInt32(rawWindowID)
        let scope = PeelAgentPresentationScope(
            pairingID: target.pairingID,
            generation: target.generation
        )
        guard let advertised = agentWindowInventory.advertisedInstance(
            windowID: windowID,
            scope: scope
        ) else {
            fail("window_not_listed", "List windows again before presenting this window.")
            return
        }
        if advertised.isDisplay {
            guard let displayID = advertised.displayID, CGDisplayIsActive(displayID) != 0 else {
                fail("window_changed", "This desktop is no longer available."); return
            }
        } else if !advertised.hasDurableIdentity {
            fail("unsupported", "A durable app instance identity is unavailable for this window.")
            return
        }
        guard admissionPermit.allows(target), agentPresentationPolicyAllows(
            epoch: epoch,
            target: target,
            deadlineUptimeNanoseconds: request.deadlineUptimeNanoseconds
        ) else {
            fail("target_unavailable", "The target changed or the request expired.")
            return
        }

        let freshWindows = WindowEnumerator.enumerateWindows()
        guard let freshWindow = freshWindows.first(where: { $0.windowId == windowID }),
              agentWindowFingerprint(freshWindow) == advertised else {
            fail("window_changed", "The listed window changed. List windows and try again.")
            return
        }
        guard admissionPermit.allows(target), agentPresentationPolicyAllows(
            epoch: epoch,
            target: target,
            deadlineUptimeNanoseconds: request.deadlineUptimeNanoseconds
        ) else {
            fail("target_unavailable", "The target changed or the request expired.")
            return
        }

        beginAgentPresentationDelivery(
            request: request,
            epoch: epoch,
            target: target,
            admissionPermit: admissionPermit,
            freshWindow: freshWindow,
            expectedFingerprint: advertised,
            currentWindows: freshWindows,
            completion: completion
        )
    }

    private func beginAgentPresentationDelivery(
        request: PeelLocalAgentRequest,
        epoch: UUID,
        target: PeelControlSession,
        admissionPermit: PeelHostProAdmissionPermit,
        freshWindow: PeelWindow,
        expectedFingerprint: PeelAgentWindowInstanceFingerprint,
        currentWindows: [PeelWindow],
        completion: @escaping PeelLocalAgentServer.Completion
    ) {
        let windowList: WindowListMessage
        do {
            windowList = try PeelAgentWindowDelivery.currentList(currentWindows)
        } catch {
            completion(.failure(.init(
                code: "payload_too_large",
                message: "The complete window list cannot be delivered safely."
            )))
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        let originalDeadline = request.deadlineUptimeNanoseconds
        let safety = Self.agentPresentationDeadlineSafetyNanoseconds
        guard admissionPermit.allows(target), originalDeadline > now,
              originalDeadline - now > safety,
              agentPresentationPolicyAllows(
                epoch: epoch,
                target: target,
                deadlineUptimeNanoseconds: originalDeadline
              ) else {
            completion(.failure(.init(
                code: "timeout",
                message: "Not enough time remains to present this window."
            )))
            return
        }

        expireAgentPresentations(nowUptimeNanoseconds: now)
        let requestID = UUID()
        let acknowledgmentDeadline = originalDeadline - safety
        let scope = PeelAgentPresentationScope(
            pairingID: target.pairingID,
            generation: target.generation
        )
        let pending = PeelAgentPendingPresentation(
            requestID: requestID,
            scope: scope,
            deadlineUptimeNanoseconds: acknowledgmentDeadline
        )
        guard pendingAgentPresentations.insert(
            pending,
            nowUptimeNanoseconds: now
        ) else {
            completion(.failure(.init(
                code: "busy",
                message: "Too many window presentations are awaiting a response."
            )))
            return
        }
        pendingAgentPresentationContexts[requestID] = AgentPresentationContext(
            epoch: epoch,
            session: target,
            windowID: freshWindow.windowId,
            originalDeadlineUptimeNanoseconds: originalDeadline,
            admissionPermit: admissionPermit,
            completion: completion
        )
        rescheduleAgentPresentationExpiration()

        network.sendTargetedJSONLine(
            windowList,
            session: target,
            deadlineUptimeNanoseconds: originalDeadline,
            authorization: { submit in admissionPermit.withValidAdmission(for: target, submit) }
        ) { [weak self] sent in
            guard let self,
                  self.pendingAgentPresentations.pending(requestID: requestID) != nil else {
                return
            }
            guard sent, admissionPermit.allows(target),
                  self.agentPresentationPolicyAllows(
                    epoch: epoch,
                    target: target,
                    deadlineUptimeNanoseconds: originalDeadline
                  ) else {
                self.failPendingAgentPresentation(
                    requestID: requestID,
                    code: "target_unavailable",
                    message: "The current window list could not be delivered."
                )
                return
            }

            let refreshedWindows = WindowEnumerator.enumerateWindows()
            guard let refreshedWindow = refreshedWindows.first(where: {
                $0.windowId == freshWindow.windowId
            }), self.agentWindowFingerprint(refreshedWindow) == expectedFingerprint else {
                self.failPendingAgentPresentation(
                    requestID: requestID,
                    code: "window_changed",
                    message: "The window changed before presentation."
                )
                return
            }
            guard admissionPermit.allows(target), self.agentPresentationPolicyAllows(
                epoch: epoch,
                target: target,
                deadlineUptimeNanoseconds: originalDeadline
            ) else {
                self.failPendingAgentPresentation(
                    requestID: requestID,
                    code: "target_unavailable",
                    message: "The target changed before presentation."
                )
                return
            }

            let deliveryNow = DispatchTime.now().uptimeNanoseconds
            guard acknowledgmentDeadline > deliveryNow else {
                self.failPendingAgentPresentation(
                    requestID: requestID,
                    code: "timeout",
                    message: "The presentation request expired before delivery."
                )
                return
            }
            let issuedAt = Date().timeIntervalSince1970
            let remaining = Double(
                acknowledgmentDeadline - deliveryNow
            ) / 1_000_000_000
            let context: String?
            if case .string(let value) = request.params["context"] { context = value } else { context = nil }
            let message = PresentWindowMessage(
                requestId: requestID.uuidString,
                pairingId: target.pairingID,
                window: PeelAgentWindowDelivery.window(refreshedWindow),
                issuedAt: issuedAt,
                expiresAt: issuedAt + remaining,
                context: context
            )
            self.network.sendTargetedJSONLine(
                message,
                session: target,
                deadlineUptimeNanoseconds: originalDeadline,
                authorization: { submit in admissionPermit.withValidAdmission(for: target, submit) }
            ) { [weak self] sent in
                guard let self, !sent,
                      self.pendingAgentPresentations.pending(requestID: requestID) != nil else {
                    return
                }
                self.failPendingAgentPresentation(
                    requestID: requestID,
                    code: "target_unavailable",
                    message: "The presentation request could not be delivered."
                )
            }
        }
    }

    private func agentPresentationPolicyAllows(
        epoch: UUID,
        target: PeelControlSession,
        deadlineUptimeNanoseconds: UInt64
    ) -> Bool {
        PeelConnectedAgentAvailability.allows(.presentWindow) && commerceAllows(target) &&
            agentTargetPolicyAllows(epoch: epoch, target: target,
                deadlineUptimeNanoseconds: deadlineUptimeNanoseconds)
    }

    /// Target-bound MCP observations and effects require both current product
    /// admission and the independent pairing/session consent policy.
    private func agentTargetPolicyAllows(
        epoch: UUID,
        target: PeelControlSession,
        deadlineUptimeNanoseconds: UInt64
    ) -> Bool {
        commerceAllows(target) && agentBridgeEnabled &&
            localAgentEpoch == epoch &&
            agentBridgeStatus == "Ready" &&
            !hostIsLockedOrAsleep &&
            clientIsVisible &&
            agentClientSession == target &&
            agentAuthorizedSession == target &&
            agentTargetSnapshot.current() == target &&
            agentClientCapabilities.contains(PeelCapability.agentPresentationV1.rawValue) &&
            pairingStore.paired.contains(where: { $0.id == target.pairingID }) &&
            network.isCurrentControlSession(target) &&
            DispatchTime.now().uptimeNanoseconds < deadlineUptimeNanoseconds
    }

    private func agentWindowFingerprint(
        _ window: PeelWindow
    ) -> PeelAgentWindowInstanceFingerprint {
        let isDisplay = WindowEnumerator.isDisplayCaptureWindowId(window.windowId)
        let ownerProcessID = isDisplay ? nil : WindowEnumerator.ownerPID(for: window.windowId)
        let appBundleIdentifier = ownerProcessID.flatMap {
            NSRunningApplication(processIdentifier: $0)?.bundleIdentifier
        }
        return PeelAgentWindowInstanceFingerprint(
            windowID: window.windowId,
            ownerProcessID: ownerProcessID,
            appBundleIdentifier: appBundleIdentifier,
            appName: window.appName,
            title: window.title,
            width: window.width,
            height: window.height,
            appLaunchTimeIntervalSince1970: window.appLaunchTimeIntervalSince1970,
            isDisplay: isDisplay,
            displayID: isDisplay
                ? WindowEnumerator.displayCaptureDisplayId(for: window.windowId)
                : nil
        )
    }

    private var agentSourceHostJSON: PeelLocalAgentJSONValue {
        .object([
            "hostId": .string(stableHostIdentifier),
            "name": .string(String((Host.current().localizedName ?? "Mac").prefix(120)))
        ])
    }

    private func agentWindowJSON(_ window: PeelWindow) -> PeelLocalAgentJSONValue {
        let fingerprint = agentWindowFingerprint(window)
        return .object([
            "windowId": .integer(Int64(window.windowId)),
            "appName": .string(String(window.appName.prefix(120))),
            "title": .string(String(window.title.prefix(256))),
            "width": .integer(Int64(window.width)),
            "height": .integer(Int64(window.height)),
            "kind": .string(fingerprint.isDisplay ? "desktop" : "window"),
            "canPresent": .bool(fingerprint.hasDurableIdentity),
            "windowToken": agentWindowControl.token(windowID: window.windowId).map { .string($0) } ?? .null,
            "controlRequires": .string("Host Agent Control consent, active paired stream and fresh inspectWindow; desktop targets are unsupported"),
            "appBundleIdentifier": fingerprint.appBundleIdentifier.map { .string($0) } ?? .null
        ])
    }

    private func rescheduleAgentPresentationExpiration() {
        let timer: DispatchSourceTimer
        if let existing = agentPresentationExpiryTimer {
            timer = existing
        } else {
            let created = DispatchSource.makeTimerSource(queue: .main)
            created.setEventHandler { [weak self] in
                guard let self else { return }
                self.expireAgentPresentations(
                    nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
                )
            }
            created.schedule(deadline: .distantFuture)
            created.resume()
            agentPresentationExpiryTimer = created
            timer = created
        }

        if let deadline = pendingAgentPresentations.earliestDeadlineUptimeNanoseconds {
            timer.schedule(
                deadline: DispatchTime(uptimeNanoseconds: deadline),
                leeway: .milliseconds(5)
            )
        } else {
            timer.schedule(deadline: .distantFuture)
        }
    }

    private func expireAgentPresentations(
        nowUptimeNanoseconds: UInt64
    ) {
        let expired = pendingAgentPresentations.removeExpired(
            nowUptimeNanoseconds: nowUptimeNanoseconds
        )
        rescheduleAgentPresentationExpiration()
        for pending in expired {
            guard let context = pendingAgentPresentationContexts.removeValue(
                forKey: pending.requestID
            ) else {
                continue
            }
            context.completion(.failure(.init(
                code: "timeout",
                message: "The client did not acknowledge the presentation in time."
            )))
        }
    }

    private func failPendingAgentPresentation(
        requestID: UUID,
        code: String,
        message: String
    ) {
        guard pendingAgentPresentations.remove(requestID: requestID) != nil else {
            return
        }
        rescheduleAgentPresentationExpiration()
        guard let context = pendingAgentPresentationContexts.removeValue(
            forKey: requestID
        ) else {
            return
        }
        context.completion(.failure(.init(code: code, message: message)))
    }

    private func cancelPendingAgentPresentations(
        code: String,
        message: String
    ) {
        let pending = pendingAgentPresentations.removeAll()
        rescheduleAgentPresentationExpiration()
        for request in pending {
            guard let context = pendingAgentPresentationContexts.removeValue(
                forKey: request.requestID
            ) else {
                continue
            }
            context.completion(.failure(.init(code: code, message: message)))
        }
        pendingAgentPresentationContexts.removeAll(keepingCapacity: false)
    }

    private func handleAgentPresentationResult(
        _ result: AgentPresentationResultMessage,
        generation: UInt64
    ) {
        guard let requestID = UUID(uuidString: result.requestId) else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let takeResult = pendingAgentPresentations.take(
            requestID: requestID,
            generation: generation,
            nowUptimeNanoseconds: now
        )
        rescheduleAgentPresentationExpiration()
        switch takeResult {
        case .missing, .generationMismatch:
            return

        case .expired(let pending):
            guard let context = pendingAgentPresentationContexts.removeValue(
                forKey: pending.requestID
            ) else {
                return
            }
            context.completion(.failure(.init(
                code: "timeout",
                message: "The client acknowledgment arrived after the deadline."
            )))

        case .matched(let pending):
            guard let context = pendingAgentPresentationContexts.removeValue(
                forKey: pending.requestID
            ) else {
                return
            }
            guard pending.scope.pairingID == context.session.pairingID,
                  context.admissionPermit.allows(context.session),
                  pending.scope.generation == context.session.generation,
                  agentPresentationPolicyAllows(
                    epoch: context.epoch,
                    target: context.session,
                    deadlineUptimeNanoseconds: pending.deadlineUptimeNanoseconds
                  ),
                  now < context.originalDeadlineUptimeNanoseconds else {
                context.completion(.failure(.init(
                    code: "target_unavailable",
                    message: "The target changed before acknowledging presentation."
                )))
                return
            }

            switch result.status {
            case "opened":
                context.completion(.success(.object([
                    "status": .string("opened"),
                    "targetPairingId": .string(context.session.pairingID),
                    "windowId": .integer(Int64(context.windowID)),
                    "sourceHost": self.agentSourceHostJSON
                ])))
            case "declined":
                context.completion(.failure(.init(
                    code: "declined",
                    message: "The client declined the window presentation."
                )))
            case "unavailable":
                context.completion(.failure(.init(
                    code: "unavailable",
                    message: "The client could not present the window."
                )))
            default:
                context.completion(.failure(.init(
                    code: "invalid_response",
                    message: "The client returned an unknown presentation status."
                )))
            }
        }
    }

    // MARK: - Client/session

    private func handleClientHello(_ msg: ClientHelloMessage, generation: UInt64) {
        let cleanName = msg.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }

        guard PeelProtocol.isCompatible(
            remoteCurrent: msg.protocolVersion,
            remoteMinimum: msg.minimumSupportedProtocolVersion
        ) else {
            let reason = "This Peel client is not compatible with this version of Peel Pro. Update both apps and try again."

            network.sendJSONLineThenDisconnect(
                ProtocolRejectedMessage(
                    reason: reason,
                    remoteProtocolVersion: msg.protocolVersion,
                    remoteMinimumSupportedProtocolVersion: msg.minimumSupportedProtocolVersion
                ),
                reason: "Protocol mismatch"
            )
            proAdmission.invalidate()

            DispatchQueue.main.async {
                self.statusText = reason
            }

            print(
                "PeelHost: rejected client protocol",
                "client=", cleanName,
                "remoteCurrent=", msg.protocolVersion.map(String.init) ?? "nil",
                "remoteMinimum=", msg.minimumSupportedProtocolVersion.map(String.init) ?? "nil",
                "localCurrent=", PeelProtocol.currentProtocolVersion,
                "localMinimum=", PeelProtocol.minimumSupportedProtocolVersion
            )
            return
        }

        DispatchQueue.main.async {
            self.statusText = "Connected: \(cleanName)"
        }

        audioController.stop(reason: "Audio session changed")
        sourceMedia.invalidate(clearStreams: false)
        clearAgentAuthorization()
        guard network.noteConnectedClient(pairingID: msg.pairingID, displayName: cleanName,
                                          generation: generation) else { return }
        agentClientSession = msg.pairingID.flatMap { network.controlSession(pairingID: $0) }
        agentClientCapabilities = Set(msg.capabilities ?? [])
        receiverDiagnostics.setSession(generation: agentClientSession?.generation,
            negotiated: agentClientCapabilities.contains(PeelClientStreamMetricsMessage.capability))
        beginAgentAuthorization()
        beginManualAgentAuthorization()

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        let displayVersion: String? = {
            switch (appVersion, buildNumber) {
            case let (version?, build?):
                return "\(version) (\(build))"
            case let (version?, nil):
                return version
            case let (nil, build?):
                return build
            case (nil, nil):
                return nil
            }
        }()

        var capabilities = PeelProtocol.capabilities
        capabilities.insert(Self.hostRenderedCursorCapability)
        capabilities.insert(PeelCapability.macSystemAudioV1.rawValue)
        capabilities.insert(PeelCapability.remoteVoiceV1.rawValue)
        capabilities.insert(PeelCapability.machineStatusV1.rawValue)
        capabilities.insert(PeelCapability.videoKeyframeRequestV1.rawValue)
        capabilities.insert(PeelClientStreamMetricsMessage.capability)
        capabilities.insert(PeelManualAgentControl.capability)
        capabilities.insert(PeelProEntitlementProtocol.capability)
        // Media keys and systemOutput volume/mute (CoreAudio). A fixed or missing
        // output is reported per query; peelStream stays unsupported.
        capabilities.insert(PeelSourceMediaProtocol.mediaKeysCapability)
        capabilities.insert(PeelSourceMediaProtocol.volumeCapability)

        let hostHello = HostHelloMessage(
            hostName: Host.current().localizedName ?? "Mac",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: displayVersion,
            capabilities: capabilities
        )
        network.sendJSONLine(hostHello)
        refreshProAdmission()

        print(
            "PeelHost: clientHello =",
            cleanName,
            "platform=", msg.platform,
            "pairingID=", msg.pairingID ?? "nil",
            "remoteProtocol=", msg.protocolVersion ?? 1,
            "remoteMinimum=", msg.minimumSupportedProtocolVersion ?? 1,
            "capabilities=", msg.capabilities ?? []
        )
    }

    private func handleProtocolRejected(_ msg: ProtocolRejectedMessage) {
        proAdmission.invalidate()
        print(
            "PeelHost: peer rejected protocol:",
            msg.reason,
            "localCurrent=", PeelProtocol.currentProtocolVersion,
            "localMinimum=", PeelProtocol.minimumSupportedProtocolVersion,
            "peerSawCurrent=", msg.remoteProtocolVersion.map(String.init) ?? "nil",
            "peerSawMinimum=", msg.remoteMinimumSupportedProtocolVersion.map(String.init) ?? "nil"
        )

        DispatchQueue.main.async {
            self.statusText = msg.reason
        }

        network.disconnectCurrentClient(reason: "Peer rejected protocol")
    }

    private func handlePairingRevoked(_ msg: PairingRevokedMessage) {
        let id = msg.pairingId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        if agentClientSession?.pairingID == id { proAdmission.invalidate() }
        // Persist outbound iCloud enrollment suppression only for the exact peer
        // revoking over its own current session; no name/service fallback.
        if UUID(uuidString: id) != nil, network.controlSession(pairingID: id) != nil,
           let peer = pairingStore.paired.first(where: { $0.id == id }) {
            PeelICloudMacPairingController.noteExplicitForget(hostID: peer.stableHostId)
        }

        pairingStore.removePeer(pairingID: id)
        if agentAuthorizedSession?.pairingID == id || manualAgentAuthorizedSession?.pairingID == id {
            clearAgentAuthorization()
        }

        if connectedClientPairingID == id {
            network.disconnectCurrentClient(reason: msg.reason ?? "Pairing revoked by client")
        }

        DispatchQueue.main.async {
            self.statusText = "Pairing removed by client. Re-pair to connect again."
        }
    }

    private func startClientPingMonitor() {
        stopClientPingMonitor()

        let timer = DispatchSource.makeTimerSource(queue: clientPingMonitorQueue)
        timer.schedule(deadline: .now() + pingMonitorInterval,
                       repeating: pingMonitorInterval,
                       leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.clientIsVisible else { return }

                if Date().timeIntervalSince(self.lastClientPingAt) > self.pingTimeoutSeconds {
                    self.clientIsVisible = false
                    self.input.resetSessionState(reason: .clientTimedOut)
                    self.receiverDiagnostics.clearObservation()
                    self.audioController.stop(reason: "iPad connection timed out")
                    self.clearAgentAuthorization()
                    self.updateAwakePolicy()
                    self.network.disconnectCurrentClient(reason: "Client ping timeout")
                }
            }
        }
        timer.resume()
        clientPingMonitor = timer
    }

    private func stopClientPingMonitor() {
        clientPingMonitor?.cancel()
        clientPingMonitor = nil
    }

    // MARK: - Power / awake

    private func configurePowerLockObserver() {
        powerLockObserver.onSleep = { [weak self] in
            self?.handleHostSleep()
        }
        powerLockObserver.onWake = { [weak self] in
            self?.handleHostWake()
        }
        powerLockObserver.onLock = { [weak self] in
            self?.handleHostLock()
        }
        powerLockObserver.onUnlock = { [weak self] in
            self?.handleHostUnlock()
        }
    }

    private func handleHostSleep() {
        hostIsLockedOrAsleep = true
        teardownSessionForPowerState(reason: "Sleep")
    }

    private func handleHostWake() {
        teardownSessionForPowerState(reason: "Wake")
        hostIsLockedOrAsleep = false
    }

    private func handleHostLock() {
        hostIsLockedOrAsleep = true
        teardownSessionForPowerState(reason: "Lock")
    }

    private func handleHostUnlock() {
        hostIsLockedOrAsleep = false
    }

    private func teardownSessionForPowerState(reason: String) {
        network.disconnectCurrentClient(reason: reason)
        updateAwakePolicy()
    }

    private func updateAwakePolicy() {
        let shouldHold = preventSleepEnabled && clientIsVisible && !hostIsLockedOrAsleep
        let keepDisplay = preventSleepEnabled && !hostIsLockedOrAsleep

        if !shouldHold {
            if lastAwakeShouldHold {
                awake.stop()
            }
            lastAwakeShouldHold = false
            lastAwakeKeepDisplay = false
            return
        }

        if !lastAwakeShouldHold || lastAwakeKeepDisplay != keepDisplay {
            awake.stop()
            awake.start(reason: "Peel streaming active", keepDisplayAwake: keepDisplay)
            lastAwakeShouldHold = true
            lastAwakeKeepDisplay = keepDisplay
        }
    }
}

struct AnyEncodable: Encodable {
    private let encodeImpl: (Encoder) throws -> Void

    init<T: Encodable>(_ value: T) {
        self.encodeImpl = value.encode(to:)
    }

    func encode(to encoder: Encoder) throws {
        try encodeImpl(encoder)
    }
}
