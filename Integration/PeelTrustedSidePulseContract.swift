//
//  PeelTrustedSidePulseContract.swift
//  Isolated trusted SidePulse handshake and frame envelope contract.
//
//  This file is deliberately independent of SidePulse's NearbySignal types.
//  It validates bounded wire values and derives role-separated HMAC proofs;
//  root owns TLS, socket identity, generation, and timeout enforcement.
//

import Foundation
import CryptoKit

nonisolated public enum PeelSignalContractError: Error, Equatable, Sendable, LocalizedError {
    case wrongMessageType(expected: String, actual: String)
    case invalidUUID(field: String)
    case invalidNonce(field: String, byteCount: Int)
    case invalidProof(byteCount: Int)
    case invalidKey(byteCount: Int)
    case invalidFramePayload(byteCount: Int)
    case messageTooLarge(byteCount: Int)
    case invalidFieldEncoding(field: String)

    public var errorDescription: String? {
        switch self {
        case let .wrongMessageType(expected, actual):
            return "Expected \(expected), received \(actual)."
        case let .invalidUUID(field):
            return "\(field) must be a UUID string."
        case let .invalidNonce(field, byteCount):
            return "\(field) must decode to exactly 32 bytes; received \(byteCount)."
        case let .invalidProof(byteCount):
            return "proof must contain exactly 32 bytes; received \(byteCount)."
        case let .invalidKey(byteCount):
            return "The pairing key must contain exactly 32 bytes; received \(byteCount)."
        case let .invalidFramePayload(byteCount):
            return "The frame payload must be at most 8192 bytes; received \(byteCount)."
        case let .messageTooLarge(byteCount):
            return "The JSON message is larger than its wire limit; received \(byteCount) bytes."
        case let .invalidFieldEncoding(field):
            return "\(field) has an invalid encoding."
        }
    }
}

