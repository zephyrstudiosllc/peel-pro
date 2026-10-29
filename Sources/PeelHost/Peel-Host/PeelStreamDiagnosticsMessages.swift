import Foundation

/// Optional, content-free receiver observations on the paired control channel.
/// Uptime values are local to the sender and cannot measure one-way latency.
nonisolated struct PeelClientStreamMetricsMessage: Codable, Equatable, Sendable {
    static let capability = "stream-diagnostics-v1"
    static let maximumStreams = 32
    static let maximumPayloadBytes = 64 * 1024

    let type: String
    let version: Int
    let sequence: UInt64
    let sampledAtClientUptimeSeconds: Double
    let untrackedRendererRegistrations: Int64
    let streams: [PeelClientStreamMetric]

    init(sequence: UInt64, sampledAtClientUptimeSeconds: Double, streams: [PeelClientStreamMetric],
         untrackedRendererRegistrations: Int64 = 0) {
        type = "clientStreamMetrics"; version = 1
        self.sequence = sequence; self.sampledAtClientUptimeSeconds = sampledAtClientUptimeSeconds
        self.streams = streams
        self.untrackedRendererRegistrations = untrackedRendererRegistrations
    }

    var isValid: Bool {
        type == "clientStreamMetrics" && version == 1 && sequence > 0 && sequence <= UInt64(Int64.max) &&
        PeelStreamMetricBounds.time(sampledAtClientUptimeSeconds) &&
        PeelStreamMetricBounds.counter(untrackedRendererRegistrations) &&
        streams.count <= Self.maximumStreams &&
        Set(streams.map(\.windowId)).count == streams.count && streams.allSatisfy(\.isValid)
    }
}

nonisolated struct PeelClientStreamMetric: Codable, Equatable, Sendable {
    enum RendererKind: String, Codable, Sendable {
        case displayLayer
        case spatialUninstrumented
    }

    let windowId: UInt32
    let rendererGeneration: UUID
    let rendererKind: RendererKind
    let width: Int
    let height: Int
    let receivedFrames: Int64
    let receivedBytes: Int64
    let enqueuedFrames: Int64?
    let applicationDroppedFrames: Int64?
    let recoveryRequests: Int64?
    let queuedFrames: Int?
    let queuedBytes: Int?
    let oldestQueuedFrameAgeMilliseconds: Double?
    let lastReceivedFrameAgeMilliseconds: Double?
    let screenMaximumFPS: Int?
    let displayLayerStatus: Int?
    let displayLayerRequiresFlush: Bool?
    let displayLayerErrorCode: Int?
    let avPerformance: PeelAVPerformanceMetric?
    /// Optional for old peers. Publication is not compositor scanout.
    var receiverTiming: PeelReceiverTimingMetric? = nil
    var spatialPipeline: PeelSpatialPipelineMetric? = nil
    var displayedFixtureQuality: PeelFixtureQualityMetric? = nil

    var isValid: Bool {
        (1...16384).contains(width) && (1...16384).contains(height) &&
        [receivedFrames, receivedBytes, enqueuedFrames, applicationDroppedFrames, recoveryRequests]
            .compactMap { $0 }.allSatisfy(PeelStreamMetricBounds.counter) &&
        (queuedFrames.map { (0...256).contains($0) } ?? true) &&
        (queuedBytes.map { (0...128 * 1024 * 1024).contains($0) } ?? true) &&
        PeelStreamMetricBounds.optionalTime(oldestQueuedFrameAgeMilliseconds) &&
        PeelStreamMetricBounds.optionalTime(lastReceivedFrameAgeMilliseconds) &&
        (screenMaximumFPS.map { (1...1000).contains($0) } ?? true) &&
        (displayLayerStatus.map { (0...2).contains($0) } ?? true) &&
        (displayLayerErrorCode.map { (Int(Int32.min)...Int(Int32.max)).contains($0) } ?? true) &&
        (avPerformance?.isValid ?? true) &&
        (receiverTiming?.isValid ?? true) &&
        (spatialPipeline?.isValid ?? true) &&
        (displayedFixtureQuality?.isValid ?? true) &&
        (rendererKind != .spatialUninstrumented ||
            (avPerformance == nil && receiverTiming == nil && enqueuedFrames == nil && applicationDroppedFrames == nil &&
             recoveryRequests == nil && queuedFrames == nil && queuedBytes == nil &&
             oldestQueuedFrameAgeMilliseconds == nil && displayLayerStatus == nil &&
             displayLayerRequiresFlush == nil && displayLayerErrorCode == nil))
    }
}


