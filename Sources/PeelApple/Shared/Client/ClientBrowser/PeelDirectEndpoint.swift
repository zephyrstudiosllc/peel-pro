//
//  PeelDirectEndpoint.swift
//  Peel
//
//  Client-only saved transport endpoints for already paired Macs.
//

import Foundation
import Network

/// A host and port supplied by the user for a Mac that is already paired.
/// This value performs no DNS or network work and intentionally carries no URL
/// scheme, path, credentials, or executable content.
struct PeelDirectEndpoint: Codable, Hashable {
    let host: String
    let port: UInt16

    private enum CodingKeys: String, CodingKey {
        case host
        case port
    }

    init?(host rawHost: String, port: UInt16) {
        guard let host = Self.normalizeHost(rawHost), port > 0 else { return nil }
        self.host = host
        self.port = port
    }

    static func normalizeHost(_ rawHost: String) -> String? {
        var candidate = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate.utf8.count <= 255 else { return nil }

        // Accept bracketed IPv6 input, but store the host without brackets for
        // Network.framework. A bare IPv6 address remains valid.
        if candidate.first == "[" || candidate.last == "]" {
            guard candidate.first == "[", candidate.last == "]" else { return nil }
            candidate.removeFirst()
            candidate.removeLast()
            guard !candidate.isEmpty else { return nil }
        }

        guard !candidate.contains("[") && !candidate.contains("]") else { return nil }

        let forbidden: Set<Character> = ["/", "\\", "?", "#", "%", "@", ",", ";"]
        let whitespaceOrControls = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard candidate.rangeOfCharacter(from: whitespaceOrControls) == nil,
              candidate.unicodeScalars.allSatisfy({ scalar in
                  scalar.value >= 0x21 && scalar.value != 0x7F
              }),
              !candidate.contains(where: { forbidden.contains($0) }) else {
            return nil
        }

        return candidate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawHost = try container.decode(String.self, forKey: .host)
        let port = try container.decode(UInt16.self, forKey: .port)
        guard let endpoint = Self(host: rawHost, port: port) else {
            throw DecodingError.dataCorruptedError(
                forKey: .host,
                in: container,
                debugDescription: "Invalid direct endpoint host or port"
            )
        }
        self = endpoint
    }
}

/// Client-only metadata keyed by an exact existing pairing. The PSK remains
/// in Keychain; this record stores only the transport endpoint and the PSK
/// identity order learned by a successful local connection.
struct PeelDirectEndpointRecord: Codable, Hashable {
    let pairingID: String
    let stableHostID: String?
    let endpoint: PeelDirectEndpoint
    let tlsPSKOrder: PeelTLSPSKOrder

    private enum CodingKeys: String, CodingKey {
        case pairingID
        case stableHostID
        case endpoint
        case tlsPSKOrder
    }

    init?(pairingID rawPairingID: String,
          stableHostID rawStableHostID: String? = nil,
          endpoint: PeelDirectEndpoint,
          tlsPSKOrder: PeelTLSPSKOrder) {
        let pairingID = rawPairingID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pairingID.isEmpty,
              pairingID.utf8.count <= 256,
              pairingID.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value != 0x7F }) else {
            return nil
        }

        let stableHostID = rawStableHostID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let stableHostID {
            guard !stableHostID.isEmpty,
                  stableHostID.utf8.count <= 256,
                  stableHostID.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value != 0x7F }) else {
                return nil
            }
        }

        self.pairingID = pairingID
        self.stableHostID = stableHostID
        self.endpoint = endpoint
        self.tlsPSKOrder = tlsPSKOrder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let pairingID = try container.decode(String.self, forKey: .pairingID)
        let stableHostID = try container.decodeIfPresent(String.self, forKey: .stableHostID)
        let endpoint = try container.decode(PeelDirectEndpoint.self, forKey: .endpoint)
        let tlsPSKOrder = try container.decode(PeelTLSPSKOrder.self, forKey: .tlsPSKOrder)
        guard let record = Self(
            pairingID: pairingID,
            stableHostID: stableHostID,
            endpoint: endpoint,
            tlsPSKOrder: tlsPSKOrder
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .pairingID,
                in: container,
                debugDescription: "Invalid direct endpoint pairing metadata"
            )
        }
        self = record
    }
}

