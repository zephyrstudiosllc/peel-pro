//
//  PeelRemoteMacVideoRenderer.swift
//  Peel-Host
//
//  Host-side H.264/HEVC display layer renderer for the existing Peel wire.
//  The transport and input owners live elsewhere.
//

import Foundation
import AppKit
import AVFoundation
import CoreMedia
import QuartzCore
import SwiftUI

@inline(__always)
private func peelRemoteMacVideoPerfNowMs() -> Double {
    ProcessInfo.processInfo.systemUptime * 1000.0
}

private enum PeelRemoteMacVideoRendererDiagnostics {
    static func logRendererFrame(
        label: String,
        windowId: UInt32?,
        action: String,
        frameIndex: Int64,
        payloadByteCount: Int,
        isKeyframe: Bool,
        mainHopMs: Double?,
        displayReady: Bool,
        layerStatus: String
    ) {}

    static func logRendererEvent(
        label: String,
        windowId: UInt32?,
        reason: String,
        frameIndex: Int64? = nil,
        payloadByteCount: Int? = nil,
        status: String? = nil,
        interval: TimeInterval = 1.0
    ) {}
}

@MainActor final class PeelRemoteMacVideoRenderer {
    var onFormatChange: ((CGSize) -> Void)?
    var onFirstFrame: (() -> Void)?
    var onNeedsKeyframe: (() -> Void)?
    private let streamingDiagnostics = PeelRemoteMacStreamingDiagnostics()
    private var lastRecoveryRequestAt: TimeInterval = 0
    // Main-queue owned; survives lifecycle changes until the external callback returns.
    private var isEmittingRecoveryKeyframeRequest = false
    private(set) var requiresKeyframe = true
    var diagnosticWindowId: UInt32?
    var diagnosticLabel: String = "renderer"

