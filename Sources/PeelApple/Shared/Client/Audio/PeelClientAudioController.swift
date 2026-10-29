#if os(iOS) || os(visionOS)
import Foundation
import Network

enum PeelClientAudioMode: String, CaseIterable, Identifiable, Sendable {
    case playback
    case voice

    var id: String { rawValue }

    var title: String {
        switch self {
        case .playback: return "Listen"
        case .voice: return "Voice"
        }
    }

    var hostCapability: String {
        switch self {
        case .playback: return PeelCapability.macSystemAudioV1.rawValue
        case .voice: return PeelCapability.remoteVoiceV1.rawValue
        }
    }
}

private enum PeelClientAudioControllerError: Error {
    case voicePrerequisiteMissing
}

/// One explicitly requested audio session. Network callbacks run on main, and
/// only one bounded receive is outstanding, so a busy UI cannot accumulate tasks.
@MainActor
final class PeelClientAudioController {
    private weak var session: PeelHostSession?
    private var sourceControl: NWConnection?
    private var socket: NWConnection?
    private var requestID: UUID?
    private var permissionRequestID: UUID?
    private var pairingID: String?
    private var mode: PeelClientAudioMode = .playback
    private var proved = false
    private var socketReady = false
    private var downlinkFormatReady = false
    private var hostStreamingReason: String?
    private var parser = PeelAudioPacketParser(expectedDirection: .macToClient)
    private let playback = PeelAudioPlaybackOwner()
    private let voice = PeelVoiceAudioOwner()
    private var uplinkWriter: PeelAudioUplinkWriter?
    private var lastDataAt: UInt64 = 0
    private var lastDownlinkAdmittedAt: UInt64 = 0

    private struct Activation {
        let id: UUID
        let control: NWConnection
        let pairingID: String
        let mode: PeelClientAudioMode
        /// Started by default playback rather than the Audio panel.
        let automatic: Bool
        var retryUsed = false
    }
    private struct Recovery {
        let id: UUID
        let activationID: UUID
        let oldRequestID: UUID
        let deadline: UInt64
        var newRequestID: UUID?
    }
    private var activation: Activation?
    private var recovery: Recovery?
    /// Control connection whose current group of streams already used its one
    /// default Listen attempt. Only an auto-owned last-stream close clears it;
    /// Off, background, failure, audio moves and manual starts keep it, and
    /// there is no retry.
    private weak var defaultPlaybackControl: NWConnection?
    /// Set only for the synchronous default start so its Activation is marked.
    private var startingAutomatically = false
    /// Pairing IDs (not keys) whose audio the user deliberately turned off.
    /// Persists across reconnect and relaunch until the user turns audio on.
    private static let defaultPlaybackOffKey = "peel.audio.defaultPlaybackOffPairingIDs"

    private static func isDefaultPlaybackOff(for pairingID: String) -> Bool {
        UserDefaults.standard.stringArray(forKey: defaultPlaybackOffKey)?.contains(pairingID) == true
    }

    private static func setDefaultPlaybackOff(_ off: Bool, for pairingID: String) {
        var ids = UserDefaults.standard.stringArray(forKey: defaultPlaybackOffKey) ?? []
        guard ids.contains(pairingID) != off else { return }
        ids.removeAll { $0 == pairingID }
        if off { ids = Array((ids + [pairingID]).suffix(64)) }
        UserDefaults.standard.set(ids, forKey: defaultPlaybackOffKey)
    }

    init(session: PeelHostSession) {
        self.session = session
        playback.onFailure = { [weak self] failure in
            guard let self, self.requestID != nil else { return }
            if failure == .timelineDiscontinuity {
                self.recoverTimeline()
            } else {
                self.stop(reason: failure.localizedDescription)
            }
        }
    }

    /// Preserves the existing playback-only caller API.
    func start() {
        start(mode: .playback)
    }

