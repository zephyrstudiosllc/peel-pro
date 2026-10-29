import Foundation

public enum CompanionValidationError: Error, Equatable, LocalizedError, Sendable {
    case emptyText
    case textTooLong(maximum: Int)
    case invalidDate
    case payloadTooLarge(maximum: Int)
    case malformedPayload
    case unsupportedVersion(Int)
    case tooManyDrafts(maximum: Int)
    case invalidSessionURL

    public var errorDescription: String? {
        switch self {
        case .emptyText: return "Write a message before saving a draft."
        case .textTooLong(let maximum): return "Drafts can contain up to \(maximum) characters."
        case .invalidDate: return "This draft has an invalid creation date."
        case .payloadTooLarge: return "This draft message is too large to transfer."
        case .malformedPayload: return "This draft message could not be read."
        case .unsupportedVersion: return "This draft message needs a newer version of Peel."
        case .tooManyDrafts: return "The draft inbox exceeds its storage limit."
        case .invalidSessionURL: return "Use an official Claude Code session link without credentials or query parameters."
        }
    }
}

/// A local draft, never a provider response or a claim that a chat has been created.
public struct CompanionDraft: Codable, Identifiable, Equatable, Sendable {
    public static let maximumTextLength = 4_000

    public let id: UUID
    public let provider: CompanionProvider
    public let text: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        provider: CompanionProvider,
        text: String,
        createdAt: Date = Date()
    ) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CompanionValidationError.emptyText }
        guard trimmed.count <= Self.maximumTextLength else {
            throw CompanionValidationError.textTooLong(maximum: Self.maximumTextLength)
        }
        guard createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw CompanionValidationError.invalidDate
        }
        self.id = id
        self.provider = provider
        self.text = trimmed
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey { case id, provider, text, createdAt }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            provider: container.decode(CompanionProvider.self, forKey: .provider),
            text: container.decode(String.self, forKey: .text),
            createdAt: container.decode(Date.self, forKey: .createdAt)
        )
    }
}