    let layer: AVSampleBufferDisplayLayer = {
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
        let timing: PeelRemoteMacStreamingDiagnostics.FrameTiming?
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
    // Main-owned FIFO of frames waiting for display-layer readiness. Every
    // entry depends on its predecessors, so entries are never replaced or
    // skipped: only drained in order or retired together with recovery.
    private struct PendingFrame {
        let sampleBuffer: CMSampleBuffer
        let timing: PeelRemoteMacStreamingDiagnostics.FrameTiming?
        let frameIndex: Int64
        let isKeyframe: Bool
        let payloadByteCount: Int
        let arrivedAt: TimeInterval
    }
    private var pendingFrames: [PendingFrame] = []
    private var pendingPayloadBytes = 0
    private var pendingDiagnosticGeneration: UInt64?
    private var isDrainScheduled = false
    private var droppedBackpressureFrameCount: Int64 = 0
    private var hasEnqueuedFirstFrame = false
    private var hasNotifiedFirstFrame = false
    // Main-owned: lifecycle generation whose deferred main reset has run and
    // which has displayed a frame. Only then may enqueue drain without a hop.
    private var presentedGeneration: UInt64?
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

    func configure(_ packet: VideoConfigPacket) {
        let perfStartMs = peelRemoteMacVideoPerfNowMs()
        guard let generation = advanceLifecycleGeneration() else { return }

        streamingDiagnostics.invalidate()
        self.formatDescription = nil
        var formatDescription: CMFormatDescription?

        let formatStartMs = peelRemoteMacVideoPerfNowMs()
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
            print("PeelRemoteMacVideo: failed to create \(packet.codec) format description, status=\(status)")
            return
        }

        let formatMs = peelRemoteMacVideoPerfNowMs() - formatStartMs

        PeelRemoteMacVideoRendererDiagnostics.logRendererEvent(

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
        streamingDiagnostics.configure(width: Int(packet.width), height: Int(packet.height))

        let beforeMainDispatchMs = peelRemoteMacVideoPerfNowMs()
        let preMainMs = beforeMainDispatchMs - perfStartMs
        if preMainMs >= 4.0 || formatMs >= 2.0 {
            print(
                "PeelRemoteMacVideoPerf rendererConfig",
                "label=\(diagnosticLabel)",
                "window=\(diagnosticWindowId ?? packet.windowId)",
                "preMainMs=\(String(format: "%.2f", preMainMs))",
                "formatMs=\(String(format: "%.2f", formatMs))",
                "size=\(packet.width)x\(packet.height)"
            )
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentLifecycleGeneration(generation) else { return }

            let mainStartMs = peelRemoteMacVideoPerfNowMs()
            let mainHopMs = mainStartMs - beforeMainDispatchMs

            _ = self.clearPendingFrames()
            self.isDrainScheduled = false
            self.droppedBackpressureFrameCount = 0
            self.hasEnqueuedFirstFrame = false
            self.hasNotifiedFirstFrame = false
            self.waitingForRecoveryKeyframe = true
            self.requiresKeyframe = true
            self.streamingDiagnostics.resetPresentation()
            self.layer.flushAndRemoveImage()
            if sizeChanged {
                self.onFormatChange?(newSize)
            }
            let mainMs = peelRemoteMacVideoPerfNowMs() - mainStartMs
            if mainHopMs >= 16.0 || mainMs >= 4.0 {
                print(
                    "PeelRemoteMacVideoPerf rendererConfigMain",
                    "label=\(self.diagnosticLabel)",
                    "window=\(self.diagnosticWindowId ?? packet.windowId)",
                    "mainHopMs=\(String(format: "%.2f", mainHopMs))",
                    "mainMs=\(String(format: "%.2f", mainMs))",
                    "sizeChanged=\(sizeChanged)"
                )
            }
        }
    }

    func enqueue(_ packet: VideoFramePacket) {
        // Wire host PTS is diagnostic metadata only. The display sample below
        // deliberately retains the existing local sequential PTS/DisplayImmediately policy.
        let sourcePTS = packet.ptsValue >= 0 && timescale > 0 ? Double(packet.ptsValue) / Double(timescale) : nil
        let timing = streamingDiagnostics.received(bytes: packet.payload.count, sourcePTSSeconds: sourcePTS)
        let enqueueStartMs = peelRemoteMacVideoPerfNowMs()
        let enqueueStartAt = enqueueStartMs / 1000.0

        guard let generation = currentLifecycleGenerationIfValid() else {
            PeelRemoteMacVideoRendererDiagnostics.logRendererEvent(

                label: diagnosticLabel,
                windowId: diagnosticWindowId ?? packet.windowId,
                reason: "drop invalid lifecycle",
                payloadByteCount: packet.payload.count
            )
            return
        }

        guard let formatDescription else {
            streamingDiagnostics.dropped()
            PeelRemoteMacVideoRendererDiagnostics.logRendererEvent(

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

        let sampleStartMs = peelRemoteMacVideoPerfNowMs()
        guard let sampleBuffer = makeSampleBuffer(
            payload: packet.payload,
            formatDescription: formatDescription,
            pts: localPTS,
            duration: localDuration,
            isKeyframe: packet.isKeyframe
        ) else {
            streamingDiagnostics.dropped()
            PeelRemoteMacVideoRendererDiagnostics.logRendererEvent(

                label: diagnosticLabel,
                windowId: diagnosticWindowId ?? packet.windowId,
                reason: "drop makeSampleBuffer failed",
                frameIndex: frameIndex,
                payloadByteCount: packet.payload.count
            )
            return
        }

        let sampleMs = peelRemoteMacVideoPerfNowMs() - sampleStartMs
        let preMainMs = peelRemoteMacVideoPerfNowMs() - enqueueStartMs
        if sampleMs >= 3.0 || preMainMs >= 4.0 {
            print(
                "PeelRemoteMacVideoPerf rendererFrameBuild",
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
                payloadByteCount: packet.payload.count, queuedAt: now, timing: timing))
            queuedPayloadBytes += packet.payload.count
        } else {
            streamingDiagnostics.dropped()
        }
        let shouldScheduleRender = !renderTaskScheduled &&
            (!queuedRenderFrames.isEmpty || queueNeedsDecoderReset)
        if shouldScheduleRender { renderTaskScheduled = true }
        queuedFrameLock.unlock()
        guard shouldScheduleRender else { return }
        // Ingress already runs on the main actor. Once this generation's deferred
        // reset has run and presented, another main hop only adds queue wait and
        // makes the 80ms/3-frame bounds expire on main contention, not decoder
        // backlog, flushing and requesting keyframes into an already busy link.
        if presentedGeneration == generation {
            drainQueuedRender(generation: generation)
        } else {
            scheduleQueuedRender(generation: generation)
        }
    }

    private func scheduleQueuedRender(generation: UInt64) {
        DispatchQueue.main.async { [weak self] in self?.drainQueuedRender(generation: generation) }
    }

    private func drainQueuedRender(generation: UInt64) {
        guard isCurrentLifecycleGeneration(generation) else { return }
        // Yield the main queue after a bounded batch so touch and native controls
        // remain responsive even while the network is continuously producing.
        for _ in 0..<maximumQueuedFrames {
            // A display callback below may reenter reset/config/invalidate.
            guard isCurrentLifecycleGeneration(generation) else { return }
            queuedFrameLock.lock()
            guard queuedGeneration == generation else { queuedFrameLock.unlock(); return }
            let shouldReset = queueNeedsDecoderReset
            queueNeedsDecoderReset = false
            let frame = queuedRenderFrames.isEmpty ? nil : queuedRenderFrames.removeFirst()
            if let frame { queuedPayloadBytes -= frame.payloadByteCount }
            if frame == nil { renderTaskScheduled = false }
            queuedFrameLock.unlock()
            if shouldReset { enterRecoveryKeyframeWait() }
            guard isCurrentLifecycleGeneration(generation) else { return }
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
            streamingDiagnostics.drained(frame.timing)
            enqueueLiveSampleBuffer(frame.sampleBuffer, timing: frame.timing, frameIndex: frame.frameIndex,
                isKeyframe: frame.isKeyframe, payloadByteCount: frame.payloadByteCount,
                arrivedAt: frame.queuedAt)
        }
        queuedFrameLock.lock()
        let hasWork = queuedGeneration == generation && (!queuedRenderFrames.isEmpty || queueNeedsDecoderReset)
        if !hasWork { renderTaskScheduled = false }
        queuedFrameLock.unlock()
        if hasWork { scheduleQueuedRender(generation: generation) }
    }



    func reset() {
        guard let generation = advanceLifecycleGeneration() else { return }
        streamingDiagnostics.invalidate()

        formatDescription = nil
        timescale = 600
        nalUnitHeaderLength = 4
        codedSize = .zero
        localFrameIndex = 0

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentLifecycleGeneration(generation) else { return }

            _ = self.clearPendingFrames()
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
            self.hasNotifiedFirstFrame = false
            self.waitingForRecoveryKeyframe = true
            self.requiresKeyframe = true
            self.streamingDiagnostics.resetPresentation()
            self.layer.flushAndRemoveImage()
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

            _ = self.clearPendingFrames()
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
            self.hasNotifiedFirstFrame = false
            self.waitingForRecoveryKeyframe = true
            self.requiresKeyframe = true
            self.streamingDiagnostics.resetPresentation()
            self.layer.flushAndRemoveImage()
            self.layer.removeFromSuperlayer()
        }
    }

    private func notifyFirstFrameIfNeeded(generation: UInt64?) {
        // Callers run only from drains ordered after this generation's main reset.
        if let generation { presentedGeneration = generation }
        guard !hasNotifiedFirstFrame else { return }
        hasNotifiedFirstFrame = true
        onFirstFrame?()
    }

    private func enqueueLiveSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        timing: PeelRemoteMacStreamingDiagnostics.FrameTiming?,
        frameIndex: Int64,
        isKeyframe: Bool,
        payloadByteCount: Int,
        arrivedAt: TimeInterval
    ) {
        guard let generation = currentLifecycleGenerationIfValid() else { return }

        let liveStartMs = peelRemoteMacVideoPerfNowMs()
        let mainHopMs = max(0, ProcessInfo.processInfo.systemUptime - arrivedAt) * 1000

        let recoverBeforeStartMs = peelRemoteMacVideoPerfNowMs()
        recoverDisplayLayerIfNeeded(reason: "before enqueue")
        guard isCurrentLifecycleGeneration(generation) else { return }
        let recoverBeforeMs = peelRemoteMacVideoPerfNowMs() - recoverBeforeStartMs

        guard layer.status != .failed else {
            streamingDiagnostics.dropped()
            PeelRemoteMacVideoRendererDiagnostics.logRendererEvent(

                label: diagnosticLabel,
                windowId: diagnosticWindowId,
                reason: "drop layer failed before enqueue",
                frameIndex: frameIndex,
                payloadByteCount: payloadByteCount,
                status: String(describing: layer.error?.localizedDescription ?? "no error")
            )
            return
        }

        if !waitingForRecoveryKeyframe && !pendingFrames.isEmpty {
            // Older dependents go first. Expiry, decoder failure or a callback
            // lifecycle change inside the drain retires the whole chain.
            drainPendingFramesIfPossible(generation: generation)
            guard isCurrentLifecycleGeneration(generation) else { return }
            if isKeyframe && !waitingForRecoveryKeyframe && !pendingFrames.isEmpty {
                // A fresh keyframe needs no older reference: retire the
                // undisplayed chain and restart decoding at this frame.
                prepareForRecoveryKeyframe()
            }
        }

        // The nested drain may expire or fail and flush the reference chain.
        // Admit this incoming frame only after rechecking recovery state.
        if waitingForRecoveryKeyframe {
            guard isKeyframe else { streamingDiagnostics.dropped(); return }
            prepareForRecoveryKeyframe()
        }

        if pendingFrames.isEmpty && (layer.isReadyForMoreMediaData || !hasEnqueuedFirstFrame || isKeyframe) {
            let wasReady = layer.isReadyForMoreMediaData
            let displayEnqueueStartMs = peelRemoteMacVideoPerfNowMs()
            layer.enqueue(sampleBuffer)
            streamingDiagnostics.enqueued(timing)
            let displayEnqueueMs = peelRemoteMacVideoPerfNowMs() - displayEnqueueStartMs
            hasEnqueuedFirstFrame = true

            PeelRemoteMacVideoRendererDiagnostics.logRendererFrame(

                label: diagnosticLabel,
                windowId: diagnosticWindowId,
                action: "immediate",
                frameIndex: frameIndex,
                payloadByteCount: payloadByteCount,
                isKeyframe: isKeyframe,
                mainHopMs: mainHopMs,
                displayReady: wasReady,
                layerStatus: String(describing: layer.status)
            )

            if recoverBeforeMs >= 2.0 || displayEnqueueMs >= 2.0 {
                print(
                    "PeelRemoteMacVideoPerf rendererDisplayEnqueue",
                    "label=\(diagnosticLabel)",
                    "window=\(diagnosticWindowId ?? 0)",
                    "frame=\(frameIndex)",
                    "payload=\(payloadByteCount)",
                    "key=\(isKeyframe)",
                    "recoverBeforeMs=\(String(format: "%.2f", recoverBeforeMs))",
                    "displayEnqueueMs=\(String(format: "%.2f", displayEnqueueMs))",
                    "readyBefore=\(wasReady)",
                    "status=\(layer.status.rawValue)"
                )
            }
            let recoverAfterStartMs = peelRemoteMacVideoPerfNowMs()
            recoverDisplayLayerIfNeeded(reason: "after enqueue")
            let recoverAfterMs = peelRemoteMacVideoPerfNowMs() - recoverAfterStartMs
            if !requiresKeyframe && layer.status != .failed {
                notifyFirstFrameIfNeeded(generation: generation)
            }
            let drainStartMs = peelRemoteMacVideoPerfNowMs()
            drainPendingFramesIfPossible(generation: generation)
            let drainMs = peelRemoteMacVideoPerfNowMs() - drainStartMs
            let liveMs = peelRemoteMacVideoPerfNowMs() - liveStartMs
            if liveMs >= 4.0 || recoverAfterMs >= 2.0 || drainMs >= 2.0 {
                print(
                    "PeelRemoteMacVideoPerf rendererLiveImmediate",
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
                    "readyAfter=\(layer.isReadyForMoreMediaData)",
                    "status=\(layer.status.rawValue)"
                )
            }
            return
        }

        // The decoder is briefly busy or older dependents still wait. Keep the
        // complete chain in order within the existing frame/byte bounds; the
        // oldest arrival bounds its age. Overflow is a broken chain: recover.
        guard pendingFrames.count < maximumQueuedFrames,
              pendingPayloadBytes + payloadByteCount <= maximumQueuedBytes else {
            droppedBackpressureFrameCount += 1
            streamingDiagnostics.dropped()
            enterRecoveryKeyframeWait()
            return
        }

        PeelRemoteMacVideoRendererDiagnostics.logRendererFrame(

            label: diagnosticLabel,
            windowId: diagnosticWindowId,
            action: "pendingStore",
            frameIndex: frameIndex,
            payloadByteCount: payloadByteCount,
            isKeyframe: isKeyframe,
            mainHopMs: mainHopMs,
            displayReady: layer.isReadyForMoreMediaData,
            layerStatus: String(describing: layer.status)
        )

        let pendingStoreStartMs = peelRemoteMacVideoPerfNowMs()
        pendingFrames.append(PendingFrame(sampleBuffer: sampleBuffer, timing: timing,
            frameIndex: frameIndex, isKeyframe: isKeyframe,
            payloadByteCount: payloadByteCount, arrivedAt: arrivedAt))
        pendingPayloadBytes += payloadByteCount
        pendingDiagnosticGeneration = generation
        schedulePendingDrain(generation: generation)
        let pendingStoreMs = peelRemoteMacVideoPerfNowMs() - pendingStoreStartMs
        let liveMs = peelRemoteMacVideoPerfNowMs() - liveStartMs
        if liveMs >= 4.0 || pendingStoreMs >= 2.0 {
            print(
                "PeelRemoteMacVideoPerf rendererLivePending",
                "label=\(diagnosticLabel)",
                "window=\(diagnosticWindowId ?? 0)",
                "frame=\(frameIndex)",
                "payload=\(payloadByteCount)",
                "key=\(isKeyframe)",
                "liveMs=\(String(format: "%.2f", liveMs))",
                "pendingStoreMs=\(String(format: "%.2f", pendingStoreMs))",
                "pending=\(pendingFrames.count)",
                "ready=\(layer.isReadyForMoreMediaData)",
                "status=\(layer.status.rawValue)"
            )
        }
    }

