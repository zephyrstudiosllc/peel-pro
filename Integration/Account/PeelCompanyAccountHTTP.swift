import Foundation

struct PeelCompanyHTTPResponse: Sendable {
    let status: Int
    let data: Data
}

@MainActor
protocol PeelCompanyHTTPExecuting {
    func execute(_ request: URLRequest) async throws -> PeelCompanyHTTPResponse
}

@MainActor
final class PeelCompanyEphemeralHTTP: PeelCompanyHTTPExecuting {
    private let protocolClasses: [AnyClass]?
    init(protocolClasses: [AnyClass]? = nil) { self.protocolClasses = protocolClasses }
    static let maximumResponseBytes = 65_536
    static func configuration() -> URLSessionConfiguration {
        PeelCompanyHTTPWorker.configuration()
    }
    func execute(_ request: URLRequest) async throws -> PeelCompanyHTTPResponse {
        let worker = PeelCompanyHTTPWorker()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { worker.start(request, protocolClasses: protocolClasses, continuation: $0) }
        } onCancel: { worker.cancel() }
    }
}

/// One short-lived request/session. Mutable delegate state is protected by the
/// lock; no response body or underlying error is logged or returned as text.
nonisolated final class PeelCompanyHTTPWorker: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static func configuration() -> URLSessionConfiguration {
        let value = URLSessionConfiguration.ephemeral
        value.urlCache = nil
        value.urlCredentialStorage = nil
        value.httpCookieStorage = nil
        value.httpShouldSetCookies = false
        value.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        value.timeoutIntervalForRequest = 20
        value.timeoutIntervalForResource = 20
        value.waitsForConnectivity = false
        return value
    }
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PeelCompanyHTTPResponse, any Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var expectedURL: URL?
    private var status: Int?
    private var bytes = Data()
    private var finished = false

    func start(_ request: URLRequest, protocolClasses: [AnyClass]? = nil,
               continuation: CheckedContinuation<PeelCompanyHTTPResponse, any Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); continuation.resume(throwing: PeelCompanyAccountError.cancelled); return }
        self.continuation = continuation
        expectedURL = request.url
        let configuration = Self.configuration()
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        lock.unlock()
        task.resume()
    }

    func cancel() { finish(.failure(PeelCompanyAccountError.cancelled)) }

    private func finish(_ result: Result<PeelCompanyHTTPResponse, any Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = continuation
        let session = session
        self.continuation = nil
        self.session = nil
        task = nil
        bytes.removeAll(keepingCapacity: false)
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Deny same-origin redirects too. POST bodies and bearer headers never
        // travel to a different endpoint through 301/302/303/307/308 handling.
        completionHandler(nil)
        finish(.failure(PeelCompanyAccountError.redirectRejected))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil) // System TLS validation only.
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        let expectedURL = expectedURL
        let stopped = finished
        lock.unlock()
        guard !stopped, let http = response as? HTTPURLResponse, http.url == expectedURL,
              http.expectedContentLength <= 65_536,
              http.statusCode == 204 || http.mimeType?.lowercased() == "application/json" else {
            completionHandler(.cancel)
            finish(.failure(PeelCompanyAccountError.invalidResponse)); return
        }
        guard !(300...399).contains(http.statusCode) else {
            completionHandler(.cancel)
            finish(.failure(PeelCompanyAccountError.redirectRejected)); return
        }
        lock.lock(); status = http.statusCode; lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard data.count <= 65_536 - bytes.count else {
            lock.unlock(); finish(.failure(PeelCompanyAccountError.invalidResponse)); return
        }
        bytes.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        let status = status
        let data = bytes
        let stopped = finished
        lock.unlock()
        guard !stopped else { return }
        if error != nil { finish(.failure(PeelCompanyAccountError.unavailable)) }
        else if let status { finish(.success(PeelCompanyHTTPResponse(status: status, data: data))) }
        else { finish(.failure(PeelCompanyAccountError.invalidResponse)) }
    }
}

@MainActor
final class PeelCompanyHTTPSAccountAPI: PeelCompanyAccountAPI {
    let configuration: PeelCompanyAccountConfiguration
    private let executor: any PeelCompanyHTTPExecuting
    init(configuration: PeelCompanyAccountConfiguration, executor: (any PeelCompanyHTTPExecuting)? = nil) {
        self.configuration = configuration
        self.executor = executor ?? PeelCompanyEphemeralHTTP()
    }
    private enum Endpoint: String {
        case challenge = "/v1/challenges", signIn = "/v1/apple/sign-in", account = "/v1/account"
        case preferences = "/v1/account/preferences", signOut = "/v1/account/sign-out"
    }
    private struct ErrorBody: Decodable { let error: String }
    private struct SignInBody: Encodable {
        let challenge_id: String, identity_token: String, authorization_code: String
        let email_collection_consent: Bool
        let marketing_consent = false
        let consent_version: String
    }
    private struct PreferenceBody: Encodable {
        let email_collection_consent = false
        let marketing_consent = false
        let consent_version = PeelCompanyAccountConfiguration.consentVersion
    }
    private struct DeleteBody: Encodable { let challenge_id: String; let identity_token: String }

