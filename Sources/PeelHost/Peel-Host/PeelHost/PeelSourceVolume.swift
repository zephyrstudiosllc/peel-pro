//
//  PeelSourceVolume.swift
//  Peel-Host
//
//  This Mac's own system output volume/mute through public CoreAudio
//  AudioObject APIs. Every operation reads the current default output.
//  It never changes output routing, capture gain, the receiver or any
//  permission. A control that is missing, read-only or inconsistent is
//  reported as unavailable rather than approximated.
//

import CoreAudio
import AudioToolbox

struct PeelSourceVolume: PeelSourceVolumeControlling {
    /// Stereo channels must agree this closely to read or write them as one level.
    private static let channelTolerance: Float32 = 0.001

    func currentDevice() -> UInt32? {
        Self.defaultOutputDevice()
    }

    func read() -> PeelSourceVolumeReading {
        guard let device = Self.defaultOutputDevice() else {
            return PeelSourceVolumeReading(device: nil, volume: nil, muted: nil, canSetVolume: false, canSetMute: false)
        }
        return Self.reading(of: device)
    }

    func apply(volume: Double?, muted: Bool?, expectedDevice: UInt32) -> PeelSourceVolumeApplyResult {
        guard let device = Self.defaultOutputDevice() else { return .noOutputDevice }
        guard device == expectedDevice else { return .deviceChanged }
        let before = Self.reading(of: device)
        // Check every requested control before writing any of them.
        if volume != nil, !before.canSetVolume { return .notSettable }
        if muted != nil, !before.canSetMute { return .notSettable }
        if let volume {
            guard let control = Self.volumeControl(device) else { return .notSettable }
            var value = Float32(volume)
            for address in control {
                guard Self.write(device, address, &value) else { return .failed }
            }
        }
        if let muted {
            guard let control = Self.muteControl(device) else { return .notSettable }
            var value: UInt32 = muted ? 1 : 0
            for address in control {
                guard Self.write(device, address, &value) else { return .failed }
            }
        }
        // Report nothing about a different device that became default meanwhile.
        guard Self.defaultOutputDevice() == expectedDevice else { return .deviceChanged }
        return .applied(Self.reading(of: device))
    }

    // MARK: Reading

    private static func reading(of device: AudioObjectID) -> PeelSourceVolumeReading {
        let volumeControl = volumeControl(device)
        let muteControl = muteControl(device)
        let volume = volumeControl.flatMap { readVolume(device, $0) }
        let muted = muteControl.flatMap { readMute(device, $0) }
        return PeelSourceVolumeReading(
            device: device,
            volume: volume,
            muted: muted,
            canSetVolume: volume != nil && (volumeControl.map { allSettable(device, $0) } ?? false),
            canSetMute: muted != nil && (muteControl.map { allSettable(device, $0) } ?? false))
    }

    private static func readVolume(_ device: AudioObjectID, _ control: [AudioObjectPropertyAddress]) -> Double? {
        var values: [Float32] = []
        for address in control {
            var value: Float32 = 0
            guard readValue(device, address, &value), value.isFinite, value >= 0, value <= 1 else { return nil }
            values.append(value)
        }
        guard let first = values.first, let low = values.min(), let high = values.max(),
              high - low <= channelTolerance else { return nil }
        return Double(first)
    }

    private static func readMute(_ device: AudioObjectID, _ control: [AudioObjectPropertyAddress]) -> Bool? {
        var values: [UInt32] = []
        for address in control {
            var value: UInt32 = 0
            guard readValue(device, address, &value), value <= 1 else { return nil }
            values.append(value)
        }
        guard let first = values.first, values.allSatisfy({ $0 == first }) else { return nil }
        return first == 1
    }

    // MARK: Controls

    /// Device-wide control first; otherwise the preferred stereo pair, used
    /// only while both channels agree (so balance is never rewritten).
    private static func volumeControl(_ device: AudioObjectID) -> [AudioObjectPropertyAddress]? {
        let virtualMain = outputAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        if has(device, virtualMain) { return [virtualMain] }
        let main = outputAddress(kAudioDevicePropertyVolumeScalar)
        if has(device, main) { return [main] }
        return stereoControl(device, selector: kAudioDevicePropertyVolumeScalar)
    }

    private static func muteControl(_ device: AudioObjectID) -> [AudioObjectPropertyAddress]? {
        let main = outputAddress(kAudioDevicePropertyMute)
        if has(device, main) { return [main] }
        return stereoControl(device, selector: kAudioDevicePropertyMute)
    }

    private static func stereoControl(_ device: AudioObjectID,
                                      selector: AudioObjectPropertySelector) -> [AudioObjectPropertyAddress]? {
        var channels: (UInt32, UInt32) = (0, 0)
        guard readValue(device, outputAddress(kAudioDevicePropertyPreferredChannelsForStereo), &channels),
              channels.0 > 0, channels.1 > 0, channels.0 != channels.1 else { return nil }
        let control = [outputAddress(selector, element: channels.0), outputAddress(selector, element: channels.1)]
        return control.allSatisfy { has(device, $0) } ? control : nil
    }

    // MARK: CoreAudio

    private static func defaultOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == kAudioHardwareNoError, size == UInt32(MemoryLayout<AudioObjectID>.size),
              device != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return device
    }

    private static func outputAddress(_ selector: AudioObjectPropertySelector,
                                      element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeOutput, mElement: element)
    }

    private static func has(_ device: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(device, &address)
    }

    private static func allSettable(_ device: AudioObjectID, _ control: [AudioObjectPropertyAddress]) -> Bool {
        control.allSatisfy { address in
            var address = address
            var settable: DarwinBoolean = false
            return AudioObjectIsPropertySettable(device, &address, &settable) == kAudioHardwareNoError && settable.boolValue
        }
    }

    /// Reads exactly `MemoryLayout<T>.size` bytes or fails.
    private static func readValue<T>(_ device: AudioObjectID, _ address: AudioObjectPropertyAddress,
                                     _ value: inout T) -> Bool {
        var address = address
        let expected = UInt32(MemoryLayout<T>.size)
        var size = expected
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        return status == kAudioHardwareNoError && size == expected
    }

    private static func write<T>(_ device: AudioObjectID, _ address: AudioObjectPropertyAddress,
                                 _ value: inout T) -> Bool {
        var address = address
        let size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(device, &address, 0, nil, size, $0)
        }
        return status == kAudioHardwareNoError
    }
}
