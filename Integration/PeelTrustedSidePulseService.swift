import Combine
import Foundation
import Network

#if PEEL_SIGNAL_STARTUP_TESTS
// Nonshipping focused-check seam only: the startup fixture supplies recording
// drivers with the same surface. Shipping builds use Network directly.
fileprivate typealias PeelSignalListenerDriver = PeelSignalStartupTestListener
fileprivate typealias PeelSignalBrowserDriver = PeelSignalStartupTestBrowser
#else
fileprivate typealias PeelSignalListenerDriver = NWListener
fileprivate typealias PeelSignalBrowserDriver = NWBrowser
#endif

/// Paired-Mac agent metadata settings. Independent of SidePulse's LED
/// sharing/follow configuration, which keeps its original meaning.
struct PeelPeerAgentConfiguration: Equatable, Sendable {
    /// Publish this Mac's agent session list to paired Macs.
    var sharesAgents: Bool
    /// Show paired Macs' agent sessions (and usage summaries) here.
    var receivesAgents: Bool
    /// Let a paired Mac ask this Mac to open one of this Mac's own sessions.
    var allowsPeerActivation: Bool
    /// Publish a bounded usage summary alongside the session list.
    var sharesUsage: Bool

    static let disabled = PeelPeerAgentConfiguration(sharesAgents: false, receivesAgents: false,
                                                     allowsPeerActivation: false, sharesUsage: false)

    /// Usage and activation require session sharing (see ownerSupportedFeatures).
    var listens: Bool { sharesAgents }
}

/// Per paired Mac, what the agent-metadata link is doing right now.
enum PeelPeerLinkStatus: Equatable, Sendable {
    case notDiscovered
    case connecting
    case live
    /// The other Mac answered without agent features (older Peel).
    case legacyPeer
    /// Connected, but the other Mac is not sharing its agents.
    case ownerNotSharing
    /// The stored pairing key could not be read on this Mac.
    case keyUnavailable
}

/// Events delivered to the Host's peer agent store on the main actor.
enum PeelPeerAgentServiceEvent: Sendable {
    case message(hostID: UUID, label: String, socketID: UUID, PeelPeerAgentMessage)
    case socketClosed(hostID: UUID, socketID: UUID)
    case trust(labels: [UUID: String])
    case links([UUID: PeelPeerLinkStatus], activationAccepted: Set<UUID>)
}

/// Owner-side activation callback. The handler must call `stillAuthorized`
/// immediately before its side effect and deliver exactly one outcome.
typealias PeelPeerActivationHandler = @MainActor (
    _ localID: String,
    _ requesterLabel: String,
    _ stillAuthorized: @escaping @MainActor () -> Bool,
    _ completion: @escaping @MainActor (PeelPeerActivationOutcome, String?) -> Void
) -> Void

enum PeelPeerActivationSend: Equatable, Sendable {
    case sent(socketID: UUID)
    case ownerOffline
    case peerTooOld
    case notAllowed
}

/// SidePulse's existing routing consumes this transport through its service seam.
/// Bonjour locates a Mac; Peel's stored key and a fresh bilateral proof authorize it.
/// The same authenticated socket also carries negotiated agent metadata
/// (owner → viewer) and activation requests (viewer → owner).
@MainActor
final class PeelTrustedSidePulseService: SidePulseSignalServicing {
    static let serviceType = "_peel-signal._tcp"
    private static let maximumSockets = 16
    private static let maximumLineBytes = 12_288
    private static let maximumPendingControl = 4
    private static let agentKeepaliveNanoseconds: UInt64 = 5_000_000_000
    private static let agentMinimumGapNanoseconds: UInt64 = 250_000_000
    private static let usageMinimumGapNanoseconds: UInt64 = 30_000_000_000

    private struct Peer {
        let record: PeelPairedPeer
        let hostID: UUID
        let pairingID: UUID
        let key: Data
    }

    private enum Phase { case initial, challenge, proof, ready }
    private final class Socket {
        let id = UUID()
        let connection: NWConnection
        let outgoing: Bool
        var phase = Phase.initial
        var peer: Peer?
        var hello: PeelSignalHello?
        var challenge: PeelSignalChallenge?
        var buffer = Data()
        var sendPending = false
        var pendingControlData: [Data] = []
        var lastWriterLane: PeelPeerWriterLane?
        var receivedFrame = false
        var lastFrameUptime: UInt64 = 0
        var lastSentFrameUptime: UInt64 = 0
        var burstStartUptime: UInt64 = 0
        var burstFrameCount = 0
        var lastSequence: UInt64?
        /// Negotiated v2 features. Always empty on a v1 (legacy) socket.
        var features: Set<String> = []
        var negotiatedV2 = false
        var sentAgentRevision: UInt64?
        var lastAgentSendUptime: UInt64 = 0
        var sentUsageRevision: UInt64?
        var lastUsageSendUptime: UInt64 = 0
        let createdAt = DispatchTime.now().uptimeNanoseconds

        init(connection: NWConnection, outgoing: Bool, peer: Peer? = nil) {
            self.connection = connection
            self.outgoing = outgoing
            self.peer = peer
        }
    }

