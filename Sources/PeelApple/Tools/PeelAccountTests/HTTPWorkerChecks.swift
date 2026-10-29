import Foundation
import Darwin

nonisolated final class WorkerFixtureState: @unchecked Sendable {
    static let shared = WorkerFixtureState()
    private let lock = NSLock()
    private var loads = 0
    private var stops = 0
    func started() { lock.lock(); loads += 1; lock.unlock() }
    func stopped() { lock.lock(); stops += 1; lock.unlock() }
    func counts() -> (Int, Int) { lock.lock(); defer { lock.unlock() }; return (loads, stops) }
}

/// Custom nonnetwork scheme. Even a failed interception cannot resolve/connect
/// to an HTTP server. The production URLSession worker/delegates remain exact.
nonisolated final class WorkerFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.scheme == "peel-review-fixture" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        WorkerFixtureState.shared.started()
        let url = request.url!
        if url.path == "/hold" { return }
        if url.path == "/redirect307" || url.path == "/redirect308" {
            let response = HTTPURLResponse(url: url, statusCode: url.path == "/redirect307" ? 307 : 308,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: "peel-review-fixture://redirected/destination")!), redirectResponse: response)
            return
        }
        let actualURL = url.path == "/wrong-url" ? URL(string: "peel-review-fixture://wrong/response")! : url
        var headers = ["Content-Type": url.path == "/wrong-mime" ? "text/html" : "application/json"]
        if url.path == "/declared-too-large" { headers["Content-Length"] = "65537" }
        let response = HTTPURLResponse(url: actualURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if url.path == "/stream-too-large" {
            client?.urlProtocol(self, didLoad: Data(repeating: 0x20, count: 32768))
            client?.urlProtocol(self, didLoad: Data(repeating: 0x20, count: 32769))
        } else if url.path == "/exact" {
            client?.urlProtocol(self, didLoad: Data(repeating: 0x20, count: 65536))
        } else { client?.urlProtocol(self, didLoad: Data("{}".utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { WorkerFixtureState.shared.stopped() }
}

@main
@MainActor
enum HTTPWorkerChecks {
    static func main() async {
        var results: [[String: Any]] = []
        func record(_ name: String, _ passed: Bool, _ detail: String = "") {
            results.append(["name": name, "passed": passed, "detail": detail])
        }
        func request(_ path: String) -> URLRequest {
            URLRequest(url: URL(string: "peel-review-fixture://scope" + path)!)
        }
        func waitForStart(after count: Int) async -> Bool {
            let deadline = Date().addingTimeInterval(2)
            while WorkerFixtureState.shared.counts().0 <= count && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(1))
            }
            return WorkerFixtureState.shared.counts().0 > count
        }
        let config = PeelCompanyEphemeralHTTP.configuration()
        record("actual_worker_factory_disables_cache_cookie_credential_storage",
            config.urlCache == nil && config.urlCredentialStorage == nil && config.httpCookieStorage == nil && !config.httpShouldSetCookies)
        record("actual_worker_factory_bounds_timeout_and_connectivity",
            config.timeoutIntervalForRequest == 20 && config.timeoutIntervalForResource == 20 && !config.waitsForConnectivity)
        let executor = PeelCompanyEphemeralHTTP(protocolClasses: [WorkerFixtureProtocol.self])
        for (path, expectedBytes) in [("/success", 2), ("/exact", 65536)] {
            do {
                let response = try await executor.execute(request(path))
                record("actual_worker_accepts" + path, response.status == 200 && response.data.count == expectedBytes)
            } catch { record("actual_worker_accepts" + path, false, String(describing: error)) }
        }
        for path in ["/declared-too-large", "/stream-too-large", "/wrong-url", "/wrong-mime"] {
            do {
                _ = try await executor.execute(request(path))
                record("actual_worker_rejects" + path, false, "unexpected success")
            } catch {
                record("actual_worker_rejects" + path, (error as? PeelCompanyAccountError) == .invalidResponse,
                    String(describing: error))
            }
        }
        for path in ["/redirect307", "/redirect308"] {
            let before = WorkerFixtureState.shared.counts().0
            do {
                _ = try await executor.execute(request(path))
                record("actual_redirect_delegate_rejects" + path, false, "unexpected success")
            } catch {
                record("actual_redirect_delegate_rejects" + path,
                    (error as? PeelCompanyAccountError) == .redirectRejected && WorkerFixtureState.shared.counts().0 == before + 1,
                    String(describing: error))
            }
        }
        do {
            let before = WorkerFixtureState.shared.counts().0
            let task = Task { try await executor.execute(request("/hold")) }
            task.cancel()
            do { _ = try await task.value; record("cancel_before_start", false) }
            catch { record("cancel_before_start", (error as? PeelCompanyAccountError) == .cancelled && WorkerFixtureState.shared.counts().0 == before) }
        }
        do {
            let before = WorkerFixtureState.shared.counts().0
            let task = Task { try await executor.execute(request("/hold")) }
            let started = await waitForStart(after: before)
            task.cancel()
            do { _ = try await task.value; record("cancel_during_actual_protocol_request", false) }
            catch { record("cancel_during_actual_protocol_request", started && (error as? PeelCompanyAccountError) == .cancelled) }
        }
        do {
            let before = WorkerFixtureState.shared.counts().0
            let worker = PeelCompanyHTTPWorker()
            let task = Task {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PeelCompanyHTTPResponse, any Error>) in
                    worker.start(request("/hold"), protocolClasses: [WorkerFixtureProtocol.self], continuation: continuation)
                }
            }
            let started = await waitForStart(after: before)
            worker.cancel(); worker.cancel()
            do { _ = try await task.value; record("worker_finishes_once_under_repeated_cancel", false) }
            catch { record("worker_finishes_once_under_repeated_cancel", started && (error as? PeelCompanyAccountError) == .cancelled) }
        }
        let counts = WorkerFixtureState.shared.counts()
        let data = try! JSONSerialization.data(withJSONObject: ["scope": "Actual production URLSession worker/delegates with synthetic custom NONNETWORK URLProtocol only; no sockets/credentials/UI", "results": results, "protocol_starts": counts.0, "protocol_stops": counts.1], options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        exit(results.allSatisfy { ($0["passed"] as? Bool) == true } ? 0 : 1)
    }
}
