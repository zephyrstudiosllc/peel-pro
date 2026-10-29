import Foundation

nonisolated final class ReceiverTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 100.0
    func now() -> Double { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Double) { lock.lock(); defer { lock.unlock() }; self.value = value }
}

@main
struct ReceiverDiagnosticsChecks {
    static func main() throws {
        let clock = ReceiverTestClock()
        let store = PeelClientVideoDiagnostics(uptime: clock.now)
        func row(_ kind: PeelClientStreamMetric.RendererKind = .displayLayer) -> PeelClientStreamMetric? {
            store.snapshot(windowId: 1, rendererKind: kind, queuedFrames: 0, queuedBytes: 0,
                oldestQueuedAgeMilliseconds: nil, screenMaximumFPS: 120)
        }
        func sample(_ total: Int64, _ dropped: Int64 = 0) -> PeelClientVideoDiagnostics.AVSample {
            .init(total: total, dropped: dropped, corrupted: 0, optimized: 0, accumulatedDelay: 0)
        }
        precondition(row() == nil)
        store.configure(width: 5120, height: 2880)
        let first = store.beginPerformanceCollection()!
        precondition(store.beginPerformanceCollection() == nil, "Only one asynchronous collection may be outstanding")
        store.completePerformanceCollection(requestToken: first, sample: sample(100))
        precondition(row()!.avPerformance!.estimatedPresentedFPS == nil)
        clock.set(104)
        store.completePerformanceCollection(requestToken: store.beginPerformanceCollection()!, sample: sample(580, 4))
        precondition(row()!.avPerformance!.estimatedPresentedFPS == 119)
        precondition(row()!.avPerformance!.intervalSeconds == 4)
        precondition(row(.spatialUninstrumented)!.avPerformance == nil)
        let spatial = row(.spatialUninstrumented)!
        precondition(spatial.screenMaximumFPS == nil,
            "A hidden conventional layer's screen must not stand in for the spatial surface")
        precondition(spatial.enqueuedFrames == nil && spatial.applicationDroppedFrames == nil &&
            spatial.recoveryRequests == nil && spatial.queuedFrames == nil && spatial.queuedBytes == nil,
            "Conventional renderer counters cannot describe the visible spatial renderer")
        clock.set(110)
        precondition(row()!.avPerformance!.estimatedPresentedFPS == nil, "Stale samples must not report a healthy rate")
        store.completePerformanceCollection(requestToken: store.beginPerformanceCollection()!, sample: sample(580, 4))
        precondition(row()!.avPerformance!.estimatedPresentedFPS == 0, "An idle renderer has zero observed progress")

        let obsolete = store.beginPerformanceCollection()!
        let oldGeneration = row()!.rendererGeneration
        store.resetPresentation()
        precondition(store.beginPerformanceCollection() == nil, "Reset cannot overlap an outstanding AV request")
        store.completePerformanceCollection(requestToken: obsolete, sample: sample(999))
        precondition(row()!.avPerformance == nil && row()!.rendererGeneration != oldGeneration)
        let replacement = store.beginPerformanceCollection()!
        store.completePerformanceCollection(requestToken: obsolete, sample: sample(999))
        precondition(store.beginPerformanceCollection() == nil, "Duplicate stale callback must not release a newer request")
        store.completePerformanceCollection(requestToken: replacement, sample: sample(10))
        clock.set(114)
        store.completePerformanceCollection(requestToken: store.beginPerformanceCollection()!, sample: sample(5))
        precondition(row()!.avPerformance!.estimatedPresentedFPS == nil, "Counter reset must not become negative FPS")
        store.completePerformanceCollection(requestToken: store.beginPerformanceCollection()!, sample: nil)
        precondition(row()!.avPerformance == nil)

        DispatchQueue.concurrentPerform(iterations: 1000) { _ in store.received(bytes: 100); store.enqueued() }
        precondition(row()!.receivedFrames == 1000 && row()!.receivedBytes == 100000 && row()!.enqueuedFrames == 1000)
        let report = PeelClientStreamMetricsMessage(sequence: 1, sampledAtClientUptimeSeconds: clock.now(), streams: [row()!])
        precondition(report.isValid)
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(PeelClientStreamMetricsMessage.self, from: data)
        precondition(decoded == report)
        // Exercise peer-controlled decoding, including fields our initializer fixes.
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for (key, value) in [("type", "other" as Any), ("version", 2), ("sequence", 0)] {
            var malformed = object
            malformed[key] = value
            let decoded = try JSONDecoder().decode(PeelClientStreamMetricsMessage.self,
                from: JSONSerialization.data(withJSONObject: malformed))
            precondition(!decoded.isValid)
        }
        // Even a fully populated 32-row report remains below the transport cap.
        var maximum = object
        var rows: [[String: Any]] = []
        for id in 1...PeelClientStreamMetricsMessage.maximumStreams {
            var populated = (object["streams"] as! [[String: Any]])[0]
            populated["windowId"] = id
            populated["oldestQueuedFrameAgeMilliseconds"] = 1_000_000_000_000.0
            populated["lastReceivedFrameAgeMilliseconds"] = 1_000_000_000_000.0
            populated["displayLayerStatus"] = 2
            populated["displayLayerRequiresFlush"] = true
            populated["displayLayerErrorCode"] = Int32.min
            populated["avPerformance"] = ["totalFrames": 9_000_000_000_000, "droppedFrames": 9_000_000_000_000,
                "corruptedFrames": 9_000_000_000_000, "optimizedCompositingFrames": 9_000_000_000_000,
                "accumulatedFrameDelaySeconds": 1_000_000_000_000.0, "sampleAgeMilliseconds": 1_000_000_000_000.0,
                "intervalSeconds": 60, "estimatedPresentedFPS": 1000]
            rows.append(populated)
        }
        maximum["streams"] = rows
        let maximumData = try JSONSerialization.data(withJSONObject: maximum)
        precondition(maximumData.count < PeelClientStreamMetricsMessage.maximumPayloadBytes)
        let maximumReport = try JSONDecoder().decode(PeelClientStreamMetricsMessage.self, from: maximumData)
        precondition(maximumReport.isValid)
        precondition(!PeelClientStreamMetricsMessage(sequence: 1, sampledAtClientUptimeSeconds: .nan, streams: []).isValid)
        precondition(!PeelClientStreamMetricsMessage(sequence: 1, sampledAtClientUptimeSeconds: 1, streams: [row()!, row()!]).isValid)
        precondition(!PeelClientStreamMetricsMessage(sequence: 1, sampledAtClientUptimeSeconds: 1, streams: Array(repeating: row()!, count: 33)).isValid)
        precondition(!PeelAVPerformanceMetric(totalFrames: 10, droppedFrames: 11, corruptedFrames: 0,
            optimizedCompositingFrames: 0, accumulatedFrameDelaySeconds: 0, sampleAgeMilliseconds: 0,
            intervalSeconds: nil, estimatedPresentedFPS: 120).isValid)
        let receiver = PeelReceiverDiagnostics(uptime: clock.now)
        precondition(!receiver.accept(report, generation: 1))
        receiver.setSession(generation: 1, negotiated: true)
        precondition(receiver.accept(report, generation: 1))
        precondition(!receiver.accept(report, generation: 1), "Reject replay")
        receiver.setSession(generation: 1, negotiated: true)
        precondition(!receiver.accept(report, generation: 1), "Same-generation hello cannot reset replay protection")
        let secondReport = PeelClientStreamMetricsMessage(sequence: 2, sampledAtClientUptimeSeconds: clock.now(), streams: [])
        precondition(!receiver.accept(secondReport, generation: 1), "Same-generation hello cannot reset cadence protection")
        receiver.setSession(generation: 1, negotiated: false)
        precondition(!receiver.accept(secondReport, generation: 1))
        receiver.setSession(generation: 1, negotiated: true)
        precondition(!receiver.accept(report, generation: 1), "Capability toggle must retain replay watermark")
        precondition(!receiver.accept(secondReport, generation: 1), "Capability toggle must retain cadence watermark")
        clock.set(116)
        precondition(receiver.accept(secondReport, generation: 1), "Rejected reports must not consume sequence numbers")
        guard case .object(let live) = receiver.snapshot() else { fatalError("Expected receiver object") }
        precondition(live["stale"] == .bool(false))
        receiver.clearObservation()
        guard case .object(let hidden) = receiver.snapshot() else { fatalError("Expected receiver object") }
        precondition(hidden["report"] == .null && hidden["stale"] == .bool(true))
        precondition(!receiver.accept(secondReport, generation: 1), "Visibility change must not reset replay protection")
        let thirdReport = PeelClientStreamMetricsMessage(sequence: 3, sampledAtClientUptimeSeconds: clock.now(), streams: [])
        precondition(!receiver.accept(thirdReport, generation: 1), "Visibility change must not reset cadence protection")
        clock.set(117)
        precondition(receiver.accept(thirdReport, generation: 1))
        clock.set(128)
        guard case .object(let stale) = receiver.snapshot() else { fatalError("Expected receiver object") }
        precondition(stale["stale"] == .bool(true))
        receiver.setSession(generation: 2, negotiated: true)
        precondition(!receiver.accept(secondReport, generation: 1), "Ignore old control socket")
        precondition(receiver.accept(report, generation: 2), "Replacement session has a fresh sequence space")
        receiver.setSession(generation: nil, negotiated: false)
        guard case .object(let cleared) = receiver.snapshot() else { fatalError("Expected receiver object") }
        precondition(cleared["report"] == .null && cleared["capabilityNegotiated"] == .bool(false))
        let beforeInvalidation = store.beginPerformanceCollection()!
        store.invalidate()
        store.configure(width: 1920, height: 1080)
        precondition(store.beginPerformanceCollection() == nil, "Reconfiguration must not overlap the old AV request")
        store.completePerformanceCollection(requestToken: beforeInvalidation, sample: sample(9999))
        precondition(row()!.avPerformance == nil)
        let afterReconfiguration = store.beginPerformanceCollection()!
        store.completePerformanceCollection(requestToken: afterReconfiguration, sample: nil)
        store.invalidate()
        store.received(bytes: 1)
        store.completePerformanceCollection(requestToken: replacement, sample: sample(9999))
        precondition(row() == nil)
        print("ReceiverDiagnosticsChecks: PASS (wire bounds, idle/stale/reset generations, concurrent callbacks)")
    }
}