    private let nodeID: UUID
    private let hostID: UUID
    private let displayName: String
    private let pairingStore: PeelPairingStore
    private let onPeers: @Sendable ([NearbySignalPeer]) -> Void
    private let onSignal: @Sendable (ReceivedNearbySignal) -> Void
    private let onStatus: @Sendable (String) -> Void
    private let onSnapshot: @Sendable (NearbySignalServiceSnapshot) -> Void
    private let ioQueue = DispatchQueue(label: "peel.trusted-sidepulse.io", qos: .utility)
    private var configuration = NearbySignalServiceConfiguration.localOnly
    private var peerAgentConfiguration = PeelPeerAgentConfiguration.disabled
    private var trust: [UUID: Peer] = [:]
    private var keyUnavailableHostIDs: Set<UUID> = []
    private var endpoints: [UUID: NWEndpoint] = [:]
    private var sockets: [UUID: Socket] = [:]
    private var listener: PeelSignalListenerDriver?
    private var browser: PeelSignalBrowserDriver?
    private var listenerReady = false
    private var browserReady = false
    private var epoch = UUID()
    /// Local startup diagnostic only; never changes network behavior.
    private var startup = NearbySignalStartupTracker()
    private var startupPublished = false
    private var latestFrame: NearbySignalFrame?
    private var heartbeat: DispatchSourceTimer?
    private var trustObservation: AnyCancellable?
    private var retryAfter: [UUID: UInt64] = [:]

    // Agent metadata (owner side).
    private var owner = PeelPeerAgentOwnerState()
    private var usageInput = PeelPeerUsageLocalInput.empty
    private var usageRevision: UInt64 = 0
    private var activationGuards: [UUID: PeelPeerActivationGuard] = [:]
    private var agentFlushScheduled = false
    private var lastLinks: [UUID: PeelPeerLinkStatus] = [:]
    private var lastActivationAccepted: Set<UUID> = []

    /// Set by the Host before configuring peer agents.
    var onPeerAgentEvent: (@MainActor (PeelPeerAgentServiceEvent) -> Void)?
    var activationHandler: PeelPeerActivationHandler?

    init(nodeID: UUID, hostID: UUID, displayName: String, pairingStore: PeelPairingStore,
         onPeers: @escaping @Sendable ([NearbySignalPeer]) -> Void,
         onSignal: @escaping @Sendable (ReceivedNearbySignal) -> Void,
         onStatus: @escaping @Sendable (String) -> Void,
         onSnapshot: @escaping @Sendable (NearbySignalServiceSnapshot) -> Void) {
        self.nodeID = nodeID
        self.hostID = hostID
        self.displayName = displayName
        self.pairingStore = pairingStore
        self.onPeers = onPeers
        self.onSignal = onSignal
        self.onStatus = onStatus
        self.onSnapshot = onSnapshot
        trustObservation = pairingStore.$paired.sink { [weak self] peers in
            Task { @MainActor [weak self] in self?.replaceTrust(peers) }
        }
    }

    func configure(_ configuration: NearbySignalServiceConfiguration) {
        guard self.configuration != configuration else {
            // An all-off install never restarts; report its startup state once.
            if !startupPublished { publishSnapshot() }
            return
        }
        self.configuration = configuration
        restartNetwork()
    }

    /// Agent metadata settings. Changing them restarts sockets so every
    /// socket renegotiates its features from the new settings.
    func configurePeerAgents(_ configuration: PeelPeerAgentConfiguration) {
        // Always (re)deliver current trust labels so a handler attached after
        // the first trust load still sees every paired Mac.
        var labels: [UUID: String] = [:]
        for peer in trust.values { labels[peer.hostID] = peer.record.displayName }
        onPeerAgentEvent?(.trust(labels: labels))
        guard peerAgentConfiguration != configuration else { return }
        peerAgentConfiguration = configuration
        restartNetwork()
    }

    func updateLocalFrame(_ frame: NearbySignalFrame) {
        guard UUID(uuidString: frame.sourceNodeID) == nodeID,
              (try? frame.validated()) != nil else { return }
        latestFrame = frame
        for socket in Array(sockets.values) where !socket.outgoing { pump(socket) }
    }

    /// Owner side: replaces the shared projection of this Mac's sessions.
    func updateLocalAgents(_ sessions: [PeelPeerAgentLocalSession],
                           integrations: [PeelPeerProviderIntegration] = []) {
        guard owner.update(sessions, integrations: integrations) else { return }
        scheduleAgentFlush()
    }

    /// Owner side: replaces the usage summary input (in-process only).
    func updateLocalUsage(_ input: PeelPeerUsageLocalInput) {
        guard input != usageInput else { return }
        usageInput = input
        usageRevision &+= 1
        for socket in Array(sockets.values) where !socket.outgoing { pump(socket) }
    }

    /// Viewer side: sends one activation request to the authenticated owner.
    /// Never falls back to another socket, peer or this Mac.
    /// `bindingRevision` is the target row's revision as last offered.
    func sendActivation(hostID ownerID: UUID, token: String, bootEpoch: UUID, bindingRevision revision: UInt64,
                        requestID: UUID) -> PeelPeerActivationSend {
        guard let socket = sockets.values.first(where: {
            $0.outgoing && $0.phase == .ready && $0.peer?.hostID == ownerID
        }), let peer = socket.peer, peerIsTrusted(peer) else { return .ownerOffline }
        guard socket.negotiatedV2 else { return .peerTooOld }
        guard socket.features.contains(PeelPeerAgentFeature.activate) else { return .notAllowed }
        let request = PeelPeerAgentActivate(requestId: requestID, token: token, bootEpoch: bootEpoch,
                                            revision: revision)
        guard send(request, socket: socket) else { return .ownerOffline }
        return .sent(socketID: socket.id)
    }

