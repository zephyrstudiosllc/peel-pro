//
//  PeelGameControllerPolicy.swift
//  Peel
//
//  Pure game controller input decisions shared by the iPhone, iPad and Vision
//  clients: target claims and fencing, per-stick neutral rearm, per-button press
//  arming with a bounded press queue, stick shaping and pointer/scroll rate
//  bounds. Foundation only; Tests/ControllerInput compiles this exact file.
//

import Foundation

struct PeelControllerVector: Equatable {
    var x: Double
    var y: Double

    static let zero = PeelControllerVector(x: 0, y: 0)

    var magnitude: Double { (x * x + y * y).squareRoot() }
}

struct PeelControllerPoint: Equatable {
    var x: Double
    var y: Double
}

/// Semantic controller actions. Physical mapping lives in the adapter so the
/// system's controller remapping is preserved.
enum PeelControllerButton: Hashable, CaseIterable {
    case primaryClick
    case secondaryClick
    case enter
    case escape
    case up
    case down
    case left
    case right

    var isKeyboard: Bool {
        switch self {
        case .primaryClick, .secondaryClick: return false
        default: return true
        }
    }
}

enum PeelControllerStickRole: Equatable {
    case pointer
    case scroll
}

/// One physical stick. Source identifiers are assigned per controller
/// connection and never reused, so a reconnected controller is a new source.
struct PeelControllerStickID: Hashable, Comparable {
    let source: UInt64
    let stick: Int

    static func < (lhs: PeelControllerStickID, rhs: PeelControllerStickID) -> Bool {
        (lhs.source, lhs.stick) < (rhs.source, rhs.stick)
    }
}

struct PeelControllerSourceSample {
    struct Stick {
        let index: Int
        let vector: PeelControllerVector
        let role: PeelControllerStickRole
    }

    let source: UInt64
    let sticks: [Stick]
    let held: Set<PeelControllerButton>
}

/// One host window lifetime: the owning app process, matching the session's
/// existing window identity semantics (same app name; launch times both absent or
/// within one second). Title and size are incidental and never part of it, so a
/// numeric window id reused by a new app is a different target.
struct PeelControllerWindowLifetime: Equatable {
    let appName: String
    let appLaunch: TimeInterval?

    static func == (lhs: PeelControllerWindowLifetime, rhs: PeelControllerWindowLifetime) -> Bool {
        guard lhs.appName == rhs.appName else { return false }
        switch (lhs.appLaunch, rhs.appLaunch) {
        case let (left?, right?): return abs(left - right) < 1
        case (nil, nil): return true
        default: return false
        }
    }
}

/// Identity of one installed pressed-state handler. Handlers are retired and
/// reinstalled whenever the policy's callback generation advances, so a callback
/// delivered late from an older registration is discarded before it can arm,
/// disarm or queue anything.
struct PeelControllerCallbackToken: Equatable, Sendable {
    let source: UInt64
    let generation: UInt64
}

/// The bounded handoff from a GameController callback queue to the main actor.
/// Main-thread callbacks deliver synchronously; others hop through `schedule`
/// while fewer than `limit` hops are in flight, otherwise they are dropped and
/// polling still observes the held state.
nonisolated final class PeelControllerCallbackRelay: @unchecked Sendable {
    typealias Delivery = @MainActor @Sendable (PeelControllerCallbackToken, PeelControllerButton, Bool) -> Void
    typealias Schedule = @Sendable (@escaping @Sendable () -> Void) -> Void

    private let lock = NSLock()
    private var inFlight = 0
    private let limit: Int
    private let schedule: Schedule
    private let deliver: Delivery

    init(limit: Int = 16, schedule: @escaping Schedule, deliver: @escaping Delivery) {
        self.limit = limit
        self.schedule = schedule
        self.deliver = deliver
    }

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return inFlight
    }

    func post(
        _ token: PeelControllerCallbackToken,
        _ button: PeelControllerButton,
        pressed: Bool,
        onMainThread: Bool = Thread.isMainThread
    ) {
        let deliver = self.deliver
        if onMainThread {
            MainActor.assumeIsolated { deliver(token, button, pressed) }
            return
        }
        lock.lock()
        guard inFlight < limit else {
            lock.unlock()
            return
        }
        inFlight += 1
        lock.unlock()
        schedule { [self] in
            lock.lock()
            inFlight -= 1
            lock.unlock()
            MainActor.assumeIsolated { deliver(token, button, pressed) }
        }
    }
}

