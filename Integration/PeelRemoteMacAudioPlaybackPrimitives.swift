import Foundation

/// Pure, allocation-bounded pieces of the Mac receiver's computer-audio
/// playback. They mirror the Apple client's v1 downlink semantics
/// (PeelAudioPlaybackPrimitives.swift) so both receivers admit the same
/// sequence/timeline, without depending on the Apple component's sources.

/// Bounded scheduling result for one 20 ms Mac-to-client PCM packet.
nonisolated enum PeelRemoteMacAudioScheduleDecision: Equatable, Sendable {
    /// Exactly contiguous (after up to 2 missing chunks); `silenceChunks`
    /// is 0 when the schedule has no room for synthesized silence.
    case accepted(sequence: UInt64, sampleTime: Int64, silenceChunks: Int)
    /// Bounded forward re-anchor. The source re-anchors sampleTime to its
    /// next capture timestamp after its own backpressure drops or capture
    /// input gaps, while sequence numbers of dropped chunks stay consumed.
    /// Becomes the new baseline; no silence is synthesized and no restart.
    case resync(sequence: UInt64, sampleTime: Int64)
    case duplicate
    case oldFrame
    case gapTooLarge
    /// Timeline-valid packet dropped only because this receiver's schedule
    /// is full. Commit it as consumed so intentional local drops never look
    /// like a source gap.
    case queueFull
    case invalidPacket
    case timelineMismatch
    case arithmeticOverflow

    /// The stream's committed baseline can no longer be trusted; the request
    /// ends (with at most one bounded restart owned by the controller).
    var isTimelineDiscontinuity: Bool {
        switch self {
        case .timelineMismatch, .gapTooLarge, .arithmeticOverflow: return true
        default: return false
        }
    }

    /// Sanitized code for diagnostics (no packet contents).
    var code: String {
        switch self {
        case .accepted: return "accepted"
        case .resync: return "resync"
        case .duplicate: return "duplicate"
        case .oldFrame: return "oldFrame"
        case .gapTooLarge: return "gapTooLarge"
        case .queueFull: return "queueFull"
        case .invalidPacket: return "invalidPacket"
        case .timelineMismatch: return "timelineMismatch"
        case .arithmeticOverflow: return "arithmeticOverflow"
        }
    }
}

