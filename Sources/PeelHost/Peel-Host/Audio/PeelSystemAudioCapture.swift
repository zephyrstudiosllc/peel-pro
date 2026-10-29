import Foundation
import AVFAudio
import CoreMedia
import ScreenCaptureKit

/// Owns one display-scoped ScreenCaptureKit system-audio stream.
///
/// All callbacks run synchronously on this object's private serial state queue.
/// Callbacks must return promptly and must not wait for downstream I/O. `start` and
/// `stop` are safe to call from a callback because they enqueue their work.
final class PeelSystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    static let outputSampleRate = PeelPCMChunkFramer.sampleRate
    static let outputChannelCount = PeelPCMChunkFramer.channelCount
    static let outputFramesPerChunk = PeelPCMChunkFramer.framesPerChunk

    struct PCMChunk {
        let sequenceNumber: UInt64
        let presentationTime: CMTime
        let frameCount: Int
        let sampleRate: Int
        let channelCount: Int
        let interleavedStereoS16LE: Data
    }

    enum ChunkDisposition {
        /// The downstream accepted the chunk.
        case accepted

        /// The downstream is full. The owner drops this chunk, all remaining audio
        /// from the source sample, converter/framer remainders, and the output
        /// timeline anchor. The next source sample rebases from its own timestamp.
        case backpressured

        /// Stop this capture generation and report `downstreamRequestedStop`.
        case stopCapture
    }

    enum CaptureState: String {
        case idle
        case starting
        case running
        case stopping
        case stopFailed
    }

    enum CaptureError: Error, LocalizedError {
        case busy(CaptureState)
        case startCancelled
        case startFailed(Error)
        case stopFailed(Error)
        case captureFailureAndStopFailed(captureFailure: String, stopError: Error)
        case streamStopped(Error)
        case conversionFailed(String)
        case downstreamRequestedStop

        var errorDescription: String? {
            switch self {
            case .busy(let state):
                return "System audio capture is \(state.rawValue)."
            case .startCancelled:
                return "System audio capture startup was cancelled."
            case .startFailed(let error):
                return "System audio capture failed to start: \(error.localizedDescription)"
            case .stopFailed(let error):
                return "System audio capture failed to stop cleanly: \(error.localizedDescription)"
            case .captureFailureAndStopFailed(let captureFailure, let stopError):
                return "System audio capture failed (\(captureFailure)) and its stream could not be confirmed stopped: \(stopError.localizedDescription)"
            case .streamStopped(let error):
                return "System audio capture stopped: \(error.localizedDescription)"
            case .conversionFailed(let detail):
                return "System audio conversion failed: \(detail)"
            case .downstreamRequestedStop:
                return "System audio capture stopped at the downstream's request."
            }
        }
    }

    typealias ChunkHandler = (PCMChunk) -> ChunkDisposition
    typealias FailureHandler = (CaptureError) -> Void
    typealias OperationCompletion = (Result<Void, CaptureError>) -> Void

    private enum ProcessingError: Error, LocalizedError {
        case sampleDataNotReady
        case missingFormat
        case unsupportedSourceFormat
        case unsupportedSourceSampleRate(Double)
        case invalidTimestamp
        case oversizedSample(frameCount: Int, maximum: Int)
        case converterUnavailable
        case sourceBufferUnavailable
        case conversion(String)
        case unexpectedOutputLayout
        case outputByteCount(expected: Int, actual: Int)

        var errorDescription: String? {
            switch self {
            case .sampleDataNotReady:
                return "The sample data is not ready."
            case .missingFormat:
                return "The sample has no audio stream description."
            case .unsupportedSourceFormat:
                return "The source is not a supported one- or two-channel PCM format."
            case .unsupportedSourceSampleRate(let sampleRate):
                return "The source sample rate \(sampleRate) Hz is outside the supported 8–192 kHz range."
            case .invalidTimestamp:
                return "The sample has no finite presentation timestamp."
            case .oversizedSample(let frameCount, let maximum):
                return "The sample contains \(frameCount) frames; the bounded maximum is \(maximum)."
            case .converterUnavailable:
                return "AVAudioConverter could not create the requested conversion."
            case .sourceBufferUnavailable:
                return "The CMSampleBuffer could not be represented as an AVAudioPCMBuffer."
            case .conversion(let detail):
                return detail
            case .unexpectedOutputLayout:
                return "The converted output is not one interleaved stereo buffer."
            case .outputByteCount(let expected, let actual):
                return "The converted output has \(actual) bytes; expected at least \(expected)."
            }
        }
    }

    private struct SourceFormatKey: Equatable {
        let sampleRate: Double
        let formatID: AudioFormatID
        let formatFlags: AudioFormatFlags
        let bytesPerPacket: UInt32
        let framesPerPacket: UInt32
        let bytesPerFrame: UInt32
        let channelsPerFrame: UInt32
        let bitsPerChannel: UInt32

        init(_ description: AudioStreamBasicDescription) {
            sampleRate = description.mSampleRate
            formatID = description.mFormatID
            formatFlags = description.mFormatFlags
            bytesPerPacket = description.mBytesPerPacket
            framesPerPacket = description.mFramesPerPacket
            bytesPerFrame = description.mBytesPerFrame
            channelsPerFrame = description.mChannelsPerFrame
            bitsPerChannel = description.mBitsPerChannel
        }
    }

    private let stateQueue = DispatchQueue(
        label: "peel.systemAudioCapture.state",
        qos: .userInitiated
    )
    private let chunkHandler: ChunkHandler
    private let failureHandler: FailureHandler
    private let outputFormat: AVAudioFormat

    // Access only on stateQueue.
    private var captureState: CaptureState = .idle
    private var captureGeneration: UInt64 = 0
    private var stream: SCStream?
    private var pendingStartCompletion: OperationCompletion?
    private var pendingStopCompletion: OperationCompletion?
    private var terminalFailureAfterStop: CaptureError?
    private var waitingForCancelledStartCompletion = false
    private var cancelledStartDidStop = false

    private var converter: AVAudioConverter?
    private var sourceFormatKey: SourceFormatKey?
    private var framer = PeelPCMChunkFramer()
    private var expectedNextInputTimeSeconds: Double?
    private var nextOutputSampleTime: Int64?

    private static let outputBufferFrameCapacity: AVAudioFrameCount = 2_048
    private static let maximumConversionPassesPerSample = 4
    private static let inputDiscontinuityToleranceSeconds = 0.010

    init(
        onChunk: @escaping ChunkHandler,
        onFailure: @escaping FailureHandler = { _ in }
    ) {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(Self.outputSampleRate),
            channels: AVAudioChannelCount(Self.outputChannelCount),
            interleaved: true
        ) else {
            preconditionFailure("The fixed Peel system-audio output format is invalid.")
        }

        self.outputFormat = outputFormat
        self.chunkHandler = onChunk
        self.failureHandler = onFailure
        super.init()
    }

    /// Captures all system audio in the supplied display filter, excluding audio
    /// produced by this process. No application or source-window filter is applied.
    ///
    /// The caller obtains `SCDisplay` from ScreenCaptureKit and owns permission UX
    /// and retry policy. A non-idle owner rejects the request with `busy`.
    func start(display: SCDisplay, completion: @escaping OperationCompletion) {
        stateQueue.async { [weak self] in
            self?.startOnStateQueue(display: display, completion: completion)
        }
    }

    /// Stops the current generation. Success means callbacks from that generation
    /// can no longer publish, even if ScreenCaptureKit later invokes a stale callback.
    func stop(completion: @escaping OperationCompletion = { _ in }) {
        stateQueue.async { [weak self] in
            self?.stopOnStateQueue(completion: completion)
        }
    }

    /// Returns a point-in-time state snapshot on the same serial queue as all events.
    func readState(_ handler: @escaping (CaptureState) -> Void) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            handler(self.captureState)
        }
    }

    private func startOnStateQueue(
        display: SCDisplay,
        completion: @escaping OperationCompletion
    ) {
        guard captureState == .idle else {
            completion(.failure(.busy(captureState)))
            return
        }

        captureGeneration &+= 1
        let generation = captureGeneration
        resetProcessingForNewCapture()

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = Self.outputSampleRate
        configuration.channelCount = Self.outputChannelCount
        configuration.excludesCurrentProcessAudio = true
        if #available(macOS 15.0, *) {
            configuration.captureMicrophone = false
        }

        let newStream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: self
        )

        stream = newStream
        captureState = .starting
        pendingStartCompletion = completion

        do {
            try newStream.addStreamOutput(
                self,
                type: .audio,
                sampleHandlerQueue: stateQueue
            )
        } catch {
            finishStartFailure(
                .startFailed(error),
                stream: newStream,
                generation: generation
            )
            return
        }

        newStream.startCapture { [weak self, weak newStream] error in
            guard let self, let newStream else { return }
            self.stateQueue.async { [weak self, weak newStream] in
                guard let self, let newStream else { return }
                guard self.stream === newStream else { return }

                if self.captureState == .stopping,
                   self.waitingForCancelledStartCompletion {
                    self.finishCancelledStart(
                        error: error,
                        stream: newStream
                    )
                    return
                }

                guard self.captureGeneration == generation,
                      self.captureState == .starting else { return }

                if let error {
                    self.finishStartFailure(
                        .startFailed(error),
                        stream: newStream,
                        generation: generation
                    )
                    return
                }

                self.captureState = .running
                let startCompletion = self.pendingStartCompletion
                self.pendingStartCompletion = nil
                startCompletion?(.success(()))
            }
        }
    }

    private func finishStartFailure(
        _ error: CaptureError,
        stream failedStream: SCStream,
        generation: UInt64
    ) {
        guard stream === failedStream,
              captureGeneration == generation,
              captureState == .starting else {
            return
        }

        captureGeneration &+= 1
        stream = nil
        captureState = .idle
        waitingForCancelledStartCompletion = false
        cancelledStartDidStop = false
        resetProcessingForNewCapture()

        let startCompletion = pendingStartCompletion
        pendingStartCompletion = nil
        startCompletion?(.failure(error))
    }

    private func stopOnStateQueue(completion: @escaping OperationCompletion) {
        switch captureState {
        case .idle:
            completion(.success(()))

        case .stopping:
            completion(.failure(.busy(.stopping)))

        case .starting:
            captureGeneration &+= 1
            captureState = .stopping
            pendingStopCompletion = completion
            terminalFailureAfterStop = nil
            waitingForCancelledStartCompletion = true
            cancelledStartDidStop = false
            resetProcessingForNewCapture()

            let startCompletion = pendingStartCompletion
            pendingStartCompletion = nil
            startCompletion?(.failure(.startCancelled))

        case .running, .stopFailed:
            beginStopOnStateQueue(completion: completion, terminalFailure: nil)
        }
    }

    private func finishCancelledStart(
        error: Error?,
        stream cancelledStream: SCStream
    ) {
        guard stream === cancelledStream,
              captureState == .stopping,
              waitingForCancelledStartCompletion else {
            return
        }

        waitingForCancelledStartCompletion = false
        if error != nil || cancelledStartDidStop {
            cancelledStartDidStop = false
            finishConfirmedStop()
            return
        }

        cancelledStartDidStop = false
        issueStopCapture(
            cancelledStream,
            stopGeneration: captureGeneration
        )
    }

    private func beginStopOnStateQueue(
        completion: OperationCompletion?,
        terminalFailure: CaptureError?
    ) {
        guard let currentStream = stream else {
            captureGeneration &+= 1
            captureState = .idle
            resetProcessingForNewCapture()
            if let terminalFailure {
                failureHandler(terminalFailure)
            } else {
                completion?(.success(()))
            }
            return
        }

        captureGeneration &+= 1
        let stopGeneration = captureGeneration
        captureState = .stopping
        pendingStopCompletion = completion
        terminalFailureAfterStop = terminalFailure
        waitingForCancelledStartCompletion = false
        cancelledStartDidStop = false
        resetProcessingForNewCapture()

        issueStopCapture(currentStream, stopGeneration: stopGeneration)
    }

    private func issueStopCapture(
        _ currentStream: SCStream,
        stopGeneration: UInt64
    ) {
        currentStream.stopCapture { [weak self, weak currentStream] error in
            guard let self, let currentStream else { return }
            self.stateQueue.async { [weak self, weak currentStream] in
                guard let self, let currentStream else { return }
                guard self.stream === currentStream,
                      self.captureGeneration == stopGeneration,
                      self.captureState == .stopping,
                      !self.waitingForCancelledStartCompletion else {
                    return
                }

                if let error {
                    self.recordAmbiguousStopFailure(error)
                } else {
                    self.finishConfirmedStop()
                }
            }
        }
    }

    private func recordAmbiguousStopFailure(_ stopError: Error) {
        let stopCompletion = pendingStopCompletion
        let terminalFailure = terminalFailureAfterStop
        pendingStopCompletion = nil
        terminalFailureAfterStop = nil
        captureState = .stopFailed
        waitingForCancelledStartCompletion = false
        cancelledStartDidStop = false

        if let terminalFailure {
            failureHandler(
                .captureFailureAndStopFailed(
                    captureFailure: terminalFailure.localizedDescription,
                    stopError: stopError
                )
            )
        } else {
            stopCompletion?(.failure(.stopFailed(stopError)))
        }
    }

    private func finishConfirmedStop(confirmationError: Error? = nil) {
        let stopCompletion = pendingStopCompletion
        let terminalFailure = terminalFailureAfterStop
        pendingStopCompletion = nil
        terminalFailureAfterStop = nil

        stream = nil
        captureState = .idle
        waitingForCancelledStartCompletion = false
        cancelledStartDidStop = false
        resetProcessingForNewCapture()

        if let terminalFailure {
            failureHandler(terminalFailure)
        } else if let confirmationError {
            stopCompletion?(.failure(.stopFailed(confirmationError)))
        } else {
            stopCompletion?(.success(()))
        }
    }

    private func stopForProcessingFailure(
        _ error: CaptureError,
        stream failedStream: SCStream,
        generation: UInt64
    ) {
        guard stream === failedStream,
              captureGeneration == generation,
              captureState == .running else {
            return
        }

        beginStopOnStateQueue(completion: nil, terminalFailure: error)
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio else { return }
        guard self.stream === stream, captureState == .running else { return }

        let generation = captureGeneration
        do {
            try process(sampleBuffer: sampleBuffer, stream: stream, generation: generation)
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            stopForProcessingFailure(
                .conversionFailed(detail),
                stream: stream,
                generation: generation
            )
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stateQueue.async { [weak self, weak stream] in
            guard let self, let stream else { return }
            guard self.stream === stream else { return }

            switch self.captureState {
            case .starting:
                // A delegate stop can race the original start completion too.
                // Retain this owner until both callbacks have serialized here.
                self.captureGeneration &+= 1
                self.captureState = .stopping
                self.waitingForCancelledStartCompletion = true
                self.cancelledStartDidStop = true
                self.resetProcessingForNewCapture()
                let completion = self.pendingStartCompletion
                self.pendingStartCompletion = nil
                completion?(.failure(.startFailed(error)))

            case .running:
                self.captureGeneration &+= 1
                self.stream = nil
                self.captureState = .idle
                self.resetProcessingForNewCapture()
                self.failureHandler(.streamStopped(error))

            case .stopping:
                if self.waitingForCancelledStartCompletion {
                    // Do not release a start-cancelled stream until its original
                    // startCapture completion has also serialized through stateQueue.
                    self.cancelledStartDidStop = true
                } else {
                    // The delegate confirms the stream is stopped even if the
                    // stopCapture completion has not arrived.
                    self.finishConfirmedStop(confirmationError: error)
                }

            case .stopFailed:
                // A prior stop completion was ambiguous, but this delegate callback
                // now confirms that the retained stream has stopped.
                self.finishConfirmedStop()

            case .idle:
                break
            }
        }
    }

    private func process(
        sampleBuffer: CMSampleBuffer,
        stream expectedStream: SCStream,
        generation: UInt64
    ) throws {
        guard CMSampleBufferDataIsReady(sampleBuffer) else {
            throw ProcessingError.sampleDataNotReady
        }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let descriptionPointer = CMAudioFormatDescriptionGetStreamBasicDescription(
                formatDescription
              ) else {
            throw ProcessingError.missingFormat
        }

        var description = descriptionPointer.pointee
        guard description.mFormatID == kAudioFormatLinearPCM,
              (1...2).contains(description.mChannelsPerFrame) else {
            throw ProcessingError.unsupportedSourceFormat
        }
        guard let maximumInputFrames = PeelPCMConversionBounds.maximumInputFrameCount(
            for: description.mSampleRate
        ) else {
            throw ProcessingError.unsupportedSourceSampleRate(description.mSampleRate)
        }
        guard let sourceFormat = AVAudioFormat(streamDescription: &description) else {
            throw ProcessingError.unsupportedSourceFormat
        }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0, frameCount <= maximumInputFrames else {
            throw ProcessingError.oversizedSample(
                frameCount: frameCount,
                maximum: maximumInputFrames
            )
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let presentationSeconds = CMTimeGetSeconds(presentationTime)
        guard presentationTime.isValid,
              !presentationTime.isIndefinite,
              presentationSeconds.isFinite else {
            throw ProcessingError.invalidTimestamp
        }

        let formatKey = SourceFormatKey(description)
        let hasInputDiscontinuity: Bool
        if let expectedNextInputTimeSeconds {
            hasInputDiscontinuity = abs(
                presentationSeconds - expectedNextInputTimeSeconds
            ) > Self.inputDiscontinuityToleranceSeconds
        } else {
            hasInputDiscontinuity = false
        }

        if sourceFormatKey != formatKey {
            guard let newConverter = AVAudioConverter(
                from: sourceFormat,
                to: outputFormat
            ) else {
                throw ProcessingError.converterUnavailable
            }
            converter = newConverter
            sourceFormatKey = formatKey
            resetTimeline(at: presentationTime)
        } else if hasInputDiscontinuity {
            converter?.reset()
            resetTimeline(at: presentationTime)
        } else if nextOutputSampleTime == nil {
            resetTimeline(at: presentationTime)
        }

        expectedNextInputTimeSeconds = presentationSeconds
            + (Double(frameCount) / description.mSampleRate)

        try sampleBuffer.withAudioBufferList { audioBufferList, _ in
            guard let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                bufferListNoCopy: audioBufferList.unsafePointer
            ), inputBuffer.frameCapacity >= AVAudioFrameCount(frameCount) else {
                throw ProcessingError.sourceBufferUnavailable
            }

            inputBuffer.frameLength = AVAudioFrameCount(frameCount)
            try convert(
                inputBuffer: inputBuffer,
                stream: expectedStream,
                generation: generation
            )
        }
    }

    private func convert(
        inputBuffer: AVAudioPCMBuffer,
        stream expectedStream: SCStream,
        generation: UInt64
    ) throws {
        guard let converter else {
            throw ProcessingError.converterUnavailable
        }

        var didProvideInput = false
        var passCount = 0

        while passCount < Self.maximumConversionPassesPerSample {
            guard self.stream === expectedStream,
                  captureGeneration == generation,
                  captureState == .running else {
                return
            }
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: Self.outputBufferFrameCapacity
            ) else {
                throw ProcessingError.converterUnavailable
            }

            var conversionError: NSError?
            let status = converter.convert(
                to: outputBuffer,
                error: &conversionError
            ) { _, inputStatus in
                if !didProvideInput {
                    didProvideInput = true
                    inputStatus.pointee = .haveData
                    return inputBuffer
                }

                inputStatus.pointee = .noDataNow
                return nil
            }
            passCount += 1

            if let conversionError {
                throw ProcessingError.conversion(conversionError.localizedDescription)
            }
            if status == .error {
                throw ProcessingError.conversion("AVAudioConverter returned an error.")
            }

            if outputBuffer.frameLength > 0 {
                let shouldContinue = try consume(
                    outputBuffer: outputBuffer,
                    stream: expectedStream,
                    generation: generation
                )
                if !shouldContinue {
                    return
                }
            }

            switch status {
            case .haveData:
                guard outputBuffer.frameLength > 0 else {
                    throw ProcessingError.conversion(
                        "AVAudioConverter made no progress."
                    )
                }
                continue
            case .inputRanDry, .endOfStream:
                return
            case .error:
                throw ProcessingError.conversion("AVAudioConverter returned an error.")
            @unknown default:
                throw ProcessingError.conversion(
                    "AVAudioConverter returned an unknown status."
                )
            }
        }

        throw ProcessingError.conversion(
            "AVAudioConverter exceeded the bounded pass count."
        )
    }

    private func consume(
        outputBuffer: AVAudioPCMBuffer,
        stream expectedStream: SCStream,
        generation: UInt64
    ) throws -> Bool {
        let frameCount = Int(outputBuffer.frameLength)
        guard frameCount <= PeelPCMChunkFramer.maxInputFramesPerAppend else {
            throw PeelPCMChunkFramer.FramingError.tooManyFrames(frameCount)
        }

        let audioBufferList = outputBuffer.audioBufferList.pointee
        guard audioBufferList.mNumberBuffers == 1,
              let bytes = audioBufferList.mBuffers.mData else {
            throw ProcessingError.unexpectedOutputLayout
        }

        let expectedByteCount = frameCount * PeelPCMChunkFramer.bytesPerFrame
        let actualByteCount = Int(audioBufferList.mBuffers.mDataByteSize)
        guard actualByteCount >= expectedByteCount else {
            throw ProcessingError.outputByteCount(
                expected: expectedByteCount,
                actual: actualByteCount
            )
        }
        guard let startSampleTime = nextOutputSampleTime else {
            throw ProcessingError.invalidTimestamp
        }

        let pcmData = Data(bytes: bytes, count: expectedByteCount)
        let framedChunks = try framer.append(
            interleavedStereoS16LE: pcmData,
            startSampleTime: startSampleTime
        )

        let (nextSampleTime, overflow) = startSampleTime.addingReportingOverflow(
            Int64(frameCount)
        )
        guard !overflow else {
            throw PeelPCMChunkFramer.FramingError.sampleTimeOverflow
        }
        nextOutputSampleTime = nextSampleTime

        for framedChunk in framedChunks {
            guard stream === expectedStream,
                  captureGeneration == generation,
                  captureState == .running else {
                return false
            }

            let chunk = PCMChunk(
                sequenceNumber: framedChunk.sequenceNumber,
                presentationTime: CMTime(
                    value: framedChunk.startSampleTime,
                    timescale: CMTimeScale(Self.outputSampleRate)
                ),
                frameCount: Self.outputFramesPerChunk,
                sampleRate: Self.outputSampleRate,
                channelCount: Self.outputChannelCount,
                interleavedStereoS16LE: framedChunk.pcmData
            )

            switch chunkHandler(chunk) {
            case .accepted:
                continue
            case .backpressured:
                discardAfterBackpressure()
                return false
            case .stopCapture:
                framer.discardBufferedAudio()
                stopForProcessingFailure(
                    .downstreamRequestedStop,
                    stream: expectedStream,
                    generation: generation
                )
                return false
            }
        }

        return true
    }

    private func discardAfterBackpressure() {
        // Drop AVAudioConverter's unconsumed source/internal resampling state, every
        // complete-but-unoffered frame still local to this callback, and the framer's
        // sub-chunk remainder. Clearing both time anchors makes the next source
        // sample's presentation timestamp authoritative.
        converter?.reset()
        framer.discardBufferedAudio()
        expectedNextInputTimeSeconds = nil
        nextOutputSampleTime = nil
    }

    private func resetTimeline(at presentationTime: CMTime) {
        framer.discardBufferedAudio()
        let scaledTime = CMTimeConvertScale(
            presentationTime,
            timescale: CMTimeScale(Self.outputSampleRate),
            method: .default
        )
        nextOutputSampleTime = scaledTime.isValid ? scaledTime.value : nil
    }

    private func resetProcessingForNewCapture() {
        converter = nil
        sourceFormatKey = nil
        expectedNextInputTimeSeconds = nil
        nextOutputSampleTime = nil
        framer.resetForNewCapture()
    }
}