/// Window keyed peeled scenes bind only to their own host's session. The
/// selected-session fallback remains only for keyless or legacy windows, so two
/// Macs exposing the same numeric window id can never be confused.
enum PeelControllerSessionResolution {
    static let legacyHostKey = "legacy"

    static func owningSession<Session>(
        hostKeyRawValue: String?,
        exact: () -> Session?,
        selected: () -> Session?
    ) -> Session? {
        if let hostKeyRawValue, hostKeyRawValue != legacyHostKey {
            return exact()
        }
        return exact() ?? selected()
    }
}

struct PeelGameControllerPolicy {
    struct Tuning {
        var deadzone = 0.15
        /// Full-deflection pointer speed in content widths per second.
        var pointerSpeed = 0.65
        /// Full-deflection scroll speed in points per second.
        var scrollSpeed = 1400.0
        var maxTickDelta = 0.05
        /// Ticks are scheduled at 60 Hz; the gate tolerates scheduling jitter
        /// while bounding pointer traffic below about 67 Hz.
        var pointerSendInterval = 0.015
        var scrollFlushInterval = 1.0 / 30.0
        var pressQueueLimit = 8
    }

    /// Exact controller target: host, window id, window lifetime and control
    /// connection identity.
    struct TargetKey: Equatable {
        let hostKey: String
        let windowId: UInt32
        let lifetime: PeelControllerWindowLifetime
        let connection: ObjectIdentifier
    }

    struct Claim: Equatable {
        let owner: UUID
        let target: TargetKey
    }

    enum OfferResult: Equatable {
        case unchanged
        case installed
        case rejected
    }

    struct Press: Equatable {
        let source: UInt64
        let button: PeelControllerButton
        let epoch: UInt64
    }

    struct Frame: Equatable {
        var moveTo: PeelControllerPoint?
        var scroll: PeelControllerVector?
        var presses: [PeelControllerButton] = []

        var isEmpty: Bool { moveTo == nil && scroll == nil && presses.isEmpty }
    }

    let tuning: Tuning

    private(set) var claim: Claim?
    /// Advances on every claim change, release, readiness loss and explicit fence.
    private(set) var epoch: UInt64 = 0
    /// Advances on every fence and whenever readiness is regained. Installed
    /// callbacks carry the generation they were registered under.
    private(set) var callbackGeneration: UInt64 = 0
    private(set) var queue: [Press] = []

    private var knownSticks: Set<PeelControllerStickID> = []
    private var sticksNeedingNeutral: Set<PeelControllerStickID> = []
    private(set) var pointerStick: PeelControllerStickID?
    private(set) var scrollStick: PeelControllerStickID?

    /// Buttons that have been observed released since the last fence or press.
    /// Unknown sources have no entry and cannot press.
    private var armed: [UInt64: Set<PeelControllerButton>] = [:]

    private var isReady = false
    /// App-local suspensions (an open controller guide). While any is held the
    /// target stays claimed but nothing is emitted and callbacks are rejected.
    private(set) var suspensions: Set<UUID> = []
    var isSuspended: Bool { !suspensions.isEmpty }
    private var lastTickAt: Double?
    private(set) var pointer: PeelControllerPoint?
    private var unsentPointer: PeelControllerPoint?
    private var lastPointerSendAt = -Double.infinity
    private var pendingScroll = PeelControllerVector.zero
    private var lastScrollFlushAt = -Double.infinity

