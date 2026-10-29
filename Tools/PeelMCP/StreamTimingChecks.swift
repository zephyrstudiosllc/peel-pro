import Foundation

@main
struct StreamTimingChecks {
    static func main() throws {
        let tracker = PeelStreamClockTracker()
        let probe = tracker.makeProbe(now: 100)
        // Host clock is 1000 seconds ahead. Forward delay 5 ms, reverse 25 ms.
        let reply = PeelStreamClockReply(type: "hostStreamClock", probe: probe,
            hostReceived: 1100.005, hostSent: 1100.006, hostMediaClockMinusUptime: 0,
            verifiedSourceWindowIds: [7])
        precondition(tracker.accept(reply, receivedAt: 100.031))
        precondition(!tracker.accept(reply, receivedAt: 100.031)) // replay
        let estimate = tracker.estimate(now: 100.032)!
        precondition(abs(estimate.roundTrip - 0.030) < 0.000001)
        precondition(estimate.lowerOffset < 1000 && estimate.upperOffset > 1000)
        precondition(tracker.estimate(now: 111) == nil)

        let diagnostics = PeelSpatialVideoDiagnostics()
        let generation = diagnostics.configure(width: 5120, height: 2880, now: 100)
        diagnostics.decoded(generation: UUID()) // stale generation
        diagnostics.decoded(generation: generation, now: 100.044)
        diagnostics.published(generation: generation,
            frame: .init(receivedAt: 100.04, sourcePTSSeconds: 1100.03, decodedAt: 100.044),
            conversionMilliseconds: 2, windowId: 7, clock: estimate, now: 100.05)
        let row = diagnostics.snapshot(clock: estimate, now: 101)
        precondition(row.isValid && row.decodedFrames == 1 && row.publishedFrames == 1)
        precondition(row.decodedFPS == 1 && row.publishedFPS == 1)
        precondition(row.sourceTimebaseVerified && !row.physicalPresentationMeasured)
        // True source-to-publication is 20 ms. Full offset bound is ~25 ms,
        // including asymmetry and a drift allowance, never half-RTT certainty.
        let upper = row.sourcePTSToPublicationUpperBound!.maximumMilliseconds
        precondition(upper >= 25 && upper < 25.1)
        precondition(abs(row.receiveToPublication!.maximumMilliseconds - 10) < 0.000001)
        precondition(row.sourcePTSToPublicationUpperBound?.sampleCount == 1)
        precondition(diagnostics.snapshot(clock: nil, now: 106).receiveToPublication == nil)
        precondition(diagnostics.snapshot(clock: nil, now: 106).sourceTimebaseVerified == false)

        let current = diagnostics.configure(width: 5120, height: 2880, now: 110)
        diagnostics.decoded(generation: generation)
        diagnostics.decoded(generation: current, failed: true)
        precondition(diagnostics.snapshot(clock: nil, now: 111).decodedFrames == 0)
        precondition(diagnostics.snapshot(clock: nil, now: 111).decodeFailures == 1)

        let slow = tracker.makeProbe(now: 200)
        let invalid = PeelStreamClockReply(type: "hostStreamClock", probe: slow,
            hostReceived: 1200, hostSent: 1199, hostMediaClockMinusUptime: 0,
            verifiedSourceWindowIds: nil)
        precondition(!tracker.accept(invalid, receivedAt: 200.1))
        tracker.reset()
        precondition(tracker.estimate(now: 200.1) == nil)
        precondition(!tracker.accept(reply, receivedAt: 100.031))
        precondition(!PeelStreamClockProbe(id: UUID(), clientSent: .nan).isValid)
        precondition(!PeelLatencyDistribution(sampleCount: 0, p50Milliseconds: 1,
            p95Milliseconds: 2, maximumMilliseconds: 3).isValid)
        precondition(!PeelLatencyDistribution(sampleCount: 1, p50Milliseconds: 3,
            p95Milliseconds: 2, maximumMilliseconds: 1).isValid)

        // Reverse-heavy probe acquisition consumes drift budget too. At exactly
        // 100 ppm, the old post-receipt-only formula reported49.995ms for50.19ms.
        let driftTracker = PeelStreamClockTracker()
        let driftProbe = driftTracker.makeProbe(now: 100)
        precondition(driftTracker.accept(PeelStreamClockReply(type: "hostStreamClock", probe: driftProbe,
            hostReceived: 1100, hostSent: 1100, hostMediaClockMinusUptime: 0,
            verifiedSourceWindowIds: [7]), receivedAt: 102))
        let driftEstimate = driftTracker.estimate(now: 102.05119)!
        let source = 1100 + (102.001 - 100) * 1.0001
        let observed = 102.05119
        let actualAge = (observed - 102.001) * 1000
        let driftDiagnostics = PeelSpatialVideoDiagnostics()
        let driftGeneration = driftDiagnostics.configure(width: 5120, height: 2880, now: 102)
        driftDiagnostics.published(generation: driftGeneration,
            frame: .init(receivedAt: 102.002, sourcePTSSeconds: source, decodedAt: 102.003),
            conversionMilliseconds: 1, windowId: 7, clock: driftEstimate, now: observed)
        let driftRow = driftDiagnostics.snapshot(clock: driftEstimate, now: observed)
        precondition(driftRow.sourcePTSToPublicationUpperBound!.maximumMilliseconds >= actualAge)
        precondition(driftRow.sourcePTSToPublicationUpperBound!.maximumMilliseconds >= 50)
        let fixtureTiming = PeelNativeFixtureQuality.sourceTiming(
            sourceHostMediaSeconds: source, now: observed, clock: driftEstimate)!
        precondition(fixtureTiming.upperMilliseconds >= actualAge)
        precondition(fixtureTiming.uncertaintyMilliseconds == driftRow.clockUncertaintyMilliseconds)
        precondition(fixtureTiming.uncertaintyMilliseconds > 2000.4)
        let narrowProbe = driftTracker.makeProbe(now: 102.04)
        precondition(driftTracker.accept(PeelStreamClockReply(type: "hostStreamClock", probe: narrowProbe,
            hostReceived: 1102.045, hostSent: 1102.045, hostMediaClockMinusUptime: 0,
            verifiedSourceWindowIds: [7]), receivedAt: 102.05))
        let narrow = driftTracker.estimate(now: observed)!
        let mixedProbeRow = driftDiagnostics.snapshot(clock: narrow, now: observed)
        precondition(mixedProbeRow.clockUncertaintyMilliseconds! >= fixtureTiming.uncertaintyMilliseconds)
        precondition(PeelNativeFixtureQuality.sourceTiming(
            sourceHostMediaSeconds: source, now: 113, clock: driftEstimate) == nil)

        // Media sample occurs40ms into a50ms Host processing bracket. Treating
        // its delta as an exact simultaneous offset would exclude the real clock.
        let bridgeTracker = PeelStreamClockTracker()
        let bridgeProbe = bridgeTracker.makeProbe(now: 100)
        precondition(bridgeTracker.accept(PeelStreamClockReply(type: "hostStreamClock", probe: bridgeProbe,
            hostReceived: 1100.005, hostSent: 1100.055, hostMediaClockMinusUptime: 100.040,
            verifiedSourceWindowIds: [7]), receivedAt: 100.060))
        let bridge = bridgeTracker.estimate(now: 100.061)!
        let bridgeBounds = bridge.offsetBounds(at: 100.061)!
        precondition(bridgeBounds.lower <= 1100 && bridgeBounds.upper >= 1100)
        precondition(bridgeBounds.uncertaintyMilliseconds >= 60)
        precondition(bridge.offsetBounds(at: 100.059) == nil)

        // Old JSON lacking the new optional field must still decode.
        let old = #"{"windowId":7,"rendererGeneration":"00000000-0000-0000-0000-000000000001","rendererKind":"spatialUninstrumented","width":5120,"height":2880,"receivedFrames":1,"receivedBytes":100}"#
        let oldMetric = try JSONDecoder().decode(PeelClientStreamMetric.self, from: Data(old.utf8))
        precondition(oldMetric.isValid && oldMetric.spatialPipeline == nil)
        print("Stream timing checks passed: asymmetry, acquisition drift, clock bridge, fixture bounds, replay, expiry, generations, old JSON")
    }
}
