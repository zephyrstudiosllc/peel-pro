import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let message: String

    var description: String { message }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw TestFailure(message: message)
    }
}

private func expectError(
    _ expected: PeelAudioPacketError,
    _ operation: () throws -> Void,
    _ label: String
) throws {
    do {
        try operation()
        throw TestFailure(message: label + " did not throw")
    } catch let error as PeelAudioPacketError {
        guard error == expected else {
            throw TestFailure(message: label + " threw " + String(describing: error) +
                              "; expected " + String(describing: expected))
        }
    }
}

private func payload(count: Int) -> Data {
    Data((0..<count).map { UInt8($0 & 0xff) })
}

private func concat(_ values: [Data]) -> Data {
    var result = Data()
    for value in values {
        result.append(contentsOf: value)
    }
    return result
}

private func replaceByte(_ data: Data, at offset: Int, with value: UInt8) -> Data {
    var result = Data(data)
    let index = result.index(result.startIndex, offsetBy: offset)
    result[index] = value
    return result
}

private func replaceBytes(_ data: Data, at offset: Int, with values: [UInt8]) -> Data {
    var result = Data(data)
    let start = result.index(result.startIndex, offsetBy: offset)
    for (index, value) in values.enumerated() {
        result[result.index(start, offsetBy: index)] = value
    }
    return result
}

private func makeDownlinkPCM(sequence: UInt64, sampleTime: Int64) throws -> PeelAudioPacket {
    try PeelAudioPacket(pcmFor: .macToClient,
                        sequence: sequence,
                        sampleTime: sampleTime,
                        payload: payload(count: 3_840))
}

private func makeUplinkPCM(sequence: UInt64, sampleTime: Int64) throws -> PeelAudioPacket {
    try PeelAudioPacket(pcmFor: .clientToMac,
                        sequence: sequence,
                        sampleTime: sampleTime,
                        payload: payload(count: 1_920))
}

private func testHeaderAndRoundTrip() throws {
    let format = PeelAudioPacket.formatPacket(for: .macToClient)
    let formatWire = try format.encode()
    try expect(formatWire.count == 36, "format header must be 36 bytes")
    try expect(Array(formatWire.prefix(4)) == [0x50, 0x45, 0x41, 0x55], "magic must be PEAU")
    try expect(formatWire[4] == 1, "version must be one")
    try expect(formatWire[5] == 0, "format kind must be zero")
    try expect(formatWire[6] == 0, "Mac-to-client direction must be zero")
    try expect(formatWire[7] == 0, "flags must be zero")
    try expect(Array(formatWire[8..<12]) == [0, 0, 0, 0], "format payload length must be zero")
    try expect(Array(formatWire[28..<32]) == [0, 0, 0xbb, 0x80], "sample rate must be 48000 BE")
    try expect(formatWire[32] == 0 && formatWire[33] == 0, "format frames must be zero")
    try expect(formatWire[34] == 2 && formatWire[35] == 2, "format channel fields must be stereo S16")
    let decodedFormat = try PeelAudioPacket.decode(formatWire)
    try expect(decodedFormat == format, "format round trip")

    let pcm = try makeDownlinkPCM(sequence: 0x0102_0304_0506_0708, sampleTime: 0x123)
    let pcmWire = try pcm.encode()
    try expect(pcmWire.count == 36 + 3_840, "downlink packet size")
    try expect(Array(pcmWire[8..<12]) == [0, 0, 0x0f, 0], "downlink payload length must be 3840 BE")
    try expect(Array(pcmWire[12..<20]) == [1, 2, 3, 4, 5, 6, 7, 8], "sequence must be UInt64 BE")
    try expect(Array(pcmWire[20..<28]) == [0, 0, 0, 0, 0, 0, 1, 0x23], "sample time must be Int64 BE")
    let decodedPCM = try PeelAudioPacket.decode(pcmWire)
    try expect(decodedPCM == pcm, "PCM round trip")

    let uplink = try makeUplinkPCM(sequence: 9, sampleTime: 10)
    try expect(uplink.payload.count == 1_920, "uplink payload size")
    try expect(uplink.channels == 1, "uplink must be mono")
    let uplinkWire = try uplink.encode()
    try expect(uplinkWire.count == 36 + 1_920, "uplink packet size")
}

