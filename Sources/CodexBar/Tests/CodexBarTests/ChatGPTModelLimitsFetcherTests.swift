import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
@MainActor
struct ChatGPTModelLimitsFetcherTests {
    private let cookieHeader = "__Secure-next-auth.session-token=session-cookie"
    private let accessToken = "session-access-token"
    private let expectedEmail = "Account@Example.com"

    @Test
    func `fetch uses the three authenticated endpoints and safe init body`() async {
        let cookieHeader = self.cookieHeader
        let accessToken = self.accessToken
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            switch url.path {
            case "/api/auth/session":
                #expect(url.absoluteString == "https://chatgpt.com/api/auth/session")
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Cookie") == cookieHeader)
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                #expect(request.value(forHTTPHeaderField: "Origin") == "https://chatgpt.com")
                #expect(request.value(forHTTPHeaderField: "Referer") == "https://chatgpt.com/")
                return Self.response(
                    for: request,
                    body: "{\"accessToken\":\"\(accessToken)\",\"user\":{\"email\":\"account@example.com\"}}")

            case "/backend-api/models":
                #expect(url.absoluteString ==
                    "https://chatgpt.com/backend-api/models?iim=false&include_icons=false")
                #expect(request.httpMethod == "GET")
                #expect(request.httpBody == nil)
                #expect(request.value(forHTTPHeaderField: "Cookie") == cookieHeader)
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(accessToken)")
                #expect(request.value(forHTTPHeaderField: "Origin") == "https://chatgpt.com")
                #expect(request.value(forHTTPHeaderField: "Referer") == "https://chatgpt.com/")
                return Self.response(
                    for: request,
                    body: """
                    {
                      "models": [
                        {"slug":"fixture-pro","title":"GPT-6 Pro","reasoning_type":"pro"},
                        {"slug":"fixture-gpt56","title":"GPT-5.6 Pro","reasoning_type":"pro"}
                      ]
                    }
                    """)

            case "/backend-api/conversation/init":
                #expect(url.absoluteString == "https://chatgpt.com/backend-api/conversation/init")
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Cookie") == cookieHeader)
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(accessToken)")
                #expect(request.value(forHTTPHeaderField: "Origin") == "https://chatgpt.com")
                #expect(request.value(forHTTPHeaderField: "Referer") == "https://chatgpt.com/")
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
                let body = try #require(request.httpBody)
                let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                #expect(object["conversation_origin"] as? String == "chat")
                let requestedModel = try #require(object["requested_default_model"] as? String)
                #expect(["fixture-pro", "fixture-gpt56"].contains(requestedModel))
                #expect(object["timezone"] as? String == TimeZone.current.identifier)
                #expect((object["timezone_offset_min"] as? NSNumber)?.intValue ==
                    -TimeZone.current.secondsFromGMT() / 60)
                #expect(object["system_hints"] is NSNull)
                #expect(object["conversation_id"] == nil)
                #expect(object["prompts"] == nil)
                #expect(object["messages"] == nil)
                return Self.response(
                    for: request,
                    body: """
                    {
                      "model_limits": [
                        {"model_slug":"\(requestedModel)","resets_after":"2099-01-01T00:00:00Z"}
                      ]
                    }
                    """)

