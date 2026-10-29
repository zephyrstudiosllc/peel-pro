import Foundation

/// Bounded peer observations. The caller must additionally verify the active
/// paired control socket; reported frame counts are not independent proof.
nonisolated final class PeelReceiverDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private let uptime: @Sendable () -> Double
    private var generation: UInt64?
    private var negotiated = false
    private var lastSequence: UInt64?
    private var receivedAt: Double?
    private var report: PeelClientStreamMetricsMessage?

    init(uptime: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.uptime = uptime
    }

    func setSession(generation: UInt64?, negotiated: Bool) {
        lock.lock(); defer { lock.unlock() }
        if self.generation != generation {
            lastSequence = nil; receivedAt = nil; report = nil
        }
        self.generation = generation; self.negotiated = negotiated && generation != nil
        // Repeated hello/capability updates do not create a new sequence space.
        if !self.negotiated { report = nil }
    }

    @discardableResult
    func accept(_ message: PeelClientStreamMetricsMessage, generation: UInt64) -> Bool {
        guard message.isValid else { return false }
        lock.lock(); defer { lock.unlock() }
        let now = uptime()
        guard negotiated, self.generation == generation,
              lastSequence.map({ message.sequence > $0 }) ?? true,
              receivedAt.map({ now - $0 >= 1 }) ?? true else { return false }
        report = message; lastSequence = message.sequence; receivedAt = now
        return true
    }

    /// Backgrounding removes cached healthy measurements, while retaining the
    /// connection's replay and cadence limits until its next fresh report.
    func clearObservation() {
        lock.lock(); defer { lock.unlock() }; report = nil
    }

    /// A paired peer's fresh active renderer is an admission signal, not proof
    /// that a person saw content. Spatial currently has no presentation signal.
    func agentControlRenderer(windowID: UInt32, generation: UInt64) -> (id: UUID?, reason: String) {
        lock.lock(); defer { lock.unlock() }
        guard negotiated, self.generation == generation, let report, let receivedAt,
              uptime() - receivedAt <= 6,
              let stream = report.streams.first(where: { $0.windowId == windowID }) else {
            return (nil, "A fresh receiving-window report is required. Keep the window open in Peel Pro.")
        }
        guard stream.rendererKind == .displayLayer else {
            return (nil, "This renderer has no presentation telemetry. Agent control is unavailable for spatial views.")
        }
        guard stream.receivedFrames > 0, (stream.enqueuedFrames ?? 0) > 0,
              (stream.lastReceivedFrameAgeMilliseconds ?? .infinity) <= 5000,
              stream.displayLayerStatus == 1, stream.displayLayerRequiresFlush != true,
              stream.displayLayerErrorCode == nil else {
            return (nil, "The receiving window is not reporting a healthy active display layer.")
        }
        return (stream.rendererGeneration, "Peer-reported active display layer; human viewing is not independently verified.")
    }

    func snapshot() -> PeelLocalAgentJSONValue {
        lock.lock()
        let enabled = negotiated
        let message = report
        let age = report == nil ? nil : receivedAt.map { max(0, uptime() - $0) }
        lock.unlock()
        let encoded = message.flatMap { try? JSONEncoder().encode($0) }
        let value = encoded.flatMap { try? JSONDecoder().decode(PeelLocalAgentJSONValue.self, from: $0) }
        return .object([
            "scope": .string("peer_reported_receiver"),
            "capabilityNegotiated": .bool(enabled),
            "reportAgeSeconds": age.map(PeelLocalAgentJSONValue.number) ?? .null,
            "stale": .bool(age.map { $0 > 10 } ?? true),
            "report": value ?? .null,
            "measurementNotes": .array([
                .string("Receiver counters are reported by the paired peer, not independently observed screen scanout."),
                .string("Renderer enqueue is separate from AVFoundation presentation estimates."),
                .string("Optional receiverTiming contains receiver-local queue intervals and source-PTS-relative excess above a recent minimum. Its 100ppm drift allowance is assumed, not verified; no absolute one-way or presentation latency follows."),
                .string("Spatial pipeline timing uses bounded clock probes when available; the full asymmetric delay interval is retained."),
                .string("Spatial publication is an application image update, not compositor scanout. Source timebase verification is reported separately."),
                .string("No physical input-to-photon measurement or pixel-quality score is inferred from stage timing or resolution.")
            ])
        ])
    }
}
