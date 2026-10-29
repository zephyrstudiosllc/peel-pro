//
//  HostNetworkServerDelegate.swift
//  Peel-Host
//
//  Created by Zach on 4/14/26.
//


import Foundation
import Combine
import Network
import AppKit

nonisolated struct PeelControlSession: Hashable, Sendable {
    let pairingID: String
    let generation: UInt64
}

enum HostDiscoveryState: Equatable {
    case disabled
    case starting
    case published
    case failed
    case portUnavailable(UInt16)
}

protocol HostNetworkServerDelegate: AnyObject {
    func hostNetworkServer(_ server: HostNetworkServer, didReceiveLine line: String, generation: UInt64)
    func hostNetworkServer(_ server: HostNetworkServer, didReceiveLine line: String)
    func hostNetworkServerDidConnect(_ server: HostNetworkServer)
    func hostNetworkServerDidDisconnect(_ server: HostNetworkServer)
    func hostNetworkServer(_ server: HostNetworkServer, didUpdateStatus status: String)
    func hostNetworkServer(_ server: HostNetworkServer, didUpdateDiscoveryState state: HostDiscoveryState)
    func hostNetworkServer(
        _ server: HostNetworkServer,
        didOpenVideoStreamForWindow windowId: UInt32,
        capabilities: Set<String>,
        streamRequest: PeelVideoStreamRequest?
    )
    func hostNetworkServer(_ server: HostNetworkServer, didCloseVideoStreamForWindow windowId: UInt32)
    func hostNetworkServer(_ server: HostNetworkServer, audioAttached requestID: String, session: PeelControlSession)
    func hostNetworkServer(_ server: HostNetworkServer, audioClosed requestID: String, session: PeelControlSession)
}

extension HostNetworkServerDelegate {
    func hostNetworkServer(_ server: HostNetworkServer, didUpdateDiscoveryState state: HostDiscoveryState) {}

    func hostNetworkServer(_ server: HostNetworkServer, audioAttached requestID: String, session: PeelControlSession) {}
    func hostNetworkServer(_ server: HostNetworkServer, audioClosed requestID: String, session: PeelControlSession) {}
    func hostNetworkServer(_ server: HostNetworkServer, didReceiveLine line: String, generation: UInt64) {
        hostNetworkServer(server, didReceiveLine: line)
    }

    func hostNetworkServer(
        _ server: HostNetworkServer,
        didOpenVideoStreamForWindow windowId: UInt32,
        capabilities: Set<String>,
        streamRequest: PeelVideoStreamRequest?
    ) {}
    func hostNetworkServer(_ server: HostNetworkServer, didCloseVideoStreamForWindow windowId: UInt32) {}
}

final class HostNetworkServer: NSObject, NetServiceDelegate {
    weak var delegate: HostNetworkServerDelegate?
    weak var streamDiagnostics: StreamDiagnosticsStore?
    let streamingSendDiagnostics = PeelVideoSendDiagnostics()

    let pairingStore: PeelPairingStore
    let hostId: String

    @Published var isDiscoverable: Bool = true
    @Published private(set) var discoveryState: HostDiscoveryState = .disabled
    @Published var lastPairingToken: String?
    @Published var pairingPIN: String = "------"
    @Published var pairingPinExpiresAt: Date = .distantPast
    @Published private(set) var connectedClientPairingID: String?
    private var lastGeneratedTokenPairingID: String?

    private var listener: NWListener?
    private(set) var listeningPort: UInt16?
    var preferredListeningPort: UInt16? {
        PeelDirectConnectionSettings.preferredPort()
    }
    private var netService: NetService?
    private var discoveryGeneration: UInt64 = 0
    private var primaryBonjourGeneration: UInt64?
    private var listenerRepairWorkItem: DispatchWorkItem?
    private var listenerRepairEpoch = UUID()
    private let listenerAdmissionLock = NSLock()
    private var listenerAdmissionEpoch = UUID()
    // Membership metadata only, never keys. Published pairing changes update this
    // synchronously, so revocation and control promotion share one admission lock.
    private var knownControlPairingIDs = Set<String>()
    // Accessed only on connectionQueue; TLS/first-line handshakes are bounded.
    private var pendingConnections: [ObjectIdentifier: (NWConnection, UUID)] = [:]
    private var pairingMaterialRestartWorkItem: DispatchWorkItem?
    private var lastTLSPairingSignature: String = ""
    private let pairingMaterialRestartDelay: TimeInterval = 0.6

    // Active client receive/state is isolated to this queue. Keep video sends off
    // this queue so heavy stream traffic cannot delay incoming mouse/keyboard input.
    private let connectionQueue = DispatchQueue(label: "peel.host.connection", qos: .userInteractive)

    // All outbound writes share this queue to preserve mux ordering between JSON
    // lines and binary video packets, while still protecting connectionQueue.
    private let outboundSendQueue = DispatchQueue(label: "peel.host.outboundSend", qos: .userInitiated)

    private(set) var audioChannel: PeelHostAudioChannel!

    private var connection: NWConnection?
    private var receiveBuffer = Data()

    private var videoConnectionsByWindowId: [UInt32: NWConnection] = [:]

    private typealias SendSnapshot = (connection: NWConnection, generation: UInt64)
    private typealias VideoSendSnapshot = (windowId: UInt32, connection: NWConnection, generation: UInt64)
    private let sendStateLock = NSLock()
    private var sendConnection: NWConnection?
    private var sendGeneration: UInt64 = 0
    private var claimedSendPairingID: String?
    private var videoSendConnectionsByWindowId: [UInt32: NWConnection] = [:]
    private var videoSendGenerationsByWindowId: [UInt32: UInt64] = [:]
    private var nextVideoSendGeneration: UInt64 = 1

    // Backpressure is intentionally byte-based, not frame-count-based.
    // Keep this very small for interactive streaming: queued video should be dropped,
    // not faithfully delivered late. Hysteresis prevents rapid admit/drop oscillation.
    private let maxOutstandingVideoBytes = 120_000
    private let resumeOutstandingVideoBytes = 40_000
    private var outstandingVideoBytes = 0
    private var videoBackpressureActive = false
    private var outstandingVideoBytesByWindowId: [UInt32: Int] = [:]
    private var videoBackpressureActiveByWindowId: [UInt32: Bool] = [:]
    private var videoBytesSentInCurrentSecond = 0
    private var lastNetworkDiagnosticsFlushAt = CFAbsoluteTimeGetCurrent()

    private var pairingListener: NWListener?
    private var pairingNetService: NetService?
    private var pairingListenerPort: UInt16?
    private var pairingSalt: Data = Data()
    private let pairingPinTTL: TimeInterval = 10 * 60
    private var pairingPinTimer: Timer?
    private var pairingCancellable: AnyCancellable?

