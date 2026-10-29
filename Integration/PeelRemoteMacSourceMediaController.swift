import Combine
import Foundation

/// Presentation-only preferences; hiding a group never changes playback,
/// Host state, grants or the microphone.
nonisolated enum PeelRemoteMacSourceMediaPreferences {
    static let showVolumeKey = "peel.controls.showVolume"
    static let showMediaControlsKey = "peel.controls.showMediaControls"
}

/// Current-stream facts supplied by PeelRemoteMacViewerController. No keys.
nonisolated struct PeelRemoteMacSourceMediaContext: Equatable, Sendable {
    let controlEpoch: UUID
    let pairingID: String
    /// Selected window whose stream has presented video.
    let windowID: UInt32
    let hostSupportsMediaKeys: Bool
    let hostSupportsVolume: Bool
    /// The viewer's existing explicit Control gate (Stop/Control Off closes it).
    let inputEnabled: Bool
}

/// Source media protocol v1 client for the Mac receiver's single stream
/// (see work/peel248-media-controls/source-media-contract.md). Commands target
/// the streamed source computer over the current paired control connection,
/// never the receiver's OS volume/media. Every request is bound to the
/// control epoch, pairing ID and window captured at tap time; replies that do
/// not match the still-current identity are ignored. Values shown are only
/// actual validated source replies; nothing is optimistic.
@MainActor
final class PeelRemoteMacSourceMediaController: ObservableObject {
    /// Source volume scope used by the volume UI: the SOURCE computer's actual
    /// system output volume/mute (root's stated contract interpretation).
    /// Listen On/Off separately controls only Peel playback on this Mac. The
    /// UI stays disabled until the source advertises source-volume-v1; there
    /// is no local fallback, and captured PCM is not assumed to follow it.
    static let selectedVolumeScope: PeelSourceVolumeScope? = .systemOutput

    struct Adapters {
        let context: () -> PeelRemoteMacSourceMediaContext?
        /// User-input sends go through the viewer's existing input gate and
        /// return false when it is closed.
        let sendCommand: (PeelSourceMediaCommand) -> Bool
        let sendVolumeSet: (PeelSourceVolumeSet) -> Bool
        /// Read-only query on the normal paired control connection.
        let sendVolumeQuery: (PeelSourceVolumeQuery) -> Bool
    }

    /// Actual source volume state for one stream identity.
    struct VolumeSnapshot: Equatable {
        let controlEpoch: UUID
        let pairingID: String
        let windowID: UInt32
        let scope: PeelSourceVolumeScope
        let supported: Bool
        let canSetVolume: Bool
        let canSetMute: Bool
        let volume: Double?
        let muted: Bool?
        let reason: PeelSourceMediaReason?
    }

    enum Availability: Equatable {
        case available
        /// Control is off; source controls are user input.
        case needsControl
        case unsupported
        case noStream
    }

    @Published private(set) var volumeSnapshot: VolumeSnapshot?
    /// Last refusal/timeout for the user; nil after success.
    @Published private(set) var lastMessage: String?
    @Published private(set) var pendingCount = 0

    private enum Kind: Equatable {
        case media(PeelSourceMediaAction)
        case volumeQuery(PeelSourceVolumeScope)
        case volumeSet(PeelSourceVolumeScope)
    }

    private struct Pending {
        let kind: Kind
        let controlEpoch: UUID
        let pairingID: String
        let windowID: UInt32
    }

    /// A volume/mute change bound to the stream identity and scope captured
    /// at tap time. It is sent only while that exact identity is current and
    /// is dropped, never re-targeted, once the identity changes.
    private struct QueuedSet: Equatable {
        let controlEpoch: UUID
        let pairingID: String
        let windowID: UInt32
        let scope: PeelSourceVolumeScope
        let volume: Double?
        let muted: Bool?

        func matches(_ context: PeelRemoteMacSourceMediaContext) -> Bool {
            controlEpoch == context.controlEpoch && pairingID == context.pairingID
                && windowID == context.windowID && scope == PeelRemoteMacSourceMediaController.selectedVolumeScope
        }
    }

    private let adapters: Adapters
    private var pending: [UUID: Pending] = [:]
    private var queuedSet: QueuedSet?
    private var sequenceEpoch: UUID?
    private var lastSequence: UInt64?

    init(adapters: Adapters) {
        self.adapters = adapters
    }

    // MARK: Availability for UI

    var mediaAvailability: Availability {
        guard let context = adapters.context() else { return .noStream }
        guard context.hostSupportsMediaKeys else { return .unsupported }
        return context.inputEnabled ? .available : .needsControl
    }

    /// Volume UI is enabled only for a selected, source-advertised scope.
    var volumeAvailability: Availability {
        guard let context = adapters.context() else { return .noStream }
        guard Self.selectedVolumeScope != nil, context.hostSupportsVolume else { return .unsupported }
        return .available
    }

