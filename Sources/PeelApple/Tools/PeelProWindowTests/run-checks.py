#!/usr/bin/env python3
"""Compile exact production admission and reservation bodies with inert scene/store adapters."""
from pathlib import Path
import subprocess, tempfile

root = Path(__file__).resolve().parents[2]

def function(source, signature):
    start = source.index(signature)
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

policy = (root / 'Shared/Client/PeelWindowAdmission.swift').read_text().split('#if canImport')[0]
common = '''
struct PeelWindow: Equatable { let windowId: UInt32 }
struct HostedPeelWindow { let id: String; let window: PeelWindow }
enum PeeledWindowSceneMode { case locked, resizable }
final class Publisher { var sends = 0; func send() { sends += 1 } }
final class PeelStore {
    var hasProAccess = false
    var freeWindowLimit: Int
    init(_ limit: Int) { freeWindowLimit = limit }
    func canOpenAdditionalWindow(openWindowCount: Int) -> Bool { hasProAccess || openWindowCount < freeWindowLimit }
}
'''
classes = []
for name, file in [('FlatScenes', 'Peel-iPad/iPadSceneCoordinator.swift'), ('VisionScenes', 'Peel/SceneCoordinator.swift')]:
    source = (root / file).read_text()
    signatures = ['func mountPeeledWindow(', 'func unmountPeeledWindow(', 'private func pruneStalePendingPeeledWindowRequests()', 'private func removeSupersededSceneRegistration(', 'func cancelPendingPeeledWindowSceneReservation(', 'func canOpenAnotherPeeledWindow()', 'private func admittedWindowKeys()', 'func openPeeledWindowSceneCount()']
    if name == 'FlatScenes':
        signatures += ['func reservePeeledWindowScene(for hostedWindow: HostedPeelWindow)', 'func reservePhoneWorkspace(owner:', 'func releasePhoneWorkspace(owner:']
    else:
        signatures += ['func reservePeeledWindowScene(for hostedWindow: HostedPeelWindow)', 'func reservePeeledWindowScene(for hostedWindow: HostedPeelWindow, mode:', 'private func canAdmitImmersiveWindows(']
    methods = '\n'.join(function(source, signature) for signature in signatures)
    classes.append(f'''final class {name} {{
        let objectWillChange = Publisher()
        var commerceStore: PeelStore?
        var peeledWindowSceneIDsByKey: [String: String] = [:]
        var pendingPeeledWindowKeys: Set<String> = []
        var peeledWindowsByKey: [String: {'PeelWindow' if name == 'FlatScenes' else 'HostedPeelWindow'}] = [:]
        var pendingPeeledWindowPlacementSlots: [Int] = []
        var pendingPeeledWindowRequestDatesByKey: [String: Date] = [:]
        var explicitlyClosedPeeledWindowKeys: Set<String> = []
        var phoneWorkspaceWindowsByOwner: [UUID: Set<String>] = [:]
        var mountedPeeledWindowKeysByOwner: [UUID: String] = [:]
        let stalePeeledWindowOpenRequestInterval: TimeInterval = 4
        var peelImmersiveHostedWindows: [HostedPeelWindow] = []
        let maxPeeledWindowSceneCount = 12
        var releasedSlots: [String] = []
        func releasePeeledWindowSlot(forKey key: String) {{ releasedSlots.append(key) }}
        func forgetPeeledWindow(forKey key: String) {{
            pendingPeeledWindowKeys.remove(key); pendingPeeledWindowRequestDatesByKey[key] = nil
            peeledWindowSceneIDsByKey[key] = nil; peeledWindowsByKey[key] = nil
            releasePeeledWindowSlot(forKey:key)
        }}
        func isSameWindowInstance(_ a: PeelWindow, _ b: PeelWindow) -> Bool {{ a == b }}
        func replaceScene(_ id: String, with key: String) {{ removeSupersededSceneRegistration(sceneID:id, keeping:key) }}
        func pruneClosedPeeledWindowScenes() {{ pruneStalePendingPeeledWindowRequests() }}
        func peeledWindowKey(for window: HostedPeelWindow) -> String {{ window.id }}
        func assignPeeledWindowSlotIfNeeded(forKey key: String) -> Int {{ key.utf8.reduce(0) {{ $0 + Int($1) }} }}
        func isPeeledWindowOpen(_ window: HostedPeelWindow) -> Bool {{ pendingPeeledWindowKeys.contains(window.id) || peeledWindowSceneIDsByKey[window.id] != nil }}
        {methods}
        func checkImmersive(_ windows: [HostedPeelWindow]) -> Bool {{ {'canAdmitImmersiveWindows(windows)' if name == 'VisionScenes' else 'false'} }}
    }}''')
