import Foundation
import XCTest
@testable import PeelWatchCore

private final class CloudAgentOAuthClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value.addTimeInterval(seconds); lock.unlock() }
}

final class CloudAgentOAuthTests: XCTestCase {
    private let redirect = URL(string: "peel-fixture://oauth/callback")!
    private func callback(_ request: CloudAgentOAuthRequest, code: String = "fixture-authorization-code", state: String? = nil) -> URL {
        var c = URLComponents(url: request.redirectURI, resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "state", value: state ?? request.state), URLQueryItem(name: "code", value: code)]
        return c.url!
    }
    private func expect<T>(_ error: CloudAgentOAuthError, operation: () async throws -> T,
                           file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Expected OAuth rejection", file: file, line: line) }
        catch let actual as CloudAgentOAuthError { XCTAssertEqual(actual, error, file: file, line: line) }
        catch { XCTFail("Unexpected error type", file: file, line: line) }
    }

    func testS256MatchesRFC7636AppendixBVector() {
        XCTAssertEqual(CloudAgentOAuthCoordinator.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }
    func testFreshSessionsGenerateIndependentCryptographicStateNonceAndChallenge() async throws {
        let coordinator = CloudAgentOAuthCoordinator()
        let first = try await coordinator.begin(provider: .dot, registeredRedirectURI: redirect)
        let second = try await coordinator.begin(provider: .dot, registeredRedirectURI: redirect)
        XCTAssertNotEqual(first.transactionID, second.transactionID)
        for value in [first.state, first.nonce, first.codeChallenge] {
            XCTAssertEqual(value.count, 43)
            XCTAssertFalse(value.contains("+")); XCTAssertFalse(value.contains("/")); XCTAssertFalse(value.contains("="))
        }
        XCTAssertNotEqual(first.state, second.state); XCTAssertNotEqual(first.nonce, second.nonce)
        XCTAssertNotEqual(first.codeChallenge, second.codeChallenge)
        XCTAssertEqual(first.codeChallengeMethod, "S256")
        XCTAssertFalse(first.description.contains(first.state)); XCTAssertFalse(first.debugDescription.contains(first.nonce))
    }
    func testVerifiedCallbackYieldsSensitiveGrantOnceWithoutEstablishingIdentity() async throws {
        let coordinator = CloudAgentOAuthCoordinator()
        let request = try await coordinator.begin(provider: .dot, registeredRedirectURI: redirect)
        let grant = try await coordinator.consumeCallback(callback(request), transactionID: request.transactionID)
        XCTAssertEqual(grant.provider, .dot); XCTAssertEqual(grant.authorizationCode, "fixture-authorization-code")
        XCTAssertEqual(grant.expectedNonce, request.nonce)
        XCTAssertEqual(CloudAgentOAuthCoordinator.challenge(for: grant.codeVerifier), request.codeChallenge)
        XCTAssertFalse(grant.description.contains(grant.authorizationCode)); XCTAssertFalse(grant.debugDescription.contains(grant.codeVerifier))
        XCTAssertFalse(CloudAgentConnectionStatus(provider: .dot).canSend)
        await expect(.noPendingAuthorization) { try await coordinator.consumeCallback(self.callback(request), transactionID: request.transactionID) }
    }
    func testLateCallbackCannotConsumeReplacementSession() async throws {
        let coordinator = CloudAgentOAuthCoordinator()
        let first = try await coordinator.begin(provider: .dot, registeredRedirectURI: redirect)
        let second = try await coordinator.begin(provider: .grokBot, registeredRedirectURI: redirect)
        await expect(.staleTransaction) { try await coordinator.consumeCallback(self.callback(first), transactionID: first.transactionID) }
        let grant = try await coordinator.consumeCallback(callback(second), transactionID: second.transactionID)
        XCTAssertEqual(grant.provider, .grokBot)
    }
    func testStateMismatchIsSingleUseAndCannotBeRetriedWithInjectedCode() async throws {
        let coordinator = CloudAgentOAuthCoordinator()
        let request = try await coordinator.begin(provider: .dot, registeredRedirectURI: redirect)
        await expect(.stateMismatch) { try await coordinator.consumeCallback(self.callback(request, state: "wrong-state"), transactionID: request.transactionID) }
        await expect(.noPendingAuthorization) { try await coordinator.consumeCallback(self.callback(request), transactionID: request.transactionID) }
    }
    func testExpiredAndBackwardsClockSessionsAreRejected() async throws {
        let clock = CloudAgentOAuthClock(); let coordinator = CloudAgentOAuthCoordinator(now: { clock.now() })
        let expired = try await coordinator.begin(provider: .dot, registeredRedirectURI: redirect)
        clock.advance(600)
        await expect(.expired) { try await coordinator.consumeCallback(self.callback(expired), transactionID: expired.transactionID) }
        let backwards = try await coordinator.begin(provider: .dot, registeredRedirectURI: redirect)
        clock.advance(-1)
        await expect(.expired) { try await coordinator.consumeCallback(self.callback(backwards), transactionID: backwards.transactionID) }
    }
    func testCallbackRequiresExactRegisteredOriginPathAndNoFragmentOrCredentials() async throws {
        let coordinator = CloudAgentOAuthCoordinator()
        for prefix in ["peel-fixture://other/callback", "peel-fixture://oauth/other", "peel-fixture://oauth/%63allback", "peel-fixture://user:pass@oauth/callback"] {
            let request = try await coordinator.begin(provider: .dot, registeredRedirectURI: redirect)
            let url = URL(string: prefix + "?state=" + request.state + "&code=fixture")!
            await expect(.redirectMismatch) { try await coordinator.consumeCallback(url, transactionID: request.transactionID) }
        }
        let request = try await coordinator.begin(provider: .dot, registeredRedirectURI: redirect)
        let fragmented = URL(string: callback(request).absoluteString + "#access_token=fixture")!
        await expect(.redirectMismatch) { try await coordinator.consumeCallback(fragmented, transactionID: request.transactionID) }
    }

    func testHTTPSCallbackKeepsExactRedirectPKCEAndOneTimeTransaction() async throws {
        let coordinator = CloudAgentOAuthCoordinator()
        let https = URL(string: "https://auth.unit.invalid/oauth/callback")!
        let request = try await coordinator.begin(provider: .grokBot, registeredRedirectURI: https)
        let grant = try await coordinator.consumeCallback(callback(request), transactionID: request.transactionID)
        XCTAssertEqual(grant.redirectURI, https)
        XCTAssertEqual(grant.provider, .grokBot)
        XCTAssertEqual(grant.expectedNonce, request.nonce)
        XCTAssertEqual(CloudAgentOAuthCoordinator.challenge(for: grant.codeVerifier), request.codeChallenge)
        await expect(.noPendingAuthorization) { try await coordinator.consumeCallback(self.callback(request), transactionID: request.transactionID) }
    }

    func testHTTPSCallbackRejectsOtherOriginPathPortAndEncodedAliases() async throws {
        let coordinator = CloudAgentOAuthCoordinator()
        let https = URL(string: "https://auth.unit.invalid/oauth/callback")!
        for prefix in ["http://auth.unit.invalid/oauth/callback", "https://other.unit.invalid/oauth/callback",
                       "https://auth.unit.invalid.evil.invalid/oauth/callback", "https://auth.unit.invalid/oauth/other",
                       "https://auth.unit.invalid/oauth/callback/", "https://auth.unit.invalid/oauth/%63allback",
                       "https://auth.unit.invalid:443/oauth/callback", "https://auth.unit.invalid:8443/oauth/callback",
                       "https://user:pass@auth.unit.invalid/oauth/callback"] {
            let request = try await coordinator.begin(provider: .dot, registeredRedirectURI: https)
            let url = URL(string: prefix + "?state=" + request.state + "&code=fixture")!
            await expect(.redirectMismatch) { try await coordinator.consumeCallback(url, transactionID: request.transactionID) }
            await expect(.noPendingAuthorization) { try await coordinator.consumeCallback(self.callback(request), transactionID: request.transactionID) }
        }
    }

    func testHTTPSCallbackRetainsStateDuplicateAndImplicitTokenRejections() async throws {
        let coordinator = CloudAgentOAuthCoordinator()
        let https = URL(string: "https://auth.unit.invalid/oauth/callback")!
        let wrongState = try await coordinator.begin(provider: .dot, registeredRedirectURI: https)
        await expect(.stateMismatch) { try await coordinator.consumeCallback(self.callback(wrongState, state: "other"), transactionID: wrongState.transactionID) }
        for extra in ["&state=other", "&code=other", "&access_token=fixture", "&id_token=fixture", "#access_token=fixture"] {
            let request = try await coordinator.begin(provider: .dot, registeredRedirectURI: https)
            let value = URL(string: callback(request).absoluteString + extra)!
            await expect(extra.hasPrefix("#") ? .redirectMismatch : .malformedCallback) {
                try await coordinator.consumeCallback(value, transactionID: request.transactionID)
            }
        }
    }
    func testDuplicateAndImplicitTokenParametersAreRejectedBeforeGrant() async throws {
        let coordinator = CloudAgentOAuthCoordinator()
        for extra in ["&state=other", "&code=other", "&access_token=fixture", "&id_token=fixture", "&refresh_token=fixture"] {
            let request = try await coordinator.begin(provider: .dot, registeredRedirectURI: redirect)
            let url = URL(string: callback(request).absoluteString + extra)!
            await expect(.malformedCallback) { try await coordinator.consumeCallback(url, transactionID: request.transactionID) }
        }
        let missing = try await coordinator.begin(provider: .dot, registeredRedirectURI: redirect)
        let url = URL(string: redirect.absoluteString + "?code=fixture")!
        await expect(.stateMismatch) { try await coordinator.consumeCallback(url, transactionID: missing.transactionID) }
    }
    func testDenialDoesNotExposeProviderErrorDescriptionOrGrantCode() async throws {
        let coordinator = CloudAgentOAuthCoordinator()
        let request = try await coordinator.begin(provider: .dot, registeredRedirectURI: redirect)
        var c = URLComponents(url: redirect, resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "state", value: request.state), URLQueryItem(name: "error", value: "access_denied"),
                        URLQueryItem(name: "error_description", value: "provider-private-text")]
        await expect(.authorizationDenied) { try await coordinator.consumeCallback(c.url!, transactionID: request.transactionID) }
        XCTAssertFalse(CloudAgentOAuthError.authorizationDenied.localizedDescription.contains("provider-private-text"))
    }
    func testCancelIsBoundToExactTransaction() async throws {
        let coordinator = CloudAgentOAuthCoordinator()
        let first = try await coordinator.begin(provider: .dot, registeredRedirectURI: redirect)
        let second = try await coordinator.begin(provider: .dot, registeredRedirectURI: redirect)
        await coordinator.cancel(transactionID: first.transactionID)
        _ = try await coordinator.consumeCallback(callback(second), transactionID: second.transactionID)
        let third = try await coordinator.begin(provider: .dot, registeredRedirectURI: redirect)
        await coordinator.cancel(transactionID: third.transactionID)
        await expect(.noPendingAuthorization) { try await coordinator.consumeCallback(self.callback(third), transactionID: third.transactionID) }
    }
    func testRedirectRegistrationRejectsUnsafeOrAmbiguousURIs() async throws {
        let coordinator = CloudAgentOAuthCoordinator()
        for raw in ["http://example.test/oauth", "javascript:alert(1)", "file:///callback", "https://user:pass@example.test/callback",
                    "https://example.test/callback?token=fixture", "https://example.test/callback#fragment", "https://example.test:8080/callback"] {
            await expect(.invalidRedirect) { try await coordinator.begin(provider: .dot, registeredRedirectURI: URL(string: raw)!) }
        }
    }
    func testOfficialPublicRegistrationBuildsOnlyAuditedIdentityRequests() async throws {
        let coordinator = CloudAgentOAuthCoordinator()
        let openAI = try CloudAgentOAuthRegistration.chatGPTPublicClient(clientID: "oaiapp_fixture_client", registeredRedirectURI: redirect)
        let request = try await coordinator.begin(provider: .dot, registeredRedirectURI: redirect)
        let url = try openAI.authorizationURL(for: request)
        XCTAssertEqual(url.host, "auth.openai.com"); XCTAssertEqual(url.path, "/api/accounts/authorize")
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(query["scope"], "openid profile email"); XCTAssertEqual(query["nonce"], request.nonce)
        XCTAssertEqual(query["code_challenge"], request.codeChallenge); XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertNil(query["code_verifier"]); XCTAssertNil(query["client_secret"])
        let grant = try await coordinator.consumeCallback(callback(request, code: "a+b c&=?/"), transactionID: request.transactionID)
        let token = try openAI.tokenExchangeRequest(for: grant)
        XCTAssertEqual(token.url?.absoluteString, "https://auth.openai.com/api/accounts/oauth/token")
        XCTAssertEqual(token.httpMethod, "POST"); XCTAssertNil(token.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(String(data: XCTUnwrap(token.httpBody), encoding: .utf8))
        XCTAssertTrue(body.contains("code=a%2Bb%20c%26%3D%3F%2F")); XCTAssertFalse(body.contains("client_secret"))
        XCTAssertEqual(openAI.expectedIdentityIssuer?.absoluteString, "https://auth.openai.com")
    }
    func testXUsesOwnNativeRegistrationAndOptionalOfflineScopeWithoutClaimingOIDCOrAgentAccess() async throws {
        let coordinator = CloudAgentOAuthCoordinator()
        let x = try CloudAgentOAuthRegistration.xNativeClient(clientID: "fixture-x-native-client", registeredRedirectURI: redirect)
        let request = try await coordinator.begin(provider: .grokBot, registeredRedirectURI: redirect)
        let url = try x.authorizationURL(for: request)
        XCTAssertEqual(url.host, "x.com"); XCTAssertEqual(url.path, "/i/oauth2/authorize")
        XCTAssertEqual(x.tokenEndpoint.absoluteString, "https://api.x.com/2/oauth2/token")
        XCTAssertNil(x.expectedIdentityIssuer); XCTAssertFalse(x.requestedScopes.contains("openid"))
        XCTAssertFalse(x.requestedScopes.contains("offline.access"))
        let offline = try CloudAgentOAuthRegistration.xNativeClient(clientID: "fixture-x-native-client", registeredRedirectURI: redirect, requestsOfflineAccess: true)
        XCTAssertTrue(offline.requestedScopes.contains("offline.access"))
        XCTAssertFalse(CloudAgentConnectionStatus(provider: .grokBot).canSend)
        let openAI = try CloudAgentOAuthRegistration.chatGPTPublicClient(clientID: "oaiapp_fixture_client", registeredRedirectURI: redirect)
        XCTAssertThrowsError(try openAI.authorizationURL(for: request))
        let grant = try await coordinator.consumeCallback(callback(request), transactionID: request.transactionID)
        XCTAssertThrowsError(try openAI.tokenExchangeRequest(for: grant))
    }
}
