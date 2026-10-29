import Foundation

/* PRODUCTION_TYPES */

// Only external effects are recorded; none of these objects opens a transport,
// captures content, reads preferences or permissions, or injects native input.
final class HostNetworkServer {
    var currentGeneration: UInt64 = 0
    var sentMessages = 0
    func isCurrentControlGeneration(_ generation: UInt64) -> Bool { generation == currentGeneration }
    func sendJSONLine<T: Encodable>(_ message: T) { sentMessages += 1 }
}
struct PeelVideoStreamRequest {}
enum FixturePermissions {
    struct Standard { func bool(forKey key: String) -> Bool { FixturePermissions.allowed } }
    static let standard = Standard()
    static var allowed = true
    static var axTrusted = true
}
final class RecordedStreamer {
    var enumerations = 0
    var snapshots = 0
    var stopped: [UInt32] = []
    var capabilityUpdates = 0
    func requestSendWindowList() { enumerations += 1 }
    func stopStreaming(windowId: UInt32) { stopped.append(windowId) }
    func requestSnapshot(windowId: UInt32) { snapshots += 1 }
    func markInput(windowId: UInt32?) {}
    func setVideoCapabilities(_ capabilities: Set<String>, windowId: UInt32, streamRequest: PeelVideoStreamRequest?) {
        capabilityUpdates += 1
    }
}
final class RecordedInput {
    enum Reason { case clientHidden, controlBlocked }
    var resets = 0
    var events = 0
    func resetSessionState(reason: Reason) { resets += 1 }
    func performClick(windowId: UInt32, normX: Double, normY: Double, button: String) { events += 1 }
    func performMouseMove(windowId: UInt32, normX: Double, normY: Double) { events += 1 }
    func performScroll(windowId: UInt32?, deltaX: Double, deltaY: Double) { events += 1 }
    func performMouseDown(windowId: UInt32, normX: Double, normY: Double, button: String) { events += 1 }
    func performMouseDragged(windowId: UInt32, normX: Double, normY: Double, button: String) { events += 1 }
    func performMouseUp(windowId: UInt32, normX: Double, normY: Double, button: String) { events += 1 }
}
final class RecordedAudio {
    var stops = 0
    func stop(reason: String) { stops += 1 }
}
final class RecordedDiagnostics {
    var clears = 0
    func clearObservation() { clears += 1 }
}
final class RecordedAwake {
    var holding = false
    var starts = 0
    var stops = 0
    func start(reason: String, keepDisplayAwake: Bool) { holding = true; starts += 1 }
    func stop() { holding = false; stops += 1 }
}

final class HostFixture {
    static let allowControlThisMacDefaultsKey = "fixture-only"
    let network = HostNetworkServer()
    let streamer = RecordedStreamer()
    let input = RecordedInput()
    let audioController = RecordedAudio()
    let receiverDiagnostics = RecordedDiagnostics()
    let awake = RecordedAwake()
    var hostIsLockedOrAsleep = false
    var preventSleepEnabled = true
    var lastAwakeShouldHold = false
    var lastAwakeKeepDisplay = false
    var lastClientPingAt = Date.distantPast
    var agentAuthorizedSession: Int?
    var pendingAgentChallenge: Int?
    var manualAgentAuthorizedSession: Int?
    var pendingManualAgentChallenge: Int?
    var agentAuthorizationStarts = 0
    var manualAuthorizationStarts = 0
    var rejectedLines = 0
    var decodeFailures = 0
    func clearAgentAuthorization() { agentAuthorizedSession = nil; manualAgentAuthorizedSession = nil }
    func beginAgentAuthorization() { agentAuthorizationStarts += 1 }
    func beginManualAgentAuthorization() { manualAuthorizationStarts += 1 }
    func startClientPingMonitor() {}
    func stopClientPingMonitor() {}
    func logRejectedClientFocusLine(_ line: String, generation: UInt64?, reason: String) { rejectedLines += 1 }
    var visible: Bool { clientIsVisible }
    var reportedVisibility: Bool { clientHasReportedVisibility }
    var inputAllowed: Bool { isRemoteControlAllowed() }
    // Models the old missed-lifecycle condition that enumeration deliberately
    // repaired before explicit visibility existed. This is not an alternate
    // implementation of the production visibility transition.
    func previousLifecycleLeftInactive() { clientIsVisible = false; updateAwakePolicy() }
    func setLocked(_ locked: Bool) { hostIsLockedOrAsleep = locked; updateAwakePolicy() }
    func report(_ visible: Bool, generation: UInt64) {
        let encoded = try! JSONEncoder().encode(ClientVisibilityMessage(isVisible: visible))
        receiveVisibility(String(data: encoded, encoding: .utf8)!, generation: generation)
    }
    func enumerate() { handle(request: PeelRequest(type: "requestWindowList")) }
    func requestSnapshot() { handle(request: PeelRequest(type: "requestWindowSnapshot", windowId: 42)) }
    func click() { handle(request: PeelRequest(type: "mouseClick", windowId: 42, normX: 0.5, normY: 0.5)) }
    func openVideo() {
        hostNetworkServer(network, didOpenVideoStreamForWindow: 42, capabilities: [], streamRequest: nil)
    }

/* PRODUCTION_HOST_BOUNDARIES */
}

var assertionCount = 0
var failures: [String] = []
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    assertionCount += 1
    if !condition() { failures.append(message) }
}

