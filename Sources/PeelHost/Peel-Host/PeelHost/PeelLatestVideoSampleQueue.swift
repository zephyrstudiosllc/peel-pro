import Foundation
import CoreMedia

/// Captures request epochs before queue hops and serializes only immediate
/// enqueue/admission with Stop. No capture, codec or socket wait occurs here.
nonisolated final class PeelVideoCaptureAdmission: @unchecked Sendable {
    struct Request: Hashable, Sendable {
        let windowId: UInt32
        fileprivate let epoch: UUID
    }
    struct Capture: Hashable, Sendable {
        let request: Request
        fileprivate let identity: UUID
        var windowId: UInt32 { request.windowId }
    }
    private struct State {
        let request: Request
        var capture: Capture?
        var encoder: UUID?
    }
    static let maximumWindows = 128
    private let lock = NSLock()
    private var states: [UInt32: State] = [:]

    func enqueueRequest(windowId: UInt32, _ enqueue: (Request?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        if states[windowId] == nil, states.count < Self.maximumWindows {
            states[windowId] = State(request: Request(windowId: windowId, epoch: UUID()))
        }
        enqueue(states[windowId]?.request)
    }
    func isCurrent(_ request: Request) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return states[request.windowId]?.request == request
    }
    func begin(_ request: Request) -> Capture? {
        lock.lock(); defer { lock.unlock() }
        guard var state = states[request.windowId], state.request == request else { return nil }
        if let capture = state.capture { return capture }
        let capture = Capture(request: request, identity: UUID())
        state.capture = capture; states[request.windowId] = state
        return capture
    }
    func currentCapture(windowId: UInt32) -> Capture? {
        lock.lock(); defer { lock.unlock() }
        return states[windowId]?.capture
    }
    func isCurrent(_ capture: Capture) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return states[capture.windowId]?.capture == capture
    }
    @discardableResult
    func withCapture(_ capture: Capture, _ submit: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard states[capture.windowId]?.capture == capture else { return false }
        submit(); return true
    }
    func bindEncoder(for capture: Capture) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        guard var state = states[capture.windowId], state.capture == capture else { return nil }
        let token = UUID(); state.encoder = token; states[capture.windowId] = state
        return token
    }
    @discardableResult
    func withEncoder(capture: Capture, encoder: UUID, _ submit: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let state = states[capture.windowId], state.capture == capture, state.encoder == encoder else { return false }
        submit(); return true
    }
    func retireEncoder(capture: Capture, encoder: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard var state = states[capture.windowId], state.capture == capture, state.encoder == encoder else { return }
        state.encoder = nil; states[capture.windowId] = state
    }
    func revoke(windowId: UInt32, _ enqueue: (Capture?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        let old = states.removeValue(forKey: windowId)
        enqueue(old?.capture)
    }
    @discardableResult
    func revoke(_ capture: Capture, _ enqueue: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard states[capture.windowId]?.capture == capture else { return false }
        states.removeValue(forKey: capture.windowId)
        enqueue(); return true
    }
    func revokeAll(_ enqueue: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        states.removeAll(keepingCapacity: false)
        enqueue()
    }
}

typealias PeelVideoCaptureToken = PeelVideoCaptureAdmission.Capture

/// Coalesces raw ScreenCaptureKit samples before they enter the host video
/// queue. Each window keeps at most one pending sample and one current drain.
final class PeelLatestVideoSampleQueue: @unchecked Sendable {
    static let maxActiveEntries = 128

    private struct Entry {
        let token: UUID
        let capture: PeelVideoCaptureToken
        var pending: CMSampleBuffer?
        var drainScheduled: Bool
    }

    private let lock = NSLock()
    private var entries: [UInt32: Entry] = [:]
    private let consumerQueue: DispatchQueue
    private let consumer: (UInt32, PeelVideoCaptureToken, CMSampleBuffer) -> Void

    init(
        consumerQueue: DispatchQueue,
        consumer: @escaping (UInt32, PeelVideoCaptureToken, CMSampleBuffer) -> Void
    ) {
        self.consumerQueue = consumerQueue
        self.consumer = consumer
    }

    /// Replaces the pending raw sample for a window. The scheduled closure
    /// captures only the window and token; it never retains a raw sample.
    @discardableResult
    func offer(_ sampleBuffer: CMSampleBuffer, windowId: UInt32, capture: PeelVideoCaptureToken) -> Bool {
        guard capture.windowId == windowId else { return false }
        let token: UUID
        var shouldSchedule = false
        var superseded: CMSampleBuffer?

        lock.lock()
        if var entry = entries[windowId], entry.capture == capture {
            token = entry.token
            superseded = entry.pending
            entry.pending = sampleBuffer
            if !entry.drainScheduled {
                entry.drainScheduled = true
                shouldSchedule = true
            }
            entries[windowId] = entry
        } else {
            guard entries[windowId] != nil || entries.count < Self.maxActiveEntries else {
                lock.unlock()
                return false
            }
            token = UUID()
            superseded = entries[windowId]?.pending
            entries[windowId] = Entry(token: token, capture: capture,
                                      pending: sampleBuffer,
                                      drainScheduled: true)
            shouldSchedule = true
        }
        lock.unlock()

        // Release a replaced CMSampleBuffer after leaving the lock. ARC's
        // retain/release path is kept out of the critical section.
        if superseded != nil {
            superseded = nil
        }

        if shouldSchedule {
            consumerQueue.async { [weak self] in
                self?.drain(windowId: windowId, token: token)
            }
        }
        return true
    }

    /// Invalidates a window token and releases its pending raw sample.
    func remove(windowId: UInt32, capture: PeelVideoCaptureToken? = nil) {
        var removed: Entry?
        lock.lock()
        if let capture, entries[windowId]?.capture != capture { lock.unlock(); return }
        removed = entries.removeValue(forKey: windowId)
        lock.unlock()
        _ = removed
    }

    /// Invalidates every window token and releases every pending raw sample.
    func clearAll() {
        let removed: [UInt32: Entry]
        lock.lock()
        removed = entries
        entries.removeAll(keepingCapacity: false)
        lock.unlock()
        _ = removed
    }

    private func drain(windowId: UInt32, token: UUID) {
        let sampleBuffer: CMSampleBuffer?
        let capture: PeelVideoCaptureToken

        lock.lock()
        guard var entry = entries[windowId], entry.token == token else {
            lock.unlock()
            return
        }
        sampleBuffer = entry.pending
        capture = entry.capture
        entry.pending = nil
        entries[windowId] = entry
        lock.unlock()

        if let sampleBuffer {
            // The consumer runs on the existing videoFrameQueue. It receives
            // exactly one latest sample per drain pass.
            consumer(windowId, capture, sampleBuffer)
        }

        var shouldReschedule = false
        lock.lock()
        guard var entry = entries[windowId], entry.token == token else {
            lock.unlock()
            return
        }
        if entry.pending != nil {
            // Keep the current generation marked scheduled while arranging one
            // follow-up pass. Offers during the consumer cannot add another.
            entry.drainScheduled = true
            shouldReschedule = true
        } else {
            entry.drainScheduled = false
        }
        entries[windowId] = entry
        lock.unlock()

        if shouldReschedule {
            consumerQueue.async { [weak self] in
                self?.drain(windowId: windowId, token: token)
            }
        }
    }
}
