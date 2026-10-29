import Foundation

// Deterministic adapters for scheduling/socket effects. No sockets are opened.
final class ManualQueue {
    var immediate: [() -> Void] = []
    var delayed: [() -> Void] = []
    func async(execute body: @escaping () -> Void) { immediate.append(body) }
    func asyncAfter(deadline: DispatchTime, execute body: @escaping () -> Void) { delayed.append(body) }
    func drain() { while !immediate.isEmpty { immediate.removeFirst()() } }
    func expire() { let work = delayed; delayed.removeAll(); for body in work { body() }; drain() }
}
enum DispatchQueue { static let main = ManualQueue() }

final class NWConnection {
    enum State { case ready, failed(Error), cancelled, preparing }
    enum SendCompletion { case contentProcessed((Error?) -> Void) }
    struct Endpoint { var debugDescription: String { "fixture-endpoint" } }
    let endpoint = Endpoint()
    var stateUpdateHandler: ((State) -> Void)?
    var receives: [(Data?, Int?, Bool, Error?) -> Void] = []
    var sends: [Data] = []
    var cancels = 0
    var starts = 0
    var completeSends = true
    func start(queue: ManualQueue) { starts += 1 }
    func cancel() { cancels += 1 }
    func receive(minimumIncompleteLength: Int, maximumLength: Int,
                 completion: @escaping (Data?, Int?, Bool, Error?) -> Void) { receives.append(completion) }
    func deliver(_ data: Data?, complete: Bool = false, error: Error? = nil) {
        precondition(!receives.isEmpty, "Fixture must deliver only requested reads")
        receives.removeFirst()(data, nil, complete, error)
    }
    func send(content: Data?, completion: SendCompletion) {
        if let content { sends.append(content) }
        if completeSends, case .contentProcessed(let body) = completion { body(nil) }
    }
}

/* PRODUCTION_WIRE_TYPES */

struct PeelAudioStreamHello: Decodable { let type: String }
final class AudioRecorder {
    var attachments = 0
    func attach(_ candidate: NWConnection, hello: PeelAudioStreamHello, hasTrailingData: Bool) { attachments += 1 }
}
final class DelegateRecorder {
    var events: [String] = []
    var lines: [(String, UInt64)] = []
    func hostNetworkServer(_ server: HostNetworkServer, didUpdateStatus: String) { events.append("status") }
    func hostNetworkServerDidConnect(_ server: HostNetworkServer) { events.append("connect") }
    func hostNetworkServerDidDisconnect(_ server: HostNetworkServer) { events.append("disconnect") }
    func hostNetworkServer(_ server: HostNetworkServer, didReceiveLine: String, generation: UInt64) {
        lines.append((didReceiveLine, generation))
    }
}

final class HostNetworkServer {
    let listenerAdmissionLock = NSLock()
    var listenerAdmissionEpoch = UUID()
    var knownControlPairingIDs = Set<String>()
    var pendingConnections: [ObjectIdentifier: (NWConnection, UUID)] = [:]
    let connectionQueue = ManualQueue()
    let sendStateLock = NSLock()
    var sendConnection: NWConnection?
    var sendGeneration: UInt64 = 7
    var connection: NWConnection?
    var receiveBuffer = Data("incumbent-buffer".utf8)
    var isDiscoverable = true
    let hostId = "fixture-host"
    let audioChannel = AudioRecorder()
    let delegate: DelegateRecorder? = DelegateRecorder()
    var mediaClosures = 0
    var sendChanges = 0
    var receiveStarts = 0
    var videoPromotions = 0
    typealias SendSnapshot = (connection: NWConnection, generation: UInt64)
    init(incumbent: NWConnection? = NWConnection()) {
        connection = incumbent; sendConnection = incumbent
        updateControlAdmissionPairingIDs(["owner-a", "owner-b"])
    }
    func setActiveSendConnection(_ newConnection: NWConnection?) {
        sendConnection = newConnection; sendGeneration &+= 1; sendChanges += 1
    }
    func closeAllVideoConnections(reason: String) { mediaClosures += 1 }
    func notifyConnectionDidDisconnect(statusMessage: String? = nil) {
        DispatchQueue.main.async { self.delegate?.hostNetworkServerDidDisconnect(self) }
    }
    func startReceiveLoop(for candidate: NWConnection) { receiveStarts += 1 }
    func handleConnectionStateUpdate(_ state: NWConnection.State, for candidate: NWConnection, endpointDesc: String) {}
    func promoteVideoConnection(_ candidate: NWConnection, firstLineData: Data, trailingData: Data, endpointDesc: String) {
        videoPromotions += 1
    }

    /* PRODUCTION_ADMISSION */

