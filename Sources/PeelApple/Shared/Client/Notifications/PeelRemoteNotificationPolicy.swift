import Foundation

/// Local adapter payload for a one-shot notification delivered over an
/// already authenticated Peel control session.
///
/// The actual shared wire message carries a request ID and pairing ID. The
/// receiver creates the per-control session ID before passing this local value
/// to admission. Admission converts both IDs to UUID values before anything
/// reaches UserNotifications.
public struct PeelRemoteNotificationMessage: Codable, Hashable, Sendable {
    public static let messageType = "remoteNotification"

    public let type: String
    public let requestId: String
    public let sessionId: String
    public let title: String
    public let body: String
    public let issuedAt: TimeInterval
    public let expiresAt: TimeInterval

    public init(
        requestId: String,
        sessionId: String,
        title: String,
        body: String,
        issuedAt: TimeInterval,
        expiresAt: TimeInterval,
        type: String = PeelRemoteNotificationMessage.messageType
    ) {
        self.type = type
        self.requestId = requestId
        self.sessionId = sessionId
        self.title = title
        self.body = body
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    public init(
        requestId: UUID,
        sessionId: UUID,
        title: String,
        body: String,
        issuedAt: TimeInterval,
        expiresAt: TimeInterval
    ) {
        self.init(
            requestId: requestId.uuidString,
            sessionId: sessionId.uuidString,
            title: title,
            body: body,
            issuedAt: issuedAt,
            expiresAt: expiresAt
        )
    }
}

/// The values passed to the local presenter after a message has passed all
/// admission checks. IDs are typed so the presenter cannot accidentally use a
/// non-UUID wire value as a notification identifier or correlation key.
public struct PeelRemoteNotificationAdmission: Equatable, Sendable {
    public let requestId: UUID
    public let sessionId: UUID
    public let title: String
    public let body: String
    public let issuedAt: TimeInterval
    public let expiresAt: TimeInterval

    public init(
        requestId: UUID,
        sessionId: UUID,
        title: String,
        body: String,
        issuedAt: TimeInterval,
        expiresAt: TimeInterval
    ) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.title = title
        self.body = body
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }
}

public enum PeelRemoteNotificationAdmissionRejection:
    Error, Equatable, Sendable, LocalizedError
{
    case unsupportedMessageType
    case invalidRequestId
    case invalidSessionId
    case invalidTimestamp
    case expired
    case expirationTooFar
    case issuedAfterExpiration
    case emptyTitle
    case titleTooLong
    case emptyBody
    case bodyTooLong
    /// Control characters and newlines are rejected. URL or markup-looking
    /// text remains inert plain text in the local notification content.
    case nonPlainText
    case duplicate
    case rateLimited

    public var errorDescription: String? {
        switch self {
        case .unsupportedMessageType:
            return "The notification message type is unsupported."
        case .invalidRequestId:
            return "The notification request ID is not a UUID."
        case .invalidSessionId:
            return "The notification session ID is not a UUID."
        case .invalidTimestamp:
            return "The notification timestamps are invalid."
        case .expired:
            return "The notification has expired."
        case .expirationTooFar:
            return "The notification expiration exceeds the allowed lifetime."
        case .issuedAfterExpiration:
            return "The notification issue time is after its expiration."
        case .emptyTitle:
            return "The notification title is empty."
        case .titleTooLong:
            return "The notification title exceeds the allowed length."
        case .emptyBody:
            return "The notification body is empty."
        case .bodyTooLong:
            return "The notification body exceeds the allowed length."
        case .nonPlainText:
            return "The notification contains a control character or newline."
        case .duplicate:
            return "The notification request was already admitted."
        case .rateLimited:
            return "The notification session exceeded its delivery rate limit."
        }
    }
}