/// Receiver-local intervals and a relative PTS residual, never one-way latency.
/// Excess is measured above the minimum in the recent contiguous PTS segment;
/// fixed capture/encode/network/display delay and compositor scanout are absent.
nonisolated struct PeelReceiverTimingMetric: Codable, Equatable, Sendable {
    enum SourcePTSAvailability: String, Codable, Sendable { case unavailable, relativeMinimum }
    let measurementKind: String
    let measurementWindowSeconds: Double
    let timingSampleCapacity: Int
    let sampleWindowTruncated: Bool
    let callbackToMainAdmission: PeelLatencyDistribution?
    let callbackToReceiveRearm: PeelLatencyDistribution?
    let frameAdmissionToRendererDrain: PeelLatencyDistribution?
    let frameAdmissionToDisplayEnqueue: PeelLatencyDistribution?
    let sourcePTSRelativeEnqueueExcess: PeelLatencyDistribution?
    let sourcePTSAvailability: SourcePTSAvailability
    let sourcePTSWindowSpanMilliseconds: Double?
    /// Conditional allowance only: no synchronization or drift verification occurs.
    let assumedRelativeClockDriftPPM: Int
    let sourcePTSRelativeDriftAllowanceMilliseconds: Double?
    let ingressCallbacks: Int64
    let fullChunkCallbacks: Int64
    let sourcePTSMissingFrames: Int64
    let sourcePTSDiscontinuities: Int64
    let physicalPresentationMeasured: Bool

    var isValid: Bool {
        measurementKind == "sourcePTSRelativeMinimum" && timingSampleCapacity == 1024 &&
        measurementWindowSeconds.isFinite && (0...5).contains(measurementWindowSeconds) &&
        [callbackToMainAdmission, callbackToReceiveRearm, frameAdmissionToRendererDrain,
         frameAdmissionToDisplayEnqueue, sourcePTSRelativeEnqueueExcess].compactMap { $0 }.allSatisfy(\.isValid) &&
        assumedRelativeClockDriftPPM == 100 &&
        [ingressCallbacks, fullChunkCallbacks, sourcePTSMissingFrames, sourcePTSDiscontinuities]
            .allSatisfy(PeelStreamMetricBounds.counter) && fullChunkCallbacks <= ingressCallbacks &&
        (sourcePTSWindowSpanMilliseconds.map { $0.isFinite && (0...5000).contains($0) } ?? true) &&
        (sourcePTSRelativeDriftAllowanceMilliseconds.map { $0.isFinite && (0...0.5).contains($0) } ?? true) &&
        relativeCoverageIsValid && !physicalPresentationMeasured
    }

    private var relativeCoverageIsValid: Bool {
        switch sourcePTSAvailability {
        case .unavailable:
            return sourcePTSRelativeEnqueueExcess == nil && sourcePTSWindowSpanMilliseconds == nil &&
                sourcePTSRelativeDriftAllowanceMilliseconds == nil
        case .relativeMinimum:
            guard let excess = sourcePTSRelativeEnqueueExcess, excess.sampleCount >= 2,
                  let span = sourcePTSWindowSpanMilliseconds, span > 0,
                  let allowance = sourcePTSRelativeDriftAllowanceMilliseconds else { return false }
            // This verifies the stated assumption's arithmetic, not real clock drift.
            return abs(allowance - span * 0.0001) <= 0.000000001
        }
    }
}

nonisolated struct PeelStreamClockProbe: Codable, Equatable, Sendable {
    let id: UUID
    let clientSent: Double
    var isValid: Bool { PeelStreamMetricBounds.time(clientSent) }
}

