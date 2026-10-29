import Foundation

/// Existing persistent agents, reached through their supported Slack conversation.
/// This is not an OpenAI/xAI model-inference client.
public enum CloudAgentProvider: String, Codable, CaseIterable, Hashable, Sendable {
    case dot
    case grokBot
}

public enum CloudAgentError: Error, Equatable, LocalizedError, Sendable {
    case needsConfiguration
    case invalidConfiguration
    case needsVerification
    case wrongWorkspace
    case wrongBot
    case wrongConversation
    case invalidText
    case invalidResponse
    case responseTooLarge
    case networkFailure
    case serviceRejected(String)
    case rateLimited(retryAt: Date)
    case busy
    case cancelled
    case deliveryUnknown
    case reusedRequestID
    case storageFailure
    case storageFull

    public var errorDescription: String? {
        switch self {
        case .needsConfiguration: return "Configure the agent’s Slack connection securely on iPhone."
        case .invalidConfiguration: return "Use exact Slack workspace, conversation and bot user IDs."
        case .needsVerification: return "Verify the Slack connection on iPhone before sending."
        case .wrongWorkspace: return "The Slack token belongs to a different workspace."
        case .wrongBot: return "The configured Slack user is not the selected bot."
        case .wrongConversation: return "This conversation does not belong to the configured agent."
        case .invalidText: return "Messages must contain 1–4,000 characters."
        case .invalidResponse: return "Slack returned an unexpected response."
        case .responseTooLarge: return "The Slack response exceeds Peel’s safe size limit."
        case .networkFailure: return "The Slack request could not complete."
        case .serviceRejected(let code): return "Slack rejected the request (\(code))."
        case .rateLimited(let retryAt): return "Slack requests are paused until \(retryAt.formatted())."
        case .busy: return "This request is already running."
        case .cancelled: return "Stopped this local request. This does not stop the remote agent."
        case .deliveryUnknown: return "Delivery is uncertain. Check the Slack thread before sending again."
        case .reusedRequestID: return "This request ID was already used for a different message."
        case .storageFailure: return "Peel could not securely save the conversation checkpoint."
        case .storageFull: return "Resolve uncertain sends before starting more messages."
        }
    }
}

public enum CloudAgentAvailability: Equatable, Sendable {
    case needsConfiguration
    case needsVerification
    /// API authentication, workspace, conversation and bot identity were verified.
    /// This does not claim that the bot has answered a real message.
    case ready
    case unavailable(CloudAgentError)
}

public struct CloudAgentSlackConfiguration: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let provider: CloudAgentProvider
    public let teamID: String
    public let channelID: String
    public let targetBotUserID: String
    public let threadTimestamp: String?

    public init(id: UUID = UUID(), provider: CloudAgentProvider, teamID: String,
                channelID: String, targetBotUserID: String, threadTimestamp: String? = nil) throws {
        guard CloudAgentValidation.slackID(teamID, prefixes: "T"),
              CloudAgentValidation.slackID(channelID, prefixes: "CDG"),
              CloudAgentValidation.slackID(targetBotUserID, prefixes: "UW"),
              threadTimestamp.map(CloudAgentValidation.timestamp) ?? true else {
            throw CloudAgentError.invalidConfiguration
        }
        self.id = id; self.provider = provider; self.teamID = teamID
        self.channelID = channelID; self.targetBotUserID = targetBotUserID
        self.threadTimestamp = threadTimestamp
    }

    private enum CodingKeys: String, CodingKey { case id, provider, teamID, channelID, targetBotUserID, threadTimestamp }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id), provider: c.decode(CloudAgentProvider.self, forKey: .provider),
                      teamID: c.decode(String.self, forKey: .teamID), channelID: c.decode(String.self, forKey: .channelID),
                      targetBotUserID: c.decode(String.self, forKey: .targetBotUserID),
                      threadTimestamp: c.decodeIfPresent(String.self, forKey: .threadTimestamp))
    }
}

public struct CloudAgentConversation: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String { "\(configurationID.uuidString):\(threadTimestamp)" }
    public let configurationID: UUID
    public let provider: CloudAgentProvider
    public let teamID: String
    public let channelID: String
    public let targetBotUserID: String
    public let threadTimestamp: String

    public init(configuration: CloudAgentSlackConfiguration, threadTimestamp: String) throws {
        guard CloudAgentValidation.timestamp(threadTimestamp),
              configuration.threadTimestamp.map({ $0 == threadTimestamp }) ?? true else {
            throw CloudAgentError.wrongConversation
        }
        configurationID = configuration.id; provider = configuration.provider
        teamID = configuration.teamID; channelID = configuration.channelID
        targetBotUserID = configuration.targetBotUserID; self.threadTimestamp = threadTimestamp
    }

    func matches(_ configuration: CloudAgentSlackConfiguration) -> Bool {
        configurationID == configuration.id && provider == configuration.provider && teamID == configuration.teamID
        && channelID == configuration.channelID && targetBotUserID == configuration.targetBotUserID
        && (configuration.threadTimestamp.map { $0 == threadTimestamp } ?? true)
        && CloudAgentValidation.timestamp(threadTimestamp)
    }
}

