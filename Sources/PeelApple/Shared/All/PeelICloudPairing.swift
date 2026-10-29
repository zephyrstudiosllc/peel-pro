import Foundation
import Security
import Darwin

/// Separate from ordinary, device-local pairing PSKs. Each Mac owns one optional
/// iCloud Keychain enrollment record; enrollment still creates a new device pair.
nonisolated struct PeelICloudHostRecord: Codable, Identifiable, Equatable, Sendable {
    let version: Int
    let hostID: String
    let enrollmentID: String
    let displayName: String
    let endpointHost: String
    let controlPort: UInt16
    let pairingPort: UInt16
    let bootstrapSecret: Data
    let updatedAt: Date

    var id: String { hostID }
    var tlsIdentity: String { "peel-icloud-v1-\(hostID)-\(enrollmentID)" }

    init(hostID: String, enrollmentID: String, displayName: String,
         endpointHost: String, controlPort: UInt16, pairingPort: UInt16,
         bootstrapSecret: Data, updatedAt: Date = Date()) throws {
        self.version = 1
        self.hostID = hostID
        self.enrollmentID = enrollmentID
        self.displayName = displayName
        self.endpointHost = endpointHost
        self.controlPort = controlPort
        self.pairingPort = pairingPort
        self.bootstrapSecret = bootstrapSecret
        self.updatedAt = updatedAt
        guard isValid else { throw PeelICloudPairingError.invalidRecord }
    }

    var isValid: Bool {
        version == 1 && PeelICloudPairingValidation.validDeviceID(hostID) &&
        PeelICloudPairingValidation.validDeviceID(enrollmentID) &&
        PeelICloudPairingValidation.cleanName(displayName) == displayName &&
        PeelICloudPairingValidation.endpointHost(endpointHost) == endpointHost &&
        controlPort > 0 && pairingPort > 0 && controlPort != pairingPort &&
        bootstrapSecret.count == 32 && updatedAt.timeIntervalSince1970.isFinite &&
        updatedAt.timeIntervalSince1970 > 0
    }
}

nonisolated enum PeelICloudPairingValidation {
    static func validDeviceID(_ value: String) -> Bool {
        value.utf8.count == 36 && UUID(uuidString: value) != nil
    }

    static func cleanName(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 128,
              value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return value
    }

    /// Restrict synced endpoints to private transport. Never store URLs, public
    /// IPs, credentials, paths, scoped addresses or shell text in this record.
    static func endpointHost(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("["), value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        guard !value.isEmpty, value.utf8.count <= 253,
              value.unicodeScalars.allSatisfy({ $0.isASCII }),
              value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else { return nil }
        var ipv4 = in_addr()
        if inet_pton(AF_INET, value, &ipv4) == 1 {
            let address = UInt32(bigEndian: ipv4.s_addr)
            let privateAddress = (address & 0xff000000) == 0x0a000000 ||
                (address & 0xfff00000) == 0xac100000 ||
                (address & 0xffff0000) == 0xc0a80000 ||
                (address & 0xffc00000) == 0x64400000
            return privateAddress ? value : nil
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, value, &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            return Array(bytes.prefix(6)) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0] ? value : nil
        }
        guard value.hasSuffix(".ts.net") || value.hasSuffix(".local") else { return nil }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
            label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        }) else { return nil }
        return value
    }

    static func generateSecret() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard result == errSecSuccess else { throw PeelICloudPairingError.keychain(result) }
        return Data(bytes)
    }
}

nonisolated struct PeelICloudPairRequest: Codable, Sendable {
    var type = "icloudPairRequest"
    let hostID: String
    let enrollmentID: String
    let requestID: String
    let clientDeviceID: String
    let clientName: String

    init(hostID: String, enrollmentID: String, requestID: String = UUID().uuidString,
         clientDeviceID: String, clientName: String) {
        self.hostID = hostID
        self.enrollmentID = enrollmentID
        self.requestID = requestID
        self.clientDeviceID = clientDeviceID
        self.clientName = clientName
    }

    func isValid(for record: PeelICloudHostRecord) -> Bool {
        record.isValid && type == "icloudPairRequest" && hostID == record.hostID &&
        enrollmentID == record.enrollmentID &&
        PeelICloudPairingValidation.validDeviceID(requestID) &&
        PeelICloudPairingValidation.validDeviceID(clientDeviceID) &&
        PeelICloudPairingValidation.cleanName(clientName) == clientName
    }
}

nonisolated struct PeelICloudPairResponse: Codable, Sendable {
    var type = "icloudPairResponse"
    let hostID: String
    let enrollmentID: String
    let requestID: String
    let hostName: String
    let accepted: Bool
    let pairingID: String?
    let psk: Data?
    let reason: String?

    init(hostID: String, enrollmentID: String, requestID: String, hostName: String,
         accepted: Bool, pairingID: String? = nil, psk: Data? = nil, reason: String? = nil) {
        self.hostID = hostID
        self.enrollmentID = enrollmentID
        self.requestID = requestID
        self.hostName = hostName
        self.accepted = accepted
        self.pairingID = pairingID
        self.psk = psk
        self.reason = reason
    }

    func isValid(for request: PeelICloudPairRequest) -> Bool {
        guard type == "icloudPairResponse", hostID == request.hostID,
              enrollmentID == request.enrollmentID, requestID == request.requestID,
              PeelICloudPairingValidation.cleanName(hostName) == hostName else { return false }
        if accepted {
            guard let pairingID, PeelICloudPairingValidation.validDeviceID(pairingID),
                  let psk, psk.count == 32, reason == nil else { return false }
        } else {
            guard pairingID == nil, psk == nil,
                  let reason, PeelICloudPairingValidation.cleanName(reason) == reason else { return false }
        }
        return true
    }
}

