import Foundation

/// Errors raised before bytes are copied into an audio buffer.
nonisolated public enum PeelAudioPlaybackPCMError: Error, Equatable, Sendable, LocalizedError {
    case invalidFrameCount(Int)
    case byteCountOverflow
    case invalidByteCount(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case let .invalidFrameCount(frameCount):
            return "Audio playback frame count \(frameCount) is outside the bounded PCM range."
        case .byteCountOverflow:
            return "Audio playback PCM byte count overflowed."
        case let .invalidByteCount(expected, actual):
            return "Audio playback PCM has \(actual) bytes; \(expected) are required."
        }
    }
}

/// The bounded scheduling result used by the AVAudioPlayerNode owner.
nonisolated public enum PeelAudioPlaybackScheduleDecision: Equatable, Sendable {
    case accepted(sequence: UInt64, sampleTime: Int64, silenceChunks: Int)
    case duplicate
    case oldFrame
    case gapTooLarge
    case queueFull
    case invalidPacket
    case timelineMismatch
    case arithmeticOverflow
}

/// Two deinterleaved Float32 channels ready for an AVAudioPCMBuffer.
nonisolated public struct PeelAudioPlaybackFloatStereo: Equatable, Sendable {
    public let left: [Float]
    public let right: [Float]

    public init(left: [Float], right: [Float]) {
        self.left = left
        self.right = right
    }
}

/// Pure sequence/timeline admission state for fixed 20 ms downlink chunks.
///
/// The state does not allocate buffers. Callers first ask for a decision with
/// their current scheduled-buffer count, then call `commit(_:after:)` only once
/// all buffers for an accepted packet have been scheduled successfully.
nonisolated public struct PeelAudioPlaybackSchedulingState: Sendable {
    public static let chunkFrameCount = 960
    public static let maxScheduledChunks = 6
    /// At most two missing 20 ms chunks are synthesized as silence.
    public static let maxSequenceGap = 2

    public private(set) var lastSequence: UInt64?
    public private(set) var lastSampleTime: Int64?

    public init() {
        lastSequence = nil
        lastSampleTime = nil
    }

    public mutating func reset() {
        lastSequence = nil
        lastSampleTime = nil
    }

    /// Computes admission without changing state or allocating PCM storage.
    public func decision(
        for packet: PeelAudioPacket,
        scheduledChunkCount: Int
    ) -> PeelAudioPlaybackScheduleDecision {
        guard packet.kind == .pcm,
              packet.direction == .macToClient,
              packet.format == .v1(for: .macToClient),
              packet.frameCount == UInt16(Self.chunkFrameCount)
        else {
            return .invalidPacket
        }

        guard scheduledChunkCount >= 0,
              scheduledChunkCount <= Self.maxScheduledChunks
        else {
            return .queueFull
        }

        guard let previousSequence = lastSequence,
              let previousSampleTime = lastSampleTime
        else {
            guard scheduledChunkCount < Self.maxScheduledChunks else {
                return .queueFull
            }
            return .accepted(sequence: packet.sequence,
                             sampleTime: packet.sampleTime,
                             silenceChunks: 0)
        }

        if packet.sequence == previousSequence {
            return .duplicate
        }
        if packet.sequence < previousSequence {
            return .oldFrame
        }

        let (expectedSequence, sequenceOverflow) = previousSequence.addingReportingOverflow(1)
        guard !sequenceOverflow else {
            return .arithmeticOverflow
        }
        let (missingSequenceCount, subtractionOverflow) =
            packet.sequence.subtractingReportingOverflow(expectedSequence)
        guard !subtractionOverflow else {
            return .arithmeticOverflow
        }
        guard missingSequenceCount <= UInt64(Self.maxSequenceGap) else {
            return .gapTooLarge
        }

        let missingChunks = Int(missingSequenceCount)
        let (chunksToPacket, chunksOverflow) = missingChunks.addingReportingOverflow(1)
        guard !chunksOverflow else {
            return .arithmeticOverflow
        }
        let (sampleAdvance, sampleAdvanceOverflow) =
            Self.chunkFrameCount.multipliedReportingOverflow(by: chunksToPacket)
        guard !sampleAdvanceOverflow else {
            return .arithmeticOverflow
        }
        let (expectedSampleTime, sampleTimeOverflow) =
            previousSampleTime.addingReportingOverflow(Int64(sampleAdvance))
        guard !sampleTimeOverflow else {
            return .arithmeticOverflow
        }
        guard packet.sampleTime == expectedSampleTime else {
            return .timelineMismatch
        }

        let (requiredChunks, requiredOverflow) = missingChunks.addingReportingOverflow(1)
        guard !requiredOverflow,
              requiredChunks <= Self.maxScheduledChunks - scheduledChunkCount
        else {
            return .queueFull
        }

        return .accepted(sequence: packet.sequence,
                         sampleTime: packet.sampleTime,
                         silenceChunks: missingChunks)
    }

    /// Records a packet after the owner has scheduled its silence and PCM.
    public mutating func commit(
        _ packet: PeelAudioPacket,
        after decision: PeelAudioPlaybackScheduleDecision
    ) {
        guard case let .accepted(sequence, sampleTime, _) = decision,
              packet.kind == .pcm,
              packet.sequence == sequence,
              packet.sampleTime == sampleTime
        else {
            return
        }
        lastSequence = sequence
        lastSampleTime = sampleTime
    }
}

