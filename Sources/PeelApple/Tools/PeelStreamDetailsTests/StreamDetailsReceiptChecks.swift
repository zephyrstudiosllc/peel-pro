import Foundation

@main
struct StreamDetailsReceiptChecks {
    static func main() throws {
        let session = UUID(), generation = UUID()
        func metric(generation: UUID? = nil, window: UInt32 = 42, received: Int64 = 100,
                    enqueued: Int64? = 95, dropped: Int64? = 5) -> PeelClientStreamMetric {
            .init(windowId: window, rendererGeneration: generation ?? Self.generationPlaceholder,
                  rendererKind: .displayLayer, width: 1920, height: 1080,
                  receivedFrames: received, receivedBytes: received * 100,
                  enqueuedFrames: enqueued, applicationDroppedFrames: dropped, recoveryRequests: 0,
                  queuedFrames: 0, queuedBytes: 0, oldestQueuedFrameAgeMilliseconds: nil,
                  lastReceivedFrameAgeMilliseconds: 1, screenMaximumFPS: 120,
                  displayLayerStatus: 1, displayLayerRequiresFlush: false, displayLayerErrorCode: nil,
                  avPerformance: nil)
        }
        func receipt(_ start: Double, _ end: Double, sessionID: UUID? = nil,
                     value: PeelClientStreamMetric? = nil) -> PeelStreamDetailsReceipt? {
            .init(observationSessionID: sessionID ?? session,
                  samplingStartedAtClientUptimeSeconds: start,
                  samplingCompletedAtClientUptimeSeconds: end,
                  metric: value ?? metric(generation: generation))
        }
        let before = receipt(10, 10.01)!
        let after = receipt(12, 12.02, value: metric(generation: generation, received: 220, enqueued: 210, dropped: 10))!
        let delta = after.counterDelta(since: before)!
        precondition(delta.receivedFrames == 120 && delta.receivedBytes == 12_000)
        precondition(delta.enqueuedFrames == 115 && delta.applicationDroppedFrames == 5)
        precondition(abs(delta.minimumIntervalSeconds - 1.99) < 0.00001)
        precondition(abs(delta.maximumIntervalSeconds - 2.02) < 0.00001)
        precondition(before.counterDelta(since: before) == nil)
        precondition(before.counterDelta(since: after) == nil)
        precondition(receipt(10.005, 12)!.counterDelta(since: before) == nil)
        precondition(receipt(12, 12.01, sessionID: UUID())!.counterDelta(since: before) == nil)
        precondition(receipt(12, 12.01, value: metric(generation: UUID()))!.counterDelta(since: before) == nil)
        precondition(receipt(12, 12.01, value: metric(generation: generation, window: 43))!.counterDelta(since: before) == nil)
        precondition(receipt(12, 12.01, value: metric(generation: generation, received: 99))!.counterDelta(since: before) == nil)
        precondition(receipt(12, 12.01, value: metric(generation: generation, enqueued: 94))!.counterDelta(since: before) == nil)
        precondition(receipt(12, 12.01, value: metric(generation: generation, dropped: 4))!.counterDelta(since: before) == nil)
        precondition(receipt(12, 12.01, value: metric(generation: generation, dropped: nil))!.counterDelta(since: before) == nil)
        let unavailableBefore = receipt(10, 10.01, value: metric(generation: generation, enqueued: nil, dropped: nil))!
        let unavailableAfter = receipt(12, 12.01, value: metric(generation: generation, enqueued: nil, dropped: nil))!
        precondition(unavailableAfter.counterDelta(since: unavailableBefore)?.applicationDroppedFrames == nil)
        precondition(receipt(.nan, 12) == nil && receipt(12, .infinity) == nil)
        precondition(receipt(12, 11) == nil && receipt(-1, 12) == nil)
        precondition(PeelStreamDetailsReceipt(observationSessionID: session,
            samplingStartedAtClientUptimeSeconds: 10, samplingCompletedAtClientUptimeSeconds: 11, metric: nil) == nil)
        let json = after.jsonString!
        let decoded = try JSONDecoder().decode(PeelStreamDetailsReceipt.self, from: Data(json.utf8))
        precondition(decoded == after)
        let keys = Set((try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]).keys)
        precondition(keys == ["version", "observationSessionID", "samplingStartedAtClientUptimeSeconds", "samplingCompletedAtClientUptimeSeconds", "metric"])
        print("StreamDetailsReceiptChecks: PASS (atomic JSON round-trip, bounded interval, identity/generation/reset rejection)")
    }
    static let generationPlaceholder = UUID()
}
