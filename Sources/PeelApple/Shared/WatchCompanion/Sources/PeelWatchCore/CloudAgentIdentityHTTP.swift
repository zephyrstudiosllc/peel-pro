#if !os(watchOS)
import Foundation

/// Fixed provider routes, ephemeral per-request session, no redirects, cookies,
/// URL cache, challenge credentials, retries or unbounded response buffering.
/// A configuration injection exists for isolated URLProtocol fixtures only.
public final class CloudAgentIdentityHTTP: @unchecked Sendable {
    static let discoveryURL = URL(string: "https://auth.openai.com/.well-known/openid-configuration")!
    static let jwksURL = URL(string: "https://auth.openai.com/.well-known/jwks.json")!
    static let xMeURL = URL(string: "https://api.x.com/2/users/me")!
    private let configuration: URLSessionConfiguration
    public init() { configuration = .ephemeral }
    init(configuration: URLSessionConfiguration) { self.configuration = configuration.copy() as! URLSessionConfiguration }

    func get(_ url: URL) async throws -> Data { try await perform(URLRequest(url: url)) }

    func perform(_ input: URLRequest) async throws -> Data {
        let tokenURLs = ["https://auth.openai.com/api/accounts/oauth/token", "https://api.x.com/2/oauth2/token"]
        guard let url = input.url, let raw = input.url?.absoluteString,
              tokenURLs.contains(raw) || [Self.discoveryURL, Self.jwksURL, Self.xMeURL].contains(url),
              input.httpMethod == (tokenURLs.contains(raw) ? "POST" : "GET"),
              (input.httpBody?.count ?? 0) <= 32_768,
              input.value(forHTTPHeaderField: "Authorization") == nil || url == Self.xMeURL else {
            throw CloudAgentIdentityError.invalidConfiguration
        }
        var request = input
        request.timeoutInterval = 20; request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let config = configuration.copy() as! URLSessionConfiguration
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCache = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let operation = IdentityHTTPTask()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                operation.start(request, configuration: config, continuation: continuation)
            }
        }, onCancel: { operation.cancel() })
    }
}

private final class IdentityHTTPTask: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var data = Data()
    private var terminal = false
    private let maximumBytes = 131_072

    func start(_ request: URLRequest, configuration: URLSessionConfiguration,
               continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        guard !terminal else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        lock.unlock()
        task.resume()
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !terminal else { lock.unlock(); return }
        terminal = true
        let continuation = self.continuation; self.continuation = nil
        let session = self.session; self.session = nil
        let task = self.task; self.task = nil
        data.removeAll(keepingCapacity: false)
        lock.unlock()
        task?.cancel(); session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(CloudAgentIdentityError.invalidResponse))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Preserve platform TLS validation; never supply app/account credentials.
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url == dataTask.originalRequest?.url,
              response.expectedContentLength < 0 || response.expectedContentLength <= Int64(maximumBytes),
              response.mimeType?.lowercased() == "application/json" else {
            completionHandler(.cancel); finish(.failure(CloudAgentIdentityError.invalidResponse)); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive received: Data) {
        lock.lock()
        let tooLarge = received.count > maximumBytes - data.count
        if !terminal && !tooLarge { data.append(received) }
        lock.unlock()
        if tooLarge { finish(.failure(CloudAgentIdentityError.invalidResponse)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let isCancelled = (error as NSError).code == NSURLErrorCancelled
            finish(.failure(isCancelled ? CancellationError() : CloudAgentIdentityError.requestFailed))
        } else {
            lock.lock(); let result = data; lock.unlock()
            finish(result.isEmpty ? .failure(CloudAgentIdentityError.invalidResponse) : .success(result))
        }
    }
}
#endif
