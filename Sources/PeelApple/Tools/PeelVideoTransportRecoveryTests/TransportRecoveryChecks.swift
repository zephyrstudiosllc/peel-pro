import Foundation

// Only dependencies are fake: the runner appends unchanged production methods,
// substituting wall time and dispatch scheduling for deterministic interleavings.
enum FixtureClock { static var date = Date(timeIntervalSince1970: 100) }
final class FixtureScheduler {
    static let main = FixtureScheduler()
    var immediate: [() -> Void] = []
    var delayed: [() -> Void] = []
    func async(execute: @escaping () -> Void) { immediate.append(execute) }
    func asyncAfter(deadline: DispatchTime, execute: @escaping () -> Void) { delayed.append(execute) }
    func drain() { while !immediate.isEmpty { immediate.removeFirst()() } }
    func fireDelayed() { let work = delayed; delayed = []; work.forEach { $0() }; drain() }
    func reset() { immediate = []; delayed = [] }
}
final class NWConnection {
    enum SendCompletion { case contentProcessed((Error?) -> Void) }
    var stateUpdateHandler: ((Int) -> Void)?
    var receiveCompletion: ((Data?, Int?, Bool, Error?) -> Void)?
    var sendCompletion: ((Error?) -> Void)?
    var cancellations = 0
    var sentContents: [Data] = []
    func cancel() { cancellations += 1 }
    func receive(minimumIncompleteLength: Int, maximumLength: Int,
                 completion: @escaping (Data?, Int?, Bool, Error?) -> Void) { receiveCompletion = completion }
    func send(content: Data?, completion: SendCompletion) {
        if let content { sentContents.append(content) }
        if case .contentProcessed(let callback) = completion { sendCompletion = callback }
    }
}
struct PeelRequest { let type: String; let windowId: UInt32 }
struct PeelVideoKeyframeRequestMessage { let windowId: UInt32 }
struct PeelWindow { let windowId: UInt32 }
/// Stand-in for the shared request; its own validation is not under test here.
struct PeelVideoStreamRequest: Codable, Equatable {
    static let capability = "nativeStreamRequestV1"
    let maximumFPS: Int
}
struct VideoStreamHelloMessage: Codable {
    let windowId: UInt32; let pairingID: String?; let capabilities: Set<String>
    let streamRequest: PeelVideoStreamRequest?
}
enum PeelProtocol { static let advertisedClientCapabilities: Set<String> = [] }
enum PeelRuntimeCapability { static let hostRenderedCursor = "cursor" }
enum PeelCapability: String { case hevcVideo, videoKeyframeRequestV1 }
let kCMVideoCodecType_HEVC = 1
func VTIsHardwareDecodeSupported(_ value: Int) -> Bool { false }
func peelReceivePerfNowMs() -> Double { 0 }
final class FixtureCancel { func cancel() {} }
final class FixtureRenderer {
    var diagnosticWindowId: UInt32?
    var diagnosticLabel = "fixture"
    var onFormatChange: ((CGSize) -> Void)?
    var onRecoveryKeyframeNeeded: (() -> Void)?
    var onFrameEnqueued: ((Int, Bool) -> Void)?
    enum Status { case rendering, failed }
    var displayLayer: FixtureRenderer { self }
    var status = Status.rendering
    var requiresFlushToResumeDecoding = false
    var flushes = 0
    func flushAndReset() { flushes += 1 }
    // Renderer drains look up this callback at delivery time, not frame ingress.
    func deliverQueuedFrame() { onFrameEnqueued?(128, true) }
}
typealias CompressedVideoRenderer = FixtureRenderer
enum PeelClientDiagnostics {
    static func logRendererEvent(label: String, windowId: UInt32, reason: String) {}
    static func logStreamEvent(ownerName: String, windowId: UInt32? = nil, message: String) {}
    static func logReceiveChunk(ownerName: String, byteCount: Int, muxBufferBytes: Int, binaryBufferBytes: Int) {}
}
class FixtureState {
    var connection: NWConnection? = NWConnection()
    var isConnectionReady = true
    var isClientVisible = true
    var desiredPullWindowIds: Set<UInt32> = []
    var desiredPullWindowIdentityByWindow: [UInt32: PeelWindow] = [:]
    var startedStreamWindowIds: Set<UInt32> = []
    var streamRepairInProgressWindowIds: Set<UInt32> = []
    var streamStartAttemptAtByWindow: [UInt32: Date] = [:]
    var streamLastRepairAtByWindow: [UInt32: Date] = [:]
    var streamRepairAttemptByWindow: [UInt32: Int] = [:]
    var videoConfigReceivedAtByWindow: [UInt32: Date] = [:]
    var latestVideoConfigByWindow: [UInt32: Int] = [:]
    var videoFrameCountByWindow: [UInt32: Int] = [:]
    var videoLastFrameReceivedAtByWindow: [UInt32: Date] = [:]
    var videoLastFrameByteCountByWindow: [UInt32: Int] = [:]
    var videoLastFrameWasKeyframeByWindow: [UInt32: Bool] = [:]
    var videoReadyWindowIds: Set<UInt32> = []
    var lastFrameAt: [UInt32: Date] = [:]
    var videoRenderers: [UInt32: FixtureRenderer] = [:]
    var videoContentSizeByWindow: [UInt32: CGSize] = [:]
    var videoRendererWindowIds: Set<UInt32> = []
    var hostCapabilities: Set<String> = []
    var snapshotCGImages: [UInt32: Int] = [:]
    var snapshotTimers: [UInt32: FixtureCancel] = [:]
    var inFlight: Set<UInt32> = []
    var inFlightSince: [UInt32: Date] = [:]
    var globalSnapshotsInFlight = 0
    let inFlightTimeout: TimeInterval = 1.5
    let streamFirstFrameTimeout: TimeInterval = 2.5
    let streamRepairCooldown: TimeInterval = 1.25
    let maxStreamRepairsBeforeReconnect = 3
    var streamWatchdog: Timer?
    var isStreamWatchdogRunning = false
    var activeWindowId: UInt32?
    var messages: [PeelRequest] = []
    var disconnects: [String] = []
    func sendJSONMessage(_ message: PeelRequest) { messages.append(message) }
    func sendJSONMessage(_ message: PeelVideoKeyframeRequestMessage) {}
    func handleDisconnectOnce(_ reason: String) { disconnects.append(reason); isConnectionReady = false }
    var starts: Int { messages.filter { $0.type == "startStream" }.count }
    var stops: Int { messages.filter { $0.type == "stopStream" }.count }
}
final class PeelClientBrowser: FixtureState {
    var selectedSession: PeelHostSession?
    var selectedHostKey = "fixture"
}
final class PeelHostSession: FixtureState {
    weak var browser: PeelClientBrowser?
    var hostKey = "fixture"
    var activePairingID: String? = "synthetic"
    var videoConnectionsByWindowId: [UInt32: NWConnection] = [:]
    var videoReceiveBuffersByWindowId: [UInt32: Data] = [:]
    var videoConnectInProgressWindowIds: Set<UInt32> = []
    var lastAnyDataAt = FixtureClock.date
    func onVideoStateQueue(_ work: @escaping () -> Void) { work() }
    func drainBinaryPackets(from buffer: inout Data) { buffer = Data() }
    func openVideoConnectionIfNeeded(windowId: UInt32) {
        if videoConnectionsByWindowId[windowId] == nil { videoConnectionsByWindowId[windowId] = NWConnection() }
    }
}

