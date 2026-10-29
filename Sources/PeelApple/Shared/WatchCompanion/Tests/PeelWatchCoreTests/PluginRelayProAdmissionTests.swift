import XCTest
@testable import PeelWatchCore

private final class ProTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var wallValue: TimeInterval = 1_800_000_000
    private var monoValue: TimeInterval = 100
    var wall: Date { lock.lock(); defer { lock.unlock() }; return Date(timeIntervalSince1970: wallValue) }
    var mono: TimeInterval { lock.lock(); defer { lock.unlock() }; return monoValue }
    func advance(wall: TimeInterval = 0, mono: TimeInterval = 0) { lock.lock(); defer { lock.unlock() }; wallValue += wall; monoValue += mono }
}
private final class ProTestDisk: PluginRelayPersistence, @unchecked Sendable {
    private let lock = NSLock(); private var data: Data?
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    var hold = false
    func read(maximumBytes: Int) throws -> Data? { lock.lock(); defer { lock.unlock() }; return data }
    func writeAtomically(_ value: Data) throws {
        lock.lock(); let block = hold; hold = false; lock.unlock()
        if block { entered.signal(); release.wait() }
        lock.lock(); data = value; lock.unlock()
    }
}
private final class ProTestFlag: @unchecked Sendable {
    private let lock = NSLock(); private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
final class PluginRelayProAdmissionTests: XCTestCase {
    private func fence() throws -> PluginRelayFence {
        .init(binding: .init(route: try .init(provider: .dot, routeID: "route_pro_fixture", generation: UUID(), accountGeneration: UUID()), pairingEpoch: UUID()), localEpoch: UUID())
    }
    private func fixture() throws -> (ProTestClock, PluginRelayProRegistry, PluginRelayProBinding, PluginRelayFence) {
        let clock = ProTestClock(), f = try fence()
        return (clock, PluginRelayProRegistry(now: { clock.wall }, uptime: { clock.mono }),
                syntheticProBinding(for: f, expiry: 1_800_001_000), f)
    }
    private func grant(_ registry: PluginRelayProRegistry, _ binding: PluginRelayProBinding,
                       at: Int64 = 1_800_000_000, duration: Int64 = 300, id: UUID = UUID()) throws {
        let operation = try registry.begin()
        try registry.install(.init(leaseID: id, verifiedAt: at, expiresAt: at + duration, binding: binding, verified: true), operation: operation)
    }
    func testMetadataAndFreshRegistryNeverGrantPaidAuthority() throws {
        let (_, registry, binding, _) = try fixture()
        XCTAssertThrowsError(try registry.permit(binding: binding)) { XCTAssertEqual($0 as? PluginRelayProError, .required) }
        XCTAssertFalse(registry.hasLease(binding: binding, minimumRemaining: 0))
        let operation = try registry.begin()
        XCTAssertThrowsError(try registry.permit(binding: binding))
        registry.finish(operation)
    }
    func testContinuousRenewalKeepsCapturedPermitWithoutExtendingItsDeadline() throws {
        let (clock, registry, binding, f) = try fixture(); try grant(registry, binding)
        let held = try registry.permit(binding: binding)
        clock.advance(wall: 10, mono: 10)
        try grant(registry, binding, at: 1_800_000_010)
        try held.validate(for: f)
        clock.advance(wall: 11, mono: 11)
        XCTAssertThrowsError(try held.validate(for: f)) { XCTAssertEqual($0 as? PluginRelayProError, .expired) }
        try registry.permit(binding: binding).validate(for: f)
    }
    func testActualExpiryThenNewProofCannotReviveOldPermitAfterClockRollback() throws {
        let (clock, registry, binding, f) = try fixture(); try grant(registry, binding, duration: 5)
        let old = try registry.permit(binding: binding)
        clock.advance(mono: 6)
        XCTAssertThrowsError(try old.validate(for: f))
        clock.advance(mono: -6)
        try grant(registry, binding)
        XCTAssertThrowsError(try old.validate(for: f)) { XCTAssertEqual($0 as? PluginRelayProError, .superseded) }
        try registry.permit(binding: binding).validate(for: f)
    }
    func testWithdrawAndDenialPermanentlyRetireCapturedOutputs() throws {
        let (_, registry, binding, _) = try fixture(); try grant(registry, binding)
        let old = try registry.permit(binding: binding), bytes = Data("reply".utf8)
        let output = PluginRelayPhoneOutput(bytes: bytes, permit: old)
        registry.withdraw(); try grant(registry, binding)
        var delivered = false
        XCTAssertThrowsError(try output.submit { _ in delivered = true }); XCTAssertFalse(delivered)
        let current = try registry.permit(binding: binding), pending = try registry.begin()
        XCTAssertThrowsError(try registry.install(.init(leaseID: nil, verifiedAt: 1_800_000_000, expiresAt: 1_800_000_000, binding: binding, verified: false), operation: pending))
        XCTAssertThrowsError(try current.withAdmission {})
        try grant(registry, binding); XCTAssertThrowsError(try old.withAdmission {})
    }
    func testUnavailableProofDoesNotExtendOrRevokeExistingFiniteLease() throws {
        let (clock, registry, binding, f) = try fixture(); try grant(registry, binding, duration: 10)
        let held = try registry.permit(binding: binding), pending = try registry.begin()
        registry.finish(pending) // transport/commerce failure installs nothing
        try held.validate(for: f); clock.advance(mono: 11)
        XCTAssertThrowsError(try held.validate(for: f)); XCTAssertFalse(registry.hasLease(binding: binding, minimumRemaining: 0))
    }
    func testInitialLeaseBindsOnlyExactAuthenticatedRouteWithoutExtension() throws {
        let (clock, registry, _, f) = try fixture(), initial = syntheticProBinding(for: f, routed: false, expiry: 1_800_001_000)
        try grant(registry, initial, duration: 10)
        let wrong = PluginRelayFence(binding: f.binding, localEpoch: UUID())
        XCTAssertThrowsError(try registry.bind(wrong))
        clock.advance(wall: 8, mono: 8); try registry.bind(f)
        let bound = try initial.adding(f), permit = try registry.permit(binding: bound)
        clock.advance(mono: 3); XCTAssertThrowsError(try permit.validate(for: f))
    }
    func testDifferentProviderAccountRoutePairAndLocalEpochCannotUsePermit() throws {
        let (_, registry, binding, f) = try fixture(); try grant(registry, binding)
        let paid = try registry.permit(binding: binding)
        let alternatives = [
            PluginRelayFence(binding: f.binding, localEpoch: UUID()),
            PluginRelayFence(binding: .init(route: f.binding.route, pairingEpoch: UUID()), localEpoch: f.localEpoch),
            PluginRelayFence(binding: .init(route: try .init(provider: .grokBot, routeID: f.binding.route.routeID, generation: f.binding.route.generation, accountGeneration: f.binding.route.accountGeneration), pairingEpoch: f.binding.pairingEpoch), localEpoch: f.localEpoch),
            PluginRelayFence(binding: .init(route: try .init(provider: .dot, routeID: "route_different", generation: UUID(), accountGeneration: UUID()), pairingEpoch: f.binding.pairingEpoch), localEpoch: f.localEpoch)]
        for other in alternatives { XCTAssertThrowsError(try paid.validate(for: other)) }
    }
    func testWithdrawalRevisionClosesPendingAndMustBeAcknowledgedBeforeNewEvidence() throws {
        let (_, registry, binding, _) = try fixture(); try grant(registry, binding)
        let pending = try registry.begin(), revision = try XCTUnwrap(registry.withdraw(needsRemoteAcknowledgement: true))
        XCTAssertThrowsError(try registry.withPendingSubmission(pending) { XCTFail("evidence dispatched") })
        XCTAssertThrowsError(try registry.begin())
        XCTAssertThrowsError(try registry.acknowledgeWithdrawal(UUID()))
        try registry.withWithdrawalSubmission(revision) {}
        try registry.acknowledgeWithdrawal(revision); try grant(registry, binding)
        XCTAssertThrowsError(try registry.withWithdrawalSubmission(revision) { XCTFail("stale delayed withdraw dispatched") })
        XCTAssertTrue(registry.hasLease(binding: binding, minimumRemaining: 0))
    }
    func testNewerWithdrawalCannotBeAcknowledgedByOlderDeferredFlush() throws {
        let (_, registry, _, _) = try fixture()
        let first = try XCTUnwrap(registry.withdraw(needsRemoteAcknowledgement: true))
        let second = try XCTUnwrap(registry.withdraw(needsRemoteAcknowledgement: true))
        XCTAssertThrowsError(try registry.acknowledgeWithdrawal(first))
        XCTAssertThrowsError(try registry.withWithdrawalSubmission(first) { XCTFail("old withdrawal dispatched") })
        XCTAssertEqual(registry.pendingWithdrawal(), second); XCTAssertThrowsError(try registry.begin())
        try registry.acknowledgeWithdrawal(second); _ = try registry.begin()
    }
    func testPositiveClockSkewKeepsLocalLifetimeBounded() throws {
        let (clock, registry, binding, _) = try fixture()
        try grant(registry, binding, at: 1_800_000_001, duration: 300)
        XCTAssertTrue(registry.hasLease(binding: binding, minimumRemaining: 299))
        clock.advance(mono: 301)
        XCTAssertThrowsError(try registry.permit(binding: binding))
    }
    func testStoreWithdrawalBarrierIncludesActualAtomicCommitAndKeepsLogicalIDs() async throws {
        let (_, registry, binding, f) = try fixture(); try grant(registry, binding)
        let paid = try registry.permit(binding: binding), disk = ProTestDisk()
        let store = try PluginRelayPhoneStore(persistence: disk, fence: f, limits: .init())
        let message = try PluginRelayMessage(messageID: UUID(), text: "durable logical id")
        disk.hold = true
        let commit = Task { try await store.reserve(message, using: f, permit: paid) }
        await Task.detached { disk.entered.wait() }.value
        let started = expectation(description: "withdraw started"), finished = expectation(description: "withdraw finished"), flag = ProTestFlag()
        DispatchQueue.global().async { started.fulfill(); registry.withdraw(); flag.set(); finished.fulfill() }
        await fulfillment(of: [started], timeout: 1); XCTAssertFalse(flag.value)
        disk.release.signal(); _ = try await commit.value
        await fulfillment(of: [finished], timeout: 1)
        do { _ = try await store.sendRecord(message.messageID, using: f, permit: paid); XCTFail("old authority read") } catch {}
        try grant(registry, binding)
        let fresh = try registry.permit(binding: binding)
        let retained = try await store.sendRecord(message.messageID, using: f, permit: fresh)
        XCTAssertEqual(retained?.message, message)
        let restored = try PluginRelayPhoneStore(persistence: disk, fence: f, limits: .init())
        let record = try await restored.sendRecord(message.messageID, using: f, permit: fresh)
        XCTAssertEqual(record?.message, message)
    }
    func testWithdrawalAfterCompletedStoreCommitBlocksNextMutationAndRead() async throws {
        let (_, registry, binding, f) = try fixture(); try grant(registry, binding)
        let paid = try registry.permit(binding: binding), disk = ProTestDisk()
        let store = try PluginRelayPhoneStore(persistence: disk, fence: f, limits: .init()), message = try PluginRelayMessage(messageID: UUID(), text: "keep")
        try await store.reserve(message, using: f, permit: paid)
        let reply = try PluginRelayReply(requestID: message.messageID, replyID: "stable_reply", text: "retain response")
        try await store.ingest(.init(route: f.binding.route, replies: [reply], cursor: 77), after: 0, using: f, permit: paid)
        registry.withdraw()
        do { try await store.markUncertain(message.messageID, using: f, permit: paid); XCTFail("mutation admitted") } catch {}
        do { _ = try await store.pendingReplies(using: f, permit: paid); XCTFail("read admitted") } catch {}
        try grant(registry, binding)
        let record = try await store.sendRecord(message.messageID, using: f, permit: registry.permit(binding: binding))
        XCTAssertEqual(record?.state, .reserved)
        let fresh = try registry.permit(binding: binding)
        let cursor = try await store.cursor(using: f, permit: fresh), replies = try await store.pendingReplies(using: f, permit: fresh)
        XCTAssertEqual(cursor, 77); XCTAssertEqual(replies, [reply])
    }
    func testCleanupOutputDoesNotNeedPaidAuthority() throws {
        var received = Data()
        try PluginRelayPhoneOutput(bytes: Data("stopped".utf8), permit: nil).submit { received = $0 }
        XCTAssertEqual(received, Data("stopped".utf8))
    }
}
