import Foundation

/// Versioned JSON carried as Data by WatchConnectivity. Receivers must use init(data:)
/// so the byte limit is checked before JSON decoding.
public struct CompanionEnvelope: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maximumPayloadBytes = 16 * 1_024

    public let version: Int
    public let draft: CompanionDraft

    public init(draft: CompanionDraft) {
        self.version = Self.currentVersion
        self.draft = draft
    }

    public init(data: Data) throws {
        guard data.count <= Self.maximumPayloadBytes else {
            throw CompanionValidationError.payloadTooLarge(maximum: Self.maximumPayloadBytes)
        }
        do {
            self = try JSONDecoder().decode(Self.self, from: data)
        } catch let error as CompanionValidationError {
            throw error
        } catch {
            throw CompanionValidationError.malformedPayload
        }
    }

    public func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumPayloadBytes else {
            throw CompanionValidationError.payloadTooLarge(maximum: Self.maximumPayloadBytes)
        }
        return data
    }

    private enum CodingKeys: String, CodingKey { case version, draft }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw CompanionValidationError.unsupportedVersion(version)
        }
        self.version = version
        self.draft = try container.decode(CompanionDraft.self, forKey: .draft)
    }
}
