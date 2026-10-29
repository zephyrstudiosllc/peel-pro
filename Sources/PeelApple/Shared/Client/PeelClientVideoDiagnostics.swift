import Foundation

/// NTP-style bounds do not assume symmetric network delay. One outstanding
/// probe and five recent observations bound memory and stale-session replies.
nonisolated final class PeelStreamClockTracker: @unchecked Sendable {
    struct Estimate {
        let lowerOffset: Double
        let upperOffset: Double
        let roundTrip: Double
        let probeStartedAt: Double
        let receivedAt: Double
        let verifiedWindows: Set<UInt32>

        struct OffsetBounds {
            let lower: Double
            let upper: Double
            var uncertaintyMilliseconds: Double { (upper - lower) * 1000 }
        }

        /// Conditional on relative clock drift of at most 100 ppm. Widen from
        /// probe send, including acquisition, rather than only from reply receipt.
        /// The sender must bracket its media-clock sample inside its two stamps.
        func offsetBounds(at now: Double) -> OffsetBounds? {
            guard now.isFinite, now >= receivedAt, now - receivedAt <= 10,
                  probeStartedAt.isFinite, now >= probeStartedAt else { return nil }
            let drift = (now - probeStartedAt) * 0.0001
            let lower = lowerOffset - drift, upper = upperOffset + drift
            guard lower.isFinite, upper.isFinite, lower <= upper else { return nil }
            return OffsetBounds(lower: lower, upper: upper)
        }

        func sourceAgeUpperBoundMilliseconds(sourceHostMediaSeconds source: Double,
                                              at now: Double) -> Double? {
            guard source.isFinite, let bounds = offsetBounds(at: now) else { return nil }
            let upper = (now - source + bounds.upper) * 1000
            return upper.isFinite && (0...60_000).contains(upper) ? upper : nil
        }
    }
    private let lock = NSLock()
    private var pending: PeelStreamClockProbe?
    private var estimates: [Estimate] = []

    func reset() {
        lock.lock(); defer { lock.unlock() }
        pending = nil; estimates.removeAll()
    }

    func makeProbe(now: Double = ProcessInfo.processInfo.systemUptime) -> PeelStreamClockProbe {
        lock.lock(); defer { lock.unlock() }
        let probe = PeelStreamClockProbe(id: UUID(), clientSent: now)
        pending = probe
        return probe
    }

    @discardableResult
    func accept(_ reply: PeelStreamClockReply, receivedAt: Double) -> Bool {
        guard reply.isValid, receivedAt.isFinite else { return false }
        lock.lock(); defer { lock.unlock() }
        guard pending == reply.probe else { return false }
        pending = nil
        let elapsed = receivedAt - reply.probe.clientSent
        let roundTrip = elapsed - (reply.hostSent - reply.hostReceived)
        guard elapsed >= 0, elapsed <= 2, roundTrip >= 0, roundTrip <= 2 else { return false }
        let delta = reply.hostMediaClockMinusUptime
        // Delta is mediaSample - hostReceived. The media read is bracketed by
        // hostReceived/hostSent, so its bridge is [delta - processing, delta].
        // Do not assume the media read and either uptime read were simultaneous.
        let bridgeSpan = reply.hostSent - reply.hostReceived
        estimates.removeAll { receivedAt - $0.receivedAt > 10 }
        estimates.append(Estimate(lowerOffset: reply.hostSent - receivedAt + delta - bridgeSpan,
            upperOffset: reply.hostReceived - reply.probe.clientSent + delta,
            roundTrip: roundTrip, probeStartedAt: reply.probe.clientSent, receivedAt: receivedAt,
            verifiedWindows: Set(reply.verifiedSourceWindowIds ?? [])))
        if estimates.count > 5 { estimates.removeFirst() }
        return true
    }

    func estimate(now: Double = ProcessInfo.processInfo.systemUptime) -> Estimate? {
        lock.lock(); defer { lock.unlock() }
        return estimates.filter { now >= $0.receivedAt && now - $0.receivedAt <= 10 }
            .min { $0.roundTrip < $1.roundTrip }
    }
}