    private func drainPendingFramesIfPossible(generation: UInt64? = nil) {
        let drainPerfStartMs = peelRemoteMacVideoPerfNowMs()
        guard let generation = generation ?? currentLifecycleGenerationIfValid(),
              isCurrentLifecycleGeneration(generation) else { return }

        // Bound the oldest pending frame even if the decoder remains busy after
        // the sender becomes idle. Expiry also stops the five-millisecond poll.
        guard let oldest = pendingFrames.first else { return }
        if ProcessInfo.processInfo.systemUptime - oldest.arrivedAt > maximumQueueAge {
            enterRecoveryKeyframeWait()
            return
        }

        recoverDisplayLayerIfNeeded(reason: "before drain")
        guard isCurrentLifecycleGeneration(generation), !pendingFrames.isEmpty else { return }

        guard layer.status != .failed else {
            PeelRemoteMacVideoRendererDiagnostics.logRendererEvent(

                label: diagnosticLabel,
                windowId: diagnosticWindowId,
                reason: "drop pending layer failed before drain",
                frameIndex: pendingFrames.first?.frameIndex,
                payloadByteCount: pendingPayloadBytes,
                status: String(describing: layer.error?.localizedDescription ?? "no error")
            )
            // Never discard dependent encoded frames without recovery.
            enterRecoveryKeyframeWait()
            return
        }

        var drainedCount = 0
        var lastDisplayEnqueueMs = 0.0
        while let frame = pendingFrames.first, layer.isReadyForMoreMediaData || !hasEnqueuedFirstFrame {
            pendingFrames.removeFirst()
            pendingPayloadBytes -= frame.payloadByteCount

            let wasReady = layer.isReadyForMoreMediaData
            let displayEnqueueStartMs = peelRemoteMacVideoPerfNowMs()
            layer.enqueue(frame.sampleBuffer)
            streamingDiagnostics.enqueued(frame.timing)
            lastDisplayEnqueueMs = peelRemoteMacVideoPerfNowMs() - displayEnqueueStartMs
            hasEnqueuedFirstFrame = true
            drainedCount += 1

            PeelRemoteMacVideoRendererDiagnostics.logRendererFrame(

                label: diagnosticLabel,
                windowId: diagnosticWindowId,
                action: "pendingDrain",
                frameIndex: frame.frameIndex,
                payloadByteCount: frame.payloadByteCount,
                isKeyframe: frame.isKeyframe,
                mainHopMs: nil,
                displayReady: wasReady,
                layerStatus: String(describing: layer.status)
            )

            // Failure recovery retires the remaining chain; a callback may
            // reenter reset/config/invalidate. Stop on either.
            recoverDisplayLayerIfNeeded(reason: "after drain")
            guard isCurrentLifecycleGeneration(generation), !waitingForRecoveryKeyframe else { return }
            if !requiresKeyframe && layer.status != .failed {
                notifyFirstFrameIfNeeded(generation: generation)
                guard isCurrentLifecycleGeneration(generation) else { return }
            }
        }

        if !pendingFrames.isEmpty {
            PeelRemoteMacVideoRendererDiagnostics.logRendererEvent(

                label: diagnosticLabel,
                windowId: diagnosticWindowId,
                reason: "pending drain still not ready",
                frameIndex: pendingFrames.first?.frameIndex,
                payloadByteCount: pendingPayloadBytes,
                status: "ready=\(layer.isReadyForMoreMediaData) layer=\(layer.status)",
                interval: 1.0
            )
            schedulePendingDrain(generation: generation)
        }

        let drainPerfMs = peelRemoteMacVideoPerfNowMs() - drainPerfStartMs
        if drainedCount > 0, drainPerfMs >= 4.0 || lastDisplayEnqueueMs >= 2.0 {
            print(
                "PeelRemoteMacVideoPerf rendererPendingDrain",
                "label=\(diagnosticLabel)",
                "window=\(diagnosticWindowId ?? 0)",
                "drained=\(drainedCount)",
                "remaining=\(pendingFrames.count)",
                "drainMs=\(String(format: "%.2f", drainPerfMs))",
                "displayEnqueueMs=\(String(format: "%.2f", lastDisplayEnqueueMs))",
                "readyAfter=\(layer.isReadyForMoreMediaData)",
                "status=\(layer.status.rawValue)"
            )
        }
    }

