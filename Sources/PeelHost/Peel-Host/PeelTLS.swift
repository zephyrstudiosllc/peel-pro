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

nonisolated enum PeelTLSPSKOrder: String, Codable, Hashable, Sendable {
    case standard = "psk-identity"
    case legacyIdentityFirst = "identity-psk"
}

/// A single paired peer record (metadata only; the PSK itself lives in Keychain).
nonisolated struct PeelPairedPeer: Identifiable, Codable, Hashable, Sendable {
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

    /// Once standard order succeeds, missing Bonjour metadata must not downgrade this pairing.
    var tlsPSKOrder: PeelTLSPSKOrder?

    /// Present only for credentials issued by optional iCloud enrollment.
    var iCloudEnrollmentID: String?

    init(id: String = UUID().uuidString,
         displayName: String,
         serviceName: String? = nil,
         stableHostId: String? = nil,
         tlsPSKOrder: PeelTLSPSKOrder? = nil,
         createdAt: Date = Date(),
         lastSeenAt: Date? = nil,
         iCloudEnrollmentID: String? = nil)
    {
        self.id = id
        self.displayName = displayName
        self.serviceName = serviceName
        self.stableHostId = stableHostId
        self.tlsPSKOrder = tlsPSKOrder
        self.iCloudEnrollmentID = iCloudEnrollmentID
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
    }
}

enum PeelPairingRole: String {
    case host
    case client
}

// MARK: - Keychain (PSK storage)

/// Typed results retain the distinction between absent credentials and a key
/// that exists but cannot currently be authorized. Only notFound permits a new
/// pairing insert. Transitional results never authorize absence or deletion.
enum PeelKeychainReadResult: Equatable, Sendable {
    case available(Data)
    case notFound
    case authorizationUnavailable(OSStatus)
    case failure(OSStatus)
    case invalidData
    case readInProgress
    case readInvalidated
    case cacheCapacityReached

    nonisolated var data: Data? {
        if case .available(let data) = self { return data }
        return nil
    }
}

/// This cache suppresses repeated reads, including failed reads. It does not
/// suppress the OS dialog for the FIRST legacy Keychain operation. Preserve the
/// legitimate signing identity and service/account/backend separately.
final class PeelKeychainReadCache: @unchecked Sendable {
    private nonisolated struct Key: Hashable, Sendable { let service: String; let account: String }
    private nonisolated enum Entry: Sendable {
        case loading(UUID, invalidated: Bool)
        case finished(PeelKeychainReadResult)
    }
    nonisolated private let lock = NSLock()
    nonisolated private let maximumEntries: Int
    nonisolated(unsafe) private var entries: [Key: Entry] = [:]

    nonisolated init(maximumEntries: Int = 512) { self.maximumEntries = max(1, maximumEntries) }

    nonisolated func lookup(service: String, account: String, read: () -> PeelKeychainReadResult) -> PeelKeychainReadResult {
        let key = Key(service: service, account: account)
        lock.lock()
        if let entry = entries[key] {
            lock.unlock()
            switch entry {
            case .loading: return .readInProgress
            case .finished(let result): return result
            }
        }
        guard entries.count < maximumEntries else {
            lock.unlock()
            return .cacheCapacityReached
        }
        let token = UUID()
        entries[key] = .loading(token, invalidated: false)
        lock.unlock()

        // Never hold a cache lock through Security, authentication UI or I/O.
        let result = read()

        lock.lock()
        guard case .loading(let currentToken, let invalidated) = entries[key], currentToken == token else {
            lock.unlock()
            return .readInvalidated
        }
        if invalidated {
            entries[key] = .finished(.readInvalidated)
            lock.unlock()
            return .readInvalidated
        }
        entries[key] = .finished(result)
        lock.unlock()
        return result
    }

    nonisolated func peek(service: String, account: String) -> PeelKeychainReadResult? {
        lock.lock()
        defer { lock.unlock() }
        switch entries[Key(service: service, account: account)] {
        case .finished(let result): return result
        case .loading: return .readInProgress
        case nil: return nil
        }
    }

    /// Exact selected retry or credential mutation only. Do not use on timers,
    /// discovery, lastSeen or general paired-metadata publications. Invalidating
    /// an in-flight query prevents its stale result from repopulating the cache
    /// but keeps its single-flight slot until the OS operation actually returns.
    nonisolated func invalidate(service: String, account: String) {
        let key = Key(service: service, account: account)
        lock.lock()
        defer { lock.unlock() }
        if case .loading(let token, _) = entries[key] {
            entries[key] = .loading(token, invalidated: true)
        } else {
            entries[key] = nil
        }
    }

