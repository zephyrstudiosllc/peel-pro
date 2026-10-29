//
//  PeelPairedPeer.swift
//  Peel
//
//  Created by Zach on 12/30/25.
//


import Foundation
import Combine
import Network
import Security
import CryptoKit

// MARK: - Model

/// A single paired peer record (metadata only; the PSK itself lives in Keychain).
struct PeelPairedPeer: Identifiable, Codable, Hashable {
    /// Stable pairing identifier. Also used as the TLS-PSK identity string.
    let id: String

    /// User-visible name ("Zach’s Vision Pro", "Office Mac mini", etc.)
    var displayName: String

    /// For clients: the discovered Bonjour service name you match against (e.g., "Peel on Mac mini").
    /// For hosts: you can leave this nil or use it as a label.
    var serviceName: String?

    var createdAt: Date
    var lastSeenAt: Date?
    
    /// Stable host identifier (from Bonjour TXT record). Prevents "already paired" breaking on rename.
    var stableHostId: String?

    init(id: String = UUID().uuidString,
         displayName: String,
         serviceName: String? = nil,
         stableHostId: String? = nil,
         createdAt: Date = Date(),
         lastSeenAt: Date? = nil)
    {
        self.id = id
        self.displayName = displayName
        self.serviceName = serviceName
        self.stableHostId = stableHostId
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
    }
}

enum PeelPairingRole: String {
    case host
    case client
}

// MARK: - Keychain (PSK storage)

enum PeelKeychain {
    static func setData(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }

        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            // After-first-unlock is reasonable for local-network connectivity.
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus), userInfo: [NSLocalizedDescriptionKey: "Keychain add failed: \(addStatus)"])
            }
            return
        }

        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Keychain update failed: \(status)"])
    }

    static func getData(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Pairing Store

/// Stores paired peers in UserDefaults and the PSK in Keychain.
/// Each app instance gets its own store (host app stores paired clients; client app stores paired hosts).
final class PeelPairingStore: ObservableObject {
    @Published private(set) var paired: [PeelPairedPeer] = []

    private let role: PeelPairingRole
    private let defaultsKey: String
    private let keychainService: String

    init(role: PeelPairingRole) {
        self.role = role
        self.defaultsKey = "PeelPairedPeers.\(role.rawValue)"
        self.keychainService = "com.zephyrstudios.peel.psk.\(role.rawValue)"
        load()
    }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
            paired = []
            return
        }
        do {
            paired = try JSONDecoder().decode([PeelPairedPeer].self, from: data)
        } catch {
            // If something goes sideways, don't brick the app.
            paired = []
        }
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(paired)
            UserDefaults.standard.set(data, forKey: defaultsKey)
        } catch {
            // ignore
        }
    }

    func psk(for pairingID: String) -> Data? {
        PeelKeychain.getData(service: keychainService, account: pairingID)
    }

    /// Adds a new paired peer and stores the PSK in Keychain.
    @discardableResult
    func addPeer(displayName: String,
                 serviceName: String? = nil,
                 stableHostId: String? = nil,
                 pairingID: String = UUID().uuidString,
                 psk: Data) -> PeelPairedPeer {
        
        if let stableHostId, !stableHostId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let normalized = stableHostId.trimmingCharacters(in: .whitespacesAndNewlines)
            let duplicateIDs = paired
                .filter { $0.stableHostId == normalized && $0.id != pairingID }
                .map { $0.id }

            if !duplicateIDs.isEmpty {
                for id in duplicateIDs {
                    PeelKeychain.delete(service: keychainService, account: id)
                }
                paired.removeAll { $0.stableHostId == normalized && $0.id != pairingID }
            }
        }
        // If we have a stable service identifier, treat it as a uniqueness key.
        // This prevents duplicate entries when the same device re-pairs.
        if let serviceName, !serviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let normalized = serviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            let duplicateIDs = paired
                .filter { $0.serviceName == normalized && $0.id != pairingID }
                .map { $0.id }

            if !duplicateIDs.isEmpty {
                for id in duplicateIDs {
                    PeelKeychain.delete(service: keychainService, account: id)
                }
                paired.removeAll { $0.serviceName == normalized && $0.id != pairingID }
            }
        }

        PeelKeychain.delete(service: keychainService, account: pairingID)
        try? PeelKeychain.setData(psk, service: keychainService, account: pairingID)

        let normalizedServiceName = serviceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedStableHostId = stableHostId?.trimmingCharacters(in: .whitespacesAndNewlines)

        var peer = PeelPairedPeer(
            id: pairingID,
            displayName: displayName,
            serviceName: normalizedServiceName,
            stableHostId: normalizedStableHostId
        )
        peer.lastSeenAt = Date()

        // Replace if exists
        paired.removeAll { $0.id == pairingID }
        paired.append(peer)
        paired.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        save()
        return peer
    }

    func removePeer(pairingID: String) {
        let identifier = pairingID.trimmingCharacters(in: .whitespacesAndNewlines)

        // Be forgiving about what identifier the caller passes.
        // Some UI code may accidentally pass `serviceName` (e.g. a stable device id) instead of `id`.
        // Order of precedence:
        //  1) exact pairing id
        //  2) exact serviceName
        //  3) exact displayName
        let idsToRemove: [String]
        if paired.contains(where: { $0.id == identifier }) {
            idsToRemove = paired.filter { $0.id == identifier }.map { $0.id }
        } else if paired.contains(where: { $0.serviceName == identifier }) {
            idsToRemove = paired.filter { $0.serviceName == identifier }.map { $0.id }
        } else if paired.contains(where: { $0.displayName == identifier }) {
            idsToRemove = paired.filter { $0.displayName == identifier }.map { $0.id }
        } else {
            idsToRemove = []
        }

        guard !idsToRemove.isEmpty else { return }

        paired.removeAll { idsToRemove.contains($0.id) }
        for id in idsToRemove {
            PeelKeychain.delete(service: keychainService, account: id)
        }
        save()
    }

    func updateLastSeen(pairingID: String) {
        guard let idx = paired.firstIndex(where: { $0.id == pairingID }) else { return }
        paired[idx].lastSeenAt = Date()
        save()
    }

    static func generatePSK(bytes: Int = 32) -> Data {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { buf in
            SecRandomCopyBytes(kSecRandomDefault, bytes, buf.baseAddress!)
        }
        return data
    }
    
    func updatePeerMetadata(pairingID: String, serviceName: String?, stableHostId: String?) {
        guard let idx = paired.firstIndex(where: { $0.id == pairingID }) else { return }
        if let serviceName { paired[idx].serviceName = serviceName }
        if let stableHostId { paired[idx].stableHostId = stableHostId }
        paired[idx].lastSeenAt = Date()
        save()
    }
    
    func updateDisplayName(pairingID: String, displayName: String) {
        guard let idx = paired.firstIndex(where: { $0.id == pairingID }) else { return }
        paired[idx].displayName = displayName
        paired[idx].lastSeenAt = Date()
        save()
    }
}


