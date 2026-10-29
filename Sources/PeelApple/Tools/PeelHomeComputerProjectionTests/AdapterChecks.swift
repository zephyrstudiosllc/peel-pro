// Adapter boundary: run-checks.py appends the production projection block and
// the real PeelClientBrowser readiness, session lookup, Disconnect and
// homeComputerProjection() methods, plus the real host identity and
// saved-address session properties, to these minimal stand-ins.
import Foundation

struct FixtureService { let name: String }
struct PeelHostKey: Hashable { let rawValue: String }
struct PeelPairedPeer { let id: String }
struct FixtureEndpointRecord { let pairingID: String }
struct PeelSavedPairedMac { let id: String }
final class FixtureSocket {}

struct PeelHostInfo {
    var id: PeelHostKey { hostKey }
    let name: String
    let service: FixtureService
    var hostId: String?
    let directPairingID: String?
    let directEndpoint: String?
}

final class PeelHostSession {
    let hostKey: PeelHostKey
    var host: PeelHostInfo
    var connection: FixtureSocket?
    var isConnectionReady = false
    var isConnectBusy = false
    var pendingConnectHost: PeelHostInfo?
    var pendingConnectIsAutoReconnect = false
    var directEndpointRecord: FixtureEndpointRecord?
    var suppressAutoReconnect = false
    var pendingReconnectWhenVisible = false
    var pendingReconnectReason: String?
    var reconnectWorkItem: DispatchWorkItem?
    var delayedConnectWorkItem: DispatchWorkItem?
    var reconnectAttempt = 0
    var didHandleDisconnectForCurrentConnection = false
    var disconnects: [String] = []
    init(host: PeelHostInfo) { hostKey = host.hostKey; self.host = host }
    func disconnect(reason: String) { disconnects.append(reason); connection = nil; isConnectionReady = false }
}

final class PeelClientBrowser {
    var hosts: [PeelHostInfo] = []
    var sessionsByHostKey: [PeelHostKey: PeelHostSession] = [:]
    // Selected-session mirror, as published by the session ready handler.
    var connection: FixtureSocket?
    var isConnectionReady = false
    var connectedHostName: String?
    var pendingConnectHost: PeelHostInfo?
    var pendingConnectIsAutoReconnect = false
    var selectedHostKey: PeelHostKey?
    var suppressAutoReconnect = false
    var pendingReconnectWhenVisible = false
    var pendingReconnectReason: String?
    var reconnectWorkItem: DispatchWorkItem?
    var delayedConnectWorkItem: DispatchWorkItem?
    var reconnectAttempt = 0
    var didHandleDisconnectForCurrentConnection = false
    var pairingByServiceName: [String: String] = [:]
    var savedPairedMacs: [PeelSavedPairedMac] = []
    var createdSessions = 0
    var forgottenLastPeers: [String] = []

    /// Saved-address descriptors carry their pairing; discovered hosts resolve
    /// through their Bonjour service, as in the production lookup.
    func pairedPeer(for host: PeelHostInfo) -> PeelPairedPeer? {
        if let id = host.directPairingID { return PeelPairedPeer(id: id) }
        return pairingByServiceName[host.service.name].map(PeelPairedPeer.init(id:))
    }
    func forgetLastConnectedPeer(_ peer: PeelPairedPeer) { forgottenLastPeers.append(peer.id) }
    /// Production creates and stores a new session here; Disconnect must not.
    func session(for host: PeelHostInfo) -> PeelHostSession {
        createdSessions += 1
        let session = PeelHostSession(host: host)
        sessionsByHostKey[host.hostKey] = session
        return session
    }
}

// ADAPTER CASES
var failures = 0
func expect(_ condition: Bool, _ message: String) {
    if !condition { failures += 1; print("FAIL: \(message)") }
}

func discoveredHost(_ name: String, service: String, hostId: String?) -> PeelHostInfo {
    PeelHostInfo(name: name, service: FixtureService(name: service), hostId: hostId,
                 directPairingID: nil, directEndpoint: nil)
}
func directHost(_ name: String, pairing: String, hostId: String?) -> PeelHostInfo {
    PeelHostInfo(name: name, service: FixtureService(name: "Direct-\(pairing)"), hostId: hostId,
                 directPairingID: pairing, directEndpoint: "10.8.0.2:47100")
}
@discardableResult
func addSession(_ browser: PeelClientBrowser, _ host: PeelHostInfo, ready: Bool) -> PeelHostSession {
    let session = PeelHostSession(host: host)
    session.connection = ready ? FixtureSocket() : nil
    session.isConnectionReady = ready
    session.directEndpointRecord = host.directPairingID.map(FixtureEndpointRecord.init(pairingID:))
    browser.sessionsByHostKey[host.hostKey] = session
    return session
}
func select(_ browser: PeelClientBrowser, _ session: PeelHostSession) {
    browser.selectedHostKey = session.hostKey
    browser.connection = session.connection
    browser.isConnectionReady = session.isConnectionReady
    browser.connectedHostName = session.host.name
}

