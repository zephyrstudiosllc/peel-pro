import Foundation

struct PeelWindow {
    let windowId: UInt32
    let appName: String
    let title: String
    let appLaunchTimeIntervalSince1970: TimeInterval?
}

@MainActor
final class PeelHostSession {
    var windows: [PeelWindow] = []
    var desiredPullWindowIds: Set<UInt32> = []
    var activeWindowId: UInt32? = 1
    var started: [UInt32] = []
    var stopped: [UInt32] = []
    var focused: [UInt32] = []
    var forcedPointerReleases = 0

    func currentWindowInstanceMatches(_ window: PeelWindow) -> Bool {
        windows.contains { $0.windowId == window.windowId && $0.appName == window.appName && $0.title == window.title && $0.appLaunchTimeIntervalSince1970 == window.appLaunchTimeIntervalSince1970 }
    }
    func beginPullStream(for window: PeelWindow) {
        started.append(window.windowId)
        desiredPullWindowIds.insert(window.windowId)
        if activeWindowId == nil { activeWindowId = window.windowId }
    }
    func endPullStream(for window: PeelWindow) {
        stopped.append(window.windowId)
        desiredPullWindowIds.remove(window.windowId)
    }
    func setActiveWindow(_ id: UInt32) { activeWindowId = id; focused.append(id) }
    func forceMouseUpIfNeeded(reason: String) { forcedPointerReleases += 1 }
}

@main
@MainActor
struct LeaseChecks {
    static func main() {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            count += 1
            guard value() else { fatalError(message) }
        }
        func window(_ id: UInt32, _ title: String = "Editor", _ launch: TimeInterval? = 100) -> PeelWindow {
            PeelWindow(windowId: id, appName: "Mac App", title: title, appLaunchTimeIntervalSince1970: launch)
        }
        let one = window(1), two = window(2, "Preview")
        let first = UUID(), second = UUID()
        let manager = PeelPhoneWorkspaceStreams()
        let session = PeelHostSession(); session.windows = [one, two]
        manager.update(owner: first, session: session, windows: [1: one], selectedWindowID: 1, canRestoreActiveSelection: true)
        manager.update(owner: second, session: session, windows: [1: one], selectedWindowID: 1, canRestoreActiveSelection: true)
        check(session.started == [1], "two scenes sharing one window start its stream once")
        manager.release(owner: first, session: session)
        check(session.stopped.isEmpty && session.desiredPullWindowIds == [1], "closing one scene retains the other scene's identical window")
        manager.release(owner: second, session: session)
        check(session.stopped == [1], "last scene releases its stream exactly once")

        session.started = []; session.stopped = []
        manager.update(owner: first, session: session, windows: [1: one, 2: two], selectedWindowID: 2, canRestoreActiveSelection: true)
        manager.update(owner: second, session: session, windows: [2: two], selectedWindowID: 2, canRestoreActiveSelection: true)
        manager.update(owner: first, session: session, windows: [2: two], selectedWindowID: 2, canRestoreActiveSelection: true)
        check(session.stopped == [1] && session.desiredPullWindowIds == [2], "primary promotion retains a companion shared by another scene")
        manager.release(owner: first, session: session)
        check(session.stopped == [1] && session.desiredPullWindowIds == [2], "closing promoted workspace leaves shared companion running")
        session.desiredPullWindowIds.remove(2); session.started = []
        manager.update(owner: second, session: session, windows: [2: two], selectedWindowID: 2, canRestoreActiveSelection: true)
        check(session.started == [2], "dropped actual desired stream is repaired without duplicate ownership")

        let renamed = window(2, "Build finished")
        session.windows = [one, renamed]; session.desiredPullWindowIds.remove(2); session.started = []
        manager.update(owner: second, session: session, windows: [2: two], selectedWindowID: 2, canRestoreActiveSelection: true)
        check(session.started == [2], "same process title change refreshes saved owners before repair")
        session.windows = [one, window(2, "New process", 200)]; session.stopped = []
        manager.update(owner: second, session: session, windows: [2: two], selectedWindowID: 2, canRestoreActiveSelection: true)
        check(session.stopped == [2] && session.desiredPullWindowIds.isEmpty, "changed app lifetime cannot inherit a prior scene stream")
        manager.release(owner: second, session: session)

        let recovery = PeelHostSession(); recovery.windows = [one, two]; recovery.activeWindowId = nil
        manager.update(owner: first, session: recovery, windows: [1: one, 2: two], selectedWindowID: 1, canRestoreActiveSelection: false)
        check(recovery.started.isEmpty && recovery.focused.isEmpty, "non-key scene cannot choose arbitrary recovery focus")
        manager.update(owner: second, session: recovery, windows: [2: two], selectedWindowID: 2, canRestoreActiveSelection: true)
        check(recovery.focused == [2] && recovery.activeWindowId == 2 && Set(recovery.started) == [1, 2], "key scene restores its selected target before all owned streams begin")
        manager.update(owner: first, session: recovery, windows: [1: one], selectedWindowID: 1, canRestoreActiveSelection: true)
        check(recovery.focused == [2], "passive list updates preserve an existing shared selection")

