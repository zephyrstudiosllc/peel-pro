import Foundation

// Mirrors HostNetworkServer's session identity so the controller compiles alone.
nonisolated struct PeelControlSession: Hashable, Sendable {
    let pairingID: String
    let generation: UInt64
}

final class FakeKeys: PeelSourceMediaKeyPosting {
    var result: PeelSourceMediaKeyPostResult = .posted
    var posted: [PeelSourceMediaAction] = []
    func post(_ action: PeelSourceMediaAction) -> PeelSourceMediaKeyPostResult {
        if result == .posted { posted.append(action) }
        return result
    }
}

final class FakeVolume: PeelSourceVolumeControlling {
    var device: UInt32? = 5
    var volume: Double? = 0.4
    var muted: Bool? = false
    var volumeSettable = true
    var muteSettable = true
    var refuseWrite = false
    /// Simulates the default output changing while the write happens.
    var switchDeviceDuringApply = false
    var writes: [(Double?, Bool?)] = []

    func currentDevice() -> UInt32? { device }

    func read() -> PeelSourceVolumeReading {
        guard let device else {
            return PeelSourceVolumeReading(device: nil, volume: nil, muted: nil, canSetVolume: false, canSetMute: false)
        }
        return PeelSourceVolumeReading(device: device, volume: volume, muted: muted,
                                       canSetVolume: volumeSettable && volume != nil,
                                       canSetMute: muteSettable && muted != nil)
    }

    func apply(volume newVolume: Double?, muted newMuted: Bool?, expectedDevice: UInt32) -> PeelSourceVolumeApplyResult {
        guard let device else { return .noOutputDevice }
        guard device == expectedDevice else { return .deviceChanged }
        let before = read()
        if newVolume != nil, !before.canSetVolume { return .notSettable }
        if newMuted != nil, !before.canSetMute { return .notSettable }
        if refuseWrite { return .failed }
        writes.append((newVolume, newMuted))
        // A real device may quantize; report what it holds, not what was asked.
        if let newVolume { volume = (newVolume * 16).rounded() / 16 }
        if let newMuted { muted = newMuted }
        if switchDeviceDuringApply { self.device = 9; return .deviceChanged }
        return .applied(read())
    }
}

final class Fixture {
    let pairing = "pair-A"
    let generation: UInt64 = 7
    var locked = false
    var visible = true
    var control = true
    var ax = true
    var bound = true
    var clock: UInt64 = 1_000_000_000
    var queued: [@MainActor @Sendable () -> Void] = []
    var replies: [PeelSourceMediaReply] = []
    let keys = FakeKeys()
    let volume = FakeVolume()
    lazy var controller = PeelSourceMediaController(
        gate: { [unowned self] generation in
            PeelSourceMediaGate(
                session: self.bound && generation == self.generation
                    ? PeelControlSession(pairingID: self.pairing, generation: self.generation) : nil,
                lockedOrAsleep: self.locked, clientVisible: self.visible,
                controlEnabled: self.control, accessibilityTrusted: self.ax)
        },
        keys: keys,
        volume: volume,
        send: { [unowned self] reply, _ in self.replies.append(reply) },
        schedule: { [unowned self] work in self.queued.append(work) },
        uptimeNanoseconds: { [unowned self] in self.clock })

    init() {
        controller.noteStreamStarted(windowId: 42)
        controller.noteStreamOpened(windowId: 42)
    }

    func run() { let work = queued; queued.removeAll(); work.forEach { $0() } }

    func send(_ json: String, inputBlocked: Bool = false) {
        let type = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["type"] as? String ?? ""
        controller.receive(type: type, data: Data(json.utf8), generation: generation, inputBlocked: inputBlocked)
    }

    func lastAck() -> (String, String?)? {
        guard case .ack(let ack)? = replies.last else { return nil }
        return (ack.status, ack.reason)
    }
}

let id = "6F1C2B0E-6A43-4D57-9C3B-2E8A1F4D9B70"

func volumeQuery(_ scope: String = "systemOutput", window: UInt32 = 42) -> String {
    #"{"type":"sourceVolumeQuery","version":1,"requestId":"\#(id)","pairingId":"pair-A","windowId":\#(window),"scope":"\#(scope)"}"#
}

