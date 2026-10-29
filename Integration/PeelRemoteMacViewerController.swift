import AppKit
import Combine
import Foundation
import Network
import OSLog
import VideoToolbox

/// One explicit outbound desktop session using the same Mac pairing that admits
/// SidePulse. Keychain's .host namespace does not change that pairing's wire ID.
@MainActor
final class PeelRemoteMacViewerController: ObservableObject, PeelICloudMacPairingAddressAccess {
    struct Mac: Identifiable {
        let peer: PeelPairedPeer
        let endpoint: NWEndpoint
        var id: String { peer.id }
    }

    private struct PendingAgentPresentation {
        let requestID: String
        let epoch: UUID
        let window: PeelWindow
        let expiresAt: TimeInterval
        let context: String?
    }

    private enum AgentPresentationValidation {
        case accepted(requestID: String, window: PeelWindow, context: String?)
        case declined(requestID: String, reason: String)
        case unavailable(requestID: String, reason: String)
    }

    private static let agentPresentationOptInDefaultsKey = "peel.ai.allowAgentPresentation"

    @Published private(set) var availableMacs: [Mac] = []
    @Published private(set) var pairedPeers: [PeelPairedPeer] = []
    @Published private(set) var savedAddresses: [PeelRemoteMacAddressRecord] = []
    @Published private(set) var activeSavedAddressID: UUID?
    @Published private(set) var connectedDisplayName: String?
    @Published private(set) var connectedPlatform = "Computer"
    @Published private(set) var windows: [PeelWindow] = []
    @Published private(set) var currentWindowInventoryID: PeelRemoteMacWindowInventoryID?
    @Published private(set) var selectedWindow: PeelWindow?
    @Published private(set) var streamDisplaySize: CGSize?
    // Presentation releases held input before a stream/session identity changes.
    var onStreamWillChange: (() -> Void)?
    var onStreamPresentationChanged: (() -> Void)?
    var onWindowInventoryUpdated: ((PeelRemoteMacWindowInventoryID) -> Void)?
    // Fires after the current stream presents a first frame, including after recovery reconfiguration.
    var onStreamVideoReady: (() -> Void)?
    // Independent of optional agent routes: the current presentation owns held input.
    private var inputReleaseOwnerID: UUID?
    private var onInputWillDisable: (() -> Void)?
    @Published private(set) var connectedPairingID: String?
    @Published private(set) var status = "Choose a paired computer to view its desktop."
    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published private(set) var hasVideo = false
    @Published private(set) var inputEnabled = false
    @Published private(set) var inputStatus = "Viewing only. Enable control to use this Mac's keyboard and pointer."
    @Published private(set) var allowsAgentPresentation = UserDefaults.standard.bool(
        forKey: PeelRemoteMacViewerController.agentPresentationOptInDefaultsKey
    )
    @Published private(set) var agentPresentationContext: String?

    let renderer = PeelRemoteMacVideoRenderer()
    /// Single computer-audio (Listen) owner for the current control connection.
    /// UI: observe status/isPlayingPCM; call startByUser()/stopByUser().
    private(set) lazy var audio = PeelRemoteMacAudioController(adapters: makeAudioAdapters())
    /// Source media keys/volume client for the selected stream (contract v1).
    private(set) lazy var sourceMedia = PeelRemoteMacSourceMediaController(adapters: makeSourceMediaAdapters())
    lazy var iCloudPairing = PeelICloudMacPairingController(
        trust: pairingStore, addresses: self, localHostID: localHostID.uuidString)
    private let pairingStore: PeelPairingStore
    private let localHostID: UUID
    private let addressStore: PeelRemoteMacAddressStore
    private let isPreview = ProcessInfo.processInfo.arguments.contains("--peel-preview")
    private let queue = DispatchQueue(label: "peel.remote-mac.network", qos: .userInteractive)
    private var browser: NWBrowser?
    private var control: NWConnection?
    private var video: NWConnection?
    private var target: Mac?
    private var targetKey: Data?
    private var controlBuffer = Data()
    private var videoFramer = PeelRemoteMacVideoFramer()
    private var epoch = UUID()
    private var browseEpoch = UUID()
    private var timer: DispatchSourceTimer?
    private var connectedAt: UInt64 = 0
    private var streamStartedAt: UInt64 = 0
    private var lastPing: UInt64 = 0
    private var lastWindowRefresh: UInt64 = 0
    private var lastStreamMetricsAt: UInt64 = 0
    private var streamMetricsSequence: UInt64 = 0
    // Fixed-size, client-clock diagnostics; no packet contents or cross-clock subtraction.
    private var ingressCallbacks: Int64 = 0
    private var ingressFullChunks: Int64 = 0
    private var ingressMainHopMaximumMilliseconds: Double = 0
    private var ingressRearmMaximumMilliseconds: Double = 0
    private let ingressLoggingEnabled = ProcessInfo.processInfo.environment["PEEL_MAC_RECEIVER_DIAGNOSTICS"] == "1"
    private let ingressLog = Logger(subsystem: "com.zephyrstudiosllc.Peel", category: "MacReceiverIngress")
    private var hostCapabilities = Set<String>()
    /// Last ClientVisibilityMessage value sent on this control connection.
    private var audioClientVisible = false
    private var pendingSendBytes = 0
    private var pendingSendCount = 0
    private var requiresFreshUserWindowSelection = false
    private var isAgentPresentationRouteActive = false
    private weak var agentPresentationWindow: NSWindow?

    private var canReceiveAgentPresentation: Bool {
        isAgentPresentationRouteActive && agentPresentationWindow?.isVisible == true
            && agentPresentationWindow?.isMiniaturized == false && !NSApp.isHidden
    }
    private var onAgentPresentationWillSelectWindow: (() -> Void)?
    private var pendingAgentPresentation: PendingAgentPresentation?
    private var handledAgentPresentationRequestIDs = Set<String>()
    private var handledAgentPresentationRequestOrder: [String] = []
    private let maxHandledAgentPresentationRequestIDs = 64
    private var lastHandledAgentPairingChallengeRequestID: String?
    private var trustObserver: AnyCancellable?
    private var sleepObservers: [AnyCancellable] = []
    private let maximumControlBytes = 16 * 1024 * 1024

