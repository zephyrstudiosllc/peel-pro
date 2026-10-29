private var failures: [String] = []
private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { failures.append(message) }
}
private func resetLinks() { for link in CADisplayLink.live { link.invalidate() } }
private func pan(_ state: UIGestureRecognizer.State) -> UIPanGestureRecognizer {
    let recognizer = UIPanGestureRecognizer()
    recognizer.state = state
    recognizer.velocityValue = CGPoint(x: 500, y: -300)
    recognizer.translationValue = CGPoint(x: 4, y: -8)
    return recognizer
}

private func pointerChecks() {
    let view = UIView()
    var scrolls = 0
    var dragEnds = 0
    var clicks = 0
    var coordinator: PointerCoordinator? = PointerCoordinator { event in
        switch event {
        case .scroll: scrolls += 1
        case .dragEnded, .dragCancelled: dragEnds += 1
        case .primaryClick, .secondaryClick: clicks += 1
        default: break
        }
    }
    coordinator!.view = view
    for state in [UIGestureRecognizer.State.cancelled, .failed] {
        coordinator!.handleScroll(pan(state))
        CADisplayLink.tick()
        check(CADisplayLink.live.isEmpty && scrolls == 0, "pointer cancellation must never create inertia")
        resetLinks()
        scrolls = 0
    }
    coordinator!.handleScroll(pan(.began))
    coordinator!.handleScroll(pan(.changed))
    check(scrolls == 1, "pointer scroll changed event retained")
    coordinator!.handleScroll(pan(.ended))
    CADisplayLink.tick()
    check(scrolls == 2 && CADisplayLink.live.count == 1, "completed pointer scroll keeps inertia")
    coordinator!.handleScroll(pan(.ended))
    check(CADisplayLink.live.count == 1, "pointer repeated end has one timer")
    coordinator!.handlePointerDrag(pan(.began))
    check(CADisplayLink.live.isEmpty, "pointer press stops previous momentum")
    coordinator!.setActive(false)
    coordinator!.setActive(false)
    check(dragEnds == 1, "inactive scene releases held pointer once")
    let countBeforeInactive = scrolls
    coordinator!.handleScroll(pan(.changed))
    coordinator!.handleScroll(pan(.ended))
    let tap = UITapGestureRecognizer(); tap.state = .ended
    coordinator!.handlePrimaryTap(tap)
    check(scrolls == countBeforeInactive && clicks == 0 && CADisplayLink.live.isEmpty,
          "inactive scene cannot send pointer input or restart timers")
    coordinator!.setActive(true)
    let previousClicks = clicks
    coordinator!.handlePrimaryTap(tap)
    check(clicks == previousClicks + 1, "reactivated scene accepts new pointer gestures")
    coordinator!.handleScroll(pan(.began))
    coordinator!.handleScroll(pan(.ended))
    weak let weakCoordinator = coordinator
    coordinator!.invalidate()
    CADisplayLink.tick()
    check(CADisplayLink.live.isEmpty && scrolls == countBeforeInactive, "pointer teardown cancels queued momentum")
    coordinator = nil
    check(weakCoordinator == nil, "pointer teardown breaks display-link retain cycle")
    resetLinks()
}

private func scrollChecks() {
    let view = UIView()
    var scrolls = 0
    var coordinator: ScrollCoordinator? = ScrollCoordinator { _, _ in scrolls += 1 }
    coordinator!.view = view
    for state in [UIGestureRecognizer.State.cancelled, .failed] {
        coordinator!.handlePan(pan(state)); CADisplayLink.tick()
        check(CADisplayLink.live.isEmpty && scrolls == 0, "scroll cancellation must never create inertia")
        resetLinks()
        scrolls = 0
    }
    coordinator!.handlePan(pan(.began))
    coordinator!.handlePan(pan(.changed))
    check(scrolls == 1, "scroll changed event retained")
    coordinator!.handlePan(pan(.ended)); CADisplayLink.tick()
    check(scrolls == 2 && CADisplayLink.live.count == 1, "completed scroll keeps inertia")
    coordinator!.handlePan(pan(.ended))
    check(CADisplayLink.live.count == 1, "repeated scroll end has one timer")
    coordinator!.setActive(false)
    let previousCount = scrolls
    CADisplayLink.tick()
    coordinator!.handlePan(pan(.changed))
    coordinator!.handlePan(pan(.ended))
    check(scrolls == previousCount && CADisplayLink.live.isEmpty, "inactive scroll cannot send or restart momentum")
    coordinator!.setActive(true)
    coordinator!.handlePan(pan(.began))
    coordinator!.handlePan(pan(.ended))
    weak let weakCoordinator = coordinator
    coordinator!.invalidate()
    CADisplayLink.tick()
    check(CADisplayLink.live.isEmpty && scrolls == previousCount, "scroll teardown cancels momentum")
    coordinator = nil
    check(weakCoordinator == nil, "scroll teardown breaks display-link retain cycle")
    resetLinks()
}

