//
//  PeelSourceMediaController.swift
//  Peel
//
//  Client side of source media v1. Every request goes to the streamed source
//  computer over the owning session's current paired control connection and
//  names the stream window it was tapped in. Nothing here reads or changes
//  this device's audio output, media session or system volume.
//

import Foundation

/// Visibility preferences for streamed-window chrome. Hiding a group changes
/// only what is drawn; playback, source state and permissions are untouched.
nonisolated enum PeelSourceControlsVisibility {
    static let showVolumeKey = "peel.controls.showVolume"
    static let showMediaControlsKey = "peel.controls.showMediaControls"
}

/// The one place the source volume scope is chosen. Volume and mute change
/// the source computer's own system output; Listen separately controls Peel
/// playback on this device. Volume stays disabled unless the source also
/// advertises `source-volume-v1`.
nonisolated enum PeelSourceVolumeScopeSelection {
    static let selected: PeelSourceVolumeScope? = .systemOutput
}

// MARK: - Request bookkeeping

/// Identity a reply must echo exactly to resolve a request.
nonisolated struct PeelSourceMediaBinding: Equatable, Sendable {
    let pairingId: String
    let windowId: UInt32
    /// Owning session's control-connection epoch when the request was made.
    let epoch: UInt64
}

nonisolated enum PeelSourceMediaRequestKind: Equatable, Sendable {
    case media(PeelSourceMediaAction)
    case volumeQuery(PeelSourceVolumeScope)
    case volumeSet(PeelSourceVolumeScope)

    var volumeScope: PeelSourceVolumeScope? {
        switch self {
        case .media: return nil
        case .volumeQuery(let scope), .volumeSet(let scope): return scope
        }
    }
}

nonisolated struct PeelSourceMediaPendingRequest: Equatable, Sendable {
    let requestId: String
    let kind: PeelSourceMediaRequestKind
    let binding: PeelSourceMediaBinding
    let deadline: TimeInterval
}

/// Actual source volume state admitted from a valid `sourceVolumeState`.
/// Values the source could not read stay nil.
nonisolated struct PeelSourceVolumeSnapshot: Equatable, Sendable {
    let scope: PeelSourceVolumeScope
    let supported: Bool
    let canSetVolume: Bool
    let canSetMute: Bool
    let volume: Double?
    let muted: Bool?
    let sequence: UInt64
    let reason: PeelSourceMediaReason?

    init?(_ state: PeelSourceVolumeState) {
        guard state.isValid, let scope = PeelSourceVolumeScope(rawValue: state.scope) else { return nil }
        self.scope = scope
        supported = state.supported
        canSetVolume = state.supported && state.canSetVolume
        canSetMute = state.supported && state.canSetMute
        volume = state.volume
        muted = state.muted
        sequence = state.sequence
        reason = state.reason.flatMap(PeelSourceMediaReason.init(rawValue:))
    }

    /// A slider needs a known starting value as well as permission.
    var canAdjustVolume: Bool { canSetVolume && volume != nil }
    /// A mute toggle needs to know which way it is toggling.
    var canToggleMute: Bool { canSetMute && muted != nil }
}

nonisolated enum PeelSourceMediaResolution: Equatable, Sendable {
    case ack(PeelSourceMediaStatus, PeelSourceMediaReason?)
    /// nil when the state's sequence is not newer than one already admitted;
    /// the request still resolves but the older value is not shown.
    case state(PeelSourceVolumeSnapshot?)
}