        let replacement = PeelHostSession(); replacement.windows = [one]
        manager.update(owner: first, session: replacement, windows: [1: one], selectedWindowID: 1, canRestoreActiveSelection: true)
        manager.release(owner: first, session: recovery)
        check(replacement.desiredPullWindowIds == [1] && replacement.stopped.isEmpty, "old scene release cannot stop replacement-session stream")

        let input = PeelHostSession(); input.windows = [one]
        manager.update(owner: first, session: input, windows: [1: one], selectedWindowID: 1, canRestoreActiveSelection: true)
        manager.update(owner: second, session: input, windows: [1: one], selectedWindowID: 1, canRestoreActiveSelection: true)
        check(manager.ownsInput(owner: first, session: input) && !manager.ownsInput(owner: second, session: input), "passive same-window scene cannot duplicate native input ownership")
        manager.claimInput(owner: second, session: input)
        check(!manager.ownsInput(owner: first, session: input) && manager.ownsInput(owner: second, session: input), "explicit activation retires old scene live input even when CG window ID is identical")
        manager.update(owner: first, session: input, windows: [1: one], selectedWindowID: 1, canRestoreActiveSelection: true)
        check(manager.ownsInput(owner: second, session: input), "fresh list from another eligible scene cannot steal input")
        manager.claimInput(owner: UUID(), session: input)
        check(manager.ownsInput(owner: second, session: input), "unregistered scene cannot claim input")
        manager.update(owner: second, session: input, windows: [1: one], selectedWindowID: 1, canRestoreActiveSelection: false)
        manager.update(owner: first, session: input, windows: [1: one], selectedWindowID: 1, canRestoreActiveSelection: true)
        check(manager.ownsInput(owner: first, session: input), "active eligible scene can replace an inactive owner")
        manager.claimInput(owner: second, session: input)
        manager.release(owner: second, session: input)
        check(manager.ownsInput(owner: first, session: input), "closing input owner promotes a remaining eligible scene")
        manager.release(owner: first, session: input)
        check(!manager.ownsInput(owner: first, session: input) && !manager.ownsInput(owner: second, session: input), "last scene clears session input ownership")

        let promotion = PeelHostSession(); promotion.windows = [one, two]
        manager.update(owner: first, session: promotion, windows: [1: one], selectedWindowID: 1, canRestoreActiveSelection: true)
        manager.update(owner: second, session: promotion, windows: [2: two], selectedWindowID: 2, canRestoreActiveSelection: true)
        check(promotion.activeWindowId == 1, "mounting another eligible workspace does not steal the current window")
        manager.release(owner: first, session: promotion)
        check(manager.ownsInput(owner: second, session: promotion) && promotion.activeWindowId == 2,
              "closing the owner restores the surviving scene's different selected window")
        manager.update(owner: first, session: promotion, windows: [1: one], selectedWindowID: 1, canRestoreActiveSelection: true)
        let retiringDrag = UUID()
        manager.claimPointer(owner: second, interaction: retiringDrag, session: promotion)
        manager.update(owner: second, session: promotion, windows: [2: two], selectedWindowID: 2, canRestoreActiveSelection: false)
        manager.update(owner: first, session: promotion, windows: [1: one], selectedWindowID: 1, canRestoreActiveSelection: true)
        check(promotion.activeWindowId == 1 && manager.ownsInput(owner: first, session: promotion),
              "scene eligibility transfer restores the promoted scene's window")
        check(promotion.forcedPointerReleases == 1 && !manager.mayReleasePointer(owner: second, interaction: retiringDrag, session: promotion),
              "ownership transfer releases the retiring pointer before another scene can send input")
        manager.release(owner: first, session: promotion)
        manager.release(owner: second, session: promotion)

        let oldDrag = UUID(), newDrag = UUID()
        manager.claimPointer(owner: first, interaction: oldDrag, session: replacement)
        check(manager.mayReleasePointer(owner: first, interaction: oldDrag, session: replacement), "gesture can release its own pointer")
        manager.claimPointer(owner: second, interaction: newDrag, session: replacement)
        check(!manager.mayReleasePointer(owner: first, interaction: oldDrag, session: replacement), "late old-scene drag end cannot release another scene's pointer on the same window")
        manager.release(owner: first, session: replacement)
        check(replacement.forcedPointerReleases == 0, "closing non-owning scene does not release current pointer")
        check(manager.mayReleasePointer(owner: second, interaction: newDrag, session: replacement), "current gesture retains pointer ownership")
        manager.release(owner: second, session: replacement)
        check(replacement.forcedPointerReleases == 1, "closing owning scene releases its pointer")
        print("Phone workspace scene leases: PASS (\(count) checks)")
    }
}