nonisolated public enum PeelSignalContract {
    public static let maximumJSONBytes = 4_096
    public static let maximumFrameJSONBytes = 12_288
    public static let nonceBytes = 32
    public static let proofBytes = 32
    public static let keyBytes = 32
    public static let maximumFramePayloadBytes = 8_192

    public static let serverProofDomain = "peel.sidepulse.server.v1"
    public static let clientProofDomain = "peel.sidepulse.client.v1"
    /// Used only when the challenge explicitly answers a hello's feature list.
    /// Both lists are bound into the transcript; v1 never carries features.
    public static let serverProofDomainV2 = "peel.sidepulse.server.v2"
    public static let clientProofDomainV2 = "peel.sidepulse.client.v2"
    public static let maximumFeatures = 8
    public static let maximumFeatureBytes = 32

    public static func canonicalUUID(_ value: UUID) -> String {
        value.uuidString.lowercased()
    }

    public static func decodeUUID<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key,
        field: String
    ) throws -> UUID {
        let raw = try container.decode(String.self, forKey: key)
        guard let value = UUID(uuidString: raw),
              raw.count == 36,
              (raw == raw.lowercased() || raw == raw.uppercased()),
              value.uuidString.lowercased() == raw.lowercased() else {
            throw PeelSignalContractError.invalidUUID(field: field)
        }
        return value
    }

    public static func decodeBase64<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key,
        field: String,
        expectedBytes: Int? = nil
    ) throws -> Data {
        let raw = try container.decode(String.self, forKey: key)
        guard let value = Data(base64Encoded: raw, options: []),
              expectedBytes.map({ value.count == $0 }) ?? true,
              value.base64EncodedString() == raw else {
            throw PeelSignalContractError.invalidFieldEncoding(field: field)
        }
        return value
    }

    public static func validateNonce(_ value: Data, field: String) throws -> Data {
        guard value.count == nonceBytes else {
            throw PeelSignalContractError.invalidNonce(field: field, byteCount: value.count)
        }
        return value
    }

    public static func validateProof(_ value: Data) throws -> Data {
        guard value.count == proofBytes else {
            throw PeelSignalContractError.invalidProof(byteCount: value.count)
        }
        return value
    }

    public static func validateKey(_ value: Data) throws -> Data {
        guard value.count == keyBytes else {
            throw PeelSignalContractError.invalidKey(byteCount: value.count)
        }
        return value
    }

    /// Canonical feature list: lowercase `[a-z0-9.]`, 1–32 bytes, unique,
    /// sorted, at most eight entries. Anything else is rejected rather than
    /// silently trimmed so both peers MAC exactly the same bytes.
    public static func validateFeatures(_ value: [String]) throws -> [String] {
        guard value.count <= maximumFeatures else {
            throw PeelSignalContractError.invalidFieldEncoding(field: "features")
        }
        for feature in value {
            let bytes = Array(feature.utf8)
            guard !bytes.isEmpty, bytes.count <= maximumFeatureBytes,
                  bytes.allSatisfy({ (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2E }) else {
                throw PeelSignalContractError.invalidFieldEncoding(field: "features")
            }
        }
        let canonical = Array(Set(value)).sorted()
        guard canonical == value else {
            throw PeelSignalContractError.invalidFieldEncoding(field: "features")
        }
        return canonical
    }

    public static func canonicalFeatures<S: Sequence>(_ value: S) -> [String] where S.Element == String {
        Array(Set(value)).sorted()
    }

    public static func validateFramePayload(_ value: Data) throws -> Data {
        guard value.count <= maximumFramePayloadBytes else {
            throw PeelSignalContractError.invalidFramePayload(byteCount: value.count)
        }
        return value
    }

    /// Encode one JSON message and apply the transport-independent message cap.
    /// The caller remains responsible for adding its framing on the TLS stream.
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximumJSONBytes else {
            throw PeelSignalContractError.messageTooLarge(byteCount: data.count)
        }
        return data
    }

    /// Decode one bounded JSON message. No transport, socket, or SidePulse
    /// model is consulted here.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= maximumJSONBytes else {
            throw PeelSignalContractError.messageTooLarge(byteCount: data.count)
        }
        return try JSONDecoder().decode(type, from: data)
    }

    /// Frame payloads have a larger JSON envelope cap because an 8192-byte
    /// payload is base64-encoded on the wire. Handshake messages continue to
    /// use `maximumJSONBytes` above.
    public static func encodeFrame(_ value: PeelSignalFrame) throws -> Data {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximumFrameJSONBytes else {
            throw PeelSignalContractError.messageTooLarge(byteCount: data.count)
        }
        return data
    }

    public static func decodeFrame(from data: Data) throws -> PeelSignalFrame {
        guard data.count <= maximumFrameJSONBytes else {
            throw PeelSignalContractError.messageTooLarge(byteCount: data.count)
        }
        return try JSONDecoder().decode(PeelSignalFrame.self, from: data)
    }
}