    /// Explicit Audio panel On. Clears an earlier deliberate Off for this
    /// computer; Voice still requests microphone permission as before.
    func startByUser(mode requestedMode: PeelClientAudioMode) {
        if let pairingID = session?.activePairingID {
            Self.setDefaultPlaybackOff(false, for: pairingID)
        }
        start(mode: requestedMode)
    }

    /// Explicit Audio panel Off. Default playback stays off for this computer,
    /// across reconnect and relaunch, until the user turns audio on again.
    func stopByUser() {
        if let pairingID = pairingID ?? activation?.pairingID ?? session?.activePairingID {
            Self.setDefaultPlaybackOff(true, for: pairingID)
        }
        stop(reason: "Off")
    }

    /// Playback-only default for an active stream. Runs from a queued
    /// first-frame callback, so stream state is rechecked here. Uses the same
    /// capability, Host consent and pairing proof as a manual start, never
    /// Voice, and never takes audio from another computer that owns it.
    func startDefaultPlaybackIfEligible() {
        guard requestID == nil, permissionRequestID == nil,
              recovery == nil, activation == nil,
              let session, !session.systemAudioRequested,
              let control = session.connection,
              defaultPlaybackControl !== control,
              PeelAudioPlatformCapabilities.supportsMacSystemAudio,
              session.isConnectionReady, session.isClientVisible,
              !session.videoReadyWindowIds.isDisjoint(with: session.desiredPullWindowIds),
              session.hostCapabilities.contains(PeelClientAudioMode.playback.hostCapability),
              let pairingID = session.activePairingID,
              session.browser?.pairingStore.paired.contains(where: { $0.id == pairingID }) == true,
              !Self.isDefaultPlaybackOff(for: pairingID) else {
            return
        }
        let otherOwnsAudio = session.browser?.sessionsByHostKey.values.contains {
            $0 !== session && $0.systemAudioRequested
        } ?? false
        guard !otherOwnsAudio else { return }
        defaultPlaybackControl = control
        startingAutomatically = true
        start(mode: .playback)
        startingAutomatically = false
    }

    /// Ends only automatically started audio once this computer has no
    /// desired stream. Audio the user turned on keeps its existing lifetime.
    /// Only this auto-owned last-stream close re-arms the default attempt, so
    /// the next stream group on the same connection gets one new attempt.
    func stopAutomaticPlaybackIfStreamsEnded() {
        guard let session, session.desiredPullWindowIds.isEmpty,
              let activation, activation.automatic,
              activation.control === session.connection,
              defaultPlaybackControl === activation.control else { return }
        stop(reason: "Off — no active stream")
        defaultPlaybackControl = nil
    }

    /// Starts playback immediately or requests microphone permission from an
    /// explicit Voice-mode UI action before sending a voice session request.
    func start(mode requestedMode: PeelClientAudioMode) {
        guard requestID == nil, permissionRequestID == nil, recovery == nil, let session else {
            return
        }
        guard PeelAudioPlatformCapabilities.supportsMacSystemAudio else {
            session.systemAudioStatus = "Audio is unavailable on this device"
            return
        }
        if requestedMode == .voice && !PeelAudioPlatformCapabilities.supportsFullDuplexVoice {
            session.systemAudioStatus = "Voice audio is unavailable on this device"
            return
        }
        guard session.isConnectionReady, session.isClientVisible else {
            session.systemAudioStatus = "Connect to an updated Peel Pro first"
            return
        }
        guard session.hostCapabilities.contains(requestedMode.hostCapability) else {
            session.systemAudioStatus = requestedMode == .voice
                ? "This computer does not advertise Voice audio"
                : "Connect to an updated Peel Pro first"
            return
        }

        if requestedMode == .voice {
            requestVoicePermission(for: session)
        } else {
            beginRequest(mode: .playback)
        }
    }

    private func requestVoicePermission(for session: PeelHostSession) {
        guard #available(iOS 17.0, visionOS 26.0, *) else {
            session.systemAudioStatus = "Voice audio requires a newer Apple OS"
            return
        }