/// Sequence/timeline admission. Bounds as on the Apple client: at most 6
/// scheduled 20 ms chunks and at most 2 synthesized silent chunks. Capacity
/// is checked only after the timeline is validated, so `.queueFull` always
/// means a timeline-valid packet that may be committed as consumed.
/// `decision` never mutates; `commit` records accepted, resync and
/// queue-full (dropped) packets.
nonisolated struct PeelRemoteMacAudioSchedulingState: Sendable {
    static let chunkFrameCount = Int(PeelAudioPacket.pcmFrameCount)
    static let maxScheduledChunks = 6
    static let maxSequenceGap = 2
    /// Forward re-anchor bounds (60 s); beyond them, or backwards, the
    /// timeline is treated as corrupt and the request restarts once.
    static let maxResyncSequenceAdvance: UInt64 = 3_000
    static let maxResyncSampleAdvance: Int64 = 2_880_000

    private(set) var lastSequence: UInt64?
    private(set) var lastSampleTime: Int64?

    mutating func reset() {
        lastSequence = nil
        lastSampleTime = nil
    }

    func decision(for packet: PeelAudioPacket, scheduledChunkCount: Int) -> PeelRemoteMacAudioScheduleDecision {
        guard packet.kind == .pcm, packet.direction == .macToClient,
              packet.format == .v1(for: .macToClient),
              Int(packet.frameCount) == Self.chunkFrameCount else { return .invalidPacket }
        // A count outside the bound is a caller bug: refuse without committing.
        guard scheduledChunkCount >= 0, scheduledChunkCount <= Self.maxScheduledChunks else { return .invalidPacket }
        let room = Self.maxScheduledChunks - scheduledChunkCount

        guard let previousSequence = lastSequence, let previousSampleTime = lastSampleTime else {
            guard room >= 1 else { return .queueFull }
            return .accepted(sequence: packet.sequence, sampleTime: packet.sampleTime, silenceChunks: 0)
        }
        if packet.sequence == previousSequence { return .duplicate }
        if packet.sequence < previousSequence { return .oldFrame }

        // packet.sequence > previousSequence, so neither subtraction wraps.
        let sequenceAdvance = packet.sequence - previousSequence
        let missing = sequenceAdvance - 1
        if missing <= UInt64(Self.maxSequenceGap) {
            let advance = Int64(Self.chunkFrameCount) * Int64(sequenceAdvance)
            let (expectedSampleTime, overflow) = previousSampleTime.addingReportingOverflow(advance)
            guard !overflow else { return .arithmeticOverflow }
            if packet.sampleTime == expectedSampleTime {
                if Int(missing) + 1 <= room {
                    return .accepted(sequence: packet.sequence, sampleTime: packet.sampleTime,
                                     silenceChunks: Int(missing))
                }
                // Under pressure prefer real PCM over synthesized silence.
                guard room >= 1 else { return .queueFull }
                return .accepted(sequence: packet.sequence, sampleTime: packet.sampleTime, silenceChunks: 0)
            }
        }

        let (timeAdvance, overflow) = packet.sampleTime.subtractingReportingOverflow(previousSampleTime)
        guard !overflow else { return .arithmeticOverflow }
        guard timeAdvance > 0, timeAdvance <= Self.maxResyncSampleAdvance,
              sequenceAdvance <= Self.maxResyncSequenceAdvance else {
            return missing > UInt64(Self.maxSequenceGap) ? .gapTooLarge : .timelineMismatch
        }
        guard room >= 1 else { return .queueFull }
        return .resync(sequence: packet.sequence, sampleTime: packet.sampleTime)
    }

    /// Records an accepted/resync packet after scheduling, or a queue-full
    /// packet as consumed. Never moves the baseline backwards.
    mutating func commit(_ packet: PeelAudioPacket, after decision: PeelRemoteMacAudioScheduleDecision) {
        guard packet.kind == .pcm else { return }
        switch decision {
        case let .accepted(sequence, sampleTime, _), let .resync(sequence, sampleTime):
            guard packet.sequence == sequence, packet.sampleTime == sampleTime else { return }
        case .queueFull:
            break
        default:
            return
        }
        if let lastSequence, packet.sequence <= lastSequence { return }
        lastSequence = packet.sequence
        lastSampleTime = packet.sampleTime
    }
}

/// Per-request scheduling counters for root diagnostics. Counts and fixed
/// codes only; never PCM, keys, tickets or titles.
nonisolated struct PeelRemoteMacAudioTimelineCounters: Equatable, Sendable {
    var acceptedPackets = 0
    var silenceChunks = 0
    var sourceResyncs = 0
    var localQueueDrops = 0
    var notRenderingDrops = 0
    var duplicates = 0
    var oldFrames = 0
    var invalidPackets = 0
    var outputRebuilds = 0
    /// gapTooLarge | timelineMismatch | arithmeticOverflow
    var lastDiscontinuity: String?

    mutating func record(_ decision: PeelRemoteMacAudioScheduleDecision) {
        switch decision {
        case let .accepted(_, _, silence):
            acceptedPackets = Self.bump(acceptedPackets)
            silenceChunks = Self.bump(silenceChunks, by: silence)
        case .resync:
            acceptedPackets = Self.bump(acceptedPackets)
            sourceResyncs = Self.bump(sourceResyncs)
        case .queueFull: localQueueDrops = Self.bump(localQueueDrops)
        case .duplicate: duplicates = Self.bump(duplicates)
        case .oldFrame: oldFrames = Self.bump(oldFrames)
        case .invalidPacket: invalidPackets = Self.bump(invalidPackets)
        case .gapTooLarge, .timelineMismatch, .arithmeticOverflow: lastDiscontinuity = decision.code
        }
    }

    static func bump(_ value: Int, by amount: Int = 1) -> Int {
        let (sum, overflow) = value.addingReportingOverflow(amount)
        return overflow ? Int.max : sum
    }

    var summary: String {
        "accepted=\(acceptedPackets) silence=\(silenceChunks) resync=\(sourceResyncs) "
            + "queueFull=\(localQueueDrops) notRendering=\(notRenderingDrops) dup=\(duplicates) "
            + "old=\(oldFrames) invalid=\(invalidPackets) rebuilds=\(outputRebuilds) "
            + "discontinuity=\(lastDiscontinuity ?? "none")"
    }
}

