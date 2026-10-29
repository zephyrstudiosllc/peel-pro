import Foundation

final class FixtureScheduler {
    static let main = FixtureScheduler()
    static var isMainThread = false
    var work: [() -> Void] = []
    var delayed: [DispatchWorkItem] = []
    func async(execute: @escaping () -> Void) { work.append(execute) }
    func asyncAfter(deadline: DispatchTime, execute: DispatchWorkItem) { delayed.append(execute) }
    func drain() {
        Self.isMainThread = true
        while !work.isEmpty { work.removeFirst()() }
        Self.isMainThread = false
    }
    func runDelayed() {
        let ready = delayed; delayed.removeAll()
        Self.isMainThread = true
        for item in ready where !item.isCancelled { item.perform() }
        Self.isMainThread = false
    }
    func reset() { work.removeAll(); delayed.removeAll(); Self.isMainThread = false }
}

struct FixtureError: Error { var localizedDescription: String { "synthetic transport loss" } }
final class NWConnection {
    enum State { case ready, failed(FixtureError), cancelled, waiting(FixtureError), setup }
    enum SendCompletion { case contentProcessed((FixtureError?) -> Void) }
    var stateUpdateHandler: ((State) -> Void)?
    var receiveCompletion: ((Data?, Int?, Bool, FixtureError?) -> Void)?
    var sendCompletion: ((FixtureError?) -> Void)?
    var cancellations = 0
    func receive(minimumIncompleteLength: Int, maximumLength: Int,
                 completion: @escaping (Data?, Int?, Bool, FixtureError?) -> Void) { receiveCompletion = completion }
    func send(content: Data, completion: SendCompletion) {
        if case let .contentProcessed(callback) = completion { sendCompletion = callback }
    }
    func cancel() { cancellations += 1 }
}
struct PeelRequest: Encodable { let type: String }
struct WindowListMessage: Codable { let windows: [Int] }
struct ClientVisibilityMessage: Encodable { let isVisible: Bool }
struct FixtureService { let name: String }
struct PeelHostInfo { let name: String; let hostId: String?; let service: FixtureService; let directPairingID: String? = nil }
struct FixturePeer { let id = "fixture-pair" }
final class FixturePairingStore { func updatePeerTLSPSKOrder(pairingID: String, tlsPSKOrder: Int) {} }
enum PeelClientDiagnostics {
    static func logStreamEvent(ownerName: String, message: String) {}
    static func logReceiveChunk(ownerName: String, byteCount: Int, muxBufferBytes: Int, binaryBufferBytes: Int) {}
}
func peelReceivePerfNowMs() -> Double { 0 }
/// Mirrors PeelProEvidenceClient.localAccessOrVisibilityChanged(): retire the
/// pending operation and publish inactive while hidden, otherwise wait for a
/// fresh Host challenge. Records order against session messages.
final class FixtureEvidenceClient {
    weak var session: PeelHostSession?
    var published: [String] = []
    init(session: PeelHostSession) { self.session = session }
    func localAccessOrVisibilityChanged() {
        guard let session else { return }
        session.browser?.lifecycleLog.append("evidence:\(session.hostKey)")
        published.append(session.isClientVisible == false ? "inactive" : "waitingForMac")
    }
}