/// Used by the real Host receiver and wire fixtures. A JSON payload without its
/// LF terminator is incomplete, never an accepted enrollment message.
nonisolated enum PeelICloudPairRequestFrameDecoder {
    static let maximumBytes = 8192
    enum Result {
        case incomplete
        case invalid
        case request(PeelICloudPairRequest)
    }

    static func decode(_ buffer: Data, isComplete: Bool = false) -> Result {
        guard buffer.count <= maximumBytes else { return .invalid }
        guard let newline = buffer.firstIndex(of: 0x0a) else {
            return isComplete ? .invalid : .incomplete
        }
        let trailing = buffer[buffer.index(after: newline)...]
        guard trailing.allSatisfy({ $0 == 0x0a || $0 == 0x0d }),
              let request = try? JSONDecoder().decode(PeelICloudPairRequest.self, from: Data(buffer[..<newline])) else {
            return .invalid
        }
        return .request(request)
    }
}

nonisolated enum PeelICloudPairingError: LocalizedError {
    case unavailable
    case invalidRecord
    case keychain(OSStatus)
    case tooManyHosts

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "This build is not signed for iCloud Pairing. Use code pairing for now."
        case .invalidRecord:
            return "An iCloud pairing record is invalid. Refresh it on the Mac."
        case .keychain(let code):
            if code == errSecMissingEntitlement { return "This build needs iCloud Pairing signing support. Use code pairing for now." }
            if code == errSecInteractionNotAllowed { return "Unlock this device to access iCloud Pairing." }
            return "iCloud Keychain is unavailable (\(code)). Check Passwords & Keychain in iCloud settings."
        case .tooManyHosts:
            return "Too many iCloud Macs. Remove an unused Mac before adding another."
        }
    }
}

nonisolated protocol PeelICloudKeychainAccess {
    func copyMatching(_ query: [String: Any], result: inout CFTypeRef?) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func add(_ attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

nonisolated private final class PeelSystemICloudKeychainAccess: PeelICloudKeychainAccess {
    func copyMatching(_ query: [String: Any], result: inout CFTypeRef?) -> OSStatus {
        SecItemCopyMatching(query as CFDictionary, &result)
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }
    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

/// No keychain reads occur at initialization. Callers must obtain local opt-in
/// before accessing this namespace. Existing pairing/SSH/provider items are never
/// queried or migrated by this store.
nonisolated final class PeelICloudPairingVault {
    static let service = "com.zephyrstudios.peel.icloud-enrollment.v1"
    static let maxHosts = 32
    private let accessGroup: String?
    private let keychain: PeelICloudKeychainAccess
    var isConfigured: Bool { accessGroup != nil }

    init(accessGroup: String? = Bundle.main.object(forInfoDictionaryKey: "PeelICloudPairingAccessGroup") as? String,
         keychain: PeelICloudKeychainAccess? = nil) {
        self.keychain = keychain ?? PeelSystemICloudKeychainAccess()
        if let value = accessGroup, !value.contains("$("),
           value.hasSuffix(".com.zephyrstudiosllc.Peel.icloud-pairing"),
           value.split(separator: ".").first?.count == 10 {
            self.accessGroup = value
        } else {
            self.accessGroup = nil
        }
    }

    private func query(account: String? = nil) throws -> [String: Any] {
        guard let accessGroup else { throw PeelICloudPairingError.unavailable }
        var result: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: true,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let account { result[kSecAttrAccount as String] = account }
        return result
    }

    private func rawItems() throws -> [[String: Any]] {
        var request = try query()
        request[kSecReturnAttributes as String] = true
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = keychain.copyMatching(request, result: &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw PeelICloudPairingError.keychain(status) }
        guard let items = result as? [[String: Any]], items.count <= Self.maxHosts else {
            throw PeelICloudPairingError.tooManyHosts
        }
        return items
    }

    func records() throws -> [PeelICloudHostRecord] {
        var records = [PeelICloudHostRecord]()
        for item in try rawItems() {
            guard let data = item[kSecValueData as String] as? Data, data.count <= 4096,
                  let record = try? JSONDecoder().decode(PeelICloudHostRecord.self, from: data),
                  record.isValid, item[kSecAttrAccount as String] as? String == record.hostID else { continue }
            records.append(record)
        }
        return records.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func upsert(_ record: PeelICloudHostRecord) throws {
        guard record.isValid else { throw PeelICloudPairingError.invalidRecord }
        let data = try JSONEncoder().encode(record)
        guard data.count <= 4096 else { throw PeelICloudPairingError.invalidRecord }
        let request = try query(account: record.hostID)
        let attributes = [kSecValueData as String: data]
        let status = keychain.update(request, attributes: attributes)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw PeelICloudPairingError.keychain(status) }
        guard try rawItems().count < Self.maxHosts else { throw PeelICloudPairingError.tooManyHosts }
        var add = request
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = keychain.add(add)
        if added == errSecDuplicateItem {
            let retried = keychain.update(request, attributes: attributes)
            guard retried == errSecSuccess else { throw PeelICloudPairingError.keychain(retried) }
            return
        }
        guard added == errSecSuccess else { throw PeelICloudPairingError.keychain(added) }
    }

    /// Deletion propagates through iCloud. Host must first stop accepting the
    /// local bootstrap credential; sync deletion alone cannot revoke cached keys.
    func remove(hostID: String) throws {
        guard PeelICloudPairingValidation.validDeviceID(hostID) else { throw PeelICloudPairingError.invalidRecord }
        let status = keychain.delete(try query(account: hostID))
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PeelICloudPairingError.keychain(status) }
    }
}
