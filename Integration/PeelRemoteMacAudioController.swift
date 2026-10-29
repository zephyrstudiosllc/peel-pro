import Combine
import Foundation
import Network
import OSLog

/// The Mac receiver's single computer-audio (Listen) owner for the current
/// paired control connection. Playback only: it never requests Voice or the
/// microphone. It reuses the existing Host protocol unchanged:
/// audioSessionRequest -> audioPairingChallenge -> audioPairingProof ->
/// audioSessionState(ready, ticket) -> auxiliary PSK-TLS socket with
/// audioStreamHello -> v1 PEAU format + 20 ms stereo S16LE PCM.
///
/// Default playback: one attempt per control connection, started from the
/// first presented video frame of the selected stream while the viewer's last
/// ClientVisibilityMessage was visible, the Host advertises
/// mac-system-audio-v1, and this pairing has no explicit Off. Explicit Off
/// persists per pairing ID; explicit On clears it. Disconnect, hidden
/// visibility, failure and Off are never retried. A timeline discontinuity
/// gets at most one bounded restart (10 s), as on the Apple client.
///
/// Every network/AV callback is fenced by request ID, socket identity and the
/// viewer's current control epoch/pairing/visibility before any effect.
/// Receiver output volume/device are never changed here; source media and
/// volume controls are separate messages owned elsewhere.
@MainActor
final class PeelRemoteMacAudioController: ObservableObject {
    /// The viewer advertises mac-system-audio-v1 only while this is true.
    static let isPlaybackBackendAvailable = true

    /// Narrow adapters owned by PeelRemoteMacViewerController. Key material
    /// and the TLS factory stay inside the viewer; this owner sees none of it.
    struct Adapters {
        let context: () -> PeelRemoteMacAudioContext?
        let sendRequest: (PeelAudioSessionRequest) -> Void
        let sendProof: (PeelAudioPairingProofMessage) -> Void
        /// Returns the HMAC proof for the current pairing, or nil.
        let proof: (PeelAudioPairingChallengeMessage) -> String?
        /// Returns an unstarted auxiliary PSK-TLS connection to the current
        /// control endpoint for (pairingID, controlEpoch), or nil.
        let makeConnection: (_ pairingID: String, _ controlEpoch: UUID) -> NWConnection?
    }

    @Published private(set) var status = "Off"
    /// An audio request (or its single bounded restart) is in progress.
    @Published private(set) var isRequested = false
    /// The current request was started by default playback, not by the user.
    @Published private(set) var isAutomatic = false
    /// PCM was admitted within the last 1.5 s and the engine is rendering.
    @Published private(set) var isPlayingPCM = false

    private struct Activation {
        let id: UUID
        let controlEpoch: UUID
        let pairingID: String
        var automatic: Bool
        let streamWindowID: UInt32?
        var retryUsed = false
    }

    private struct Recovery {
        let id: UUID
        let activationID: UUID
        let oldRequestID: UUID
        let deadline: UInt64
        var newRequestID: UUID?
    }

    private let adapters: Adapters
    private let offStore: PeelRemoteMacAudioPlaybackOffStore
    private let playback = PeelRemoteMacAudioPlaybackOwner()
    /// Counts and fixed codes only; never PCM, keys, tickets, titles or Host text.
    private let log = Logger(subsystem: "com.zephyrstudiosllc.Peel", category: "MacReceiverAudio")

    /// Scheduling counters of the current or last playback session, for root.
    var timelineDiagnostics: String { playback.timelineCounters.summary }
    private let socketQueue = DispatchQueue(label: "peel.remote-mac.audio", qos: .userInteractive)
    private static let maximumReadBytes = 8 * 1024
    private static let livenessNanoseconds: UInt64 = 20_000_000_000
    private static let playingWindowNanoseconds: UInt64 = 1_500_000_000
    private static let restartNanoseconds: UInt64 = 10_000_000_000

