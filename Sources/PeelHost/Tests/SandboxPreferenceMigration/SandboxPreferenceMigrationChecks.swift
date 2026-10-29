import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@main
struct SandboxPreferenceMigrationChecks {
    private static let hostIDKey = "PeelHost.hostId"
    private static let pairedPeersKey = "PeelPairedPeers.host"
    private static let booleanKeys = [
        "PeelHost.isDiscoverable",
        "allowControlThisMac",
        "showMenuBarIcon",
        "hideDockIcon",
    ]

    static func main() throws {
        try sourceAbsentIsMarked()
        try validSourceCopiesAllowlist()
        try existingValuesArePreservedAndMissingValuesFill()
        try identityConflictPreservesTrustDataAndDoesNotMark()
        try pairingsWithoutTargetIdentityAreNotMixed()
        try sourcePairingsWithoutSourceIdentityAreRejectedEvenWithTargetIdentity()
        try malformedSourceDoesNotWriteOrMark()
        try boundsAndDuplicateIDsAreRejected()
        try oversizedAndSymlinkSourcesAreRejected()
        print("sandbox preference migration checks passed")
    }

    private static func sourceAbsentIsMarked() throws {
        let fixture = try Fixture()
        let result = PeelHostSandboxPreferenceMigration.migrate(
            sourceURL: fixture.sourceURL,
            targetDefaults: fixture.defaults
        )

        check(result == .sourceAbsent, "missing source should be a successful no-op")
        check(marker(in: fixture.defaults), "missing source should set the marker")
    }

