import AVFoundation
import Foundation

nonisolated enum PeelRemoteMacAudioPlaybackFailure: Error, Equatable, Sendable {
    case formatUnavailable
    case engineStartFailed
    case bufferCreationFailed
    case outputConfigurationLost
    case timelineDiscontinuity

    var message: String {
        switch self {
        case .formatUnavailable: return "This Mac could not create the 48 kHz stereo audio format."
        case .engineStartFailed: return "This Mac's audio output could not start."
        case .bufferCreationFailed: return "This Mac could not create a bounded audio buffer."
        case .outputConfigurationLost: return "This Mac's audio output changed; turn audio on to retry."
        case .timelineDiscontinuity: return "The computer audio timeline changed."
        }
    }
}

/// Owns one AVAudioEngine/AVAudioPlayerNode for one authenticated audio
/// request. macOS has no AVAudioSession; the engine renders to the current
/// default output and is created only when the Host's format packet arrives.
/// It never changes the receiver's system volume or output device.
@MainActor
final class PeelRemoteMacAudioPlaybackOwner {
    var onFailure: ((PeelRemoteMacAudioPlaybackFailure) -> Void)?

    private(set) var isStarted = false
    private(set) var activeSessionID: UUID?

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var configurationObserver: NSObjectProtocol?
    /// Changes on every teardown/rebuild so late buffer completions and
    /// notifications from an older graph cannot touch current counts.
    private var bufferGeneration = UUID()
    private var observerGeneration = UUID()
    private var scheduledChunkCount = 0
    private var scheduling = PeelRemoteMacAudioSchedulingState()
    /// Counts and codes for the current/last session; reset only on start,
    /// so they survive a teardown for the controller's diagnostics.
    private(set) var timelineCounters = PeelRemoteMacAudioTimelineCounters()
    /// Uptimes of recent rebuilds; more than 4 within 10 s is a failure.
    private var recentRebuilds: [UInt64] = []
    private static let maximumRebuildsPerWindow = 4
    private static let rebuildWindowNanoseconds: UInt64 = 10_000_000_000

    /// True only while the engine is running and the player is playing.
    var isRendering: Bool { isStarted && engine?.isRunning == true && player?.isPlaying == true }