/// Bounded, collection-index-safe conversion helpers for stereo S16LE PCM.
nonisolated public enum PeelAudioPlaybackPCM {
    public static let sampleRate: UInt32 = 48_000
    public static let channelCount = 2
    public static let bytesPerSample = 2
    public static let maxFrameCount = PeelAudioPlaybackSchedulingState.chunkFrameCount

    public static func expectedByteCount(frameCount: Int) throws -> Int {
        guard frameCount > 0, frameCount <= Self.maxFrameCount else {
            throw PeelAudioPlaybackPCMError.invalidFrameCount(frameCount)
        }
        let (sampleCount, sampleOverflow) =
            frameCount.multipliedReportingOverflow(by: Self.channelCount)
        guard !sampleOverflow else {
            throw PeelAudioPlaybackPCMError.byteCountOverflow
        }
        let (byteCount, byteOverflow) =
            sampleCount.multipliedReportingOverflow(by: Self.bytesPerSample)
        guard !byteOverflow else {
            throw PeelAudioPlaybackPCMError.byteCountOverflow
        }
        return byteCount
    }

    /// Validates and copies a byte collection by iterating its actual indices.
    /// This deliberately accepts `Data.SubSequence`, whose start index may be
    /// non-zero, instead of assuming an offset-zero buffer.
    public static func validatedStereoS16LE<C: Collection>(
        _ bytes: C,
        frameCount: Int
    ) throws -> [UInt8] where C.Element == UInt8 {
        let expected = try Self.expectedByteCount(frameCount: frameCount)
        guard bytes.count == expected else {
            throw PeelAudioPlaybackPCMError.invalidByteCount(expected: expected,
                                                             actual: bytes.count)
        }
        var result: [UInt8] = []
        result.reserveCapacity(expected)
        result.append(contentsOf: bytes)
        return result
    }

    /// Decodes little-endian signed samples for pure fixture verification.
    public static func decodeStereoS16LE<C: Collection>(
        _ bytes: C,
        frameCount: Int
    ) throws -> [Int16] where C.Element == UInt8 {
        let raw = try Self.validatedStereoS16LE(bytes, frameCount: frameCount)
        let sampleCount = raw.count / Self.bytesPerSample
        var result: [Int16] = []
        result.reserveCapacity(sampleCount)
        for offset in stride(from: 0, to: raw.count, by: Self.bytesPerSample) {
            let unsignedValue = UInt16(raw[offset]) |
                (UInt16(raw[offset + 1]) << 8)
            result.append(Int16(bitPattern: unsignedValue))
        }
        return result
    }

    /// Converts stereo S16LE samples to deinterleaved Float32 channels.
    /// Signed 16-bit full scale maps to -1.0 ... 32767/32768.0.
    public static func decodeStereoS16LEToFloatChannels<C: Collection>(
        _ bytes: C,
        frameCount: Int
    ) throws -> PeelAudioPlaybackFloatStereo where C.Element == UInt8 {
        let raw = try Self.validatedStereoS16LE(bytes, frameCount: frameCount)
        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(frameCount)
        right.reserveCapacity(frameCount)

        for frame in 0..<frameCount {
            let offset = frame * Self.channelCount * Self.bytesPerSample
            let leftBits = UInt16(raw[offset]) |
                (UInt16(raw[offset + 1]) << 8)
            let rightBits = UInt16(raw[offset + 2]) |
                (UInt16(raw[offset + 3]) << 8)
            left.append(Float(Int16(bitPattern: leftBits)) / 32_768.0)
            right.append(Float(Int16(bitPattern: rightBits)) / 32_768.0)
        }
        return PeelAudioPlaybackFloatStereo(left: left, right: right)
    }
}