    /// The snapshot only while it belongs to the current stream identity.
    var currentVolume: VolumeSnapshot? {
        guard let snapshot = volumeSnapshot, let context = adapters.context(),
              snapshot.controlEpoch == context.controlEpoch, snapshot.pairingID == context.pairingID,
              snapshot.windowID == context.windowID, snapshot.scope == Self.selectedVolumeScope else { return nil }
        return snapshot
    }

    // MARK: Requests

    func send(_ action: PeelSourceMediaAction) {
        guard let context = adapters.context() else { lastMessage = "No active stream."; return }
        guard context.hostSupportsMediaKeys else {
            lastMessage = "The source computer does not offer media controls."; return
        }
        guard context.inputEnabled else {
            lastMessage = "Turn on Control to use the source computer's media controls."; return
        }
        guard let id = reserve(.media(action), context) else { return }
        let message = PeelSourceMediaCommand(requestId: id, pairingId: context.pairingID,
                                             windowId: context.windowID, action: action)
        if !adapters.sendCommand(message) { release(id, message: "Control is off.") }
    }

    /// Queries the source level. Call on popover appearance only (no polling).
    func refreshVolume() {
        guard let scope = Self.selectedVolumeScope, let context = adapters.context(),
              context.hostSupportsVolume,
              !pending.values.contains(where: { $0.kind == .volumeQuery(scope) }),
              let id = reserve(.volumeQuery(scope), context) else { return }
        let message = PeelSourceVolumeQuery(requestId: id, pairingId: context.pairingID,
                                            windowId: context.windowID, scope: scope)
        if !adapters.sendVolumeQuery(message) { release(id, message: "The source computer is unavailable.") }
    }

    func setVolume(_ volume: Double) {
        guard PeelSourceMediaProtocol.isVolume(volume) else { return }
        guard let change = boundChange(volume: volume, muted: nil) else { return }
        requestSet(change)
    }

    func setMuted(_ muted: Bool) {
        guard let change = boundChange(volume: nil, muted: muted) else { return }
        requestSet(change)
    }

    /// Captures the current stream identity and scope for a user tap.
    private func boundChange(volume: Double?, muted: Bool?) -> QueuedSet? {
        guard let scope = Self.selectedVolumeScope, let context = adapters.context() else {
            lastMessage = "Source volume control isn't available."; return nil
        }
        return QueuedSet(controlEpoch: context.controlEpoch, pairingID: context.pairingID,
                         windowID: context.windowID, scope: scope, volume: volume, muted: muted)
    }

    func clearMessage() { lastMessage = nil }

    /// Viewer: the control connection is ending.
    func controlWillEnd() {
        pending.removeAll()
        pendingCount = 0
        queuedSet = nil
        volumeSnapshot = nil
        lastMessage = nil
        sequenceEpoch = nil
        lastSequence = nil
    }

    /// One set in flight; later changes coalesce to the latest value.
    private func requestSet(_ change: QueuedSet) {
        guard let scope = Self.selectedVolumeScope, let context = adapters.context(),
              context.hostSupportsVolume else {
            lastMessage = "Source volume control isn't available."; return
        }
        // Never send a change under a stream identity other than its own.
        guard change.matches(context), change.scope == scope else {
            if queuedSet == change { queuedSet = nil }
            return
        }
        guard context.inputEnabled else {
            lastMessage = "Turn on Control to change the source computer's volume."; return
        }
        guard let current = currentVolume, current.supported,
              change.volume == nil || current.canSetVolume,
              change.muted == nil || current.canSetMute else {
            lastMessage = "The source computer did not report a settable volume."; return
        }
        if pending.values.contains(where: {
            $0.kind == .volumeSet(scope) && $0.controlEpoch == change.controlEpoch
                && $0.pairingID == change.pairingID && $0.windowID == change.windowID
        }) {
            queuedSet = change
            return
        }
        guard let id = reserve(.volumeSet(scope), context) else { return }
        let message = PeelSourceVolumeSet(requestId: id, pairingId: context.pairingID,
                                          windowId: context.windowID, scope: scope,
                                          volume: change.volume, muted: change.muted)
        if !adapters.sendVolumeSet(message) { release(id, message: "Control is off.") }
    }

    private func sendQueuedSetIfAny() {
        guard let change = queuedSet else { return }
        queuedSet = nil
        // A change captured for another stream identity is dropped, not rebound.
        guard let context = adapters.context(), change.matches(context) else { return }
        requestSet(change)
    }

    /// Clears a queued change whose captured identity is no longer current.
    private func dropStaleQueuedSet() {
        guard let change = queuedSet else { return }
        if let context = adapters.context(), change.matches(context) { return }
        queuedSet = nil
    }

