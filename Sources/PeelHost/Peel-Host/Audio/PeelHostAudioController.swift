import Foundation
import ScreenCaptureKit
import CoreMedia
import Security

/// The main-thread policy/lifecycle owner. Capturing never starts from discovery,
/// an advertised pairing ID, or an unproved auxiliary socket.
final class PeelHostAudioController {
    private struct Request {
        let challenge: PeelAudioPairingChallengeMessage
        let session: PeelControlSession
        let deadline: UInt64
        var proved = false
        var prepared = false
    }
    private let network: HostNetworkServer
    private let keyForSession: (PeelControlSession) -> Data?
    private let voiceAllowed: (PeelControlSession) -> Bool
    private let onStatus: (String) -> Void
    private let onVoiceStatus: (String) -> Void
    private var request: Request?
    private var capture: PeelSystemAudioCapture?
    private var captureStarted = false
    private var stopping = false
    private var microphone: PeelRemoteMicrophoneSink?
    private var microphoneState: PeelRemoteMicrophoneSink.RouteState = .waitingForVoiceApp

    init(network: HostNetworkServer, keyForSession: @escaping (PeelControlSession) -> Data?,
         voiceAllowed: @escaping (PeelControlSession) -> Bool,
         onStatus: @escaping (String) -> Void,
         onVoiceStatus: @escaping (String) -> Void = { _ in }) {
        self.network = network
        self.keyForSession = keyForSession
        self.voiceAllowed = voiceAllowed
        self.onStatus = onStatus
        self.onVoiceStatus = onVoiceStatus
    }

    func receive(_ message: PeelAudioSessionRequest, session: PeelControlSession) {
        guard UUID(uuidString: message.requestId) != nil, network.isCurrentControlSession(session) else { return }
        if !message.enabled {
            guard request?.challenge.requestId == message.requestId, request?.session == session else { return }
            stop(reason: "Off")
            return
        }
        guard message.mode == nil || message.mode == "playback" || message.mode == "voice" else {
            send(message.requestId, session, "unavailable", reason: "Unsupported audio mode."); return
        }
        let isVoice = message.mode == "voice"
        if isVoice, !voiceAllowed(session) {
            onVoiceStatus("Off — enable remote microphone input and Mac audio in Peel Pro.")
            send(message.requestId, session, "unavailable", reason: "Enable remote microphone input in Peel Pro."); return
        }
        // Keep the one-owner guarantee through asynchronous or ambiguous capture stops.
        guard request == nil, capture == nil, !stopping else {
            if isVoice { onVoiceStatus("Voice unavailable: audio is already active or stopping.") }
            send(message.requestId, session, "unavailable", reason: "Audio is already active or stopping.")
            return
        }
        guard keyForSession(session) != nil, let nonce = randomToken() else {
            if isVoice { onVoiceStatus("Voice error: the paired session is not ready.") }
            send(message.requestId, session, "unavailable", reason: "Enable Mac system audio in Peel Pro.")
            return
        }
        let challenge = PeelAudioPairingChallengeMessage(requestId: message.requestId,
            pairingId: session.pairingID, nonce: nonce, expiresAt: Date().timeIntervalSince1970 + 10,
            mode: message.mode)
        request = Request(challenge: challenge, session: session,
                          deadline: DispatchTime.now().uptimeNanoseconds + 10_000_000_000)
        onStatus("Verifying paired device")
        if isVoice { onVoiceStatus("Starting Voice") }
        network.sendTargetedJSONLine(challenge, session: session) { [weak self] sent in
            guard let self, self.matches(message.requestId, session), !sent else { return }
            self.stop(reason: "Audio request could not be delivered")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.matches(message.requestId, session), self.request?.prepared == false else { return }
            self.stop(reason: "Audio verification expired")
        }
    }

