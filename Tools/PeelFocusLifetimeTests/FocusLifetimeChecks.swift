import Foundation
import OSLog

// Production methods/switch arms are inserted by the runner. Only external I/O,
// AX readiness, user defaults, process metadata, and scheduling are simulated.
final class FixtureScheduler {
    static let main = FixtureScheduler()
    var jobs: [() -> Void] = []
    func async(execute: @escaping () -> Void) { jobs.append(execute) }
    func asyncAfter(deadline: DispatchTime, execute: @escaping () -> Void) { jobs.append(execute) }
    func next() { precondition(!jobs.isEmpty); jobs.removeFirst()() }
    func drain() { while !jobs.isEmpty { next() } }
    func reset() { jobs = [] }
}
final class NWConnection {
    enum SendCompletion { case contentProcessed((Error?) -> Void) }
    var messages: [Data] = []
    func send(content: Data?, completion: SendCompletion) {
        if let content { messages.append(content) }
        if case .contentProcessed(let callback) = completion { callback(nil) }
    }
}
struct MessageEnvelope: Codable { var type: String }
struct ClientActiveWindowMessage: Codable { var windowId: UInt32 }
struct WindowFocusStateMessage: Codable {
    var activeWindowId: UInt32?
    var requestedWindowId: UInt32?
    var didActivateRequestedWindow: Bool
}
enum WindowEnumerator {
    static func isDisplayCaptureWindowId(_ windowId: UInt32) -> Bool { windowId == 999 }
    static func ownerPID(for windowId: UInt32) -> Int32? { 44 }
}
final class NSWorkspace {
    static let shared = NSWorkspace()
    struct Application { var processIdentifier: Int32 = 44 }
    var frontmostApplication: Application? = Application()
}
final class UserDefaults {
    static let standard = UserDefaults()
    func bool(forKey: String) -> Bool { true }
}
func AXIsProcessTrusted() -> Bool { true }
final class FixtureAccessibility {
    var ready = false
    var allowed = true
    var readinessChecks = 0
    var focusCalls: [UInt32] = []
    var callbacks: [() -> Void] = []
    func authoritativePointFallback(for windowId: UInt32) -> CGPoint? { CGPoint(x: 0, y: 0) }
    func bringWindowToFront(windowId: UInt32, interactionPoint: CGPoint?, completion: @escaping () -> Void) {
        focusCalls.append(windowId); callbacks.append(completion)
    }
    func isWindowReadyForInput(windowId: UInt32, interactionPoint: CGPoint?) -> Bool {
        readinessChecks += 1; return allowed && ready
    }
    func complete() { precondition(!callbacks.isEmpty); callbacks.removeFirst()() }
}
final class FixtureStreamer {
    var targets: [UInt32] = []
    func clientActiveWindowDidChange(windowId: UInt32) { targets.append(windowId) }
}
final class HostNetworkServer {
    typealias SendSnapshot = (connection: NWConnection, generation: UInt64)
    var connection: NWConnection? = NWConnection()
    var generation: UInt64 = 7
    var replaceDuringSnapshot = false
    let outboundSendQueue = FixtureScheduler()
    func isCurrentControlGeneration(_ value: UInt64) -> Bool { connection != nil && generation == value }
    func currentSendSnapshot() -> SendSnapshot? {
        if replaceDuringSnapshot { replaceDuringSnapshot = false; generation += 1; connection = NWConnection() }
        return connection.map { ($0, generation) }
    }
    func isCurrentSendSnapshot(_ snapshot: SendSnapshot) -> Bool {
        snapshot.connection === connection && snapshot.generation == generation
    }
    var messages: [WindowFocusStateMessage] {
        (connection?.messages ?? []).compactMap { try? JSONDecoder().decode(WindowFocusStateMessage.self, from: $0) }
    }
}
final class PeelHost {
    let network = HostNetworkServer()
    let accessibility = FixtureAccessibility()
    let streamer = FixtureStreamer()
    let log = Logger(subsystem: "PeelFocusLifetimeChecks", category: "Fixture")
    let focusStateQueue = DispatchQueue(label: "fixture.focus")
    var lastClientActiveWindowId: UInt32?
    var pendingFocusRequestID = UUID()
    let clientFocusDebounce: TimeInterval = 0.075
    static let allowControlThisMacDefaultsKey = "fixture"
    var hostIsLockedOrAsleep = false
    var clientIsVisible = true
}
class ClientState {
    var connection: NWConnection? = NWConnection()
    var activeWindowId: UInt32? = 42
    var hostConfirmedActiveWindowId: UInt32?
    var lastWindowFocusState: WindowFocusStateMessage?
    var focusHistory: [UInt32] = []
    var rateUpdates = 0
    func recordFocusedWindowId(_ id: UInt32) { focusHistory.append(id) }
    func updateStreamRates() { rateUpdates += 1 }
}
final class PeelClientBrowser: ClientState {
    var selectedSession: PeelHostSession?
    var selectedHostKey = "fixture"
}
final class PeelHostSession: ClientState {
    weak var browser: PeelClientBrowser?
    var hostKey = "fixture"
}
// PRODUCTION_METHODS

