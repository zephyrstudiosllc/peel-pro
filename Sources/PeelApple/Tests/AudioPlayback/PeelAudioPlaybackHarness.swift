import Foundation

private enum HarnessError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw HarnessError.failed(message)
    }
}

private func makePayload(seed: UInt8 = 0) -> Data {
    let byteCount = PeelAudioPlaybackSchedulingState.chunkFrameCount *
        PeelAudioPlaybackPCM.channelCount * PeelAudioPlaybackPCM.bytesPerSample
    return Data(repeating: seed, count: byteCount)
}

private func makePacket(sequence: UInt64, sampleTime: Int64) throws -> PeelAudioPacket {
    try PeelAudioPacket.pcmPacket(for: .macToClient,
                                  sequence: sequence,
                                  sampleTime: sampleTime,
                                  payload: makePayload())
}

private func requireDecision(
    _ actual: PeelAudioPlaybackScheduleDecision,
    _ expected: PeelAudioPlaybackScheduleDecision,
    _ message: String
) throws {
    try require(actual == expected,
                "\(message): got \(actual), expected \(expected)")
}

private func testPCMConversionUsesCollectionIndices() throws {
    let pcmBytes: [UInt8] = [
        0x00, 0x80, 0xff, 0x7f,
        0x34, 0x12, 0x00, 0x00
    ]
    let wrapped = Data([0xf0] + pcmBytes + [0x0f])
    let nonZeroIndexedSlice = wrapped.dropFirst().dropLast()

    let normalized = try PeelAudioPlaybackPCM.validatedStereoS16LE(nonZeroIndexedSlice,
                                                                    frameCount: 2)
    try require(normalized == pcmBytes,
                "PCM normalization must preserve the bytes in a sliced Data collection")

    let samples = try PeelAudioPlaybackPCM.decodeStereoS16LE(nonZeroIndexedSlice,
                                                              frameCount: 2)
    try require(samples == [-32768, 32767, 0x1234, 0],
                "S16LE conversion must decode signed little-endian samples")

    let channels = try PeelAudioPlaybackPCM.decodeStereoS16LEToFloatChannels(
        nonZeroIndexedSlice,
        frameCount: 2
    )
    try require(channels.left == [-1.0, Float(0x1234) / 32_768.0],
                "left S16LE samples must map to deinterleaved Float32 values")
    try require(channels.right == [Float(0x7fff) / 32_768.0, 0.0],
                "right S16LE samples must map to deinterleaved Float32 values")

    do {
        _ = try PeelAudioPlaybackPCM.validatedStereoS16LE(nonZeroIndexedSlice,
                                                          frameCount: 1)
        throw HarnessError.failed("PCM conversion accepted an invalid byte count")
    } catch PeelAudioPlaybackPCMError.invalidByteCount(let expected, let actual) {
        try require(expected == 4 && actual == 8,
                    "PCM byte-count error must report bounded expected and actual sizes")
    }
}

private func testMicrophoneConversionAndPacketization() throws {
    var packetizer = PeelAudioMicrophonePacketizer()
    let samples = [-1.0, 0.0, 0.5, 1.0] +
        [Float](repeating: 0, count: PeelAudioMicrophonePacketizer.frameCount - 4)
    let packets = try packetizer.append(samples)
    try require(packets.count == 1,
                "960 mono samples must produce one uplink packet")
    let first = packets[0]
    try require(first.direction == .clientToMac &&
                first.frameCount == UInt16(PeelAudioMicrophonePacketizer.frameCount) &&
                first.sampleTime == 0 && first.sequence == 0,
                "uplink packet metadata must use the client-to-Mac v1 format")
    try require(Array(first.payload.prefix(8)) ==
                [0x00, 0x80, 0x00, 0x00, 0x00, 0x40, 0xff, 0x7f],
                "mono Float32 samples must quantize to little-endian S16")

    let second = try packetizer.append(
        [Float](repeating: 0, count: PeelAudioMicrophonePacketizer.frameCount)
    )
    try require(second.count == 1 && second[0].sequence == 1 &&
                second[0].sampleTime == Int64(PeelAudioMicrophonePacketizer.frameCount),
                "uplink packet sequence and sample time must advance by one chunk")

    var converter = PeelAudioMicrophoneCaptureConverter()
    let converted = try converter.append(
        [Float](repeating: 0.25, count: PeelAudioMicrophoneResampler.maxInputFrames),
        sourceSampleRate: PeelAudioMicrophoneResampler.outputSampleRate
    )
    try require(converted.count == 4,
                "48 kHz capture conversion must preserve four complete chunks")
    try require(converted.allSatisfy { $0.direction == .clientToMac &&
                $0.payload.count == PeelAudioMicrophonePacketizer.maxPayloadLength },
                "capture conversion must emit bounded mono uplink payloads")

    do {
        _ = try converter.append([Float](repeating: 0, count: 1), sourceSampleRate: 0)
        throw HarnessError.failed("capture conversion accepted an invalid source rate")
    } catch PeelAudioMicrophoneCaptureConversionError.invalidSourceSampleRate {
        // Expected.
    }
}

