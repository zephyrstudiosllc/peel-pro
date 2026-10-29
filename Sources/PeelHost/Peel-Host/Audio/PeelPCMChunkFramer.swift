import Foundation

enum PeelPCMConversionBounds {
    static let minimumSourceSampleRate = 8_000.0
    static let maximumSourceSampleRate = 192_000.0
    static let maximumSourceDurationSeconds = 0.120

    static func maximumInputFrameCount(for sampleRate: Double) -> Int? {
        guard sampleRate.isFinite,
              (minimumSourceSampleRate...maximumSourceSampleRate).contains(sampleRate) else {
            return nil
        }

        let frameCount = ceil(sampleRate * maximumSourceDurationSeconds)
        guard frameCount >= 1, frameCount <= Double(Int.max) else { return nil }
        return Int(frameCount)
    }
}

struct PeelPCMChunkFrame: Equatable {
    let sequenceNumber: UInt64
    let startSampleTime: Int64
    let pcmData: Data
}

struct PeelPCMChunkFramer {
    static let sampleRate = 48_000
    static let channelCount = 2
    static let bytesPerSample = 2
    static let framesPerChunk = 960
    static let bytesPerFrame = channelCount * bytesPerSample
    static let bytesPerChunk = framesPerChunk * bytesPerFrame

    // AVAudioConverter output is capped to this amount before it reaches the framer.
    // Together with the sub-chunk remainder, one append can emit at most three chunks.
    static let maxInputFramesPerAppend = 2_048

    enum FramingError: Error, Equatable {
        case unalignedByteCount(Int)
        case tooManyFrames(Int)
        case sampleTimeOverflow
    }

    private var pendingData = Data()
    private var pendingStartSampleTime: Int64?
    private var nextSequenceNumber: UInt64 = 0

    var bufferedFrameCount: Int {
        pendingData.count / Self.bytesPerFrame
    }

    mutating func append(
        interleavedStereoS16LE data: Data,
        startSampleTime: Int64
    ) throws -> [PeelPCMChunkFrame] {
        guard data.count.isMultiple(of: Self.bytesPerFrame) else {
            throw FramingError.unalignedByteCount(data.count)
        }

        let inputFrameCount = data.count / Self.bytesPerFrame
        guard inputFrameCount <= Self.maxInputFramesPerAppend else {
            throw FramingError.tooManyFrames(inputFrameCount)
        }
        guard inputFrameCount > 0 else { return [] }

        if let pendingStartSampleTime {
            let (expectedStart, overflow) = pendingStartSampleTime.addingReportingOverflow(
                Int64(bufferedFrameCount)
            )
            guard !overflow else {
                discardBufferedAudio()
                throw FramingError.sampleTimeOverflow
            }

            let isContinuous: Bool
            let (difference, differenceOverflow) = expectedStart.subtractingReportingOverflow(startSampleTime)
            if differenceOverflow {
                isContinuous = false
            } else {
                isContinuous = (-1...1).contains(difference)
            }

            if !isContinuous {
                discardBufferedAudio()
            }
        }

        if pendingData.isEmpty {
            pendingStartSampleTime = startSampleTime
        }
        pendingData.append(data)

        var chunks: [PeelPCMChunkFrame] = []
        chunks.reserveCapacity(3)

        while pendingData.count >= Self.bytesPerChunk {
            guard let chunkStartSampleTime = pendingStartSampleTime else {
                discardBufferedAudio()
                throw FramingError.sampleTimeOverflow
            }

            let chunkData = Data(pendingData.prefix(Self.bytesPerChunk))
            pendingData.removeFirst(Self.bytesPerChunk)
            chunks.append(
                PeelPCMChunkFrame(
                    sequenceNumber: nextSequenceNumber,
                    startSampleTime: chunkStartSampleTime,
                    pcmData: chunkData
                )
            )
            nextSequenceNumber &+= 1

            let (nextStart, overflow) = chunkStartSampleTime.addingReportingOverflow(
                Int64(Self.framesPerChunk)
            )
            guard !overflow else {
                discardBufferedAudio()
                throw FramingError.sampleTimeOverflow
            }
            pendingStartSampleTime = pendingData.isEmpty ? nil : nextStart
        }

        return chunks
    }

    mutating func discardBufferedAudio() {
        pendingData.removeAll(keepingCapacity: true)
        pendingStartSampleTime = nil
    }

    mutating func resetForNewCapture() {
        discardBufferedAudio()
        nextSequenceNumber = 0
    }
}
