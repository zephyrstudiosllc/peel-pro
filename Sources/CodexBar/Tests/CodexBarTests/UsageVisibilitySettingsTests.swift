import Foundation
import Observation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct UsageVisibilitySettingsTests {
    private final class ObservationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set() {
            self.lock.lock()
            self.value = true
            self.lock.unlock()
        }

        func get() -> Bool {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.value
        }
    }

    @Test
    func `cursor quota usage visibility defaults on persists and refreshes only menus`() async throws {
        try await self.verifyVisibilitySetting(
            suite: "UsageVisibilitySettingsTests-cursor-quota",
            read: { $0.cursorQuotaUsageVisible },
            disable: { $0.cursorQuotaUsageVisible = false })
    }

    @Test
    func `codex reset credits visibility defaults on persists and refreshes only menus`() async throws {
        try await self.verifyVisibilitySetting(
            suite: "UsageVisibilitySettingsTests-codex-reset-credits",
            read: { $0.codexResetCreditsVisible },
            disable: { $0.codexResetCreditsVisible = false })
    }

    private func verifyVisibilitySetting(
        suite: String,
        read: (SettingsStore) -> Bool,
        disable: (SettingsStore) -> Void) async throws
    {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(read(store))
        let backgroundRevision = store.backgroundWorkSettingsRevision
        let menuDidChange = ObservationFlag()
        withObservationTracking {
            _ = store.menuObservationToken
        } onChange: {
            menuDidChange.set()
        }
        disable(store)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.backgroundWorkSettingsRevision == backgroundRevision)
        #expect(menuDidChange.get())

        let reloaded = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        #expect(read(reloaded) == false)
    }
}