// 1. VPN session A is selected and ready; Bonjour A reappears with the same
//    name and no Bonjour session. The real saved-address session owns the card
//    and Disconnect.
do {
    let browser = PeelClientBrowser()
    let vpn = addSession(browser, directHost("Studio", pairing: "A", hostId: "H-A"), ready: true)
    select(browser, vpn)
    let bonjour = discoveredHost("Studio", service: "Peel Pro on Studio", hostId: "H-A")
    browser.hosts = [bonjour]
    browser.pairingByServiceName = ["Peel Pro on Studio": "A"]
    browser.savedPairedMacs = [PeelSavedPairedMac(id: "A")]

    expect(browser.owningSession(for: bonjour) == nil, "discovered host never owns the saved-address session")
    expect(!browser.hasOwnedReadyConnection(to: bonjour), "same name does not make the discovered host ready")
    let p = browser.homeComputerProjection()
    expect(p.connected.map { $0.hostKey } == [vpn.hostKey], "the saved-address descriptor is the connected card")
    expect(p.connected.first?.directPairingID == "A", "card keeps the saved pairing identity")
    expect(p.other.isEmpty && p.saved.isEmpty, "no duplicate discovered or saved row for pairing A")
    if let card = p.connected.first {
        expect(browser.owningSession(for: card) === vpn && browser.hasOwnedReadyConnection(to: card),
               "card resolves to the live VPN session")
        browser.disconnect(from: card)
    }
    expect(vpn.disconnects == ["User disconnected"], "Disconnect reaches the live VPN session")
    expect(browser.createdSessions == 0 && browser.sessionsByHostKey.count == 1,
           "Disconnect creates no empty Bonjour session")
}

// 2. Same-named but unrelated discovered host while VPN A is selected: listed
//    as not connected, so its row offers Connect rather than Disconnect.
do {
    let browser = PeelClientBrowser()
    let vpn = addSession(browser, directHost("Studio", pairing: "A", hostId: "H-A"), ready: true)
    select(browser, vpn)
    let stranger = discoveredHost("Studio", service: "Peel Pro on Studio (2)", hostId: "H-Z")
    browser.hosts = [stranger]
    browser.savedPairedMacs = [PeelSavedPairedMac(id: "A")]
    let p = browser.homeComputerProjection()
    expect(p.connected.map { $0.hostKey } == [vpn.hostKey], "VPN session stays the only connected card")
    expect(p.other.map { $0.hostKey } == [stranger.hostKey], "unrelated same-name host remains reachable")
    expect(!browser.hasOwnedReadyConnection(to: stranger), "unrelated same-name host is not ready")
}

// 3. Genuine Bonjour connection B is ready and selected: it is connected only
//    through its own bound session; others stay in their sections.
do {
    let browser = PeelClientBrowser()
    let mini = discoveredHost("Mini", service: "Peel Pro on Mini", hostId: "H-B")
    let laptop = discoveredHost("Laptop", service: "Peel Pro on Laptop", hostId: "H-C")
    let bonjourSession = addSession(browser, mini, ready: true)
    select(browser, bonjourSession)
    let staleVPN = addSession(browser, directHost("Studio", pairing: "A", hostId: "H-A"), ready: false)
    browser.hosts = [mini, laptop]
    browser.pairingByServiceName = ["Peel Pro on Mini": "B", "Peel Pro on Laptop": "C"]
    browser.savedPairedMacs = ["A", "B", "C"].map(PeelSavedPairedMac.init(id:))
    let p = browser.homeComputerProjection()
    expect(p.connected.map { $0.hostKey } == [mini.hostKey], "the ready Bonjour host is connected")
    expect(p.other.map { $0.hostKey } == [laptop.hostKey], "unconnected discovered host is listed")
    expect(p.saved.map { $0.id } == ["A"], "stale VPN pairing stays reachable as saved")
    expect(!browser.hasOwnedReadyConnection(to: laptop), "a host without its own session is not ready")
    browser.disconnect(from: mini)
    expect(bonjourSession.disconnects == ["User disconnected"] && staleVPN.disconnects.isEmpty,
           "Disconnect reaches only the bound Bonjour session")
    expect(browser.createdSessions == 0, "Disconnect of a bound host creates no session")
}

// 4. Same pairing with a genuine Bonjour connection and a lingering stale VPN
//    session: the Bonjour connection wins and owns Disconnect.
do {
    let browser = PeelClientBrowser()
    let bonjour = discoveredHost("Studio", service: "Peel Pro on Studio", hostId: "H-A")
    let bonjourSession = addSession(browser, bonjour, ready: true)
    select(browser, bonjourSession)
    let staleVPN = addSession(browser, directHost("Studio", pairing: "A", hostId: "H-A"), ready: false)
    browser.hosts = [bonjour]
    browser.pairingByServiceName = ["Peel Pro on Studio": "A"]
    browser.savedPairedMacs = [PeelSavedPairedMac(id: "A")]
    let p = browser.homeComputerProjection()
    expect(p.connected.map { $0.hostKey } == [bonjour.hostKey], "the real Bonjour connection is the card")
    expect(p.saved.isEmpty && p.other.isEmpty, "pairing A is listed once")
    expect(browser.owningSession(for: bonjour) === bonjourSession, "card resolves to its own session")
    browser.disconnect(from: bonjour)
    expect(bonjourSession.disconnects.count == 1 && staleVPN.disconnects.isEmpty && browser.createdSessions == 0,
           "Disconnect stays on the bound Bonjour session")
}

if failures == 0 {
    print("PeelHomeComputerProjection adapter checks: passed")
} else {
    print("PeelHomeComputerProjection adapter checks: \(failures) failure(s)")
    exit(1)
}
