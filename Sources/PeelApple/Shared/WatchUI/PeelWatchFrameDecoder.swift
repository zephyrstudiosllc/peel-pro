#if os(iOS)
import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import CoreImage
import ImageIO
import PeelWatchCore

/// A bounded, opt-in copy of the authenticated compressed video. No screen/UI
/// capture and no synthetic frame path. Only JPEG crops cross WatchConnectivity.
final class PeelWatchFrameDecoder: @unchecked Sendable {
    struct ImageResult { let data: Data; let width: Int; let height: Int; let capturedAt: TimeInterval; let epoch: UInt64 }
    private struct Item { let sample: CMSampleBuffer; let keyframe: Bool; let epoch: UInt64 }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "peel.watch.video.decode", qos: .utility)
    private let imageQueue = DispatchQueue(label: "peel.watch.video.jpeg", qos: .utility)
    private var pending: [Item] = []
    private var bytes = 0
    private var draining = false
    private var invalid = false
    private var needsKeyframe = true
    private var rendererID: UUID?
    private var epoch: UInt64 = 0
    private var decodingEpoch: UInt64 = 0
    private var decoderResetRequested = false
    private var latest: (CVPixelBuffer, TimeInterval, UInt64)?
    private var decoder: VTDecompressionSession?
    private var format: CMFormatDescription?
    private let context = CIContext(options: [.cacheIntermediates: false])

    func submit(_ sample: CMSampleBuffer, keyframe: Bool, rendererID: UUID) {
        let size = CMSampleBufferGetTotalSampleSize(sample)
        lock.lock()
        guard !invalid, size > 0, size <= 8 * 1_024 * 1_024 else { lock.unlock(); return }
        if self.rendererID != rendererID {
            self.rendererID = rendererID; epoch &+= 1; pending.removeAll(); bytes = 0
            latest = nil; needsKeyframe = true
        }
        if pending.count >= 3 || bytes + size > 16 * 1_024 * 1_024 {
            epoch &+= 1; pending.removeAll(); bytes = 0; latest = nil; needsKeyframe = true
        }
        if keyframe { needsKeyframe = false }
        guard !needsKeyframe else { lock.unlock(); return }
        pending.append(Item(sample: sample, keyframe: keyframe, epoch: epoch)); bytes += size
        let start = !draining; draining = true
        lock.unlock()
        if start { queue.async { [self] in drain() } }
    }

    func invalidate() {
        lock.lock(); invalid = true; epoch &+= 1; pending.removeAll(); bytes = 0; latest = nil; lock.unlock()
        queue.async { [self] in destroyDecoder() }
    }

    private func destroyDecoder() {
        if let decoder { VTDecompressionSessionWaitForAsynchronousFrames(decoder); VTDecompressionSessionInvalidate(decoder) }
        decoder = nil; format = nil
    }

    /// Retire pixels before tearing down a failed decoder. This also invalidates
    /// JPEG work already in flight and any previously issued control frame.
    private func retirePixelsLocked(expectedEpoch: UInt64) {
        guard !invalid, epoch == expectedEpoch else { return }
        epoch &+= 1; latest = nil; pending.removeAll(); bytes = 0; needsKeyframe = true
    }

    private func drain() {
        while true {
            lock.lock()
            guard !invalid, !pending.isEmpty else { draining = false; lock.unlock(); return }
            let item = pending.removeFirst(); bytes -= CMSampleBufferGetTotalSampleSize(item.sample)
            let current = epoch == item.epoch
            lock.unlock()
            guard current, let incoming = CMSampleBufferGetFormatDescription(item.sample) else { continue }
            let dimensions = CMVideoFormatDescriptionGetDimensions(incoming)
            guard dimensions.width > 0, dimensions.height > 0,
                  dimensions.width <= 8192, dimensions.height <= 8192,
                  Int64(dimensions.width) * Int64(dimensions.height) <= 34_000_000 else { continue }
            let changedFormat = format.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: incoming) }) == true
            if changedFormat {
                destroyDecoder()
                lock.lock()
                guard !invalid, item.epoch == epoch else { lock.unlock(); continue }
                retirePixelsLocked(expectedEpoch: item.epoch)
                // This keyframe is the first frame of the replacement format.
                // Queued old-format work was discarded by retirement.
                decodingEpoch = epoch
                needsKeyframe = !item.keyframe
                lock.unlock()
            } else {
                lock.lock()
                guard !invalid, item.epoch == epoch else { lock.unlock(); continue }
                decodingEpoch = item.epoch
                lock.unlock()
            }
            if decoder == nil {
                destroyDecoder()
                guard item.keyframe else { continue }
                var callback = VTDecompressionOutputCallbackRecord(
                    decompressionOutputCallback: { ref, _, status, _, image, _, _ in
                        guard let ref else { return }
                        Unmanaged<PeelWatchFrameDecoder>.fromOpaque(ref).takeUnretainedValue().received(image, status: status)
                    }, decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
                let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                                   kCVPixelBufferIOSurfacePropertiesKey: [:]]
                let result = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: incoming,
                    decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary,
                    outputCallback: &callback, decompressionSessionOut: &decoder)
                guard result == noErr, let decoder else {
                    lock.lock(); retirePixelsLocked(expectedEpoch: decodingEpoch); lock.unlock()
                    destroyDecoder(); continue
                }
                VTSessionSetProperty(decoder, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
                format = incoming
            }
            guard let decoder else { continue }
            lock.lock(); let decodeIsCurrent = !invalid && decodingEpoch == epoch; lock.unlock()
            guard decodeIsCurrent else { continue }
            let status = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: item.sample,
                flags: [], frameRefcon: nil, infoFlagsOut: nil)
            VTDecompressionSessionWaitForAsynchronousFrames(decoder)
            lock.lock()
            if status != noErr { retirePixelsLocked(expectedEpoch: decodingEpoch) }
            let reset = status != noErr || decoderResetRequested
            decoderResetRequested = false
            lock.unlock()
            if reset { destroyDecoder() }
        }
    }

    private func received(_ image: CVPixelBuffer?, status: OSStatus) {
        lock.lock(); defer { lock.unlock() }
        guard status == noErr, let image else {
            // Callback failures can occur even if DecodeFrame returned noErr.
            // Mark state only here; session destruction waits on the decode queue.
            retirePixelsLocked(expectedEpoch: decodingEpoch)
            decoderResetRequested = true
            return
        }
        guard !invalid, decodingEpoch == epoch else { return }
        latest = (image, ProcessInfo.processInfo.systemUptime, epoch)
    }

    func isCurrent(_ image: ImageResult) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !invalid && image.epoch == epoch
    }

    func jpeg(viewport: WatchViewport) async -> ImageResult? {
        await withCheckedContinuation { continuation in
            imageQueue.async { [self] in
                lock.lock(); let captured = invalid ? nil : latest; lock.unlock()
                guard let (buffer, time, capturedEpoch) = captured,
                      ProcessInfo.processInfo.systemUptime-time <= 3 else { continuation.resume(returning: nil); return }
                let original = CIImage(cvPixelBuffer: buffer)
                let crop = CGRect(x: viewport.x * original.extent.width,
                                  y: (1-viewport.y-viewport.height) * original.extent.height,
                                  width: viewport.width * original.extent.width,
                                  height: viewport.height * original.extent.height)
                for edge in [512.0, 384.0] {
                    let scale = min(1, edge/max(crop.width,crop.height))
                    let image = original.cropped(to: crop)
                        .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                        .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    guard let cg = context.createCGImage(image, from: CGRect(x: 0, y: 0,
                        width: max(1, floor(crop.width*scale)), height: max(1, floor(crop.height*scale)))) else { continue }
                    for quality in [0.55, 0.3, 0.15] {
                        let data = NSMutableData()
                        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { continue }
                        CGImageDestinationAddImage(destination, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                        if CGImageDestinationFinalize(destination), data.length <= 32 * 1_024 {
                            lock.lock(); let current = !invalid && epoch == capturedEpoch; lock.unlock()
                            guard current else { continuation.resume(returning: nil); return }
                            continuation.resume(returning: ImageResult(data: data as Data, width: cg.width, height: cg.height, capturedAt: time, epoch: capturedEpoch)); return
                        }
                    }
                }
                continuation.resume(returning: nil)
            }
        }
    }
}
#endif
