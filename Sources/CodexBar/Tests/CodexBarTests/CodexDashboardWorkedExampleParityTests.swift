import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

@Suite(.serialized, CodexCredentialFixtures())
@MainActor
struct CodexDashboardWorkedExampleParityTests {
    @Test
    func `worked example A wrong email app and CLI both reject and retire owned state`() async throws {
        try await self.withIsolatedDashboardCache {
            OpenAIDashboardCacheStore.clear()
            defer { OpenAIDashboardCacheStore.clear() }

            let store = self.makeAppStore(suite: "CodexDashboardWorkedExampleParityTests-example-a")
            store.settings._test_liveSystemCodexAccount = self.liveAccount(
                email: "person-c88baccdc9a3@example.test",
                identity: .emailOnly(normalizedEmail: "person-c88baccdc9a3@example.test"))
            store.settings.codexActiveSource = .liveSystem

            let attachedDashboard = self.makeDashboard(
                email: "person-c88baccdc9a3@example.test",
                creditsRemaining: 42,
                usedPercent: 20)
            let attachedCredits = self.credits(remaining: 42)
            store._setSnapshotForTesting(
                self.codexSnapshot(email: "person-c88baccdc9a3@example.test", usedPercent: 20),
                provider: .codex)
            store.lastSourceLabels[.codex] = "openai-web"
            store.credits = attachedCredits
            store.lastCreditsSnapshot = attachedCredits
            store.lastCreditsSnapshotAccountKey = "person-c88baccdc9a3@example.test"
            store.lastCreditsSource = .dashboardWeb
            store.openAIDashboard = attachedDashboard
            store.lastOpenAIDashboardSnapshot = attachedDashboard
            store.lastOpenAIDashboardTargetEmail = "person-c88baccdc9a3@example.test"
            OpenAIDashboardCacheStore.save(OpenAIDashboardCache(
                accountEmail: "person-c88baccdc9a3@example.test",
                snapshot: attachedDashboard))

            await store.applyOpenAIDashboard(
                self.makeDashboard(
                    email: "person-a7c1e4a26f3e@example.test",
                    creditsRemaining: 9,
                    usedPercent: 35),
                targetEmail: "person-c88baccdc9a3@example.test")

            #expect(store.openAIDashboard == nil)
            #expect(store.lastOpenAIDashboardSnapshot == nil)
            #expect(store.snapshots[.codex] == nil)
            #expect(store.credits == nil)
            #expect(store.lastCreditsSource == .none)
            #expect(OpenAIDashboardCacheStore.load() == nil)
            #expect(store.openAIDashboardRequiresLogin == true)

            let authHome = try self.makeAuthHome(
                email: "person-c88baccdc9a3@example.test",
                accountId: "acct-work")
            defer { try? FileManager.default.removeItem(at: authHome) }
            let cliContext = self.makeCLIContext(
                authHome: authHome,
                knownOwners: [
                    CodexDashboardKnownOwnerCandidate(
                        identity: .providerAccount(id: "acct-work"),
                        normalizedEmail: "person-c88baccdc9a3@example.test"),
                ])
            let wrongEmailDashboard = self.makeDashboard(
                email: "person-a7c1e4a26f3e@example.test",
                creditsRemaining: 9,
                usedPercent: 35)

            do {
                _ = try CodexWebDashboardStrategy.makeAuthorizedDashboardResultForTesting(
                    dashboard: wrongEmailDashboard,
                    context: cliContext,
                    routingTargetEmail: "person-c88baccdc9a3@example.test")
                Issue.record("Expected OpenAIWebCodexError.policyRejected")
            } catch let error as OpenAIWebCodexError {
                if case let .policyRejected(decision) = error {
                    #expect(decision.reason == .wrongEmail(expected: "person-c88baccdc9a3@example.test", actual: "person-a7c1e4a26f3e@example.test"))
                } else {
                    Issue.record("Expected policyRejected, got \(error)")
                }
            } catch {
                Issue.record("Expected OpenAIWebCodexError.policyRejected, got \(error)")
            }

            OpenAIDashboardCacheStore.save(OpenAIDashboardCache(
                accountEmail: "person-a7c1e4a26f3e@example.test",
                snapshot: wrongEmailDashboard))

            let restored = CodexBarCLI.loadOpenAIDashboardIfAvailable(
                usage: self.makeUsage(email: "person-c88baccdc9a3@example.test"),
                sourceLabel: "codex-cli",
                context: cliContext)

            #expect(restored == nil)
            #expect(OpenAIDashboardCacheStore.load() == nil)
        }
    }

