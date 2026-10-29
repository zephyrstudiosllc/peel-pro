//
//  CompressedVideoRenderer.swift
//  Peel
//
//  Created by Zach on 4/15/26.
//


import Foundation
import AVFoundation
import CoreMedia
import QuartzCore

#if canImport(UIKit)
import UIKit




import SwiftUI
#endif

@inline(__always)
private func peelRendererPerfNowMs() -> Double {
    ProcessInfo.processInfo.systemUptime * 1000.0
}
#if canImport(UIKit)
#endif

final class CompressedVideoRenderer {
    let streamingDiagnostics = PeelClientVideoDiagnostics()
#if os(visionOS)
    let displayedFixtureDiagnostics = PeelDisplayLayerFixtureDiagnostics()
#endif
    var onFormatChange: ((CGSize) -> Void)?
    var onFrameEnqueued: ((Int, Bool) -> Void)?
    var onRecoveryKeyframeNeeded: (() -> Void)?
#if os(iOS)
    /// Opt-in phone relay only. The ordinary renderer never decodes a second copy
    /// unless the user is explicitly sharing a window with their paired Watch.
    var onWatchRelaySampleBuffer: ((CMSampleBuffer, Bool) -> Void)?
#endif
    private var lastRecoveryRequestAt: TimeInterval = 0
    // Main-queue owned; survives lifecycle changes until the external callback returns.
    private var isEmittingRecoveryKeyframeRequest = false
    private(set) var requiresKeyframe = true
    var diagnosticWindowId: UInt32?
    var diagnosticLabel: String = "renderer"

    let displayLayer: AVSampleBufferDisplayLayer = {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = nil
        return layer
    }()

    private var formatDescription: CMVideoFormatDescription?
    private var timescale: CMTimeScale = 600
    private var nalUnitHeaderLength: Int32 = 4
    private var codedSize: CGSize = .zero
    private var localFrameIndex: Int64 = 0
    private let localFrameTimescale: CMTimeScale = 600

    private struct QueuedRenderFrame {
        let sampleBuffer: CMSampleBuffer
        let frameIndex: Int64
        let isKeyframe: Bool
        let payloadByteCount: Int
        let queuedAt: TimeInterval
    }

    private let queuedFrameLock = NSLock()
    private var queuedRenderFrames: [QueuedRenderFrame] = []
    private var renderTaskScheduled = false
    private var queuedGeneration: UInt64?
    private var queuedPayloadBytes = 0
    private var queueNeedsKeyframe = false
    private var queueNeedsDecoderReset = false
    private let maximumQueuedFrames = 3
    private let maximumQueuedBytes = 24 * 1024 * 1024
    private let maximumQueueAge: TimeInterval = 0.080
    private var pendingSampleBuffer: CMSampleBuffer?
    private var pendingFrameIndex: Int64?
    private var pendingIsKeyframe: Bool = false
    private var pendingPayloadByteCount: Int = 0
    private var pendingQueuedAt: TimeInterval?
    private var isDrainScheduled = false
    private var droppedBackpressureFrameCount: Int64 = 0
    private var hasEnqueuedFirstFrame = false
    private var waitingForRecoveryKeyframe = false
    private let lifecycleLock = NSLock()
    private var lifecycleGeneration: UInt64 = 0
    // Guarded by lifecycleLock, including off-main config/reset invalidation.
    private var deferredRecoveryRequestToken: UUID?
    private var isInvalidated = false

    private func advanceLifecycleGeneration(invalidate: Bool = false) -> UInt64? {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        if isInvalidated {
            return nil
        }

        lifecycleGeneration &+= 1
        deferredRecoveryRequestToken = nil
#if os(visionOS)
        displayedFixtureDiagnostics.reset(generation: lifecycleGeneration)
#endif

        if invalidate {
            isInvalidated = true
        }

        return lifecycleGeneration
    }

    private func currentLifecycleGenerationIfValid() -> UInt64? {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        guard !isInvalidated else { return nil }
        return lifecycleGeneration
    }