    func receive(_ proof: PeelAudioPairingProofMessage, generation: UInt64) {
        guard var pending = request, !pending.proved,
              pending.session.generation == generation,
              pending.session.pairingID == proof.pairingId,
              pending.challenge.requestId == proof.requestId else { return }
        guard DispatchTime.now().uptimeNanoseconds < pending.deadline,
              let key = keyForSession(pending.session),
              PeelAudioPairingProof.verify(proof.proof, challenge: pending.challenge, key: key),
              let ticket = randomToken() else { stop(reason: "Audio pairing verification failed"); return }
        pending.proved = true
        request = pending
        if pending.challenge.mode == "voice" {
            guard voiceAllowed(pending.session) else { stop(reason: "Remote microphone input is off"); return }
            let id = proof.requestId
            let session = pending.session
            let sink = PeelRemoteMicrophoneSink(onState: { [weak self] state in
                DispatchQueue.main.async {
                    guard let self, self.matches(id, session) else { return }
                    self.microphoneState = state
                    self.reportVoiceState(id, session: session)
                }
            }, onFailure: { [weak self] error in
                DispatchQueue.main.async {
                    guard let self, self.matches(id, session) else { return }
                    self.stop(reason: error.localizedDescription, voiceStatus: Self.voiceStatus(for: error))
                }
            })
            microphone = sink
            microphoneState = .waitingForVoiceApp
            onStatus("Connecting remote microphone")
            onVoiceStatus("Starting Voice")
            sink.start { [weak self, weak sink] result in
                DispatchQueue.main.async {
                    guard let self, let sink, self.matches(id, session), self.microphone === sink else { return }
                    switch result {
                    case .success: self.prepare(ticket: ticket, requestID: id, session: session, sink: sink)
                    case .failure(let error):
                        self.stop(reason: error.localizedDescription, voiceStatus: Self.voiceStatus(for: error))
                    }
                }
            }
        } else {
            prepare(ticket: ticket, requestID: proof.requestId, session: pending.session, sink: nil)
        }
    }

    private func prepare(ticket: String, requestID: String, session: PeelControlSession,
                         sink: PeelRemoteMicrophoneSink?) {
        guard let pending = request, matches(requestID, session), pending.proved,
              DispatchTime.now().uptimeNanoseconds < pending.deadline,
              keyForSession(session) != nil,
              sink == nil || voiceAllowed(session) else { stop(reason: "Audio authorization ended"); return }
        let uplink: ((PeelAudioPacket) -> Bool)? = sink.map { owner in { owner.offer($0) } }
        guard network.audioChannel.install(requestID: requestID, session: session, ticket: ticket, uplink: uplink) else {
            stop(reason: "Audio session ended"); return
        }
        request?.prepared = true
        onStatus("Waiting for device audio")
        if sink != nil {
            reportVoiceState(requestID, session: session)
        }
        send(requestID, session, "ready", ticket: ticket)
    }

