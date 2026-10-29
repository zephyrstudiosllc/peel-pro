import Foundation

/// The two directions supported by the v1 audio transport.
nonisolated public enum PeelAudioPacketDirection: UInt8, Equatable, Hashable, Sendable {
    case macToClient = 0
    case clientToMac = 1

    /// The fixed v1 channel count for this direction.
    public var expectedChannelCount: UInt8 {
        switch self {
        case .macToClient:
            return 2
        case .clientToMac:
            return 1
        }
    }

    /// Short aliases useful at call sites that use transport terminology.
    public static var downlink: Self { .macToClient }
    public static var uplink: Self { .clientToMac }
}

/// The kind byte in a v1 packet header.
nonisolated public enum PeelAudioPacketKind: UInt8, Equatable, Hashable, Sendable {
    case format = 0
    case pcm = 1
}

/// The format fields which a stream parser expects after its format packet.
nonisolated public struct PeelAudioPacketFormat: Equatable, Hashable, Sendable {
    public let sampleRate: UInt32
    public let channels: UInt8
    public let bytesPerSample: UInt8

    public init(sampleRate: UInt32, channels: UInt8, bytesPerSample: UInt8) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bytesPerSample = bytesPerSample
    }

    public static func v1(for direction: PeelAudioPacketDirection) -> Self {
        Self(sampleRate: PeelAudioPacket.sampleRate,
             channels: direction.expectedChannelCount,
             bytesPerSample: PeelAudioPacket.bytesPerSample)
    }
}