    nonisolated func prepareExplicitRetry(service: String, account: String) -> Bool {
        let key = Key(service: service, account: account)
        lock.lock()
        defer { lock.unlock() }
        if case .loading = entries[key] { return false }
        entries[key] = nil
        return true
    }

    /// Seed only bytes returned by a successful, exact Security readback.
    /// Replaces any older pending result without allowing it to overwrite this.
    @discardableResult
    nonisolated func recordVerified(_ data: Data, service: String, account: String) -> Bool {
        guard data.count >= 32 else { return false }
        let key = Key(service: service, account: account)
        lock.lock()
        defer { lock.unlock() }
        guard entries[key] != nil || entries.count < maximumEntries else { return false }
        entries[key] = .finished(.available(data))
        return true
    }
}

enum PeelKeychain {
    nonisolated static func setData(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess {
            readCache.invalidate(service: service, account: account)
            return
        }

        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            // After-first-unlock is reasonable for local-network connectivity.
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus), userInfo: [NSLocalizedDescriptionKey: "Keychain add failed: \(addStatus)"])
            }
            readCache.invalidate(service: service, account: account)
            return
        }

        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Keychain update failed: \(status)"])
    }

    nonisolated private static let readCache = PeelKeychainReadCache()
    typealias CopyMatching = (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus

    /// The first read preserves the existing authorized automatic-host path;
    /// successful and failed outcomes are cached for this exact item thereafter.
    nonisolated static func readDataResult(service: String, account: String,
                                           copyMatching: CopyMatching = SecItemCopyMatching) -> PeelKeychainReadResult {
        readCache.lookup(service: service, account: account) {
            readUncachedDataResult(service: service, account: account, copyMatching: copyMatching)
        }
    }

    /// Only selected new-pair collision/readback transactions bypass the cache.
    /// Unknown candidate UUIDs must not permanently consume the bounded cache.
    nonisolated static func readUncachedDataResult(service: String, account: String,
                                                   copyMatching: CopyMatching = SecItemCopyMatching) -> PeelKeychainReadResult {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            let status = copyMatching(query as CFDictionary, &item)
            switch status {
            case errSecSuccess:
                // Existing Host consumers accept legacy keys of at least32
                // bytes; the outgoing Mac viewer separately requires exactly32.
                guard let data = item as? Data, data.count >= 32 else { return .invalidData }
                return .available(data)
            case errSecItemNotFound:
                return .notFound
            case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
                return .authorizationUnavailable(status)
            default:
                return .failure(status)
            }
    }

    nonisolated static func getData(service: String, account: String) -> Data? {
        readDataResult(service: service, account: account).data
    }

    /// No I/O; an unattempted item is nil, distinct from an actual notFound.
    nonisolated static func cachedReadResult(service: String, account: String) -> PeelKeychainReadResult? {
        readCache.peek(service: service, account: account)
    }

    /// A selected gesture cannot invalidate or duplicate an unfinished query.
    nonisolated static func retryDataResult(service: String, account: String) -> PeelKeychainReadResult {
        guard readCache.prepareExplicitRetry(service: service, account: account) else { return .readInProgress }
        return readDataResult(service: service, account: account)
    }

    @discardableResult
    nonisolated static func recordVerifiedData(_ data: Data, service: String, account: String) -> Bool {
        readCache.recordVerified(data, service: service, account: account)
    }

    /// Add-only commit: a race/collision must never update an existing item.
    nonisolated static func insertNewData(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Keychain insertion failed: \(status)"])
        }
        readCache.invalidate(service: service, account: account)
    }

    nonisolated static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        readCache.invalidate(service: service, account: account)
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

    /// Read status without opening another Keychain operation.
    func cachedPSKReadResult(for pairingID: String) -> PeelKeychainReadResult? {
        PeelKeychain.cachedReadResult(service: keychainService, account: pairingID)
    }

    /// Selected explicit retry only; never call from discovery/timer callbacks.
    func retryPSKRead(for pairingID: String) -> PeelKeychainReadResult {
        guard let peer = paired.first(where: { $0.id == pairingID }) else { return .readInvalidated }
        if case .available(let data) = cachedPSKReadResult(for: pairingID), data.count >= 32 { return .available(data) }
        let result = PeelKeychain.retryDataResult(service: keychainService, account: pairingID)
        return finishSelectedPSKRead(result, peer: peer)
    }

    /// Called by the selected Connect action, never a timer or discovery path.
    /// Keep verified positives; retry a prior unavailable result once per click.
    func pskReadForExplicitConnection(for pairingID: String) -> PeelKeychainReadResult {
        guard let peer = paired.first(where: { $0.id == pairingID }) else { return .readInvalidated }
        switch cachedPSKReadResult(for: pairingID) {
        case .available(let data) where data.count >= 32: return .available(data)
        case .readInProgress: return .readInProgress
        case nil:
            let result = PeelKeychain.readDataResult(service: keychainService, account: pairingID)
            return finishSelectedPSKRead(result, peer: peer)
        default: return retryPSKRead(for: pairingID)
        }
    }

    private func finishSelectedPSKRead(_ result: PeelKeychainReadResult, peer: PeelPairedPeer) -> PeelKeychainReadResult {
        guard paired.contains(where: {
            $0.id == peer.id && $0.serviceName == peer.serviceName &&
            $0.stableHostId == peer.stableHostId && $0.tlsPSKOrder == peer.tlsPSKOrder
        }) else {
            // Credential writes/deletes already retire the read-cache token.
            // Never invalidate a newer replacement's verified cache entry here.
            return .readInvalidated
        }
        if case .available(let data) = result {
            guard data.count >= 32 else { return .invalidData }
            // Republish the SAME metadata for existing listener/SidePulse trust
            // sinks to rebuild from the now-cached key. Never save or mutate it.
            paired = paired
        }
        return result
    }

    /// New pairings commit their credential before replacing metadata or old keys.
    /// A failed Keychain write leaves all existing trust records intact.
    @discardableResult
    func addPeerPersistingKey(displayName: String, serviceName: String? = nil,
                              stableHostId: String? = nil, tlsPSKOrder: PeelTLSPSKOrder? = nil,
                              pairingID: String, psk: Data, iCloudEnrollmentID: String? = nil) throws -> PeelPairedPeer {
        guard iCloudEnrollmentID.map({ UUID(uuidString: $0) != nil }) ?? true,
              UUID(uuidString: pairingID) != nil, psk.count == 32,
              !paired.contains(where: { $0.id == pairingID }) else {
            throw NSError(domain: "PeelPairing", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The Mac returned invalid or already-used pairing credentials."])
        }
        // nil is not proof of absence: denial, cancellation and other read
        // failures must never authorize overwriting an existing credential.
        switch PeelKeychain.readUncachedDataResult(service: keychainService, account: pairingID) {
        case .notFound: break
        case .available:
            throw NSError(domain: "PeelPairing", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The returned pairing credential already exists."])
        default:
            throw NSError(domain: "PeelPairing", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Saved pairing credentials are unavailable. Existing pairings are unchanged."])
        }
        let service = serviceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostID = stableHostId?.trimmingCharacters(in: .whitespacesAndNewlines)
        try PeelKeychain.insertNewData(psk, service: keychainService, account: pairingID)
        guard case .available(let stored) = PeelKeychain.readUncachedDataResult(service: keychainService, account: pairingID), stored == psk else {
            // An unavailable/unverified readback is not permission to delete
            // a credential. Leave the item and existing metadata untouched.
            throw NSError(domain: "PeelPairing", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "The new pairing key could not be verified. Existing pairings are unchanged."])
        }
        guard PeelKeychain.recordVerifiedData(stored, service: keychainService, account: pairingID) else {
            throw NSError(domain: "PeelPairing", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Pairing credential capacity was reached. Existing pairings are unchanged."])
        }
        let replaced = paired.filter { peer in
            (hostID?.isEmpty == false && peer.stableHostId == hostID) ||
            (service?.isEmpty == false && peer.serviceName == service)
        }
        let removedIDs = Set(replaced.map(\.id))
        var peer = PeelPairedPeer(id: pairingID, displayName: displayName,
            serviceName: service, stableHostId: hostID, tlsPSKOrder: tlsPSKOrder,
            iCloudEnrollmentID: iCloudEnrollmentID)
        peer.lastSeenAt = Date()
        paired = paired.filter { !removedIDs.contains($0.id) } + [peer]
        save()
        for id in removedIDs { PeelKeychain.delete(service: keychainService, account: id) }
        return peer
    }

    /// Adds a new paired peer and stores the PSK in Keychain.
    @discardableResult
    func addPeer(displayName: String,
                 serviceName: String? = nil,
                 stableHostId: String? = nil,
                 tlsPSKOrder: PeelTLSPSKOrder? = nil,
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
            stableHostId: normalizedStableHostId,
            tlsPSKOrder: tlsPSKOrder
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

    func updatePeerTLSPSKOrder(pairingID: String, tlsPSKOrder: PeelTLSPSKOrder) {
        guard let idx = paired.firstIndex(where: { $0.id == pairingID }) else { return }
        guard paired[idx].tlsPSKOrder != tlsPSKOrder else { return }
        paired[idx].tlsPSKOrder = tlsPSKOrder
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

nonisolated enum PeelTLS {
    static let pskOrderTXTKey = "tlsPSKOrder"
    static let standardPSKOrderTXTValue = PeelTLSPSKOrder.standard.rawValue

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

        let tcp = NWProtocolTCP.Options()
        // Input, audio and recovery messages are latency-sensitive even when
        // smaller than one TCP segment. Keep existing TLS/PSK semantics.
        tcp.noDelay = true
        return NWParameters(tls: tls, tcp: tcp)
    }

    /// Creates a TLS-PSK secured NWParameters for the client connection.
    static func makeClientParameters(
        pairingID: String,
        psk: Data,
        pskOrder: PeelTLSPSKOrder
    ) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let secOptions = tls.securityProtocolOptions

        // The client presents exactly one identity+key (the one for the selected host).
        if !psk.isEmpty {
            addPSK(
                secOptions: secOptions,
                identity: pairingID,
                psk: psk,
                pskOrder: pskOrder
            )
        }

        appendPSKCipherSuite(secOptions: secOptions)

        let tcp = NWProtocolTCP.Options()
        // Input, audio and recovery messages are latency-sensitive even when
        // smaller than one TCP segment. Keep existing TLS/PSK semantics.
        tcp.noDelay = true
        return NWParameters(tls: tls, tcp: tcp)
    }

    static func advertisedPSKOrder(from service: NetService) -> PeelTLSPSKOrder? {
        guard let txtData = service.txtRecordData() else { return nil }
        let txt = NetService.dictionary(fromTXTRecord: txtData)
        guard let rawValue = txt[pskOrderTXTKey],
              let value = String(data: rawValue, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return PeelTLSPSKOrder(rawValue: value)
    }

    static func clientPSKOrder(
        for peer: PeelPairedPeer?,
        service: NetService
    ) -> PeelTLSPSKOrder {
        if peer?.tlsPSKOrder == .standard {
            return .standard
        }
        if advertisedPSKOrder(from: service) == .standard {
            return .standard
        }
        return .legacyIdentityFirst
    }

    private static func addPSK(
        secOptions: sec_protocol_options_t,
        identity: String,
        psk: Data,
        pskOrder: PeelTLSPSKOrder = .standard
    ) {
        let identityData = identity.data(using: .utf8) ?? Data()
        let ddIdentity = identityData.withUnsafeBytes { DispatchData(bytes: $0) }
        let ddPSK = psk.withUnsafeBytes { DispatchData(bytes: $0) }

        // NOTE: Sec APIs use __DispatchData.
        switch pskOrder {
        case .standard:
            sec_protocol_options_add_pre_shared_key(
                secOptions,
                ddPSK as __DispatchData,
                ddIdentity as __DispatchData
            )
        case .legacyIdentityFirst:
            // Client-only migration path for Host builds that predate the TXT marker.
            // Never register this ordering on a new Host listener.
            sec_protocol_options_add_pre_shared_key(
                secOptions,
                ddIdentity as __DispatchData,
                ddPSK as __DispatchData
            )
        }
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

    static func makePairingPinProof(pinPSK: Data, hostId: String, clientDeviceId: String) -> String {
        let normalizedHostId = hostId.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedClientDeviceId = clientDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = "peel-pin-proof-v1|\(normalizedHostId)|\(normalizedClientDeviceId)"
        let key = SymmetricKey(data: pinPSK)

        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: key
        )

        return Data(signature).base64EncodedString()
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
