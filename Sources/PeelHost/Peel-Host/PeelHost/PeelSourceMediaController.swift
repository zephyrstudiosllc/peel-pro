//
//  PeelSourceMediaController.swift
//  Peel-Host
//
//  Source media v1 on this Mac: paired-user media keys and this Mac's
//  system output volume/mute from the current control session. The
//  peelStream scope stays unsupported.
//

import Foundation

/// Authority facts read by PeelHost at receipt and again immediately before
/// the OS effect. `session` is nil when the generation is not the current,
/// still-paired control session; nothing is replied then.
struct PeelSourceMediaGate {
    let session: PeelControlSession?
    let lockedOrAsleep: Bool
    let clientVisible: Bool
    let controlEnabled: Bool
    let accessibilityTrusted: Bool
}

enum PeelSourceMediaKeyPostResult: Equatable {
    /// Both key-down and key-up were posted to the OS event stream.
    case posted
    /// The OS does not allow this process to post events.
    case accessDenied
    /// The events could not be created; nothing was posted.
    case unavailable
}

protocol PeelSourceMediaKeyPosting {
    /// Posts exactly one down/up pair or nothing.
    func post(_ action: PeelSourceMediaAction) -> PeelSourceMediaKeyPostResult
}

/// Actual state of this Mac's current default output. `device` is an opaque
/// CoreAudio object identity, never sent on the wire; nil means no output.
struct PeelSourceVolumeReading: Equatable {
    let device: UInt32?
    let volume: Double?
    let muted: Bool?
    let canSetVolume: Bool
    let canSetMute: Bool
}

enum PeelSourceVolumeApplyResult: Equatable {
    /// The OS accepted every requested write; the reading is re-read afterwards.
    case applied(PeelSourceVolumeReading)
    /// The default output differs from the admitted device (before or after writing).
    case deviceChanged
    case noOutputDevice
    /// A requested control is missing or read-only; nothing was written.
    case notSettable
    /// The OS refused a write; the device may be partially changed.
    case failed
}

protocol PeelSourceVolumeControlling {
    /// The current default output device, read fresh.
    func currentDevice() -> UInt32?
    /// Actual state of the current default output, read fresh.
    func read() -> PeelSourceVolumeReading
    /// Writes only to `expectedDevice` while it is still the default output.
    func apply(volume: Double?, muted: Bool?, expectedDevice: UInt32) -> PeelSourceVolumeApplyResult
}

enum PeelSourceMediaReply {
    case ack(PeelSourceMediaAck)
    case volumeState(PeelSourceVolumeState)
}

final class PeelSourceMediaController {
    private let gate: (_ generation: UInt64) -> PeelSourceMediaGate
    private let keys: PeelSourceMediaKeyPosting
    private let volume: PeelSourceVolumeControlling
    private let send: (_ reply: PeelSourceMediaReply, _ session: PeelControlSession) -> Void
    private let schedule: (@escaping @MainActor @Sendable () -> Void) -> Void
    private let uptimeNanoseconds: () -> UInt64

    /// Bumped on every authority boundary; a pending effect from an older
    /// epoch is never applied.
    private var epoch: UInt64 = 0
    /// Windows the current session asked to stream (startStream, not yet stopped).
    private var requestedWindowIds = Set<UInt32>()
    /// Windows with an open video socket under the current control connection.
    private var socketWindowIds = Set<UInt32>()
    private var limiterSession: PeelControlSession?
    private var limitTimes: [Limit: [UInt64]] = [:]
    private var volumeSequence: UInt64 = 0

    init(gate: @escaping (_ generation: UInt64) -> PeelSourceMediaGate,
         keys: PeelSourceMediaKeyPosting,
         volume: PeelSourceVolumeControlling,
         send: @escaping (_ reply: PeelSourceMediaReply, _ session: PeelControlSession) -> Void,
         schedule: @escaping (@escaping @MainActor @Sendable () -> Void) -> Void = { work in
             DispatchQueue.main.async { work() }
         },
         uptimeNanoseconds: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.gate = gate
        self.keys = keys
        self.volume = volume
        self.send = send
        self.schedule = schedule
        self.uptimeNanoseconds = uptimeNanoseconds
    }

    // MARK: Lifecycle

    /// Disconnect, new connection or hello, revoke, lock/sleep or hidden client.
    func invalidate(clearStreams: Bool) {
        epoch &+= 1
        if clearStreams {
            requestedWindowIds.removeAll()
            socketWindowIds.removeAll()
        }
    }

    /// A stream is admitted only while both its start request and its video
    /// socket are current, so a socket alone never revives a stopped stream.
    func noteStreamStarted(windowId: UInt32) { requestedWindowIds.insert(windowId) }

    func noteStreamStopped(windowId: UInt32) {
        guard requestedWindowIds.remove(windowId) != nil else { return }
        epoch &+= 1
    }

    func noteStreamOpened(windowId: UInt32) { socketWindowIds.insert(windowId) }

