// Cases for the production PeelHomeComputerProjection block extracted from
// Shared/Client/ClientBrowser/PeelDirectEndpoint.swift by run-checks.py.
// Hosts are plain labels; identity and state mirror what the browser adapter
// passes from discovery, saved-address sessions and saved pairings.

struct Saved: Equatable { let id: String }

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    if !condition {
        failures += 1
        print("FAIL: \(message)")
    }
}

func discovered(_ host: String, pairing: String?, connected: Bool = false, connecting: Bool = false)
    -> PeelHomeComputerCandidate<String> {
    PeelHomeComputerCandidate(host: host, key: "service:\(host)", pairingID: pairing,
                              isConnected: connected, isActive: connected || connecting)
}

func direct(_ host: String, pairing: String, ready: Bool = false, connecting: Bool = false)
    -> PeelHomeComputerCandidate<String> {
    PeelHomeComputerCandidate(host: host, key: "pairingID:\(pairing)", pairingID: pairing,
                              isConnected: ready, isActive: ready || connecting)
}

func project(
    _ discoveredHosts: [PeelHomeComputerCandidate<String>],
    _ sessions: [PeelHomeComputerCandidate<String>],
    _ saved: [String]
) -> PeelHomeComputerProjection<String, Saved> {
    PeelHomeComputerProjection(discovered: discoveredHosts, directSessions: sessions,
                               saved: saved.map(Saved.init(id:)), savedPairingID: { $0.id })
}

// 1. VPN-only: no Bonjour, ready saved-address session, saved pairing.
do {
    let p = project([], [direct("Studio", pairing: "A", ready: true)], ["A"])
    expect(p.connected == ["Studio"], "direct-only ready session is the connected computer")
    expect(p.other.isEmpty, "no discovered computers to list")
    expect(p.saved.isEmpty, "connected saved pairing is not repeated as saved")
    expect(p.showsComputerList(hasConnectedSession: false), "list shows without Bonjour discovery")
    expect(p.showsComputerList(hasConnectedSession: true), "list shows with session content")
}

// 2. VPN-only while connecting: card stays visible with its Cancel control.
do {
    let p = project([], [direct("Studio", pairing: "A", connecting: true)], ["A"])
    expect(p.connected == ["Studio"], "connecting direct session keeps its card")
    expect(p.saved.isEmpty, "connecting saved pairing is not duplicated")
}

// 3. Disconnected/stale direct session: back to saved, with nothing fabricated.
do {
    let p = project([], [direct("Studio", pairing: "A")], ["A"])
    expect(p.connected.isEmpty, "stale direct session is not shown as connected")
    expect(p.saved == [Saved(id: "A")], "stale direct pairing stays reachable as saved")
    expect(!p.showsComputerList(hasConnectedSession: false), "nothing active and no discovery keeps the searching view")
    expect(p.showsComputerList(hasConnectedSession: true), "remaining session content still shows the list")
}

// 4. A direct session whose pairing is no longer saved is never shown.
do {
    let p = project([], [direct("Studio", pairing: "A", ready: true)], ["B"])
    expect(p.connected.isEmpty, "direct session without a saved pairing is hidden")
    expect(p.saved == [Saved(id: "B")], "other saved pairing remains")
}

// 5. Same pairing discovered by Bonjour while the direct session is active.
do {
    let p = project([discovered("Studio (Bonjour)", pairing: "A")],
                    [direct("Studio", pairing: "A", ready: true)], ["A"])
    expect(p.connected == ["Studio"], "the active direct session is the card")
    expect(p.other.isEmpty, "the duplicate discovered host is not offered beside it")
    expect(p.saved.isEmpty, "no saved duplicate")
}

// 6. Same pairing connected through discovery; a lingering direct session is ignored.
do {
    let p = project([discovered("Studio (Bonjour)", pairing: "A", connected: true)],
                    [direct("Studio", pairing: "A", ready: true)], ["A"])
    expect(p.connected == ["Studio (Bonjour)"], "discovered connection wins; one card per pairing")
}

// 7. Duplicate direct sessions for one pairing collapse to the first.
do {
    let first = direct("Studio", pairing: "A", ready: true)
    let second = PeelHomeComputerCandidate(host: "Studio copy", key: "pairingID:A-copy", pairingID: "A",
                                           isConnected: true, isActive: true)
    let p = project([], [first, second], ["A"])
    expect(p.connected == ["Studio"], "one card per saved pairing")
}

// 8. Discovery unchanged: connected first, others listed, undiscovered saved kept.
do {
    let p = project([discovered("Mini", pairing: "A", connected: true),
                     discovered("Laptop", pairing: "B"),
                     discovered("Guest", pairing: nil)],
                    [], ["A", "B", "C"])
    expect(p.connected == ["Mini"], "connected discovered host is first")
    expect(p.other == ["Laptop", "Guest"], "unconnected and unpaired discovered hosts stay listed")
    expect(p.saved == [Saved(id: "C")], "only the undiscovered saved pairing is listed as saved")
}

// 9. Connected and unconnected saved pairings together, with discovery present.
do {
    let p = project([discovered("Laptop", pairing: "B")],
                    [direct("Studio", pairing: "A", ready: true), direct("Office", pairing: "D")],
                    ["A", "B", "D"])
    expect(p.connected == ["Studio"], "ready direct session is connected while Bonjour has other hosts")
    expect(p.other == ["Laptop"], "unrelated discovered host stays reachable")
    expect(p.saved == [Saved(id: "D")], "stale direct pairing stays reachable as saved")
}

// 10. No discovery, no sessions, saved pairings only: searching view as before.
do {
    let p = project([], [], ["A"])
    expect(!p.showsComputerList(hasConnectedSession: false), "saved-only keeps the searching view and address entry")
    expect(p.saved == [Saved(id: "A")], "saved pairing is still projected")
}

if failures == 0 {
    print("PeelHomeComputerProjection checks: passed")
} else {
    print("PeelHomeComputerProjection checks: \(failures) failure(s)")
    exit(1)
}