/// Typed failures raised by both the packet encoder and stream parser.
nonisolated public enum PeelAudioPacketError: Error, Equatable, Sendable, LocalizedError {
    case packetTooShort(actual: Int, minimum: Int)
    case packetLengthMismatch(expected: Int, actual: Int)
    case invalidMagic
    case unsupportedVersion(UInt8)
    case unsupportedKind(UInt8)
    case unsupportedDirection(UInt8)
    case unsupportedFlags(UInt8)
    case payloadTooLarge(length: UInt32, maximum: UInt32)
    case negativeSampleTime(Int64)
    case unsupportedSampleRate(UInt32)
    case invalidFrameCount(kind: PeelAudioPacketKind, actual: UInt16)
    case invalidChannelCount(direction: PeelAudioPacketDirection, actual: UInt8)
    case unsupportedBytesPerSample(UInt8)
    case payloadLengthMismatch(expected: Int, actual: Int)
    case nonZeroFormatSequence(UInt64)
    case nonZeroFormatSampleTime(Int64)
    case nonZeroFormatFrameCount(UInt16)
    case nonEmptyFormatPayload(Int)
    case unexpectedDirection(expected: PeelAudioPacketDirection, actual: PeelAudioPacketDirection)
    case formatMismatch(expected: PeelAudioPacketFormat, actual: PeelAudioPacketFormat)
    case pcmBeforeFormat
    case accumulatorLimitExceeded(current: Int, incoming: Int, maximum: Int)
    case feedPacketLimitExceeded(limit: Int)
    case parserFailed

    public var errorDescription: String? {
        switch self {
        case let .packetTooShort(actual, minimum):
            return "Audio packet has " + String(actual) + " bytes; at least " + String(minimum) + " are required."
        case let .packetLengthMismatch(expected, actual):
            return "Audio packet length is " + String(actual) + " bytes; header requires " + String(expected) + "."
        case .invalidMagic:
            return "Audio packet magic is not PEAU."
        case let .unsupportedVersion(version):
            return "Unsupported audio packet version " + String(version) + "."
        case let .unsupportedKind(kind):
            return "Unsupported audio packet kind " + String(kind) + "."
        case let .unsupportedDirection(direction):
            return "Unsupported audio packet direction " + String(direction) + "."
        case let .unsupportedFlags(flags):
            return "Audio packet flags must be zero; received " + String(flags) + "."
        case let .payloadTooLarge(length, maximum):
            return "Audio packet payload " + String(length) + " exceeds the " + String(maximum) + "-byte limit."
        case let .negativeSampleTime(sampleTime):
            return "Audio packet sample time " + String(sampleTime) + " must be non-negative."
        case let .unsupportedSampleRate(sampleRate):
            return "Audio packet sample rate " + String(sampleRate) + " is not the v1 rate of 48000 Hz."
        case let .invalidFrameCount(kind, actual):
            let name = kind == .format ? "format" : "PCM"
            return "Audio " + name + " packet frame count " + String(actual) + " is invalid."
        case let .invalidChannelCount(direction, actual):
            let name = direction == .macToClient ? "Mac-to-client" : "client-to-Mac"
            return "Audio packet channel count " + String(actual) + " is invalid for " + name + " v1 audio."
        case let .unsupportedBytesPerSample(bytesPerSample):
            return "Audio packet bytes-per-sample value " + String(bytesPerSample) + " is not 2."
        case let .payloadLengthMismatch(expected, actual):
            return "Audio packet payload is " + String(actual) + " bytes; " + String(expected) + " are required."
        case let .nonZeroFormatSequence(sequence):
            return "Format packet sequence must be zero; received " + String(sequence) + "."
        case let .nonZeroFormatSampleTime(sampleTime):
            return "Format packet sample time must be zero; received " + String(sampleTime) + "."
        case let .nonZeroFormatFrameCount(frameCount):
            return "Format packet frame count must be zero; received " + String(frameCount) + "."
        case let .nonEmptyFormatPayload(length):
            return "Format packet payload must be empty; received " + String(length) + " bytes."
        case let .unexpectedDirection(expected, actual):
            let expectedName = expected == .macToClient ? "Mac-to-client" : "client-to-Mac"
            let actualName = actual == .macToClient ? "Mac-to-client" : "client-to-Mac"
            return "Audio stream expects " + expectedName + " packets, received " + actualName + "."
        case let .formatMismatch(expected, actual):
            return "Audio packet format " + String(describing: actual) + " does not match expected format " + String(describing: expected) + "."
        case .pcmBeforeFormat:
            return "PCM audio arrived before a valid format packet."
        case let .accumulatorLimitExceeded(current, incoming, maximum):
            return "Audio parser accumulator would grow from " + String(current) + " by " + String(incoming) + " past " + String(maximum) + " bytes."
        case let .feedPacketLimitExceeded(limit):
            return "Audio parser feed exceeded the " + String(limit) + "-packet limit."
        case .parserFailed:
            return "Audio parser is failed; call reset() before feeding more data."
        }
    }
}