private func testFragmentationCoalescingAndNonZeroIndices() throws {
    let formatWire = try PeelAudioPacket.formatPacket(for: .macToClient).encode()
    let pcmWire = try makeDownlinkPCM(sequence: 4, sampleTime: 3).encode()
    let wire = concat([formatWire, pcmWire])

    var fragmented = PeelAudioPacketParser(expectedDirection: .macToClient)
    var output: [PeelAudioPacket] = []
    var offset = 0
    for width in [1, 2, 7, 13, 29, 64, 128, 512, 777, 999, 1_000] {
        guard offset < wire.count else { break }
        let end = min(wire.count, offset + width)
        let part = Data(wire[wire.index(wire.startIndex, offsetBy: offset)..<wire.index(wire.startIndex, offsetBy: end)])
        output.append(contentsOf: try fragmented.feed(part))
        offset = end
    }
    if offset < wire.count {
        let part = Data(wire[wire.index(wire.startIndex, offsetBy: offset)..<wire.endIndex])
        output.append(contentsOf: try fragmented.feed(part))
    }
    try expect(output.count == 2, "fragmented stream packet count")
    try expect(output[0].kind == .format && output[1].kind == .pcm, "fragmented stream ordering")
    try expect(fragmented.hasReceivedFormat, "format state after fragmented stream")

    var coalesced = PeelAudioPacketParser(expectedDirection: .macToClient)
    let coalescedOutput = try coalesced.feed(wire)
    try expect(coalescedOutput == output, "coalesced stream output")

    var nonZeroIndices = PeelAudioPacketParser(expectedDirection: .macToClient)
    var wrapped = Data([0xff])
    wrapped.append(contentsOf: wire)
    wrapped.append(0xee)
    let slice = wrapped.dropFirst().dropLast()
    try expect(slice.startIndex != 0, "fixture must retain a nonzero Data start index")
    let nonZeroOutput = try nonZeroIndices.feed(slice)
    try expect(nonZeroOutput == output, "nonzero-index Data output")
}

private func testFormatAndDirectionGates() throws {
    let pcmWire = try makeUplinkPCM(sequence: 1, sampleTime: 0).encode()
    var beforeFormat = PeelAudioPacketParser(expectedDirection: .clientToMac)
    try expectError(.pcmBeforeFormat,
                    { _ = try beforeFormat.feed(pcmWire) },
                    "PCM-before-format")
    try expect(beforeFormat.isFailed, "PCM-before-format must fail closed")
    try expect(!beforeFormat.hasReceivedFormat, "failed parser must clear format state")
    try expectError(.parserFailed,
                    { _ = try beforeFormat.feed(try PeelAudioPacket.formatPacket(for: .clientToMac).encode()) },
                    "failed parser")
    beforeFormat.reset()
    let valid = concat([
        try PeelAudioPacket.formatPacket(for: .clientToMac).encode(),
        pcmWire
    ])
    let resetOutput = try beforeFormat.feed(valid)
    try expect(resetOutput.count == 2, "reset must restore parser")

    var wrongDirection = PeelAudioPacketParser(expectedDirection: .macToClient)
    let uplinkFormat = try PeelAudioPacket.formatPacket(for: .clientToMac).encode()
    try expectError(.unexpectedDirection(expected: .macToClient, actual: .clientToMac),
                    { _ = try wrongDirection.feed(uplinkFormat) },
                    "direction gate")

    var wrongFormat = PeelAudioPacketParser(
        expectedDirection: .macToClient,
        expectedFormat: PeelAudioPacketFormat(sampleRate: 44_100, channels: 2, bytesPerSample: 2))
    let downlinkFormat = try PeelAudioPacket.formatPacket(for: .macToClient).encode()
    try expectError(.formatMismatch(expected: wrongFormat.expectedFormat,
                                    actual: PeelAudioPacketFormat(sampleRate: 48_000, channels: 2, bytesPerSample: 2)),
                    { _ = try wrongFormat.feed(downlinkFormat) },
                    "format gate")
}

private func testValidationErrors() throws {
    try expectError(.payloadLengthMismatch(expected: 3_840, actual: 1),
                    { _ = try PeelAudioPacket(pcmFor: .macToClient, sequence: 0, sampleTime: 0, payload: payload(count: 1)) },
                    "encoder PCM body size")
    try expectError(.invalidChannelCount(direction: .macToClient, actual: 1),
                    { _ = try PeelAudioPacket(kind: .format, direction: .macToClient, channels: 1) },
                    "encoder channel count")
    try expectError(.negativeSampleTime(-1),
                    { _ = try PeelAudioPacket(kind: .format, direction: .macToClient, sampleTime: -1) },
                    "encoder sample time")

    let format = try PeelAudioPacket.formatPacket(for: .macToClient).encode()
    try expectError(.invalidMagic,
                    { _ = try PeelAudioPacket.decode(replaceByte(format, at: 0, with: 0)) },
                    "magic")
    try expectError(.unsupportedVersion(2),
                    { _ = try PeelAudioPacket.decode(replaceByte(format, at: 4, with: 2)) },
                    "version")
    try expectError(.unsupportedKind(2),
                    { _ = try PeelAudioPacket.decode(replaceByte(format, at: 5, with: 2)) },
                    "kind")
    try expectError(.unsupportedDirection(2),
                    { _ = try PeelAudioPacket.decode(replaceByte(format, at: 6, with: 2)) },
                    "direction")
    try expectError(.unsupportedFlags(1),
                    { _ = try PeelAudioPacket.decode(replaceByte(format, at: 7, with: 1)) },
                    "flags")
    try expectError(.payloadTooLarge(length: 4_097, maximum: 4_096),
                    { _ = try PeelAudioPacket.decode(replaceBytes(format, at: 8, with: [0, 0, 0x10, 1])) },
                    "payload bound")
    try expectError(.negativeSampleTime(Int64.min),
                    { _ = try PeelAudioPacket.decode(replaceBytes(format, at: 20, with: [0x80, 0, 0, 0, 0, 0, 0, 0])) },
                    "negative sample time")
    try expectError(.unsupportedSampleRate(44_100),
                    { _ = try PeelAudioPacket.decode(replaceBytes(format, at: 28, with: [0, 0, 0xac, 0x44])) },
                    "sample rate")
    try expectError(.invalidChannelCount(direction: .macToClient, actual: 1),
                    { _ = try PeelAudioPacket.decode(replaceByte(format, at: 34, with: 1)) },
                    "channels")
    try expectError(.unsupportedBytesPerSample(1),
                    { _ = try PeelAudioPacket.decode(replaceByte(format, at: 35, with: 1)) },
                    "bytes per sample")
    try expectError(.nonZeroFormatSequence(1),
                    { _ = try PeelAudioPacket.decode(replaceByte(format, at: 19, with: 1)) },
                    "format sequence")
    try expectError(.nonZeroFormatSampleTime(1),
                    { _ = try PeelAudioPacket.decode(replaceByte(format, at: 27, with: 1)) },
                    "format sample time")
    try expectError(.nonZeroFormatFrameCount(1),
                    { _ = try PeelAudioPacket.decode(replaceByte(format, at: 33, with: 1)) },
                    "format frame count")

    let nonEmptyFormat = replaceBytes(format, at: 8, with: [0, 0, 0, 1]) + Data([0])
    try expectError(.nonEmptyFormatPayload(1),
                    { _ = try PeelAudioPacket.decode(nonEmptyFormat) },
                    "format body")
    try expectError(.packetTooShort(actual: 35, minimum: 36),
                    { _ = try PeelAudioPacket.decode(Data(format.dropLast())) },
                    "short packet")
    try expectError(.packetLengthMismatch(expected: 36, actual: 37),
                    { _ = try PeelAudioPacket.decode(format + Data([0])) },
                    "extra packet byte")
}