/// Validated stereo S16LE -> deinterleaved Float32 conversion for one packet.
nonisolated enum PeelRemoteMacAudioPCM {
    static let channelCount = Int(PeelAudioPacketDirection.macToClient.expectedChannelCount)
    static let bytesPerSample = Int(PeelAudioPacket.bytesPerSample)

    /// Walks the collection's own indices (Data slices may not start at 0).
    /// Returns nil for any frame count or byte count other than the exact
    /// fixed v1 PCM packet shape.
    static func floatChannels<C: Collection>(_ bytes: C, frameCount: Int) -> (left: [Float], right: [Float])?
    where C.Element == UInt8 {
        guard frameCount == PeelRemoteMacAudioSchedulingState.chunkFrameCount,
              bytes.count == frameCount * channelCount * bytesPerSample else { return nil }
        var left = [Float](); left.reserveCapacity(frameCount)
        var right = [Float](); right.reserveCapacity(frameCount)
        var iterator = bytes.makeIterator()
        for _ in 0..<frameCount {
            guard let l0 = iterator.next(), let l1 = iterator.next(),
                  let r0 = iterator.next(), let r1 = iterator.next() else { return nil }
            left.append(Float(Int16(bitPattern: UInt16(l0) | (UInt16(l1) << 8))) / 32_768.0)
            right.append(Float(Int16(bitPattern: UInt16(r0) | (UInt16(r1) << 8))) / 32_768.0)
        }
        return (left, right)
    }
}

/// Pairing IDs (never keys) whose default playback the user explicitly turned
/// Off on this Mac receiver. Survives reconnect and relaunch; explicit On
/// clears it. Bounded to the 64 most recent IDs, like the Apple client.
nonisolated struct PeelRemoteMacAudioPlaybackOffStore: @unchecked Sendable {
    static let defaultsKey = "peel.remoteMac.audio.defaultPlaybackOffPairingIDs"
    static let maximumEntries = 64
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func isOff(_ pairingID: String) -> Bool {
        defaults.stringArray(forKey: Self.defaultsKey)?.contains(pairingID) == true
    }

    func setOff(_ off: Bool, for pairingID: String) {
        guard !pairingID.isEmpty else { return }
        var ids = defaults.stringArray(forKey: Self.defaultsKey) ?? []
        guard ids.contains(pairingID) != off else { return }
        ids.removeAll { $0 == pairingID }
        if off { ids = Array((ids + [pairingID]).suffix(Self.maximumEntries)) }
        defaults.set(ids, forKey: Self.defaultsKey)
    }
}

/// Current-connection facts supplied by PeelRemoteMacViewerController. It
/// carries no key material; proofs and the auxiliary TLS socket are produced
/// by the viewer controller's own narrow adapters.
nonisolated struct PeelRemoteMacAudioContext: Equatable, Sendable {
    /// The viewer controller's control-connection epoch.
    let controlEpoch: UUID
    let pairingID: String
    /// The last ClientVisibilityMessage value this viewer sent the Host.
    let clientVisible: Bool
    /// Host advertised mac-system-audio-v1 in its hello.
    let hostSupportsPlayback: Bool
    /// Selected window whose stream has presented video, if any.
    let streamWindowID: UInt32?
}

/// One default Listen attempt per control connection, playback only.
nonisolated enum PeelRemoteMacAudioDefaultGate {
    nonisolated struct Inputs: Equatable, Sendable {
        var backendAvailable: Bool
        var idle: Bool
        var context: PeelRemoteMacAudioContext?
        var defaultAttemptEpoch: UUID?
        var explicitlyOff: Bool
    }

    static func shouldStart(_ inputs: Inputs) -> Bool {
        guard inputs.backendAvailable, inputs.idle, let context = inputs.context,
              context.clientVisible, context.hostSupportsPlayback, context.streamWindowID != nil,
              inputs.defaultAttemptEpoch != context.controlEpoch,
              !inputs.explicitlyOff else { return false }
        return true
    }
}
