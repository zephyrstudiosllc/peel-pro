import Foundation
import CoreMedia
import CoreVideo

nonisolated private final class Lifetimes: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var live: Int { lock.lock(); defer { lock.unlock() }; return count }
    func change(_ amount: Int) { lock.lock(); count += amount; lock.unlock() }
}

nonisolated private final class Diagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var replaced = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return replaced }
    func replacedPending(windowID: UInt32, token: UUID?) {
        lock.lock(); replaced += 1; lock.unlock()
    }
}

nonisolated private final class EncoderFixture: @unchecked Sendable {
    let callbackQueue = DispatchQueue(label: "peel.test.encoder.input")
    private let inputMailbox = VideoEncoderInputMailbox()
    let diagnostics = Diagnostics()
    let windowId: UInt32 = 1
    let diagnosticToken: UUID? = UUID()
    var received: [(Int64, Bool, Bool)] = [] // Accessed only on callbackQueue.
    var marker = false
    var onEncode: (() -> Void)?
    func encode(sampleBuffer: CMSampleBuffer, forceKeyframe: Bool) {
        received.append((CMSampleBufferGetPresentationTimeStamp(sampleBuffer).value, forceKeyframe, marker))
        onEncode?()
    }
    func invalidate() { inputMailbox.close() }
    // PRODUCTION_ADMISSION_METHODS
}

@main private struct Checks {
    nonisolated static func check(_ condition: Bool, _ message: String) {
        if !condition { print("FAIL: \(message)"); exit(1) }
    }

    nonisolated static func sample(_ index: Int64, _ tracker: Lifetimes) -> CMSampleBuffer {
        let memory = malloc(16)!
        tracker.change(1)
        var pixel: CVPixelBuffer?
        let refcon = Unmanaged.passRetained(tracker).toOpaque()
        let status = CVPixelBufferCreateWithBytes(kCFAllocatorDefault, 2, 2,
            kCVPixelFormatType_32BGRA, memory, 8, { refcon, bytes in
                guard let refcon else { return }
                Unmanaged<Lifetimes>.fromOpaque(refcon).takeRetainedValue().change(-1)
                free(UnsafeMutableRawPointer(mutating: bytes))
            }, refcon, nil, &pixel)
        check(status == kCVReturnSuccess, "pixel creation")
        var format: CMVideoFormatDescription?
        check(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pixel!, formatDescriptionOut: &format) == noErr, "format creation")
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(value: index, timescale: 60), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        check(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pixel!, formatDescription: format!, sampleTiming: &timing,
            sampleBufferOut: &sample) == noErr, "sample creation")
        return sample!
    }

    static func main() {
        let tracker = Lifetimes()
        let encoder = EncoderFixture()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        encoder.callbackQueue.async { entered.signal(); release.wait() }
        check(entered.wait(timeout: .now() + 2) == .success, "queue stall entered")
        for index in 0..<1000 {
            autoreleasepool { encoder.encodeAsync(sampleBuffer: sample(Int64(index), tracker), forceKeyframe: index == 0) }
        }
        check(tracker.live == 1, "blocked encoder must retain only the latest pending raw frame (live=\(tracker.live))")
        check(encoder.diagnostics.count == 999, "replacements must be counted")
        release.signal()
        encoder.callbackQueue.sync {
            check(encoder.received.count == 1 && encoder.received[0].0 == 999 && encoder.received[0].1,
                  "latest raw frame must retain earlier keyframe intent")
        }
        check(tracker.live == 0, "drained raw frame released")

        // A synchronous encoder stall permits one current plus one latest input.
        // Follow-up drains yield to callbacks already waiting on the queue.
        let active = EncoderFixture()
        let activeEntered = DispatchSemaphore(value: 0), activeRelease = DispatchSemaphore(value: 0)
        let second = DispatchSemaphore(value: 0)
        active.onEncode = {
            if active.received.count == 1 { activeEntered.signal(); activeRelease.wait() }
            else { second.signal() }
        }
        autoreleasepool { active.encodeAsync(sampleBuffer: sample(0, tracker), forceKeyframe: false) }
        check(activeEntered.wait(timeout: .now() + 2) == .success, "active encode stall entered")
        for index in 1...1000 {
            autoreleasepool { active.encodeAsync(sampleBuffer: sample(Int64(index), tracker), forceKeyframe: index == 50) }
        }
        check(tracker.live == 2, "active stall permits one current and one pending frame")
        active.callbackQueue.async { active.marker = true }
        activeRelease.signal()
        check(second.wait(timeout: .now() + 2) == .success, "follow-up drain completed")
        active.callbackQueue.sync {
            check(active.received.count == 2 && active.received[1].0 == 1000 && active.received[1].1 && active.received[1].2,
                  "follow-up drain must use latest input, retain keyframe intent and yield to callbacks")
            active.onEncode = nil
        }
        check(tracker.live == 0, "active frames released")

        // Close input synchronously while the encoder queue is unavailable.
        let closed = EncoderFixture()
        let closeEntered = DispatchSemaphore(value: 0), closeRelease = DispatchSemaphore(value: 0)
        closed.callbackQueue.async { closeEntered.signal(); closeRelease.wait() }
        check(closeEntered.wait(timeout: .now() + 2) == .success, "close stall entered")
        autoreleasepool { closed.encodeAsync(sampleBuffer: sample(1, tracker), forceKeyframe: true) }
        closed.invalidateAsync()
        for index in 2...100 {
            autoreleasepool { closed.encodeAsync(sampleBuffer: sample(Int64(index), tracker), forceKeyframe: false) }
        }
        check(tracker.live == 0, "invalidation must immediately release and reject pending raw frames")
        closeRelease.signal()
        closed.callbackQueue.sync { check(closed.received.isEmpty, "queued drain must not encode invalidated input") }
        print("PASS: real raw-buffer bounds, latest-frame/keyframe preservation, callback fairness and invalidation")
    }
}
