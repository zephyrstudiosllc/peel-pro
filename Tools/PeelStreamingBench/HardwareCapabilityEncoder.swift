// Deliberately independent capability probe, NOT a production encoder.
// A bounded four-frame pipeline measures whether the hardware itself can keep up.
private final class HardwareCapabilityEncoder {
    private let queue = DispatchQueue(label: "peel.bench.hardware", qos: .userInteractive)
    private let diagnostics: PeelStreamingDiagnostics
    private let token: UUID?
    private let windowID: UInt32
    private var session: VTCompressionSession?
    private var nextSequence: UInt = 0
    private var submitted: [UInt: Double] = [:]
    private var pending: (CMSampleBuffer, Bool)?
    private var invalidated = false

    init(windowId: UInt32, width: Int, height: Int, bitRate: Int, fps: Int,
         preferredCodec: PeelVideoCodec, teardownQueue: DispatchQueue, diagnostics: PeelStreamingDiagnostics) {
        self.windowID = windowId; self.diagnostics = diagnostics
        token = diagnostics.begin(windowID: windowId, width: width, height: height,
            targetFPS: fps, targetBitrate: bitRate, preferredCodec: preferredCodec == .hevc ? "hevc" : "h264")
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
            codecType: preferredCodec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: Self.callback,
            refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &session)
        guard status == noErr, let session else { fatalError("Hardware create failed: \(status)") }
        let properties: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue),
            (kVTCompressionPropertyKey_ProfileLevel, preferredCodec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel),
            (kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitRate)),
            (kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps)),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: fps * 2))]
        for (key, value) in properties {
            let status = VTSessionSetProperty(session, key: key, value: value)
            guard status == noErr else { fatalError("Hardware property \(key) failed: \(status)") }
        }
        if #available(macOS 15.0, *) {
            let maximumRateStatus = VTSessionSetProperty(session,
                key: kVTCompressionPropertyKey_MaximumRealTimeFrameRate, value: NSNumber(value: fps))
            guard maximumRateStatus == noErr else { fatalError("Hardware maximum rate failed: \(maximumRateStatus)") }
        }
        let prepare = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepare == noErr else { fatalError("Hardware prepare failed: \(prepare)") }
        var encoderID: Unmanaged<CFTypeRef>?
        _ = VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_EncoderID, allocator: nil, valueOut: &encoderID)
        diagnostics.setEncoder(windowID: windowID, token: token,
            codec: preferredCodec == .hevc ? "hevc" : "h264", mode: "fourFrameHardwareCapabilityOnly",
            hardwareAccelerated: true, hardwareVerification: "requiredAtCreation",
            encoderID: encoderID?.takeRetainedValue() as? String)
        diagnostics.setSpeedPriorityStatus(windowID: windowID, token: token, status: 0)
    }

    func encodeAsync(sampleBuffer: CMSampleBuffer, forceKeyframe: Bool) {
        queue.async { self.encode(sampleBuffer, forceKeyframe) }
    }

    private func encode(_ sample: CMSampleBuffer, _ forceKeyframe: Bool) {
        guard !invalidated, let session, let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        if submitted.count >= 4 {
            if pending != nil { diagnostics.replacedPending(windowID: windowID, token: token) }
            pending = (sample, forceKeyframe || (pending?.1 ?? false))
            return
        }
        nextSequence += 1
        let sequence = nextSequence
        submitted[sequence] = ProcessInfo.processInfo.systemUptime
        diagnostics.submitted(windowID: windowID, token: token)
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: buffer,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample), duration: CMSampleBufferGetDuration(sample),
            frameProperties: forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil,
            sourceFrameRefcon: UnsafeMutableRawPointer(bitPattern: sequence), infoFlagsOut: nil)
        if status != noErr {
            submitted.removeValue(forKey: sequence)
            diagnostics.sessionFailure(windowID: windowID, token: token, reason: "hardware capability submit=\(status)")
        }
    }

    func invalidateAsync() {
        queue.sync {
            invalidated = true; pending = nil; submitted.removeAll()
            if let session { VTCompressionSessionInvalidate(session) }
            session = nil
        }
    }

    private static let callback: VTCompressionOutputCallback = { refcon, frame, status, _, sample in
        guard let refcon, let frame else { return }
        let encoder = Unmanaged<HardwareCapabilityEncoder>.fromOpaque(refcon).takeUnretainedValue()
        let sequence = UInt(bitPattern: frame)
        encoder.queue.async {
            guard !encoder.invalidated, let start = encoder.submitted.removeValue(forKey: sequence) else { return }
            if status == noErr, let sample, CMSampleBufferDataIsReady(sample), let data = CMSampleBufferGetDataBuffer(sample) {
                let attachment = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]])?.first
                let keyframe = (attachment?[kCMSampleAttachmentKey_NotSync] as? Bool) != true
                encoder.diagnostics.output(windowID: encoder.windowID, token: encoder.token,
                    bytes: CMBlockBufferGetDataLength(data), keyframe: keyframe,
                    encodeMilliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000)
            } else {
                encoder.diagnostics.sessionFailure(windowID: encoder.windowID, token: encoder.token,
                    reason: "hardware capability callback=\(status) validSample=\(sample != nil)")
            }
            if let pending = encoder.pending {
                encoder.pending = nil
                encoder.encode(pending.0, pending.1)
            }
        }
    }
}
