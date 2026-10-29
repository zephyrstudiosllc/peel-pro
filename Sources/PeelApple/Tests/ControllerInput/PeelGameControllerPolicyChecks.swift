//
//  PeelGameControllerPolicyChecks.swift
//  Compiled together with Shared/Client/PeelGameControllerPolicy.swift only.
//  No GameController device, UIKit scene, network or host is involved.
//

import Foundation

private var failures: [String] = []
private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { failures.append(message) }
}

private final class FakeConnection {}

private typealias Policy = PeelGameControllerPolicy
private let center = PeelControllerPoint(x: 0.5, y: 0.5)
private let ownerA = UUID()
private let ownerB = UUID()

private let safari = PeelControllerWindowLifetime(appName: "Safari", appLaunch: 1_000)

private func key(_ host: String, _ window: UInt32, _ connection: FakeConnection,
                 lifetime: PeelControllerWindowLifetime = safari) -> Policy.TargetKey {
    Policy.TargetKey(hostKey: host, windowId: window, lifetime: lifetime, connection: ObjectIdentifier(connection))
}

private func pad(_ source: UInt64, left: PeelControllerVector = .zero, right: PeelControllerVector = .zero,
                 held: Set<PeelControllerButton> = []) -> PeelControllerSourceSample {
    PeelControllerSourceSample(source: source, sticks: [
        .init(index: 0, vector: left, role: .pointer),
        .init(index: 1, vector: right, role: .scroll)
    ], held: held)
}

private func sense(_ source: UInt64, _ stick: PeelControllerVector = .zero, grip: Bool = false,
                   held: Set<PeelControllerButton> = []) -> PeelControllerSourceSample {
    PeelControllerSourceSample(source: source, sticks: [
        .init(index: 0, vector: stick, role: grip ? .scroll : .pointer)
    ], held: held)
}

private struct Clock {
    var now = 100.0
    mutating func next(_ step: Double = 1.0 / 60.0) -> Double { now += step; return now }
}

@discardableResult
private func run(_ policy: inout Policy, _ clock: inout Clock, ready: Bool = true,
                 _ sources: [PeelControllerSourceSample], aspect: Double = 1, step: Double = 1.0 / 60.0) -> Policy.Frame {
    policy.tick(now: clock.next(step), ready: ready, sources: sources, aspect: aspect, pointerOrigin: { center })
}

private func installed(_ connection: FakeConnection = FakeConnection()) -> Policy {
    var policy = Policy()
    _ = policy.offer(.init(owner: ownerA, target: key("hostA", 42, connection)), preempt: false, currentIsLive: false)
    return policy
}

private let right = PeelControllerVector(x: 1, y: 0)
private let leftVec = PeelControllerVector(x: -1, y: 0)
private let up = PeelControllerVector(x: 0, y: 1)

// MARK: - Exact host / window / connection targets

private func twoHostsSameWindowID() {
    let hostB = "session-B"
    check(PeelControllerSessionResolution.owningSession(
        hostKeyRawValue: "hostA", exact: { nil as String? }, selected: { hostB }) == nil,
          "keyed window must not fall back to the selected host with the same window id")
    check(PeelControllerSessionResolution.owningSession(
        hostKeyRawValue: nil, exact: { nil as String? }, selected: { hostB }) == hostB,
          "keyless legacy window keeps selected-session behavior")
    check(PeelControllerSessionResolution.owningSession(
        hostKeyRawValue: "legacy", exact: { nil as String? }, selected: { hostB }) == hostB,
          "legacy key keeps selected-session behavior")

    let connA = FakeConnection(), connB = FakeConnection()
    var policy = Policy()
    check(policy.offer(.init(owner: ownerA, target: key("hostA", 42, connA)), preempt: false, currentIsLive: false) == .installed,
          "first claim installs")
    check(policy.offer(.init(owner: ownerB, target: key("hostB", 42, connB)), preempt: false, currentIsLive: true) == .rejected,
          "another host's same window id cannot take a live claim without preemption")
    let epoch = policy.epoch
    check(policy.offer(.init(owner: ownerA, target: key("hostB", 42, connB)), preempt: false, currentIsLive: true) == .installed
          && policy.epoch != epoch,
          "same owner moving to another host with the same window id is a new fenced target")
}

