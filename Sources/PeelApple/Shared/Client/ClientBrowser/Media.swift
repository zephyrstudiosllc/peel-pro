//
//  Media.swift
//  Peel
//
//  Created by Zach on 5/25/26.
//


import Foundation
import Combine
import Network
import ImageIO
import AVFoundation
import VideoToolbox

#if canImport(UIKit)

import UIKit
#endif

@inline(__always)
private func peelMediaPerfNowMs() -> Double {
    Date.timeIntervalSinceReferenceDate * 1000.0
}

extension PeelClientBrowser {
    // Legacy name. For H.264 streaming, this starts the SCK/H.264 stream.
    func requestSnapshot(for window: PeelWindow) {
        requestStreamStart(windowId: window.windowId, reason: "view requested stream")
    }
    
    func requestStreamStart(windowId: UInt32, reason: String, force: Bool = false) {
        guard connection != nil, isConnectionReady else {
            return
        }

        if streamRepairInProgressWindowIds.contains(windowId), !force {
            return
        }

        if force {
            startedStreamWindowIds.remove(windowId)
            selectedSession?.startedStreamWindowIds.remove(windowId)
        } else if startedStreamWindowIds.contains(windowId) {
            return
        }

        resetVideoStreamReadiness(windowId: windowId)
        startedStreamWindowIds.insert(windowId)
        streamStartAttemptAtByWindow[windowId] = Date()
        PeelClientDiagnostics.logStreamEvent(ownerName: "browser", windowId: windowId, message: "startStream send reason=\(reason) force=\(force)")
        selectedSession?.startedStreamWindowIds.insert(windowId)
        selectedSession?.streamStartAttemptAtByWindow[windowId] = streamStartAttemptAtByWindow[windowId]

        selectedSession?.openVideoConnectionIfNeeded(windowId: windowId)

        let req = PeelRequest(type: "startStream", windowId: windowId)
        sendJSONMessage(req)
    }

    func resetVideoStreamReadiness(windowId: UInt32) {
        // Keep the last image, but retire callbacks from frames queued before
        // this attempt. A new videoConfig installs a new renderer and callback.
        videoRenderers[windowId]?.onFrameEnqueued = nil
        videoFrameCountByWindow[windowId] = 0
        videoLastFrameReceivedAtByWindow.removeValue(forKey: windowId)
        lastFrameAt.removeValue(forKey: windowId)
        videoReadyWindowIds.remove(windowId)
        selectedSession?.resetVideoStreamReadiness(windowId: windowId)
    }

    func reassertDesiredStreams(reason: String) {
        guard connection != nil, isConnectionReady else { return }

        for windowId in desiredPullWindowIds.sorted() {
            guard !startedStreamWindowIds.contains(windowId) else { continue }
            requestStreamStart(windowId: windowId, reason: reason)
        }
    }

    func repairStream(windowId: UInt32, reason: String) {
        guard desiredPullWindowIds.contains(windowId) else { return }
        guard isClientVisible, let repairConnection = connection, isConnectionReady else {
            startedStreamWindowIds.remove(windowId)
            selectedSession?.startedStreamWindowIds.remove(windowId)
            return
        }

        let now = Date()

        if let lastRepair = streamLastRepairAtByWindow[windowId],
           now.timeIntervalSince(lastRepair) < streamRepairCooldown {
            return
        }

        streamLastRepairAtByWindow[windowId] = now
        selectedSession?.streamLastRepairAtByWindow[windowId] = now
        PeelClientDiagnostics.logStreamEvent(ownerName: "browser", windowId: windowId, message: "repair begin reason=\(reason)")

        let attempt = (streamRepairAttemptByWindow[windowId] ?? 0) + 1
        streamRepairAttemptByWindow[windowId] = attempt
        selectedSession?.streamRepairAttemptByWindow[windowId] = attempt

        if attempt > maxStreamRepairsBeforeReconnect {
            PeelClientDiagnostics.logStreamEvent(ownerName: "browser", windowId: windowId, message: "repair escalating to reconnect attempt=\(attempt) reason=\(reason)")
            reconnectForStreamRepair(windowId: windowId, reason: reason)
            return
        }


        startedStreamWindowIds.remove(windowId)
        streamStartAttemptAtByWindow[windowId] = now
        videoConfigReceivedAtByWindow.removeValue(forKey: windowId)
        selectedSession?.startedStreamWindowIds.remove(windowId)
        selectedSession?.streamStartAttemptAtByWindow[windowId] = now
        selectedSession?.videoConfigReceivedAtByWindow.removeValue(forKey: windowId)

        // This is a new stream attempt. Do not let stale state make the UI think video is alive.
        lastFrameAt.removeValue(forKey: windowId)
        videoFrameCountByWindow[windowId] = 0
        videoLastFrameByteCountByWindow.removeValue(forKey: windowId)
        videoLastFrameWasKeyframeByWindow.removeValue(forKey: windowId)
        videoLastFrameReceivedAtByWindow.removeValue(forKey: windowId)
        selectedSession?.lastFrameAt.removeValue(forKey: windowId)
        selectedSession?.videoFrameCountByWindow[windowId] = 0
        selectedSession?.videoLastFrameByteCountByWindow.removeValue(forKey: windowId)
        selectedSession?.videoLastFrameWasKeyframeByWindow.removeValue(forKey: windowId)
        selectedSession?.videoLastFrameReceivedAtByWindow.removeValue(forKey: windowId)
        DispatchQueue.main.async {
            self.videoReadyWindowIds.remove(windowId)
            self.selectedSession?.videoReadyWindowIds.remove(windowId)
        }

        videoRenderers[windowId]?.flushAndReset()

        streamRepairInProgressWindowIds.insert(windowId)
        selectedSession?.streamRepairInProgressWindowIds.insert(windowId)

        // Existing host contract: stop the possibly wedged stream, then start a fresh one.
        selectedSession?.closeVideoConnection(windowId: windowId, reason: "repair restart")
        sendJSONMessage(PeelRequest(type: "stopStream", windowId: windowId))

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            guard let self else { return }
            guard self.connection === repairConnection,
                  self.streamLastRepairAtByWindow[windowId] == now else { return }
            guard self.isClientVisible, self.desiredPullWindowIds.contains(windowId),
                  self.isConnectionReady else {
                self.streamRepairInProgressWindowIds.remove(windowId)
                self.selectedSession?.streamRepairInProgressWindowIds.remove(windowId)
                return
            }

            self.requestStreamStart(
                windowId: windowId,
                reason: "repair restart after \(reason)",
                force: true
            )

            self.streamRepairInProgressWindowIds.remove(windowId)
            self.selectedSession?.streamRepairInProgressWindowIds.remove(windowId)
        }
    }

    func reconnectForStreamRepair(windowId: UInt32, reason: String) {
        streamRepairAttemptByWindow[windowId] = 0
        selectedSession?.streamRepairAttemptByWindow[windowId] = 0
        handleDisconnectOnce("stream repair reconnect: \(reason)")
    }

    func decodeUInt32(from slice: Data) -> UInt32 {
        var value: UInt32 = 0
        slice.withUnsafeBytes { rawPtr in
            memcpy(&value, rawPtr.baseAddress!, 4)
        }
        return UInt32(littleEndian: value)
    }
    
    func decodeInt64(from slice: Data) -> Int64 {
        var value: Int64 = 0
        slice.withUnsafeBytes { rawPtr in
            memcpy(&value, rawPtr.baseAddress!, 8)
        }
        return Int64(littleEndian: value)
    }
    
    func isKnownBinaryLeadByte(_ byte: UInt8?) -> Bool {
        guard let byte else { return false }
        return byte == PeelBinaryPacketType.jpegFrame.rawValue ||
        byte == PeelBinaryPacketType.videoConfig.rawValue ||
        byte == PeelBinaryPacketType.hevcVideoConfig.rawValue ||
        byte == PeelBinaryPacketType.videoFrame.rawValue
    }

    // MARK: - JPEG decode helpers


    func snapshotCGImage(for windowId: UInt32) -> CGImage? {
        snapshotCGImages[windowId]
    }

#if canImport(UIKit)
    func appIconImage(for window: PeelWindow) -> UIImage? {
        guard let base64 = window.appIconPNGBase64,
              !base64.isEmpty else {
            return nil
        }

        if let cached = appIconImageCache[base64] {
            return cached
        }

        guard let data = Data(base64Encoded: base64),
              let image = UIImage(data: data) else {
            return nil
        }

        appIconImageCache[base64] = image
        return image
    }
#endif
    
    func videoRenderer(for windowId: UInt32) -> CompressedVideoRenderer? {
        videoRenderers[windowId]
    }
#if os(visionOS)
func spatialVideoRenderer(for windowId: UInt32) -> SpatialCompressedVideoRenderer {
    if let existing = spatialVideoRenderers[windowId] {
        return existing
    }

    let renderer = SpatialCompressedVideoRenderer()
    renderer.diagnosticClock = streamDiagnosticReporter.clock
    spatialVideoRenderers[windowId] = renderer

    if let config = latestVideoConfigByWindow[windowId] {
        renderer.applyConfig(config)
    }

    return renderer
}

