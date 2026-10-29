import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Best-effort reader for ChatGPT conversation model cooldowns.
///
/// This endpoint family is intentionally kept separate from the required Codex dashboard fetch. A
/// failure at any stage simply omits the optional adjunct snapshot.
@MainActor
public enum ChatGPTModelLimitsFetcher {
    private static let sessionURL = URL(string: "https://chatgpt.com/api/auth/session")!
    private static let modelsURL = URL(
        string: "https://chatgpt.com/backend-api/models?iim=false&include_icons=false")!
    private static let conversationInitURL = URL(string: "https://chatgpt.com/backend-api/conversation/init")!
    private static let requestTimeoutCap: TimeInterval = 2
    private static let userAgent = "CodexBar"

    private struct AuthSessionResponse: Decodable {
        let accessToken: String?
        let user: AuthUser?
    }

    private struct AuthUser: Decodable {
        let email: String?
    }

    /// Fetches optional ChatGPT model cooldowns for the account represented by `expectedEmail`.
    ///
    /// The supplied cookie header is used only for this sequential, three-stage pipeline. The
    /// session token is held in memory for the duration of the call and is never logged or persisted.
    public static func fetch(
        cookieHeader: String,
        expectedEmail: String,
        deadline: Date,
        logger: @escaping (String) -> Void) async -> ChatGPTModelLimitsSnapshot?
    {
        let cookieHeader = cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cookieHeader.isEmpty,
              cookieHeader.rangeOfCharacter(from: .newlines) == nil,
              let expectedEmail = self.normalizedEmail(expectedEmail)
        else { return nil }

        do {
            guard let timeout = self.requestTimeout(until: deadline) else {
                return nil
            }
            try Task.checkCancellation()
            let sessionRequest = self.makeRequest(
                url: self.sessionURL,
                method: "GET",
                cookieHeader: cookieHeader,
                accessToken: nil,
                timeout: timeout)
            let (sessionData, sessionResponse) = try await CodexAuthenticatedHTTPTransport.current.data(
                for: sessionRequest)
            let sessionStatus = self.statusCode(for: sessionResponse)
            logger("chatgpt limits stage=session status=\(sessionStatus)")
            guard self.isSuccess(sessionStatus) else { return nil }

            guard let session = try? JSONDecoder().decode(AuthSessionResponse.self, from: sessionData),
                  let accessToken = session.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !accessToken.isEmpty,
                  let signedInEmail = self.normalizedEmail(session.user?.email),
                  signedInEmail == expectedEmail,
                  accessToken.rangeOfCharacter(from: .newlines) == nil
            else {
                logger("chatgpt limits stage=session invalid")
                return nil
            }

            guard let modelsTimeout = self.requestTimeout(until: deadline) else {
                return nil
            }
            try Task.checkCancellation()
            let modelsRequest = self.makeRequest(
                url: self.modelsURL,
                method: "GET",
                cookieHeader: cookieHeader,
                accessToken: accessToken,
                timeout: modelsTimeout)
            let (catalogData, modelsResponse) = try await CodexAuthenticatedHTTPTransport.current.data(
                for: modelsRequest)
            let modelsStatus = self.statusCode(for: modelsResponse)
            logger("chatgpt limits stage=models status=\(modelsStatus)")
            guard self.isSuccess(modelsStatus) else { return nil }

            let requestedModelSlugs: [String]
            do {
                requestedModelSlugs = try ChatGPTModelLimitsParser.requestedModelSlugs(catalog: catalogData)
            } catch {
                logger("chatgpt limits stage=parser invalid")
                return nil
            }

            var mergedMetadata: [String: Any]?
            var modelLimits: [Any] = []
            for modelSlug in requestedModelSlugs.prefix(2) {
                guard let initTimeout = self.requestTimeout(until: deadline) else {
                    return nil
                }
                try Task.checkCancellation()
                let initRequest = try self.makeConversationInitRequest(
                    cookieHeader: cookieHeader,
                    accessToken: accessToken,
                    requestedModelSlug: modelSlug,
                    timeout: initTimeout)
                let (metadataData, initResponse) = try await CodexAuthenticatedHTTPTransport.current.data(
                    for: initRequest)
                try Task.checkCancellation()
                let initStatus = self.statusCode(for: initResponse)
                logger("chatgpt limits stage=conversation_init status=\(initStatus)")
                guard self.isSuccess(initStatus) else { return nil }

                guard let decodedMetadata = self.decodeModelLimitsMetadata(from: metadataData) else {
                    logger("chatgpt limits stage=conversation_init invalid")
                    return nil
                }
                if mergedMetadata == nil {
                    mergedMetadata = decodedMetadata.object
                }
                modelLimits.append(contentsOf: decodedMetadata.modelLimits)
            }

            let metadataData: Data
            do {
                var metadataObject = mergedMetadata ?? [:]
                metadataObject["model_limits"] = modelLimits
                metadataData = try JSONSerialization.data(withJSONObject: metadataObject, options: [])
            } catch {
                logger("chatgpt limits stage=parser invalid")
                return nil
            }
            try Task.checkCancellation()

            do {
                return try ChatGPTModelLimitsParser.parse(
                    catalog: catalogData,
                    metadata: metadataData,
                    now: Date())
            } catch {
                logger("chatgpt limits stage=parser invalid")
                return nil
            }
        } catch is CancellationError {
            return nil
        } catch {
            // Keep transport and request errors opaque: a cookie, token, response body, or NSError
            // description must never appear in the provider log.
            logger("chatgpt limits stage=unavailable")
            return nil
        }
    }

    private static func normalizedEmail(_ email: String?) -> String? {
        guard let email else { return nil }
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func requestTimeout(until deadline: Date) -> TimeInterval? {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return nil }
        return min(self.requestTimeoutCap, remaining)
    }

    private static func statusCode(for response: URLResponse) -> Int {
        (response as? HTTPURLResponse)?.statusCode ?? -1
    }

    private static func isSuccess(_ statusCode: Int) -> Bool {
        (200..<300).contains(statusCode)
    }

    private static func makeRequest(
        url: URL,
        method: String,
        cookieHeader: String,
        accessToken: String?,
        timeout: TimeInterval) -> URLRequest
    {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
        request.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func makeConversationInitRequest(
        cookieHeader: String,
        accessToken: String,
        requestedModelSlug: String,
        timeout: TimeInterval) throws -> URLRequest
    {
        let timezone = TimeZone.current
        let body: [String: Any] = [
            "conversation_origin": "chat",
            "requested_default_model": requestedModelSlug,
            "timezone": timezone.identifier,
            "timezone_offset_min": -timezone.secondsFromGMT() / 60,
            "system_hints": NSNull(),
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [])

        var request = self.makeRequest(
            url: self.conversationInitURL,
            method: "POST",
            cookieHeader: cookieHeader,
            accessToken: accessToken,
            timeout: timeout)
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private static func decodeModelLimitsMetadata(from data: Data) -> (object: [String: Any], modelLimits: [Any])? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelLimits = object["model_limits"] as? [Any],
              modelLimits.allSatisfy({ rawLimit in
                  guard let limit = rawLimit as? [String: Any],
                        let modelSlug = limit["model_slug"] as? String
                  else { return false }
                  return !modelSlug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              })
        else { return nil }
        return (object, modelLimits)
    }
}