checks = r'''
@main struct Checks {
    static func main() {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) { count += 1; precondition(value(), message) }
        func w(_ host: String, _ id: UInt32) -> HostedPeelWindow { HostedPeelWindow(id: "\(host)::windowId:\(id)", window: PeelWindow(windowId: id)) }
        let a = w("mac-a", 1), b = w("mac-a", 2), c = w("mac-b", 1)
        let flat = FlatScenes(), flatStore = PeelStore(1)
        flat.commerceStore = flatStore
        check(flat.reservePeeledWindowScene(for: a), "first flat window is free")
        check(!flat.reservePeeledWindowScene(for: b), "pending first request blocks immediate second before UIKit registers")
        check(flat.reservePeeledWindowScene(for: a), "repeat tap reuses pending window")
        check(flat.openPeeledWindowSceneCount() == 1, "pending repeated tap counts once")
        check(!flat.reservePeeledWindowScene(for: c), "different Mac same CGWindowID still costs a window")
        flat.peeledWindowSceneIDsByKey[a.id] = "scene-a"
        flat.pendingPeeledWindowKeys.remove(a.id)
        check(flat.reservePeeledWindowScene(for: a), "existing registered scene can focus freely")
        flatStore.hasProAccess = true
        check(flat.reservePeeledWindowScene(for: b), "Pro admits second")
        flatStore.hasProAccess = false
        check(flat.reservePeeledWindowScene(for: b), "expiry does not revoke already admitted stream")
        check(!flat.reservePeeledWindowScene(for: c), "expiry blocks addition")
        check(flat.openPeeledWindowSceneCount() == 2, "expiry leaves both active")

        let vision = VisionScenes(), visionStore = PeelStore(2)
        vision.commerceStore = visionStore
        check(vision.reservePeeledWindowScene(for: a, mode: .locked), "first Vision free")
        check(vision.reservePeeledWindowScene(for: b, mode: .resizable), "second Vision free")
        check(!vision.reservePeeledWindowScene(for: c, mode: .locked), "third Vision blocked even while first two pending")
        check(vision.reservePeeledWindowScene(for: a, mode: .resizable), "changing frame mode reuses existing stream")
        check(vision.openPeeledWindowSceneCount() == 2, "mode switch not double charged")
        check(vision.checkImmersive([a,b]), "moving existing windows to immersive is free")
        check(!vision.checkImmersive([a,b,c]), "HUD/display cannot bypass third window gate")
        let immersiveOnly = VisionScenes()
        immersiveOnly.commerceStore = visionStore
        immersiveOnly.peelImmersiveHostedWindows = [a,b]
        check(!immersiveOnly.canOpenAnotherPeeledWindow(), "immersive-only windows consume normal budget")
        check(immersiveOnly.reservePeeledWindowScene(for:a, mode:.resizable), "existing immersive stream can change to regular scene without paying twice")
        check(immersiveOnly.openPeeledWindowSceneCount() == 2, "immersive/regular overlap consumes same two slots")
        visionStore.hasProAccess = true
        check(vision.checkImmersive([a,b,c]), "Pro can add immersive window")
        for id in UInt32(3)...12 { check(vision.reservePeeledWindowScene(for: w("mac-a",id),mode:.locked), "Pro resource slot \(id)") }
        check(!vision.reservePeeledWindowScene(for:w("mac-a",13),mode:.locked), "Pro retains 12 resource cap")

        let phone = FlatScenes(), phoneStore = PeelStore(1), first = UUID(), second = UUID()
        phone.commerceStore = phoneStore
        check(phone.reservePhoneWorkspace(owner:first, windows:[a]), "phone first pane free")
        check(!phone.reservePhoneWorkspace(owner:first, windows:[a,b]), "Duo second pane blocked")
        check(phone.reservePhoneWorkspace(owner:first, windows:[b]), "phone single-window replacement stays free")
        check(!phone.reservePhoneWorkspace(owner:second, windows:[c]), "a second main scene cannot bypass allowance")
        check(phone.reservePhoneWorkspace(owner:second, windows:[b]), "same actual stream in two scenes counts once")
        check(phone.openPeeledWindowSceneCount() == 1, "shared ownership deduplicates")
        check(!phone.reservePhoneWorkspace(owner:first, windows:[c]), "replacement cannot duplicate occupied slot across another owner")
        phone.releasePhoneWorkspace(owner:second)
        check(phone.openPeeledWindowSceneCount() == 1, "releasing sibling preserves owner's slot")
        phoneStore.hasProAccess = true
        check(phone.reservePhoneWorkspace(owner:first, windows:[a,b]), "Pro adds workspace pane")
        phoneStore.hasProAccess = false
        check(phone.reservePhoneWorkspace(owner:first, windows:[a,b]), "rotation and selection preserve admitted two panes after expiry")
        check(!phone.reservePhoneWorkspace(owner:second, windows:[c]), "expired Pro cannot add sibling workspace")
        check(phone.reservePhoneWorkspace(owner:first, windows:[a,c]), "popup/slot replacement keeps existing streams usable after expiry")
        check(phone.reservePhoneWorkspace(owner:first, windows:[a]), "close companion frees its slot")
        check(!phone.reservePhoneWorkspace(owner:first, windows:[a,b]), "closed paid slot cannot be reopened after expiry")
        phone.releasePhoneWorkspace(owner:first)
        check(phone.openPeeledWindowSceneCount() == 0, "closing phone workspace releases allowance")
        check(phone.reservePeeledWindowScene(for:a), "fresh scene uses released slot")
        check(!phone.reservePhoneWorkspace(owner:second, windows:[b]), "phone + separate scene share one budget")
        let canceled = FlatScenes(); canceled.commerceStore = PeelStore(1)
        check(canceled.reservePeeledWindowScene(for:a), "reserve before OS launch")
        canceled.cancelPendingPeeledWindowSceneReservation(for:a)
        check(canceled.openPeeledWindowSceneCount() == 0, "canceling pending scene frees slot")
        check(canceled.reservePeeledWindowScene(for:b), "released slot can open different window")
        canceled.peeledWindowSceneIDsByKey[b.id] = "active"
        canceled.cancelPendingPeeledWindowSceneReservation(for:b)
        check(canceled.openPeeledWindowSceneCount() == 1, "cancel cannot revoke registered stream")
        canceled.replaceScene("active", with:c.id)
        check(canceled.openPeeledWindowSceneCount() == 0 && canceled.releasedSlots.contains(b.id), "launcher successor retires previous scene identity")
        let canceledVision = VisionScenes(); canceledVision.commerceStore = PeelStore(2)
        check(canceledVision.reservePeeledWindowScene(for:a, mode:.locked), "Vision reservation accepted")
        canceledVision.cancelPendingPeeledWindowSceneReservation(for:a)
        check(canceledVision.openPeeledWindowSceneCount() == 0, "Vision canceled restore releases pending reservation")
        let mounted = FlatScenes(), mountedStore = PeelStore(1), owner = UUID()
        mounted.commerceStore = mountedStore
        check(mounted.mountPeeledWindow(owner:owner, for:a), "mount atomically reserves free window")
        mounted.pendingPeeledWindowRequestDatesByKey[a.id] = Date(timeIntervalSinceNow:-10)
        check(mounted.openPeeledWindowSceneCount() == 1, "delayed UIKit registration cannot expire mounted admission")
        check(!mounted.reservePeeledWindowScene(for:b), "another request cannot steal mounted unregistered slot")
        mounted.unmountPeeledWindow(owner:owner, for:a)
        check(mounted.openPeeledWindowSceneCount() == 0, "disappearance releases mounted pending slot")
        check(mounted.reservePeeledWindowScene(for:b), "different scene can consume released slot")
        check(!mounted.mountPeeledWindow(owner:owner, for:a), "reappearance must re-admit after previous slot was consumed")
        mounted.pendingPeeledWindowRequestDatesByKey[b.id] = Date(timeIntervalSinceNow:-10)
        check(mounted.openPeeledWindowSceneCount() == 0, "failed unmounted OS opening still expires")
        check(mounted.mountPeeledWindow(owner:owner, for:a), "reappearance works after capacity returns")
        mounted.peeledWindowSceneIDsByKey[a.id] = "successor-scene"
        mounted.replaceScene("successor-scene", with:b.id)
        check(mounted.mountedPeeledWindowKeysByOwner[owner] == b.id, "successor moves view lease to new represented window")
        check(mounted.openPeeledWindowSceneCount() == 1, "successor lease doesn't double charge old and new keys")
        let mountedVision = VisionScenes(), visionOwner = UUID(), mountedVisionStore = PeelStore(2)
        mountedVision.commerceStore = mountedVisionStore
        check(mountedVision.mountPeeledWindow(owner:visionOwner, for:a), "Vision view admission reserves")
        mountedVision.pendingPeeledWindowRequestDatesByKey[a.id] = Date(timeIntervalSinceNow:-10)
        check(mountedVision.openPeeledWindowSceneCount() == 1, "Vision mounted admission outlives slow registration")
        mountedVision.unmountPeeledWindow(owner:visionOwner, for:a)
        check(mountedVision.openPeeledWindowSceneCount() == 0, "Vision disappearance releases live lease")
        print("Peel Pro window admission: PASS (\(count) checks; exact production reservation/policy bodies)")
    }
}
'''
# Raw string holds normal Swift interpolation; correct escaping used for Python raw literal.
checks = checks.replace('\\\\(', '\\(')
with tempfile.TemporaryDirectory(prefix='peel-pro-window-checks-') as tmp:
    source = Path(tmp) / 'Checks.swift'; binary = Path(tmp) / 'checks'
    source.write_text(policy + common + '\n'.join(classes) + checks)
    subprocess.run(['swiftc','-parse-as-library',str(source),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
