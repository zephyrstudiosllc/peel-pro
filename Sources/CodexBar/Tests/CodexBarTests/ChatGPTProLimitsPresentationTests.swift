import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct ChatGPTProLimitsPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func `pro limits are opt in and never appear under other providers`() throws {
        #expect(try UsageMenuCardView.Model.chatGPTProLimitsSection(input: self.input(enabled: false)) == nil)
        #expect(try UsageMenuCardView.Model.chatGPTProLimitsSection(input: self.input(provider: .openai)) == nil)
        #expect(try UsageMenuCardView.Model.chatGPTProLimitsSection(input: self.input(provider: .cursor)) == nil)
    }

    @Test
    func `missing data never becomes full empty or unlimited quota`() throws {
        let section = try #require(try UsageMenuCardView.Model.chatGPTProLimitsSection(input: self.input()))
        #expect(section.rows.map(\.label) == ["GPT-6 Pro", "GPT-5.6 Pro"])
        #expect(section.rows.allSatisfy { $0.value == "Unavailable" })
        #expect(section.chart == nil)
    }

    @Test
    func `cooldowns show reset times without inventing message counters`() throws {
        let projection = self.projection(reset: self.now.addingTimeInterval(3600))
        let section = try #require(try UsageMenuCardView.Model.chatGPTProLimitsSection(
            input: self.input(projection: projection)))
        #expect(section.rows.first?.value == "Limit reached")
        #expect(section.rows.first?.secondaryValue?.hasPrefix("Resets in ") == true)
        #expect(section.chart == nil)
    }

    @Test
    func `no reported cooldown still has unknown remaining messages`() throws {
        let section = try #require(try UsageMenuCardView.Model.chatGPTProLimitsSection(
            input: self.input(projection: self.projection(reset: nil))))
        #expect(section.rows.first?.value == "Count unavailable")
        #expect(section.rows.first?.secondaryValue == "Reset time unavailable")
    }

    @Test
    func `stale cooldowns do not look like current readings`() throws {
        let section = try #require(try UsageMenuCardView.Model.chatGPTProLimitsSection(
            input: self.input(projection: self.projection(
                reset: self.now.addingTimeInterval(3600), age: 3600))))
        #expect(section.rows.first?.value == "Unavailable")
        #expect(section.rows.first?.secondaryValue == "Refresh needed")
    }

    @Test
    func `chat limits never leak from unattached accounts or other surfaces`() {
        for surface in [CodexConsumerProjection.Surface.overrideCard, .menuBar, .widget] {
            #expect(self.projection(reset: self.now, surface: surface).chatGPTModelLimits == nil)
        }
        #expect(self.projection(reset: self.now, attached: false).chatGPTModelLimits == nil)
        #expect(self.projection(reset: self.now, loginRequired: true).chatGPTModelLimits == nil)
    }

    @Test
    func `dashboard cache round trips limits without changing codex usage`() throws {
        var dashboard = self.dashboard(reset: self.now)
        let decoder = JSONDecoder()
        let encoded = try JSONEncoder().encode(dashboard)
        #expect(try decoder.decode(OpenAIDashboardSnapshot.self, from: encoded) == dashboard)
        dashboard.chatGPTModelLimits = nil
        let old = try JSONEncoder().encode(dashboard)
        #expect(try decoder.decode(OpenAIDashboardSnapshot.self, from: old).chatGPTModelLimits == nil)
        #expect(dashboard.toUsageSnapshot() == nil)
    }

    private func dashboard(reset: Date?, age: TimeInterval = 0) -> OpenAIDashboardSnapshot {
        OpenAIDashboardSnapshot(
            signedInEmail: "fixture@example.com",
            codeReviewRemainingPercent: nil,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            chatGPTModelLimits: ChatGPTModelLimitsSnapshot(
                models: [ChatGPTModelLimit(modelSlug: "fixture-pro", title: "GPT-6 Pro", resetsAt: reset)],
                updatedAt: self.now.addingTimeInterval(-age)),
            updatedAt: self.now)
    }

    private func projection(
        reset: Date?,
        age: TimeInterval = 0,
        surface: CodexConsumerProjection.Surface = .liveCard,
        attached: Bool = true,
        loginRequired: Bool = false) -> CodexConsumerProjection
    {
        CodexConsumerProjection.make(surface: surface, context: .init(
            snapshot: nil,
            rawUsageError: nil,
            liveCredits: nil,
            rawCreditsError: nil,
            liveDashboard: self.dashboard(reset: reset, age: age),
            rawDashboardError: nil,
            dashboardAttachmentAuthorized: attached,
            dashboardRequiresLogin: loginRequired,
            now: self.now))
    }

    private func input(
        provider: UsageProvider = .codex,
        enabled: Bool = true,
        projection: CodexConsumerProjection? = nil) throws -> UsageMenuCardView.Model.Input
    {
        try .init(
            provider: provider,
            metadata: #require(ProviderDefaults.metadata[provider]),
            snapshot: nil,
            codexProjection: projection,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: false,
            chatGPTProLimitsEnabled: enabled,
            hidePersonalInfo: false,
            now: self.now)
    }
}