func deactivateSpatialVideoRenderer(for windowId: UInt32) {
    activeSpatialWindowIds.remove(windowId)
    if let renderer = spatialVideoRenderers.removeValue(forKey: windowId) {
        renderer.invalidate()
    }
}
#endif
    
    func hasVideoRenderer(for windowId: UInt32) -> Bool {
        videoRenderers[windowId] != nil
    }
    
    func videoContentSize(for windowId: UInt32) -> CGSize? {
        videoContentSizeByWindow[windowId]
    }

    func windowGeometry(for windowId: UInt32) -> WindowGeometryMessage? {
        windowGeometryById[windowId]
    }
    
    func decodeJPEGToCGImage(_ data: Data) -> CGImage? {
        let cfData = data as CFData
        guard let src = CGImageSourceCreateWithData(cfData, nil) else { return nil }
        // Avoid forcing cache/decode on creation; let the renderer decide.
        let opts: CFDictionary = [kCGImageSourceShouldCache: false] as CFDictionary
        return CGImageSourceCreateImageAtIndex(src, 0, opts)
    }
    
    func handleReceivedJPEG(windowId: UInt32, jpegData: Data) {
        // 1) Always store the raw bytes (useful for debugging and any future features).
        DispatchQueue.main.async {
            self.snapshots[windowId] = jpegData
            self.lastFrameAt[windowId] = Date()
            self.selectedSession?.snapshots[windowId] = jpegData
            self.selectedSession?.lastFrameAt[windowId] = self.lastFrameAt[windowId]
        }
        
        // 2) Track a generation so slow decodes don't overwrite newer frames.
        snapshotGenCounter &+= 1
        let gen = snapshotGenCounter
        latestSnapshotGenByWindow[windowId] = gen
        selectedSession?.snapshotGenCounter = snapshotGenCounter
        selectedSession?.latestSnapshotGenByWindow[windowId] = gen
        
        // 3) Decode off-main.
        jpegDecodeQueue.async { [weak self] in
            guard let self else { return }
            guard let cg = self.decodeJPEGToCGImage(jpegData) else { return }
            
            DispatchQueue.main.async {
                guard self.latestSnapshotGenByWindow[windowId] == gen else { return }
                self.snapshotCGImages[windowId] = cg
                self.selectedSession?.snapshotCGImages[windowId] = cg
            }
        }
    }
    
    func makeVideoRenderer(windowId: UInt32, reason: String) -> CompressedVideoRenderer {
        let renderer = CompressedVideoRenderer()
#if os(visionOS)
        renderer.displayedFixtureDiagnostics.clock = streamDiagnosticReporter.clock
#endif
        renderer.diagnosticWindowId = windowId
        renderer.diagnosticLabel = "browserRenderer"
        PeelClientDiagnostics.logStreamEvent(ownerName: "browser", windowId: windowId, message: "renderer create reason=\(reason)")
        renderer.onFormatChange = { [weak self] size in
            guard let self else { return }
            guard size.width.isFinite,
                  size.height.isFinite,
                  size.width > 0,
                  size.height > 0 else {
                return
            }

            DispatchQueue.main.async {
                self.videoContentSizeByWindow[windowId] = size
                self.videoRendererWindowIds.insert(windowId)
                self.selectedSession?.videoContentSizeByWindow[windowId] = size
                self.selectedSession?.videoRendererWindowIds.insert(windowId)
            }
        }
        renderer.onRecoveryKeyframeNeeded = { [weak self, weak renderer] in
            guard let self, let renderer, self.videoRenderers[windowId] === renderer,
                  self.isConnectionReady,
                  self.hostCapabilities.contains(PeelCapability.videoKeyframeRequestV1.rawValue) else { return }
            self.sendJSONMessage(PeelVideoKeyframeRequestMessage(windowId: windowId))
        }
        let videoSession = selectedSession
        let usesSessionTransport = videoSession != nil
        let videoConnection = videoSession?.videoConnectionsByWindowId[windowId]
        renderer.onFrameEnqueued = { [weak self, weak renderer, weak videoSession, weak videoConnection] payloadByteCount, isKeyframe in
            guard let self, let renderer else { return }
            guard self.videoRenderers[windowId] === renderer else { return }
            if usesSessionTransport {
                guard let videoSession, let videoConnection,
                      self.selectedSession === videoSession,
                      videoSession.videoConnectionsByWindowId[windowId] === videoConnection else { return }
            }
            self.recordEnqueuedVideoFrame(
                windowId: windowId,
                payloadByteCount: payloadByteCount,
                isKeyframe: isKeyframe
            )
        }
        
        videoRenderers[windowId] = renderer
        selectedSession?.videoRenderers[windowId] = renderer
        
        DispatchQueue.main.async {
            self.videoRendererWindowIds.insert(windowId)
            self.selectedSession?.videoRendererWindowIds.insert(windowId)
        }
        
        return renderer
    }

    private func recordEnqueuedVideoFrame(
        windowId: UInt32,
        payloadByteCount: Int,
        isKeyframe: Bool
    ) {
        let now = Date()
        let previousCount = videoFrameCountByWindow[windowId] ?? 0
        let newCount = previousCount + 1

        videoFrameCountByWindow[windowId] = newCount
        videoLastFrameByteCountByWindow[windowId] = payloadByteCount
        videoLastFrameWasKeyframeByWindow[windowId] = isKeyframe
        videoLastFrameReceivedAtByWindow[windowId] = now
        lastFrameAt[windowId] = now
        selectedSession?.videoFrameCountByWindow[windowId] = newCount
        selectedSession?.videoLastFrameByteCountByWindow[windowId] = payloadByteCount
        selectedSession?.videoLastFrameWasKeyframeByWindow[windowId] = isKeyframe
        selectedSession?.videoLastFrameReceivedAtByWindow[windowId] = now
        selectedSession?.lastFrameAt[windowId] = now

        if previousCount == 0 {
            videoReadyWindowIds.insert(windowId)
            selectedSession?.videoReadyWindowIds.insert(windowId)
        }

        streamRepairAttemptByWindow[windowId] = 0
        streamLastRepairAtByWindow.removeValue(forKey: windowId)
        selectedSession?.streamRepairAttemptByWindow[windowId] = 0
        selectedSession?.streamLastRepairAtByWindow.removeValue(forKey: windowId)
    }

    func ensureVideoRenderer(windowId: UInt32) -> CompressedVideoRenderer {
        if let existing = videoRenderers[windowId] {
            return existing
        }
        
        return makeVideoRenderer(windowId: windowId, reason: "missing renderer")
    }

    func recreateVideoRenderer(windowId: UInt32, reason: String) -> CompressedVideoRenderer {
        if let oldRenderer = videoRenderers.removeValue(forKey: windowId) {
            PeelClientDiagnostics.logStreamEvent(ownerName: "browser", windowId: windowId, message: "renderer invalidate before recreate reason=\(reason)")
            oldRenderer.invalidate()
        }
        selectedSession?.videoRenderers.removeValue(forKey: windowId)
#if os(visionOS)
        if let oldSpatialRenderer = spatialVideoRenderers.removeValue(forKey: windowId) {
            oldSpatialRenderer.invalidate()
        }
#endif

        // Force SwiftUI to drop any view/layer bound to the old renderer before the new
        // renderer publishes its first frame. Keep the last known content size during
        // renderer replacement so peeled window geometry does not fall back to stale
        // host bounds and collapse to the minimum scene size.
        DispatchQueue.main.async {
            self.videoRendererWindowIds.remove(windowId)
            self.videoReadyWindowIds.remove(windowId)
            self.videoFrameCountByWindow[windowId] = 0
            self.videoLastFrameByteCountByWindow.removeValue(forKey: windowId)
            self.videoLastFrameWasKeyframeByWindow.removeValue(forKey: windowId)
            self.videoLastFrameReceivedAtByWindow.removeValue(forKey: windowId)
            self.selectedSession?.videoRendererWindowIds.remove(windowId)
            self.selectedSession?.videoReadyWindowIds.remove(windowId)
            self.selectedSession?.videoFrameCountByWindow[windowId] = 0
            self.selectedSession?.videoLastFrameByteCountByWindow.removeValue(forKey: windowId)
            self.selectedSession?.videoLastFrameWasKeyframeByWindow.removeValue(forKey: windowId)
            self.selectedSession?.videoLastFrameReceivedAtByWindow.removeValue(forKey: windowId)
        }

        return makeVideoRenderer(windowId: windowId, reason: reason)
    }
    
    func handleReceivedVideoConfig(_ packet: VideoConfigPacket) {
        let mediaPerfStartMs = peelMediaPerfNowMs()
        PeelClientDiagnostics.logVideoConfig(
            
            ownerName: "browser",
            windowId: packet.windowId,
            width: Int(packet.width),
            height: Int(packet.height),
            timescale: Int(packet.timescale),
            nalUnitHeaderLength: Int(packet.nalUnitHeaderLength),
            spsBytes: packet.sps.count,
            ppsBytes: packet.pps.count,
            codec: String(describing: packet.codec)
        )
        
        let recreateStartMs = peelMediaPerfNowMs()
        let renderer = recreateVideoRenderer(windowId: packet.windowId, reason: "videoConfig")
        let recreateMs = peelMediaPerfNowMs() - recreateStartMs
        videoConfigReceivedAtByWindow[packet.windowId] = Date()
        latestVideoConfigByWindow[packet.windowId] = packet
        selectedSession?.videoConfigReceivedAtByWindow[packet.windowId] = videoConfigReceivedAtByWindow[packet.windowId]
        selectedSession?.latestVideoConfigByWindow[packet.windowId] = packet
        let applyConfigStartMs = peelMediaPerfNowMs()
        renderer.applyConfig(packet)
        streamDiagnosticReporter.register(windowId: packet.windowId, renderer: renderer, collector: renderer.streamingDiagnostics)
        let applyConfigMs = peelMediaPerfNowMs() - applyConfigStartMs
#if os(visionOS)
        if activeSpatialWindowIds.contains(packet.windowId) {
            spatialVideoRenderer(for: packet.windowId).applyConfig(packet)
        }
#endif
        
        let totalConfigMs = peelMediaPerfNowMs() - mediaPerfStartMs
        if totalConfigMs >= 4.0 || recreateMs >= 2.0 || applyConfigMs >= 2.0 {
            print(
                "PeelClientPerf mediaConfig owner=browser",
                "window=\(packet.windowId)",
                "totalMs=\(String(format: "%.2f", totalConfigMs))",
                "recreateMs=\(String(format: "%.2f", recreateMs))",
                "applyConfigMs=\(String(format: "%.2f", applyConfigMs))",
                "size=\(packet.width)x\(packet.height)",
                "sps=\(packet.sps.count)",
                "pps=\(packet.pps.count)"
            )
        }

        DispatchQueue.main.async {
            self.lastFrameAt.removeValue(forKey: packet.windowId)
            self.videoReadyWindowIds.remove(packet.windowId)
            self.videoFrameCountByWindow[packet.windowId] = 0
            self.videoLastFrameByteCountByWindow.removeValue(forKey: packet.windowId)
            self.videoLastFrameWasKeyframeByWindow.removeValue(forKey: packet.windowId)
            self.videoLastFrameReceivedAtByWindow.removeValue(forKey: packet.windowId)
            self.selectedSession?.lastFrameAt.removeValue(forKey: packet.windowId)
            self.selectedSession?.videoReadyWindowIds.remove(packet.windowId)
            self.selectedSession?.videoFrameCountByWindow[packet.windowId] = 0
            self.selectedSession?.videoLastFrameByteCountByWindow.removeValue(forKey: packet.windowId)
            self.selectedSession?.videoLastFrameWasKeyframeByWindow.removeValue(forKey: packet.windowId)
            self.selectedSession?.videoLastFrameReceivedAtByWindow.removeValue(forKey: packet.windowId)
        }
    }
    
    func handleReceivedVideoFrame(_ packet: VideoFramePacket) {
        let mediaPerfStartMs = peelMediaPerfNowMs()
        guard desiredPullWindowIds.contains(packet.windowId) else {
            PeelClientDiagnostics.logVideoDrop(
                
                ownerName: "browser",
                windowId: packet.windowId,
                reason: "not desired",
                payloadByteCount: packet.payload.count
            )
            return
        }

        guard let renderer = videoRenderers[packet.windowId] else {
            PeelClientDiagnostics.logVideoDrop(
                
                ownerName: "browser",
                windowId: packet.windowId,
                reason: "missing renderer",
                payloadByteCount: packet.payload.count
            )
            return
        }

        renderer.streamingDiagnostics.received(bytes: packet.payload.count)

        let diagnosticBufferRemainingBytes = 0
        let diagnosticsStartMs = peelMediaPerfNowMs()
        PeelClientDiagnostics.logVideoFrame(
            
            ownerName: "browser",
            stage: "toRenderer",
            windowId: packet.windowId,
            payloadByteCount: packet.payload.count,
            isKeyframe: packet.isKeyframe,
            bufferRemainingBytes: diagnosticBufferRemainingBytes
        )
        let diagnosticsMs = peelMediaPerfNowMs() - diagnosticsStartMs

        let enqueueStartMs = peelMediaPerfNowMs()
        renderer.enqueueFrame(packet)
        let enqueueMs = peelMediaPerfNowMs() - enqueueStartMs
#if os(visionOS)
        var spatialLookupMs = 0.0
        var spatialEnqueueMs = 0.0
        if activeSpatialWindowIds.contains(packet.windowId) {
            let spatialLookupStartMs = peelMediaPerfNowMs()
            let spatialRenderer = spatialVideoRenderer(for: packet.windowId)
            spatialLookupMs = peelMediaPerfNowMs() - spatialLookupStartMs
            let spatialEnqueueStartMs = peelMediaPerfNowMs()
            spatialRenderer.enqueueFrame(packet)
            spatialEnqueueMs = peelMediaPerfNowMs() - spatialEnqueueStartMs
        }
#endif

        let preMainTotalMs = peelMediaPerfNowMs() - mediaPerfStartMs
        if preMainTotalMs >= 4.0 || enqueueMs >= 3.0 || diagnosticsMs >= 2.0 {
#if os(visionOS)
            print(
                "PeelClientPerf mediaFrame owner=browser",
                "window=\(packet.windowId)",
                "payload=\(packet.payload.count)",
                "key=\(packet.isKeyframe)",
                "preMainMs=\(String(format: "%.2f", preMainTotalMs))",
                "diagnosticsMs=\(String(format: "%.2f", diagnosticsMs))",
                "enqueueMs=\(String(format: "%.2f", enqueueMs))",
                "spatialLookupMs=\(String(format: "%.2f", spatialLookupMs))",
                "spatialEnqueueMs=\(String(format: "%.2f", spatialEnqueueMs))"
            )
#else
            print(
                "PeelClientPerf mediaFrame owner=browser",
                "window=\(packet.windowId)",
                "payload=\(packet.payload.count)",
                "key=\(packet.isKeyframe)",
                "preMainMs=\(String(format: "%.2f", preMainTotalMs))",
                "diagnosticsMs=\(String(format: "%.2f", diagnosticsMs))",
                "enqueueMs=\(String(format: "%.2f", enqueueMs))"
            )
#endif
        }

    }
    func removeBinaryPrefix(_ byteCount: Int, from buffer: inout Data) -> Bool {
        guard byteCount >= 0 else { return false }

        guard buffer.count >= byteCount else {
            buffer.removeAll()
            return false
        }

        guard byteCount > 0 else { return true }

        let endIndex = buffer.index(buffer.startIndex, offsetBy: byteCount)
        buffer.removeSubrange(buffer.startIndex..<endIndex)
        return true
    }
    
    func clearVideoRenderers() {
        PeelClientDiagnostics.logStreamEvent(ownerName: "browser", message: "clear renderers count=\(videoRenderers.count)")
        let renderers = Array(videoRenderers.values)
        videoRenderers.removeAll()
        selectedSession?.videoRenderers.removeAll()
//#if os(visionOS)
#if os(visionOS)
        let spatialRenderers = Array(spatialVideoRenderers.values)
        spatialVideoRenderers.removeAll()
        activeSpatialWindowIds.removeAll()
#endif
        
        DispatchQueue.main.async {
            self.videoRendererWindowIds.removeAll()
            self.videoContentSizeByWindow.removeAll()
            self.videoReadyWindowIds.removeAll()
            self.videoFrameCountByWindow.removeAll()
            self.videoLastFrameByteCountByWindow.removeAll()
            self.videoLastFrameWasKeyframeByWindow.removeAll()
            self.videoLastFrameReceivedAtByWindow.removeAll()
            self.latestVideoConfigByWindow.removeAll()
            self.selectedSession?.videoRendererWindowIds.removeAll()
            self.selectedSession?.videoContentSizeByWindow.removeAll()
            self.selectedSession?.videoReadyWindowIds.removeAll()
            self.selectedSession?.videoFrameCountByWindow.removeAll()
            self.selectedSession?.videoLastFrameByteCountByWindow.removeAll()
            self.selectedSession?.videoLastFrameWasKeyframeByWindow.removeAll()
            self.selectedSession?.videoLastFrameReceivedAtByWindow.removeAll()
            self.selectedSession?.latestVideoConfigByWindow.removeAll()
        }
        
        for renderer in renderers {
            renderer.invalidate()
        }
#if os(visionOS)
        for renderer in spatialRenderers {
            renderer.invalidate()
        }
#endif
    }

    /// Clears H.264 receiver/decoder state without removing desired stream intent.
    /// Use this at socket boundaries so stale decoders, partial binary packets, and
    /// per-connection startStream bookkeeping cannot survive into the next connection.
    func resetVideoReceiversForConnectionBoundary(reason: String) {
        PeelClientDiagnostics.logStreamEvent(ownerName: "browser", message: "reset video receivers reason=\(reason)")

        clearVideoRenderers()
        binaryBuffer.removeAll()
        muxBuffer.removeAll()
        expectedBinaryLength = nil
        selectedSession?.binaryBuffer.removeAll()
        selectedSession?.muxBuffer.removeAll()
        selectedSession?.expectedBinaryLength = nil

        startedStreamWindowIds.removeAll()
        streamRepairInProgressWindowIds.removeAll()
        streamStartAttemptAtByWindow.removeAll()
        streamLastRepairAtByWindow.removeAll()
        streamRepairAttemptByWindow.removeAll()
        videoConfigReceivedAtByWindow.removeAll()
        latestVideoConfigByWindow.removeAll()
        selectedSession?.startedStreamWindowIds.removeAll()
        selectedSession?.streamRepairInProgressWindowIds.removeAll()
        selectedSession?.streamStartAttemptAtByWindow.removeAll()
        selectedSession?.streamLastRepairAtByWindow.removeAll()
        selectedSession?.streamRepairAttemptByWindow.removeAll()
        selectedSession?.videoConfigReceivedAtByWindow.removeAll()
        selectedSession?.latestVideoConfigByWindow.removeAll()
#if os(visionOS)
        activeSpatialWindowIds.removeAll()
#endif

        lastFrameAt.removeAll()
        videoFrameCountByWindow.removeAll()
        videoLastFrameByteCountByWindow.removeAll()
        videoLastFrameWasKeyframeByWindow.removeAll()
        videoLastFrameReceivedAtByWindow.removeAll()
        selectedSession?.lastFrameAt.removeAll()
        selectedSession?.videoFrameCountByWindow.removeAll()
        selectedSession?.videoLastFrameByteCountByWindow.removeAll()
        selectedSession?.videoLastFrameWasKeyframeByWindow.removeAll()
        selectedSession?.videoLastFrameReceivedAtByWindow.removeAll()
        DispatchQueue.main.async {
            self.videoReadyWindowIds.removeAll()
            self.selectedSession?.videoReadyWindowIds.removeAll()
        }
    }
    
    func drainBinaryPackets(from buffer: inout Data) {
        let maxJPEGBytes = 64 * 1024 * 1024
        let maxVideoPayloadBytes = 64 * 1024 * 1024
        let maxConfigBytes = 1024 * 1024

        while true {
            guard !buffer.isEmpty else { return }

            guard let firstByte = buffer.first,
                  let packetType = PeelBinaryPacketType(rawValue: firstByte) else {
                PeelClientDiagnostics.logParserEvent(
                    
                    ownerName: "browser",
                    reason: "binary resync",
                    bufferBytes: buffer.count,
                    detail: "lead=\(buffer.first.map { String($0) } ?? "nil")"
                )
                if let idx = buffer.firstIndex(where: { isKnownBinaryLeadByte($0) }) {
                    if idx > buffer.startIndex {
                        buffer.removeSubrange(buffer.startIndex..<idx)
                    } else {
                        _ = removeBinaryPrefix(1, from: &buffer)
                    }
                } else {
                    buffer.removeAll()
                }
                return
            }

            switch packetType {
            case .jpegFrame:
                guard buffer.count >= 9 else {
                    PeelClientDiagnostics.logParserWait(
                        
                        ownerName: "browser",
                        parser: "binary",
                        reason: "jpeg header",
                        bufferBytes: buffer.count,
                        neededBytes: 9
                    )
                    return
                }

                let windowId = decodeUInt32(from: buffer[1..<5])
                let jpegLength = Int(decodeUInt32(from: buffer[5..<9]))

                guard jpegLength <= maxJPEGBytes else {
                    _ = removeBinaryPrefix(1, from: &buffer)
                    continue
                }

                let total = 9 + jpegLength
                guard buffer.count >= total else {
                    PeelClientDiagnostics.logParserWait(
                        
                        ownerName: "browser",
                        parser: "binary",
                        reason: "jpeg payload",
                        bufferBytes: buffer.count,
                        neededBytes: total
                    )
                    return
                }

                let jpegData = Data(buffer[9..<total])

                guard removeBinaryPrefix(total, from: &buffer) else { return }

                handleReceivedJPEG(windowId: windowId, jpegData: jpegData)

                stateQueue.async { [weak self] in
                    guard let self else { return }
                    self.inFlight.remove(windowId)
                    self.inFlightSince.removeValue(forKey: windowId)
                    self.globalSnapshotsInFlight = max(0, self.globalSnapshotsInFlight - 1)
                    self.selectedSession?.inFlight.remove(windowId)
                    self.selectedSession?.inFlightSince.removeValue(forKey: windowId)
                    self.selectedSession?.globalSnapshotsInFlight = self.globalSnapshotsInFlight
                }

            case .videoConfig, .hevcVideoConfig:
                let isHEVC = packetType == .hevcVideoConfig
                let minimumHeader = isHEVC ? 31 : 27
                guard buffer.count >= minimumHeader else {
                    PeelClientDiagnostics.logParserWait(
                        
                        ownerName: "browser",
                        parser: "binary",
                        reason: "videoConfig header",
                        bufferBytes: buffer.count,
                        neededBytes: minimumHeader
                    )
                    return
                }

                let vpsLength = isHEVC ? Int(decodeUInt32(from: buffer[19..<23])) : 0
                let spsRange = isHEVC ? 23..<27 : 19..<23
                let ppsRange = isHEVC ? 27..<31 : 23..<27
                let spsLength = Int(decodeUInt32(from: buffer[spsRange]))
                let ppsLength = Int(decodeUInt32(from: buffer[ppsRange]))

                guard vpsLength <= maxConfigBytes,
                      spsLength <= maxConfigBytes,
                      ppsLength <= maxConfigBytes else {
                    _ = removeBinaryPrefix(1, from: &buffer)
                    continue
                }

                let total = minimumHeader + vpsLength + spsLength + ppsLength
                guard buffer.count >= total else {
                    PeelClientDiagnostics.logParserWait(
                        
                        ownerName: "browser",
                        parser: "binary",
                        reason: "videoConfig payload",
                        bufferBytes: buffer.count,
                        neededBytes: total
                    )
                    return
                }

                let packetData = Data(buffer.prefix(total))

                guard removeBinaryPrefix(total, from: &buffer) else { return }

                if let packet = VideoConfigPacket(data: packetData) {
                    handleReceivedVideoConfig(packet)
                } else {
                    PeelClientDiagnostics.logParserEvent(
                        
                        ownerName: "browser",
                        reason: "videoConfig decode failed",
                        bufferBytes: buffer.count,
                        detail: "packetBytes=\(total)"
                    )
                }

            case .videoFrame:
                let minimumHeader = 26
                guard buffer.count >= minimumHeader else {
                    PeelClientDiagnostics.logParserWait(
                        
                        ownerName: "browser",
                        parser: "binary",
                        reason: "videoFrame header",
                        bufferBytes: buffer.count,
                        neededBytes: minimumHeader
                    )
                    return
                }

                let payloadLength = Int(decodeUInt32(from: buffer[22..<26]))

                guard payloadLength <= maxVideoPayloadBytes else {
                    _ = removeBinaryPrefix(1, from: &buffer)
                    continue
                }

                let total = minimumHeader + payloadLength
                guard buffer.count >= total else {
                    PeelClientDiagnostics.logParserWait(
                        
                        ownerName: "browser",
                        parser: "binary",
                        reason: "videoFrame payload",
                        bufferBytes: buffer.count,
                        neededBytes: total
                    )
                    return
                }

                let packetData = Data(buffer.prefix(total))

                guard removeBinaryPrefix(total, from: &buffer) else { return }

                if let packet = VideoFramePacket(data: packetData) {
                    PeelClientDiagnostics.logVideoFrame(
                        
                        ownerName: "browser",
                        stage: "parsed",
                        windowId: packet.windowId,
                        payloadByteCount: packet.payload.count,
                        isKeyframe: packet.isKeyframe,
                        bufferRemainingBytes: buffer.count
                    )
                    handleReceivedVideoFrame(packet)
                } else {
                    PeelClientDiagnostics.logParserEvent(
                        
                        ownerName: "browser",
                        reason: "videoFrame decode failed",
                        bufferBytes: buffer.count,
                        detail: "packetBytes=\(total) payload=\(payloadLength)"
                    )
                }
            }
        }
    }

    /// Begin streaming for this window.
    func beginPullStream(for window: PeelWindow, fps: Double = 30.0) {
        PeelClientDiagnostics.logStreamEvent(ownerName: "browser", windowId: window.windowId, message: "beginPullStream fps=\(fps)")
        // Do NOT call endPullStream here.
        // That sends stopStream and can race the new startStream.

        if let timer = snapshotTimers[window.windowId] {
            timer.cancel()
            snapshotTimers.removeValue(forKey: window.windowId)
            selectedSession?.snapshotTimers.removeValue(forKey: window.windowId)
        }

        inFlight.remove(window.windowId)
        inFlightSince.removeValue(forKey: window.windowId)
        selectedSession?.inFlight.remove(window.windowId)
        selectedSession?.inFlightSince.removeValue(forKey: window.windowId)

        let inserted = desiredPullWindowIds.insert(window.windowId).inserted
        desiredPullWindowIdentityByWindow[window.windowId] = window
        selectedSession?.desiredPullWindowIdentityByWindow[window.windowId] = window
        if inserted {
            selectedSession?.desiredPullWindowIds.insert(window.windowId)
        }

        if activeWindowId == nil {
            activeWindowId = window.windowId
            selectedSession?.activeWindowId = window.windowId
        }

        if inserted || !startedStreamWindowIds.contains(window.windowId) {
            requestSnapshot(for: window)
        }
    }
    
    func endPullStream(for window: PeelWindow) {
        PeelClientDiagnostics.logStreamEvent(ownerName: "browser", windowId: window.windowId, message: "endPullStream stopStream send")
        desiredPullWindowIds.remove(window.windowId)
        desiredPullWindowIdentityByWindow.removeValue(forKey: window.windowId)
        startedStreamWindowIds.remove(window.windowId)
        selectedSession?.desiredPullWindowIds.remove(window.windowId)
        selectedSession?.desiredPullWindowIdentityByWindow.removeValue(forKey: window.windowId)
        selectedSession?.startedStreamWindowIds.remove(window.windowId)

        streamStartAttemptAtByWindow.removeValue(forKey: window.windowId)
        streamLastRepairAtByWindow.removeValue(forKey: window.windowId)
        streamRepairAttemptByWindow.removeValue(forKey: window.windowId)
        streamRepairInProgressWindowIds.remove(window.windowId)
        videoConfigReceivedAtByWindow.removeValue(forKey: window.windowId)
        latestVideoConfigByWindow.removeValue(forKey: window.windowId)
        selectedSession?.streamStartAttemptAtByWindow.removeValue(forKey: window.windowId)
        selectedSession?.streamLastRepairAtByWindow.removeValue(forKey: window.windowId)
        selectedSession?.streamRepairAttemptByWindow.removeValue(forKey: window.windowId)
        selectedSession?.streamRepairInProgressWindowIds.remove(window.windowId)
        selectedSession?.videoConfigReceivedAtByWindow.removeValue(forKey: window.windowId)
        selectedSession?.latestVideoConfigByWindow.removeValue(forKey: window.windowId)
#if os(visionOS)
        activeSpatialWindowIds.remove(window.windowId)
        if let spatialRenderer = spatialVideoRenderers.removeValue(forKey: window.windowId) {
            spatialRenderer.invalidate()
        }
#endif

        if let timer = snapshotTimers[window.windowId] {
            timer.cancel()
            snapshotTimers.removeValue(forKey: window.windowId)
            selectedSession?.snapshotTimers.removeValue(forKey: window.windowId)
        }

        inFlight.remove(window.windowId)
        inFlightSince.removeValue(forKey: window.windowId)
        selectedSession?.inFlight.remove(window.windowId)
        selectedSession?.inFlightSince.removeValue(forKey: window.windowId)

        selectedSession?.closeVideoConnection(windowId: window.windowId, reason: "end pull stream")

        let req = PeelRequest(type: "stopStream", windowId: window.windowId)
        sendJSONMessage(req)
    }
}


