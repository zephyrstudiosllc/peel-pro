import Foundation

// This keeps the focused migration fixture independent of PeelTLS.swift and
// its Security/Network/CryptoKit dependencies while matching the persisted
// Codable model fields used by the Host target.
enum PeelTLSPSKOrder: String, Codable, Hashable {
    case standard = "psk-identity"
    case legacyIdentityFirst = "identity-psk"
}

struct PeelPairedPeer: Codable, Hashable {
    let id: String
    var displayName: String
    var serviceName: String?
    var createdAt: Date
    var lastSeenAt: Date?
    var stableHostId: String?
    var tlsPSKOrder: PeelTLSPSKOrder?

    init(
        id: String,
        displayName: String,
        serviceName: String? = nil,
        stableHostId: String? = nil,
        tlsPSKOrder: PeelTLSPSKOrder? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        lastSeenAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.serviceName = serviceName
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.stableHostId = stableHostId
        self.tlsPSKOrder = tlsPSKOrder
    }
}
