import Foundation

typealias Framer = PeelRemoteMacVideoFramer
typealias FramingError = Framer.FramingError

private func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) {
    precondition(condition(), message)
}

private func expectError(
    _ expected: FramingError,
    _ operation: () throws -> Void,
    _ message: String
) {
    do {
        try operation()
        preconditionFailure("\(message): expected \(expected), but no error was thrown")
    } catch let error as FramingError {
        require(error == expected, "\(message): got \(error), expected \(expected)")
    } catch {
        preconditionFailure("\(message): got unexpected error \(error)")
    }
}

private func littleEndian32(_ value: UInt32) -> Data {
    Data([
        UInt8(truncatingIfNeeded: value),
        UInt8(truncatingIfNeeded: value >> 8),
        UInt8(truncatingIfNeeded: value >> 16),
        UInt8(truncatingIfNeeded: value >> 24),
    ])
}

private func littleEndian64(_ value: Int64) -> Data {
    let raw = UInt64(bitPattern: value)
    var result = Data()
    result.reserveCapacity(8)
    for shift in stride(from: 0, through: 56, by: 8) {
        result.append(UInt8(truncatingIfNeeded: raw >> UInt64(shift)))
    }
    return result
}

private func makeConfig(
    kind: UInt8,
    windowId: UInt32,
    vps: Data? = nil,
    sps: Data,
    pps: Data
) -> Data {
    var result = Data([kind])
    result.append(littleEndian32(windowId))
    result.append(kind == Framer.PacketKind.hevcVideoConfig.rawValue ? 2 : 1)
    result.append(littleEndian32(1920))
    result.append(littleEndian32(1080))
    result.append(littleEndian32(600))
    result.append(4)
    if kind == Framer.PacketKind.hevcVideoConfig.rawValue {
        result.append(littleEndian32(UInt32(vps?.count ?? 0)))
    }
    result.append(littleEndian32(UInt32(sps.count)))
    result.append(littleEndian32(UInt32(pps.count)))
    if kind == Framer.PacketKind.hevcVideoConfig.rawValue, let vps {
        result.append(vps)
    }
    result.append(sps)
    result.append(pps)
    return result
}

private func makeFrame(
    windowId: UInt32,
    isKeyframe: Bool,
    pts: Int64,
    duration: Int64,
    payload: Data
) -> Data {
    var result = Data([Framer.PacketKind.videoFrame.rawValue])
    result.append(littleEndian32(windowId))
    result.append(isKeyframe ? 1 : 0)
    result.append(littleEndian64(pts))
    result.append(littleEndian64(duration))
    result.append(littleEndian32(UInt32(payload.count)))
    result.append(payload)
    return result
}

private func makeFrameHeader(windowId: UInt32, payloadLength: UInt32) -> Data {
    var result = Data([Framer.PacketKind.videoFrame.rawValue])
    result.append(littleEndian32(windowId))
    result.append(1)
    result.append(littleEndian64(1))
    result.append(littleEndian64(1))
    result.append(littleEndian32(payloadLength))
    return result
}

private func append(
    _ data: Data,
    to framer: inout Framer,
    _ message: String
) -> [Data] {
    do {
        return try framer.append(data)
    } catch {
        preconditionFailure("\(message): unexpected \(error)")
    }
}

let windowId: UInt32 = 0x1234_5678
let config = makeConfig(
    kind: Framer.PacketKind.videoConfig.rawValue,
    windowId: windowId,
    sps: Data([0x67, 0x42, 0x00]),
    pps: Data([0x68, 0xCE])
)
let frame = makeFrame(
    windowId: windowId,
    isKeyframe: true,
    pts: 0x0102_0304_0506_0708,
    duration: 600,
    payload: Data([0x00, 0x00, 0x01, 0x65, 0xAA])
)

// A config split at the header boundary and again inside its parameter body.
var fragmented = Framer()
var fragmentedPackets: [Data] = []
var cursor = 0
for end in [1, 7, 27, config.count] {
    let part = Data(config[cursor..<end])
    let packets = append(part, to: &fragmented, "fragmented config")
    if end < config.count {
        require(packets.isEmpty, "a partial config must not be emitted")
    }
    fragmentedPackets.append(contentsOf: packets)
    cursor = end
}
require(fragmentedPackets == [config], "fragmented config must emit one exact packet")

// Config and frame in one receive callback must be emitted in wire order.
var coalesced = Framer()
var configAndFrame = config
configAndFrame.append(frame)
require(
    append(configAndFrame, to: &coalesced, "coalesced config/frame") == [config, frame],
    "coalesced config and frame must preserve packet order"
)

