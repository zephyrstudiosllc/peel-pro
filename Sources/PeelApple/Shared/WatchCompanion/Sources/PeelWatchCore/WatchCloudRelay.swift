import Foundation

/// Foreground Watch-to-phone courier. Provider tokens never appear in this wire.
public struct WatchCloudRequest: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case status, send, replies, cancel }
    public let channel: String
    public let version: Int
    public let requestID: UUID
    public let kind: Kind
    public let provider: CloudAgentProvider
    public let text: String?
    public let conversation: CloudAgentConversationReference?
    public let cancelRequestID: UUID?
    public init(kind: Kind, provider: CloudAgentProvider, text: String? = nil,
                conversation: CloudAgentConversationReference? = nil, cancelRequestID: UUID? = nil,
                requestID: UUID = UUID()) {
        self.channel = "peel.watch.cloud.v1"; self.version = 1; self.requestID = requestID
        self.kind = kind; self.provider = provider; self.text = text
        self.conversation = conversation; self.cancelRequestID = cancelRequestID
    }
    public func validate() throws {
        guard version == 1, channel == "peel.watch.cloud.v1",
              conversation.map({ $0.binding.provider == provider }) ?? true else { throw WatchStreamError.invalid }
        if kind == .send {
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.count <= 4_000, text.utf8.count <= 16_000 else { throw WatchStreamError.invalid }
        } else if text != nil { throw WatchStreamError.invalid }
        if kind == .replies, conversation == nil { throw WatchStreamError.invalid }
        if kind == .cancel, cancelRequestID == nil { throw WatchStreamError.invalid }
    }
    public func encoded() throws -> Data { try validate(); return try WatchStreamWire.encode(self) }
    public static func decode(_ data: Data) throws -> Self {
        let value: Self = try WatchStreamWire.decode(data); try value.validate(); return value
    }
}

public struct WatchCloudResponse: Codable, Sendable {
    public let channel: String
    public let version: Int
    public let requestID: UUID
    public let provider: CloudAgentProvider
    public let ready: Bool
    public let connectionStatus: CloudAgentConnectionStatus
    public let message: String
    public let conversation: CloudAgentConversationReference?
    public let replies: [WatchCloudReply]
    public let receipt: WatchCloudReceipt?
    public let nextPollAfter: Date?
    public init(requestID: UUID, provider: CloudAgentProvider, ready: Bool, message: String,
                conversation: CloudAgentConversationReference? = nil, replies: [WatchCloudReply] = [],
                receipt: WatchCloudReceipt? = nil, nextPollAfter: Date? = nil,
                connectionStatus: CloudAgentConnectionStatus? = nil) {
        self.channel = "peel.watch.cloud.v1"; self.version = 1; self.requestID = requestID
        let status = connectionStatus ?? .notIntegrated(provider: provider)
        self.connectionStatus = status
        self.provider = provider; self.ready = ready && status.canSend; self.message = String(message.prefix(300))
        self.conversation = conversation; self.replies = replies; self.receipt = receipt; self.nextPollAfter = nextPollAfter
    }
    public func encoded() throws -> Data { try WatchStreamWire.encode(self) }
    public static func decode(_ data: Data) throws -> Self {
        let value: Self = try WatchStreamWire.decode(data)
        guard value.version == 1, value.channel == "peel.watch.cloud.v1", value.message.count <= 300,
              value.connectionStatus.provider == value.provider, !value.ready || value.connectionStatus.canSend,
              value.replies.count <= 15,
              value.conversation.map({ $0.binding.provider == value.provider && $0.matches(value.connectionStatus) }) ?? true,
              value.replies.isEmpty || value.conversation != nil,
              value.receipt.map({ $0.conversation.binding.provider == value.provider && $0.conversation.matches(value.connectionStatus)
                  && $0.conversation == value.conversation && $0.requestID == value.requestID
                  && !$0.messageID.isEmpty && $0.messageID.utf8.count <= 256 }) ?? true,
              value.replies.allSatisfy({ reply in
                  reply.conversation.binding.provider == value.provider && reply.conversation.matches(value.connectionStatus)
                  && !reply.id.isEmpty && reply.id.utf8.count <= 256 && reply.text.utf8.count <= 32_000
                  && (value.conversation.map({ $0 == reply.conversation }) ?? true)
              }) else { throw WatchStreamError.invalid }
        return value
    }
}

/// Provider-native messages. No token, arbitrary endpoint, or Slack-specific ID.
public struct WatchCloudReply: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let conversation: CloudAgentConversationReference
    public let text: String
    public init(id: String, conversation: CloudAgentConversationReference, text: String) {
        self.id = id; self.conversation = conversation; self.text = text
    }
}

public struct WatchCloudReceipt: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let conversation: CloudAgentConversationReference
    public let messageID: String
    public init(requestID: UUID, conversation: CloudAgentConversationReference, messageID: String) {
        self.requestID = requestID; self.conversation = conversation; self.messageID = messageID
    }
}