    func start(sessionID: UUID) throws {
        if isStarted, activeSessionID == sessionID { return }
        tearDown()
        timelineCounters = PeelRemoteMacAudioTimelineCounters()
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: Double(PeelAudioPacket.sampleRate),
            channels: AVAudioChannelCount(PeelRemoteMacAudioPCM.channelCount)),
              format.channelCount == 2, !format.isInterleaved else {
            throw PeelRemoteMacAudioPlaybackFailure.formatUnavailable
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.detach(player)
            throw PeelRemoteMacAudioPlaybackFailure.engineStartFailed
        }
        player.play()
        self.engine = engine
        self.player = player
        self.format = format
        activeSessionID = sessionID
        isStarted = true
        bufferGeneration = UUID()
        observerGeneration = UUID()
        installConfigurationObserver(engine: engine)
    }

    /// A stale caller cannot stop a replacement session.
    func stop(sessionID: UUID? = nil) {
        guard sessionID == nil || sessionID == activeSessionID else { return }
        tearDown()
    }

    /// Format packets are metadata. PCM is admitted by the bounded timeline
    /// state, converted and scheduled. False means rejected or dropped.
    @discardableResult
    func enqueue(_ packet: PeelAudioPacket, sessionID: UUID) -> Bool {
        guard isStarted, activeSessionID == sessionID,
              packet.direction == .macToClient, packet.format == .v1(for: .macToClient) else { return false }
        if packet.kind == .format { return true }
        guard isRendering, let player, let format else {
            timelineCounters.notRenderingDrops = PeelRemoteMacAudioTimelineCounters.bump(timelineCounters.notRenderingDrops)
            return false
        }

        let decision = scheduling.decision(for: packet, scheduledChunkCount: scheduledChunkCount)
        timelineCounters.record(decision)
        if decision.isTimelineDiscontinuity {
            fail(.timelineDiscontinuity)
            return false
        }
        let silenceChunks: Int
        switch decision {
        case let .accepted(_, _, silence):
            silenceChunks = silence
        case .resync:
            silenceChunks = 0
        case .queueFull:
            // Intentional local drop: the packet is timeline-valid, so it is
            // consumed and the next contiguous packet is not a false gap.
            scheduling.commit(packet, after: decision)
            return false
        default:
            return false
        }
        guard let pcm = PeelRemoteMacAudioPCM.floatChannels(packet.payload, frameCount: Int(packet.frameCount)) else {
            return false
        }

        var buffers: [AVAudioPCMBuffer] = []
        buffers.reserveCapacity(silenceChunks + 1)
        for _ in 0..<silenceChunks {
            guard let silence = makeBuffer(left: nil, right: nil, format: format) else {
                fail(.bufferCreationFailed); return false
            }
            buffers.append(silence)
        }
        guard let buffer = makeBuffer(left: pcm.left, right: pcm.right, format: format) else {
            fail(.bufferCreationFailed); return false
        }
        buffers.append(buffer)

        let generation = bufferGeneration
        for buffer in buffers {
            // Count the player's own queue (rendered), not output-device
            // latency (played back), against the 6-buffer bound.
            player.scheduleBuffer(buffer, completionCallbackType: .dataRendered,
                                  completionHandler: Self.completion(owner: self, generation: generation))
        }
        scheduledChunkCount += buffers.count
        scheduling.commit(packet, after: decision)
        return true
    }

    /// Built outside main-actor isolation: AVFAudio calls it on its own thread.
    nonisolated private static func completion(owner: PeelRemoteMacAudioPlaybackOwner,
                                               generation: UUID) -> AVAudioPlayerNodeCompletionHandler {
        { [weak owner] _ in
            DispatchQueue.main.async { [weak owner] in
                owner?.bufferPlayedBack(generation: generation)
            }
        }
    }

    private func bufferPlayedBack(generation: UUID) {
        guard bufferGeneration == generation, scheduledChunkCount > 0 else { return }
        scheduledChunkCount -= 1
    }

    /// `nil` channels produce one silent chunk.
    private func makeBuffer(left: [Float]?, right: [Float]?, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = PeelRemoteMacAudioSchedulingState.chunkFrameCount
        guard left.map({ $0.count == frames }) ?? true, right.map({ $0.count == frames }) ?? true,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard let channels = buffer.floatChannelData else { return nil }
        for (index, samples) in [left, right].enumerated() {
            if let samples {
                samples.withUnsafeBufferPointer { source in
                    guard let base = source.baseAddress else { return }
                    channels[index].update(from: base, count: frames)
                }
            } else {
                channels[index].update(repeating: 0, count: frames)
            }
        }
        return buffer
    }

    private func installConfigurationObserver(engine: AVAudioEngine) {
        let generation = observerGeneration
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.observerGeneration == generation else { return }
                self.rebuildAfterConfigurationChange()
            }
        }
    }

    /// An output device/format change stops the engine and discards its
    /// scheduled buffers. Rebuild the same graph a bounded number of times;
    /// the next PCM packet becomes a fresh baseline. Never retargets the
    /// receiver's output device or volume.
    private func rebuildAfterConfigurationChange() {
        guard isStarted, let engine, let player, let format else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        recentRebuilds.removeAll { now < $0 || now - $0 >= Self.rebuildWindowNanoseconds }
        recentRebuilds.append(now)
        timelineCounters.outputRebuilds = PeelRemoteMacAudioTimelineCounters.bump(timelineCounters.outputRebuilds)
        guard recentRebuilds.count <= Self.maximumRebuildsPerWindow else {
            fail(.outputConfigurationLost); return
        }
        bufferGeneration = UUID()
        scheduledChunkCount = 0
        scheduling.reset()
        player.stop()
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            fail(.outputConfigurationLost); return
        }
        player.play()
    }

    private func fail(_ failure: PeelRemoteMacAudioPlaybackFailure) {
        tearDown()
        onFailure?(failure)
    }

    private func tearDown() {
        bufferGeneration = UUID()
        observerGeneration = UUID()
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        isStarted = false
        activeSessionID = nil
        player?.stop()
        engine?.stop()
        if let engine, let player { engine.detach(player) }
        engine = nil
        player = nil
        format = nil
        scheduledChunkCount = 0
        scheduling.reset()
        recentRebuilds.removeAll()
    }
}