    init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
    }

    // MARK: - Claims

    /// A different owner replaces a live claim only when preempting. A dead
    /// claim (host window no longer active, connection gone) is always replaceable.
    mutating func offer(_ newClaim: Claim, preempt: Bool, currentIsLive: Bool) -> OfferResult {
        if let claim {
            if claim == newClaim { return .unchanged }
            if claim.owner != newClaim.owner, !preempt, currentIsLive { return .rejected }
        }
        claim = newClaim
        fence()
        return .installed
    }

    @discardableResult
    mutating func release(owner: UUID) -> Bool {
        guard claim?.owner == owner else { return false }
        claim = nil
        fence()
        return true
    }

    /// Drops queued presses, disarms every button and requires every stick to
    /// return to neutral before it acts on whatever target follows.
    mutating func fence() {
        epoch &+= 1
        callbackGeneration &+= 1
        queue.removeAll()
        for source in armed.keys { armed[source] = [] }
        sticksNeedingNeutral = knownSticks
        pointerStick = nil
        scrollStick = nil
        isReady = false
        lastTickAt = nil
        pointer = nil
        unsentPointer = nil
        pendingScroll = .zero
    }

    /// Suspends output immediately: the first suspension fences (drops queued
    /// presses, disarms buttons, requires neutral sticks, retires callbacks).
    mutating func suspend(_ id: UUID) {
        let wasSuspended = isSuspended
        suspensions.insert(id)
        if !wasSuspended { fence() }
    }

    /// Ending the last suspension does not replay anything: buttons rearm only
    /// after an observed release, sticks after neutral, and the next ready tick
    /// regains readiness with a new callback generation.
    mutating func resume(_ id: UUID) {
        suspensions.remove(id)
    }

    // MARK: - Sources and presses

    mutating func addSource(_ source: UInt64) {
        if armed[source] == nil { armed[source] = [] }
    }

    mutating func removeSource(_ source: UInt64) {
        armed[source] = nil
        queue.removeAll { $0.source == source }
        knownSticks = knownSticks.filter { $0.source != source }
        sticksNeedingNeutral = sticksNeedingNeutral.filter { $0.source != source }
        if pointerStick?.source == source { pointerStick = nil }
        if scrollStick?.source == source { scrollStick = nil }
    }

    /// Pressed-state callback or polled observation. A press counts only when the
    /// button was seen released first, so callbacks and polling never double
    /// fire, and a button held across a fence or reconnect never fires.
    mutating func pressChanged(source: UInt64, button: PeelControllerButton, pressed: Bool) {
        guard var buttons = armed[source] else { return }
        if pressed {
            guard buttons.contains(button) else { return }
            buttons.remove(button)
            if queue.count < tuning.pressQueueLimit {
                queue.append(Press(source: source, button: button, epoch: epoch))
            }
        } else {
            buttons.insert(button)
        }
        armed[source] = buttons
    }

    mutating func observeHeld(source: UInt64, held: Set<PeelControllerButton>) {
        for button in PeelControllerButton.allCases {
            pressChanged(source: source, button: button, pressed: held.contains(button))
        }
    }

    /// Reconciles connected sources and their held buttons. Missing sources are
    /// removed with their queued presses; new sources start disarmed.
    mutating func observeSources(_ sources: [PeelControllerSourceSample]) {
        let liveSources = Set(sources.map(\.source))
        for source in armed.keys where !liveSources.contains(source) {
            removeSource(source)
        }
        for sample in sources {
            addSource(sample.source)
            observeHeld(source: sample.source, held: sample.held)
        }
    }

    /// Entry point for installed pressed-state callbacks. A callback from a
    /// retired registration is rejected before any button state changes.
    @discardableResult
    mutating func callbackChanged(
        _ token: PeelControllerCallbackToken,
        button: PeelControllerButton,
        pressed: Bool
    ) -> Bool {
        guard claim != nil, !isSuspended, token.generation == callbackGeneration else { return false }
        pressChanged(source: token.source, button: button, pressed: pressed)
        return true
    }

    // MARK: - Tick

    /// One bounded tick. `ready` is the adapter's full target admission. When not
    /// ready, nothing is emitted and the first not-ready tick fences.
    mutating func tick(
        now: Double,
        ready: Bool,
        sources: [PeelControllerSourceSample],
        aspect: Double,
        pointerOrigin: () -> PeelControllerPoint
    ) -> Frame {
        observeSources(sources)

        guard ready, !isSuspended else {
            if isReady { fence() }
            queue.removeAll()
            return Frame()
        }
        if !isReady {
            // Regaining readiness retires callbacks registered while not ready and
            // drops anything they queued; held buttons stay disarmed.
            isReady = true
            callbackGeneration &+= 1
            queue.removeAll()
        }

        let dt = min(max(now - (lastTickAt ?? now), 0), tuning.maxTickDelta)
        lastTickAt = now

        let (pointerVector, scrollVector) = resolveSticks(sources)
        var frame = Frame()

        if pointerVector != .zero, dt > 0 {
            let start = pointer ?? pointerOrigin()
            let next = Self.pointerStep(
                from: start,
                vector: pointerVector,
                dt: dt,
                aspect: aspect,
                speed: tuning.pointerSpeed
            )
            pointer = next
            if next != start { unsentPointer = next }
        }
        if let unsent = unsentPointer, now - lastPointerSendAt >= tuning.pointerSendInterval {
            frame.moveTo = unsent
            unsentPointer = nil
            lastPointerSendAt = now
        }
        // A neutral stick hands the cursor back to touch/trackpad once its last
        // position has been sent.
        if pointerVector == .zero, unsentPointer == nil {
            pointer = nil
        }

        if scrollVector != .zero, dt > 0 {
            // Stick up scrolls up (+dy); horizontal follows the stick.
            let step = tuning.scrollSpeed * dt
            pendingScroll.x -= scrollVector.x * step
            pendingScroll.y += scrollVector.y * step
        }
        if now - lastScrollFlushAt >= tuning.scrollFlushInterval,
           abs(pendingScroll.x) + abs(pendingScroll.y) >= 0.5 {
            frame.scroll = pendingScroll
            pendingScroll = .zero
            lastScrollFlushAt = now
        }

        frame.presses = queue.filter { $0.epoch == epoch }.map(\.button)
        queue.removeAll()
        return frame
    }

    /// Records a click location so the next stick motion continues from it.
    mutating func pointerForClick(origin: () -> PeelControllerPoint) -> PeelControllerPoint {
        let point = unsentPointer ?? pointer ?? origin()
        pointer = point
        unsentPointer = nil
        return point
    }

    /// Each physical stick rearms independently; one active stick per role is
    /// retained through its gesture. A stick deflected while another holds the
    /// role is suppressed until it, too, returns to neutral.
    private mutating func resolveSticks(
        _ sources: [PeelControllerSourceSample]
    ) -> (PeelControllerVector, PeelControllerVector) {
        var deflected: [(id: PeelControllerStickID, role: PeelControllerStickRole, vector: PeelControllerVector)] = []
        var live: Set<PeelControllerStickID> = []

        for sample in sources {
            for stick in sample.sticks {
                let id = PeelControllerStickID(source: sample.source, stick: stick.index)
                live.insert(id)
                if !knownSticks.contains(id) {
                    knownSticks.insert(id)
                    sticksNeedingNeutral.insert(id)
                }
                let shaped = Self.shaped(stick.vector, deadzone: tuning.deadzone)
                if sticksNeedingNeutral.contains(id) {
                    if shaped == .zero { sticksNeedingNeutral.remove(id) }
                    continue
                }
                if shaped != .zero {
                    deflected.append((id, stick.role, shaped))
                }
            }
        }
        knownSticks.formIntersection(live)
        sticksNeedingNeutral.formIntersection(live)
        deflected.sort { $0.id < $1.id }

        var suppressed: [PeelControllerStickID] = []
        func select(
            _ role: PeelControllerStickRole,
            _ current: PeelControllerStickID?
        ) -> (PeelControllerStickID?, PeelControllerVector) {
            let candidates = deflected.filter { $0.role == role }
            var active = current
            if let id = active, !candidates.contains(where: { $0.id == id }) {
                active = nil
            }
            if active == nil {
                active = candidates.first?.id
            }
            var vector = PeelControllerVector.zero
            for candidate in candidates {
                if candidate.id == active {
                    vector = candidate.vector
                } else {
                    suppressed.append(candidate.id)
                }
            }
            return (active, vector)
        }

        let (pointerActive, pointerVector) = select(.pointer, pointerStick)
        let (scrollActive, scrollVector) = select(.scroll, scrollStick)
        pointerStick = pointerActive
        scrollStick = scrollActive
        sticksNeedingNeutral.formUnion(suppressed)
        return (pointerVector, scrollVector)
    }

    // MARK: - Shaping

    /// Radial deadzone with a squared response curve; returns length <= 1.
    static func shaped(_ vector: PeelControllerVector, deadzone: Double) -> PeelControllerVector {
        guard vector.x.isFinite, vector.y.isFinite else { return .zero }
        let length = vector.magnitude
        let magnitude = min(length, 1.0)
        guard magnitude > deadzone, length > 0 else { return .zero }
        let scaled = (magnitude - deadzone) / (1.0 - deadzone)
        let response = scaled * scaled
        return PeelControllerVector(x: vector.x / length * response, y: vector.y / length * response)
    }

    static func clampedAspect(_ raw: Double) -> Double {
        guard raw.isFinite, raw > 0 else { return 16.0 / 9.0 }
        return min(max(raw, 0.25), 4.0)
    }

    /// Equal physical speed on both axes; stick up moves the pointer up.
    static func pointerStep(
        from start: PeelControllerPoint,
        vector: PeelControllerVector,
        dt: Double,
        aspect: Double,
        speed: Double
    ) -> PeelControllerPoint {
        let step = speed * dt
        let aspect = clampedAspect(aspect)
        return PeelControllerPoint(
            x: min(max(start.x + vector.x * step, 0), 1),
            y: min(max(start.y - vector.y * step * aspect, 0), 1)
        )
    }
}
