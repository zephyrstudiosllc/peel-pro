import XCTest
@testable import PeelWatchCore

private final class ProviderRouteDisk: PluginRelayPersistence, @unchecked Sendable {
    private let lock = NSLock(); private var data: Data?
    func read(maximumBytes: Int) throws -> Data? { lock.lock(); defer { lock.unlock() }; return data }
    func writeAtomically(_ data: Data) throws { lock.lock(); defer { lock.unlock() }; self.data = data }
}
private struct ProviderRouteAuthority: PluginRelayWatchAuthority {
    let fence: PluginRelayFence
    func validateCurrent(_ fence: PluginRelayFence) throws { if self.fence != fence { throw PluginRelayEnrollmentError.wrongPeer } }
}
private actor ProviderRouteTransport: PluginRelayWatchTransport {
    let fence: PluginRelayFence
    var message: PluginRelayMessage?
    private var holding = false
    private var releaseGate: CheckedContinuation<Void, Never>?
    private var entered = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var cancelled = false
    private var cancelArrivals: [CheckedContinuation<Void, Never>] = []
    func holdSend() { holding = true }
    func waitForSend() async { if !entered { await withCheckedContinuation { arrivals.append($0) } } }
    func waitForCancellation() async { if !cancelled { await withCheckedContinuation { cancelArrivals.append($0) } } }
    func releaseSend() { holding = false; releaseGate?.resume(); releaseGate = nil }
    init(_ fence: PluginRelayFence) { self.fence = fence }
    func exchange(_ data: Data, courierID: UUID) async throws -> Data {
        let request = try PluginRelayV2Envelope.decode(data, expectedFence: fence, expectedCourierID: courierID)
        switch request.kind {
        case .status:
            let dot = fence.binding.route.provider == .dot
            return try PluginRelayV2Envelope(courierID: courierID, fence: fence, kind: .statusReport,
                statusReport: .init(state: dot ? .connected : .manualReady, remoteReady: true, deliveryMode: dot ? .events : .manual,
                    automaticDeliveryReady: dot, minimumRoutineIntervalSeconds: dot ? nil : 300, nextReply: nil)).encoded()
        case .send:
            message = request.message
            entered = true; arrivals.forEach { $0.resume() }; arrivals.removeAll()
            if holding { await withCheckedContinuation { releaseGate = $0 } }
            return try PluginRelayV2Envelope(courierID: courierID, fence: fence, kind: .receipt,
                receipt: .init(requestID: request.message!.messageID, route: fence.binding.route, receiptID: "receipt_provider_test", state: .accepted, agentReplyReceived: false)).encoded()
        case .replyRefresh:
            let reply = try PluginRelayReply(requestID: message!.messageID, replyID: "reply_provider_test", text: "saved reply")
            return try PluginRelayV2Envelope(courierID: courierID, fence: fence, kind: .chunk,
                chunk: PluginRelayChunk.split(reply, route: fence.binding.route)[0]).encoded()
        case .acknowledge: return data
        default: throw PluginRelayWatchCoordinatorError.invalidResponse
        }
    }
    func cancel(courierID: UUID) async {
        cancelled = true; cancelArrivals.forEach { $0.resume() }; cancelArrivals.removeAll()
    }
}
final class PluginRelayWatchProviderRoutesTests: XCTestCase {
    private func entry(_ provider: CloudAgentProvider) throws -> (PluginRelayWatchProviderRoutes.Entry, ProviderRouteDisk) {
        let route = try PluginRelayReference(provider: provider, routeID: "route_provider_test", generation: UUID(), accountGeneration: UUID())
        let fence = PluginRelayFence(binding: .init(route: route, pairingEpoch: UUID()), localEpoch: UUID())
        let disk = ProviderRouteDisk(), store = try PluginRelayWatchStore(persistence: disk, fence: fence)
        let slot = try PluginRelayWatchAuthoritySlot(fence: fence, authority: ProviderRouteAuthority(fence: fence))
        let coordinator = try PluginRelayWatchCoordinator(fence: fence, store: store, transport: ProviderRouteTransport(fence), authority: slot)
        return (.init(fence: fence, coordinator: coordinator, authority: slot), disk)
    }
    func testDotGrokDotKeepsSameCoordinatorRequestReplyAndStoreEpoch() async throws {
        let routes = PluginRelayWatchProviderRoutes(), (dot, disk) = try entry(.dot), (grok, _) = try entry(.grokBot)
        try await routes.install(dot); try await routes.install(grok)
        let first = try await routes.select(.dot)
        _ = try await dot.coordinator.status()
        let message = try PluginRelayMessage(messageID: UUID(), text: "retained Dot request")
        _ = try await dot.coordinator.send(message); let saved = try await dot.coordinator.refreshReply()
        _ = try await routes.select(.grokBot); _ = try await grok.coordinator.status()
        let returned = try await routes.select(.dot)
        XCTAssertTrue(returned.1?.coordinator === dot.coordinator)
        let oldIsCurrent = await routes.isCurrent(first.0); XCTAssertFalse(oldIsCurrent)
        let snapshot = try await dot.coordinator.snapshot()
        XCTAssertEqual(snapshot.outgoing, saved.outgoing); XCTAssertEqual(snapshot.replies, saved.replies)
        XCTAssertEqual(snapshot.outgoing.first?.message.messageID, message.messageID)
        let restored = try PluginRelayWatchStore(persistence: disk, fence: dot.fence)
        let outgoing = try await restored.outgoingMessages(using: dot.fence); XCTAssertEqual(outgoing, saved.outgoing)
    }
    func testOnlyActualProviderReplacementTerminalizesOldFenceAndLeavesOtherAgent() async throws {
        let routes = PluginRelayWatchProviderRoutes(), (old, _) = try entry(.dot), (grok, _) = try entry(.grokBot), (next, _) = try entry(.dot)
        try await routes.install(old); try await routes.install(grok); try await routes.install(next)
        XCTAssertThrowsError(try old.authority.validateCurrent(old.fence))
        do { _ = try await old.coordinator.snapshot(); XCTFail("Old coordinator must be terminal") } catch {}
        let remaining = await routes.entry(for: .grokBot)
        XCTAssertTrue(remaining?.coordinator === grok.coordinator); try grok.authority.validateCurrent(grok.fence)
        try await routes.invalidate(.dot); try grok.authority.validateCurrent(grok.fence)
    }
    func testPairReplacementClosesGrokBeforeHeldDotDrainFinishes() async throws {
        let routes = PluginRelayWatchProviderRoutes(), (dot, _) = try entry(.dot), (grok, _) = try entry(.grokBot)
        // A controlled transport lets Dot's old in-flight send finish late.
        let disk = ProviderRouteDisk(), store = try PluginRelayWatchStore(persistence: disk, fence: dot.fence)
        let transport = ProviderRouteTransport(dot.fence)
        let client = try PluginRelayWatchCoordinator(fence: dot.fence, store: store, transport: transport, authority: dot.authority)
        let heldDot = PluginRelayWatchProviderRoutes.Entry(fence: dot.fence, coordinator: client, authority: dot.authority)
        try await routes.install(heldDot); try await routes.install(grok)
        _ = try await client.status(); await transport.holdSend()
        let message = try PluginRelayMessage(messageID: UUID(), text: "old phone request")
        let sending = Task { try await client.send(message) }
        await transport.waitForSend()
        let closing = Task { try await routes.invalidateAll() }
        await transport.waitForCancellation()
        // Dot is still suspended; Grok must already reject old peer admission.
        XCTAssertThrowsError(try grok.authority.validateCurrent(grok.fence))
        do { _ = try await grok.coordinator.status(); XCTFail("Grok survived pair replacement") } catch {}
        await transport.releaseSend()
        do { _ = try await sending.value; XCTFail("Late Dot response survived pair replacement") } catch {}
        try await closing.value
        let missing = await routes.entry(for: .grokBot); XCTAssertNil(missing)
    }
    func testSameFenceLeaseReplacementPreservesCoordinatorAndOldUISelectionIsRejected() async throws {
        let routes = PluginRelayWatchProviderRoutes(), (installed, _) = try entry(.dot)
        try await routes.install(installed); let selected = try await routes.select(.dot)
        try installed.authority.replaceVerifiedAuthority(ProviderRouteAuthority(fence: installed.fence))
        try await routes.install(installed)
        let same = await routes.entry(for: .dot); XCTAssertTrue(same?.coordinator === installed.coordinator)
        _ = try await routes.select(.dot)
        let stale = await routes.isCurrent(selected.0); XCTAssertFalse(stale)
        try installed.authority.validateCurrent(installed.fence)
    }
}
