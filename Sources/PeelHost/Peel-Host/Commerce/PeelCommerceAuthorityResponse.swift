import Foundation

/// Strict schema for a response received directly from the configured HTTPS
/// authority. This type is intentionally absent from the peer wire protocol.
nonisolated struct PeelCommerceAuthorityResponse: Decodable, Sendable {
    let schema: Int
    let requestId: String
    let nonce: String
    let pairingId: String
    let sessionId: String
    let decision: String
    let reason: String
    let productId: String?
    let ownership: String?
    let verifiedAt: TimeInterval
    let expiresAt: TimeInterval

    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 140_000 else { throw PeelCommerceAuthorityError.invalidResponse }
        try PeelProEntitlementWire.validateAuthorityResponseBytes(data)
        return try JSONDecoder().decode(Self.self, from: data)
    }

    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
        static func key(_ name: String) -> Self { Self(stringValue: name)! }
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Key.self)
        let required: Set<String> = ["schema", "requestId", "nonce", "pairingId", "sessionId", "decision", "reason", "verifiedAt", "expiresAt"]
        let keys = Set(values.allKeys.map(\.stringValue))
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(["productId", "ownership"])) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid authority schema"))
        }
        schema = try values.decode(Int.self, forKey: .key("schema"))
        requestId = try values.decode(String.self, forKey: .key("requestId"))
        nonce = try values.decode(String.self, forKey: .key("nonce"))
        pairingId = try values.decode(String.self, forKey: .key("pairingId"))
        sessionId = try values.decode(String.self, forKey: .key("sessionId"))
        decision = try values.decode(String.self, forKey: .key("decision"))
        reason = try values.decode(String.self, forKey: .key("reason"))
        productId = keys.contains("productId") ? try values.decode(String.self, forKey: .key("productId")) : nil
        ownership = keys.contains("ownership") ? try values.decode(String.self, forKey: .key("ownership")) : nil
        verifiedAt = try values.decode(Double.self, forKey: .key("verifiedAt"))
        expiresAt = try values.decode(Double.self, forKey: .key("expiresAt"))
        let products = ["peel.pro.lifetime", "peel.pro.monthly", "peel.pro.yearly", "peel.pro.3day.freetrial"]
        let denied = ["no_entitlement", "invalid_evidence", "revoked", "expired", "unsupported_environment"]
        let shapeValid = decision == "granted"
            ? (reason == "active" && productId.map(products.contains) == true &&
               ownership.map({ ["purchased", "familyShared"].contains($0) }) == true && expiresAt > verifiedAt)
            : (decision == "denied" && denied.contains(reason) && productId == nil && ownership == nil && expiresAt == verifiedAt)
        guard schema == 1, UUID(uuidString: requestId) != nil, UUID(uuidString: sessionId) != nil,
              !pairingId.isEmpty, pairingId.utf8.count <= 256,
              PeelHostProAdmissionState.isCanonicalNonce(nonce),
              verifiedAt.isFinite, expiresAt.isFinite, shapeValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid authority decision"))
        }
    }

    func matches(_ challenge: PeelProEntitlementChallenge) -> Bool {
        schema == 1 && requestId == challenge.requestId && nonce == challenge.nonce &&
            pairingId == challenge.pairingId && sessionId == challenge.sessionId
    }

}
