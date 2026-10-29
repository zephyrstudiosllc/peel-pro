import Foundation

/// A peer capability negotiates this exchange; it never grants paid access.
nonisolated enum PeelProEntitlementProtocol {
    static let capability = "pro-entitlement-v1"
    static let maximumTokens = 4
    static let maximumTokenBytes = 32_768
    static let maximumWireBytes = 140_000
    static let challengeSeconds: TimeInterval = 30
    static let maximumLeaseSeconds: TimeInterval = 300
    static let refreshAfterSeconds: TimeInterval = 120
}

nonisolated struct PeelProEntitlementChallenge: Codable, Equatable, Sendable {
    let type: String
    let requestId: String
    let nonce: String
    let pairingId: String
    let sessionId: String
    let expiresAt: Double

    init(requestId: String, nonce: String, pairingId: String, sessionId: String, expiresAt: Double) {
        type = "proEntitlementChallenge"
        self.requestId = requestId
        self.nonce = nonce
        self.pairingId = pairingId
        self.sessionId = sessionId
        self.expiresAt = expiresAt
    }
}

nonisolated struct PeelProEntitlementProof: Codable, Equatable, Sendable {
    let type: String
    let requestId: String
    let nonce: String
    let pairingId: String
    let sessionId: String
    let signedTransactions: [String]

    init(requestId: String, nonce: String, pairingId: String, sessionId: String, signedTransactions: [String]) {
        type = "proEntitlementProof"
        self.requestId = requestId
        self.nonce = nonce
        self.pairingId = pairingId
        self.sessionId = sessionId
        self.signedTransactions = signedTransactions
    }
}

nonisolated struct PeelProEntitlementWithdrawal: Codable, Equatable, Sendable {
    let type: String
    let pairingId: String
    let sessionId: String

    init(pairingId: String, sessionId: String) {
        type = "proEntitlementWithdraw"
        self.pairingId = pairingId
        self.sessionId = sessionId
    }
}

nonisolated struct PeelProEntitlementStatus: Codable, Equatable, Sendable {
    let type: String
    let requestId: String
    let sessionId: String
    let state: String
    let expiresAt: Double?
    let reason: String

    init(requestId: String, sessionId: String, state: String, expiresAt: Double? = nil, reason: String) {
        type = "proEntitlementStatus"
        self.requestId = requestId
        self.sessionId = sessionId
        self.state = state
        self.expiresAt = expiresAt
        self.reason = reason
    }
}