private func targetReplacementChecks() {
    let view = UIView()
    var oldScrolls = 0, newScrolls = 0, oldReleases = 0, newDrags = 0
    let oldSink: (IndirectPointerEvent) -> Void = { event in
        if case .scroll = event { oldScrolls += 1 }
        if case .dragCancelled = event { oldReleases += 1 }
    }
    let newSink: (IndirectPointerEvent) -> Void = { event in
        switch event {
        case .scroll: newScrolls += 1
        case .dragBegan, .dragChanged, .dragEnded: newDrags += 1
        default: break
        }
    }
    let pointer = PointerCoordinator(onEvent: oldSink)
    pointer.view = view
    pointer.updateTarget(windowId: 41, isActive: true, onEvent: oldSink)
    pointer.handleScroll(pan(.began)); pointer.handleScroll(pan(.ended)); CADisplayLink.tick()
    check(oldScrolls == 1, "original target receives its completed momentum")
    pointer.updateTarget(windowId: 42, isActive: true, onEvent: newSink)
    CADisplayLink.tick()
    pointer.handleScroll(pan(.changed)); pointer.handleScroll(pan(.ended)); CADisplayLink.tick()
    check(oldScrolls == 1 && newScrolls == 0 && CADisplayLink.live.isEmpty,
          "retargeting discards old momentum and remaining old scroll events")
    pointer.handleScroll(pan(.began)); pointer.handleScroll(pan(.changed))
    pointer.updateTarget(windowId: 42, isActive: true, onEvent: newSink)
    pointer.handleScroll(pan(.ended)); CADisplayLink.tick()
    check(newScrolls == 2, "same-target refresh retains a new scroll gesture")
    pointer.updateTarget(windowId: 41, isActive: true, onEvent: oldSink)
    pointer.handlePointerDrag(pan(.began))
    pointer.updateTarget(windowId: 42, isActive: true, onEvent: newSink)
    pointer.handlePointerDrag(pan(.changed)); pointer.handlePointerDrag(pan(.ended))
    check(oldReleases == 1 && newDrags == 0, "retargeting releases old capture without dragging replacement")
    pointer.handlePointerDrag(pan(.began)); pointer.handlePointerDrag(pan(.changed)); pointer.handlePointerDrag(pan(.ended))
    check(newDrags == 3, "replacement accepts a fresh balanced drag")
    pointer.invalidate(); resetLinks()

    oldScrolls = 0; newScrolls = 0
    let oldScroll: (CGFloat, CGFloat) -> Void = { _, _ in oldScrolls += 1 }
    let newScroll: (CGFloat, CGFloat) -> Void = { _, _ in newScrolls += 1 }
    let scroll = ScrollCoordinator(onScroll: oldScroll)
    scroll.view = view
    scroll.updateTarget(windowId: 41, isActive: true, onScroll: oldScroll)
    scroll.handlePan(pan(.began)); scroll.handlePan(pan(.ended)); CADisplayLink.tick()
    check(oldScrolls == 1, "original scroll target receives momentum")
    scroll.updateTarget(windowId: 42, isActive: true, onScroll: newScroll)
    CADisplayLink.tick()
    scroll.handlePan(pan(.changed)); scroll.handlePan(pan(.ended)); CADisplayLink.tick()
    check(oldScrolls == 1 && newScrolls == 0 && CADisplayLink.live.isEmpty,
          "scroll retargeting drops old momentum and remaining gesture events")
    scroll.handlePan(pan(.began)); scroll.handlePan(pan(.changed))
    scroll.updateTarget(windowId: 42, isActive: true, onScroll: newScroll)
    scroll.handlePan(pan(.ended)); CADisplayLink.tick()
    check(newScrolls == 2, "replacement scroll target accepts new gesture and same-target refresh")
    scroll.invalidate(); resetLinks()
}

pointerChecks()
scrollChecks()
targetReplacementChecks()
if failures.isEmpty { print("PASS: exact pointer/scroll coordinator lifecycle checks") }
else { for failure in failures { print("FAIL: \(failure)") }; exit(1) }