nonisolated public struct PeelSignalHello: Codable, Equatable, Sendable {
    public static let messageType = "peelSignalHello"

    public let type: String
    public let pairingId: UUID
    public let publisherHostId: UUID
    public let subscriberHostId: UUID
    public let subscriberNodeId: UUID
    /// Codable emits this Data as a base64 JSON string. It is exactly 32 bytes.
    public let clientNonce: Data
    /// Optional requested features. Nil is a v1 hello; old publishers ignore
    /// the key and answer with a v1 challenge, which keeps the socket LED-only.
    public let features: [String]?

    public init(
        pairingId: UUID,
        publisherHostId: UUID,
        subscriberHostId: UUID,
        subscriberNodeId: UUID,
        clientNonce: Data,
        features: [String]? = nil
    ) throws {
        type = Self.messageType
        self.pairingId = pairingId
        self.publisherHostId = publisherHostId
        self.subscriberHostId = subscriberHostId
        self.subscriberNodeId = subscriberNodeId
        self.clientNonce = try PeelSignalContract.validateNonce(clientNonce, field: "clientNonce")
        self.features = try features.map(PeelSignalContract.validateFeatures)
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case pairingId
        case publisherHostId
        case subscriberHostId
        case subscriberNodeId
        case clientNonce
        case features
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let type = try values.decode(String.self, forKey: .type)
        guard type == Self.messageType else {
            throw PeelSignalContractError.wrongMessageType(expected: Self.messageType, actual: type)
        }
        try self.init(
            pairingId: PeelSignalContract.decodeUUID(
                from: values, forKey: .pairingId, field: "pairingId"),
            publisherHostId: PeelSignalContract.decodeUUID(
                from: values, forKey: .publisherHostId, field: "publisherHostId"),
            subscriberHostId: PeelSignalContract.decodeUUID(
                from: values, forKey: .subscriberHostId, field: "subscriberHostId"),
            subscriberNodeId: PeelSignalContract.decodeUUID(
                from: values, forKey: .subscriberNodeId, field: "subscriberNodeId"),
            clientNonce: PeelSignalContract.decodeBase64(
                from: values,
                forKey: .clientNonce,
                field: "clientNonce",
                expectedBytes: PeelSignalContract.nonceBytes),
            features: values.decodeIfPresent([String].self, forKey: .features)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.messageType, forKey: .type)
        try values.encode(pairingId.uuidString, forKey: .pairingId)
        try values.encode(publisherHostId.uuidString, forKey: .publisherHostId)
        try values.encode(subscriberHostId.uuidString, forKey: .subscriberHostId)
        try values.encode(subscriberNodeId.uuidString, forKey: .subscriberNodeId)
        try values.encode(clientNonce, forKey: .clientNonce)
        try values.encodeIfPresent(features, forKey: .features)
    }
}

nonisolated public struct PeelSignalChallenge: Codable, Equatable, Sendable {
    public static let messageType = "peelSignalChallenge"

    public let type: String
    /// Codable emits this Data as a base64 JSON string. It is exactly 32 bytes.
    public let serverNonce: Data
    public let publisherNodeId: UUID
    /// Codable emits this Data as a base64 JSON string. It is exactly 32 bytes.
    public let proof: Data
    /// Present only when the publisher explicitly accepts a featured hello.
    /// Its presence selects the v2 transcript, which binds both feature lists.
    public let features: [String]?

    public init(serverNonce: Data, publisherNodeId: UUID, proof: Data, features: [String]? = nil) throws {
        type = Self.messageType
        self.serverNonce = try PeelSignalContract.validateNonce(serverNonce, field: "serverNonce")
        self.publisherNodeId = publisherNodeId
        self.proof = try PeelSignalContract.validateProof(proof)
        self.features = try features.map(PeelSignalContract.validateFeatures)
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case serverNonce
        case publisherNodeId
        case proof
        case features
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let type = try values.decode(String.self, forKey: .type)
        guard type == Self.messageType else {
            throw PeelSignalContractError.wrongMessageType(expected: Self.messageType, actual: type)
        }
        try self.init(
            serverNonce: PeelSignalContract.decodeBase64(
                from: values,
                forKey: .serverNonce,
                field: "serverNonce",
                expectedBytes: PeelSignalContract.nonceBytes),
            publisherNodeId: PeelSignalContract.decodeUUID(
                from: values, forKey: .publisherNodeId, field: "publisherNodeId"),
            proof: PeelSignalContract.decodeBase64(
                from: values,
                forKey: .proof,
                field: "proof",
                expectedBytes: PeelSignalContract.proofBytes),
            features: values.decodeIfPresent([String].self, forKey: .features)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.messageType, forKey: .type)
        try values.encode(serverNonce, forKey: .serverNonce)
        try values.encode(publisherNodeId.uuidString, forKey: .publisherNodeId)
        try values.encode(proof, forKey: .proof)
        try values.encodeIfPresent(features, forKey: .features)
    }
}

