#if os(iOS) || os(visionOS)

import AVFoundation
import Foundation

nonisolated public enum PeelAudioPlaybackFailure: Error, Equatable, Sendable, LocalizedError {
    case interrupted
    case routeLost
    case formatUnavailable
    case bufferCreationFailed
    case audioSessionDeactivationFailed
    case timelineDiscontinuity

    public var errorDescription: String? {
        switch self {
        case .interrupted:
            return "The Apple audio session was interrupted; playback stopped."
        case .routeLost:
            return "The Apple audio output route was lost; playback stopped."
        case .formatUnavailable:
            return "The Apple client could not create the required 48 kHz stereo Float32 format."
        case .bufferCreationFailed:
            return "The Apple client could not create a bounded playback buffer."
        case .timelineDiscontinuity:
            return "The computer audio timeline changed; this audio request must end."
        case .audioSessionDeactivationFailed:
            return "The Apple audio session could not be deactivated cleanly."
        }
    }
}

/// Owns one explicitly started Apple playback engine for one authenticated
/// caller session. The caller supplies already decoded `PeelAudioPacket`s.
@MainActor
public final class PeelAudioPlaybackOwner {
    public var onFailure: ((PeelAudioPlaybackFailure) -> Void)?

    public private(set) var isStarted = false
    public private(set) var activeSessionID: UUID?

    private let audioSession = AVAudioSession.sharedInstance()
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let observers = PeelAudioPlaybackObserverBag()

    private var playbackFormat: AVAudioFormat?
    private var isAttached = false
    private var playbackGeneration = UUID()
    private var scheduledChunkCount = 0
    private var schedulingState = PeelAudioPlaybackSchedulingState()

    public init(onFailure: ((PeelAudioPlaybackFailure) -> Void)? = nil) {
        self.onFailure = onFailure
    }

    /// Configures and activates playback. Audio session activation is delayed
    /// until this method; initialization performs no audio-session work.
    public func start(sessionID: UUID) throws {
        if isStarted, activeSessionID == sessionID {
            return
        }
        if isStarted || isAttached || activeSessionID != nil {
            tearDown(reportDeactivationFailure: false)
        }

        playbackGeneration = UUID()
        schedulingState.reset()
        scheduledChunkCount = 0
        activeSessionID = sessionID

        do {
            try audioSession.setCategory(.playback,
                                          mode: .default,
                                          options: [.mixWithOthers])
            try audioSession.setActive(true)

            guard let format = AVAudioFormat(
                standardFormatWithSampleRate: Double(PeelAudioPlaybackPCM.sampleRate),
                channels: AVAudioChannelCount(PeelAudioPacketDirection.macToClient.expectedChannelCount)
            ) else {
                throw PeelAudioPlaybackFailure.formatUnavailable
            }
            playbackFormat = format

            engine.attach(playerNode)
            isAttached = true
            engine.connect(playerNode, to: engine.mainMixerNode, format: format)
            engine.prepare()
            try engine.start()
            playerNode.play()
            isStarted = true
            installObservers()
        } catch {
            tearDown(reportDeactivationFailure: false)
            throw error
        }
    }

    /// Stops only the current session when an ID is supplied. A stale caller
    /// cannot stop a replacement session.
    public func stop(sessionID: UUID? = nil) {
        guard let activeSessionID else {
            if sessionID == nil, isStarted || isAttached {
                tearDown(reportDeactivationFailure: true)
            }
            return
        }
        guard sessionID == nil || sessionID == activeSessionID else {
            return
        }
        tearDown(reportDeactivationFailure: true)
    }