class FixtureState {
    var connection: NWConnection?
    var isConnectionReady = false
    var isConnectBusy = false
    var pendingReconnectWhenVisible = false
    var pendingReconnectReason: String?
    var suppressAutoReconnect = false
    var lastConnectedHost: PeelHostInfo?
    var lastConnectedHostName: String?
    var connectedHostName: String?
    var status = ""
    var nextAllowedConnectAt = Date.distantPast
    var pendingWindowListRequest = false
    var windows: [Int] = []
    var hasFreshWindowListForCurrentConnection = false
}
final class PeelClientBrowser: FixtureState {
    var isClientVisible = true
    var selectedHostKey: String? = "fixture-host"
    var sessionsByHostKey: [String: PeelHostSession] = [:]
    var selectedSession: PeelHostSession? { selectedHostKey.flatMap { sessionsByHostKey[$0] } }
    var hosts: [PeelHostInfo] = []
    let pairingStore = FixturePairingStore()
    var discoveryRefreshes = 0
    var legacyConnects = 0
    var didHandleDisconnectForCurrentConnection = false
    var legacyResets = 0
    var legacyPings = 0
    var legacyWindowRefreshes = 0
    var legacyWatchdogs = 0
    var legacyWindowRequests = 0
    var reconnectAttempt = 0
    var reconnectWorkItem: DispatchWorkItem?
    let maxReconnectAttempts = 8
    var invalidations = 0
    var staleMarks = 0
    var proEvidenceClients: [String: FixtureEvidenceClient] = [:]
    var lifecycleLog: [String] = []
    func matchesReconnectTarget(_ host: PeelHostInfo) -> Bool { host.hostId == lastConnectedHost?.hostId }
    func refreshDiscoveryAfterLifecycleWake(reason: String) { discoveryRefreshes += 1 }
    func connectAndRequestWindows(for host: PeelHostInfo, isAutoReconnect: Bool) {
        legacyConnects += 1
        // Record the router's existing per-host transport destination.
        sessionsByHostKey[host.hostId ?? ""]?.connectAndRequestWindows(isAutoReconnect: isAutoReconnect)
    }
    func startPing() { legacyPings += 1 }
    func sendJSONMessage<T: Encodable>(_ message: T) {}
    func requestWindowListIfReadyOrDefer() { legacyWindowRequests += 1 }
    func startWindowListAutoRefresh() { legacyWindowRefreshes += 1 }
    func stopPing() {}
    func stopWindowListAutoRefresh() {}
    func stopAllPullStreams() {}
    func stopStreamWatchdog() {}
    func startStreamWatchdog() { legacyWatchdogs += 1 }
    func restartDiscoveryAfterHostDrop(reason: String) { discoveryRefreshes += 1 }
    func resetSession(reason: String) {
        legacyResets += 1
        connection?.cancel(); connection = nil; isConnectionReady = false
        selectedSession?.isConnectionReady = false
    }
    func directEndpointRecord(for pairingID: String) -> String? { "fixture-address" }
    func pairedPeer(forPairingID pairingID: String) -> FixturePeer? { FixturePeer() }
    func persistLastConnectedPeer(_ peer: FixturePeer, host: PeelHostInfo) {}
    func shouldInvalidateLocalPairing(for host: PeelHostInfo, error: FixtureError) -> Bool { false }
    func invalidateLocalPairing(for host: PeelHostInfo, because error: FixtureError) { invalidations += 1 }
    func markDiscoveredHostStaleAndRefresh(_ host: PeelHostInfo, reason: String) { staleMarks += 1 }
}
final class PeelHostSession: FixtureState {
    weak var browser: PeelClientBrowser?
    let hostKey: String
    var host: PeelHostInfo
    var isClientVisible: Bool { browser?.isClientVisible ?? true }
    var isUsingDirectEndpoint = false
    var directPairingID: String? { isUsingDirectEndpoint ? "fixture-pair" : nil }
    var didHandleDisconnectForCurrentConnection = false
    var isInWaitingState = false
    var resolveTimeoutWorkItem: DispatchWorkItem?
    var reconnectWorkItem: DispatchWorkItem?
    var waitingTimeoutWorkItem: DispatchWorkItem?
    let waitingTimeoutSeconds: Double = 4
    var reconnectAttempt = 0
    var reconnectSchedules = 0
    var resets: [String] = []
    var transportAdmissions = 0
    var boundaryResets = 0
    var helloMessages = 0
    var pings = 0
    var windowRefreshes = 0
    var watchdogStarts = 0
    var muxBuffer = Data()
    var binaryBuffer = Data()
    var useMuxParser = false
    var lastAnyDataAt = Date.distantPast
    var lastWindowListAt = Date.distantPast
    var streamRestores = 0
    init(browser: PeelClientBrowser, name: String = "fixture-host") {
        self.browser = browser
        hostKey = name
        host = PeelHostInfo(name: name, hostId: name, service: FixtureService(name: name))
        super.init()
        lastConnectedHost = host; lastConnectedHostName = name
    }
    func userVisibleWindows(from windows: [Int]) -> [Int] { windows }
    func reconcileRecentFocusOrder(with windows: [Int]) {}
    func processWindowListForPendingHostCommandAutoOpen(_ windows: [Int]) {}
    func processWindowListForPendingLauncherSuccessor(_ windows: [Int]) {}
    func processWindowListForAutoPopup(_ windows: [Int]) {}
    func resendPeeledWindowHostingStateIfSupported(freshWindows: [Int]) {}
    func restoreDesiredPullStreamsIfNeeded() { streamRestores += 1 }
    func connectionPeer() -> FixturePeer? { FixturePeer() }
    func resetVideoReceiversForConnectionBoundary(reason: String) { boundaryResets += 1 }
    func startStreamWatchdog() { watchdogStarts += 1 }
    func stopStreamWatchdog() {}
    func sendClientHello() { helloMessages += 1; browser?.lifecycleLog.append("hello:\(hostKey)") }
    func sendJSONMessage<T: Encodable>(_ message: T) {
        if let visibility = message as? ClientVisibilityMessage {
            browser?.lifecycleLog.append("visibility:\(hostKey):\(visibility.isVisible)")
        }
    }
    func startWindowListAutoRefresh() { windowRefreshes += 1 }
    func startPing() { pings += 1 }
    func stopSystemAudio(reason: String) {}
    func requestWindowListIfReadyOrDefer() { if isConnectionReady { sendWindowListRequest() } }
    func stopPing() {}
    func stopWindowListAutoRefresh() {}
    func stopAllPullStreams() {}
    func configureDirectEndpoint(_ record: String) {}
    func updateHost(_ host: PeelHostInfo) { self.host = host }
    func resetSession(reason: String) {
        resets.append(reason); connection?.cancel(); connection = nil; isConnectionReady = false
        // The production reset mirrors these fields before returning.
        if browser?.selectedHostKey == hostKey {
            browser?.connection = nil; browser?.isConnectionReady = false
            browser?.pendingReconnectWhenVisible = pendingReconnectWhenVisible
            browser?.pendingReconnectReason = pendingReconnectReason
        }
    }
    func scheduleReconnect(reason: String) { reconnectSchedules += 1 }
    func processMuxedIncomingData(_ data: Data, sourceConnection: NWConnection) {}
    func processIncomingData(_ data: Data, sourceConnection: NWConnection) {}
}