nonisolated public struct PeelSignalProof: Codable, Equatable, Sendable {
    public static let messageType = "peelSignalProof"

    public let type: String
    /// Codable emits this Data as a base64 JSON string. It is exactly 32 bytes.
    public let proof: Data

    public init(proof: Data) throws {
        type = Self.messageType
        self.proof = try PeelSignalContract.validateProof(proof)
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case proof
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let type = try values.decode(String.self, forKey: .type)
        guard type == Self.messageType else {
            throw PeelSignalContractError.wrongMessageType(expected: Self.messageType, actual: type)
        }
        try self.init(proof: PeelSignalContract.decodeBase64(
            from: values,
            forKey: .proof,
            field: "proof",
            expectedBytes: PeelSignalContract.proofBytes))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.messageType, forKey: .type)
        try values.encode(proof, forKey: .proof)
    }
}

/// A bounded authenticated-TLS payload carrying the existing NearbySignalFrame
/// JSON. The payload remains opaque here, so this contract does not import or
/// depend on SidePulse's renderer model.
nonisolated public struct PeelSignalFrame: Codable, Equatable, Sendable {
    public static let messageType = "peelSignalFrame"

    public let type: String
    public let payload: Data

    public init(payload: Data) throws {
        type = Self.messageType
        self.payload = try PeelSignalContract.validateFramePayload(payload)
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case payload
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let type = try values.decode(String.self, forKey: .type)
        guard type == Self.messageType else {
            throw PeelSignalContractError.wrongMessageType(expected: Self.messageType, actual: type)
        }
        try self.init(payload: PeelSignalContract.decodeBase64(
            from: values,
            forKey: .payload,
            field: "payload"))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.messageType, forKey: .type)
        try values.encode(payload, forKey: .payload)
    }
}

