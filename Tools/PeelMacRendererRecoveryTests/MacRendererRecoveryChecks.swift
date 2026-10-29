import Foundation
import AVFoundation
import CoreMedia
import QuartzCore

// Only AV readiness, logging, unused packet shapes and local time are stand-ins.
// The runner appends the entire actual production renderer. No window, hardware
// decode, native input or network action occurs; CoreMedia sample buffers are real.
enum FixtureClock { static var now: TimeInterval = 0 }
private func peelRemoteMacVideoPerfNowMs() -> Double { FixtureClock.now * 1000 }
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
    func enqueue(_ sample: CMSampleBuffer) { enqueueCount += 1 }
    func flush() { flushCount += 1; status = .unknown; requiresFlushToResumeDecoding = false }
    func flushAndRemoveImage() { flush() }
    func removeFromSuperlayer() {}
}
enum PeelRemoteMacVideoRendererDiagnostics {
    static func logRendererEvent(label: String, windowId: UInt32?, reason: String,
                                 frameIndex: Int64? = nil, payloadByteCount: Int? = nil,
                                 status: String? = nil, interval: TimeInterval = 1) {}
    static func logRendererFrame(label: String, windowId: UInt32?, action: String,
                                 frameIndex: Int64, payloadByteCount: Int, isKeyframe: Bool,
                                 mainHopMs: Double?, displayReady: Bool, layerStatus: String) {}
}
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

extension PeelRemoteMacVideoRenderer {
    static func checkPendingRecovery() -> [String] {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
        var pixel: CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &pixel) == noErr)
        var format: CMVideoFormatDescription?
        precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                      imageBuffer: pixel!, formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                      imageBuffer: pixel!, formatDescription: format!, sampleTiming: &timing,
                      sampleBufferOut: &sample) == noErr)
        func pending(age: Double, ready: Bool = false) -> PeelRemoteMacVideoRenderer {
            FixtureClock.now = 0
            let renderer = PeelRemoteMacVideoRenderer()
            renderer.hasEnqueuedFirstFrame = true
            renderer.requiresKeyframe = false
            renderer.lastRecoveryRequestAt = -1
            renderer.enqueueLiveSampleBuffer(sample!, frameIndex: 1, isKeyframe: false,
                                             payloadByteCount: 16, mainHopMs: 0)
            check(renderer.pendingSampleBuffer != nil, "Production enqueue stores a pending frame while busy")
            FixtureClock.now = age
            renderer.layer.isReadyForMoreMediaData = ready
            // Model the scheduled callback consuming its one pending drain token.
            renderer.isDrainScheduled = false
            return renderer
        }
        let expired = pending(age: 0.081)
        var requests = 0
        expired.onNeedsKeyframe = { requests += 1 }
        expired.drainPendingSampleBufferIfPossible()
        check(expired.pendingSampleBuffer == nil && !expired.isDrainScheduled,
              "Expired busy frame is released and polling stops without another incoming frame")
        check(expired.requiresKeyframe && expired.layer.flushCount == 1 && requests == 1,
              "Expiry flushes and requests recovery once")
        expired.drainPendingSampleBufferIfPossible()
        check(requests == 1 && expired.layer.flushCount == 1, "Empty repeated drain is inert")
        let lateReady = pending(age: 0.081, ready: true)
        lateReady.drainPendingSampleBufferIfPossible()
        check(lateReady.layer.enqueueCount == 0 && lateReady.requiresKeyframe, "Late readiness never displays the expired frame")
        for age in [0.040, 0.080] {
            let fresh = pending(age: age, ready: true)
            fresh.drainPendingSampleBufferIfPossible()
            check(fresh.layer.enqueueCount == 1 && !fresh.requiresKeyframe, "Fresh/boundary frame drains normally")
        }
        let busy = pending(age: 0.040)
        busy.drainPendingSampleBufferIfPossible()
        check(busy.pendingSampleBuffer != nil && busy.isDrainScheduled && !busy.requiresKeyframe,
              "Brief decoder pressure retains a fresh frame")
        let dependent = pending(age: 0.081, ready: true)
        dependent.enqueueLiveSampleBuffer(sample!, frameIndex: 2, isKeyframe: false, payloadByteCount: 16, mainHopMs: 0)
        check(dependent.layer.enqueueCount == 0 && dependent.requiresKeyframe,
              "Same-call expiry rejects the current dependent frame")
        let key = pending(age: 0.081, ready: true)
        key.enqueueLiveSampleBuffer(sample!, frameIndex: 2, isKeyframe: true, payloadByteCount: 16, mainHopMs: 0)
        check(key.layer.enqueueCount == 1 && !key.requiresKeyframe && !key.waitingForRecoveryKeyframe,
              "Same-call expiry prepares the current keyframe")
        key.enqueueLiveSampleBuffer(sample!, frameIndex: 3, isKeyframe: false, payloadByteCount: 16, mainHopMs: 0)
        check(key.layer.enqueueCount == 2, "Dependent frame after recovery keyframe is accepted")
        let retired = pending(age: 0.081, ready: true)
        let generation = retired.currentLifecycleGenerationIfValid()!
        _ = retired.advanceLifecycleGeneration()
        retired.drainPendingSampleBufferIfPossible(generation: generation)
        check(retired.pendingSampleBuffer != nil && retired.layer.flushCount == 0, "Retired callback cannot mutate new state")
        let invalid = pending(age: 0.081, ready: true)
        _ = invalid.advanceLifecycleGeneration(invalidate: true)
        invalid.drainPendingSampleBufferIfPossible()
        check(invalid.layer.enqueueCount == 0 && invalid.layer.flushCount == 0, "Invalidated decoder is untouched")
        return failures
    }
}
@main struct MacRendererRecoveryChecks {
    static func main() {
        let failures = PeelRemoteMacVideoRenderer.checkPendingRecovery()
        if !failures.isEmpty { failures.forEach { print("FAIL: \($0)") }; exit(1) }
        print("PASS: actual Mac renderer pending expiry, fresh/boundary drain, same-call P/I recovery and generation guards; no UI/hardware decode")
    }
}
