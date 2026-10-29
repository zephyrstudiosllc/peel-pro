struct PeelWindow {
    let windowId: UInt32
    let appName: String
    let title: String
    let appLaunchTimeIntervalSince1970: TimeInterval?
}

var count = 0
func check(_ passes: @autoclosure () -> Bool, _ message: String) {
    count += 1
    guard passes() else { fatalError(message) }
}

typealias Layout = PeelPhoneWorkspaceLayout
func visible(_ selected: PeelPhoneWorkspacePane, _ split: Bool, companion: UInt32? = 2) -> Set<UInt32> {
    let geometry = PeelPhoneWorkspaceGeometry.resolve(
        size: split ? CGSize(width: 1000, height: 700) : CGSize(width: 400, height: 700),
        regularWidth: split, selected: selected, hasCompanion: companion != nil && companion != 1
    )
    var ids: Set<UInt32> = []
    if geometry.visiblePanes.contains(.primary) { ids.insert(1) }
    if geometry.visiblePanes.contains(.companion), let companion { ids.insert(companion) }
    return ids
}
check(visible(.primary, true) == [1, 2], "unfolded keeps editor and preview visible")
check(visible(.companion, true) == [1, 2], "selecting preview does not remove editor when wide")
check(visible(.primary, false) == [1], "compact primary selection hides companion")
check(visible(.companion, false) == [2], "folding keeps selected companion visible")
check(visible(.companion, false, companion: nil) == [1], "closing companion always restores primary")
check(visible(.companion, true, companion: 1) == [1], "primary handoff to companion cannot duplicate stream ownership")

let wide: Set<UInt32> = [1, 2]
let fold = Layout.streamTransition(current: wide, desired: visible(.companion, false))
check(fold.start.isEmpty && fold.stop == [1], "fold stops only hidden primary, retaining selected stream")
let unfold = Layout.streamTransition(current: [2], desired: wide)
check(unfold.start == [1] && unfold.stop.isEmpty, "unfold starts only hidden stream, retaining companion")
let switchCompact = Layout.streamTransition(current: [1], desired: [2])
check(switchCompact.start == [2] && switchCompact.stop == [1], "compact pane switch updates exactly two stream memberships")
let primaryHandoff = Layout.streamTransition(current: wide, desired: [2])
check(!primaryHandoff.stop.contains(2) && !primaryHandoff.start.contains(2), "companion becoming primary retains its stream")
let close = Layout.streamTransition(current: wide, desired: [1])
check(close.start.isEmpty && close.stop == [2], "closing second pane leaves editor stream intact")
let dismiss = Layout.streamTransition(current: wide, desired: [])
check(dismiss.start.isEmpty && dismiss.stop == wide, "dismiss releases both owned streams")
let stable = Layout.streamTransition(current: wide, desired: wide)
check(stable.start.isEmpty && stable.stop.isEmpty, "selection in split layout does not restart either stream")

let repaired = Layout.streamTransition(current: wide.intersection([1]), desired: wide)
check(repaired.start == [2] && repaired.stop.isEmpty, "reconcile restarts only a stream dropped from actual desired state")

func identity(_ id: UInt32 = 1, app: String = "Terminal", title: String = "editor", launch: TimeInterval? = 100) -> PeelPhoneWorkspaceWindowIdentity {
    PeelPhoneWorkspaceWindowIdentity(PeelWindow(windowId: id, appName: app, title: title, appLaunchTimeIntervalSince1970: launch))
}
check(identity().isSameLifetime(as: identity(title: "build finished")), "primary title drift can refresh within proved process lifetime")
check(identity(2).isSameLifetime(as: identity(2, title: "tests finished")), "companion title drift can refresh within proved process lifetime")
check(!identity().isSameLifetime(as: identity(launch: 200)), "changed process launch rejects recycled window ID")
check(!identity().isSameLifetime(as: identity(app: "Other App")), "same window ID cannot migrate to another app")
check(!identity().isSameLifetime(as: identity(3)), "same process cannot substitute another window")
check(identity(launch: nil).isSameLifetime(as: identity(launch: nil)), "unknown launch retains original strict title fallback")
check(!identity(launch: nil).isSameLifetime(as: identity(title: "new title", launch: nil)), "unknown launch cannot excuse changed title")
check(!identity().isSameLifetime(as: identity(launch: nil)), "lost process identity is rejected")
check(!identity(launch: 0).isSameLifetime(as: identity(launch: 0)), "zero launch is not positive identity")
check(!identity(launch: .infinity).isSameLifetime(as: identity(launch: .infinity)), "nonfinite launch is rejected")
check(!identity(launch: .nan).isSameLifetime(as: identity(launch: .nan)), "NaN launch is rejected")

var lifetime = PeelPhoneWorkspaceLifetime()
let beforeAppearance = lifetime.generation
check(!lifetime.admits(beforeAppearance), "unmounted workspace cannot start streams")
lifetime.appear()
let firstAppearance = lifetime.generation
check(lifetime.admits(firstAppearance), "mounted workspace admits current deferred work")
check(!lifetime.admits(beforeAppearance), "appearance retires work queued before mounting")
lifetime.disappear()
check(!lifetime.isPresent && !lifetime.admits(firstAppearance), "dismiss retires queued window-list work before stream cleanup")
lifetime.appear()
check(!lifetime.admits(firstAppearance), "reappearance cannot revive old yielded reconcile")
check(lifetime.admits(lifetime.generation), "new appearance can admit its own work")
check(Layout.allowsInput(isPresent: true, selected: true, showingPicker: false, sourceIsCurrent: true), "selected visible workspace admits input")
check(!Layout.allowsInput(isPresent: true, selected: true, showingPicker: true, sourceIsCurrent: true), "window picker suspends underlying Mac input")
check(!Layout.allowsInput(isPresent: false, selected: true, showingPicker: false, sourceIsCurrent: true), "dismissed workspace cannot admit late input")
check(!Layout.allowsInput(isPresent: true, selected: false, showingPicker: false, sourceIsCurrent: true), "passive pane cannot admit input")
check(!Layout.allowsInput(isPresent: true, selected: true, showingPicker: false, sourceIsCurrent: false), "retired source session cannot admit a late old-pane input")
check(!Layout.allowsInput(isPresent: true, selected: true, showingPicker: false, sourceIsCurrent: true, sceneIsInputOwner: false), "eligible but non-owning scene cannot admit same-window input")
print("Phone workspace policy: PASS (\(count) checks)")