/// A validated v1 audio packet.
nonisolated public struct PeelAudioPacket: Equatable, Sendable {
    public static let wireMagic: [UInt8] = [0x50, 0x45, 0x41, 0x55] // PEAU
    public static let version: UInt8 = 1
    public static let headerLength = 36
    public static let sampleRate: UInt32 = 48_000
    public static let bytesPerSample: UInt8 = 2
    public static let pcmFrameCount: UInt16 = 960
    public static let maxPayloadLength: UInt32 = 4_096
    public static let maxAccumulatorBytes = 64 * 1024
    public static let maxPacketsPerFeed = 32

    public let kind: PeelAudioPacketKind
    public let direction: PeelAudioPacketDirection
    public let flags: UInt8
    public let sequence: UInt64
    public let sampleTime: Int64
    public let sampleRate: UInt32
    public let frameCount: UInt16
    public let channels: UInt8
    public let bytesPerSample: UInt8
    public let payload: Data

    public var payloadLength: Int { payload.count }

    public var format: PeelAudioPacketFormat {
        PeelAudioPacketFormat(sampleRate: sampleRate,
                              channels: channels,
                              bytesPerSample: bytesPerSample)
    }

    /// Creates a packet after validating every v1 field and payload bound.
    public init(
        kind: PeelAudioPacketKind,
        direction: PeelAudioPacketDirection,
        flags: UInt8 = 0,
        sequence: UInt64 = 0,
        sampleTime: Int64 = 0,
        sampleRate: UInt32 = PeelAudioPacket.sampleRate,
        frameCount: UInt16 = 0,
        channels: UInt8? = nil,
        bytesPerSample: UInt8 = PeelAudioPacket.bytesPerSample,
        payload: Data = Data()
    ) throws {
        let resolvedChannels = channels ?? direction.expectedChannelCount
        try Self.validate(kind: kind,
                          direction: direction,
                          flags: flags,
                          sequence: sequence,
                          sampleTime: sampleTime,
                          sampleRate: sampleRate,
                          frameCount: frameCount,
                          channels: resolvedChannels,
                          bytesPerSample: bytesPerSample,
                          payload: payload)
        self.kind = kind
        self.direction = direction
        self.flags = flags
        self.sequence = sequence
        self.sampleTime = sampleTime
        self.sampleRate = sampleRate
        self.frameCount = frameCount
        self.channels = resolvedChannels
        self.bytesPerSample = bytesPerSample
        self.payload = Data(payload)
    }

    /// Creates the zero-payload format packet required before PCM.
    public init(formatFor direction: PeelAudioPacketDirection) {
        self.kind = .format
        self.direction = direction
        self.flags = 0
        self.sequence = 0
        self.sampleTime = 0
        self.sampleRate = Self.sampleRate
        self.frameCount = 0
        self.channels = direction.expectedChannelCount
        self.bytesPerSample = Self.bytesPerSample
        self.payload = Data()
    }

    /// Creates one fixed-size 960-frame PCM packet.
    public init(
        pcmFor direction: PeelAudioPacketDirection,
        sequence: UInt64,
        sampleTime: Int64,
        payload: Data
    ) throws {
        try self.init(kind: .pcm,
                      direction: direction,
                      sequence: sequence,
                      sampleTime: sampleTime,
                      frameCount: Self.pcmFrameCount,
                      payload: payload)
    }

    public static func formatPacket(for direction: PeelAudioPacketDirection) -> Self {
        Self(formatFor: direction)
    }

    public static func pcmPacket(
        for direction: PeelAudioPacketDirection,
        sequence: UInt64,
        sampleTime: Int64,
        payload: Data
    ) throws -> Self {
        try Self(pcmFor: direction, sequence: sequence, sampleTime: sampleTime, payload: payload)
    }

    /// Serializes the packet into the fixed 36-byte big-endian header and PCM body.
    public func encode() throws -> Data {
        try Self.validate(kind: kind,
                          direction: direction,
                          flags: flags,
                          sequence: sequence,
                          sampleTime: sampleTime,
                          sampleRate: sampleRate,
                          frameCount: frameCount,
                          channels: channels,
                          bytesPerSample: bytesPerSample,
                          payload: payload)

        var data = Data(capacity: Self.headerLength + payload.count)
        data.append(contentsOf: Self.wireMagic)
        data.append(Self.version)
        data.append(kind.rawValue)
        data.append(direction.rawValue)
        data.append(flags)
        Wire.appendUInt32BE(UInt32(payload.count), to: &data)
        Wire.appendUInt64BE(sequence, to: &data)
        Wire.appendUInt64BE(UInt64(bitPattern: sampleTime), to: &data)
        Wire.appendUInt32BE(sampleRate, to: &data)
        Wire.appendUInt16BE(frameCount, to: &data)
        data.append(channels)
        data.append(bytesPerSample)
        data.append(contentsOf: payload)
        return data
    }

    /// Decodes one complete packet. Extra or missing bytes are rejected.
    public static func decode(_ data: Data) throws -> Self {
        guard data.count >= Self.headerLength else {
            throw PeelAudioPacketError.packetTooShort(actual: data.count, minimum: Self.headerLength)
        }
        for offset in 0..<Self.wireMagic.count where Wire.byte(at: offset, in: data) != Self.wireMagic[offset] {
            throw PeelAudioPacketError.invalidMagic
        }

        let version = Wire.byte(at: 4, in: data)
        guard version == Self.version else {
            throw PeelAudioPacketError.unsupportedVersion(version)
        }
        let kindRaw = Wire.byte(at: 5, in: data)
        guard let kind = PeelAudioPacketKind(rawValue: kindRaw) else {
            throw PeelAudioPacketError.unsupportedKind(kindRaw)
        }
        let directionRaw = Wire.byte(at: 6, in: data)
        guard let direction = PeelAudioPacketDirection(rawValue: directionRaw) else {
            throw PeelAudioPacketError.unsupportedDirection(directionRaw)
        }
        let flags = Wire.byte(at: 7, in: data)
        guard flags == 0 else {
            throw PeelAudioPacketError.unsupportedFlags(flags)
        }

        let declaredPayloadLength = Wire.readUInt32BE(at: 8, in: data)
        guard declaredPayloadLength <= Self.maxPayloadLength else {
            throw PeelAudioPacketError.payloadTooLarge(length: declaredPayloadLength,
                                                       maximum: Self.maxPayloadLength)
        }
        let expectedLength = Self.headerLength + Int(declaredPayloadLength)
        guard data.count == expectedLength else {
            throw PeelAudioPacketError.packetLengthMismatch(expected: expectedLength, actual: data.count)
        }

        let sequence = Wire.readUInt64BE(at: 12, in: data)
        let sampleTime = Int64(bitPattern: Wire.readUInt64BE(at: 20, in: data))
        guard sampleTime >= 0 else {
            throw PeelAudioPacketError.negativeSampleTime(sampleTime)
        }
        let sampleRate = Wire.readUInt32BE(at: 28, in: data)
        let frameCount = Wire.readUInt16BE(at: 32, in: data)
        let channels = Wire.byte(at: 34, in: data)
        let bytesPerSample = Wire.byte(at: 35, in: data)
        let payloadStart = data.index(data.startIndex, offsetBy: Self.headerLength)
        let payload = Data(data[payloadStart..<data.endIndex])

        try Self.validate(kind: kind,
                          direction: direction,
                          flags: flags,
                          sequence: sequence,
                          sampleTime: sampleTime,
                          sampleRate: sampleRate,
                          frameCount: frameCount,
                          channels: channels,
                          bytesPerSample: bytesPerSample,
                          payload: payload)
        return Self(validatedKind: kind,
                    direction: direction,
                    flags: flags,
                    sequence: sequence,
                    sampleTime: sampleTime,
                    sampleRate: sampleRate,
                    frameCount: frameCount,
                    channels: channels,
                    bytesPerSample: bytesPerSample,
                    payload: payload)
    }

    private init(
        validatedKind kind: PeelAudioPacketKind,
        direction: PeelAudioPacketDirection,
        flags: UInt8,
        sequence: UInt64,
        sampleTime: Int64,
        sampleRate: UInt32,
        frameCount: UInt16,
        channels: UInt8,
        bytesPerSample: UInt8,
        payload: Data
    ) {
        self.kind = kind
        self.direction = direction
        self.flags = flags
        self.sequence = sequence
        self.sampleTime = sampleTime
        self.sampleRate = sampleRate
        self.frameCount = frameCount
        self.channels = channels
        self.bytesPerSample = bytesPerSample
        self.payload = Data(payload)
    }

    private static func validate(
        kind: PeelAudioPacketKind,
        direction: PeelAudioPacketDirection,
        flags: UInt8,
        sequence: UInt64,
        sampleTime: Int64,
        sampleRate: UInt32,
        frameCount: UInt16,
        channels: UInt8,
        bytesPerSample: UInt8,
        payload: Data
    ) throws {
        guard flags == 0 else {
            throw PeelAudioPacketError.unsupportedFlags(flags)
        }
        guard sampleTime >= 0 else {
            throw PeelAudioPacketError.negativeSampleTime(sampleTime)
        }
        guard sampleRate == Self.sampleRate else {
            throw PeelAudioPacketError.unsupportedSampleRate(sampleRate)
        }
        guard bytesPerSample == Self.bytesPerSample else {
            throw PeelAudioPacketError.unsupportedBytesPerSample(bytesPerSample)
        }
        guard channels == direction.expectedChannelCount else {
            throw PeelAudioPacketError.invalidChannelCount(direction: direction, actual: channels)
        }
        guard payload.count <= Int(Self.maxPayloadLength) else {
            throw PeelAudioPacketError.payloadTooLarge(length: UInt32(clamping: payload.count),
                                                       maximum: Self.maxPayloadLength)
        }

        switch kind {
        case .format:
            guard sequence == 0 else {
                throw PeelAudioPacketError.nonZeroFormatSequence(sequence)
            }
            guard sampleTime == 0 else {
                throw PeelAudioPacketError.nonZeroFormatSampleTime(sampleTime)
            }
            guard frameCount == 0 else {
                throw PeelAudioPacketError.nonZeroFormatFrameCount(frameCount)
            }
            guard payload.isEmpty else {
                throw PeelAudioPacketError.nonEmptyFormatPayload(payload.count)
            }
        case .pcm:
            guard frameCount == Self.pcmFrameCount else {
                throw PeelAudioPacketError.invalidFrameCount(kind: .pcm, actual: frameCount)
            }
            let expectedPayloadLength = Int(frameCount) * Int(channels) * Int(bytesPerSample)
            guard payload.count == expectedPayloadLength else {
                throw PeelAudioPacketError.payloadLengthMismatch(expected: expectedPayloadLength,
                                                                  actual: payload.count)
            }
        }
    }

    /// Big-endian wire helpers deliberately index from a collection's startIndex.
    fileprivate enum Wire {
        static func byte(at offset: Int, in data: Data) -> UInt8 {
            data[data.index(data.startIndex, offsetBy: offset)]
        }

        static func readUInt16BE(at offset: Int, in data: Data) -> UInt16 {
            (UInt16(byte(at: offset, in: data)) << 8) |
            UInt16(byte(at: offset + 1, in: data))
        }

        static func readUInt32BE(at offset: Int, in data: Data) -> UInt32 {
            var value: UInt32 = 0
            for index in 0..<4 {
                value = (value << 8) | UInt32(byte(at: offset + index, in: data))
            }
            return value
        }

        static func readUInt64BE(at offset: Int, in data: Data) -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<8 {
                value = (value << 8) | UInt64(byte(at: offset + index, in: data))
            }
            return value
        }

        static func appendUInt16BE(_ value: UInt16, to data: inout Data) {
            data.append(UInt8((value >> 8) & 0xff))
            data.append(UInt8(value & 0xff))
        }

        static func appendUInt32BE(_ value: UInt32, to data: inout Data) {
            data.append(UInt8((value >> 24) & 0xff))
            data.append(UInt8((value >> 16) & 0xff))
            data.append(UInt8((value >> 8) & 0xff))
            data.append(UInt8(value & 0xff))
        }

        static func appendUInt64BE(_ value: UInt64, to data: inout Data) {
            data.append(UInt8((value >> 56) & 0xff))
            data.append(UInt8((value >> 48) & 0xff))
            data.append(UInt8((value >> 40) & 0xff))
            data.append(UInt8((value >> 32) & 0xff))
            data.append(UInt8((value >> 24) & 0xff))
            data.append(UInt8((value >> 16) & 0xff))
            data.append(UInt8((value >> 8) & 0xff))
            data.append(UInt8(value & 0xff))
        }
    }
}