/// Bounded pending table for one owning session. Replies resolve a request
/// only when request ID, pairing, window and connection epoch all match and
/// the deadline has not passed. Anything else is ignored.
nonisolated struct PeelSourceMediaLedger: Sendable {
    let maximumPending: Int
    let timeout: TimeInterval
    private(set) var pending: [String: PeelSourceMediaPendingRequest] = [:]
    private var lastSequence: [SequenceKey: UInt64] = [:]

    nonisolated private struct SequenceKey: Hashable, Sendable {
        let windowId: UInt32
        let scope: PeelSourceVolumeScope
    }

    init(maximumPending: Int = PeelSourceMediaProtocol.clientMaximumPending,
         timeout: TimeInterval = PeelSourceMediaProtocol.clientTimeoutSeconds) {
        self.maximumPending = maximumPending
        self.timeout = timeout
    }

    /// Registers a request, or returns nil when the table is full or the
    /// identity cannot be sent.
    mutating func begin(_ kind: PeelSourceMediaRequestKind, binding: PeelSourceMediaBinding,
                        requestId: UUID, now: TimeInterval) -> PeelSourceMediaPendingRequest? {
        guard now.isFinite, (now + timeout).isFinite,
              PeelSourceMediaProtocol.isPairingID(binding.pairingId) else { return nil }
        let id = requestId.uuidString
        guard pending.count < maximumPending, pending[id] == nil else { return nil }
        let request = PeelSourceMediaPendingRequest(requestId: id, kind: kind, binding: binding,
                                                    deadline: now + timeout)
        pending[id] = request
        return request
    }

    /// Removes a request without a reply (timeout or failed send).
    @discardableResult
    mutating func remove(requestId: String) -> PeelSourceMediaPendingRequest? {
        pending.removeValue(forKey: requestId)
    }

    /// Cancels every request for a window whose stream ended; later replies
    /// for them are unmatched. A reopened stream starts a fresh sequence.
    mutating func removeAll(windowId: UInt32) {
        pending = pending.filter { $0.value.binding.windowId != windowId }
        lastSequence = lastSequence.filter { $0.key.windowId != windowId }
    }

    func hasPending(windowId: UInt32, where matches: (PeelSourceMediaRequestKind) -> Bool) -> Bool {
        pending.values.contains { $0.binding.windowId == windowId && matches($0.kind) }
    }

    mutating func resolve(_ ack: PeelSourceMediaAck, epoch: UInt64,
                          now: TimeInterval) -> (PeelSourceMediaPendingRequest, PeelSourceMediaResolution)? {
        guard let parsed = ack.parsed,
              let request = admit(requestId: ack.requestId, pairingId: ack.pairingId,
                                  windowId: ack.windowId, epoch: epoch, now: now) else { return nil }
        return (request, .ack(parsed.status, parsed.reason))
    }

    /// Only a volume request for the same scope can be resolved by state.
    /// Unsolicited state (no request ID) is not admitted in v1.
    mutating func resolve(_ state: PeelSourceVolumeState, epoch: UInt64,
                          now: TimeInterval) -> (PeelSourceMediaPendingRequest, PeelSourceMediaResolution)? {
        guard let snapshot = PeelSourceVolumeSnapshot(state),
              let requestId = state.requestId,
              pending[requestId]?.kind.volumeScope == snapshot.scope,
              let request = admit(requestId: requestId, pairingId: state.pairingId,
                                  windowId: state.windowId, epoch: epoch, now: now) else { return nil }
        let key = SequenceKey(windowId: request.binding.windowId, scope: snapshot.scope)
        if let last = lastSequence[key], snapshot.sequence <= last {
            return (request, .state(nil))
        }
        lastSequence[key] = snapshot.sequence
        return (request, .state(snapshot))
    }

    /// Forget everything; used when the control connection or epoch changes.
    mutating func reset() {
        pending.removeAll()
        lastSequence.removeAll()
    }

    private mutating func admit(requestId: String, pairingId: String, windowId: UInt32,
                                epoch: UInt64, now: TimeInterval) -> PeelSourceMediaPendingRequest? {
        // A late reply stays unmatched; the request's own timer reports it.
        guard let request = pending[requestId], now.isFinite, now < request.deadline,
              request.binding == PeelSourceMediaBinding(pairingId: pairingId, windowId: windowId,
                                                        epoch: epoch) else { return nil }
        pending.removeValue(forKey: requestId)
        return request
    }
}