private func connectionReplacementRearms() {
    let first = FakeConnection(), replacement = FakeConnection()
    var clock = Clock()
    var policy = installed(first)
    run(&policy, &clock, [pad(1)])
    run(&policy, &clock, [pad(1, left: right)])
    check(run(&policy, &clock, [pad(1, left: right)]).moveTo != nil, "neutral-armed stick moves")

    policy.pressChanged(source: 1, button: .primaryClick, pressed: true)
    let epoch = policy.epoch
    check(policy.offer(.init(owner: ownerA, target: key("hostA", 42, first)), preempt: false, currentIsLive: true) == .unchanged
          && policy.epoch == epoch, "identical claim is not a fence")
    check(policy.offer(.init(owner: ownerA, target: key("hostA", 42, replacement)), preempt: false, currentIsLive: false) == .installed
          && policy.epoch != epoch, "replacement connection fences even with the same host and window id")
    let after = run(&policy, &clock, [pad(1, left: right)])
    check(after.presses.isEmpty, "press queued for the old connection is not replayed")
    check(after.moveTo == nil, "stick held across connection replacement must return to neutral")
}

private func paneSwitchDoesNotFight() {
    let conn = FakeConnection()
    var policy = installed(conn)
    // Phone Duo: the newly selected pane preempts; the hidden pane's late release
    // and non-preempting re-offer must not disturb it.
    check(policy.offer(.init(owner: ownerB, target: key("hostA", 43, conn)), preempt: true, currentIsLive: true) == .installed,
          "selected pane preempts")
    check(!policy.release(owner: ownerA), "hidden pane release is a no-op for the new owner")
    check(policy.claim?.owner == ownerB, "new owner survives stale release")
    check(policy.offer(.init(owner: ownerA, target: key("hostA", 42, conn)), preempt: false, currentIsLive: true) == .rejected,
          "passive pane cannot reclaim a live target")
    check(policy.offer(.init(owner: ownerA, target: key("hostA", 42, conn)), preempt: false, currentIsLive: false) == .installed,
          "dead target is replaceable")
}

// MARK: - Sticks

private func oppositeHeldSenseSticks() {
    var clock = Clock()
    var policy = installed()
    run(&policy, &clock, [sense(1), sense(2)])
    check(run(&policy, &clock, [sense(1, right), sense(2)]).moveTo != nil, "left Sense moves pointer")

    // Readiness loss (background, pane hidden, stream ended) fences.
    run(&policy, &clock, ready: false, [sense(1, right), sense(2)])
    for _ in 0..<5 {
        check(run(&policy, &clock, [sense(1, right), sense(2, leftVec)]).moveTo == nil,
              "opposite held sticks never count as neutral")
    }
    check(run(&policy, &clock, [sense(1, right), sense(2)]).moveTo == nil,
          "releasing one half must not let the other half's held stick act")
    run(&policy, &clock, [sense(1), sense(2)])
    check(run(&policy, &clock, [sense(1, right), sense(2)]).moveTo != nil, "rearmed after its own neutral")
}

private func eitherSenseHalfAlone() {
    var clock = Clock()
    var policy = installed()
    run(&policy, &clock, [sense(7)])
    let moved = run(&policy, &clock, [sense(7, up)])
    check(moved.moveTo.map { $0.y < center.y } == true, "single right half moves pointer up")
    var scrolled = false
    for _ in 0..<4 where run(&policy, &clock, [sense(7, up, grip: true)]).scroll != nil { scrolled = true }
    check(scrolled, "grip + stick scrolls with one half")
}

private func activeStickRetention() {
    var clock = Clock()
    var policy = installed()
    run(&policy, &clock, [sense(1), sense(2)])
    run(&policy, &clock, [sense(1, right), sense(2)])
    let start = run(&policy, &clock, [sense(1, right), sense(2)]).moveTo
    let next = run(&policy, &clock, [sense(1, right), sense(2, leftVec)]).moveTo
    check(start != nil && next != nil && next!.x > start!.x, "active stick keeps the pointer; second is ignored")
    check(run(&policy, &clock, [sense(1), sense(2, leftVec)]).moveTo == nil,
          "suppressed stick must recenter before taking over")
    run(&policy, &clock, [sense(1), sense(2)])
    check(run(&policy, &clock, [sense(1), sense(2, leftVec)]).moveTo != nil, "other half usable after neutral")
}