    @Test
    func `worked example B same email ambiguity is display only in app and non attach in CLI`() async throws {
        try await self.withIsolatedDashboardCache {
            OpenAIDashboardCacheStore.clear()
            defer { OpenAIDashboardCacheStore.clear() }

            let managedHome = try self.makeAuthHome(
                email: "person-c88baccdc9a3@example.test",
                accountId: "acct-managed")
            defer { try? FileManager.default.removeItem(at: managedHome) }
            let managedAccount = ManagedCodexAccount(
                id: UUID(),
                email: "person-c88baccdc9a3@example.test",
                managedHomePath: managedHome.path,
                createdAt: 1,
                updatedAt: 1,
                lastAuthenticatedAt: 1)
            let managedStoreURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
            defer { try? FileManager.default.removeItem(at: managedStoreURL) }

            let store = self.makeAppStore(suite: "CodexDashboardWorkedExampleParityTests-example-b")
            store.settings._test_managedCodexAccountStoreURL = managedStoreURL
            store.settings._test_liveSystemCodexAccount = self.liveAccount(
                email: "person-c88baccdc9a3@example.test",
                identity: .emailOnly(normalizedEmail: "person-c88baccdc9a3@example.test"))
            store.settings.codexActiveSource = .liveSystem

            await store.applyOpenAIDashboard(
                self.makeDashboard(
                    email: "person-c88baccdc9a3@example.test",
                    creditsRemaining: 14,
                    usedPercent: 30,
                    includeUsageBreakdown: true),
                targetEmail: "person-c88baccdc9a3@example.test")
            try await Task.sleep(for: .milliseconds(250))

            #expect(store.openAIDashboard?.signedInEmail == "person-c88baccdc9a3@example.test")
            #expect(store.snapshots[.codex] == nil)
            #expect(store.credits == nil)
            #expect(OpenAIDashboardCacheStore.load() == nil)
            #expect(store.codexHistoricalDataset == nil)

            let cliAuthHome = try self.makeAuthHome(email: "person-c88baccdc9a3@example.test")
            defer { try? FileManager.default.removeItem(at: cliAuthHome) }
            let ambiguousOwners = [
                CodexDashboardKnownOwnerCandidate(
                    identity: .providerAccount(id: "acct-alpha"),
                    normalizedEmail: "person-c88baccdc9a3@example.test"),
                CodexDashboardKnownOwnerCandidate(
                    identity: .providerAccount(id: "acct-beta"),
                    normalizedEmail: "person-c88baccdc9a3@example.test"),
            ]
            let cliContext = self.makeCLIContext(
                authHome: cliAuthHome,
                knownOwners: ambiguousOwners)
            let dashboard = self.makeDashboard(
                email: "person-c88baccdc9a3@example.test",
                creditsRemaining: 14,
                usedPercent: 30,
                includeUsageBreakdown: true)
            let expectedDecision = CodexDashboardAuthority.evaluate(
                CodexCLIDashboardAuthorityContext.makeLiveWebInput(
                    dashboard: dashboard,
                    context: cliContext,
                    routingTargetEmail: "person-c88baccdc9a3@example.test"))

            do {
                _ = try CodexWebDashboardStrategy.makeAuthorizedDashboardResultForTesting(
                    dashboard: dashboard,
                    context: cliContext,
                    routingTargetEmail: "person-c88baccdc9a3@example.test")
                Issue.record("Expected CodexDashboardPolicyError.displayOnly")
            } catch let error as CodexDashboardPolicyError {
                #expect(error == .displayOnly(expectedDecision))
            } catch {
                Issue.record("Expected CodexDashboardPolicyError.displayOnly, got \(error)")
            }

            OpenAIDashboardCacheStore.save(OpenAIDashboardCache(
                accountEmail: "person-c88baccdc9a3@example.test",
                snapshot: dashboard))

            let restored = CodexBarCLI.loadOpenAIDashboardIfAvailable(
                usage: self.makeUsage(email: "person-c88baccdc9a3@example.test"),
                sourceLabel: "codex-cli",
                context: cliContext)

            #expect(restored == nil)
            #expect(OpenAIDashboardCacheStore.load() == nil)
        }
    }