var assertions = 0
func expect(_ value: @autoclosure () -> Bool, _ text: String) {
    precondition(value(), text); assertions += 1
}
func freshHost() -> PeelHost { FixtureScheduler.main.reset(); return PeelHost() }
func start(_ host: PeelHost, window: UInt32 = 42) {
    host.handleClientActiveWindow(.init(windowId: window), generation: host.network.generation)
}
func drain(_ host: PeelHost) { FixtureScheduler.main.drain(); host.network.outboundSendQueue.drain() }

// Old control session cannot begin a delayed activation or publish its completion.
do {
    let host = freshHost(); start(host); host.network.generation += 1
    drain(host)
    expect(host.accessibility.focusCalls.isEmpty, "Replacement before debounce cannot activate")
    host.handleClientActiveWindow(.init(windowId: 42), generation: 7)
    expect(host.streamer.targets.count == 1, "Already obsolete request cannot update active target")
}
do {
    let host = freshHost(); start(host); FixtureScheduler.main.next()
    host.network.generation += 1; host.accessibility.ready = true; host.accessibility.complete(); drain(host)
    expect(host.network.messages.isEmpty && host.accessibility.readinessChecks == 0, "Old AX completion cannot confirm replacement session")
}
do {
    let host = freshHost(); start(host); FixtureScheduler.main.next(); host.accessibility.complete()
    expect(host.accessibility.readinessChecks == 1, "Current request checks exact readiness")
    host.network.generation += 1; host.accessibility.ready = true; drain(host)
    expect(host.network.messages.isEmpty && host.accessibility.readinessChecks == 1, "Old readiness retry cannot survive replacement")
}
// Same window/request replacement matters even when generation and target match.
do {
    let host = freshHost(); start(host); FixtureScheduler.main.next()
    let oldID = host.pendingFocusRequestID
    start(host); host.accessibility.ready = true; host.accessibility.complete()
    expect(host.accessibility.readinessChecks == 0, "Superseded same-window AX completion cannot confirm")
    host.sendWindowFocusState(activeWindowId: nil, requestedWindowId: 42, didActivateRequestedWindow: false, generation: 7, requestID: oldID)
    expect(host.network.outboundSendQueue.jobs.isEmpty, "Superseded request cannot send a late rejection")
    FixtureScheduler.main.next(); host.accessibility.complete(); drain(host)
    expect(host.network.messages.count == 1 && host.network.messages[0].activeWindowId == 42, "Current replacement request still confirms")
}
do {
    let host = freshHost(); start(host); FixtureScheduler.main.next(); host.accessibility.complete()
    start(host, window: 43); host.accessibility.ready = true; FixtureScheduler.main.drain()
    expect(host.accessibility.readinessChecks == 1, "Superseded retry cannot perform new readiness check")
    host.accessibility.complete(); drain(host)
    expect(host.network.messages.count == 1 && host.network.messages[0].activeWindowId == 43, "Different target owns confirmation")
}
do {
    let host = freshHost(); start(host); start(host, window: 999); drain(host)
    expect(host.accessibility.focusCalls.isEmpty && host.network.messages.count == 1 && host.network.messages[0].activeWindowId == 999, "Display request also invalidates queued app focus")
}
do {
    let host = freshHost(); host.accessibility.ready = true; host.accessibility.allowed = false
    start(host); FixtureScheduler.main.next(); host.accessibility.complete(); drain(host)
    expect(host.accessibility.readinessChecks == 4, "Readiness denial preserves bounded four checks")
    expect(host.network.messages.count == 1 && host.network.messages[0].activeWindowId == nil && !host.network.messages[0].didActivateRequestedWindow, "Denied readiness never confirms")
}
// Snapshot selection race and queued send race retain the originating generation.
do {
    let host = freshHost(); start(host); FixtureScheduler.main.next(); host.accessibility.ready = true
    host.network.replaceDuringSnapshot = true; host.accessibility.complete(); drain(host)
    expect(host.network.messages.isEmpty, "Replacement between host guard and send snapshot cannot receive old confirmation")
}
do {
    let host = freshHost(); start(host); FixtureScheduler.main.next(); host.accessibility.ready = true; host.accessibility.complete()
    let old = host.network.connection!; host.network.connection = NWConnection(); host.network.generation += 1; drain(host)
    expect(old.messages.isEmpty && host.network.messages.isEmpty, "Replacement after enqueue invalidates old socket send")
    host.network.sendJSONLine(WindowFocusStateMessage(activeWindowId: 42, requestedWindowId: 42, didActivateRequestedWindow: true)); drain(host)
    expect(host.network.messages.count == 1, "Existing unbound send callers remain compatible")
}
do {
    let host = freshHost(); let data = try JSONEncoder().encode(ClientActiveWindowMessage(windowId: 42))
    try host.routeFocus(data, generation: nil)
    expect(host.streamer.targets.isEmpty, "Unattributed focus line cannot activate")
    try host.routeFocus(data, generation: 7); FixtureScheduler.main.next()
    expect(host.accessibility.focusCalls == [42], "Received control generation reaches production focus handler")
}
do {
    let host = freshHost()
    expect(!host.ensureWindowIsFrontmostBeforeInput(windowId: 42, inputType: "fixture", generation: 7), "Pre-input path defers until exact readiness")
    host.network.generation += 1; drain(host)
    expect(host.accessibility.focusCalls.isEmpty, "Pre-input delayed focus also belongs to its control generation")
}