nonisolated struct PeelStreamClockReply: Codable, Equatable, Sendable {
    static let capability = "stream-clock-v1"
    let type: String
    let probe: PeelStreamClockProbe
    let hostReceived: Double
    let hostSent: Double
    /// Media-clock sample minus hostReceived; sample occurs inside the two Host
    /// uptime stamps. Its bridge offset is [value - (hostSent-hostReceived), value].
    let hostMediaClockMinusUptime: Double
    let verifiedSourceWindowIds: [UInt32]?
    var isValid: Bool {
        type == "hostStreamClock" && probe.isValid &&
        (verifiedSourceWindowIds.map { $0.count <= 32 && Set($0).count == $0.count } ?? true) &&
        PeelStreamMetricBounds.time(hostReceived) && PeelStreamMetricBounds.time(hostSent) &&
        hostSent >= hostReceived && hostSent - hostReceived <= 10 &&
        hostMediaClockMinusUptime.isFinite && abs(hostMediaClockMinusUptime) <= 86400
    }
}

nonisolated struct PeelLatencyDistribution: Codable, Equatable, Sendable {
    let sampleCount: Int
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let maximumMilliseconds: Double
    var isValid: Bool {
        (1...1024).contains(sampleCount) &&
        [p50Milliseconds, p95Milliseconds, maximumMilliseconds].allSatisfy {
            $0.isFinite && (0...60_000).contains($0)
        } && p50Milliseconds <= p95Milliseconds && p95Milliseconds <= maximumMilliseconds
    }
}

/// All durations end at application publication, before the system compositor.
/// Source PTS timing additionally assumes the SCK PTS uses the Host media clock.
nonisolated struct PeelSpatialPipelineMetric: Codable, Equatable, Sendable {
    let decodedFrames: Int64
    let publishedFrames: Int64
    let replacedDecodedFrames: Int64
    let decodeFailures: Int64
    let measurementWindowSeconds: Double
    let decodedFPS: Double?
    let publishedFPS: Double?
    let receiveToDecode: PeelLatencyDistribution?
    let imageConversion: PeelLatencyDistribution?
    let receiveToPublication: PeelLatencyDistribution?
    let sourcePTSToPublicationUpperBound: PeelLatencyDistribution?
    let clockRoundTripMilliseconds: Double?
    let clockUncertaintyMilliseconds: Double?
    let clockSampleAgeMilliseconds: Double?
    let sourceTimebaseVerified: Bool
    let physicalPresentationMeasured: Bool
    var decodedWidth: Int? = nil
    var decodedHeight: Int? = nil
    var decodedPixelFormat: UInt32? = nil
    var fixtureQuality: PeelFixtureQualityMetric? = nil

    var isValid: Bool {
        [decodedFrames, publishedFrames, replacedDecodedFrames, decodeFailures]
            .allSatisfy(PeelStreamMetricBounds.counter) &&
        measurementWindowSeconds.isFinite && (0...5).contains(measurementWindowSeconds) &&
        [decodedFPS, publishedFPS].compactMap { $0 }.allSatisfy {
            $0.isFinite && (0...1000).contains($0)
        } &&
        [receiveToDecode, imageConversion, receiveToPublication, sourcePTSToPublicationUpperBound]
            .compactMap { $0 }.allSatisfy(\.isValid) &&
        [clockRoundTripMilliseconds, clockUncertaintyMilliseconds, clockSampleAgeMilliseconds]
            .allSatisfy(PeelStreamMetricBounds.optionalTime) &&
        !physicalPresentationMeasured
        && (decodedWidth.map { (1...16384).contains($0) } ?? true)
        && (decodedHeight.map { (1...16384).contains($0) } ?? true)
        && (fixtureQuality?.isValid ?? true)
    }
}

