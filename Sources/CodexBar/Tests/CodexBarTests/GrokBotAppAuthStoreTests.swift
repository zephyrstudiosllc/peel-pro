import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
import LocalAuthentication
import Security

@Suite(.serialized)
struct GrokBotAppAuthStoreTests {
    private static let accessToken =
        "eyJhbGciOiJub25lIn0." +
        "eyJzdWIiOiJhdXRoMHxib3QtdXNlciIsImVtYWlsIjoiYm90QGV4YW1wbGUuY29tIiwiZXhwIjo0MTAyNDQ0ODAwfQ.sig"
    private static let encryptedAccessToken =
        "djEwWYhmSnp1q+qiTrBMIfHTGiaocfNxVB1uHnqJLpROHUsnz+dm5VzCtVLNxuiDqK1mt752aN2knyD93fmJXv/" +
        "SzMm3cdkiG0mVOI8hjJDSNstfIFmvkF6BIZUAnapsJgrWU0gSAx+2B4EldFNrz7kqIKvvOq0J1qZCO4rDCQfZ644="

    @Test
    func `decrypts the active Grok Bot Cursor account`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-grok-bot-auth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let accounts: [String: Any] = [
            "active": "active-account",
            "accounts": [
                "active-account": ["cursor-access-token": Self.encryptedAccessToken],
            ],
        ]
        let accountsData = try JSONSerialization.data(withJSONObject: accounts)
        let accountsString = try #require(String(data: accountsData, encoding: .utf8))
        let secretsData = try JSONSerialization.data(withJSONObject: ["cursor-accounts": accountsString])
        let secretsURL = directory.appendingPathComponent("sand-secrets.json")
        try secretsData.write(to: secretsURL)

        let store = GrokBotAppAuthStore(
            secretsPath: secretsURL.path,
            passwordProvider: { "test-password" })
        let loadedSession = try store.loadSession()
        let session = try #require(loadedSession)

        #expect(session.accessToken == Self.accessToken)
        #expect(session.source == .grokBotApp)
        #expect(session.identity?.displayLabel == "bot@example.com")
        #expect(session.isUsable)
    }

    @Test
    func `desktop auth prefers a usable Grok Bot session`() throws {
        let grokSession = CursorAppAuthSession(accessToken: Self.accessToken, source: .grokBotApp)
        let cursorSession = CursorAppAuthSession(accessToken: Self.accessToken, source: .cursorApp)
        let store = CursorDesktopAuthStore(
            grokBotStore: CursorDesktopAuthSessionStub(session: grokSession),
            cursorAppStore: CursorDesktopAuthSessionStub(session: cursorSession))

        #expect(try store.loadSession()?.source == .grokBotApp)
    }

    @Test
    func `desktop auth falls back to Cursor app when Grok Bot is unavailable`() throws {
        let cursorSession = CursorAppAuthSession(accessToken: Self.accessToken, source: .cursorApp)
        let store = CursorDesktopAuthStore(
            grokBotStore: CursorDesktopAuthSessionStub(session: nil),
            cursorAppStore: CursorDesktopAuthSessionStub(session: cursorSession))

        #expect(try store.loadSession()?.source == .cursorApp)
    }

    @Test
    func `default secrets path follows the supplied home`() {
        #expect(GrokBotAppAuthStore.resolveDefaultSecretsPath(home: "/tmp/home") ==
            "/tmp/home/Library/Application Support/Grok Bot/sand-secrets.json")
    }

    @Test
    func `fresh background polls never claim an interactive Grok Bot keychain read`() throws {
        var claims = 0
        var reads = 0
        for _ in 0..<20 {
            let password = try GrokBotAppAuthStore.loadSafeStoragePassword(
                preflight: .interactionRequired,
                interaction: .background,
                promptsAllowed: true,
                readPassword: { _ in reads += 1; return "test-password" },
                claimInteractiveRead: { claims += 1; return true })
            #expect(password == nil)
        }
        #expect(claims == 0)
        #expect(reads == 0)
    }

    @Test
    func `dashboard policy prevents prompting even during a user initiated refresh`() throws {
        var claims = 0
        var reads = 0
        let password = try GrokBotAppAuthStore.loadSafeStoragePassword(
            preflight: .interactionRequired,
            interaction: .userInitiated,
            promptsAllowed: false,
            readPassword: { _ in reads += 1; return "test-password" },
            claimInteractiveRead: { claims += 1; return true })
        #expect(password == nil)
        #expect(claims == 0)
        #expect(reads == 0)
    }

    @Test
    func `explicit interactive authentication keeps its bounded authorization path`() throws {
        var readModes: [Bool] = []
        let password = try GrokBotAppAuthStore.loadSafeStoragePassword(
            preflight: .interactionRequired,
            interaction: .userInitiated,
            promptsAllowed: true,
            readPassword: { readModes.append($0); return "test-password" },
            claimInteractiveRead: { true })
        #expect(password == "test-password")
        #expect(readModes == [false])
    }

    @Test
    func `authorized background credentials remain usable through a no UI read`() throws {
        var readModes: [Bool] = []
        let password = try GrokBotAppAuthStore.loadSafeStoragePassword(
            preflight: .allowed,
            interaction: .background,
            promptsAllowed: false,
            readPassword: { readModes.append($0); return "test-password" },
            claimInteractiveRead: {
                Issue.record("Authorized reads must not request interactive permission"); return false
            })
        #expect(password == "test-password")
        #expect(readModes == [true])
    }

    @Test
    func `denied silent keychain reads fail soft without another interactive attempt`() throws {
        var reads = 0
        let password = try GrokBotAppAuthStore.readSafeStoragePassword(disallowInteraction: true) { query, _ in
            reads += 1
            let dictionary = query as? [String: Any]
            #expect(dictionary?[kSecAttrService as String] as? String == "Grok Bot Safe Storage")
            #expect((dictionary?[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true)
            #expect(dictionary?[kSecUseAuthenticationUI as String] as? String ==
                KeychainNoUIQuery.uiFailPolicyForTesting())
            return errSecInteractionNotAllowed
        }
        #expect(password == nil)
        #expect(reads == 1)
    }
}

private struct CursorDesktopAuthSessionStub: CursorAppAuthSessionProviding {
    let session: CursorAppAuthSession?

    func loadSession() throws -> CursorAppAuthSession? {
        self.session
    }
}
#endif