        let permissionID = UUID()
        permissionRequestID = permissionID
        mode = .voice
        session.systemAudioRequested = true
        session.systemAudioStatus = "Requesting microphone permission"

        PeelVoiceAudioOwner.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.permissionRequestID == permissionID else { return }
                self.permissionRequestID = nil
                guard granted else {
                    self.session?.systemAudioRequested = false
                    self.session?.systemAudioStatus = "Microphone permission was not granted"
                    return
                }
                self.beginRequest(mode: .voice)
            }
        }
    }

    private func beginRequest(mode requestedMode: PeelClientAudioMode,
                              restarting activationID: UUID? = nil) {
        guard requestID == nil, let session else { return }
        guard requestedMode == .playback
                ? PeelAudioPlatformCapabilities.supportsMacSystemAudio
                : PeelAudioPlatformCapabilities.supportsFullDuplexVoice,
              session.isConnectionReady,
              session.isClientVisible,
              session.hostCapabilities.contains(requestedMode.hostCapability),
              let control = session.connection,
              let pairingID = session.activePairingID,
              session.browser?.pairingStore.psk(for: pairingID) != nil
        else {
            stop(reason: "Audio is unavailable for this computer")
            return
        }

        if let activationID {
            guard let activation, activation.id == activationID,
                  activation.retryUsed, activation.mode == requestedMode,
                  activation.control === control, activation.pairingID == pairingID,
                  let recovery, recovery.activationID == activationID,
                  recovery.newRequestID == nil,
                  DispatchTime.now().uptimeNanoseconds < recovery.deadline else {
                stop(reason: "Audio restart ended")
                return
            }
        } else {
            guard recovery == nil else { return }
            activation = Activation(id: UUID(), control: control,
                                    pairingID: pairingID, mode: requestedMode,
                                    automatic: startingAutomatically && requestedMode == .playback)
        }

        // AVAudioSession is process-wide. Only one host may own playback or
        // voice at a time.
        for other in session.browser?.sessionsByHostKey.values
                ?? Dictionary<PeelHostKey, PeelHostSession>().values
            where other !== session {
            other.stopSystemAudio(reason: "Audio moved to another computer")
        }

        let id = UUID()
        requestID = id
        if activationID != nil { recovery?.newRequestID = id }
        mode = requestedMode
        self.pairingID = pairingID
        sourceControl = control
        proved = false
        socketReady = false
        downlinkFormatReady = false
        hostStreamingReason = nil
        parser.reset()
        lastDataAt = DispatchTime.now().uptimeNanoseconds
        lastDownlinkAdmittedAt = lastDataAt
        session.systemAudioRequested = true
        session.systemAudioStatus = requestedMode == .voice
            ? "Requesting voice audio"
            : "Requesting system audio"
        // Moving audio off another host may synchronously drain its AV graph.
        // Recheck the fixed child deadline immediately before this new request.
        guard requestID == id, admitCurrentRequest() else { return }
        session.sendJSONMessage(PeelAudioSessionRequest(
            requestId: id.uuidString,
            enabled: true,
            mode: requestedMode.rawValue
        ))
        watch(id)
    }

    func receive(_ challenge: PeelAudioPairingChallengeMessage) {
        guard validSession(), !proved, let session,
              challenge.requestId == requestID?.uuidString,
              challenge.pairingId == pairingID else {
            return
        }
        guard admitCurrentRequest() else { return }
        // Older playback Hosts omitted the optional mode field. Preserve that
        // interop only for playback; voice must echo the selected mode exactly
        // before its distinct proof is accepted.
        let challengeModeAccepted = mode == .playback
            ? (challenge.mode == nil || challenge.mode == PeelClientAudioMode.playback.rawValue)
            : challenge.mode == PeelClientAudioMode.voice.rawValue
        guard challengeModeAccepted else {
            stop(reason: "Audio mode mismatch")
            return
        }
        guard PeelAudioPairingProof.isFresh(challenge, now: Date().timeIntervalSince1970),
              let key = session.browser?.pairingStore.psk(for: challenge.pairingId),
              let proof = PeelAudioPairingProof.make(challenge, key: key) else {
            stop(reason: "Invalid audio challenge")
            return
        }
        guard admitCurrentRequest() else { return }
        proved = true
        session.systemAudioStatus = mode == .voice
            ? "Verified voice audio"
            : "Connecting system audio"
        session.sendJSONMessage(PeelAudioPairingProofMessage(
            requestId: challenge.requestId,
            pairingId: challenge.pairingId,
            proof: proof
        ))
    }

    func receive(_ state: PeelAudioSessionState) {
        // The old request is already torn down. Match its captured authority
        // before validSession(), which deliberately requires a live request.
        if let recovery, recovery.newRequestID == nil,
           state.requestId == recovery.oldRequestID.uuidString,
           state.pairingId == activation?.pairingID {
            guard recoveryContextCurrent(recovery),
                  DispatchTime.now().uptimeNanoseconds < recovery.deadline else {
                stop(reason: "Audio restart ended")
                return
            }
            if state.status == "stopped" {
                guard let activation else { return }
                if activation.mode == .voice {
                    guard #available(iOS 17.0, visionOS 26.0, *),
                          PeelVoiceAudioOwner.hasRecordPermission else {
                        stop(reason: "Voice restart requires microphone permission")
                        return
                    }
                }
                beginRequest(mode: activation.mode, restarting: activation.id)
            } else if state.status == "unavailable" {
                stop(reason: String((state.reason ?? "Computer audio could not stop cleanly").prefix(200)),
                     notifyHost: false)
            }
            return
        }
        guard validSession(), let session,
              state.requestId == requestID?.uuidString,
              state.pairingId == pairingID else {
            return
        }
        guard admitCurrentRequest() else { return }
        switch state.status {
        case "ready":
            guard proved, socket == nil, let ticket = state.ticket,
                  Data(base64Encoded: ticket)?.count == 32 else {
                stop(reason: "Invalid audio attachment")
                return
            }
            connect(ticket: ticket)
        case "streaming":
            if let reason = state.reason?.trimmingCharacters(in: .whitespacesAndNewlines),
               !reason.isEmpty {
                let boundedReason = String(reason.prefix(200))
                hostStreamingReason = boundedReason
                session.systemAudioStatus = boundedReason
            } else {
                hostStreamingReason = nil
            }
        case "unavailable", "stopped":
            stop(reason: String((state.reason ?? "Computer audio ended").prefix(200)),
                 notifyHost: false)
        default:
            stop(reason: "Unsupported audio session state")
        }
    }

    func stop(reason: String = "Off", notifyHost: Bool = true) {
        // Public Stop/background/revocation also cancels a child waiting with
        // no live request. Its old receipt/timer can never rearm this intent.
        activation = nil
        recovery = nil
        endCurrentRequest(reason: reason, notifyHost: notifyHost)
    }

    private func endCurrentRequest(reason: String, notifyHost: Bool,
                                   preservingActivation: Bool = false) {
        let id = requestID
        let activeMode = mode
        let canNotify = validSession()

        // Invalidate every asynchronous source before stopping the shared
        // audio owners. Late socket sends, permission callbacks, worker
        // callbacks, and AVAudio completions then fail their generation checks.
        permissionRequestID = nil
        requestID = nil
        socketReady = false
        downlinkFormatReady = false
        hostStreamingReason = nil
        uplinkWriter?.invalidate()
        uplinkWriter = nil
        socket?.stateUpdateHandler = nil
        socket?.cancel()
        socket = nil

        voice.stop(sessionID: id)
        playback.stop(sessionID: id)
        parser.reset()
        proved = false
        sourceControl = nil
        pairingID = nil

        if notifyHost, canNotify, let id {
            session?.sendJSONMessage(PeelAudioSessionRequest(
                requestId: id.uuidString,
                enabled: false,
                mode: activeMode.rawValue
            ))
        }
        if !preservingActivation { mode = .playback }
        setPlaying(false)
        session?.systemAudioRequested = preservingActivation
        session?.systemAudioStatus = reason
    }

    private func recoveryContextCurrent(_ recovery: Recovery) -> Bool {
        guard let activation, activation.id == recovery.activationID,
              let session, session.connection === activation.control,
              session.activePairingID == activation.pairingID,
              session.isConnectionReady, session.isClientVisible,
              session.hostCapabilities.contains(activation.mode.hostCapability),
              session.browser?.pairingStore.paired.contains(where: { $0.id == activation.pairingID }) == true else {
            return false
        }
        return true
    }

    private func recoverTimeline() {
        guard let id = requestID, validSession(), var activation,
              !activation.retryUsed, recovery == nil,
              sourceControl === activation.control,
              pairingID == activation.pairingID, mode == activation.mode else {
            stop(reason: "Computer audio stalled; turn audio on to retry")
            return
        }
        let (deadline, overflow) = DispatchTime.now().uptimeNanoseconds
            .addingReportingOverflow(10_000_000_000)
        guard !overflow else {
            stop(reason: "Audio restart deadline unavailable")
            return
        }
        activation.retryUsed = true
        self.activation = activation
        let child = Recovery(id: UUID(), activationID: activation.id,
                             oldRequestID: id, deadline: deadline)
        recovery = child
        endCurrentRequest(reason: "Restarting computer audio", notifyHost: true,
                          preservingActivation: true)
        DispatchQueue.main.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadline)) { [weak self] in
            guard let self, self.recovery?.id == child.id,
                  self.activation?.id == child.activationID else { return }
            self.stop(reason: "Computer audio restart timed out")
        }
    }

    /// Admission for new effects, separate from authority used for deny-only
    /// cleanup. A delayed timeout callback must never extend recovery lifetime.
    private func admitCurrentRequest() -> Bool {
        guard validSession() else {
            stop(reason: "Audio session ended")
            return false
        }
        if let recovery {
            guard recovery.newRequestID == requestID,
                  recoveryContextCurrent(recovery),
                  DispatchTime.now().uptimeNanoseconds < recovery.deadline else {
                stop(reason: "Computer audio restart timed out")
                return false
            }
        }
        return true
    }

    private func validSession() -> Bool {
        guard requestID != nil, let session, let sourceControl,
              session.connection === sourceControl,
              session.activePairingID == pairingID,
              session.isConnectionReady,
              session.isClientVisible,
              let pairingID,
              session.browser?.pairingStore.paired.contains(where: { $0.id == pairingID }) == true
        else {
            return false
        }
        return true
    }

    private func connect(ticket: String) {
        guard admitCurrentRequest(),
              let session,
              let id = requestID,
              let pairingID,
              let browser = session.browser,
              let peer = session.connectionPeer(),
              peer.id == pairingID,
              let key = browser.pairingStore.psk(for: pairingID),
              let endpoint = session.currentTransportEndpoint(),
              let pskOrder = session.transportPSKOrder(for: peer),
              let portValue = UInt16(exactly: endpoint.port),
              portValue > 0,
              let port = NWEndpoint.Port(rawValue: portValue) else {
            stop(reason: "Computer audio is unavailable")
            return
        }

        let parameters = PeelTLS.makeClientParameters(
            pairingID: pairingID,
            psk: key,
            pskOrder: pskOrder
        )
        // Keep latency tuning local to the dedicated audio socket. The shared
        // control/video TLS parameters retain their existing policy.
        parameters.serviceClass = mode == .voice ? .interactiveVoice : .responsiveData
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        guard requestID == id, admitCurrentRequest() else { return }
        let connection = NWConnection(
            host: NWEndpoint.Host(endpoint.host),
            port: port,
            using: parameters
        )
        socket = connection
        socketReady = false
        downlinkFormatReady = false
        uplinkWriter = mode == .voice ? PeelAudioUplinkWriter() : nil

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            DispatchQueue.main.async { [weak self, weak connection] in
                guard let self, let connection,
                      self.socket === connection,
                      self.requestID == id else {
                    return
                }
                guard self.admitCurrentRequest() else { return }
                switch state {
                case .ready:
                    guard !self.socketReady else { return }
                    self.socketReady = true
                    if self.mode == .voice, let writer = self.uplinkWriter {
                        writer.bind(connection: connection, generation: id) { [weak self] in
                            DispatchQueue.main.async { [weak self] in
                                guard let self,
                                      self.requestID == id,
                                      self.mode == .voice else {
                                    return
                                }
                                self.stop(reason: "Voice uplink connection failed")
                            }
                        }
                    }
                    do {
                        var hello = try JSONEncoder().encode(PeelAudioStreamHello(
                            requestId: id.uuidString,
                            pairingId: pairingID,
                            ticket: ticket
                        ))
                        hello.append(0x0A)
                        guard self.socket === connection, self.requestID == id,
                              self.admitCurrentRequest() else { return }
                        connection.send(content: hello, completion: .contentProcessed { [weak self] error in
                            DispatchQueue.main.async { [weak self] in
                                guard let self,
                                      self.requestID == id,
                                      error != nil else {
                                    return
                                }
                                self.stop(reason: "Audio connection failed")
                            }
                        })
                        self.receiveNext(connection, id: id)
                    } catch {
                        self.stop(reason: "Audio connection failed")
                    }
                case .failed, .cancelled:
                    self.stop(reason: "Audio connection ended")
                default:
                    break
                }
            }
        }
        guard socket === connection, requestID == id,
              admitCurrentRequest() else { return }
        connection.start(queue: .main)
    }

    private func receiveNext(_ connection: NWConnection, id: UUID) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 8 * 1024
        ) { [weak self, weak connection] data, _, complete, error in
            guard let connection else { return }
            DispatchQueue.main.async { [weak self, weak connection] in
                guard let self, let connection,
                      self.socket === connection,
                      self.requestID == id else {
                    return
                }
                guard self.admitCurrentRequest() else { return }
                guard !complete, error == nil else {
                    self.stop(reason: "Audio connection ended")
                    return
                }
                do {
                    if let data, !data.isEmpty {
                        for packet in try self.parser.feed(data) {
                            guard self.socket === connection, self.requestID == id,
                                  self.admitCurrentRequest() else { return }
                            try self.accept(packet, sessionID: id)
                        }
                    }
                    // enqueue can synchronously fail/tear down an owner. Do
                    // not rearm an old socket after that same-batch callback.
                    guard self.socket === connection, self.requestID == id,
                          self.admitCurrentRequest() else { return }
                    self.receiveNext(connection, id: id)
                } catch {
                    guard self.socket === connection, self.requestID == id else { return }
                    self.stop(reason: "Malformed computer audio stream")
                }
            }
        }
    }

    private func accept(_ packet: PeelAudioPacket, sessionID: UUID) throws {
        guard requestID == sessionID, admitCurrentRequest() else { return }

        let accepted: Bool
        switch mode {
        case .playback:
            if packet.kind == .format, !playback.isStarted {
                try playback.start(sessionID: sessionID)
            }
            guard requestID == sessionID, admitCurrentRequest() else { return }
            accepted = playback.enqueue(packet, sessionID: sessionID)
        case .voice:
            if packet.kind == .format, !voice.isStarted {
                // The format can only arrive after the verified challenge,
                // ticket, and TLS socket are ready. Start the shared engine
                // only at this point, so the input tap cannot run earlier.
                guard proved, socketReady else {
                    throw PeelClientAudioControllerError.voicePrerequisiteMissing
                }
                downlinkFormatReady = true
                try startVoice(sessionID: sessionID)
            }
            guard requestID == sessionID, admitCurrentRequest() else { return }
            accepted = voice.enqueueDownlink(packet, sessionID: sessionID)
        }

        // Both owners report fatal enqueue failures synchronously on main.
        // Old batch packets cannot refresh clocks/status after that teardown.
        guard requestID == sessionID, validSession() else { return }
        if packet.kind == .pcm {
            // A bounded playback admission drop does not mean the transport
            // timed out. Keep the liveness clock tied to valid received PCM.
            let now = DispatchTime.now().uptimeNanoseconds
            lastDataAt = now
            if accepted {
                if let recovery {
                    guard recovery.newRequestID == sessionID,
                          recoveryContextCurrent(recovery), now < recovery.deadline else {
                        stop(reason: "Computer audio restart timed out")
                        return
                    }
                    self.recovery = nil
                }
                lastDownlinkAdmittedAt = now
                setPlaying(true)
                switch mode {
                case .voice:
                    session?.systemAudioStatus = hostStreamingReason ?? "Voice audio active"
                case .playback:
                    session?.systemAudioStatus = "Receiving system audio"
                }
            }
        }
    }

    private func startVoice(sessionID: UUID) throws {
        guard requestID == sessionID, admitCurrentRequest() else {
            throw PeelClientAudioControllerError.voicePrerequisiteMissing
        }
        if recovery != nil {
            guard #available(iOS 17.0, visionOS 26.0, *),
                  PeelVoiceAudioOwner.hasRecordPermission else {
                stop(reason: "Voice restart requires microphone permission")
                throw PeelClientAudioControllerError.voicePrerequisiteMissing
            }
        }
        guard mode == .voice,
              downlinkFormatReady,
              proved,
              socketReady,
              let writer = uplinkWriter else {
            throw PeelClientAudioControllerError.voicePrerequisiteMissing
        }

        try voice.start(
            sessionID: sessionID,
            onUplink: { packet in
                writer.offer(packet)
            },
            onFailure: { [weak self] failure in
                // VoiceOwner owns this callback on main, including its worker
                // handoff. Preserve synchronous downlink failure fencing.
                guard let self, self.requestID == sessionID,
                      self.mode == .voice else { return }
                self.handleVoiceFailure(failure)
            }
        )
    }

    private func handleVoiceFailure(_ failure: PeelVoiceAudioFailure) {
        // A full bounded writer is expected under transient network pressure.
        // Drop that fresh packet and keep the live voice graph; malformed
        // protocol state, socket errors, and audio failures remain fatal.
        if failure == .packetSinkRejected {
            session?.systemAudioStatus = "Voice uplink busy; dropping fresh audio"
            return
        }
        if failure == .timelineDiscontinuity {
            recoverTimeline()
        } else {
            stop(reason: failure.localizedDescription)
        }
    }

    private func watch(_ id: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.requestID == id else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            guard self.validSession(),
                  now >= self.lastDataAt,
                  now - self.lastDataAt < 20_000_000_000 else {
                self.stop(reason: "Computer audio timed out")
                return
            }
            if let recovery = self.recovery {
                guard self.recoveryContextCurrent(recovery), now < recovery.deadline else {
                    self.stop(reason: "Computer audio restart timed out")
                    return
                }
            } else {
                guard now >= self.lastDownlinkAdmittedAt,
                      now - self.lastDownlinkAdmittedAt < 20_000_000_000 else {
                    self.stop(reason: "Computer audio playback stalled; turn audio on to retry")
                    return
                }
            }
            // Indicate playback only while PCM was admitted recently.
            self.setPlaying(now >= self.lastDownlinkAdmittedAt
                && now - self.lastDownlinkAdmittedAt < 5_000_000_000
                && (self.playback.isStarted || self.voice.isStarted))
            self.watch(id)
        }
    }

    /// Publishes only changes; PCM arrives far faster than the UI needs.
    private func setPlaying(_ playing: Bool) {
        guard let session, session.systemAudioPlaying != playing else { return }
        session.systemAudioPlaying = playing
    }
}
#endif