    func begin(_ candidate: NWConnection) {
        accept(newConnection: candidate); connectionQueue.drain()
        candidate.stateUpdateHandler?(.ready); connectionQueue.drain()
    }
    func feed(_ candidate: NWConnection, data: Data, complete: Bool = false) {
        candidate.deliver(data, complete: complete); connectionQueue.drain()
    }
    func feed(_ candidate: NWConnection, _ text: String) { feed(candidate, data: Data(text.utf8)) }
    func drainMain() { DispatchQueue.main.drain() }
    func updateMembership(_ ids: Set<String>) { updateControlAdmissionPairingIDs(ids) }
    func invalidate() { invalidatePendingConnections() }
    func queueAccept(_ candidate: NWConnection) { accept(newConnection: candidate) }
    func disconnectIncumbent() { cleanupConnectionOnConnectionQueue(cancelConnection: true) }
    func directClaim(_ candidate: NWConnection, pairingID: String, expectedGeneration: UInt64) -> Bool {
        switch claimPendingControlConnection(candidate, pairingID: pairingID, expectedGeneration: expectedGeneration,
                                             promote: { self.sendChanges += 100 }) {
        case .admitted: return true
        case .stale, .unknownPairing: return false
        }
    }
}

var assertions = 0
func check(_ condition: @autoclosure () -> Bool, _ description: String) {
    assertions += 1
    if !condition() { print("FAIL: \(description)"); exit(1) }
}
func hello(pairing: String? = "owner-b", name: String = "Fixture client", platform: String = "iOS",
           current: Int? = 2, minimum: Int? = 2, type: String = "clientHello") -> String {
    var json: [String: Any] = ["type": type, "deviceName": name, "platform": platform,
                              "extraFutureField": ["enabled": true]]
    if let pairing { json["pairingID"] = pairing }
    if let current { json["protocolVersion"] = current }
    if let minimum { json["minimumSupportedProtocolVersion"] = minimum }
    return String(data: try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), encoding: .utf8)!
}
func preserved(_ server: HostNetworkServer, _ old: NWConnection, _ label: String) {
    server.drainMain()
    check(server.connection === old && server.sendConnection === old, "\(label): incumbent sockets preserved")
    check(server.sendGeneration == 7 && server.sendChanges == 0, "\(label): generation/send snapshot untouched")
    check(server.receiveBuffer == Data("incumbent-buffer".utf8), "\(label): receive buffer untouched")
    check(old.cancels == 0 && old.sends.isEmpty, "\(label): incumbent has no cancel/rejection send")
    check(server.mediaClosures == 0 && server.receiveStarts == 0, "\(label): media/receive lifecycle untouched")
    check(server.delegate!.events.isEmpty && server.delegate!.lines.isEmpty, "\(label): no incumbent delegate callbacks")
}

