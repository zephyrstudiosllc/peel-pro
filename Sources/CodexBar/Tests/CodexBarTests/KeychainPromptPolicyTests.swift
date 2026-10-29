import Foundation
import Testing
@testable import CodexBarCore

struct KeychainPromptPolicyTests {
    @Test
    func `noninteractive policy is explicitly inherited without deleting other environment values`() {
        let key = KeychainPromptPolicy.nonInteractiveEnvironmentKey
        #expect(KeychainPromptPolicy.isNonInteractive(environment: [key: "1"]))
        #expect(!KeychainPromptPolicy.isNonInteractive(environment: [key: "0"]))
        #expect(!KeychainPromptPolicy.isNonInteractive(environment: [:]))
        #expect(KeychainPromptPolicy.inheritingEnvironment(
            ["PATH": "/test/bin", key: "0"],
            nonInteractive: true) == ["PATH": "/test/bin", key: "1"])
        #expect(KeychainPromptPolicy.inheritingEnvironment(
            ["PATH": "/test/bin"],
            nonInteractive: false) == ["PATH": "/test/bin"])
    }

    @Test
    func `legacy suppression failure blocks access after exporting the child policy`() {
        var events: [String] = []
        let available = KeychainPromptPolicy.enforceNonInteractivePolicy(
            exportEnvironment: { events.append("export") },
            disableInteraction: { events.append("suppress"); return false },
            disableAccess: { events.append("block") })
        #expect(events == ["export", "suppress", "block"])
        #expect(!available)
    }

    @Test
    func `successful legacy suppression preserves silently authorized keychain access`() {
        var events: [String] = []
        let available = KeychainPromptPolicy.enforceNonInteractivePolicy(
            exportEnvironment: { events.append("export") },
            disableInteraction: { events.append("suppress"); return true },
            disableAccess: { events.append("block") })
        #expect(events == ["export", "suppress"])
        #expect(available)
    }

    @Test
    func `opaque credential subprocesses cannot escape the noninteractive process boundary`() {
        for binary in ["/usr/bin/security", "/opt/homebrew/bin/claude", "/tmp/codex", "/tmp/grok", "/tmp/aws"] {
            #expect(!KeychainPromptPolicy.allowsSubprocess(binary: binary, nonInteractive: true))
            #expect(KeychainPromptPolicy.allowsSubprocess(binary: binary, nonInteractive: false))
        }
        #expect(KeychainPromptPolicy.allowsSubprocess(binary: "/bin/ps", nonInteractive: true))
        #expect(KeychainPromptPolicy.allowsSubprocess(binary: "/usr/sbin/lsof", nonInteractive: true))
        #expect(!KeychainPromptPolicy.allowsSubprocess(binary: "/tmp/ps", nonInteractive: true))
    }

    #if os(macOS)
    @Test
    func `common item gateway overrides an interactive query without changing the credential selector`() {
        let context = LAContext()
        context.interactionNotAllowed = false
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "test.service",
            kSecAttrAccount as String: "test.account",
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context,
            kSecUseAuthenticationUI as String: "interactive-policy",
        ]
        let protected = KeychainSecurity.itemQuery(query, nonInteractive: true)
        #expect(protected[kSecAttrService as String] as? String == "test.service")
        #expect(protected[kSecAttrAccount as String] as? String == "test.account")
        #expect(protected[kSecReturnData as String] as? Bool == true)
        #expect((protected[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true)
        #expect(protected[kSecUseAuthenticationUI as String] as? String == KeychainNoUIQuery.uiFailPolicyForTesting())

        let interactive = KeychainSecurity.itemQuery(query, nonInteractive: false)
        #expect((interactive[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == false)
        #expect(interactive[kSecUseAuthenticationUI as String] as? String == "interactive-policy")
    }
    #endif
}

#if os(macOS)
import LocalAuthentication
import Security
#endif
