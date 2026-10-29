//
//  PeelHostSandboxPreferenceMigration.swift
//  Peel-Host
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Imports the small set of Host preferences that can be stranded in the
/// former sandbox container after moving to the shared, non-sandboxed Host.
///
/// This migration is deliberately limited to UserDefaults. It never reads,
/// writes, or removes Keychain material, and it never mutates the old plist.
enum PeelHostSandboxPreferenceMigration {
    enum Result: Equatable {
        case alreadyMigrated
        case sourceAbsent
        case migrated(keys: [String])
        case identityConflict
        case invalidSource
    }

    static let migrationMarkerKey = "PeelHost.sandboxPreferenceMigration.v1"

    private static let legacyBundleIdentifier = "com.zephyrstudiosllc.Peel-Host"
    private static let legacyPreferenceFileName = "com.zephyrstudiosllc.Peel-Host.plist"
    private static let maximumSourceBytes = 1_048_576
    private static let maximumPeers = 128
    private static let maximumPeerNameUTF8Bytes = 256
    private static let maximumPeerServiceNameUTF8Bytes = 256

    private static let hostIDKey = "PeelHost.hostId"
    private static let pairedPeersKey = "PeelPairedPeers.host"
    private static let booleanKeys = [
        "PeelHost.isDiscoverable",
        "allowControlThisMac",
        "showMenuBarIcon",
        "hideDockIcon",
    ]

    /// Uses the real user's home directory rather than an injected test path.
    /// The caller should invoke this before the SwiftUI App initializes.
    @discardableResult
    static func migrateIfNeeded() -> Result {
        migrate(sourceURL: legacyPreferenceURL(), targetDefaults: .standard)
    }

    /// Test and startup injection seam. The target defaults are mutated only
    /// after the source plist has passed its size, type, and model checks.
    @discardableResult
    static func migrate(sourceURL: URL, targetDefaults: UserDefaults) -> Result {
        if targetDefaults.object(forKey: migrationMarkerKey) as? Bool == true {
            return .alreadyMigrated
        }

        switch readSourceData(at: sourceURL) {
        case .absent:
            // A missing file is a successful no-op: there is nothing left to
            // import, so mark it and avoid checking the path on every launch.
            targetDefaults.set(true, forKey: migrationMarkerKey)
            return .sourceAbsent
        case .invalid:
            return .invalidSource
        case let .valid(sourceData):
            guard let source = decodeSource(sourceData) else {
                return .invalidSource
            }

            return migrate(source: source, targetDefaults: targetDefaults)
        }
    }

    private static func migrate(source: SourceValues, targetDefaults: UserDefaults) -> Result {

        let targetHostObject = targetDefaults.object(forKey: hostIDKey)
        let targetHasHostID = targetHostObject != nil
        let targetHostID = targetHostObject as? String
        let targetHasPairings = targetDefaults.object(forKey: pairedPeersKey) != nil

        // A host identity and its pairing metadata are one trust record. Do
        // not mix records from two installations, or create an identity next
        // to pairings whose owner cannot be established.
        if let sourceHostID = source.hostID {
            if targetHasHostID {
                guard let targetHostID,
                      UUID(uuidString: targetHostID) == UUID(uuidString: sourceHostID) else {
                    return applyBooleansAndReturnConflict(
                        source: source,
                        targetDefaults: targetDefaults
                    )
                }
            } else if targetHasPairings {
                return applyBooleansAndReturnConflict(
                    source: source,
                    targetDefaults: targetDefaults
                )
            }
        } else if source.peers != nil || (!targetHasHostID && targetHasPairings) {
            // Pairings without a host identity are not independently
            // attributable. Even an existing target identity cannot prove that
            // these source pairings belong to it, so keep the whole trust
            // record retryable instead of mixing credentials metadata.
            return applyBooleansAndReturnConflict(
                source: source,
                targetDefaults: targetDefaults
            )
        }

        var migratedKeys: [String] = []

        if let sourceHostID = source.hostID, !targetHasHostID {
            targetDefaults.set(sourceHostID, forKey: hostIDKey)
            migratedKeys.append(hostIDKey)
        }

        if let pairingData = source.pairingData, !targetHasPairings {
            targetDefaults.set(pairingData, forKey: pairedPeersKey)
            migratedKeys.append(pairedPeersKey)
        }

        for key in booleanKeys {
            guard let value = source.booleans[key], targetDefaults.object(forKey: key) == nil else {
                continue
            }
            targetDefaults.set(value, forKey: key)
            migratedKeys.append(key)
        }

        targetDefaults.set(true, forKey: migrationMarkerKey)
        return .migrated(keys: migratedKeys)
    }

    private struct SourceValues {
        let hostID: String?
        let peers: [PeelPairedPeer]?
        let pairingData: Data?
        let booleans: [String: Bool]
    }