    init(pairingStore: PeelPairingStore, localHostID: UUID,
         addressStore: PeelRemoteMacAddressStore? = nil) {
        self.pairingStore = pairingStore
        self.localHostID = localHostID
        self.addressStore = addressStore ?? PeelRemoteMacAddressStore()
        refreshSavedAddresses()
        renderer.onNeedsKeyframe = { [weak self] in self?.requestKeyframe() }
        renderer.onFormatChange = { [weak self] size in
            guard let self, self.selectedWindow != nil else { return }
            self.streamDisplaySize = size
            self.onStreamPresentationChanged?()
        }
        renderer.onFirstFrame = { [weak self] in
            guard let self, self.isConnected, self.video != nil else { return }
            self.hasVideo = true
            self.status = "Connected to \(self.connectedDisplayName ?? "Computer")"
            self.completePendingAgentPresentationIfReady()
            self.onStreamVideoReady?()
            self.audio.streamVideoReady()
        }
        trustObserver = pairingStore.$paired.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // @Published emits before mutation; read the committed state in
                // this main-actor task instead of retaining an older emission.
                self.refreshSavedAddresses()
                self.availableMacs.removeAll { mac in !self.pairedPeers.contains { $0.id == mac.id } }
                if self.control != nil, !self.hasCurrentTrust || !self.currentKeyMatches {
                    self.disconnect(reason: "This computer pairing was removed or replaced.")
                }
            }
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            sleepObservers.append(NSWorkspace.shared.notificationCenter.publisher(for: name).sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.disconnect(reason: "Reconnect after unlocking this Mac.") }
            })
        }
    }

    func updateAgentPresentationWindow(_ window: NSWindow?) {
        agentPresentationWindow = window
        refreshAgentPresentationVisibility()
    }

    func refreshAgentPresentationVisibility() {
        if !canReceiveAgentPresentation {
            onAgentPresentationWillSelectWindow?()
            disableInputControl()
            cancelPendingAgentPresentation(status: "unavailable", reason: "The stream window is hidden.")
        }
        if isConnected {
            send(ClientVisibilityMessage(isVisible: canReceiveAgentPresentation))
            noteClientVisibilitySent(canReceiveAgentPresentation)
            sendClientHello()
        }
    }

    func registerAgentPresentationRoute(onWillSelectWindow: @escaping () -> Void) {
        isAgentPresentationRouteActive = true
        onAgentPresentationWillSelectWindow = onWillSelectWindow
        if isConnected {
            sendClientHello()
        }
    }

    func unregisterAgentPresentationRoute() {
        cancelPendingAgentPresentation(
            status: "unavailable",
            reason: "The computer browser and stream window are no longer visible."
        )
        isAgentPresentationRouteActive = false
        onAgentPresentationWillSelectWindow = nil
        if isConnected {
            sendClientHello()
        }
    }

    func setAgentPresentationOptIn(_ enabled: Bool) {
        guard allowsAgentPresentation != enabled else { return }
        allowsAgentPresentation = enabled
        UserDefaults.standard.set(enabled, forKey: Self.agentPresentationOptInDefaultsKey)

        if !enabled {
            onAgentPresentationWillSelectWindow?()
            disableInputControl()
            cancelPendingAgentPresentation(
                status: "declined",
                reason: "Agent window opening is turned off on this viewer."
            )
            agentPresentationContext = nil
        }

        if isConnected {
            sendClientHello()
        }
    }

    func startDiscovery() {
        guard browser == nil, !ProcessInfo.processInfo.arguments.contains("--peel-preview") else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_peel._tcp", domain: nil), using: .tcp)
        let generation = UUID()
        browseEpoch = generation
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                guard let self, self.browseEpoch == generation else { return }
                var next: [String: Mac] = [:]
                for result in results.prefix(128) {
                    guard case .bonjour(let txt) = result.metadata,
                          let rawID = txt.dictionary["hostId"], let hostID = UUID(uuidString: rawID),
                          hostID != self.localHostID else { continue }
                    for peer in self.pairingStore.paired.prefix(128) {
                        guard UUID(uuidString: peer.stableHostId ?? peer.serviceName ?? "") == hostID,
                              UUID(uuidString: peer.id) != nil,
                              peer.tlsPSKOrder != nil else { continue }
                        next[peer.id] = Mac(peer: peer, endpoint: result.endpoint)
                    }
                }
                self.availableMacs = next.values.sorted { $0.peer.displayName.localizedStandardCompare($1.peer.displayName) == .orderedAscending }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.browseEpoch == generation else { return }
                if case .failed = state, self.control == nil { self.status = "Nearby discovery is unavailable. Select Refresh to retry." }
            }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    func stop() {
        iCloudPairing.pause()
        disconnect()
        browseEpoch = UUID()
        browser?.cancel()
        browser = nil
        availableMacs = []
    }

    func refreshDiscovery() {
        browseEpoch = UUID()
        browser?.cancel()
        browser = nil
        availableMacs = []
        startDiscovery()
    }

    private func refreshSavedAddresses() {
        pairedPeers = pairingStore.paired.filter { peer in
            UUID(uuidString: peer.id) != nil && peer.tlsPSKOrder != nil &&
                UUID(uuidString: peer.stableHostId ?? peer.serviceName ?? "") != nil
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        let validIDs = Set(pairedPeers.map(\.id))
        if !isPreview { addressStore.removeUnpaired(validPairingIDs: validIDs) }
        savedAddresses = addressStore.records.filter { validIDs.contains($0.pairingID) }
    }

    func saveAddress(_ record: PeelRemoteMacAddressRecord) throws {
        guard !isPreview,
              let peer = pairedPeers.first(where: { $0.id == record.pairingID }),
              pairingStore.paired.contains(where: { $0.id == peer.id }) else {
            throw PeelRemoteMacAddressValidationError.invalidPairingID
        }
        try addressStore.save(record)
        if activeSavedAddressID == record.id {
            disconnect(reason: "Address updated. Select it to reconnect.")
        }
        refreshSavedAddresses()
    }

    func canSaveICloudAddress(id: UUID) -> Bool {
        addressStore.records.contains(where: { $0.id == id }) || addressStore.records.count < PeelRemoteMacAddressStore.maxRecords
    }

    /// Metadata-only account enrollment adapter. An active target is deferred;
    /// this path never reconnects or disconnects either viewer or Host sessions.
    /// The key check reads only the verified cache populated by enrollment, so
    /// it opens no Keychain operation.
    func saveICloudAddress(record: PeelICloudHostRecord, pairingID: String, addressID: UUID) throws -> Bool {
        guard !isPreview, record.isValid,
              let peer = pairingStore.paired.first(where: { $0.id == pairingID }),
              peer.stableHostId?.lowercased() == record.hostID.lowercased(),
              peer.tlsPSKOrder != nil, pairingStore.cachedPSKReadResult(for: peer.id)?.data?.count == 32,
              !addressStore.records.contains(where: { $0.id == addressID && $0.pairingID != pairingID }) else {
            throw PeelRemoteMacAddressValidationError.invalidPairingID
        }
        if connectedPairingID == pairingID || activeSavedAddressID == addressID { return false }
        // The address store has a narrower label bound than the shared record.
        var label = ""
        for character in record.displayName {
            let next = label + String(character)
            guard next.utf8.count <= 96 else { break }
            label = next
        }
        label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if label.isEmpty { label = "Mac" }
        let address = try PeelRemoteMacAddressRecord(id: addressID, pairingID: pairingID,
            displayName: label, host: record.endpointHost, port: record.controlPort)
        try addressStore.save(address)
        refreshSavedAddresses()
        return true
    }

    func removeAddress(_ record: PeelRemoteMacAddressRecord) {
        guard !isPreview, addressStore.records.contains(record) else { return }
        if activeSavedAddressID == record.id {
            disconnect(reason: "Saved address removed.")
        }
        addressStore.remove(id: record.id)
        refreshSavedAddresses()
    }

    func connectDirectAddress(_ record: PeelRemoteMacAddressRecord) {
        guard !isPreview, savedAddresses.contains(record), addressStore.records.contains(record),
              let peer = pairingStore.paired.first(where: { $0.id == record.pairingID }),
              let port = NWEndpoint.Port(rawValue: record.port) else {
            status = "This saved address or its pairing is no longer available."
            return
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(record.host), port: port)
        connectTrusted(Mac(peer: peer, endpoint: endpoint), address: record)
    }

    func connect(_ mac: Mac) {
        guard !isPreview,
              let current = availableMacs.first(where: { $0.id == mac.id }),
              current.endpoint == mac.endpoint else {
            status = "This nearby computer is no longer available. Refresh discovery and try again."
            return
        }
        connectTrusted(current)
    }

    private func connectTrusted(_ candidate: Mac, address: PeelRemoteMacAddressRecord? = nil) {
        guard let peer = pairingStore.paired.first(where: { $0.id == candidate.id }),
              UUID(uuidString: peer.id) != nil,
              let order = peer.tlsPSKOrder else {
            status = "Pair with this computer in Peel Pro before connecting."
            return
        }
        // This method is reached only by the selected nearby/saved Connect
        // buttons. Discovery, timers and background routes never clear a read.
        let key: Data
        switch pairingStore.pskReadForExplicitConnection(for: peer.id) {
        case .available(let stored) where stored.count == 32:
            key = stored
        case .available:
            status = "This saved key format is not supported by this viewer. Your pairing record has been kept."
            return
        case .notFound:
            status = "The saved connection key was not found. Its pairing record has been kept. Pair again in Peel Pro to replace it."
            return
        case .readInProgress:
            status = "Saved connection authorization is already in progress."
            return
        case .cacheCapacityReached:
            status = "Saved connection credential capacity was reached. Restart Peel Pro before trying again."
            return
        default:
            status = "Saved connection credentials are unavailable. Select Connect again to retry authorization. Your pairing has been kept."
            return
        }
        let current = Mac(peer: peer, endpoint: candidate.endpoint)
        disconnect()
        target = current
        targetKey = key
        connectedPairingID = peer.id
        activeSavedAddressID = address?.id
        connectedDisplayName = address?.displayName ?? peer.displayName
        isConnecting = true
        connectedAt = DispatchTime.now().uptimeNanoseconds
        status = "Connecting to \(connectedDisplayName ?? peer.displayName)…"
        let connection = NWConnection(to: current.endpoint,
            using: PeelTLS.makeClientParameters(pairingID: peer.id, psk: key, pskOrder: order))
        let generation = epoch
        control = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor [weak self, weak connection] in
                guard let self, let connection, self.epoch == generation, self.control === connection else { return }
                switch state {
                case .ready:
                    guard self.hasCurrentTrust else { self.disconnect(reason: "Pairing is no longer available."); return }
                    self.sendClientHello()
                    self.receiveControl(connection, generation: generation)
                case .failed:
                    self.disconnect(reason: "Could not connect. Check that the paired computer is awake and Peel Pro is running.")
                case .cancelled: self.disconnect(reason: "Disconnected.")
                default: break
                }
            }
        }
        connection.start(queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    func disconnect(reason: String = "Disconnected.") {
        disableInputControl()
        onStreamWillChange?()
        requiresFreshUserWindowSelection = false
        cancelPendingAgentPresentation(status: "unavailable", reason: reason)
        audio.controlWillEnd()
        sourceMedia.controlWillEnd()
        epoch = UUID()
        control?.stateUpdateHandler = nil
        video?.stateUpdateHandler = nil
        control?.cancel()
        video?.cancel()
        control = nil
        video = nil
        timer?.cancel()
        timer = nil
        target = nil
        targetKey = nil
        connectedPairingID = nil
        connectedDisplayName = nil
        connectedPlatform = "Computer"
        activeSavedAddressID = nil
        controlBuffer = Data()
        videoFramer.reset()
        windows = []
        currentWindowInventoryID = nil
        selectedWindow = nil
        streamDisplaySize = nil
        isConnected = false
        isConnecting = false
        hasVideo = false
        hostCapabilities = []
        audioClientVisible = false
        agentPresentationContext = nil
        pendingAgentPresentation = nil
        handledAgentPresentationRequestIDs.removeAll(keepingCapacity: true)
        handledAgentPresentationRequestOrder.removeAll(keepingCapacity: true)
        lastHandledAgentPairingChallengeRequestID = nil
        pendingSendBytes = 0
        pendingSendCount = 0
        lastPing = 0
        lastWindowRefresh = 0
        lastStreamMetricsAt = 0
        streamMetricsSequence = 0
        resetIngressDiagnostics()
        renderer.reset()
        inputStatus = "Viewing only. Enable control to use this Mac's keyboard and pointer."
        status = reason
        onStreamPresentationChanged?()
    }

    @discardableResult
    func selectWindow(_ window: PeelWindow, preservingAgentRequestID: String? = nil,
                      inventoryID: PeelRemoteMacWindowInventoryID? = nil) -> Bool {
        guard !requiresFreshUserWindowSelection || inventoryID != nil else {
            status = "Choose a window from the current list after reconnecting."
            return false
        }
        if let inventoryID, !isCurrentWindowSelection(window, inventoryID: inventoryID) {
            status = "The window list changed. Choose a window from the current list."
            return false
        }
        guard selectedWindow == nil, video == nil else {
            status = "One remote window at a time. Reconnect before opening another window."
            return false
        }
        if let pendingAgentPresentation,
           pendingAgentPresentation.requestID != preservingAgentRequestID {
            cancelPendingAgentPresentation(
                status: "unavailable",
                reason: "The selected window changed before it opened."
            )
        }
        if preservingAgentRequestID == nil {
            agentPresentationContext = nil
        }
        guard isConnected, hasCurrentTrust,
              let current = windows.first(where: { $0.windowId == window.windowId }),
              let target, let key = targetKey, let order = target.peer.tlsPSKOrder else { return false }
        disableInputControl()
        onStreamWillChange?()
        video?.stateUpdateHandler = nil
        video?.cancel()
        video = nil
        videoFramer.reset()
        resetIngressDiagnostics()
        renderer.reset()
        streamDisplaySize = nil
        if inventoryID != nil { requiresFreshUserWindowSelection = false }
        selectedWindow = current
        hasVideo = false
        streamStartedAt = DispatchTime.now().uptimeNanoseconds
        status = "Opening \(current.title)…"
        let connection = NWConnection(to: target.endpoint,
            using: PeelTLS.makeClientParameters(pairingID: target.id, psk: key, pskOrder: order))
        let generation = epoch
        video = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor [weak self, weak connection] in
                guard let self, let connection, self.epoch == generation, self.video === connection else { return }
                switch state {
                case .ready:
                    guard self.hasCurrentTrust else { self.disconnect(reason: "Pairing is no longer available."); return }
                    let hello = VideoStreamHelloMessage(windowId: current.windowId, pairingID: target.id, capabilities: self.clientCapabilities)
                    guard var data = try? JSONEncoder().encode(hello) else { return }
                    data.append(10)
                    connection.send(content: data, completion: .contentProcessed { [weak self] error in
                        guard error != nil else { return }
                        Task { @MainActor [weak self] in
                            guard let self, self.epoch == generation, self.video === connection else { return }
                            self.disconnect(reason: "The video connection ended.")
                        }
                    })
                    self.send(ClientVisibilityMessage(isVisible: true))
                    self.noteClientVisibilitySent(true)
                    self.send(ClientActiveWindowMessage(windowId: current.windowId))
                    self.send(ClientWindowActivityMessage(windowId: current.windowId, isActive: true))
                    self.send(PeelRequest(type: "startStream", windowId: current.windowId))
                    self.receiveVideo(connection, generation: generation)
                case .failed, .cancelled: self.disconnect(reason: "The video connection ended. Reconnect to resume.")
                default: break
                }
            }
        }
        connection.start(queue: queue)
        onStreamPresentationChanged?()
        return true
    }

    var hasControlConnection: Bool { control != nil }

    /// The current exact target's paired computer name, never a saved-address label.
    var connectedPeerDisplayName: String? {
        guard let target, connectedPairingID == target.id else { return nil }
        return target.peer.displayName
    }

    func reconnectIntent(for window: PeelWindow, displaySize: CGSize) -> PeelRemoteMacReconnectIntent? {
        guard let target, connectedPairingID == target.id else { return nil }
        let address = activeSavedAddressID.flatMap { id in savedAddresses.first { $0.id == id } }
        guard activeSavedAddressID == nil || address != nil else { return nil }
        return PeelRemoteMacReconnectIntent(pairingID: target.id,
            stableHostID: target.peer.stableHostId, serviceName: target.peer.serviceName,
            tlsOrder: target.peer.tlsPSKOrder?.rawValue, address: address, window: window,
            displaySize: displaySize, displayName: connectedDisplayName ?? target.peer.displayName)
    }

    /// Called only by the visible Reconnect button. Never stores a key in the retained intent.
    func reconnect(_ intent: PeelRemoteMacReconnectIntent) -> UUID? {
        guard !isPreview, !hasControlConnection, !isConnecting,
              let peer = pairingStore.paired.first(where: { $0.id == intent.pairingID }),
              peer.stableHostId == intent.stableHostID, peer.serviceName == intent.serviceName,
              peer.tlsPSKOrder?.rawValue == intent.tlsOrder else {
            status = "This pairing changed. Choose a computer from the current list."
            return nil
        }
        let previousEpoch = epoch
        if let expectedAddress = intent.address {
            guard let current = savedAddresses.first(where: { $0.id == expectedAddress.id }),
                  current == expectedAddress, addressStore.records.contains(current) else {
                status = "The saved address changed. Choose its current entry in Computers."
                return nil
            }
            connectDirectAddress(current)
        } else {
            // Resolve the current discovery row; the retained intent contains no old endpoint.
            guard let current = availableMacs.first(where: { $0.id == intent.pairingID }) else {
                status = "The computer is not currently nearby. Refresh Computers or select a saved address."
                return nil
            }
            connect(current)
        }
        guard control != nil, epoch != previousEpoch else { return nil }
        requiresFreshUserWindowSelection = true
        return epoch
    }

    func requireFreshWindowSelection() { requiresFreshUserWindowSelection = true }

    func isCurrentConnectionEpoch(_ expected: UUID) -> Bool { control != nil && epoch == expected }

    func isCurrentWindowSelection(_ window: PeelWindow, inventoryID: PeelRemoteMacWindowInventoryID) -> Bool {
        guard isConnected, control != nil, currentWindowInventoryID == inventoryID,
              inventoryID.controlEpoch == epoch,
              let current = windows.first(where: { $0.windowId == window.windowId }) else { return false }
        return current.appName == window.appName && current.title == window.title
            && current.width == window.width && current.height == window.height
            && current.appLaunchTimeIntervalSince1970 == window.appLaunchTimeIntervalSince1970
    }

    func refreshWindows() {
        guard isConnected else { return }
        send(PeelRequest(type: "requestWindowList"))
    }

    func dismissAgentPresentationContext() {
        agentPresentationContext = nil
    }

    func registerInputRelease(ownerID: UUID, release: @escaping () -> Void) {
        // Drain the previous surface and close its gate before transferring ownership.
        disableInputControl()
        inputReleaseOwnerID = ownerID
        onInputWillDisable = release
    }

    func unregisterInputRelease(ownerID: UUID) {
        guard inputReleaseOwnerID == ownerID else { return }
        disableInputControl()
        inputReleaseOwnerID = nil
        onInputWillDisable = nil
    }

    /// Opens only the local send gate for the current trusted, presenting stream.
    /// Host Allow Control and Accessibility are still enforced per message.
    @discardableResult
    func enableInputControl() -> Bool {
        guard isConnected, hasVideo, video != nil, selectedWindow != nil, hasCurrentTrust else { return false }
        inputEnabled = true
        return true
    }

    func disableInputControl() {
        // Release only through the current persistent presentation, before closing sendInput's gate.
        onInputWillDisable?()
        inputEnabled = false
    }

    func sendInput<T: Encodable>(_ message: T) {
        guard inputEnabled, isConnected, hasVideo, hasCurrentTrust else { return }
        send(message)
    }

    private var hasCurrentTrust: Bool {
        guard let target, let key = targetKey,
              let current = pairingStore.paired.first(where: { $0.id == target.id }),
              current.stableHostId == target.peer.stableHostId,
              current.serviceName == target.peer.serviceName,
              current.tlsPSKOrder == target.peer.tlsPSKOrder else { return false }
        // Membership is checked at every receive/send. Keychain reads belong at
        // connection/rotation boundaries and the low-rate liveness check, not
        // on every video chunk or pointer event.
        if let addressID = activeSavedAddressID {
            guard let address = addressStore.records.first(where: { $0.id == addressID }),
                  address.pairingID == target.id,
                  let port = NWEndpoint.Port(rawValue: address.port),
                  target.endpoint == .hostPort(host: NWEndpoint.Host(address.host), port: port) else { return false }
        }
        return key.count == 32 && current.id == target.id
    }

    private var currentKeyMatches: Bool {
        guard let target, let targetKey else { return false }
        return pairingStore.psk(for: target.id) == targetKey
    }

    private func sendClientHello() {
        guard let target else { return }
        send(ClientHelloMessage(
            pairingID: target.peer.id,
            deviceName: Host.current().localizedName ?? "Peel Pro",
            deviceModel: "Mac",
            platform: "macOS",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            capabilities: clientCapabilities
        ))
    }

    private var clientCapabilities: Set<String> {
        var result: Set<String> = [PeelCapability.h264Video.rawValue,
            PeelCapability.binaryVideoTransportV2.rawValue, PeelCapability.perWindowVideoConnections.rawValue,
            PeelCapability.clientVisibility.rawValue, PeelCapability.clientWindowActivity.rawValue,
            PeelCapability.expandedKeyboard.rawValue, PeelCapability.inputFocus.rawValue,
            PeelCapability.pairingRevocation.rawValue, PeelCapability.videoKeyframeRequestV1.rawValue,
            "host-rendered-cursor", PeelClientStreamMetricsMessage.capability,
            // This viewer keeps its native AppKit pointer; a current host then
            // omits the baked video cursor. Shape stays the local arrow.
            "mac-native-cursor-v1"]
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) { result.insert(PeelCapability.hevcVideo.rawValue) }
        if allowsAgentPresentation && canReceiveAgentPresentation {
            result.insert(PeelCapability.agentPresentationV1.rawValue)
        }
        // Playback only; this viewer never advertises remote-voice-v1.
        if PeelRemoteMacAudioController.isPlaybackBackendAvailable {
            result.insert(PeelCapability.macSystemAudioV1.rawValue)
        }
        return result
    }

    private func tick() {
        guard control != nil, hasCurrentTrust, currentKeyMatches else { disconnect(reason: "This pairing is no longer available."); return }
        if let pendingAgentPresentation,
           pendingAgentPresentation.expiresAt <= Date().timeIntervalSince1970 {
            cancelPendingAgentPresentation(
                status: "unavailable",
                reason: "The window presentation request expired."
            )
        }
        let now = DispatchTime.now().uptimeNanoseconds
        if !isConnected, now - connectedAt > 12_000_000_000 {
            disconnect(reason: "Connection timed out. Check the other computer and try again."); return
        }
        if selectedWindow != nil, !hasVideo, now - streamStartedAt > 15_000_000_000 {
            disconnect(reason: "No video arrived. Check capture permissions on the other computer."); return
        }
        if isConnected, now - lastPing > 4_000_000_000 {
            lastPing = now
            send(ClientPingMessage())
        }
        if isConnected, now - lastWindowRefresh > 15_000_000_000 {
            lastWindowRefresh = now
            refreshWindows()
        }
        sendStreamingDiagnosticsSnapshot(now: now)
    }

    private func sendStreamingDiagnosticsSnapshot(now: UInt64) {
        guard isConnected, hasVideo, video != nil, !NSApp.isHidden, hasCurrentTrust,
              hostCapabilities.contains(PeelClientStreamMetricsMessage.capability),
              let window = selectedWindow, now - lastStreamMetricsAt >= 2_000_000_000,
              streamMetricsSequence < UInt64(Int64.max),
              pendingSendCount < 64, pendingSendBytes < 131_072 else { return }
        renderer.refreshStreamingPerformanceMetrics()
        guard let row = renderer.streamingDiagnosticSnapshot(windowId: window.windowId) else { return }
        let message = PeelClientStreamMetricsMessage(sequence: streamMetricsSequence + 1,
            sampledAtClientUptimeSeconds: ProcessInfo.processInfo.systemUptime, streams: [row])
        // Best-effort telemetry retains half the existing send budget as headroom for normal input.
        guard message.isValid, let data = try? JSONEncoder().encode(message), data.count < 16_384,
              pendingSendCount < 64, pendingSendBytes + data.count + 1 <= 131_072 else { return }
        streamMetricsSequence += 1
        lastStreamMetricsAt = now
        send(message)
        if ingressLoggingEnabled {
            // Cumulative maxima since stream selection; callback -> MainActor and callback -> rearm only.
            ingressLog.debug("callbacks=\(self.ingressCallbacks, privacy: .public) fullChunks=\(self.ingressFullChunks, privacy: .public) mainHopMaxMs=\(self.ingressMainHopMaximumMilliseconds, privacy: .public) rearmMaxMs=\(self.ingressRearmMaximumMilliseconds, privacy: .public)")
        }
    }

    private func resetIngressDiagnostics() {
        ingressCallbacks = 0; ingressFullChunks = 0
        ingressMainHopMaximumMilliseconds = 0; ingressRearmMaximumMilliseconds = 0
    }

    private func requestKeyframe() {
        guard let window = selectedWindow, isConnected,
              hostCapabilities.contains(PeelCapability.videoKeyframeRequestV1.rawValue) else { return }
        send(PeelVideoKeyframeRequestMessage(windowId: window.windowId))
    }

    private func send<T: Encodable>(_ message: T) {
        guard let control, hasCurrentTrust, var data = try? JSONEncoder().encode(message), data.count <= 16_384 else { return }
        data.append(10)
        guard pendingSendCount < 128, pendingSendBytes + data.count <= 262_144 else {
            disconnect(reason: "The remote connection cannot keep up. Reconnect to resume."); return
        }
        let count = data.count
        pendingSendCount += 1
        pendingSendBytes += count
        let generation = epoch
        control.send(content: data, completion: .contentProcessed { [weak self, weak control] error in
            Task { @MainActor [weak self, weak control] in
                guard let self, let control, self.epoch == generation, self.control === control else { return }
                self.pendingSendCount -= 1
                self.pendingSendBytes -= count
                if error != nil { self.disconnect(reason: "The remote connection ended.") }
            }
        })
    }

    private func receiveControl(_ connection: NWConnection, generation: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak connection] data, _, complete, error in
            Task { @MainActor [weak self, weak connection] in
                guard let self, let connection, self.epoch == generation, self.control === connection else { return }
                guard self.hasCurrentTrust else { self.disconnect(reason: "Pairing was removed."); return }
                if let data {
                    guard self.controlBuffer.count + data.count <= self.maximumControlBytes else { self.disconnect(reason: "The computer sent an oversized message."); return }
                    self.controlBuffer.append(data)
                    var lines = 0
                    while let end = self.controlBuffer.firstIndex(of: 10) {
                        lines += 1
                        guard lines <= 256 else { self.disconnect(reason: "The computer sent too many messages."); return }
                        let line = Data(self.controlBuffer[..<end])
                        self.controlBuffer = Data(self.controlBuffer[(end + 1)...])
                        self.handleControl(line)
                        guard self.epoch == generation else { return }
                    }
                }
                if complete || error != nil { self.disconnect(reason: "The computer disconnected."); return }
                self.receiveControl(connection, generation: generation)
            }
        }
    }

    private func handleControl(_ data: Data) {
        guard let envelope = try? JSONDecoder().decode(MessageEnvelope.self, from: data) else {
            disconnect(reason: "The computer sent an invalid message."); return
        }
        switch envelope.type {
        case "hostHello":
            guard let hello = try? JSONDecoder().decode(HostHelloMessage.self, from: data),
                  PeelProtocol.isCompatible(remoteCurrent: hello.protocolVersion, remoteMinimum: hello.minimumSupportedProtocolVersion),
                  Set(hello.capabilities ?? []).contains(PeelCapability.binaryVideoTransportV2.rawValue) else {
                disconnect(reason: "Update Peel Pro on this computer before connecting."); return
            }
            connectedPlatform = PeelRemoteMacPlatformLabel.title(for: hello.platform)
            hostCapabilities = Set(hello.capabilities ?? [])
            isConnected = true
            isConnecting = false
            status = "Choose a desktop or app window."
            send(ClientVisibilityMessage(isVisible: true))
            noteClientVisibilitySent(true)
            refreshWindows()
        case "windowList":
            guard isConnected, let list = try? JSONDecoder().decode(WindowListMessage.self, from: data), list.windows.count <= 2048 else { return }
            windows = list.windows.filter { $0.width > 0 && $0.height > 0 && $0.width <= 32768 && $0.height <= 32768 }
                .sorted { a, b in
                    let aDisplay = Self.isDesktop(a), bDisplay = Self.isDesktop(b)
                    return aDisplay != bDisplay ? aDisplay : a.title.localizedStandardCompare(b.title) == .orderedAscending
                }
            let revision = (currentWindowInventoryID?.revision ?? 0)
            guard revision < UInt64.max else {
                disconnect(reason: "Reconnect to refresh the window inventory.")
                return
            }
            let inventoryID = PeelRemoteMacWindowInventoryID(controlEpoch: epoch, revision: revision + 1)
            currentWindowInventoryID = inventoryID
            if let selectedWindow, !windows.contains(where: {
                self.agentWindowIdentityMatches(selectedWindow, current: $0, compareTitle: false)
            }) {
                disconnect(reason: "The selected desktop or app window is no longer available.")
            }
            if isConnected, currentWindowInventoryID == inventoryID {
                onWindowInventoryUpdated?(inventoryID)
            }
        case "agentPairingChallenge":
            guard let message = try? JSONDecoder().decode(PeelAgentPairingChallengeMessage.self, from: data) else { return }
            handleAgentPairingChallenge(message)
        case "presentWindow":
            guard let message = try? JSONDecoder().decode(PresentWindowMessage.self, from: data) else { return }
            handleAgentPresentation(message)
        case "audioPairingChallenge":
            guard let message = try? JSONDecoder().decode(PeelAudioPairingChallengeMessage.self, from: data) else { return }
            audio.receive(message)
        case "audioSessionState":
            guard let message = try? JSONDecoder().decode(PeelAudioSessionState.self, from: data) else { return }
            audio.receive(message)
        case PeelSourceMediaProtocol.ackType:
            guard data.count <= PeelSourceMediaProtocol.maximumLineBytes,
                  let message = try? JSONDecoder().decode(PeelSourceMediaAck.self, from: data) else { return }
            sourceMedia.receive(message)
        case PeelSourceMediaProtocol.volumeStateType:
            guard data.count <= PeelSourceMediaProtocol.maximumLineBytes,
                  let message = try? JSONDecoder().decode(PeelSourceVolumeState.self, from: data) else { return }
            sourceMedia.receive(message)
        case "inputRejected":
            if let rejection = try? JSONDecoder().decode(InputRejectedMessage.self, from: data), rejection.windowId == selectedWindow?.windowId {
                disableInputControl()
                inputStatus = String(rejection.reason.prefix(256))
            }
        case "pairingRevoked":
            if let message = try? JSONDecoder().decode(PairingRevokedMessage.self, from: data), message.pairingId == connectedPairingID {
                PeelICloudMacPairingController.noteExplicitForget(hostID: target?.peer.stableHostId)
                disconnect(reason: "The other computer revoked this pairing. Pair again in Peel Pro.")
            }
        case "disconnectReason", "protocolMismatch": disconnect(reason: "The other computer ended this session. Check its Peel Pro status.")
        default: break
        }
    }

    private func handleAgentPairingChallenge(_ message: PeelAgentPairingChallengeMessage) {
        guard allowsAgentPresentation,
              canReceiveAgentPresentation,
              control != nil,
              hasCurrentTrust,
              currentKeyMatches,
              let target,
              let key = targetKey,
              key.count == 32,
              connectedPairingID == message.pairingId,
              target.peer.id == message.pairingId,
              PeelAgentPairingProof.isFresh(message, now: Date().timeIntervalSince1970),
              let requestUUID = UUID(uuidString: message.requestId) else {
            return
        }

        let normalizedRequestID = requestUUID.uuidString
        guard lastHandledAgentPairingChallengeRequestID != normalizedRequestID else { return }
        lastHandledAgentPairingChallengeRequestID = normalizedRequestID

        guard let proof = PeelAgentPairingProof.make(message, key: key) else { return }
        send(PeelAgentPairingProofMessage(
            requestId: message.requestId,
            pairingId: message.pairingId,
            proof: proof
        ))
    }

    private func handleAgentPresentation(_ message: PresentWindowMessage) {
        let validation = validateAgentPresentation(message)
        switch validation {
        case .declined(let requestID, let reason):
            sendAgentPresentationResult(requestID: requestID, status: "declined", reason: reason)
        case .unavailable(let requestID, let reason):
            sendAgentPresentationResult(requestID: requestID, status: "unavailable", reason: reason)
        case .accepted(let requestID, let window, let context):
            guard reserveAgentPresentationRequest(requestID) else {
                // Duplicate delivery must not restart a stream or terminate the
                // original request before its first-frame result is available.
                return
            }

            if let pendingAgentPresentation,
               pendingAgentPresentation.expiresAt <= Date().timeIntervalSince1970 {
                cancelPendingAgentPresentation(
                    status: "unavailable",
                    reason: "The earlier window presentation request expired."
                )
            }

            guard pendingAgentPresentation == nil else {
                sendAgentPresentationResult(
                    requestID: requestID,
                    status: "unavailable",
                    reason: "Another window presentation is already in progress."
                )
                return
            }

            // The view owns the AppKit event surface. Release held input while
            // the gate is still open, then prevent any further input sends.
            onAgentPresentationWillSelectWindow?()
            disableInputControl()
            agentPresentationContext = nil
            pendingAgentPresentation = PendingAgentPresentation(
                requestID: requestID,
                epoch: epoch,
                window: window,
                expiresAt: message.expiresAt,
                context: context
            )

            guard selectWindow(window, preservingAgentRequestID: requestID) else {
                cancelPendingAgentPresentation(
                    status: "unavailable",
                    reason: "The requested window could not be opened."
                )
                return
            }
        }
    }

    private func validateAgentPresentation(_ message: PresentWindowMessage) -> AgentPresentationValidation {
        let requestID = message.requestId
        guard allowsAgentPresentation else {
            return .declined(
                requestID: requestID,
                reason: "Agent window opening is turned off on this viewer."
            )
        }
        guard canReceiveAgentPresentation else {
            return .unavailable(
                requestID: requestID,
                reason: "The computer browser and stream window are not visible."
            )
        }
        guard isConnected,
              hasCurrentTrust,
              currentKeyMatches,
              let target,
              connectedPairingID == message.pairingId,
              target.peer.id == message.pairingId else {
            return .unavailable(
                requestID: requestID,
                reason: "This request is for a different computer connection."
            )
        }
        guard let requestUUID = UUID(uuidString: requestID) else {
            return .unavailable(
                requestID: requestID,
                reason: "This request could not be identified."
            )
        }

        let now = Date().timeIntervalSince1970
        let ttl = message.expiresAt - message.issuedAt
        guard message.issuedAt.isFinite,
              message.expiresAt.isFinite,
              message.expiresAt >= now,
              ttl >= 0,
              ttl <= 60,
              message.issuedAt <= now + 5 else {
            return .unavailable(requestID: requestID, reason: "This request has expired.")
        }

        guard let current = windows.first(where: { $0.windowId == message.window.windowId }),
              agentWindowIdentityMatches(message.window, current: current) else {
            return .unavailable(
                requestID: requestID,
                reason: "That window is no longer available."
            )
        }

        let context: String?
        if let rawContext = message.context {
            guard rawContext.count <= 1000,
                  rawContext.utf8.count <= 4000,
                  rawContext.unicodeScalars.allSatisfy({ scalar in
                      scalar.value >= 32 || scalar == "\n" || scalar == "\t"
                  }) else {
                return .unavailable(
                    requestID: requestID,
                    reason: "The presentation context is too large or contains unsupported characters."
                )
            }
            context = rawContext.isEmpty ? nil : rawContext
        } else {
            context = nil
        }

        return .accepted(
            requestID: requestUUID.uuidString,
            window: current,
            context: context
        )
    }

    private func agentWindowIdentityMatches(_ expected: PeelWindow, current: PeelWindow, compareTitle: Bool = true) -> Bool {
        guard expected.windowId == current.windowId,
              expected.appName == current.appName,
              (!compareTitle || expected.title == current.title) else {
            return false
        }
        switch (expected.appLaunchTimeIntervalSince1970, current.appLaunchTimeIntervalSince1970) {
        case let (expectedLaunch?, currentLaunch?):
            return abs(expectedLaunch - currentLaunch) < 1
        case (nil, nil):
            return true
        default:
            return false
        }
    }

    @discardableResult
    private func reserveAgentPresentationRequest(_ normalizedRequestID: String) -> Bool {
        guard !handledAgentPresentationRequestIDs.contains(normalizedRequestID) else { return false }
        handledAgentPresentationRequestIDs.insert(normalizedRequestID)
        handledAgentPresentationRequestOrder.append(normalizedRequestID)
        while handledAgentPresentationRequestOrder.count > maxHandledAgentPresentationRequestIDs {
            let evicted = handledAgentPresentationRequestOrder.removeFirst()
            handledAgentPresentationRequestIDs.remove(evicted)
        }
        return true
    }

    private func completePendingAgentPresentationIfReady() {
        guard let pending = pendingAgentPresentation else { return }
        guard pending.epoch == epoch,
              canReceiveAgentPresentation,
              allowsAgentPresentation,
              isConnected,
              hasCurrentTrust,
              currentKeyMatches,
              video != nil,
              hasVideo,
              let selectedWindow,
              agentWindowIdentityMatches(pending.window, current: selectedWindow),
              Date().timeIntervalSince1970 < pending.expiresAt else {
            cancelPendingAgentPresentation(
                status: "unavailable",
                reason: "The requested window changed before its first frame."
            )
            return
        }

        pendingAgentPresentation = nil
        agentPresentationContext = pending.context
        sendAgentPresentationResult(requestID: pending.requestID, status: "opened")
    }

    private func cancelPendingAgentPresentation(status: String, reason: String) {
        guard let pending = pendingAgentPresentation else { return }
        pendingAgentPresentation = nil
        agentPresentationContext = nil
        sendAgentPresentationResult(requestID: pending.requestID, status: status, reason: reason)
    }

    private func sendAgentPresentationResult(requestID: String, status: String, reason: String? = nil) {
        send(AgentPresentationResultMessage(requestId: requestID, status: status, reason: reason))
    }

    static func isDesktop(_ window: PeelWindow) -> Bool {
        window.appName == "Peel Display" && (0xFFF0_0000..<0xFFF0_0040).contains(window.windowId)
    }

    private func receiveVideo(_ connection: NWConnection, generation: UUID) {
        // Every read waits for one MainActor turn before rearming. Take all
        // already-buffered bytes (as the Apple client does) so that turn rate
        // cannot cap video throughput and silently back up both TCP buffers.
        let chunkBytes = PeelRemoteMacVideoFramer.maximumInputChunkBytes
        connection.receive(minimumIncompleteLength: 1, maximumLength: chunkBytes) { [weak self, weak connection] data, _, complete, error in
            let callbackAt = ProcessInfo.processInfo.systemUptime
            Task { @MainActor [weak self, weak connection] in
                guard let self, let connection, self.epoch == generation, self.video === connection else { return }
                guard self.hasCurrentTrust else { self.disconnect(reason: "Pairing was removed."); return }
                let mainAdmittedAt = ProcessInfo.processInfo.systemUptime
                self.ingressCallbacks = min(9_000_000_000_000, self.ingressCallbacks + 1)
                if data?.count == chunkBytes { self.ingressFullChunks = min(9_000_000_000_000, self.ingressFullChunks + 1) }
                self.ingressMainHopMaximumMilliseconds = max(self.ingressMainHopMaximumMilliseconds,
                    max(0, ProcessInfo.processInfo.systemUptime - callbackAt) * 1000)
                if let data {
                    do {
                        let packets = try self.videoFramer.append(data)
                        // Same density bound as 128 packets per 64 KiB read.
                        guard packets.count <= chunkBytes / 512 else {
                            self.disconnect(reason: "The video packet rate exceeded its limit."); return
                        }
                        for packet in packets {
                            self.handleVideoPacket(packet)
                            guard self.epoch == generation else { return }
                        }
                    } catch {
                        self.disconnect(reason: "The computer sent an invalid video packet."); return
                    }
                }
                if complete || error != nil { self.disconnect(reason: "The video connection ended."); return }
                self.ingressRearmMaximumMilliseconds = max(self.ingressRearmMaximumMilliseconds,
                    max(0, ProcessInfo.processInfo.systemUptime - callbackAt) * 1000)
                self.renderer.recordIngressTiming(callbackAt: callbackAt, mainAdmittedAt: mainAdmittedAt,
                    rearmedAt: ProcessInfo.processInfo.systemUptime, fullChunk: data?.count == chunkBytes)
                self.receiveVideo(connection, generation: generation)
            }
        }
    }

    private func handleVideoPacket(_ packetData: Data) {
        if packetData.first == PeelBinaryPacketType.videoFrame.rawValue {
            guard let frame = VideoFramePacket(data: packetData), frame.windowId == selectedWindow?.windowId else {
                disconnect(reason: "Video stream identity changed."); return
            }
            renderer.enqueue(frame)
        } else {
            guard let config = VideoConfigPacket(data: packetData), config.windowId == selectedWindow?.windowId,
                  config.width > 0, config.height > 0, config.width <= 16384, config.height <= 16384,
                  UInt64(config.width) * UInt64(config.height) <= 67_108_864,
                  config.timescale > 0, config.timescale <= UInt32(Int32.max), config.nalUnitHeaderLength == 4 else {
                disconnect(reason: "Unsupported video configuration."); return
            }
            renderer.configure(config)
        }
    }
}