/// Fixed-size stage samples contain timings only. No frame pixels are retained.
nonisolated final class PeelSpatialVideoDiagnostics: @unchecked Sendable {
    struct Frame {
        let receivedAt: Double
        let sourcePTSSeconds: Double?
        let decodedAt: Double
    }
    private struct Sample {
        let at: Double
        let decode: Double?
        let conversion: Double?
        let publication: Double?
        let sourceUpper: Double?
        let sourceVerified: Bool
        let clockUncertainty: Double?
        let clockReceivedAt: Double?
        let clockRoundTrip: Double?
    }
    private let lock = NSLock()
    private var generation = UUID()
    private var width = 0
    private var height = 0
    private var startedAt: Double = 0
    private var decoded: Int64 = 0
    private var published: Int64 = 0
    private var replaced: Int64 = 0
    private var failures: Int64 = 0
    private var samples = [Sample?](repeating: nil, count: 1024)
    private var next = 0
    private var decodedTimes = [Double?](repeating: nil, count: 1024)
    private var nextDecoded = 0

    func configure(width: Int, height: Int, now: Double = ProcessInfo.processInfo.systemUptime) -> UUID {
        lock.lock(); defer { lock.unlock() }
        generation = UUID(); self.width = width; self.height = height; startedAt = now
        decoded = 0; published = 0; replaced = 0; failures = 0
        samples = [Sample?](repeating: nil, count: 1024); next = 0
        decodedTimes = [Double?](repeating: nil, count: 1024); nextDecoded = 0
        return generation
    }

    func decoded(generation: UUID, failed: Bool = false, replaced: Bool = false,
                 now: Double = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        guard self.generation == generation else { return }
        if failed { failures += 1 } else {
            decoded += 1; decodedTimes[nextDecoded] = now
            nextDecoded = (nextDecoded + 1) % decodedTimes.count
        }
        if replaced { self.replaced += 1 }
    }

    func published(generation: UUID, frame: Frame, conversionMilliseconds: Double,
                   windowId: UInt32, clock: PeelStreamClockTracker.Estimate?,
                   now: Double = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        guard self.generation == generation, now >= frame.decodedAt,
              frame.decodedAt >= frame.receivedAt else { return }
        published += 1
        var sourceUpper: Double?
        var verified = false
        var usedBounds: PeelStreamClockTracker.Estimate.OffsetBounds?
        if let clock, let pts = frame.sourcePTSSeconds,
           let upper = clock.sourceAgeUpperBoundMilliseconds(sourceHostMediaSeconds: pts, at: now) {
            sourceUpper = upper; verified = clock.verifiedWindows.contains(windowId)
            usedBounds = clock.offsetBounds(at: now)
        }
        samples[next] = Sample(at: now, decode: (frame.decodedAt - frame.receivedAt) * 1000,
            conversion: conversionMilliseconds, publication: (now - frame.receivedAt) * 1000,
            sourceUpper: sourceUpper, sourceVerified: verified,
            clockUncertainty: usedBounds?.uncertaintyMilliseconds,
            clockReceivedAt: usedBounds == nil ? nil : clock?.receivedAt,
            clockRoundTrip: usedBounds == nil ? nil : clock.map { $0.roundTrip * 1000 })
        next = (next + 1) % samples.count
    }

    func snapshot(clock: PeelStreamClockTracker.Estimate?,
                  now: Double = ProcessInfo.processInfo.systemUptime) -> PeelSpatialPipelineMetric {
        lock.lock(); defer { lock.unlock() }
        let recent = samples.compactMap { $0 }.filter { $0.at <= now && $0.at > now - 5 }
        func distribution(_ values: [Double]) -> PeelLatencyDistribution? {
            let sorted = values.filter { $0.isFinite && (0...60_000).contains($0) }.sorted()
            guard !sorted.isEmpty else { return nil }
            func percentile(_ value: Double) -> Double {
                sorted[max(0, Int(ceil(Double(sorted.count) * value)) - 1)]
            }
            return PeelLatencyDistribution(sampleCount: sorted.count, p50Milliseconds: percentile(0.5),
                p95Milliseconds: percentile(0.95), maximumMilliseconds: sorted.last!)
        }
        let interval = min(5, max(0, now - startedAt))
        let recentDecoded = decodedTimes.compactMap { $0 }.filter { $0 <= now && $0 > now - 5 }
        let clockAge = clock.map { max(0, now - $0.receivedAt) }
        let bounds = clock?.offsetBounds(at: now)
        // A newer, narrower probe must not understate uncertainty of older
        // samples still present in the five-second distribution.
        let uncertainty = (recent.compactMap(\.clockUncertainty) + [bounds?.uncertaintyMilliseconds].compactMap { $0 }).max()
        let sampleClockAge = recent.compactMap { sample in
            sample.clockReceivedAt.map { max(0, now - $0) * 1000 }
        }
        let maximumClockAge = (sampleClockAge + [clockAge.map { $0 * 1000 }].compactMap { $0 }).max()
        let maximumRoundTrip = (recent.compactMap(\.clockRoundTrip) + [clock.map { $0.roundTrip * 1000 }].compactMap { $0 }).max()
        return PeelSpatialPipelineMetric(decodedFrames: decoded, publishedFrames: published,
            replacedDecodedFrames: replaced, decodeFailures: failures, measurementWindowSeconds: interval,
            decodedFPS: interval >= 1 && recentDecoded.count < decodedTimes.count ? Double(recentDecoded.count) / interval : nil,
            publishedFPS: interval >= 1 && recent.count < samples.count ? Double(recent.count) / interval : nil,
            receiveToDecode: distribution(recent.compactMap(\.decode)),
            imageConversion: distribution(recent.compactMap(\.conversion)),
            receiveToPublication: distribution(recent.compactMap(\.publication)),
            sourcePTSToPublicationUpperBound: distribution(recent.compactMap(\.sourceUpper)),
            clockRoundTripMilliseconds: maximumRoundTrip,
            clockUncertaintyMilliseconds: uncertainty,
            clockSampleAgeMilliseconds: maximumClockAge,
            sourceTimebaseVerified: !recent.isEmpty && recent.allSatisfy { $0.sourceVerified },
            physicalPresentationMeasured: false)
    }
}