private func deadzoneClampAndAspect() {
    check(Policy.shaped(PeelControllerVector(x: 0.1, y: 0.05), deadzone: 0.15) == .zero, "inside deadzone is zero")
    check(Policy.shaped(PeelControllerVector(x: 3, y: 4), deadzone: 0.15).magnitude <= 1.0000001, "output clamped to unit")
    check(Policy.shaped(PeelControllerVector(x: .nan, y: 1), deadzone: 0.15) == .zero, "non-finite input ignored")
    let half = Policy.shaped(PeelControllerVector(x: 0.575, y: 0), deadzone: 0.15).x
    check(abs(half - 0.25) < 0.001, "squared response gives precision near center")

    let edge = Policy.pointerStep(from: PeelControllerPoint(x: 0.99, y: 0.01), vector: PeelControllerVector(x: 1, y: 1),
                                  dt: 0.05, aspect: 1, speed: 0.65)
    check(edge.x == 1 && edge.y == 0, "pointer clamps to the window")
    let wide = Policy.pointerStep(from: center, vector: up, dt: 0.05, aspect: 100, speed: 0.65)
    check(abs((center.y - wide.y) - 0.65 * 0.05 * 4) < 1e-9, "aspect is clamped to 4")
    let tall = Policy.pointerStep(from: center, vector: PeelControllerVector(x: 1, y: 1), dt: 0.01, aspect: 2, speed: 1)
    check(abs((center.y - tall.y) - 2 * (tall.x - center.x)) < 1e-9, "equal physical speed on both axes")

    var clock = Clock()
    var policy = installed()
    run(&policy, &clock, [pad(1)])
    let stalled = run(&policy, &clock, [pad(1, left: right)], step: 2.0)
    check(stalled.moveTo.map { abs($0.x - (center.x + 0.65 * 0.05)) < 1e-9 } == true,
          "a stalled tick moves at most maxTickDelta")
}

private func idleAndRateBounds() {
    var clock = Clock()
    var policy = installed()
    for _ in 0..<120 {
        check(run(&policy, &clock, [pad(1)]).isEmpty, "neutral controller sends nothing")
    }

    var moves = 0, scrolls = 0
    for _ in 0..<200 {
        let frame = run(&policy, &clock, [pad(1, left: PeelControllerVector(x: 0.2, y: 0.2), right: up)], step: 0.005)
        if frame.moveTo != nil { moves += 1 }
        if frame.scroll != nil { scrolls += 1 }
    }
    check(moves > 0 && moves <= 67, "pointer bounded near 60 Hz over 1 s, got \(moves)")
    check(scrolls > 0 && scrolls <= 31, "scroll bounded to 30 Hz over 1 s, got \(scrolls)")

    var edge = installed()
    var edgeClock = Clock()
    let corner = PeelControllerPoint(x: 1, y: 0.5)
    _ = edge.tick(now: edgeClock.next(), ready: true, sources: [pad(1)], aspect: 1, pointerOrigin: { corner })
    var pinned = 0
    for _ in 0..<30 where edge.tick(now: edgeClock.next(), ready: true, sources: [pad(1, left: right)],
                                    aspect: 1, pointerOrigin: { corner }).moveTo != nil { pinned += 1 }
    check(pinned == 0, "pointer pinned at the edge sends nothing")
}

// MARK: - Buttons