// MARK: - Computer audio adapters (playback only; see PeelRemoteMacAudioController)

extension PeelRemoteMacViewerController {
    /// Hook after every ClientVisibilityMessage send; hidden ends audio.
    private func noteClientVisibilitySent(_ visible: Bool) {
        audioClientVisible = visible
        audio.clientVisibilityChanged(visible)
    }

    private func makeAudioAdapters() -> PeelRemoteMacAudioController.Adapters {
        PeelRemoteMacAudioController.Adapters(
            context: { [weak self] in self?.audioContext() },
            sendRequest: { [weak self] message in self?.send(message) },
            sendProof: { [weak self] message in self?.send(message) },
            proof: { [weak self] challenge in self?.audioProof(for: challenge) },
            makeConnection: { [weak self] pairingID, controlEpoch in
                self?.makeAudioConnection(pairingID: pairingID, controlEpoch: controlEpoch)
            })
    }

    private func audioContext() -> PeelRemoteMacAudioContext? {
        guard control != nil, isConnected, hasCurrentTrust, let target,
              connectedPairingID == target.id else { return nil }
        let presenting = hasVideo && video != nil
        return PeelRemoteMacAudioContext(controlEpoch: epoch, pairingID: target.id,
            clientVisible: audioClientVisible,
            hostSupportsPlayback: hostCapabilities.contains(PeelCapability.macSystemAudioV1.rawValue),
            streamWindowID: presenting ? selectedWindow?.windowId : nil)
    }

