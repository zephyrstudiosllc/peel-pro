import Foundation

/// Bounded content-free observations. All `at` values are receiver systemUptime.
/// Host PTS remains separate from the display layer's existing local sequential PTS.
nonisolated final class PeelRemoteMacStreamingDiagnostics: @unchecked Sendable {
    struct AVSample: Sendable {
        let total: Int64, dropped: Int64, corrupted: Int64, optimized: Int64
        let accumulatedDelay: Double
    }
    struct FrameTiming: Sendable {
        let generation: UUID
        let admittedAt: Double
        let sourceSegment: UInt64
        let sourceRelativeSeconds: Double?
    }
    private struct Observation {
        let sample: AVSample
        let at: Double
        let interval: Double?
        let estimatedFPS: Double?
    }
    private struct Sample {
        let at: Double
        let value: Double
        var segment: UInt64 = 0
    }
    private struct Ring {
        static let capacity = 1024
        var values = [Sample?](repeating: nil, count: capacity)
        var next = 0
        mutating func append(_ sample: Sample) {
            values[next] = sample; next = (next + 1) % Self.capacity
        }
        func recent(at now: Double) -> [Sample] {
            values.compactMap { $0 }.filter { $0.at <= now && $0.at > now - 5 }
        }
    }
    private let lock = NSLock()
    private let uptime: @Sendable () -> Double
    private var generation = UUID()
    private var active = false
    private var width = 0, height = 0
    private var receivedFrames: Int64 = 0, receivedBytes: Int64 = 0
    private var enqueuedFrames: Int64 = 0, droppedFrames: Int64 = 0, recoveryRequests: Int64 = 0
    private var lastReceivedAt: Double?
    private var observation: Observation?
    // Retained across reset until completion: a missing AV callback cannot cause
    // overlapping/unbounded requests. A stale callback only releases its own token.
    private var inFlight: (token: UUID, generation: UUID)?
    private var startedAt: Double = 0
    private var ingressCallbacks: Int64 = 0, fullChunkCallbacks: Int64 = 0
    private var sourcePTSMissingFrames: Int64 = 0, sourcePTSDiscontinuities: Int64 = 0
    private var callbackToMain = Ring(), callbackToRearm = Ring()
    private var admissionToDrain = Ring(), admissionToEnqueue = Ring(), sourceResidual = Ring()
    private var sourceSegment: UInt64 = 0
    private var sourceAnchor: (pts: Double, at: Double)?
    private var lastSource: (pts: Double, at: Double)?

    init(uptime: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.uptime = uptime
    }

    private func clearTiming(now: Double) {
        startedAt = now
        callbackToMain = Ring(); callbackToRearm = Ring()
        admissionToDrain = Ring(); admissionToEnqueue = Ring(); sourceResidual = Ring()
        sourceSegment &+= 1; sourceAnchor = nil; lastSource = nil
    }

    func configure(width: Int, height: Int) {
        lock.lock(); defer { lock.unlock() }
        generation = UUID(); active = true; self.width = width; self.height = height
        receivedFrames = 0; receivedBytes = 0; enqueuedFrames = 0
        droppedFrames = 0; recoveryRequests = 0; lastReceivedAt = nil; observation = nil
        ingressCallbacks = 0; fullChunkCallbacks = 0
        sourcePTSMissingFrames = 0; sourcePTSDiscontinuities = 0
        clearTiming(now: uptime())
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        generation = UUID(); active = false; observation = nil
        clearTiming(now: uptime())
    }

    /// Every actual decoder flush retires AV/PTS timing baselines and queued
    /// timing tokens while preserving stream receive/drop/ingress totals.
    func resetPresentation() {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        generation = UUID(); observation = nil
        clearTiming(now: uptime())
    }

    @discardableResult
    func received(bytes: Int, sourcePTSSeconds: Double? = nil) -> FrameTiming? {
        guard bytes >= 0 else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard active else { return nil }
        let now = uptime()
        guard now.isFinite, now >= 0 else { return nil }
        receivedFrames = min(9_000_000_000_000, receivedFrames + 1)
        receivedBytes = min(9_000_000_000_000, receivedBytes + min(9_000_000_000_000, Int64(bytes)))
        if now < startedAt || lastReceivedAt.map({ now < $0 }) == true {
            generation = UUID(); observation = nil; clearTiming(now: now)
        }
        lastReceivedAt = now
        var relative: Double?
        if let pts = sourcePTSSeconds, pts.isFinite, pts >= 0 {
            // Unknown forward jumps and non-increasing PTS must never bridge
            // separate timelines. Smaller jumps/rate drift remain unknowable;
            // this is a relative diagnostic, not a synchronized clock bound.
            if let last = lastSource,
               pts <= last.pts || abs((pts - last.pts) - (now - last.at)) > 1 {
                sourcePTSDiscontinuities = min(9_000_000_000_000, sourcePTSDiscontinuities + 1)
                sourceSegment &+= 1; sourceAnchor = nil; lastSource = nil
            }
            if sourceAnchor == nil { sourceAnchor = (pts, now) }
            if let anchor = sourceAnchor {
                relative = (now - anchor.at) - (pts - anchor.pts)
            }
            lastSource = (pts, now)
        } else {
            sourcePTSMissingFrames = min(9_000_000_000_000, sourcePTSMissingFrames + 1)
            sourceSegment &+= 1; sourceAnchor = nil; lastSource = nil
        }
        return FrameTiming(generation: generation, admittedAt: now,
            sourceSegment: sourceSegment, sourceRelativeSeconds: relative)
    }

    func ingress(callbackAt: Double, mainAdmittedAt: Double, rearmedAt: Double, fullChunk: Bool) {
        guard [callbackAt, mainAdmittedAt, rearmedAt].allSatisfy({ $0.isFinite && $0 >= 0 }),
              callbackAt <= mainAdmittedAt, mainAdmittedAt <= rearmedAt,
              rearmedAt - callbackAt <= 60 else { return }
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        ingressCallbacks = min(9_000_000_000_000, ingressCallbacks + 1)
        if fullChunk { fullChunkCallbacks = min(9_000_000_000_000, fullChunkCallbacks + 1) }
        callbackToMain.append(Sample(at: rearmedAt, value: (mainAdmittedAt - callbackAt) * 1000))
        callbackToRearm.append(Sample(at: rearmedAt, value: (rearmedAt - callbackAt) * 1000))
    }

    func drained(_ frame: FrameTiming?) {
        lock.lock(); defer { lock.unlock() }
        let now = uptime()
        guard active, let frame, frame.generation == generation,
              now.isFinite, now >= frame.admittedAt, now - frame.admittedAt <= 60 else { return }
        admissionToDrain.append(Sample(at: now, value: (now - frame.admittedAt) * 1000))
    }

    func enqueued(_ frame: FrameTiming? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        enqueuedFrames = min(9_000_000_000_000, enqueuedFrames + 1)
        let now = uptime()
        guard let frame, frame.generation == generation,
              now.isFinite, now >= frame.admittedAt, now - frame.admittedAt <= 60 else { return }
        admissionToEnqueue.append(Sample(at: now, value: (now - frame.admittedAt) * 1000))
        if let residual = frame.sourceRelativeSeconds, frame.sourceSegment == sourceSegment {
            sourceResidual.append(Sample(at: now,
                value: residual + now - frame.admittedAt, segment: frame.sourceSegment))
        }
    }

    func dropped(_ count: Int = 1) {
        guard count > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        droppedFrames = min(9_000_000_000_000, droppedFrames + min(9_000_000_000_000, Int64(count)))
    }

    func requestedRecovery() {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        recoveryRequests = min(9_000_000_000_000, recoveryRequests + 1)
    }

    func beginPerformanceCollection() -> UUID? {
        lock.lock(); defer { lock.unlock() }
        guard active, inFlight == nil else { return nil }
        let token = UUID(); inFlight = (token, generation); return token
    }

    func completePerformanceCollection(requestToken token: UUID, sample: AVSample?) {
        lock.lock(); defer { lock.unlock() }
        guard let request = inFlight, request.token == token else { return }
        inFlight = nil
        guard active, generation == request.generation else { return }
        let now = uptime()
        guard let sample, now.isFinite, now >= 0,
              [sample.total, sample.dropped, sample.corrupted, sample.optimized].allSatisfy(PeelStreamMetricBounds.counter),
              sample.dropped <= sample.total, sample.optimized <= sample.total,
              PeelStreamMetricBounds.time(sample.accumulatedDelay) else { observation = nil; return }
        var interval: Double?, fps: Double?
        if let previous = observation {
            let duration = now - previous.at
            let totalDelta = sample.total - previous.sample.total
            let droppedDelta = sample.dropped - previous.sample.dropped
            if (1...60).contains(duration), totalDelta >= 0, droppedDelta >= 0,
               sample.corrupted >= previous.sample.corrupted, sample.optimized >= previous.sample.optimized,
               droppedDelta <= totalDelta, sample.accumulatedDelay >= previous.sample.accumulatedDelay {
                let estimate = Double(totalDelta - droppedDelta) / duration
                if estimate.isFinite, (0...1000).contains(estimate) { interval = duration; fps = estimate }
            }
        }
        observation = Observation(sample: sample, at: now, interval: interval, estimatedFPS: fps)
    }

    private func timingSnapshot(now: Double) -> PeelReceiverTimingMetric {
        let main = callbackToMain.recent(at: now), rearm = callbackToRearm.recent(at: now)
        let drain = admissionToDrain.recent(at: now), enqueue = admissionToEnqueue.recent(at: now)
        let source = sourceResidual.recent(at: now).filter { $0.segment == sourceSegment }
        func distribution(_ values: [Double]) -> PeelLatencyDistribution? {
            guard !values.isEmpty, values.allSatisfy({ $0.isFinite && (0...60_000).contains($0) }) else { return nil }
            let sorted = values.sorted()
            func percentile(_ p: Double) -> Double { sorted[max(0, Int(ceil(Double(sorted.count) * p)) - 1)] }
            return PeelLatencyDistribution(sampleCount: sorted.count, p50Milliseconds: percentile(0.5),
                p95Milliseconds: percentile(0.95), maximumMilliseconds: sorted.last!)
        }
        // Recompute the minimum over current five-second samples. When that
        // minimum ages out, the reference shifts; never compare across windows
        // as an absolute delay. At least two distinct enqueue times are needed.
        let span = source.map(\.at).max().flatMap { last in source.map(\.at).min().map { last - $0 } }
        let hasRelative = source.count >= 2 && (span ?? 0) > 0
        let minimum = source.map(\.value).min() ?? 0
        let excess = hasRelative ? distribution(source.map { max(0, $0.value - minimum) * 1000 }) : nil
        return PeelReceiverTimingMetric(measurementKind: "sourcePTSRelativeMinimum",
            measurementWindowSeconds: min(5, max(0, now - startedAt)), timingSampleCapacity: Ring.capacity,
            sampleWindowTruncated: [main.count, rearm.count, drain.count, enqueue.count, source.count].contains(Ring.capacity),
            callbackToMainAdmission: distribution(main.map(\.value)), callbackToReceiveRearm: distribution(rearm.map(\.value)),
            frameAdmissionToRendererDrain: distribution(drain.map(\.value)), frameAdmissionToDisplayEnqueue: distribution(enqueue.map(\.value)),
            sourcePTSRelativeEnqueueExcess: excess, sourcePTSAvailability: excess == nil ? .unavailable : .relativeMinimum,
            sourcePTSWindowSpanMilliseconds: excess == nil ? nil : span.map { $0 * 1000 },
            assumedRelativeClockDriftPPM: 100,
            sourcePTSRelativeDriftAllowanceMilliseconds: excess == nil ? nil : span.map { $0 * 1000 * 0.0001 },
            ingressCallbacks: ingressCallbacks, fullChunkCallbacks: fullChunkCallbacks,
            sourcePTSMissingFrames: sourcePTSMissingFrames, sourcePTSDiscontinuities: sourcePTSDiscontinuities,
            physicalPresentationMeasured: false)
    }

    func snapshot(windowId: UInt32, queuedFrames: Int, queuedBytes: Int,
                  oldestQueuedAgeMilliseconds: Double?, displayLayerStatus: Int,
                  displayLayerRequiresFlush: Bool, displayLayerErrorCode: Int?) -> PeelClientStreamMetric? {
        lock.lock(); defer { lock.unlock() }
        guard active else { return nil }
        let now = uptime()
        guard now.isFinite, now >= startedAt else { return nil }
        let performance: PeelAVPerformanceMetric?
        if let observation, now >= observation.at {
            let age = now - observation.at
            performance = PeelAVPerformanceMetric(totalFrames: observation.sample.total,
                droppedFrames: observation.sample.dropped, corruptedFrames: observation.sample.corrupted,
                optimizedCompositingFrames: observation.sample.optimized,
                accumulatedFrameDelaySeconds: observation.sample.accumulatedDelay,
                sampleAgeMilliseconds: age * 1000, intervalSeconds: age <= 5 ? observation.interval : nil,
                estimatedPresentedFPS: age <= 5 ? observation.estimatedFPS : nil)
        } else { performance = nil }
        var row = PeelClientStreamMetric(windowId: windowId, rendererGeneration: generation,
            rendererKind: .displayLayer, width: width, height: height,
            receivedFrames: receivedFrames, receivedBytes: receivedBytes, enqueuedFrames: enqueuedFrames,
            applicationDroppedFrames: droppedFrames, recoveryRequests: recoveryRequests,
            queuedFrames: queuedFrames, queuedBytes: queuedBytes,
            oldestQueuedFrameAgeMilliseconds: oldestQueuedAgeMilliseconds,
            lastReceivedFrameAgeMilliseconds: lastReceivedAt.flatMap { now >= $0 ? (now - $0) * 1000 : nil },
            screenMaximumFPS: nil, displayLayerStatus: displayLayerStatus,
            displayLayerRequiresFlush: displayLayerRequiresFlush, displayLayerErrorCode: displayLayerErrorCode,
            avPerformance: performance)
        row.receiverTiming = timingSnapshot(now: now)
        return row.isValid ? row : nil
    }
}
