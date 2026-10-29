import Foundation

/// One short-lived ephemeral request. Redirects are refused before forwarding
/// Authorization, cookies/cache/credential storage are disabled, and incoming
/// bytes are capped while streaming rather than after an unbounded download.
final class CloudAgentHTTPOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let configuration: URLSessionConfiguration
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var data = Data()
    private var terminalError: CloudAgentError?
    private var finished = false
    static let maximumBytes = 256 * 1_024

    init(configuration: URLSessionConfiguration) { self.configuration = configuration }

    func run(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let error = terminalError {
                    lock.unlock(); continuation.resume(throwing: error); return
                }
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.dataTask(with: request); self.task = task
                lock.unlock(); task.resume()
            }
        }, onCancel: { self.cancel() })
    }

    func cancel() { finish(.failure(CloudAgentError.cancelled)) }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(CloudAgentError.invalidResponse))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, let url = http.url,
              url.scheme == "https", url.host == "slack.com", url.port == nil,
              url.path.hasPrefix("/api/"), response.expectedContentLength <= Int64(Self.maximumBytes) else {
            completionHandler(.cancel)
            finish(.failure(response.expectedContentLength > Int64(Self.maximumBytes)
                            ? CloudAgentError.responseTooLarge : CloudAgentError.invalidResponse))
            return
        }
        lock.lock(); self.response = http; lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        if self.data.count + data.count > Self.maximumBytes {
            lock.unlock(); finish(.failure(CloudAgentError.responseTooLarge)); return
        }
        self.data.append(data); lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let response = self.response; let data = self.data; lock.unlock()
        if error != nil { finish(.failure(CloudAgentError.networkFailure)) }
        else if let response { finish(.success((data, response))) }
        else { finish(.failure(CloudAgentError.invalidResponse)) }
    }

    private func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        if case .failure(let error) = result { terminalError = error as? CloudAgentError ?? .networkFailure }
        let continuation = self.continuation; self.continuation = nil
        let session = self.session; self.session = nil; self.task = nil
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
}