    /// Viewer side: the store found an epoch/revision violation on a socket.
    func closeAgentSocket(_ socketID: UUID) {
        guard let socket = sockets[socketID] else { return }
        close(socket)
    }

    /// In-process only: the pairing key for viewer-side pair-tag comparisons.
    func pairKey(for ownerID: UUID) -> Data? {
        trust.values.first(where: { $0.hostID == ownerID })?.key
    }

    func stop() {
        configuration = .localOnly
        peerAgentConfiguration = .disabled
        stopNetwork()
    }

    private func replaceTrust(_ records: [PeelPairedPeer]) {
        var next: [UUID: Peer] = [:]
        var unavailable: Set<UUID> = []
        for record in records.prefix(128) {
            // On an initiating Mac stableHostId is stored after PIN pairing.
            // On the receiving Mac the existing PIN contract stores the other
            // Mac's stable clientDeviceId in serviceName. Names never authorize.
            guard let pairingID = UUID(uuidString: record.id),
                  let remoteID = UUID(uuidString: record.stableHostId ?? record.serviceName ?? ""),
                  remoteID != hostID else { continue }
            guard let key = pairingStore.psk(for: record.id), key.count == 32 else {
                // Surface the paired Mac instead of silently omitting it. No
                // background Keychain retry happens here.
                unavailable.insert(remoteID)
                continue
            }
            next[pairingID] = Peer(record: record, hostID: remoteID, pairingID: pairingID, key: key)
        }
        let stillUnavailable = unavailable.subtracting(next.values.map(\.hostID))
        let unchanged = trust.count == next.count && next.allSatisfy { id, peer in
            guard let previous = trust[id] else { return false }
            return previous.hostID == peer.hostID && previous.key == peer.key &&
                previous.record.displayName == peer.record.displayName
        } && keyUnavailableHostIDs == stillUnavailable
        guard !unchanged else { return }
        // Replay/rate state is per authenticated peer and survives ordinary
        // reconnects; it is discarded only when that peer's trust or key changes.
        let unchangedKeys = Set(next.values.compactMap { peer -> UUID? in
            trust.values.contains { $0.hostID == peer.hostID && $0.key == peer.key } ? peer.hostID : nil
        })
        trust = next
        keyUnavailableHostIDs = stillUnavailable
        activationGuards = activationGuards.filter { id, _ in unchangedKeys.contains(id) }
        var labels: [UUID: String] = [:]
        for peer in next.values { labels[peer.hostID] = peer.record.displayName }
        onPeerAgentEvent?(.trust(labels: labels))
        // Revocation and replacement invalidate every pending proof and socket.
        restartNetwork()
    }

    private func stopNetwork() {
        epoch = UUID()
        startup.begin(epoch)
        listener?.newConnectionHandler = nil
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        browser?.browseResultsChangedHandler = nil
        browser?.stateUpdateHandler = nil
        browser?.cancel()
        browser = nil
        heartbeat?.cancel()
        heartbeat = nil
        let closing = Array(sockets.values)
        for socket in closing {
            socket.connection.stateUpdateHandler = nil
            socket.connection.cancel()
        }
        sockets.removeAll()
        for socket in closing { notifyClosed(socket) }
        endpoints.removeAll()
        retryAfter.removeAll()
        listenerReady = false
        browserReady = false
        onPeers([])
        publish()
    }

    private var listens: Bool { configuration.sharesLocalSignal || peerAgentConfiguration.listens }
    private var browses: Bool { configuration.discoversPeers || peerAgentConfiguration.receivesAgents }