    /// Same in-memory admitted key and checks as the agent pairing proof.
    private func audioProof(for challenge: PeelAudioPairingChallengeMessage) -> String? {
        guard control != nil, isConnected, hasCurrentTrust, currentKeyMatches,
              let target, let key = targetKey, key.count == 32,
              connectedPairingID == challenge.pairingId, target.peer.id == challenge.pairingId else { return nil }
        return PeelAudioPairingProof.make(challenge, key: key)
    }

    /// Auxiliary socket to the current control endpoint with the existing
    /// pairing TLS factory, like the video connection.
    private func makeAudioConnection(pairingID: String, controlEpoch: UUID) -> NWConnection? {
        guard control != nil, isConnected, epoch == controlEpoch, hasCurrentTrust, currentKeyMatches,
              let target, target.id == pairingID, connectedPairingID == pairingID,
              let key = targetKey, key.count == 32, let order = target.peer.tlsPSKOrder else { return nil }
        let parameters = PeelTLS.makeClientParameters(pairingID: target.id, psk: key, pskOrder: order)
        // Latency tuning stays local to the audio socket, as on the Apple client.
        parameters.serviceClass = .responsiveData
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        return NWConnection(to: target.endpoint, using: parameters)
    }
}

// MARK: - Source media adapters (contract v1; see PeelRemoteMacSourceMediaController)