    private func request(_ method: String, _ endpoint: Endpoint, bearer: String? = nil, body: Data? = nil) async throws -> PeelCompanyHTTPResponse {
        let url = configuration.origin.appendingPathComponent(String(endpoint.rawValue.dropFirst()))
        guard url.scheme == "https", url.host == configuration.origin.host, url.path == endpoint.rawValue,
              url.query == nil, url.fragment == nil, (body?.count ?? 0) <= 24_576 else { throw PeelCompanyAccountError.invalidRequest }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 20)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let bearer {
            guard PeelCompanyValidation.bearer(bearer) else { throw PeelCompanyAccountError.unauthorized }
            request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        }
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let response: PeelCompanyHTTPResponse
        do { response = try await executor.execute(request) }
        catch let error as PeelCompanyAccountError { throw error }
        catch { throw Task.isCancelled ? PeelCompanyAccountError.cancelled : .unavailable }
        guard response.data.count <= 65_536 else { throw PeelCompanyAccountError.invalidResponse }
        if (200...299).contains(response.status) { return response }
        if (300...399).contains(response.status) { throw PeelCompanyAccountError.redirectRejected }
        let code = (try? JSONDecoder().decode(ErrorBody.self, from: response.data))?.error
        switch response.status {
        case 401: throw PeelCompanyAccountError.unauthorized
        case 409:
            switch code {
            case "apple_revocation_pending": throw PeelCompanyAccountError.pendingRevocation
            case "account_grant_capacity_reached": throw PeelCompanyAccountError.grantCapacity
            case "fresh_apple_sign_in_required": throw PeelCompanyAccountError.freshAppleProofRequired
            case "verified_email_unavailable": throw PeelCompanyAccountError.verifiedEmailUnavailable
            default: throw PeelCompanyAccountError.invalidResponse
            }
        case 429: throw PeelCompanyAccountError.rateLimited
        case 500...599: throw PeelCompanyAccountError.unavailable
        default: throw PeelCompanyAccountError.invalidRequest
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ response: PeelCompanyHTTPResponse, status: Int = 200) throws -> T {
        guard response.status == status else { throw PeelCompanyAccountError.invalidResponse }
        do { return try JSONDecoder().decode(type, from: response.data) }
        catch { throw PeelCompanyAccountError.invalidResponse }
    }
    func challenge() async throws -> PeelCompanyChallenge {
        let result = try decode(PeelCompanyChallenge.self, await request("POST", .challenge, body: Data("{}".utf8)))
        guard result.isValid else { throw PeelCompanyAccountError.invalidResponse }
        return result
    }
    func signIn(challenge: String, identityToken: String, code: String, collectEmail: Bool, consentVersion: String) async throws -> PeelCompanySignInResponse {
        guard PeelCompanyValidation.opaque(challenge, maximum: 128), PeelCompanyValidation.identityToken(identityToken),
              PeelCompanyValidation.text(code, maximum: 4096), consentVersion == PeelCompanyAccountConfiguration.consentVersion else { throw PeelCompanyAccountError.invalidAuthorization }
        let body = try JSONEncoder().encode(SignInBody(challenge_id: challenge, identity_token: identityToken,
            authorization_code: code, email_collection_consent: collectEmail, consent_version: consentVersion))
        let result = try decode(PeelCompanySignInResponse.self, await request("POST", .signIn, body: body))
        guard result.account.isValid, result.account.email_collection_consent == collectEmail,
              PeelCompanyValidation.bearer(result.session_token), (1...(30 * 86_400)).contains(result.expires_in) else { throw PeelCompanyAccountError.invalidResponse }
        return result
    }
    func account(bearer: String) async throws -> PeelCompanyAccountProfile {
        let result = try decode(PeelCompanyProfileResponse.self, await request("GET", .account, bearer: bearer)).account
        guard result.isValid else { throw PeelCompanyAccountError.invalidResponse }
        return result
    }
    func withdrawEmail(bearer: String) async throws -> PeelCompanyAccountProfile {
        let body = try JSONEncoder().encode(PreferenceBody())
        let result = try decode(PeelCompanyProfileResponse.self, await request("PUT", .preferences, bearer: bearer, body: body)).account
        guard result.isValid, !result.email_collection_consent, result.email == nil else { throw PeelCompanyAccountError.invalidResponse }
        return result
    }
    func signOut(bearer: String) async throws {
        let result = try await request("POST", .signOut, bearer: bearer, body: Data("{}".utf8))
        guard result.status == 204, result.data.isEmpty else { throw PeelCompanyAccountError.invalidResponse }
    }
    func delete(bearer: String?, challenge: String?, identityToken: String?) async throws -> PeelCompanyDeletionOutcome {
        let body: Data
        if let challenge, let identityToken {
            guard PeelCompanyValidation.opaque(challenge, maximum: 128), PeelCompanyValidation.identityToken(identityToken) else { throw PeelCompanyAccountError.invalidAuthorization }
            body = try JSONEncoder().encode(DeleteBody(challenge_id: challenge, identity_token: identityToken))
        } else {
            guard challenge == nil, identityToken == nil, bearer != nil else { throw PeelCompanyAccountError.invalidAuthorization }
            body = Data("{}".utf8)
        }
        let response = try await request("DELETE", .account, bearer: bearer, body: body)
        guard response.status == 200 || response.status == 202 else { throw PeelCompanyAccountError.invalidResponse }
        let flags: PeelCompanyDeletionResponse
        do { flags = try JSONDecoder().decode(PeelCompanyDeletionResponse.self, from: response.data) }
        catch { throw PeelCompanyAccountError.invalidResponse }
        return try flags.outcome(status: response.status)
    }
}
