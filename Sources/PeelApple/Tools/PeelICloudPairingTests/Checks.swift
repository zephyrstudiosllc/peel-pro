import Foundation
import Security

private var checks = 0
private func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { fatalError(message) }
}
private func mustThrow(_ message: String, _ action: () throws -> Void) {
    checks += 1
    do { try action(); fatalError(message) } catch { }
}

nonisolated private final class MemoryKeychain: PeelICloudKeychainAccess {
    var items = [[String: Any]]()
    var queries = [[String: Any]]()
    var failUpdates: OSStatus?
    var failAdds: OSStatus?
    func copyMatching(_ query: [String: Any], result: inout CFTypeRef?) -> OSStatus {
        queries.append(query)
        if items.isEmpty { return errSecItemNotFound }
        result = items as CFArray
        return errSecSuccess
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        queries.append(query)
        if let failUpdates { return failUpdates }
        guard let index = items.firstIndex(where: {
            $0[kSecAttrAccount as String] as? String == query[kSecAttrAccount as String] as? String
        }) else { return errSecItemNotFound }
        items[index].merge(attributes) { _, new in new }
        return errSecSuccess
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        queries.append(attributes)
        if let failAdds { return failAdds }
        items.append(attributes)
        return errSecSuccess
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        queries.append(query)
        items.removeAll { $0[kSecAttrAccount as String] as? String == query[kSecAttrAccount as String] as? String }
        return errSecSuccess
    }
}

@main struct Checks {
    static func main() throws {
        let hostID = UUID().uuidString, enrollmentID = UUID().uuidString
        let secret = Data(repeating: 0xa7, count: 32)
        let record = try PeelICloudHostRecord(hostID: hostID, enrollmentID: enrollmentID,
            displayName: "Office Mac", endpointHost: "office.tailabc.ts.net", controlPort: 49706,
            pairingPort: 49707, bootstrapSecret: secret)
        expect(record.isValid, "valid host rejected")
        expect(try JSONDecoder().decode(PeelICloudHostRecord.self, from: JSONEncoder().encode(record)) == record, "record round trip")
        expect(record.tlsIdentity.contains(enrollmentID), "TLS identity must rotate with enrollment")
        for host in ["100.64.0.1", "100.127.255.254", "10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.1.2", "fd7a:115c:a1e0::1", "office.local"] {
            expect(PeelICloudPairingValidation.endpointHost(host) == host, "private host rejected: \(host)")
        }
        expect(PeelICloudPairingValidation.endpointHost(" OFFICE.TAILABC.TS.NET ") == "office.tailabc.ts.net", "host normalization")
        for host in ["100.63.255.255", "100.128.0.1", "172.15.0.1", "172.32.0.1", "8.8.8.8", "127.0.0.1", "0.0.0.0", "169.254.1.2", "::1", "2001:4860:4860::8888", "https://office.ts.net", "user@office.ts.net", "office.ts.net/path", "office.ts.net.evil.com", "office.ts.net:22", "-bad.ts.net", "bad..ts.net", "office.ts.net\nother", "$(whoami).local"] {
            expect(PeelICloudPairingValidation.endpointHost(host) == nil, "unsafe host accepted: \(host)")
        }
        mustThrow("short enrollment secret accepted") {
            _ = try PeelICloudHostRecord(hostID: hostID, enrollmentID: enrollmentID, displayName: "Mac",
                endpointHost: "100.87.53.84", controlPort: 49706, pairingPort: 49707, bootstrapSecret: Data())
        }
        mustThrow("same control/enrollment port accepted") {
            _ = try PeelICloudHostRecord(hostID: hostID, enrollmentID: enrollmentID, displayName: "Mac",
                endpointHost: "100.87.53.84", controlPort: 49706, pairingPort: 49706, bootstrapSecret: secret)
        }
        var invalidJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        invalidJSON["version"] = 2
        let untrustedRecord = try JSONDecoder().decode(PeelICloudHostRecord.self, from: JSONSerialization.data(withJSONObject: invalidJSON))
        expect(!untrustedRecord.isValid, "unknown schema accepted")
        let request = PeelICloudPairRequest(hostID: hostID, enrollmentID: enrollmentID, clientDeviceID: UUID().uuidString, clientName: "New Phone")
        expect(request.isValid(for: record), "valid request rejected")
        let wireRequest = try PeelICloudEnrollmentTransport.requestLine(request)
        if case .request(let parsed) = PeelICloudPairRequestFrameDecoder.decode(wireRequest) {
            expect(parsed.requestID == request.requestID && parsed.isValid(for: record), "Host parser changed request")
        } else { fatalError("actual transport frame rejected by actual Host parser") }
        if case .incomplete = PeelICloudPairRequestFrameDecoder.decode(Data(wireRequest.dropLast())) {
            expect(true, "partial frame")
        } else { fatalError("unframed JSON accepted before LF") }
        if case .invalid = PeelICloudPairRequestFrameDecoder.decode(Data(wireRequest.dropLast()), isComplete: true) {
            expect(true, "closed incomplete frame")
        } else { fatalError("closed unframed JSON accepted") }
        for badFrame in [Data("not-json\n".utf8), wireRequest + Data("{}\n".utf8), Data(repeating: 0x78, count: 8193)] {
            if case .invalid = PeelICloudPairRequestFrameDecoder.decode(badFrame) { expect(true, "invalid frame") }
            else { fatalError("malformed/oversized/multiple frame accepted") }
        }
        let wrongEpoch = PeelICloudPairRequest(hostID: hostID, enrollmentID: UUID().uuidString, clientDeviceID: request.clientDeviceID, clientName: request.clientName)
        expect(!wrongEpoch.isValid(for: record), "stale enrollment accepted")
        let malformedDevice = PeelICloudPairRequest(hostID: hostID, enrollmentID: enrollmentID, clientDeviceID: "Office Mac", clientName: request.clientName)
        expect(!malformedDevice.isValid(for: record), "display name accepted as device ID")
        let response = PeelICloudPairResponse(hostID: hostID, enrollmentID: enrollmentID,
            requestID: request.requestID, hostName: "Office Mac", accepted: true, pairingID: UUID().uuidString, psk: secret)
        expect(response.isValid(for: request), "valid response rejected")
        let anotherRequest = PeelICloudPairRequest(hostID: hostID, enrollmentID: enrollmentID,
            clientDeviceID: request.clientDeviceID, clientName: request.clientName)
        expect(!response.isValid(for: anotherRequest), "response replay into another attempt accepted")
        let forgedHost = PeelICloudPairResponse(hostID: UUID().uuidString, enrollmentID: enrollmentID,
            requestID: request.requestID, hostName: "Office Mac", accepted: true, pairingID: UUID().uuidString, psk: secret)
        expect(!forgedHost.isValid(for: request), "other host accepted")
        let shortPSK = PeelICloudPairResponse(hostID: hostID, enrollmentID: enrollmentID,
            requestID: request.requestID, hostName: "Office Mac", accepted: true, pairingID: UUID().uuidString, psk: Data([1]))
        expect(!shortPSK.isValid(for: request), "short transport key accepted")
        let denied = PeelICloudPairResponse(hostID: hostID, enrollmentID: enrollmentID,
            requestID: request.requestID, hostName: "Office Mac", accepted: false, reason: "Device removed on this Mac.")
        expect(denied.isValid(for: request), "valid denial rejected")

        let memory = MemoryKeychain()
        let group = "V729QMY3V6.com.zephyrstudiosllc.Peel.icloud-pairing"
        let vault = PeelICloudPairingVault(accessGroup: group, keychain: memory)
        expect(memory.queries.isEmpty, "initialization read keychain without opt-in")
        try vault.upsert(record)
        expect(try vault.records() == [record], "shared keychain round trip")
        let second = try PeelICloudHostRecord(hostID: UUID().uuidString, enrollmentID: UUID().uuidString,
            displayName: "Other Mac", endpointHost: "100.78.40.111", controlPort: 49706, pairingPort: 49707, bootstrapSecret: Data(repeating: 3, count: 32))
        try vault.upsert(second)
        try vault.remove(hostID: hostID)
        expect(try vault.records() == [second], "removal affected another host")
        for query in memory.queries {
            expect(query[kSecAttrService as String] as? String == PeelICloudPairingVault.service, "legacy service queried")
            expect(query[kSecAttrAccessGroup as String] as? String == group, "shared group missing")
            expect(query[kSecAttrSynchronizable as String] as? Bool == true, "sync flag missing")
            expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true, "Mac data protection flag missing")
            expect(query[kSecAttrAccessible as String] as? String != kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String, "sync incompatible accessibility")
        }
        let badConfig = PeelICloudPairingVault(accessGroup: "$(AppIdentifierPrefix)com.zephyrstudiosllc.Peel.icloud-pairing", keychain: memory)
        expect(!badConfig.isConfigured, "unexpanded signing configuration accepted")
        let calls = memory.queries.count
        mustThrow("unsigned build read keychain") { _ = try badConfig.records() }
        expect(memory.queries.count == calls, "unsigned build queried keychain")
        memory.failUpdates = errSecMissingEntitlement
        mustThrow("missing entitlement silently ignored") { try vault.upsert(record) }
        expect(!memory.items.contains { $0[kSecAttrAccount as String] as? String == hostID }, "failed write added host")
        memory.failUpdates = nil
        memory.items.append([kSecAttrAccount as String: hostID, kSecValueData as String: Data("corrupt".utf8)])
        expect(try vault.records() == [second], "corrupt sync data accepted")

