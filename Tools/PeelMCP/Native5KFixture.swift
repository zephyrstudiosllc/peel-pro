import AppKit
import ImageIO
import UniformTypeIdentifiers
import CoreMedia
import CoreVideo
import CoreImage

private func makeImage(damage: Bool = false, marker: Bool = true, markerEdgeNoise: Bool = false,
                       stamp: (microseconds: UInt64, sequence: UInt32)? = nil) -> CGImage {
    let width = PeelQualityFixture.width, height = PeelQualityFixture.height
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let rgb = PeelQualityFixture.rgb(x: x, y: y)
            let index = (y * width + x) * 4
            let damaged = damage && (PeelQualityFixture.roiX..<PeelQualityFixture.roiX + 128).contains(x)
                && (PeelQualityFixture.roiY..<PeelQualityFixture.roiY + PeelQualityFixture.roiHeight).contains(y)
            bytes[index] = UInt8(damaged ? 128 : rgb.0)
            bytes[index + 1] = UInt8(damaged ? 128 : rgb.1)
            bytes[index + 2] = UInt8(damaged ? 128 : rgb.2)
            if !marker && (y < 32 || y >= height - 32) {
                bytes[index] = 0; bytes[index + 1] = 0; bytes[index + 2] = 0
            }
            if markerEdgeNoise && (y < 32 || y >= height - 32) && (x % 16 == 0 || x % 16 == 15) {
                bytes[index] = 128; bytes[index + 1] = 128; bytes[index + 2] = 128
            }
        }
    }
    if let stamp {
        let encoded = PeelQualityFixture.stampBytes(microseconds: stamp.microseconds, sequence: stamp.sequence)
        for bit in 0..<128 {
            let value: UInt8 = encoded[bit / 8] & (1 << (bit % 8)) == 0 ? 16 : 240
            for baseY in [64, height - 80] {
                for y in baseY..<baseY + 16 {
                    for x in bit * 16..<bit * 16 + 16 {
                        let index = (y * width + x) * 4
                        bytes[index] = value; bytes[index + 1] = value; bytes[index + 2] = value
                    }
                }
            }
        }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue |
            CGBitmapInfo.byteOrder32Big.rawValue), provider: provider, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent)!
}

@MainActor
private final class FixtureView: NSView {
    let image: CGImage
    var sequence: UInt32 = 0
    var displayLink: CADisplayLink?
    init(image: CGImage, frame: CGRect) { self.image = image; super.init(frame: frame) }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .none
        context.draw(image, in: bounds)
        let seconds = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        let stamp = PeelQualityFixture.stampBytes(microseconds: UInt64(seconds * 1_000_000), sequence: sequence)
        let scale = bounds.width / Double(PeelQualityFixture.width)
        for bit in 0..<128 {
            let white = stamp[bit / 8] & (1 << (bit % 8)) != 0
            context.setFillColor(CGColor(gray: white ? 240.0 / 255 : 16.0 / 255, alpha: 1))
            for y in [64, PeelQualityFixture.height - 80] {
                context.fill(CGRect(x: Double(bit * 16) * scale, y: Double(y) * scale,
                                    width: 16 * scale, height: 16 * scale))
            }
        }
        // A changing block outside the measured ROI makes each source update
        // distinct without contaminating the static quality reference.
        context.setFillColor(CGColor(gray: sequence & 1 == 0 ? 0.1 : 0.9, alpha: 1))
        context.fill(CGRect(x: 2100 * scale, y: 200 * scale, width: 128 * scale, height: 128 * scale))
    }
    @objc func tick(_ link: CADisplayLink) {
        sequence &+= 1
        needsDisplay = true
    }
}

