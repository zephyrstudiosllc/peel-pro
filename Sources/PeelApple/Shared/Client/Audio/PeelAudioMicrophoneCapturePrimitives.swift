import Foundation

nonisolated public enum PeelAudioMicrophoneCaptureConversionError: Error, Equatable, Sendable, LocalizedError {
    case invalidSourceSampleRate
    case inputTooLarge
    case sourceBufferOverflow
    case resampledOutputOverflow
    case packetCounterOverflow

    public var errorDescription: String? {
        switch self {
        case .invalidSourceSampleRate:
            return "The microphone source sample rate is unsupported or non-finite."
        case .inputTooLarge:
            return "The microphone input buffer exceeds the bounded capture size."
        case .sourceBufferOverflow:
            return "The bounded microphone resampler source buffer would overflow."
        case .resampledOutputOverflow:
            return "The bounded microphone resampler output would overflow."
        case .packetCounterOverflow:
            return "The microphone packet sequence or sample time would overflow."
        }
    }
}

/// Streaming linear resampling from a finite hardware rate to 48 kHz mono.
nonisolated public struct PeelAudioMicrophoneResampler: Sendable {
    public static let outputSampleRate = 48_000.0
    public static let maxInputFrames = 4_096
    public static let maxSourceFrames = 16_384
    public static let maxOutputFramesPerAppend = 32_768
    public static let minimumSourceSampleRate = 8_000.0
    public static let maximumSourceSampleRate = 384_000.0

    private var sourceSamples: [Float] = []
    private var sourcePhase = 0.0
    private var sourceSampleRate: Double?

    public init() {
        sourceSamples.reserveCapacity(Self.maxSourceFrames)
    }

    public mutating func reset() {
        sourceSamples.removeAll(keepingCapacity: true)
        sourcePhase = 0
        sourceSampleRate = nil
    }

    /// Appends one bounded mono hardware buffer and returns bounded 48 kHz
    /// samples. The input collection is consumed by iteration, so no pointer
    /// base-index assumption is made by callers.
    public mutating func append<C: Collection>(
        _ input: C,
        sourceSampleRate: Double
    ) throws -> [Float] where C.Element == Float {
        guard sourceSampleRate.isFinite,
              sourceSampleRate >= Self.minimumSourceSampleRate,
              sourceSampleRate <= Self.maximumSourceSampleRate
        else {
            throw PeelAudioMicrophoneCaptureConversionError.invalidSourceSampleRate
        }
        guard input.count <= Self.maxInputFrames else {
            throw PeelAudioMicrophoneCaptureConversionError.inputTooLarge
        }

        if let previousRate = self.sourceSampleRate,
           previousRate != sourceSampleRate {
            reset()
        }
        self.sourceSampleRate = sourceSampleRate

        let (newSourceCount, sourceCountOverflow) =
            sourceSamples.count.addingReportingOverflow(input.count)
        guard !sourceCountOverflow,
              newSourceCount <= Self.maxSourceFrames
        else {
            throw PeelAudioMicrophoneCaptureConversionError.sourceBufferOverflow
        }
        sourceSamples.append(contentsOf: input)

        let ratio = Self.outputSampleRate / sourceSampleRate
        let estimatedOutput = (Double(sourceSamples.count) + 1.0) * ratio + 1.0
        guard estimatedOutput.isFinite,
              estimatedOutput <= Double(Self.maxOutputFramesPerAppend)
        else {
            throw PeelAudioMicrophoneCaptureConversionError.resampledOutputOverflow
        }

        var output: [Float] = []
        output.reserveCapacity(Int(estimatedOutput.rounded(.up)))
        while sourcePhase + 1.0 < Double(sourceSamples.count) {
            let baseIndex = Int(sourcePhase)
            let fraction = Float(sourcePhase - Double(baseIndex))
            let first = sourceSamples[baseIndex]
            let second = sourceSamples[baseIndex + 1]
            output.append(first + ((second - first) * fraction))
            sourcePhase += 1.0 / ratio
            guard output.count <= Self.maxOutputFramesPerAppend else {
                throw PeelAudioMicrophoneCaptureConversionError.resampledOutputOverflow
            }
        }

        let removableCount = min(Int(sourcePhase.rounded(.down)),
                                 max(0, sourceSamples.count - 1))
        if removableCount > 0 {
            sourceSamples.removeFirst(removableCount)
            sourcePhase -= Double(removableCount)
        }
        return output
    }
}

