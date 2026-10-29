#if !os(watchOS)
import XCTest
@testable import PeelWatchCore

private actor BrokerGateCancellationFixture {
    private var entered = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var releaseGate: CheckedContinuation<Void, Never>?
    func cancel() async {
        entered = true; arrival?.resume(); arrival = nil
        await withCheckedContinuation { releaseGate = $0 }
    }
    func waitForEntry() async { if !entered { await withCheckedContinuation { arrival = $0 } } }
    func finish() { releaseGate?.resume(); releaseGate = nil }
}
final class PluginRelayNativeBrokerOperationGateTests: XCTestCase {
    func testOtherProviderBusyIsRejectedBeforeRefreshCheckpointMutation() throws {
        let gate = PluginRelayNativeBrokerOperationGate(), dot = try gate.begin(.dot)
        var checkpoints = 0
        func beginRotation(_ provider: CloudAgentProvider) throws -> PluginRelayNativeBrokerOperationGate.Operation {
            let lease = try gate.begin(provider)
            checkpoints += 1 // Production controller is entered only after admission.
            return lease
        }
        XCTAssertThrowsError(try beginRotation(.grokBot)) { XCTAssertEqual($0 as? PluginRelayNativeBrokerGateError, .busy) }
        XCTAssertEqual(checkpoints, 0); try gate.validate(dot)
        gate.finish(dot)
        let grok = try beginRotation(.grokBot); XCTAssertEqual(checkpoints, 1); gate.finish(grok)
    }
    func testCancellationNeverTargetsOtherProviderOperation() throws {
        let gate = PluginRelayNativeBrokerOperationGate(), dot = try gate.begin(.dot)
        XCTAssertNil(gate.beginCancellation(.grokBot)); try gate.validate(dot)
        let own = try XCTUnwrap(gate.beginCancellation(.dot))
        XCTAssertThrowsError(try gate.validate(dot)) { XCTAssertEqual($0 as? PluginRelayNativeBrokerGateError, .cancelled) }
        gate.finishCancellation(own); XCTAssertThrowsError(try gate.validate(dot))
        gate.finish(dot); let grok = try gate.begin(.grokBot); try gate.validate(grok)
    }
    func testHeldCancellationBlocksReplacementEvenWhenOldOperationReturns() async throws {
        let gate = PluginRelayNativeBrokerOperationGate(), broker = BrokerGateCancellationFixture()
        let dot = try gate.begin(.dot), cancellation = try XCTUnwrap(gate.beginCancellation(.dot))
        let cancelling = Task {
            await broker.cancel()
            gate.finishCancellation(cancellation)
        }
        await broker.waitForEntry()
        // The old operation can return before its queued actor cancellation.
        gate.finish(dot)
        XCTAssertThrowsError(try gate.begin(.grokBot)) { XCTAssertEqual($0 as? PluginRelayNativeBrokerGateError, .busy) }
        XCTAssertNil(gate.beginCancellation(.grokBot))
        await broker.finish(); await cancelling.value
        let grok = try gate.begin(.grokBot); try gate.validate(grok); gate.finish(grok)
    }
    func testEveryConcurrentCancellationLeaseMustDrainBeforeReplacement() throws {
        let gate = PluginRelayNativeBrokerOperationGate(), dot = try gate.begin(.dot)
        let first = try XCTUnwrap(gate.beginCancellation(.dot)), second = try XCTUnwrap(gate.beginCancellation(.dot))
        gate.finish(dot); gate.finishCancellation(first)
        XCTAssertThrowsError(try gate.begin(.grokBot))
        gate.finishCancellation(first) // Duplicate finish cannot consume another lease.
        XCTAssertThrowsError(try gate.begin(.grokBot))
        gate.finishCancellation(second)
        let grok = try gate.begin(.grokBot); gate.finish(grok)
    }
    func testStaleOperationCompletionCannotReleaseLaterOtherProvider() throws {
        let gate = PluginRelayNativeBrokerOperationGate(), dot = try gate.begin(.dot)
        gate.finish(dot); let grok = try gate.begin(.grokBot)
        gate.finish(dot); try gate.validate(grok)
        XCTAssertThrowsError(try gate.begin(.dot))
        gate.finish(grok)
    }
}
#endif