private func testSchedulingAdmissionAndGaps() throws {
    var state = PeelAudioPlaybackSchedulingState()
    let formatPacket = PeelAudioPacket.formatPacket(for: .macToClient)
    try requireDecision(state.decision(for: formatPacket, scheduledChunkCount: 0),
                        .invalidPacket,
                        "format metadata must not enter PCM scheduling state")
    let uplinkPayload = Data(repeating: 0,
                             count: PeelAudioPlaybackSchedulingState.chunkFrameCount *
                                 Int(PeelAudioPacketDirection.clientToMac.expectedChannelCount) *
                                 Int(PeelAudioPacket.bytesPerSample))
    let uplink = try PeelAudioPacket.pcmPacket(for: .clientToMac,
                                               sequence: 0,
                                               sampleTime: 0,
                                               payload: uplinkPayload)
    try requireDecision(state.decision(for: uplink, scheduledChunkCount: 0),
                        .invalidPacket,
                        "uplink PCM must not enter downlink scheduling state")

    let first = try makePacket(sequence: 10, sampleTime: 1_000)
    let firstDecision = state.decision(for: first, scheduledChunkCount: 0)
    try requireDecision(firstDecision,
                        .accepted(sequence: 10, sampleTime: 1_000, silenceChunks: 0),
                        "first PCM packet")
    state.commit(first, after: firstDecision)

    let duplicate = try makePacket(sequence: 10, sampleTime: 1_000)
    try requireDecision(state.decision(for: duplicate, scheduledChunkCount: 1),
                        .duplicate,
                        "duplicate packet")

    let old = try makePacket(sequence: 9, sampleTime: 40)
    try requireDecision(state.decision(for: old, scheduledChunkCount: 1),
                        .oldFrame,
                        "old packet")

    let next = try makePacket(sequence: 11, sampleTime: 1_960)
    let nextDecision = state.decision(for: next, scheduledChunkCount: 1)
    try requireDecision(nextDecision,
                        .accepted(sequence: 11, sampleTime: 1_960, silenceChunks: 0),
                        "contiguous packet")
    state.commit(next, after: nextDecision)

    let oneMissing = try makePacket(sequence: 13, sampleTime: 3_880)
    let gapDecision = state.decision(for: oneMissing, scheduledChunkCount: 1)
    try requireDecision(gapDecision,
                        .accepted(sequence: 13, sampleTime: 3_880, silenceChunks: 1),
                        "bounded one-packet gap")
    state.commit(oneMissing, after: gapDecision)

    let tooLarge = try makePacket(sequence: 17, sampleTime: 7_720)
    try requireDecision(state.decision(for: tooLarge, scheduledChunkCount: 1),
                        .gapTooLarge,
                        "unbounded packet gap")

    let badTimeline = try makePacket(sequence: 14, sampleTime: 4_000)
    try requireDecision(state.decision(for: badTimeline, scheduledChunkCount: 1),
                        .timelineMismatch,
                        "misaligned sample time")
}

private func testQueueBoundAndReset() throws {
    var state = PeelAudioPlaybackSchedulingState()
    let first = try makePacket(sequence: 0, sampleTime: 0)
    try requireDecision(state.decision(for: first,
                                       scheduledChunkCount: PeelAudioPlaybackSchedulingState.maxScheduledChunks),
                        .queueFull,
                        "full queue must reject before PCM conversion")

    let firstDecision = state.decision(for: first, scheduledChunkCount: 0)
    state.commit(first, after: firstDecision)
    let gap = try makePacket(sequence: 3, sampleTime: 2_880)
    try requireDecision(state.decision(for: gap, scheduledChunkCount: 4),
                        .queueFull,
                        "gap silence plus PCM must fit the six-chunk bound")

    state.reset()
    try require(state.lastSequence == nil && state.lastSampleTime == nil,
                "reset must clear sequence and sample-time state")
    try requireDecision(state.decision(for: first, scheduledChunkCount: 0),
                        .accepted(sequence: 0, sampleTime: 0, silenceChunks: 0),
                        "reset stream baseline")
}

private func testCheckedArithmeticBoundaries() throws {
    var sequenceState = PeelAudioPlaybackSchedulingState()
    let maxMinusOne = try makePacket(sequence: UInt64.max - 1,
                                     sampleTime: Int64.max - 960)
    let baseline = sequenceState.decision(for: maxMinusOne, scheduledChunkCount: 0)
    sequenceState.commit(maxMinusOne, after: baseline)
    let maxSequence = try makePacket(sequence: UInt64.max, sampleTime: Int64.max)
    let maxDecision = sequenceState.decision(for: maxSequence, scheduledChunkCount: 0)
    try requireDecision(maxDecision,
                        .accepted(sequence: UInt64.max, sampleTime: Int64.max, silenceChunks: 0),
                        "maximum representable sequence")
    sequenceState.commit(maxSequence, after: maxDecision)
    let duplicateMaximum = try makePacket(sequence: UInt64.max, sampleTime: Int64.max)
    try requireDecision(sequenceState.decision(for: duplicateMaximum, scheduledChunkCount: 0),
                        .duplicate,
                        "maximum sequence duplicate must not overflow")

    var timeState = PeelAudioPlaybackSchedulingState()
    let maxTime = try makePacket(sequence: 1, sampleTime: Int64.max)
    let maxTimeDecision = timeState.decision(for: maxTime, scheduledChunkCount: 0)
    timeState.commit(maxTime, after: maxTimeDecision)
    let next = try makePacket(sequence: 2, sampleTime: Int64.max)
    try requireDecision(timeState.decision(for: next, scheduledChunkCount: 0),
                        .arithmeticOverflow,
                        "sample-time advancement must be checked")
}

@main
struct PeelAudioPlaybackHarness {
    static func main() throws {
        try testPCMConversionUsesCollectionIndices()
        try testMicrophoneConversionAndPacketization()
        try testSchedulingAdmissionAndGaps()
        try testQueueBoundAndReset()
        try testCheckedArithmeticBoundaries()
        print("PeelAudioPlayback focused tests passed")
    }
}