    func noteStreamClosed(windowId: UInt32) {
        guard socketWindowIds.remove(windowId) != nil else { return }
        epoch &+= 1
    }

    // MARK: Receive

    /// `inputBlocked` is set by the router when its master remote-control gate
    /// refused the line; such a request is only ever answered with a refusal.
    func receive(type: String, data: Data, generation: UInt64, inputBlocked: Bool = false) {
        guard data.count <= PeelSourceMediaProtocol.maximumLineBytes,
              PeelSourceMediaProtocol.requestTypes.contains(type),
              let identity = try? JSONDecoder().decode(PeelSourceMediaRequestIdentity.self, from: data),
              identity.type == type, identity.isValid,
              let session = boundSession(identity, generation: generation) else { return }
        let decoder = JSONDecoder()
        switch type {
        case PeelSourceMediaProtocol.commandType:
            guard let message = try? decoder.decode(PeelSourceMediaCommand.self, from: data) else {
                reply(identity, session, .invalid); return
            }
            switch message.check() {
            case .refused(let status, let reason): reply(identity, session, status, reason)
            case .valid(let action):
                if inputBlocked { refuseBlockedInput(identity, session: session, generation: generation); return }
                admitMedia(action, identity: identity, session: session, generation: generation)
            }
        case PeelSourceMediaProtocol.volumeQueryType:
            guard let message = try? decoder.decode(PeelSourceVolumeQuery.self, from: data) else {
                reply(identity, session, .invalid); return
            }
            switch message.check() {
            case .refused(let status, let reason): reply(identity, session, status, reason)
            case .valid(let scope): admitVolumeQuery(scope, identity: identity, session: session, generation: generation)
            }
        case PeelSourceMediaProtocol.volumeSetType:
            guard let message = try? decoder.decode(PeelSourceVolumeSet.self, from: data) else {
                reply(identity, session, .invalid); return
            }
            switch message.check() {
            case .refused(let status, let reason): reply(identity, session, status, reason)
            case .valid(let change):
                if inputBlocked { refuseBlockedInput(identity, session: session, generation: generation); return }
                admitVolumeSet(change, identity: identity, session: session, generation: generation)
            }
        default:
            return
        }
    }

    // MARK: Media keys

    private func admitMedia(_ action: PeelSourceMediaAction, identity: PeelSourceMediaRequestIdentity,
                            session: PeelControlSession, generation: UInt64) {
        if let denial = refusal(identity, generation: generation, userInput: true) {
            reply(identity, session, denial.status, denial.reason); return
        }
        guard admit(.media, session: session) else {
            reply(identity, session, .denied, .rateLimited); return
        }
        let admittedEpoch = epoch
        schedule { [weak self] in
            guard let self else { return }
            // Execution-time recheck: same epoch, same session, same gates, same stream.
            guard let current = self.gate(generation).session, current == session else { return }
            if let denial = self.refusal(identity, generation: generation, userInput: true) {
                self.reply(identity, session, denial.status, denial.reason); return
            }
            guard self.epoch == admittedEpoch else { self.reply(identity, session, .stale); return }
            switch self.keys.post(action) {
            case .posted: self.reply(identity, session, .applied)
            case .accessDenied: self.reply(identity, session, .denied, .accessibilityMissing)
            case .unavailable: self.reply(identity, session, .failed, .osRefused)
            }
        }
    }

    // MARK: Volume (systemOutput only)

    /// Read-only: needs the bound session, visible client, unlocked Mac and
    /// an owned stream, but not Allow Control or Accessibility.
    private func admitVolumeQuery(_ scope: PeelSourceVolumeScope, identity: PeelSourceMediaRequestIdentity,
                                  session: PeelControlSession, generation: UInt64) {
        if let denial = refusal(identity, generation: generation, userInput: false) {
            reply(identity, session, denial.status, denial.reason); return
        }
        guard admit(.volumeQuery, session: session) else {
            reply(identity, session, .denied, .rateLimited); return
        }
        volumeSequence &+= 1
        guard scope == .systemOutput else {
            send(.volumeState(.unsupported(requestId: identity.requestId, pairingId: identity.pairingId,
                                           windowId: identity.windowId, scope: scope, sequence: volumeSequence)), session)
            return
        }
        send(.volumeState(state(identity, volume.read())), session)
    }