    private var activation: Activation?
    private var recovery: Recovery?
    private var requestID: UUID?
    private var requestControlEpoch: UUID?
    private var pairingID: String?
    private var proved = false
    private var socket: NWConnection?
    private var socketReady = false
    private var hostStreamingReason: String?
    private var parser = PeelAudioPacketParser(expectedDirection: .macToClient)
    private var lastDataAt: UInt64 = 0
    private var lastAdmittedAt: UInt64 = 0
    /// Control epoch whose one default attempt was used. Only an auto-owned
    /// stream end re-arms it; Off, hidden, failure and manual starts keep it.
    private var defaultAttemptEpoch: UUID?

    init(adapters: Adapters, offStore: PeelRemoteMacAudioPlaybackOffStore = PeelRemoteMacAudioPlaybackOffStore()) {
        self.adapters = adapters
        self.offStore = offStore
        playback.onFailure = { [weak self] failure in
            guard let self, self.requestID != nil else { return }
            if failure == .timelineDiscontinuity {
                self.log.notice("audio timeline discontinuity \(self.playback.timelineCounters.summary, privacy: .public)")
                self.recoverTimeline()
            } else {
                self.stop(reason: failure.message)
            }
        }
    }

    // MARK: Public API for later UI

    func isDefaultPlaybackOff(for pairingID: String) -> Bool { offStore.isOff(pairingID) }

    /// Explicit On. Clears this pairing's saved Off and starts playback for
    /// the current connection. An automatic request becomes user-owned.
    func startByUser() {
        guard let context = adapters.context() else {
            status = "Connect to a computer first"
            return
        }
        offStore.setOff(false, for: context.pairingID)
        if var activation, activation.pairingID == context.pairingID,
           activation.controlEpoch == context.controlEpoch {
            activation.automatic = false
            self.activation = activation
            isAutomatic = false
            return
        }
        start(automatic: false)
    }

    /// Explicit Off. Default playback stays off for this pairing, across
    /// reconnect and relaunch, until the user turns audio on again.
    func stopByUser() {
        if let id = pairingID ?? activation?.pairingID ?? adapters.context()?.pairingID {
            offStore.setOff(true, for: id)
        }
        stop(reason: "Off")
    }

    // MARK: Viewer hooks

    /// Viewer: the selected stream presented a frame (also after recovery).
    func streamVideoReady() {
        let context = adapters.context()
        let inputs = PeelRemoteMacAudioDefaultGate.Inputs(
            backendAvailable: Self.isPlaybackBackendAvailable,
            idle: requestID == nil && recovery == nil && activation == nil,
            context: context,
            defaultAttemptEpoch: defaultAttemptEpoch,
            explicitlyOff: context.map { offStore.isOff($0.pairingID) } ?? true)
        guard PeelRemoteMacAudioDefaultGate.shouldStart(inputs), let context else { return }
        defaultAttemptEpoch = context.controlEpoch
        start(automatic: true)
    }

    /// Viewer: a ClientVisibilityMessage was sent. Hidden ends audio; the Host
    /// stops its capture on the same message, so nothing else is sent.
    func clientVisibilityChanged(_ visible: Bool) {
        guard !visible, activation != nil || requestID != nil else { return }
        stop(reason: "Off — stream hidden", notifyHost: false)
    }

    /// Viewer: the control connection is ending; the Host stops audio with
    /// its session, so nothing is sent on the closing connection.
    func controlWillEnd() {
        stop(reason: "Off", notifyHost: false)
        defaultAttemptEpoch = nil
    }

    func receive(_ challenge: PeelAudioPairingChallengeMessage) {
        guard let id = requestID, !proved, challenge.requestId == id.uuidString,
              challenge.pairingId == pairingID else { return }
        guard admitCurrentRequest() else { return }
        // Older playback Hosts omit mode; anything else is not Listen.
        guard challenge.mode == nil || challenge.mode == "playback" else {
            stop(reason: "Audio mode mismatch"); return
        }
        guard PeelAudioPairingProof.isFresh(challenge, now: Date().timeIntervalSince1970),
              let proof = adapters.proof(challenge) else {
            stop(reason: "Invalid audio challenge"); return
        }
        guard requestID == id, admitCurrentRequest() else { return }
        proved = true
        status = "Connecting computer audio"
        adapters.sendProof(PeelAudioPairingProofMessage(
            requestId: challenge.requestId, pairingId: challenge.pairingId, proof: proof))
    }