/// Pure, bounded admission state for one-way remote notification requests.
///
/// This policy deliberately does not know about pairing keys, sockets, APNs,
/// UserNotifications, accounts, or UI. The caller must perform the existing
/// connection, pairing, generation, visibility, and opt-in checks before
/// calling `admit`.
public struct PeelRemoteNotificationAdmissionPolicy: Sendable {
    public struct Limits: Equatable, Sendable {
        public let maxTitleCharacters: Int
        public let maxTitleUTF8Bytes: Int
        public let maxBodyCharacters: Int
        public let maxBodyUTF8Bytes: Int
        public let maxDedupeEntries: Int
        public let maxNotificationsPerSession: Int
        public let rateWindowSeconds: TimeInterval
        public let maxLifetimeSeconds: TimeInterval

        public init(
            maxTitleCharacters: Int = 120,
            maxTitleUTF8Bytes: Int = 480,
            maxBodyCharacters: Int = 2_000,
            maxBodyUTF8Bytes: Int = 8_000,
            maxDedupeEntries: Int = 64,
            maxNotificationsPerSession: Int = 5,
            rateWindowSeconds: TimeInterval = 60,
            maxLifetimeSeconds: TimeInterval = 60
        ) {
            // These upper bounds keep a caller-provided configuration from
            // weakening the wire and state limits that this policy promises.
            self.maxTitleCharacters = max(1, min(maxTitleCharacters, 120))
            self.maxTitleUTF8Bytes = max(1, min(maxTitleUTF8Bytes, 480))
            self.maxBodyCharacters = max(1, min(maxBodyCharacters, 2_000))
            self.maxBodyUTF8Bytes = max(1, min(maxBodyUTF8Bytes, 8_000))
            self.maxDedupeEntries = max(1, min(maxDedupeEntries, 64))
            self.maxNotificationsPerSession = max(
                1,
                min(maxNotificationsPerSession, 64)
            )
            let safeRateWindow = rateWindowSeconds.isFinite ? rateWindowSeconds : 60
            let safeLifetime = maxLifetimeSeconds.isFinite ? maxLifetimeSeconds : 60
            self.rateWindowSeconds = max(1, min(safeRateWindow, 60))
            self.maxLifetimeSeconds = max(0.001, min(safeLifetime, 60))
        }
    }

    private struct DedupeKey: Hashable, Sendable {
        let requestId: UUID
        let sessionId: UUID
    }

    private enum TextValidation {
        case accepted(String)
        case empty
        case tooLong
        case nonPlainText
    }

    public let limits: Limits

    private var dedupeKeys: Set<DedupeKey> = []
    private var dedupeOrder: [DedupeKey] = []
    private var recentDeliveryTimesBySession: [UUID: [TimeInterval]] = [:]
    private var rateSessionOrder: [UUID] = []

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    public var trackedDedupeCount: Int {
        dedupeOrder.count
    }

    public var trackedRateSessionCount: Int {
        rateSessionOrder.count
    }

