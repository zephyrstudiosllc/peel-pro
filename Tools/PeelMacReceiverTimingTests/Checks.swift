import Foundation

nonisolated final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 100
    func now() -> Double { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Double) { lock.lock(); defer { lock.unlock() }; self.value = value }
}

@main struct Checks {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1; precondition(condition(), message)
        }
        let clock = TestClock()
        let store = PeelRemoteMacStreamingDiagnostics(uptime: clock.now)
        func row() -> PeelClientStreamMetric? {
            store.snapshot(windowId: 7, queuedFrames: 0, queuedBytes: 0, oldestQueuedAgeMilliseconds: nil,
                displayLayerStatus: 1, displayLayerRequiresFlush: false, displayLayerErrorCode: nil)
        }
        func av(_ total: Int64, dropped: Int64 = 0, corrupted: Int64 = 0, delay: Double = 0) -> PeelRemoteMacStreamingDiagnostics.AVSample {
            .init(total: total, dropped: dropped, corrupted: corrupted, optimized: 0, accumulatedDelay: delay)
        }
        func collect(_ sample: PeelRemoteMacStreamingDiagnostics.AVSample?) {
            store.completePerformanceCollection(requestToken: store.beginPerformanceCollection()!, sample: sample)
        }
        check(row() == nil, "Inactive renderer cannot report")
        store.configure(width: 5120, height: 2880)
        check(row()!.receiverTiming!.sourcePTSAvailability == .unavailable, "No source PTS means unavailable")
        check(row()!.receiverTiming!.sourcePTSRelativeEnqueueExcess == nil, "No invented zero latency")
        collect(av(100))
        check(row()!.avPerformance?.estimatedPresentedFPS == nil, "First AV sample is only a baseline")
        clock.set(102); collect(av(282, dropped: 2, delay: 0.1))
        check(row()!.avPerformance?.estimatedPresentedFPS == 90, "AV FPS uses delta frames minus delta drops")
        check(row()!.avPerformance?.intervalSeconds == 2, "AV interval explicit")
        clock.set(108)
        check(row()!.avPerformance?.estimatedPresentedFPS == nil, "Stale AV rate unavailable")
        collect(av(282, dropped: 2, delay: 0.1))
        check(row()!.avPerformance?.estimatedPresentedFPS == 0, "Actual no progress is zero")
        clock.set(110); collect(av(10))
        check(row()!.avPerformance?.estimatedPresentedFPS == nil, "Counter reset establishes baseline")
        clock.set(112); collect(av(20, corrupted: 3))
        clock.set(114); collect(av(30, corrupted: 2))
        check(row()!.avPerformance?.estimatedPresentedFPS == nil, "Any decreasing AV counter invalidates interval")
        collect(av(2, dropped: 3))
        check(row()!.avPerformance == nil, "Contradictory AV counters unavailable")
        collect(av(1, delay: .nan))
        check(row()!.avPerformance == nil, "Nonfinite AV delay unavailable")
        collect(nil)
        check(row()!.avPerformance == nil, "Missing AV collection unavailable")
        let old = store.beginPerformanceCollection()!
        check(store.beginPerformanceCollection() == nil, "Single asynchronous request")
        let oldGeneration = row()!.rendererGeneration
        store.resetPresentation()
        check(row()!.rendererGeneration != oldGeneration, "Flush changes report generation")
        check(store.beginPerformanceCollection() == nil, "Flush cannot overlap old callback")
        store.completePerformanceCollection(requestToken: old, sample: av(1000))
        check(row()!.avPerformance == nil, "Stale callback cannot repopulate flushed layer")
        let fresh = store.beginPerformanceCollection()!
        store.completePerformanceCollection(requestToken: old, sample: av(9999))
        check(store.beginPerformanceCollection() == nil, "Duplicate stale callback cannot release newer token")
        store.completePerformanceCollection(requestToken: fresh, sample: av(10))
        check(row()!.avPerformance?.totalFrames == 10, "New generation baseline collected")
        let invalidated = store.beginPerformanceCollection()!
        store.invalidate(); store.configure(width: 5120, height: 2880)
        store.completePerformanceCollection(requestToken: invalidated, sample: av(1000))
        check(row()!.avPerformance == nil, "Reconfigure fences old request")

        clock.set(200); store.configure(width: 5120, height: 2880)
        let first = store.received(bytes: 100, sourcePTSSeconds: 9000)!
        clock.set(200.005); store.drained(first)
        clock.set(200.010); store.enqueued(first)
        clock.set(200.020); let second = store.received(bytes: 200, sourcePTSSeconds: 9000.020)!
        clock.set(200.025); store.drained(second)
        clock.set(200.050); store.enqueued(second)
        store.ingress(callbackAt: 200, mainAdmittedAt: 200.003, rearmedAt: 200.006, fullChunk: true)
        store.ingress(callbackAt: 200.01, mainAdmittedAt: 200.017, rearmedAt: 200.02, fullChunk: false)
        let timing = row()!.receiverTiming!
        check(timing.measurementKind == "sourcePTSRelativeMinimum", "Relative semantics explicit")
        check(timing.sourcePTSAvailability == .relativeMinimum, "Two valid frames allow relative diagnostic")
        check(abs(timing.sourcePTSRelativeEnqueueExcess!.maximumMilliseconds - 20) < 0.000001,
            "Receiver/source deltas cancel unknown clock offset; 20ms excess remains")
        check(timing.sourcePTSRelativeEnqueueExcess?.sampleCount == 2, "Relative distribution count")
        check(abs(timing.frameAdmissionToDisplayEnqueue!.maximumMilliseconds - 30) < 0.000001, "Enqueue is local suffix")
        check(abs(timing.frameAdmissionToRendererDrain!.maximumMilliseconds - 5) < 0.000001, "Second hop exported separately")
        check(abs(timing.callbackToMainAdmission!.maximumMilliseconds - 7) < 0.000001, "First hop distribution")
        check(abs(timing.callbackToReceiveRearm!.maximumMilliseconds - 10) < 0.000001, "Rearm includes parsing hop")
        check(timing.ingressCallbacks == 2 && timing.fullChunkCallbacks == 1, "Full-chunk coverage explicit")
        check(timing.assumedRelativeClockDriftPPM == 100 &&
            abs(timing.sourcePTSRelativeDriftAllowanceMilliseconds! - 0.004) < 0.000001,
            "100ppm budget conditional on relative sample span, not measured clock uncertainty")
        check(!timing.physicalPresentationMeasured, "Enqueue data never claims photons")
        store.ingress(callbackAt: 200.02, mainAdmittedAt: 200.01, rearmedAt: 200.03, fullChunk: true)
        check(row()!.receiverTiming!.ingressCallbacks == 2, "Contradictory local ordering rejected")
        let wire = try JSONEncoder().encode(row()!)
        let decoded = try JSONDecoder().decode(PeelClientStreamMetric.self, from: wire)
        check(decoded == row(), "Optional timing wire round trip")
        var oldPayload = try JSONSerialization.jsonObject(with: wire) as! [String: Any]
        oldPayload.removeValue(forKey: "receiverTiming")
        let decodedOld = try JSONDecoder().decode(PeelClientStreamMetric.self,
            from: JSONSerialization.data(withJSONObject: oldPayload))
        check(decodedOld.receiverTiming == nil, "Old payload decodes optional nil")
        check(wire.count < 16_384, "Actual one-window report retains existing send bound")
        let receiver = PeelReceiverDiagnostics(uptime: clock.now)
        receiver.setSession(generation: 1, negotiated: true)
        let report = PeelClientStreamMetricsMessage(sequence: 1, sampledAtClientUptimeSeconds: clock.now(), streams: [row()!])
        check(receiver.accept(report, generation: 1), "Actual normalizer accepts valid current report")
        guard case .object(let snapshot) = receiver.snapshot(), case .object(let forwarded)? = snapshot["report"],
              case .array(let rows)? = forwarded["streams"], case .object(let forwardedRow) = rows[0] else {
            preconditionFailure("Missing actual MCP receiver forwarding")
        }
        check(forwardedRow["receiverTiming"] != nil, "Actual JSON normalizer preserves timing field")

        clock.set(200.06); _ = store.received(bytes: 1)
        check(row()!.receiverTiming!.sourcePTSRelativeEnqueueExcess == nil, "Missing PTS retires old relative segment")
        check(row()!.receiverTiming!.sourcePTSMissingFrames == 1, "Missing count explicit")
        clock.set(200.07); let baseline = store.received(bytes: 1, sourcePTSSeconds: 100)!
        store.enqueued(baseline)
        clock.set(200.08); let backwards = store.received(bytes: 1, sourcePTSSeconds: 99)!
        store.enqueued(backwards)
        check(row()!.receiverTiming!.sourcePTSDiscontinuities == 1, "Backwards PTS starts separate segment")
        check(row()!.receiverTiming!.sourcePTSRelativeEnqueueExcess == nil, "No bridging backwards PTS")
        clock.set(200.09); _ = store.received(bytes: 1, sourcePTSSeconds: 1000)
        check(row()!.receiverTiming!.sourcePTSDiscontinuities == 2, "Unknown large forward jump retires timeline")
        clock.set(200.10); _ = store.received(bytes: 1, sourcePTSSeconds: .infinity)
        check(row()!.receiverTiming!.sourcePTSMissingFrames == 2, "Nonfinite PTS unavailable")
        let obsoleteFrame = store.received(bytes: 1, sourcePTSSeconds: 1)!
        store.resetPresentation()
        store.drained(obsoleteFrame); store.enqueued(obsoleteFrame)
        check(row()!.receiverTiming!.frameAdmissionToDisplayEnqueue == nil, "Flush rejects queued old timing token")
        check(row()!.receiverTiming!.sourcePTSRelativeEnqueueExcess == nil, "Flush clears all relative baselines")
        let beforeRollbackGeneration = row()!.rendererGeneration
        clock.set(199)
        check(row() == nil, "Backwards receiver clock cannot report future samples as fresh")
        _ = store.received(bytes: 1, sourcePTSSeconds: 1)
        check(row()!.receiverTiming!.frameAdmissionToRendererDrain == nil, "Observed clock rollback retires interval rings")
        check(row()!.rendererGeneration != beforeRollbackGeneration, "Clock rollback also fences old queued/AV tokens")

        clock.set(300); store.configure(width: 5120, height: 2880)
        for i in 0..<1100 {
            clock.set(300 + Double(i) * 0.001)
            let frame = store.received(bytes: 1, sourcePTSSeconds: 7000 + Double(i) * 0.001)!
            store.drained(frame); store.enqueued(frame)
            store.ingress(callbackAt: clock.now(), mainAdmittedAt: clock.now(), rearmedAt: clock.now(), fullChunk: true)
        }
        let bounded = row()!.receiverTiming!
        check(bounded.frameAdmissionToDisplayEnqueue?.sampleCount == 1024, "Fixed capacity overwrites timing samples")
        check(bounded.sourcePTSRelativeEnqueueExcess?.sampleCount == 1024, "Source timing samples bounded")
        check(bounded.sampleWindowTruncated && bounded.timingSampleCapacity == 1024, "Truncation disclosed")
        check(bounded.ingressCallbacks == 1100 && bounded.fullChunkCallbacks == 1100, "Cumulative counts separate from recent samples")
        check(bounded.sourcePTSRelativeEnqueueExcess!.maximumMilliseconds < 0.000001, "Stable relative cadence yields zero excess, never absolute latency")
        clock.set(307)
        check(row()!.receiverTiming!.callbackToMainAdmission == nil && row()!.receiverTiming!.sourcePTSRelativeEnqueueExcess == nil,
            "Samples older than five seconds expire")
        check(!row()!.receiverTiming!.sampleWindowTruncated, "Expired full ring does not imply current truncation")

        // Once a previous minimum ages out, a new minimum is intentionally used.
        clock.set(400); store.configure(width: 5120, height: 2880)
        let initial = store.received(bytes: 1, sourcePTSSeconds: 10)!
        store.enqueued(initial)
        clock.set(404); let slow = store.received(bytes: 1, sourcePTSSeconds: 13.98)!
        store.enqueued(slow)
        clock.set(404.5); let slower = store.received(bytes: 1, sourcePTSSeconds: 14.47)!
        store.enqueued(slower)
        check(abs(row()!.receiverTiming!.sourcePTSRelativeEnqueueExcess!.maximumMilliseconds - 30) < 0.000001, "Old minimum currently in window")
        clock.set(405.1)
        check(abs(row()!.receiverTiming!.sourcePTSRelativeEnqueueExcess!.maximumMilliseconds - 10) < 0.000001, "Reference shifts when old minimum expires")
        clock.set(450); store.configure(width: 5120, height: 2880)
        for i in 1...20 {
            let end = 450 + Double(i) * 0.1
            clock.set(end)
            store.ingress(callbackAt: end - 0.03, mainAdmittedAt: end - 0.03 + Double(i) * 0.001,
                rearmedAt: end, fullChunk: false)
        }
        let percentile = row()!.receiverTiming!.callbackToMainAdmission!
        check(abs(percentile.p50Milliseconds - 10) < 0.000001 &&
              abs(percentile.p95Milliseconds - 19) < 0.000001 &&
              abs(percentile.maximumMilliseconds - 20) < 0.000001,
              "Nearest-rank p50/p95/max use real recent samples")
        // A stable path plus 100ppm relative rate drift can itself produce a
        // residual. Export that allowance as assumed, not synchronized uncertainty.
        clock.set(500); store.configure(width: 5120, height: 2880)
        for i in 0...40 {
            let elapsed = Double(i) / 10
            clock.set(500 + elapsed)
            let frame = store.received(bytes: 1, sourcePTSSeconds: 9000 + elapsed * 1.0001)!
            clock.set(500 + elapsed + 0.01); store.enqueued(frame)
        }
        let drift = row()!.receiverTiming!
        check(abs(drift.sourcePTSRelativeEnqueueExcess!.maximumMilliseconds - 0.4) < 0.000001,
            "Rate drift alone can appear as relative delay")
        check(abs(drift.sourcePTSRelativeDriftAllowanceMilliseconds! - 0.4) < 0.000001,
            "Conditional drift allowance covers recent baseline span")
        var malformed = try JSONSerialization.jsonObject(with: JSONEncoder().encode(row()!)) as! [String: Any]
        var malformedTiming = malformed["receiverTiming"] as! [String: Any]
        malformedTiming["physicalPresentationMeasured"] = true
        malformed["receiverTiming"] = malformedTiming
        let malformedRow = try JSONDecoder().decode(PeelClientStreamMetric.self,
            from: JSONSerialization.data(withJSONObject: malformed))
        check(!malformedRow.isValid, "Peer cannot label relative data physical presentation")
        if CommandLine.arguments.count > 1 {
            try JSONEncoder().encode(row()!).write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .withoutOverwriting)
        }
        let pending = store.beginPerformanceCollection()!
        store.invalidate(); store.completePerformanceCollection(requestToken: pending, sample: av(5))
        check(row() == nil && store.beginPerformanceCollection() == nil, "Invalidation releases no stale observable state")
        print("MacReceiverTimingChecks: PASS (\(checks) checks; actual production transforms, bounded rings, AV generations, wire/MCP forwarding)")
    }
}