#if os(iOS) || os(visionOS)

import Combine
import Network

nonisolated enum PeelSourceMediaOutcome: Equatable, Sendable {
    /// The source posted the media key. Not proof that anything played.
    case sent(PeelSourceMediaAction)
    case refused(PeelSourceMediaStatus, PeelSourceMediaReason?)
    case noResponse
    /// Too many requests are already waiting for this computer.
    case busy
}

nonisolated struct PeelSourceMediaFeedback: Equatable, Sendable, Identifiable {
    let id = UUID()
    let outcome: PeelSourceMediaOutcome
}

nonisolated struct PeelSourceMediaWindowState: Equatable, Sendable {
    var volume: PeelSourceVolumeSnapshot?
    var isCheckingVolume = false
    var volumeFeedback: PeelSourceMediaFeedback?
    var mediaFeedback: PeelSourceMediaFeedback?
}

/// One per PeelHostSession. Window views pass their exact owning session and
/// stream window; the controller never consults the browser's selection and
/// never activates or focuses a window to send a request.
@MainActor
final class PeelSourceMediaController: ObservableObject {
    weak var session: PeelHostSession?

    @Published private(set) var windowStates: [UInt32: PeelSourceMediaWindowState] = [:]

    private var ledger = PeelSourceMediaLedger()
    private weak var ledgerConnection: NWConnection?
    private var ledgerEpoch: UInt64?
    /// Latest requested change while another volume request is in flight. It
    /// keeps the exact target it was made for and is dropped, never rebound,
    /// if that connection, epoch, pairing or stream is gone when it would run.
    private struct QueuedVolumeChange {
        let binding: PeelSourceMediaBinding
        weak var connection: NWConnection?
        var volume: Double?
        var muted: Bool?
    }
    private var queuedVolumeChanges: [UInt32: QueuedVolumeChange] = [:]

    init(session: PeelHostSession) {
        self.session = session
    }

    // MARK: Availability

    var sourceOffersMediaKeys: Bool {
        session?.hostCapabilities.contains(PeelSourceMediaProtocol.mediaKeysCapability) == true
    }

    /// The selected scope when the source offers volume control; otherwise nil.
    var volumeScope: PeelSourceVolumeScope? {
        guard let scope = PeelSourceVolumeScopeSelection.selected,
              session?.hostCapabilities.contains(PeelSourceMediaProtocol.volumeCapability) == true else {
            return nil
        }
        return scope
    }

    func canSendMedia(windowId: UInt32) -> Bool {
        sourceOffersMediaKeys && currentRoute(windowId: windowId) != nil
    }

    func canUseVolume(windowId: UInt32) -> Bool {
        volumeScope != nil && currentRoute(windowId: windowId) != nil
    }

    func state(for windowId: UInt32) -> PeelSourceMediaWindowState {
        windowStates[windowId] ?? PeelSourceMediaWindowState()
    }

    /// Admitted source state, shown only while the window is still an eligible
    /// stream on the connection that produced it.
    func volumeSnapshot(windowId: UInt32) -> PeelSourceVolumeSnapshot? {
        guard let scope = volumeScope,
              let route = currentRoute(windowId: windowId),
              route.connection === ledgerConnection, route.binding.epoch == ledgerEpoch,
              let snapshot = windowStates[windowId]?.volume, snapshot.scope == scope else { return nil }
        return snapshot
    }

    // MARK: Requests

    @discardableResult
    func perform(_ action: PeelSourceMediaAction, windowId: UInt32) -> Bool {
        guard sourceOffersMediaKeys, let route = currentRoute(windowId: windowId) else { return false }
        let requestId = UUID()
        guard let request = begin(.media(action), route: route, requestId: requestId) else {
            updateWindow(windowId) { $0.mediaFeedback = PeelSourceMediaFeedback(outcome: .busy) }
            return false
        }
        let message = PeelSourceMediaCommand(requestId: requestId, pairingId: route.binding.pairingId,
                                             windowId: windowId, action: action)
        return send(message, on: route.connection, for: request)
    }

