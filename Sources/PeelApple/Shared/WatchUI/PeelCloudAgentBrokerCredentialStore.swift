#if os(iOS)
import Foundation
import Security
import PeelWatchCore

/// Broker-issued scoped credentials only. Reading bytes does NOT restore a
/// verified session: the connector must verify expiry/revocation/account and
/// enrolled peer before constructing its live authority registry. Provider login
/// tokens and identity metadata use different stores and are not promoted here.
final class PeelCloudAgentBrokerCredentialStore {
    enum Failure: Error { case invalidInput, unavailable }
    private let service: String
    init(bundleID: String) throws {
        guard !bundleID.isEmpty, bundleID.utf8.count <= 256,
              !bundleID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.invalidInput }
        service = bundleID + ".watch-plugin-broker"
    }
    private func query(_ namespace: String) throws -> [String: Any] {
        guard (16...128).contains(namespace.utf8.count), namespace.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }) else { throw Failure.invalidInput }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: namespace, kSecAttrSynchronizable as String: false]
    }
    func load(namespace: String) throws -> Data? {
        var request = try query(namespace)
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        request[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, (1...16_384).contains(data.count) else { throw Failure.unavailable }
        return data
    }
    func save(_ data: Data, namespace: String) throws {
        guard (1...16_384).contains(data.count) else { throw Failure.invalidInput }
        var request = try query(namespace)
        request[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        let values: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(request as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = try query(namespace); values.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw Failure.unavailable }
        } else if status != errSecSuccess { throw Failure.unavailable }
    }
    func remove(namespace: String) throws {
        var request = try query(namespace)
        request[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        let status = SecItemDelete(request as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.unavailable }
    }
}
/// No token leaves this phone-only Keychain item. SecItemUpdate is the atomic
/// ready → uncertain → replacement checkpoint; a failed save never falls back.
final class PeelCloudAgentContinuityPersistence: PluginRelayContinuityPersistence, @unchecked Sendable {
    private let vault: PeelCloudAgentBrokerCredentialStore
    private let namespace: String
    init(vault: PeelCloudAgentBrokerCredentialStore, provider: CloudAgentProvider) {
        self.vault = vault; namespace = "native_continuity_v2_" + provider.rawValue
    }
    func read(maximumBytes: Int) throws -> Data? {
        let data = try vault.load(namespace: namespace)
        if let data, data.count > maximumBytes { throw PeelCloudAgentBrokerCredentialStore.Failure.unavailable }
        return data
    }
    func writeAtomically(_ data: Data) throws { try vault.save(data, namespace: namespace) }
    func remove() throws { try vault.remove(namespace: namespace) }
}
#endif