    private enum SourceData {
        case absent
        case invalid
        case valid(Data)
    }

    private static func legacyPreferenceURL() -> URL {
        let userName = NSUserName()
        let homePath = userName.isEmpty ? nil : NSHomeDirectoryForUser(userName)
        let homeURL = homePath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser

        return homeURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Containers", isDirectory: true)
            .appendingPathComponent(legacyBundleIdentifier, isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent(legacyPreferenceFileName, isDirectory: false)
    }

    private static func readSourceData(at url: URL) -> SourceData {
        let flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        let descriptor = url.path.withCString { path in
            open(path, flags)
        }
        guard descriptor >= 0 else {
            return (errno == ENOENT || errno == ENOTDIR) ? .absent : .invalid
        }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0,
              info.st_size <= Int64(maximumSourceBytes) else {
            return .invalid
        }

        var data = Data()
        data.reserveCapacity(min(Int(info.st_size), maximumSourceBytes))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        // Read through the same descriptor that was fstat'ed. Request one
        // byte beyond the cap so a file that grows after fstat is rejected,
        // while never allowing an unbounded replacement to enter memory.
        while data.count <= maximumSourceBytes {
            let requested = min(buffer.count, maximumSourceBytes + 1 - data.count)
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return read(descriptor, baseAddress, requested)
            }

            if bytesRead > 0 {
                data.append(contentsOf: buffer.prefix(bytesRead))
                if data.count > maximumSourceBytes {
                    return .invalid
                }
                continue
            }
            if bytesRead == 0 {
                return .valid(data)
            }
            if errno == EINTR {
                continue
            }
            return .invalid
        }
        return .invalid
    }

    private static func decodeSource(_ data: Data) -> SourceValues? {
        guard let propertyList = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ), let dictionary = propertyList as? [String: Any] else {
            return nil
        }

        let hostID: String?
        if let rawHostID = dictionary[hostIDKey] {
            guard let value = rawHostID as? String,
                  UUID(uuidString: value) != nil,
                  validText(value, maximumUTF8Bytes: 64, allowEmpty: false) else {
                return nil
            }
            hostID = value
        } else {
            hostID = nil
        }

        let peers: [PeelPairedPeer]?
        let pairingData: Data?
        if let rawPeers = dictionary[pairedPeersKey] {
            guard let data = rawPeers as? Data,
                  data.count <= maximumSourceBytes,
                  let decodedPeers = try? JSONDecoder().decode([PeelPairedPeer].self, from: data),
                  validatePeers(decodedPeers) else {
                return nil
            }
            peers = decodedPeers
            pairingData = data
        } else {
            peers = nil
            pairingData = nil
        }

        var booleans: [String: Bool] = [:]
        for key in booleanKeys {
            if let rawValue = dictionary[key] {
                guard let value = rawValue as? Bool else {
                    return nil
                }
                booleans[key] = value
            }
        }

        return SourceValues(hostID: hostID, peers: peers, pairingData: pairingData, booleans: booleans)
    }

    private static func validatePeers(_ peers: [PeelPairedPeer]) -> Bool {
        guard peers.count <= maximumPeers else { return false }

        var seenIDs = Set<UUID>()
        for peer in peers {
            guard let peerID = UUID(uuidString: peer.id),
                  seenIDs.insert(peerID).inserted,
                  validText(peer.displayName, maximumUTF8Bytes: maximumPeerNameUTF8Bytes, allowEmpty: false) else {
                return false
            }

            if let serviceName = peer.serviceName,
               !validText(serviceName, maximumUTF8Bytes: maximumPeerServiceNameUTF8Bytes, allowEmpty: true) {
                return false
            }

            if let stableHostId = peer.stableHostId {
                guard UUID(uuidString: stableHostId) != nil,
                      validText(stableHostId, maximumUTF8Bytes: 64, allowEmpty: false) else {
                    return false
                }
            }

            guard peer.createdAt.timeIntervalSince1970.isFinite,
                  peer.lastSeenAt?.timeIntervalSince1970.isFinite ?? true else {
                return false
            }
        }
        return true
    }

    private static func validText(
        _ value: String,
        maximumUTF8Bytes: Int,
        allowEmpty: Bool
    ) -> Bool {
        guard value.utf8.count <= maximumUTF8Bytes,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            return false
        }
        return allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func applyBooleansAndReturnConflict(
        source: SourceValues,
        targetDefaults: UserDefaults
    ) -> Result {
        // Booleans are independent preferences, so a conflict in the trust
        // record does not prevent filling an absent UI preference. Deliberately
        // leave the migration marker unset so a later repair can retry trust
        // data without losing the source.
        for key in booleanKeys {
            guard let value = source.booleans[key], targetDefaults.object(forKey: key) == nil else {
                continue
            }
            targetDefaults.set(value, forKey: key)
        }
        return .identityConflict
    }
}