/// A bounded client-only collection. This is persisted separately from the
/// shared pairing model and never contains keychain PSK material.
struct PeelDirectEndpointStore: Codable, Equatable {
    static let maxEntries = 16
    private(set) var records: [PeelDirectEndpointRecord]

    private enum CodingKeys: String, CodingKey {
        case records
    }

    init(records: [PeelDirectEndpointRecord] = []) {
        self.records = []
        for record in records {
            _ = upsert(record)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let records = try container.decode([PeelDirectEndpointRecord].self, forKey: .records)
        guard records.count <= Self.maxEntries else {
            throw DecodingError.dataCorruptedError(
                forKey: .records,
                in: container,
                debugDescription: "Too many direct endpoint records"
            )
        }
        self.init(records: records)
    }

    func record(for pairingID: String) -> PeelDirectEndpointRecord? {
        records.first { $0.pairingID == pairingID }
    }

    @discardableResult
    mutating func upsert(_ record: PeelDirectEndpointRecord) -> Bool {
        if let index = records.firstIndex(where: { $0.pairingID == record.pairingID }) {
            records[index] = record
            return true
        }
        guard records.count < Self.maxEntries else { return false }
        records.append(record)
        return true
    }

    mutating func remove(pairingID: String) {
        records.removeAll { $0.pairingID == pairingID }
    }
}

struct PeelSessionTransportEndpoint: Equatable {
    let host: String
    let port: UInt16
}

enum PeelDirectEndpointMutationResult: Equatable {
    case saved
    case removed
    case invalidEndpoint
    case pairingUnavailable
    case missingPSKOrder
    case storageFull

    private var clientProductName: String {
#if os(visionOS)
        return "Peel Pro"
#elseif os(iOS)
        return "Peel Pro"
#else
        return "Peel Pro"
#endif
    }

    var userMessage: String {
        switch self {
        case .saved:
            return "Address saved."
        case .removed:
            return "Saved address removed."
        case .invalidEndpoint:
            return "Enter a host name or IP address and a port from 1 to 65535."
        case .pairingUnavailable:
            return "This computer is no longer paired. Pair it again before saving an address."
        case .missingPSKOrder:
            return "Connect to this computer once on the local network so \(clientProductName) can learn its TLS compatibility, then save a direct address."
        case .storageFull:
            return "Remove a saved address before adding another."
        }
    }
}

extension PeelHostInfo {
    /// A descriptor for an explicitly saved endpoint. The synthetic
    /// NetService is never resolved or browsed; it exists only because the
    /// existing host/session model carries a nonoptional service descriptor.
    static func direct(
        displayName: String,
        pairingID: String,
        stableHostID: String?,
        endpoint: PeelDirectEndpoint
    ) -> PeelHostInfo {
        let service = NetService(
            domain: "local.",
            type: "_peel._tcp.",
            name: "Direct-\(pairingID)",
            port: Int32(endpoint.port)
        )
        return PeelHostInfo(
            name: displayName.isEmpty ? "Paired Mac" : displayName,
            service: service,
            hostId: stableHostID,
            directPairingID: pairingID,
            directEndpoint: endpoint
        )
    }
}

extension PeelClientBrowser {
    private static let directEndpointDefaultsKey = "Peel.client.directEndpoints.v1"