    private func isCurrentLifecycleGeneration(_ generation: UInt64) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        return !isInvalidated && lifecycleGeneration == generation
    }

    func applyConfig(_ packet: VideoConfigPacket) {
        let perfStartMs = peelRendererPerfNowMs()
        guard let generation = advanceLifecycleGeneration() else { return }
        streamingDiagnostics.invalidate()

        self.formatDescription = nil
        var formatDescription: CMFormatDescription?

        let formatStartMs = peelRendererPerfNowMs()
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
            print("PeelClient: failed to create \(packet.codec) format description, status=\(status)")
            return
        }
        let actualDimensions = CMVideoFormatDescriptionGetDimensions(videoFormat)
        streamingDiagnostics.configure(width: Int(actualDimensions.width), height: Int(actualDimensions.height))

        let formatMs = peelRendererPerfNowMs() - formatStartMs

        PeelClientDiagnostics.logRendererEvent(
            
            label: diagnosticLabel,
            windowId: diagnosticWindowId ?? packet.windowId,
            reason: "apply config",
            status: "size=\(packet.width)x\(packet.height) timescale=\(packet.timescale)",
            interval: 0
        )

        self.formatDescription = videoFormat
        self.timescale = CMTimeScale(max(1, packet.timescale))
        self.nalUnitHeaderLength = Int32(packet.nalUnitHeaderLength)
        self.localFrameIndex = 0

        let newSize = CGSize(width: Int(packet.width), height: Int(packet.height))
        let sizeChanged = codedSize != newSize
        codedSize = newSize

        let beforeMainDispatchMs = peelRendererPerfNowMs()
        let preMainMs = beforeMainDispatchMs - perfStartMs
        if preMainMs >= 4.0 || formatMs >= 2.0 {
            print(
                "PeelClientPerf rendererConfig",
                "label=\(diagnosticLabel)",
                "window=\(diagnosticWindowId ?? packet.windowId)",
                "preMainMs=\(String(format: "%.2f", preMainMs))",
                "formatMs=\(String(format: "%.2f", formatMs))",
                "size=\(packet.width)x\(packet.height)"
            )
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentLifecycleGeneration(generation) else { return }

            let mainStartMs = peelRendererPerfNowMs()
            let mainHopMs = mainStartMs - beforeMainDispatchMs

            self.pendingSampleBuffer = nil
            self.pendingFrameIndex = nil
            self.pendingIsKeyframe = false
            self.pendingPayloadByteCount = 0
            self.isDrainScheduled = false
            self.droppedBackpressureFrameCount = 0
            self.hasEnqueuedFirstFrame = false
            self.waitingForRecoveryKeyframe = true
            self.requiresKeyframe = true
            self.displayLayer.flushAndRemoveImage()
            if sizeChanged {
                self.onFormatChange?(newSize)
            }
            let mainMs = peelRendererPerfNowMs() - mainStartMs
            if mainHopMs >= 16.0 || mainMs >= 4.0 {
                print(
                    "PeelClientPerf rendererConfigMain",
                    "label=\(self.diagnosticLabel)",
                    "window=\(self.diagnosticWindowId ?? packet.windowId)",
                    "mainHopMs=\(String(format: "%.2f", mainHopMs))",
                    "mainMs=\(String(format: "%.2f", mainMs))",
                    "sizeChanged=\(sizeChanged)"
                )
            }
        }
    }

    func enqueueFrame(_ packet: VideoFramePacket) {
        let enqueueStartMs = peelRendererPerfNowMs()
        let enqueueStartAt = enqueueStartMs / 1000.0

        guard let generation = currentLifecycleGenerationIfValid() else {
            PeelClientDiagnostics.logRendererEvent(
                
                label: diagnosticLabel,
                windowId: diagnosticWindowId ?? packet.windowId,
                reason: "drop invalid lifecycle",
                payloadByteCount: packet.payload.count
            )
            return
        }

        guard let formatDescription else {
            streamingDiagnostics.dropped()
            PeelClientDiagnostics.logRendererEvent(
                
                label: diagnosticLabel,
                windowId: diagnosticWindowId ?? packet.windowId,
                reason: "drop missing formatDescription",
                payloadByteCount: packet.payload.count
            )
            return
        }

        let frameIndex = localFrameIndex
        localFrameIndex += 1

        let localPTS = CMTime(value: frameIndex, timescale: localFrameTimescale)
        let localDuration = CMTime.invalid

        let sampleStartMs = peelRendererPerfNowMs()
        guard let sampleBuffer = makeSampleBuffer(
            payload: packet.payload,
            formatDescription: formatDescription,
            pts: localPTS,
            duration: localDuration,
            isKeyframe: packet.isKeyframe
        ) else {
            streamingDiagnostics.dropped()
            PeelClientDiagnostics.logRendererEvent(
                
                label: diagnosticLabel,
                windowId: diagnosticWindowId ?? packet.windowId,
                reason: "drop makeSampleBuffer failed",
                frameIndex: frameIndex,
                payloadByteCount: packet.payload.count
            )
            return
        }

        let sampleMs = peelRendererPerfNowMs() - sampleStartMs
#if os(iOS)
        onWatchRelaySampleBuffer?(sampleBuffer, packet.isKeyframe)
#endif
        let preMainMs = peelRendererPerfNowMs() - enqueueStartMs
        if sampleMs >= 3.0 || preMainMs >= 4.0 || packet.payload.count >= 96 * 1024 {
            print(
                "PeelClientPerf rendererFrameBuild",
                "label=\(diagnosticLabel)",
                "window=\(diagnosticWindowId ?? packet.windowId)",
                "frame=\(frameIndex)",
                "payload=\(packet.payload.count)",
                "key=\(packet.isKeyframe)",
                "sampleMs=\(String(format: "%.2f", sampleMs))",
                "preMainMs=\(String(format: "%.2f", preMainMs))"
            )
        }

        queuedFrameLock.lock()
        if queuedGeneration != generation {
            queuedGeneration = generation
            queuedRenderFrames.removeAll(keepingCapacity: true)
            queuedPayloadBytes = 0
            queueNeedsKeyframe = false
            queueNeedsDecoderReset = false
            renderTaskScheduled = false
        }
        let now = ProcessInfo.processInfo.systemUptime
        let isStale = queuedRenderFrames.first.map { now - $0.queuedAt > maximumQueueAge } ?? false
        if isStale || queuedRenderFrames.count >= maximumQueuedFrames ||
            queuedPayloadBytes + packet.payload.count > maximumQueuedBytes {
            // Dropping encoded reference frames requires a new keyframe. Never
            // feed surviving P frames into a decoder whose reference chain broke.
            streamingDiagnostics.dropped(queuedRenderFrames.count)
            queuedRenderFrames.removeAll(keepingCapacity: true)
            queuedPayloadBytes = 0
            queueNeedsKeyframe = true
            queueNeedsDecoderReset = true
        }
        let frameLimit = maximumQueuedBytes
        if packet.isKeyframe, packet.payload.count <= frameLimit { queueNeedsKeyframe = false }
        if !queueNeedsKeyframe, packet.payload.count <= frameLimit {
            queuedRenderFrames.append(QueuedRenderFrame(sampleBuffer: sampleBuffer,
                frameIndex: frameIndex, isKeyframe: packet.isKeyframe,
                payloadByteCount: packet.payload.count, queuedAt: now))
            queuedPayloadBytes += packet.payload.count
        } else {
            streamingDiagnostics.dropped()
        }
        let shouldScheduleRender = !renderTaskScheduled &&
            (!queuedRenderFrames.isEmpty || queueNeedsDecoderReset)
        if shouldScheduleRender { renderTaskScheduled = true }
        queuedFrameLock.unlock()
        if shouldScheduleRender { scheduleQueuedRender(generation: generation) }
    }

    private func scheduleQueuedRender(generation: UInt64) {
        DispatchQueue.main.async { [weak self] in self?.drainQueuedRender(generation: generation) }
    }

    private func drainQueuedRender(generation: UInt64) {
        guard isCurrentLifecycleGeneration(generation) else { return }
        // Yield the main queue after a bounded batch so touch and native controls
        // remain responsive even while the network is continuously producing.
        for _ in 0..<maximumQueuedFrames {
            queuedFrameLock.lock()
            guard queuedGeneration == generation else { queuedFrameLock.unlock(); return }
            let shouldReset = queueNeedsDecoderReset
            queueNeedsDecoderReset = false
            let frame = queuedRenderFrames.isEmpty ? nil : queuedRenderFrames.removeFirst()
            if let frame { queuedPayloadBytes -= frame.payloadByteCount }
            if frame == nil { renderTaskScheduled = false }
            queuedFrameLock.unlock()
            if shouldReset { enterRecoveryKeyframeWait() }
            guard let frame else { return }
            if ProcessInfo.processInfo.systemUptime - frame.queuedAt > maximumQueueAge {
                queuedFrameLock.lock()
                streamingDiagnostics.dropped(queuedRenderFrames.count + 1)
                queuedRenderFrames.removeAll(keepingCapacity: true)
                queuedPayloadBytes = 0
                queueNeedsKeyframe = true
                queuedFrameLock.unlock()
                enterRecoveryKeyframeWait()
                continue
            }
            enqueueLiveSampleBuffer(frame.sampleBuffer, frameIndex: frame.frameIndex,
                isKeyframe: frame.isKeyframe, payloadByteCount: frame.payloadByteCount,
                mainHopMs: (ProcessInfo.processInfo.systemUptime - frame.queuedAt) * 1000)
        }
        queuedFrameLock.lock()
        let hasWork = queuedGeneration == generation && (!queuedRenderFrames.isEmpty || queueNeedsDecoderReset)
        if !hasWork { renderTaskScheduled = false }
        queuedFrameLock.unlock()
        if hasWork { scheduleQueuedRender(generation: generation) }
    }



    func flushAndReset() {
        guard let generation = advanceLifecycleGeneration() else { return }
        streamingDiagnostics.invalidate()

        formatDescription = nil
        timescale = 600
        nalUnitHeaderLength = 4
        codedSize = .zero
        localFrameIndex = 0

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentLifecycleGeneration(generation) else { return }

            self.pendingSampleBuffer = nil
            self.pendingFrameIndex = nil
            self.pendingIsKeyframe = false
            self.pendingPayloadByteCount = 0
            self.queuedFrameLock.lock()
            self.queuedRenderFrames.removeAll()
            self.queuedPayloadBytes = 0
            self.queueNeedsKeyframe = false
            self.queueNeedsDecoderReset = false
            self.queuedGeneration = nil
            self.renderTaskScheduled = false
            self.queuedFrameLock.unlock()
            self.isDrainScheduled = false
            self.droppedBackpressureFrameCount = 0
            self.hasEnqueuedFirstFrame = false
            self.waitingForRecoveryKeyframe = true
            self.requiresKeyframe = true
            self.displayLayer.flushAndRemoveImage()
        }
    }

    func invalidate() {
        guard advanceLifecycleGeneration(invalidate: true) != nil else { return }
        streamingDiagnostics.invalidate()

        formatDescription = nil
        timescale = 600
        nalUnitHeaderLength = 4
        codedSize = .zero
        localFrameIndex = 0

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            self.pendingSampleBuffer = nil
            self.pendingFrameIndex = nil
            self.pendingIsKeyframe = false
            self.pendingPayloadByteCount = 0
            self.queuedFrameLock.lock()
            self.queuedRenderFrames.removeAll()
            self.queuedPayloadBytes = 0
            self.queueNeedsKeyframe = false
            self.queueNeedsDecoderReset = false
            self.queuedGeneration = nil
            self.renderTaskScheduled = false
            self.queuedFrameLock.unlock()
            self.isDrainScheduled = false
            self.droppedBackpressureFrameCount = 0
            self.hasEnqueuedFirstFrame = false
            self.waitingForRecoveryKeyframe = true
            self.requiresKeyframe = true
            self.displayLayer.flushAndRemoveImage()
            self.displayLayer.removeFromSuperlayer()
        }
    }

    private func enqueueLiveSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        frameIndex: Int64,
        isKeyframe: Bool,
        payloadByteCount: Int,
        mainHopMs: Double
    ) {
        guard let generation = currentLifecycleGenerationIfValid() else { return }

        let liveStartMs = peelRendererPerfNowMs()

        let recoverBeforeStartMs = peelRendererPerfNowMs()
        recoverDisplayLayerIfNeeded(reason: "before enqueue")
        let recoverBeforeMs = peelRendererPerfNowMs() - recoverBeforeStartMs

        guard displayLayer.status != .failed else {
            streamingDiagnostics.dropped()
            PeelClientDiagnostics.logRendererEvent(
                
                label: diagnosticLabel,
                windowId: diagnosticWindowId,
                reason: "drop displayLayer failed before enqueue",
                frameIndex: frameIndex,
                payloadByteCount: payloadByteCount,
                status: String(describing: displayLayer.error?.localizedDescription ?? "no error")
            )
            return
        }

        if !waitingForRecoveryKeyframe && pendingSampleBuffer != nil {
            if displayLayer.isReadyForMoreMediaData {
                drainPendingSampleBufferIfPossible(generation: generation)
            }

            if pendingSampleBuffer != nil {
                if isKeyframe {
                    prepareForRecoveryKeyframe()
                } else {
                    droppedBackpressureFrameCount += 1
                    streamingDiagnostics.dropped()
                    enterRecoveryKeyframeWait()
                    return
                }
            }
        }

        // Draining a pending frame can itself expire or fail and flush the
        // decoder. Recheck the reference-chain requirement after that operation
        // before admitting this incoming frame.
        if waitingForRecoveryKeyframe {
            guard isKeyframe else {
                streamingDiagnostics.dropped()
                return
            }
            prepareForRecoveryKeyframe()
        }

        if displayLayer.isReadyForMoreMediaData || !hasEnqueuedFirstFrame || isKeyframe {
            let wasReady = displayLayer.isReadyForMoreMediaData
            let displayEnqueueStartMs = peelRendererPerfNowMs()
            displayLayer.enqueue(sampleBuffer)
            streamingDiagnostics.enqueued()
            let displayEnqueueMs = peelRendererPerfNowMs() - displayEnqueueStartMs
            hasEnqueuedFirstFrame = true

            PeelClientDiagnostics.logRendererFrame(
                
                label: diagnosticLabel,
                windowId: diagnosticWindowId,
                action: "immediate",
                frameIndex: frameIndex,
                payloadByteCount: payloadByteCount,
                isKeyframe: isKeyframe,
                mainHopMs: mainHopMs,
                displayReady: wasReady,
                layerStatus: String(describing: displayLayer.status)
            )

            if recoverBeforeMs >= 2.0 || displayEnqueueMs >= 2.0 {
                print(
                    "PeelClientPerf rendererDisplayEnqueue",
                    "label=\(diagnosticLabel)",
                    "window=\(diagnosticWindowId ?? 0)",
                    "frame=\(frameIndex)",
                    "payload=\(payloadByteCount)",
                    "key=\(isKeyframe)",
                    "recoverBeforeMs=\(String(format: "%.2f", recoverBeforeMs))",
                    "displayEnqueueMs=\(String(format: "%.2f", displayEnqueueMs))",
                    "readyBefore=\(wasReady)",
                    "status=\(displayLayer.status.rawValue)"
                )
            }
            let recoverAfterStartMs = peelRendererPerfNowMs()
            recoverDisplayLayerIfNeeded(reason: "after enqueue")
            let recoverAfterMs = peelRendererPerfNowMs() - recoverAfterStartMs
            if !requiresKeyframe && displayLayer.status != .failed {
                onFrameEnqueued?(payloadByteCount, isKeyframe)
            }
            let drainStartMs = peelRendererPerfNowMs()
            drainPendingSampleBufferIfPossible(generation: generation)
            let drainMs = peelRendererPerfNowMs() - drainStartMs
            let liveMs = peelRendererPerfNowMs() - liveStartMs
            if liveMs >= 4.0 || recoverAfterMs >= 2.0 || drainMs >= 2.0 {
                print(
                    "PeelClientPerf rendererLiveImmediate",
                    "label=\(diagnosticLabel)",
                    "window=\(diagnosticWindowId ?? 0)",
                    "frame=\(frameIndex)",
                    "payload=\(payloadByteCount)",
                    "key=\(isKeyframe)",
                    "liveMs=\(String(format: "%.2f", liveMs))",
                    "recoverBeforeMs=\(String(format: "%.2f", recoverBeforeMs))",
                    "displayEnqueueMs=\(String(format: "%.2f", displayEnqueueMs))",
                    "recoverAfterMs=\(String(format: "%.2f", recoverAfterMs))",
                    "drainMs=\(String(format: "%.2f", drainMs))",
                    "readyBefore=\(wasReady)",
                    "readyAfter=\(displayLayer.isReadyForMoreMediaData)",
                    "status=\(displayLayer.status.rawValue)"
                )
            }
            return
        }

        PeelClientDiagnostics.logRendererFrame(
            
            label: diagnosticLabel,
            windowId: diagnosticWindowId,
            action: "pendingStore",
            frameIndex: frameIndex,
            payloadByteCount: payloadByteCount,
            isKeyframe: isKeyframe,
            mainHopMs: mainHopMs,
            displayReady: displayLayer.isReadyForMoreMediaData,
            layerStatus: String(describing: displayLayer.status)
        )

        let pendingStoreStartMs = peelRendererPerfNowMs()
        pendingSampleBuffer = sampleBuffer
        pendingQueuedAt = ProcessInfo.processInfo.systemUptime
        pendingFrameIndex = frameIndex
        pendingIsKeyframe = isKeyframe
        pendingPayloadByteCount = payloadByteCount
        schedulePendingDrain(generation: generation)
        let pendingStoreMs = peelRendererPerfNowMs() - pendingStoreStartMs
        let liveMs = peelRendererPerfNowMs() - liveStartMs
        if liveMs >= 4.0 || pendingStoreMs >= 2.0 {
            print(
                "PeelClientPerf rendererLivePending",
                "label=\(diagnosticLabel)",
                "window=\(diagnosticWindowId ?? 0)",
                "frame=\(frameIndex)",
                "payload=\(payloadByteCount)",
                "key=\(isKeyframe)",
                "liveMs=\(String(format: "%.2f", liveMs))",
                "pendingStoreMs=\(String(format: "%.2f", pendingStoreMs))",
                "replaced=false",
                "ready=\(displayLayer.isReadyForMoreMediaData)",
                "status=\(displayLayer.status.rawValue)"
            )
        }
    }

    private func drainPendingSampleBufferIfPossible(generation: UInt64? = nil) {
        let drainPerfStartMs = peelRendererPerfNowMs()
        if let generation, !isCurrentLifecycleGeneration(generation) { return }
        guard currentLifecycleGenerationIfValid() != nil else { return }

        // A decoder that never becomes ready must not retain an old frame and
        // poll forever after the sender stops producing. Apply the same live
        // deadline as the ingress queue before testing decoder readiness.
        guard pendingSampleBuffer != nil else { return }
        if pendingQueuedAt.map({ ProcessInfo.processInfo.systemUptime - $0 > maximumQueueAge }) ?? true {
            enterRecoveryKeyframeWait()
            return
        }

        recoverDisplayLayerIfNeeded(reason: "before drain")

        guard displayLayer.status != .failed else {
            PeelClientDiagnostics.logRendererEvent(
                
                label: diagnosticLabel,
                windowId: diagnosticWindowId,
                reason: "drop pending displayLayer failed before drain",
                frameIndex: pendingFrameIndex,
                payloadByteCount: pendingPayloadByteCount,
                status: String(describing: displayLayer.error?.localizedDescription ?? "no error")
            )
            if pendingSampleBuffer != nil { streamingDiagnostics.dropped() }
            pendingSampleBuffer = nil
            pendingFrameIndex = nil
            return
        }

        guard displayLayer.isReadyForMoreMediaData || !hasEnqueuedFirstFrame else {
            PeelClientDiagnostics.logRendererEvent(
                
                label: diagnosticLabel,
                windowId: diagnosticWindowId,
                reason: "pending drain still not ready",
                frameIndex: pendingFrameIndex,
                payloadByteCount: pendingPayloadByteCount,
                status: "ready=\(displayLayer.isReadyForMoreMediaData) layer=\(displayLayer.status)",
                interval: 1.0
            )
            schedulePendingDrain(generation: generation)
            return
        }

        guard let sampleBuffer = pendingSampleBuffer else {
            return
        }

        let frameIndex = pendingFrameIndex ?? -1
        let isKeyframe = pendingIsKeyframe
        let payloadByteCount = pendingPayloadByteCount

        pendingSampleBuffer = nil
        pendingFrameIndex = nil
        pendingIsKeyframe = false
        pendingPayloadByteCount = 0

        let wasReady = displayLayer.isReadyForMoreMediaData
        let displayEnqueueStartMs = peelRendererPerfNowMs()
        displayLayer.enqueue(sampleBuffer)
        streamingDiagnostics.enqueued()
        let displayEnqueueMs = peelRendererPerfNowMs() - displayEnqueueStartMs
        hasEnqueuedFirstFrame = true

        PeelClientDiagnostics.logRendererFrame(
            
            label: diagnosticLabel,
            windowId: diagnosticWindowId,
            action: "pendingDrain",
            frameIndex: frameIndex,
            payloadByteCount: payloadByteCount,
            isKeyframe: isKeyframe,
            mainHopMs: nil,
            displayReady: wasReady,
            layerStatus: String(describing: displayLayer.status)
        )

        recoverDisplayLayerIfNeeded(reason: "after drain")
        if !requiresKeyframe && displayLayer.status != .failed {
            onFrameEnqueued?(payloadByteCount, isKeyframe)
        }
        let drainPerfMs = peelRendererPerfNowMs() - drainPerfStartMs
        if drainPerfMs >= 4.0 || displayEnqueueMs >= 2.0 {
            print(
                "PeelClientPerf rendererPendingDrain",
                "label=\(diagnosticLabel)",
                "window=\(diagnosticWindowId ?? 0)",
                "frame=\(frameIndex)",
                "payload=\(payloadByteCount)",
                "key=\(isKeyframe)",
                "drainMs=\(String(format: "%.2f", drainPerfMs))",
                "displayEnqueueMs=\(String(format: "%.2f", displayEnqueueMs))",
                "readyBefore=\(wasReady)",
                "readyAfter=\(displayLayer.isReadyForMoreMediaData)",
                "status=\(displayLayer.status.rawValue)"
            )
        }
    }

    private func enterRecoveryKeyframeWait() {
        if pendingSampleBuffer != nil { streamingDiagnostics.dropped() }
        streamingDiagnostics.resetPresentation()
        pendingSampleBuffer = nil
        pendingFrameIndex = nil
        pendingIsKeyframe = false
        pendingPayloadByteCount = 0
        isDrainScheduled = false
        waitingForRecoveryKeyframe = true
        requiresKeyframe = true
        hasEnqueuedFirstFrame = false
        displayLayer.flush()
        requestRecoveryKeyframeIfNeeded()
    }

    private func requestRecoveryKeyframeIfNeeded() {
        guard let generation = currentLifecycleGenerationIfValid(),
              waitingForRecoveryKeyframe, requiresKeyframe else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if !isEmittingRecoveryKeyframeRequest, now - lastRecoveryRequestAt >= 0.25 {
            cancelDeferredRecoveryKeyframeRequest()
            emitRecoveryKeyframeRequest(generation: generation)
            return
        }

        lifecycleLock.lock()
        guard !isInvalidated, lifecycleGeneration == generation,
              deferredRecoveryRequestToken == nil else {
            lifecycleLock.unlock()
            return
        }
        let token = UUID()
        deferredRecoveryRequestToken = token
        lifecycleLock.unlock()
        // A callback may submit late and reenter after 250ms. Its completion,
        // including across a reentrant lifecycle change, owns the next deadline.
        guard !isEmittingRecoveryKeyframeRequest else { return }
        scheduleDeferredRecoveryKeyframeRequest(token: token, generation: generation,
            deadline: lastRecoveryRequestAt + 0.25)
    }

    private func cancelDeferredRecoveryKeyframeRequest() {
        lifecycleLock.lock()
        deferredRecoveryRequestToken = nil
        lifecycleLock.unlock()
    }

    private func retireDeferredRecoveryKeyframeRequest(token: UUID, generation: UInt64) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard !isInvalidated, lifecycleGeneration == generation,
              deferredRecoveryRequestToken == token else { return false }
        deferredRecoveryRequestToken = nil
        return true
    }

    private func scheduleDeferredRecoveryKeyframeRequest(
        token: UUID, generation: UInt64, deadline: TimeInterval
    ) {
        // The limiter and dispatch timer need not expose identical epochs.
        // Round a finite remaining delay UP; check the limiter clock at firing.
        let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        let nanoseconds = (remaining * 1_000_000_000).rounded(.up)
        guard deadline.isFinite, nanoseconds.isFinite, nanoseconds >= 0,
              nanoseconds < Double(UInt64.max) else {
            _ = retireDeferredRecoveryKeyframeRequest(token: token, generation: generation)
            return
        }
        let (dispatchDeadline, overflow) = DispatchTime.now().uptimeNanoseconds
            .addingReportingOverflow(UInt64(nanoseconds))
        guard !overflow else {
            _ = retireDeferredRecoveryKeyframeRequest(token: token, generation: generation)
            return
        }
        lifecycleLock.lock()
        let ownsIntent = !isInvalidated && lifecycleGeneration == generation &&
            deferredRecoveryRequestToken == token
        lifecycleLock.unlock()
        guard ownsIntent else { return }
        DispatchQueue.main.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: dispatchDeadline)) { [weak self] in
            guard let self else { return }
            self.lifecycleLock.lock()
            let ownsIntent = !self.isInvalidated && self.lifecycleGeneration == generation &&
                self.deferredRecoveryRequestToken == token
            self.lifecycleLock.unlock()
            guard ownsIntent, !self.isEmittingRecoveryKeyframeRequest,
                  self.waitingForRecoveryKeyframe, self.requiresKeyframe else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now >= deadline, now - self.lastRecoveryRequestAt >= 0.25 else { return }
            guard self.retireDeferredRecoveryKeyframeRequest(token: token, generation: generation) else { return }
            self.emitRecoveryKeyframeRequest(generation: generation)
        }
    }

    private func emitRecoveryKeyframeRequest(generation: UInt64) {
        guard isCurrentLifecycleGeneration(generation), !isEmittingRecoveryKeyframeRequest,
              waitingForRecoveryKeyframe, requiresKeyframe else { return }
        // This physical callback may outlive a reentrant config/reset. Keep the
        // flag until it returns; a new generation still cannot submit recursively.
        isEmittingRecoveryKeyframeRequest = true
        lastRecoveryRequestAt = ProcessInfo.processInfo.systemUptime
        streamingDiagnostics.requestedRecovery()
        onRecoveryKeyframeNeeded?()
        lastRecoveryRequestAt = max(lastRecoveryRequestAt, ProcessInfo.processInfo.systemUptime)
        isEmittingRecoveryKeyframeRequest = false
        lifecycleLock.lock()
        let pendingToken = isInvalidated ? nil : deferredRecoveryRequestToken
        let pendingGeneration = lifecycleGeneration
        lifecycleLock.unlock()
        // Only the exact current pending intent is scheduled. Never overwrite
        // a token installed by the callback or restore an old lifecycle's token.
        if let pendingToken {
            scheduleDeferredRecoveryKeyframeRequest(token: pendingToken, generation: pendingGeneration,
                deadline: lastRecoveryRequestAt + 0.25)
        }
    }

    private func prepareForRecoveryKeyframe() {
        cancelDeferredRecoveryKeyframeRequest()
        if pendingSampleBuffer != nil { streamingDiagnostics.dropped() }
        streamingDiagnostics.resetPresentation()
        pendingSampleBuffer = nil
        pendingFrameIndex = nil
        pendingIsKeyframe = false
        pendingPayloadByteCount = 0
        isDrainScheduled = false
        waitingForRecoveryKeyframe = false
        requiresKeyframe = false
        hasEnqueuedFirstFrame = false
        displayLayer.flush()
    }

    private func schedulePendingDrain(generation: UInt64? = nil) {
        guard pendingSampleBuffer != nil, !isDrainScheduled else { return }
        guard let scheduledGeneration = generation ?? currentLifecycleGenerationIfValid() else { return }

        isDrainScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { [weak self] in
            guard let self, self.isCurrentLifecycleGeneration(scheduledGeneration) else { return }
            self.isDrainScheduled = false
            self.drainPendingSampleBufferIfPossible(generation: scheduledGeneration)
        }
    }

    /// Called by the session's bounded metrics cadence on the main queue.
    /// Async AV callbacks update only the generation-scoped, thread-safe store.
    func refreshStreamingPerformanceMetrics() {
#if os(visionOS) && DEBUG
        if ProcessInfo.processInfo.arguments.contains("--peel-quality-fixture-v1"),
           let generation = currentLifecycleGenerationIfValid(),
           let pixelBuffer = displayLayer.sampleBufferRenderer.displayedPixelBuffer() {
            displayedFixtureDiagnostics.sample(pixelBuffer, generation: generation)
        }
#endif
        let collector = streamingDiagnostics
        guard let requestToken = collector.beginPerformanceCollection() else { return }
        if #available(iOS 17.4, macOS 14.4, visionOS 1.1, *) {
            displayLayer.sampleBufferRenderer.loadVideoPerformanceMetrics { metrics in
                let sample = metrics.map {
                    PeelClientVideoDiagnostics.AVSample(total: Int64($0.totalNumberOfFrames),
                        dropped: Int64($0.numberOfDroppedFrames), corrupted: Int64($0.numberOfCorruptedFrames),
                        optimized: Int64($0.numberOfFramesDisplayedUsingOptimizedCompositing),
                        accumulatedDelay: $0.totalAccumulatedFrameDelay)
                }
                collector.completePerformanceCollection(requestToken: requestToken, sample: sample)
            }
        } else {
            collector.completePerformanceCollection(requestToken: requestToken, sample: nil)
        }
    }

    /// A conventional renderer must never stand in for the visible spatial path.
    func streamingDiagnosticSnapshot(windowId: UInt32, spatial: Bool) -> PeelClientStreamMetric? {
        queuedFrameLock.lock()
        let queueCount = queuedRenderFrames.count
        let queueBytes = queuedPayloadBytes
        let queueStart = queuedRenderFrames.first?.queuedAt
        queuedFrameLock.unlock()
        let hasPending = pendingSampleBuffer != nil
        let earliest = [queueStart, hasPending ? pendingQueuedAt : nil].compactMap { $0 }.min()
        let age = earliest.map { max(0, ProcessInfo.processInfo.systemUptime - $0) * 1000 }
        #if canImport(UIKit)
        let screenMaximumFPS = spatial ? nil : VideoLayerContainerView.screenMaximumFPS(for: displayLayer)
        #else
        let screenMaximumFPS: Int? = nil
        #endif
        var row = streamingDiagnostics.snapshot(windowId: windowId,
            rendererKind: spatial ? .spatialUninstrumented : .displayLayer,
            queuedFrames: queueCount + (hasPending ? 1 : 0),
            queuedBytes: queueBytes + (hasPending ? pendingPayloadByteCount : 0),
            oldestQueuedAgeMilliseconds: age, screenMaximumFPS: screenMaximumFPS,
            displayLayerStatus: displayLayer.status.rawValue,
            displayLayerRequiresFlush: displayLayer.requiresFlushToResumeDecoding,
            displayLayerErrorCode: (displayLayer.error as NSError?)?.code)
#if os(visionOS)
        if !spatial { row?.displayedFixtureQuality = displayedFixtureDiagnostics.snapshot() }
#endif
        return row
    }

    private func recoverDisplayLayerIfNeeded(reason: String) {
        guard currentLifecycleGenerationIfValid() != nil else { return }

        if displayLayer.status == .failed || displayLayer.requiresFlushToResumeDecoding {
            PeelClientDiagnostics.logRendererEvent(
                
                label: diagnosticLabel,
                windowId: diagnosticWindowId,
                reason: "flush displayLayer",
                status: "reason=\(reason) layer=\(displayLayer.status) requiresFlush=\(displayLayer.requiresFlushToResumeDecoding) error=\(displayLayer.error?.localizedDescription ?? "nil")",
                interval: 0.5
            )
            enterRecoveryKeyframeWait()
        }
    }

    private func makeSampleBuffer(
        payload: Data,
        formatDescription: CMVideoFormatDescription,
        pts: CMTime,
        duration: CMTime,
        isKeyframe: Bool
    ) -> CMSampleBuffer? {
        let samplePerfStartMs = peelRendererPerfNowMs()
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
            print("PeelClient: CMBlockBufferCreateWithMemoryBlock failed, status=\(createStatus)")
            return nil
        }

        let blockMs = peelRendererPerfNowMs() - samplePerfStartMs
        let replaceStartMs = peelRendererPerfNowMs()
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
            print("PeelClient: CMBlockBufferReplaceDataBytes failed, status=\(replaceStatus)")
            return nil
        }

        let replaceMs = peelRendererPerfNowMs() - replaceStartMs

        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        var sampleSize = payload.count
        var sampleBuffer: CMSampleBuffer?

        let createReadyStartMs = peelRendererPerfNowMs()
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
            print("PeelClient: CMSampleBufferCreateReady failed, status=\(sbStatus)")
            return nil
        }

        let createReadyMs = peelRendererPerfNowMs() - createReadyStartMs
        let attachmentsStartMs = peelRendererPerfNowMs()

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let attachmentCount = CFArrayGetCount(attachments)
            if attachmentCount > 0 {
                let raw = CFArrayGetValueAtIndex(attachments, 0)
                let dict = unsafeBitCast(raw, to: CFMutableDictionary.self)
                let notSyncValue: CFBoolean = isKeyframe ? kCFBooleanFalse : kCFBooleanTrue
                CFDictionarySetValue(
                    dict,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                    Unmanaged.passUnretained(notSyncValue).toOpaque()
                )

                // Peel is a live remote-control stream, not movie playback.
                // Host PTS values should not make AVSampleBufferDisplayLayer wait/stall.
                CFDictionarySetValue(
                    dict,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }
        }

        let attachmentsMs = peelRendererPerfNowMs() - attachmentsStartMs
        let totalMs = peelRendererPerfNowMs() - samplePerfStartMs
        if totalMs >= 3.0 || payload.count >= 96 * 1024 {
            print(
                "PeelClientPerf rendererSampleBuffer",
                "payload=\(payload.count)",
                "key=\(isKeyframe)",
                "totalMs=\(String(format: "%.2f", totalMs))",
                "blockMs=\(String(format: "%.2f", blockMs))",
                "replaceMs=\(String(format: "%.2f", replaceMs))",
                "createReadyMs=\(String(format: "%.2f", createReadyMs))",
                "attachmentsMs=\(String(format: "%.2f", attachmentsMs))"
            )
        }
        return sampleBuffer
    }
}