    func receive(_ state: PeelAudioSessionState) {
        // The old request is already torn down during a restart. Match its
        // captured authority first.
        if let recovery, recovery.newRequestID == nil,
           state.requestId == recovery.oldRequestID.uuidString,
           state.pairingId == activation?.pairingID {
            guard recoveryContextCurrent(recovery),
                  DispatchTime.now().uptimeNanoseconds < recovery.deadline else {
                stop(reason: "Audio restart ended"); return
            }
            if state.status == "stopped", let activation {
                beginRequest(restarting: activation.id)
            } else if state.status == "unavailable" {
                stop(reason: Self.bounded(state.reason) ?? "Computer audio could not stop cleanly", notifyHost: false)
            }
            return
        }
        guard let id = requestID, state.requestId == id.uuidString, state.pairingId == pairingID else { return }
        guard admitCurrentRequest() else { return }
        switch state.status {
        case "ready":
            guard proved, socket == nil, let ticket = state.ticket,
                  Data(base64Encoded: ticket)?.count == 32 else {
                stop(reason: "Invalid audio attachment"); return
            }
            connect(ticket: ticket, id: id)
        case "streaming":
            hostStreamingReason = Self.bounded(state.reason)
            if let hostStreamingReason { status = hostStreamingReason }
        case "unavailable", "stopped":
            stop(reason: Self.bounded(state.reason) ?? "Computer audio ended", notifyHost: false)
        default:
            stop(reason: "Unsupported audio session state")
        }
    }

    /// Ends the request and any pending restart. Never re-arms default.
    func stop(reason: String = "Off", notifyHost: Bool = true) {
        activation = nil
        recovery = nil
        endCurrentRequest(reason: reason, notifyHost: notifyHost)
    }

    // MARK: Request lifecycle

    private func start(automatic: Bool) {
        guard requestID == nil, recovery == nil, activation == nil else { return }
        guard Self.isPlaybackBackendAvailable, let context = adapters.context(), context.clientVisible else {
            status = "Connect to a computer first"; return
        }
        guard context.hostSupportsPlayback else {
            status = "This computer does not offer audio"; return
        }
        if automatic, context.streamWindowID == nil { return }
        activation = Activation(id: UUID(), controlEpoch: context.controlEpoch, pairingID: context.pairingID,
                                automatic: automatic, streamWindowID: automatic ? context.streamWindowID : nil)
        beginRequest(restarting: nil)
    }

    private func beginRequest(restarting activationID: UUID?) {
        guard requestID == nil, let activation, let context = adapters.context(),
              contextCurrent(activation, context) else {
            stop(reason: "Audio is unavailable for this computer"); return
        }
        if let activationID {
            guard activation.id == activationID, activation.retryUsed,
                  let recovery, recovery.activationID == activationID, recovery.newRequestID == nil,
                  DispatchTime.now().uptimeNanoseconds < recovery.deadline else {
                stop(reason: "Audio restart ended"); return
            }
        }
        let id = UUID()
        requestID = id
        if activationID != nil { recovery?.newRequestID = id }
        requestControlEpoch = activation.controlEpoch
        pairingID = activation.pairingID
        proved = false
        socketReady = false
        hostStreamingReason = nil
        parser.reset()
        lastDataAt = DispatchTime.now().uptimeNanoseconds
        lastAdmittedAt = lastDataAt
        isRequested = true
        isAutomatic = activation.automatic
        status = "Requesting computer audio"
        adapters.sendRequest(PeelAudioSessionRequest(requestId: id.uuidString, enabled: true, mode: "playback"))
        // A failed control send may synchronously disconnect and stop us.
        guard requestID == id else { return }
        watch(id)
    }

    private func endCurrentRequest(reason: String, notifyHost: Bool, preservingActivation: Bool = false) {
        let id = requestID
        var canNotify = false
        if notifyHost, id != nil, let context = adapters.context() {
            canNotify = context.controlEpoch == requestControlEpoch && context.pairingID == pairingID
        }
        // Invalidate every async source before stopping the engine.
        requestID = nil
        requestControlEpoch = nil
        socketReady = false
        hostStreamingReason = nil
        socket?.stateUpdateHandler = nil
        socket?.cancel()
        socket = nil
        playback.stop(sessionID: id)
        if id != nil {
            log.notice("audio request ended restart=\(preservingActivation, privacy: .public) \(self.playback.timelineCounters.summary, privacy: .public)")
        }
        parser.reset()
        proved = false
        pairingID = nil
        setPlaying(false)
        isRequested = preservingActivation
        isAutomatic = preservingActivation && activation?.automatic == true
        status = reason
        // Send last: a send failure can re-enter disconnect -> stop().
        if canNotify, let id {
            adapters.sendRequest(PeelAudioSessionRequest(requestId: id.uuidString, enabled: false, mode: "playback"))
        }
    }

