import Foundation
import CoreGraphics

struct PointerWindow { let windowId: UInt32 = 1 }
final class PointerSession {
    var forceReleases = 0
    var mouseUps = 0
    func forceMouseUpIfNeeded(reason: String) { forceReleases += 1 }
    func currentSharedCursorNorm(for id: UInt32) -> CGPoint { .zero }
    func sendMouseUp(on window: PointerWindow, normX: Double, normY: Double, button: String) { mouseUps += 1 }
}
final class PointerHarness {
    let pointerInteractionID = UUID()
    let runtimeSession = PointerSession()
    let presentedWindow = PointerWindow()
    var workspaceMayReleasePointer: (UUID) -> Bool = { _ in true }
    var mouseDragDidSendDown = true
    var mouseDragStartNorm: CGPoint? = .zero
    var isMouseDragActive = true
    var dragStartTime: Date? = Date()
    var dragStartLocation: CGPoint? = .zero
    var tapCursorNorm: CGPoint?
    var inertiasCancelled = 0
    var scrollResets = 0
    var cursorsEnded = 0
    func cancelDirectScrollInertia() { inertiasCancelled += 1 }
    func resetDirectScrollGesture() { scrollResets += 1 }
    func endDirectCursorInteraction() { cursorsEnded += 1 }
    // POINTER METHODS
}

var count = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    count += 1
    guard value() else { fatalError(message) }
}
let retired = PointerHarness()
retired.workspaceMayReleasePointer = { _ in false }
retired.cancelPointerInteraction(reason: "retired scene resized")
check(retired.runtimeSession.forceReleases == 0, "late resize/dismiss cleanup must not release a sibling scene's new drag")
check(!retired.mouseDragDidSendDown && !retired.isMouseDragActive && retired.mouseDragStartNorm == nil, "retired cleanup still resets its local drag")
check(retired.inertiasCancelled == 1 && retired.scrollResets == 1 && retired.cursorsEnded == 1, "retired cleanup still stops local inertia and cursor feedback")
let own = PointerHarness()
own.cancelPointerInteraction(reason: "own pane reflow")
check(own.runtimeSession.forceReleases == 1, "pane reflow releases its own held pointer")
let oldRelease = PointerHarness()
oldRelease.workspaceMayReleasePointer = { _ in false }
oldRelease.releaseLocalMouseDownIfNeeded()
check(oldRelease.runtimeSession.mouseUps == 0 && !oldRelease.mouseDragDidSendDown, "late mode change cannot release a new owner's drag")
let ownRelease = PointerHarness()
ownRelease.releaseLocalMouseDownIfNeeded()
check(ownRelease.runtimeSession.mouseUps == 1 && !ownRelease.isMouseDragActive, "current mode change sends one mouse up and clears local drag")
ownRelease.releaseLocalMouseDownIfNeeded()
check(ownRelease.runtimeSession.mouseUps == 1, "repeated cleanup does not duplicate mouse up")
print("Phone pane pointer cleanup: PASS (\(count) checks)")