#if canImport(UIKit)
struct CompressedVideoLayerView: UIViewRepresentable {
    let renderer: CompressedVideoRenderer
    var fillsAvailableBounds: Bool = false

    func makeUIView(context: Context) -> VideoLayerContainerView {
        let view = VideoLayerContainerView()
        view.attach(renderer.displayLayer, fillsAvailableBounds: fillsAvailableBounds)
        return view
    }

    func updateUIView(_ uiView: VideoLayerContainerView, context: Context) {
        uiView.attach(renderer.displayLayer, fillsAvailableBounds: fillsAvailableBounds)
    }

    static func dismantleUIView(_ uiView: VideoLayerContainerView, coordinator: ()) {
        uiView.detachCurrentLayerIfStillOwned()
    }
}

final class VideoLayerContainerView: UIView {
    private weak var attachedLayerRef: AVSampleBufferDisplayLayer?
    private var fillsAvailableBounds: Bool = false

    /// Inspect the layer's current owner instead of retaining a stale view or
    /// assuming the app's main screen. Capability is not presentation cadence.
    static func screenMaximumFPS(for layer: AVSampleBufferDisplayLayer) -> Int? {
        #if os(visionOS)
        return nil // Window scenes expose no public UIScreen on visionOS.
        #else
        guard Thread.isMainThread,
              let owner = layer.superlayer?.delegate as? VideoLayerContainerView,
              owner.attachedLayerRef === layer, layer.superlayer === owner.layer,
              let maximum = owner.window?.windowScene?.screen.maximumFramesPerSecond,
              (1...1000).contains(maximum) else { return nil }
        return maximum
        #endif
    }

