import Foundation

enum FixtureClock {
    static var date = Date(timeIntervalSince1970: 100)
}

struct FixtureDeadline {
    let date: Date
    static func now() -> Self { Self(date: FixtureClock.date) }
    static func + (lhs: Self, rhs: TimeInterval) -> Self { Self(date: lhs.date.addingTimeInterval(rhs)) }
}

final class FixtureScheduler {
    static let main = FixtureScheduler()
    var work: [(Date, DispatchWorkItem)] = []
    func async(execute: () -> Void) { execute() }
    func asyncAfter(deadline: FixtureDeadline, execute: DispatchWorkItem) { work.append((deadline.date, execute)) }
    func advance(to date: Date) {
        FixtureClock.date = date
        let due = work.filter { $0.0 <= date }
        work.removeAll { $0.0 <= date }
        for (_, item) in due where !item.isCancelled { item.perform() }
    }
    func reset() { work.removeAll(); FixtureClock.date = Date(timeIntervalSince1970: 100) }
}

struct FixtureService { let name: String }
struct PeelHostInfo {
    let name: String
    let service: FixtureService
    let hostId: String?
    var directPairingID: String? = nil
    var isDirectEndpoint: Bool { directPairingID != nil }
    var hostKey: String { hostId ?? service.name }
}

class ReconnectState {
    var lastConnectedHost: PeelHostInfo?
    var lastConnectedHostName: String?
    var pendingReconnectWhenVisible = false
    var pendingReconnectReason: String?
    var suppressAutoReconnect = false
    var nextAllowedConnectAt = Date.distantPast
    let postPairConnectCooldown: TimeInterval = 1.1
    var reconnectAttempt = 0
    var reconnectWorkItem: DispatchWorkItem?
    var delayedConnectWorkItem: DispatchWorkItem?
    var isConnectBusy = false
    var connection: NSObject?
    var status = ""
}

final class PeelClientBrowser: ReconnectState {
    var sessionsByHostKey: [String: PeelHostSession] = [:]
    var selectedHostKey: String?
    var hosts: [PeelHostInfo] = []
    var selectedSession: PeelHostSession? { selectedHostKey.flatMap { sessionsByHostKey[$0] } }
    var isClientVisible = true
    func bindSession(_ session: PeelHostSession) {}
    func matchesReconnectTarget(_ host: PeelHostInfo) -> Bool { host.hostId == lastConnectedHost?.hostId }
    func refreshDiscoveryAfterLifecycleWake(reason: String) {}
    func directEndpointRecord(for pairingID: String) -> String? { nil }
    func pairedPeer(forPairingID pairingID: String) -> String? { nil }
}

final class PeelHostSession: ReconnectState {
    var host: PeelHostInfo
    let hostKey: String
    weak var browser: PeelClientBrowser?
    var requiresPairingRepair = false
    var isUsingDirectEndpoint: Bool { host.isDirectEndpoint }
    // Production sessions read the browser's visibility.
    var isClientVisible: Bool { browser?.isClientVisible ?? true }
    var directPairingID: String? { host.directPairingID }
    var isConnectionReady = false
    var connectedHostName: String?
    var connectedTransportEndpoint: String?
    var admissions: [Date] = []
    init(host: PeelHostInfo, browser: PeelClientBrowser) {
        self.host = host; self.hostKey = host.hostKey; self.browser = browser
    }
    func currentTransportEndpoint() -> String? { "synthetic" }
    func configureDirectEndpoint(_ record: String) {}
    func requestWindowListIfReadyOrDefer() {}
    func startWindowListAutoRefresh() {}
    func startPing() {}
    func recordTransportAdmission() { admissions.append(FixtureClock.date) }
}

// REGRESSION CASES
var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { failures += 1; print("FAIL: " + message) }
}

func fixture() -> (PeelClientBrowser, PeelHostInfo, PeelHostSession) {
    FixtureScheduler.main.reset()
    let browser = PeelClientBrowser()
    let host = PeelHostInfo(name: "Owned fixture Host", service: FixtureService(name: "fixture-service"), hostId: "fixture-host")
    browser.hosts = [host]
    let session = browser.session(for: host)
    browser.selectedHostKey = session.hostKey
    session.requiresPairingRepair = true
    session.suppressAutoReconnect = true
    session.reconnectAttempt = 8
    browser.suppressAutoReconnect = true
    return (browser, host, session)
}

