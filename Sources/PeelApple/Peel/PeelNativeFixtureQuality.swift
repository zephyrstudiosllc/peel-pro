import Foundation
import CoreGraphics
import CoreImage
import CoreVideo
import AVFoundation

/// Called only with an explicit diagnostic fixture opt-in, at most once per two
/// seconds. A small native-scale crop avoids resampling and full-frame analysis.
nonisolated enum PeelNativeFixtureQuality {
    static func rgba(_ image: CGImage, x: Int, y: Int, width: Int, height: Int) -> [UInt8]? {
        guard width > 0, height > 0, width * height <= 32768,
              let crop = image.cropping(to: CGRect(x: x, y: y, width: width, height: height)),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let succeeded = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.interpolationQuality = .none
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return succeeded ? bytes : nil
    }

    static func measure(_ image: CGImage, now: Double = ProcessInfo.processInfo.systemUptime,
                        clock: PeelStreamClockTracker.Estimate? = nil,
                        stage: String = "spatialImageInspection") -> PeelFixtureQualityMetric? {
        measure(width: image.width, height: image.height, now: now, clock: clock, stage: stage) {
            rgba(image, x: $0, y: $1, width: $2, height: $3)
        }
    }

    static func measure(_ pixelBuffer: CVPixelBuffer, context: CIContext, now: Double,
                        clock: PeelStreamClockTracker.Estimate?) -> PeelFixtureQualityMetric? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        return measure(width: CVPixelBufferGetWidth(pixelBuffer), height: height,
                       now: now, clock: clock, stage: "displayLayerPixelObservation") { x, y, width, rows in
            // Core Image uses a bottom-left origin. Only these small crops are
            // converted; no second full-resolution decoder or image is created.
            guard let crop = context.createCGImage(image,
                from: CGRect(x: x, y: height - y - rows, width: width, height: rows)) else { return nil }
            return rgba(crop, x: 0, y: 0, width: width, height: rows)
        }
    }

    private static func measure(width: Int, height: Int, now: Double,
                                clock: PeelStreamClockTracker.Estimate?, stage: String,
                                read: (Int, Int, Int, Int) -> [UInt8]?) -> PeelFixtureQualityMetric? {
        guard width == PeelQualityFixture.width, height == PeelQualityFixture.height,
              let marker = read(0, 16, width, 1) else { return nil }
        let matched = stride(from: 7, to: width, by: 73).allSatisfy { position in
            let x = (position / 16) * 16 + 8
            let expected = PeelQualityFixture.rgb(x: x, y: 16)
            return abs(Int(marker[x * 4]) - expected.0) <= 32 &&
                abs(Int(marker[x * 4 + 1]) - expected.1) <= 32 &&
                abs(Int(marker[x * 4 + 2]) - expected.2) <= 32
        }
        guard matched else {
            return PeelFixtureQualityMetric(fixtureID: PeelQualityFixture.identifier,
                sampledAtClientUptimeSeconds: now, markerMatched: false, comparedPixels: 0,
                rgbPSNRDecibels: nil, lumaPSNRDecibels: nil, exactMatch: false)
        }
        let width = PeelQualityFixture.roiWidth
        let height = PeelQualityFixture.roiHeight
        guard let pixels = read(PeelQualityFixture.roiX, PeelQualityFixture.roiY, width, height) else { return nil }
        var rgbSquaredError: Double = 0
        var lumaSquaredError: Double = 0
        for y in 0..<height {
            for x in 0..<width {
                let expected = PeelQualityFixture.rgb(x: x + PeelQualityFixture.roiX, y: y + PeelQualityFixture.roiY)
                let index = (y * width + x) * 4
                let red = Double(pixels[index]) - Double(expected.0)
                let green = Double(pixels[index + 1]) - Double(expected.1)
                let blue = Double(pixels[index + 2]) - Double(expected.2)
                rgbSquaredError += red * red + green * green + blue * blue
                let luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
                lumaSquaredError += luma * luma
            }
        }
        let count = width * height
        func psnr(_ mse: Double) -> Double? {
            mse > 0 ? 10 * log10(255 * 255 / mse) : nil
        }
        var metric = PeelFixtureQualityMetric(fixtureID: PeelQualityFixture.identifier,
            sampledAtClientUptimeSeconds: now, markerMatched: true, comparedPixels: count,
            rgbPSNRDecibels: psnr(rgbSquaredError / Double(count * 3)),
            lumaPSNRDecibels: psnr(lumaSquaredError / Double(count)),
            exactMatch: rgbSquaredError == 0)
        metric.observationStage = stage
        if let stamp = read(0, 64, 2048, 16) {
            var bytes = [UInt8](repeating: 0, count: 16)
            for bit in 0..<128 {
                let index = (8 * 2048 + bit * 16 + 8) * 4
                if stamp[index] > 128 { bytes[bit / 8] |= 1 << (bit % 8) }
            }
            let micros = (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[$1]) << ($1 * 8) }
            let sequence = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[$1 + 8]) << ($1 * 8) }
            if bytes == PeelQualityFixture.stampBytes(microseconds: micros, sequence: sequence),
               micros > 0 {
                let source = Double(micros) / 1_000_000
                metric.fixtureFrameSequence = sequence; metric.sourceHostMediaSeconds = source
                if let timing = sourceTiming(sourceHostMediaSeconds: source, now: now, clock: clock) {
                    metric.sourceToObservationUpperBoundMilliseconds = timing.upperMilliseconds
                    metric.clockUncertaintyMilliseconds = timing.uncertaintyMilliseconds
                }
            }
        }
        return metric
    }

    /// Scalar timing boundary shared by real fixture observations and offline checks.
    static func sourceTiming(sourceHostMediaSeconds: Double, now: Double,
                             clock: PeelStreamClockTracker.Estimate?)
        -> (upperMilliseconds: Double, uncertaintyMilliseconds: Double)? {
        guard let clock, let bounds = clock.offsetBounds(at: now),
              let upper = clock.sourceAgeUpperBoundMilliseconds(
                sourceHostMediaSeconds: sourceHostMediaSeconds, at: now) else { return nil }
        return (upper, bounds.uncertaintyMilliseconds)
    }
}