    @Test
    func `worked example C unresolved but proven continuity attaches in app and CLI`() async {
        await self.withIsolatedDashboardCache {
            OpenAIDashboardCacheStore.clear()
            defer { OpenAIDashboardCacheStore.clear() }

            let emptyHome = self.makeEmptyHome()
            defer { try? FileManager.default.removeItem(at: emptyHome) }

            let store = self.makeAppStore(suite: "CodexDashboardWorkedExampleParityTests-example-c")
            store.settings._test_codexReconciliationEnvironment = ["CODEX_HOME": emptyHome.path]
            store.settings._test_liveSystemCodexAccount = nil
            store.settings.codexActiveSource = .liveSystem
            store._setSnapshotForTesting(
                self.codexSnapshot(email: "person-c88baccdc9a3@example.test", usedPercent: 12),
                provider: .codex)
            store.lastSourceLabels[.codex] = "codex-cli"

            let dashboard = self.makeDashboard(
                email: "person-c88baccdc9a3@example.test",
                creditsRemaining: 33,
                usedPercent: 12)
            let appAuthority = store.evaluateCodexDashboardAuthority(
                dashboard: dashboard,
                sourceKind: .liveWeb,
                routingTargetEmail: "person-c88baccdc9a3@example.test")

            await store.applyOpenAIDashboard(dashboard, targetEmail: "person-c88baccdc9a3@example.test")

            #expect(store.openAIDashboard?.signedInEmail == "person-c88baccdc9a3@example.test")
            #expect(store.credits?.remaining == 33)
            #expect(store.lastCreditsSource == .dashboardWeb)
            #expect(store.lastCodexAccountScopedRefreshGuard?.accountKey == "person-c88baccdc9a3@example.test")
            #expect(store.openAIDashboardRequiresLogin == false)
            #expect(store.lastOpenAIDashboardError == nil)

            let cliContext = self.makeCLIContext(authHome: emptyHome, knownOwners: [])
            OpenAIDashboardCacheStore.save(OpenAIDashboardCache(
                accountEmail: "stale-route@example.com",
                snapshot: dashboard))

            let restored = CodexBarCLI.loadOpenAIDashboardIfAvailable(
                usage: self.makeUsage(email: "person-c88baccdc9a3@example.test"),
                sourceLabel: "codex-cli",
                context: cliContext)
            let cliInput = CodexCLIDashboardAuthorityContext.makeCachedDashboardInput(
                dashboard: dashboard,
                cachedAccountEmail: "stale-route@example.com",
                usage: self.makeUsage(email: "person-c88baccdc9a3@example.test"),
                sourceLabel: "codex-cli",
                context: cliContext)
            let cliDecision = CodexDashboardAuthority.evaluate(cliInput)

            #expect(restored == dashboard)
            #expect(appAuthority.decision.disposition == .attach)
            #expect(cliDecision.disposition == .attach)
            #expect(appAuthority.decision.reason == .trustedContinuityNoCompetingOwner)
            #expect(cliDecision.reason == .trustedContinuityNoCompetingOwner)
        }
    }