// REGRESSION CASES
var failures = 0
var retainedBrowser: PeelClientBrowser?
func check(_ value: @autoclosure () -> Bool, _ reason: String) {
    if !value() { failures += 1; print("FAIL: " + reason) }
}
func fixture() -> (PeelClientBrowser, PeelHostSession, NWConnection) {
    FixtureScheduler.main.reset()
    let browser = PeelClientBrowser()
    retainedBrowser = browser
    let session = PeelHostSession(browser: browser)
    let socket = NWConnection()
    session.connection = socket; session.isConnectionReady = true
    browser.connection = socket; browser.isConnectionReady = true
    browser.lastConnectedHost = session.host; browser.lastConnectedHostName = session.host.name
    browser.hosts = [session.host]; browser.sessionsByHostKey[session.hostKey] = session
    session.installHandler(on: socket)
    return (browser, session, socket)
}
func replace(_ session: PeelHostSession, with replacement: NWConnection) {
    session.connection = replacement; session.isConnectionReady = true
    session.didHandleDisconnectForCurrentConnection = false
    session.browser?.connection = replacement; session.browser?.isConnectionReady = true
    session.installHandler(on: replacement)
}

// An automatic intent may be queued by Bonjour resolve, direct retry, or a
// cooldown while visible, then execute only after Home. It must use the real
// production admission prefix's current visibility, and resume once normally.
for direct in [false, true] {
    let (browser, session, _) = fixture()
    session.isUsingDirectEndpoint = direct
    session.connection = nil; session.isConnectionReady = false
    browser.connection = nil; browser.isConnectionReady = false
    FixtureScheduler.main.async { session.connectAndRequestWindows(isAutoReconnect: true) }
    browser.setClientVisibility(false)
    FixtureScheduler.main.drain()
    check(session.transportAdmissions == 0 && !session.isConnectBusy,
          "queued automatic admission cannot start transport after hiding")
    check(session.pendingReconnectWhenVisible && browser.pendingReconnectWhenVisible,
          "hidden admission retains the same session's foreground retry intent")
    browser.setClientVisibility(true)
    FixtureScheduler.main.drain()
    check(session.transportAdmissions == 1 && browser.legacyConnects == 0,
          "foreground resumes one session-owned admission after a blocked retry")
}
do {
    let (browser, session, _) = fixture()
    session.connection = nil; browser.connection = nil
    session.isConnectionReady = false; browser.isConnectionReady = false
    session.suppressAutoReconnect = true
    browser.setClientVisibility(false)
    session.connectAndRequestWindows(isAutoReconnect: true)
    FixtureScheduler.main.drain()
    check(session.transportAdmissions == 0 && !session.pendingReconnectWhenVisible,
          "hiding does not revive an explicitly suppressed reconnect")
    browser.setClientVisibility(true)
    session.connectAndRequestWindows(isAutoReconnect: false)
    FixtureScheduler.main.drain()
    check(session.transportAdmissions == 1 && !session.suppressAutoReconnect,
          "explicit visible Connect retains its normal authorization and admission")
}
do {
    let (browser, session, candidate) = fixture()
    session.isConnectionReady = false; browser.isConnectionReady = false
    candidate.stateUpdateHandler?(.ready) // Ready has only queued its main mutation.
    browser.setClientVisibility(false)
    FixtureScheduler.main.drain()
    check(session.helloMessages == 0 && !session.isConnectionReady,
          "ready queued before Home cannot publish a hidden ClientHello")
    check(candidate.cancellations == 1 && session.connection == nil,
          "unpublished hidden candidate is retired through its bound disconnect owner")
    check(session.pendingReconnectWhenVisible && session.reconnectSchedules == 0,
          "retired hidden candidate waits for normal foreground recovery")
    let replacement = NWConnection(); replace(session, with: replacement)
    browser.setClientVisibility(true)
    FixtureScheduler.main.drain()
    // Resume sends exactly one fresh hello on the ready replacement so the
    // Host can issue a new evidence challenge.
    check(session.helloMessages == 1, "resume sends one hello on the ready replacement")
    candidate.stateUpdateHandler?(.ready)
    FixtureScheduler.main.drain()
    check(session.connection === replacement && session.helloMessages == 1,
          "late hidden candidate callback cannot publish into its replacement")
}