// MARK: - Per-host session media
extension PeelHostSession {
    /// Old pixels may stay visible, but only frames from the new attempt satisfy
    /// first-frame readiness. Also keep the selected browser's mirror coherent.
    func resetVideoStreamReadiness(windowId: UInt32) {
        // Queued renderer work may still drain after a close/reopen or while a
        // terminal loss waits for repair cooldown. It cannot make this attempt
        // ready; only the renderer installed by a new videoConfig may do that.
        videoRenderers[windowId]?.onFrameEnqueued = nil
        videoFrameCountByWindow[windowId] = 0
        videoLastFrameReceivedAtByWindow.removeValue(forKey: windowId)
        lastFrameAt.removeValue(forKey: windowId)
        videoReadyWindowIds.remove(windowId)
        if browser?.selectedHostKey == hostKey {
            browser?.videoRenderers[windowId]?.onFrameEnqueued = nil
            browser?.videoFrameCountByWindow[windowId] = 0
            browser?.videoLastFrameReceivedAtByWindow.removeValue(forKey: windowId)
            browser?.lastFrameAt.removeValue(forKey: windowId)
            browser?.videoReadyWindowIds.remove(windowId)
        }
    }

    // Legacy name. For H.264 streaming, this starts the SCK/H.264 stream.
    func requestSnapshot(for window: PeelWindow) {
        requestStreamStart(windowId: window.windowId, reason: "view requested stream")
    }
    