extension PeelRemoteMacViewerController {
    private func makeSourceMediaAdapters() -> PeelRemoteMacSourceMediaController.Adapters {
        PeelRemoteMacSourceMediaController.Adapters(
            context: { [weak self] in self?.sourceMediaContext() },
            sendCommand: { [weak self] message in self?.sendSourceMediaInput(message) ?? false },
            sendVolumeSet: { [weak self] message in self?.sendSourceMediaInput(message) ?? false },
            sendVolumeQuery: { [weak self] message in self?.sendSourceMediaQuery(message) ?? false })
    }

    private func sourceMediaContext() -> PeelRemoteMacSourceMediaContext? {
        guard control != nil, isConnected, hasVideo, video != nil, hasCurrentTrust, let target,
              connectedPairingID == target.id, let window = selectedWindow else { return nil }
        return PeelRemoteMacSourceMediaContext(controlEpoch: epoch, pairingID: target.id,
            windowID: window.windowId,
            hostSupportsMediaKeys: hostCapabilities.contains(PeelSourceMediaProtocol.mediaKeysCapability),
            hostSupportsVolume: hostCapabilities.contains(PeelSourceMediaProtocol.volumeCapability),
            inputEnabled: inputEnabled)
    }

    /// Media keys and volume sets are user input: the existing explicit
    /// Control gate (sendInput) applies and is never reopened here.
    private func sendSourceMediaInput<T: Encodable>(_ message: T) -> Bool {
        guard inputEnabled, isConnected, hasVideo, hasCurrentTrust else { return false }
        sendInput(message)
        return true
    }

    /// Read-only query on the current paired control connection.
    private func sendSourceMediaQuery(_ message: PeelSourceVolumeQuery) -> Bool {
        guard isConnected, hasVideo, video != nil, hasCurrentTrust, audioClientVisible else { return false }
        send(message)
        return true
    }
}
