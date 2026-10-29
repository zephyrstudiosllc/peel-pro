import Foundation
import VideoToolbox

// Encoder discovery only; no screen capture, frames, transport or device settings.
for (codecName, codecType) in [("hevc", kCMVideoCodecType_HEVC), ("h264", kCMVideoCodecType_H264)] {
for lowLatency in [true, false] {
    var session: VTCompressionSession?
    var specification: [String: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true]
    if lowLatency { specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String] = true }
    let status = VTCompressionSessionCreate(allocator: nil, width: 5120, height: 2880,
        codecType: codecType, encoderSpecification: specification as CFDictionary,
        imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
        refcon: nil, compressionSessionOut: &session)
    var report: [String: Any] = ["codec": codecName, "lowLatency": lowLatency, "createStatus": status]
    if let session {
        defer { VTCompressionSessionInvalidate(session) }
        var supported: CFDictionary?
        report["supportedPropertiesStatus"] = VTSessionCopySupportedPropertyDictionary(session, supportedPropertyDictionaryOut: &supported)
        if let dictionary = supported as? [String: Any] {
            report["supportedKeys"] = dictionary.keys.sorted()
            report["maxFrameDelayDescription"] = dictionary[kVTCompressionPropertyKey_MaxFrameDelayCount as String].map { String(describing: $0) } ?? "unavailable"
        }
        for key in [kVTCompressionPropertyKey_EncoderID,
                    kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                    kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
                    kVTCompressionPropertyKey_ExpectedFrameRate,
                    kVTCompressionPropertyKey_MaxFrameDelayCount] {
            var value: Unmanaged<CFTypeRef>?
            let propertyStatus = VTSessionCopyProperty(session, key: key, allocator: nil, valueOut: &value)
            report[key as String] = ["status": propertyStatus, "value": value.map { String(describing: $0.takeRetainedValue()) } ?? "unavailable"]
        }
        var propertyChanges: [[String: Any]] = []
        let properties: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue),
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_MaxFrameDelayCount, NSNumber(value: 0)),
            (kVTCompressionPropertyKey_MaxFrameDelayCount, NSNumber(value: 1)),
            (kVTCompressionPropertyKey_MaxFrameDelayCount, NSNumber(value: 2)),
            (kVTCompressionPropertyKey_MaxFrameDelayCount, NSNumber(value: 3))]
        for (key, value) in properties {
            let setStatus = VTSessionSetProperty(session, key: key, value: value)
            var selectedEncoder: Unmanaged<CFTypeRef>?
            let idStatus = VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_EncoderID,
                allocator: nil, valueOut: &selectedEncoder)
            propertyChanges.append(["key": key as String, "setStatus": setStatus,
                "encoderIDStatus": idStatus,
                "encoderID": selectedEncoder.map { String(describing: $0.takeRetainedValue()) } ?? "unavailable"])
        }
        report["propertyChanges"] = propertyChanges
    }
    let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}
}