/// Role-separated HMAC helpers. Every public proof method validates all
/// fields before deriving a MAC; verification uses CryptoKit's constant-time
/// `HMAC.isValidAuthenticationCode` rather than an ordinary byte comparison.
nonisolated public enum PeelSignalAuthentication {
    public static func mintNonce() -> Data {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { Data($0) }
    }

    // MARK: Feature negotiation (v2)
    //
    // A v2 transcript exists only when a featured hello is answered by a
    // challenge that itself carries a feature list. A missing challenge list
    // is an ordinary v1 exchange: the socket stays LED-only and new message
    // types are never sent. Stripping or adding either list changes which
    // transcript is MACed, so a downgrade fails closed instead of granting
    // capabilities.

    /// Publisher side. A v1 hello always yields a v1 challenge (no features).
    /// A featured hello yields a v2 challenge whose features are the subset of
    /// the request the publisher accepts (possibly empty, still v2).
    public static func makeNegotiatedChallenge(
        hello: PeelSignalHello,
        serverNonce: Data,
        publisherNodeId: UUID,
        key: Data,
        supportedFeatures: [String]
    ) throws -> PeelSignalChallenge {
        guard let requested = hello.features else {
            return try makeChallenge(hello: hello, serverNonce: serverNonce,
                                     publisherNodeId: publisherNodeId, key: key)
        }
        let accepted = PeelSignalContract.canonicalFeatures(Set(requested).intersection(supportedFeatures))
        let proof = try makeProof(domain: PeelSignalContract.serverProofDomainV2, hello: hello,
                                  serverNonce: serverNonce, publisherNodeId: publisherNodeId, key: key,
                                  featureLists: (requested, accepted))
        return try PeelSignalChallenge(serverNonce: serverNonce, publisherNodeId: publisherNodeId,
                                       proof: proof, features: accepted)
    }

    /// Subscriber side. Chooses v1 or v2 strictly from the challenge, and
    /// rejects a challenge that grants anything the hello did not request.
    public static func verifyNegotiatedServerProof(
        _ challenge: PeelSignalChallenge,
        hello: PeelSignalHello,
        key: Data
    ) -> Bool {
        guard let accepted = challenge.features else {
            return verifyServerProof(challenge, hello: hello, key: key)
        }
        guard let requested = hello.features,
              Set(accepted).isSubset(of: Set(requested)) else { return false }
        return verify(challenge.proof, domain: PeelSignalContract.serverProofDomainV2, hello: hello,
                      serverNonce: challenge.serverNonce, publisherNodeId: challenge.publisherNodeId,
                      key: key, featureLists: (requested, accepted))
    }

    /// Subscriber side: the client proof uses the same transcript version the
    /// verified challenge selected.
    public static func negotiatedClientProof(
        hello: PeelSignalHello,
        challenge: PeelSignalChallenge,
        key: Data
    ) throws -> Data {
        guard let accepted = challenge.features else {
            return try clientProof(hello: hello, serverNonce: challenge.serverNonce,
                                   publisherNodeId: challenge.publisherNodeId, key: key)
        }
        guard let requested = hello.features else {
            throw PeelSignalContractError.invalidFieldEncoding(field: "features")
        }
        return try makeProof(domain: PeelSignalContract.clientProofDomainV2, hello: hello,
                             serverNonce: challenge.serverNonce, publisherNodeId: challenge.publisherNodeId,
                             key: key, featureLists: (requested, accepted))
    }

    /// Publisher side: verify against exactly the challenge it sent.
    public static func verifyNegotiatedClientProof(
        _ message: PeelSignalProof,
        hello: PeelSignalHello,
        challenge: PeelSignalChallenge,
        key: Data
    ) -> Bool {
        guard let accepted = challenge.features else {
            return verifyClientProof(message, hello: hello, serverNonce: challenge.serverNonce,
                                     publisherNodeId: challenge.publisherNodeId, key: key)
        }
        guard let requested = hello.features else { return false }
        return verify(message.proof, domain: PeelSignalContract.clientProofDomainV2, hello: hello,
                      serverNonce: challenge.serverNonce, publisherNodeId: challenge.publisherNodeId,
                      key: key, featureLists: (requested, accepted))
    }

    /// Features usable on an authenticated socket. Empty for every v1 socket.
    public static func negotiatedFeatures(challenge: PeelSignalChallenge) -> Set<String> {
        Set(challenge.features ?? [])
    }

    public static func serverProof(
        hello: PeelSignalHello,
        serverNonce: Data,
        publisherNodeId: UUID,
        key: Data
    ) throws -> Data {
        try makeProof(
            domain: PeelSignalContract.serverProofDomain,
            hello: hello,
            serverNonce: serverNonce,
            publisherNodeId: publisherNodeId,
            key: key
        )
    }

    public static func clientProof(
        hello: PeelSignalHello,
        serverNonce: Data,
        publisherNodeId: UUID,
        key: Data
    ) throws -> Data {
        try makeProof(
            domain: PeelSignalContract.clientProofDomain,
            hello: hello,
            serverNonce: serverNonce,
            publisherNodeId: publisherNodeId,
            key: key
        )
    }

    public static func makeChallenge(
        hello: PeelSignalHello,
        serverNonce: Data,
        publisherNodeId: UUID,
        key: Data
    ) throws -> PeelSignalChallenge {
        try PeelSignalChallenge(
            serverNonce: serverNonce,
            publisherNodeId: publisherNodeId,
            proof: serverProof(
                hello: hello,
                serverNonce: serverNonce,
                publisherNodeId: publisherNodeId,
                key: key
            )
        )
    }

    public static func verifyServerProof(
        _ proof: Data,
        hello: PeelSignalHello,
        serverNonce: Data,
        publisherNodeId: UUID,
        key: Data
    ) -> Bool {
        verify(
            proof,
            domain: PeelSignalContract.serverProofDomain,
            hello: hello,
            serverNonce: serverNonce,
            publisherNodeId: publisherNodeId,
            key: key
        )
    }

    public static func verifyServerProof(
        _ challenge: PeelSignalChallenge,
        hello: PeelSignalHello,
        key: Data
    ) -> Bool {
        verifyServerProof(
            challenge.proof,
            hello: hello,
            serverNonce: challenge.serverNonce,
            publisherNodeId: challenge.publisherNodeId,
            key: key
        )
    }

    public static func verifyClientProof(
        _ proof: Data,
        hello: PeelSignalHello,
        serverNonce: Data,
        publisherNodeId: UUID,
        key: Data
    ) -> Bool {
        verify(
            proof,
            domain: PeelSignalContract.clientProofDomain,
            hello: hello,
            serverNonce: serverNonce,
            publisherNodeId: publisherNodeId,
            key: key
        )
    }

    public static func verifyClientProof(
        _ message: PeelSignalProof,
        hello: PeelSignalHello,
        serverNonce: Data,
        publisherNodeId: UUID,
        key: Data
    ) -> Bool {
        verifyClientProof(
            message.proof,
            hello: hello,
            serverNonce: serverNonce,
            publisherNodeId: publisherNodeId,
            key: key
        )
    }

    private static func makeProof(
        domain: String,
        hello: PeelSignalHello,
        serverNonce: Data,
        publisherNodeId: UUID,
        key: Data,
        featureLists: (hello: [String], challenge: [String])? = nil
    ) throws -> Data {
        let transcript = try makeTranscript(
            domain: domain,
            hello: hello,
            serverNonce: serverNonce,
            publisherNodeId: publisherNodeId,
            key: key,
            featureLists: featureLists
        )
        let mac = HMAC<SHA256>.authenticationCode(
            for: transcript,
            using: SymmetricKey(data: key)
        )
        return Data(mac)
    }

    private static func verify(
        _ proof: Data,
        domain: String,
        hello: PeelSignalHello,
        serverNonce: Data,
        publisherNodeId: UUID,
        key: Data,
        featureLists: (hello: [String], challenge: [String])? = nil
    ) -> Bool {
        guard proof.count == PeelSignalContract.proofBytes,
              let transcript = try? makeTranscript(
                  domain: domain,
                  hello: hello,
                  serverNonce: serverNonce,
                  publisherNodeId: publisherNodeId,
                  key: key,
                  featureLists: featureLists
              ),
              (try? PeelSignalContract.validateKey(key)) != nil else {
            return false
        }

        return HMAC<SHA256>.isValidAuthenticationCode(
            proof,
            authenticating: transcript,
            using: SymmetricKey(data: key)
        )
    }

    private static func makeTranscript(
        domain: String,
        hello: PeelSignalHello,
        serverNonce: Data,
        publisherNodeId: UUID,
        key: Data,
        featureLists: (hello: [String], challenge: [String])? = nil
    ) throws -> Data {
        _ = try PeelSignalContract.validateKey(key)
        // v1 domains never carry features and v2 domains always do.
        let isV2Domain = domain == PeelSignalContract.serverProofDomainV2
            || domain == PeelSignalContract.clientProofDomainV2
        guard isV2Domain == (featureLists != nil) else {
            throw PeelSignalContractError.invalidFieldEncoding(field: "features")
        }
        _ = try PeelSignalContract.validateNonce(hello.clientNonce, field: "clientNonce")
        _ = try PeelSignalContract.validateNonce(serverNonce, field: "serverNonce")
        var transcript = Data()
        appendLengthPrefixedUTF8(domain, to: &transcript)
        appendUUID(hello.pairingId, to: &transcript)
        appendUUID(hello.publisherHostId, to: &transcript)
        appendUUID(hello.subscriberHostId, to: &transcript)
        appendUUID(hello.subscriberNodeId, to: &transcript)

        // Both nonces have a fixed validated length and are appended raw so
        // their bytes, rather than a JSON/base64 representation, are MACed.
        transcript.append(hello.clientNonce)
        transcript.append(serverNonce)
        appendUUID(publisherNodeId, to: &transcript)
        if let featureLists {
            for list in [featureLists.hello, featureLists.challenge] {
                let canonical = try PeelSignalContract.validateFeatures(list)
                var count = UInt32(canonical.count).bigEndian
                withUnsafeBytes(of: &count) { transcript.append(contentsOf: $0) }
                for feature in canonical { appendLengthPrefixedUTF8(feature, to: &transcript) }
            }
        }
        return transcript
    }

    private static func appendUUID(_ value: UUID, to data: inout Data) {
        appendLengthPrefixedUTF8(PeelSignalContract.canonicalUUID(value), to: &data)
    }

    private static func appendLengthPrefixedUTF8(_ value: String, to data: inout Data) {
        let bytes = Array(value.utf8)
        var length = UInt32(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(contentsOf: bytes)
    }
}
