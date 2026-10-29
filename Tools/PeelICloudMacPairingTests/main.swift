import Foundation

@MainActor private var checks = 0
@MainActor private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { fatalError("FAIL: \(message)") }
}

private let localID = "00000000-0000-4000-8000-000000000001"
private let remoteID = "00000000-0000-4000-8000-000000000002"
private let epoch = "00000000-0000-4000-8000-000000000003"
private let pairID = "00000000-0000-4000-8000-000000000004"
private let fakeKey = Data(repeating: 0x48, count: 32)
private let instant = Date(timeIntervalSince1970: 1_800_000_000)
private func record(_ hostID: String = remoteID) -> PeelICloudHostRecord {
    try! PeelICloudHostRecord(hostID: hostID, enrollmentID: epoch, displayName: "Fixture Mac",
        endpointHost: "100.90.1.2", controlPort: 49752, pairingPort: 49753,
        bootstrapSecret: fakeKey, updatedAt: instant)
}
private enum FixtureError: Error { case expected }

@MainActor private final class Trace { var events: [String] = [] }
@MainActor private final class Vault: PeelICloudMacPairingVaultAccess {
    var isConfigured = true
    var values: [PeelICloudHostRecord] = [record()]
    var reads = 0
    func records() throws -> [PeelICloudHostRecord] { reads += 1; return values }
}
@MainActor private final class Trust: PeelICloudMacPairingTrustAccess {
    var iCloudPeers: [PeelPairedPeer] = []
    var keys: [String: Data] = [:]
    var additions = 0
    var removals: [String] = []
    var failWrite = false
    let trace: Trace
    init(_ trace: Trace) { self.trace = trace }
    func iCloudKey(for pairingID: String) -> Data? { keys[pairingID] }
    func addICloudPair(record: PeelICloudHostRecord, response: PeelICloudPairResponse) throws -> PeelPairedPeer {
        additions += 1; trace.events.append("key")
        if failWrite { throw FixtureError.expected }
        let peer = PeelPairedPeer(id: response.pairingID!, displayName: response.hostName,
            stableHostId: record.hostID, tlsPSKOrder: .standard, iCloudEnrollmentID: record.enrollmentID)
        keys[peer.id] = response.psk!
        iCloudPeers.append(peer)
        return peer
    }
    func removeICloudPair(pairingID: String) {
        removals.append(pairingID); trace.events.append("rollback")
        iCloudPeers.removeAll { $0.id == pairingID }; keys[pairingID] = nil
    }
}
@MainActor private final class Addresses: PeelICloudMacPairingAddressAccess {
    var count = 0
    var writes = 0
    var failWrite = false
    var deferActive = false
    var ids: Set<UUID> = []
    let trace: Trace
    init(_ trace: Trace) { self.trace = trace }
    func canSaveICloudAddress(id: UUID) -> Bool { ids.contains(id) || count < 16 }
    func saveICloudAddress(record: PeelICloudHostRecord, pairingID: String, addressID: UUID) throws -> Bool {
        writes += 1; trace.events.append("address")
        if failWrite { throw FixtureError.expected }
        if deferActive { return false }
        if ids.insert(addressID).inserted { count += 1 }
        return true
    }
}
private final class Connection: PeelICloudMacEnrollmentConnection {
    let record: PeelICloudHostRecord
    let request: PeelICloudPairRequest
    var completion: ((Result<PeelICloudPairResponse, PeelICloudEnrollmentTransportError>) -> Void)?
    var cancels = 0
    init(_ record: PeelICloudHostRecord, _ request: PeelICloudPairRequest) { self.record = record; self.request = request }
    func start(completion: @escaping (Result<PeelICloudPairResponse, PeelICloudEnrollmentTransportError>) -> Void) { self.completion = completion }
    func cancel() { cancels += 1 }
    func accepted(id: String = pairID, requestID: String? = nil, key: Data = fakeKey) {
        completion?(.success(PeelICloudPairResponse(hostID: record.hostID, enrollmentID: record.enrollmentID,
            requestID: requestID ?? request.requestID, hostName: "Fixture Mac", accepted: true, pairingID: id, psk: key)))
    }
}
@MainActor private final class Fixture {
    let domain = "peel-icloud-mac-test-" + UUID().uuidString
    let defaults: UserDefaults
    let vault = Vault()
    let trace = Trace()
    let trust: Trust
    let addresses: Addresses
    var connections: [Connection] = []
    var time = instant
    var foreground = true
    var name = "Fixture Laptop"
    var preview = false
    init() {
        defaults = UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
        trust = Trust(trace); addresses = Addresses(trace)
    }
    func makeController() -> PeelICloudMacPairingController {
        PeelICloudMacPairingController(trust: trust, addresses: addresses, localHostID: localID,
            vault: vault, defaults: defaults, isPreview: preview,
            now: { [unowned self] in self.time }, isForeground: { [unowned self] in self.foreground },
            displayName: { [unowned self] in self.name }, makeConnection: { [unowned self] record, request in
                let value = Connection(record, request); self.connections.append(value); return value
            })
    }
    func cleanup() { defaults.removePersistentDomain(forName: domain) }
}