// MARK: - Simple manual pairing token (clipboard / text)

/// A compact, copy/paste-able pairing token.
/// You can display `encodedToken()` on the host, then paste it into the client to pair.
/// (This is intentionally ugly-but-effective; you can swap it for a QR code or UI flow later.)
struct PeelPairingInvitation: Codable {
    var serviceName: String
    var pairingID: String
    var pskBase64: String
    var hostDisplayName: String
    var hostId: String?

    init(serviceName: String, pairingID: String, psk: Data, hostDisplayName: String, hostId: String?) {
        self.serviceName = serviceName
        self.pairingID = pairingID
        self.pskBase64 = psk.base64EncodedString()
        self.hostDisplayName = hostDisplayName
        self.hostId = hostId
    }
    var psk: Data? { Data(base64Encoded: pskBase64) }

    func encodedToken() -> String {
        let json = (try? JSONEncoder().encode(self)) ?? Data()
        return json.base64EncodedString()
    }

    static func decodeToken(_ token: String) -> PeelPairingInvitation? {
        guard let data = Data(base64Encoded: token) else { return nil }
        return try? JSONDecoder().decode(PeelPairingInvitation.self, from: data)
    }
}


// MARK: - TLS-PSK via Network.framework + Security.framework

enum PeelTLS {
    /// Creates a TLS-PSK secured NWParameters for the host listener.
    ///
    /// - pairedPeers: list of peers whose PSKs you want to accept.
    /// - keyProvider: closure that returns the raw PSK bytes for a given pairingID.
    static func makeHostParameters(
        pairedPeers: [PeelPairedPeer],
        keyProvider: (String) -> Data?
    ) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let secOptions = tls.securityProtocolOptions

        // Register all known PSKs; the TLS stack will pick based on the identity sent by the client.
        for peer in pairedPeers {
            guard let psk = keyProvider(peer.id), !psk.isEmpty else { continue }
            addPSK(secOptions: secOptions, identity: peer.id, psk: psk)
        }

        appendPSKCipherSuite(secOptions: secOptions)

        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }

    /// Creates a TLS-PSK secured NWParameters for the client connection.
    static func makeClientParameters(pairingID: String, psk: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let secOptions = tls.securityProtocolOptions

        // The client presents exactly one identity+key (the one for the selected host).
        if !psk.isEmpty {
            addPSK(secOptions: secOptions, identity: pairingID, psk: psk)
        }

        appendPSKCipherSuite(secOptions: secOptions)

        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }

    private static func addPSK(secOptions: sec_protocol_options_t, identity: String, psk: Data) {
        let identityData = identity.data(using: .utf8) ?? Data()
        let ddIdentity = identityData.withUnsafeBytes { DispatchData(bytes: $0) }
        let ddPSK = psk.withUnsafeBytes { DispatchData(bytes: $0) }

        // NOTE: Sec APIs use __DispatchData.
        sec_protocol_options_add_pre_shared_key(
            secOptions,
            ddIdentity as __DispatchData,
            ddPSK as __DispatchData
        )
    }

    private static func appendPSKCipherSuite(secOptions: sec_protocol_options_t) {
        let suite = tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!
        sec_protocol_options_append_tls_ciphersuite(secOptions, suite)
    }
    static let pairingPinIdentity = "peel-pin"

    static func derivePairingPinPSK(pin: String, salt: Data, hostId: String) -> Data {
        // Tie the derived key to the hostId so the same PIN on a different Mac isn’t equivalent.
        let normalizedPin = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        let ikmData = Data((normalizedPin + "|" + hostId).utf8)
        let ikm = SymmetricKey(data: ikmData)

        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: salt,
            info: Data("peel-pair-pin-v1".utf8),
            outputByteCount: 32
        )

        return key.withUnsafeBytes { Data($0) }
    }

    static func makeSinglePSKHostParameters(identity: String, psk: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let secOptions = tls.securityProtocolOptions

        if !psk.isEmpty {
            addPSK(secOptions: secOptions, identity: identity, psk: psk)
        }
        appendPSKCipherSuite(secOptions: secOptions)

        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }
}