private func testBoundsAndReset() throws {
    let headerFragment = Data(try PeelAudioPacket.formatPacket(for: .macToClient).encode().dropLast())
    var accumulator = PeelAudioPacketParser(expectedDirection: .macToClient)
    try _ = accumulator.feed(headerFragment)
    try expectError(.accumulatorLimitExceeded(current: 35,
                                               incoming: PeelAudioPacket.maxAccumulatorBytes - 34,
                                               maximum: PeelAudioPacket.maxAccumulatorBytes),
                    { _ = try accumulator.feed(Data(repeating: 0, count: PeelAudioPacket.maxAccumulatorBytes - 34)) },
                    "accumulator bound")
    try expect(accumulator.isFailed, "accumulator bound must fail closed")
    try expect(!accumulator.hasReceivedFormat, "accumulator failure must clear format state")
    accumulator.reset()
    let resetFormatWire = try PeelAudioPacket.formatPacket(for: .macToClient).encode()
    let resetFormatOutput = try accumulator.feed(resetFormatWire)
    try expect(resetFormatOutput.count == 1, "reset after accumulator failure")

    let formatWire = try PeelAudioPacket.formatPacket(for: .macToClient).encode()
    var thirtyTwo = Data()
    for _ in 0..<PeelAudioPacket.maxPacketsPerFeed {
        thirtyTwo.append(contentsOf: formatWire)
    }
    var packetLimit = PeelAudioPacketParser(expectedDirection: .macToClient)
    try expectError(.feedPacketLimitExceeded(limit: PeelAudioPacket.maxPacketsPerFeed),
                    { _ = try packetLimit.feed(thirtyTwo + formatWire) },
                    "feed packet bound")
    try expect(packetLimit.isFailed, "feed packet bound must fail closed")
    try expect(!packetLimit.hasReceivedFormat, "terminal failure must clear a previously accepted format")
}

private func testSequenceAndSampleTimeAreTransportPolicy() throws {
    let format = try PeelAudioPacket.formatPacket(for: .macToClient).encode()
    let first = try makeDownlinkPCM(sequence: 900, sampleTime: 2_000).encode()
    let second = try makeDownlinkPCM(sequence: 3, sampleTime: 10).encode()
    var parser = PeelAudioPacketParser(expectedDirection: .macToClient)
    let packets = try parser.feed(concat([format, first, second]))
    try expect(packets.count == 3, "out-of-order transport metadata should decode")
    try expect(packets[1].sequence == 900 && packets[2].sequence == 3,
               "parser must preserve sequence values")
    try expect(packets[1].sampleTime == 2_000 && packets[2].sampleTime == 10,
               "parser must preserve sample times")
}

@main
struct PeelAudioPacketHarness {
    static func main() {
        do {
            try testHeaderAndRoundTrip()
            try testFragmentationCoalescingAndNonZeroIndices()
            try testFormatAndDirectionGates()
            try testValidationErrors()
            try testBoundsAndReset()
            try testSequenceAndSampleTimeAreTransportPolicy()
            print("PeelAudioPacket tests passed")
        } catch {
            fputs("PeelAudioPacket tests failed: " + String(describing: error) + "\n", stderr)
            exit(1)
        }
    }
}
