import VideoToolbox

/// A hardware-required creation specification is a VideoToolbox contract, even
/// when a particular encoder mode does not expose the optional inspection key.
nonisolated enum PeelVideoEncoderHardwarePolicy {
    enum Verification: String, Sendable {
        case queried
        case requiredAtCreation
        case unavailable
    }

    static func verification(status: OSStatus, reportedHardware: Bool?,
                             hardwareRequired: Bool) -> Verification {
        if status == noErr, reportedHardware == true { return .queried }
        if hardwareRequired, status == kVTPropertyNotSupportedErr { return .requiredAtCreation }
        return .unavailable
    }
}
