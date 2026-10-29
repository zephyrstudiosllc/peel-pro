#if os(iOS) || os(visionOS)

import AVFoundation
import Foundation

nonisolated public enum PeelVoiceAudioFailure: Error, Equatable, Sendable, LocalizedError {
    case interrupted
    case routeLost
    case inputOverrun
    case conversionFailed
    case packetSinkRejected
    case inputFormatUnavailable
    case voiceProcessingUnavailable
    case playbackFormatUnavailable
    case bufferCreationFailed
    case audioSessionDeactivationFailed
    case timelineDiscontinuity

    public var errorDescription: String? {
        switch self {
        case .interrupted:
            return "The Apple voice session was interrupted; capture and playback stopped."
        case .routeLost:
            return "The Apple voice route was lost; capture and playback stopped."
        case .inputOverrun:
            return "The bounded Apple voice input handoff dropped an input buffer."
        case .conversionFailed:
            return "The Apple voice input could not be converted to the wire format."
        case .packetSinkRejected:
            return "A bounded voice uplink offer was dropped; capture continues."
        case .inputFormatUnavailable:
            return "The Apple voice input format is unavailable or outside the bounded range."
        case .voiceProcessingUnavailable:
            return "The Apple voice processing input/output mode could not be enabled."
        case .playbackFormatUnavailable:
            return "The Apple client could not create the required 48 kHz stereo Float32 playback format."
        case .bufferCreationFailed:
            return "The Apple client could not create a bounded voice playback buffer."
        case .timelineDiscontinuity:
            return "The computer audio timeline changed; this audio request must end."
        case .audioSessionDeactivationFailed:
            return "The Apple voice audio session could not be deactivated cleanly."
        }
    }
}

/// Owns one full-duplex Apple voice graph. Capture and downlink playback share
/// this engine, session, route policy, generation, and teardown boundary.
@MainActor
public final class PeelVoiceAudioOwner {
    public typealias UplinkSink = @Sendable (PeelAudioPacket) -> Bool
    public typealias FailureSink = @MainActor @Sendable (PeelVoiceAudioFailure) -> Void

    public private(set) var isStarted = false
    public private(set) var activeSessionID: UUID?

    private static let preferredSampleRate = 48_000.0
    private static let preferredIOBufferDuration = 0.010

    private let audioSession = AVAudioSession.sharedInstance()
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let generationGate = PeelVoiceAudioGenerationGate()
    private let observers = PeelVoiceAudioObserverBag()

    private var generation = UUID()
    private var inputNode: AVAudioInputNode?
    private var tapInstalled = false
    private var captureWorker: PeelVoiceAudioCaptureDrainWorker?
    private var playbackFormat: AVAudioFormat?
    private var isPlayerAttached = false
    private var scheduledChunkCount = 0
    private var schedulingState = PeelAudioPlaybackSchedulingState()
    private var failureSink: FailureSink?

    public init() {}

    /// Requests microphone permission explicitly. Initialization and `start`
    /// never prompt and never activate the audio session.
    @available(iOS 17.0, visionOS 26.0, *)
    public static func requestRecordPermission(
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }

    /// Checks current OS permission without prompting during a bounded restart.
    @available(iOS 17.0, visionOS 26.0, *)
    public static var hasRecordPermission: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    /// Starts one voice-processing full-duplex engine. Permission must be
    /// requested separately before this method is called.
    public func start(
        sessionID: UUID,
        onUplink: @escaping UplinkSink,
        onFailure: FailureSink? = nil
    ) throws {
        if isStarted, activeSessionID == sessionID {
            return
        }
        if isStarted || captureWorker != nil || activeSessionID != nil ||
            tapInstalled || isPlayerAttached {
            tearDown(reportDeactivationFailure: false)
        }

        generation = UUID()
        generationGate.activate(generation)
        activeSessionID = sessionID
        failureSink = onFailure

        do {
            try audioSession.setCategory(.playAndRecord,
                                          mode: .voiceChat,
                                          options: [.defaultToSpeaker, .allowBluetoothHFP])
            try audioSession.setPreferredSampleRate(Self.preferredSampleRate)
            try audioSession.setPreferredIOBufferDuration(Self.preferredIOBufferDuration)
            try audioSession.setActive(true)

            let node = engine.inputNode
            do {
                // AVAudioIONode documents that enabling this on input also
                // enables output voice processing for the shared engine.
                try node.setVoiceProcessingEnabled(true)
            } catch {
                throw PeelVoiceAudioFailure.voiceProcessingUnavailable
            }

            let inputFormat = node.outputFormat(forBus: 0)
            guard inputFormat.sampleRate.isFinite,
                  inputFormat.sampleRate >= PeelAudioMicrophoneResampler.minimumSourceSampleRate,
                  inputFormat.sampleRate <= PeelAudioMicrophoneResampler.maximumSourceSampleRate,
                  inputFormat.channelCount > 0,
                  inputFormat.channelCount <= AVAudioChannelCount(PeelVoiceAudioInputRing.maxInputChannels)
            else {
                throw PeelVoiceAudioFailure.inputFormatUnavailable
            }

            guard let playbackFormat = AVAudioFormat(
                standardFormatWithSampleRate: Self.preferredSampleRate,
                channels: AVAudioChannelCount(PeelAudioPlaybackPCM.channelCount)
            ) else {
                throw PeelVoiceAudioFailure.playbackFormatUnavailable
            }
            self.playbackFormat = playbackFormat

            let gate = generationGate
            let currentGeneration = generation
            let workerFailure: PeelVoiceAudioFailureSink?
            if let onFailure {
                workerFailure = { failure in
                    DispatchQueue.main.async {
                        guard gate.isCurrent(currentGeneration) else { return }
                        onFailure(failure)
                    }
                }
            } else {
                workerFailure = nil
            }

            let ring = PeelVoiceAudioInputRing()
            captureWorker = PeelVoiceAudioCaptureDrainWorker(
                ring: ring,
                sourceSampleRate: inputFormat.sampleRate,
                generation: currentGeneration,
                gate: gate,
                onUplink: onUplink,
                onFailure: workerFailure
            )
            inputNode = node

            node.installTap(onBus: 0,
                            bufferSize: AVAudioFrameCount(PeelVoiceAudioInputRing.tapBufferFrames),
                            format: inputFormat) { [weak ring] buffer, _ in
                ring?.push(buffer)
            }
            tapInstalled = true

            engine.attach(playerNode)
            isPlayerAttached = true
            engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)
            engine.prepare()
            try engine.start()
            playerNode.play()
            isStarted = true
            installObservers()
            captureWorker?.start()
        } catch {
            tearDown(reportDeactivationFailure: false)
            throw error
        }
    }

    /// Schedules an authenticated caller's stereo downlink packet on the
    /// shared player node. The queue is capped at six 20 ms chunks.
    @discardableResult
    public func enqueueDownlink(
        _ packet: PeelAudioPacket,
        sessionID: UUID
    ) -> Bool {
        guard isStarted, activeSessionID == sessionID else {
            return false
        }
        guard packet.direction == .macToClient,
              packet.format == .v1(for: .macToClient)
        else {
            return false
        }
        if packet.kind == .format {
            return true
        }

        let decision = schedulingState.decision(
            for: packet,
            scheduledChunkCount: scheduledChunkCount
        )
        // Sequence/time admission is unchanged. These decisions cannot recover
        // on this stream's committed baseline; bounded pressure/old packets can.
        switch decision {
        case .timelineMismatch, .gapTooLarge, .arithmeticOverflow:
            fail(.timelineDiscontinuity)
            return false
        default:
            break
        }
        guard case let .accepted(_, _, silenceChunks) = decision,
              let format = playbackFormat
        else {
            return false
        }

        let stereo: PeelAudioPlaybackFloatStereo
        do {
            // The pure helper validates the exact byte count and iterates the
            // collection, so a sliced Data value with a non-zero start index
            // cannot shift channel decoding.
            stereo = try PeelAudioPlaybackPCM.decodeStereoS16LEToFloatChannels(
                packet.payload,
                frameCount: Int(packet.frameCount)
            )
        } catch {
            return false
        }

        var buffers: [AVAudioPCMBuffer] = []
        buffers.reserveCapacity(silenceChunks + 1)
        do {
            for _ in 0..<silenceChunks {
                buffers.append(try makeBuffer(
                    stereo: zeroPCMChannels(),
                    frameCount: PeelAudioPlaybackSchedulingState.chunkFrameCount,
                    format: format
                ))
            }
            buffers.append(try makeBuffer(
                stereo: stereo,
                frameCount: Int(packet.frameCount),
                format: format
            ))
        } catch {
            fail(.bufferCreationFailed)
            return false
        }

        let (newScheduledCount, countOverflow) =
            scheduledChunkCount.addingReportingOverflow(buffers.count)
        guard !countOverflow,
              newScheduledCount <= PeelAudioPlaybackSchedulingState.maxScheduledChunks
        else {
            return false
        }

        let callbackGeneration = generation
        for buffer in buffers {
            playerNode.scheduleBuffer(buffer,
                                       completionCallbackType: .dataPlayedBack) { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.generation == callbackGeneration,
                          self.scheduledChunkCount > 0
                    else {
                        return
                    }
                    self.scheduledChunkCount -= 1
                }
            }
        }
        scheduledChunkCount = newScheduledCount
        schedulingState.commit(packet, after: decision)
        return true
    }

    /// Stops only the active session when an ID is supplied. A stale caller
    /// cannot stop a replacement generation.
    public func stop(sessionID: UUID? = nil) {
        guard let activeSessionID else {
            if sessionID == nil,
               isStarted || captureWorker != nil || tapInstalled || isPlayerAttached {
                tearDown(reportDeactivationFailure: true)
            }
            return
        }
        guard sessionID == nil || sessionID == activeSessionID else {
            return
        }
        tearDown(reportDeactivationFailure: true)
    }

    private func zeroPCMChannels() -> PeelAudioPlaybackFloatStereo {
        let zeros = [Float](repeating: 0,
                            count: PeelAudioPlaybackSchedulingState.chunkFrameCount)
        return PeelAudioPlaybackFloatStereo(left: zeros, right: zeros)
    }

    private func makeBuffer(
        stereo: PeelAudioPlaybackFloatStereo,
        frameCount: Int,
        format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        guard frameCount > 0,
              frameCount <= PeelAudioPlaybackPCM.maxFrameCount,
              stereo.left.count == frameCount,
              stereo.right.count == frameCount,
              format.channelCount == AVAudioChannelCount(PeelAudioPlaybackPCM.channelCount),
              !format.isInterleaved,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
            )
        else {
            throw PeelVoiceAudioFailure.bufferCreationFailed
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        guard let channelData = buffer.floatChannelData else {
            throw PeelVoiceAudioFailure.bufferCreationFailed
        }
        stereo.left.withUnsafeBufferPointer { source in
            guard let sourceBaseAddress = source.baseAddress else { return }
            channelData[0].update(from: sourceBaseAddress, count: frameCount)
        }
        stereo.right.withUnsafeBufferPointer { source in
            guard let sourceBaseAddress = source.baseAddress else { return }
            channelData[1].update(from: sourceBaseAddress, count: frameCount)
        }
        return buffer
    }

    private func installObservers() {
        let center = NotificationCenter.default
        let observerGeneration = generation
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] notification in
            let rawType =
                (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            DispatchQueue.main.async { [weak self] in
                // Notification delivery can outlive observer removal and a restart.
                guard let self, self.generation == observerGeneration else { return }
                self.handleInterruption(rawType: rawType)
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] notification in
            let rawReason =
                (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
            DispatchQueue.main.async { [weak self] in
                // Notification delivery can outlive observer removal and a restart.
                guard let self, self.generation == observerGeneration else { return }
                self.handleRouteChange(rawReason: rawReason)
            }
        })
    }

    private func handleInterruption(rawType: UInt?) {
        guard isStarted,
              let rawType,
              let type = AVAudioSession.InterruptionType(rawValue: rawType),
              type == .began
        else {
            return
        }
        let callback = failureSink
        tearDown(reportDeactivationFailure: false)
        callback?(.interrupted)
    }

    private func handleRouteChange(rawReason: UInt?) {
        guard isStarted,
              let rawReason,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
        else {
            return
        }

        switch reason {
        case .oldDeviceUnavailable, .noSuitableRouteForCategory:
            let callback = failureSink
            tearDown(reportDeactivationFailure: false)
            callback?(.routeLost)
        default:
            break
        }
    }

    private func fail(_ failure: PeelVoiceAudioFailure) {
        let callback = failureSink
        tearDown(reportDeactivationFailure: true)
        callback?(failure)
    }

    private func tearDown(reportDeactivationFailure: Bool) {
        let callback = failureSink
        generationGate.invalidate(generation)
        generation = UUID()
        observers.removeAll()

        captureWorker?.stop()
        captureWorker = nil
        if tapInstalled {
            inputNode?.removeTap(onBus: 0)
            tapInstalled = false
        }
        inputNode = nil

        playerNode.stop()
        engine.stop()
        engine.reset()
        if isPlayerAttached {
            engine.detach(playerNode)
            isPlayerAttached = false
        }

        isStarted = false
        activeSessionID = nil
        playbackFormat = nil
        scheduledChunkCount = 0
        schedulingState.reset()
        failureSink = nil

        do {
            try audioSession.setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            if reportDeactivationFailure {
                callback?(.audioSessionDeactivationFailed)
            }
        }
    }
}

#endif