    /// Re-read the actual owner at each socket hello; never substitute UIScreen.main.
    static func receiverDisplayCapabilities(for layer: AVSampleBufferDisplayLayer) -> PeelReceiverDisplayCapabilities? {
#if os(iOS)
        guard let fps = screenMaximumFPS(for: layer),
              let owner = layer.superlayer?.delegate as? VideoLayerContainerView,
              let window = owner.window, !window.isHidden,
              let scene = window.windowScene, scene.activationState == .foregroundActive else { return nil }
        let size = scene.screen.nativeBounds.size
        guard size.width.isFinite, size.height.isFinite,
              size.width >= 1, size.height >= 1,
              size.width <= 16_384, size.height <= 16_384 else { return nil }
        let result = PeelReceiverDisplayCapabilities(pixelWidth: Int(size.width),
            pixelHeight: Int(size.height), maximumFPS: fps)
        return result.isValid ? result : nil
#else
        return nil // No public per-window screen capability on visionOS.
#endif
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attach(_ layer: AVSampleBufferDisplayLayer, fillsAvailableBounds: Bool) {
        if Thread.isMainThread {
            attachOnMain(layer, fillsAvailableBounds: fillsAvailableBounds)
        } else {
            DispatchQueue.main.async { [weak self, weak layer] in
                guard let self, let layer else { return }
                self.attachOnMain(layer, fillsAvailableBounds: fillsAvailableBounds)
            }
        }
    }

    func detachCurrentLayerIfStillOwned() {
        if Thread.isMainThread {
            detachCurrentLayerIfStillOwnedOnMain()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.detachCurrentLayerIfStillOwnedOnMain()
            }
        }
    }

