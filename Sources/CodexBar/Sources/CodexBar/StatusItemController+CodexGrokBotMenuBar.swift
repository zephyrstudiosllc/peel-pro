import CodexBarCore
import Foundation

struct CodexGrokBotMenuBarStackValues: Equatable {
    let codex: Double?
    let grokBot: Double
}

extension StatusItemController {
    func codexGrokBotMenuBarLaneColors() -> IconRenderer.LaneColors {
        // Provider-specific by design: Grok Bot is a Cursor-owned usage window and shares its dropdown accent.
        IconRenderer.LaneColors(
            top: self.settings.accentColor(for: .codex),
            bottom: self.settings.accentColor(for: .cursor))
    }

    func codexGrokBotMenuBarStackValues(showUsed: Bool) -> CodexGrokBotMenuBarStackValues? {
        guard self.shouldMergeIcons,
              !self.settings.menuBarShowsBrandIconWithPercent
        else { return nil }

        let visibleProviders = self.store.enabledProvidersForDisplay()
        // Provider-specific by design: this opt-in presentation exists only for the Codex and Cursor pairing.
        guard visibleProviders.contains(.codex), visibleProviders.contains(.cursor),
              let cursorSnapshot = self.store.menuBarSnapshot(for: .cursor),
              let grokBot = cursorSnapshot.extraRateWindows?.first(where: {
                  $0.id == CursorSandUsageStatus.extraWindowID && $0.usageKnown
              })?.window
        else { return nil }

        let codexSnapshot = self.store.menuBarSnapshot(for: .codex)
        let codex = self.resolvedMenuBarIconPercents(
            provider: .codex,
            snapshot: codexSnapshot,
            style: self.store.style(for: .codex),
            showUsed: showUsed)?.primary
        let grokBotPercent = showUsed ? grokBot.usedPercent : grokBot.remainingPercent
        return CodexGrokBotMenuBarStackValues(
            codex: codex,
            grokBot: max(0, min(grokBotPercent, 100)))
    }

    func codexGrokBotMenuBarCandidateSignature() -> String? {
        guard self.shouldMergeIcons else { return nil }
        let visibleProviders = self.store.enabledProvidersForDisplay()
        guard visibleProviders.contains(.codex), visibleProviders.contains(.cursor) else { return nil }

        let namedWindow = self.store.menuBarSnapshot(for: .cursor)?.extraRateWindows?.first {
            $0.id == CursorSandUsageStatus.extraWindowID
        }
        // Provider-specific by design: this signature invalidates the fixed Codex and Cursor menu bar pairing.
        return [
            "known=\(namedWindow?.usageKnown == true ? "1" : "0")",
            "used=\(Self.iconSignatureValue(namedWindow?.window.usedPercent))",
            "cursorStale=\(self.store.isStale(provider: .cursor) ? "1" : "0")",
            "codexRefreshing=\(self.store.refreshingProviders.contains(.codex) ? "1" : "0")",
            "cursorRefreshing=\(self.store.refreshingProviders.contains(.cursor) ? "1" : "0")",
        ].joined(separator: ",")
    }

    func codexGrokBotAccessibilityTitle(
        values: CodexGrokBotMenuBarStackValues,
        showUsed: Bool)
        -> String
    {
        let metric = showUsed ? "used" : "remaining"
        // Provider-specific by design: accessibility names the fixed Codex lane instead of a generic primary lane.
        let codex = values.codex.map { String(format: "%.0f%%", $0) } ?? "unavailable"
        let grokBot = String(format: "%.0f%%", values.grokBot)
        return "CodexBar, Codex \(codex) \(metric), Grok Bot \(grokBot) \(metric)"
    }
}
