// Bounded synthetic-output capture for a SEPARATE decode/quality check.
// These runs are labelled instrumented, not clean performance measurements.
private protocol BenchEncodedUnit {
    var codec: PeelVideoCodec { get }
    var width: Int { get }
    var height: Int { get }
    var isKeyframe: Bool { get }
    var pts: CMTime { get }
    var payload: Data { get }
    var vps: Data? { get }
    var sps: Data? { get }
    var pps: Data? { get }
    var nalUnitHeaderLength: Int32 { get }
}
extension VideoH264Encoder.EncodedAccessUnit: BenchEncodedUnit {}

private final class BenchEncodedCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private let width: Int
    private let height: Int
    private let sourceFPS: Int
    private let pixelFormat: String
    private var bytes = Data()
    private var frames: [[String: PeelLocalAgentJSONValue]] = []
    private var codec: String?
    private var failure: String?
    private var sealed = false
    private let maximumFrames = 32
    private let maximumBytes = 32 * 1024 * 1024

    init(directory: URL, width: Int, height: Int, sourceFPS: Int, pixelFormat: String) throws {
        self.directory = directory; self.width = width; self.height = height
        self.sourceFPS = sourceFPS; self.pixelFormat = pixelFormat
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw NSError(domain: "EncoderBench.CaptureDirectoryAlreadyExists", code: 1)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func record(_ unit: any BenchEncodedUnit) {
        lock.lock(); defer { lock.unlock() }
        guard !sealed, failure == nil, frames.count < maximumFrames else { return }
        let selected = unit.codec == .hevc ? "hevc" : "h264"
        guard codec == nil || codec == selected else { failure = "codec_changed_during_capture"; return }
        guard unit.width == width, unit.height == height, (1...4).contains(unit.nalUnitHeaderLength) else {
            failure = "unexpected_dimensions_or_nal_header"; return
        }
        if frames.isEmpty {
            guard unit.isKeyframe, unit.sps != nil, unit.pps != nil,
                  unit.codec != .hevc || unit.vps != nil else {
                failure = "first_output_missing_keyframe_or_configuration"; return
            }
        }
        let sourceIndex = CMTimeGetSeconds(unit.pts) * Double(sourceFPS)
        guard sourceIndex.isFinite, sourceIndex >= 0, sourceIndex <= 3600,
              abs(sourceIndex.rounded() - sourceIndex) < 0.001 else {
            failure = "unexpected_source_timestamp"; return
        }
        var annexB = Data()
        let startCode = Data([0, 0, 0, 1])
        for parameter in [unit.vps, unit.sps, unit.pps].compactMap({ $0 }) {
            annexB.append(startCode); annexB.append(parameter)
        }
        let payload = [UInt8](unit.payload)
        let header = Int(unit.nalUnitHeaderLength)
        var offset = 0
        while offset < payload.count {
            guard payload.count - offset >= header else { failure = "truncated_nal_header"; return }
            var length = 0
            for value in payload[offset..<(offset + header)] { length = (length << 8) | Int(value) }
            offset += header
            guard length > 0, length <= payload.count - offset else { failure = "invalid_nal_length"; return }
            annexB.append(startCode)
            annexB.append(contentsOf: payload[offset..<(offset + length)])
            offset += length
        }
        guard !annexB.isEmpty, bytes.count + annexB.count <= maximumBytes else {
            failure = "encoded_capture_byte_limit"; return
        }
        let index = Int64(sourceIndex.rounded())
        frames.append([
            "sourceFrameIndex": .integer(index), "patternPhase": .integer(index % 8),
            "keyframe": .bool(unit.isKeyframe), "ptsValue": .integer(unit.pts.value),
            "ptsTimescale": .integer(Int64(unit.pts.timescale)),
            "byteOffset": .integer(Int64(bytes.count)), "byteLength": .integer(Int64(annexB.count))
        ])
        bytes.append(annexB); codec = selected
    }

    func seal() -> PeelLocalAgentJSONValue {
        lock.lock(); defer { lock.unlock() }
        sealed = true
        let record: PeelLocalAgentJSONValue = .object([
            "scope": .string("synthetic_encoded_capture_not_streaming_acceptance"),
            "codec": codec.map(PeelLocalAgentJSONValue.string) ?? .null,
            "width": .integer(Int64(width)), "height": .integer(Int64(height)),
            "sourceFPS": .integer(Int64(sourceFPS)), "inputPixelFormat": .string(pixelFormat),
            "pattern": .string("eight_phase_moving_luma_bar_on_static_stripes"),
            "failure": failure.map(PeelLocalAgentJSONValue.string) ?? .null,
            "frameCount": .integer(Int64(frames.count)), "encodedBytes": .integer(Int64(bytes.count)),
            "frames": .array(frames.map(PeelLocalAgentJSONValue.object))
        ])
        do {
            try bytes.write(to: directory.appendingPathComponent("encoded.annexb"), options: .atomic)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(record).write(to: directory.appendingPathComponent("capture.json"), options: .atomic)
            return .object(["directory": .string(directory.path), "frames": .integer(Int64(frames.count)),
                "failure": failure.map(PeelLocalAgentJSONValue.string) ?? .null])
        } catch {
            return .object(["directory": .string(directory.path), "failure": .string("capture_write_failed")])
        }
    }
}