    private func attachOnMain(_ layer: AVSampleBufferDisplayLayer, fillsAvailableBounds: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))

        self.fillsAvailableBounds = fillsAvailableBounds

        guard attachedLayerRef !== layer || layer.superlayer !== self.layer else {
            applyLayerLayout()
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if let currentLayer = attachedLayerRef, currentLayer !== layer,
           currentLayer.superlayer === self.layer {
            currentLayer.removeFromSuperlayer()
        }

        if layer.superlayer !== self.layer {
            layer.removeFromSuperlayer()
            self.layer.addSublayer(layer)
        }

        attachedLayerRef = layer
        applyLayerLayout()

        CATransaction.commit()
    }

    private func detachCurrentLayerIfStillOwnedOnMain() {
        dispatchPrecondition(condition: .onQueue(.main))

        guard let attachedLayerRef, attachedLayerRef.superlayer === self.layer else {
            self.attachedLayerRef = nil
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        attachedLayerRef.removeFromSuperlayer()
        CATransaction.commit()

        self.attachedLayerRef = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyLayerLayout()
    }

    private func applyLayerLayout() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.applyLayerLayout()
            }
            return
        }

        guard let attachedLayerRef, attachedLayerRef.superlayer === layer else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        attachedLayerRef.videoGravity = fillsAvailableBounds ? .resizeAspectFill : .resizeAspect
        attachedLayerRef.frame = bounds
        CATransaction.commit()
    }
}
#endif