    /// Reads actual source state. Called when controls or the volume popover
    /// appear; there is no repeating refresh.
    @discardableResult
    func refreshVolume(windowId: UInt32) -> Bool {
        guard let scope = volumeScope, let route = currentRoute(windowId: windowId),
              !hasVolumeRequest(windowId: windowId) else { return false }
        let requestId = UUID()
        guard let request = begin(.volumeQuery(scope), route: route, requestId: requestId) else { return false }
        updateWindow(windowId) { $0.isCheckingVolume = true }
        let message = PeelSourceVolumeQuery(requestId: requestId, pairingId: route.binding.pairingId,
                                            windowId: windowId, scope: scope)
        return send(message, on: route.connection, for: request)
    }

    /// Out-of-range or non-finite values are refused, never clamped.
    @discardableResult
    func setVolume(_ volume: Double, windowId: UInt32) -> Bool {
        guard PeelSourceMediaProtocol.isVolume(volume) else { return false }
        return requestVolumeChange(volume: volume, muted: nil, windowId: windowId)
    }

    @discardableResult
    func setMuted(_ muted: Bool, windowId: UInt32) -> Bool {
        requestVolumeChange(volume: nil, muted: muted, windowId: windowId)
    }

    func clearFeedback(windowId: UInt32, id: UUID) {
        guard var state = windowStates[windowId] else { return }
        if state.mediaFeedback?.id == id { state.mediaFeedback = nil }
        if state.volumeFeedback?.id == id { state.volumeFeedback = nil }
        windowStates[windowId] = state
    }

    // MARK: Session hooks

    /// The session's control connection or epoch changed. Pending requests
    /// and every state learned on an older epoch are dropped; work already
    /// begun on the current epoch is kept.
    func controlConnectionDidChange() {
        guard ledgerEpoch != session?.sourceMediaControlEpoch else { return }
        resetAll()
    }

    /// The session stopped streaming these windows. Their pending requests,
    /// queued changes and shown state end with the stream.
    func streamsDidEnd(_ windowIds: Set<UInt32>) {
        for windowId in windowIds {
            ledger.removeAll(windowId: windowId)
            queuedVolumeChanges[windowId] = nil
            if windowStates[windowId] != nil { windowStates[windowId] = nil }
        }
    }

    private func resetAll() {
        ledger.reset()
        ledgerConnection = nil
        ledgerEpoch = nil
        queuedVolumeChanges.removeAll()
        if !windowStates.isEmpty { windowStates.removeAll() }
    }

    func receive(_ ack: PeelSourceMediaAck, sourceConnection: NWConnection) {
        guard let epoch = admittedEpoch(sourceConnection),
              let resolved = ledger.resolve(ack, epoch: epoch, now: Self.now()) else { return }
        apply(resolved.1, to: resolved.0)
    }

    func receive(_ state: PeelSourceVolumeState, sourceConnection: NWConnection) {
        guard let epoch = admittedEpoch(sourceConnection),
              let resolved = ledger.resolve(state, epoch: epoch, now: Self.now()) else { return }
        apply(resolved.1, to: resolved.0)
    }

    // MARK: Private

    private struct Route {
        let connection: NWConnection
        let binding: PeelSourceMediaBinding
    }

    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    /// The owning session's current paired, visible control connection and a
    /// window it is actually streaming. No route means no request.
    private func currentRoute(windowId: UInt32) -> Route? {
        guard let session, session.isConnectionReady, session.isClientVisible,
              let connection = session.connection,
              let pairingId = session.activePairingID,
              PeelSourceMediaProtocol.isPairingID(pairingId),
              session.browser?.pairedPeer(forPairingID: pairingId)?.id == pairingId,
              isStreaming(windowId: windowId) else { return nil }
        return Route(connection: connection,
                     binding: PeelSourceMediaBinding(pairingId: pairingId, windowId: windowId,
                                                     epoch: session.sourceMediaControlEpoch))
    }

