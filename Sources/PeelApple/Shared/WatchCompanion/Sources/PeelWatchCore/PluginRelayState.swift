import Foundation
import Darwin

/// Exactly one serialized owner per backing file is required. A successful write
/// commits all bytes atomically; a throwing writer must leave its previous bytes
/// intact. This protocol is a persistence seam, never a credential/session seam.
public protocol PluginRelayPersistence: Sendable {
    func read(maximumBytes: Int) throws -> Data?
    func writeAtomically(_ data: Data) throws
}

public struct PluginRelayFilePersistence: PluginRelayPersistence {
    public let fileURL: URL
    private let phoneProtection: (any PluginRelayPhoneFileProtection)?

    /// Existing behavior: complete file protection on iOS/watchOS. This does not
    /// opt a Watch or any other store into the phone's background relay policy.
    public init(fileURL: URL) throws {
        guard fileURL.isFileURL else { throw PluginRelayError.storageFailure }
        self.fileURL = fileURL
        phoneProtection = nil
    }

    #if os(iOS)
    /// Explicit opt-in for a PHONE relay spool in its own dedicated directory.
    /// Call while existing complete-protected bytes are readable (normally during
    /// unlocked setup). Migrates attributes in place, never message contents.
    /// This provides storage availability after first unlock, not a wake grant,
    /// credential/session authority, or permission to use another store's folder.
    public static func phoneRelayAfterFirstUnlock(fileURL: URL) throws -> Self {
        try Self(fileURL: fileURL, phoneRelayProtection: PluginRelayIOSPhoneFileProtection())
    }
    #endif

    /// Internal policy seam permits deterministic filesystem/failure tests on
    /// macOS. A fixture policy is not evidence of iOS file-protection behavior.
    init(fileURL: URL, phoneRelayProtection: any PluginRelayPhoneFileProtection) throws {
        guard fileURL.isFileURL else { throw PluginRelayError.storageFailure }
        self.fileURL = fileURL
        phoneProtection = phoneRelayProtection
        do {
            // Read before changing any protection. Unavailable bytes cannot be
            // mistaken for a missing/new store, or silently weakened to recover.
            let previous = try readRegularFile(maximumBytes: 8 * 1_024 * 1_024)
            let parent = try ensureDirectory()
            try phoneRelayProtection.establish(at: parent)
            if let previous {
                try phoneRelayProtection.establish(at: fileURL)
                guard try readRegularFile(maximumBytes: 8 * 1_024 * 1_024) == previous else {
                    throw PluginRelayError.storageFailure
                }
                try phoneRelayProtection.verify(at: fileURL)
            }
        } catch { throw PluginRelayError.storageFailure }
    }

    public func read(maximumBytes: Int) throws -> Data? {
        guard (1...8 * 1_024 * 1_024).contains(maximumBytes) else { throw PluginRelayError.storageFailure }
        do {
            if let phoneProtection { try phoneProtection.verify(at: fileURL.deletingLastPathComponent()) }
            let data = try readRegularFile(maximumBytes: maximumBytes)
            if data != nil, let phoneProtection { try phoneProtection.verify(at: fileURL) }
            return data
        } catch let error as PluginRelayError { throw error }
        catch { throw PluginRelayError.storageFailure }
    }

    /// Only POSIX ENOENT means absent. EACCES/EPERM, bad parents, symlinks,
    /// nonregular objects, short/error reads and oversized files never mean empty.
    /// O_NONBLOCK avoids waiting for a FIFO/device before fstat can reject it.
    private func readRegularFile(maximumBytes: Int) throws -> Data? {
        let opened = fileURL.withUnsafeFileSystemRepresentation { path -> (descriptor: Int32, failure: Int32) in
            guard let path else { return (-1, EINVAL) }
            let descriptor = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            return (descriptor, descriptor < 0 ? errno : 0)
        }
        guard opened.descriptor >= 0 else {
            if opened.failure == ENOENT { return nil }
            throw PluginRelayError.storageFailure
        }
        let descriptor = opened.descriptor
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else { throw PluginRelayError.storageFailure }
        guard metadata.st_size >= 0 else { throw PluginRelayError.storageFailure }
        guard metadata.st_size <= Int64(maximumBytes) else { throw PluginRelayError.capacity }
        do {
            var data = Data()
            while data.count <= maximumBytes {
                guard let part = try file.read(upToCount: min(64 * 1_024, maximumBytes + 1 - data.count)),
                      !part.isEmpty else { break }
                data.append(part)
            }
            guard data.count <= maximumBytes else { throw PluginRelayError.capacity }
            var finalMetadata = stat()
            guard Int64(data.count) == metadata.st_size,
                  Darwin.fstat(descriptor, &finalMetadata) == 0,
                  finalMetadata.st_size == metadata.st_size else { throw PluginRelayError.storageFailure }
            return data
        } catch let error as PluginRelayError { throw error }
        catch { throw PluginRelayError.storageFailure }
    }