    private func restartNetwork() {
        stopNetwork()
        guard listens || browses else { return }
        if listens, !trust.isEmpty { startListener() }
        if browses { startBrowser() }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.tick() }
        heartbeat = timer
        timer.resume()
        publish()
    }

    private func startListener() {
        let records = trust.values.map(\.record)
        let keys = Dictionary(uniqueKeysWithValues: trust.values.map { ($0.record.id, $0.key) })
        let parameters = PeelTLS.makeHostParameters(pairedPeers: records, keyProvider: { keys[$0] })
        do {
            let listener = try PeelSignalListenerDriver(using: parameters)
            let generation = epoch
            // `agents` is a discovery hint only; identity and features come
            // from the authenticated handshake. `version` stays "1" so older
            // browsers continue to discover this Mac.
            var txtValues: [String: Data] = [
                "hostId": Data(hostID.uuidString.utf8), "version": Data("1".utf8)
            ]
            if peerAgentConfiguration.sharesAgents { txtValues["agents"] = Data("1".utf8) }
            let txt = NetService.data(fromTXTRecord: txtValues)
            listener.service = NWListener.Service(
                name: String("Peel Signals · \(displayName)".prefix(45)),
                type: Self.serviceType, domain: nil, txtRecord: txt)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self, self.epoch == generation else { return }
                    if case .ready = state {
                        self.listenerReady = true
                        self.startup.recordReady(.listener, generation: generation)
                    }
                    if case .waiting = state { self.startup.record(.listenerWaiting, generation: generation) }
                    if case .failed = state {
                        self.listenerReady = false
                        self.startup.record(.listenerFailed, generation: generation)
                        self.scheduleNetworkRetry(generation)
                    }
                    self.publish()
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    guard let self, self.epoch == generation else { connection.cancel(); return }
                    self.accept(connection)
                }
            }
            self.listener = listener
            listener.start(queue: ioQueue)
        } catch {
            startup.record(.listenerCreate, generation: epoch)
            onStatus("Could not start paired computer sharing: \(error.localizedDescription)")
        }
    }

    private func startBrowser() {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = PeelSignalBrowserDriver(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil),
                                              using: parameters)
        let generation = epoch
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.epoch == generation else { return }
                if case .ready = state {
                    self.browserReady = true
                    self.startup.recordReady(.browser, generation: generation)
                }
                if case .waiting = state { self.startup.record(.browserWaiting, generation: generation) }
                if case .failed = state {
                    self.browserReady = false
                    self.startup.record(.browserFailed, generation: generation)
                    self.scheduleNetworkRetry(generation)
                }
                self.publish()
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                guard let self, self.epoch == generation else { return }
                self.receiveDiscovery(results)
            }
        }
        self.browser = browser
        browser.start(queue: ioQueue)
    }

    private func receiveDiscovery(_ results: Set<NWBrowser.Result>) {
        var next: [UUID: NWEndpoint] = [:]
        let allowed = Set(trust.values.map(\.hostID))
        for result in results.prefix(128) {
            guard case .bonjour(let txt) = result.metadata,
                  let value = txt.dictionary["hostId"],
                  let id = UUID(uuidString: value), allowed.contains(id), id != hostID,
                  txt.dictionary["version"] == "1" else { continue }
            next[id] = result.endpoint
        }
        let changed = Set(endpoints.keys).union(next.keys).filter { endpoints[$0] != next[$0] }
        endpoints = next
        for socket in Array(sockets.values) where socket.outgoing {
            if let id = socket.peer?.hostID, changed.contains(id) { close(socket, retry: false) }
        }
        onPeers(next.keys.compactMap { id in
            guard let peer = trust.values.first(where: { $0.hostID == id }) else { return nil }
            return NearbySignalPeer(id: id.uuidString, displayName: peer.record.displayName)
        }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending })
        connectDesired()
        publish()
    }

    /// LED frames from this peer drive SidePulse routing (unchanged semantics).
    private func ledDesired(_ hostID: UUID) -> Bool {
        configuration.discoversPeers && (configuration.followsAllPeers ||
            configuration.followedPeerIDs.contains(where: { UUID(uuidString: $0) == hostID }))
    }

    /// A subscription socket is wanted for LED following OR agent metadata.
    private func desired(_ hostID: UUID) -> Bool {
        ledDesired(hostID) || peerAgentConfiguration.receivesAgents
    }

    private var requestedFeatures: [String]? {
        peerAgentConfiguration.receivesAgents ? PeelPeerAgentFeature.all : nil
    }

    private var ownerSupportedFeatures: [String] {
        // Activation and usage ride on a session-sharing socket: its
        // snapshots/keepalives provide the epoch and liveness they depend on.
        var features: [String] = []
        if peerAgentConfiguration.sharesAgents {
            features.append(PeelPeerAgentFeature.agents)
            if peerAgentConfiguration.allowsPeerActivation { features.append(PeelPeerAgentFeature.activate) }
            if peerAgentConfiguration.sharesUsage { features.append(PeelPeerAgentFeature.usage) }
        }
        return PeelSignalContract.canonicalFeatures(features)
    }

    private func connectDesired() {
        let now = DispatchTime.now().uptimeNanoseconds
        for (remoteID, endpoint) in endpoints where desired(remoteID) {
            guard sockets.count < Self.maximumSockets,
                  !sockets.values.contains(where: { $0.outgoing && $0.peer?.hostID == remoteID }),
                  now >= (retryAfter[remoteID] ?? 0),
                  let peer = trust.values.first(where: { $0.hostID == remoteID }) else { continue }
            // This new endpoint supports standard PSK order only. It never falls
            // back to the insecure historical identity-first compatibility mode.
            let parameters = PeelTLS.makeClientParameters(
                pairingID: peer.record.id, psk: peer.key, pskOrder: .standard)
            start(Socket(connection: NWConnection(to: endpoint, using: parameters),
                         outgoing: true, peer: peer))
        }
    }

    private func accept(_ connection: NWConnection) {
        guard listens, sockets.count < Self.maximumSockets else {
            connection.cancel(); return
        }
        start(Socket(connection: connection, outgoing: false))
    }

    private func start(_ socket: Socket) {
        sockets[socket.id] = socket
        socket.connection.stateUpdateHandler = { [weak self, weak socket] state in
            Task { @MainActor [weak self, weak socket] in
                guard let self, let socket, self.current(socket) else { return }
                switch state {
                case .ready:
                    if socket.outgoing {
                        guard let peer = socket.peer,
                              let hello = try? PeelSignalHello(pairingId: peer.pairingID,
                                publisherHostId: peer.hostID, subscriberHostId: self.hostID,
                                subscriberNodeId: self.nodeID, clientNonce: PeelSignalAuthentication.mintNonce(),
                                features: self.requestedFeatures) else {
                            self.close(socket); return
                        }
                        socket.hello = hello
                        socket.phase = .challenge
                        self.send(hello, socket: socket)
                    }
                    self.receive(socket)
                case .failed, .cancelled: self.close(socket)
                default: break
                }
            }
        }
        socket.connection.start(queue: ioQueue)
    }

    private func current(_ socket: Socket) -> Bool { sockets[socket.id] === socket }

    private func peerIsTrusted(_ peer: Peer) -> Bool {
        trust[peer.pairingID]?.key == peer.key &&
            pairingStore.paired.contains(where: { $0.id == peer.record.id })
    }

    private func receive(_ socket: Socket) {
        guard current(socket) else { return }
        socket.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak socket] data, _, complete, error in
            Task { @MainActor [weak self, weak socket] in
                guard let self, let socket, self.current(socket) else { return }
                if let data {
                    guard socket.buffer.count + data.count <= Self.maximumLineBytes + 4096 else {
                        self.close(socket); return
                    }
                    socket.buffer.append(data)
                    var lines = 0
                    while let newline = socket.buffer.firstIndex(of: 10) {
                        guard lines < 4, newline <= Self.maximumLineBytes else { self.close(socket); return }
                        let line = Data(socket.buffer.prefix(upTo: newline))
                        socket.buffer.removeSubrange(...newline)
                        lines += 1
                        self.consume(line, socket: socket)
                        guard self.current(socket) else { return }
                    }
                    guard socket.buffer.count <= Self.maximumLineBytes else { self.close(socket); return }
                }
                if complete || error != nil { self.close(socket) }
                else { self.receive(socket) }
            }
        }
    }

    private func consume(_ data: Data, socket: Socket) {
        do {
            if socket.phase != .ready {
                guard data.count <= 4096,
                      DispatchTime.now().uptimeNanoseconds - socket.createdAt <= 10_000_000_000 else {
                    close(socket); return
                }
            }
            switch (socket.outgoing, socket.phase) {
            case (false, .initial):
                let hello = try JSONDecoder().decode(PeelSignalHello.self, from: data)
                guard hello.publisherHostId == hostID,
                      let peer = trust[hello.pairingId], peerIsTrusted(peer), peer.hostID == hello.subscriberHostId,
                      hello.subscriberNodeId != nodeID else { close(socket); return }
                // v1 hello ⇒ v1 challenge, LED only. Featured hello ⇒ explicit
                // v2 challenge binding both lists (possibly granting none).
                let challenge = try PeelSignalAuthentication.makeNegotiatedChallenge(hello: hello,
                    serverNonce: PeelSignalAuthentication.mintNonce(), publisherNodeId: nodeID, key: peer.key,
                    supportedFeatures: ownerSupportedFeatures)
                let granted = PeelSignalAuthentication.negotiatedFeatures(challenge: challenge)
                // A socket that would carry nothing is refused, as before.
                guard configuration.sharesLocalSignal || !granted.isEmpty else { close(socket); return }
                socket.peer = peer
                socket.hello = hello
                socket.challenge = challenge
                socket.phase = .proof
                send(challenge, socket: socket)
            case (false, .proof):
                let proof = try JSONDecoder().decode(PeelSignalProof.self, from: data)
                guard let hello = socket.hello, let challenge = socket.challenge,
                      let peer = socket.peer, peerIsTrusted(peer),
                      PeelSignalAuthentication.verifyNegotiatedClientProof(proof, hello: hello,
                        challenge: challenge, key: peer.key) else {
                    close(socket); return
                }
                socket.features = PeelSignalAuthentication.negotiatedFeatures(challenge: challenge)
                socket.negotiatedV2 = challenge.features != nil
                socket.phase = .ready
                pump(socket)
                publish()
            case (true, .challenge):
                let challenge = try JSONDecoder().decode(PeelSignalChallenge.self, from: data)
                guard let hello = socket.hello, let peer = socket.peer,
                      peerIsTrusted(peer),
                      PeelSignalAuthentication.verifyNegotiatedServerProof(challenge, hello: hello, key: peer.key) else {
                    close(socket); return
                }
                let proof = try PeelSignalProof(proof: PeelSignalAuthentication.negotiatedClientProof(
                    hello: hello, challenge: challenge, key: peer.key))
                socket.challenge = challenge
                socket.features = PeelSignalAuthentication.negotiatedFeatures(challenge: challenge)
                socket.negotiatedV2 = challenge.features != nil
                socket.phase = .ready
                send(proof, socket: socket)
                // An older publisher, or one granting nothing, cannot supply
                // anything this Mac wants unless LED following is selected.
                if !ledDesired(peer.hostID), !socket.features.contains(PeelPeerAgentFeature.agents) {
                    retryAfter[peer.hostID] = DispatchTime.now().uptimeNanoseconds + 60_000_000_000
                    publishLinks(forcedStatus: [peer.hostID: socket.negotiatedV2 ? .ownerNotSharing : .legacyPeer])
                    close(socket, retry: false)
                    return
                }
                publish()
            case (true, .ready):
                try consumeSubscriberLine(data, socket: socket)
            case (false, .ready):
                try consumeOwnerLine(data, socket: socket)
            default: close(socket)
            }
        } catch { close(socket) }
    }

    /// Viewer side of a ready socket: LED frames plus negotiated agent data.
    private func consumeSubscriberLine(_ data: Data, socket: Socket) throws {
        guard let peer = socket.peer, let challenge = socket.challenge, peerIsTrusted(peer) else {
            close(socket); return
        }
        let type = PeelPeerAgentWire.messageType(of: data)
        let now = DispatchTime.now().uptimeNanoseconds
        if now - socket.burstStartUptime > 1_000_000_000 {
            socket.burstStartUptime = now
            socket.burstFrameCount = 0
        }
        socket.burstFrameCount += 1
        guard socket.burstFrameCount <= (socket.features.isEmpty ? 8 : 12) else { close(socket); return }

        if type == PeelSignalFrame.messageType {
            let envelope = try JSONDecoder().decode(PeelSignalFrame.self, from: data)
            var frame = try JSONDecoder().decode(NearbySignalFrame.self, from: envelope.payload).validated()
            guard UUID(uuidString: frame.sourceNodeID) == challenge.publisherNodeId,
                  [frame.generatedAt, frame.sentAt, frame.programStartedAt].allSatisfy({ $0.timeIntervalSince1970.isFinite }),
                  abs(frame.sentAt.timeIntervalSince(frame.programStartedAt)) < 366 * 86400,
                  socket.lastSequence.map({ frame.sequence >= $0 }) ?? true else { close(socket); return }
            socket.lastFrameUptime = now
            socket.lastSequence = frame.sequence
            socket.receivedFrame = true
            // LED frames only reach SidePulse routing for followed peers.
            // Routing uses the authenticated Peel peer identity, never a
            // service name or a frame-supplied identity from another Mac.
            if ledDesired(peer.hostID) {
                frame.sourceNodeID = peer.hostID.uuidString
                onSignal(ReceivedNearbySignal(peerID: peer.hostID.uuidString, frame: frame, receivedAt: .now))
            }
            publish()
            return
        }

        guard let type, PeelPeerAgentWire.messageTypes.contains(type), type != PeelPeerAgentActivate.messageType else {
            close(socket); return
        }
        let message = try PeelPeerAgentWire.decode(data)
        // Every agent message requires its feature on THIS socket; a v1
        // socket never accepts one.
        guard socket.features.contains(PeelPeerAgentWire.requiredFeature(for: message)) else {
            close(socket); return
        }
        socket.lastFrameUptime = now
        onPeerAgentEvent?(.message(hostID: peer.hostID, label: peer.record.displayName,
                                   socketID: socket.id, message))
        publishLinks()
    }

    /// Owner side of a ready socket: only negotiated activation requests.
    private func consumeOwnerLine(_ data: Data, socket: Socket) throws {
        guard let peer = socket.peer, peerIsTrusted(peer),
              socket.features.contains(PeelPeerAgentFeature.activate),
              PeelPeerAgentWire.messageType(of: data) == PeelPeerAgentActivate.messageType,
              case .activate(let request) = try PeelPeerAgentWire.decode(data) else {
            close(socket); return
        }
        handleActivation(request, socket: socket, peer: peer)
    }

    private func handleActivation(_ request: PeelPeerAgentActivate, socket: Socket, peer: Peer) {
        guard peerAgentConfiguration.allowsPeerActivation, peerAgentConfiguration.sharesAgents else {
            reply(request.requestId, .notAllowed, socket: socket)
            return
        }
        var admission = activationGuards[peer.hostID] ?? PeelPeerActivationGuard()
        let decision = admission.admit(request, owner: owner, now: .now)
        activationGuards[peer.hostID] = admission
        switch decision {
        case .inFlight:
            return
        case .replay(let outcome), .reject(let outcome), .refuse(let outcome):
            reply(request.requestId, outcome, socket: socket)
        case .execute(let localID):
            let ownerID = peer.hostID
            let requestID = request.requestId
            let stillAuthorized: @MainActor () -> Bool = { [weak self, weak socket] in
                guard let self, let socket, self.current(socket), let peer = socket.peer else { return false }
                // Same trusted socket, consent still on, and the target is
                // still offered at the exact binding revision the viewer saw.
                return self.peerIsTrusted(peer) && self.peerAgentConfiguration.allowsPeerActivation
                    && self.peerAgentConfiguration.sharesAgents
                    && socket.features.contains(PeelPeerAgentFeature.activate)
                    && self.owner.check(token: request.token, bindingRevision: request.revision)
                        == .current(localID: localID)
            }
            guard let handler = activationHandler else {
                finishActivation(requestID, ownerID: ownerID, outcome: .unsupported, appLabel: nil, socket: socket)
                return
            }
            handler(localID, peer.record.displayName, stillAuthorized) { [weak self, weak socket] outcome, appLabel in
                guard let self else { return }
                self.finishActivation(requestID, ownerID: ownerID, outcome: outcome, appLabel: appLabel, socket: socket)
            }
        }
    }

    private func finishActivation(_ requestID: UUID, ownerID: UUID, outcome: PeelPeerActivationOutcome,
                                  appLabel: String?, socket: Socket?) {
        let safeOutcome = PeelPeerActivationOutcome.viewerOnly.contains(outcome) ? .launchFailed : outcome
        guard activationGuards[ownerID]?.complete(requestID, outcome: safeOutcome, now: .now) == true else { return }
        // Results go only to the same live, trusted socket the request came on.
        guard let socket, current(socket), let peer = socket.peer, peerIsTrusted(peer) else { return }
        reply(requestID, safeOutcome, appLabel: appLabel, socket: socket)
    }

    private func reply(_ requestID: UUID, _ outcome: PeelPeerActivationOutcome, appLabel: String? = nil,
                       socket: Socket) {
        send(PeelPeerAgentActivateResult(requestId: requestID, outcome: outcome, appLabel: appLabel), socket: socket)
    }

    @discardableResult
    private func send<T: Encodable>(_ message: T, socket: Socket, isFrame: Bool = false) -> Bool {
        guard current(socket),
              var data = try? JSONEncoder().encode(message), data.count <= Self.maximumLineBytes else { return false }
        data.append(10)
        if socket.sendPending {
            // A peer response may reach main before the previous write's
            // completion hop. Keep a small bounded control queue; frames and
            // snapshots simply use the latest cached value on their next
            // writer turn.
            guard !isFrame else { return false }
            let limit = socket.phase == .ready ? Self.maximumPendingControl : 1
            guard socket.pendingControlData.count < limit, data.count <= 4097 else { close(socket); return false }
            socket.pendingControlData.append(data)
            return true
        }
        sendData(data, socket: socket)
        return true
    }

    private func sendData(_ data: Data, socket: Socket) {
        guard current(socket), !socket.sendPending else { return }
        socket.sendPending = true
        socket.connection.send(content: data, completion: .contentProcessed { [weak self, weak socket] error in
            Task { @MainActor [weak self, weak socket] in
                guard let self, let socket, self.current(socket) else { return }
                socket.sendPending = false
                if error != nil { self.close(socket); return }
                if !socket.pendingControlData.isEmpty {
                    let next = socket.pendingControlData.removeFirst()
                    self.sendData(next, socket: socket)
                } else {
                    // Hand the free writer to whichever metadata or LED lane
                    // is due; ticks alone would always find the writer busy.
                    self.pump(socket)
                }
            }
        })
    }

    /// Owner side: offers the free writer to LED frames, agent state and
    /// usage in rotation (`PeelPeerWriterTurns`), so none can starve another.
    private func pump(_ socket: Socket) {
        guard current(socket), !socket.outgoing, socket.phase == .ready, !socket.sendPending,
              socket.pendingControlData.isEmpty else { return }
        let lane = PeelPeerWriterTurns.next(after: socket.lastWriterLane) { lane in
            switch lane {
            case .frame: sendFrame(socket)
            case .agents: sendAgentState(socket)
            case .usage: sendUsage(socket)
            }
            return socket.sendPending
        }
        if let lane { socket.lastWriterLane = lane }
    }

    private func sendFrame(_ socket: Socket) {
        guard current(socket), !socket.outgoing, socket.phase == .ready, !socket.sendPending,
              configuration.sharesLocalSignal, let peer = socket.peer,
              peerIsTrusted(peer), var frame = latestFrame else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard socket.lastSentFrameUptime == 0 || now - socket.lastSentFrameUptime >= 500_000_000 else { return }
        socket.lastSentFrameUptime = now
        frame.sentAt = .now
        guard let payload = try? JSONEncoder().encode(frame),
              let envelope = try? PeelSignalFrame(payload: payload) else { return }
        send(envelope, socket: socket, isFrame: true)
    }

    /// Owner side: sends a full snapshot when the revision changed, otherwise
    /// a keepalive every five seconds. Never on a socket without `agents.v1`.
    private func sendAgentState(_ socket: Socket) {
        guard current(socket), !socket.outgoing, socket.phase == .ready, !socket.sendPending,
              socket.features.contains(PeelPeerAgentFeature.agents),
              peerAgentConfiguration.sharesAgents, let peer = socket.peer, peerIsTrusted(peer) else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        if socket.sentAgentRevision != owner.revision {
            guard now - socket.lastAgentSendUptime >= Self.agentMinimumGapNanoseconds else { return }
            let snapshot = owner.snapshot(now: .now, pairKey: peer.key)
            if send(snapshot, socket: socket, isFrame: true) {
                socket.sentAgentRevision = snapshot.revision
                socket.lastAgentSendUptime = now
            }
        } else if now - socket.lastAgentSendUptime >= Self.agentKeepaliveNanoseconds {
            if send(PeelPeerAgentKeepalive(bootEpoch: owner.bootEpoch, revision: owner.revision),
                    socket: socket, isFrame: true) {
                socket.lastAgentSendUptime = now
            }
        }
    }

    private func sendUsage(_ socket: Socket) {
        guard current(socket), !socket.outgoing, socket.phase == .ready, !socket.sendPending,
              socket.features.contains(PeelPeerAgentFeature.usage),
              socket.sentAgentRevision != nil || !socket.features.contains(PeelPeerAgentFeature.agents),
              peerAgentConfiguration.sharesUsage, let peer = socket.peer, peerIsTrusted(peer),
              socket.sentUsageRevision != usageRevision else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard socket.sentUsageRevision == nil
                || now - socket.lastUsageSendUptime >= Self.usageMinimumGapNanoseconds else { return }
        let summary = PeelPeerUsageProjection.summary(usageInput, pairKey: peer.key, bootEpoch: owner.bootEpoch,
                                                      revision: usageRevision, now: .now)
        if send(summary, socket: socket, isFrame: true) {
            socket.sentUsageRevision = usageRevision
            socket.lastUsageSendUptime = now
        }
    }

    private func scheduleAgentFlush() {
        guard !agentFlushScheduled else { return }
        agentFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.agentFlushScheduled = false
            for socket in Array(self.sockets.values) where !socket.outgoing { self.pump(socket) }
        }
    }

    private func close(_ socket: Socket, retry: Bool = true) {
        guard current(socket) else { return }
        sockets[socket.id] = nil
        socket.connection.stateUpdateHandler = nil
        socket.connection.cancel()
        if retry, socket.outgoing, let peer = socket.peer {
            retryAfter[peer.hostID] = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        }
        notifyClosed(socket)
        publish()
    }

    private func notifyClosed(_ socket: Socket) {
        guard socket.outgoing, socket.phase == .ready, !socket.features.isEmpty, let peer = socket.peer else { return }
        onPeerAgentEvent?(.socketClosed(hostID: peer.hostID, socketID: socket.id))
    }

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        for socket in Array(sockets.values) {
            if socket.phase != .ready, now - socket.createdAt > 10_000_000_000 { close(socket); continue }
            if socket.outgoing, socket.phase == .ready {
                let last = socket.lastFrameUptime == 0 ? socket.createdAt : socket.lastFrameUptime
                if now - last > 15_000_000_000 { close(socket); continue }
            }
            if !socket.outgoing { pump(socket) }
        }
        connectDesired()
        publishLinks()
    }

    private func scheduleNetworkRetry(_ generation: UUID) {
        let retry: @MainActor () -> Void = { [weak self] in
            guard let self, self.epoch == generation else { return }
            // The diagnostic survives this retry until a real ready transition.
            self.startup.markRetry()
            self.restartNetwork()
        }
#if PEEL_SIGNAL_STARTUP_TESTS
        PeelSignalStartupTestHooks.scheduleRetry(after: 3, retry)
#else
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { retry() }
#endif
    }

    /// Per paired Mac agent-link status for the Host UI. Emitted on change.
    private func publishLinks(forcedStatus: [UUID: PeelPeerLinkStatus] = [:]) {
        var links: [UUID: PeelPeerLinkStatus] = [:]
        var activation: Set<UUID> = []
        for id in keyUnavailableHostIDs { links[id] = .keyUnavailable }
        if peerAgentConfiguration.receivesAgents {
            for peer in trust.values {
                let socket = sockets.values.first { $0.outgoing && $0.peer?.hostID == peer.hostID }
                if let socket, socket.phase == .ready {
                    if !socket.negotiatedV2 {
                        links[peer.hostID] = .legacyPeer
                    } else if socket.features.contains(PeelPeerAgentFeature.agents) {
                        links[peer.hostID] = .live
                        if socket.features.contains(PeelPeerAgentFeature.activate) { activation.insert(peer.hostID) }
                    } else {
                        links[peer.hostID] = .ownerNotSharing
                    }
                } else if let previous = lastLinks[peer.hostID],
                          previous == .legacyPeer || previous == .ownerNotSharing,
                          (retryAfter[peer.hostID] ?? 0) > DispatchTime.now().uptimeNanoseconds {
                    links[peer.hostID] = previous
                } else {
                    links[peer.hostID] = endpoints[peer.hostID] == nil ? .notDiscovered : .connecting
                }
            }
        }
        for (id, status) in forcedStatus { links[id] = status }
        guard links != lastLinks || activation != lastActivationAccepted else { return }
        lastLinks = links
        lastActivationAccepted = activation
        onPeerAgentEvent?(.links(links, activationAccepted: activation))
    }

    private func publish() {
        let (ready, receivers) = publishSnapshot()
        if !configuration.sharesLocalSignal && !configuration.discoversPeers {
            onStatus(peerAgentConfiguration.listens || peerAgentConfiguration.receivesAgents
                ? "Light sharing is off · agent sessions sync with paired Macs"
                : "Paired computer sharing is off")
        } else if trust.isEmpty {
            onStatus("Pair another computer in Peel Pro to share Notch Pulse signals.")
        } else if ready.isEmpty && receivers == 0 {
            onStatus("Looking for paired computers")
        } else {
            onStatus("\(ready.count) paired computer sources · \(receivers) receivers")
        }
        publishLinks()
    }

    /// Snapshot only: no status, link, network or credential side effects.
    @discardableResult
    private func publishSnapshot() -> (ready: Set<String>, receivers: Int) {
        let ready = Set(sockets.values.filter { $0.outgoing && $0.receivedFrame }
            .compactMap { $0.peer?.hostID.uuidString })
        let receivers = sockets.values.filter { !$0.outgoing && $0.phase == .ready }.count
        let gates = NearbySignalStartupGates(listens: listens, browses: browses, usableTrust: !trust.isEmpty,
            keyUnavailable: !keyUnavailableHostIDs.isEmpty, listenerReady: listenerReady,
            browserReady: browserReady)
        startupPublished = true
        onSnapshot(NearbySignalServiceSnapshot(listenerReady: listenerReady, browserReady: browserReady,
            discoveredPeerIDs: Set(endpoints.keys.map(\.uuidString)),
            readyOutboundPeerIDs: ready, inboundReceiverCount: receivers,
            startup: startup.availability(gates)))
        return (ready, receivers)
    }
}

/// Corrupt local identity data never falls back to the old unauthenticated service.
@MainActor
final class PeelUnavailableSignalService: SidePulseSignalServicing {
    let onStatus: @Sendable (String) -> Void
    let onSnapshot: @Sendable (NearbySignalServiceSnapshot) -> Void
    init(onStatus: @escaping @Sendable (String) -> Void,
         onSnapshot: @escaping @Sendable (NearbySignalServiceSnapshot) -> Void = { _ in }) {
        self.onStatus = onStatus
        self.onSnapshot = onSnapshot
    }
    func configure(_ configuration: NearbySignalServiceConfiguration) {
        var snapshot = NearbySignalServiceSnapshot.localOnly
        snapshot.startup = .identityUnavailable
        onSnapshot(snapshot)
        onStatus("Paired computer sharing could not load this Mac's identity.")
    }
    func updateLocalFrame(_ frame: NearbySignalFrame) {}
    func stop() {}
}