/// Weak renderer inventory avoids reading mutable media dictionaries from the
/// metrics timer. Collection never retains pixels or extends renderer lifetime.
nonisolated final class PeelClientStreamDiagnosticsReporter: @unchecked Sendable {
    struct Batch {
        let sequence: UInt64
        let entries: [(windowId: UInt32, renderer: CompressedVideoRenderer)]
        let untracked: Int64
    }
    private struct Entry {
        weak var renderer: CompressedVideoRenderer?
        let collector: PeelClientVideoDiagnostics
    }
    private let lock = NSLock()
    private var entries: [UInt32: Entry] = [:]
    private var sequence: UInt64 = 0
    private var lastReportAt: Double?
    private var untracked: Int64 = 0
    private var reportScheduled = false
    let clock = PeelStreamClockTracker()

    func beginScheduledReport() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !reportScheduled else { return false }
        reportScheduled = true
        return true
    }

    func finishScheduledReport() {
        lock.lock(); defer { lock.unlock() }; reportScheduled = false
    }

    func register(windowId: UInt32, renderer: CompressedVideoRenderer, collector: PeelClientVideoDiagnostics) {
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { $0.value.renderer != nil && $0.value.collector.isActive }
        if entries[windowId] == nil, entries.count >= PeelClientStreamMetricsMessage.maximumStreams {
            untracked += 1
            return
        }
        entries[windowId] = Entry(renderer: renderer, collector: collector)
    }

    func nextBatchIfDue() -> Batch? {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        guard sequence < UInt64(Int64.max), lastReportAt.map({ now - $0 >= 1 }) ?? true else { return nil }
        lastReportAt = now; sequence += 1
        entries = entries.filter { $0.value.renderer != nil && $0.value.collector.isActive }
        let live: [(windowId: UInt32, renderer: CompressedVideoRenderer)] = entries.keys.sorted().compactMap { id in
            entries[id]?.renderer.map { (id, $0) }
        }
        return Batch(sequence: sequence, entries: live, untracked: untracked)
    }
}
