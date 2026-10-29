import XCTest
import Darwin
@testable import PeelWatchCore

/// Records policy by real filesystem inode, so rename/restart tests do not
/// accidentally confuse path bookkeeping with retained replacement attributes.
/// This does NOT simulate Apple encryption, lock state or background runtime.
private final class RelayFixturePhoneProtection: PluginRelayPhoneFileProtection, @unchecked Sendable {
    enum Failure: Equatable { case directoryMigration, storeMigration, replacementVerification }
    private let lock = NSLock()
    private var protectedInodes = Set<String>()
    private var failure: Failure?
    private(set) var establishedPaths: [String] = []
    let directory: URL
    let store: URL

    init(store: URL) { self.store = store; directory = store.deletingLastPathComponent() }
    func failNext(_ value: Failure) { lock.lock(); defer { lock.unlock() }; failure = value }
    private func inode(_ url: URL) throws -> String {
        var value = stat()
        guard url.path.withCString({ Darwin.lstat($0, &value) }) == 0 else { throw PluginRelayError.storageFailure }
        return "\(value.st_dev):\(value.st_ino)"
    }
    func establish(at url: URL) throws {
        let key = try inode(url)
        lock.lock(); defer { lock.unlock() }
        if (url == directory && failure == .directoryMigration) || (url == store && failure == .storeMigration) {
            failure = nil; throw PluginRelayError.storageFailure
        }
        protectedInodes.insert(key)
        guard protectedInodes.contains(key) else { throw PluginRelayError.storageFailure }
        establishedPaths.append(url.path)
    }
    func verify(at url: URL) throws {
        let key = try inode(url)
        lock.lock(); defer { lock.unlock() }
        if url.lastPathComponent.hasPrefix(".relay-"), failure == .replacementVerification {
            failure = nil; throw PluginRelayError.storageFailure
        }
        guard protectedInodes.contains(key) else { throw PluginRelayError.storageFailure }
    }
}

