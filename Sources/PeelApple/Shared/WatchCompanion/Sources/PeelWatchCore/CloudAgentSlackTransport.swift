import Foundation
import CryptoKit

/// iPhone-only bridge to the user's existing Slack-connected Dot/Grok Bot.
/// No arbitrary endpoint, model inference, OAuth installation or real message
/// is performed by construction. The UI supplies a user-authorized OAuth token
/// from device-only Keychain; no token enters a Codable/Watch payload.
@available(watchOS, unavailable, message: "Cloud agent networking and credentials remain on iPhone.")
public actor CloudAgentSlackTransport: CloudAgentTransport {
    public typealias TokenProvider = @Sendable () async throws -> String?
    private let configuration: CloudAgentSlackConfiguration?
    private let tokenProvider: TokenProvider
    private let stateStore: CloudAgentStateStore
    private let networkConfiguration: @Sendable () -> URLSessionConfiguration
    private let now: @Sendable () -> Date
    private var verifiedToken: String?
    private var verifiedUntil = Date.distantPast
    private var verifying = false
    private var activeIDs: Set<UUID> = []
    private var cancelledIDs: Set<UUID> = []
    private var operations: [UUID: CloudAgentHTTPOperation] = [:]

    public init(configuration: CloudAgentSlackConfiguration?, tokenProvider: @escaping TokenProvider,
                stateStore: CloudAgentStateStore) {
        self.configuration = configuration; self.tokenProvider = tokenProvider; self.stateStore = stateStore
        self.networkConfiguration = { Self.secureNetworkConfiguration() }; self.now = { Date() }
    }

    /// Test-only network substitution. Production always uses fixed Slack URLs
    /// with the secure, redirect-refusing HTTP operation.
    init(configuration: CloudAgentSlackConfiguration?, tokenProvider: @escaping TokenProvider,
         stateStore: CloudAgentStateStore, networkConfiguration: @escaping @Sendable () -> URLSessionConfiguration,
         now: @escaping @Sendable () -> Date) {
        self.configuration = configuration; self.tokenProvider = tokenProvider; self.stateStore = stateStore
        self.networkConfiguration = networkConfiguration; self.now = now
    }

    public func availability() async -> CloudAgentAvailability {
        guard configuration != nil else { return .needsConfiguration }
        do {
            let token = try await token()
            return verifiedToken == token && verifiedUntil > now() ? .ready : .needsVerification
        } catch let error as CloudAgentError {
            return error == .needsConfiguration ? .needsConfiguration : .unavailable(error)
        } catch { return .unavailable(.needsConfiguration) }
    }

    public func verifyConfiguration() async throws -> CloudAgentAvailability {
        let id = UUID(); try begin(id); defer { end(id) }
        try await verify(id: id)
        return .ready
    }

    public func send(text: String, requestID: UUID,
                     conversation: CloudAgentConversation? = nil) async throws -> CloudAgentSendReceipt {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4_000, text.utf8.count <= 16_000 else { throw CloudAgentError.invalidText }
        guard let config = configuration else { throw CloudAgentError.needsConfiguration }
        if let conversation, !conversation.matches(config) { throw CloudAgentError.wrongConversation }
        try begin(requestID); defer { end(requestID) }
        try await ensureVerified(id: requestID)
        let thread = conversation?.threadTimestamp ?? config.threadTimestamp
        // The digest binds a stable request ID to exact target and text without
        // persisting message contents in the send ledger.
        let digestData = try JSONEncoder().encode([config.id.uuidString, config.teamID, config.channelID,
                                                  config.targetBotUserID, thread ?? "", text])
        let digest = SHA256.hash(data: digestData).map { String(format: "%02x", $0) }.joined()
        if let saved = try await stateStore.reserveSend(id: requestID, digest: digest, now: now()) {
            guard saved.requestID == requestID, saved.conversation.matches(config),
                  conversation.map({ saved.conversation == $0 }) ?? true,
                  CloudAgentValidation.timestamp(saved.messageTimestamp) else { throw CloudAgentError.storageFailure }
            return saved
        }
        do {
            let token = try await token()
            let escaped = text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            var body: [String: Any] = ["channel": config.channelID, "text": "<@\(config.targetBotUserID)> \(escaped)",
                                      "unfurl_links": false, "unfurl_media": false, "reply_broadcast": false,
                                      "parse": "none"]
            if let thread { body["thread_ts"] = thread }
            let result = try await request("chat.postMessage", token: token, body: body, id: requestID)
            guard result["channel"] as? String == config.channelID,
                  let timestamp = result["ts"] as? String, CloudAgentValidation.timestamp(timestamp) else {
                throw CloudAgentError.invalidResponse
            }
            let conversation = try CloudAgentConversation(configuration: config, threadTimestamp: thread ?? timestamp)
            let receipt = CloudAgentSendReceipt(requestID: requestID, conversation: conversation, messageTimestamp: timestamp)
            try await stateStore.completeSend(receipt)
            return receipt
        } catch let error as CloudAgentError {
            // Only a known definitive rejection releases a request for a safe retry.
            switch error {
            case .serviceRejected, .rateLimited:
                try await stateStore.releaseRejectedSend(id: requestID)
                throw error
            default: throw CloudAgentError.deliveryUnknown
            }
        } catch { throw CloudAgentError.deliveryUnknown }
    }

    public func replies(in conversation: CloudAgentConversation, cursor: CloudAgentCursor? = nil,
                        requestID: UUID = UUID()) async throws -> CloudAgentReplyPage {
        guard let config = configuration else { throw CloudAgentError.needsConfiguration }
        guard conversation.matches(config) else { throw CloudAgentError.wrongConversation }
        let stored = await stateStore.cursor(for: conversation)
        let cursor = cursor ?? stored ?? CloudAgentCursor(conversation: conversation)
        try cursor.validate(for: conversation)
        try begin(requestID); defer { end(requestID) }
        try await ensureVerified(id: requestID)
        var body: [String: Any] = ["channel": config.channelID, "ts": conversation.threadTimestamp,
                                  "oldest": cursor.oldestTimestamp, "inclusive": true, "limit": 15]
        if let pageCursor = cursor.pageCursor { body["cursor"] = pageCursor }
        let result = try await request("conversations.replies", token: try await token(), body: body, id: requestID)
        guard let messages = result["messages"] as? [[String: Any]], messages.count <= 15 else {
            throw CloudAgentError.invalidResponse
        }
        let metadata = result["response_metadata"] as? [String: Any]
        let rawNext = metadata?["next_cursor"] as? String
        let next = rawNext.flatMap { $0.isEmpty ? nil : $0 }
        let hasMore = result["has_more"] as? Bool ?? false
        guard !hasMore || next != nil, next.map({ $0.utf8.count <= 1_024 && !$0.contains(where: { $0.isNewline }) }) ?? true,
              next == nil || next != cursor.pageCursor else { throw CloudAgentError.invalidResponse }
        var seen = Set(cursor.seenTimestamps)
        var revisions = cursor.messageRevisions
        var batchMaximum = cursor.batchMaximumTimestamp
        var replies: [CloudAgentReply] = []
        for message in messages {
            guard let timestamp = message["ts"] as? String, CloudAgentValidation.timestamp(timestamp) else {
                throw CloudAgentError.invalidResponse
            }
            guard timestamp == conversation.threadTimestamp || message["thread_ts"] as? String == conversation.threadTimestamp else { continue }
            if CloudAgentValidation.compare(timestamp, batchMaximum) == .orderedDescending { batchMaximum = timestamp }
            guard CloudAgentValidation.compare(timestamp, cursor.oldestTimestamp) != .orderedAscending,
                  timestamp != conversation.threadTimestamp,
                  message["type"] as? String == "message",
                  message["thread_ts"] as? String == conversation.threadTimestamp,
                  message["user"] as? String == config.targetBotUserID,
                  message["subtype"] == nil || message["subtype"] as? String == "bot_message" else { continue }
            guard let text = message["text"] as? String, !text.isEmpty, text.utf8.count <= 32_000 else {
                throw CloudAgentError.invalidResponse
            }
            let revision = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
            guard revisions[timestamp] != revision else { continue }
            seen.insert(timestamp)
            revisions[timestamp] = revision
            replies.append(CloudAgentReply(conversation: conversation, timestamp: timestamp,
                                          senderUserID: config.targetBotUserID, text: text))
        }
        replies.sort { CloudAgentValidation.compare($0.timestamp, $1.timestamp) == .orderedAscending }
        let orderedSeen = seen.sorted { CloudAgentValidation.compare($0, $1) == .orderedAscending }
        let retainedSeen = Array(orderedSeen.suffix(256))
        revisions = revisions.filter { retainedSeen.contains($0.key) }
        // Revisit the latest fifteen bot messages to observe Slack's edited
        // responses (e.g. a thinking placeholder becoming the final answer).
        // The UI upserts stable reply IDs rather than appending edited duplicates.
        let overlap = orderedSeen.suffix(15).first ?? batchMaximum
        let advanced = CloudAgentCursor(conversation: conversation,
                                       oldestTimestamp: next == nil ? overlap : cursor.oldestTimestamp,
                                       pageCursor: next, batchMaximumTimestamp: batchMaximum,
                                       seenTimestamps: retainedSeen, messageRevisions: revisions)
        try advanced.validate(for: conversation)
        return CloudAgentReplyPage(messages: replies, cursor: advanced, nextPollAfter: now().addingTimeInterval(60))
    }

    /// Call only after the phone has durably stored the page's replies. Watch
    /// delivery is a separate acknowledged transport and must not gate storage.
    public func acknowledge(_ page: CloudAgentReplyPage) async throws {
        guard let config = configuration, page.cursor.conversation.matches(config),
              page.messages.allSatisfy({ $0.conversation == page.cursor.conversation }) else {
            throw CloudAgentError.wrongConversation
        }
        try await stateStore.saveCursor(page.cursor)
    }

    /// Cancels local requests only. Slack exposes no generic remote-agent stop
    /// operation; a post already accepted by Slack may still be processed.
    public func cancel(requestID: UUID) {
        guard activeIDs.contains(requestID) else { return }
        cancelledIDs.insert(requestID); operations[requestID]?.cancel()
    }

    public func invalidate() {
        for id in activeIDs { cancelledIDs.insert(id) }
        for operation in operations.values { operation.cancel() }
        verifiedToken = nil; verifiedUntil = .distantPast
    }

    private func begin(_ id: UUID) throws {
        guard !activeIDs.contains(id), activeIDs.count < 4 else { throw CloudAgentError.busy }
        activeIDs.insert(id)
    }
    private func end(_ id: UUID) { activeIDs.remove(id); cancelledIDs.remove(id); operations.removeValue(forKey: id) }
    private func checkCancellation(_ id: UUID) throws {
        if Task.isCancelled || cancelledIDs.contains(id) { throw CloudAgentError.cancelled }
    }
    private func token() async throws -> String {
        guard let token = try await tokenProvider(),
              token.hasPrefix("xoxp-") || token.hasPrefix("xoxe.xoxp-"),
              (16...4_096).contains(token.utf8.count),
              token.utf8.allSatisfy({ (45...46).contains($0) || (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else {
            verifiedToken = nil; verifiedUntil = .distantPast
            throw CloudAgentError.needsConfiguration
        }
        return token
    }
    private func ensureVerified(id: UUID) async throws {
        try checkCancellation(id)
        let token = try await token()
        if verifiedToken != token || verifiedUntil <= now() { try await verify(id: id) }
        try checkCancellation(id)
    }
    private func verify(id: UUID) async throws {
        guard let config = configuration else { throw CloudAgentError.needsConfiguration }
        guard !verifying else { throw CloudAgentError.busy }
        verifying = true; defer { verifying = false }
        verifiedToken = nil; verifiedUntil = .distantPast
        let token = try await token()
        let auth = try await request("auth.test", token: token, body: [:], id: id)
        guard auth["team_id"] as? String == config.teamID else { throw CloudAgentError.wrongWorkspace }
        guard let userID = auth["user_id"] as? String,
              CloudAgentValidation.slackID(userID, prefixes: "UW"), auth["bot_id"] == nil,
              userID != config.targetBotUserID else { throw CloudAgentError.invalidConfiguration }
        let botResult = try await request("users.info", token: token, body: ["user": config.targetBotUserID], id: id)
        guard let bot = botResult["user"] as? [String: Any], bot["id"] as? String == config.targetBotUserID,
              bot["team_id"] as? String == config.teamID, bot["deleted"] as? Bool != true,
              bot["is_bot"] as? Bool == true || bot["is_app_user"] as? Bool == true else { throw CloudAgentError.wrongBot }
        let channelResult = try await request("conversations.info", token: token, body: ["channel": config.channelID], id: id)
        guard let channel = channelResult["channel"] as? [String: Any], channel["id"] as? String == config.channelID,
              channel["is_archived"] as? Bool != true else { throw CloudAgentError.wrongConversation }
        if channel["is_im"] as? Bool == true {
            guard channel["user"] as? String == config.targetBotUserID else { throw CloudAgentError.wrongConversation }
        } else {
            guard channel["is_member"] as? Bool == true else { throw CloudAgentError.wrongConversation }
            let membership = try await request("conversations.members", token: token,
                                               body: ["channel": config.channelID, "limit": 200], id: id)
            guard let members = membership["members"] as? [String], members.count <= 200,
                  members.contains(config.targetBotUserID) else {
                // A dedicated agent channel should fit this bounded membership
                // query. We do not scan an entire large workspace to guess.
                throw CloudAgentError.wrongConversation
            }
        }
        try checkCancellation(id)
        verifiedToken = token; verifiedUntil = now().addingTimeInterval(300)
    }

    private func request(_ method: String, token: String, body: [String: Any], id: UUID) async throws -> [String: Any] {
        try checkCancellation(id)
        guard let config = configuration,
              ["auth.test", "users.info", "conversations.info", "conversations.members", "chat.postMessage", "conversations.replies"].contains(method) else {
            throw CloudAgentError.invalidConfiguration
        }
        if method == "chat.postMessage" || method == "conversations.replies" {
            guard verifiedToken == token, verifiedUntil > now() else { throw CloudAgentError.needsVerification }
        }
        let interval: TimeInterval = method == "conversations.replies" ? 60 : method == "chat.postMessage" ? 1 : 0.25
        let rateKey = "\(config.teamID):\(method)" + (method == "chat.postMessage" ? ":\(config.channelID)" : "")
        try await stateStore.reserveRate(key: rateKey, now: now(), interval: interval)
        try checkCancellation(id)
        let isRead = method != "auth.test" && method != "chat.postMessage"
        var url = URLComponents(string: "https://slack.com/api/\(method)")!
        if isRead {
            url.queryItems = body.keys.sorted().map { URLQueryItem(name: $0, value: String(describing: body[$0]!)) }
        }
        var request = URLRequest(url: url.url!)
        request.httpMethod = isRead ? "GET" : "POST"; request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if !isRead { request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) }
        let operation = CloudAgentHTTPOperation(configuration: networkConfiguration()); operations[id] = operation
        defer { operations.removeValue(forKey: id) }
        let (data, response) = try await operation.run(request)
        try checkCancellation(id)
        if response.statusCode == 429 {
            let parsed = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "60") ?? 60
            let seconds = parsed.isFinite ? max(parsed, 1) : 60
            // Never shorten Slack's Retry-After. Unreasonably large values fail
            // closed until reconfiguration rather than overflowing Date.
            let retryAt = seconds <= 31_536_000 ? now().addingTimeInterval(seconds) : Date.distantFuture
            try await stateStore.deferRate(key: rateKey, until: retryAt)
            throw CloudAgentError.rateLimited(retryAt: retryAt)
        }
        guard response.statusCode == 200,
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = result["ok"] as? Bool else { throw CloudAgentError.invalidResponse }
        if !ok {
            let code = result["error"] as? String ?? "request_rejected"
            let definitive = ["invalid_auth", "token_expired", "token_revoked", "not_authed", "missing_scope", "no_permission",
                              "channel_not_found", "not_in_channel", "is_archived", "thread_not_found", "cannot_reply_to_message",
                              "restricted_action", "not_allowed_token_type", "account_inactive"]
            if ["invalid_auth", "token_expired", "token_revoked", "not_authed"].contains(code) {
                verifiedToken = nil; verifiedUntil = .distantPast
            }
            if definitive.contains(code) { throw CloudAgentError.serviceRejected(code) }
            // Slack documents fatal/internal errors as potentially partially
            // successful. Unknown service errors likewise cannot authorize replay.
            throw CloudAgentError.invalidResponse
        }
        return result
    }

    private static func secureNetworkConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 25
        configuration.httpMaximumConnectionsPerHost = 1
        return configuration
    }
}