func volumeSet(_ fields: String, scope: String = "systemOutput", window: UInt32 = 42) -> String {
    #"{"type":"sourceVolumeSet","version":1,"requestId":"\#(id)","pairingId":"pair-A","windowId":\#(window),"scope":"\#(scope)"\#(fields)}"#
}

func command(_ action: String = "playPause", window: UInt32 = 42, version: Int = 1,
             request: String = id, pairing: String = "pair-A") -> String {
    #"{"type":"sourceMediaCommand","version":\#(version),"requestId":"\#(request)","pairingId":"\#(pairing)","windowId":\#(window),"action":"\#(action)"}"#
}

func lastState(_ f: Fixture) -> PeelSourceVolumeState? {
    guard case .volumeState(let state)? = f.replies.last else { return nil }
    return state
}

var failures = 0
func expect(_ condition: Bool, _ name: String) {
    if !condition { failures += 1; print("FAIL:", name) }
}

@main
struct PeelSourceMediaHarness {
    static func main() {
        // Identity rules.
        expect(PeelSourceMediaProtocol.isRequestID(id), "uuid accepted")
        expect(!PeelSourceMediaProtocol.isRequestID("{" + id.dropFirst() + "}"), "braced uuid rejected")
        expect(!PeelSourceMediaProtocol.isRequestID(id.replacingOccurrences(of: "-", with: "")), "undashed rejected")
        expect(!PeelSourceMediaProtocol.isPairingID(""), "empty pairing rejected")
        expect(!PeelSourceMediaProtocol.isPairingID("a\u{0}b"), "NUL pairing rejected")
        expect(!PeelSourceMediaProtocol.isPairingID(String(repeating: "x", count: 257)), "long pairing rejected")
        expect(!PeelSourceMediaProtocol.isVolume(.nan) && !PeelSourceMediaProtocol.isVolume(1.01), "volume bounds")

        // Applied: exactly one down/up pair, only after the scheduled recheck.
        var f = Fixture()
        f.send(command())
        expect(f.keys.posted.isEmpty && f.replies.isEmpty, "nothing posted before execution")
        f.run()
        expect(f.keys.posted == [.playPause], "one post")
        expect(f.lastAck()?.0 == "applied", "applied ack")

        // Unknown action / version: unsupported. Bad shape: invalid. Bad identity: dropped.
        f = Fixture(); f.send(command("shuffle")); expect(f.lastAck()?.0 == "unsupported", "unknown action")
        f = Fixture(); f.send(command(version: 2)); expect(f.lastAck()?.0 == "unsupported", "unknown version")
        f = Fixture()
        f.send(#"{"type":"sourceMediaCommand","version":"1","requestId":"\#(id)","pairingId":"pair-A","windowId":42,"action":"playPause"}"#)
        expect(f.lastAck()?.0 == "invalid", "string version invalid")
        f = Fixture(); f.send(command(request: "nope")); expect(f.replies.isEmpty, "bad request id dropped")
        f = Fixture(); f.send(command(pairing: "pair-B")); expect(f.replies.isEmpty, "other pairing dropped")
        f = Fixture(); f.send(command().replacingOccurrences(of: #""windowId":42"#, with: #""windowId":4294967296"#))
        expect(f.replies.isEmpty, "window overflow dropped")
        f = Fixture(); f.bound = false; f.send(command()); expect(f.replies.isEmpty, "unbound dropped")

        // Gates at receipt.
        f = Fixture(); f.control = false; f.send(command()); expect(f.lastAck()! == ("denied", "controlOff"), "control off")
        f = Fixture(); f.ax = false; f.send(command()); expect(f.lastAck()! == ("denied", "accessibilityMissing"), "ax")
        f = Fixture(); f.visible = false; f.send(command()); expect(f.lastAck()! == ("denied", "notVisible"), "hidden")
        f = Fixture(); f.send(command(window: 9)); expect(f.lastAck()! == ("stale", "staleStream"), "not streamed")
        f = Fixture(); f.send(command(), inputBlocked: true); f.run()
        expect(f.keys.posted.isEmpty && f.lastAck()! == ("denied", "controlOff"), "router-blocked never posts")

        // Execution-time recheck and fences.
        f = Fixture(); f.send(command()); f.locked = true; f.run()
        expect(f.keys.posted.isEmpty && f.lastAck()! == ("denied", "locked"), "lock before effect")
        f = Fixture(); f.send(command()); f.controller.invalidate(clearStreams: false); f.run()
        expect(f.keys.posted.isEmpty && f.lastAck()?.0 == "stale", "epoch fence")
        f = Fixture(); f.send(command()); f.controller.noteStreamClosed(windowId: 42); f.run()
        expect(f.keys.posted.isEmpty && f.lastAck()! == ("stale", "staleStream"), "stream closed fence")
        f = Fixture(); f.send(command()); f.bound = false; f.run()
        expect(f.keys.posted.isEmpty && f.replies.isEmpty, "disconnect fence")

        // Explicit stop: queued action never posts; the still-open socket alone
        // cannot revive it; a fresh start on the reused socket admits once.
        f = Fixture(); f.send(command()); f.controller.noteStreamStopped(windowId: 42); f.run()
        expect(f.keys.posted.isEmpty && f.lastAck()! == ("stale", "staleStream"), "stop fences queued action")
        f.send(command()); f.run()
        expect(f.keys.posted.isEmpty && f.lastAck()! == ("stale", "staleStream"), "socket alone after stop refused")
        f.controller.noteStreamOpened(windowId: 42); f.send(command()); f.run()
        expect(f.keys.posted.isEmpty && f.lastAck()! == ("stale", "staleStream"), "reopened socket alone refused")
        f.controller.noteStreamStarted(windowId: 42); f.send(command()); f.run()
        expect(f.keys.posted == [.playPause] && f.lastAck()?.0 == "applied", "fresh start admits once")
        f = Fixture(); f.controller.noteStreamStarted(windowId: 7); f.send(command(window: 7))
        expect(f.lastAck()! == ("stale", "staleStream"), "start without socket refused")
        f.controller.noteStreamOpened(windowId: 7); f.send(command(window: 7)); f.run()
        expect(f.keys.posted == [.playPause], "start plus socket admits")

        // Permission revoke/re-enable cycle: the router's permission boundary
        // invalidates; the old action is stale, a new permitted one posts.
        f = Fixture(); f.send(command())
        f.control = false; f.controller.invalidate(clearStreams: false); f.control = true
        f.run()
        expect(f.keys.posted.isEmpty && f.lastAck()! == ("stale", nil), "revoke cycle stales old action")
        f.send(command(request: "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D")); f.run()
        expect(f.keys.posted == [.playPause] && f.lastAck()?.0 == "applied", "new permitted action posts")

        // OS refusal is reported, never applied.
        f = Fixture(); f.keys.result = .accessDenied; f.send(command()); f.run()
        expect(f.lastAck()! == ("denied", "accessibilityMissing"), "post access denied")
        f = Fixture(); f.keys.result = .unavailable; f.send(command()); f.run()
        expect(f.lastAck()! == ("failed", "osRefused"), "event unavailable")

        // Rate: 5 per second per session.
        f = Fixture()
        for _ in 0..<6 { f.send(command()) }
        expect(f.lastAck()! == ("denied", "rateLimited"), "sixth limited")
        f.run(); expect(f.keys.posted.count == 5, "five posted")
        f.clock += 1_000_000_000; f.send(command()); f.run()
        expect(f.keys.posted.count == 6, "window slides")

        // Volume: peelStream never pretends.
        f = Fixture(); f.control = false; f.send(volumeQuery("peelStream"))
        if case .volumeState(let state)? = f.replies.last {
            expect(!state.supported && state.volume == nil && state.muted == nil && state.requestId == id &&
                   state.reason == "scopeUnsupported" && state.isValid, "query unsupported state")
        } else { expect(false, "query state reply") }

        // systemOutput query: read-only, no Allow Control / AX needed, actual values.
        f = Fixture(); f.control = false; f.ax = false; f.send(volumeQuery())
        if let state = lastState(f) {
            expect(state.supported && state.volume == 0.4 && state.muted == false && state.canSetVolume &&
                   state.canSetMute && state.reason == nil && state.requestId == id && state.sequence == 1 &&
                   state.isValid, "query actual state")
        } else { expect(false, "query actual reply") }
        expect(f.volume.writes.isEmpty, "query never writes")
        f.send(volumeQuery()); expect(lastState(f)?.sequence == 2, "sequence increases")
        f = Fixture(); f.visible = false; f.send(volumeQuery()); expect(f.lastAck()! == ("denied", "notVisible"), "query hidden")
        f = Fixture(); f.send(volumeQuery(window: 9)); expect(f.lastAck()! == ("stale", "staleStream"), "query stream")
        f = Fixture(); f.volume.device = nil; f.send(volumeQuery())
        expect(lastState(f).map { !$0.supported && $0.reason == "noOutputDevice" && $0.volume == nil && $0.isValid } == true,
               "no output device")
        f = Fixture(); f.volume.volume = nil; f.volume.muted = nil; f.send(volumeQuery())
        expect(lastState(f).map { !$0.supported && $0.reason == "fixedVolume" && !$0.canSetVolume && $0.isValid } == true,
               "fixed output unsupported")
        f = Fixture(); f.volume.volumeSettable = false; f.volume.muteSettable = false; f.send(volumeQuery())
        expect(lastState(f).map { $0.supported && $0.volume == 0.4 && !$0.canSetVolume && !$0.canSetMute &&
                                  $0.reason == "fixedVolume" } == true, "readable but fixed")
        f = Fixture(); f.volume.volumeSettable = false; f.send(volumeQuery())
        expect(lastState(f).map { $0.supported && !$0.canSetVolume && $0.canSetMute && $0.reason == nil } == true,
               "partial: mute only")
        f = Fixture(); f.volume.muted = nil; f.send(volumeQuery())
        expect(lastState(f).map { $0.supported && $0.canSetVolume && !$0.canSetMute && $0.muted == nil } == true,
               "partial: volume only")

        // systemOutput set: queued user input, actual post-write state echoed.
        f = Fixture(); f.send(volumeSet(#","volume":0.7"#))
        expect(f.volume.writes.isEmpty && f.replies.isEmpty, "set waits for recheck")
        f.run()
        expect(f.volume.writes.count == 1 && f.volume.writes[0].0 == 0.7 && f.volume.writes[0].1 == nil, "one write")
        expect(lastState(f).map { $0.supported && $0.volume == 0.6875 && $0.requestId == id } == true,
               "actual quantized value, not requested")
        f = Fixture(); f.send(volumeSet(#","muted":true"#)); f.run()
        expect(lastState(f)?.muted == true && f.volume.writes.count == 1, "mute only set")
        f = Fixture(); f.send(volumeSet(#","volume":1.5"#)); f.run()
        expect(f.lastAck()?.0 == "invalid" && f.volume.writes.isEmpty, "set range invalid")
        f = Fixture(); f.send(volumeSet(#","volume":-0.1"#)); f.run()
        expect(f.lastAck()?.0 == "invalid" && f.volume.writes.isEmpty, "set negative invalid")
        f = Fixture(); f.send(volumeSet(#","volume":"0.5""#)); f.run()
        expect(f.lastAck()?.0 == "invalid" && f.volume.writes.isEmpty, "set string invalid")
        f = Fixture(); f.control = false; f.send(volumeSet(#","volume":0.5"#)); f.run()
        expect(f.lastAck()! == ("denied", "controlOff") && f.volume.writes.isEmpty, "set control off")
        f = Fixture(); f.ax = false; f.send(volumeSet(#","volume":0.5"#)); f.run()
        expect(f.lastAck()! == ("denied", "accessibilityMissing") && f.volume.writes.isEmpty, "set ax")
        f = Fixture(); f.send(volumeSet(#","volume":0.5"#), inputBlocked: true); f.run()
        expect(f.volume.writes.isEmpty && f.lastAck()! == ("denied", "controlOff"), "router-blocked set never writes")
        f = Fixture(); f.send(volumeSet(#","volume":0.5"#)); f.controller.noteStreamStopped(windowId: 42); f.run()
        expect(f.volume.writes.isEmpty && f.lastAck()! == ("stale", "staleStream"), "set stop fence")
        f = Fixture(); f.send(volumeSet(#","volume":0.5"#)); f.controller.invalidate(clearStreams: false); f.run()
        expect(f.volume.writes.isEmpty && f.lastAck()! == ("stale", nil), "set epoch fence")
        f = Fixture(); f.send(volumeSet(#","volume":0.5"#)); f.control = false; f.run()
        expect(f.volume.writes.isEmpty && f.lastAck()! == ("denied", "controlOff"), "set control recheck")
        f = Fixture(); f.send(volumeSet(#","volume":0.5"#)); f.locked = true; f.run()
        expect(f.volume.writes.isEmpty && f.lastAck()! == ("denied", "locked"), "set lock recheck")
        f = Fixture(); f.send(volumeSet(#","volume":0.5"#)); f.bound = false; f.run()
        expect(f.volume.writes.isEmpty && f.replies.isEmpty, "set disconnect fence")
        f = Fixture(); f.send(volumeSet(#","volume":0.5"#)); f.volume.device = 9; f.run()
        expect(f.volume.writes.isEmpty && f.lastAck()! == ("stale", nil), "device changed before write")
        f = Fixture(); f.volume.switchDeviceDuringApply = true; f.send(volumeSet(#","volume":0.5"#)); f.run()
        expect(f.lastAck()! == ("stale", nil), "device changed during write")
        f = Fixture(); f.volume.device = nil; f.send(volumeSet(#","volume":0.5"#)); f.run()
        expect(f.lastAck()! == ("failed", "noOutputDevice") && f.volume.writes.isEmpty, "no device at receipt")
        f = Fixture(); f.volume.volumeSettable = false; f.send(volumeSet(#","volume":0.5,"muted":true"#)); f.run()
        expect(f.volume.writes.isEmpty && f.lastAck()! == ("unsupported", "fixedVolume"), "not settable writes nothing")
        f = Fixture(); f.volume.refuseWrite = true; f.send(volumeSet(#","volume":0.5"#)); f.run()
        expect(f.lastAck()! == ("failed", "osRefused"), "os refused write")
        f = Fixture(); for _ in 0..<21 { f.send(volumeSet(#","volume":0.5"#)) }
        expect(f.lastAck()! == ("denied", "rateLimited"), "21st set limited")
        f.run(); expect(f.volume.writes.count == 20, "twenty writes")
        f = Fixture(); f.send(volumeSet(#","volume":0.5"#, scope: "peelStream")); f.run()
        expect(f.lastAck()! == ("unsupported", "scopeUnsupported") && f.volume.writes.isEmpty, "peelStream set unsupported")
        f = Fixture()
        f.send(#"{"type":"sourceVolumeSet","version":1,"requestId":"\#(id)","pairingId":"pair-A","windowId":42,"scope":"peelStream","volume":1.5}"#)
        expect(f.lastAck()?.0 == "invalid", "out of range not clamped")
        f = Fixture()
        f.send(#"{"type":"sourceVolumeSet","version":1,"requestId":"\#(id)","pairingId":"pair-A","windowId":42,"scope":"peelStream"}"#)
        expect(f.lastAck()?.0 == "invalid", "empty set invalid")
        f = Fixture()
        f.send(#"{"type":"sourceVolumeQuery","version":1,"requestId":"\#(id)","pairingId":"pair-A","windowId":42,"scope":"roomSpeakers"}"#)
        expect(f.lastAck()! == ("unsupported", "scopeUnsupported"), "unknown scope")

        // Encoded replies never carry NaN or receiver data.
        let ack = PeelSourceMediaAck(requestId: id, pairingId: "pair-A", windowId: 42, status: .applied)
        let encoded = String(decoding: try! JSONEncoder().encode(ack), as: UTF8.self)
        expect(!encoded.contains("reason") && ack.parsed?.status == .applied, "ack encoding")

        if failures == 0 { print("PeelSourceMediaHarness: all checks passed") } else { exit(1) }
    }
}