@main struct Checks {
    @MainActor static func settle() async { for _ in 0..<8 { await Task.yield() } }
    @MainActor static func main() async {
        let idle = Fixture(); defer { idle.cleanup() }
        let off = idle.makeController()
        expect(!off.isEnabled, "receiver default off")
        off.refresh()
        expect(idle.vault.reads == 0 && idle.connections.isEmpty, "init/disabled refresh never reads vault or network")
        expect(idle.defaults.string(forKey: PeelICloudMacPairingController.deviceIDKey) == nil, "default-off initialization creates no identity")

        let forgotten = Fixture(); defer { forgotten.cleanup() }
        PeelICloudMacPairingController.noteExplicitForget(hostID: remoteID, defaults: forgotten.defaults)
        let forgottenController = forgotten.makeController(); forgottenController.setEnabled(true)
        expect(forgotten.connections.isEmpty && forgottenController.hosts.first?.canPairAgain == true,
            "manual Forget before first enable remains suppressed without vault initialization")

        let preview = Fixture(); defer { preview.cleanup() }; preview.preview = true
        let previewController = preview.makeController(); previewController.setEnabled(true)
        expect(!previewController.isEnabled && preview.vault.reads == 0 && preview.connections.isEmpty, "preview remains inert")
        let unavailable = Fixture(); defer { unavailable.cleanup() }; unavailable.vault.isConfigured = false
        let unavailableController = unavailable.makeController(); unavailableController.setEnabled(true)
        expect(!unavailableController.isEnabled && unavailable.vault.reads == 0, "unconfigured signing fails closed")

        let good = Fixture(); defer { good.cleanup() }; good.vault.values = [record(localID), record()]
        let controller = good.makeController(); controller.setEnabled(true)
        expect(good.connections.count == 1 && good.connections[0].record.hostID == remoteID, "own host excluded")
        let request = good.connections[0].request
        expect(UUID(uuidString: request.clientDeviceID) != nil && request.clientDeviceID != localID, "receiver gets separate stable installation UUID")
        expect(good.defaults.string(forKey: PeelICloudMacPairingController.deviceIDKey) == request.clientDeviceID, "installation identity persisted")
        let pendingBytes = good.defaults.data(forKey: PeelICloudMacPairingController.pendingKey)!
        expect(!String(decoding: pendingBytes, as: UTF8.self).contains("bootstrapSecret"), "pending defaults contain no bootstrap secret")
        good.connections[0].accepted(); await settle()
        expect(good.trust.iCloudPeers.count == 1 && good.trust.keys[pairID] == fakeKey, "accepted response persists separate device key")
        expect(good.trust.iCloudPeers[0].stableHostId == remoteID && good.trust.iCloudPeers[0].iCloudEnrollmentID == epoch, "outbound host/epoch metadata exact")
        expect(good.trace.events == ["key", "address"], "credential stored before address")
        expect(good.addresses.count == 1 && !controller.isBusy, "success ends round without any connection-selection capability")
        let addressIDs = good.defaults.dictionary(forKey: PeelICloudMacPairingController.addressIDsKey)!
        expect(UUID(uuidString: addressIDs[remoteID] as! String) != nil, "stable separate address UUID persisted")
        good.addresses.deferActive = true
        controller.refresh(); await settle()
        expect(good.connections.count == 1 && good.trust.additions == 1, "existing exact host updates metadata without new enrollment")
        expect(controller.hosts.first?.detail.contains("deferred") == true, "active viewer address update deferred")
        good.trust.iCloudPeers = []; good.trust.keys = [:]
        controller.refresh(); await settle()
        expect(good.connections.count == 1 && controller.hosts.first?.canPairAgain == true, "Forget remains suppressed on later automatic refresh")
        controller.pairAgain(hostID: remoteID)
        expect(good.connections.count == 2, "Pair Again requires explicit user action")
        controller.setEnabled(false)

        let full = Fixture(); defer { full.cleanup() }; full.addresses.count = 16
        let fullController = full.makeController(); fullController.setEnabled(true)
        expect(full.connections.isEmpty && full.trust.additions == 0, "capacity preflight prevents remote enrollment")
        let race = Fixture(); defer { race.cleanup() }
        let raceController = race.makeController(); raceController.setEnabled(true); race.addresses.count = 16
        race.connections[0].accepted(); await settle()
        expect(race.trust.additions == 0 && race.addresses.writes == 0, "capacity rechecked before credential write")

        let manual = Fixture(); defer { manual.cleanup() }
        let manualController = manual.makeController(); manualController.setEnabled(true)
        let oldID = UUID().uuidString
        manual.trust.iCloudPeers = [PeelPairedPeer(id: oldID, displayName: "Manual", stableHostId: remoteID, tlsPSKOrder: .standard)]
        manual.trust.keys[oldID] = fakeKey
        manual.connections[0].accepted(); await settle()
        expect(manual.trust.additions == 0 && manual.trust.iCloudPeers.first?.id == oldID, "concurrent manual pairing is never replaced")

        let keyFailure = Fixture(); defer { keyFailure.cleanup() }; keyFailure.trust.failWrite = true
        let keyController = keyFailure.makeController(); keyController.setEnabled(true)
        keyFailure.connections[0].accepted(); await settle()
        expect(keyFailure.addresses.writes == 0 && keyFailure.trust.removals.isEmpty, "credential failure never saves address or removes old trust")

        let rollback = Fixture(); defer { rollback.cleanup() }; rollback.addresses.failWrite = true
        let preservedID = UUID().uuidString
        rollback.trust.iCloudPeers = [PeelPairedPeer(id: preservedID, displayName: "Other paired Mac", stableHostId: UUID().uuidString, tlsPSKOrder: .standard)]
        rollback.trust.keys[preservedID] = fakeKey
        let rollbackController = rollback.makeController(); rollbackController.setEnabled(true)
        rollback.connections[0].accepted(); await settle()
        expect(rollback.trace.events == ["key", "address", "rollback"], "address failure rolls back new credential")
        expect(rollback.trust.iCloudPeers.map(\.id) == [preservedID] && rollback.trust.keys[preservedID] == fakeKey, "rollback preserves existing pairings")
        expect(rollback.trust.keys[pairID] == nil, "rollback deletes only new key")

        let invalid = Fixture(); defer { invalid.cleanup() }
        let invalidController = invalid.makeController(); invalidController.setEnabled(true)
        invalid.connections[0].accepted(requestID: UUID().uuidString); await settle()
        expect(invalid.trust.additions == 0 && invalid.addresses.writes == 0, "response request identity must match")
        let badKey = Fixture(); defer { badKey.cleanup() }
        let badKeyController = badKey.makeController(); badKeyController.setEnabled(true)
        badKey.connections[0].accepted(key: Data(repeating: 1, count: 31)); await settle()
        expect(badKey.trust.additions == 0, "invalid key length rejected")

        let stale = Fixture(); defer { stale.cleanup() }
        let staleController = stale.makeController(); staleController.setEnabled(true); staleController.setEnabled(false)
        stale.connections[0].accepted(); await settle()
        expect(stale.trust.additions == 0 && !staleController.isEnabled, "disabled generation rejects late completion")
        let forgottenDuring = Fixture(); defer { forgottenDuring.cleanup() }
        let forgottenDuringController = forgottenDuring.makeController(); forgottenDuringController.setEnabled(true)
        PeelICloudMacPairingController.noteExplicitForget(hostID: remoteID, defaults: forgottenDuring.defaults)
        forgottenDuring.connections[0].accepted(); await settle()
        expect(forgottenDuring.trust.additions == 0, "Forget during network attempt suppresses late success")
        let background = Fixture(); defer { background.cleanup() }
        let backgroundController = background.makeController(); backgroundController.setEnabled(true)
        background.foreground = false; backgroundController.pause()
        background.connections[0].accepted(); await settle()
        expect(background.trust.additions == 0 && !backgroundController.isBusy, "background pause rejects late completion")

        let retry = Fixture(); defer { retry.cleanup() }
        let first = retry.makeController(); first.setEnabled(true)
        let frozen = retry.connections[0].request; first.pause(); retry.name = "Renamed Laptop"
        let second = retry.makeController(); second.setEnabled(true)
        let repeated = retry.connections[1].request
        expect(repeated.requestID == frozen.requestID && repeated.clientName == frozen.clientName, "retry retains request UUID and frozen name across controller restart")
        expect(repeated.clientDeviceID == frozen.clientDeviceID, "retry retains installation ID")
        second.pause(); retry.time = instant.addingTimeInterval(300)
        let expired = retry.makeController(); expired.setEnabled(true)
        expect(retry.connections[2].request.requestID != frozen.requestID && retry.connections[2].request.clientName == "Renamed Laptop", "expired retry gets new bounded request")
        expired.setEnabled(false)

        let bounded = Fixture(); defer { bounded.cleanup() }
        let boundedController = bounded.makeController(); boundedController.setEnabled(true)
        bounded.connections[0].completion?(.failure(.connectionFailed)); await settle()
        try? await Task.sleep(nanoseconds: 1_100_000_000); await settle()
        expect(bounded.connections.count == 2 && bounded.connections[1].request.requestID == bounded.connections[0].request.requestID,
            "single bounded automatic retry keeps exact request identity")
        bounded.connections[1].completion?(.failure(.timedOut)); await settle()
        expect(!boundedController.isBusy && bounded.connections.count == 2, "at most two attempts per host in one round")

        print("PASS: \(checks) Mac receiver enrollment checks (fake vault, transport, trust and addresses; isolated temporary defaults)")
    }
}
