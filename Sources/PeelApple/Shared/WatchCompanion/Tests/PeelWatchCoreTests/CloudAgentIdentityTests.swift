import Foundation
import XCTest
import CryptoKit
import Security
@testable import PeelWatchCore

/// Entirely synthetic keys, codes and profiles. URLProtocol handles EVERY URL;
/// no fixture can fall back to a provider or use a real app/account registration.
final class CloudAgentIdentityTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)
    private let clientID = "oaiapp_unit_test_client"
    private let nonce = "unit-test-oidc-nonce"
    private let redirect = URL(string: "com.peel.unit.oauth://signin/callback")!

    private var discoveryData: Data {
        json(["issuer": "https://auth.openai.com", "authorization_endpoint": "https://auth.openai.com/api/accounts/authorize",
              "token_endpoint": "https://auth.openai.com/api/accounts/oauth/token", "jwks_uri": "https://auth.openai.com/.well-known/jwks.json",
              "id_token_signing_alg_values_supported": ["RS256", "ES256"]])
    }
    private var claims: [String: Any] {
        ["iss": "https://auth.openai.com", "aud": clientID, "sub": "unit-test-subject",
         "exp": instant.timeIntervalSince1970 + 600, "iat": instant.timeIntervalSince1970, "nonce": nonce]
    }
    private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    private func b64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private func registration(_ provider: CloudAgentProvider = .dot) throws -> CloudAgentIdentityConfiguration {
        try CloudAgentIdentityConfiguration(provider: provider, values: values(provider), bundleID: "com.peel.unit",
                                             registeredURLSchemes: ["com.peel.unit.oauth"])
    }
    private func values(_ provider: CloudAgentProvider = .dot) -> [String: String] {
        ["ClientID": provider == .dot ? clientID : "unit-test-x-native-client", "RedirectURI": redirect.absoluteString,
         "BundleID": "com.peel.unit", "ClientType": "public-native", "TokenEndpointAuthMethod": "none",
         "ApprovalReference": "unit-test-only-registration"]
    }
    private func jwt(_ key: P256.Signing.PrivateKey, claims: [String: Any]? = nil,
                     header: [String: Any]? = nil) throws -> String {
        let unsigned = b64(json(header ?? ["alg": "ES256", "kid": "unit-key"])) + "." + b64(json(claims ?? self.claims))
        return unsigned + "." + b64(try key.signature(for: Data(unsigned.utf8)).rawRepresentation)
    }
    private func jwks(_ key: P256.Signing.PrivateKey, extra: [String: Any] = [:]) -> Data {
        let bytes = key.publicKey.x963Representation
        var jwk: [String: Any] = ["kty": "EC", "kid": "unit-key", "alg": "ES256", "use": "sig", "key_ops": ["verify"],
                                  "crv": "P-256", "x": b64(bytes.subdata(in: 1..<33)), "y": b64(bytes.subdata(in: 33..<65))]
        extra.forEach { jwk[$0.key] = $0.value }
        return json(["keys": [jwk]])
    }
    private func verify(_ token: String, keys: Data, discovery: Data? = nil) throws -> CloudAgentVerifiedIdentity {
        try CloudAgentIDTokenVerifier().verify(token, jwks: keys,
            discovery: JSONDecoder().decode(CloudAgentOIDCDiscovery.self, from: discovery ?? discoveryData),
            clientID: clientID, nonce: nonce, now: instant)
    }

    func testConfigurationRequiresOwnPublicRegistrationExactBundleAndInstalledCallback() throws {
        XCTAssertEqual(try registration().callback, .customScheme("com.peel.unit.oauth"))
        XCTAssertThrowsError(try CloudAgentIdentityConfiguration(provider: .dot, values: [:], bundleID: "com.peel.unit", registeredURLSchemes: []))
        for changed in [["BundleID": "another.app"], ["ClientType": "confidential"], ["TokenEndpointAuthMethod": "client_secret_basic"],
                        ["ClientID": "dynamic_agent_client"], ["ClientID": "oaiapp_example"], ["ApprovalReference": "TODO-registration"],
                        ["ClientSecret": "not-permitted"]] {
            var invalid = values(); changed.forEach { invalid[$0.key] = $0.value }
            XCTAssertThrowsError(try CloudAgentIdentityConfiguration(provider: .dot, values: invalid, bundleID: "com.peel.unit", registeredURLSchemes: ["com.peel.unit.oauth"]))
        }
        XCTAssertThrowsError(try CloudAgentIdentityConfiguration(provider: .dot, values: values(), bundleID: "com.peel.unit", registeredURLSchemes: ["another.scheme"]))
    }

    func testHTTPSConfigurationDerivesExactMatcherFromOwnApprovedRegistration() throws {
        for provider in [CloudAgentProvider.dot, .grokBot] {
            var configuration = values(provider)
            configuration["RedirectURI"] = "https://auth.unit.invalid/oauth/callback"
            let value = try CloudAgentIdentityConfiguration(provider: provider, values: configuration,
                bundleID: "com.peel.unit", registeredURLSchemes: [])
            XCTAssertEqual(value.callback, .https(host: "auth.unit.invalid", path: "/oauth/callback"))
            XCTAssertEqual(value.registration.redirectURI.absoluteString, configuration["RedirectURI"])
            XCTAssertEqual(value.registration.provider, provider)
            XCTAssertEqual(value.registration.clientID, configuration["ClientID"])
            XCTAssertNotEqual(value.storageNamespace, try registration(provider).storageNamespace)
        }
    }

    func testHTTPSDoesNotRelaxRegistrationApprovalBundleOrClientPolicy() throws {
        for changed in [["ApprovalReference": "TODO-registration"], ["BundleID": "another.app"],
                        ["ClientType": "confidential"], ["TokenEndpointAuthMethod": "client_secret_basic"],
                        ["ClientID": "oaiapp_example"], ["ClientSecret": "not-permitted"]] {
            var configuration = values()
            configuration["RedirectURI"] = "https://auth.unit.invalid/oauth/callback"
            changed.forEach { configuration[$0.key] = $0.value }
            XCTAssertThrowsError(try CloudAgentIdentityConfiguration(provider: .dot, values: configuration,
                bundleID: "com.peel.unit", registeredURLSchemes: []))
        }
    }

    func testHTTPSConfigurationRejectsUnrepresentableOrAmbiguousMatchers() throws {
        for redirect in ["http://auth.unit.invalid/oauth/callback", "https://auth.unit.invalid:443/oauth/callback",
                         "https://auth.unit.invalid:8443/oauth/callback", "https://Auth.unit.invalid/oauth/callback",
                         "https://*.unit.invalid/oauth/callback", "https://auth.unit.invalid./oauth/callback",
                         "https://auth..unit.invalid/oauth/callback", "https://%61uth.unit.invalid/oauth/callback", "https://auth.unit.invalid",
                         "https://user@auth.unit.invalid/oauth/callback", "https://auth.unit.invalid/oauth/%63allback",
                         "https://auth.unit.invalid/oauth/callback?route=other", "https://auth.unit.invalid/oauth/callback#other"] {
            var configuration = values(); configuration["RedirectURI"] = redirect
            XCTAssertThrowsError(try CloudAgentIdentityConfiguration(provider: .dot, values: configuration,
                bundleID: "com.peel.unit", registeredURLSchemes: []), redirect) { error in
                XCTAssertEqual(error as? CloudAgentIdentityError, .unsupportedCallback, redirect)
            }
        }
    }

    func testES256AuthenticatesBeforeClaimsAndRetainsOnlyMinimumMapping() throws {
        let key = P256.Signing.PrivateKey()
        let identity = try verify(jwt(key), keys: jwks(key))
        XCTAssertEqual(identity.subject, "unit-test-subject")
        XCTAssertTrue(identity.isCurrent(for: try registration(), now: instant))
        let encoded = try JSONEncoder().encode(identity)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        for forbidden in ["id_token", "access_token", "refresh_token", "email", "picture", "nonce", "unit-test-oidc-nonce"] {
            XCTAssertFalse(text.contains(forbidden))
        }
        let binding = try identity.binding()
        XCTAssertNotEqual(binding.accountID, identity.subject)
        let status = CloudAgentConnectionStatus(provider: .dot, identity: .signedIn(binding), conversationCapability: .notEstablished)
        XCTAssertFalse(status.canSend)
        XCTAssertFalse(identity.isCurrent(for: try registration(.grokBot), now: instant))
        XCTAssertFalse(identity.isCurrent(for: try registration(), now: instant.addingTimeInterval(600)))
    }

    func testTamperedSignatureWrongKeyAndAlgorithmConfusionFail() throws {
        let key = P256.Signing.PrivateKey(); let token = try jwt(key)
        let parts = token.split(separator: ".").map(String.init)
        let tampered = parts[0] + "." + b64(json(["sub": "attacker"])) + "." + parts[2]
        XCTAssertThrowsError(try verify(tampered, keys: jwks(key)))
        XCTAssertThrowsError(try verify(token, keys: jwks(P256.Signing.PrivateKey())))
        for algorithm in ["none", "HS256", "ES384", "RS256"] {
            XCTAssertThrowsError(try verify(jwt(key, header: ["alg": algorithm, "kid": "unit-key"]), keys: jwks(key)))
        }
        for extra in [["jku": "https://attacker.invalid/keys"], ["x5u": "https://attacker.invalid/cert"], ["crit": ["b64"]], ["b64": true]] as [[String: Any]] {
            var header: [String: Any] = ["alg": "ES256", "kid": "unit-key"]; extra.forEach { header[$0.key] = $0.value }
            XCTAssertThrowsError(try verify(jwt(key, header: header), keys: jwks(key)))
        }
        XCTAssertThrowsError(try verify(token, keys: jwks(key, extra: ["use": "enc"])))
        XCTAssertThrowsError(try verify(token, keys: jwks(key, extra: ["key_ops": ["sign"]])))
        XCTAssertThrowsError(try verify(token, keys: jwks(key, extra: ["alg": "RS256"])))
        let duplicate = try JSONSerialization.jsonObject(with: jwks(key)) as! [String: [[String: Any]]]
        XCTAssertThrowsError(try verify(token, keys: json(["keys": duplicate["keys"]! + duplicate["keys"]!])))
    }

    func testIssuerAudienceExpiryNonceAndRequiredClaimsAreVerified() throws {
        let key = P256.Signing.PrivateKey()
        let changes: [[String: Any]] = [["iss": "https://auth.openai.com/"], ["aud": "other-client"], ["nonce": "other-nonce"],
            ["exp": instant.timeIntervalSince1970], ["iat": instant.timeIntervalSince1970 + 6],
            ["nbf": instant.timeIntervalSince1970 + 6], ["sub": ""], ["azp": "other-client"],
            ["aud": [clientID, "another-client"]]]
        for change in changes {
            var invalid = claims; change.forEach { invalid[$0.key] = $0.value }
            XCTAssertThrowsError(try verify(jwt(key, claims: invalid), keys: jwks(key)))
        }
        for required in ["iss", "aud", "sub", "exp", "iat", "nonce"] {
            var invalid = claims; invalid[required] = nil
            XCTAssertThrowsError(try verify(jwt(key, claims: invalid), keys: jwks(key)))
        }
        var multi = claims; multi["aud"] = [clientID, "another-client"]; multi["azp"] = clientID
        _ = try verify(jwt(key, claims: multi), keys: jwks(key))
        var wrongDiscovery = try JSONSerialization.jsonObject(with: discoveryData) as! [String: Any]
        wrongDiscovery["jwks_uri"] = "https://attacker.invalid/keys"
        XCTAssertThrowsError(try verify(jwt(key), keys: jwks(key), discovery: json(wrongDiscovery)))
        wrongDiscovery["jwks_uri"] = "https://auth.openai.com/.well-known/jwks.json"
        wrongDiscovery["id_token_signing_alg_values_supported"] = ["RS256"]
        XCTAssertThrowsError(try verify(jwt(key), keys: jwks(key), discovery: json(wrongDiscovery)))
    }

    func testRS256UsesRealPlatformSignatureAndRejectsChangedSignature() throws {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        let key = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        let der = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        var cursor = 0
        func field(_ tag: UInt8, data: Data, cursor: inout Int) throws -> Data {
            guard cursor + 2 <= data.count, data[cursor] == tag else { throw CloudAgentIdentityError.invalidIdentity }
            cursor += 1; var length = Int(data[cursor]); cursor += 1
            if length >= 128 {
                let count = length & 127; guard count <= 2, cursor + count <= data.count else { throw CloudAgentIdentityError.invalidIdentity }
                length = 0; for _ in 0..<count { length = (length << 8) | Int(data[cursor]); cursor += 1 }
            }
            guard cursor + length <= data.count else { throw CloudAgentIdentityError.invalidIdentity }
            let result = data.subdata(in: cursor..<(cursor + length)); cursor += length; return result
        }
        let sequence = try field(0x30, data: der, cursor: &cursor); var inner = 0
        var modulus = try field(0x02, data: sequence, cursor: &inner)
        if modulus.first == 0 { modulus.removeFirst() }
        let exponent = try field(0x02, data: sequence, cursor: &inner)
        let keys = json(["keys": [["kid": "rsa-unit-key", "kty": "RSA", "alg": "RS256", "n": b64(modulus), "e": b64(exponent)]]])
        let unsigned = b64(json(["alg": "RS256", "kid": "rsa-unit-key"])) + "." + b64(json(claims))
        let signature = try XCTUnwrap(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(unsigned.utf8) as CFData, nil)) as Data
        _ = try verify(unsigned + "." + b64(signature), keys: keys)
        var changed = signature; changed[0] ^= 1
        XCTAssertThrowsError(try verify(unsigned + "." + b64(changed), keys: keys))
    }

    private func grant(_ provider: CloudAgentProvider) async throws -> CloudAgentOAuthCodeGrant {
        let coordinator = CloudAgentOAuthCoordinator()
        let pending = try await coordinator.begin(provider: provider, registeredRedirectURI: redirect)
        var callback = URLComponents(url: redirect, resolvingAgainstBaseURL: false)!
        callback.queryItems = [URLQueryItem(name: "code", value: "synthetic-once-code"), URLQueryItem(name: "state", value: pending.state)]
        return try await coordinator.consumeCallback(callback.url!, transactionID: pending.transactionID)
    }

    func testSIWCExchangeDoesNotRequireAccessTokenAndChecksOriginalNonce() async throws {
        let key = P256.Signing.PrivateKey(); let grant = try await grant(.dot)
        var signedClaims = claims; signedClaims["nonce"] = grant.expectedNonce
        let token = try jwt(key, claims: signedClaims)
        let discovery = discoveryData, keys = jwks(key)
        let fixture = IdentityProtocolFixture { request in
            switch request.url!.path {
            case "/api/accounts/oauth/token":
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertFalse(String(data: request.httpBody ?? Data(), encoding: .utf8)?.contains("client_secret") ?? false)
                return .json(self.json(["id_token": token]))
            case "/.well-known/openid-configuration": return .json(discovery)
            case "/.well-known/jwks.json": return .json(keys)
            default: throw CloudAgentIdentityError.invalidConfiguration
            }
        }
        defer { fixture.close() }
        let current = instant
        let client = CloudAgentIdentityClient(http: fixture.http, now: { current })
        let result = try await client.verify(grant, configuration: registration())
        XCTAssertEqual(result.subject, "unit-test-subject")
        XCTAssertEqual(fixture.requests.count, 3)
        XCTAssertFalse(CloudAgentConnectionStatus(provider: .dot, identity: .signedIn(try result.binding())).canSend)
    }

    func testXIdentityUsesOnlyDocumentedMeRouteAndNeverTreatsIdentityAsBotAccess() async throws {
        let fixture = IdentityProtocolFixture { request in
            if request.url?.path == "/2/oauth2/token" {
                return .json(self.json(["access_token": "synthetic-bearer", "token_type": "bearer", "expires_in": 7200,
                                        "scope": "users.read tweet.read"]))
            }
            XCTAssertEqual(request.url, URL(string: "https://api.x.com/2/users/me"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-bearer")
            return .json(self.json(["data": ["id": "123456789", "name": "not-retained", "username": "not-retained"]]))
        }
        defer { fixture.close() }
        let current = instant
        let client = CloudAgentIdentityClient(http: fixture.http, now: { current })
        let identity = try await client.verify(grant(.grokBot), configuration: registration(.grokBot))
        XCTAssertEqual(identity.subject, "123456789"); XCTAssertEqual(fixture.requests.count, 2)
        XCTAssertFalse(CloudAgentConnectionStatus(provider: .grokBot, identity: .signedIn(try identity.binding())).canSend)
        XCTAssertFalse(String(data: try JSONEncoder().encode(identity), encoding: .utf8)!.contains("synthetic-bearer"))
    }

    func testUnknownKidGetsOneBoundedJWKSRefreshAndNoOtherRoute() async throws {
        let key = P256.Signing.PrivateKey(); let grant = try await grant(.dot)
        var signedClaims = claims; signedClaims["nonce"] = grant.expectedNonce
        let token = try jwt(key, claims: signedClaims)
        let discovery = discoveryData
        // Never contains the token's kid, so the result must remain blocked.
        let keys = jwks(key, extra: ["kid": "other-key"])
        let fixture = IdentityProtocolFixture { request in
            switch request.url!.path {
            case "/api/accounts/oauth/token": return .json(self.json(["id_token": token]))
            case "/.well-known/openid-configuration": return .json(discovery)
            case "/.well-known/jwks.json": return .json(keys)
            default: throw CloudAgentIdentityError.invalidConfiguration
            }
        }
        defer { fixture.close() }
        let current = instant
        let client = CloudAgentIdentityClient(http: fixture.http, now: { current })
        do { _ = try await client.verify(grant, configuration: registration()); XCTFail("Must reject unknown key") }
        catch { }
        XCTAssertEqual(fixture.requests.filter { $0.url == CloudAgentIdentityHTTP.jwksURL }.count, 2)
        XCTAssertEqual(fixture.requests.count, 4)
    }

    func testMissingXUserScopesOrFailedCurrentUserNeverCreateIdentity() async throws {
        for token in [["token_type": "bearer", "scope": "users.read"], ["token_type": "basic", "scope": "users.read tweet.read"]] {
            let fixture = IdentityProtocolFixture { request in
                XCTAssertEqual(request.url?.path, "/2/oauth2/token")
                var response: [String: Any] = ["access_token": "synthetic-bearer", "expires_in": 7200]
                token.forEach { response[$0.key] = $0.value }
                return .json(self.json(response))
            }
            defer { fixture.close() }
            let current = instant
            let client = CloudAgentIdentityClient(http: fixture.http, now: { current })
            do { _ = try await client.verify(grant(.grokBot), configuration: registration(.grokBot)); XCTFail("Must reject token") }
            catch { }
            XCTAssertEqual(fixture.requests.count, 1)
        }
        for profile in [["data": ["id": "not-a-user-id"]], ["errors": [["detail": "not displayed"]]]] as [[String: Any]] {
            let fixture = IdentityProtocolFixture { request in
                request.url?.path == "/2/oauth2/token"
                    ? .json(self.json(["access_token": "synthetic-bearer", "token_type": "bearer", "expires_in": 7200, "scope": "users.read tweet.read"]))
                    : .json(self.json(profile))
            }
            defer { fixture.close() }
            let current = instant
            let client = CloudAgentIdentityClient(http: fixture.http, now: { current })
            do { _ = try await client.verify(grant(.grokBot), configuration: registration(.grokBot)); XCTFail("Must reject profile") }
            catch { }
        }
    }

    func testActualHTTPRedirectIsRejectedWithoutFollowingBearerOrCode() async throws {
        let fixture = IdentityProtocolFixture { _ in .redirect(URL(string: "https://attacker.invalid/collect")!) }
        defer { fixture.close() }
        do { _ = try await fixture.http.get(CloudAgentIdentityHTTP.jwksURL); XCTFail("Must reject redirect") }
        catch { }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testHTTPRejectsStatusContentTypeOversizeAndArbitraryTokenDestinations() async throws {
        for plan in [IdentityProtocolFixture.Plan.status(302), .status(400), .status(200, type: "text/html"),
                     .json(Data(repeating: 65, count: 131_073)), .declaredLength(131_073)] {
            let fixture = IdentityProtocolFixture { _ in plan }
            defer { fixture.close() }
            do { _ = try await fixture.http.get(CloudAgentIdentityHTTP.jwksURL); XCTFail("Must reject response") }
            catch { }
        }
        let fixture = IdentityProtocolFixture { _ in XCTFail("Must not issue arbitrary request"); return .json(Data("{}".utf8)) }
        defer { fixture.close() }
        do { _ = try await fixture.http.get(URL(string: "https://attacker.invalid/token")!); XCTFail("Must reject destination") }
        catch { }
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testCancellationStopsStalledExchangeWithoutNetworkFallback() async throws {
        let reached = expectation(description: "fixture intercepted request")
        let fixture = IdentityProtocolFixture { _ in reached.fulfill(); return .stall }
        defer { fixture.close() }
        let work = Task { try await fixture.http.get(CloudAgentIdentityHTTP.jwksURL) }
        await fulfillment(of: [reached], timeout: 2)
        work.cancel()
        do { _ = try await work.value; XCTFail("Must cancel") }
        catch is CancellationError { }
        catch { XCTFail("Expected cancellation") }
    }
}

private final class IdentityProtocolFixture: @unchecked Sendable {
    enum Plan {
        case json(Data), status(Int, type: String = "application/json"), declaredLength(Int), redirect(URL), stall
    }
    private static let registryLock = NSLock()
    private static var fixtures: [String: IdentityProtocolFixture] = [:]
    private let id = UUID().uuidString
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    let handler: (URLRequest) throws -> Plan
    lazy var http: CloudAgentIdentityHTTP = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [IdentityURLProtocol.self]
        config.httpAdditionalHeaders = ["X-Peel-Unit-Fixture": id]
        return CloudAgentIdentityHTTP(configuration: config)
    }()
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    init(handler: @escaping (URLRequest) throws -> Plan) {
        self.handler = handler
        Self.registryLock.lock(); Self.fixtures[id] = self; Self.registryLock.unlock()
    }
    func close() { Self.registryLock.lock(); Self.fixtures[id] = nil; Self.registryLock.unlock() }
    // Registry removal is explicit because the registry retains the fixture.
    // Every URL is still intercepted if a test's fixture is absent.
    static func consume(_ request: URLRequest) throws -> Plan {
        Self.registryLock.lock(); let fixture = Self.fixtures[request.value(forHTTPHeaderField: "X-Peel-Unit-Fixture") ?? ""]; Self.registryLock.unlock()
        guard let fixture else { throw CloudAgentIdentityError.invalidConfiguration }
        fixture.lock.lock(); fixture.captured.append(request); fixture.lock.unlock()
        return try fixture.handler(request)
    }
}

private final class IdentityURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let plan = try IdentityProtocolFixture.consume(request)
            let status: Int, type: String, payload: Data, length: Int?
            switch plan {
            case .json(let data): status = 200; type = "application/json"; payload = data; length = nil
            case .status(let code, let contentType): status = code; type = contentType; payload = Data("{}".utf8); length = nil
            case .declaredLength(let count): status = 200; type = "application/json"; payload = Data(); length = count
            case .redirect(let destination):
                let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": destination.absoluteString])!
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: destination), redirectResponse: response)
                return
            case .stall: return
            }
            var headers = ["Content-Type": type]
            if let length { headers["Content-Length"] = String(length) }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            // Chunking exercises the running bound, not only Content-Length.
            for offset in stride(from: 0, to: payload.count, by: 4096) {
                client?.urlProtocol(self, didLoad: payload.subdata(in: offset..<min(offset + 4096, payload.count)))
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
