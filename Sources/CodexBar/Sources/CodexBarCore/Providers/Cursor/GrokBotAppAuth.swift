import Foundation

#if os(macOS)
import CommonCrypto
import Security

/// Reads the Cursor account that Grok Bot owns without copying credentials out of Grok Bot's store.
///
/// Grok Bot persists its active Cursor access token in `sand-secrets.json`, encrypted with Electron's
/// macOS Safe Storage key. The token is decrypted only in memory and mapped onto CodexBar's existing
/// short-lived Cursor desktop-auth session.
struct GrokBotAppAuthStore: CursorAppAuthSessionProviding {
    private struct SecretsFile: Decodable {
        let cursorAccounts: String?

        enum CodingKeys: String, CodingKey {
            case cursorAccounts = "cursor-accounts"
        }
    }

    private struct CursorAccounts: Decodable {
        let accounts: [String: Account]
        let active: String
    }

    private struct Account: Decodable {
        let accessToken: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "cursor-access-token"
        }
    }

    enum StoreError: LocalizedError {
        case malformedSecrets
        case invalidEnvelope
        case decryptionFailed
        case keychainFailure(OSStatus)

        var errorDescription: String? {
            switch self {
            case .malformedSecrets:
                "Grok Bot's local account store is malformed."
            case .invalidEnvelope:
                "Grok Bot's local access token uses an unsupported encryption envelope."
            case .decryptionFailed:
                "Grok Bot's local access token could not be decrypted."
            case let .keychainFailure(status):
                "Grok Bot Safe Storage could not be read (macOS status \(status))."
            }
        }
    }

    typealias PasswordProvider = @Sendable () throws -> String?

    private static let safeStorageService = "Grok Bot Safe Storage"
    private static let safeStorageAccount = "Grok Bot Key"
    private static let interactiveReadLock = NSLock()
    private nonisolated(unsafe) static var attemptedInteractiveRead = false

    private let secretsPath: String
    private let passwordProvider: PasswordProvider

    init(
        secretsPath: String? = nil,
        passwordProvider: @escaping PasswordProvider = Self.loadSafeStoragePassword)
    {
        self.secretsPath = secretsPath ?? Self.resolveDefaultSecretsPath()
        self.passwordProvider = passwordProvider
    }

    static func resolveDefaultSecretsPath(home: String = NSHomeDirectory()) -> String {
        "\(home)/Library/Application Support/Grok Bot/sand-secrets.json"
    }

    func loadSession() throws -> CursorAppAuthSession? {
        guard FileManager.default.fileExists(atPath: self.secretsPath) else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: self.secretsPath), options: [.mappedIfSafe])
        let secrets = try JSONDecoder().decode(SecretsFile.self, from: data)
        guard let rawAccounts = secrets.cursorAccounts,
              let accountsData = rawAccounts.data(using: .utf8),
              let cursorAccounts = try? JSONDecoder().decode(CursorAccounts.self, from: accountsData),
              let account = cursorAccounts.accounts[cursorAccounts.active]
        else {
            throw StoreError.malformedSecrets
        }
        guard let password = try self.passwordProvider(), !password.isEmpty else { return nil }
        let token = try Self.decryptAccessToken(account.accessToken, password: password)
        return CursorAppAuthSession(accessToken: token, source: .grokBotApp)
    }

    static func decryptAccessToken(_ encryptedBase64: String, password: String) throws -> String {
        guard let encrypted = Data(base64Encoded: encryptedBase64), encrypted.count > 3,
              String(data: encrypted.prefix(3), encoding: .utf8) == "v10"
        else {
            throw StoreError.invalidEnvelope
        }

        let key = Self.deriveKey(from: password)
        let payload = Data(encrypted.dropFirst(3))
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var outputLength = 0
        var output = Data(count: payload.count + kCCBlockSizeAES128)
        let outputCapacity = output.count

        let status = output.withUnsafeMutableBytes { outputBytes in
            payload.withUnsafeBytes { payloadBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            payloadBytes.baseAddress,
                            payload.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &outputLength)
                    }
                }
            }
        }

        guard status == kCCSuccess else { throw StoreError.decryptionFailed }
        output.count = outputLength
        guard let token = String(data: output, encoding: .utf8), !token.isEmpty else {
            throw StoreError.decryptionFailed
        }
        return token
    }

    private static func deriveKey(from password: String) -> Data {
        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let keyLength = key.count
        _ = key.withUnsafeMutableBytes { keyBytes in
            password.utf8CString.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        passwordBytes.count - 1,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyLength)
                }
            }
        }
        return key
    }

    private static func loadSafeStoragePassword() throws -> String? {
        let preflight = KeychainAccessPreflight.checkGenericPassword(
            service: Self.safeStorageService,
            account: Self.safeStorageAccount)
        return try Self.loadSafeStoragePassword(
            preflight: preflight,
            interaction: ProviderInteractionContext.current,
            promptsAllowed: !KeychainPromptPolicy.isNonInteractive,
            readPassword: { try Self.readSafeStoragePassword(disallowInteraction: $0) },
            claimInteractiveRead: { Self.claimInteractiveRead() })
    }

    static func loadSafeStoragePassword(
        preflight: KeychainAccessPreflight.Outcome,
        interaction: ProviderInteraction,
        promptsAllowed: Bool,
        readPassword: (Bool) throws -> String?,
        claimInteractiveRead: () -> Bool) throws -> String?
    {
        switch preflight {
        case .allowed:
            return try readPassword(true)
        case .interactionRequired:
            // A new dashboard process gets a fresh per-process attempt flag. Requiring an explicit
            // user action here prevents every background poll from opening another authorization dialog.
            guard interaction == .userInitiated, promptsAllowed, claimInteractiveRead() else { return nil }
            return try readPassword(false)
        case .temporarilyUnavailable, .notFound:
            return nil
        case let .failure(status):
            throw StoreError.keychainFailure(OSStatus(status))
        }
    }

    private static func claimInteractiveRead() -> Bool {
        self.interactiveReadLock.withLock {
            guard !self.attemptedInteractiveRead else { return false }
            self.attemptedInteractiveRead = true
            return true
        }
    }

    static func readSafeStoragePassword(
        disallowInteraction: Bool,
        copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = KeychainSecurity.copyMatching)
        throws -> String?
    {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.safeStorageService,
            kSecAttrAccount as String: Self.safeStorageAccount,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        if disallowInteraction {
            KeychainNoUIQuery.apply(to: &query)
        }

        var result: AnyObject?
        let status = copyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw StoreError.decryptionFailed }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound, errSecUserCanceled, errSecInteractionNotAllowed:
            return nil
        default:
            throw StoreError.keychainFailure(status)
        }
    }
}
#endif