    private func ensureDirectory() throws -> URL {
        let parent = fileURL.deletingLastPathComponent(), manager = FileManager.default
        try manager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var metadata = stat()
        guard parent.path.withCString({ Darwin.lstat($0, &metadata) }) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR else { throw PluginRelayError.storageFailure }
        return parent
    }

    public func writeAtomically(_ data: Data) throws {
        let manager = FileManager.default, parent = fileURL.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".relay-\(UUID().uuidString).tmp")
        defer { try? manager.removeItem(at: temporary) }
        do {
            _ = try ensureDirectory()
            if let phoneProtection {
                try phoneProtection.verify(at: parent)
                // Recheck a committed store's readability/policy before replacing
                // it. A protected/unavailable previous store must stay retained.
                if try readRegularFile(maximumBytes: 8 * 1_024 * 1_024) != nil {
                    try phoneProtection.verify(at: fileURL)
                }
            }
            var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
            #if os(iOS)
            attributes[.protectionKey] = phoneProtection == nil
                ? FileProtectionType.complete : FileProtectionType.completeUntilFirstUserAuthentication
            #elseif os(watchOS)
            attributes[.protectionKey] = FileProtectionType.complete
            #endif
            guard manager.createFile(atPath: temporary.path, contents: nil, attributes: attributes) else {
                throw PluginRelayError.storageFailure
            }
            if let phoneProtection { try phoneProtection.establish(at: temporary) }
            let file = try FileHandle(forWritingTo: temporary)
            do { try file.write(contentsOf: data); try file.synchronize(); try file.close() }
            catch { try? file.close(); throw error }
            if let phoneProtection {
                try phoneProtection.verify(at: parent)
                try phoneProtection.verify(at: temporary)
            }
            // The verified temporary inode is the committed store after this
            // same-directory rename, including its protection attributes. No
            // fallible post-commit check may claim the old bytes were retained.
            let result = temporary.path.withCString { source in fileURL.path.withCString { target in Darwin.rename(source, target) } }
            guard result == 0 else { throw PluginRelayError.storageFailure }
            // Process-restart atomicity, not power-loss/fsync-directory durability.
        } catch { throw PluginRelayError.storageFailure }
    }
}

public struct PluginRelayStoreLimits: Sendable {
    public let maximumBytes: Int
    public let maximumSends: Int
    public let maximumReplies: Int
    public init(maximumBytes: Int = 8 * 1_024 * 1_024, maximumSends: Int = 256, maximumReplies: Int = 256) throws {
        guard (1...8 * 1_024 * 1_024).contains(maximumBytes), (1...256).contains(maximumSends),
              (1...256).contains(maximumReplies) else { throw PluginRelayError.invalidPayload }
        self.maximumBytes = maximumBytes; self.maximumSends = maximumSends; self.maximumReplies = maximumReplies
    }
}

public struct PluginRelaySendRecord: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case reserved, uncertain, accepted, replied }
    public let message: PluginRelayMessage
    public fileprivate(set) var state: State
    public fileprivate(set) var receipt: PluginRelayReceipt?
}

private struct PluginRelayStoredReply: Codable {
    let reply: PluginRelayReply
    var watchAcknowledged: Bool
}

