import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusItemCodexGrokBotStackTests {
    @Test
    func `stack maps codex above grok bot for used and remaining modes`() throws {
        let (_, _, controller) = self.makeController(
            suiteName: "StatusItemCodexGrokBotStackTests-values",
            grokBotUsed: 5)
        defer { controller.releaseStatusItemsForTesting() }

        let used = try #require(controller.codexGrokBotMenuBarStackValues(showUsed: true))
        #expect(used == CodexGrokBotMenuBarStackValues(codex: 40, grokBot: 5))

        let remaining = try #require(controller.codexGrokBotMenuBarStackValues(showUsed: false))
        #expect(remaining == CodexGrokBotMenuBarStackValues(codex: 60, grokBot: 95))
    }

    @Test
    func `merged icon fixes codex and grok bot lanes and observes grok changes`() throws {
        let (_, store, controller) = self.makeController(
            suiteName: "StatusItemCodexGrokBotStackTests-render",
            grokBotUsed: 5)
        defer { controller.releaseStatusItemsForTesting() }

        let baselineObservation = controller.storeIconObservationSignature()
        controller.applyIcon(phase: nil)

        let renderSignature = try #require(controller.lastAppliedMergedIconRenderSignature)
        #expect(renderSignature.contains("provider=codex"))
        #expect(renderSignature.contains("primary=40.000"))
        #expect(renderSignature.contains("weekly=5.000"))
        #expect(renderSignature.contains("lanes=codex-grok-bot"))
        #expect(renderSignature.contains("laneColors=#49A3B0,#00BFA5"))
        #expect(controller.statusItem.button?.image?.isTemplate == false)
        #expect(controller.statusItem.button?.accessibilityTitle()?.contains("Grok Bot 5% used") == true)

        store._setSnapshotForTesting(Self.cursorSnapshot(grokBotUsed: 12), provider: .cursor)
        #expect(controller.storeIconObservationSignature() != baselineObservation)
    }

    @Test
    func `merged icon fill shows consumed usage while title can show remaining capacity`() throws {
        let (settings, _, controller) = self.makeController(
            suiteName: "StatusItemCodexGrokBotStackTests-consumed-fill",
            grokBotUsed: 5)
        defer { controller.releaseStatusItemsForTesting() }
        settings.usageBarsShowUsed = false

        controller.applyIcon(phase: nil)

        let renderSignature = try #require(controller.lastAppliedMergedIconRenderSignature)
        #expect(renderSignature.contains("primary=40.000"))
        #expect(renderSignature.contains("weekly=5.000"))
        #expect(controller.statusItem.button?.accessibilityTitle()?.contains("Codex 60% remaining") == true)
        #expect(controller.statusItem.button?.accessibilityTitle()?.contains("Grok Bot 95% remaining") == true)
    }

    @Test
    func `lane colors follow codex and grok bot dropdown accent overrides`() throws {
        let (settings, _, controller) = self.makeController(
            suiteName: "StatusItemCodexGrokBotStackTests-colors",
            grokBotUsed: 5)
        defer { controller.releaseStatusItemsForTesting() }

        #expect(controller.codexGrokBotMenuBarLaneColors() == IconRenderer.LaneColors(
            top: ProviderColor(hex: 0x49A3B0),
            bottom: ProviderColor(hex: 0x00BFA5)))

        settings.setAccentColorOverride(ProviderColor(hex: 0xA56CC1), for: .codex)
        settings.setAccentColorOverride(ProviderColor(hex: 0xE8A64A), for: .cursor)
        controller.applyIcon(phase: nil)

        #expect(controller.codexGrokBotMenuBarLaneColors() == IconRenderer.LaneColors(
            top: ProviderColor(hex: 0xA56CC1),
            bottom: ProviderColor(hex: 0xE8A64A)))
        let renderSignature = try #require(controller.lastAppliedMergedIconRenderSignature)
        #expect(renderSignature.contains("laneColors=#A56CC1,#E8A64A"))
    }

    private func makeController(
        suiteName: String,
        grokBotUsed: Double)
        -> (SettingsStore, UsageStore, StatusItemController)
    {
        let settings = testSettingsStore(suiteName: suiteName)
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.menuBarShowsBrandIconWithPercent = false
        settings.menuBarShowsHighestUsage = true
        settings.usageBarsShowUsed = true

        let registry = ProviderRegistry.shared
        if let codex = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codex, enabled: true)
        }
        if let cursor = registry.metadata[.cursor] {
            settings.setProviderEnabled(provider: .cursor, metadata: cursor, enabled: true)
        }
        if let claude = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claude, enabled: false)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 40,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 80,
                    windowMinutes: 10080,
                    resetsAt: nil,
                    resetDescription: nil),
                updatedAt: Date()),
            provider: .codex)
        store._setSnapshotForTesting(Self.cursorSnapshot(grokBotUsed: grokBotUsed), provider: .cursor)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        return (settings, store, controller)
    }

    private static func cursorSnapshot(grokBotUsed: Double) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: 91,
                windowMinutes: 10080,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: CursorSandUsageStatus.extraWindowID,
                    title: CursorSandUsageStatus.extraWindowTitle,
                    window: RateWindow(
                        usedPercent: grokBotUsed,
                        windowMinutes: 10080,
                        resetsAt: nil,
                        resetDescription: nil)),
            ],
            updatedAt: Date())
    }
}