            default:
                Issue.record("Unexpected endpoint: \(url.absoluteString)")
                return Self.response(for: request, statusCode: 500, body: "{}")
            }
        }
        var logs: [String] = []

        let result = await self.fetch(transport: transport) { logs.append($0) }

        let requests = await transport.requests()
        #expect(result?.models.count == 2)
        #expect(requests.count == 4)
        #expect(requests.allSatisfy { $0.timeoutInterval > 0 && $0.timeoutInterval <= 2 })
        let logText = logs.joined(separator: "\n")
        #expect(!logText.contains(self.cookieHeader))
        #expect(!logText.contains(self.accessToken))
        #expect(logText.contains("stage=session status=200"))
        #expect(logText.contains("stage=models status=200"))
        #expect(logText.components(separatedBy: "stage=conversation_init status=200").count - 1 == 2)
    }

    @Test
    func `session identity mismatch stops before model and init requests`() async {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(url.path == "/api/auth/session")
            return Self.response(
                for: request,
                body: #"{"accessToken":"session-access-token","user":{"email":"other@example.com"}}"#)
        }

        let result = await self.fetch(transport: transport)

        #expect(result == nil)
        #expect(await transport.requests().count == 1)
    }

    @Test
    func `empty cookies perform no request`() async {
        let transport = ProviderHTTPTransportStub { _ in
            Issue.record("Empty cookies must not invoke transport")
            throw URLError(.userAuthenticationRequired)
        }

        let result = await self.fetch(cookieHeader: " \n\t", transport: transport)

        #expect(result == nil)
        #expect(await transport.requests().isEmpty)
    }

    @Test
    func `non success status returns nil and logs only stage and status`() async {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(url.path == "/api/auth/session")
            return Self.response(
                for: request,
                statusCode: 401,
                body: #"{"error":"secret response body"}"#)
        }
        var logs: [String] = []

        let result = await self.fetch(transport: transport) { logs.append($0) }

        #expect(result == nil)
        #expect(await transport.requests().count == 1)
        #expect(logs == ["chatgpt limits stage=session status=401"])
        #expect(!logs.joined().contains("secret response body"))
    }

    @Test
    func `missing token or identity never reaches model endpoint`() async {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(url.path == "/api/auth/session")
            return Self.response(
                for: request,
                body: #"{"accessToken":"","user":{"email":"account@example.com"}}"#)
        }

        let result = await self.fetch(transport: transport)

        #expect(result == nil)
        #expect(await transport.requests().count == 1)
    }

    @Test
    func `malformed catalog is contained as an optional parser failure`() async {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            switch url.path {
            case "/api/auth/session":
                return Self.response(
                    for: request,
                    body: #"{"accessToken":"session-access-token","user":{"email":"account@example.com"}}"#)
            case "/backend-api/models":
                return Self.response(for: request, body: "not-json")
            case "/backend-api/conversation/init":
                return Self.response(
                    for: request,
                    body: #"{"model_limits":[]}"#)
            default:
                Issue.record("Unexpected endpoint: \(url.path)")
                return Self.response(for: request, statusCode: 500, body: "{}")
            }
        }
        var logs: [String] = []

        let result = await self.fetch(transport: transport) { logs.append($0) }

        #expect(result == nil)
        #expect(await transport.requests().count == 2)
        #expect(logs.contains("chatgpt limits stage=parser invalid"))
        #expect(!logs.joined().contains("not-json"))
    }

    @Test
    func `malformed model limits metadata stops after the failed init`() async {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            switch url.path {
            case "/api/auth/session":
                return Self.response(
                    for: request,
                    body: #"{"accessToken":"session-access-token","user":{"email":"account@example.com"}}"#)
            case "/backend-api/models":
                return Self.response(
                    for: request,
                    body: #"{"models":[{"slug":"fixture-pro","title":"GPT-6 Pro","reasoning_type":"pro"}]}"#)
            case "/backend-api/conversation/init":
                return Self.response(for: request, body: #"{"model_limits":"not-an-array"}"#)
            default:
                Issue.record("Unexpected endpoint: \(url.path)")
                return Self.response(for: request, statusCode: 500, body: "{}")
            }
        }
        var logs: [String] = []

        let result = await self.fetch(transport: transport) { logs.append($0) }

        #expect(result == nil)
        #expect(await transport.requests().count == 3)
        #expect(logs.contains("chatgpt limits stage=conversation_init invalid"))
        #expect(!logs.joined().contains("not-an-array"))
    }

    @Test
    func `catalog without target models skips conversation init but still parses`() async {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            switch url.path {
            case "/api/auth/session":
                return Self.response(
                    for: request,
                    body: #"{"accessToken":"session-access-token","user":{"email":"account@example.com"}}"#)
            case "/backend-api/models":
                return Self.response(for: request, body: #"{"models":[{"slug":"gpt-4o","title":"GPT-4o"}]}"#)
            default:
                Issue.record("No conversation init should be requested: \(url.path)")
                return Self.response(for: request, statusCode: 500, body: "{}")
            }
        }

        let result = await self.fetch(transport: transport)

        #expect(result?.models.isEmpty == true)
        #expect(await transport.requests().count == 2)
    }

    @Test
    func `cookie header control characters perform no request`() async {
        let transport = ProviderHTTPTransportStub { _ in
            Issue.record("Invalid cookie header must not invoke transport")
            throw URLError(.userAuthenticationRequired)
        }

        let result = await self.fetch(cookieHeader: "session=secret\r\nX-Leak: yes", transport: transport)

        #expect(result == nil)
        #expect(await transport.requests().isEmpty)
    }

    @Test
    func `expired deadline performs no request`() async {
        let transport = ProviderHTTPTransportStub { _ in
            Issue.record("Expired deadline must not invoke transport")
            throw URLError(.timedOut)
        }

        let result = await self.fetch(
            transport: transport,
            deadline: Date(timeIntervalSinceNow: -1))

        #expect(result == nil)
        #expect(await transport.requests().isEmpty)
    }

    /// Stubbed happy paths must not expire while unrelated main-actor suites scan the source tree.
    private func fetch(
        cookieHeader: String? = nil,
        transport: ProviderHTTPTransportStub,
        deadline: Date = .distantFuture,
        logger: @escaping (String) -> Void = { _ in }) async -> ChatGPTModelLimitsSnapshot?
    {
        await CodexAuthenticatedHTTPTransport.$overrideForTesting.withValue(transport) {
            await ChatGPTModelLimitsFetcher.fetch(
                cookieHeader: cookieHeader ?? self.cookieHeader,
                expectedEmail: self.expectedEmail,
                deadline: deadline,
                logger: logger)
        }
    }

    private nonisolated static func response(
        for request: URLRequest,
        statusCode: Int = 200,
        body: String) -> (Data, URLResponse)
    {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        return (Data(body.utf8), response)
    }
}