do {
    let (browser, host, session) = fixture()
    var staleAdmissions = 0
    let staleReconnect = DispatchWorkItem { staleAdmissions += 1 }
    let staleDelay = DispatchWorkItem { staleAdmissions += 1 }
    session.reconnectWorkItem = staleReconnect
    session.delayedConnectWorkItem = staleDelay
    FixtureScheduler.main.asyncAfter(deadline: .now() + 0.2, execute: staleReconnect)
    FixtureScheduler.main.asyncAfter(deadline: .now() + 0.3, execute: staleDelay)
    browser.prepareReconnectAfterPairing(with: host)
    check(!session.requiresPairingRepair && !session.suppressAutoReconnect, "durable pairing retires exact session missing-key suppression")
    check(session.reconnectAttempt == 0, "fresh pairing restores bounded retry budget")
    check(staleReconnect.isCancelled && staleDelay.isCancelled, "stale reconnect and delayed work are retired")
    check(session.nextAllowedConnectAt == browser.nextAllowedConnectAt, "browser and routed session share the post-pair deadline")
    browser.attemptPendingReconnectIfPossible(reason: "paired host available")
    check(session.admissions.isEmpty, "automatic post-pair connect must not hit the old TLS listener")
    FixtureScheduler.main.advance(to: Date(timeIntervalSince1970: 101.09))
    check(session.admissions.isEmpty && staleAdmissions == 0, "no admission before the existing 1.1-second cooldown")
    FixtureScheduler.main.advance(to: Date(timeIntervalSince1970: 101.1))
    check(session.admissions.count == 1, "exactly one automatic admission at the cooldown deadline")
    check(!session.suppressAutoReconnect, "a delayed Host refresh can still use bounded normal retries")
}

do {
    let (browser, host, session) = fixture()
    browser.isClientVisible = false
    browser.prepareReconnectAfterPairing(with: host)
    browser.attemptPendingReconnectIfPossible(reason: "paired while hidden")
    FixtureScheduler.main.advance(to: Date(timeIntervalSince1970: 102))
    check(session.admissions.isEmpty && browser.pendingReconnectWhenVisible, "hidden clients retain pending intent without connecting")
    browser.isClientVisible = true
    browser.attemptPendingReconnectIfPossible(reason: "became visible")
    check(session.admissions.count == 1, "visibility resumes the repaired target after its cooldown")
}

do {
    let (browser, host, session) = fixture()
    let other = PeelHostInfo(name: "Other fixture", service: FixtureService(name: "other-service"), hostId: "other-host")
    let otherSession = browser.session(for: other)
    otherSession.suppressAutoReconnect = true
    otherSession.requiresPairingRepair = true
    otherSession.nextAllowedConnectAt = Date(timeIntervalSince1970: 150)
    browser.selectedHostKey = otherSession.hostKey
    let rediscovered = PeelHostInfo(name: "Renamed fixture", service: FixtureService(name: "new-service"), hostId: host.hostId)
    browser.hosts = [rediscovered, other]
    browser.prepareReconnectAfterPairing(with: rediscovered)
    check(browser.session(for: rediscovered) === session, "stable Host identity reuses the original repaired session")
    check(browser.sessionsByHostKey.count == 2, "repair creates no duplicate session")
    check(otherSession.suppressAutoReconnect && otherSession.requiresPairingRepair && otherSession.nextAllowedConnectAt == Date(timeIntervalSince1970: 150), "another Host's repair and cooldown state is untouched")
    browser.attemptPendingReconnectIfPossible(reason: "paired host available")
    FixtureScheduler.main.advance(to: Date(timeIntervalSince1970: 101.1))
    check(session.admissions.count == 1 && otherSession.admissions.isEmpty, "automatic repair connects only its intended session")
    check(browser.selectedHostKey == otherSession.hostKey, "automatic repair does not steal another selected Host")
}

// A repaired session's own admission defers while hidden: no transport, the
// same Host identity is retained for foreground recovery, and the selected
// browser mirror reports the same pending intent.
do {
    let (browser, host, session) = fixture()
    browser.prepareReconnectAfterPairing(with: host)
    FixtureScheduler.main.advance(to: Date(timeIntervalSince1970: 102))
    browser.isClientVisible = false
    session.connectAndRequestWindows(isAutoReconnect: true)
    check(session.admissions.isEmpty && !session.isConnectBusy, "hidden session admission starts no transport")
    check(session.pendingReconnectWhenVisible && session.pendingReconnectReason != nil,
          "hidden admission keeps a foreground retry intent")
    check(session.lastConnectedHost?.hostKey == host.hostKey && session.lastConnectedHostName == host.name,
          "hidden admission retains the exact repaired Host identity")
    check(browser.pendingReconnectWhenVisible && browser.pendingReconnectReason == session.pendingReconnectReason,
          "selected browser mirror reports the same pending intent")
    browser.isClientVisible = true
    browser.attemptPendingReconnectIfPossible(reason: "became visible")
    FixtureScheduler.main.advance(to: Date(timeIntervalSince1970: 103))
    check(session.admissions.count == 1, "foreground resumes exactly one admission for the deferred session")
}
do {
    let (browser, _, session) = fixture()
    browser.isClientVisible = false
    session.connectAndRequestWindows(isAutoReconnect: true)
    check(session.admissions.isEmpty && !session.pendingReconnectWhenVisible,
          "a still-suppressed session is paused without reviving its retry")
}

if failures > 0 { exit(1) }
print("PASS: post-pair session cooldown, retry state, visibility and target isolation")