// Exercise both actual receive switch arms, including the async publication hop.
let confirmed = try JSONEncoder().encode(WindowFocusStateMessage(activeWindowId: 42, requestedWindowId: 42, didActivateRequestedWindow: true))
let rejected = try JSONEncoder().encode(WindowFocusStateMessage(activeWindowId: nil, requestedWindowId: 42, didActivateRequestedWindow: false))
for isSession in [false, true] {
    FixtureScheduler.main.reset()
    let browser = PeelClientBrowser(); let session = PeelHostSession()
    browser.selectedSession = session; session.browser = browser
    let state: ClientState = isSession ? session : browser
    func receive(_ data: Data, source: NWConnection?) throws {
        if isSession { try session.receiveFocus(data, sourceConnection: source) }
        else { try browser.receiveFocus(data, sourceConnection: source) }
    }
    let old = state.connection
    try receive(confirmed, source: old); state.connection = NWConnection(); FixtureScheduler.main.drain()
    expect(state.hostConfirmedActiveWindowId == nil && state.lastWindowFocusState == nil && state.focusHistory.isEmpty, "Old success cannot publish after replacement")
    state.hostConfirmedActiveWindowId = 42
    try receive(rejected, source: old); FixtureScheduler.main.drain()
    expect(state.hostConfirmedActiveWindowId == 42 && state.lastWindowFocusState == nil, "Old same-window rejection cannot clear replacement readiness")
    try receive(rejected, source: nil); FixtureScheduler.main.drain()
    expect(state.hostConfirmedActiveWindowId == 42, "Unattributed focus response cannot clear readiness")
    try receive(rejected, source: state.connection); FixtureScheduler.main.drain()
    expect(state.hostConfirmedActiveWindowId == nil && browser.hostConfirmedActiveWindowId == nil && session.hostConfirmedActiveWindowId == nil, "Current rejection clears both selected mirrors")
    try receive(confirmed, source: state.connection); FixtureScheduler.main.drain()
    expect(state.hostConfirmedActiveWindowId == 42 && browser.hostConfirmedActiveWindowId == 42 && session.hostConfirmedActiveWindowId == 42, "Current success confirms both selected mirrors")
    state.activeWindowId = 43
    try receive(rejected, source: state.connection); FixtureScheduler.main.drain()
    expect(state.hostConfirmedActiveWindowId == 42, "Existing target-intent stale-message filter remains enforced")
}
print("FocusLifetimeChecks: PASS (\(assertions) production-transition assertions; no sockets, app activation or device actions)")