final class PluginRelayFilePersistenceTests: XCTestCase {
    private func location() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PeelRelay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("dedicated-relay/state.json")
    }
    private func seed(_ data: Data, at file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }
    private func fence() throws -> PluginRelayFence {
        let route = try PluginRelayReference(provider: .dot, routeID: "route_file_fixture", generation: UUID(), accountGeneration: UUID())
        return PluginRelayFence(binding: PluginRelayBinding(route: route, pairingEpoch: UUID()), localEpoch: UUID())
    }
    private func expectStorageFailure(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual($0 as? PluginRelayError, .storageFailure, file: file, line: line)
        }
    }

    func testOnlyMissingLeafOrParentReturnsNil() throws {
        let file = try location(), persistence = try PluginRelayFilePersistence(fileURL: file)
        XCTAssertNil(try persistence.read(maximumBytes: 32))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: false)
        XCTAssertNil(try persistence.read(maximumBytes: 32))
        try seed(Data(), at: file)
        XCTAssertEqual(try persistence.read(maximumBytes: 32), Data()) // Empty is not absent.
        expectStorageFailure { _ = try persistence.read(maximumBytes: 0) }
    }

    func testBadParentAndDirectoryFailRatherThanCreateFreshStore() throws {
        let file = try location()
        try Data("not a directory".utf8).write(to: file.deletingLastPathComponent())
        expectStorageFailure { _ = try PluginRelayFilePersistence(fileURL: file).read(maximumBytes: 32) }
        try FileManager.default.removeItem(at: file.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        expectStorageFailure { _ = try PluginRelayFilePersistence(fileURL: file).read(maximumBytes: 32) }
    }

    func testSymlinkAndDanglingSymlinkAreRejected() throws {
        let file = try location(), target = file.deletingLastPathComponent().appendingPathComponent("other.json")
        try seed(Data("retained".utf8), at: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        expectStorageFailure { _ = try PluginRelayFilePersistence(fileURL: file).read(maximumBytes: 32) }
        try FileManager.default.removeItem(at: target)
        expectStorageFailure { _ = try PluginRelayFilePersistence(fileURL: file).read(maximumBytes: 32) }
    }

    func testFIFONeverWaitsForAWriter() throws {
        let file = try location()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertEqual(file.path.withCString { Darwin.mkfifo($0, 0o600) }, 0)
        let start = ProcessInfo.processInfo.systemUptime
        expectStorageFailure { _ = try PluginRelayFilePersistence(fileURL: file).read(maximumBytes: 32) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
    }

    func testExactReadCapSucceedsAndCapPlusOneFailsWithoutMutation() throws {
        let file = try location(), data = Data(repeating: 31, count: 65_537)
        try seed(data, at: file)
        let persistence = try PluginRelayFilePersistence(fileURL: file)
        XCTAssertEqual(try persistence.read(maximumBytes: data.count), data)
        XCTAssertThrowsError(try persistence.read(maximumBytes: data.count - 1)) {
            XCTAssertEqual($0 as? PluginRelayError, .capacity)
        }
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func testUnreadableExistingStoreIsNotAbsentOrMigrated() throws {
        guard Darwin.geteuid() != 0 else { throw XCTSkip("Permission denial requires a non-root process") }
        let file = try location(), data = Data("retained inaccessible bytes".utf8)
        try seed(data, at: file)
        let policy = RelayFixturePhoneProtection(store: file)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        expectStorageFailure { _ = try PluginRelayFilePersistence(fileURL: file).read(maximumBytes: 1_024) }
        expectStorageFailure { _ = try PluginRelayFilePersistence(fileURL: file, phoneRelayProtection: policy) }
        XCTAssertTrue(policy.establishedPaths.isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func testInaccessibleParentIsNotMissingAndCannotInitializeEmptyPhoneStore() throws {
        guard Darwin.geteuid() != 0 else { throw XCTSkip("Permission denial requires a non-root process") }
        let file = try location(), data = Data("retain behind inaccessible directory".utf8)
        try seed(data, at: file)
        let parent = file.deletingLastPathComponent(), policy = RelayFixturePhoneProtection(store: file)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
        expectStorageFailure { _ = try PluginRelayFilePersistence(fileURL: file).read(maximumBytes: 1_024) }
        expectStorageFailure { _ = try PluginRelayFilePersistence(fileURL: file, phoneRelayProtection: policy) }
        XCTAssertTrue(policy.establishedPaths.isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func testNewPhoneSpoolStartsOnlyAfterVerifiedAbsenceAndRestoresFirstCommit() throws {
        let file = try location(), policy = RelayFixturePhoneProtection(store: file)
        let persistence = try PluginRelayFilePersistence(fileURL: file, phoneRelayProtection: policy)
        XCTAssertNil(try persistence.read(maximumBytes: 1_024))
        let bytes = Data("first committed message bytes".utf8)
        try persistence.writeAtomically(bytes)
        try policy.verify(at: file.deletingLastPathComponent())
        try policy.verify(at: file)
        let restored = try PluginRelayFilePersistence(fileURL: file, phoneRelayProtection: policy)
        XCTAssertEqual(try restored.read(maximumBytes: 1_024), bytes)
    }

    func testMigrationPreservesBytesAndAtomicReplacementCarriesVerifiedInode() throws {
        let file = try location(), first = Data([0, 255, 13, 10, 34]), second = Data("replacement".utf8)
        try seed(first, at: file)
        let before = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber)
        let policy = RelayFixturePhoneProtection(store: file)
        let persistence = try PluginRelayFilePersistence(fileURL: file, phoneRelayProtection: policy)
        XCTAssertEqual(try persistence.read(maximumBytes: 1_024), first)
        XCTAssertEqual(try Data(contentsOf: file), first)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber, before)
        try persistence.writeAtomically(second)
        try policy.verify(at: file) // Same verified temp inode is now the committed store.
        XCTAssertNotEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber, before)
        let restored = try PluginRelayFilePersistence(fileURL: file, phoneRelayProtection: policy)
        XCTAssertEqual(try restored.read(maximumBytes: 1_024), second)
        XCTAssertTrue(policy.establishedPaths.contains(file.deletingLastPathComponent().path))
        XCTAssertTrue(policy.establishedPaths.contains(file.path))
        XCTAssertTrue(policy.establishedPaths.contains { URL(fileURLWithPath: $0).lastPathComponent.hasPrefix(".relay-") })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path), ["state.json"])
    }

    func testFailedMigrationRetainsExactBytesAndDoesNotReturnAStore() throws {
        for failure in [RelayFixturePhoneProtection.Failure.directoryMigration, .storeMigration] {
            let file = try location(), data = Data("{\"retained\":true}".utf8)
            try seed(data, at: file)
            let policy = RelayFixturePhoneProtection(store: file); policy.failNext(failure)
            expectStorageFailure { _ = try PluginRelayFilePersistence(fileURL: file, phoneRelayProtection: policy) }
            XCTAssertEqual(try Data(contentsOf: file), data)
            XCTAssertEqual(try PluginRelayFilePersistence(fileURL: file).read(maximumBytes: 1_024), data)
        }
    }

    func testPhoneMigrationRejectsSymlinkDirectoryWithoutChangingTarget() throws {
        let file = try location(), target = file.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("separate")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let targetFile = target.appendingPathComponent(file.lastPathComponent), bytes = Data("retain elsewhere".utf8)
        try bytes.write(to: targetFile)
        try FileManager.default.createSymbolicLink(at: file.deletingLastPathComponent(), withDestinationURL: target)
        let policy = RelayFixturePhoneProtection(store: file)
        expectStorageFailure { _ = try PluginRelayFilePersistence(fileURL: file, phoneRelayProtection: policy) }
        XCTAssertTrue(policy.establishedPaths.isEmpty)
        XCTAssertEqual(try Data(contentsOf: targetFile), bytes)
    }

    func testFailedReplacementPreservesSnapshotCursorIDsAndRestart() async throws {
        let file = try location(), current = try fence()
        let request = try PluginRelayMessage(messageID: UUID(), text: "retain this stable send")
        let reply = try PluginRelayReply(requestID: request.messageID, replyID: "file_reply", text: "actual response")
        let original = try PluginRelayPhoneStore(persistence: PluginRelayFilePersistence(fileURL: file), fence: current, limits: .init())
        try await original.reserve(request, using: current, permit: try syntheticPaidPermit(for: current))
        try await original.markUncertain(request.messageID, using: current, permit: try syntheticPaidPermit(for: current))
        try await original.ingest(.init(route: current.binding.route, replies: [reply], cursor: 71), after: 0, using: current, permit: try syntheticPaidPermit(for: current))
        let bytesBeforeMigration = try Data(contentsOf: file)
        let policy = RelayFixturePhoneProtection(store: file)
        let persistence = try PluginRelayFilePersistence(fileURL: file, phoneRelayProtection: policy)
        XCTAssertEqual(try Data(contentsOf: file), bytesBeforeMigration)
        let migrated = try PluginRelayPhoneStore(persistence: persistence, fence: current, limits: .init())
        let cursor = try await migrated.cursor(using: current, permit: try syntheticPaidPermit(for: current))
        let reservation = try await migrated.sendRecord(request.messageID, using: current, permit: try syntheticPaidPermit(for: current))
        XCTAssertEqual(cursor, 71); XCTAssertEqual(reservation?.message, request); XCTAssertEqual(reservation?.state, .uncertain)
        let next = try PluginRelayMessage(messageID: UUID(), text: "new send must fail to commit")
        policy.failNext(.replacementVerification)
        do { try await migrated.reserve(next, using: current, permit: try syntheticPaidPermit(for: current)); XCTFail("Expected failed replacement") }
        catch { XCTAssertEqual(error as? PluginRelayError, .storageFailure) }
        XCTAssertEqual(try Data(contentsOf: file), bytesBeforeMigration)
        let failedRecord = try await migrated.sendRecord(next.messageID, using: current, permit: try syntheticPaidPermit(for: current))
        let failedCursor = try await migrated.cursor(using: current, permit: try syntheticPaidPermit(for: current))
        XCTAssertNil(failedRecord); XCTAssertEqual(failedCursor, 71)
        let restoredFence = PluginRelayFence(binding: current.binding, localEpoch: UUID())
        let restored = try PluginRelayPhoneStore(persistence: persistence, fence: restoredFence, limits: .init())
        let restoredCursor = try await restored.cursor(using: restoredFence, permit: try syntheticPaidPermit(for: restoredFence))
        let restoredReplies = try await restored.pendingReplies(using: restoredFence, permit: try syntheticPaidPermit(for: restoredFence))
        let restoredRecord = try await restored.sendRecord(request.messageID, using: restoredFence, permit: try syntheticPaidPermit(for: restoredFence))
        XCTAssertEqual(restoredCursor, 71); XCTAssertEqual(restoredReplies, [reply]); XCTAssertEqual(restoredRecord?.message, request)
    }

    func testCorruptReadableFileCannotBecomeEmptyStore() throws {
        let file = try location(), bytes = Data("{malformed snapshot".utf8)
        try seed(bytes, at: file)
        let policy = RelayFixturePhoneProtection(store: file)
        let persistence = try PluginRelayFilePersistence(fileURL: file, phoneRelayProtection: policy)
        expectStorageFailure { _ = try PluginRelayPhoneStore(persistence: persistence, fence: fence(), limits: .init()) }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    #if os(iOS)
    func testPhoneFactoryEstablishesActualProtectionAttributesWithoutClaimingLockProof() throws {
        let file = try location(), bytes = Data("preserve".utf8)
        try seed(bytes, at: file)
        let persistence = try PluginRelayFilePersistence.phoneRelayAfterFirstUnlock(fileURL: file)
        let actualPolicy = PluginRelayIOSPhoneFileProtection()
        try actualPolicy.verify(at: file.deletingLastPathComponent())
        try actualPolicy.verify(at: file)
        XCTAssertEqual(try persistence.read(maximumBytes: 1_024), bytes)
        try persistence.writeAtomically(Data("new".utf8))
        try actualPolicy.verify(at: file)
        // Device locked/background/BFU acceptance is a separate physical recipe.
    }
    #endif
}
