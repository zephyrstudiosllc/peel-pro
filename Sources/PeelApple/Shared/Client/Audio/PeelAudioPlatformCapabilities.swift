#if os(iOS) || os(visionOS)

/// Platform gates shared by the audio UI and the client audio controller.
///
/// The shared iOS client supports both iPhone and iPad. Vision uses its native
/// audio surface directly; neither platform needs a device-idiom check.
public enum PeelAudioPlatformCapabilities {
    @MainActor
    public static var supportsMacSystemAudio: Bool {
        true
    }

    @MainActor
    public static var supportsFullDuplexVoice: Bool {
        supportsMacSystemAudio
    }
}

#endif
