import Foundation

nonisolated final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 100
    func now() -> Double { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ next: Double) { lock.lock(); value = next; lock.unlock() }
}

@main
struct StreamingDiagnosticsChecks {
    static func object(_ value: PeelLocalAgentJSONValue) -> [String: PeelLocalAgentJSONValue] {
        guard case .object(let result) = value else { fatalError("Expected object") }
        return result
    }
    static func rows(_ store: PeelStreamingDiagnostics) -> [[String: PeelLocalAgentJSONValue]] {
        guard case .array(let items) = object(store.snapshot())["streams"] else { fatalError("Expected streams") }
        return items.map(object)
    }
    static func main() throws {
        precondition(PeelVideoEncoderHardwarePolicy.verification(status: 0, reportedHardware: true,
            hardwareRequired: true) == .queried)
        precondition(PeelVideoEncoderHardwarePolicy.verification(status: -12900, reportedHardware: nil,
            hardwareRequired: true) == .requiredAtCreation)
        precondition(PeelVideoEncoderHardwarePolicy.verification(status: -12900, reportedHardware: nil,
            hardwareRequired: false) == .unavailable)
        precondition(PeelVideoEncoderHardwarePolicy.verification(status: 0, reportedHardware: false,
            hardwareRequired: true) == .unavailable)
        precondition(PeelVideoEncoderHardwarePolicy.verification(status: -12903, reportedHardware: nil,
            hardwareRequired: true) == .unavailable)
        let clock = TestClock()
        let store = PeelStreamingDiagnostics(uptime: clock.now)
        let old = store.begin(windowID: 1, width: 5120, height: 2880,
            targetFPS: 120, targetBitrate: 100_000_000, preferredCodec: "hevc")!
        precondition(rows(store)[0]["encodedFPS"] == .null)
        precondition(rows(store)[0]["hardwareAccelerated"] == .null)
        store.setEncoder(windowID: 1, token: old, codec: "hevc", mode: "lowLatency", hardwareAccelerated: true,
            hardwareVerification: "requiredAtCreation", encoderID: "test.encoder")
        store.setSpeedPriorityStatus(windowID: 1, token: old, status: -12900)
        for i in 0..<10 { store.sessionFailure(windowID: 1, token: old, reason: "failure \(i)") }
        precondition(rows(store)[0]["encoderID"] == .string("test.encoder"))
        precondition(rows(store)[0]["speedPriorityPropertyStatus"] == .integer(-12900))
        precondition(rows(store)[0]["sessionFailures"] == .integer(10))
        precondition(rows(store)[0]["recentSessionFailures"] == .array((2..<10).map { .string("failure \($0)") }))
        store.resetEncoder(windowID: 1, token: old, reason: "test reset")
        precondition(rows(store)[0]["encoderID"] == .null)
        precondition(rows(store)[0]["speedPriorityPropertyStatus"] == .null)
        store.setRecovery(windowID: 1, token: old, state: "cooldown", nextCandidate: "hevcLowLatency",
            consecutiveFailures: 0, retryAfterUptime: 105)
        precondition(rows(store)[0]["recoveryState"] == .string("cooldown"))
        precondition(rows(store)[0]["retryAfterHostUptimeSeconds"] == .number(105))
        store.setEncoder(windowID: 1, token: old, codec: "hevc", mode: "lowLatency", hardwareAccelerated: true)
        for i in 1...600 {
            clock.set(100 + Double(i) / 120)
            store.submitted(windowID: 1, token: old)
            store.output(windowID: 1, token: old, bytes: 1000, keyframe: i == 1,
                encodeMilliseconds: i.isMultiple(of: 20) ? 7 : 2)
        }
        let measured = rows(store)[0]
        precondition(measured["encodedFPS"] == .number(120))
        precondition(measured["encodedMbps"] == .number(0.96))
        precondition(measured["encodeCallbackMillisecondsP50"] == .number(2))
        precondition(measured["encodeCallbackMillisecondsP95"] == .number(2))
        precondition(measured["encodeCallbackMillisecondsMax"] == .number(7))
        precondition(measured["outputFrames"] == .integer(600))
        precondition(measured["recoveryState"] == .string("active"))
        precondition(measured["retryAfterHostUptimeSeconds"] == .null)
        precondition(rows(store)[0] == measured, "Read must not reset counters")

        // An idle encoder retains historical totals but cannot report stale 120fps.
        clock.set(111)
        let idle = rows(store)[0]
        precondition(idle["encodedFPS"] == .number(0))
        precondition(idle["lastOutputAgeSeconds"] == .number(6))
        precondition(idle["encodeCallbackMillisecondsP95"] == .null)

        let replacement = store.begin(windowID: 1, width: 1920, height: 1080,
            targetFPS: 60, targetBitrate: 10_000_000, preferredCodec: "h264")!
        store.output(windowID: 1, token: old, bytes: 10, keyframe: false, encodeMilliseconds: 3)
        store.setSpeedPriorityStatus(windowID: 1, token: old, status: 0)
        store.setRecovery(windowID: 1, token: old, state: "cooldown", nextCandidate: "hevcLowLatency",
            consecutiveFailures: 1, retryAfterUptime: 115)
        store.end(windowID: 1, token: old)
        precondition(rows(store)[0]["active"] == .bool(true))
        precondition(rows(store)[0]["outputFrames"] == .integer(0))
        precondition(rows(store)[0]["speedPriorityPropertyStatus"] == .null)
        precondition(rows(store)[0]["recoveryState"] == .string("waitingForSession"))
        precondition(rows(store)[0]["retryAfterHostUptimeSeconds"] == .null)
        store.setRecovery(windowID: 1, token: replacement, state: "retrying", nextCandidate: "h264LowLatency",
            consecutiveFailures: 1, retryAfterUptime: .nan)
        precondition(rows(store)[0]["consecutiveRuntimeFailures"] == .integer(1))
        precondition(rows(store)[0]["retryAfterHostUptimeSeconds"] == .null)
        store.output(windowID: 1, token: replacement, bytes: 10, keyframe: true, encodeMilliseconds: .nan)
        precondition(rows(store)[0]["encodeCallbackMillisecondsP95"] == .null)
        precondition(rows(store)[0]["outputFrames"] == .integer(1))
        store.end(windowID: 1, token: replacement)
        store.output(windowID: 1, token: replacement, bytes: 10, keyframe: false, encodeMilliseconds: 3)
        precondition(rows(store)[0]["outputFrames"] == .integer(1))
        store.reset()
        store.output(windowID: 1, token: replacement, bytes: 10, keyframe: false, encodeMilliseconds: 3)
        precondition(rows(store).isEmpty)

        for id in 1...PeelStreamingDiagnostics.maximumStreams {
            precondition(store.begin(windowID: UInt32(id), width: 2, height: 2,
                targetFPS: 120, targetBitrate: 1, preferredCodec: "h264") != nil)
        }
        precondition(store.begin(windowID: 99, width: 2, height: 2,
            targetFPS: 120, targetBitrate: 1, preferredCodec: "h264") == nil)
        precondition(object(store.snapshot())["untrackedEncoderStarts"] == .integer(1))
        precondition(rows(store).count == PeelStreamingDiagnostics.maximumStreams)
        let payload = try JSONEncoder().encode(store.snapshot())
        precondition(payload.count < PeelLocalAgentServer.maximumMessageBytes / 2)
        precondition(object(store.snapshot())["clientPresentationMetrics"] == .null)
        precondition(object(store.snapshot())["endToEndLatencyMilliseconds"] == .null)

        // Concurrent callback delivery stays bounded and serializes counter updates.
        store.reset()
        let concurrent = store.begin(windowID: 1, width: 2, height: 2,
            targetFPS: 120, targetBitrate: 1, preferredCodec: "hevc")!
        DispatchQueue.concurrentPerform(iterations: 2000) { _ in
            store.output(windowID: 1, token: concurrent, bytes: 1,
                keyframe: false, encodeMilliseconds: 1)
            _ = store.snapshot()
        }
        clock.set(112)
        let bounded = rows(store)[0]
        precondition(bounded["outputFrames"] == .integer(2000))
        precondition(bounded["outputSampleCount"] == .integer(Int64(PeelStreamingDiagnostics.maximumSamples)))
        precondition(bounded["sampleCapacityReached"] == .bool(true))
        precondition(bounded["encodedFPS"] == .null, "Do not under-report saturated sample windows")
        let transport = PeelVideoSendDiagnostics(uptime: clock.now)
        func sendRow() -> [String: PeelLocalAgentJSONValue] {
            guard case .array(let rows) = object(transport.snapshot())["transports"], let row = rows.first else {
                fatalError("Expected transport")
            }
            return object(row)
        }
        clock.set(200)
        transport.begin(windowID: 1, generation: 1)
        transport.enqueued(windowID: 1, generation: 1, bytes: 120_000)
        transport.queue(windowID: 1, generation: 1, outstandingBytes: 120_000, backpressure: true)
        precondition(sendRow()["backpressureActive"] == .bool(true))
        clock.set(200.020)
        transport.completed(windowID: 1, generation: 1, bytes: 120_000, startedAt: 200, failed: false)
        transport.queue(windowID: 1, generation: 1, outstandingBytes: 0, backpressure: false)
        clock.set(201)
        precondition(sendRow()["contentProcessedMbps"] == .number(0.96))
        precondition(sendRow()["outstandingBytes"] == .integer(0))
        transport.completed(windowID: 1, generation: 1, bytes: 1000, startedAt: 200.9, failed: true)
        precondition(sendRow()["failedPackets"] == .integer(1))
        precondition(sendRow()["contentProcessedBytes"] == .integer(120_000))
        transport.begin(windowID: 1, generation: 2)
        transport.completed(windowID: 1, generation: 1, bytes: 999, startedAt: 200, failed: false)
        transport.queue(windowID: 1, generation: 1, outstandingBytes: 999, backpressure: true)
        transport.end(windowID: 1, generation: 1)
        precondition(sendRow()["active"] == .bool(true))
        precondition(sendRow()["contentProcessedBytes"] == .integer(0))
        precondition(sendRow()["outstandingBytes"] == .integer(0))
        transport.end(windowID: 1, generation: 2)
        transport.completed(windowID: 1, generation: 2, bytes: 999, startedAt: 200, failed: false)
        precondition(sendRow()["contentProcessedBytes"] == .integer(0))
        transport.reset()
        precondition(object(transport.snapshot())["transports"] == .array([]))
        print("StreamingDiagnosticsChecks: PASS (encoder/send rates, idle freshness, generations, bounds, concurrent callbacks)")
    }
}