nonisolated final class PeelDisplayLayerFixtureDiagnostics: @unchecked Sendable {
    /// Retaining a displayed buffer keeps its pool allocation alive. This lease
    /// is read-only and crosses only to this collector's serial utility queue.
    private final class PixelBufferLease: @unchecked Sendable {
        let value: CVPixelBuffer
        init(_ value: CVPixelBuffer) { self.value = value }
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "peel.displayLayer.fixture", qos: .utility)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var lastSampleAt: Double = 0
    private var inFlight = false
    private var quality: PeelFixtureQualityMetric?
    private var generation: UInt64 = 0
    var clock: PeelStreamClockTracker?

    func reset(generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        self.generation = generation; quality = nil
    }

    func sample(_ pixelBuffer: CVPixelBuffer, generation: UInt64) {
#if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--peel-quality-fixture-v1") else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard self.generation == generation, !inFlight, now - lastSampleAt >= 2 else { lock.unlock(); return }
        inFlight = true; lastSampleAt = now
        lock.unlock()
        let estimate = clock?.estimate(now: now)
        let lease = PixelBufferLease(pixelBuffer)
        queue.async { [weak self] in
            guard let self else { return }
            let result = PeelNativeFixtureQuality.measure(lease.value, context: self.context,
                                                          now: now, clock: estimate)
            self.lock.lock()
            self.inFlight = false
            self.quality = self.generation == generation ? result : nil
            self.lock.unlock()
        }
#endif
    }

    func snapshot() -> PeelFixtureQualityMetric? {
        lock.lock(); defer { lock.unlock() }
        guard let quality, ProcessInfo.processInfo.systemUptime - quality.sampledAtClientUptimeSeconds <= 5 else { return nil }
        return quality
    }
}