    /// Ordinary user input: same gates, epoch, stream ownership and queued
    /// recheck as media keys. The admitted output device is fenced too.
    private func admitVolumeSet(_ change: PeelSourceVolumeChange, identity: PeelSourceMediaRequestIdentity,
                                session: PeelControlSession, generation: UInt64) {
        if let denial = refusal(identity, generation: generation, userInput: true) {
            reply(identity, session, denial.status, denial.reason); return
        }
        guard admit(.volumeSet, session: session) else {
            reply(identity, session, .denied, .rateLimited); return
        }
        guard change.scope == .systemOutput else {
            reply(identity, session, .unsupported, .scopeUnsupported); return
        }
        guard let admittedDevice = volume.currentDevice() else {
            reply(identity, session, .failed, .noOutputDevice); return
        }
        let admittedEpoch = epoch
        schedule { [weak self] in
            guard let self else { return }
            guard let current = self.gate(generation).session, current == session else { return }
            if let denial = self.refusal(identity, generation: generation, userInput: true) {
                self.reply(identity, session, denial.status, denial.reason); return
            }
            guard self.epoch == admittedEpoch else { self.reply(identity, session, .stale); return }
            switch self.volume.apply(volume: change.volume, muted: change.muted, expectedDevice: admittedDevice) {
            case .applied(let reading):
                // Actual post-write state; never the requested values.
                self.volumeSequence &+= 1
                self.send(.volumeState(self.state(identity, reading)), session)
            case .deviceChanged: self.reply(identity, session, .stale)
            case .noOutputDevice: self.reply(identity, session, .failed, .noOutputDevice)
            case .notSettable: self.reply(identity, session, .unsupported, .fixedVolume)
            case .failed: self.reply(identity, session, .failed, .osRefused)
            }
        }
    }

    /// Caller increments `volumeSequence` first.
    private func state(_ identity: PeelSourceMediaRequestIdentity, _ reading: PeelSourceVolumeReading) -> PeelSourceVolumeState {
        guard reading.device != nil else {
            return .unsupported(requestId: identity.requestId, pairingId: identity.pairingId,
                                windowId: identity.windowId, scope: .systemOutput, sequence: volumeSequence,
                                reason: .noOutputDevice)
        }
        guard reading.volume != nil || reading.muted != nil else {
            return .unsupported(requestId: identity.requestId, pairingId: identity.pairingId,
                                windowId: identity.windowId, scope: .systemOutput, sequence: volumeSequence,
                                reason: .fixedVolume)
        }
        let canSetVolume = reading.canSetVolume && reading.volume != nil
        let canSetMute = reading.canSetMute && reading.muted != nil
        return PeelSourceVolumeState(requestId: identity.requestId, pairingId: identity.pairingId,
                                     windowId: identity.windowId, scope: .systemOutput, supported: true,
                                     canSetVolume: canSetVolume, canSetMute: canSetMute,
                                     volume: reading.volume, muted: reading.muted, sequence: volumeSequence,
                                     reason: canSetVolume || canSetMute ? nil : .fixedVolume)
    }

    // MARK: Authority

    private func refuseBlockedInput(_ identity: PeelSourceMediaRequestIdentity, session: PeelControlSession,
                                    generation: UInt64) {
        let denial = refusal(identity, generation: generation, userInput: true) ?? (status: .denied, reason: .controlOff)
        reply(identity, session, denial.status, denial.reason)
    }

    private func boundSession(_ identity: PeelSourceMediaRequestIdentity, generation: UInt64) -> PeelControlSession? {
        guard let session = gate(generation).session, session.generation == generation,
              session.pairingID == identity.pairingId else { return nil }
        return session
    }

    private func refusal(_ identity: PeelSourceMediaRequestIdentity, generation: UInt64,
                         userInput: Bool) -> (status: PeelSourceMediaStatus, reason: PeelSourceMediaReason)? {
        let facts = gate(generation)
        if facts.lockedOrAsleep { return (.denied, .locked) }
        if !facts.clientVisible { return (.denied, .notVisible) }
        if userInput, !facts.controlEnabled { return (.denied, .controlOff) }
        if userInput, !facts.accessibilityTrusted { return (.denied, .accessibilityMissing) }
        guard requestedWindowIds.contains(identity.windowId),
              socketWindowIds.contains(identity.windowId) else { return (.stale, .staleStream) }
        return nil
    }

    private enum Limit {
        case media, volumeSet, volumeQuery

        var perSecond: Int {
            switch self {
            case .media: return PeelSourceMediaProtocol.mediaActionsPerSecond
            case .volumeSet: return PeelSourceMediaProtocol.volumeSetsPerSecond
            case .volumeQuery: return PeelSourceMediaProtocol.volumeQueriesPerSecond
            }
        }
    }

    /// Sliding one-second window per control session; a new session starts empty.
    private func admit(_ kind: Limit, session: PeelControlSession) -> Bool {
        if limiterSession != session {
            limiterSession = session
            limitTimes.removeAll()
        }
        let now = uptimeNanoseconds()
        var times = (limitTimes[kind] ?? []).filter { now &- $0 < 1_000_000_000 }
        guard times.count < kind.perSecond else { limitTimes[kind] = times; return false }
        times.append(now)
        limitTimes[kind] = times
        return true
    }

    private func reply(_ identity: PeelSourceMediaRequestIdentity, _ session: PeelControlSession,
                       _ status: PeelSourceMediaStatus, _ reason: PeelSourceMediaReason? = nil) {
        send(.ack(PeelSourceMediaAck(requestId: identity.requestId, pairingId: identity.pairingId,
                                     windowId: identity.windowId, status: status, reason: reason)), session)
    }
}