    private static func validSourceCopiesAllowlist() throws {
        let fixture = try Fixture()
        let hostID = UUID().uuidString
        let stableHostID = UUID().uuidString
        let peerID = UUID().uuidString
        let peer = PeelPairedPeer(
            id: peerID,
            displayName: "Office Mac",
            serviceName: "Peel Host Office",
            stableHostId: stableHostID,
            tlsPSKOrder: .standard,
            lastSeenAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let pairingData = try JSONEncoder().encode([peer])
        try fixture.write([
            hostIDKey: hostID,
            pairedPeersKey: pairingData,
            "PeelHost.isDiscoverable": true,
            "allowControlThisMac": false,
            "showMenuBarIcon": false,
            "hideDockIcon": true,
            "peel.ai.allowAgentNotifications": true,
        ])

        let result = PeelHostSandboxPreferenceMigration.migrate(
            sourceURL: fixture.sourceURL,
            targetDefaults: fixture.defaults
        )
        guard case .migrated(let keys) = result else {
            throw Failure("valid source should migrate")
        }

        check(keys == [hostIDKey, pairedPeersKey] + booleanKeys, "all missing allowlisted keys should be reported")
        check(fixture.defaults.string(forKey: hostIDKey) == hostID, "host identity should be copied")
        check(fixture.defaults.data(forKey: pairedPeersKey) == pairingData, "pairing JSON should be copied byte-for-byte")
        check(fixture.defaults.bool(forKey: "PeelHost.isDiscoverable"), "discoverability should be copied")
        check(!fixture.defaults.bool(forKey: "allowControlThisMac"), "false booleans should be copied")
        check(!fixture.defaults.bool(forKey: "showMenuBarIcon"), "menu bar preference should be copied")
        check(fixture.defaults.bool(forKey: "hideDockIcon"), "dock preference should be copied")
        check(fixture.defaults.object(forKey: "peel.ai.allowAgentNotifications") == nil, "unknown keys must be ignored")
        check(marker(in: fixture.defaults), "valid source should set the marker")
        check(
            PeelHostSandboxPreferenceMigration.migrate(
                sourceURL: fixture.sourceURL,
                targetDefaults: fixture.defaults
            ) == .alreadyMigrated,
            "marked source should not run twice"
        )
    }

    private static func existingValuesArePreservedAndMissingValuesFill() throws {
        let fixture = try Fixture()
        let hostID = UUID().uuidString
        let peerID = UUID().uuidString
        let peer = PeelPairedPeer(id: peerID, displayName: "Paired Mac")
        let pairingData = try JSONEncoder().encode([peer])
        try fixture.write([
            hostIDKey: hostID,
            pairedPeersKey: pairingData,
            "PeelHost.isDiscoverable": true,
            "allowControlThisMac": false,
            "showMenuBarIcon": true,
            "hideDockIcon": false,
        ])

        fixture.defaults.set(hostID, forKey: hostIDKey)
        fixture.defaults.set(false, forKey: "PeelHost.isDiscoverable")
        fixture.defaults.set(true, forKey: "allowControlThisMac")

        // The source pairing key is missing from the target, so only that
        // trust metadata and the two missing UI preferences should be filled.
        fixture.defaults.removeObject(forKey: pairedPeersKey)
        fixture.defaults.removeObject(forKey: "showMenuBarIcon")
        fixture.defaults.removeObject(forKey: "hideDockIcon")
        let result = PeelHostSandboxPreferenceMigration.migrate(
            sourceURL: fixture.sourceURL,
            targetDefaults: fixture.defaults
        )

        guard case .migrated(let keys) = result else {
            throw Failure("same identity should allow missing values to fill")
        }
        check(keys == [pairedPeersKey, "showMenuBarIcon", "hideDockIcon"], "only missing values should be reported")
        check(fixture.defaults.string(forKey: hostIDKey) == hostID, "existing host identity must be preserved")
        check(fixture.defaults.data(forKey: pairedPeersKey) == pairingData, "missing pairing metadata should fill")
        check(!fixture.defaults.bool(forKey: "PeelHost.isDiscoverable"), "existing false preference must be preserved")
        check(fixture.defaults.bool(forKey: "allowControlThisMac"), "existing true preference must be preserved")
        check(fixture.defaults.bool(forKey: "showMenuBarIcon"), "missing menu bar preference should fill")
        check(!fixture.defaults.bool(forKey: "hideDockIcon"), "missing dock preference should fill")
        check(marker(in: fixture.defaults), "coherent migration should set the marker")
    }

    private static func identityConflictPreservesTrustDataAndDoesNotMark() throws {
        let fixture = try Fixture()
        let sourceHostID = UUID().uuidString
        let targetHostID = UUID().uuidString
        let sourcePairingData = try JSONEncoder().encode([
            PeelPairedPeer(id: UUID().uuidString, displayName: "Source Mac")
        ])
        let targetPairingData = try JSONEncoder().encode([
            PeelPairedPeer(id: UUID().uuidString, displayName: "Current Mac")
        ])
        try fixture.write([
            hostIDKey: sourceHostID,
            pairedPeersKey: sourcePairingData,
            "showMenuBarIcon": false,
        ])
        fixture.defaults.set(targetHostID, forKey: hostIDKey)
        fixture.defaults.set(targetPairingData, forKey: pairedPeersKey)

        let result = PeelHostSandboxPreferenceMigration.migrate(
            sourceURL: fixture.sourceURL,
            targetDefaults: fixture.defaults
        )

        check(result == .identityConflict, "different host identities should conflict")
        check(fixture.defaults.string(forKey: hostIDKey) == targetHostID, "conflicting host identity must be preserved")
        check(fixture.defaults.data(forKey: pairedPeersKey) == targetPairingData, "conflicting pairing data must be preserved")
        check(fixture.defaults.bool(forKey: "showMenuBarIcon") == false, "independent booleans may still fill")
        check(!marker(in: fixture.defaults), "identity conflict must remain retryable")
    }

    private static func pairingsWithoutTargetIdentityAreNotMixed() throws {
        let fixture = try Fixture()
        let sourceHostID = UUID().uuidString
        let sourcePairingData = try JSONEncoder().encode([
            PeelPairedPeer(id: UUID().uuidString, displayName: "Source Mac")
        ])
        let existingPairingData = try JSONEncoder().encode([
            PeelPairedPeer(id: UUID().uuidString, displayName: "Existing Mac")
        ])
        try fixture.write([
            hostIDKey: sourceHostID,
            pairedPeersKey: sourcePairingData,
        ])
        fixture.defaults.set(existingPairingData, forKey: pairedPeersKey)

        let result = PeelHostSandboxPreferenceMigration.migrate(
            sourceURL: fixture.sourceURL,
            targetDefaults: fixture.defaults
        )

        check(result == .identityConflict, "target pairing data without identity should conflict")
        check(fixture.defaults.object(forKey: hostIDKey) == nil, "source identity must not join target pairings")
        check(fixture.defaults.data(forKey: pairedPeersKey) == existingPairingData, "target pairings must be preserved")
        check(!marker(in: fixture.defaults), "identity conflict must remain retryable")
    }

    private static func sourcePairingsWithoutSourceIdentityAreRejectedEvenWithTargetIdentity() throws {
        let fixture = try Fixture()
        let targetHostID = UUID().uuidString
        let pairingData = try JSONEncoder().encode([
            PeelPairedPeer(id: UUID().uuidString, displayName: "Source Mac")
        ])
        try fixture.write([pairedPeersKey: pairingData])
        fixture.defaults.set(targetHostID, forKey: hostIDKey)

        let result = PeelHostSandboxPreferenceMigration.migrate(
            sourceURL: fixture.sourceURL,
            targetDefaults: fixture.defaults
        )

        check(result == .identityConflict, "source pairings without source identity must be rejected")
        check(fixture.defaults.string(forKey: hostIDKey) == targetHostID, "target identity must be preserved")
        check(fixture.defaults.object(forKey: pairedPeersKey) == nil, "source pairings must not be mixed")
        check(!marker(in: fixture.defaults), "source pairings without identity must remain retryable")
    }

    private static func malformedSourceDoesNotWriteOrMark() throws {
        let fixture = try Fixture()
        try fixture.write([
            hostIDKey: "not-a-uuid",
            "PeelHost.isDiscoverable": true,
        ])

        let result = PeelHostSandboxPreferenceMigration.migrate(
            sourceURL: fixture.sourceURL,
            targetDefaults: fixture.defaults
        )

        check(result == .invalidSource, "invalid source identity should be rejected")
        check(fixture.defaults.object(forKey: hostIDKey) == nil, "invalid source must not write identity")
        check(fixture.defaults.object(forKey: "PeelHost.isDiscoverable") == nil, "invalid source must not partially write booleans")
        check(!marker(in: fixture.defaults), "invalid source must remain retryable")

        let peerFixture = try Fixture()
        let peerData = try JSONEncoder().encode([
            PeelPairedPeer(id: UUID().uuidString, displayName: "Valid Mac", stableHostId: "bad-host-id")
        ])
        try peerFixture.write([pairedPeersKey: peerData])
        check(
            PeelHostSandboxPreferenceMigration.migrate(
                sourceURL: peerFixture.sourceURL,
                targetDefaults: peerFixture.defaults
            ) == .invalidSource,
            "invalid stable host ID should be rejected"
        )
        check(!marker(in: peerFixture.defaults), "invalid peer source must remain retryable")
    }

    private static func boundsAndDuplicateIDsAreRejected() throws {
        let tooManyFixture = try Fixture()
        let tooManyPeers = (0..<129).map { _ in
            PeelPairedPeer(id: UUID().uuidString, displayName: "Mac")
        }
        try tooManyFixture.write([
            pairedPeersKey: try JSONEncoder().encode(tooManyPeers),
        ])
        check(
            PeelHostSandboxPreferenceMigration.migrate(
                sourceURL: tooManyFixture.sourceURL,
                targetDefaults: tooManyFixture.defaults
            ) == .invalidSource,
            "more than 128 peers should be rejected"
        )

        let duplicateFixture = try Fixture()
        let duplicateID = UUID().uuidString
        let duplicatePeers = [
            PeelPairedPeer(id: duplicateID, displayName: "Mac A"),
            PeelPairedPeer(id: duplicateID.lowercased(), displayName: "Mac B"),
        ]
        try duplicateFixture.write([
            pairedPeersKey: try JSONEncoder().encode(duplicatePeers),
        ])
        check(
            PeelHostSandboxPreferenceMigration.migrate(
                sourceURL: duplicateFixture.sourceURL,
                targetDefaults: duplicateFixture.defaults
            ) == .invalidSource,
            "duplicate UUID IDs should be rejected case-insensitively"
        )

        let textFixture = try Fixture()
        let badName = String(repeating: "n", count: 257)
        try textFixture.write([
            pairedPeersKey: try JSONEncoder().encode([
                PeelPairedPeer(id: UUID().uuidString, displayName: badName),
            ]),
        ])
        check(
            PeelHostSandboxPreferenceMigration.migrate(
                sourceURL: textFixture.sourceURL,
                targetDefaults: textFixture.defaults
            ) == .invalidSource,
            "oversized peer names should be rejected"
        )
    }

    private static func oversizedAndSymlinkSourcesAreRejected() throws {
        let oversizedFixture = try Fixture()
        let oversizedData = Data(repeating: 0, count: 1_048_577)
        try oversizedData.write(to: oversizedFixture.sourceURL, options: .atomic)
        check(
            PeelHostSandboxPreferenceMigration.migrate(
                sourceURL: oversizedFixture.sourceURL,
                targetDefaults: oversizedFixture.defaults
            ) == .invalidSource,
            "source files above one MiB should be rejected"
        )
        check(!marker(in: oversizedFixture.defaults), "oversized source must remain retryable")

        let symlinkFixture = try Fixture()
        try FileManager.default.createSymbolicLink(
            at: symlinkFixture.sourceURL,
            withDestinationURL: symlinkFixture.root.appendingPathComponent("missing.plist")
        )
        check(
            PeelHostSandboxPreferenceMigration.migrate(
                sourceURL: symlinkFixture.sourceURL,
                targetDefaults: symlinkFixture.defaults
            ) == .invalidSource,
            "symbolic-link sources should be rejected"
        )
        check(!marker(in: symlinkFixture.defaults), "symbolic-link source must remain retryable")

        let fifoFixture = try Fixture()
        let fifoResult = fifoFixture.sourceURL.path.withCString { path in
            mkfifo(path, mode_t(0o600))
        }
        check(fifoResult == 0, "fixture FIFO should be created")
        check(
            PeelHostSandboxPreferenceMigration.migrate(
                sourceURL: fifoFixture.sourceURL,
                targetDefaults: fifoFixture.defaults
            ) == .invalidSource,
            "FIFO sources should be rejected before reading"
        )
        check(!marker(in: fifoFixture.defaults), "FIFO source must remain retryable")
    }

    private static func marker(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: PeelHostSandboxPreferenceMigration.migrationMarkerKey) as? Bool == true
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError(message)
        }
    }

    private struct Failure: Error {
        let message: String

        init(_ message: String) {
            self.message = message
        }
    }

    private final class Fixture {
        let root: URL
        let sourceURL: URL
        let defaults: UserDefaults
        private let suiteName: String

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("peel-sandbox-migration-\(UUID().uuidString)", isDirectory: true)
            sourceURL = root.appendingPathComponent("legacy.plist")
            suiteName = "peel-sandbox-migration-\(UUID().uuidString)"
            guard let suite = UserDefaults(suiteName: suiteName) else {
                throw Failure("could not create isolated defaults")
            }
            defaults = suite
            defaults.removePersistentDomain(forName: suiteName)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        deinit {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        func write(_ values: [String: Any]) throws {
            let data = try PropertyListSerialization.data(
                fromPropertyList: values,
                format: .binary,
                options: 0
            )
            try data.write(to: sourceURL, options: .atomic)
        }
    }
}