    func attached(_ requestID: String, session: PeelControlSession) {
        guard matches(requestID, session), request?.proved == true,
              keyForSession(session) != nil, capture == nil, !stopping else {
            network.audioChannel.invalidate(); return
        }
        onStatus("Starting Mac system audio")
        if request?.challenge.mode == "voice" { onVoiceStatus("Starting Voice") }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            DispatchQueue.main.async {
                guard let self, self.matches(requestID, session), self.keyForSession(session) != nil,
                      self.capture == nil, !self.stopping else { return }
                guard error == nil, let displays = content?.displays,
                      let display = displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? displays.first else {
                    self.stop(reason: "Mac system audio requires Screen Recording permission"); return
                }
                self.start(display, requestID: requestID, session: session)
            }
        }
    }

    func closed(_ requestID: String, session: PeelControlSession) {
        guard matches(requestID, session) else { return }
        stop(reason: "Audio connection ended")
    }

    func stop(reason: String, voiceStatus: String? = nil) {
        let previous = request
        let wasVoice = previous?.challenge.mode == "voice"
        request = nil
        captureStarted = false
        microphone?.stop()
        microphone = nil
        network.audioChannel.invalidate()
        onStatus(reason)
        if wasVoice {
            onVoiceStatus(voiceStatus ?? Self.voiceStatus(for: reason))
        }
        guard !stopping else { return }
        guard let capture else {
            if let previous {
                send(previous.challenge.requestId, previous.session, "stopped", reason: reason)
            }
            return
        }
        // Preserve the first owned request/session even if closing the audio
        // socket reaches closed() before its enabled:false control message.
        stopping = true
        capture.stop { [weak self, weak capture] result in
            DispatchQueue.main.async {
                guard let self, self.capture === capture else { return }
                self.stopping = false
                switch result {
                case .success:
                    self.capture = nil
                    // New request admission is available before the receipt.
                    if let previous {
                        self.send(previous.challenge.requestId, previous.session, "stopped", reason: reason)
                    }
                case .failure:
                    // Retain the owner; toggling off retries a caller-directed stop.
                    self.onStatus("Audio could not stop cleanly. Turn audio off to retry.")
                    if let previous {
                        self.send(previous.challenge.requestId, previous.session, "unavailable",
                                  reason: "Audio could not stop cleanly. Turn audio off to retry.")
                    }
                    if wasVoice {
                        self.onVoiceStatus("Voice error: audio could not stop cleanly. Turn Voice off to retry.")
                    }
                }
            }
        }
    }

    private func start(_ display: SCDisplay, requestID: String, session: PeelControlSession) {
        let channel = network.audioChannel!
        let owner = PeelSystemAudioCapture(onChunk: { chunk in
            let timestamp = CMTimeConvertScale(chunk.presentationTime, timescale: 48_000, method: .roundTowardZero)
            guard timestamp.isNumeric, timestamp.value >= 0,
                  let packet = try? PeelAudioPacket(pcmFor: .macToClient,
                    sequence: chunk.sequenceNumber, sampleTime: timestamp.value,
                    payload: chunk.interleavedStereoS16LE) else { return .stopCapture }
            return channel.offer(packet, requestID: requestID, session: session) ? .accepted : .backpressured
        }, onFailure: { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.matches(requestID, session) else { return }
                self.stop(reason: "Mac system audio stopped")
            }
        })
        capture = owner
        owner.start(display: display) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.matches(requestID, session) else { return }
                switch result {
                case .success:
                    guard self.keyForSession(session) != nil else { self.stop(reason: "Audio session ended"); return }
                    self.captureStarted = true
                    self.onStatus("Streaming Mac system audio")
                    if self.microphone != nil {
                        self.reportVoiceState(requestID, session: session)
                    } else {
                        self.send(requestID, session, "streaming")
                    }
                case .failure: self.stop(reason: "Mac system audio could not start")
                }
            }
        }
    }

    private func reportVoiceState(_ requestID: String, session: PeelControlSession) {
        let reason = microphoneState == .ready
            ? "Peel Remote Microphone is in use"
            : "Driver ready; select Peel Remote Microphone in your Mac voice app"
        onVoiceStatus(reason)
        // Streaming means the downlink capture has started, not proof the voice
        // app heard the microphone. The route-specific reason stays explicit.
        if captureStarted { send(requestID, session, "streaming", reason: reason) }
    }

    private static func voiceStatus(for error: PeelRemoteMicrophoneSink.SinkError) -> String {
        switch error {
        case .driverMissing:
            return error.localizedDescription
        case .authorizationFailed:
            return "Voice error: \(error.localizedDescription)"
        case .connectionEnded:
            return "Disconnected"
        }
    }

    private static func voiceStatus(for reason: String) -> String {
        switch reason {
        case "Off", "Remote microphone input is off":
            return "Off"
        case "Audio connection ended", "Audio session ended", "Audio request could not be delivered":
            return "Disconnected"
        default:
            return reason.hasPrefix("Voice") ? reason : "Voice error: \(reason)"
        }
    }

    private func matches(_ requestID: String, _ session: PeelControlSession) -> Bool {
        request?.challenge.requestId == requestID && request?.session == session
    }

    private func send(_ id: String, _ session: PeelControlSession, _ status: String,
                      reason: String? = nil, ticket: String? = nil) {
        network.sendTargetedJSONLine(PeelAudioSessionState(requestId: id, pairingId: session.pairingID,
            status: status, reason: reason, ticket: ticket), session: session) { _ in }
    }

    private func randomToken() -> String? {
        var data = Data(count: 32)
        let result = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        return result == errSecSuccess ? data.base64EncodedString() : nil
    }
}
