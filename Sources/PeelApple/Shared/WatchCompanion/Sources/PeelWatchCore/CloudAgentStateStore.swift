import Foundation

/// One phone-owned actor should be shared by both agents. It stores bounded send
/// receipts/cursors/rate deadlines, never OAuth tokens. Save reply content in the
/// app inbox BEFORE acknowledging a page, so a failed Watch handoff cannot lose it.
@available(watchOS, unavailable, message: "Cloud credentials and checkpoints remain on iPhone.")
public actor CloudAgentStateStore {
    private struct SendRecord: Codable {
        let id: UUID
        let digest: String
        let createdAt: Date
        var receipt: CloudAgentSendReceipt?
    }
    private struct State: Codable {
        var version = 1
        var sends: [SendRecord] = []
        var cursors: [CloudAgentCursor] = []
        var deadlines: [String: Date] = [:]
    }
    private let fileURL: URL
    private var state: State
    private static let maximumBytes = 512 * 1_024

    public init(fileURL: URL) throws {
        guard fileURL.isFileURL else { throw CloudAgentError.storageFailure }
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let handle = try FileHandle(forReadingFrom: fileURL)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
                guard data.count <= Self.maximumBytes else { throw CloudAgentError.storageFailure }
                let value = try JSONDecoder().decode(State.self, from: data)
                guard value.version == 1, value.sends.count <= 256, value.cursors.count <= 64,
                      value.deadlines.count <= 64,
                      Set(value.sends.map(\.id)).count == value.sends.count,
                      Set(value.cursors.map { $0.conversation.id }).count == value.cursors.count,
                      value.sends.allSatisfy({ record in record.digest.utf8.count == 64
                          && record.digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
                          && record.createdAt.timeIntervalSinceReferenceDate.isFinite
                          && (record.receipt.map { $0.requestID == record.id && CloudAgentValidation.timestamp($0.messageTimestamp) } ?? true) }),
                      value.deadlines.values.allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else {
                    throw CloudAgentError.storageFailure
                }
                for cursor in value.cursors { try cursor.validate(for: cursor.conversation) }
                state = value
            } catch { throw CloudAgentError.storageFailure }
        } else { state = State() }
    }

    public func cursor(for conversation: CloudAgentConversation) -> CloudAgentCursor? {
        state.cursors.first { $0.conversation == conversation }
    }

    func reserveSend(id: UUID, digest: String, now: Date) throws -> CloudAgentSendReceipt? {
        if let record = state.sends.first(where: { $0.id == id }) {
            guard record.digest == digest else { throw CloudAgentError.reusedRequestID }
            guard let receipt = record.receipt else { throw CloudAgentError.deliveryUnknown }
            return receipt
        }
        var value = state
        if value.sends.count >= 256 {
            // Never forget an uncertain send automatically: doing so could replay it.
            guard let index = value.sends.firstIndex(where: { $0.receipt != nil }) else { throw CloudAgentError.storageFull }
            value.sends.remove(at: index)
        }
        value.sends.append(SendRecord(id: id, digest: digest, createdAt: now))
        try persist(value)
        return nil
    }

    func completeSend(_ receipt: CloudAgentSendReceipt) throws {
        guard let index = state.sends.firstIndex(where: { $0.id == receipt.requestID }) else { throw CloudAgentError.storageFailure }
        var value = state; value.sends[index].receipt = receipt
        try persist(value)
    }

    /// Only used for an authoritative Slack rejection before acceptance, never
    /// for a timeout, cancellation, HTTP5xx or malformed success response.
    func releaseRejectedSend(id: UUID) throws {
        var value = state
        value.sends.removeAll { $0.id == id && $0.receipt == nil }
        try persist(value)
    }

    func saveCursor(_ cursor: CloudAgentCursor) throws {
        try cursor.validate(for: cursor.conversation)
        var value = state
        if let index = value.cursors.firstIndex(where: { $0.conversation == cursor.conversation }) {
            let current = value.cursors[index]
            guard CloudAgentValidation.compare(cursor.oldestTimestamp, current.oldestTimestamp) != .orderedAscending else {
                throw CloudAgentError.wrongConversation
            }
            value.cursors[index] = cursor
        } else {
            guard value.cursors.count < 64 else { throw CloudAgentError.storageFull }
            value.cursors.append(cursor)
        }
        try persist(value)
    }

    func reserveRate(key: String, now: Date, interval: TimeInterval) throws {
        if let deadline = state.deadlines[key], deadline > now { throw CloudAgentError.rateLimited(retryAt: deadline) }
        var value = state
        value.deadlines = value.deadlines.filter { $0.value > now }
        guard value.deadlines.count < 64 || value.deadlines[key] != nil else { throw CloudAgentError.storageFull }
        value.deadlines[key] = now.addingTimeInterval(interval)
        try persist(value)
    }

    func deferRate(key: String, until: Date) throws {
        var value = state
        value.deadlines[key] = max(value.deadlines[key] ?? .distantPast, until)
        guard value.deadlines.count <= 64 else { throw CloudAgentError.storageFull }
        try persist(value)
    }

    private func persist(_ value: State) throws {
        do {
            let data = try JSONEncoder().encode(value)
            guard data.count <= Self.maximumBytes else { throw CloudAgentError.storageFailure }
            let parent = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            try data.write(to: fileURL, options: [.atomic])
            var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
            #if os(iOS)
            attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
            #endif
            try FileManager.default.setAttributes(attributes, ofItemAtPath: fileURL.path)
            state = value
        } catch { throw CloudAgentError.storageFailure }
    }
}
