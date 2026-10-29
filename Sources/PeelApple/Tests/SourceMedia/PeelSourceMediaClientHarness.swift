import Foundation

// Exercises the real client ledger and snapshot admission from
// Shared/Client/PeelSourceMediaController.swift against the real wire types in
// Shared/All/PeelSourceMediaMessages.swift. The session-bound controller and
// UI are iOS/visionOS-only and are covered by check-routing.py.

var failures = 0
func expect(_ condition: Bool, _ name: String) {
    if !condition { failures += 1; print("FAIL:", name) }
}

func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T? {
    try? JSONDecoder().decode(type, from: Data(json.utf8))
}

func ackJSON(_ request: String, pairing: String = "pair-A", window: UInt32 = 42,
             status: String = "applied", reason: String? = nil) -> String {
    let reasonField = reason.map { #","reason":"\#($0)""# } ?? ""
    return #"{"type":"sourceMediaAck","version":1,"requestId":"\#(request)","pairingId":"\#(pairing)","windowId":\#(window),"status":"\#(status)"\#(reasonField)}"#
}

func stateJSON(_ request: String?, pairing: String = "pair-A", window: UInt32 = 42,
               scope: String = "systemOutput", supported: Bool = true, volume: String? = "0.5",
               muted: String? = "false", sequence: UInt64 = 1) -> String {
    let requestField = request.map { #""requestId":"\#($0)","# } ?? ""
    let volumeField = volume.map { #","volume":\#($0)"# } ?? ""
    let mutedField = muted.map { #","muted":\#($0)"# } ?? ""
    return #"{"type":"sourceVolumeState","version":1,\#(requestField)"pairingId":"\#(pairing)","windowId":\#(window),"scope":"\#(scope)","supported":\#(supported),"canSetVolume":\#(supported),"canSetMute":\#(supported)\#(volumeField)\#(mutedField),"sequence":\#(sequence)}"#
}

let binding = PeelSourceMediaBinding(pairingId: "pair-A", windowId: 42, epoch: 3)

@main
struct PeelSourceMediaClientHarness {
    static func main() {
        boundedPending()
        exactAckMatching()
        deadlineAndStatus()
        stateAdmission()
        sequenceIsMonotonic()
        resetDropsEverything()
        streamEndCancelsWindow()
        wireShape()
        if failures == 0 { print("PeelSourceMediaClientHarness: all checks passed") } else { exit(1) }
    }

    static func boundedPending() {
        var ledger = PeelSourceMediaLedger()
        expect(ledger.maximumPending == 8 && ledger.timeout == 3, "contract limits")
        for _ in 0..<8 {
            expect(ledger.begin(.media(.playPause), binding: binding, requestId: UUID(), now: 10) != nil, "under cap")
        }
        expect(ledger.begin(.media(.nextTrack), binding: binding, requestId: UUID(), now: 10) == nil, "ninth refused")
        let bad = PeelSourceMediaBinding(pairingId: "", windowId: 42, epoch: 3)
        var other = PeelSourceMediaLedger()
        expect(other.begin(.media(.playPause), binding: bad, requestId: UUID(), now: 10) == nil, "empty pairing refused")
        expect(other.begin(.media(.playPause), binding: binding, requestId: UUID(), now: .nan) == nil, "NaN clock refused")
        let id = UUID()
        expect(other.begin(.media(.playPause), binding: binding, requestId: id, now: 10) != nil, "first id")
        expect(other.begin(.media(.playPause), binding: binding, requestId: id, now: 10) == nil, "duplicate id refused")
    }

    static func exactAckMatching() {
        var ledger = PeelSourceMediaLedger()
        let id = UUID()
        _ = ledger.begin(.media(.playPause), binding: binding, requestId: id, now: 10)
        let rid = id.uuidString

        for (json, name) in [
            (ackJSON(rid, pairing: "pair-B"), "other pairing"),
            (ackJSON(rid, window: 43), "other window"),
            (ackJSON(rid.lowercased()), "case-changed request id"),
            (ackJSON(UUID().uuidString), "unknown request id"),
        ] {
            let ack = decode(PeelSourceMediaAck.self, json)
            expect(ack != nil, "\(name) decodes")
            if let ack { expect(ledger.resolve(ack, epoch: 3, now: 11) == nil, "\(name) ignored") }
        }
        if let ack = decode(PeelSourceMediaAck.self, ackJSON(rid)) {
            expect(ledger.resolve(ack, epoch: 4, now: 11) == nil, "other epoch ignored")
            expect(ledger.pending.count == 1, "mismatches keep the request pending")
            let resolved = ledger.resolve(ack, epoch: 3, now: 11)
            expect(resolved?.1 == .ack(.applied, nil), "exact match resolves")
            expect(resolved?.0.kind == .media(.playPause), "resolved kind")
            expect(ledger.resolve(ack, epoch: 3, now: 11) == nil, "duplicate reply ignored")
            expect(ledger.pending.isEmpty, "resolved request removed")
        } else {
            expect(false, "matching ack decodes")
        }
    }

    static func deadlineAndStatus() {
        var ledger = PeelSourceMediaLedger()
        let late = UUID()
        _ = ledger.begin(.media(.nextTrack), binding: binding, requestId: late, now: 10)
        if let ack = decode(PeelSourceMediaAck.self, ackJSON(late.uuidString)) {
            expect(ledger.resolve(ack, epoch: 3, now: 13) == nil, "reply at deadline ignored")
            expect(ledger.remove(requestId: late.uuidString) != nil, "timer removes expired request")
        }

        let unknown = UUID()
        _ = ledger.begin(.media(.playPause), binding: binding, requestId: unknown, now: 10)
        if let ack = decode(PeelSourceMediaAck.self, ackJSON(unknown.uuidString, status: "maybe")) {
            expect(ledger.resolve(ack, epoch: 3, now: 11) == nil, "unknown status ignored")
        }
        if let ack = decode(PeelSourceMediaAck.self, ackJSON(unknown.uuidString, status: "denied", reason: "futureCode")) {
            expect(ledger.resolve(ack, epoch: 3, now: 11)?.1 == .ack(.denied, nil), "unknown reason reads as nil")
        }

        let refused = UUID()
        _ = ledger.begin(.volumeSet(.systemOutput), binding: binding, requestId: refused, now: 10)
        if let ack = decode(PeelSourceMediaAck.self, ackJSON(refused.uuidString, status: "unsupported", reason: "scopeUnsupported")) {
            expect(ledger.resolve(ack, epoch: 3, now: 11)?.1 == .ack(.unsupported, .scopeUnsupported),
                   "volume refusal is an ack, never a state")
        }
    }

    static func stateAdmission() {
        var ledger = PeelSourceMediaLedger()
        let media = UUID()
        _ = ledger.begin(.media(.playPause), binding: binding, requestId: media, now: 10)
        if let state = decode(PeelSourceVolumeState.self, stateJSON(media.uuidString)) {
            expect(ledger.resolve(state, epoch: 3, now: 11) == nil, "state cannot resolve a media request")
        }

        let query = UUID()
        _ = ledger.begin(.volumeQuery(.systemOutput), binding: binding, requestId: query, now: 10)
        let rid = query.uuidString
        for (json, name) in [
            (stateJSON(rid, scope: "peelStream"), "other scope"),
            (stateJSON(rid, scope: "futureScope"), "unknown scope"),
            (stateJSON(rid, volume: "1.5"), "out-of-range volume"),
            (stateJSON(rid, volume: "-0.1"), "negative volume"),
            (stateJSON(rid, supported: false, volume: "0.5"), "unsupported with a value"),
            (stateJSON(nil), "unsolicited state"),
            (stateJSON(rid, pairing: "pair-B"), "other pairing"),
            (stateJSON(rid, window: 7), "other window"),
        ] {
            if let state = decode(PeelSourceVolumeState.self, json) {
                expect(ledger.resolve(state, epoch: 3, now: 11) == nil, "\(name) ignored")
            }
        }
        expect(decode(PeelSourceVolumeState.self, stateJSON(rid, volume: "NaN")) == nil, "NaN is not JSON")
        expect(ledger.pending.count == 2, "rejected states leave requests pending")

        if let state = decode(PeelSourceVolumeState.self, stateJSON(rid, volume: "0.25", muted: "true", sequence: 5)) {
            guard case .state(let snapshot?)? = ledger.resolve(state, epoch: 3, now: 11)?.1 else {
                expect(false, "valid state resolves"); return
            }
            expect(snapshot.volume == 0.25 && snapshot.muted == true && snapshot.sequence == 5, "actual values kept")
            expect(snapshot.canAdjustVolume && snapshot.canToggleMute, "settable when reported")
        }

        let unknownValues = UUID()
        _ = ledger.begin(.volumeQuery(.systemOutput), binding: binding, requestId: unknownValues, now: 10)
        if let state = decode(PeelSourceVolumeState.self, stateJSON(unknownValues.uuidString, volume: nil, muted: nil, sequence: 6)),
           case .state(let snapshot?)? = ledger.resolve(state, epoch: 3, now: 11)?.1 {
            expect(!snapshot.canAdjustVolume && !snapshot.canToggleMute, "unknown values cannot be adjusted")
        } else {
            expect(false, "state with unknown values resolves")
        }

        let unsupported = UUID()
        _ = ledger.begin(.volumeQuery(.peelStream), binding: binding, requestId: unsupported, now: 10)
        let wire = PeelSourceVolumeState.unsupported(requestId: unsupported.uuidString, pairingId: "pair-A",
                                                     windowId: 42, scope: .peelStream, sequence: 1)
        if let data = try? JSONEncoder().encode(wire),
           let state = try? JSONDecoder().decode(PeelSourceVolumeState.self, from: data),
           case .state(let snapshot?)? = ledger.resolve(state, epoch: 3, now: 11)?.1 {
            expect(!snapshot.supported && snapshot.volume == nil && snapshot.reason == .scopeUnsupported,
                   "unsupported stays honest")
        } else {
            expect(false, "unsupported state resolves")
        }
    }

    static func sequenceIsMonotonic() {
        var ledger = PeelSourceMediaLedger()
        let first = UUID(), older = UUID()
        _ = ledger.begin(.volumeQuery(.systemOutput), binding: binding, requestId: first, now: 10)
        _ = ledger.begin(.volumeQuery(.systemOutput), binding: binding, requestId: older, now: 10)
        if let state = decode(PeelSourceVolumeState.self, stateJSON(first.uuidString, sequence: 9)) {
            if case .state(let snapshot)? = ledger.resolve(state, epoch: 3, now: 11)?.1 {
                expect(snapshot != nil, "newer sequence shown")
            } else {
                expect(false, "newer sequence resolves")
            }
        }
        if let state = decode(PeelSourceVolumeState.self, stateJSON(older.uuidString, volume: "0.9", sequence: 9)) {
            expect(ledger.resolve(state, epoch: 3, now: 11)?.1 == .state(nil), "equal sequence resolves without a value")
        }
    }

    static func resetDropsEverything() {
        var ledger = PeelSourceMediaLedger()
        let id = UUID()
        _ = ledger.begin(.volumeQuery(.systemOutput), binding: binding, requestId: id, now: 10)
        ledger.reset()
        expect(ledger.pending.isEmpty, "reset clears pending")
        if let state = decode(PeelSourceVolumeState.self, stateJSON(id.uuidString)) {
            expect(ledger.resolve(state, epoch: 3, now: 11) == nil, "reply after reset ignored")
        }
        expect(PeelSourceVolumeScopeSelection.selected == .systemOutput, "volume targets the source system output")
        expect(PeelSourceControlsVisibility.showVolumeKey == "peel.controls.showVolume" &&
               PeelSourceControlsVisibility.showMediaControlsKey == "peel.controls.showMediaControls",
               "visibility keys")
    }

    static func streamEndCancelsWindow() {
        var ledger = PeelSourceMediaLedger()
        let closed = UUID(), other = UUID()
        let otherWindow = PeelSourceMediaBinding(pairingId: "pair-A", windowId: 43, epoch: 3)
        _ = ledger.begin(.volumeSet(.systemOutput), binding: binding, requestId: closed, now: 10)
        _ = ledger.begin(.volumeQuery(.systemOutput), binding: otherWindow, requestId: other, now: 10)
        ledger.removeAll(windowId: 42)
        expect(ledger.pending.count == 1 && ledger.pending[other.uuidString] != nil, "only the ended window is cancelled")
        if let ack = decode(PeelSourceMediaAck.self, ackJSON(closed.uuidString)) {
            expect(ledger.resolve(ack, epoch: 3, now: 11) == nil, "reply for an ended stream is ignored")
        }
        // Same window ID reopened on the same epoch starts a fresh sequence.
        let reopened = UUID()
        _ = ledger.begin(.volumeQuery(.systemOutput), binding: binding, requestId: reopened, now: 12)
        if let state = decode(PeelSourceVolumeState.self, stateJSON(reopened.uuidString, sequence: 1)) {
            if case .state(let snapshot)? = ledger.resolve(state, epoch: 3, now: 13)?.1 {
                expect(snapshot != nil, "reopened stream admits its first state")
            } else {
                expect(false, "reopened stream state resolves")
            }
        }
    }

    static func wireShape() {
        let id = UUID()
        let command = PeelSourceMediaCommand(requestId: id, pairingId: "pair-A", windowId: 42, action: .previousTrack)
        guard let data = try? JSONEncoder().encode(command),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            expect(false, "command encodes"); return
        }
        expect(object["type"] as? String == "sourceMediaCommand" && object["version"] as? Int == 1, "command envelope")
        expect(object["requestId"] as? String == id.uuidString, "request id is the exact UUID string")
        expect(object["action"] as? String == "previousTrack" && object["windowId"] as? Int == 42, "command body")
        expect(data.count < PeelSourceMediaProtocol.maximumLineBytes, "command fits one line")
    }
}