    @discardableResult
    private func clearPendingFrames() -> Int {
        let count = pendingFrames.count
        pendingFrames.removeAll(keepingCapacity: true)
        pendingPayloadBytes = 0
        pendingDiagnosticGeneration = nil
        return count
    }

    private func enterRecoveryKeyframeWait() {
        streamingDiagnostics.dropped(clearPendingFrames())
        isDrainScheduled = false
        waitingForRecoveryKeyframe = true
        requiresKeyframe = true
        hasEnqueuedFirstFrame = false
        streamingDiagnostics.resetPresentation()
        layer.flush()
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
        onNeedsKeyframe?()
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
        streamingDiagnostics.dropped(clearPendingFrames())
        isDrainScheduled = false
        waitingForRecoveryKeyframe = false
        requiresKeyframe = false
        hasEnqueuedFirstFrame = false
        streamingDiagnostics.resetPresentation()
        layer.flush()
    }

    private func schedulePendingDrain(generation: UInt64? = nil) {
        guard !pendingFrames.isEmpty, !isDrainScheduled else { return }
        guard let scheduledGeneration = generation ?? currentLifecycleGenerationIfValid() else { return }

        isDrainScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { [weak self] in
            guard let self, self.isCurrentLifecycleGeneration(scheduledGeneration) else { return }
            self.isDrainScheduled = false
            self.drainPendingFramesIfPossible(generation: scheduledGeneration)
        }
    }

