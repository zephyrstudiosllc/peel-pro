import Foundation

/// The human-selected primary identity routes. Connect also verifies the agent
/// route used for new Watch messages and replies.
public enum CloudAgentSignInMethod: String, Codable, Sendable {
    case chatGPT
    case x

    public var title: String {
        switch self {
        case .chatGPT: return "Sign in with ChatGPT"
        case .x: return "Sign in with X"
        }
    }
    public static func primary(for provider: CloudAgentProvider) -> Self {
        switch provider { case .dot: return .chatGPT; case .grokBot: return .x }
    }
}

public enum CloudAgentConnectionBlocker: String, Codable, Sendable {
    case signInNotIntegrated
    case existingAgentAPIUnverified
    case accessNotGranted
    case accountChanged
    case connectionFailed

    public var message: String {
        switch self {
        case .signInNotIntegrated: return "This sign-in connection is not available in this build."
        case .existingAgentAPIUnverified: return "Connect your agent to send and receive Watch messages."
        case .accessNotGranted: return "This account has not granted access to the selected agent."
        case .accountChanged: return "Reconnect your agent after changing accounts."
        case .connectionFailed: return "The provider connection could not be verified."
        }
    }
}

/// Non-secret account/session binding. Each sign-out or account replacement
/// needs a fresh generation, which invalidates late replies from the old session.
/// OAuth tokens, authorization codes, PKCE verifiers and API URLs are absent.
public struct CloudAgentAccountBinding: Codable, Equatable, Hashable, Sendable {
    public let provider: CloudAgentProvider
    public let accountID: String
    public let generation: UUID

    public init(provider: CloudAgentProvider, accountID: String, generation: UUID = UUID()) throws {
        guard Self.validOpaqueID(accountID) else { throw CloudAgentError.invalidConfiguration }
        self.provider = provider; self.accountID = accountID; self.generation = generation
    }

    private enum CodingKeys: String, CodingKey { case provider, accountID, generation }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(provider: c.decode(CloudAgentProvider.self, forKey: .provider),
                      accountID: c.decode(String.self, forKey: .accountID),
                      generation: c.decode(UUID.self, forKey: .generation))
    }
    static func validOpaqueID(_ string: String) -> Bool {
        (1...256).contains(string.utf8.count)
        && !string.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        && !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum CloudAgentIdentityState: Codable, Equatable, Sendable {
    case signedOut
    case authorizing
    case signedIn(CloudAgentAccountBinding)
    case unavailable(CloudAgentConnectionBlocker)
}

public enum CloudAgentConversationCapability: Codable, Equatable, Sendable {
    case notEstablished
    case unavailable(CloudAgentConnectionBlocker)
    /// Set by an audited provider adapter only after existing-agent access is
    /// verified for this exact account/session. Generic model-inference access
    /// and identity-only OAuth grants cannot establish this state.
    case verified(CloudAgentAccountBinding)
}

public struct CloudAgentConnectionStatus: Codable, Equatable, Sendable {
    public let provider: CloudAgentProvider
    public let identity: CloudAgentIdentityState
    public let conversationCapability: CloudAgentConversationCapability
    public var signInMethod: CloudAgentSignInMethod { .primary(for: provider) }

    public init(provider: CloudAgentProvider, identity: CloudAgentIdentityState = .signedOut,
                conversationCapability: CloudAgentConversationCapability = .notEstablished) {
        self.provider = provider; self.identity = identity; self.conversationCapability = conversationCapability
    }

    public var verifiedBinding: CloudAgentAccountBinding? {
        guard case .signedIn(let identityBinding) = identity,
              case .verified(let conversationBinding) = conversationCapability,
              identityBinding == conversationBinding, identityBinding.provider == provider else { return nil }
        return identityBinding
    }
    public var canSend: Bool { verifiedBinding != nil }

    /// Defaults are truthful even if no public direct-agent API has been found.
    /// They do not invent a sign-in URL or silently substitute another service.
    public static func notIntegrated(provider: CloudAgentProvider) -> Self {
        Self(provider: provider, identity: .unavailable(.signInNotIntegrated),
             conversationCapability: .unavailable(.existingAgentAPIUnverified))
    }
}

/// Provider-native identifiers, not Slack channel/timestamp fields. Only the
/// concrete audited provider adapter interprets these opaque values. They are
/// never used as arbitrary network URLs by the shared model or Watch courier.
public struct CloudAgentConversationReference: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String {
        [binding.provider.rawValue, binding.accountID, binding.generation.uuidString, agentID, conversationID]
            .map { "\($0.utf8.count):\($0)" }.joined()
    }
    public let binding: CloudAgentAccountBinding
    public let agentID: String
    public let conversationID: String

    public init(binding: CloudAgentAccountBinding, agentID: String, conversationID: String) throws {
        guard CloudAgentAccountBinding.validOpaqueID(agentID), CloudAgentAccountBinding.validOpaqueID(conversationID) else {
            throw CloudAgentError.invalidConfiguration
        }
        self.binding = binding; self.agentID = agentID; self.conversationID = conversationID
    }
    public func matches(_ status: CloudAgentConnectionStatus) -> Bool { status.verifiedBinding == binding }

    private enum CodingKeys: String, CodingKey { case binding, agentID, conversationID }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(binding: c.decode(CloudAgentAccountBinding.self, forKey: .binding),
                      agentID: c.decode(String.self, forKey: .agentID), conversationID: c.decode(String.self, forKey: .conversationID))
    }
}