// Legacy peers never publish explicit visibility: preserve the actual prior
// lifecycle-repair behavior, including its awake/input/media consequences.
let legacy = HostFixture()
legacy.connect(generation: 1)
legacy.previousLifecycleLeftInactive()
expect(!legacy.visible && !legacy.awake.holding, "legacy starts in the missed-lifecycle condition")
legacy.enumerate()
expect(legacy.visible && !legacy.reportedVisibility, "legacy catalog request still repairs foreground")
expect(legacy.streamer.enumerations == 1 && legacy.awake.holding, "legacy enumeration holds awake as before")
legacy.requestSnapshot(); legacy.click(); legacy.openVideo()
expect(legacy.streamer.snapshots == 2 && legacy.input.events == 1, "legacy visible media and input remain admitted")

// The actual request that followed false visibility was the defect: refreshing
// the catalog must continue without implicitly reauthorizing foreground work.
let hidden = HostFixture()
hidden.connect(generation: 10)
hidden.report(false, generation: 10)
let hiddenAwakeStarts = hidden.awake.starts
expect(hidden.reportedVisibility && !hidden.visible, "current decoded false owns visibility")
expect(hidden.input.resets == 1 && hidden.audioController.stops == 1 && hidden.receiverDiagnostics.clears == 1,
       "real false case still revokes input/audio/receiver observation")
hidden.enumerate(); hidden.enumerate()
expect(hidden.streamer.enumerations == 2, "hidden catalog remains available")
expect(!hidden.visible && !hidden.awake.holding && hidden.awake.starts == hiddenAwakeStarts,
       "catalog does not wake an explicitly hidden receiver")
expect(!hidden.inputAllowed, "real remote-input policy remains false after hidden catalog")
hidden.requestSnapshot(); hidden.click(); hidden.openVideo()
expect(hidden.streamer.snapshots == 0 && hidden.streamer.capabilityUpdates == 0 && hidden.input.events == 0,
       "hidden catalog cannot open video/snapshot or dispatch mouse input")
hidden.handle(request: PeelRequest(type: "stopStream", windowId: 42))
expect(hidden.streamer.stopped == [42], "hidden stream teardown remains allowed")
expect(hidden.agentAuthorizationStarts == 0 && hidden.manualAuthorizationStarts == 0,
       "enumeration does not start agent authorization")

hidden.report(true, generation: 10)
hidden.enumerate(); hidden.requestSnapshot(); hidden.click(); hidden.openVideo()
expect(hidden.visible && hidden.reportedVisibility && hidden.awake.holding, "explicit foreground can resume normally")
expect(hidden.streamer.enumerations == 3 && hidden.streamer.snapshots == 2 && hidden.input.events == 1,
       "foreground enumeration/media/input still work")
expect(hidden.agentAuthorizationStarts == 1 && hidden.manualAuthorizationStarts == 1,
       "only explicit foreground runs the existing authorization path")

// A new control lifecycle starts with its own defaults, independent of whether
// it implements explicit visibility. Old-generation messages cannot claim it.
let replaced = HostFixture()
replaced.connect(generation: 20); replaced.report(false, generation: 20)
replaced.connect(generation: 21)
expect(replaced.visible && !replaced.reportedVisibility, "connect clears the previous receiver's explicit state")
replaced.report(false, generation: 20)
expect(replaced.visible && !replaced.reportedVisibility && replaced.rejectedLines == 1,
       "stale hidden message cannot mark a new session explicit")
replaced.previousLifecycleLeftInactive(); replaced.enumerate()
expect(replaced.visible && !replaced.reportedVisibility, "new legacy receiver retains enumeration recovery")
replaced.report(false, generation: 21)
replaced.report(true, generation: 20); replaced.enumerate()
expect(!replaced.visible && replaced.reportedVisibility && !replaced.awake.holding,
       "stale foreground message cannot wake the current hidden receiver")
replaced.disconnect()
expect(!replaced.visible && !replaced.reportedVisibility && !replaced.awake.holding,
       "disconnect clears visibility ownership and awake state")

// Decode failure cannot disable legacy fallback; only successfully decoded
// explicit messages count. Locked hosts retain their existing rejection order.
let malformed = HostFixture()
malformed.connect(generation: 30)
malformed.receiveVisibility("{\"type\":\"clientVisibility\",\"isVisible\":\"no\"}", generation: 30)
expect(malformed.decodeFailures == 1 && !malformed.reportedVisibility, "malformed visibility cannot claim explicit state")
malformed.previousLifecycleLeftInactive(); malformed.enumerate()
expect(malformed.visible, "malformed visibility does not break legacy recovery")

let locked = HostFixture()
locked.connect(generation: 40); locked.setLocked(true)
locked.report(false, generation: 40); locked.enumerate(); locked.requestSnapshot(); locked.click(); locked.openVideo()
expect(!locked.reportedVisibility && locked.streamer.enumerations == 0 && !locked.awake.holding,
       "locked host drops visibility and catalog before mutation")
expect(locked.streamer.snapshots == 0 && locked.input.events == 0 && !locked.inputAllowed,
       "locked host retains media and input gates")
locked.setLocked(false); locked.report(false, generation: 40); locked.setLocked(true)
locked.report(true, generation: 40); locked.enumerate(); locked.setLocked(false); locked.enumerate()
expect(!locked.visible && locked.reportedVisibility && !locked.awake.holding && locked.streamer.enumerations == 1,
       "foreground message received while locked cannot reactivate hidden state after unlock")

FixturePermissions.allowed = false
legacy.click()
expect(!legacy.inputAllowed && legacy.input.events == 1, "visible enumeration does not bypass control permission")
FixturePermissions.allowed = true; FixturePermissions.axTrusted = false
legacy.click()
expect(!legacy.inputAllowed && legacy.input.events == 1, "visible enumeration does not bypass Accessibility trust")

if failures.isEmpty {
    print("PASS \(assertionCount) Host visibility/catalog boundary assertions")
} else {
    for failure in failures { print("FAIL: \(failure)") }
    exit(1)
}
