import Foundation

/// A user's intended destination. Selecting one does not establish a provider connection.
public enum CompanionProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAI
    case grok
    case claude

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAI: return "OpenAI / dot"
        case .grok: return "Grok"
        case .claude: return "Claude"
        }
    }

    public var subtitle: String {
        switch self {
        case .openAI: return "ChatGPT and your dot"
        case .grok: return "Grok with your X account"
        case .claude: return "Claude chat and Claude Code"
        }
    }

    public var systemImage: String {
        switch self {
        case .openAI: return "circle.dotted"
        case .grok: return "sparkle"
        case .claude: return "sun.max"
        }
    }

    /// This package transports local drafts only. No provider login, chat, voice,
    /// or remote execution integration has been established by selecting a provider.
    public var liveCapabilities: CompanionLiveCapabilities { .unavailable }
}

public struct CompanionLiveCapabilities: Equatable, Sendable {
    public let accountSignIn: Bool
    public let textChat: Bool
    public let voiceChat: Bool
    public let remoteSessionControl: Bool

    public static let unavailable = CompanionLiveCapabilities(
        accountSignIn: false,
        textChat: false,
        voiceChat: false,
        remoteSessionControl: false
    )
}
