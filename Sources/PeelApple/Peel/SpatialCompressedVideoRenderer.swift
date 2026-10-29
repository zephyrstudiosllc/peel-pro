//
//  SpatialCompressedVideoRenderer.swift
//  Peel
//
//  Created by Zach on 5/25/26.
//


#if os(visionOS)

import SwiftUI
import Combine
import AVFoundation
import CoreMedia
import CoreImage
import VideoToolbox

final class SpatialCompressedVideoRenderer: ObservableObject {
    @Published private(set) var cgImage: CGImage?
    @Published private(set) var contentSize: CGSize = .zero

    private var formatDescription: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    private var decodeCallbackContext: DecodeCallbackContext?
    private var localFrameIndex: Int64 = 0
    private var renderGeneration: UInt64 = 0
    private let localFrameTimescale: CMTimeScale = 600
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let publishFrameLock = NSLock()
    private var latestPublishPixelBuffer: CVImageBuffer?
    private var latestPublishGeneration: UInt64 = 0
    private var isPublishScheduled = false
    private let pipelineDiagnostics = PeelSpatialVideoDiagnostics()
    private var diagnosticGeneration = UUID()
    private var configuredTimescale: Double = 0
    private var diagnosticWindowId: UInt32 = 0
    var diagnosticClock: PeelStreamClockTracker?
    private let frameContextLock = NSLock()
    private struct FrameContext {
        let receivedAt: Double
        let sourcePTSSeconds: Double?
        let diagnosticGeneration: UUID
    }
    private var frameContexts: [UInt: FrameContext] = [:]
    private var latestPublishFrame: PeelSpatialVideoDiagnostics.Frame?
    private var latestPublishDiagnosticGeneration: UUID?
    private var decodedPixelMetadata: (width: Int, height: Int, format: UInt32)?
    private var lastFixtureAt: Double = 0
    private var fixtureInFlight = false
    private var fixtureQuality: PeelFixtureQualityMetric?
    private let fixtureQueue = DispatchQueue(label: "peel.spatial.fixtureQuality", qos: .utility)

    private final class DecodeCallbackContext {
        weak var renderer: SpatialCompressedVideoRenderer?
        let generation: UInt64

        init(renderer: SpatialCompressedVideoRenderer, generation: UInt64) {
            self.renderer = renderer
            self.generation = generation
        }
    }

    deinit {
        tearDownDecoder()
    }

