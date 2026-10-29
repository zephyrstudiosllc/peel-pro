import Foundation
import CryptoKit

// This is advisory metadata. There are deliberately no pairing keys, addresses,
// PINs, task text, file paths, authorization tokens, or remote-action APIs here.
struct PeelCloudAgentDigest: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let provider: String
    let state: String
    let updatedAt: Date

    static let providers: Set<String> = ["codex", "grok_bot", "grok", "claude", "unknown"]
    static let states: Set<String> = ["idle", "working", "toolRunning", "waiting", "completed", "error"]

    static func snapshot(localID: String, deviceID: String, provider: String, state: String,
                         updatedAt: Date) -> Self {
        let digest = SHA256.hash(data: Data((deviceID + ":" + localID).utf8))
        return Self(id: digest.map { String(format: "%02x", $0) }.joined(),
                    provider: providers.contains(provider) ? provider : "unknown",
                    state: states.contains(state) ? state : "idle", updatedAt: updatedAt)
    }

    var isValid: Bool {
        id.utf8.count == 64 && id.allSatisfy { "0123456789abcdef".contains($0) }
            && Self.providers.contains(provider) && Self.states.contains(state)
            && updatedAt.timeIntervalSince1970.isFinite
    }
}

struct PeelCloudDeviceMetadata: Codable, Equatable, Sendable, Identifiable {
    enum Platform: String, Codable, Sendable { case mac, iPhone, iPad, vision }
    static let schemaVersion = 1
    static let maximumAgents = 24
    static let maximumDevices = 128
    static let maximumPayloadBytes = 16_384
    static let lifetime: TimeInterval = 30 * 24 * 60 * 60
    static let tombstoneLifetime: TimeInterval = 7 * 24 * 60 * 60

    let schema: Int
    let id: String
    let writerID: String
    let revision: Int64
    let displayName: String
    let platform: Platform
    /// Public Bonjour host identity, used only to label an existing local
    /// pairing. It is never written into the pairing store or used to connect.
    let discoveryID: String?
    let updatedAt: Date
    let expiresAt: Date
    let isDeleted: Bool
    let agents: [PeelCloudAgentDigest]

    func isValid(at now: Date) -> Bool {
        schema == Self.schemaVersion && UUID(uuidString: id) != nil && UUID(uuidString: writerID) != nil
            && revision >= 0 && revision <= Int64((now.timeIntervalSince1970 + 300) * 1000)
            && !displayName.isEmpty && displayName.utf8.count <= 128
            && displayName.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
            && (discoveryID == nil || UUID(uuidString: discoveryID!) != nil)
            && updatedAt.timeIntervalSince1970.isFinite && updatedAt <= now.addingTimeInterval(300)
            && expiresAt > updatedAt && expiresAt <= updatedAt.addingTimeInterval(Self.lifetime)
            && agents.count <= Self.maximumAgents && Set(agents.map(\.id)).count == agents.count
            && agents.allSatisfy { $0.isValid && $0.updatedAt <= now.addingTimeInterval(300) }
            && (!isDeleted || agents.isEmpty)
    }

    func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumPayloadBytes else { throw PeelAccountError.invalidMetadata }
        return data
    }

    static func decoded(_ data: Data, at now: Date) -> Self? {
        guard data.count <= maximumPayloadBytes,
              let record = try? JSONDecoder().decode(Self.self, from: data), record.isValid(at: now)
        else { return nil }
        return record
    }

    /// Per-device last writer wins, with deterministic ties and tombstone wins.
    static func winner(_ lhs: Self, _ rhs: Self) -> Self {
        if lhs.revision != rhs.revision { return lhs.revision > rhs.revision ? lhs : rhs }
        if lhs.isDeleted != rhs.isDeleted { return lhs.isDeleted ? lhs : rhs }
        return lhs.writerID >= rhs.writerID ? lhs : rhs
    }

    /// Query expiry hides rows; it must not silently grant permission to
    /// restore a removed device when an old installation comes online again.
    static func publicationWinner(_ existing: Self, _ proposed: Self,
                                  allowingTombstoneRestore: Bool) -> Self {
        if existing.isDeleted && !proposed.isDeleted && !allowingTombstoneRestore { return existing }
        return winner(existing, proposed)
    }

    static func merge(_ records: [Self], at now: Date) -> [Self] {
        var byID: [String: Self] = [:]
        // The transport also bounds its query. This defensive bound keeps a
        // malformed fake/provider from allocating an unbounded client cache.
        for record in records.prefix(maximumDevices * 2) where record.isValid(at: now) && record.expiresAt > now {
            byID[record.id] = byID[record.id].map { winner($0, record) } ?? record
        }
        return byID.values.sorted {
            $0.revision == $1.revision ? $0.id < $1.id : $0.revision > $1.revision
        }.prefix(maximumDevices).map { $0 }
    }
}

struct PeelAppleAccountProfile: Codable, Equatable, Sendable {
    let userID: String
    let email: String?
    var usesPrivateRelay: Bool { email?.lowercased().hasSuffix("@privaterelay.appleid.com") == true }
}

enum PeelAccountError: LocalizedError {
    case setupRequired, iCloudUnavailable, accountChanged, invalidMetadata, credentialUnavailable, secureStorage(Int32)
    var errorDescription: String? {
        switch self {
        case .setupRequired: "iCloud sync is not configured for this build yet. Local pairing remains available."
        case .iCloudUnavailable: "Sign in to iCloud in system Settings, then refresh. Local pairing remains available."
        case .accountChanged: "The system iCloud account changed. Enable sync again for the current account."
        case .invalidMetadata: "Device metadata could not be validated."
        case .credentialUnavailable: "Apple sign-in is no longer authorized. Sign in again if you want to use it."
        case .secureStorage(let status): "The Apple account profile could not be saved securely (\(status))."
        }
    }
}

/// Dependency boundary has no access to PeelPairingStore or any action sender.
@MainActor
protocol PeelCloudMetadataTransport {
    func availableAccountID() async throws -> String
    func fetchDevices(now: Date) async throws -> [PeelCloudDeviceMetadata]
    func saveDevice(_ device: PeelCloudDeviceMetadata, allowingTombstoneRestore: Bool) async throws -> PeelCloudDeviceMetadata
}

@MainActor
protocol PeelAppleProfileStorage {
    func load() throws -> PeelAppleAccountProfile?
    func save(_ profile: PeelAppleAccountProfile) throws
    func remove() throws
}

@MainActor
protocol PeelAppleCredentialChecking {
    func isAuthorized(userID: String) async throws -> Bool
}