/// Phone inbox/checkpoint only. Restoring it never restores live authority.
/// The coordinator must revalidate external session/device authority before each
/// call. Local epoch rotates separately via invalidate; saved binding does not.
public actor PluginRelayPhoneStore {
    private struct Snapshot: Codable {
        var version = 2
        let binding: PluginRelayBinding
        var sends: [PluginRelaySendRecord] = []
        var replies: [PluginRelayStoredReply] = []
        var cursor: Int64 = 0
    }
    private let persistence: any PluginRelayPersistence
    private let limits: PluginRelayStoreLimits
    private var fence: PluginRelayFence
    private var snapshot: Snapshot

    public init(persistence: any PluginRelayPersistence, fence: PluginRelayFence,
                limits: PluginRelayStoreLimits) throws {
        self.persistence = persistence; self.fence = fence; self.limits = limits
        try fence.binding.route.validate()
        if let data = try persistence.read(maximumBytes: limits.maximumBytes) {
            let value: Snapshot
            do { value = try JSONDecoder().decode(Snapshot.self, from: data) }
            catch { throw PluginRelayError.storageFailure }
            guard value.binding == fence.binding else { throw PluginRelayError.wrongBinding }
            try Self.validate(value, limits: limits); snapshot = value
        } else { snapshot = Snapshot(binding: fence.binding) }
    }
    /// Rotation is local only; it does not cancel a remote task or revoke a route.
    public func invalidate(using current: PluginRelayFence, newLocalEpoch: UUID) throws -> PluginRelayFence {
        try check(current)
        guard newLocalEpoch != current.localEpoch else { throw PluginRelayError.invalidPayload }
        fence = PluginRelayFence(binding: fence.binding, localEpoch: newLocalEpoch)
        return fence
    }
    public func cursor(using current: PluginRelayFence, permit: PluginRelayProPermit) throws -> Int64 {
        return try permit.withAdmission(for: current) {
            try check(current); return snapshot.cursor
        }
    }
    public func sendRecord(_ id: UUID, using current: PluginRelayFence, permit: PluginRelayProPermit) throws -> PluginRelaySendRecord? {
        return try permit.withAdmission(for: current) {
            try check(current); return snapshot.sends.first { $0.message.messageID == id }
        }
    }
    /// A repeat returns its original reservation/receipt, including uncertain
    /// sends. The HTTP coordinator may reconcile ONLY this same stable ID/body.
    @discardableResult
    public func reserve(_ message: PluginRelayMessage, using current: PluginRelayFence, permit: PluginRelayProPermit) throws -> PluginRelaySendRecord {
        return try permit.withAdmission(for: current) {
            try check(current); try message.validate()
            if let record = snapshot.sends.first(where: { $0.message.messageID == message.messageID }) {
                guard record.message == message else { throw PluginRelayError.reusedMessageID }
                return record
            }
            var value = snapshot
            value.sends.append(PluginRelaySendRecord(message: message, state: .reserved))
            try commit(value); return value.sends.last!
        }
    }
    public func markUncertain(_ id: UUID, using current: PluginRelayFence, permit: PluginRelayProPermit) throws {
        return try permit.withAdmission(for: current) {
            try check(current)
            guard let index = snapshot.sends.firstIndex(where: { $0.message.messageID == id }) else { throw PluginRelayError.unknownMessage }
            guard snapshot.sends[index].receipt == nil else { return }
            var value = snapshot; value.sends[index].state = .uncertain; try commit(value)
        }
    }
    public func record(_ receipt: PluginRelayReceipt, using current: PluginRelayFence, permit: PluginRelayProPermit) throws {
        return try permit.withAdmission(for: current) {
            try check(current); try receipt.validate()
            guard receipt.route == fence.binding.route else { throw PluginRelayError.wrongBinding }
            guard let index = snapshot.sends.firstIndex(where: { $0.message.messageID == receipt.requestID }) else {
                throw PluginRelayError.unknownMessage
            }
            if let previous = snapshot.sends[index].receipt {
                guard PluginRelayValidation.sameBytes(previous.receiptID, receipt.receiptID) else { throw PluginRelayError.conflict }
                if previous.state == .replied && receipt.state == .accepted { return }
            }
            var value = snapshot; value.sends[index].receipt = receipt
            value.sends[index].state = receipt.state == .accepted ? .accepted : .replied
            try commit(value)
        }
    }
    /// Broker cursor and full page content commit together. after must be the
    /// exact current checkpoint, rejecting stale concurrently completed polls.
    public func ingest(_ page: PluginRelayReplyPage, after: Int64, using current: PluginRelayFence, permit: PluginRelayProPermit) throws {
        return try permit.withAdmission(for: current) {
            try check(current); try page.validate()
            guard page.route == fence.binding.route else { throw PluginRelayError.wrongBinding }
            guard after == snapshot.cursor, page.cursor >= after,
                  page.replies.isEmpty ? page.cursor == after : page.cursor > after else { throw PluginRelayError.staleCursor }
            var value = snapshot
            for reply in page.replies {
                guard value.sends.contains(where: { $0.message.messageID == reply.requestID }) else { throw PluginRelayError.unknownMessage }
                if let old = value.replies.first(where: { $0.reply.requestID == reply.requestID }) {
                    guard old.reply == reply else { throw PluginRelayError.conflict }
                } else { value.replies.append(PluginRelayStoredReply(reply: reply, watchAcknowledged: false)) }
            }
            value.cursor = page.cursor; try commit(value)
        }
    }
    public func pendingReplies(using current: PluginRelayFence, permit: PluginRelayProPermit) throws -> [PluginRelayReply] {
        return try permit.withAdmission(for: current) {
            try check(current); return snapshot.replies.filter { !$0.watchAcknowledged }.map(\.reply)
        }
    }
    public func chunks(requestID: UUID, using current: PluginRelayFence, permit: PluginRelayProPermit) throws -> [PluginRelayChunk] {
        return try permit.withAdmission(for: current) {
            try check(current)
            guard let reply = snapshot.replies.first(where: { $0.reply.requestID == requestID })?.reply else {
                throw PluginRelayError.unknownMessage
            }
            return try PluginRelayChunk.split(reply, route: fence.binding.route)
        }
    }
    /// Only a complete-reply durable Watch acknowledgment advances this flag.
    /// A WC callback/HTTP cursor alone cannot acknowledge a reply.
    public func acknowledge(requestID: UUID, replyID: String, digest: String, using current: PluginRelayFence, permit: PluginRelayProPermit) throws {
        return try permit.withAdmission(for: current) {
            try check(current)
            guard let index = snapshot.replies.firstIndex(where: { $0.reply.requestID == requestID }) else {
                throw PluginRelayError.unknownMessage
            }
            let record = snapshot.replies[index]
            guard PluginRelayValidation.sameBytes(record.reply.replyID, replyID), PluginRelayValidation.digest(record.reply.text) == digest else {
                throw PluginRelayError.conflict
            }
            if record.watchAcknowledged { return }
            var value = snapshot; value.replies[index].watchAcknowledged = true; try commit(value)
        }
    }
    private func check(_ current: PluginRelayFence) throws {
        guard current == fence else { throw PluginRelayError.wrongBinding }
    }
    private func commit(_ value: Snapshot) throws {
        try Self.validate(value, limits: limits)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= limits.maximumBytes else { throw PluginRelayError.capacity }
        do { try persistence.writeAtomically(data) } catch { throw PluginRelayError.storageFailure }
        snapshot = value
    }
    private static func validate(_ value: Snapshot, limits: PluginRelayStoreLimits) throws {
        try value.binding.route.validate()
        guard value.version == 2, value.cursor >= 0,
              value.sends.count <= limits.maximumSends, value.replies.count <= limits.maximumReplies else { throw PluginRelayError.capacity }
        guard Set(value.sends.map { $0.message.messageID }).count == value.sends.count,
              Set(value.replies.map { $0.reply.requestID }).count == value.replies.count else { throw PluginRelayError.conflict }
        for record in value.sends {
            try record.message.validate()
            if let receipt = record.receipt {
                try receipt.validate()
                guard receipt.route == value.binding.route, receipt.requestID == record.message.messageID,
                      record.state == (receipt.state == .accepted ? .accepted : .replied) else { throw PluginRelayError.conflict }
            } else if record.state != .reserved && record.state != .uncertain { throw PluginRelayError.conflict }
        }
        for record in value.replies {
            try record.reply.validate()
            guard value.sends.contains(where: { $0.message.messageID == record.reply.requestID }) else { throw PluginRelayError.unknownMessage }
        }
    }
}

