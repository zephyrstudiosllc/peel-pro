import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
struct IconRendererLaneColorTests {
    @Test
    func `colored lanes preserve their tint and disable template rendering`() throws {
        let image = IconRenderer.makeIcon(
            primaryRemaining: 100,
            weeklyRemaining: 100,
            creditsRemaining: nil,
            stale: false,
            style: .codex,
            lanePresentation: .codexGrokBot,
            laneColors: IconRenderer.LaneColors(
                top: ProviderColor(hex: 0xFF0000),
                bottom: ProviderColor(hex: 0x00FF00)),
            quotaLayoutPolicy: .provider(.codex))
        let rep = try Self.bitmap(image)
        // NSBitmapImageRep exposes its rows top-down even though AppKit draws bottom-up.
        let top = try #require(rep.colorAt(x: 18, y: 11)?.usingColorSpace(.sRGB))
        let bottom = try #require(rep.colorAt(x: 18, y: 25)?.usingColorSpace(.sRGB))

        #expect(!image.isTemplate)
        #expect(top.redComponent > 0.9)
        #expect(top.greenComponent < 0.1)
        #expect(bottom.greenComponent > 0.9)
        #expect(bottom.redComponent < 0.1)
    }

    @Test
    func `lane colors participate in the icon cache key`() throws {
        let first = Self.icon(top: 0xFF0000, bottom: 0x00FF00)
        let second = Self.icon(top: 0x0000FF, bottom: 0xFFFF00)

        #expect(first !== second)
        let firstRep = try Self.bitmap(first)
        let secondRep = try Self.bitmap(second)
        let firstTop = try #require(firstRep.colorAt(x: 18, y: 11)?.usingColorSpace(.sRGB))
        let secondTop = try #require(secondRep.colorAt(x: 18, y: 11)?.usingColorSpace(.sRGB))
        #expect(firstTop.redComponent > firstTop.blueComponent)
        #expect(secondTop.blueComponent > secondTop.redComponent)
    }

    @Test
    func `uncolored lanes remain a monochrome template`() {
        let image = IconRenderer.makeIcon(
            primaryRemaining: 100,
            weeklyRemaining: 100,
            creditsRemaining: nil,
            stale: false,
            style: .codex,
            lanePresentation: .codexGrokBot,
            quotaLayoutPolicy: .provider(.codex))

        #expect(image.isTemplate)
    }

    private static func icon(top: UInt32, bottom: UInt32) -> NSImage {
        IconRenderer.makeIcon(
            primaryRemaining: 100,
            weeklyRemaining: 100,
            creditsRemaining: nil,
            stale: false,
            style: .codex,
            lanePresentation: .codexGrokBot,
            laneColors: IconRenderer.LaneColors(
                top: ProviderColor(hex: top),
                bottom: ProviderColor(hex: bottom)),
            quotaLayoutPolicy: .provider(.codex))
    }

    private static func bitmap(_ image: NSImage) throws -> NSBitmapImageRep {
        try #require(image.representations.compactMap { $0 as? NSBitmapImageRep }.first { rep in
            rep.pixelsWide == 36 && rep.pixelsHigh == 36
        })
    }
}
