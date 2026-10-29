import Foundation

/// Background collectors must never turn a missing credential into a system authorization dialog.
/// This process policy is inherited by CodexBar children; explicit login commands in a separate
/// process retain their normal user-initiated behavior.
public enum KeychainPromptPolicy {
    public static let nonInteractiveEnvironmentKey = "CODEXBAR_NO_KEYCHAIN_PROMPTS"
    private static let stateLock = NSLock()
    private nonisolated(unsafe) static var configured = false
    private nonisolated(unsafe) static var suppressionAvailable = true

    public static var isNonInteractive: Bool {
        self.stateLock.withLock { self.configured }
            || self.isNonInteractive(environment: ProcessInfo.processInfo.environment)
    }

    static func isNonInteractive(environment: [String: String]) -> Bool {
        environment[self.nonInteractiveEnvironmentKey] == "1"
    }

    @discardableResult
    public static func configureForCurrentProcess(nonInteractive: Bool = false) -> Bool {
        guard nonInteractive || self.isNonInteractive else { return true }
        return self.stateLock.withLock {
            guard !self.configured else { return self.suppressionAvailable }
            self.configured = true
            #if os(macOS)
            // Query flags alone do not reliably suppress legacy ACL dialogs. This also covers
            // in-process dependencies such as SweetCookieKit that do not use our item gateway.
            self.suppressionAvailable = self.enforceNonInteractivePolicy(
                exportEnvironment: { setenv(self.nonInteractiveEnvironmentKey, "1", 1) },
                disableInteraction: { KeychainLegacyInteraction.disableProcessWideInteraction() },
                disableAccess: {
                    KeychainAccessGate.forceDisabledForProcess(reason: "Keychain prompt suppression is unavailable")
                })
            #else
            setenv(self.nonInteractiveEnvironmentKey, "1", 1)
            #endif
            return self.suppressionAvailable
        }
    }

    @discardableResult
    static func enforceNonInteractivePolicy(
        exportEnvironment: () -> Void,
        disableInteraction: () -> Bool,
        disableAccess: () -> Void) -> Bool
    {
        exportEnvironment()
        guard disableInteraction() else { disableAccess(); return false }
        return true
    }

    public static func inheritingEnvironment(_ environment: [String: String]) -> [String: String] {
        self.inheritingEnvironment(environment, nonInteractive: self.isNonInteractive)
    }

    static func inheritingEnvironment(
        _ environment: [String: String],
        nonInteractive: Bool) -> [String: String]
    {
        guard nonInteractive else { return environment }
        var environment = environment
        environment[self.nonInteractiveEnvironmentKey] = "1"
        return environment
    }

    /// An external credential CLI can start its own Security process and does not have to honor
    /// our environment variable or process-wide Security setting. Keep those probes outside a
    /// collector that promises no prompts; provider file/HTTP strategies can still run.
    static func allowsSubprocess(binary: String, nonInteractive: Bool) -> Bool {
        guard nonInteractive else { return true }
        return [
            "/bin/ps", "/usr/bin/pgrep", "/usr/bin/which", "/usr/bin/uname",
            "/usr/bin/id", "/usr/bin/sw_vers", "/usr/sbin/lsof",
        ].contains(binary)
    }

    static let unavailableCredentialCommandMessage =
        "External credential commands are unavailable while Keychain prompts are disabled. " +
        "Use an existing file, token or silently accessible credential."

    public static let unavailableSuppressionMessage =
        "Usage collection stopped because macOS Keychain prompts could not be suppressed."
}

enum KeychainTestSafety {
    static let suppressAccessEnvironmentKey = "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"
    static let allowAccessEnvironmentKey = "CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"

    /// One-shot side effects when this process decides keychain access is blocked:
    /// export the suppression variable so spawned children (debug CLI binaries,
    /// PTY helpers) inherit the decision — name-based self-detection cannot cover
    /// arbitrary child process names — and turn off legacy-keychain interaction
    /// process-wide so no code path can raise the login-keychain ACL dialog.
    private nonisolated(unsafe) static var didApplyBlockedProcessSideEffects = false
    private static let blockedProcessSideEffectsLock = NSLock()

    private static func applyBlockedProcessSideEffectsOnce() {
        self.blockedProcessSideEffectsLock.lock()
        defer { self.blockedProcessSideEffectsLock.unlock() }
        guard !self.didApplyBlockedProcessSideEffects else { return }
        self.didApplyBlockedProcessSideEffects = true
        setenv(self.suppressAccessEnvironmentKey, "1", 1)
        #if os(macOS)
        KeychainLegacyInteraction.disableProcessWideInteraction()
        #endif
    }

    static func shouldBlockRealKeychainAccess(
        processName: String = ProcessInfo.processInfo.processName,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        let blocked = self.resolveShouldBlockRealKeychainAccess(
            processName: processName,
            environment: environment)
        if blocked {
            self.applyBlockedProcessSideEffectsOnce()
        }
        return blocked
    }