    func requestStreamStart(windowId: UInt32, reason: String, force: Bool = false) {
        guard connection != nil, isConnectionReady else {
            return
        }

        if streamRepairInProgressWindowIds.contains(windowId), !force {
            return
        }

        if force {
            startedStreamWindowIds.remove(windowId)
        } else if startedStreamWindowIds.contains(windowId) {
            return
        }

        resetVideoStreamReadiness(windowId: windowId)
        startedStreamWindowIds.insert(windowId)
        streamStartAttemptAtByWindow[windowId] = Date()
        PeelClientDiagnostics.logStreamEvent(ownerName: "session", windowId: windowId, message: "startStream send reason=\(reason) force=\(force)")

        openVideoConnectionIfNeeded(windowId: windowId)

        let req = PeelRequest(type: "startStream", windowId: windowId)
        sendJSONMessage(req)
    }

    func reassertDesiredStreams(reason: String) {
        guard connection != nil, isConnectionReady else { return }

        for windowId in desiredPullWindowIds.sorted() {
            guard !startedStreamWindowIds.contains(windowId) else { continue }
            requestStreamStart(windowId: windowId, reason: reason)
        }
    }

    func repairStream(windowId: UInt32, reason: String) {
        guard desiredPullWindowIds.contains(windowId) else { return }
        guard isClientVisible, let repairConnection = connection, isConnectionReady else {
            startedStreamWindowIds.remove(windowId)
            return
        }

        let now = Date()

        if let lastRepair = streamLastRepairAtByWindow[windowId],
           now.timeIntervalSince(lastRepair) < streamRepairCooldown {
            return
        }

        streamLastRepairAtByWindow[windowId] = now
        PeelClientDiagnostics.logStreamEvent(ownerName: "session", windowId: windowId, message: "repair begin reason=\(reason)")

        let attempt = (streamRepairAttemptByWindow[windowId] ?? 0) + 1
        streamRepairAttemptByWindow[windowId] = attempt

        if attempt > maxStreamRepairsBeforeReconnect {
            PeelClientDiagnostics.logStreamEvent(ownerName: "session", windowId: windowId, message: "repair escalating to reconnect attempt=\(attempt) reason=\(reason)")
            reconnectForStreamRepair(windowId: windowId, reason: reason)
            return
        }


        startedStreamWindowIds.remove(windowId)
        streamStartAttemptAtByWindow[windowId] = now
        videoConfigReceivedAtByWindow.removeValue(forKey: windowId)

        // This is a new stream attempt. Do not let stale state make the UI think video is alive.
        lastFrameAt.removeValue(forKey: windowId)
        videoFrameCountByWindow[windowId] = 0
        videoLastFrameByteCountByWindow.removeValue(forKey: windowId)
        videoLastFrameWasKeyframeByWindow.removeValue(forKey: windowId)
        videoLastFrameReceivedAtByWindow.removeValue(forKey: windowId)
        DispatchQueue.main.async {
            self.videoReadyWindowIds.remove(windowId)
        }

        videoRenderers[windowId]?.flushAndReset()

        streamRepairInProgressWindowIds.insert(windowId)

        // Existing host contract: stop the possibly wedged stream, then start a fresh one.
        closeVideoConnection(windowId: windowId, reason: "repair restart")
        sendJSONMessage(PeelRequest(type: "stopStream", windowId: windowId))

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            guard let self else { return }
            guard self.connection === repairConnection,
                  self.streamLastRepairAtByWindow[windowId] == now else { return }
            guard self.isClientVisible, self.desiredPullWindowIds.contains(windowId),
                  self.isConnectionReady else {
                self.streamRepairInProgressWindowIds.remove(windowId)
                return
            }

            self.requestStreamStart(
                windowId: windowId,
                reason: "repair restart after \(reason)",
                force: true
            )

            self.streamRepairInProgressWindowIds.remove(windowId)
        }
    }

    func reconnectForStreamRepair(windowId: UInt32, reason: String) {
        streamRepairAttemptByWindow[windowId] = 0
        handleDisconnectOnce("stream repair reconnect: \(reason)")
    }

    func decodeUInt32(from slice: Data) -> UInt32 {
        var value: UInt32 = 0
        slice.withUnsafeBytes { rawPtr in
            memcpy(&value, rawPtr.baseAddress!, 4)
        }
        return UInt32(littleEndian: value)
    }
    
    func decodeInt64(from slice: Data) -> Int64 {
        var value: Int64 = 0
        slice.withUnsafeBytes { rawPtr in
            memcpy(&value, rawPtr.baseAddress!, 8)
        }
        return Int64(littleEndian: value)
    }
    
    func isKnownBinaryLeadByte(_ byte: UInt8?) -> Bool {
        guard let byte else { return false }
        return byte == PeelBinaryPacketType.jpegFrame.rawValue ||
        byte == PeelBinaryPacketType.videoConfig.rawValue ||
        byte == PeelBinaryPacketType.hevcVideoConfig.rawValue ||
        byte == PeelBinaryPacketType.videoFrame.rawValue
    }

    // MARK: - JPEG decode helpers


    func snapshotCGImage(for windowId: UInt32) -> CGImage? {
        snapshotCGImages[windowId]
    }

