import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct DashboardHistoryIdentityTests {
    @Test
    func `fresh status cannot relabel stale allowance history`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stale = now.addingTimeInterval(-3600)
        let usage = UsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: stale)
        let payload = ProviderPayload(
            provider: .codex,
            account: nil,
            version: nil,
            source: "oauth",
            status: ProviderStatusPayload(
                indicator: .none, description: "Operational", updatedAt: now, url: "https://example.test"),
            usage: usage,
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: nil)
        let snapshot = DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: [payload],
            costPayloads: [],
            config: CodexBarConfig(providers: [ProviderConfig(id: .codex, enabled: true)]),
            identityMode: .redacted,
            generatedAt: now,
            refreshInterval: 60,
            codexBarVersion: nil)
        let provider = try #require(snapshot.providers.first)
        #expect(provider.updatedAt == now)
        #expect(provider.allowanceUpdatedAt == stale)
    }

    @Test
    func `history identity distinguishes accounts sharing a redacted domain and providers`() throws {
        let first = try #require(DashboardIdentityPayload.historyAccountKey(
            providerID: "codex", email: "first@example.test"))
        #expect(first == DashboardIdentityPayload.historyAccountKey(
            providerID: "codex", email: " FIRST@example.test "))
        #expect(first != DashboardIdentityPayload.historyAccountKey(
            providerID: "codex", email: "second@example.test"))
        #expect(first != DashboardIdentityPayload.historyAccountKey(
            providerID: "cursor", email: "first@example.test"))
        let payload = DashboardIdentityPayload(accountEmail: "redacted@example.test", plan: nil, accountKey: first)
        let data = try JSONEncoder().encode(payload)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("first@example.test"))
        #expect(json.contains(first))
    }

    @Test
    func `explicit accounts and organizations remain distinct without requiring email`() throws {
        let first = try #require(DashboardIdentityPayload.historyAccountKey(
            providerID: "codex", email: nil, accountID: "account-a", organization: "org-a"))
        #expect(first != DashboardIdentityPayload.historyAccountKey(
            providerID: "codex", email: nil, accountID: "account-b", organization: "org-a"))
        #expect(first != DashboardIdentityPayload.historyAccountKey(
            providerID: "codex", email: nil, accountID: "account-a", organization: "org-b"))
        #expect(first == DashboardIdentityPayload.historyAccountKey(
            providerID: "codex", email: "changed@example.test", accountID: "account-a", organization: "org-a"))
    }

    @Test
    func `missing or already redacted identity cannot create a history owner`() {
        for email: String? in [nil, "", "unknown", "redacted@example.test", "@example.test", "user@"] {
            #expect(DashboardIdentityPayload.historyAccountKey(providerID: "codex", email: email) == nil)
        }
    }
}