    /// Pure decision, side-effect free; kept separate for tests.
    static func resolveShouldBlockRealKeychainAccess(
        processName: String,
        environment: [String: String]) -> Bool
    {
        if environment[self.allowAccessEnvironmentKey] == "1" { return false }
        if environment[self.suppressAccessEnvironmentKey] == "1" { return true }
        if environment[KeychainAccessGate.disableAccessEnvironmentKey] == "1" { return true }
        return self.isRunningUnderTests(processName: processName, environment: environment)
    }

    static func shouldIsolateUserStateUnderTests(
        processName: String = ProcessInfo.processInfo.processName,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        guard environment[self.allowAccessEnvironmentKey] != "1" else { return false }
        return self.isRunningUnderTests(processName: processName, environment: environment)
    }

    static func isRunningUnderTests(
        processName: String,
        environment: [String: String]) -> Bool
    {
        TestProcessSafety.isRunningUnderTests(
            processName: processName,
            environment: environment)
    }
}

#if os(macOS)
import Security

/// Process-wide legacy-keychain interaction switch. `KeychainNoUIQuery` marks
/// individual queries non-interactive, but the repo has observed legacy ACL
/// dialogs surfacing regardless (see KeychainAccessPreflight); for processes
/// that must never prompt — test runners and suppressed children — flipping the
/// documented process-wide switch is the airtight variant. Resolved via dlsym
/// to avoid deprecation warnings, matching the existing pattern in
/// KeychainNoUIQuery/KeychainCacheStore.
enum KeychainLegacyInteraction {
    private typealias SetUserInteractionAllowedFn = @convention(c) (DarwinBoolean) -> OSStatus

    @discardableResult
    static func disableProcessWideInteraction() -> Bool {
        guard let handle = dlopen(
            "/System/Library/Frameworks/Security.framework/Security",
            RTLD_LAZY | RTLD_NOLOAD) else { return false }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "SecKeychainSetUserInteractionAllowed") else { return false }
        let setUserInteractionAllowed = unsafeBitCast(symbol, to: SetUserInteractionAllowedFn.self)
        return setUserInteractionAllowed(false) == errSecSuccess
    }
}

/// The only first-party entry point for Security.framework item operations.
/// Test processes fail closed before touching the user's Keychain, even when a test enables
/// higher-level Keychain logic with `KeychainAccessGate.withTaskOverrideForTesting(false)`.
public enum KeychainSecurity {
    enum ItemOperationBlockReason: Equatable {
        case keychainAccessDisabled
        case testSafetySuppressed
    }

    static func itemOperationBlockReason(
        keychainAccessDisabled: Bool,
        testSafetyBlocked: Bool) -> ItemOperationBlockReason?
    {
        if keychainAccessDisabled { return .keychainAccessDisabled }
        if testSafetyBlocked { return .testSafetySuppressed }
        return nil
    }

    private static func currentItemOperationBlockReason() -> ItemOperationBlockReason? {
        KeychainPromptPolicy.configureForCurrentProcess()
        return self.itemOperationBlockReason(
            keychainAccessDisabled: KeychainAccessGate.isDisabled,
            testSafetyBlocked: KeychainTestSafety.shouldBlockRealKeychainAccess())
    }

    static func itemQuery(_ query: [String: Any], nonInteractive: Bool) -> [String: Any] {
        guard nonInteractive else { return query }
        var query = query
        KeychainNoUIQuery.apply(to: &query)
        return query
    }

    private static func itemQuery(_ query: CFDictionary) -> CFDictionary? {
        guard KeychainPromptPolicy.isNonInteractive else { return query }
        guard let dictionary = query as? [String: Any] else { return nil }
        return self.itemQuery(dictionary, nonInteractive: true) as CFDictionary
    }

    public static func copyMatching(
        _ query: CFDictionary,
        _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    {
        guard self.currentItemOperationBlockReason() == nil else {
            return errSecInteractionNotAllowed
        }
        guard let query = self.itemQuery(query) else { return errSecParam }
        return SecItemCopyMatching(query, result)
    }

    public static func update(_ query: CFDictionary, _ attributesToUpdate: CFDictionary) -> OSStatus {
        guard self.currentItemOperationBlockReason() == nil else {
            return errSecInteractionNotAllowed
        }
        guard let query = self.itemQuery(query) else { return errSecParam }
        return SecItemUpdate(query, attributesToUpdate)
    }

    public static func add(
        _ attributes: CFDictionary,
        _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    {
        guard self.currentItemOperationBlockReason() == nil else {
            return errSecInteractionNotAllowed
        }
        guard let attributes = self.itemQuery(attributes) else { return errSecParam }
        return SecItemAdd(attributes, result)
    }

    public static func delete(_ query: CFDictionary) -> OSStatus {
        guard self.currentItemOperationBlockReason() == nil else {
            return errSecInteractionNotAllowed
        }
        guard let query = self.itemQuery(query) else { return errSecParam }
        return SecItemDelete(query)
    }
}
#endif