/// Watch-side durable partial assembly and complete inbox, with independent
/// checkpoints from the phone's broker cursor. No remote readiness is stored.
public actor PluginRelayWatchStore {
    private struct Snapshot: Codable {
        var version = 2
        let binding: PluginRelayBinding
        var partial: [PluginRelayChunk] = []
        var complete: [PluginRelayReply] = []
        var outgoing: [PluginRelaySendRecord] = []
    }
    private let persistence: any PluginRelayPersistence
    private let maximumBytes: Int
    private let maximumReplies: Int
    private var fence: PluginRelayFence
    private var snapshot: Snapshot
    public init(persistence: any PluginRelayPersistence, fence: PluginRelayFence,
                maximumBytes: Int = 1_024 * 1_024, maximumReplies: Int = 100) throws {
        guard (1...1_024 * 1_024).contains(maximumBytes), (1...100).contains(maximumReplies) else { throw PluginRelayError.capacity }
        self.persistence = persistence; self.maximumBytes = maximumBytes; self.maximumReplies = maximumReplies; self.fence = fence
        if let data = try persistence.read(maximumBytes: maximumBytes) {
            let value: Snapshot
            do { value = try JSONDecoder().decode(Snapshot.self, from: data) } catch { throw PluginRelayError.storageFailure }
            guard value.binding == fence.binding else { throw PluginRelayError.wrongBinding }
            try Self.validate(value, maximumReplies: maximumReplies); snapshot = value
        } else { snapshot = Snapshot(binding: fence.binding) }
    }
    public func invalidate(using current: PluginRelayFence, newLocalEpoch: UUID) throws -> PluginRelayFence {
        try check(current)
        guard newLocalEpoch != current.localEpoch else { throw PluginRelayError.invalidPayload }
        fence = PluginRelayFence(binding: fence.binding, localEpoch: newLocalEpoch); return fence
    }
    /// Save before the first courier send; restoration retains the logical ID.
    @discardableResult
    public func reserve(_ message: PluginRelayMessage, using current: PluginRelayFence) throws -> PluginRelaySendRecord {
        try check(current); try message.validate()
        if let record = snapshot.outgoing.first(where: { $0.message.messageID == message.messageID }) {
            guard record.message == message else { throw PluginRelayError.reusedMessageID }; return record
        }
        var value = snapshot; value.outgoing.append(PluginRelaySendRecord(message: message, state: .reserved))
        try commit(value); return value.outgoing.last!
    }
    public func outgoingMessages(using current: PluginRelayFence) throws -> [PluginRelaySendRecord] {
        try check(current); return snapshot.outgoing
    }
    public func markUncertain(_ id: UUID, using current: PluginRelayFence) throws {
        try check(current)
        guard let index = snapshot.outgoing.firstIndex(where: { $0.message.messageID == id }) else { throw PluginRelayError.unknownMessage }
        guard snapshot.outgoing[index].receipt == nil else { return }
        var value = snapshot; value.outgoing[index].state = .uncertain; try commit(value)
    }
    public func record(_ receipt: PluginRelayReceipt, using current: PluginRelayFence) throws {
        try check(current); try receipt.validate()
        guard receipt.route == fence.binding.route else { throw PluginRelayError.wrongBinding }
        guard let index = snapshot.outgoing.firstIndex(where: { $0.message.messageID == receipt.requestID }) else { throw PluginRelayError.unknownMessage }
        if let previous = snapshot.outgoing[index].receipt {
            guard PluginRelayValidation.sameBytes(previous.receiptID, receipt.receiptID) else { throw PluginRelayError.conflict }
            if previous.state == .replied && receipt.state == .accepted { return }
        }
        var value = snapshot; value.outgoing[index].receipt = receipt
        value.outgoing[index].state = receipt.state == .accepted ? .accepted : .replied
        try commit(value)
    }
    @discardableResult
    public func receive(_ chunk: PluginRelayChunk, using current: PluginRelayFence) throws -> PluginRelayReply? {
        try check(current); try chunk.validate()
        guard chunk.route == fence.binding.route else { throw PluginRelayError.wrongBinding }
        guard snapshot.outgoing.contains(where: { $0.message.messageID == chunk.requestID }) else { throw PluginRelayError.unknownMessage }
        if let complete = snapshot.complete.first(where: { $0.requestID == chunk.requestID }) {
            let expected = try PluginRelayChunk.split(complete, route: chunk.route)
            guard expected.contains(chunk) else { throw PluginRelayError.conflict }
            return complete
        }
        if let first = snapshot.partial.first, !first.sameAssembly(as: chunk) { throw PluginRelayError.conflict }
        if let old = snapshot.partial.first(where: { $0.index == chunk.index }) {
            guard old == chunk else { throw PluginRelayError.conflict }; return nil
        }
        var value = snapshot; value.partial.append(chunk)
        var result: PluginRelayReply?
        if value.partial.count == chunk.count {
            let text = value.partial.sorted { $0.index < $1.index }.map(\.text).joined()
            guard text.utf8.count == chunk.totalUTF8Bytes, PluginRelayValidation.digest(text) == chunk.digest else {
                throw PluginRelayError.conflict
            }
            result = try PluginRelayReply(requestID: chunk.requestID, replyID: chunk.replyID, text: text)
            value.complete.append(result!); value.partial = []
        }
        try commit(value); return result
    }
    public func completeReplies(using current: PluginRelayFence) throws -> [PluginRelayReply] {
        try check(current); return snapshot.complete
    }
    /// Call only after receive has durably saved a complete reply. The envelope
    /// can be retried with a new courierID until the phone durably records it.
    public func acknowledgment(requestID: UUID, courierID: UUID, using current: PluginRelayFence) throws -> PluginRelayV2Envelope {
        try check(current)
        guard let reply = snapshot.complete.first(where: { $0.requestID == requestID }) else { throw PluginRelayError.unknownMessage }
        return try PluginRelayV2Envelope(courierID: courierID, fence: current, kind: .acknowledge,
                                        requestID: requestID, replyID: reply.replyID, digest: PluginRelayValidation.digest(reply.text))
    }
    private func check(_ current: PluginRelayFence) throws { guard current == fence else { throw PluginRelayError.wrongBinding } }
    private func commit(_ value: Snapshot) throws {
        try Self.validate(value, maximumReplies: maximumReplies)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= maximumBytes else { throw PluginRelayError.capacity }
        do { try persistence.writeAtomically(data) } catch { throw PluginRelayError.storageFailure }
        snapshot = value
    }
    private static func validate(_ value: Snapshot, maximumReplies: Int) throws {
        try value.binding.route.validate()
        guard value.version == 2, value.complete.count <= maximumReplies, value.partial.count <= 8,
              value.outgoing.count <= 256 else { throw PluginRelayError.capacity }
        guard Set(value.complete.map(\.requestID)).count == value.complete.count,
              Set(value.partial.map(\.index)).count == value.partial.count,
              Set(value.outgoing.map { $0.message.messageID }).count == value.outgoing.count else { throw PluginRelayError.conflict }
        for record in value.outgoing {
            try record.message.validate()
            if let receipt = record.receipt {
                try receipt.validate()
                guard receipt.route == value.binding.route, receipt.requestID == record.message.messageID,
                      record.state == (receipt.state == .accepted ? .accepted : .replied) else { throw PluginRelayError.conflict }
            } else if record.state != .reserved && record.state != .uncertain { throw PluginRelayError.conflict }
        }
        for reply in value.complete {
            try reply.validate()
            guard value.outgoing.contains(where: { $0.message.messageID == reply.requestID }) else { throw PluginRelayError.unknownMessage }
        }
        if let first = value.partial.first {
            guard value.partial.count < first.count, !value.complete.contains(where: { $0.requestID == first.requestID }),
                  value.partial.reduce(0, { $0 + $1.text.utf8.count }) <= first.totalUTF8Bytes else { throw PluginRelayError.conflict }
            guard value.outgoing.contains(where: { $0.message.messageID == first.requestID }) else { throw PluginRelayError.unknownMessage }
            for chunk in value.partial {
                try chunk.validate()
                guard chunk.route == value.binding.route, chunk.sameAssembly(as: first) else { throw PluginRelayError.wrongBinding }
            }
        }
    }
}