        let fullMemory = MemoryKeychain()
        fullMemory.items = (0..<32).map { _ in
            [kSecAttrAccount as String: UUID().uuidString, kSecValueData as String: Data("corrupt".utf8)]
        }
        let fullVault = PeelICloudPairingVault(accessGroup: group, keychain: fullMemory)
        mustThrow("corrupt entries bypassed the raw item bound") { try fullVault.upsert(record) }
        expect(fullMemory.items.count == 32, "over-limit item was added")
        fullMemory.items = Array(repeating: [kSecAttrAccount as String: second.hostID,
                                            kSecValueData as String: try JSONEncoder().encode(second)], count: 32)
        try fullVault.upsert(second)
        expect(fullMemory.items.count == 32, "existing update incorrectly consumed capacity")
        fullMemory.items.append([:])
        mustThrow("oversized item result accepted") { _ = try fullVault.records() }
        let mismatchMemory = MemoryKeychain()
        mismatchMemory.items = [[kSecAttrAccount as String: UUID().uuidString,
                                  kSecValueData as String: try JSONEncoder().encode(record)]]
        expect(try PeelICloudPairingVault(accessGroup: group, keychain: mismatchMemory).records().isEmpty,
               "record from another keychain account accepted")

        let oldJSON = "{\"id\":\"\(UUID().uuidString)\",\"displayName\":\"Existing Mac\",\"createdAt\":0}"
        let oldPeer = try JSONDecoder().decode(PeelPairedPeer.self, from: Data(oldJSON.utf8))
        expect(oldPeer.iCloudEnrollmentID == nil, "legacy pairing migrated into cloud authority")
        print("PASS \(checks) iCloud pairing checks; fake Keychain only, no account or secret access.")
    }
}
