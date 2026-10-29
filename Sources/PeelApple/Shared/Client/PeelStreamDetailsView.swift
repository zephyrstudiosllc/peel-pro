import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Reads the same bounded receiver observations sent to the paired Host. Opening
/// this view never starts another performance request or changes stream policy.
/// A Debug-only experiment requires a separate explicit button press.
struct PeelStreamDetailsView: View {
    let snapshot: () -> PeelClientStreamMetric?
    let requestNativeExperiment: (() -> Void)?

    init(requestNativeExperiment: (() -> Void)? = nil,
         snapshot: @escaping () -> PeelClientStreamMetric?) {
        self.requestNativeExperiment = requestNativeExperiment
        self.snapshot = snapshot
    }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var receipt: PeelStreamDetailsReceipt?
    @State private var observationSessionID = UUID()
    @State private var copiedDiagnostics = false

    private var metric: PeelClientStreamMetric? { receipt?.metric }

    private var diagnosticAccessibilityValue: String {
#if DEBUG
        if ProcessInfo.processInfo.environment["PEEL_STREAM_DIAGNOSTICS_UI_FIXTURE"] == "1" {
            return receipt?.jsonString ?? "Unavailable"
        }
#endif
        return copiedDiagnostics ? "Copied" : "Content-free receiver measurements"
    }