private func shortPressQueueAndFence() {
    var clock = Clock()
    var policy = installed()
    run(&policy, &clock, [pad(1)])

    policy.pressChanged(source: 1, button: .primaryClick, pressed: true)
    policy.pressChanged(source: 1, button: .primaryClick, pressed: false)
    check(run(&policy, &clock, [pad(1)]).presses == [.primaryClick], "press shorter than a poll is delivered once")

    policy.pressChanged(source: 1, button: .secondaryClick, pressed: true)
    check(run(&policy, &clock, [pad(1, held: [.secondaryClick])]).presses == [.secondaryClick],
          "callback and poll of the same press do not double fire")
    check(run(&policy, &clock, [pad(1, held: [.secondaryClick])]).presses.isEmpty, "held button does not repeat")
    run(&policy, &clock, [pad(1)])
    check(run(&policy, &clock, [pad(1, held: [.enter])]).presses == [.enter], "poll catches a press without callback")

    // Two elements share primary (trigger and A): releasing one while the other
    // is held must not rearm.
    run(&policy, &clock, [pad(1)])
    policy.pressChanged(source: 1, button: .primaryClick, pressed: true)
    policy.pressChanged(source: 1, button: .primaryClick, pressed: true)
    check(run(&policy, &clock, [pad(1, held: [.primaryClick])]).presses == [.primaryClick], "alias press counts once")

    for _ in 0..<20 {
        policy.pressChanged(source: 1, button: .escape, pressed: true)
        policy.pressChanged(source: 1, button: .escape, pressed: false)
    }
    check(run(&policy, &clock, [pad(1)]).presses.count == 8, "press queue is bounded")

    policy.pressChanged(source: 1, button: .up, pressed: true)
    policy.pressChanged(source: 1, button: .up, pressed: false)
    _ = policy.offer(.init(owner: ownerB, target: key("hostA", 99, FakeConnection())), preempt: true, currentIsLive: true)
    check(run(&policy, &clock, [pad(1)]).presses.isEmpty, "queued press is never replayed to a new window")

    run(&policy, &clock, [pad(1, held: [.primaryClick])])
    _ = policy.release(owner: ownerB)
    _ = policy.offer(.init(owner: ownerA, target: key("hostA", 42, FakeConnection())), preempt: true, currentIsLive: false)
    check(run(&policy, &clock, [pad(1, held: [.primaryClick])]).presses.isEmpty, "button held through a fence is consumed")
    run(&policy, &clock, [pad(1)])
    check(run(&policy, &clock, [pad(1, held: [.primaryClick])]).presses == [.primaryClick], "fresh press after release works")
}

private func backgroundAndReconnect() {
    var clock = Clock()
    var policy = installed()
    run(&policy, &clock, [pad(1)])

    // Background / hidden pane / unfocused: presses are dropped, not deferred.
    run(&policy, &clock, ready: false, [pad(1)])
    policy.pressChanged(source: 1, button: .primaryClick, pressed: true)
    run(&policy, &clock, ready: false, [pad(1, held: [.primaryClick])])
    check(run(&policy, &clock, [pad(1, held: [.primaryClick])]).presses.isEmpty,
          "press made while not ready never fires after readiness returns")
    policy.pressChanged(source: 1, button: .escape, pressed: true)
    run(&policy, &clock, ready: false, [pad(1)])
    check(run(&policy, &clock, [pad(1)]).presses.isEmpty, "keyboard press queued before readiness loss is dropped")

    // Disconnect drops the source's queue; reconnect is a new source and a held
    // button or stick must be released first.
    run(&policy, &clock, [pad(1)])
    policy.pressChanged(source: 1, button: .secondaryClick, pressed: true)
    run(&policy, &clock, [])
    policy.pressChanged(source: 1, button: .secondaryClick, pressed: false)
    policy.pressChanged(source: 1, button: .secondaryClick, pressed: true)
    let reconnected = run(&policy, &clock, [pad(2, left: right, held: [.secondaryClick])])
    check(reconnected.presses.isEmpty, "disconnect drops queued presses and late callbacks")
    check(reconnected.moveTo == nil, "reconnected held stick waits for neutral")
    policy.pressChanged(source: 2, button: .secondaryClick, pressed: true)
    check(run(&policy, &clock, [pad(2, left: right, held: [.secondaryClick])]).presses.isEmpty,
          "button held through reconnect is consumed")
}

// MARK: - Window lifetime

private func sameWindowIDNewAppLifetime() {
    check(PeelControllerWindowLifetime(appName: "Safari", appLaunch: 1_000.4) == safari,
          "launch-time jitter under one second is the same lifetime")
    check(PeelControllerWindowLifetime(appName: "Safari", appLaunch: 1_005) != safari, "relaunched app is a new lifetime")
    check(PeelControllerWindowLifetime(appName: "Safari", appLaunch: nil) != safari, "lost launch time is not a match")
    check(PeelControllerWindowLifetime(appName: "Notes", appLaunch: 1_000) != safari, "another app is a new lifetime")

    let conn = FakeConnection()
    var clock = Clock()
    var policy = installed(conn)
    run(&policy, &clock, [pad(1)])
    run(&policy, &clock, [pad(1, left: right)])

    // Title or size refresh of the same lifetime keeps the claim and gesture.
    let titleRefresh = key("hostA", 42, conn, lifetime: PeelControllerWindowLifetime(appName: "Safari", appLaunch: 1_000.2))
    let epoch = policy.epoch
    check(policy.offer(.init(owner: ownerA, target: titleRefresh), preempt: false, currentIsLive: true) == .unchanged
          && policy.epoch == epoch, "same lifetime refresh does not fence")

    // Same host, same connection, same numeric window id, new app process.
    policy.pressChanged(source: 1, button: .primaryClick, pressed: true)
    let notes = key("hostA", 42, conn, lifetime: PeelControllerWindowLifetime(appName: "Notes", appLaunch: 2_000))
    check(policy.offer(.init(owner: ownerA, target: notes), preempt: false, currentIsLive: true) == .installed
          && policy.epoch != epoch, "reused window id with a new app lifetime fences")
    let after = run(&policy, &clock, [pad(1, left: right)])
    check(after.presses.isEmpty, "press made for the old app is never delivered to the new one")
    check(after.moveTo == nil, "stick held into the new app lifetime waits for neutral")
}