    func loadDirectEndpointStore() {
        guard let data = UserDefaults.standard.data(forKey: Self.directEndpointDefaultsKey) else {
            return
        }

        do {
            let decoded = try JSONDecoder().decode(PeelDirectEndpointStore.self, from: data)
            // Pairing removal can happen in another app lifecycle. Do not keep
            // orphaned endpoint records occupying the bounded store.
            let currentPairingIDs = Set(pairingStore.paired.map(\.id))
            let validRecords = decoded.records.filter { currentPairingIDs.contains($0.pairingID) }
            directEndpointStore = PeelDirectEndpointStore(records: validRecords)
        } catch {
            directEndpointStore = PeelDirectEndpointStore()
        }
    }

    func persistDirectEndpointStore() {
        guard let data = try? JSONEncoder().encode(directEndpointStore) else { return }
        UserDefaults.standard.set(data, forKey: Self.directEndpointDefaultsKey)
    }

    func directEndpointRecord(for pairingID: String) -> PeelDirectEndpointRecord? {
        directEndpointStore.record(for: pairingID.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func pairedPeer(forPairingID pairingID: String) -> PeelPairedPeer? {
        let normalized = pairingID.trimmingCharacters(in: .whitespacesAndNewlines)
        return pairingStore.paired.first { $0.id == normalized }
    }

    @discardableResult
    func saveDirectEndpoint(for pairingID: String, endpoint: PeelDirectEndpoint) -> PeelDirectEndpointMutationResult {
        guard let peer = pairedPeer(forPairingID: pairingID) else {
            return .pairingUnavailable
        }

        guard let pskOrder = peer.tlsPSKOrder ?? directEndpointRecord(for: peer.id)?.tlsPSKOrder else {
            return .missingPSKOrder
        }

        guard let record = PeelDirectEndpointRecord(
            pairingID: peer.id,
            stableHostID: peer.stableHostId,
            endpoint: endpoint,
            tlsPSKOrder: pskOrder
        ) else {
            return .invalidEndpoint
        }

        var updatedStore = directEndpointStore
        guard updatedStore.upsert(record) else { return .storageFull }
        directEndpointStore = updatedStore
        persistDirectEndpointStore()

        // If a direct session already exists, update only its saved transport
        // target. The next explicit connect or automatic reconnect will use it.
        for session in sessionsByHostKey.values where session.directPairingID == peer.id {
            session.configureDirectEndpoint(record)
        }
        return .saved
    }

    @discardableResult
    func removeDirectEndpoint(for pairingID: String) -> PeelDirectEndpointMutationResult {
        let normalized = pairingID.trimmingCharacters(in: .whitespacesAndNewlines)
        if directEndpointStore.record(for: normalized) != nil {
            var updatedStore = directEndpointStore
            updatedStore.remove(pairingID: normalized)
            directEndpointStore = updatedStore
            persistDirectEndpointStore()
        }

        // Removing an endpoint invalidates any current direct session. Drop the
        // session object so a later Bonjour tap gets a fresh, real descriptor.
        let directSessions = sessionsByHostKey.values.filter { $0.directPairingID == normalized }
        for session in directSessions {
            let wasSelected = selectedHostKey == session.hostKey
            session.invalidateDirectEndpoint(reason: "saved address removed")
            if wasSelected {
                lastConnectedHost = nil
                lastConnectedHostName = nil
                activePairingID = nil
            }
            removeSession(for: session.hostKey)
        }
        return .removed
    }

    func isConnectedToDirectEndpoint(for pairingID: String) -> Bool {
        let normalized = pairingID.trimmingCharacters(in: .whitespacesAndNewlines)
        return sessionsByHostKey.values.contains {
            $0.directPairingID == normalized && $0.connection != nil && $0.isConnectionReady
        }
    }

    @discardableResult
    func connectToDirectEndpoint(for pairingID: String) -> Bool {
        let normalized = pairingID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let record = directEndpointRecord(for: normalized) else {
            let message = "Save a direct address for this paired computer first."
            status = message
            pairingStatus = message
            return false
        }
        guard let peer = pairedPeer(forPairingID: normalized) else {
            let message = "This computer is no longer paired. Pair it again before connecting by address."
            status = message
            pairingStatus = message
            return false
        }
        guard let psk = pairingStore.psk(for: peer.id), !psk.isEmpty else {
            let message = "Pairing material is unavailable. Pair this computer again before connecting by address."
            status = message
            pairingStatus = message
            return false
        }

        let descriptor = PeelHostInfo.direct(
            displayName: peer.displayName,
            pairingID: peer.id,
            stableHostID: record.stableHostID,
            endpoint: record.endpoint
        )
        let targetSession = session(for: descriptor)
        let wasDirect = targetSession.isUsingDirectEndpoint
        targetSession.configureDirectEndpoint(record)
        if targetSession.connection != nil && !wasDirect {
            targetSession.resetSession(reason: "Switching to direct address")
        }
        selectedHostKey = targetSession.hostKey
        targetSession.connectAndRequestWindows(isAutoReconnect: false, skipResolve: true)
        return true
    }
}

extension PeelHostSession {
    var isUsingDirectEndpoint: Bool {
        directEndpointRecord != nil
    }

    var directPairingID: String? {
        directEndpointRecord?.pairingID
    }

    func configureDirectEndpoint(_ record: PeelDirectEndpointRecord) {
        directEndpointRecord = record
        host = PeelHostInfo.direct(
            displayName: host.name,
            pairingID: record.pairingID,
            stableHostID: record.stableHostID,
            endpoint: record.endpoint
        )
    }

    func invalidateDirectEndpoint(reason: String) {
        suppressAutoReconnect = true
        pendingReconnectWhenVisible = false
        pendingReconnectReason = nil
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        delayedConnectWorkItem?.cancel()
        delayedConnectWorkItem = nil
        reconnectAttempt = 0
        directEndpointRecord = nil
        if connection != nil {
            resetSession(reason: reason)
        } else {
            status = "Disconnected (\(reason))"
        }
    }

    func currentTransportEndpoint() -> PeelSessionTransportEndpoint? {
        if let endpoint = directEndpointRecord?.endpoint {
            return PeelSessionTransportEndpoint(host: endpoint.host, port: endpoint.port)
        }

        guard let hostName = host.service.hostName,
              let port = UInt16(exactly: host.service.port),
              port > 0 else {
            return nil
        }
        return PeelSessionTransportEndpoint(host: hostName, port: port)
    }

    /// Direct sessions use this exact pairing ID. Bonjour sessions retain the
    /// existing matching behavior through `pairedPeer(for:)`.
    func connectionPeer() -> PeelPairedPeer? {
        guard let browser else { return nil }
        if let pairingID = directPairingID {
            return browser.pairedPeer(forPairingID: pairingID)
        }
        return browser.pairedPeer(for: host)
    }

    func transportPSKOrder(for peer: PeelPairedPeer) -> PeelTLSPSKOrder? {
        if let directOrder = directEndpointRecord?.tlsPSKOrder {
            return directOrder
        }
        return PeelTLS.clientPSKOrder(for: peer, service: host.service)
    }
}

// BEGIN PeelHomeComputerProjection
/// One home-list candidate: a discovered host or a saved-address session,
/// with the identity and state the browser already resolved for it.
struct PeelHomeComputerCandidate<Host> {
    let host: Host
    let key: String
    /// Saved pairing identity; nil for an unpaired discovered host.
    let pairingID: String?
    /// Ready connection on this candidate's own session.
    let isConnected: Bool
    /// Ready, or connecting on its own session.
    let isActive: Bool
}

/// Which computers the home list shows and where. Saved-address sessions
/// never enter discovery; they appear only as their own exact saved pairing
/// while their session is active, so a VPN-only connection is not hidden
/// behind an empty Bonjour list.
struct PeelHomeComputerProjection<Host, Saved> {
    /// Connected discovered hosts, then active saved-address sessions.
    let connected: [Host]
    /// Discovered hosts that are not connected and do not duplicate an
    /// active saved-address session for the same pairing.
    let other: [Host]
    /// Saved pairings not already represented by a listed computer.
    let saved: [Saved]
    let hasDiscoveredComputers: Bool

    init(
        discovered: [PeelHomeComputerCandidate<Host>],
        directSessions: [PeelHomeComputerCandidate<Host>],
        saved: [Saved],
        savedPairingID: (Saved) -> String
    ) {
        let savedIDs = Set(saved.map(savedPairingID))
        let connectedDiscovered = discovered.filter { $0.isConnected }
        var claimedPairingIDs = Set(connectedDiscovered.compactMap { $0.pairingID })
        var claimedKeys = Set(connectedDiscovered.map { $0.key })
        var activeDirect: [PeelHomeComputerCandidate<Host>] = []

        for session in directSessions where session.isActive {
            // A saved-address session is shown only for a pairing that is
            // still saved, once per pairing, and never beside a discovered
            // connection to that same pairing.
            guard let pairingID = session.pairingID,
                  savedIDs.contains(pairingID),
                  !claimedPairingIDs.contains(pairingID),
                  !claimedKeys.contains(session.key) else { continue }
            claimedPairingIDs.insert(pairingID)
            claimedKeys.insert(session.key)
            activeDirect.append(session)
        }

        let directPairingIDs = Set(activeDirect.compactMap { $0.pairingID })
        connected = (connectedDiscovered + activeDirect).map { $0.host }
        other = discovered
            .filter { candidate in
                guard !candidate.isConnected else { return false }
                guard let pairingID = candidate.pairingID else { return true }
                return !directPairingIDs.contains(pairingID)
            }
            .map { $0.host }

        let represented = claimedPairingIDs.union(discovered.compactMap { $0.pairingID })
        self.saved = saved.filter { !represented.contains(savedPairingID($0)) }
        hasDiscoveredComputers = !discovered.isEmpty
    }

    /// The searching view is only for having nothing to show: no discovery,
    /// no active computer and no connected session content.
    func showsComputerList(hasConnectedSession: Bool) -> Bool {
        hasDiscoveredComputers || !connected.isEmpty || hasConnectedSession
    }
}
// END PeelHomeComputerProjection

extension PeelClientBrowser {
    /// Home-list projection from the real discovery list, saved-address
    /// sessions and saved pairings. Nothing is added to discovery. Every
    /// candidate's state comes from the session that owns its transport,
    /// never from the selected session's global host name.
    func homeComputerProjection() -> PeelHomeComputerProjection<PeelHostInfo, PeelSavedPairedMac> {
        func state(of session: PeelHostSession?) -> (ready: Bool, active: Bool) {
            guard let session else { return (ready: false, active: false) }
            let ready = session.connection != nil && session.isConnectionReady
            return (ready: ready, active: ready || session.connection != nil || session.isConnectBusy ||
                    session.pendingConnectHost != nil)
        }

        let discovered = hosts.map { host -> PeelHomeComputerCandidate<PeelHostInfo> in
            let owned = state(of: owningSession(for: host))
            return PeelHomeComputerCandidate(
                host: host,
                key: host.hostKey.rawValue,
                pairingID: pairedPeer(for: host)?.id,
                isConnected: owned.ready,
                isActive: owned.active
            )
        }

        let directSessions = sessionsByHostKey.values
            .filter { $0.isUsingDirectEndpoint }
            .sorted { ($0.host.name, $0.hostKey.rawValue) < ($1.host.name, $1.hostKey.rawValue) }
            .map { session -> PeelHomeComputerCandidate<PeelHostInfo> in
                let owned = state(of: session)
                return PeelHomeComputerCandidate(
                    host: session.host,
                    key: session.hostKey.rawValue,
                    pairingID: session.directPairingID,
                    isConnected: owned.ready,
                    isActive: owned.active
                )
            }

        return PeelHomeComputerProjection(
            discovered: discovered,
            directSessions: directSessions,
            saved: savedPairedMacs,
            savedPairingID: { $0.id }
        )
    }
}