    var body: some View {
        NavigationStack {
            List {
#if DEBUG
                if let requestNativeExperiment {
                    Section {
                        Button("Run 30-second native-resolution experiment") {
                            requestNativeExperiment()
                            dismiss()
                        }
                        .accessibilityIdentifier("peel.streamDetails.nativeExperiment")
                    } footer: {
                        Text("Requests the selected refresh target on this display stream. The Host may use a lower setting. Inspect actual resolution and presentation measurements; a requested target is not delivered performance.")
                    }
                }
#endif
                if let metric {
                    Section("Video") {
                        detail("Resolution", "\(metric.width) × \(metric.height)", id: "resolution")
                        detail("Received frames", metric.receivedFrames.formatted(), id: "receivedFrames")
                        detail("Last frame received", milliseconds(metric.lastReceivedFrameAgeMilliseconds), id: "lastReceivedAge")
                    }
                    if let spatial = metric.spatialPipeline {
                        Section {
                            detail("Published frames", spatial.publishedFrames.formatted(), id: "spatialPublishedFrames")
                            detail("Publication rate", spatial.publishedFPS.map { String(format: "%.1f fps", $0) } ?? "Unavailable", id: "spatialPublishedFPS")
                            detail("Decode p95", milliseconds(spatial.receiveToDecode?.p95Milliseconds), id: "spatialDecodeP95")
                            detail("Image conversion p95", milliseconds(spatial.imageConversion?.p95Milliseconds), id: "spatialConversionP95")
                            detail("Receive to publication max", milliseconds(spatial.receiveToPublication?.maximumMilliseconds), id: "spatialPublicationMax")
                            detail("Source to publication upper bound", milliseconds(spatial.sourcePTSToPublicationUpperBound?.maximumMilliseconds), id: "spatialSourceUpperBound")
                            detail("Source clock verified", spatial.sourceTimebaseVerified ? "Yes" : "No", id: "spatialSourceClock")
                            detail("Clock uncertainty", milliseconds(spatial.clockUncertaintyMilliseconds), id: "spatialClockUncertainty")
                        } header: {
                            Text("Spatial pipeline")
                        } footer: {
                            Text("Publication ends when the app updates its image. The system compositor and physical display follow afterward. These values cannot certify input-to-photon latency.")
                        }
                    }
                    if let quality = metric.displayedFixtureQuality ?? metric.spatialPipeline?.fixtureQuality {
                        Section {
                            detail("Fixture matched", quality.markerMatched ? "Yes" : "No", id: "fixtureMatched")
                            detail("Luma PSNR", quality.exactMatch ? "Exact" : quality.lumaPSNRDecibels.map { String(format: "%.1f dB", $0) } ?? "Unavailable", id: "fixtureLumaPSNR")
                            detail("RGB PSNR", quality.exactMatch ? "Exact" : quality.rgbPSNRDecibels.map { String(format: "%.1f dB", $0) } ?? "Unavailable", id: "fixtureRGBPSNR")
                            detail("Source to image observation", milliseconds(quality.sourceToObservationUpperBoundMilliseconds), id: "fixtureObservationUpperBound")
                        } header: {
                            Text("Native quality fixture")
                        } footer: {
                            Text("A sampled native-scale comparison against the known test pattern. Image observation is separate from physical display timing.")
                        }
                    }
                    Section {
                        detail("Presentation estimate", metric.avPerformance?.estimatedPresentedFPS.map { String(format: "%.1f fps", $0) } ?? "Unavailable", id: "presentationFPS")
                        detail("Screen maximum", metric.screenMaximumFPS.map { "\($0) fps" } ?? "Unavailable", id: "screenMaximumFPS")
                        detail("Queued frames", metric.queuedFrames.map { $0.formatted() } ?? "Unavailable", id: "queuedFrames")
                        detail("Oldest queued frame", milliseconds(metric.oldestQueuedFrameAgeMilliseconds), id: "queueAge")
                    } header: {
                        Text("Display")
                    } footer: {
                        Text(metric.rendererKind == .spatialUninstrumented
                            ? "Display measurements are unavailable for the spatial view."
                            : "The presentation estimate comes from the video renderer. The screen maximum is a capability, not delivered frame rate. A still image may produce few new frames.")
                    }
                    Section {
                        detail("Decoder state", decoderState(metric), id: "decoderState")
                        detail("Decoder error", metric.rendererKind == .spatialUninstrumented ? "Unavailable" : metric.displayLayerErrorCode.map { String($0) } ?? "None reported", id: "decoderError")
                        detail("Client frame drops", metric.applicationDroppedFrames.map { $0.formatted() } ?? "Unavailable", id: "clientDrops")
                        detail("Decoder frame drops", PeelStreamDetailsFormatting.decoderDrops(metric.avPerformance), id: "decoderDrops")
                        detail("Recovery requests", metric.recoveryRequests.map { $0.formatted() } ?? "Unavailable", id: "recoveryRequests")
                    } header: {
                        Text("Recovery")
                    } footer: {
                        Text("Counts cover this video session and can reset when the stream changes. These measurements do not measure input response time.")
                    }
                } else {
                    ContentUnavailableView("Waiting for video", systemImage: "video",
                        description: Text("Stream details appear when this device receives video from the connected computer."))
                }
            }
            .navigationTitle("Stream Details")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(copiedDiagnostics ? "Copied Diagnostics" : "Copy Diagnostics", systemImage: "doc.on.doc") {
                        guard let json = receipt?.jsonString else { return }
#if canImport(UIKit)
                        UIPasteboard.general.string = json
                        copiedDiagnostics = true
#endif
                    }
                    .disabled(receipt == nil)
                    .accessibilityIdentifier("peel.streamDetails.copyDiagnostics")
                    .accessibilityValue(diagnosticAccessibilityValue)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("peel.streamDetails.done")
                }
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { receipt = nil; return }
                while !Task.isCancelled {
                    let startedAt = ProcessInfo.processInfo.systemUptime
                    let sample = snapshot()
                    receipt = PeelStreamDetailsReceipt(observationSessionID: observationSessionID,
                        samplingStartedAtClientUptimeSeconds: startedAt,
                        samplingCompletedAtClientUptimeSeconds: ProcessInfo.processInfo.systemUptime,
                        metric: sample)
                    do { try await Task.sleep(for: .seconds(1)) }
                    catch { return }
                }
            }
        }
    }

    private func detail(_ title: String, _ value: String, id: String) -> some View {
        LabeledContent(title, value: value)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(value)
            .accessibilityIdentifier("peel.streamDetails.\(id)")
    }

    private func milliseconds(_ value: Double?) -> String {
        guard let value else { return "Unavailable" }
        if value >= 1000 { return String(format: "%.1f s", value / 1000) }
        return String(format: "%.0f ms", value)
    }

    private func decoderState(_ metric: PeelClientStreamMetric) -> String {
        if metric.displayLayerRequiresFlush == true { return "Needs recovery" }
        switch metric.displayLayerStatus {
        case 0: return "Waiting"
        case 1: return "Rendering"
        case 2: return "Needs recovery"
        default: return "Unavailable"
        }
    }
}

nonisolated enum PeelStreamDetailsFormatting {
    static func decoderDrops(_ performance: PeelAVPerformanceMetric?) -> String {
        // The collector retains raw AV counters after an async request stalls.
        // Match its five-second presentation-estimate freshness window so an
        // old zero is never presented as a current decoder-drop measurement.
        guard let performance, performance.isValid,
              performance.sampleAgeMilliseconds <= 5_000 else { return "Unavailable" }
        return performance.droppedFrames.formatted()
    }
}

