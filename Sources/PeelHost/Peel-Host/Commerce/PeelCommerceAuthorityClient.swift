import Foundation

nonisolated protocol PeelCommerceAuthorityVerifying: Sendable {
    func verify(_ proof: PeelProEntitlementProof) async throws -> PeelCommerceAuthorityResponse
}

nonisolated enum PeelCommerceAuthorityError: Error {
    case notConfigured, invalidRequest, unavailable, invalidResponse
}

nonisolated private struct PeelCommerceAuthorityRequest: Encodable, Sendable {
    let schema = 1
    let requestId: String
    let nonce: String
    let pairingId: String
    let sessionId: String
    let signedTransactions: [String]
}

/// One ephemeral session per request prevents credential, cookie, cache and
/// redirect state from crossing requests. Only the operator's configured origin
/// is used; no peer-supplied URL or verdict is accepted.
nonisolated struct PeelCommerceAuthorityClient: PeelCommerceAuthorityVerifying {
    let endpoint: URL?

    init(origin: String?) {
        endpoint = Self.endpoint(origin: origin)
    }

    static func endpoint(origin: String?) -> URL? {
        guard let origin, origin.utf8.count <= 2048, origin.hasPrefix("https://"),
              !origin.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let parts = URLComponents(string: origin), parts.scheme == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.port == nil || parts.port == 443,
              var result = parts.url else { return nil }
        result = result.appendingPathComponent("v1/entitlements/verify")
        return result
    }

    func verify(_ proof: PeelProEntitlementProof) async throws -> PeelCommerceAuthorityResponse {
        guard let endpoint else { throw PeelCommerceAuthorityError.notConfigured }
        guard proof.signedTransactions.count <= 4,
              proof.signedTransactions.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 32_768 }),
              PeelHostProAdmissionState.isCanonicalNonce(proof.nonce) else {
            throw PeelCommerceAuthorityError.invalidRequest
        }
        let body = try JSONEncoder().encode(PeelCommerceAuthorityRequest(requestId: proof.requestId, nonce: proof.nonce,
            pairingId: proof.pairingId, sessionId: proof.sessionId, signedTransactions: proof.signedTransactions))
        guard body.count <= 140_000 else { throw PeelCommerceAuthorityError.invalidRequest }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.httpBody = body
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let exchange = PeelCommerceAuthorityExchange(endpoint: endpoint)
        let data = try await exchange.perform(request)
        try Task.checkCancellation()
        return try PeelCommerceAuthorityResponse.decode(data)
    }
}

/// URLSession's accumulated-data convenience API cannot bound a response while
/// it arrives. This delegate enforces the bound before retaining each chunk.
nonisolated private final class PeelCommerceAuthorityExchange: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let endpoint: URL
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var body = Data()
    private var completed = false
    private var cancelled = false
    private let maximumBytes = 140_000

    init(endpoint: URL) { self.endpoint = endpoint }

    func perform(_ request: URLRequest) async throws -> Data {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.urlCache = nil
                configuration.httpCookieStorage = nil
                configuration.httpShouldSetCookies = false
                configuration.urlCredentialStorage = nil
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.timeoutIntervalForRequest = 10
                configuration.timeoutIntervalForResource = 12
                configuration.httpMaximumConnectionsPerHost = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        }, onCancel: { self.cancel() })
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        // Cancellation may race creation of the continuation. The cancelled bit
        // makes perform reject if it has not installed the continuation yet.
        guard let continuation else { lock.unlock(); return }
        completed = true
        self.continuation = nil
        let session = self.session
        self.session = nil
        task = nil
        body.removeAll(keepingCapacity: false)
        lock.unlock()
        session?.invalidateAndCancel()
        continuation.resume(with: result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(PeelCommerceAuthorityError.invalidResponse))
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handleAuthentication(challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handleAuthentication(challenge, completionHandler: completionHandler)
    }

    private func handleAuthentication(_ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.url == endpoint,
              response.statusCode == 200, response.mimeType?.lowercased() == "application/json",
              response.expectedContentLength <= Int64(maximumBytes) else {
            completionHandler(.cancel)
            finish(.failure(PeelCommerceAuthorityError.unavailable))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        guard data.count <= maximumBytes - body.count else {
            lock.unlock()
            finish(.failure(PeelCommerceAuthorityError.invalidResponse))
            return
        }
        body.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        lock.lock()
        let data = body
        lock.unlock()
        finish(.success(data))
    }
}