// MARK: - Callback handoff seam

/// Stands in for DispatchQueue.main: hops wait until the test runs them, which
/// models callbacks delivered late after a claim change.
nonisolated private final class PendingHops: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [@Sendable () -> Void] = []

    func add(_ work: @escaping @Sendable () -> Void) {
        lock.lock(); items.append(work); lock.unlock()
    }

    func runAll() {
        lock.lock(); let work = items; items.removeAll(); lock.unlock()
        work.forEach { $0() }
    }
}

private final class PolicyBox {
    var policy: Policy
    var accepted = 0
    var rejected = 0
    init(_ policy: Policy) { self.policy = policy }
}

private func relay(_ box: PolicyBox, _ hops: PendingHops, limit: Int = 16) -> PeelControllerCallbackRelay {
    PeelControllerCallbackRelay(limit: limit, schedule: { hops.add($0) }, deliver: { token, button, pressed in
        if box.policy.callbackChanged(token, button: button, pressed: pressed) {
            box.accepted += 1
        } else {
            box.rejected += 1
        }
    })
}

private func tick(_ box: PolicyBox, _ clock: inout Clock, ready: Bool = true,
                  _ sources: [PeelControllerSourceSample]) -> Policy.Frame {
    box.policy.tick(now: clock.next(), ready: ready, sources: sources, aspect: 1, pointerOrigin: { center })
}

private func token(_ box: PolicyBox, _ source: UInt64 = 1) -> PeelControllerCallbackToken {
    PeelControllerCallbackToken(source: source, generation: box.policy.callbackGeneration)
}

private func delayedCallbacksAcrossClaims() {
    let hops = PendingHops()
    var clock = Clock()
    let box = PolicyBox(installed())
    let callbacks = relay(box, hops)
    _ = tick(box, &clock, [pad(1)])

    // Current registration: a fast off-main press/release is captured once.
    let current = token(box)
    callbacks.post(current, .primaryClick, pressed: true, onMainThread: false)
    callbacks.post(current, .primaryClick, pressed: false, onMainThread: false)
    hops.runAll()
    check(tick(box, &clock, [pad(1)]).presses == [.primaryClick], "fast off-main press on the current registration")

    // A -> B with the same controller still connected: A's callback is still in
    // flight when the claim changes and must not become a B press.
    let registeredForA = token(box)
    callbacks.post(registeredForA, .enter, pressed: true, onMainThread: false)
    _ = box.policy.offer(.init(owner: ownerB, target: key("hostB", 42, FakeConnection())), preempt: true, currentIsLive: true)
    _ = tick(box, &clock, [pad(1)])
    hops.runAll()
    check(box.rejected == 1, "late callback from the retired A registration is rejected")
    check(tick(box, &clock, [pad(1)]).presses.isEmpty, "late A callback never presses on B")

    // Release -> reclaim by the same owner and target has the same hazard.
    let beforeRelease = token(box)
    callbacks.post(beforeRelease, .secondaryClick, pressed: true, onMainThread: false)
    _ = box.policy.release(owner: ownerB)
    _ = box.policy.offer(.init(owner: ownerB, target: key("hostB", 42, FakeConnection())), preempt: false, currentIsLive: false)
    _ = tick(box, &clock, [pad(1)])
    hops.runAll()
    check(tick(box, &clock, [pad(1)]).presses.isEmpty, "late callback across release and reclaim is rejected")

    // A stale release must not arm a button still held through the fence;
    // otherwise the next poll would turn the old hold into a new press.
    _ = tick(box, &clock, [pad(1, held: [.primaryClick])])
    let heldUnderOld = token(box)
    callbacks.post(heldUnderOld, .primaryClick, pressed: false, onMainThread: false)
    _ = box.policy.offer(.init(owner: ownerA, target: key("hostA", 7, FakeConnection())), preempt: true, currentIsLive: true)
    _ = tick(box, &clock, [pad(1, held: [.primaryClick])])
    hops.runAll()
    check(tick(box, &clock, [pad(1, held: [.primaryClick])]).presses.isEmpty,
          "stale release is discarded before it can rearm a held button")

    // Readiness loss and regain retire registrations made while not ready.
    _ = tick(box, &clock, [pad(1)])
    _ = tick(box, &clock, ready: false, [pad(1)])
    let whileHidden = token(box)
    callbacks.post(whileHidden, .escape, pressed: true, onMainThread: false)
    _ = tick(box, &clock, [pad(1)])
    hops.runAll()
    check(tick(box, &clock, [pad(1)]).presses.isEmpty, "callback registered while hidden never fires after regain")

    // In-flight hops are bounded.
    let bounded = relay(box, hops, limit: 4)
    for _ in 0..<40 { bounded.post(token(box), .up, pressed: true, onMainThread: false) }
    check(bounded.pendingCount == 4, "off-main callback hops are bounded")
    hops.runAll()
    check(bounded.pendingCount == 0, "delivered hops release their slots")
}