/// One immutable observation; no names, content, endpoints or input are included.
/// The sampling interval bounds the renderer read. Queue state and AV statistics
/// have their own acquisition/freshness bounds; this is not a scanout measurement.
nonisolated struct PeelStreamDetailsReceipt: Codable, Equatable, Sendable {
    let version: Int
    let observationSessionID: UUID
    let samplingStartedAtClientUptimeSeconds: Double
    let samplingCompletedAtClientUptimeSeconds: Double
    let metric: PeelClientStreamMetric

    init?(observationSessionID: UUID, samplingStartedAtClientUptimeSeconds: Double,
          samplingCompletedAtClientUptimeSeconds: Double, metric: PeelClientStreamMetric?) {
        guard let metric, metric.isValid,
              PeelStreamMetricBounds.time(samplingStartedAtClientUptimeSeconds),
              PeelStreamMetricBounds.time(samplingCompletedAtClientUptimeSeconds),
              samplingCompletedAtClientUptimeSeconds >= samplingStartedAtClientUptimeSeconds else { return nil }
        version = 1
        self.observationSessionID = observationSessionID
        self.samplingStartedAtClientUptimeSeconds = samplingStartedAtClientUptimeSeconds
        self.samplingCompletedAtClientUptimeSeconds = samplingCompletedAtClientUptimeSeconds
        self.metric = metric
    }

    var jsonString: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    struct CounterDelta: Codable, Equatable, Sendable {
        let minimumIntervalSeconds: Double
        let maximumIntervalSeconds: Double
        let receivedFrames: Int64
        let receivedBytes: Int64
        let enqueuedFrames: Int64?
        let applicationDroppedFrames: Int64?
        let recoveryRequests: Int64?
    }

    /// A changed generation, identity, overlapping interval or decreased counter
    /// is a boundary, never a usable rate interval. AV counters are not mixed in.
    func counterDelta(since previous: Self) -> CounterDelta? {
        guard version == 1, previous.version == 1,
              observationSessionID == previous.observationSessionID,
              metric.isValid, previous.metric.isValid,
              metric.windowId == previous.metric.windowId,
              metric.rendererGeneration == previous.metric.rendererGeneration,
              metric.rendererKind == previous.metric.rendererKind,
              metric.width == previous.metric.width, metric.height == previous.metric.height,
              PeelStreamMetricBounds.time(samplingStartedAtClientUptimeSeconds),
              PeelStreamMetricBounds.time(samplingCompletedAtClientUptimeSeconds),
              PeelStreamMetricBounds.time(previous.samplingStartedAtClientUptimeSeconds),
              PeelStreamMetricBounds.time(previous.samplingCompletedAtClientUptimeSeconds),
              samplingCompletedAtClientUptimeSeconds >= samplingStartedAtClientUptimeSeconds,
              previous.samplingCompletedAtClientUptimeSeconds >= previous.samplingStartedAtClientUptimeSeconds,
              samplingStartedAtClientUptimeSeconds > previous.samplingCompletedAtClientUptimeSeconds else { return nil }
        let counters = [(metric.receivedFrames, previous.metric.receivedFrames),
                        (metric.receivedBytes, previous.metric.receivedBytes)]
        guard counters.allSatisfy({ $0.0 >= $0.1 }) else { return nil }
        let optionalCounters = [(metric.enqueuedFrames, previous.metric.enqueuedFrames),
                                (metric.applicationDroppedFrames, previous.metric.applicationDroppedFrames),
                                (metric.recoveryRequests, previous.metric.recoveryRequests)]
        guard optionalCounters.allSatisfy({ current, prior in
            switch (current, prior) {
            case (nil, nil): return true
            case let (current?, prior?): return current >= prior
            default: return false
            }
        }) else { return nil }
        func difference(_ current: Int64?, _ prior: Int64?) -> Int64? {
            guard let current, let prior else { return nil }
            return current - prior
        }
        return CounterDelta(
            minimumIntervalSeconds: samplingStartedAtClientUptimeSeconds - previous.samplingCompletedAtClientUptimeSeconds,
            maximumIntervalSeconds: samplingCompletedAtClientUptimeSeconds - previous.samplingStartedAtClientUptimeSeconds,
            receivedFrames: metric.receivedFrames - previous.metric.receivedFrames,
            receivedBytes: metric.receivedBytes - previous.metric.receivedBytes,
            enqueuedFrames: difference(metric.enqueuedFrames, previous.metric.enqueuedFrames),
            applicationDroppedFrames: difference(metric.applicationDroppedFrames, previous.metric.applicationDroppedFrames),
            recoveryRequests: difference(metric.recoveryRequests, previous.metric.recoveryRequests))
    }
}
