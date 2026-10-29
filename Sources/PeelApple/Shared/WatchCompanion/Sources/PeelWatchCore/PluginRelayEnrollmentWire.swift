import Foundation

/// Separate enrollment channel, never the v1 draft or v2 cloud courier. No code,
/// verifier, provider token, broker bearer or private key crosses this wire.
public struct PluginRelayEnrollmentWire: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case keyRequest, keyResponse, signChallenge, signatureResponse, installGrant, installed, invalidate
        case renewChallengeRequest, renewChallenge, renewProof, renewed, renewalUnavailable, resumeRequest, resumeAcknowledged
    }
    public static let maximumBytes = 16 * 1_024
    public let channel: String
    public let version: Int
    public let courierID: UUID
    public let kind: Kind
    public let publicKey: String?
    public let challenge: PluginRelayEnrollmentChallenge?
    public let phoneSignature: String?
    public let watchSignature: String?
    public let challengeID: UUID?
    public let routeGrant: String?
    public let grantID: UUID?
    public let provider: CloudAgentProvider?
    public let resumeContext: PluginRelayWatchResumeContext?
    public let resumeChallenge: PluginRelayWatchResumeChallenge?
    public let renewalFailure: String?
    public init(courierID: UUID, kind: Kind, publicKey: String? = nil,
                challenge: PluginRelayEnrollmentChallenge? = nil, phoneSignature: String? = nil,
                watchSignature: String? = nil, challengeID: UUID? = nil,
                routeGrant: String? = nil, grantID: UUID? = nil, provider: CloudAgentProvider? = nil,
                resumeContext: PluginRelayWatchResumeContext? = nil, resumeChallenge: PluginRelayWatchResumeChallenge? = nil,
                renewalFailure: String? = nil) throws {
        channel = "peel.watch.cloud.enrollment.v1"; version = 1; self.courierID = courierID; self.kind = kind
        self.publicKey = publicKey; self.challenge = challenge; self.phoneSignature = phoneSignature
        self.watchSignature = watchSignature; self.challengeID = challengeID; self.routeGrant = routeGrant; self.grantID = grantID
        self.provider = provider
        self.resumeContext = resumeContext; self.resumeChallenge = resumeChallenge; self.renewalFailure = renewalFailure
        try validate()
    }
    private func validate() throws {
        guard channel == "peel.watch.cloud.enrollment.v1", version == 1 else { throw PluginRelayEnrollmentError.invalidInput }
        let present = Set([(publicKey != nil, "publicKey"), (challenge != nil, "challenge"),
            (phoneSignature != nil, "phoneSignature"), (watchSignature != nil, "watchSignature"),
            (challengeID != nil, "challengeID"), (routeGrant != nil, "routeGrant"), (grantID != nil, "grantID"), (provider != nil, "provider"),
            (resumeContext != nil, "resumeContext"), (resumeChallenge != nil, "resumeChallenge"), (renewalFailure != nil, "renewalFailure")]
            .compactMap { $0.0 ? $0.1 : nil })
        guard present == Self.payload(kind) else { throw PluginRelayEnrollmentError.invalidInput }
        if let publicKey { _ = try PluginRelayEnrollmentCrypto.publicKey(publicKey) }
        for signature in [phoneSignature, watchSignature].compactMap({ $0 }) {
            _ = try PluginRelayEnrollmentCrypto.decodeBase64URL(signature, maximum: 80)
        }
        if let routeGrant {
            guard (1...8_192).contains(routeGrant.utf8.count), routeGrant.utf8.allSatisfy({ (33...126).contains($0) }) else {
                throw PluginRelayEnrollmentError.invalidInput
            }
        }
        try resumeContext?.validate(); try resumeChallenge?.context.validate()
        if let renewalFailure {
            guard ["temporarilyUnavailable", "explicitConnectRequired", "revoked"].contains(renewalFailure) else { throw PluginRelayEnrollmentError.invalidInput }
        }
    }
    private static func payload(_ kind: Kind) -> Set<String> {
        switch kind {
        case .keyRequest: return []
        case .invalidate, .resumeRequest, .resumeAcknowledged: return ["provider"]
        case .keyResponse: return ["publicKey"]
        case .signChallenge: return ["challenge", "phoneSignature"]
        case .signatureResponse: return ["watchSignature", "challengeID"]
        case .installGrant: return ["routeGrant"]
        case .installed: return ["grantID"]
        case .renewChallengeRequest: return ["resumeContext"]
        case .renewChallenge: return ["resumeChallenge", "phoneSignature"]
        case .renewProof: return ["challengeID", "watchSignature"]
        case .renewed: return ["routeGrant"]
        case .renewalUnavailable: return ["renewalFailure"]
        }
    }
    public func encoded() throws -> Data {
        try validate(); let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let raw = try JSONSerialization.jsonObject(with: encoder.encode(self))
        let data = try JSONSerialization.data(withJSONObject: Self.canonicalUUIDs(raw), options: [.sortedKeys])
        guard data.count <= Self.maximumBytes else { throw PluginRelayEnrollmentError.invalidInput }; return data
    }
    private static func canonicalUUIDs(_ value: Any, key: String? = nil) -> Any {
        let names: Set<String> = ["courierID", "challengeID", "transactionID", "localEpoch", "enrollmentID", "grantID",
                                  "generation", "accountGeneration", "pairingEpoch"]
        if let text = value as? String, let key, names.contains(key), let id = UUID(uuidString: text) {
            return id.uuidString.lowercased()
        }
        if let object = value as? [String: Any] { return object.mapValues { $0 }.reduce(into: [String: Any]()) { $0[$1.key] = canonicalUUIDs($1.value, key: $1.key) } }
        if let array = value as? [Any] { return array.map { canonicalUUIDs($0) } }
        return value
    }
    public static func decode(_ data: Data, expectedCourierID: UUID? = nil) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else { throw PluginRelayEnrollmentError.invalidInput }
        let raw = try PluginRelayCourierJSON.parse(data)
        guard case .object(let root) = raw, let kind = Kind(rawValue: try root.required("kind").string()) else {
            throw PluginRelayEnrollmentError.invalidInput
        }
        _ = try raw.object(keys: Set(["channel", "version", "courierID", "kind"]).union(payload(kind)))
        if kind == .signChallenge {
            let object = try root.required("challenge").object(keys: ["challengeID", "challenge", "provider", "transactionID", "clientID", "redirectURI",
                "codeChallenge", "expectedNonce", "phonePublicKey", "watchPublicKey", "localEpoch", "expiresAt"])
            for name in ["challengeID", "transactionID", "localEpoch"] { try canonicalUUID(object.required(name)) }
            _ = try object.required("expiresAt").integer()
        }
        if kind == .renewChallengeRequest { try contextSchema(root.required("resumeContext")) }
        if kind == .renewChallenge {
            let object = try root.required("resumeChallenge").object(keys: ["challengeID", "nonce", "expiresAt", "context"])
            try contextSchema(object.required("context")); _ = try object.required("expiresAt").integer()
        }
        let value = try JSONDecoder().decode(Self.self, from: data); try value.validate()
        if let expectedCourierID, value.courierID != expectedCourierID { throw PluginRelayEnrollmentError.invalidInput }
        return value
    }
    private static func canonicalUUID(_ value: PluginRelayCourierJSON) throws {
        let raw = try value.string()
        guard let id = UUID(uuidString: raw), id.uuidString.lowercased() == raw else { throw PluginRelayEnrollmentError.invalidInput }
    }
    private static func contextSchema(_ raw: PluginRelayCourierJSON) throws {
        let object = try raw.object(keys: ["issuer", "enrollmentID", "phoneDeviceID", "fence", "phonePublicKey", "watchPublicKey"])
        let fence = try object.required("fence").object(keys: ["binding", "localEpoch"])
        let binding = try fence.required("binding").object(keys: ["route", "pairingEpoch"])
        _ = try binding.required("route").object(keys: ["kind", "provider", "routeID", "generation", "accountGeneration"])
    }
    /// Classification only; never a successful decode or authority. A claimed
    /// packet is consumed/rejected in this channel and must not fall through.
    public static func claims(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= maximumBytes,
              let raw = try? PluginRelayCourierJSON.parse(data), case .object(let object) = raw,
              let channel = try? object.required("channel").string() else { return false }
        return channel == "peel.watch.cloud.enrollment.v1"
    }
}
