import Foundation

/// Local NWConnection submission/completion observations. A contentProcessed
/// callback does not acknowledge remote receipt or presentation.
nonisolated final class PeelVideoSendDiagnostics: @unchecked Sendable {
    private struct Completion {
        let uptime: Double
        let bytes: Int
        let milliseconds: Double
    }
    private struct Transport {
        let generation: UInt64
        let startedAt: Double
        var active = true
        var enqueuedPackets = 0
        var enqueuedBytes = 0
        var processedPackets = 0
        var processedBytes = 0
        var failedPackets = 0
        var outstandingBytes = 0
        var backpressureActive = false
        var lastCompletionAt: Double?
        var samples = [Completion?](repeating: nil, count: 1024)
        var nextSample = 0
    }
    private let lock = NSLock()
    private var transports: [UInt32: Transport] = [:]
    private let uptime: @Sendable () -> Double
    private var untrackedStarts = 0

    init(uptime: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.uptime = uptime
    }

    func begin(windowID: UInt32, generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        if transports[windowID] == nil, transports.count >= 32 {
            guard let victim = transports.filter({ !$0.value.active })
                .min(by: { $0.value.startedAt < $1.value.startedAt }) else {
                    untrackedStarts += 1
                    return
                }
            transports.removeValue(forKey: victim.key)
        }
        transports[windowID] = Transport(generation: generation, startedAt: uptime())
    }

    private func update(_ windowID: UInt32, _ generation: UInt64, _ body: (inout Transport) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard transports[windowID]?.generation == generation, transports[windowID]?.active == true else { return }
        body(&transports[windowID]!)
    }

    func enqueued(windowID: UInt32, generation: UInt64, bytes: Int) {
        update(windowID, generation) { $0.enqueuedPackets += 1; $0.enqueuedBytes += max(0, bytes) }
    }

    func completed(windowID: UInt32, generation: UInt64, bytes: Int, startedAt: Double, failed: Bool) {
        let now = uptime()
        update(windowID, generation) {
            $0.lastCompletionAt = now
            if failed { $0.failedPackets += 1; return }
            $0.processedPackets += 1
            $0.processedBytes += max(0, bytes)
            $0.samples[$0.nextSample] = Completion(uptime: now, bytes: max(0, bytes),
                milliseconds: max(0, now - startedAt) * 1000)
            $0.nextSample = ($0.nextSample + 1) % $0.samples.count
        }
    }

    func queue(windowID: UInt32, generation: UInt64, outstandingBytes: Int, backpressure: Bool) {
        update(windowID, generation) { $0.outstandingBytes = max(0, outstandingBytes); $0.backpressureActive = backpressure }
    }

    func end(windowID: UInt32, generation: UInt64) {
        update(windowID, generation) { $0.active = false; $0.outstandingBytes = 0; $0.backpressureActive = false }
    }

    func reset() {
        lock.lock(); transports.removeAll(); untrackedStarts = 0; lock.unlock()
    }

    func snapshot() -> PeelLocalAgentJSONValue {
        lock.lock()
        let now = uptime()
        let observations = transports
        let omitted = untrackedStarts
        lock.unlock()
        let rows = observations.sorted { $0.key < $1.key }.map { windowID, transport in
            let elapsed = min(5, max(0, now - transport.startedAt))
            let samples = transport.samples.compactMap { $0 }.filter { $0.uptime > now - 5 && $0.uptime <= now }
            let durations = samples.map(\.milliseconds).sorted()
            let rate: PeelLocalAgentJSONValue = elapsed >= 1 && samples.count < 1024
                ? .number(Double(samples.reduce(0) { $0 + $1.bytes }) * 8 / elapsed / 1_000_000) : .null
            return PeelLocalAgentJSONValue.object([
                "windowId": .integer(Int64(windowID)),
                "transportGeneration": .string(String(transport.generation)),
                "active": .bool(transport.active),
                "enqueuedPackets": .integer(Int64(transport.enqueuedPackets)),
                "enqueuedBytes": .integer(Int64(transport.enqueuedBytes)),
                "contentProcessedPackets": .integer(Int64(transport.processedPackets)),
                "contentProcessedBytes": .integer(Int64(transport.processedBytes)),
                "failedPackets": .integer(Int64(transport.failedPackets)),
                "outstandingBytes": .integer(Int64(transport.outstandingBytes)),
                "backpressureActive": .bool(transport.backpressureActive),
                "measurementWindowSeconds": .number(elapsed),
                "contentProcessedMbps": rate,
                "completionSampleCount": .integer(Int64(samples.count)),
                "sampleCapacityReached": .bool(samples.count == 1024),
                "sendCompletionMillisecondsP95": durations.isEmpty ? .null
                    : .number(durations[max(0, Int(ceil(Double(durations.count) * 0.95)) - 1)]),
                "lastCompletionAgeSeconds": transport.lastCompletionAt.map { .number(max(0, now - $0)) } ?? .null
            ])
        }
        return .object([
            "sampledAtHostUptimeSeconds": .number(now), "transports": .array(rows),
            "untrackedTransportStarts": .integer(Int64(omitted)),
            "measurementNote": .string("Local contentProcessed callbacks are not remote delivery acknowledgments. Packet counts include video configuration packets. Send completion duration includes local queue scheduling.")
        ])
    }
}
