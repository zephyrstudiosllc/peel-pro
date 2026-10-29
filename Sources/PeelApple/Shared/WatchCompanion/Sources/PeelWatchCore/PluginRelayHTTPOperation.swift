#if !os(watchOS)
import Foundation

struct PluginRelayHTTPResponse: Sendable { let status: Int; let body: Data }
protocol PluginRelayHTTPSubmissionAdmission: Sendable {
    func submit(_ body: @Sendable () -> Void) throws
}

/// One request/session, incremental cap and monotonic absolute deadline. Trusted
/// test configuration injection is internal; production uses ephemeral settings.
final class PluginRelayHTTPOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PluginRelayHTTPResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var timer: DispatchSourceTimer?
    private var validateAuthority: (@Sendable () throws -> Void)?
    private var bytes = Data()
    private var status: Int?
    private var terminal = false
    private var deadline: DispatchTime = .now()
    static let maximumBytes = 256 * 1_024

    func perform(_ request: URLRequest, configuration: URLSessionConfiguration, timeout: TimeInterval,
                 submission: (any PluginRelayHTTPSubmissionAdmission)? = nil,
                 validateAuthority: @escaping @Sendable () throws -> Void) async throws -> PluginRelayHTTPResponse {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                start(request, configuration: configuration, timeout: timeout, submission: submission,
                      validator: validateAuthority, continuation: continuation)
            }
        }, onCancel: { self.cancel() })
    }
    private func start(_ input: URLRequest, configuration: URLSessionConfiguration, timeout: TimeInterval,
                       submission: (any PluginRelayHTTPSubmissionAdmission)?,
                       validator: @escaping @Sendable () throws -> Void,
                       continuation: CheckedContinuation<PluginRelayHTTPResponse, Error>) {
        lock.lock()
        guard !terminal else { lock.unlock(); continuation.resume(throwing: PluginRelayHTTPError.cancelled); return }
        self.continuation = continuation; validateAuthority = validator
        deadline = .now() + timeout
        var request = input; request.timeoutInterval = timeout; request.cachePolicy = .reloadIgnoringLocalCacheData
        let config = configuration.copy() as! URLSessionConfiguration
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCache = nil; config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout; config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request); self.task = task
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        self.timer = timer
        timer.schedule(deadline: .now(), repeating: .milliseconds(25))
        timer.setEventHandler { [weak self] in self?.checkProgress() }
        timer.resume()
        lock.unlock()
        do {
            try validator()
            if let submission { try submission.submit { task.resume() } }
            else { task.resume() } // Identity/cleanup calls have no paid effect.
        } catch let paid as PluginRelayProError { finish(.failure(paid)) }
        catch { finish(.failure(PluginRelayHTTPError.authorityChanged)) }
    }
    func cancel() { finish(.failure(PluginRelayHTTPError.cancelled)) }

    private func checkProgress() {
        lock.lock(); let stopped = terminal, deadline = deadline, validate = validateAuthority; lock.unlock()
        guard !stopped else { return }
        if DispatchTime.now() >= deadline { finish(.failure(PluginRelayHTTPError.timeout)); return }
        do { try validate?() }
        catch let paid as PluginRelayProError { finish(.failure(paid)) }
        catch { finish(.failure(PluginRelayHTTPError.authorityChanged)) }
    }
    private func finish(_ result: Result<PluginRelayHTTPResponse, Error>) {
        lock.lock()
        guard !terminal else { lock.unlock(); return }
        terminal = true
        let continuation = self.continuation; self.continuation = nil
        let session = self.session; self.session = nil
        let task = self.task; self.task = nil
        let timer = self.timer; self.timer = nil
        validateAuthority = nil; bytes.removeAll(keepingCapacity: false)
        lock.unlock()
        timer?.setEventHandler {}; timer?.cancel()
        task?.cancel(); session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // No target request is allowed, including same-origin redirects.
        completionHandler(nil); finish(.failure(PluginRelayHTTPError.redirectRejected))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        checkProgress()
        guard let response = response as? HTTPURLResponse, response.url == dataTask.originalRequest?.url,
              response.mimeType?.lowercased() == "application/json" else {
            completionHandler(.cancel); finish(.failure(PluginRelayHTTPError.invalidResponse)); return
        }
        guard !(300..<400).contains(response.statusCode) else {
            completionHandler(.cancel); finish(.failure(PluginRelayHTTPError.redirectRejected)); return
        }
        guard response.expectedContentLength <= Int64(Self.maximumBytes) else {
            completionHandler(.cancel); finish(.failure(PluginRelayHTTPError.responseTooLarge)); return
        }
        lock.lock(); let stopped = terminal
        if !stopped { status = response.statusCode }; lock.unlock()
        completionHandler(stopped ? .cancel : .allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        checkProgress()
        lock.lock()
        let tooLarge = data.count > Self.maximumBytes - bytes.count
        if !terminal && !tooLarge { bytes.append(data) }; lock.unlock()
        if tooLarge { finish(.failure(PluginRelayHTTPError.responseTooLarge)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        checkProgress()
        if let error {
            let code = (error as NSError).code
            finish(.failure(code == NSURLErrorTimedOut ? PluginRelayHTTPError.timeout
                            : code == NSURLErrorCancelled ? PluginRelayHTTPError.cancelled : PluginRelayHTTPError.networkFailure))
        } else {
            lock.lock(); let body = bytes, status = status; lock.unlock()
            guard let status, !body.isEmpty else { finish(.failure(PluginRelayHTTPError.invalidResponse)); return }
            finish(.success(PluginRelayHTTPResponse(status: status, body: body)))
        }
    }
}
#endif
