// Adapted from OrcheSSHtra (Conductor) 7add890ce1897a75f23ba8da41f1c83e1dcf1179.
// See ORIGIN.md for provenance and changes.
//
//  SSHCredentialStore.swift
//  Conductor
//
//  Keychain-backed storage for SSH secrets. Secrets live in the Keychain
//  only — never in files, Firestore, or logs (prime directive 3 and
//  docs/security_model.md). Device-only accessibility: credentials do not
//  sync via iCloud Keychain in the MVP.
//

import Foundation
import Security

/// What gets stored for a host profile. Mirrors `SSHAuthMethod` but is
/// Codable for Keychain serialization.
public nonisolated enum SSHStoredCredential: Codable, Equatable, Sendable {
    case password(String)
    case privateKey(pem: String, passphrase: String?)

    public var authMethod: SSHAuthMethod {
        switch self {
        case .password(let password):
            .password(password)
        case .privateKey(let pem, let passphrase):
            .privateKey(pem: pem, passphrase: passphrase)
        }
    }
}

extension SSHStoredCredential: CustomStringConvertible, CustomDebugStringConvertible {
    /// Redacted so a stored credential can never leak through logging.
    public var description: String {
        switch self {
        case .password: "password(<redacted>)" // secret-scan:allow: log-redaction placeholder, not a credential
        case .privateKey: "privateKey(<redacted>)"
        }
    }

    public var debugDescription: String { description }
}

public nonisolated enum SSHCredentialStoreError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case corruptEntry
}

/// A loaded secret remains bound while an editable connection form changes around it.
/// Callers cannot retrieve it for another machine, address, port, or username.
public nonisolated struct SSHBoundCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let key: String
    private let value: SSHStoredCredential
    public init(_ value: SSHStoredCredential, for target: PeelShellTarget) {
        self.key = target.credentialKey
        self.value = value
    }
    public func credential(for target: PeelShellTarget) -> SSHStoredCredential? {
        key == target.credentialKey ? value : nil
    }
    public var description: String { "boundCredential(<redacted>)" }
    public var debugDescription: String { description }
}

public nonisolated protocol SSHCredentialStoreProtocol: Sendable {
    func save(_ credential: SSHStoredCredential, for key: String) throws
    func load(for key: String) throws -> SSHStoredCredential?
    func delete(for key: String) throws
}

/// Generic-password Keychain items: service = bundle-scoped constant,
/// account = the caller's key (a host profile ID). The service is
/// parameterizable so tests use a throwaway namespace.
public nonisolated struct KeychainCredentialStore: SSHCredentialStoreProtocol {
    public let service: String

    public init(service: String = "com.zephyrstudiosllc.Peel.manual-shell.credentials") {
        self.service = service
    }

    public func save(_ credential: SSHStoredCredential, for key: String) throws {
        let data = try JSONEncoder().encode(credential)
        let query = baseQuery(for: key)
        let addAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        var status = SecItemAdd(query.merging(addAttributes) { _, new in new } as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
        }
        guard status == errSecSuccess else {
            throw SSHCredentialStoreError.unexpectedStatus(status)
        }
    }

    public func load(for key: String) throws -> SSHStoredCredential? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let credential = try? JSONDecoder().decode(SSHStoredCredential.self, from: data)
            else {
                throw SSHCredentialStoreError.corruptEntry
            }
            return credential
        case errSecItemNotFound:
            return nil
        default:
            throw SSHCredentialStoreError.unexpectedStatus(status)
        }
    }

    public func delete(for key: String) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SSHCredentialStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}
