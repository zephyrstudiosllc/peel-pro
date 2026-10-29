import Foundation
import AVFoundation
import CoreMedia
import QuartzCore

// Production renderer and collector are compiled by the runner. AV readiness and
// local uptime are deterministic stand-ins; CMSampleBuffer is real. No display,
// network, native input, hardware decode or presentation measurement takes place.
enum FixtureClock { static var now: TimeInterval = 0 }
private func peelRendererPerfNowMs() -> Double { FixtureClock.now * 1000 }
enum FixtureGravity { case resizeAspect }
enum FixtureStatus: Int { case unknown, rendering, failed }
final class FixtureDisplayLayer {
    var videoGravity = FixtureGravity.resizeAspect
    var backgroundColor: CGColor?
    var status = FixtureStatus.rendering
    var error: Error?
    var isReadyForMoreMediaData = false
    var requiresFlushToResumeDecoding = false
    var enqueueCount = 0
    var flushCount = 0
    var sampleBufferRenderer: FixtureDisplayLayer { self }
    func enqueue(_ sample: CMSampleBuffer) { enqueueCount += 1 }
    func flush() { flushCount += 1; status = .unknown; requiresFlushToResumeDecoding = false }
    func flushAndRemoveImage() { flush() }
    func removeFromSuperlayer() {}
    func loadVideoPerformanceMetrics(completionHandler: (FixturePerformance?) -> Void) { completionHandler(nil) }
}
struct FixturePerformance {
    let totalNumberOfFrames: Int
    let numberOfDroppedFrames: Int
    let numberOfCorruptedFrames: Int
    let numberOfFramesDisplayedUsingOptimizedCompositing: Int
    let totalAccumulatedFrameDelay: Double
}
enum PeelClientDiagnostics {
    static func logRendererEvent(label: String, windowId: UInt32?, reason: String,
                                 frameIndex: Int64? = nil, payloadByteCount: Int? = nil,
                                 status: String? = nil, interval: TimeInterval = 1) {}
    static func logRendererFrame(label: String, windowId: UInt32?, action: String,
                                 frameIndex: Int64, payloadByteCount: Int, isKeyframe: Bool,
                                 mainHopMs: Double?, displayReady: Bool, layerStatus: String) {}
}
// Packet shape only; these checks never exercise packet parsing/configuration.
enum PeelVideoCodec { case h264, hevc }
struct VideoConfigPacket {
    let windowId: UInt32
    let codec: PeelVideoCodec
    let width: UInt32
    let height: UInt32
    let timescale: UInt32
    let nalUnitHeaderLength: UInt8
    let sps: Data
    let pps: Data
    let vps: Data?
}
struct VideoFramePacket {
    let windowId: UInt32
    let isKeyframe: Bool
    let payload: Data
}