enum Failure: Error { case transport }
var failures: [String] = []
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { failures.append(message); print("FAIL: " + message) }
}
let window = PeelWindow(windowId: 42)
let id = window.windowId
func prepared() -> (PeelHostSession, NWConnection, PeelClientBrowser) {
    FixtureScheduler.main.reset()
    FixtureClock.date = Date(timeIntervalSince1970: 100)
    let session = PeelHostSession()
    let browser = PeelClientBrowser()
    session.browser = browser; browser.selectedSession = session
    session.desiredPullWindowIds = [id]; session.startedStreamWindowIds = [id]
    session.streamStartAttemptAtByWindow[id] = FixtureClock.date
    session.videoFrameCountByWindow[id] = 73; session.videoReadyWindowIds = [id]
    session.videoLastFrameReceivedAtByWindow[id] = FixtureClock.date
    session.lastFrameAt[id] = FixtureClock.date
    session.videoRenderers[id] = FixtureRenderer()
    browser.videoFrameCountByWindow[id] = 73; browser.videoReadyWindowIds = [id]
    let video = NWConnection(); session.videoConnectionsByWindowId[id] = video
    return (session, video, browser)
}

do {
    let (s, video, b) = prepared()
    s.startVideoReceiveLoop(windowId: id, connection: video)
    video.receiveCompletion?(nil, nil, true, nil)
    FixtureScheduler.main.drain()
    check(video.cancellations == 1 && s.stops == 1, "EOF after frames closes and enters normal repair")
    check(s.videoFrameCountByWindow[id] == 0 && b.videoFrameCountByWindow[id] == 0, "EOF clears both readiness counters")
    check(!s.videoReadyWindowIds.contains(id) && !b.videoReadyWindowIds.contains(id), "EOF clears readiness flags")
    FixtureScheduler.main.fireDelayed()
    check(s.starts == 1 && s.videoConnectionsByWindowId[id] !== video, "EOF restarts a replacement transport")
    check(s.streamRepairAttemptByWindow[id] == 1, "EOF uses bounded existing repair attempts")
}
do {
    let (s, old, _) = prepared()
    s.sendVideoStreamHello(windowId: id, connection: old)
    old.sendCompletion?(Failure.transport) // callback enqueues failure handling
    let replacement = NWConnection(); s.videoConnectionsByWindowId[id] = replacement
    FixtureScheduler.main.drain()
    check(s.videoConnectionsByWindowId[id] === replacement && replacement.cancellations == 0,
          "delayed old hello failure cannot close replacement")
    check(s.videoFrameCountByWindow[id] == 73 && s.stops == 0, "stale failure cannot reset replacement readiness")
}
do {
    let (s, old, _) = prepared()
    s.startVideoReceiveLoop(windowId: id, connection: old)
    let replacement = NWConnection(); s.videoConnectionsByWindowId[id] = replacement
    old.receiveCompletion?(nil, nil, false, Failure.transport)
    FixtureScheduler.main.drain()
    check(s.videoConnectionsByWindowId[id] === replacement && s.stops == 0, "old receive error is ignored")
}
do {
    let (s, video, _) = prepared()
    s.startVideoReceiveLoop(windowId: id, connection: video)
    video.receiveCompletion?(nil, nil, false, Failure.transport)
    FixtureScheduler.main.drain(); FixtureScheduler.main.fireDelayed()
    check(s.starts == 1 && s.stops == 1, "current receive error follows bounded recovery")
}
for excluded in ["hidden", "undesired", "controlNotReady", "controlMissing", "alreadyRepairing"] {
    let (s, video, _) = prepared()
    switch excluded {
    case "hidden": s.isClientVisible = false
    case "undesired": s.desiredPullWindowIds = []
    case "controlNotReady": s.isConnectionReady = false
    case "controlMissing": s.connection = nil
    default: s.streamRepairInProgressWindowIds = [id]
    }
    s.handleUnexpectedVideoConnectionClosure(windowId: id, connection: video, reason: excluded)
    FixtureScheduler.main.drain(); FixtureScheduler.main.fireDelayed()
    check(s.starts == 0 && s.stops == 0, "excluded \(excluded) does not restart")
}
do {
    let (s, video, _) = prepared()
    s.startVideoReceiveLoop(windowId: id, connection: video)
    s.endPullStream(for: window)
    video.receiveCompletion?(nil, nil, true, nil)
    FixtureScheduler.main.drain(); FixtureScheduler.main.fireDelayed()
    check(s.starts == 0 && s.stops == 1, "intentional end and its late EOF never repair")
}
do {
    let (s, _, b) = prepared()
    let renderer = s.videoRenderers[id]
    s.endPullStream(for: window)
    s.beginPullStream(for: window)
    check(s.videoFrameCountByWindow[id] == 0 && b.videoFrameCountByWindow[id] == 0,
          "Return then reopen cannot inherit prior 73-frame readiness")
    check(s.videoRenderers[id] === renderer, "reopen retains image renderer")
    s.startStreamWatchdog()
    FixtureClock.date.addTimeInterval(3)
    s.streamWatchdog?.fire(); FixtureScheduler.main.drain()
    check(s.stops == 2 && s.streamRepairAttemptByWindow[id] == 1, "reopen without fresh frame reaches watchdog repair")
    s.stopStreamWatchdog()
}
do {
    let (s, _, b) = prepared()
    b.connection = s.connection; b.desiredPullWindowIds = [id]; b.startedStreamWindowIds = []
    b.requestStreamStart(windowId: id, reason: "legacy reopen")
    check(b.videoFrameCountByWindow[id] == 0 && s.videoFrameCountByWindow[id] == 0, "browser start resets both owners")
    check(b.streamStartAttemptAtByWindow[id] == s.streamStartAttemptAtByWindow[id], "browser attempt timestamp mirror")
}
do {
    let (s, _, b) = prepared()
    b.selectedHostKey = "another-host"
    s.startedStreamWindowIds = []
    s.requestStreamStart(windowId: id, reason: "background host start")
    check(s.videoFrameCountByWindow[id] == 0 && b.videoFrameCountByWindow[id] == 73,
          "nonselected host cannot reset selected browser readiness")
}
do {
    let (s, video, _) = prepared()
    s.streamLastRepairAtByWindow[id] = FixtureClock.date
    s.streamRepairAttemptByWindow[id] = 1
    s.handleUnexpectedVideoConnectionClosure(windowId: id, connection: video, reason: "cooldown")
    FixtureScheduler.main.drain()
    check(s.stops == 0 && s.streamRepairAttemptByWindow[id] == 1, "loss respects active cooldown")
    s.startStreamWatchdog()
    FixtureClock.date.addTimeInterval(3)
    s.streamWatchdog?.fire(); FixtureScheduler.main.drain(); FixtureScheduler.main.fireDelayed()
    check(s.starts == 1 && s.streamRepairAttemptByWindow[id] == 2, "watchdog recovers cooldown-suppressed EOF")
    for _ in 0..<3 {
        FixtureClock.date.addTimeInterval(3)
        s.streamWatchdog?.fire(); FixtureScheduler.main.drain(); FixtureScheduler.main.fireDelayed()
    }
    check(s.disconnects.count == 1 && s.starts == 2, "retries stop at existing reconnect escalation bound")
    s.stopStreamWatchdog()
}
for transition in ["hidden", "ended", "replacementControl", "supersededRepair"] {
    let (s, video, _) = prepared()
    s.handleUnexpectedVideoConnectionClosure(windowId: id, connection: video, reason: transition)
    FixtureScheduler.main.drain()
    switch transition {
    case "hidden": s.isClientVisible = false
    case "ended": s.endPullStream(for: window)
    case "replacementControl": s.connection = NWConnection()
    default: s.streamLastRepairAtByWindow[id] = FixtureClock.date.addingTimeInterval(1)
    }
    FixtureScheduler.main.fireDelayed()
    check(s.starts == 0, "queued repair does not restart after \(transition)")
    if transition == "replacementControl" || transition == "supersededRepair" {
        check(s.streamRepairInProgressWindowIds.contains(id), "old repair does not clear successor marker")
    }
}
do {
    let (s, _, _) = prepared()
    s.startStreamWatchdog()
    FixtureClock.date.addTimeInterval(60)
    s.streamWatchdog?.fire(); FixtureScheduler.main.drain(); FixtureScheduler.main.fireDelayed()
    check(s.stops == 0 && s.starts == 0, "valid static stream is not restarted for age alone")
    s.stopStreamWatchdog()
}
// Exercise the actual production renderer callback and record method, including
// a frame already accepted by the old renderer but delivered after the boundary.
for owner in ["session", "browser"] {
    let (s, _, b) = prepared()
    b.connection = s.connection
    b.desiredPullWindowIds = [id]; b.startedStreamWindowIds = [id]
    b.streamStartAttemptAtByWindow[id] = FixtureClock.date
    let renderer = owner == "session"
        ? s.makeVideoRenderer(windowId: id, reason: "queued before reopen")
        : b.makeVideoRenderer(windowId: id, reason: "queued before reopen")
    FixtureScheduler.main.drain()
    if owner == "session" {
        s.endPullStream(for: window); s.beginPullStream(for: window)
    } else {
        b.endPullStream(for: window); b.beginPullStream(for: window)
    }
    renderer.deliverQueuedFrame()
    check(s.videoFrameCountByWindow[id] == 0 && b.videoFrameCountByWindow[id] == 0,
          "\(owner) queued old frame cannot satisfy reopened attempt")
    check(!s.videoReadyWindowIds.contains(id) && !b.videoReadyWindowIds.contains(id),
          "\(owner) queued old frame cannot restore readiness flags")
    s.startStreamWatchdog()
    FixtureClock.date.addTimeInterval(3)
    s.streamWatchdog?.fire(); FixtureScheduler.main.drain()
    check(s.stops == (owner == "session" ? 2 : 1),
          "\(owner) queued old frame cannot suppress reopened first-frame recovery")
    s.stopStreamWatchdog()
}
for owner in ["session", "browser"] {
    let (s, _, b) = prepared()
    let renderer = owner == "session"
        ? s.makeVideoRenderer(windowId: id, reason: "before transport replacement")
        : b.makeVideoRenderer(windowId: id, reason: "before transport replacement")
    FixtureScheduler.main.drain()
    s.videoConnectionsByWindowId[id] = NWConnection()
    renderer.deliverQueuedFrame()
    check(s.videoFrameCountByWindow[id] == 73 && b.videoFrameCountByWindow[id] == 73,
          "\(owner) callback from replaced socket cannot report a frame")
    s.closeVideoConnection(windowId: id)
    let late = owner == "session"
        ? s.makeVideoRenderer(windowId: id, reason: "late config after terminal close")
        : b.makeVideoRenderer(windowId: id, reason: "late config after terminal close")
    FixtureScheduler.main.drain(); late.deliverQueuedFrame()
    check(s.videoFrameCountByWindow[id] == 73 && b.videoFrameCountByWindow[id] == 73,
          "\(owner) renderer created without transport cannot report a frame")
}
do {
    let (s, _, b) = prepared()
    b.resetVideoStreamReadiness(windowId: id)
    let renderer = b.makeVideoRenderer(windowId: id, reason: "selected current config")
    FixtureScheduler.main.drain(); renderer.deliverQueuedFrame()
    check(s.videoFrameCountByWindow[id] == 1 && b.videoFrameCountByWindow[id] == 1 &&
          s.videoReadyWindowIds.contains(id) && b.videoReadyWindowIds.contains(id),
          "current browser renderer restores readiness in both owners")
    let legacy = PeelClientBrowser()
    let legacyRenderer = legacy.makeVideoRenderer(windowId: id, reason: "legacy control stream")
    FixtureScheduler.main.drain(); legacyRenderer.deliverQueuedFrame()
    check(legacy.videoFrameCountByWindow[id] == 1, "legacy browser without session retains frame admission")
}
do {
    let (s, video, b) = prepared()
    let renderer = s.makeVideoRenderer(windowId: id, reason: "queued before terminal event")
    FixtureScheduler.main.drain()
    s.streamLastRepairAtByWindow[id] = FixtureClock.date
    s.streamRepairAttemptByWindow[id] = 1
    s.handleUnexpectedVideoConnectionClosure(windowId: id, connection: video, reason: "cooldown")
    FixtureScheduler.main.drain()
    renderer.deliverQueuedFrame()
    check(s.videoFrameCountByWindow[id] == 0 && b.videoFrameCountByWindow[id] == 0,
          "queued terminal frame cannot restore readiness during cooldown")
    check(s.streamLastRepairAtByWindow[id] == FixtureClock.date && s.streamRepairAttemptByWindow[id] == 1,
          "queued terminal frame cannot erase repair bounds")
    s.startStreamWatchdog(); FixtureClock.date.addTimeInterval(3)
    s.streamWatchdog?.fire(); FixtureScheduler.main.drain(); FixtureScheduler.main.fireDelayed()
    check(s.starts == 1 && s.streamRepairAttemptByWindow[id] == 2,
          "queued terminal frame cannot suppress cooldown retry")
    let current = s.makeVideoRenderer(windowId: id, reason: "replacement config")
    FixtureScheduler.main.drain(); current.deliverQueuedFrame()
    check(s.videoFrameCountByWindow[id] == 1 && s.videoReadyWindowIds.contains(id),
          "replacement config renderer can satisfy current attempt")
    FixtureClock.date.addTimeInterval(60)
    let stops = s.stops
    s.streamWatchdog?.fire(); FixtureScheduler.main.drain(); FixtureScheduler.main.fireDelayed()
    check(s.stops == stops, "accepted static replacement frame does not cause age-only restarts")
    s.stopStreamWatchdog()
}
// Video hello identity. Debug builds defer an explicit native stream request to
// the main queue and send it only if the same control connection, window socket
// and desired stream are still current; Release never sends a request.
func sentHellos(_ connection: NWConnection) -> [VideoStreamHelloMessage] {
    connection.sentContents.compactMap { try? JSONDecoder().decode(VideoStreamHelloMessage.self, from: $0.dropLast()) }
}
do {
    let (s, video, _) = prepared()
    s.sendVideoStreamHello(windowId: id, connection: video)
    let hellos = sentHellos(video)
    check(hellos.count == 1 && hellos.first?.windowId == id && hellos.first?.pairingID == "synthetic",
          "plain hello is sent at once for its own window and pairing")
    check(hellos.first?.streamRequest == nil &&
          hellos.first?.capabilities.contains(PeelVideoStreamRequest.capability) == false &&
          hellos.first?.capabilities.contains(PeelRuntimeCapability.hostRenderedCursor) == true,
          "plain hello carries no stream request or request capability")
}
let request = PeelVideoStreamRequest(maximumFPS: 90)
#if DEBUG
do {
    let (s, video, _) = prepared()
    s.sendVideoStreamHello(windowId: id, connection: video, nativeExperimentRequest: request)
    check(video.sentContents.isEmpty, "native request hello is deferred to the main queue")
    FixtureScheduler.main.drain()
    let hellos = sentHellos(video)
    check(hellos.count == 1 && hellos.first?.streamRequest == request &&
          hellos.first?.capabilities.contains(PeelVideoStreamRequest.capability) == true,
          "deferred hello carries the exact request and its capability")
}
do {
    let (s, old, _) = prepared()
    s.sendVideoStreamHello(windowId: id, connection: old, nativeExperimentRequest: request)
    let replacement = NWConnection(); s.videoConnectionsByWindowId[id] = replacement
    FixtureScheduler.main.drain()
    check(old.sentContents.isEmpty && replacement.sentContents.isEmpty,
          "a request deferred for a replaced window socket is not sent")
}
do {
    let (s, video, _) = prepared()
    s.sendVideoStreamHello(windowId: id, connection: video, nativeExperimentRequest: request)
    s.connection = NWConnection()
    FixtureScheduler.main.drain()
    check(video.sentContents.isEmpty, "a request deferred across a control reconnect is not sent")
}
do {
    let (s, video, _) = prepared()
    s.sendVideoStreamHello(windowId: id, connection: video, nativeExperimentRequest: request)
    s.isClientVisible = false
    FixtureScheduler.main.drain()
    check(video.sentContents.isEmpty, "a request deferred while the client hides is not sent")
}
do {
    let (s, video, _) = prepared()
    s.sendVideoStreamHello(windowId: id, connection: video, nativeExperimentRequest: request)
    s.desiredPullWindowIds = []
    FixtureScheduler.main.drain()
    check(video.sentContents.isEmpty, "a request deferred after its stream is no longer desired is not sent")
}
#else
do {
    let (s, video, _) = prepared()
    s.sendVideoStreamHello(windowId: id, connection: video, nativeExperimentRequest: request)
    let hellos = sentHellos(video)
    check(hellos.count == 1 && hellos.first?.streamRequest == nil &&
          hellos.first?.capabilities.contains(PeelVideoStreamRequest.capability) == false,
          "Release sends a plain hello immediately and never the native request")
}
#endif
if failures.isEmpty { print("PASS: \(checks) production video transport/reopen recovery assertions") }
exit(failures.isEmpty ? 0 : 1)
