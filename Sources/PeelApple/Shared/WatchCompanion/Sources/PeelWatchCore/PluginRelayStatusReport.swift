import Foundation

/// Ephemeral, non-secret description of ONE already persisted phone reply.
/// It grants no authority and advances neither broker nor Watch-delivery cursor.
public struct PluginRelayReplyNotice: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let replyID: String
    public let chunkCount: Int
    public let totalUTF8Bytes: Int
    public let digest: String

    public init(requestID: UUID, replyID: String, chunkCount: Int, totalUTF8Bytes: Int, digest: String) throws {
        self.requestID = requestID; self.replyID = replyID; self.chunkCount = chunkCount
        self.totalUTF8Bytes = totalUTF8Bytes; self.digest = digest
        try validate()
    }
    public func validate() throws {
        guard PluginRelayValidation.opaque(replyID), (1...8).contains(chunkCount),
              (1...32_000).contains(totalUTF8Bytes), PluginRelayValidation.isDigest(digest) else {
            throw PluginRelayError.invalidPayload
        }
    }
}

/// Remote status report, never a native authorization/readiness grant. Its outer
/// v2 envelope must bind the current full fence and expected courier operation.
public struct PluginRelayStatusReport: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case authorizePlugin, connected, manualReady }
    public enum DeliveryMode: String, Codable, Sendable { case events, manual }
    public let state: State
    public let remoteReady: Bool
    public let deliveryMode: DeliveryMode
    public let automaticDeliveryReady: Bool
    public let minimumRoutineIntervalSeconds: Int64?
    public let nextReply: PluginRelayReplyNotice?

    public init(state: State, remoteReady: Bool, deliveryMode: DeliveryMode, automaticDeliveryReady: Bool,
                minimumRoutineIntervalSeconds: Int64?, nextReply: PluginRelayReplyNotice?) {
        self.state = state; self.remoteReady = remoteReady; self.deliveryMode = deliveryMode
        self.automaticDeliveryReady = automaticDeliveryReady
        self.minimumRoutineIntervalSeconds = minimumRoutineIntervalSeconds; self.nextReply = nextReply
    }
    public func validate(provider: CloudAgentProvider) throws {
        let dot = provider == .dot
        guard state == (remoteReady ? (dot ? .connected : .manualReady) : .authorizePlugin),
              deliveryMode == (dot ? .events : .manual), automaticDeliveryReady == (remoteReady && dot),
              minimumRoutineIntervalSeconds == (dot ? nil : 300), nextReply == nil || remoteReady else {
            throw PluginRelayError.invalidPayload
        }
        try nextReply?.validate()
    }
}