    private func isStreaming(windowId: UInt32) -> Bool {
        guard let session else { return false }
        return session.desiredPullWindowIds.contains(windowId) && session.videoReadyWindowIds.contains(windowId)
    }

    private func admittedEpoch(_ sourceConnection: NWConnection) -> UInt64? {
        guard let session, session.connection === sourceConnection, session.isConnectionReady,
              ledgerConnection === sourceConnection, let ledgerEpoch,
              session.sourceMediaControlEpoch == ledgerEpoch else { return nil }
        return ledgerEpoch
    }

    private func hasVolumeRequest(windowId: UInt32) -> Bool {
        ledger.hasPending(windowId: windowId) { $0.volumeScope != nil }
    }

    private func begin(_ kind: PeelSourceMediaRequestKind, route: Route,
                       requestId: UUID) -> PeelSourceMediaPendingRequest? {
        if ledgerConnection !== route.connection || ledgerEpoch != route.binding.epoch {
            resetAll()
            ledgerConnection = route.connection
            ledgerEpoch = route.binding.epoch
        }
        guard let request = ledger.begin(kind, binding: route.binding, requestId: requestId,
                                         now: Self.now()) else { return nil }
        let id = request.requestId
        DispatchQueue.main.asyncAfter(deadline: .now() + ledger.timeout) { [weak self] in
            self?.expire(requestId: id)
        }
        return request
    }

    private func send<Message: Encodable>(_ message: Message, on connection: NWConnection,
                                          for request: PeelSourceMediaPendingRequest) -> Bool {
        guard session?.connection === connection,
              let data = try? JSONEncoder().encode(message),
              data.count < PeelSourceMediaProtocol.maximumLineBytes else {
            ledger.remove(requestId: request.requestId)
            finishVolumeRequestIfNeeded(windowId: request.binding.windowId)
            return false
        }
        var line = data
        line.append(0x0A)
        connection.send(content: line, completion: .contentProcessed { _ in })
        return true
    }

    private func requestVolumeChange(volume: Double?, muted: Bool?, windowId: UInt32) -> Bool {
        guard volume != nil || muted != nil,
              let scope = volumeScope, let route = currentRoute(windowId: windowId),
              let snapshot = volumeSnapshot(windowId: windowId), snapshot.supported,
              volume == nil || snapshot.canSetVolume,
              muted == nil || snapshot.canSetMute else { return false }

        if hasVolumeRequest(windowId: windowId) {
            // Merge only into a change made for this exact target.
            var queued = QueuedVolumeChange(binding: route.binding, connection: route.connection)
            if let existing = queuedVolumeChanges[windowId],
               existing.binding == route.binding, existing.connection === route.connection {
                queued = existing
            }
            let priorVolume = queued.volume
            let priorMuted = queued.muted
            queued.volume = volume ?? priorVolume
            queued.muted = muted ?? priorMuted
            queuedVolumeChanges[windowId] = queued
            return true
        }

        let requestId = UUID()
        guard let request = begin(.volumeSet(scope), route: route, requestId: requestId) else {
            updateWindow(windowId) { $0.volumeFeedback = PeelSourceMediaFeedback(outcome: .busy) }
            return false
        }
        updateWindow(windowId) { $0.isCheckingVolume = true }
        let message = PeelSourceVolumeSet(requestId: requestId, pairingId: route.binding.pairingId,
                                          windowId: windowId, scope: scope, volume: volume, muted: muted)
        return send(message, on: route.connection, for: request)
    }

