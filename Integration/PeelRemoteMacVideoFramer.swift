import Foundation

/// Frames the existing compressed-video byte stream without decoding it.
///
/// The caller owns the connection lifecycle. A framing error is terminal for
/// that connection: callers should disconnect instead of trying to resync.
struct PeelRemoteMacVideoFramer {
    enum PacketKind: UInt8, Equatable {
        case videoConfig = 0x10
        case videoFrame = 0x11
        case hevcVideoConfig = 0x12
    }

    enum ConfigurationParameter: String, Equatable {
        case vps
        case sps
        case pps
    }

    enum FramingError: Swift.Error, Equatable, CustomStringConvertible {
        case inputChunkTooLarge(actual: Int, maximum: Int)
        case bufferLimitExceeded(current: Int, incoming: Int, maximum: Int)
        case unsupportedPacketKind(UInt8)
        case configurationParameterIsZero(kind: PacketKind, parameter: ConfigurationParameter)
        case configurationParameterTooLarge(
            kind: PacketKind,
            parameter: ConfigurationParameter,
            actual: UInt32,
            maximum: Int
        )
        case framePayloadIsZero
        case framePayloadTooLarge(actual: UInt32, maximum: Int)

        var description: String {
            switch self {
            case let .inputChunkTooLarge(actual, maximum):
                return "Video input chunk is \(actual) bytes; maximum is \(maximum)."
            case let .bufferLimitExceeded(current, incoming, maximum):
                return "Video framer buffer would grow from \(current) by \(incoming) bytes past \(maximum)."
            case let .unsupportedPacketKind(kind):
                return String(format: "Unsupported video packet kind 0x%02X.", kind)
            case let .configurationParameterIsZero(kind, parameter):
                return "\(kind) has a zero-length \(parameter.rawValue) parameter set."
            case let .configurationParameterTooLarge(kind, parameter, actual, maximum):
                return "\(kind) \(parameter.rawValue) is \(actual) bytes; maximum is \(maximum)."
            case .framePayloadIsZero:
                return "Video frame payload must be positive."
            case let .framePayloadTooLarge(actual, maximum):
                return "Video frame payload is \(actual) bytes; maximum is \(maximum)."
            }
        }
    }

    /// The largest encoded frame payload accepted by the existing wire.
    static let maximumFramePayloadBytes = 8 * 1024 * 1024

    /// Each H.264/HEVC VPS, SPS, and PPS length is bounded independently.
    static let maximumParameterSetBytes = 64 * 1024

    /// The viewer's single Network.framework video read size (Apple client: 256 KiB).
    static let maximumInputChunkBytes = 256 * 1024

    /// Keep one receive chunk of headroom while a maximum-size frame is partial.
    static let maximumBufferedBytes = maximumFramePayloadBytes + maximumInputChunkBytes

    private var buffer = Data()

    init() {}

    var bufferedByteCount: Int { buffer.count }

    /// Appends arbitrary stream fragments and returns every complete packet.
    ///
    /// Packet boundaries are taken from the protocol's little-endian length
    /// fields. Unknown kinds and invalid declared lengths throw without any
    /// resynchronization attempt.
    mutating func append(_ data: Data) throws -> [Data] {
        guard !data.isEmpty else { return [] }
        guard data.count <= Self.maximumInputChunkBytes else {
            throw FramingError.inputChunkTooLarge(
                actual: data.count,
                maximum: Self.maximumInputChunkBytes
            )
        }
        guard buffer.count <= Self.maximumBufferedBytes - data.count else {
            throw FramingError.bufferLimitExceeded(
                current: buffer.count,
                incoming: data.count,
                maximum: Self.maximumBufferedBytes
            )
        }

        buffer.append(data)
        var packets: [Data] = []

        while let firstByte = buffer.first {
            guard let kind = PacketKind(rawValue: firstByte) else {
                throw FramingError.unsupportedPacketKind(firstByte)
            }

            let packetLength: Int
            switch kind {
            case .videoConfig, .hevcVideoConfig:
                let headerLength = kind == .hevcVideoConfig ? 31 : 27
                guard buffer.count >= headerLength else { return packets }

                let parameterLengths: [(ConfigurationParameter, UInt32)]
                if kind == .hevcVideoConfig {
                    parameterLengths = [
                        (.vps, readUInt32LE(at: 19)),
                        (.sps, readUInt32LE(at: 23)),
                        (.pps, readUInt32LE(at: 27)),
                    ]
                } else {
                    parameterLengths = [
                        (.sps, readUInt32LE(at: 19)),
                        (.pps, readUInt32LE(at: 23)),
                    ]
                }

                var bodyLength = 0
                for (parameter, rawLength) in parameterLengths {
                    guard rawLength > 0 else {
                        throw FramingError.configurationParameterIsZero(
                            kind: kind,
                            parameter: parameter
                        )
                    }
                    guard rawLength <= UInt32(Self.maximumParameterSetBytes) else {
                        throw FramingError.configurationParameterTooLarge(
                            kind: kind,
                            parameter: parameter,
                            actual: rawLength,
                            maximum: Self.maximumParameterSetBytes
                        )
                    }
                    bodyLength += Int(rawLength)
                }
                packetLength = headerLength + bodyLength

            case .videoFrame:
                let headerLength = 26
                guard buffer.count >= headerLength else { return packets }
                let rawLength = readUInt32LE(at: 22)
                guard rawLength > 0 else { throw FramingError.framePayloadIsZero }
                guard rawLength <= UInt32(Self.maximumFramePayloadBytes) else {
                    throw FramingError.framePayloadTooLarge(
                        actual: rawLength,
                        maximum: Self.maximumFramePayloadBytes
                    )
                }
                packetLength = headerLength + Int(rawLength)
            }

            guard buffer.count >= packetLength else { return packets }
            packets.append(Data(buffer.prefix(packetLength)))
            buffer.removeSubrange(0..<packetLength)
        }

        return packets
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
    }

    private func readUInt32LE(at offset: Int) -> UInt32 {
        UInt32(buffer[offset]) |
            (UInt32(buffer[offset + 1]) << 8) |
            (UInt32(buffer[offset + 2]) << 16) |
            (UInt32(buffer[offset + 3]) << 24)
    }
}
