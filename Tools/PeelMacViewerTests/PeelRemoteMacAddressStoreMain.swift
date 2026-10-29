import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

private func expectFailure(
    _ operation: () throws -> Void,
    _ message: String
) {
    do {
        try operation()
        preconditionFailure("\(message): expected failure")
    } catch {
        // The production model owns the exact validation error taxonomy. This
        // fixture only needs to establish that invalid input cannot be saved.
    }
}

private func makeRecord(
    id: UUID = UUID(),
    pairingID: String = UUID().uuidString,
    name: String = "Office Mac",
    host: String = "office-mac.example.ts.net",
    port: Int = 7000
) throws -> PeelRemoteMacAddressRecord {
    try PeelRemoteMacAddressRecord(
        id: id,
        pairingID: pairingID,
        displayName: name,
        host: host,
        port: port)
}

@main
struct PeelRemoteMacAddressStoreChecks {
    static func main() throws {
        let exactPairingID = "abcdefab-cdef-abcd-efab-cdefabcdefab"
        let bracketedIPv6 = try makeRecord(
            pairingID: exactPairingID,
            host: "[2001:db8::7]",
            port: 65535)
        require(bracketedIPv6.host == "2001:db8::7", "bracketed IPv6 must be normalized")
        require(bracketedIPv6.pairingID == exactPairingID, "pairing identity spelling must be preserved")

        expectFailure(
            { _ = try makeRecord(pairingID: "not-a-uuid") },
            "non-UUID pairing ID")
        expectFailure(
            { _ = try makeRecord(name: "") },
            "empty display name")
        expectFailure(
            { _ = try makeRecord(name: "Mac\n") },
            "control character in display name")
        expectFailure(
            { _ = try makeRecord(name: String(repeating: "x", count: 97)) },
            "overlong display name")
        for invalidHost in [
            "https://office-mac.example",
            "office-mac.example/path",
            "user@office-mac.example",
            "[2001:db8::7",
            "office mac.example"
        ] {
            expectFailure({ _ = try makeRecord(host: invalidHost) }, "invalid host \(invalidHost)")
        }
        expectFailure({ _ = try makeRecord(port: 0) }, "zero port")
        expectFailure({ _ = try makeRecord(port: 65_536) }, "overflow port")

        let suite = "peel.remote-address.fixture.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Unable to create isolated UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = PeelRemoteMacAddressStore(defaults: defaults)
        require(store.records.isEmpty, "fresh suite must be empty")

        var records: [PeelRemoteMacAddressRecord] = []
        for index in 0..<PeelRemoteMacAddressStore.maxRecords {
            let record = try makeRecord(
                pairingID: UUID().uuidString,
                name: "Mac \(index)",
                host: "mac-\(index).example.ts.net",
                port: 7000 + index)
            records.append(record)
            try store.save(record)
        }
        require(store.records.count == PeelRemoteMacAddressStore.maxRecords, "store must accept exactly max records")

        do {
            try store.save(try makeRecord())
            preconditionFailure("capacity must reject the seventeenth record")
        } catch let error as PeelRemoteMacAddressStoreError {
            require(error == .capacityReached, "capacity error must be explicit")
        }

        let edited = try makeRecord(
            id: records[0].id,
            pairingID: records[0].pairingID,
            name: "Edited Mac",
            host: records[0].host,
            port: Int(records[0].port))
        try store.save(edited)
        require(store.records.count == PeelRemoteMacAddressStore.maxRecords, "editing must not consume capacity")
        require(store.records.first(where: { $0.id == edited.id })?.displayName == "Edited Mac", "edit must replace by record ID")

        let reloaded = PeelRemoteMacAddressStore(defaults: defaults)
        require(reloaded.records.first(where: { $0.id == edited.id })?.displayName == "Edited Mac", "edit must persist")
        reloaded.remove(id: edited.id)
        require(reloaded.records.count == PeelRemoteMacAddressStore.maxRecords - 1, "remove must delete by record ID")
        let afterRemove = PeelRemoteMacAddressStore(defaults: defaults)
        require(afterRemove.records.count == PeelRemoteMacAddressStore.maxRecords - 1, "remove must persist")

        let pruneSuite = "peel.remote-address.prune.\(UUID().uuidString)"
        guard let pruneDefaults = UserDefaults(suiteName: pruneSuite) else {
            fatalError("Unable to create prune UserDefaults suite")
        }
        pruneDefaults.removePersistentDomain(forName: pruneSuite)
        defer { pruneDefaults.removePersistentDomain(forName: pruneSuite) }
        let pruneStore = PeelRemoteMacAddressStore(defaults: pruneDefaults)
        let survivingPairingID = UUID().uuidString
        let orphanPairingID = UUID().uuidString
        try pruneStore.save(try makeRecord(pairingID: survivingPairingID, host: "survivor.example.ts.net"))
        try pruneStore.save(try makeRecord(pairingID: orphanPairingID, host: "orphan.example.ts.net"))
        try pruneStore.save(try makeRecord(pairingID: exactPairingID, host: "exact.example.ts.net"))
        pruneStore.removeUnpaired(validPairingIDs: [survivingPairingID, exactPairingID.uppercased()])
        require(pruneStore.records.count == 1, "orphan pruning must remove unpaired records")
        require(pruneStore.records[0].pairingID == survivingPairingID, "pruning must compare exact pairing IDs")

        let corruptSuite = "peel.remote-address.corrupt.\(UUID().uuidString)"
        guard let corruptDefaults = UserDefaults(suiteName: corruptSuite) else {
            fatalError("Unable to create corrupt UserDefaults suite")
        }
        corruptDefaults.removePersistentDomain(forName: corruptSuite)
        defer { corruptDefaults.removePersistentDomain(forName: corruptSuite) }
        let corruptPayload = Data("{\"records\":[}".utf8)
        corruptDefaults.set(corruptPayload, forKey: PeelRemoteMacAddressStore.defaultsKey)
        require(
            PeelRemoteMacAddressStore(defaults: corruptDefaults).records.isEmpty,
            "invalid payload must fail closed without a write")
        require(
            corruptDefaults.data(forKey: PeelRemoteMacAddressStore.defaultsKey) == corruptPayload,
            "invalid payload must remain untouched")

        print("PeelRemoteMacAddressStoreChecks: PASS")
    }
}