// A complete config followed by the last byte of a frame leaves only the
// trailing packet partial; the final byte completes it.
var trailing = Framer()
var configAndPartialFrame = config
configAndPartialFrame.append(frame.dropLast())
require(
    append(configAndPartialFrame, to: &trailing, "trailing partial frame") == [config],
    "trailing partial frame must remain buffered"
)
require(
    append(Data(frame.suffix(1)), to: &trailing, "trailing frame completion") == [frame],
    "trailing partial frame must complete on the next append"
)

// HEVC has the additional VPS length and body, and remains independently framed.
let hevcConfig = makeConfig(
    kind: Framer.PacketKind.hevcVideoConfig.rawValue,
    windowId: windowId,
    vps: Data([0x40, 0x01]),
    sps: Data([0x42, 0x01, 0x01]),
    pps: Data([0x44, 0x01])
)
var hevc = Framer()
require(append(hevcConfig, to: &hevc, "HEVC config") == [hevcConfig], "HEVC config must frame with VPS")

// The fixture constructs fields independently, so these checks catch an
// accidental big-endian length or window interpretation.
require(
    Data(config[1..<5]) == Data([0x78, 0x56, 0x34, 0x12]),
    "config window ID fixture must be little-endian"
)
require(
    Data(frame[22..<26]) == Data([0x05, 0x00, 0x00, 0x00]),
    "frame payload length fixture must be little-endian"
)
var endian = Framer()
require(append(frame, to: &endian, "little-endian frame") == [frame], "little-endian frame must be accepted")
var bigEndianLength = frame
bigEndianLength.replaceSubrange(22..<26, with: [0x00, 0x00, 0x00, 0x05])
var endianRejecting = Framer()
expectError(
    .framePayloadTooLarge(actual: 83_886_080, maximum: Framer.maximumFramePayloadBytes),
    { _ = try endianRejecting.append(Data(bigEndianLength.prefix(26))) },
    "big-endian payload length must fail closed"
)

var unknown = Framer()
expectError(
    .unsupportedPacketKind(0x02),
    { _ = try unknown.append(Data([0x02])) },
    "legacy JPEG and unknown kinds must not be silently resynchronized"
)
require(unknown.bufferedByteCount == 1, "unknown kind must remain terminally buffered")
expectError(
    .unsupportedPacketKind(0x02),
    { _ = try unknown.append(frame) },
    "a later valid packet must not resynchronize past an unknown kind"
)

let zeroConfig = makeConfig(
    kind: Framer.PacketKind.videoConfig.rawValue,
    windowId: windowId,
    sps: Data(),
    pps: Data([0x01])
)
var zeroConfigFramer = Framer()
expectError(
    .configurationParameterIsZero(kind: .videoConfig, parameter: .sps),
    { _ = try zeroConfigFramer.append(Data(zeroConfig.prefix(27))) },
    "zero-length SPS must fail closed"
)

let oversizedSPS = makeConfig(
    kind: Framer.PacketKind.videoConfig.rawValue,
    windowId: windowId,
    sps: Data(repeating: 0x01, count: Framer.maximumParameterSetBytes + 1),
    pps: Data([0x02])
)
var oversizedConfigFramer = Framer()
expectError(
    .configurationParameterTooLarge(
        kind: .videoConfig,
        parameter: .sps,
        actual: UInt32(Framer.maximumParameterSetBytes + 1),
        maximum: Framer.maximumParameterSetBytes
    ),
    { _ = try oversizedConfigFramer.append(Data(oversizedSPS.prefix(27))) },
    "oversized SPS must fail before its body is buffered"
)

var zeroFrameFramer = Framer()
expectError(
    .framePayloadIsZero,
    { _ = try zeroFrameFramer.append(makeFrameHeader(windowId: windowId, payloadLength: 0)) },
    "zero-length frame must fail closed"
)

var oversizedFrameFramer = Framer()
let oversizedFrameLength = UInt32(Framer.maximumFramePayloadBytes + 1)
expectError(
    .framePayloadTooLarge(actual: oversizedFrameLength, maximum: Framer.maximumFramePayloadBytes),
    { _ = try oversizedFrameFramer.append(makeFrameHeader(windowId: windowId, payloadLength: oversizedFrameLength)) },
    "oversized frame must fail before its body is buffered"
)

var oversizedInputFramer = Framer()
expectError(
    .inputChunkTooLarge(
        actual: Framer.maximumInputChunkBytes + 1,
        maximum: Framer.maximumInputChunkBytes
    ),
    { _ = try oversizedInputFramer.append(Data(repeating: 0, count: Framer.maximumInputChunkBytes + 1)) },
    "an oversized receive chunk must be rejected"
)
require(oversizedInputFramer.bufferedByteCount == 0, "rejected input chunk must not be retained")

unknown.reset()
require(append(frame, to: &unknown, "reset frame") == [frame], "reset must make a framer reusable")

print("PeelRemoteMacVideoFramerChecks: PASS")
