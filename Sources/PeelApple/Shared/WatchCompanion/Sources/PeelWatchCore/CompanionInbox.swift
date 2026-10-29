import Foundation

/// A bounded local inbox. The newest accepted delivery is first; redelivery never
/// changes an existing draft or its position, even if its contents have changed.
/// A full inbox rejects additional deliveries without deleting existing drafts.
public struct CompanionInbox: Codable, Equatable, Sendable {
    public static let maximumDrafts = 100
    public private(set) var drafts: [CompanionDraft]

    /// Seeds an inbox with the first 100 distinct IDs in the supplied order.
    /// Excess array entries are omitted. Persisted/wire decoding instead rejects
    /// arrays containing more than 100 entries, even when IDs are duplicated.
    public init(drafts: [CompanionDraft] = []) {
        var seen: Set<UUID> = []
        self.drafts = drafts.filter { seen.insert($0.id).inserted }.prefix(Self.maximumDrafts).map { $0 }
    }

    /// Returns false for duplicate IDs or a full inbox; existing drafts are retained.
    @discardableResult
    public mutating func insert(_ draft: CompanionDraft) -> Bool {
        guard !drafts.contains(where: { $0.id == draft.id }) else { return false }
        guard drafts.count < Self.maximumDrafts else { return false }
        drafts.insert(draft, at: 0)
        return true
    }

    public func drafts(for provider: CompanionProvider) -> [CompanionDraft] {
        drafts.filter { $0.provider == provider }
    }

    private enum CodingKeys: String, CodingKey { case drafts }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var list = try container.nestedUnkeyedContainer(forKey: .drafts)
        var drafts: [CompanionDraft] = []
        var seen: Set<UUID> = []
        var decodedCount = 0
        while !list.isAtEnd {
            guard decodedCount < Self.maximumDrafts else {
                throw CompanionValidationError.tooManyDrafts(maximum: Self.maximumDrafts)
            }
            let draft = try list.decode(CompanionDraft.self)
            decodedCount += 1
            if seen.insert(draft.id).inserted { drafts.append(draft) }
        }
        self.drafts = drafts
    }
}