@main
struct Native5KFixture {
    @MainActor static func main() throws {
        let args = CommandLine.arguments
        if args.contains("--self-test") {
            let exact = PeelNativeFixtureQuality.measure(makeImage())!
            precondition(exact.isValid && exact.markerMatched && exact.exactMatch)
            let damaged = PeelNativeFixtureQuality.measure(makeImage(damage: true))!
            precondition(damaged.isValid && damaged.markerMatched && !damaged.exactMatch)
            precondition(damaged.lumaPSNRDecibels! < 20)
            let unknown = PeelNativeFixtureQuality.measure(makeImage(marker: false))!
            precondition(unknown.isValid && !unknown.markerMatched && unknown.comparedPixels == 0)
            let noisyMarker = PeelNativeFixtureQuality.measure(makeImage(markerEdgeNoise: true))!
            precondition(noisyMarker.markerMatched && noisyMarker.exactMatch)
            let stamp = PeelNativeFixtureQuality.measure(makeImage(stamp: (123_456_789, 90)))!
            precondition(stamp.fixtureFrameSequence == 90 && stamp.sourceHostMediaSeconds == 123.456789)
            var buffer: CVPixelBuffer?
            precondition(CVPixelBufferCreate(nil, 5120, 2880, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferCGImageCompatibilityKey: true,
                 kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer) == kCVReturnSuccess)
            let pixelBuffer = buffer!
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: 5120, height: 2880,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            context.draw(makeImage(stamp: (123_456_789, 90)), in: CGRect(x: 0, y: 0, width: 5120, height: 2880))
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            let observed = PeelNativeFixtureQuality.measure(pixelBuffer, context: CIContext(),
                now: 100, clock: nil)!
            precondition(observed.markerMatched && observed.fixtureFrameSequence == 90)
            precondition(observed.exactMatch)
            print("Native quality checks passed: exact reference, lost pixel detail, unknown fixture, timestamp checksum, native CVPixelBuffer crops")
            return
        }
        if let flag = args.firstIndex(of: "--write-png"), flag + 1 < args.count {
            let url = URL(fileURLWithPath: args[flag + 1])
            guard !FileManager.default.fileExists(atPath: url.path) else { fatalError("Output already exists") }
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { fatalError("Cannot create fixture output") }
            CGImageDestinationAddImage(destination, makeImage(), nil)
            guard CGImageDestinationFinalize(destination) else { fatalError("Cannot save fixture") }
            return
        }
        guard let flag = args.firstIndex(of: "--display-id"), flag + 1 < args.count,
              let id = UInt32(args[flag + 1]),
              let mode = CGDisplayCopyDisplayMode(id),
              mode.pixelWidth == 5120, mode.pixelHeight == 2880, mode.refreshRate >= 89.9,
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
              }) else {
            print("Requires --display-id of an existing 5120x2880 display at 90 Hz or above. No display settings were changed.")
            return
        }
        // Device-lane owner runs this only on the dedicated virtual screen.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                              backing: .buffered, defer: false, screen: screen)
        window.isReleasedWhenClosed = false
        // This dedicated test screen must not have menu-bar pixels covering the
        // reference marker. The bounded fixture owns only its exact screen.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        window.title = "Peel 5K Native Quality Fixture"
        let view = FixtureView(image: makeImage(), frame: CGRect(origin: .zero, size: screen.frame.size))
        window.contentView = view
        let backing = view.convertToBacking(view.bounds)
        guard abs(backing.width - 5120) < 0.5, abs(backing.height - 2880) < 0.5 else {
            print("Virtual screen backing raster does not match 5120x2880."); return
        }
        let link = screen.displayLink(target: view, selector: #selector(FixtureView.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 90, maximum: 90, preferred: 90)
        view.displayLink = link
        link.add(to: .main, forMode: .common)
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        print("Native fixture: display \(id), \(mode.pixelWidth)x\(mode.pixelHeight), \(mode.refreshRate) Hz, requested display-link cadence 90. Timestamped changing content; delivered cadence still requires receiver evidence.")
        Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { _ in
            MainActor.assumeIsolated { view.displayLink?.invalidate(); window.close(); app.terminate(nil) }
        }
        app.run()
    }
}