    @Test
    func `worked example D prior attach downgrades to ambiguity and retires old owned state`() async throws {
        try await self.withIsolatedDashboardCache {
            OpenAIDashboardCacheStore.clear()
            defer { OpenAIDashboardCacheStore.clear() }

            let store = self.makeAppStore(suite: "CodexDashboardWorkedExampleParityTests-example-d")
            store.settings._test_liveSystemCodexAccount = self.liveAccount(
                email: "shared@example.com",
                identity: .emailOnly(normalizedEmail: "shared@example.com"))
            store.settings.codexActiveSource = .liveSystem

            let initialDashboard = self.makeDashboard(
                email: "shared@example.com",
                creditsRemaining: 21,
                usedPercent: 18)
            await store.applyOpenAIDashboard(initialDashboard, targetEmail: "shared@example.com")

            #expect(store.openAIDashboard?.signedInEmail == "shared@example.com")
            #expect(store.snapshots[.codex]?.accountEmail(for: .codex) == "shared@example.com")
            #expect(store.credits?.remaining == 21)
            #expect(store.lastSourceLabels[.codex] == "openai-web")
            #expect(OpenAIDashboardCacheStore.load()?.accountEmail == "shared@example.com")

            let managedHome = try self.makeAuthHome(
                email: "shared@example.com",
                accountId: "acct-managed")
            defer { try? FileManager.default.removeItem(at: managedHome) }
            let managedAccount = ManagedCodexAccount(
                id: UUID(),
                email: "shared@example.com",
                managedHomePath: managedHome.path,
                createdAt: 1,
                updatedAt: 1,
                lastAuthenticatedAt: 1)
            let managedStoreURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
            defer { try? FileManager.default.removeItem(at: managedStoreURL) }
            store.settings._test_managedCodexAccountStoreURL = managedStoreURL

            await store.applyOpenAIDashboard(
                self.makeDashboard(
                    email: "shared@example.com",
                    creditsRemaining: 9,
                    usedPercent: 35,
                    includeUsageBreakdown: true),
                targetEmail: "shared@example.com")

            #expect(store.openAIDashboard?.signedInEmail == "shared@example.com")
            #expect(store.lastOpenAIDashboardSnapshot?.signedInEmail == "shared@example.com")
            #expect(store.snapshots[.codex] == nil)
            #expect(store.credits == nil)
            #expect(store.lastCreditsSource == .none)
            #expect(OpenAIDashboardCacheStore.load() == nil)

            OpenAIDashboardCacheStore.clear()
            let cliAuthHome = try self.makeAuthHome(email: "shared@example.com")
            defer { try? FileManager.default.removeItem(at: cliAuthHome) }
            let attachableContext = self.makeCLIContext(
                authHome: cliAuthHome,
                knownOwners: [
                    CodexDashboardKnownOwnerCandidate(
                        identity: .providerAccount(id: "acct-alpha"),
                        normalizedEmail: "shared@example.com"),
                ])
            OpenAIDashboardCacheStore.save(OpenAIDashboardCache(
                accountEmail: "shared@example.com",
                snapshot: initialDashboard))

            let initiallyRestored = CodexBarCLI.loadOpenAIDashboardIfAvailable(
                usage: self.makeUsage(email: "shared@example.com"),
                sourceLabel: "codex-cli",
                context: attachableContext)
            #expect(initiallyRestored == initialDashboard)

            let ambiguousContext = self.makeCLIContext(
                authHome: cliAuthHome,
                knownOwners: [
                    CodexDashboardKnownOwnerCandidate(
                        identity: .providerAccount(id: "acct-alpha"),
                        normalizedEmail: "shared@example.com"),
                    CodexDashboardKnownOwnerCandidate(
                        identity: .providerAccount(id: "acct-beta"),
                        normalizedEmail: "shared@example.com"),
                ])

            let downgradedRestored = CodexBarCLI.loadOpenAIDashboardIfAvailable(
                usage: self.makeUsage(email: "shared@example.com"),
                sourceLabel: "codex-cli",
                context: ambiguousContext)

            #expect(downgradedRestored == nil)
            #expect(OpenAIDashboardCacheStore.load() == nil)
        }
    }

    private func withIsolatedDashboardCache<T>(
        _ operation: () async throws -> T) async rethrows -> T
    {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-dashboard-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        return try await OpenAIDashboardCacheStore.$cacheURLOverride.withValue(cacheURL) {
            try await operation()
        }
    }

    private func makeDashboard(
        email: String,
        creditsRemaining: Double,
        usedPercent: Double,
        includeUsageBreakdown: Bool = false) -> OpenAIDashboardSnapshot
    {
        let updatedAt = Date(timeIntervalSince1970: 2000)
        let creditEvents = [
            CreditEvent(
                date: Date(timeIntervalSince1970: 1000),
                service: "codex",
                creditsUsed: 3),
        ]
        let usageBreakdown = includeUsageBreakdown
            ? self.makeUsageBreakdown(endingAt: updatedAt, days: 35, dailyCredits: 10)
            : []
        return OpenAIDashboardSnapshot(
            signedInEmail: email,
            codeReviewRemainingPercent: 75,
            codeReviewLimit: RateWindow(
                usedPercent: 25,
                windowMinutes: 60,
                resetsAt: Date(timeIntervalSince1970: 3600),
                resetDescription: nil),
            creditEvents: creditEvents,
            dailyBreakdown: OpenAIDashboardSnapshot.makeDailyBreakdown(from: creditEvents, maxDays: 30),
            usageBreakdown: usageBreakdown,
            creditsPurchaseURL: nil,
            primaryLimit: RateWindow(
                usedPercent: usedPercent,
                windowMinutes: 300,
                resetsAt: Date(timeIntervalSince1970: 7200),
                resetDescription: nil),
            secondaryLimit: includeUsageBreakdown
                ? RateWindow(
                    usedPercent: usedPercent,
                    windowMinutes: 10080,
                    resetsAt: updatedAt.addingTimeInterval(2 * 24 * 60 * 60),
                    resetDescription: nil)
                : nil,
            creditsRemaining: creditsRemaining,
            accountPlan: "pro",
            updatedAt: updatedAt)
    }

