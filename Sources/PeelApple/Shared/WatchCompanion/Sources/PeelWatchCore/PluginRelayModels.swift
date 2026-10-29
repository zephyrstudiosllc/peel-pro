import Foundation
import CryptoKit

public enum PluginRelayError: Error, Equatable, Sendable {
    case invalidPayload, wrongBinding, reusedMessageID, conflict, capacity
    case storageFailure, staleCursor, unknownMessage
}

/// Data validation is not authentication. No type in this foundation grants
/// readiness, verifies a login or constructs a broker/device credential.
enum PluginRelayValidation {
    static func sameBytes(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }
    static func opaque(_ value: String) -> Bool {
        (1...256).contains(value.utf8.count)
        && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }
    static func text(_ value: String, send: Bool, allowBlank: Bool = false) -> Bool {
        !value.isEmpty && (allowBlank || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        && value.utf8.count <= (send ? 16_000 : 32_000)
        && (!send || value.unicodeScalars.count <= 4_000)
        && !value.unicodeScalars.contains { ($0.value < 32 && $0 != "\n" && $0 != "\t") || $0.value == 127 }
    }
    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// Exact broker reference, explicitly different from a provider conversation.
/// accountGeneration is issued by verified broker-session composition. It has
/// no default and must never be generated from local identity metadata.
public struct PluginRelayReference: Codable, Equatable, Hashable, Sendable {
    public let kind: String
    public let provider: CloudAgentProvider
    public let routeID: String
    public let generation: UUID
    public let accountGeneration: UUID

    public init(provider: CloudAgentProvider, routeID: String, generation: UUID, accountGeneration: UUID) throws {
        kind = "pluginRelay"; self.provider = provider; self.routeID = routeID
        self.generation = generation; self.accountGeneration = accountGeneration
        try validate()
    }
    public func validate() throws {
        guard kind == "pluginRelay", PluginRelayValidation.opaque(routeID), routeID.hasPrefix("route_"),
              routeID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || $0 == 95 || $0 == 45 }) else { throw PluginRelayError.invalidPayload }
    }
    private enum CodingKeys: String, CodingKey { case kind, provider, routeID, generation, accountGeneration }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(String.self, forKey: .kind) == "pluginRelay" else { throw PluginRelayError.invalidPayload }
        try self.init(provider: c.decode(CloudAgentProvider.self, forKey: .provider),
                      routeID: c.decode(String.self, forKey: .routeID),
                      generation: c.decode(UUID.self, forKey: .generation),
                      accountGeneration: c.decode(UUID.self, forKey: .accountGeneration))
    }
}

/// Persisted data partition; pairingEpoch must come from current external
/// paired-device composition. These public values are not proofs or grants.
public struct PluginRelayBinding: Codable, Equatable, Hashable, Sendable {
    public let route: PluginRelayReference
    public let pairingEpoch: UUID
    public init(route: PluginRelayReference, pairingEpoch: UUID) {
        self.route = route; self.pairingEpoch = pairingEpoch
    }
}

/// Local operation invalidation is separate from the remote account generation.
/// A coordinator must verify live authority before using a fence, and invalidate
/// it on Stop/account expiry/revoke/pair change. Stored data cannot restore it.
public struct PluginRelayFence: Codable, Equatable, Sendable {
    public let binding: PluginRelayBinding
    public let localEpoch: UUID
    public init(binding: PluginRelayBinding, localEpoch: UUID) {
        self.binding = binding; self.localEpoch = localEpoch
    }
}

public struct PluginRelayMessage: Codable, Equatable, Sendable {
    public let messageID: UUID
    public let text: String
    public init(messageID: UUID, text: String) throws {
        self.messageID = messageID; self.text = text; try validate()
    }
    public func validate() throws {
        guard PluginRelayValidation.text(text, send: true) else { throw PluginRelayError.invalidPayload }
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.messageID == rhs.messageID && PluginRelayValidation.sameBytes(lhs.text, rhs.text)
    }
}

/// The requestID is the logical message ID, never a courier operation ID.
/// A replied receipt still contains no actual reply text.
public struct PluginRelayReceipt: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case accepted, replied }
    public let requestID: UUID
    public let route: PluginRelayReference
    public let receiptID: String
    public let state: State
    public let agentReplyReceived: Bool
    public init(requestID: UUID, route: PluginRelayReference, receiptID: String,
                state: State, agentReplyReceived: Bool) throws {
        self.requestID = requestID; self.route = route; self.receiptID = receiptID
        self.state = state; self.agentReplyReceived = agentReplyReceived; try validate()
    }
    public func validate() throws {
        try route.validate()
        guard PluginRelayValidation.opaque(receiptID), agentReplyReceived == (state == .replied) else {
            throw PluginRelayError.invalidPayload
        }
    }
}

public struct PluginRelayReply: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let replyID: String
    public let text: String
    public init(requestID: UUID, replyID: String, text: String) throws {
        self.requestID = requestID; self.replyID = replyID; self.text = text; try validate()
    }
    public func validate() throws {
        guard PluginRelayValidation.opaque(replyID), PluginRelayValidation.text(text, send: false) else {
            throw PluginRelayError.invalidPayload
        }
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.requestID == rhs.requestID && PluginRelayValidation.sameBytes(lhs.replyID, rhs.replyID)
        && PluginRelayValidation.sameBytes(lhs.text, rhs.text)
    }
}

/// Service page, NOT a Watch envelope. Cursor is reply-arrival order and can have
/// gaps because it is broker-global. No send-order arithmetic is valid here.
public struct PluginRelayReplyPage: Codable, Equatable, Sendable {
    public let route: PluginRelayReference
    public let replies: [PluginRelayReply]
    public let cursor: Int64
    public init(route: PluginRelayReference, replies: [PluginRelayReply], cursor: Int64) throws {
        self.route = route; self.replies = replies; self.cursor = cursor; try validate()
    }
    public func validate() throws {
        try route.validate()
        guard cursor >= 0, replies.count <= 15,
              Set(replies.map(\.requestID)).count == replies.count else { throw PluginRelayError.invalidPayload }
        for reply in replies { try reply.validate() }
        // The actual incoming HTTP bytes are bounded in decode. Re-encoding
        // here is not equivalent to the broker's ensure_ascii=False encoding
        // (Foundation may escape slashes), and could reject a valid service page.
    }
    public static func decode(_ data: Data, expectedRoute: PluginRelayReference) throws -> Self {
        guard !data.isEmpty, data.count <= 256 * 1_024 else { throw PluginRelayError.capacity }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        guard value.route == expectedRoute else { throw PluginRelayError.wrongBinding }
        return value
    }
}