/// Stateless convenience entry point for callers that prefer a codec namespace.
nonisolated public enum PeelAudioPacketCodec {
    public static func encode(_ packet: PeelAudioPacket) throws -> Data {
        try packet.encode()
    }

    public static func decode(_ data: Data) throws -> PeelAudioPacket {
        try PeelAudioPacket.decode(data)
    }
}

/// Incremental decoder for arbitrary TCP fragmentation and coalescing.
///
/// A parser is intentionally stateful and should be confined to the connection's
/// serial receive queue. Any protocol or resource-bound failure is terminal until
/// `reset()` is called.
nonisolated public struct PeelAudioPacketParser {
    public let expectedDirection: PeelAudioPacketDirection
    public let expectedFormat: PeelAudioPacketFormat

    private var buffer = Data()
    private var receivedFormat = false
    private var failedState = false

    public init(
        expectedDirection: PeelAudioPacketDirection,
        expectedFormat: PeelAudioPacketFormat? = nil
    ) {
        self.expectedDirection = expectedDirection
        self.expectedFormat = expectedFormat ?? .v1(for: expectedDirection)
    }

    public var isFailed: Bool { failedState }
    public var hasReceivedFormat: Bool { receivedFormat }
    public var bufferedByteCount: Int { buffer.count }

    /// Feeds bytes and returns all complete packets discovered in this call.
    public mutating func feed(_ data: Data) throws -> [PeelAudioPacket] {
        guard !failedState else {
            throw PeelAudioPacketError.parserFailed
        }
        guard !data.isEmpty else {
            return []
        }

        let currentCount = buffer.count
        let (combinedCount, overflow) = currentCount.addingReportingOverflow(data.count)
        guard !overflow, combinedCount <= PeelAudioPacket.maxAccumulatorBytes else {
            throw terminal(.accumulatorLimitExceeded(current: currentCount,
                                                      incoming: data.count,
                                                      maximum: PeelAudioPacket.maxAccumulatorBytes))
        }
        buffer.append(contentsOf: data)

        var packets: [PeelAudioPacket] = []
        while buffer.count >= PeelAudioPacket.headerLength {
            let declaredPayloadLength = PeelAudioPacket.Wire.readUInt32BE(at: 8, in: buffer)
            guard declaredPayloadLength <= PeelAudioPacket.maxPayloadLength else {
                throw terminal(.payloadTooLarge(length: declaredPayloadLength,
                                                maximum: PeelAudioPacket.maxPayloadLength))
            }
            let packetLength = PeelAudioPacket.headerLength + Int(declaredPayloadLength)
            guard buffer.count >= packetLength else {
                break
            }
            guard packets.count < PeelAudioPacket.maxPacketsPerFeed else {
                throw terminal(.feedPacketLimitExceeded(limit: PeelAudioPacket.maxPacketsPerFeed))
            }

            let packetData = Data(buffer.prefix(packetLength))
            let packet: PeelAudioPacket
            do {
                packet = try PeelAudioPacket.decode(packetData)
            } catch let error as PeelAudioPacketError {
                throw terminal(error)
            } catch {
                // The packet decoder only emits PeelAudioPacketError today, but
                // keep this parser's public failure type explicit if that changes.
                throw terminal(.packetLengthMismatch(expected: packetLength, actual: packetData.count))
            }
            buffer.removeFirst(packetLength)

            guard packet.direction == expectedDirection else {
                throw terminal(.unexpectedDirection(expected: expectedDirection,
                                                    actual: packet.direction))
            }
            guard packet.format == expectedFormat else {
                throw terminal(.formatMismatch(expected: expectedFormat, actual: packet.format))
            }

            switch packet.kind {
            case .format:
                receivedFormat = true
            case .pcm:
                guard receivedFormat else {
                    throw terminal(.pcmBeforeFormat)
                }
            }
            packets.append(packet)
        }
        return packets
    }

    /// Clears buffered bytes, negotiated format state, and terminal failure state.
    public mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
        receivedFormat = false
        failedState = false
    }

    private mutating func terminal(_ error: PeelAudioPacketError) -> PeelAudioPacketError {
        failedState = true
        receivedFormat = false
        buffer.removeAll(keepingCapacity: false)
        return error
    }
}