#if canImport(UIKit)
    func appIconImage(for window: PeelWindow) -> UIImage? {
        guard let base64 = window.appIconPNGBase64,
              !base64.isEmpty else {
            return nil
        }

        if let cached = appIconImageCache[base64] {
            return cached
        }

        guard let data = Data(base64Encoded: base64),
              let image = UIImage(data: data) else {
            return nil
        }

        appIconImageCache[base64] = image
        return image
    }
#endif
    
    func videoRenderer(for windowId: UInt32) -> CompressedVideoRenderer? {
        videoRenderers[windowId]
    }
#if os(visionOS)
func spatialVideoRenderer(for windowId: UInt32) -> SpatialCompressedVideoRenderer {
    if let existing = spatialVideoRenderers[windowId] {
        return existing
    }

    let renderer = SpatialCompressedVideoRenderer()
    renderer.diagnosticClock = streamDiagnosticReporter.clock
    spatialVideoRenderers[windowId] = renderer

    if let config = latestVideoConfigByWindow[windowId] {
        renderer.applyConfig(config)
    }

    return renderer
}

func deactivateSpatialVideoRenderer(for windowId: UInt32) {
    activeSpatialWindowIds.remove(windowId)
    if let renderer = spatialVideoRenderers.removeValue(forKey: windowId) {
        renderer.invalidate()
    }
}
#endif
    
    func hasVideoRenderer(for windowId: UInt32) -> Bool {
        videoRenderers[windowId] != nil
    }
    
    func videoContentSize(for windowId: UInt32) -> CGSize? {
        videoContentSizeByWindow[windowId]
    }

    func windowGeometry(for windowId: UInt32) -> WindowGeometryMessage? {
        windowGeometryById[windowId]
    }
    
    func decodeJPEGToCGImage(_ data: Data) -> CGImage? {
        let cfData = data as CFData
        guard let src = CGImageSourceCreateWithData(cfData, nil) else { return nil }
        // Avoid forcing cache/decode on creation; let the renderer decide.
        let opts: CFDictionary = [kCGImageSourceShouldCache: false] as CFDictionary
        return CGImageSourceCreateImageAtIndex(src, 0, opts)
    }
    
    func handleReceivedJPEG(windowId: UInt32, jpegData: Data) {
        // 1) Always store the raw bytes (useful for debugging and any future features).
        DispatchQueue.main.async {
            self.snapshots[windowId] = jpegData
            self.lastFrameAt[windowId] = Date()
        }
        
        // 2) Track a generation so slow decodes don't overwrite newer frames.
        snapshotGenCounter &+= 1
        let gen = snapshotGenCounter
        latestSnapshotGenByWindow[windowId] = gen
        
        // 3) Decode off-main.
        jpegDecodeQueue.async { [weak self] in
            guard let self else { return }
            guard let cg = self.decodeJPEGToCGImage(jpegData) else { return }
            
            DispatchQueue.main.async {
                guard self.latestSnapshotGenByWindow[windowId] == gen else { return }
                self.snapshotCGImages[windowId] = cg
            }
        }
    }
    
    func makeVideoRenderer(windowId: UInt32, reason: String) -> CompressedVideoRenderer {
        let renderer = CompressedVideoRenderer()
#if os(visionOS)
        renderer.displayedFixtureDiagnostics.clock = streamDiagnosticReporter.clock
#endif
        renderer.diagnosticWindowId = windowId
        renderer.diagnosticLabel = "sessionRenderer"
        PeelClientDiagnostics.logStreamEvent(ownerName: "session", windowId: windowId, message: "renderer create reason=\(reason)")
        renderer.onFormatChange = { [weak self] size in
            guard let self else { return }
            guard size.width.isFinite,
                  size.height.isFinite,
                  size.width > 0,
                  size.height > 0 else {
                return
            }

            DispatchQueue.main.async {
                self.videoContentSizeByWindow[windowId] = size
                self.videoRendererWindowIds.insert(windowId)
            }
        }
        renderer.onRecoveryKeyframeNeeded = { [weak self, weak renderer] in
            guard let self, let renderer, self.videoRenderers[windowId] === renderer,
                  self.isConnectionReady,
                  self.hostCapabilities.contains(PeelCapability.videoKeyframeRequestV1.rawValue) else { return }
            self.sendJSONMessage(PeelVideoKeyframeRequestMessage(windowId: windowId))
        }
        let videoConnection = videoConnectionsByWindowId[windowId]
#if os(iOS)
        let watchRendererID = UUID()
        renderer.onWatchRelaySampleBuffer = { [weak self, weak renderer, weak videoConnection] sample, keyframe in
            guard let self, let renderer, let videoConnection,
                  self.videoRenderers[windowId] === renderer,
                  self.videoConnectionsByWindowId[windowId] === videoConnection else { return }
            self.deliverWatchRelaySample(windowID: windowId, rendererID: watchRendererID, sample: sample, keyframe: keyframe)
        }
#endif
        renderer.onFrameEnqueued = { [weak self, weak renderer, weak videoConnection] payloadByteCount, isKeyframe in
            guard let self, let renderer, let videoConnection else { return }
            guard self.videoRenderers[windowId] === renderer,
                  self.videoConnectionsByWindowId[windowId] === videoConnection else { return }
            self.recordEnqueuedVideoFrame(
                windowId: windowId,
                payloadByteCount: payloadByteCount,
                isKeyframe: isKeyframe
            )
        }
        
        videoRenderers[windowId] = renderer
        
        DispatchQueue.main.async {
            self.videoRendererWindowIds.insert(windowId)
        }
        
        return renderer
    }

    private func recordEnqueuedVideoFrame(
        windowId: UInt32,
        payloadByteCount: Int,
        isKeyframe: Bool
    ) {
        let now = Date()
        let previousCount = videoFrameCountByWindow[windowId] ?? 0
        let newCount = previousCount + 1

        videoFrameCountByWindow[windowId] = newCount
        videoLastFrameByteCountByWindow[windowId] = payloadByteCount
        videoLastFrameWasKeyframeByWindow[windowId] = isKeyframe
        videoLastFrameReceivedAtByWindow[windowId] = now
        lastFrameAt[windowId] = now

        if previousCount == 0 {
            videoReadyWindowIds.insert(windowId)
        }

        streamRepairAttemptByWindow[windowId] = 0
        streamLastRepairAtByWindow.removeValue(forKey: windowId)
    }

    func ensureVideoRenderer(windowId: UInt32) -> CompressedVideoRenderer {
        if let existing = videoRenderers[windowId] {
            return existing
        }
        
        return makeVideoRenderer(windowId: windowId, reason: "missing renderer")
    }

    func recreateVideoRenderer(windowId: UInt32, reason: String) -> CompressedVideoRenderer {
        if let oldRenderer = videoRenderers.removeValue(forKey: windowId) {
            PeelClientDiagnostics.logStreamEvent(ownerName: "session", windowId: windowId, message: "renderer invalidate before recreate reason=\(reason)")
            oldRenderer.invalidate()
        }
#if os(visionOS)
        if let oldSpatialRenderer = spatialVideoRenderers.removeValue(forKey: windowId) {
            oldSpatialRenderer.invalidate()
        }
#endif

        // Force SwiftUI to drop any view/layer bound to the old renderer before the new
        // renderer publishes its first frame. Keep the last known content size during
        // renderer replacement so peeled window geometry does not fall back to stale
        // host bounds and collapse to the minimum scene size.
        DispatchQueue.main.async {
            self.videoRendererWindowIds.remove(windowId)
            self.videoReadyWindowIds.remove(windowId)
            self.videoFrameCountByWindow[windowId] = 0
            self.videoLastFrameByteCountByWindow.removeValue(forKey: windowId)
            self.videoLastFrameWasKeyframeByWindow.removeValue(forKey: windowId)
            self.videoLastFrameReceivedAtByWindow.removeValue(forKey: windowId)
        }

        return makeVideoRenderer(windowId: windowId, reason: reason)
    }
    
    func handleReceivedVideoConfig(_ packet: VideoConfigPacket) {
        let mediaPerfStartMs = peelMediaPerfNowMs()
        PeelClientDiagnostics.logVideoConfig(
            
            ownerName: "session",
            windowId: packet.windowId,
            width: Int(packet.width),
            height: Int(packet.height),
            timescale: Int(packet.timescale),
            nalUnitHeaderLength: Int(packet.nalUnitHeaderLength),
            spsBytes: packet.sps.count,
            ppsBytes: packet.pps.count,
            codec: String(describing: packet.codec)
        )
        
        let recreateStartMs = peelMediaPerfNowMs()
        let renderer = recreateVideoRenderer(windowId: packet.windowId, reason: "videoConfig")
        let recreateMs = peelMediaPerfNowMs() - recreateStartMs
        videoConfigReceivedAtByWindow[packet.windowId] = Date()
        latestVideoConfigByWindow[packet.windowId] = packet
        let applyConfigStartMs = peelMediaPerfNowMs()
        renderer.applyConfig(packet)
        streamDiagnosticReporter.register(windowId: packet.windowId, renderer: renderer, collector: renderer.streamingDiagnostics)
        let applyConfigMs = peelMediaPerfNowMs() - applyConfigStartMs
#if os(visionOS)
        if activeSpatialWindowIds.contains(packet.windowId) {
            spatialVideoRenderer(for: packet.windowId).applyConfig(packet)
        }
#endif
        
        let totalConfigMs = peelMediaPerfNowMs() - mediaPerfStartMs
        if totalConfigMs >= 4.0 || recreateMs >= 2.0 || applyConfigMs >= 2.0 {
            print(
                "PeelClientPerf mediaConfig owner=session",
                "window=\(packet.windowId)",
                "totalMs=\(String(format: "%.2f", totalConfigMs))",
                "recreateMs=\(String(format: "%.2f", recreateMs))",
                "applyConfigMs=\(String(format: "%.2f", applyConfigMs))",
                "size=\(packet.width)x\(packet.height)",
                "sps=\(packet.sps.count)",
                "pps=\(packet.pps.count)"
            )
        }

        DispatchQueue.main.async {
            self.lastFrameAt.removeValue(forKey: packet.windowId)
            self.videoReadyWindowIds.remove(packet.windowId)
            self.videoFrameCountByWindow[packet.windowId] = 0
            self.videoLastFrameByteCountByWindow.removeValue(forKey: packet.windowId)
            self.videoLastFrameWasKeyframeByWindow.removeValue(forKey: packet.windowId)
            self.videoLastFrameReceivedAtByWindow.removeValue(forKey: packet.windowId)
        }
    }
    
    func handleReceivedVideoFrame(_ packet: VideoFramePacket) {
        let mediaPerfStartMs = peelMediaPerfNowMs()
        guard desiredPullWindowIds.contains(packet.windowId) else {
            PeelClientDiagnostics.logVideoDrop(
                
                ownerName: "session",
                windowId: packet.windowId,
                reason: "not desired",
                payloadByteCount: packet.payload.count
            )
            return
        }

        guard let renderer = videoRenderers[packet.windowId] else {
            PeelClientDiagnostics.logVideoDrop(
                
                ownerName: "session",
                windowId: packet.windowId,
                reason: "missing renderer",
                payloadByteCount: packet.payload.count
            )
            return
        }

        renderer.streamingDiagnostics.received(bytes: packet.payload.count)

        let diagnosticBufferRemainingBytes = 0
        let diagnosticsStartMs = peelMediaPerfNowMs()
        PeelClientDiagnostics.logVideoFrame(
            
            ownerName: "session",
            stage: "toRenderer",
            windowId: packet.windowId,
            payloadByteCount: packet.payload.count,
            isKeyframe: packet.isKeyframe,
            bufferRemainingBytes: diagnosticBufferRemainingBytes
        )
        let diagnosticsMs = peelMediaPerfNowMs() - diagnosticsStartMs

        let enqueueStartMs = peelMediaPerfNowMs()
        renderer.enqueueFrame(packet)
        let enqueueMs = peelMediaPerfNowMs() - enqueueStartMs
#if os(visionOS)
        var spatialLookupMs = 0.0
        var spatialEnqueueMs = 0.0
        if activeSpatialWindowIds.contains(packet.windowId) {
            let spatialLookupStartMs = peelMediaPerfNowMs()
            let spatialRenderer = spatialVideoRenderer(for: packet.windowId)
            spatialLookupMs = peelMediaPerfNowMs() - spatialLookupStartMs
            let spatialEnqueueStartMs = peelMediaPerfNowMs()
            spatialRenderer.enqueueFrame(packet)
            spatialEnqueueMs = peelMediaPerfNowMs() - spatialEnqueueStartMs
        }
#endif

        let preMainTotalMs = peelMediaPerfNowMs() - mediaPerfStartMs
        if preMainTotalMs >= 4.0 || enqueueMs >= 3.0 || diagnosticsMs >= 2.0 {
#if os(visionOS)
            print(
                "PeelClientPerf mediaFrame owner=session",
                "window=\(packet.windowId)",
                "payload=\(packet.payload.count)",
                "key=\(packet.isKeyframe)",
                "preMainMs=\(String(format: "%.2f", preMainTotalMs))",
                "diagnosticsMs=\(String(format: "%.2f", diagnosticsMs))",
                "enqueueMs=\(String(format: "%.2f", enqueueMs))",
                "spatialLookupMs=\(String(format: "%.2f", spatialLookupMs))",
                "spatialEnqueueMs=\(String(format: "%.2f", spatialEnqueueMs))"
            )
#else
            print(
                "PeelClientPerf mediaFrame owner=session",
                "window=\(packet.windowId)",
                "payload=\(packet.payload.count)",
                "key=\(packet.isKeyframe)",
                "preMainMs=\(String(format: "%.2f", preMainTotalMs))",
                "diagnosticsMs=\(String(format: "%.2f", diagnosticsMs))",
                "enqueueMs=\(String(format: "%.2f", enqueueMs))"
            )
#endif
        }

    }
    func removeBinaryPrefix(_ byteCount: Int, from buffer: inout Data) -> Bool {
        guard byteCount >= 0 else { return false }

        guard buffer.count >= byteCount else {
            buffer.removeAll()
            return false
        }

        guard byteCount > 0 else { return true }

        let endIndex = buffer.index(buffer.startIndex, offsetBy: byteCount)
        buffer.removeSubrange(buffer.startIndex..<endIndex)
        return true
    }
    
    func clearVideoRenderers() {
        PeelClientDiagnostics.logStreamEvent(ownerName: "session", message: "clear renderers count=\(videoRenderers.count)")
        let renderers = Array(videoRenderers.values)
        videoRenderers.removeAll()
//#if os(visionOS)
#if os(visionOS)
        let spatialRenderers = Array(spatialVideoRenderers.values)
        spatialVideoRenderers.removeAll()
        activeSpatialWindowIds.removeAll()
#endif
        
        DispatchQueue.main.async {
            self.videoRendererWindowIds.removeAll()
            self.videoContentSizeByWindow.removeAll()
            self.videoReadyWindowIds.removeAll()
            self.videoFrameCountByWindow.removeAll()
            self.videoLastFrameByteCountByWindow.removeAll()
            self.videoLastFrameWasKeyframeByWindow.removeAll()
            self.videoLastFrameReceivedAtByWindow.removeAll()
            self.latestVideoConfigByWindow.removeAll()
        }
        
        for renderer in renderers {
            renderer.invalidate()
        }
#if os(visionOS)
        for renderer in spatialRenderers {
            renderer.invalidate()
        }
#endif
    }

    /// Clears H.264 receiver/decoder state without removing desired stream intent.
    /// Use this at socket boundaries so stale decoders, partial binary packets, and
    /// per-connection startStream bookkeeping cannot survive into the next connection.
    func resetVideoReceiversForConnectionBoundary(reason: String) {
        PeelClientDiagnostics.logStreamEvent(ownerName: "session", message: "reset video receivers reason=\(reason)")

        clearVideoRenderers()
        binaryBuffer.removeAll()
        muxBuffer.removeAll()
        expectedBinaryLength = nil

        startedStreamWindowIds.removeAll()
        streamRepairInProgressWindowIds.removeAll()
        streamStartAttemptAtByWindow.removeAll()
        streamLastRepairAtByWindow.removeAll()
        streamRepairAttemptByWindow.removeAll()
        videoConfigReceivedAtByWindow.removeAll()
        latestVideoConfigByWindow.removeAll()
#if os(visionOS)
        activeSpatialWindowIds.removeAll()
#endif

        lastFrameAt.removeAll()
        videoFrameCountByWindow.removeAll()
        videoLastFrameByteCountByWindow.removeAll()
        videoLastFrameWasKeyframeByWindow.removeAll()
        videoLastFrameReceivedAtByWindow.removeAll()
        DispatchQueue.main.async {
            self.videoReadyWindowIds.removeAll()
        }
    }
    
    func drainBinaryPackets(from buffer: inout Data) {
        let maxJPEGBytes = 64 * 1024 * 1024
        let maxVideoPayloadBytes = 64 * 1024 * 1024
        let maxConfigBytes = 1024 * 1024

        while true {
            guard !buffer.isEmpty else { return }

            guard let firstByte = buffer.first,
                  let packetType = PeelBinaryPacketType(rawValue: firstByte) else {
                PeelClientDiagnostics.logParserEvent(
                    
                    ownerName: "session",
                    reason: "binary resync",
                    bufferBytes: buffer.count,
                    detail: "lead=\(buffer.first.map { String($0) } ?? "nil")"
                )
                if let idx = buffer.firstIndex(where: { isKnownBinaryLeadByte($0) }) {
                    if idx > buffer.startIndex {
                        buffer.removeSubrange(buffer.startIndex..<idx)
                    } else {
                        _ = removeBinaryPrefix(1, from: &buffer)
                    }
                } else {
                    buffer.removeAll()
                }
                return
            }

            switch packetType {
            case .jpegFrame:
                guard buffer.count >= 9 else {
                    PeelClientDiagnostics.logParserWait(
                        
                        ownerName: "session",
                        parser: "binary",
                        reason: "jpeg header",
                        bufferBytes: buffer.count,
                        neededBytes: 9
                    )
                    return
                }

                let windowId = decodeUInt32(from: buffer[1..<5])
                let jpegLength = Int(decodeUInt32(from: buffer[5..<9]))

                guard jpegLength <= maxJPEGBytes else {
                    _ = removeBinaryPrefix(1, from: &buffer)
                    continue
                }

                let total = 9 + jpegLength
                guard buffer.count >= total else {
                    PeelClientDiagnostics.logParserWait(
                        
                        ownerName: "session",
                        parser: "binary",
                        reason: "jpeg payload",
                        bufferBytes: buffer.count,
                        neededBytes: total
                    )
                    return
                }

                let jpegData = Data(buffer[9..<total])

                guard removeBinaryPrefix(total, from: &buffer) else { return }

                handleReceivedJPEG(windowId: windowId, jpegData: jpegData)

                stateQueue.async { [weak self] in
                    guard let self else { return }
                    self.inFlight.remove(windowId)
                    self.inFlightSince.removeValue(forKey: windowId)
                    self.globalSnapshotsInFlight = max(0, self.globalSnapshotsInFlight - 1)
                }

            case .videoConfig, .hevcVideoConfig:
                let isHEVC = packetType == .hevcVideoConfig
                let minimumHeader = isHEVC ? 31 : 27
                guard buffer.count >= minimumHeader else {
                    PeelClientDiagnostics.logParserWait(
                        
                        ownerName: "session",
                        parser: "binary",
                        reason: "videoConfig header",
                        bufferBytes: buffer.count,
                        neededBytes: minimumHeader
                    )
                    return
                }

                let vpsLength = isHEVC ? Int(decodeUInt32(from: buffer[19..<23])) : 0
                let spsRange = isHEVC ? 23..<27 : 19..<23
                let ppsRange = isHEVC ? 27..<31 : 23..<27
                let spsLength = Int(decodeUInt32(from: buffer[spsRange]))
                let ppsLength = Int(decodeUInt32(from: buffer[ppsRange]))

                guard vpsLength <= maxConfigBytes,
                      spsLength <= maxConfigBytes,
                      ppsLength <= maxConfigBytes else {
                    _ = removeBinaryPrefix(1, from: &buffer)
                    continue
                }

                let total = minimumHeader + vpsLength + spsLength + ppsLength
                guard buffer.count >= total else {
                    PeelClientDiagnostics.logParserWait(
                        
                        ownerName: "session",
                        parser: "binary",
                        reason: "videoConfig payload",
                        bufferBytes: buffer.count,
                        neededBytes: total
                    )
                    return
                }

                let packetData = Data(buffer.prefix(total))

                guard removeBinaryPrefix(total, from: &buffer) else { return }

                if let packet = VideoConfigPacket(data: packetData) {
                    handleReceivedVideoConfig(packet)
                } else {
                    PeelClientDiagnostics.logParserEvent(
                        
                        ownerName: "session",
                        reason: "videoConfig decode failed",
                        bufferBytes: buffer.count,
                        detail: "packetBytes=\(total)"
                    )
                }

            case .videoFrame:
                let minimumHeader = 26
                guard buffer.count >= minimumHeader else {
                    PeelClientDiagnostics.logParserWait(
                        
                        ownerName: "session",
                        parser: "binary",
                        reason: "videoFrame header",
                        bufferBytes: buffer.count,
                        neededBytes: minimumHeader
                    )
                    return
                }

                let payloadLength = Int(decodeUInt32(from: buffer[22..<26]))

                guard payloadLength <= maxVideoPayloadBytes else {
                    _ = removeBinaryPrefix(1, from: &buffer)
                    continue
                }

                let total = minimumHeader + payloadLength
                guard buffer.count >= total else {
                    PeelClientDiagnostics.logParserWait(
                        
                        ownerName: "session",
                        parser: "binary",
                        reason: "videoFrame payload",
                        bufferBytes: buffer.count,
                        neededBytes: total
                    )
                    return
                }

                let packetData = Data(buffer.prefix(total))

                guard removeBinaryPrefix(total, from: &buffer) else { return }

                if let packet = VideoFramePacket(data: packetData) {
                    PeelClientDiagnostics.logVideoFrame(
                        
                        ownerName: "session",
                        stage: "parsed",
                        windowId: packet.windowId,
                        payloadByteCount: packet.payload.count,
                        isKeyframe: packet.isKeyframe,
                        bufferRemainingBytes: buffer.count
                    )
                    handleReceivedVideoFrame(packet)
                } else {
                    PeelClientDiagnostics.logParserEvent(
                        
                        ownerName: "session",
                        reason: "videoFrame decode failed",
                        bufferBytes: buffer.count,
                        detail: "packetBytes=\(total) payload=\(payloadLength)"
                    )
                }
            }
        }
    }

    /// Begin streaming for this window.
    func beginPullStream(for window: PeelWindow, fps: Double = 30.0) {
        PeelClientDiagnostics.logStreamEvent(ownerName: "session", windowId: window.windowId, message: "beginPullStream fps=\(fps)")
        // Do NOT call endPullStream here.
        // That sends stopStream and can race the new startStream.

        if let timer = snapshotTimers[window.windowId] {
            timer.cancel()
            snapshotTimers.removeValue(forKey: window.windowId)
        }

        inFlight.remove(window.windowId)
        inFlightSince.removeValue(forKey: window.windowId)

        let inserted = desiredPullWindowIds.insert(window.windowId).inserted
        desiredPullWindowIdentityByWindow[window.windowId] = window
        if inserted {
        }

        if activeWindowId == nil {
            activeWindowId = window.windowId
        }

        if inserted || !startedStreamWindowIds.contains(window.windowId) {
            requestSnapshot(for: window)
        }
    }
    
    func endPullStream(for window: PeelWindow) {
        PeelClientDiagnostics.logStreamEvent(ownerName: "session", windowId: window.windowId, message: "endPullStream stopStream send")
        desiredPullWindowIds.remove(window.windowId)
        desiredPullWindowIdentityByWindow.removeValue(forKey: window.windowId)
        startedStreamWindowIds.remove(window.windowId)

        streamStartAttemptAtByWindow.removeValue(forKey: window.windowId)
        streamLastRepairAtByWindow.removeValue(forKey: window.windowId)
        streamRepairAttemptByWindow.removeValue(forKey: window.windowId)
        streamRepairInProgressWindowIds.remove(window.windowId)
        videoConfigReceivedAtByWindow.removeValue(forKey: window.windowId)
        latestVideoConfigByWindow.removeValue(forKey: window.windowId)
#if os(visionOS)
        activeSpatialWindowIds.remove(window.windowId)
        if let spatialRenderer = spatialVideoRenderers.removeValue(forKey: window.windowId) {
            spatialRenderer.invalidate()
        }
#endif

        if let timer = snapshotTimers[window.windowId] {
            timer.cancel()
            snapshotTimers.removeValue(forKey: window.windowId)
        }

        inFlight.remove(window.windowId)
        inFlightSince.removeValue(forKey: window.windowId)

        closeVideoConnection(windowId: window.windowId, reason: "end pull stream")

        let req = PeelRequest(type: "stopStream", windowId: window.windowId)
        sendJSONMessage(req)
    }
}