    /// Accepts a format packet as stream metadata and schedules bounded PCM
    /// packets. `false` means the packet was rejected or dropped; no readiness
    /// callback is inferred from that Boolean.
    @discardableResult
    public func enqueue(_ packet: PeelAudioPacket, sessionID: UUID) -> Bool {
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

        let decision = schedulingState.decision(for: packet,
                                                scheduledChunkCount: scheduledChunkCount)
        // Sequence/time admission is unchanged. These decisions cannot recover
        // on this stream's committed baseline; bounded pressure/old packets can.
        switch decision {
        case .timelineMismatch, .gapTooLarge, .arithmeticOverflow:
            fail(.timelineDiscontinuity)
            return false
        default:
            break
        }
        guard case let .accepted(_, _, silenceChunks) = decision else {
            return false
        }
        guard let format = playbackFormat else {
            return false
        }

        let pcmChannels: PeelAudioPlaybackFloatStereo
        do {
            // The helper walks the Data collection rather than assuming its
            // start index is zero. The packet has already validated this size.
            pcmChannels = try PeelAudioPlaybackPCM.decodeStereoS16LEToFloatChannels(
                packet.payload,
                frameCount: Int(packet.frameCount)
            )
        } catch {
            return false
        }

        var buffers: [AVAudioPCMBuffer] = []
        do {
            buffers.reserveCapacity(silenceChunks + 1)
            for _ in 0..<silenceChunks {
                buffers.append(try makeBuffer(stereo: zeroPCMChannels(),
                                              frameCount: PeelAudioPlaybackSchedulingState.chunkFrameCount,
                                              format: format))
            }
            buffers.append(try makeBuffer(stereo: pcmChannels,
                                          frameCount: Int(packet.frameCount),
                                          format: format))
        } catch {
            fail(.bufferCreationFailed)
            return false
        }

        let callbackGeneration = playbackGeneration
        for buffer in buffers {
            playerNode.scheduleBuffer(buffer,
                                       completionCallbackType: .dataPlayedBack) { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.playbackGeneration == callbackGeneration,
                          self.scheduledChunkCount > 0
                    else {
                        return
                    }
                    self.scheduledChunkCount -= 1
                }
            }
        }
        scheduledChunkCount += buffers.count
        schedulingState.commit(packet, after: decision)
        return true
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
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                             frameCapacity: AVAudioFrameCount(frameCount))
        else {
            throw PeelAudioPlaybackFailure.bufferCreationFailed
        }

        // Set the valid frame length before copying so floatChannelData
        // exposes exactly the bounded number of writable samples.
        buffer.frameLength = AVAudioFrameCount(frameCount)
        guard let channelData = buffer.floatChannelData
        else {
            throw PeelAudioPlaybackFailure.bufferCreationFailed
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
        let observerGeneration = playbackGeneration
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] notification in
            let rawType = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            DispatchQueue.main.async { [weak self] in
                // Notification delivery can outlive observer removal and a restart.
                guard let self, self.playbackGeneration == observerGeneration else { return }
                self.handleInterruption(rawType: rawType)
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] notification in
            let rawReason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
            DispatchQueue.main.async { [weak self] in
                // Notification delivery can outlive observer removal and a restart.
                guard let self, self.playbackGeneration == observerGeneration else { return }
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
        tearDown(reportDeactivationFailure: true)
        onFailure?(.interrupted)
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
            tearDown(reportDeactivationFailure: true)
            onFailure?(.routeLost)
        default:
            break
        }
    }

    private func fail(_ failure: PeelAudioPlaybackFailure) {
        tearDown(reportDeactivationFailure: true)
        onFailure?(failure)
    }

    private func tearDown(reportDeactivationFailure: Bool) {
        playbackGeneration = UUID()
        observers.removeAll()
        isStarted = false
        activeSessionID = nil
        playerNode.stop()
        engine.stop()
        engine.reset()
        if isAttached {
            engine.detach(playerNode)
            isAttached = false
        }
        playbackFormat = nil
        scheduledChunkCount = 0
        schedulingState.reset()

        do {
            try audioSession.setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            if reportDeactivationFailure {
                onFailure?(.audioSessionDeactivationFailed)
            }
        }
    }
}

private final class PeelAudioPlaybackObserverBag: @unchecked Sendable {
    private var tokens: [NSObjectProtocol] = []

    func append(_ token: NSObjectProtocol) {
        tokens.append(token)
    }

    func removeAll() {
        let center = NotificationCenter.default
        for token in tokens {
            center.removeObserver(token)
        }
        tokens.removeAll(keepingCapacity: false)
    }

    deinit {
        let center = NotificationCenter.default
        for token in tokens {
            center.removeObserver(token)
        }
    }
}

#endif