    private func recoverTimeline() {
        guard let id = requestID, var activation, !activation.retryUsed, recovery == nil,
              let context = adapters.context(), contextCurrent(activation, context) else {
            let cause = requestID == nil ? "noRequest" : activation == nil ? "noActivation"
                : activation?.retryUsed == true ? "retryUsed" : recovery != nil ? "recoveryActive" : "contextChanged"
            log.notice("audio restart refused cause=\(cause, privacy: .public)")
            stop(reason: "Computer audio stalled; turn audio on to retry"); return
        }
        log.notice("audio restart once")
        let (deadline, overflow) = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(Self.restartNanoseconds)
        guard !overflow else { stop(reason: "Audio restart deadline unavailable"); return }
        activation.retryUsed = true
        self.activation = activation
        let child = Recovery(id: UUID(), activationID: activation.id, oldRequestID: id, deadline: deadline)
        recovery = child
        endCurrentRequest(reason: "Restarting computer audio", notifyHost: true, preservingActivation: true)
        DispatchQueue.main.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadline)) { [weak self] in
            guard let self, self.recovery?.id == child.id, self.activation?.id == child.activationID else { return }
            self.stop(reason: "Computer audio restart timed out")
        }
    }

    // MARK: Authority

    private func contextCurrent(_ activation: Activation, _ context: PeelRemoteMacAudioContext) -> Bool {
        context.controlEpoch == activation.controlEpoch && context.pairingID == activation.pairingID
            && context.clientVisible && context.hostSupportsPlayback
            && (!activation.automatic || context.streamWindowID == activation.streamWindowID)
    }

    private func recoveryContextCurrent(_ recovery: Recovery) -> Bool {
        guard let activation, activation.id == recovery.activationID,
              let context = adapters.context() else { return false }
        return contextCurrent(activation, context)
    }

    /// Admission for new effects. Lost authority ends the request; an
    /// automatic request whose stream ended re-arms the next stream's default.
    private func admitCurrentRequest() -> Bool {
        let context = adapters.context()
        guard requestID != nil, let activation, let context, contextCurrent(activation, context) else {
            if let activation, activation.automatic, let context,
               context.controlEpoch == activation.controlEpoch, context.pairingID == activation.pairingID,
               context.clientVisible, context.streamWindowID != activation.streamWindowID {
                stop(reason: "Off — no active stream")
                defaultAttemptEpoch = nil
            } else {
                stop(reason: "Audio session ended")
            }
            return false
        }
        if let recovery {
            guard recovery.newRequestID == requestID,
                  DispatchTime.now().uptimeNanoseconds < recovery.deadline else {
                stop(reason: "Computer audio restart timed out"); return false
            }
        }
        return true
    }

    // MARK: Auxiliary audio socket

    private func connect(ticket: String, id: UUID) {
        guard requestID == id, admitCurrentRequest(), let pairingID, let activation,
              let connection = adapters.makeConnection(pairingID, activation.controlEpoch) else {
            stop(reason: "Computer audio is unavailable"); return
        }
        socket = connection
        socketReady = false
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            DispatchQueue.main.async { [weak self, weak connection] in
                guard let self, let connection, self.socket === connection, self.requestID == id,
                      self.admitCurrentRequest() else { return }
                switch state {
                case .ready:
                    guard !self.socketReady else { return }
                    self.socketReady = true
                    guard var hello = try? JSONEncoder().encode(
                        PeelAudioStreamHello(requestId: id.uuidString, pairingId: pairingID, ticket: ticket)) else {
                        self.stop(reason: "Audio connection failed"); return
                    }
                    hello.append(0x0A)
                    connection.send(content: hello, completion: .contentProcessed { [weak self, weak connection] error in
                        guard error != nil else { return }
                        DispatchQueue.main.async { [weak self, weak connection] in
                            guard let self, let connection, self.socket === connection, self.requestID == id else { return }
                            self.stop(reason: "Audio connection failed")
                        }
                    })
                    self.receiveNext(connection, id: id)
                case .failed, .cancelled:
                    self.stop(reason: "Audio connection ended")
                default:
                    break
                }
            }
        }
        connection.start(queue: socketQueue)
    }

    /// Exactly one bounded receive is outstanding per socket.
    private func receiveNext(_ connection: NWConnection, id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maximumReadBytes) {
            [weak self, weak connection] data, _, complete, error in
            DispatchQueue.main.async { [weak self, weak connection] in
                guard let self, let connection, self.socket === connection, self.requestID == id,
                      self.admitCurrentRequest() else { return }
                do {
                    if let data, !data.isEmpty {
                        for packet in try self.parser.feed(data) {
                            guard self.socket === connection, self.requestID == id,
                                  self.admitCurrentRequest() else { return }
                            try self.accept(packet, id: id)
                        }
                    }
                } catch {
                    guard self.socket === connection, self.requestID == id else { return }
                    self.stop(reason: "Malformed computer audio stream"); return
                }
                // accept() may synchronously restart (recoverTimeline) and
                // retire this socket/request; an old EOF must not stop the
                // newly pending restart.
                guard self.socket === connection, self.requestID == id else { return }
                guard !complete, error == nil else { self.stop(reason: "Audio connection ended"); return }
                // An enqueue failure can tear down synchronously; never rearm then.
                guard self.socket === connection, self.requestID == id, self.admitCurrentRequest() else { return }
                self.receiveNext(connection, id: id)
            }
        }
    }

    private enum AcceptError: Error { case formatBeforeAttachment }

    private func accept(_ packet: PeelAudioPacket, id: UUID) throws {
        guard requestID == id, admitCurrentRequest() else { return }
        if packet.kind == .format, !playback.isStarted {
            guard proved, socketReady else { throw AcceptError.formatBeforeAttachment }
            do {
                try playback.start(sessionID: id)
            } catch let failure as PeelRemoteMacAudioPlaybackFailure {
                stop(reason: failure.message); return
            }
            status = "Waiting for computer audio"
        }
        guard requestID == id, admitCurrentRequest() else { return }
        let accepted = playback.enqueue(packet, sessionID: id)
        // Enqueue failures report synchronously and may end or restart.
        guard requestID == id, packet.kind == .pcm else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        lastDataAt = now
        guard accepted else { return }
        if let recovery {
            guard recovery.newRequestID == id, recoveryContextCurrent(recovery), now < recovery.deadline else {
                stop(reason: "Computer audio restart timed out"); return
            }
            self.recovery = nil
        }
        lastAdmittedAt = now
        setPlaying(playback.isRendering)
        status = hostStreamingReason ?? "Playing computer audio"
    }

    private func watch(_ id: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.requestID == id, self.admitCurrentRequest() else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now >= self.lastDataAt, now - self.lastDataAt < Self.livenessNanoseconds else {
                self.stop(reason: "Computer audio timed out"); return
            }
            if self.recovery == nil {
                guard now >= self.lastAdmittedAt, now - self.lastAdmittedAt < Self.livenessNanoseconds else {
                    self.stop(reason: "Computer audio playback stalled; turn audio on to retry"); return
                }
            }
            self.setPlaying(self.playback.isRendering && now >= self.lastAdmittedAt
                && now - self.lastAdmittedAt < Self.playingWindowNanoseconds)
            self.watch(id)
        }
    }

    private func setPlaying(_ playing: Bool) {
        guard isPlayingPCM != playing else { return }
        isPlayingPCM = playing
    }

    private static func bounded(_ reason: String?) -> String? {
        guard let reason else { return nil }
        var scalars = String.UnicodeScalarView()
        var count = 0
        for scalar in reason.unicodeScalars where scalar.value >= 32 && scalar.value != 127 {
            guard count < 200 else { break }
            scalars.append(scalar)
            count += 1
        }
        let cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}