public struct CloudAgentSendReceipt: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let conversation: CloudAgentConversation
    public let messageTimestamp: String
}

public struct CloudAgentReply: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(conversation.id):\(timestamp)" }
    public let conversation: CloudAgentConversation
    public let timestamp: String
    public let senderUserID: String
    public let text: String
}

/// Tokens and arbitrary URLs are intentionally absent from every Watch-safe model.
public struct CloudAgentCursor: Codable, Equatable, Sendable {
    public let conversation: CloudAgentConversation
    public let oldestTimestamp: String
    public let pageCursor: String?
    public let batchMaximumTimestamp: String
    public let seenTimestamps: [String]
    public let messageRevisions: [String: String]

    public init(conversation: CloudAgentConversation) {
        self.conversation = conversation; oldestTimestamp = conversation.threadTimestamp
        pageCursor = nil; batchMaximumTimestamp = conversation.threadTimestamp; seenTimestamps = []; messageRevisions = [:]
    }

    init(conversation: CloudAgentConversation, oldestTimestamp: String, pageCursor: String?,
         batchMaximumTimestamp: String, seenTimestamps: [String], messageRevisions: [String: String] = [:]) {
        self.conversation = conversation; self.oldestTimestamp = oldestTimestamp
        self.pageCursor = pageCursor; self.batchMaximumTimestamp = batchMaximumTimestamp
        self.seenTimestamps = seenTimestamps
        self.messageRevisions = messageRevisions
    }

    func validate(for conversation: CloudAgentConversation) throws {
        guard self.conversation == conversation, CloudAgentValidation.timestamp(oldestTimestamp),
              CloudAgentValidation.timestamp(batchMaximumTimestamp),
              CloudAgentValidation.compare(oldestTimestamp, conversation.threadTimestamp) != .orderedAscending,
              CloudAgentValidation.compare(batchMaximumTimestamp, oldestTimestamp) != .orderedAscending,
              seenTimestamps.count <= 256, seenTimestamps.allSatisfy(CloudAgentValidation.timestamp),
              messageRevisions.count <= 256,
              messageRevisions.allSatisfy({ CloudAgentValidation.timestamp($0.key) && $0.value.utf8.count == 64 }),
              pageCursor.map({ !$0.isEmpty && $0.utf8.count <= 1_024 && !$0.contains(where: { $0.isNewline }) }) ?? true else {
            throw CloudAgentError.wrongConversation
        }
    }
}

public struct CloudAgentReplyPage: Codable, Equatable, Sendable {
    public let messages: [CloudAgentReply]
    public let cursor: CloudAgentCursor
    public let nextPollAfter: Date
}

public protocol CloudAgentTransport: Sendable {
    func availability() async -> CloudAgentAvailability
    func verifyConfiguration() async throws -> CloudAgentAvailability
    func send(text: String, requestID: UUID, conversation: CloudAgentConversation?) async throws -> CloudAgentSendReceipt
    func replies(in conversation: CloudAgentConversation, cursor: CloudAgentCursor?, requestID: UUID) async throws -> CloudAgentReplyPage
    func acknowledge(_ page: CloudAgentReplyPage) async throws
    func cancel(requestID: UUID) async
}

enum CloudAgentValidation {
    static func slackID(_ string: String, prefixes: String) -> Bool {
        guard (3...32).contains(string.utf8.count), let first = string.first, prefixes.contains(first) else { return false }
        return string.utf8.allSatisfy { (65...90).contains($0) || (48...57).contains($0) }
    }
    static func timestamp(_ string: String) -> Bool {
        let pieces = string.split(separator: ".", omittingEmptySubsequences: false)
        return pieces.count == 2 && (1...16).contains(pieces[0].count) && pieces[1].count == 6
        && pieces.allSatisfy { $0.utf8.allSatisfy { (48...57).contains($0) } }
        && pieces[0].first != "0"
    }
    static func compare(_ left: String, _ right: String) -> ComparisonResult {
        // Decimal avoids Double rounding of Slack's exact six-digit timestamp IDs.
        let a = Decimal(string: left, locale: Locale(identifier: "en_US_POSIX")) ?? 0
        let b = Decimal(string: right, locale: Locale(identifier: "en_US_POSIX")) ?? 0
        return a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }
}