    private func reserve(_ kind: Kind, _ context: PeelRemoteMacSourceMediaContext) -> UUID? {
        guard pending.count < PeelSourceMediaProtocol.clientMaximumPending else {
            lastMessage = "Waiting for the source computer to respond."
            return nil
        }
        let id = UUID()
        pending[id] = Pending(kind: kind, controlEpoch: context.controlEpoch,
                              pairingID: context.pairingID, windowID: context.windowID)
        pendingCount = pending.count
        DispatchQueue.main.asyncAfter(deadline: .now() + PeelSourceMediaProtocol.clientTimeoutSeconds) { [weak self] in
            guard let self, self.pending[id] != nil else { return }
            self.release(id, message: "The source computer did not respond.")
            self.sendQueuedSetIfAny()
        }
        return id
    }

    private func release(_ id: UUID, message: String?) {
        guard let removed = pending.removeValue(forKey: id) else { return }
        pendingCount = pending.count
        if case .volumeSet = removed.kind, message != nil { queuedSet = nil }
        if let message { lastMessage = message }
    }

    /// Removes and returns the pending entry only when the reply and the
    /// still-current stream both match the identity captured at send time.
    private func takeMatching(_ rawID: String?, pairingID: String, windowID: UInt32) -> Pending? {
        guard let rawID, PeelSourceMediaProtocol.isRequestID(rawID), let id = UUID(uuidString: rawID),
              let entry = pending[id] else { return nil }
        guard let context = adapters.context(), context.controlEpoch == entry.controlEpoch,
              context.pairingID == entry.pairingID, context.windowID == entry.windowID else {
            // Stream identity changed: the request and any change queued
            // behind it are stale.
            pending.removeValue(forKey: id)
            pendingCount = pending.count
            dropStaleQueuedSet()
            return nil
        }
        guard pairingID == entry.pairingID, windowID == entry.windowID else { return nil }
        pending.removeValue(forKey: id)
        pendingCount = pending.count
        return entry
    }

    // MARK: Replies

    func receive(_ ack: PeelSourceMediaAck) {
        guard let parsed = ack.parsed,
              let entry = takeMatching(ack.requestId, pairingID: ack.pairingId, windowID: ack.windowId) else { return }
        switch entry.kind {
        case .media:
            lastMessage = parsed.status == .applied ? nil : Self.describe(parsed.status, parsed.reason)
        case .volumeSet(let scope):
            if parsed.status == .applied {
                lastMessage = nil
                // Show only the source's actual resulting state.
                if !pending.values.contains(where: { $0.kind == .volumeQuery(scope) }) { refreshVolume() }
            } else {
                lastMessage = Self.describe(parsed.status, parsed.reason)
                queuedSet = nil
            }
        case .volumeQuery:
            lastMessage = Self.describe(parsed.status, parsed.reason)
        }
        sendQueuedSetIfAny()
    }

    func receive(_ state: PeelSourceVolumeState) {
        guard state.isValid, let scope = PeelSourceVolumeScope(rawValue: state.scope),
              let context = adapters.context(), context.pairingID == state.pairingId,
              context.windowID == state.windowId else { return }
        if state.requestId != nil {
            guard let entry = takeMatching(state.requestId, pairingID: state.pairingId, windowID: state.windowId),
                  entry.kind == .volumeQuery(scope) || entry.kind == .volumeSet(scope) else { return }
        }
        // Monotonic per source process, fenced per control connection.
        if sequenceEpoch != context.controlEpoch {
            sequenceEpoch = context.controlEpoch
            lastSequence = nil
        }
        if let lastSequence, state.sequence <= lastSequence { sendQueuedSetIfAny(); return }
        lastSequence = state.sequence
        guard scope == Self.selectedVolumeScope else { sendQueuedSetIfAny(); return }
        volumeSnapshot = VolumeSnapshot(controlEpoch: context.controlEpoch, pairingID: context.pairingID,
            windowID: context.windowID, scope: scope, supported: state.supported,
            canSetVolume: state.canSetVolume, canSetMute: state.canSetMute,
            volume: state.volume, muted: state.muted,
            reason: state.reason.flatMap(PeelSourceMediaReason.init(rawValue:)))
        if state.supported { lastMessage = nil }
        sendQueuedSetIfAny()
    }

    static func describe(_ status: PeelSourceMediaStatus, _ reason: PeelSourceMediaReason?) -> String {
        if let reason {
            switch reason {
            case .controlOff: return "Allow Control is off on the source computer."
            case .notVisible: return "The stream isn't visible."
            case .locked: return "The source computer is locked."
            case .accessibilityMissing: return "The source computer needs Accessibility permission for Peel Pro."
            case .scopeUnsupported: return "The source computer doesn't support this control."
            case .fixedVolume: return "The source computer's output has a fixed volume."
            case .noOutputDevice: return "The source computer has no audio output."
            case .staleStream: return "The stream changed. Try again."
            case .rateLimited: return "Too many requests. Try again in a moment."
            case .osRefused: return "The source computer refused the request."
            }
        }
        switch status {
        case .applied: return "Done."
        case .unsupported: return "The source computer doesn't support this control."
        case .denied: return "The source computer denied the request."
        case .failed: return "The source computer couldn't complete the request."
        case .stale: return "The stream changed. Try again."
        case .invalid: return "The request was invalid."
        }
    }
}