    private func apply(_ resolution: PeelSourceMediaResolution, to request: PeelSourceMediaPendingRequest) {
        let windowId = request.binding.windowId
        var readBack = false

        switch (request.kind, resolution) {
        case (.media(let action), .ack(let status, let reason)):
            let outcome: PeelSourceMediaOutcome = status == .applied ? .sent(action) : .refused(status, reason)
            updateWindow(windowId) { $0.mediaFeedback = PeelSourceMediaFeedback(outcome: outcome) }

        case (.volumeQuery, .ack(let status, let reason)):
            // The source could not report state; nothing known remains shown,
            // and a change queued against that state is cancelled.
            queuedVolumeChanges[windowId] = nil
            updateWindow(windowId) {
                $0.volume = nil
                $0.volumeFeedback = PeelSourceMediaFeedback(outcome: .refused(status, reason))
            }

        case (.volumeSet, .ack(.applied, _)):
            // An applied set is not a state report. The last reported state
            // stays marked as checking while the actual state is read back.
            updateWindow(windowId) { $0.volumeFeedback = nil }
            readBack = true

        case (.volumeSet, .ack(let status, let reason)):
            // Refused, stale or invalid: cancel what was queued behind it.
            queuedVolumeChanges[windowId] = nil
            updateWindow(windowId) {
                $0.volumeFeedback = PeelSourceMediaFeedback(outcome: .refused(status, reason))
            }

        case (_, .state(let snapshot)):
            if let snapshot {
                updateWindow(windowId) {
                    $0.volume = snapshot
                    $0.volumeFeedback = nil
                }
            }
        }

        guard isStreaming(windowId: windowId) else {
            queuedVolumeChanges[windowId] = nil
            windowStates[windowId] = nil
            return
        }
        finishVolumeRequestIfNeeded(windowId: windowId)
        if readBack {
            // A queued change waits for the read-back state it is based on.
            if !refreshVolume(windowId: windowId) {
                queuedVolumeChanges[windowId] = nil
                updateWindow(windowId) { $0.volume = nil }
            }
        } else if queuedVolumeChanges[windowId] != nil {
            flushQueuedVolumeChange(windowId: windowId)
        }
    }

    private func expire(requestId: String) {
        guard let request = ledger.remove(requestId: requestId) else { return }
        let windowId = request.binding.windowId
        queuedVolumeChanges[windowId] = nil
        switch request.kind {
        case .media:
            updateWindow(windowId) { $0.mediaFeedback = PeelSourceMediaFeedback(outcome: .noResponse) }
        case .volumeQuery, .volumeSet:
            // Whether an unanswered set took effect is unknown.
            updateWindow(windowId) {
                $0.volume = nil
                $0.volumeFeedback = PeelSourceMediaFeedback(outcome: .noResponse)
            }
        }
        finishVolumeRequestIfNeeded(windowId: windowId)
    }

    private func flushQueuedVolumeChange(windowId: UInt32) {
        guard let change = queuedVolumeChanges.removeValue(forKey: windowId) else { return }
        // Runs only against the exact target it was queued for.
        guard let connection = change.connection,
              let route = currentRoute(windowId: windowId),
              route.binding == change.binding, route.connection === connection,
              connection === ledgerConnection, change.binding.epoch == ledgerEpoch else {
            finishVolumeRequestIfNeeded(windowId: windowId)
            return
        }
        if !requestVolumeChange(volume: change.volume, muted: change.muted, windowId: windowId) {
            finishVolumeRequestIfNeeded(windowId: windowId)
        }
    }

    private func finishVolumeRequestIfNeeded(windowId: UInt32) {
        let checking = hasVolumeRequest(windowId: windowId)
        guard (windowStates[windowId]?.isCheckingVolume ?? false) != checking else { return }
        updateWindow(windowId) { $0.isCheckingVolume = checking }
    }

    private func updateWindow(_ windowId: UInt32, _ change: (inout PeelSourceMediaWindowState) -> Void) {
        var state = windowStates[windowId] ?? PeelSourceMediaWindowState()
        change(&state)
        windowStates[windowId] = state
    }
}

#endif