@main struct AdmissionChecks {
    static func main() {
        let invalid: [(String, String)] = [
            ("not-json", "not json"), ("unknown-first-command", #"{"type":"requestWindowList"}"#),
            ("typed-wrong-discriminator", hello(type: "requestWindowList")),
            ("blank-name", hello(name: " \n\t")), ("blank-platform", hello(platform: " \t")),
            ("missing-name", #"{"type":"clientHello","platform":"iOS","pairingID":"owner-b"}"#),
            ("missing-pairing", hello(pairing: nil)), ("empty-pairing", hello(pairing: " \t")),
            ("unknown-pairing", hello(pairing: "unknown")),
            ("pairing-case-preserved", hello(pairing: "OWNER-B")),
            ("incompatible-old-current", hello(current: 1)),
            ("incompatible-new-minimum", hello(minimum: 3)),
            ("legacy-nil-versions", hello(current: nil, minimum: nil))]
        for (label, line) in invalid {
            let server = HostNetworkServer(), candidate = NWConnection(), old = server.connection!
            server.begin(candidate); server.feed(candidate, line + "\n")
            preserved(server, old, label)
            check(candidate.cancels > 0 && server.pendingConnections.isEmpty, "\(label): candidate closed")
            if label == "unknown-pairing" || label == "pairing-case-preserved" {
                check(candidate.sends.count == 1 && String(data: candidate.sends[0], encoding: .utf8)!.contains("pairingRevoked"), "\(label): candidate-only revocation")
            }
            if label.hasPrefix("incompatible") || label == "legacy-nil-versions" {
                check(candidate.sends.count == 1 && String(data: candidate.sends[0], encoding: .utf8)!.contains("protocolRejected"), "\(label): candidate-only protocol rejection")
            }
        }
        for (label, bytes) in [("empty-firstline", Data([10])), ("invalid-utf8", Data([0xff, 10])),
                               ("oversized-firstline", Data(repeating: 65, count: 16 * 1024 + 1) + Data([10])),
                               ("oversized-unframed", Data(repeating: 65, count: 16 * 1024 + 1))] {
            let server = HostNetworkServer(), candidate = NWConnection(), old = server.connection!
            server.begin(candidate); server.feed(candidate, data: bytes)
            preserved(server, old, label)
            check(candidate.cancels > 0, "\(label): closed")
        }
        do {
            let server = HostNetworkServer(), candidate = NWConnection(), old = server.connection!
            server.begin(candidate); server.feed(candidate, data: Data("incomplete".utf8), complete: true)
            preserved(server, old, "EOF before newline")
            check(candidate.cancels > 0, "EOF: candidate closed")
        }
        // Every actual supported receiver uses these platform values. Platform is
        // validated only as nonempty, never ranked; new platform values work too.
        for platform in ["macOS", "iOS", "visionOS", "Windows", "Linux", "future-platform"] {
            let server = HostNetworkServer(), candidate = NWConnection(), old = server.connection!
            let first = hello(pairing: " \towner-b\n", platform: platform)
            server.begin(candidate); server.feed(candidate, first + "\n" + #"{"type":"requestWindowList"}"# + "\n")
            server.drainMain()
            check(server.connection === candidate && server.sendConnection === candidate, "\(platform): valid stored pairing promoted")
            check(old.cancels == 1 && server.mediaClosures == 1 && server.sendGeneration == 9, "\(platform): normal replacement teardown")
            check(server.delegate!.events == ["disconnect", "status", "connect"], "\(platform): lifecycle order preserved")
            check(server.delegate!.lines.map(\.0) == [first, #"{"type":"requestWindowList"}"#], "\(platform): Hello precedes trailing inventory")
            check(server.delegate!.lines.map(\.1) == [9, 9], "\(platform): lines belong to admitted generation")
        }
        do {
            let server = HostNetworkServer(), one = NWConnection(), two = NWConnection()
            server.begin(one); server.feed(one, hello(pairing: "owner-a") + "\n")
            server.drainMain(); server.begin(two); server.feed(two, hello(pairing: "owner-a") + "\n")
            server.drainMain()
            check(server.connection === two && one.cancels == 1 && server.sendGeneration == 11, "same-owner recovery remains supported")
        }
        do {
            let server = HostNetworkServer(), slow = NWConnection(), fresh = NWConnection()
            server.begin(slow)
            let line = hello() + "\n", split = line.index(line.startIndex, offsetBy: 12)
            let splitAgain = line.index(line.startIndex, offsetBy: 25)
            server.feed(slow, String(line[..<split]))
            server.begin(fresh); server.feed(fresh, hello(pairing: "owner-a") + "\n")
            server.drainMain(); let events = server.delegate!.events
            server.feed(slow, String(line[split..<splitAgain]))
            server.feed(slow, String(line[splitAgain...])); server.drainMain()
            check(server.connection === fresh && server.sendGeneration == 9 && fresh.cancels == 0, "fragmented old candidate cannot evict newer owner")
            check(slow.cancels > 0 && server.delegate!.events == events && server.mediaClosures == 1, "stale candidate cannot reset newer media/lifecycle")
        }
        do {
            let server = HostNetworkServer(), one = NWConnection(), two = NWConnection()
            server.begin(one); server.begin(two)
            server.feed(one, hello() + "\n"); server.drainMain()
            server.feed(two, hello(pairing: "owner-a") + "\n"); server.drainMain()
            check(server.connection === one && two.cancels > 0 && one.cancels == 0 && server.sendGeneration == 9, "simultaneously ready candidates cannot repeatedly replace one another")
        }
        do {
            let server = HostNetworkServer(incumbent: nil), candidate = NWConnection()
            server.begin(candidate)
            server.setActiveSendConnection(nil) // Idle -> idle ABA still changes generation.
            server.feed(candidate, hello() + "\n"); server.drainMain()
            check(server.connection === candidate && server.sendGeneration == 9 && candidate.cancels == 0, "generation change while truly idle does not reject a valid reconnect")
        }
        do {
            let server = HostNetworkServer(), candidate = NWConnection(), old = server.connection!
            server.begin(candidate)
            let line = hello(pairing: "owner-a") + "\n", split = line.index(line.startIndex, offsetBy: 12)
            server.feed(candidate, String(line[..<split]))
            server.disconnectIncumbent() // Actual old-socket cleanup finishes after new TLS-ready.
            check(server.connection == nil && server.sendConnection == nil && server.sendGeneration == 8, "reconnect gap really has no control/send owner")
            server.feed(candidate, String(line[split...])); server.drainMain()
            check(server.connection === candidate && server.sendConnection === candidate && server.sendGeneration == 9, "same-owner recovery spans old socket cleanup")
            check(old.cancels == 1 && candidate.cancels == 0 && server.mediaClosures == 1, "reconnect gap adds no second teardown")
            check(server.delegate!.events == ["disconnect", "status", "connect"], "reconnect gap preserves ordered old disconnect then new connect")
        }
        do {
            let server = HostNetworkServer(), candidate = NWConnection(), old = server.connection!
            server.begin(candidate)
            let line = hello() + "\n", split = line.index(line.startIndex, offsetBy: 9)
            server.feed(candidate, String(line[..<split]))
            server.updateMembership(["owner-a"]) // Revoke after TLS readiness, before final classification.
            server.feed(candidate, String(line[split...]))
            preserved(server, old, "revoked during buffered classification")
            check(candidate.cancels > 0 && candidate.sends.count == 1, "revocation rejects only candidate")
        }
        do {
            let server = HostNetworkServer(), candidate = NWConnection()
            server.begin(candidate); server.updateMembership(["owner-a", "owner-b"])
            server.feed(candidate, hello() + "\n"); server.drainMain()
            check(server.connection === candidate, "metadata-only pairing update does not invalidate valid membership")
        }
        do {
            let server = HostNetworkServer(), candidate = NWConnection(), old = server.connection!
            server.begin(candidate)
            candidate.deliver(Data((hello() + "\n").utf8)) // Receive callback queued before teardown.
            server.invalidate() // Epoch invalidated synchronously, queued cleanup follows receive callback.
            server.connectionQueue.drain()
            preserved(server, old, "stop/repair invalidates listener epoch before queued promotion")
            check(candidate.cancels > 0, "invalid epoch: candidate canceled")
        }
        for boundary in ["membership", "epoch", "generation", "pending"] {
            let server = HostNetworkServer(), candidate = NWConnection(), old = server.connection!
            server.begin(candidate)
            switch boundary {
            case "membership": server.updateMembership(["owner-a"])
            case "epoch": server.listenerAdmissionEpoch = UUID()
            case "generation": server.sendGeneration = 8
            default: server.pendingConnections.removeValue(forKey: ObjectIdentifier(candidate))
            }
            check(!server.directClaim(candidate, pairingID: "owner-b", expectedGeneration: 7), "\(boundary): actual final claim rechecks after prior validation")
            if boundary == "generation" { server.sendGeneration = 7 }
            preserved(server, old, "\(boundary) changed just before final claim")
        }
        do {
            let server = HostNetworkServer(), candidate = NWConnection(), old = server.connection!
            server.begin(candidate); server.connectionQueue.expire() // Existing 10s pending bound.
            candidate.deliver(Data((hello() + "\n").utf8)); server.connectionQueue.drain()
            preserved(server, old, "pending timeout before receive callback")
            check(candidate.cancels > 0 && server.pendingConnections.isEmpty, "expired candidate cannot promote")
        }
        do {
            let server = HostNetworkServer(), candidate = NWConnection(), old = server.connection!
            server.begin(candidate); candidate.completeSends = false
            server.feed(candidate, hello(current: 1) + "\n")
            check(candidate.cancels == 0, "candidate-only rejection may finish writing")
            server.connectionQueue.expire()
            preserved(server, old, "bounded rejection write timeout")
            check(candidate.cancels > 0 && candidate.sends.count == 1, "candidate rejected even when send completion never arrives")
        }
        do {
            let server = HostNetworkServer(), old = server.connection!, candidate = NWConnection()
            server.isDiscoverable = false; server.begin(candidate)
            preserved(server, old, "not discoverable")
            check(candidate.starts == 0 && candidate.cancels > 0, "disabled listener never starts candidate")
        }
        do {
            let server = HostNetworkServer(), old = server.connection!
            for _ in 0..<32 { let c = NWConnection(); server.queueAccept(c) }
            server.connectionQueue.drain()
            let excess = NWConnection(); server.queueAccept(excess); server.connectionQueue.drain()
            preserved(server, old, "pending connection cap")
            check(server.pendingConnections.count == 32 && excess.starts == 0 && excess.cancels > 0, "existing 32 pending connection cap retained")
        }
        do {
            let server = HostNetworkServer(), old = server.connection!, video = NWConnection(), audio = NWConnection()
            server.begin(video); server.feed(video, #"{"type":"videoStreamHello"}"# + "\n")
            server.begin(audio); server.feed(audio, #"{"type":"audioStreamHello"}"# + "\n")
            preserved(server, old, "separate video/audio classification")
            check(server.videoPromotions == 1 && server.audioChannel.attachments == 1, "media sockets retain separate admission paths")
        }
        print("ControlCandidateAdmissionChecks: PASS (\(assertions) assertions, extracted production classification/claim/promotion; fake sockets and deterministic schedulers)")
    }
}
