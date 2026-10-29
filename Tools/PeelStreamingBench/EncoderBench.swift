// Appended to the exact production encoder by run-encoder-bench.py.
// Synthetic frames only: no ScreenCaptureKit, TCC, pairing, UI, or network.
@main
struct EncoderBench {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 8, let width = Int(args[1]), let height = Int(args[2]),
              let fps = Int(args[3]), let seconds = Double(args[4]),
              [1920, 2560, 3840, 5120].contains(width),
              [1080, 1440, 2160, 2880].contains(height),
              [30, 60, 120].contains(fps), (2...30).contains(seconds),
              ["hevc", "h264"].contains(args[5]), ["nv12", "bgra"].contains(args[6]) else {
            fatalError("width height fps durationSeconds hevc|h264 nv12|bgra")
        }
        let diagnostics = PeelStreamingDiagnostics()
        let capture = args[7] == "-" ? nil : try BenchEncodedCapture(directory: URL(fileURLWithPath: args[7]),
            width: width, height: height, sourceFPS: fps, pixelFormat: args[6])
        let encoder = VideoH264Encoder(windowId: 1, width: width, height: height,
            bitRate: 100_000_000, fps: fps, preferredCodec: args[5] == "hevc" ? .hevc : .h264,
            teardownQueue: DispatchQueue(label: "peel.bench.teardown"), diagnostics: diagnostics)
        encoder.onOutput = { capture?.record($0) }
        let buffers = try (0..<8).map { phase in
            var result: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                args[6] == "nv12" ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result)
            guard status == kCVReturnSuccess, let buffer = result else {
                throw NSError(domain: "EncoderBench.PixelBuffer", code: Int(status))
            }
            // Production capture applies this before encoding. Format descriptions
            // must include it before a cached pixel buffer is reused by the fixture.
            VideoColorMetadata.applyRec709FullRange(to: buffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            if args[6] == "bgra" {
                guard let base = CVPixelBufferGetBaseAddress(buffer) else {
                    throw NSError(domain: "EncoderBench.BaseAddress", code: 1)
                }
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                for y in 0..<height {
                    let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
                    row.initialize(repeating: (y / 32).isMultiple(of: 2) ? 0xff303030 : 0xff606060, count: width)
                    let x = phase * (width - 128) / 7
                    row.advanced(by: x).initialize(repeating: 0xffdcdcdc, count: 128)
                }
                return buffer
            }
            guard let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
                  let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else {
                throw NSError(domain: "EncoderBench.Planes", code: 1)
            }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            for y in 0..<height {
                let row = luma.advanced(by: y * stride)
                memset(row, (y / 32).isMultiple(of: 2) ? 48 : 96, width)
                let x = phase * (width - 128) / 7
                memset(row.advanced(by: x), 220, 128)
            }
            memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * height / 2)
            return buffer
        }
        var format: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: buffers[0], formatDescriptionOut: &format)
        guard formatStatus == noErr, let format else {
            throw NSError(domain: "EncoderBench.Format", code: Int(formatStatus))
        }
        let source = BenchSource(encoder: encoder, diagnostics: diagnostics, buffers: buffers,
            format: format, fps: fps, seconds: seconds, pixelFormat: args[6], capture: capture)
        source.run()
        guard source.finished.wait(timeout: .now() + seconds + 5) == .success else {
            throw NSError(domain: "EncoderBench.Timeout", code: 1)
        }
        encoder.invalidateAsync()
    }
}

private final class BenchSource: @unchecked Sendable {
    let finished = DispatchSemaphore(value: 0)
    private let queue = DispatchQueue(label: "peel.bench.source", qos: .userInteractive)
    private let encoder: VideoH264Encoder
    private let diagnostics: PeelStreamingDiagnostics
    private let buffers: [CVPixelBuffer]
    private let format: CMVideoFormatDescription
    private let fps: Int
    private let seconds: Double
    private let pixelFormat: String
    private let capture: BenchEncodedCapture?
    private var timer: DispatchSourceTimer?
    private var index: Int64 = 0
    private var start: Double = 0
    private var sampleFailures = 0

    init(encoder: VideoH264Encoder, diagnostics: PeelStreamingDiagnostics, buffers: [CVPixelBuffer],
         format: CMVideoFormatDescription, fps: Int, seconds: Double, pixelFormat: String, capture: BenchEncodedCapture?) {
        self.encoder = encoder; self.diagnostics = diagnostics; self.buffers = buffers
        self.format = format; self.fps = fps; self.seconds = seconds
        self.pixelFormat = pixelFormat
        self.capture = capture
    }

    func run() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        start = ProcessInfo.processInfo.systemUptime
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / fps), leeway: .microseconds(100))
        timer.setEventHandler { [self] in
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            if elapsed >= seconds {
                timer.cancel()
                self.timer = nil
                var report: [String: PeelLocalAgentJSONValue] = [
                    "scope": .string("synthetic_production_encoder_only"),
                    "pattern": .string("eight_phase_moving_luma_bar_on_static_stripes"),
                    "inputPixelFormat": .string(pixelFormat),
                    "sourceFramesOffered": .integer(index),
                    "sourceElapsedSeconds": .number(elapsed),
                    "sourceOfferedFPS": .number(Double(index) / elapsed),
                    "sampleBufferFailures": .integer(Int64(sampleFailures)),
                    "hostEncoder": diagnostics.snapshot(),
                    "isEndToEndStreamingAcceptance": .bool(false)
                ]
                report["instrumentedOutputCapture"] = .bool(capture != nil)
                if let capture { report["outputCapture"] = capture.seal() }
                report["thermalState"] = .integer(Int64(ProcessInfo.processInfo.thermalState.rawValue))
                let json = JSONEncoder()
                json.outputFormatting = [.sortedKeys]
                if let data = try? json.encode(PeelLocalAgentJSONValue.object(report)),
                   let text = String(data: data, encoding: .utf8) { print(text) }
                finished.signal()
                return
            }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(fps)),
                presentationTimeStamp: CMTime(value: index, timescale: Int32(fps)), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            let status = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                imageBuffer: buffers[Int(index % Int64(buffers.count))], formatDescription: format,
                sampleTiming: &timing, sampleBufferOut: &sample)
            if status == noErr, let sample {
                encoder.encodeAsync(sampleBuffer: sample, forceKeyframe: index == 0)
            } else { sampleFailures += 1 }
            index += 1
        }
        timer.resume()
    }
}
