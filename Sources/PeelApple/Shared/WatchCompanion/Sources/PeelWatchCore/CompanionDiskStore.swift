import Foundation

/// Synchronous storage intended for a caller's serialized persistence queue.
/// This store does not create credentials, make network calls, or read provider state.
public struct CompanionDiskStore: Sendable {
    public static let maximumStoredBytes = CompanionEnvelope.maximumPayloadBytes * CompanionInbox.maximumDrafts + 1_024
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> CompanionInbox {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return CompanionInbox() }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var data = Data()
        // A bounded read protects against a corrupt or concurrently replaced file.
        while data.count <= Self.maximumStoredBytes {
            let remaining = Self.maximumStoredBytes + 1 - data.count
            guard let chunk = try handle.read(upToCount: min(64 * 1_024, remaining)), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= Self.maximumStoredBytes else {
            throw CompanionValidationError.payloadTooLarge(maximum: Self.maximumStoredBytes)
        }
        do {
            return try JSONDecoder().decode(CompanionInbox.self, from: data)
        } catch let error as CompanionValidationError {
            throw error
        } catch {
            throw CompanionValidationError.malformedPayload
        }
    }

    public func save(_ inbox: CompanionInbox) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(inbox)
        guard data.count <= Self.maximumStoredBytes else {
            throw CompanionValidationError.payloadTooLarge(maximum: Self.maximumStoredBytes)
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic])
    }
}