/// Packetizes bounded mono 48 kHz samples into the existing uplink format.
nonisolated public struct PeelAudioMicrophonePacketizer: Sendable {
    public static let sampleRate: UInt32 = 48_000
    public static let frameCount = 960
    public static let maxPayloadLength = frameCount * 2
    public static let maxSamplesPerAppend = PeelAudioMicrophoneResampler.maxOutputFramesPerAppend

    private var pendingSamples = [Float](repeating: 0, count: Self.frameCount)
    private var pendingCount = 0
    private var nextSequence: UInt64 = 0
    private var nextSampleTime: Int64 = 0

    public init() {}

    public var pendingFrameCount: Int { pendingCount }

    public mutating func reset() {
        pendingCount = 0
        nextSequence = 0
        nextSampleTime = 0
    }

    /// Returns zero or more complete mono uplink packets. The packet codec is
    /// supplied by the caller's existing client copy of `PeelAudioPacket`.
    public mutating func append<C: Collection>(
        _ samples: C
    ) throws -> [PeelAudioPacket] where C.Element == Float {
        guard samples.count <= Self.maxSamplesPerAppend else {
            throw PeelAudioMicrophoneCaptureConversionError.inputTooLarge
        }
        let (roundedSampleCount, countOverflow) =
            samples.count.addingReportingOverflow(Self.frameCount - 1)
        guard !countOverflow else {
            throw PeelAudioMicrophoneCaptureConversionError.inputTooLarge
        }
        let boundedPacketCount = roundedSampleCount / Self.frameCount
        var packets: [PeelAudioPacket] = []
        packets.reserveCapacity(boundedPacketCount)

        for sample in samples {
            pendingSamples[pendingCount] = sample
            pendingCount += 1
            if pendingCount == Self.frameCount {
                packets.append(try makePacket())
                pendingCount = 0
            }
        }
        return packets
    }

    private mutating func makePacket() throws -> PeelAudioPacket {
        let (nextSequence, sequenceOverflow) = nextSequence.addingReportingOverflow(1)
        let (nextSampleTime, sampleTimeOverflow) =
            nextSampleTime.addingReportingOverflow(Int64(Self.frameCount))
        guard !sequenceOverflow, !sampleTimeOverflow else {
            throw PeelAudioMicrophoneCaptureConversionError.packetCounterOverflow
        }

        var payload = Data(capacity: Self.maxPayloadLength)
        for sample in pendingSamples {
            let value = quantize(sample)
            let bits = UInt16(bitPattern: value)
            payload.append(UInt8(bits & 0xff))
            payload.append(UInt8(bits >> 8))
        }

        let packet = try PeelAudioPacket.pcmPacket(for: .clientToMac,
                                                   sequence: self.nextSequence,
                                                   sampleTime: self.nextSampleTime,
                                                   payload: payload)
        self.nextSequence = nextSequence
        self.nextSampleTime = nextSampleTime
        return packet
    }

    private func quantize(_ sample: Float) -> Int16 {
        guard sample.isFinite else { return 0 }
        if sample <= -1.0 { return Int16.min }
        if sample >= 1.0 { return Int16.max }

        let scaled = (sample * 32_768.0).rounded(.toNearestOrAwayFromZero)
        if scaled <= Float(Int16.min) { return Int16.min }
        if scaled >= Float(Int16.max) { return Int16.max }
        return Int16(scaled)
    }
}

/// A bounded conversion pipeline used by the capture drain worker.
nonisolated public struct PeelAudioMicrophoneCaptureConverter: Sendable {
    private var resampler = PeelAudioMicrophoneResampler()
    private var packetizer = PeelAudioMicrophonePacketizer()

    public init() {}

    public mutating func reset() {
        resampler.reset()
        packetizer.reset()
    }

    public mutating func append<C: Collection>(
        _ input: C,
        sourceSampleRate: Double
    ) throws -> [PeelAudioPacket] where C.Element == Float {
        let resampled = try resampler.append(input, sourceSampleRate: sourceSampleRate)
        return try packetizer.append(resampled)
    }
}