extension CompressedVideoRenderer {
    static func checkPendingRecovery() -> [String] {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
        var pixelBuffer: CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA,
                                       nil, &pixelBuffer) == noErr)
        var format: CMVideoFormatDescription?
        precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                      imageBuffer: pixelBuffer!, formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                      imageBuffer: pixelBuffer!, formatDescription: format!, sampleTiming: &timing,
                      sampleBufferOut: &sample) == noErr)

        func renderer(pendingAge: Double, ready: Bool = false) -> CompressedVideoRenderer {
            FixtureClock.now = pendingAge
            let value = CompressedVideoRenderer()
            value.streamingDiagnostics.configure(width: 2, height: 2)
            value.pendingSampleBuffer = sample!
            value.pendingFrameIndex = 5
            value.pendingPayloadByteCount = 16
            value.pendingQueuedAt = 0
            value.hasEnqueuedFirstFrame = true
            value.waitingForRecoveryKeyframe = false
            value.requiresKeyframe = false
            value.lastRecoveryRequestAt = -1
            value.displayLayer.isReadyForMoreMediaData = ready
            return value
        }

        let blocked = renderer(pendingAge: 0.081)
        var recoveryRequests = 0
        blocked.onRecoveryKeyframeNeeded = { recoveryRequests += 1 }
        blocked.drainPendingSampleBufferIfPossible()
        check(blocked.pendingSampleBuffer == nil, "Expired pending frame is released even when decoder remains busy")
        check(!blocked.isDrainScheduled, "Expired pending frame stops the five-millisecond polling loop")
        check(blocked.requiresKeyframe && blocked.waitingForRecoveryKeyframe, "Reference-chain loss requires recovery")
        check(blocked.displayLayer.enqueueCount == 0 && blocked.displayLayer.flushCount == 1, "Expiry flushes once without enqueue")
        check(recoveryRequests == 1, "Expiry requests a fresh keyframe")
        let expiredMetric = blocked.streamingDiagnosticSnapshot(windowId: 1, spatial: false)
        check(expiredMetric?.applicationDroppedFrames == 1 && expiredMetric?.queuedFrames == 0,
              "Expiry is counted once and queue becomes empty")
        blocked.drainPendingSampleBufferIfPossible()
        check(recoveryRequests == 1 && blocked.displayLayer.flushCount == 1, "Repeated empty drain is inert")
        blocked.enqueueLiveSampleBuffer(sample!, frameIndex: 6, isKeyframe: false, payloadByteCount: 16, mainHopMs: 0)
        check(blocked.displayLayer.enqueueCount == 0, "Following dependent frames stay rejected until keyframe")
        blocked.enqueueLiveSampleBuffer(sample!, frameIndex: 7, isKeyframe: true, payloadByteCount: 16, mainHopMs: 0)
        check(blocked.displayLayer.enqueueCount == 1 && !blocked.requiresKeyframe, "Fresh keyframe restores enqueue")

        let becameReadyLate = renderer(pendingAge: 0.081, ready: true)
        becameReadyLate.drainPendingSampleBufferIfPossible()
        check(becameReadyLate.displayLayer.enqueueCount == 0 && becameReadyLate.requiresKeyframe,
              "Readiness must not allow an expired frame to display")
        let dependentAtExpiry = renderer(pendingAge: 0.081, ready: true)
        dependentAtExpiry.enqueueLiveSampleBuffer(sample!, frameIndex: 6, isKeyframe: false,
                                                 payloadByteCount: 16, mainHopMs: 0)
        check(dependentAtExpiry.displayLayer.enqueueCount == 0 && dependentAtExpiry.requiresKeyframe,
              "Nested expiry during enqueue cannot admit the current dependent P frame")
        check(dependentAtExpiry.streamingDiagnosticSnapshot(windowId: 1, spatial: false)?.applicationDroppedFrames == 2,
              "Nested expiry counts both stale pending and rejected current dependent frame")
        let keyframeAtExpiry = renderer(pendingAge: 0.081, ready: true)
        keyframeAtExpiry.enqueueLiveSampleBuffer(sample!, frameIndex: 6, isKeyframe: true,
                                               payloadByteCount: 16, mainHopMs: 0)
        check(keyframeAtExpiry.displayLayer.enqueueCount == 1 && !keyframeAtExpiry.requiresKeyframe &&
              !keyframeAtExpiry.waitingForRecoveryKeyframe,
              "Nested expiry prepares the current keyframe and clears recovery flags")
        keyframeAtExpiry.enqueueLiveSampleBuffer(sample!, frameIndex: 7, isKeyframe: false,
                                               payloadByteCount: 16, mainHopMs: 0)
        check(keyframeAtExpiry.displayLayer.enqueueCount == 2,
              "P frame after current recovery keyframe is accepted")
        let fresh = renderer(pendingAge: 0.040, ready: true)
        fresh.drainPendingSampleBufferIfPossible()
        check(fresh.displayLayer.enqueueCount == 1 && fresh.pendingSampleBuffer == nil && !fresh.requiresKeyframe,
              "Fresh pending frame drains normally")
        let stillBusy = renderer(pendingAge: 0.040)
        stillBusy.drainPendingSampleBufferIfPossible()
        check(stillBusy.pendingSampleBuffer != nil && stillBusy.isDrainScheduled && !stillBusy.requiresKeyframe,
              "Temporary decoder pressure below the deadline retains the pending frame")
        let boundary = renderer(pendingAge: 0.080, ready: true)
        boundary.drainPendingSampleBufferIfPossible()
        check(boundary.displayLayer.enqueueCount == 1, "Exact eighty-millisecond boundary remains admissible")
        let missingAge = renderer(pendingAge: 0.040)
        missingAge.pendingQueuedAt = nil
        missingAge.drainPendingSampleBufferIfPossible()
        check(missingAge.pendingSampleBuffer == nil && missingAge.requiresKeyframe, "Unknown pending age fails closed")
        let staleGeneration = renderer(pendingAge: 0.081, ready: true)
        let retired = staleGeneration.currentLifecycleGenerationIfValid()!
        _ = staleGeneration.advanceLifecycleGeneration()
        staleGeneration.drainPendingSampleBufferIfPossible(generation: retired)
        check(staleGeneration.pendingSampleBuffer != nil && staleGeneration.displayLayer.flushCount == 0,
              "Retired generation callback cannot touch current decoder state")
        let invalidated = renderer(pendingAge: 0.081, ready: true)
        _ = invalidated.advanceLifecycleGeneration(invalidate: true)
        invalidated.drainPendingSampleBufferIfPossible()
        check(invalidated.displayLayer.enqueueCount == 0 && invalidated.displayLayer.flushCount == 0,
              "Invalidated renderer does not enqueue or request recovery")
        return failures
    }
}

@main struct RendererRecoveryChecks {
    static func main() {
        let failures = CompressedVideoRenderer.checkPendingRecovery()
        if !failures.isEmpty { failures.forEach { print("FAIL: \($0)") }; exit(1) }
        print("PASS: actual renderer pending deadline, busy/ready expiry, fresh/boundary drain, recovery and generation guards; deterministic decoder, no UI")
    }
}