nonisolated struct PeelFixtureQualityMetric: Codable, Equatable, Sendable {
    let fixtureID: String
    let sampledAtClientUptimeSeconds: Double
    let markerMatched: Bool
    let comparedPixels: Int
    let rgbPSNRDecibels: Double?
    let lumaPSNRDecibels: Double?
    let exactMatch: Bool
    var fixtureFrameSequence: UInt32? = nil
    var sourceHostMediaSeconds: Double? = nil
    var sourceToObservationUpperBoundMilliseconds: Double? = nil
    var clockUncertaintyMilliseconds: Double? = nil
    var observationStage: String? = nil
    var isValid: Bool {
        fixtureID == PeelQualityFixture.identifier &&
        PeelStreamMetricBounds.time(sampledAtClientUptimeSeconds) &&
        (0...32768).contains(comparedPixels) &&
        [rgbPSNRDecibels, lumaPSNRDecibels].compactMap { $0 }.allSatisfy {
            $0.isFinite && (-10...200).contains($0)
        } &&
        PeelStreamMetricBounds.optionalTime(sourceHostMediaSeconds) &&
        PeelStreamMetricBounds.optionalTime(sourceToObservationUpperBoundMilliseconds) &&
        PeelStreamMetricBounds.optionalTime(clockUncertaintyMilliseconds) &&
        (observationStage.map { ["spatialImageInspection", "displayLayerPixelObservation"].contains($0) } ?? true) &&
        (markerMatched || (comparedPixels == 0 && rgbPSNRDecibels == nil && lumaPSNRDecibels == nil && !exactMatch))
    }
}

/// Deterministic native-scale fixture. No production image content is used.
nonisolated enum PeelQualityFixture {
    static let identifier = "peel-5k-roi-v1"
    static let width = 5120
    static let height = 2880
    static let roiX = 2304
    static let roiY = 1408
    static let roiWidth = 512
    static let roiHeight = 64

    static func stampBytes(microseconds: UInt64, sequence: UInt32) -> [UInt8] {
        var bytes = (0..<8).map { UInt8(truncatingIfNeeded: microseconds >> ($0 * 8)) }
        bytes += (0..<4).map { UInt8(truncatingIfNeeded: sequence >> ($0 * 8)) }
        let checksum = bytes.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 }
        bytes += (0..<4).map { UInt8(truncatingIfNeeded: checksum >> ($0 * 8)) }
        return bytes
    }

    static func rgb(x: Int, y: Int) -> (Int, Int, Int) {
        if y < 32 || y >= height - 32 {
            let value = ((x / 16) ^ (x / 256)) & 1 == 0 ? 32 : 224
            return (value, value, value)
        }
        if (roiX..<roiX + roiWidth).contains(x), (roiY..<roiY + roiHeight).contains(y) {
            let local = x - roiX
            switch local / 128 {
            case 0: let value = local & 1 == 0 ? 16 : 240; return (value, value, value)
            case 1: return local & 1 == 0 ? (240, 16, 16) : (16, 16, 240)
            case 2: let value = (local % 128) * 2; return (value, value, value)
            default:
                let value = (local / 8) & 1 == 0 ? 48 : 208
                return (value, 255 - value, 96)
            }
        }
        return (16, 24, 32)
    }
}

/// Raw AVFoundation counts and a separately labelled delta estimate. This does
/// not certify scanout, content correctness, or capture/input-to-photon latency.
nonisolated struct PeelAVPerformanceMetric: Codable, Equatable, Sendable {
    let totalFrames: Int64
    let droppedFrames: Int64
    let corruptedFrames: Int64
    let optimizedCompositingFrames: Int64
    let accumulatedFrameDelaySeconds: Double
    let sampleAgeMilliseconds: Double
    let intervalSeconds: Double?
    let estimatedPresentedFPS: Double?

    var isValid: Bool {
        [totalFrames, droppedFrames, corruptedFrames, optimizedCompositingFrames]
            .allSatisfy(PeelStreamMetricBounds.counter) &&
        droppedFrames <= totalFrames && optimizedCompositingFrames <= totalFrames &&
        PeelStreamMetricBounds.time(accumulatedFrameDelaySeconds) &&
        PeelStreamMetricBounds.time(sampleAgeMilliseconds) &&
        (intervalSeconds.map { $0.isFinite && $0 > 0 && $0 <= 60 } ?? true) &&
        (estimatedPresentedFPS.map { $0.isFinite && (0...1000).contains($0) && intervalSeconds != nil } ?? true)
    }
}

nonisolated enum PeelStreamMetricBounds {
    static func counter(_ value: Int64) -> Bool { (0...9_000_000_000_000).contains(value) }
    static func time(_ value: Double) -> Bool { value.isFinite && (0...1_000_000_000_000).contains(value) }
    static func optionalTime(_ value: Double?) -> Bool { value.map(time) ?? true }
}