// The old socket callback was accepted on networkQueue, then its main work ran
// after the connection had already been replaced during resume.
for event: NWConnection.State in [.ready, .failed(FixtureError()), .cancelled, .waiting(FixtureError())] {
    let (browser, session, old) = fixture()
    old.stateUpdateHandler?(event)
    let replacement = NWConnection(); replace(session, with: replacement)
    FixtureScheduler.main.drain(); FixtureScheduler.main.runDelayed()
    check(session.connection === replacement && session.isConnectionReady, "queued stale state cannot reset or mark replacement unready")
    check(session.resets.isEmpty && session.boundaryResets == 0 && session.helloMessages == 0, "stale state cannot reset video or send a replacement hello")
    check(browser.connection === replacement && browser.isConnectionReady, "stale state cannot corrupt selected browser mirror")
}

do {
    let (_, session, old) = fixture()
    session.handleDisconnectOnce("queued old receive", sourceConnection: old)
    let replacement = NWConnection(); replace(session, with: replacement)
    FixtureScheduler.main.drain()
    check(session.connection === replacement && session.resets.isEmpty, "disconnect eligibility is checked on the mutation queue")
}
for eof in [false, true] {
    let (_, session, old) = fixture()
    session.startReceiveLoop()
    old.receiveCompletion?(nil, nil, eof, eof ? nil : FixtureError())
    let replacement = NWConnection(); replace(session, with: replacement)
    FixtureScheduler.main.drain()
    check(session.connection === replacement && session.resets.isEmpty, "receive error/EOF keeps the original control socket across main hop")
}
do {
    let (_, session, old) = fixture()
    session.sendWindowListRequest()
    let replacement = NWConnection(); replace(session, with: replacement)
    old.sendCompletion?(FixtureError())
    FixtureScheduler.main.drain()
    check(session.connection === replacement && session.resets.isEmpty, "old window-list send failure cannot tear down replacement")
}
do {
    let (_, session, old) = fixture()
    old.stateUpdateHandler?(.waiting(FixtureError()))
    FixtureScheduler.main.drain()
    let oldTimeout = session.waitingTimeoutWorkItem!
    let replacement = NWConnection(); replace(session, with: replacement)
    session.isInWaitingState = true
    oldTimeout.perform(); FixtureScheduler.main.drain()
    check(session.connection === replacement && replacement.cancellations == 0, "old waiting timeout cannot cancel a later waiting socket")
}
do {
    let (browser, session, old) = fixture()
    let data = try! JSONEncoder().encode(WindowListMessage(windows: [42]))
    try! session.receiveWindowList(data, sourceConnection: old)
    let replacement = NWConnection(); replace(session, with: replacement)
    FixtureScheduler.main.drain()
    check(session.windows.isEmpty && !session.hasFreshWindowListForCurrentConnection
          && !browser.hasFreshWindowListForCurrentConnection && session.streamRestores == 0,
          "a queued old window list cannot mark replacement fresh or restore its streams")
    try! session.receiveWindowList(data, sourceConnection: replacement)
    FixtureScheduler.main.drain()
    check(session.windows == [42] && session.hasFreshWindowListForCurrentConnection
          && browser.hasFreshWindowListForCurrentConnection && session.streamRestores == 1,
          "current window list publishes freshness and restores desired streams")
}
do {
    let (browser, session, old) = fixture()
    browser.isClientVisible = false
    session.handleDisconnectOnce("background EOF", sourceConnection: old)
    session.handleDisconnectOnce("duplicate failure", sourceConnection: old)
    FixtureScheduler.main.drain()
    check(session.resets.count == 1 && session.reconnectSchedules == 0, "background disconnect occurs once without reconnect")
    check(session.pendingReconnectWhenVisible && browser.pendingReconnectWhenVisible, "background retry intent is mirrored before reset returns")
    browser.pendingReconnectWhenVisible = false // Nonselected sessions have no mirror.
    browser.isClientVisible = true
    browser.attemptPendingReconnectIfPossible(reason: "resumed")
    FixtureScheduler.main.drain()
    check(session.transportAdmissions == 1, "Bonjour session resumes from its own pending intent")
    check(browser.legacyConnects == 0, "session retry never races the browser retry")
}
do {
    let (browser, session, _) = fixture()
    session.connection = nil; session.isConnectionReady = false
    browser.connection = nil; browser.isConnectionReady = false
    session.pendingReconnectWhenVisible = true
    browser.pendingReconnectWhenVisible = true
    browser.attemptPendingReconnectIfPossible(reason: "selected resumed")
    check(session.transportAdmissions == 1 && browser.legacyConnects == 0,
          "selected pending mirror does not start a duplicate browser connect before busy publishes")
}
do {
    let (browser, session, _) = fixture()
    session.connection = nil; session.isConnectionReady = false
    browser.connection = nil; browser.isConnectionReady = false
    session.isConnectBusy = false; browser.isConnectBusy = false
    session.pendingReconnectWhenVisible = true
    browser.pendingReconnectWhenVisible = true
    browser.isClientVisible = false
    browser.setClientVisibility(true)
    FixtureScheduler.main.drain()
    check(session.transportAdmissions == 1 && browser.reconnectAttempt == 0
          && browser.reconnectWorkItem == nil,
          "full visibility entry schedules no legacy retry behind the session resolve")
    let resumed = NWConnection(); replace(session, with: resumed)
    resumed.stateUpdateHandler?(.ready); FixtureScheduler.main.drain()
    FixtureScheduler.main.runDelayed(); FixtureScheduler.main.drain()
    check(session.transportAdmissions == 1 && browser.legacyConnects == 0,
          "no delayed browser reconnect reaches transport after the resumed socket is ready")
    check(session.connection === resumed && session.isConnectionReady,
          "the resumed socket remains ready after all delayed work drains")
}
do {
    let (browser, session, _) = fixture()
    browser.isClientVisible = false
    browser.setClientVisibility(true)
    FixtureScheduler.main.drain()
    check(browser.legacyPings == 0 && browser.legacyWindowRefreshes == 0
          && browser.legacyWindowRequests == 0 && browser.legacyWatchdogs == 0,
          "session-owned visibility starts no legacy poll, request, ping or watchdog")
    check(session.pings == 1 && session.windowRefreshes == 1 && session.watchdogStarts == 1,
          "the real session alone resumes polling and watchdog")
}
do {
    let (browser, session, old) = fixture()
    browser.sendWindowListRequest() // Already in flight when the app backgrounds.
    let oldSendCompletion = old.sendCompletion!
    session.handleDisconnectOnce("background abort", sourceConnection: old)
    FixtureScheduler.main.drain()
    oldSendCompletion(FixtureError())
    FixtureScheduler.main.drain()
    check(session.resets.count == 1 && browser.legacyResets == 0
          && browser.reconnectWorkItem == nil && browser.reconnectAttempt == 0,
          "cancelled legacy poll cannot start a parallel retry after real-session abort")
    let replacement = NWConnection(); replace(session, with: replacement)
    replacement.stateUpdateHandler?(.ready); FixtureScheduler.main.drain()
    FixtureScheduler.main.runDelayed(); FixtureScheduler.main.drain()
    check(session.connection === replacement && session.isConnectionReady
          && browser.legacyConnects == 0,
          "new ready socket survives delayed work after the captured background-abort sequence")
}
do {
    let (browser, session, old) = fixture()
    browser.sendWindowListRequest()
    let oldSendCompletion = old.sendCompletion!
    let replacement = NWConnection(); replace(session, with: replacement)
    oldSendCompletion(FixtureError()); FixtureScheduler.main.drain()
    check(session.connection === replacement && session.resets.isEmpty
          && browser.legacyResets == 0 && browser.reconnectAttempt == 0,
          "browser send callback retains old socket identity after replacement")
}
do {
    let (browser, session, old) = fixture()
    browser.sendWindowListRequest()
    let oldSendCompletion = old.sendCompletion!
    let replacement = NWConnection()
    // Deliberately retain the old browser mirror while only the real session
    // advances; callback safety must not depend on atomic mirror publication.
    session.connection = replacement; session.isConnectionReady = true
    session.status = "replacement ready"; session.pendingReconnectWhenVisible = false
    oldSendCompletion(FixtureError()); FixtureScheduler.main.drain()
    FixtureScheduler.main.runDelayed(); FixtureScheduler.main.drain()
    check(session.connection === replacement && session.isConnectionReady
          && session.status == "replacement ready" && !session.pendingReconnectWhenVisible
          && browser.legacyResets == 0 && browser.reconnectAttempt == 0,
          "a lagging browser mirror cannot invoke legacy reset on an advanced real session")
}
do {
    let (browser, session, socket) = fixture()
    browser.handleDisconnectOnce("current mirrored send failure", sourceConnection: socket)
    FixtureScheduler.main.drain()
    check(session.resets.count == 1 && session.reconnectSchedules == 1
          && browser.legacyResets == 0 && browser.reconnectAttempt == 0,
          "current mirrored failure routes to the real session's sole reset and retry")
}
do {
    let (browser, selected, _) = fixture()
    let other = PeelHostSession(browser: browser, name: "other-host")
    browser.hosts.append(other.host); browser.sessionsByHostKey[other.hostKey] = other
    other.pendingReconnectWhenVisible = true
    browser.attemptPendingReconnectIfPossible(reason: "resumed")
    FixtureScheduler.main.drain()
    check(other.transportAdmissions == 1 && selected.transportAdmissions == 0, "a live selected session cannot hide another Bonjour retry")
    check(browser.selectedHostKey == selected.hostKey, "resuming another session preserves selected Host")
}
for direct in [false, true] {
    let (browser, session, _) = fixture()
    session.connection = nil; session.isConnectionReady = false
    session.pendingReconnectWhenVisible = true; session.isUsingDirectEndpoint = direct
    browser.isClientVisible = false
    browser.attemptPendingReconnectIfPossible(reason: "hidden")
    check(session.transportAdmissions == 0 && session.pendingReconnectWhenVisible, "hidden pending retries do not connect")
    browser.isClientVisible = true; session.suppressAutoReconnect = true
    browser.attemptPendingReconnectIfPossible(reason: "explicitly disconnected")
    check(session.transportAdmissions == 0, "explicit retry suppression survives visibility")
    session.suppressAutoReconnect = false
    browser.attemptPendingReconnectIfPossible(reason: "resumed")
    check(session.transportAdmissions == 1, "both Bonjour and direct routes resume eligible pending intent")
}
do {
    let (_, session, socket) = fixture()
    socket.stateUpdateHandler?(.ready); FixtureScheduler.main.drain()
    check(session.helloMessages == 1 && session.windowRefreshes == 1 && session.pings == 1, "current ready performs the existing startup sequence")
    socket.stateUpdateHandler?(.failed(FixtureError())); FixtureScheduler.main.drain()
    check(session.resets.count == 1 && session.reconnectSchedules == 1, "current visible failure resets and schedules the normal bounded retry")
}
// Signed Pro evidence: each real visibility transition retires every session's
// pending evidence through the production browser invalidation, after the new
// visibility is observable and before any visibility message or ClientHello.
func evidenceRetiredFirst(_ log: [String], sessions: Int, hellos: Int) -> Bool {
    let evidence = log.indices.filter { log[$0].hasPrefix("evidence:") }
    let messages = log.indices.filter { !log[$0].hasPrefix("evidence:") }
    guard evidence.count == sessions, let lastEvidence = evidence.last,
          let firstMessage = messages.first else { return false }
    return lastEvidence < firstMessage && log.filter { $0.hasPrefix("hello:") }.count == hellos
}
do {
    let (browser, session, _) = fixture()
    let other = PeelHostSession(browser: browser, name: "other-host")
    other.connection = NWConnection(); other.isConnectionReady = true
    browser.sessionsByHostKey[other.hostKey] = other
    let first = FixtureEvidenceClient(session: session)
    let second = FixtureEvidenceClient(session: other)
    browser.proEvidenceClients = [session.hostKey: first, other.hostKey: second]
    browser.setClientVisibility(true)
    check(first.published.isEmpty && second.published.isEmpty && browser.lifecycleLog.isEmpty,
          "an unchanged visibility leaves signed evidence untouched")
    browser.setClientVisibility(false)
    check(first.published == ["inactive"] && second.published == ["inactive"],
          "hiding retires every session's evidence as inactive")
    check(evidenceRetiredFirst(browser.lifecycleLog, sessions: 2, hellos: 0),
          "hidden evidence is retired before either session reports visibility")
    browser.lifecycleLog.removeAll()
    browser.setClientVisibility(true)
    FixtureScheduler.main.drain()
    check(first.published == ["inactive", "waitingForMac"] && second.published == ["inactive", "waitingForMac"],
          "resume retires suspended evidence and waits for a fresh Host challenge")
    check(evidenceRetiredFirst(browser.lifecycleLog, sessions: 2, hellos: 2),
          "resume retires evidence before any visibility message or ClientHello")
}
if failures > 0 { exit(1) }
print("PASS: control callback identity, background retry intent, foreground session routing, suppression and evidence retirement")