// MARK: - Controller guide suspension

private func guideSuspendsInput() {
    let hops = PendingHops()
    var clock = Clock()
    let box = PolicyBox(installed())
    let callbacks = relay(box, hops)
    _ = tick(box, &clock, [pad(1)])
    _ = tick(box, &clock, [pad(1, left: right)])

    // A press queued and a callback in flight when the guide opens.
    callbacks.post(token(box), .primaryClick, pressed: true, onMainThread: false)
    box.policy.pressChanged(source: 1, button: .enter, pressed: true)
    let guideA = UUID(), guideB = UUID()
    box.policy.suspend(guideA)
    hops.runAll()
    let behindGuide = tick(box, &clock, [pad(1, left: right, held: [.secondaryClick])])
    check(behindGuide.isEmpty, "nothing reaches the window behind an open guide")
    check(!box.policy.callbackChanged(token(box), button: .escape, pressed: true),
          "callbacks are rejected while the guide is open, even on the current registration")

    // A second guide instance; closing one keeps input suspended.
    box.policy.suspend(guideB)
    box.policy.resume(guideA)
    check(tick(box, &clock, [pad(1, left: right)]).isEmpty, "another open guide keeps input suspended")
    box.policy.resume(UUID())
    check(box.policy.isSuspended, "resuming an unknown guide changes nothing")
    box.policy.resume(guideB)

    // Closing the guide replays nothing; held stick and button must be released.
    let reopened = tick(box, &clock, [pad(1, left: right, held: [.secondaryClick])])
    check(reopened.presses.isEmpty && reopened.moveTo == nil, "queued press and held stick do not act after the guide closes")
    check(tick(box, &clock, [pad(1, left: right, held: [.secondaryClick])]).isEmpty, "held input stays consumed")
    _ = tick(box, &clock, [pad(1)])
    _ = tick(box, &clock, [pad(1, left: right)])
    let fresh = tick(box, &clock, [pad(1, left: right, held: [.primaryClick])])
    check(fresh.moveTo != nil && fresh.presses == [.primaryClick], "fresh input works after the guide closes")
}

@main
enum PeelGameControllerPolicyChecks {
    static func main() {
        twoHostsSameWindowID()
        connectionReplacementRearms()
        paneSwitchDoesNotFight()
        oppositeHeldSenseSticks()
        eitherSenseHalfAlone()
        activeStickRetention()
        deadzoneClampAndAspect()
        idleAndRateBounds()
        shortPressQueueAndFence()
        backgroundAndReconnect()
        sameWindowIDNewAppLifetime()
        delayedCallbacksAcrossClaims()
        guideSuspendsInput()

        if failures.isEmpty {
            print("PeelGameControllerPolicy checks passed")
        } else {
            for failure in failures { print("FAIL: \(failure)") }
            exit(1)
        }
    }
}
