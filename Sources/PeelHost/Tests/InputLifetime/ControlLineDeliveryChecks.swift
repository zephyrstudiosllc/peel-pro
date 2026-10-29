import Foundation

// The runner inserts the exact production processIncomingData method below.
// A controllable snapshot replaces socket state; no connection is opened.
@MainActor
final class DeliveryRecorder {
    var lines: [String] = []
    var generations: [UInt64] = []
    func hostNetworkServer(_ server: HostNetworkServer, didReceiveLine line: String, generation: UInt64) {
        lines.append(line); generations.append(generation)
    }
}

@MainActor
final class HostNetworkServer {
    let delegate: DeliveryRecorder? = DeliveryRecorder()
    var receiveBuffer = Data()
    var generation: UInt64 = 7
    var active = true
    struct SendSnapshot { let generation: UInt64 }
    func currentSendSnapshot() -> SendSnapshot? { active ? .init(generation: generation) : nil }
    func isCurrentSendSnapshot(_ snapshot: SendSnapshot) -> Bool { active && snapshot.generation == generation }
    func feed(_ text: String) { processIncomingData(Data(text.utf8)) }
    // PRODUCTION_METHOD
}

@main
struct ControlLineDeliveryChecks {
    static func main() async throws {
        let server = HostNetworkServer()
        let recorder = server.delegate!
        let mouse = #"{"type":"mouseScroll","windowId":1,"deltaX":1.5,"deltaY":0}"#
        let key = #"{"type":"keyboardCommand","windowId":1,"command":"enter","action":"down"}"#
        let ping = #"{"type":"clientPing"}"#
        server.feed(mouse + "\n" + key + "\n" + ping + "\n")
        server.generation = 8
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(recorder.lines.isEmpty, "All queued old-connection lines must be dropped before delegate delivery")
        server.feed(mouse + "\n" + key + "\n" + ping + "\n")
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(recorder.lines == [mouse, key, ping] && recorder.generations == [8, 8, 8],
            "Input and lifecycle messages must share ordered, generation-bearing delivery")
        server.feed(key + "\n")
        server.active = false
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(recorder.lines.count == 3, "Disconnected lines cannot be delivered")
        server.active = true; server.generation = 9
        server.feed(String(mouse.prefix(12)))
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(recorder.lines.count == 3)
        server.feed(String(mouse.dropFirst(12)) + "\n")
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(recorder.lines.last == mouse && recorder.generations.last == 9)
        print("ControlLineDeliveryChecks: PASS (production method, queued replacement/disconnect, ordered/partial lines; no sockets)")
    }
}