    /// MainActor ingress intervals share the receiver uptime domain. Called once
    /// per rearmed network callback; this does not move framing off main.
    func recordIngressTiming(callbackAt: Double, mainAdmittedAt: Double, rearmedAt: Double, fullChunk: Bool) {
        streamingDiagnostics.ingress(callbackAt: callbackAt, mainAdmittedAt: mainAdmittedAt,
            rearmedAt: rearmedAt, fullChunk: fullChunk)
    }

    /// The existing >=2s control snapshot cadence permits at most one outstanding
    /// AV request. A late callback may release only its own generation's token.
    func refreshStreamingPerformanceMetrics() {
        let collector = streamingDiagnostics
        guard let token = collector.beginPerformanceCollection() else { return }
        if #available(macOS 14.4, *) {
            layer.sampleBufferRenderer.loadVideoPerformanceMetrics { metrics in
                let sample = metrics.map {
                    PeelRemoteMacStreamingDiagnostics.AVSample(total: Int64($0.totalNumberOfFrames),
                        dropped: Int64($0.numberOfDroppedFrames), corrupted: Int64($0.numberOfCorruptedFrames),
                        optimized: Int64($0.numberOfFramesDisplayedUsingOptimizedCompositing),
                        accumulatedDelay: $0.totalAccumulatedFrameDelay)
                }
                collector.completePerformanceCollection(requestToken: token, sample: sample)
            }
        } else {
            collector.completePerformanceCollection(requestToken: token, sample: nil)
        }
    }

    func streamingDiagnosticSnapshot(windowId: UInt32) -> PeelClientStreamMetric? {
        guard let generation = currentLifecycleGenerationIfValid() else { return nil }
        queuedFrameLock.lock()
        // A config advances lifecycle before its deferred layer flush. Old media can
        // remain retained until the next enqueue, but must not enter the new report.
        let currentQueue = queuedGeneration == generation
        let count = currentQueue ? queuedRenderFrames.count : 0
        let bytes = currentQueue ? queuedPayloadBytes : 0
        let started = currentQueue ? queuedRenderFrames.first?.queuedAt : nil
        queuedFrameLock.unlock()
        let pending = pendingDiagnosticGeneration == generation ? pendingFrames : []
        let oldest = [started, pending.first?.arrivedAt].compactMap { $0 }.min()
        let age = oldest.map { max(0, ProcessInfo.processInfo.systemUptime - $0) * 1000 }
        // No guessed main-screen refresh: the attached display is not tracked here.
        return streamingDiagnostics.snapshot(windowId: windowId,
            queuedFrames: count + pending.count, queuedBytes: bytes + pending.reduce(0) { $0 + $1.payloadByteCount },
            oldestQueuedAgeMilliseconds: age,
            displayLayerStatus: layer.status.rawValue, displayLayerRequiresFlush: layer.requiresFlushToResumeDecoding,
            displayLayerErrorCode: (layer.error as NSError?)?.code)
    }

    private func recoverDisplayLayerIfNeeded(reason: String) {
        guard currentLifecycleGenerationIfValid() != nil else { return }

        if layer.status == .failed || layer.requiresFlushToResumeDecoding {
            PeelRemoteMacVideoRendererDiagnostics.logRendererEvent(

                label: diagnosticLabel,
                windowId: diagnosticWindowId,
                reason: "flush layer",
                status: "reason=\(reason) layer=\(layer.status) requiresFlush=\(layer.requiresFlushToResumeDecoding) error=\(layer.error?.localizedDescription ?? "nil")",
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
        let samplePerfStartMs = peelRemoteMacVideoPerfNowMs()
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
            print("PeelRemoteMacVideo: CMBlockBufferCreateWithMemoryBlock failed, status=\(createStatus)")
            return nil
        }

        let blockMs = peelRemoteMacVideoPerfNowMs() - samplePerfStartMs
        let replaceStartMs = peelRemoteMacVideoPerfNowMs()
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
            print("PeelRemoteMacVideo: CMBlockBufferReplaceDataBytes failed, status=\(replaceStatus)")
            return nil
        }

        let replaceMs = peelRemoteMacVideoPerfNowMs() - replaceStartMs

        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        var sampleSize = payload.count
        var sampleBuffer: CMSampleBuffer?

        let createReadyStartMs = peelRemoteMacVideoPerfNowMs()
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
            print("PeelRemoteMacVideo: CMSampleBufferCreateReady failed, status=\(sbStatus)")
            return nil
        }

        let createReadyMs = peelRemoteMacVideoPerfNowMs() - createReadyStartMs
        let attachmentsStartMs = peelRemoteMacVideoPerfNowMs()

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

        let attachmentsMs = peelRemoteMacVideoPerfNowMs() - attachmentsStartMs
        let totalMs = peelRemoteMacVideoPerfNowMs() - samplePerfStartMs
        if totalMs >= 3.0 {
            print(
                "PeelRemoteMacVideoPerf rendererSampleBuffer",
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

struct PeelRemoteMacVideoLayerView: NSViewRepresentable {
    let renderer: PeelRemoteMacVideoRenderer
    var fillsAvailableBounds: Bool = false

    func makeNSView(context: Context) -> PeelRemoteMacVideoLayerContainer {
        let view = PeelRemoteMacVideoLayerContainer()
        view.attach(renderer.layer, fillsAvailableBounds: fillsAvailableBounds)
        return view
    }

    func updateNSView(_ nsView: PeelRemoteMacVideoLayerContainer, context: Context) {
        nsView.attach(renderer.layer, fillsAvailableBounds: fillsAvailableBounds)
    }

    static func dismantleNSView(_ nsView: PeelRemoteMacVideoLayerContainer, coordinator: ()) {
        nsView.detachCurrentLayerIfStillOwned()
    }
}

@MainActor
final class PeelRemoteMacVideoLayerContainer: NSView {
    private weak var attachedLayerRef: AVSampleBufferDisplayLayer?
    private var fillsAvailableBounds = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attach(_ rendererLayer: AVSampleBufferDisplayLayer, fillsAvailableBounds: Bool) {
        if Thread.isMainThread {
            attachOnMain(rendererLayer, fillsAvailableBounds: fillsAvailableBounds)
        } else {
            DispatchQueue.main.async { [weak self, weak rendererLayer] in
                guard let self, let rendererLayer else { return }
                self.attachOnMain(rendererLayer, fillsAvailableBounds: fillsAvailableBounds)
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

    private func attachOnMain(_ rendererLayer: AVSampleBufferDisplayLayer, fillsAvailableBounds: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.fillsAvailableBounds = fillsAvailableBounds

        guard let hostLayer = layer else { return }
        guard attachedLayerRef !== rendererLayer || rendererLayer.superlayer !== hostLayer else {
            applyLayerLayout()
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if let currentLayer = attachedLayerRef, currentLayer !== rendererLayer {
            currentLayer.removeFromSuperlayer()
        }

        if rendererLayer.superlayer !== hostLayer {
            rendererLayer.removeFromSuperlayer()
            hostLayer.addSublayer(rendererLayer)
        }

        attachedLayerRef = rendererLayer
        applyLayerLayout()
        CATransaction.commit()
    }

    private func detachCurrentLayerIfStillOwnedOnMain() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let attachedLayerRef, attachedLayerRef.superlayer === layer else {
            self.attachedLayerRef = nil
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        attachedLayerRef.removeFromSuperlayer()
        CATransaction.commit()
        self.attachedLayerRef = nil
    }

    override func layout() {
        super.layout()
        applyLayerLayout()
    }

    private func applyLayerLayout() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.applyLayerLayout()
            }
            return
        }

        guard let attachedLayerRef else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        attachedLayerRef.videoGravity = fillsAvailableBounds ? .resizeAspectFill : .resizeAspect
        attachedLayerRef.frame = bounds
        CATransaction.commit()
    }
}