    func applyConfig(_ packet: VideoConfigPacket) {
        var formatDescription: CMFormatDescription?
        let status: OSStatus
        switch packet.codec {
        case .h264:
            status = packet.sps.withUnsafeBytes { spsRaw in
                packet.pps.withUnsafeBytes { ppsRaw in
                    guard
                        let spsBase = spsRaw.bindMemory(to: UInt8.self).baseAddress,
                        let ppsBase = ppsRaw.bindMemory(to: UInt8.self).baseAddress
                    else {
                        return kCMFormatDescriptionError_InvalidParameter
                    }

                    let parameterSetPointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                    let parameterSetSizes: [Int] = [packet.sps.count, packet.pps.count]

                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 2,
                        parameterSetPointers: parameterSetPointers,
                        parameterSetSizes: parameterSetSizes,
                        nalUnitHeaderLength: Int32(packet.nalUnitHeaderLength),
                        formatDescriptionOut: &formatDescription
                    )
                }
            }

        case .hevc:
            guard let vps = packet.vps, !vps.isEmpty else { return }
            status = vps.withUnsafeBytes { vpsRaw in
                packet.sps.withUnsafeBytes { spsRaw in
                    packet.pps.withUnsafeBytes { ppsRaw in
                        guard
                            let vpsBase = vpsRaw.bindMemory(to: UInt8.self).baseAddress,
                            let spsBase = spsRaw.bindMemory(to: UInt8.self).baseAddress,
                            let ppsBase = ppsRaw.bindMemory(to: UInt8.self).baseAddress
                        else {
                            return kCMFormatDescriptionError_InvalidParameter
                        }

                        let parameterSetPointers: [UnsafePointer<UInt8>] = [vpsBase, spsBase, ppsBase]
                        let parameterSetSizes: [Int] = [vps.count, packet.sps.count, packet.pps.count]

                        return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 3,
                            parameterSetPointers: parameterSetPointers,
                            parameterSetSizes: parameterSetSizes,
                            nalUnitHeaderLength: Int32(packet.nalUnitHeaderLength),
                            extensions: nil,
                            formatDescriptionOut: &formatDescription
                        )
                    }
                }
            }
        }

        guard status == noErr, let videoFormat = formatDescription else {
            print("SpatialRenderer: failed to create \(packet.codec) format description status=\(status)")
            return
        }

        let generation = bumpGeneration()

        tearDownDecoder()

        self.formatDescription = videoFormat
        self.localFrameIndex = 0
        configuredTimescale = Double(packet.timescale)
        diagnosticWindowId = packet.windowId
        diagnosticGeneration = pipelineDiagnostics.configure(width: Int(packet.width), height: Int(packet.height))
        frameContextLock.lock()
        frameContexts.removeAll()
        frameContextLock.unlock()

        publishFrameLock.lock()
        latestPublishPixelBuffer = nil
        latestPublishGeneration = 0
        isPublishScheduled = false
        decodedPixelMetadata = nil
        fixtureQuality = nil
        publishFrameLock.unlock()

        let newSize = CGSize(width: Int(packet.width), height: Int(packet.height))

        publishOnMain(generation: generation) { renderer in
            renderer.contentSize = newSize
            renderer.cgImage = nil
        }

        makeDecompressionSession(formatDescription: videoFormat, generation: generation)
    }

    func enqueueFrame(_ packet: VideoFramePacket) {
        let receivedAt = ProcessInfo.processInfo.systemUptime
        guard let formatDescription else {
            print("SpatialRenderer: dropped frame because formatDescription is nil")
            return
        }

        if decompressionSession == nil {
            makeDecompressionSession(formatDescription: formatDescription, generation: renderGeneration)
        }

        guard let decompressionSession else {
            print("SpatialRenderer: dropped frame because decompressionSession is nil")
            return
        }

        let frameIndex = localFrameIndex
        localFrameIndex += 1

        let pts = CMTime(value: frameIndex, timescale: localFrameTimescale)
        let duration = CMTime.invalid

        guard let sampleBuffer = makeSampleBuffer(
            payload: packet.payload,
            formatDescription: formatDescription,
            pts: pts,
            duration: duration,
            isKeyframe: packet.isKeyframe
        ) else {
            print("SpatialRenderer: failed to make sampleBuffer key=\(packet.isKeyframe)")
            return
        }

        let frameToken = UInt(frameIndex) + 1
        frameContextLock.lock()
        // A decoder may omit callbacks. Diagnostics never grows without bound.
        if frameContexts.count >= 128 { frameContexts.removeValue(forKey: frameContexts.keys.min()!) }
        frameContexts[frameToken] = FrameContext(receivedAt: receivedAt,
            sourcePTSSeconds: configuredTimescale > 0 ? Double(packet.ptsValue) / configuredTimescale : nil,
            diagnosticGeneration: diagnosticGeneration)
        frameContextLock.unlock()
        var flagsOut = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            decompressionSession,
            sampleBuffer: sampleBuffer,
            flags: [],
            frameRefcon: UnsafeMutableRawPointer(bitPattern: frameToken),
            infoFlagsOut: &flagsOut
        )

        if status != noErr {
            frameContextLock.lock()
            let failed = frameContexts.removeValue(forKey: frameToken)
            frameContextLock.unlock()
            if let failed { pipelineDiagnostics.decoded(generation: failed.diagnosticGeneration, failed: true) }
            print("SpatialRenderer: decode failed status=\(status)")
            if packet.isKeyframe {
                tearDownDecoder()
                makeDecompressionSession(formatDescription: formatDescription, generation: renderGeneration)
            }
        }
    }

    func invalidate() {
        let generation = bumpGeneration()

        tearDownDecoder()

        formatDescription = nil
        localFrameIndex = 0
        diagnosticGeneration = pipelineDiagnostics.configure(width: 0, height: 0)
        frameContextLock.lock()
        frameContexts.removeAll()
        frameContextLock.unlock()

        publishFrameLock.lock()
        decodedPixelMetadata = nil
        fixtureQuality = nil
        latestPublishPixelBuffer = nil
        latestPublishGeneration = 0
        isPublishScheduled = false
        publishFrameLock.unlock()

        publishOnMain(generation: generation) { renderer in
            renderer.cgImage = nil
            renderer.contentSize = .zero
        }
    }

    @discardableResult
    private func bumpGeneration() -> UInt64 {
        renderGeneration &+= 1
        return renderGeneration
    }

    private func tearDownDecoder() {
        let session = decompressionSession
        decompressionSession = nil

        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }

        decodeCallbackContext = nil
    }

    private func publishOnMain(
        generation: UInt64,
        _ update: @escaping (SpatialCompressedVideoRenderer) -> Void
    ) {
        if Thread.isMainThread {
            guard renderGeneration == generation else { return }
            update(self)
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.renderGeneration == generation else { return }
            update(self)
        }
    }

    private func makeDecompressionSession(
        formatDescription: CMVideoFormatDescription,
        generation: UInt64
    ) {
        let callbackContext = DecodeCallbackContext(renderer: self, generation: generation)

        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: Self.decodeCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(callbackContext).toOpaque()
        )

        let pixelAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]

        var session: VTDecompressionSession?

        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: pixelAttributes as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &session
        )

        guard status == noErr, let session else {
            print("SpatialRenderer: failed to create decompression session status=\(status)")
            return
        }

        decodeCallbackContext = callbackContext
        decompressionSession = session
    }

    private static let decodeCallback: VTDecompressionOutputCallback = {
        refCon,
        frameRefCon,
        status,
        _,
        imageBuffer,
        _,
        _
        in

        guard let refCon, let frameRefCon else {
            return
        }

        let context = Unmanaged<DecodeCallbackContext>
            .fromOpaque(refCon)
            .takeUnretainedValue()

        guard let renderer = context.renderer, renderer.renderGeneration == context.generation else { return }
        renderer.frameContextLock.lock()
        let frame = renderer.frameContexts.removeValue(forKey: UInt(bitPattern: frameRefCon))
        renderer.frameContextLock.unlock()
        guard let frame else { return }
        guard status == noErr, let imageBuffer else {
            renderer.pipelineDiagnostics.decoded(generation: frame.diagnosticGeneration, failed: true)
            return
        }
        renderer.publish(pixelBuffer: imageBuffer, generation: context.generation,
            frame: PeelSpatialVideoDiagnostics.Frame(receivedAt: frame.receivedAt,
                sourcePTSSeconds: frame.sourcePTSSeconds, decodedAt: ProcessInfo.processInfo.systemUptime),
            diagnosticGeneration: frame.diagnosticGeneration)
    }

    private func publish(pixelBuffer: CVImageBuffer, generation: UInt64,
                         frame: PeelSpatialVideoDiagnostics.Frame, diagnosticGeneration: UUID) {
        guard renderGeneration == generation else { return }

        publishFrameLock.lock()
        pipelineDiagnostics.decoded(generation: diagnosticGeneration, replaced: latestPublishPixelBuffer != nil)
        decodedPixelMetadata = (CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer),
                                CVPixelBufferGetPixelFormatType(pixelBuffer))
        latestPublishPixelBuffer = pixelBuffer
        latestPublishGeneration = generation
        latestPublishFrame = frame
        latestPublishDiagnosticGeneration = diagnosticGeneration

        if isPublishScheduled {
            publishFrameLock.unlock()
            return
        }

        isPublishScheduled = true
        publishFrameLock.unlock()

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            self?.buildAndPublishLatestImage()
        }
    }

    private func buildAndPublishLatestImage() {
        publishFrameLock.lock()
        let pixelBuffer = latestPublishPixelBuffer
        let generation = latestPublishGeneration
        let frame = latestPublishFrame
        let diagnosticGeneration = latestPublishDiagnosticGeneration
        latestPublishPixelBuffer = nil
        latestPublishFrame = nil
        latestPublishDiagnosticGeneration = nil
        publishFrameLock.unlock()

        defer {
            publishFrameLock.lock()
            if latestPublishPixelBuffer != nil, renderGeneration == latestPublishGeneration {
                DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                    self?.buildAndPublishLatestImage()
                }
            } else {
                isPublishScheduled = false
            }
            publishFrameLock.unlock()
        }

        guard renderGeneration == generation, let pixelBuffer, let frame, let diagnosticGeneration else { return }

        let conversionStartedAt = ProcessInfo.processInfo.systemUptime
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let rect = ciImage.extent

        guard let image = ciContext.createCGImage(ciImage, from: rect) else {
            return
        }
        let conversionMilliseconds = (ProcessInfo.processInfo.systemUptime - conversionStartedAt) * 1000
        scheduleFixtureMeasurement(image, generation: generation)

        publishOnMain(generation: generation) { renderer in
            renderer.cgImage = image
            renderer.contentSize = CGSize(width: rect.width, height: rect.height)
            renderer.pipelineDiagnostics.published(generation: diagnosticGeneration, frame: frame,
                conversionMilliseconds: conversionMilliseconds, windowId: renderer.diagnosticWindowId,
                clock: renderer.diagnosticClock?.estimate())
        }
    }

    func streamingDiagnosticSnapshot() -> PeelSpatialPipelineMetric {
        var row = pipelineDiagnostics.snapshot(clock: diagnosticClock?.estimate())
        publishFrameLock.lock()
        row.decodedWidth = decodedPixelMetadata?.width
        row.decodedHeight = decodedPixelMetadata?.height
        row.decodedPixelFormat = decodedPixelMetadata?.format
        if let fixtureQuality,
           ProcessInfo.processInfo.systemUptime - fixtureQuality.sampledAtClientUptimeSeconds <= 5 {
            row.fixtureQuality = fixtureQuality
        }
        publishFrameLock.unlock()
        return row
    }

    private func scheduleFixtureMeasurement(_ image: CGImage, generation: UInt64) {
#if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--peel-quality-fixture-v1") else { return }
        let now = ProcessInfo.processInfo.systemUptime
        publishFrameLock.lock()
        guard renderGeneration == generation, !fixtureInFlight, now - lastFixtureAt >= 2 else {
            publishFrameLock.unlock(); return
        }
        fixtureInFlight = true; lastFixtureAt = now
        publishFrameLock.unlock()
        let estimate = diagnosticClock?.estimate(now: now)
        fixtureQueue.async { [weak self] in
            let quality = PeelNativeFixtureQuality.measure(image, now: now, clock: estimate)
            guard let self else { return }
            self.publishFrameLock.lock()
            self.fixtureInFlight = false
            if self.renderGeneration == generation { self.fixtureQuality = quality }
            self.publishFrameLock.unlock()
        }
#endif
    }

    private func makeSampleBuffer(
        payload: Data,
        formatDescription: CMVideoFormatDescription,
        pts: CMTime,
        duration: CMTime,
        isKeyframe: Bool
    ) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?

        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard createStatus == noErr, let blockBuffer else {
            print("SpatialRenderer: CMBlockBufferCreateWithMemoryBlock failed status=\(createStatus)")
            return nil
        }

        let replaceStatus = payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                return kCMBlockBufferBadCustomBlockSourceErr
            }

            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: payload.count
            )
        }

        guard replaceStatus == kCMBlockBufferNoErr else {
            print("SpatialRenderer: CMBlockBufferReplaceDataBytes failed status=\(replaceStatus)")
            return nil
        }

        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        var sampleSize = payload.count
        var sampleBuffer: CMSampleBuffer?

        let sbStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard sbStatus == noErr, let sampleBuffer else {
            print("SpatialRenderer: CMSampleBufferCreateReady failed status=\(sbStatus)")
            return nil
        }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let raw = CFArrayGetValueAtIndex(attachments, 0)
            let dict = unsafeBitCast(raw, to: CFMutableDictionary.self)

            let notSyncValue: CFBoolean = isKeyframe ? kCFBooleanFalse : kCFBooleanTrue

            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(notSyncValue).toOpaque()
            )

            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        return sampleBuffer
    }
}

struct SpatialCompressedVideoView: View {
    @ObservedObject var renderer: SpatialCompressedVideoRenderer

    var body: some View {
        ZStack {
            Color.black

            if let cgImage = renderer.cgImage {
                Image(decorative: cgImage, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .clipped()
    }
}

#endif