    private func makeAppStore(suite: String) -> UsageStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings._test_activeManagedCodexAccount = nil
        settings._test_activeManagedCodexRemoteHomePath = nil
        settings._test_unreadableManagedCodexAccountStore = false
        settings._test_managedCodexAccountStoreURL = nil
        settings._test_liveSystemCodexAccount = nil
        settings._test_codexReconciliationEnvironment = nil
        settings.historicalTrackingEnabled = true
        let historyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("usage-history.jsonl")
        let planStore = testPlanUtilizationHistoryStore(
            suiteName: "CodexDashboardWorkedExampleParityTests-\(UUID().uuidString)")
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            historicalUsageHistoryStore: HistoricalUsageHistoryStore(fileURL: historyURL),
            planUtilizationHistoryStore: planStore)
        store._cancelPlanUtilizationHistoryLoadForTesting()
        return store
    }

    private func makeCLIContext(
        authHome: URL?,
        knownOwners: [CodexDashboardKnownOwnerCandidate]) -> ProviderFetchContext
    {
        let env = authHome.map { ["CODEX_HOME": $0.path] } ?? [:]
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .cli,
            sourceMode: .auto,
            includeCredits: true,
            webTimeout: 60,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: ProviderSettingsSnapshot.make(
                codex: .init(
                    usageDataSource: .auto,
                    cookieSource: .auto,
                    manualCookieHeader: nil,
                    dashboardAuthorityKnownOwners: knownOwners)),
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }

    private func makeAuthHome(email: String?, accountId: String? = nil) throws -> URL {
        let homeURL = CodexCredentialFixtures.root.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        try self.writeCodexAuthFile(homeURL: homeURL, email: email, accountId: accountId)
        return homeURL
    }

    private func makeEmptyHome() -> URL {
        let homeURL = CodexCredentialFixtures.root.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        try? FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        return homeURL
    }

    private func writeCodexAuthFile(
        homeURL: URL,
        email: String?,
        accountId: String?) throws
    {
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        var tokens: [String: Any] = [
            "accessToken": "access-token",
            "refreshToken": "refresh-token",
            "idToken": Self.fakeJWT(email: email, accountId: accountId),
        ]
        if let accountId {
            tokens["accountId"] = accountId
        }
        let auth = ["tokens": tokens]
        let data = try JSONSerialization.data(withJSONObject: auth)
        try data.write(to: homeURL.appendingPathComponent("auth.json"))
    }

    private static func fakeJWT(email: String?, accountId: String?) -> String {
        let header = (try? JSONSerialization.data(withJSONObject: ["alg": "none"])) ?? Data()
        var authClaims: [String: Any] = [
            "chatgpt_plan_type": "pro",
        ]
        if let accountId {
            authClaims["chatgpt_account_id"] = accountId
        }
        var claims: [String: Any] = [
            "chatgpt_plan_type": "pro",
            "https://api.openai.com/auth": authClaims,
        ]
        if let email {
            claims["email"] = email
        }
        let payload = (try? JSONSerialization.data(withJSONObject: claims)) ?? Data()

        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
        }

        return "\(base64URL(header)).\(base64URL(payload))."
    }

    private func makeManagedAccountStoreURL(accounts: [ManagedCodexAccount]) throws -> URL {
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = FileManagedCodexAccountStore(fileURL: storeURL)
        try store.storeAccounts(ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: accounts))
        return storeURL
    }

    private func liveAccount(email: String, identity: CodexIdentity = .unresolved) -> ObservedSystemCodexAccount {
        ObservedSystemCodexAccount(
            email: email,
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: identity)
    }

    private func codexSnapshot(email: String, usedPercent: Double) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: usedPercent,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 2000),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: email,
                accountOrganization: nil,
                loginMethod: "Pro"))
    }

    private func credits(remaining: Double) -> CreditsSnapshot {
        CreditsSnapshot(remaining: remaining, events: [], updatedAt: Date(timeIntervalSince1970: 2000))
    }

    private func makeUsage(email: String?) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: 10,
                windowMinutes: 300,
                resetsAt: Date(timeIntervalSince1970: 7200),
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 2000),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: email,
                accountOrganization: nil,
                loginMethod: nil))
    }

    private func makeUsageBreakdown(
        endingAt endDate: Date,
        days: Int,
        dailyCredits: Double) -> [OpenAIDashboardDailyBreakdown]
    {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar(identifier: .gregorian)
        let endDay = calendar.startOfDay(for: endDate)
        return (0..<days).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: endDay) else { return nil }
            return OpenAIDashboardDailyBreakdown(
                day: formatter.string(from: date),
                services: [
                    OpenAIDashboardServiceUsage(service: "CLI", creditsUsed: dailyCredits),
                ],
                totalCreditsUsed: dailyCredits)
        }
    }
}