/// One bounded record per renderer. No pixel data or input contents are kept.
nonisolated final class PeelClientVideoDiagnostics: @unchecked Sendable {
    struct AVSample: Sendable {
        let total: Int64
        let dropped: Int64
        let corrupted: Int64
        let optimized: Int64
        let accumulatedDelay: Double
    }
    private struct Observation {
        let sample: AVSample
        let uptime: Double
        let interval: Double?
        let presentedFPS: Double?
    }
    private let lock = NSLock()
    private let uptime: @Sendable () -> Double
    private var generation = UUID()
    private var active = false
    private var width = 0
    private var height = 0
    private var receivedFrames: Int64 = 0
    private var receivedBytes: Int64 = 0
    private var enqueuedFrames: Int64 = 0
    private var droppedFrames: Int64 = 0
    private var recoveryRequests: Int64 = 0
    private var lastReceivedAt: Double?
    private var observation: Observation?
    private var inFlight: (token: UUID, rendererGeneration: UUID)?

    init(uptime: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.uptime = uptime
    }

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }; return active
    }

    func configure(width: Int, height: Int) {
        lock.lock(); defer { lock.unlock() }
        generation = UUID(); active = true
        self.width = width; self.height = height
        receivedFrames = 0; receivedBytes = 0; enqueuedFrames = 0
        droppedFrames = 0; recoveryRequests = 0; lastReceivedAt = nil
        observation = nil
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        generation = UUID(); active = false; observation = nil
    }

    /// Decoder flushes invalidate the AV baseline without losing receive totals.
    func resetPresentation() {
        lock.lock(); defer { lock.unlock() }
        generation = UUID(); observation = nil
    }

    func received(bytes: Int) {
        guard bytes >= 0 else { return }
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        receivedFrames += 1; receivedBytes += Int64(bytes); lastReceivedAt = uptime()
    }

    func enqueued() {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        enqueuedFrames += 1
    }

    func dropped(_ count: Int = 1) {
        guard count > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        droppedFrames += Int64(count)
    }

    func requestedRecovery() {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        recoveryRequests += 1
    }

    /// A missing callback cannot create an unbounded queue of metric requests.
    func beginPerformanceCollection() -> UUID? {
        lock.lock(); defer { lock.unlock() }
        guard active, inFlight == nil else { return nil }
        let token = UUID()
        inFlight = (token, generation)
        return token
    }

    func completePerformanceCollection(requestToken token: UUID, sample: AVSample?) {
        lock.lock(); defer { lock.unlock() }
        guard let request = inFlight, request.token == token else { return }
        inFlight = nil
        guard active, generation == request.rendererGeneration else { return }
        guard let sample,
              [sample.total, sample.dropped, sample.corrupted, sample.optimized].allSatisfy(PeelStreamMetricBounds.counter),
              sample.dropped <= sample.total, sample.optimized <= sample.total,
              PeelStreamMetricBounds.time(sample.accumulatedDelay) else {
            observation = nil
            return
        }
        let now = uptime()
        var interval: Double?
        var fps: Double?
        if let previous = observation {
            let duration = now - previous.uptime
            let totalDelta = sample.total - previous.sample.total
            let droppedDelta = sample.dropped - previous.sample.dropped
            if (1...60).contains(duration), totalDelta >= 0, droppedDelta >= 0,
               droppedDelta <= totalDelta, sample.accumulatedDelay >= previous.sample.accumulatedDelay {
                let estimate = Double(totalDelta - droppedDelta) / duration
                if estimate.isFinite, (0...1000).contains(estimate) {
                    interval = duration; fps = estimate
                }
            }
        }
        observation = Observation(sample: sample, uptime: now, interval: interval, presentedFPS: fps)
    }

    func snapshot(windowId: UInt32, rendererKind: PeelClientStreamMetric.RendererKind,
                  queuedFrames: Int, queuedBytes: Int, oldestQueuedAgeMilliseconds: Double?,
                  screenMaximumFPS: Int?, displayLayerStatus: Int? = nil,
                  displayLayerRequiresFlush: Bool? = nil, displayLayerErrorCode: Int? = nil) -> PeelClientStreamMetric? {
        lock.lock(); defer { lock.unlock() }
        guard active else { return nil }
        let now = uptime()
        let performance: PeelAVPerformanceMetric?
        if rendererKind == .displayLayer, let observation {
            let age = max(0, now - observation.uptime)
            performance = PeelAVPerformanceMetric(totalFrames: observation.sample.total,
                droppedFrames: observation.sample.dropped, corruptedFrames: observation.sample.corrupted,
                optimizedCompositingFrames: observation.sample.optimized,
                accumulatedFrameDelaySeconds: observation.sample.accumulatedDelay,
                sampleAgeMilliseconds: age * 1000,
                intervalSeconds: age <= 5 ? observation.interval : nil,
                estimatedPresentedFPS: age <= 5 ? observation.presentedFPS : nil)
        } else { performance = nil }
        let conventional = rendererKind == .displayLayer
        let row = PeelClientStreamMetric(windowId: windowId, rendererGeneration: generation,
            rendererKind: rendererKind, width: width, height: height,
            receivedFrames: receivedFrames, receivedBytes: receivedBytes,
            enqueuedFrames: conventional ? enqueuedFrames : nil, applicationDroppedFrames: conventional ? droppedFrames : nil,
            recoveryRequests: conventional ? recoveryRequests : nil, queuedFrames: conventional ? queuedFrames : nil,
            queuedBytes: conventional ? queuedBytes : nil,
            oldestQueuedFrameAgeMilliseconds: conventional ? oldestQueuedAgeMilliseconds : nil,
            lastReceivedFrameAgeMilliseconds: lastReceivedAt.map { max(0, now - $0) * 1000 },
            screenMaximumFPS: conventional ? screenMaximumFPS : nil,
            displayLayerStatus: conventional ? displayLayerStatus : nil,
            displayLayerRequiresFlush: conventional ? displayLayerRequiresFlush : nil,
            displayLayerErrorCode: conventional ? displayLayerErrorCode : nil, avPerformance: performance)
        return row.isValid ? row : nil
    }
}