/// Decode the input bytes before Codable can discard duplicate or unknown keys.
/// These are wire-shape checks. Current pairing, nonce, deadline and authority
/// checks belong to the owning live session and must still run after decoding.
nonisolated enum PeelProEntitlementWire {
    enum InvalidMessage: Error { case invalid }

    static func decodeChallenge(_ data: Data) throws -> PeelProEntitlementChallenge {
        let fields = try object(data, limit: 4_096)
        try keys(fields, required: ["type", "requestId", "nonce", "pairingId", "sessionId", "expiresAt"])
        try boundFields(fields, type: "proEntitlementChallenge")
        try timestamp(fields, "expiresAt")
        return try JSONDecoder().decode(PeelProEntitlementChallenge.self, from: data)
    }

    static func decodeProof(_ data: Data) throws -> PeelProEntitlementProof {
        let fields = try object(data, limit: PeelProEntitlementProtocol.maximumWireBytes)
        try keys(fields, required: ["type", "requestId", "nonce", "pairingId", "sessionId", "signedTransactions"])
        try boundFields(fields, type: "proEntitlementProof")
        guard case let .strings(tokens)? = fields["signedTransactions"],
              tokens.count <= PeelProEntitlementProtocol.maximumTokens,
              Set(tokens).count == tokens.count,
              tokens.allSatisfy(validCompactJWS) else { throw InvalidMessage.invalid }
        return try JSONDecoder().decode(PeelProEntitlementProof.self, from: data)
    }

    static func decodeWithdrawal(_ data: Data) throws -> PeelProEntitlementWithdrawal {
        let fields = try object(data, limit: 1_024)
        try keys(fields, required: ["type", "pairingId", "sessionId"])
        guard try string(fields, "type") == "proEntitlementWithdraw",
              validPairingID(try string(fields, "pairingId")),
              validUUID(try string(fields, "sessionId")) else { throw InvalidMessage.invalid }
        return try JSONDecoder().decode(PeelProEntitlementWithdrawal.self, from: data)
    }

    static func decodeStatus(_ data: Data) throws -> PeelProEntitlementStatus {
        let fields = try object(data, limit: 4_096)
        try keys(fields, required: ["type", "requestId", "sessionId", "state", "reason"], optional: ["expiresAt"])
        guard try string(fields, "type") == "proEntitlementStatus",
              validUUID(try string(fields, "requestId")),
              validUUID(try string(fields, "sessionId")),
              ["pending", "verified", "denied", "unavailable"].contains(try string(fields, "state")),
              statusReasons.contains(try string(fields, "reason")) else { throw InvalidMessage.invalid }
        if fields["expiresAt"] != nil { try timestamp(fields, "expiresAt") }
        let status = try JSONDecoder().decode(PeelProEntitlementStatus.self, from: data)
        if status.state == "verified" {
            guard status.reason == "active", status.expiresAt != nil else { throw InvalidMessage.invalid }
        } else if status.expiresAt != nil {
            throw InvalidMessage.invalid
        }
        return status
    }

    /// Used only on a response fetched directly by the Host. This does not add
    /// an authority-verdict message to the peer protocol or validate its grant.
    static func validateAuthorityResponseBytes(_ data: Data) throws {
        let fields = try object(data, limit: 4_096)
        let names: Set<String> = ["schema", "requestId", "nonce", "pairingId", "sessionId", "decision", "reason", "verifiedAt", "expiresAt"]
        try keys(fields, required: names, optional: ["productId", "ownership"])
        guard case .number(1)? = fields["schema"],
              validUUID(try string(fields, "requestId")),
              validUUID(try string(fields, "sessionId")),
              validPairingID(try string(fields, "pairingId")),
              validNonce(try string(fields, "nonce")) else { throw InvalidMessage.invalid }
        _ = try string(fields, "decision")
        _ = try string(fields, "reason")
        for name in ["productId", "ownership"] where fields[name] != nil { _ = try string(fields, name) }
        try timestamp(fields, "verifiedAt")
        try timestamp(fields, "expiresAt")
    }

    private static let statusReasons: Set<String> = [
        "pending", "active", "no_entitlement", "invalid_evidence", "revoked", "expired",
        "unsupported_environment", "unavailable", "verification_unavailable", "awaiting_proof",
        "pairing_changed", "client_withdrew", "unsupported_client"
    ]

    private static func boundFields(_ fields: [String: Value], type: String) throws {
        guard try string(fields, "type") == type,
              validUUID(try string(fields, "requestId")),
              validUUID(try string(fields, "sessionId")),
              validPairingID(try string(fields, "pairingId")),
              validNonce(try string(fields, "nonce")) else { throw InvalidMessage.invalid }
    }

    private static func validUUID(_ value: String) -> Bool {
        value.utf8.count == 36 && UUID(uuidString: value) != nil
    }

    private static func validPairingID(_ value: String) -> Bool {
        let bytes = value.utf8
        return !bytes.isEmpty && bytes.count <= 128 && bytes.allSatisfy {
            ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) ||
            ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95 || $0 == 46 || $0 == 58
        }
    }

    private static func validNonce(_ value: String) -> Bool {
        guard value.utf8.count == 44, let bytes = Data(base64Encoded: value), bytes.count == 32 else { return false }
        return bytes.base64EncodedString() == value
    }

    private static func validCompactJWS(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= PeelProEntitlementProtocol.maximumTokenBytes else { return false }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { part in
            !part.isEmpty && part.utf8.allSatisfy {
                ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) ||
                ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95
            }
        }
    }

    private static func string(_ fields: [String: Value], _ key: String) throws -> String {
        guard case let .string(value)? = fields[key] else { throw InvalidMessage.invalid }
        return value
    }

    private static func timestamp(_ fields: [String: Value], _ key: String) throws {
        guard case let .number(value)? = fields[key], value.isFinite, value > 0 else { throw InvalidMessage.invalid }
    }

    private static func keys(_ fields: [String: Value], required: Set<String>, optional: Set<String> = []) throws {
        let actual = Set(fields.keys)
        guard required.isSubset(of: actual), actual.isSubset(of: required.union(optional)) else { throw InvalidMessage.invalid }
    }

    private enum Value { case string(String), number(Double), strings([String]) }

    private static func object(_ data: Data, limit: Int) throws -> [String: Value] {
        guard !data.isEmpty, data.count <= limit else { throw InvalidMessage.invalid }
        var scanner = Scanner(bytes: Array(data))
        return try scanner.object()
    }

    /// A deliberately shallow JSON grammar: this protocol has no nested objects,
    /// booleans or nulls. String decoding uses Foundation for Unicode validation.
    private struct Scanner {
        let bytes: [UInt8]
        var index = 0

        mutating func object() throws -> [String: Value] {
            whitespace()
            try consume(123)
            whitespace()
            var fields: [String: Value] = [:]
            if take(125) {
                whitespace()
                guard index == bytes.count else { throw InvalidMessage.invalid }
                return fields
            }
            while true {
                guard fields.count < 12 else { throw InvalidMessage.invalid }
                let key = try string()
                guard key.utf8.count <= 64, fields[key] == nil else { throw InvalidMessage.invalid }
                whitespace()
                try consume(58)
                whitespace()
                let value: Value
                guard let next = peek else { throw InvalidMessage.invalid }
                switch next {
                case 34: value = .string(try string())
                case 91: value = .strings(try strings())
                case 45, 48...57: value = .number(try number())
                default: throw InvalidMessage.invalid
                }
                fields[key] = value
                whitespace()
                if take(125) { break }
                try consume(44)
                whitespace()
            }
            whitespace()
            guard index == bytes.count else { throw InvalidMessage.invalid }
            return fields
        }

        private var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

        private mutating func strings() throws -> [String] {
            try consume(91)
            whitespace()
            var values: [String] = []
            if take(93) { return values }
            while true {
                guard values.count < PeelProEntitlementProtocol.maximumTokens else { throw InvalidMessage.invalid }
                values.append(try string())
                whitespace()
                if take(93) { return values }
                try consume(44)
                whitespace()
            }
        }

        private mutating func string() throws -> String {
            let start = index
            try consume(34)
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte == 34 {
                    let value = try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
                    guard value.utf8.count <= PeelProEntitlementProtocol.maximumTokenBytes else { throw InvalidMessage.invalid }
                    return value
                }
                guard byte >= 32 else { throw InvalidMessage.invalid }
                if byte == 92 {
                    guard index < bytes.count else { throw InvalidMessage.invalid }
                    index += 1
                }
            }
            throw InvalidMessage.invalid
        }

        private mutating func number() throws -> Double {
            let start = index
            while let byte = peek, byte != 44 && byte != 125 && byte != 32 && byte != 9 && byte != 10 && byte != 13 {
                index += 1
                guard index - start <= 32 else { throw InvalidMessage.invalid }
            }
            let value = try JSONDecoder().decode(Double.self, from: Data(bytes[start..<index]))
            guard value.isFinite else { throw InvalidMessage.invalid }
            return value
        }

        private mutating func whitespace() {
            while let byte = peek, byte == 32 || byte == 9 || byte == 10 || byte == 13 { index += 1 }
        }

        private mutating func take(_ byte: UInt8) -> Bool {
            guard peek == byte else { return false }
            index += 1
            return true
        }

        private mutating func consume(_ byte: UInt8) throws {
            guard take(byte) else { throw InvalidMessage.invalid }
        }
    }
}