    init(pairingStore: PeelPairingStore, hostId: String, observesPairing: Bool = true) {
        self.pairingStore = pairingStore
        self.hostId = hostId
        super.init()
        knownControlPairingIDs = Set(pairingStore.paired.map(\.id))
        audioChannel = PeelHostAudioChannel(queue: outboundSendQueue,
            isCurrent: { [weak self] in self?.isCurrentControlSession($0) == true },
            onAttached: { [weak self] requestID, session in
                guard let self else { return }
                self.delegate?.hostNetworkServer(self, audioAttached: requestID, session: session)
            }, onClosed: { [weak self] requestID, session in
                guard let self else { return }
                self.delegate?.hostNetworkServer(self, audioClosed: requestID, session: session)
            })

        pairingCancellable = pairingStore.$paired
            .handleEvents(receiveOutput: { [weak self] peers in
                self?.updateControlAdmissionPairingIDs(Set(peers.map(\.id)))
            })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard observesPairing else { return }
                self?.scheduleListenerRefreshIfPairingMaterialChanged(reason: "pairing material changed")
            }
    }

    func start() {
        refreshPairingPIN()
        applyDiscoverabilityPolicy()
    }

    func stop() {
        isDiscoverable = false
        applyDiscoverabilityPolicy()
    }

    func setDiscoverable(_ discoverable: Bool) {
        isDiscoverable = discoverable
        applyDiscoverabilityPolicy()
    }

    private func updateDiscoveryState(_ state: HostDiscoveryState) {
        guard discoveryState != state else { return }
        discoveryState = state
        delegate?.hostNetworkServer(self, didUpdateDiscoveryState: state)
    }

    private var discoveryStateIsFailure: Bool {
        switch discoveryState {
        case .failed, .portUnavailable:
            return true
        case .disabled, .starting, .published:
            return false
        }
    }

    private func invalidatePrimaryBonjour() {
        discoveryGeneration &+= 1
        primaryBonjourGeneration = nil
        netService?.delegate = nil
        netService?.stop()
        netService = nil
    }

    private func beginPrimaryBonjour() {
        discoveryGeneration &+= 1
        primaryBonjourGeneration = discoveryGeneration
    }

    private func isCurrentPrimaryBonjour(_ sender: NetService) -> Bool {
        sender === netService && primaryBonjourGeneration == discoveryGeneration
    }

    func refreshAdvertising(reason: String) {
        guard isDiscoverable else { return }
        delegate?.hostNetworkServer(self, didUpdateStatus: "Refreshing host advertising (\(reason))…")
        repairListenerAndAdvertising(reason: reason)
    }

    /// A local, explicit settings action. Keep the configured port exact; an
    /// occupied fixed port must not silently become another saved destination.
    func setPreferredListeningPort(_ port: UInt16?) {
        guard !ProcessInfo.processInfo.arguments.contains("--peel-preview") else { return }
        // Invalidate admission before enqueueing active-session cleanup. This
        // orders any already-claimed promotion before that cleanup as well.
        invalidatePendingConnections()
        PeelDirectConnectionSettings.setPreferredPort(port)
        disconnectCurrentClient(reason: "direct connection port changed")
        repairListenerAndAdvertising(reason: "direct connection port changed")
        if !isDiscoverable {
            delegate?.hostNetworkServer(self, didUpdateStatus: "Port saved. Enable discovery to accept connections.")
        }
    }

    func disconnectCurrentClient(reason: String) {
        cleanupConnection(
            cancelConnection: true,
            statusMessage: "Client disconnected (\(reason))"
        )
    }

    @discardableResult
    func generatePairingToken(clientLabel: String = "New Client") -> String {
        let fallbackHostName = Host.current().localizedName ?? "Mac"
        let serviceName = netService?.name ?? "Peel on \(fallbackHostName)"
        let hostDisplayName = fallbackHostName

        if let stalePairingID = lastGeneratedTokenPairingID {
            let stalePeer = pairingStore.paired.first { $0.id == stalePairingID }
            let wasUnclaimedDebugToken = stalePeer?.serviceName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true

            if wasUnclaimedDebugToken {
                pairingStore.removePeer(pairingID: stalePairingID)
            }

            lastGeneratedTokenPairingID = nil
        }

        let psk = PeelPairingStore.generatePSK()
        let pairingID = UUID().uuidString
        lastGeneratedTokenPairingID = pairingID

        _ = pairingStore.addPeer(
            displayName: clientLabel,
            serviceName: nil,
            pairingID: pairingID,
            psk: psk
        )

        scheduleListenerRefreshIfPairingMaterialChanged(reason: "pairing token generated")

        let invite = PeelPairingInvitation(
            serviceName: serviceName,
            pairingID: pairingID,
            psk: psk,
            hostDisplayName: hostDisplayName,
            hostId: hostId
        )

        let token = invite.encodedToken()
        lastPairingToken = token
        return token
    }

    func sendJSONLine<T: Encodable>(_ value: T, generation: UInt64? = nil) {
        do {
            let data = try JSONEncoder().encode(value)
            if let jsonString = String(data: data, encoding: .utf8) {
                sendLine(jsonString, generation: generation)
            }
        } catch {
            print("PeelHost: encode failed:", error)
        }
    }

    func controlSession(pairingID: String) -> PeelControlSession? {
        sendStateLock.lock()
        defer { sendStateLock.unlock() }
        guard sendConnection != nil, claimedSendPairingID == pairingID else { return nil }
        return PeelControlSession(pairingID: pairingID, generation: sendGeneration)
    }

    func isCurrentControlGeneration(_ generation: UInt64) -> Bool {
        currentSendSnapshot()?.generation == generation
    }

    func isCurrentControlSession(_ session: PeelControlSession) -> Bool {
        targetSendSnapshot(session) != nil
    }

    private func targetSendSnapshot(_ session: PeelControlSession) -> SendSnapshot? {
        sendStateLock.lock()
        defer { sendStateLock.unlock() }
        guard let sendConnection, sendGeneration == session.generation,
              claimedSendPairingID == session.pairingID else { return nil }
        return (sendConnection, sendGeneration)
    }

    /// New agent actions always retain their intended socket and pairing generation.
    /// They must never resolve an old request against a replacement connection.
    func sendTargetedJSONLine<T: Encodable>(
        _ value: T,
        session: PeelControlSession,
        deadlineUptimeNanoseconds: UInt64? = nil,
        authorization: (@Sendable (_ submit: () -> Void) -> Bool)? = nil,
        completion: @escaping (Bool) -> Void
    ) {
        let deadlineIsValid = deadlineUptimeNanoseconds.map {
            DispatchTime.now().uptimeNanoseconds < $0
        } ?? true
        guard deadlineIsValid,
              var data = try? JSONEncoder().encode(value), data.count < 256 * 1024,
              let snapshot = targetSendSnapshot(session) else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        data.append(0x0A)
        let payload = data
        outboundSendQueue.async { [weak self] in
            let deadlineIsStillValid = deadlineUptimeNanoseconds.map {
                DispatchTime.now().uptimeNanoseconds < $0
            } ?? true
            guard deadlineIsStillValid,
                  let self, self.isCurrentSendSnapshot(snapshot),
                  self.isCurrentControlSession(session) else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            // The optional paid permit holds its lock through only this
            // immediate enqueue. Completion never runs while that lock is held.
            let submit = {
                snapshot.connection.send(content: payload, completion: .contentProcessed { error in
                    let completedBeforeDeadline = deadlineUptimeNanoseconds.map {
                        DispatchTime.now().uptimeNanoseconds < $0
                    } ?? true
                    DispatchQueue.main.async {
                        completion(error == nil && completedBeforeDeadline)
                    }
                })
            }
            if let authorization {
                guard authorization(submit) else {
                    DispatchQueue.main.async { completion(false) }
                    return
                }
            } else {
                submit()
            }
        }
    }

    func sendJSONLineThenDisconnect<T: Encodable>(_ value: T, reason: String, delay: TimeInterval = 0.15) {
        sendJSONLine(value)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.disconnectCurrentClient(reason: reason)
        }
    }

    func sendLine(_ line: String, generation: UInt64? = nil) {
        guard let data = (line + "\n").data(using: .utf8),
              let snapshot = currentSendSnapshot(),
              generation == nil || snapshot.generation == generation else { return }

        outboundSendQueue.async { [weak self] in
            guard let self else { return }
            guard self.isCurrentSendSnapshot(snapshot) else { return }

            snapshot.connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    print("PeelHost: sendLine error:", error.localizedDescription)
                }
            })
        }
    }

    /// Returns false when the host already has too much compressed video queued or in flight.
    /// WindowStreamer uses this to drop raw ScreenCaptureKit frames before VideoToolbox work.
    func canAcceptVideoFrame() -> Bool {
        guard currentSendSnapshot() != nil else { return false }

        return outboundSendQueue.sync {
            refreshVideoBackpressureState_locked()
            return !videoBackpressureActive
        }
    }

    /// v2 transport: returns false when this specific window already has too much compressed video queued or in flight.
    func canAcceptVideoFrame(windowId: UInt32) -> Bool {
        guard currentVideoSendSnapshot(windowId: windowId) != nil else { return false }

        return outboundSendQueue.sync {
            refreshVideoBackpressureState_locked(windowId: windowId)
            return !(videoBackpressureActiveByWindowId[windowId] ?? false)
        }
    }

    /// Returns true when the per-window video transport exists, regardless of backpressure.
    /// Use this for post-encode delivery checks so encoded H.264 access units are not
    /// dropped just because the send queue is temporarily backed up.
    func hasVideoTransport(windowId: UInt32) -> Bool {
        currentVideoSendSnapshot(windowId: windowId) != nil
    }

    func sendBinaryPacket(_ data: Data) {
        guard !data.isEmpty,
              let snapshot = currentSendSnapshot(),
              reserveVideoBytesForSend(data.count, generation: snapshot.generation) else { return }

        outboundSendQueue.async { [weak self] in
            guard let self else { return }

            guard self.isCurrentSendSnapshot(snapshot) else {
                self.finishVideoBytesForSend(data.count, generation: snapshot.generation)
                return
            }

            self.videoBytesSentInCurrentSecond += data.count
            self.publishNetworkDiagnostics_locked()

            snapshot.connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error {
                    print("PeelHost: legacy video send error:", error.localizedDescription)
                }

                self?.finishVideoBytesForSend(data.count, generation: snapshot.generation)
            })
        }
    }

    /// v2 transport: sends compressed video only on the per-window video socket.
    func sendVideoPacket(windowId: UInt32, _ data: Data) {
        let sendStartedAt = ProcessInfo.processInfo.systemUptime
        guard !data.isEmpty,
              let snapshot = currentVideoSendSnapshot(windowId: windowId),
              reserveVideoBytesForSend(data.count, windowId: windowId, generation: snapshot.generation) else { return }

        streamingSendDiagnostics.enqueued(windowID: windowId, generation: snapshot.generation, bytes: data.count)

        outboundSendQueue.async { [weak self] in
            guard let self else { return }

            guard self.isCurrentVideoSendSnapshot(snapshot) else {
                self.finishVideoBytesForSend(data.count, windowId: windowId, generation: snapshot.generation)
                return
            }

            self.videoBytesSentInCurrentSecond += data.count
            self.publishNetworkDiagnostics_locked()

            snapshot.connection.send(content: data, completion: .contentProcessed { [weak self] error in
                self?.streamingSendDiagnostics.completed(windowID: windowId, generation: snapshot.generation,
                    bytes: data.count, startedAt: sendStartedAt, failed: error != nil)
                if let error {
                    print("PeelHost: video send error window=\(windowId):", error.localizedDescription)
                }

                self?.finishVideoBytesForSend(data.count, windowId: windowId, generation: snapshot.generation)
            })
        }
    }

    private func currentSendSnapshot() -> SendSnapshot? {
        sendStateLock.lock()
        defer { sendStateLock.unlock() }

        guard let sendConnection else { return nil }
        return (sendConnection, sendGeneration)
    }

    private func currentVideoSendSnapshot(windowId: UInt32) -> VideoSendSnapshot? {
        sendStateLock.lock()
        defer { sendStateLock.unlock() }

        guard let connection = videoSendConnectionsByWindowId[windowId],
              let generation = videoSendGenerationsByWindowId[windowId] else { return nil }
        return (windowId, connection, generation)
    }

    private func isCurrentSendSnapshot(_ snapshot: SendSnapshot) -> Bool {
        sendStateLock.lock()
        defer { sendStateLock.unlock() }

        return sendConnection === snapshot.connection && sendGeneration == snapshot.generation
    }

    private func isCurrentVideoSendSnapshot(_ snapshot: VideoSendSnapshot) -> Bool {
        sendStateLock.lock()
        defer { sendStateLock.unlock() }

        return videoSendConnectionsByWindowId[snapshot.windowId] === snapshot.connection &&
            videoSendGenerationsByWindowId[snapshot.windowId] == snapshot.generation
    }

    private func isCurrentSendGeneration(_ generation: UInt64) -> Bool {
        sendStateLock.lock()
        defer { sendStateLock.unlock() }

        return sendGeneration == generation
    }

    private func currentControlAdmissionGeneration() -> UInt64 {
        sendStateLock.lock()
        defer { sendStateLock.unlock() }
        return sendGeneration
    }

    /// connection is owned by connectionQueue, which also owns this decision.
    /// Permit an old socket's normal cleanup to finish during a reconnect, while
    /// never allowing a buffered candidate to replace a different live owner.
    private func isCurrentOrIdleControlAdmission(_ expectedGeneration: UInt64) -> Bool {
        sendStateLock.lock()
        defer { sendStateLock.unlock() }
        return sendGeneration == expectedGeneration || (connection == nil && sendConnection == nil)
    }

    private func isCurrentVideoSendGeneration(_ generation: UInt64, windowId: UInt32) -> Bool {
        sendStateLock.lock()
        defer { sendStateLock.unlock() }

        return videoSendGenerationsByWindowId[windowId] == generation
    }

    private func setActiveSendConnection(_ newConnection: NWConnection?) {
        streamingSendDiagnostics.reset()
        sendStateLock.lock()
        sendConnection = newConnection
        claimedSendPairingID = nil
        sendGeneration &+= 1
        sendStateLock.unlock()
        audioChannel.invalidate()

        outboundSendQueue.async { [weak self] in
            guard let self else { return }
            self.outstandingVideoBytes = 0
            self.videoBackpressureActive = false
            if newConnection == nil {
                self.outstandingVideoBytesByWindowId.removeAll()
                self.videoBackpressureActiveByWindowId.removeAll()
            }
            self.videoBytesSentInCurrentSecond = 0
            self.lastNetworkDiagnosticsFlushAt = CFAbsoluteTimeGetCurrent()
            self.publishNetworkDiagnostics_locked()
        }
    }

    private func setActiveVideoSendConnection(_ newConnection: NWConnection?, windowId: UInt32) {
        sendStateLock.lock()
        let priorGeneration = videoSendGenerationsByWindowId[windowId]
        if let newConnection {
            videoSendConnectionsByWindowId[windowId] = newConnection
            videoSendGenerationsByWindowId[windowId] = nextVideoSendGeneration
            nextVideoSendGeneration &+= 1
        } else {
            videoSendConnectionsByWindowId.removeValue(forKey: windowId)
            videoSendGenerationsByWindowId.removeValue(forKey: windowId)
        }
        let diagnosticGeneration = videoSendGenerationsByWindowId[windowId]
        sendStateLock.unlock()
        if let diagnosticGeneration {
            streamingSendDiagnostics.begin(windowID: windowId, generation: diagnosticGeneration)
        } else if let priorGeneration {
            streamingSendDiagnostics.end(windowID: windowId, generation: priorGeneration)
        }

        outboundSendQueue.async { [weak self] in
            guard let self else { return }
            self.outstandingVideoBytesByWindowId[windowId] = 0
            self.videoBackpressureActiveByWindowId[windowId] = false
            self.publishNetworkDiagnostics_locked()
        }
    }

    private func reserveVideoBytesForSend(_ byteCount: Int, generation: UInt64) -> Bool {
        outboundSendQueue.sync {
            guard isCurrentSendGeneration(generation) else { return false }

            outstandingVideoBytes += byteCount
            refreshVideoBackpressureState_locked()
            publishNetworkDiagnostics_locked()
            return true
        }
    }

    private func reserveVideoBytesForSend(_ byteCount: Int, windowId: UInt32, generation: UInt64) -> Bool {
        outboundSendQueue.sync {
            guard isCurrentVideoSendGeneration(generation, windowId: windowId) else { return false }

            outstandingVideoBytesByWindowId[windowId, default: 0] += byteCount
            refreshVideoBackpressureState_locked(windowId: windowId)
            streamingSendDiagnostics.queue(windowID: windowId, generation: generation,
                outstandingBytes: outstandingVideoBytesByWindowId[windowId] ?? 0,
                backpressure: videoBackpressureActiveByWindowId[windowId] ?? false)
            publishNetworkDiagnostics_locked()
            return true
        }
    }

    private func finishVideoBytesForSend(_ byteCount: Int, generation: UInt64) {
        outboundSendQueue.async { [weak self] in
            guard let self else { return }
            guard self.isCurrentSendGeneration(generation) else { return }

            self.outstandingVideoBytes = max(0, self.outstandingVideoBytes - byteCount)
            self.refreshVideoBackpressureState_locked()
        }
    }

    private func finishVideoBytesForSend(_ byteCount: Int, windowId: UInt32, generation: UInt64) {
        outboundSendQueue.async { [weak self] in
            guard let self else { return }
            guard self.isCurrentVideoSendGeneration(generation, windowId: windowId) else { return }

            let current = self.outstandingVideoBytesByWindowId[windowId] ?? 0
            self.outstandingVideoBytesByWindowId[windowId] = max(0, current - byteCount)
            self.refreshVideoBackpressureState_locked(windowId: windowId)
            self.streamingSendDiagnostics.queue(windowID: windowId, generation: generation,
                outstandingBytes: self.outstandingVideoBytesByWindowId[windowId] ?? 0,
                backpressure: self.videoBackpressureActiveByWindowId[windowId] ?? false)
        }
    }

    private func publishNetworkDiagnostics_locked() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastNetworkDiagnosticsFlushAt >= 1.0 else { return }

        let elapsed = max(0.001, now - lastNetworkDiagnosticsFlushAt)
        let mbps = (Double(videoBytesSentInCurrentSecond) * 8.0) / elapsed / 1_000_000.0
        let outstanding = outstandingVideoBytes + outstandingVideoBytesByWindowId.values.reduce(0, +)

        videoBytesSentInCurrentSecond = 0
        lastNetworkDiagnosticsFlushAt = now

        let diagnostics = streamDiagnostics
        Task { @MainActor in
            diagnostics?.estimatedVideoMbps = mbps
            diagnostics?.outstandingVideoBytes = outstanding
        }
    }

    private func refreshVideoBackpressureState_locked() {
        if videoBackpressureActive {
            if outstandingVideoBytes <= resumeOutstandingVideoBytes {
                videoBackpressureActive = false
            }
        } else if outstandingVideoBytes >= maxOutstandingVideoBytes {
            videoBackpressureActive = true
        }
    }

    private func refreshVideoBackpressureState_locked(windowId: UInt32) {
        let outstanding = outstandingVideoBytesByWindowId[windowId] ?? 0
        let isActive = videoBackpressureActiveByWindowId[windowId] ?? false

        if isActive {
            if outstanding <= resumeOutstandingVideoBytes {
                videoBackpressureActiveByWindowId[windowId] = false
            }
        } else if outstanding >= maxOutstandingVideoBytes {
            videoBackpressureActiveByWindowId[windowId] = true
        }
    }

    private func applyDiscoverabilityPolicy() {
        if isDiscoverable {
            if !discoveryStateIsFailure {
                updateDiscoveryState(.starting)
            }
            startListener()
            lastTLSPairingSignature = tlsPairingSignature()
            startPairingListener()

            if let port = listener?.port?.rawValue, netService == nil {
                startBonjour(port: Int32(port))
            } else if listener == nil {
                scheduleListenerRepair(reason: "discoverability enabled", delay: 0.25)
            }
            return
        }

        listenerRepairEpoch = UUID()
        listenerRepairWorkItem?.cancel()
        listenerRepairWorkItem = nil

        pairingMaterialRestartWorkItem?.cancel()
        pairingMaterialRestartWorkItem = nil
        lastTLSPairingSignature = ""

        invalidatePrimaryBonjour()
        updateDiscoveryState(.disabled)

        pairingNetService?.stop()
        pairingNetService = nil
        pairingListener?.cancel()
        pairingListener = nil
        pairingListenerPort = nil

        invalidatePendingConnections()
        cleanupConnection(cancelConnection: true)

        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        listeningPort = nil

        delegate?.hostNetworkServer(self, didUpdateStatus: "Not discoverable")
    }

    private func tlsPairingSignature() -> String {
        pairingStore.paired
            .filter { pairingStore.psk(for: $0.id)?.isEmpty == false }
            .map(\.id)
            .sorted()
            .joined(separator: "|")
    }

    private func scheduleListenerRefreshIfPairingMaterialChanged(reason: String) {
        guard isDiscoverable else { return }

        let newSignature = tlsPairingSignature()
        guard newSignature != lastTLSPairingSignature else { return }
        lastTLSPairingSignature = newSignature

        pairingMaterialRestartWorkItem?.cancel()

        let work = DispatchWorkItem { [weak self] in
            self?.pairingMaterialRestartWorkItem = nil
            self?.repairListenerAndAdvertising(reason: reason)
        }

        pairingMaterialRestartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + pairingMaterialRestartDelay, execute: work)
    }

    private func startListener() {
        guard isDiscoverable else {
            delegate?.hostNetworkServer(self, didUpdateStatus: "Not discoverable")
            return
        }
        guard listener == nil else { return }

        let params: NWParameters = PeelTLS.makeHostParameters(
            pairedPeers: pairingStore.paired,
            keyProvider: { [weak self] pairingID in
                self?.pairingStore.psk(for: pairingID)
            }
        )

        do {
            let requestedPort = preferredListeningPort.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any
            let listener = try NWListener(using: params, on: requestedPort)
            self.listener = listener
            let admissionEpoch = currentListenerAdmissionEpoch()

            listener.stateUpdateHandler = { [weak self, weak listener] state in
                DispatchQueue.main.async {
                    guard let self, let listener, self.listener === listener,
                          self.currentListenerAdmissionEpoch() == admissionEpoch else { return }
                    self.handleListenerStateUpdate(state)
                }
            }

            listener.newConnectionHandler = { [weak self, weak listener] newConnection in
                guard let self, let listener, self.listener === listener,
                      self.currentListenerAdmissionEpoch() == admissionEpoch else {
                    newConnection.cancel()
                    return
                }
                self.accept(newConnection: newConnection)
            }

            listener.start(queue: .main)
            delegate?.hostNetworkServer(self, didUpdateStatus: "Starting listener…")
        } catch {
            if handleUnavailableFixedPort(error) { return }
            delegate?.hostNetworkServer(self, didUpdateStatus: "Failed to start listener: \(error.localizedDescription)")
            scheduleListenerRepair(reason: "listener start failed", delay: 1.0)
        }
    }
    private func scheduleListenerRepair(reason: String, delay: TimeInterval = 1.0) {
        guard isDiscoverable else { return }

        listenerRepairEpoch = UUID()
        listenerRepairWorkItem?.cancel()
        let generation = listenerRepairEpoch
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.listenerRepairEpoch == generation, self.isDiscoverable else { return }
            self.repairListenerAndAdvertising(reason: reason)
        }
        listenerRepairWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func repairListenerAndAdvertising(reason: String) {
        guard isDiscoverable else { return }

        listenerRepairEpoch = UUID()
        listenerRepairWorkItem?.cancel()
        listenerRepairWorkItem = nil
        let generation = listenerRepairEpoch

        delegate?.hostNetworkServer(self, didUpdateStatus: "Repairing listener/Bonjour (\(reason))…")
        if !discoveryStateIsFailure {
            updateDiscoveryState(.starting)
        }
        invalidatePrimaryBonjour()
        invalidatePendingConnections()
        listeningPort = nil

        guard let previous = listener else { startListener(); return }
        previous.newConnectionHandler = nil
        // Cancellation is asynchronous. Keep the old listener alive until it
        // releases the fixed port, then bind the replacement exactly once.
        previous.stateUpdateHandler = { [weak self, weak previous] state in
            guard case .cancelled = state else { return }
            DispatchQueue.main.async {
                guard let self, let previous, self.listener === previous,
                      self.listenerRepairEpoch == generation else { return }
                self.listener = nil
                if self.isDiscoverable { self.startListener() }
            }
        }
        if case .cancelled = previous.state {
            listener = nil
            startListener()
        } else {
            previous.cancel()
        }
    }

    private func handleUnavailableFixedPort(_ error: Error) -> Bool {
        guard let port = preferredListeningPort,
              let networkError = error as? NWError,
              case .posix(let code) = networkError,
              code == .EADDRINUSE || code == .EACCES else { return false }
        listenerRepairEpoch = UUID()
        listenerRepairWorkItem?.cancel()
        listenerRepairWorkItem = nil
        invalidatePendingConnections()
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        listeningPort = nil
        invalidatePrimaryBonjour()
        updateDiscoveryState(.portUnavailable(port))
        delegate?.hostNetworkServer(self, didUpdateStatus:
            "Port \(port) is unavailable. Choose another port in Direct Connections and apply it.")
        return true
    }

    private func handleListenerStateUpdate(_ state: NWListener.State) {
        switch state {
        case .setup:
            if !discoveryStateIsFailure {
                updateDiscoveryState(.starting)
            }
            delegate?.hostNetworkServer(self, didUpdateStatus: "Setting up…")
        case .waiting(let error):
            listeningPort = nil
            if handleUnavailableFixedPort(error) { return }
            invalidatePrimaryBonjour()
            updateDiscoveryState(.failed)
            delegate?.hostNetworkServer(self, didUpdateStatus: "Waiting: \(error.localizedDescription)")
            scheduleListenerRepair(reason: "listener waiting: \(error.localizedDescription)", delay: 2.0)
        case .ready:
            listenerRepairEpoch = UUID()
            listenerRepairWorkItem?.cancel()
            listenerRepairWorkItem = nil
            if let port = listener?.port?.rawValue {
                listeningPort = port
                if !discoveryStateIsFailure {
                    updateDiscoveryState(.starting)
                }
                let pairedCount = pairingStore.paired.count
                if pairedCount == 0 {
                    delegate?.hostNetworkServer(self, didUpdateStatus: "Listening on port \(port) (TLS enabled; 0 paired clients — connections will be rejected until paired)")
                } else {
                    delegate?.hostNetworkServer(self, didUpdateStatus: "Listening on port \(port) (TLS enabled; \(pairedCount) paired client\(pairedCount == 1 ? "" : "s"))")
                }

                if isDiscoverable {
                    startBonjour(port: Int32(port))
                }
            } else {
                delegate?.hostNetworkServer(self, didUpdateStatus: "Listener ready (unknown port)")
            }
        case .failed(let error):
            listeningPort = nil
            if handleUnavailableFixedPort(error) { return }
            invalidatePrimaryBonjour()
            updateDiscoveryState(.failed)
            delegate?.hostNetworkServer(self, didUpdateStatus: "Listener failed: \(error.localizedDescription)")
            cleanupConnection()
            scheduleListenerRepair(reason: "listener failed: \(error.localizedDescription)", delay: 0.25)
        case .cancelled:
            listeningPort = nil
            if isDiscoverable {
                invalidatePrimaryBonjour()
                updateDiscoveryState(.failed)
            }
            delegate?.hostNetworkServer(self, didUpdateStatus: "Listener cancelled")
            cleanupConnection()
            if isDiscoverable {
                scheduleListenerRepair(reason: "listener cancelled while discoverable", delay: 0.5)
            }
        @unknown default:
            invalidatePrimaryBonjour()
            updateDiscoveryState(.failed)
            delegate?.hostNetworkServer(self, didUpdateStatus: "Unknown listener state")
        }
    }

    private func startBonjour(port: Int32) {
        guard isDiscoverable else { return }

        invalidatePrimaryBonjour()
        if !discoveryStateIsFailure {
            updateDiscoveryState(.starting)
        }

        let hostName = Host.current().localizedName ?? "Mac"
        let service = NetService(
            domain: "local.",
            type: "_peel._tcp.",
            name: "Peel on \(hostName)",
            port: port
        )
        service.delegate = self

        var txt: [String: Data] = [:]
        txt["hostId"] = hostId.data(using: .utf8)
        txt["hostName"] = hostName.data(using: .utf8)
        txt[PeelTLS.pskOrderTXTKey] = Data(PeelTLS.standardPSKOrderTXTValue.utf8)
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        beginPrimaryBonjour()
        netService = service
        service.publish()

        delegate?.hostNetworkServer(self, didUpdateStatus: "Advertising as “Peel on \(hostName)” on port \(port)")
        updateBonjourTXTRecords()
    }

    private func currentListenerAdmissionEpoch() -> UUID {
        listenerAdmissionLock.lock()
        defer { listenerAdmissionLock.unlock() }
        return listenerAdmissionEpoch
    }

    private func updateControlAdmissionPairingIDs(_ pairingIDs: Set<String>) {
        listenerAdmissionLock.lock()
        knownControlPairingIDs = pairingIDs
        listenerAdmissionLock.unlock()
    }

    private func invalidatePendingConnections() {
        listenerAdmissionLock.lock()
        listenerAdmissionEpoch = UUID()
        listenerAdmissionLock.unlock()
        connectionQueue.async { [weak self] in
            guard let self else { return }
            for (connection, _) in self.pendingConnections.values {
                connection.stateUpdateHandler = nil
                connection.cancel()
            }
            self.pendingConnections.removeAll()
        }
    }

    private func isCurrentPendingConnection(_ connection: NWConnection) -> Bool {
        guard let entry = pendingConnections[ObjectIdentifier(connection)], entry.0 === connection else { return false }
        return entry.1 == currentListenerAdmissionEpoch()
    }

    /// The epoch check and promotion form one admission decision. Listener
    /// invalidation cannot slip between them and lose a just-promoted socket.
    /// None of the promotion actions synchronously waits for the main thread
    /// that owns listener teardown.
    private func claimPendingConnection(_ connection: NWConnection, promote: () -> Void) -> Bool {
        listenerAdmissionLock.lock()
        defer { listenerAdmissionLock.unlock() }
        let id = ObjectIdentifier(connection)
        guard let entry = pendingConnections[id], entry.0 === connection,
              entry.1 == listenerAdmissionEpoch else { return false }
        pendingConnections.removeValue(forKey: id)
        promote()
        return true
    }

    private enum ControlCandidateClaim {
        case admitted
        case stale
        case unknownPairing
    }

    /// Typed Hello validation precedes this call. Recheck trust metadata, listener
    /// epoch and the incumbent generation atomically with the actual promotion.
    /// A slow candidate must not replace a control admitted while it was buffering.
    private func claimPendingControlConnection(_ candidate: NWConnection, pairingID: String,
                                               expectedGeneration: UInt64, promote: () -> Void) -> ControlCandidateClaim {
        listenerAdmissionLock.lock()
        defer { listenerAdmissionLock.unlock() }
        let id = ObjectIdentifier(candidate)
        guard let entry = pendingConnections[id], entry.0 === candidate,
              entry.1 == listenerAdmissionEpoch,
              isCurrentOrIdleControlAdmission(expectedGeneration) else { return .stale }
        guard knownControlPairingIDs.contains(pairingID) else { return .unknownPairing }
        pendingConnections.removeValue(forKey: id)
        promote()
        return .admitted
    }

    private func rejectPendingConnection(_ connection: NWConnection) {
        pendingConnections.removeValue(forKey: ObjectIdentifier(connection))
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func accept(newConnection: NWConnection) {
        guard isDiscoverable else {
            newConnection.cancel()
            return
        }

        let activeConn = newConnection
        let endpointDesc = newConnection.endpoint.debugDescription
        let generation = currentListenerAdmissionEpoch()

        connectionQueue.async { [weak self, activeConn] in
            guard let self else { activeConn.cancel(); return }
            guard self.currentListenerAdmissionEpoch() == generation,
                  self.pendingConnections.count < 32 else { activeConn.cancel(); return }
            self.pendingConnections[ObjectIdentifier(activeConn)] = (activeConn, generation)
            self.connectionQueue.asyncAfter(deadline: .now() + 10) { [weak self, weak activeConn] in
                guard let self, let activeConn,
                      self.pendingConnections[ObjectIdentifier(activeConn)]?.0 === activeConn else { return }
                self.rejectPendingConnection(activeConn)
            }

            activeConn.stateUpdateHandler = { [weak self, weak activeConn] newState in
                guard let self, let activeConn else { return }
                self.connectionQueue.async { [weak self, weak activeConn] in
                    guard let self, let activeConn else { return }
                    self.handleUnclassifiedConnectionStateUpdate(newState, for: activeConn, endpointDesc: endpointDesc)
                }
            }

            activeConn.start(queue: self.connectionQueue)
        }
    }

    private func handleUnclassifiedConnectionStateUpdate(_ newState: NWConnection.State, for activeConn: NWConnection, endpointDesc: String) {
        // A callback queued before promotion must not cancel a promoted socket.
        guard pendingConnections[ObjectIdentifier(activeConn)] != nil else { return }
        guard isCurrentPendingConnection(activeConn) else { rejectPendingConnection(activeConn); return }
        switch newState {
        case .ready:
            startConnectionClassification(for: activeConn, endpointDesc: endpointDesc, buffer: Data(),
                                          expectedControlGeneration: currentControlAdmissionGeneration())
        case .failed(let error):
            print("PeelHost: unclassified connection failed:", error.localizedDescription)
            rejectPendingConnection(activeConn)
        case .cancelled:
            rejectPendingConnection(activeConn)
        default:
            break
        }
    }

    private struct InitialSocketMessageType: Decodable {
        let type: String?
    }

    private func startConnectionClassification(for activeConn: NWConnection, endpointDesc: String, buffer: Data,
                                               expectedControlGeneration: UInt64) {
        guard isCurrentPendingConnection(activeConn) else { rejectPendingConnection(activeConn); return }
        activeConn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self, weak activeConn] data, _, isComplete, error in
            guard let self, let activeConn else { return }

            self.connectionQueue.async { [weak self, weak activeConn] in
                guard let self, let activeConn else { return }
                guard self.isCurrentPendingConnection(activeConn) else {
                    self.rejectPendingConnection(activeConn)
                    return
                }

                if let error {
                    print("PeelHost: classify receive error:", error.localizedDescription)
                    self.rejectPendingConnection(activeConn)
                    return
                }

                var nextBuffer = buffer
                if let data, !data.isEmpty {
                    nextBuffer.append(data)
                }

                guard let newlineRange = nextBuffer.firstRange(of: Data([0x0A])) else {
                    if nextBuffer.count > 16 * 1024 || isComplete {
                        print("PeelHost: classify failed before first line, bytes=\(nextBuffer.count)")
                        self.rejectPendingConnection(activeConn)
                        return
                    }

                    self.startConnectionClassification(for: activeConn, endpointDesc: endpointDesc, buffer: nextBuffer,
                                                       expectedControlGeneration: expectedControlGeneration)
                    return
                }

                let firstLineData = nextBuffer.subdata(in: 0..<newlineRange.lowerBound)
                let trailingData = nextBuffer.subdata(in: newlineRange.upperBound..<nextBuffer.endIndex)

                guard !firstLineData.isEmpty, firstLineData.count <= 16 * 1024,
                      let firstLine = String(data: firstLineData, encoding: .utf8) else {
                    self.rejectPendingConnection(activeConn)
                    return
                }

                if let typeProbe = try? JSONDecoder().decode(InitialSocketMessageType.self, from: firstLineData),
                   typeProbe.type == "videoStreamHello" {
                    if !self.claimPendingConnection(activeConn, promote: {
                        self.promoteVideoConnection(activeConn, firstLineData: firstLineData, trailingData: trailingData, endpointDesc: endpointDesc)
                    }) { self.rejectPendingConnection(activeConn) }
                    return
                }

                if let probe = try? JSONDecoder().decode(InitialSocketMessageType.self, from: firstLineData),
                   probe.type == "audioStreamHello" {
                    guard firstLineData.count <= 2048,
                          let hello = try? JSONDecoder().decode(PeelAudioStreamHello.self, from: firstLineData) else {
                        self.rejectPendingConnection(activeConn); return
                    }
                    if !self.claimPendingConnection(activeConn, promote: {
                        self.audioChannel.attach(activeConn, hello: hello, hasTrailingData: !trailingData.isEmpty || isComplete)
                    }) { self.rejectPendingConnection(activeConn) }
                    return
                }

                self.admitControlCandidate(activeConn, firstLineData: firstLineData, firstLine: firstLine,
                                           trailingData: trailingData, endpointDesc: endpointDesc,
                                           expectedGeneration: expectedControlGeneration)
            }
        }
    }

    private func admitControlCandidate(_ candidate: NWConnection, firstLineData: Data, firstLine: String,
                                       trailingData: Data, endpointDesc: String, expectedGeneration: UInt64) {
        guard let hello = try? JSONDecoder().decode(ClientHelloMessage.self, from: firstLineData),
              hello.type == "clientHello",
              !hello.deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !hello.platform.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("PeelHost: rejected control candidate reason=invalidHello expectedGeneration=\(expectedGeneration)")
            rejectPendingConnection(candidate)
            return
        }
        guard PeelProtocol.isCompatible(remoteCurrent: hello.protocolVersion,
                                        remoteMinimum: hello.minimumSupportedProtocolVersion) else {
            print("PeelHost: rejected control candidate reason=protocolMismatch expectedGeneration=\(expectedGeneration)")
            rejectPendingControlCandidate(candidate, response: ProtocolRejectedMessage(
                reason: "This Peel client is not compatible with this version of Peel Pro. Update both apps and try again.",
                remoteProtocolVersion: hello.protocolVersion,
                remoteMinimumSupportedProtocolVersion: hello.minimumSupportedProtocolVersion))
            return
        }
        guard let pairingID = hello.pairingID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pairingID.isEmpty else {
            print("PeelHost: rejected control candidate reason=missingPairing expectedGeneration=\(expectedGeneration)")
            rejectPendingConnection(candidate)
            return
        }

        // Known claimed pairing membership does not bind that claim to the PSK
        // selected by TLS. Preserve the existing TLS authorization boundary;
        // this change prevents invalid first lines from destroying an incumbent.
        let result = claimPendingControlConnection(candidate, pairingID: pairingID,
                                                   expectedGeneration: expectedGeneration) {
            promoteControlConnection(candidate, firstLine: firstLine, trailingData: trailingData,
                                     endpointDesc: endpointDesc)
        }
        switch result {
        case .admitted:
            print("PeelHost: admitted control candidate previousGeneration=\(expectedGeneration) generation=\(currentControlAdmissionGeneration())")
        case .stale:
            print("PeelHost: rejected control candidate reason=staleAdmission expectedGeneration=\(expectedGeneration)")
            rejectPendingConnection(candidate)
        case .unknownPairing:
            print("PeelHost: rejected control candidate reason=unknownPairing expectedGeneration=\(expectedGeneration)")
            rejectPendingControlCandidate(candidate, response: PairingRevokedMessage(
                pairingId: pairingID, deviceId: hostId, reason: "Host no longer recognizes this pairing"))
        }
    }

    /// Rejections use only the candidate socket. Never use the active send
    /// snapshot, delegate callbacks or global session cleanup for this response.
    private func rejectPendingControlCandidate<T: Encodable>(_ candidate: NWConnection, response: T) {
        guard isCurrentPendingConnection(candidate) else { rejectPendingConnection(candidate); return }
        pendingConnections.removeValue(forKey: ObjectIdentifier(candidate))
        candidate.stateUpdateHandler = nil
        guard var data = try? JSONEncoder().encode(response) else { candidate.cancel(); return }
        data.append(0x0A)
        candidate.send(content: data, completion: .contentProcessed { [weak candidate] _ in candidate?.cancel() })
        connectionQueue.asyncAfter(deadline: .now() + 0.15) { [weak candidate] in candidate?.cancel() }
    }

    private func promoteControlConnection(_ activeConn: NWConnection, firstLine: String, trailingData: Data, endpointDesc: String) {
        if let oldConnection = connection {
            setActiveSendConnection(nil)
            closeAllVideoConnections(reason: "new control connection")
            oldConnection.stateUpdateHandler = nil
            oldConnection.cancel()

            // Important: a new client socket must mean a fresh media session.
            // Otherwise existing SCK streams/encoders can survive the reconnect and
            // startStream can become a no-op with no fresh videoConfig.
            receiveBuffer.removeAll()
            notifyConnectionDidDisconnect()
        }

        connection = activeConn
        setActiveSendConnection(activeConn)
        receiveBuffer.removeAll()

        activeConn.stateUpdateHandler = { [weak self, weak activeConn] newState in
            guard let self, let activeConn else { return }
            self.connectionQueue.async { [weak self, weak activeConn] in
                guard let self, let activeConn else { return }
                self.handleConnectionStateUpdate(newState, for: activeConn, endpointDesc: endpointDesc)
            }
        }

        let promotedSnapshot = currentSendSnapshot()
        DispatchQueue.main.async { [weak self] in
            guard let self, let promotedSnapshot,
                  self.isCurrentSendSnapshot(promotedSnapshot) else { return }
            self.delegate?.hostNetworkServer(self, didUpdateStatus: "Client connected")
            self.delegate?.hostNetworkServerDidConnect(self)
            self.delegate?.hostNetworkServer(self, didReceiveLine: firstLine, generation: promotedSnapshot.generation)
        }

        if !trailingData.isEmpty {
            processIncomingData(trailingData)
        }

        startReceiveLoop(for: activeConn)
    }

    private func promoteVideoConnection(_ activeConn: NWConnection, firstLineData: Data, trailingData: Data, endpointDesc: String) {
        guard let hello = try? JSONDecoder().decode(VideoStreamHelloMessage.self, from: firstLineData) else {
            print("PeelHost: invalid videoStreamHello")
            activeConn.cancel()
            return
        }

        guard hello.protocolVersion >= PeelProtocol.minimumSupportedProtocolVersion,
              PeelProtocol.currentProtocolVersion >= hello.minimumSupportedProtocolVersion else {
            print("PeelHost: rejected video stream for incompatible protocol window=\(hello.windowId) remote=\(hello.protocolVersion)/\(hello.minimumSupportedProtocolVersion)")
            activeConn.cancel()
            return
        }

        if let pairingID = hello.pairingID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !pairingID.isEmpty,
           let connectedClientPairingID,
           pairingID != connectedClientPairingID {
            print("PeelHost: rejected video stream for mismatched pairing window=\(hello.windowId)")
            activeConn.cancel()
            return
        }

        if let oldVideoConnection = videoConnectionsByWindowId[hello.windowId] {
            setActiveVideoSendConnection(nil, windowId: hello.windowId)
            oldVideoConnection.stateUpdateHandler = nil
            oldVideoConnection.cancel()
            notifyVideoStreamClosed(windowId: hello.windowId)
        }

        videoConnectionsByWindowId[hello.windowId] = activeConn
        setActiveVideoSendConnection(activeConn, windowId: hello.windowId)

        activeConn.stateUpdateHandler = { [weak self, weak activeConn] newState in
            guard let self, let activeConn else { return }
            self.connectionQueue.async { [weak self, weak activeConn] in
                guard let self, let activeConn else { return }
                self.handleVideoConnectionStateUpdate(newState, for: activeConn, windowId: hello.windowId, endpointDesc: endpointDesc)
            }
        }

        if !trailingData.isEmpty {
            print("PeelHost: ignoring \(trailingData.count) trailing bytes after videoStreamHello window=\(hello.windowId)")
        }

        let admittedVideo = currentVideoSendSnapshot(windowId: hello.windowId)
        let admittedControl = currentSendSnapshot()
        DispatchQueue.main.async { [weak self] in
            guard let self, let admittedVideo,
                  self.isCurrentVideoSendSnapshot(admittedVideo) else { return }
            // Preferences cannot cross a control-session replacement. Existing
            // TLS/pairing admission above remains the authorization boundary.
            let request = admittedControl.map { self.isCurrentSendSnapshot($0) } == true
                ? hello.streamRequest : nil
            self.delegate?.hostNetworkServer(self, didUpdateStatus: "Video stream connected for window \(hello.windowId)")
            self.delegate?.hostNetworkServer(
                self,
                didOpenVideoStreamForWindow: hello.windowId,
                capabilities: Set(hello.capabilities ?? []),
                streamRequest: request
            )
        }
    }

    private func handleConnectionStateUpdate(_ newState: NWConnection.State, for activeConn: NWConnection, endpointDesc: String) {
        guard connection === activeConn else { return }

        switch newState {
        case .ready:
            break

        case .failed(let error):
            cleanupConnectionOnConnectionQueue(
                for: activeConn,
                cancelConnection: false,
                statusMessage: "Connection failed: \(error.localizedDescription)"
            )

        case .cancelled:
            print("PeelHost: connection cancelled:", endpointDesc)
            cleanupConnectionOnConnectionQueue(
                for: activeConn,
                cancelConnection: false,
                statusMessage: "Client disconnected"
            )

        default:
            break
        }
    }

    private func handleVideoConnectionStateUpdate(_ newState: NWConnection.State, for activeConn: NWConnection, windowId: UInt32, endpointDesc: String) {
        guard videoConnectionsByWindowId[windowId] === activeConn else { return }

        switch newState {
        case .ready:
            break
        case .failed(let error):
            print("PeelHost: video connection failed window=\(windowId):", error.localizedDescription)
            cleanupVideoConnectionOnConnectionQueue(for: activeConn, windowId: windowId, cancelConnection: false)
        case .cancelled:
            print("PeelHost: video connection cancelled window=\(windowId):", endpointDesc)
            cleanupVideoConnectionOnConnectionQueue(for: activeConn, windowId: windowId, cancelConnection: false)
        default:
            break
        }
    }

    private func cleanupConnection(
        for activeConn: NWConnection? = nil,
        cancelConnection: Bool = false,
        statusMessage: String? = nil
    ) {
        connectionQueue.async { [weak self] in
            self?.cleanupConnectionOnConnectionQueue(
                for: activeConn,
                cancelConnection: cancelConnection,
                statusMessage: statusMessage
            )
        }
    }

    private func cleanupConnectionOnConnectionQueue(
        for activeConn: NWConnection? = nil,
        cancelConnection: Bool,
        statusMessage: String? = nil
    ) {
        if let activeConn, connection !== activeConn {
            return
        }

        let currentConnection = connection
        connection = nil
        setActiveSendConnection(nil)
        receiveBuffer.removeAll()
        closeAllVideoConnections(reason: statusMessage ?? "control connection cleanup")

        currentConnection?.stateUpdateHandler = nil

        if cancelConnection {
            currentConnection?.cancel()
        }

        if currentConnection != nil || statusMessage != nil {
            notifyConnectionDidDisconnect(statusMessage: statusMessage)
        }
    }

    private func cleanupVideoConnectionOnConnectionQueue(for activeConn: NWConnection, windowId: UInt32, cancelConnection: Bool) {
        guard videoConnectionsByWindowId[windowId] === activeConn else { return }

        videoConnectionsByWindowId.removeValue(forKey: windowId)
        setActiveVideoSendConnection(nil, windowId: windowId)

        activeConn.stateUpdateHandler = nil
        if cancelConnection {
            activeConn.cancel()
        }

        notifyVideoStreamClosed(windowId: windowId)
    }

    private func closeAllVideoConnections(reason: String) {
        let connections = videoConnectionsByWindowId
        videoConnectionsByWindowId.removeAll()

        for (windowId, connection) in connections {
            setActiveVideoSendConnection(nil, windowId: windowId)
            connection.stateUpdateHandler = nil
            connection.cancel()
            notifyVideoStreamClosed(windowId: windowId)
        }
    }

    private func notifyVideoStreamClosed(windowId: UInt32) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.hostNetworkServer(self, didCloseVideoStreamForWindow: windowId)
        }
    }

    private func notifyConnectionDidDisconnect(statusMessage: String? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let statusMessage {
                let diagnostics = self.streamDiagnostics
                Task { @MainActor in
                    diagnostics?.lastDisconnectReason = statusMessage
                }
                self.delegate?.hostNetworkServer(self, didUpdateStatus: statusMessage)
            }
            self.connectedClientPairingID = nil
            self.delegate?.hostNetworkServerDidDisconnect(self)
        }
    }

    private func startReceiveLoop(for activeConn: NWConnection) {
        guard connection === activeConn else { return }

        activeConn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak activeConn] data, _, isComplete, error in
            guard let self, let activeConn else { return }

            self.connectionQueue.async { [weak self, weak activeConn] in
                guard let self, let activeConn else { return }
                guard self.connection === activeConn else { return }

                if let data, !data.isEmpty {
                    self.processIncomingData(data)
                }

                if let error {
                    print("PeelHost: receive error:", error.localizedDescription)
                    self.cleanupConnectionOnConnectionQueue(for: activeConn, cancelConnection: false)
                    return
                }

                if isComplete {
                    self.cleanupConnectionOnConnectionQueue(for: activeConn, cancelConnection: false)
                    return
                }

                self.startReceiveLoop(for: activeConn)
            }
        }
    }

    private func processIncomingData(_ data: Data) {
        receiveBuffer.append(data)

        while let newlineRange = receiveBuffer.firstRange(of: Data([0x0A])) {
            let messageData = receiveBuffer.subdata(in: 0..<newlineRange.lowerBound)
            receiveBuffer.removeSubrange(0..<newlineRange.upperBound)

            guard !messageData.isEmpty,
                  let jsonString = String(data: messageData, encoding: .utf8) else {
                continue
            }

            // All control lines retain their receiving connection identity until
            // main-actor delivery. A delayed input must never enter a newer session.
            let receivedSnapshot = currentSendSnapshot()
            DispatchQueue.main.async { [weak self] in
                guard let self, let receivedSnapshot,
                      self.isCurrentSendSnapshot(receivedSnapshot) else { return }
                self.delegate?.hostNetworkServer(self, didReceiveLine: jsonString, generation: receivedSnapshot.generation)
            }
        }
    }

    func netServiceDidPublish(_ sender: NetService) {
        guard isCurrentPrimaryBonjour(sender) else {
            if sender === pairingNetService {
                delegate?.hostNetworkServer(self, didUpdateStatus: "Bonjour published: \(sender.name) (\(sender.type)\(sender.domain))")
            }
            return
        }
        updateDiscoveryState(.published)
        delegate?.hostNetworkServer(self, didUpdateStatus: "Bonjour published: \(sender.name) (\(sender.type)\(sender.domain))")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]) {
        if isCurrentPrimaryBonjour(sender) {
            delegate?.hostNetworkServer(self, didUpdateStatus: "Bonjour failed: \(errorDict)")
            invalidatePrimaryBonjour()
            updateDiscoveryState(.failed)
            scheduleListenerRepair(reason: "Bonjour publish failed: \(errorDict)", delay: 0.75)
            return
        }

        if sender === pairingNetService {
            delegate?.hostNetworkServer(self, didUpdateStatus: "Bonjour failed: \(errorDict)")
            pairingNetService?.delegate = nil
            pairingNetService?.stop()
            pairingNetService = nil

            if let port = pairingListener?.port?.rawValue ?? pairingListenerPort, isDiscoverable {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
                    guard let self, self.isDiscoverable else { return }
                    self.startPairingBonjour(port: Int32(port))
                }
            }
        }
    }

    func netServiceDidStop(_ sender: NetService) {
        guard isCurrentPrimaryBonjour(sender) else { return }
        invalidatePrimaryBonjour()
        if isDiscoverable {
            updateDiscoveryState(.failed)
            scheduleListenerRepair(reason: "Bonjour stopped unexpectedly", delay: 0.75)
        } else {
            updateDiscoveryState(.disabled)
        }
    }

    private final class PairingRXBuffer {
        var data = Data()
    }

    private func startPairingListener() {
        guard pairingListener == nil else { return }

        do {
            let pinPSK = PeelTLS.derivePairingPinPSK(pin: pairingPIN, salt: pairingSalt, hostId: hostId)
            let params = PeelTLS.makeSinglePSKHostParameters(identity: PeelTLS.pairingPinIdentity, psk: pinPSK)
            pairingListener = try NWListener(using: params)
        } catch {
            print("PeelHost: failed to start pairing listener:", error)
            return
        }

        pairingListener?.newConnectionHandler = { [weak self] conn in
            self?.acceptPairingConnection(conn)
        }

        pairingListener?.stateUpdateHandler = { [weak self] state in
            guard let self else { return }

            switch state {
            case .ready:
                if let port = self.pairingListener?.port?.rawValue {
                    self.pairingListenerPort = port

                    if self.isDiscoverable {
                        self.pairingNetService?.stop()
                        self.pairingNetService = nil
                        self.startPairingBonjour(port: Int32(port))
                    }

                    self.updateBonjourTXTRecords()
                }

            case .failed(let error):
                print("PeelHost: pairing listener failed:", error)
                self.pairingListener?.stateUpdateHandler = nil
                self.pairingListener?.newConnectionHandler = nil
                self.pairingListener?.cancel()
                self.pairingListener = nil
                self.pairingListenerPort = nil
                self.updateBonjourTXTRecords()

            case .cancelled:
                self.pairingListenerPort = nil
                self.updateBonjourTXTRecords()

            default:
                break
            }
        }

        pairingListener?.start(queue: .main)
    }

    private func startPairingBonjour(port: Int32) {
        guard isDiscoverable else { return }
        let hostName = Host.current().localizedName ?? "Mac"
        let service = NetService(domain: "local.", type: "_peelpair._tcp.", name: "Peel Pair on \(hostName)", port: port)
        service.delegate = self
        service.publish()
        pairingNetService = service
        updateBonjourTXTRecords()
    }

    private func acceptPairingConnection(_ conn: NWConnection) {
        let buffer = PairingRXBuffer()
        var didStartReceive = false

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }

            switch state {
            case .ready:
                guard !didStartReceive else { return }
                didStartReceive = true
                self.receivePairingJSONBuffered(on: conn, buffer: buffer)
            case .failed, .cancelled:
                conn.stateUpdateHandler = nil
                conn.cancel()
            default:
                break
            }
        }

        conn.start(queue: .main)
    }

    private func receivePairingJSONBuffered(on conn: NWConnection, buffer: PairingRXBuffer) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if error != nil {
                conn.cancel()
                return
            }

            if let data, !data.isEmpty {
                buffer.data.append(data)

                if let msg = try? JSONDecoder().decode(PairRequestMessage.self, from: buffer.data) {
                    self.handlePairRequest(msg, on: conn)
                    return
                }

                if buffer.data.count > 64 * 1024 {
                    conn.cancel()
                    return
                }
            }

            if isComplete {
                conn.cancel()
                return
            }

            self.receivePairingJSONBuffered(on: conn, buffer: buffer)
        }
    }

    private func handlePairRequest(_ req: PairRequestMessage, on conn: NWConnection) {
        let hostName = Host.current().localizedName ?? "Mac"
        let serviceName = netService?.name ?? "Peel Pro"
        let cleanClientName = req.clientName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanClientDeviceId = req.clientDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)

        guard Date() < pairingPinExpiresAt else {
            sendPairingRejection(
                on: conn,
                hostName: hostName,
                serviceName: serviceName,
                reason: "Pairing PIN expired. Generate a new PIN and try again."
            )
            return
        }

        guard !cleanClientName.isEmpty, !cleanClientDeviceId.isEmpty else {
            sendPairingRejection(
                on: conn,
                hostName: hostName,
                serviceName: serviceName,
                reason: "Pairing request was missing device identity. Restart the client and try again."
            )
            return
        }

        let receivedPinProof = req.pinProof?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let expectedPinPSK = PeelTLS.derivePairingPinPSK(
            pin: pairingPIN,
            salt: pairingSalt,
            hostId: hostId
        )
        let expectedPinProof = PeelTLS.makePairingPinProof(
            pinPSK: expectedPinPSK,
            hostId: hostId,
            clientDeviceId: cleanClientDeviceId
        )

        guard !receivedPinProof.isEmpty, receivedPinProof == expectedPinProof else {
            sendPairingRejection(
                on: conn,
                hostName: hostName,
                serviceName: serviceName,
                reason: "Incorrect PIN. Check the 6-digit code and try again."
            )
            return
        }

        let psk = PeelPairingStore.generatePSK()
        let pairingId = UUID().uuidString

        do {
            _ = try pairingStore.addPeerPersistingKey(
                displayName: cleanClientName, serviceName: cleanClientDeviceId,
                tlsPSKOrder: .standard, pairingID: pairingId, psk: psk)
        } catch {
            sendPairingRejection(on: conn, hostName: hostName, serviceName: serviceName,
                reason: "This Mac could not save the pairing key. Existing pairings are unchanged. Try again.")
            return
        }

        scheduleListenerRefreshIfPairingMaterialChanged(reason: "PIN pairing accepted")

        let resp = PairResponseMessage(
            hostName: hostName,
            serviceName: serviceName,
            pairingId: pairingId,
            psk: psk,
            accepted: true
        )

        guard let data = try? JSONEncoder().encode(resp) else { return }
        conn.send(content: data, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func sendPairingRejection(on conn: NWConnection, hostName: String, serviceName: String, reason: String) {
        let resp = PairResponseMessage(
            hostName: hostName,
            serviceName: serviceName,
            pairingId: "",
            psk: Data(),
            accepted: false,
            reason: reason
        )

        guard let data = try? JSONEncoder().encode(resp) else {
            conn.cancel()
            return
        }

        conn.send(content: data, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    @discardableResult
    func noteConnectedClient(pairingID: String?, displayName: String?, generation: UInt64) -> Bool {
        guard let helloSnapshot = currentSendSnapshot(), helloSnapshot.generation == generation else { return false }
        sendStateLock.lock()
        if sendGeneration == generation { claimedSendPairingID = nil }
        sendStateLock.unlock()
        let cleanPairingID = pairingID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDisplayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let cleanPairingID, !cleanPairingID.isEmpty else {
            connectedClientPairingID = nil
            return false
        }

        guard pairingStore.paired.contains(where: { $0.id == cleanPairingID }) else {
            let rejection = PairingRevokedMessage(pairingId: cleanPairingID, deviceId: hostId,
                                                  reason: "Host no longer recognizes this pairing")
            if var rejectionData = try? JSONEncoder().encode(rejection) {
                rejectionData.append(0x0A)
                let payload = rejectionData
                outboundSendQueue.async { [weak self] in
                    guard let self, self.isCurrentSendSnapshot(helloSnapshot) else { return }
                    helloSnapshot.connection.send(content: payload, completion: .contentProcessed { _ in })
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.cleanupConnection(for: helloSnapshot.connection, cancelConnection: true,
                                        statusMessage: "Stale pairing rejected")
            }
            connectedClientPairingID = nil
            return false
        }

        sendStateLock.lock()
        guard sendConnection != nil, sendGeneration == generation else {
            sendStateLock.unlock()
            return false
        }
        claimedSendPairingID = cleanPairingID
        sendStateLock.unlock()
        connectedClientPairingID = cleanPairingID

        if lastGeneratedTokenPairingID == cleanPairingID {
            lastGeneratedTokenPairingID = nil
        }

        if let cleanDisplayName, !cleanDisplayName.isEmpty {
            pairingStore.updateDisplayName(pairingID: cleanPairingID, displayName: cleanDisplayName)
        }
        return true
    }

    private func generateSixDigitPIN() -> String {
        var value: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &value) { buf in
            SecRandomCopyBytes(kSecRandomDefault, buf.count, buf.baseAddress!)
        }
        let pin = Int(value % 1_000_000)
        return String(format: "%06d", pin)
    }

    func refreshPairingPIN() {
        pairingPIN = generateSixDigitPIN()

        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { buf in
            SecRandomCopyBytes(kSecRandomDefault, buf.count, buf.baseAddress!)
        }
        pairingSalt = salt
        pairingPinExpiresAt = Date().addingTimeInterval(pairingPinTTL)

        restartPairingListenerForPinChange()

        pairingPinTimer?.invalidate()
        pairingPinTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if Date() >= self.pairingPinExpiresAt {
                t.invalidate()
                self.refreshPairingPIN()
            }
        }
    }

    private func updateBonjourTXTRecords() {
        var record: [String: Data] = [
            "hostId": Data(hostId.utf8),
            "pairMode": Data("pin".utf8),
            "pinSalt": Data(pairingSalt.base64EncodedString().utf8),
            "pinExp": Data("\(Int(pairingPinExpiresAt.timeIntervalSince1970))".utf8),
        ]
        record[PeelTLS.pskOrderTXTKey] = Data(PeelTLS.standardPSKOrderTXTValue.utf8)

        if let port = pairingListener?.port?.rawValue ?? pairingListenerPort {
            record["pairPort"] = Data("\(port)".utf8)
        }

        let data = NetService.data(fromTXTRecord: record)
        netService?.setTXTRecord(data)
        pairingNetService?.setTXTRecord(data)
    }

    private func restartPairingListenerForPinChange() {
        guard isDiscoverable else { return }

        pairingListener?.stateUpdateHandler = nil
        pairingListener?.newConnectionHandler = nil
        pairingListener?.cancel()
        pairingListener = nil
        pairingListenerPort = nil
        updateBonjourTXTRecords()

        startPairingListener()
    }
}
