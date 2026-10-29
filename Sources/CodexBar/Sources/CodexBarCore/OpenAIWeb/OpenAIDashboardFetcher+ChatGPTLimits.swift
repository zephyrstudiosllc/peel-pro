#if os(macOS)
import Foundation
import WebKit

extension OpenAIDashboardFetcher {
    public func loadLatestDashboard(
        websiteDataStore: WKWebsiteDataStore,
        logger: ((String) -> Void)? = nil,
        debugDumpHTML: Bool = false,
        allowNavigationTimeoutRetry: Bool = true,
        timeout: TimeInterval = 60,
        previousSnapshot: OpenAIDashboardSnapshot? = nil,
        includeChatGPTModelLimits: Bool = false,
        allowPageScrape: Bool = true) async throws -> OpenAIDashboardSnapshot
    {
        let deadline = Self.deadline(startingAt: Date(), timeout: timeout)
        var snapshot = try await self.loadDashboardSnapshot(
            websiteDataStore: websiteDataStore,
            logger: logger,
            debugDumpHTML: debugDumpHTML,
            allowNavigationTimeoutRetry: allowNavigationTimeoutRetry,
            timeout: timeout,
            previousSnapshot: previousSnapshot,
            allowPageScrape: allowPageScrape)
        // Optional Chat limits never replace or invalidate the required Codex snapshot.
        // Clear old adjunct data on failure instead of refreshing a stale cooldown's timestamp.
        snapshot.chatGPTModelLimits = nil
        if includeChatGPTModelLimits, let email = snapshot.signedInEmail,
           let cookies = try? await Self.chatGPTCookieHeader(in: websiteDataStore, deadline: deadline)
        {
            snapshot.chatGPTModelLimits = await ChatGPTModelLimitsFetcher.fetch(
                cookieHeader: cookies,
                expectedEmail: email,
                deadline: deadline,
                logger: { logger?($0) })
        }
        try Task.checkCancellation()
        return snapshot
    }
}
#endif