    /// Admit a request at the supplied wall-clock timestamp.
    ///
    /// `now` is injectable so this method can be exercised without sleeping.
    /// A successful result means only that the request passed local admission;
    /// it does not mean that iOS displayed the notification.
    public mutating func admit(
        _ message: PeelRemoteNotificationMessage,
        now: TimeInterval
    ) -> Result<PeelRemoteNotificationAdmission, PeelRemoteNotificationAdmissionRejection> {
        guard message.type == PeelRemoteNotificationMessage.messageType else {
            return .failure(.unsupportedMessageType)
        }

        guard now.isFinite,
              message.issuedAt.isFinite,
              message.expiresAt.isFinite else {
            return .failure(.invalidTimestamp)
        }

        guard let requestId = UUID(uuidString: message.requestId) else {
            return .failure(.invalidRequestId)
        }
        guard let sessionId = UUID(uuidString: message.sessionId) else {
            return .failure(.invalidSessionId)
        }

        let dedupeKey = DedupeKey(requestId: requestId, sessionId: sessionId)
        guard !dedupeKeys.contains(dedupeKey) else {
            return .failure(.duplicate)
        }

        guard message.expiresAt > now else {
            return .failure(.expired)
        }
        guard message.expiresAt - now <= limits.maxLifetimeSeconds else {
            return .failure(.expirationTooFar)
        }
        guard message.issuedAt <= message.expiresAt else {
            return .failure(.issuedAfterExpiration)
        }

        let title: String
        switch Self.validatePlainText(
            message.title,
            maximumCharacters: limits.maxTitleCharacters,
            maximumUTF8Bytes: limits.maxTitleUTF8Bytes
        ) {
        case .accepted(let value):
            title = value
        case .empty:
            return .failure(.emptyTitle)
        case .tooLong:
            return .failure(.titleTooLong)
        case .nonPlainText:
            return .failure(.nonPlainText)
        }

        let body: String
        switch Self.validatePlainText(
            message.body,
            maximumCharacters: limits.maxBodyCharacters,
            maximumUTF8Bytes: limits.maxBodyUTF8Bytes
        ) {
        case .accepted(let value):
            body = value
        case .empty:
            return .failure(.emptyBody)
        case .tooLong:
            return .failure(.bodyTooLong)
        case .nonPlainText:
            return .failure(.nonPlainText)
        }

        var recent = recentDeliveryTimesBySession[sessionId] ?? []
        let cutoff = now - limits.rateWindowSeconds
        recent.removeAll { $0 < cutoff }
        if recent.count >= limits.maxNotificationsPerSession {
            recentDeliveryTimesBySession[sessionId] = recent
            return .failure(.rateLimited)
        }

        recent.append(now)
        rememberRateSession(sessionId, events: recent)
        rememberDedupeKey(dedupeKey)

        return .success(
            PeelRemoteNotificationAdmission(
                requestId: requestId,
                sessionId: sessionId,
                title: title,
                body: body,
                issuedAt: message.issuedAt,
                expiresAt: message.expiresAt
            )
        )
    }

    public mutating func reset() {
        dedupeKeys.removeAll(keepingCapacity: true)
        dedupeOrder.removeAll(keepingCapacity: true)
        recentDeliveryTimesBySession.removeAll(keepingCapacity: true)
        rateSessionOrder.removeAll(keepingCapacity: true)
    }

    public mutating func reset(sessionId: UUID) {
        recentDeliveryTimesBySession.removeValue(forKey: sessionId)
        rateSessionOrder.removeAll { $0 == sessionId }
        let keysToRemove = dedupeOrder.filter { $0.sessionId == sessionId }
        for key in keysToRemove {
            dedupeKeys.remove(key)
        }
        dedupeOrder.removeAll { $0.sessionId == sessionId }
    }

    private mutating func rememberDedupeKey(_ key: DedupeKey) {
        dedupeKeys.insert(key)
        dedupeOrder.append(key)

        while dedupeOrder.count > limits.maxDedupeEntries {
            let evicted = dedupeOrder.removeFirst()
            dedupeKeys.remove(evicted)
        }
    }

    private mutating func rememberRateSession(
        _ sessionId: UUID,
        events: [TimeInterval]
    ) {
        if recentDeliveryTimesBySession[sessionId] == nil {
            rateSessionOrder.append(sessionId)
        }
        recentDeliveryTimesBySession[sessionId] = events

        // A hostile peer must not be able to create an unbounded dictionary by
        // changing its session ID. The rate-state bound is independent of the
        // 64-entry request dedupe bound, but uses the same small ceiling.
        while rateSessionOrder.count > 64 {
            let evicted = rateSessionOrder.removeFirst()
            recentDeliveryTimesBySession.removeValue(forKey: evicted)
        }
    }

    private static func validatePlainText(
        _ rawValue: String,
        maximumCharacters: Int,
        maximumUTF8Bytes: Int
    ) -> TextValidation {
        // Keep the wire value plain text. In particular, reject controls and
        // newlines before trimming so a caller cannot hide them at a boundary.
        guard rawValue.unicodeScalars.allSatisfy({ scalar in
            !CharacterSet.controlCharacters.contains(scalar) &&
            !CharacterSet.newlines.contains(scalar)
        }) else {
            return .nonPlainText
        }

        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .empty }

        // Character count bounds what a user sees; the UTF-8 bound prevents a
        // string made from multi-byte scalars from bypassing the same limit.
        guard value.count <= maximumCharacters,
              value.utf8.count <= maximumUTF8Bytes else {
            return .tooLong
        }

        return .accepted(value)
    }
}
