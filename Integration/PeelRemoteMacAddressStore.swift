//
//  PeelRemoteMacAddressStore.swift
//  Peel Host
//
//  Bounded, credential-free addresses for already paired Macs. The pairing ID
//  remains the exact TLS-PSK identity; an endpoint never establishes trust.
//

import Foundation

struct PeelRemoteMacAddressRecord: Codable, Hashable, Identifiable {
    let id: UUID
    let pairingID: String
    let displayName: String
    let host: String
    let port: UInt16

    private enum CodingKeys: String, CodingKey {
        case id
        case pairingID
        case displayName
        case host
        case port
    }

    init(
        id: UUID = UUID(),
        pairingID rawPairingID: String,
        displayName rawDisplayName: String,
        host rawHost: String,
        port: UInt16
    ) throws {
        let pairingID = rawPairingID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: pairingID) != nil else {
            throw PeelRemoteMacAddressValidationError.invalidPairingID
        }

        guard let displayName = Self.normalizeDisplayLabel(rawDisplayName) else {
            throw PeelRemoteMacAddressValidationError.invalidDisplayLabel
        }

        guard let host = Self.normalizeHost(rawHost) else {
            throw PeelRemoteMacAddressValidationError.invalidHost
        }

        guard port > 0 else {
            throw PeelRemoteMacAddressValidationError.invalidPort
        }

        self.id = id
        // Preserve the exact pairing identity after trimming. This value is
        // also used for TLS-PSK lookup and must not be case-normalized.
        self.pairingID = pairingID
        self.displayName = displayName
        self.host = host
        self.port = port
    }

    init(
        id: UUID = UUID(),
        pairingID: String,
        displayName: String,
        host: String,
        port: Int
    ) throws {
        guard (1...Int(UInt16.max)).contains(port), let value = UInt16(exactly: port) else {
            throw PeelRemoteMacAddressValidationError.invalidPort
        }
        try self.init(
            id: id,
            pairingID: pairingID,
            displayName: displayName,
            host: host,
            port: value)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(UUID.self, forKey: .id),
                pairingID: container.decode(String.self, forKey: .pairingID),
                displayName: container.decode(String.self, forKey: .displayName),
                host: container.decode(String.self, forKey: .host),
                port: container.decode(UInt16.self, forKey: .port))
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .pairingID,
                in: container,
                debugDescription: "Invalid saved remote Mac address")
        }
    }

    private static func normalizeDisplayLabel(_ rawLabel: String) -> String? {
        guard rawLabel.unicodeScalars.allSatisfy({
            !CharacterSet.controlCharacters.contains($0)
        }) else {
            return nil
        }
        let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty,
              label.utf8.count <= 96
        else {
            return nil
        }
        return label
    }

    /// Mirrors PeelDirectEndpoint.normalizeHost because the Host app target
    /// intentionally does not import the Apple client target. No URL, userinfo,
    /// path, control character, or malformed bracket is accepted.
    static func normalizeHost(_ rawHost: String) -> String? {
        var candidate = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate.utf8.count <= 255 else { return nil }

        if candidate.first == "[" || candidate.last == "]" {
            guard candidate.first == "[", candidate.last == "]" else { return nil }
            candidate.removeFirst()
            candidate.removeLast()
            guard !candidate.isEmpty else { return nil }
        }

        guard !candidate.contains("[") && !candidate.contains("]") else { return nil }

        let forbidden: Set<Character> = ["/", "\\", "?", "#", "%", "@", ",", ";"]
        let whitespaceOrControls = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard candidate.rangeOfCharacter(from: whitespaceOrControls) == nil,
              candidate.unicodeScalars.allSatisfy({ scalar in
                  scalar.value >= 0x21 && scalar.value != 0x7F
              }),
              !candidate.contains(where: { forbidden.contains($0) }) else {
            return nil
        }

        return candidate
    }
}

enum PeelRemoteMacAddressValidationError: LocalizedError, Equatable {
    case invalidPairingID
    case invalidDisplayLabel
    case invalidHost
    case invalidPort

    var errorDescription: String? {
        switch self {
        case .invalidPairingID:
            return "Choose an existing paired computer."
        case .invalidDisplayLabel:
            return "Enter a display name up to 96 characters."
        case .invalidHost:
            return "Enter a host name, IP address, or Tailscale name without a URL or path."
        case .invalidPort:
            return "Enter a port from 1 to 65535."
        }
    }
}

enum PeelRemoteMacAddressStoreError: LocalizedError, Equatable {
    case capacityReached
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .capacityReached:
            return "Remove a saved address before adding another."
        case .encodingFailed:
            return "The address could not be saved."
        }
    }
}

final class PeelRemoteMacAddressStore {
    static let defaultsKey = "peel.remoteMac.savedAddresses.v1"
    static let maxRecords = 16

    private struct Payload: Codable {
        let records: [PeelRemoteMacAddressRecord]
    }

    private let defaults: UserDefaults
    private(set) var records: [PeelRemoteMacAddressRecord]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.records = Self.load(from: defaults)
    }

    func save(_ record: PeelRemoteMacAddressRecord) throws {
        var updated = records
        if let index = updated.firstIndex(where: { $0.id == record.id }) {
            updated[index] = record
        } else {
            guard updated.count < Self.maxRecords else {
                throw PeelRemoteMacAddressStoreError.capacityReached
            }
            updated.append(record)
        }

        guard persist(updated) else {
            throw PeelRemoteMacAddressStoreError.encodingFailed
        }
        records = updated
    }

    func remove(id: UUID) {
        let updated = records.filter { $0.id != id }
        guard updated.count != records.count, persist(updated) else { return }
        records = updated
    }

    func removeUnpaired(validPairingIDs: Set<String>) {
        let updated = records.filter { validPairingIDs.contains($0.pairingID) }
        guard updated.count != records.count, persist(updated) else { return }
        records = updated
    }

    private static func load(from defaults: UserDefaults) -> [PeelRemoteMacAddressRecord] {
        guard let data = defaults.data(forKey: defaultsKey),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.records.count <= maxRecords else {
            return []
        }

        var seen = Set<UUID>()
        guard payload.records.allSatisfy({ seen.insert($0.id).inserted }) else {
            return []
        }
        return payload.records
    }

    private func persist(_ records: [PeelRemoteMacAddressRecord]) -> Bool {
        guard records.count <= Self.maxRecords,
              let data = try? JSONEncoder().encode(Payload(records: records)) else {
            return false
        }
        defaults.set(data, forKey: Self.defaultsKey)
        return true
    }
}
