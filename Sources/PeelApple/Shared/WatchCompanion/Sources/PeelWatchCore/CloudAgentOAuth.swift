import Foundation
import CryptoKit
import Security

public enum CloudAgentOAuthError: Error, Equatable, LocalizedError, Sendable {
    case invalidRedirect
    case randomGenerationFailed
    case noPendingAuthorization
    case staleTransaction
    case expired
    case redirectMismatch
    case stateMismatch
    case malformedCallback
    case authorizationDenied
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidRedirect: return "Use the exact redirect registered for this app."
        case .randomGenerationFailed: return "A secure sign-in session could not be created."
        case .noPendingAuthorization, .staleTransaction: return "This sign-in session is no longer active."
        case .expired: return "The sign-in session expired. Start again."
        case .redirectMismatch, .stateMismatch, .malformedCallback: return "The sign-in callback could not be verified."
        case .authorizationDenied: return "Sign-in was declined or could not be authorized."
        case .cancelled: return "Sign-in was cancelled."
        }
    }
}

/// Phone-only material for an audited ASWebAuthenticationSession adapter. The
/// core supplies no authorization/token endpoint and starts no browser/network.
@available(watchOS, unavailable, message: "OAuth sessions remain on iPhone.")
public struct CloudAgentOAuthRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let transactionID: UUID
    public let provider: CloudAgentProvider
    public let redirectURI: URL
    public let state: String
    public let nonce: String
    public let codeChallenge: String
    public let codeChallengeMethod = "S256"
    public let expiresAt: Date
    public var description: String { "CloudAgentOAuthRequest(provider: \(provider.rawValue), private session material redacted)" }
    public var debugDescription: String { description }
}

/// Sensitive one-time exchange input. Intentionally not Codable, not a signed-in
/// identity, and not an existing-agent capability. Never log/save/send to Watch.
@available(watchOS, unavailable, message: "Authorization codes and PKCE verifiers remain on iPhone.")
public struct CloudAgentOAuthCodeGrant: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let transactionID: UUID
    public let provider: CloudAgentProvider
    public let redirectURI: URL
    public let authorizationCode: String
    public let codeVerifier: String
    public let expectedNonce: String
    /// An adapter must verify this when the provider's audited contract supplies
    /// issuer identification. This core never treats it as trusted identity.
    public let reportedIssuer: String?
    public var description: String { "CloudAgentOAuthCodeGrant(provider: \(provider.rawValue), secrets redacted)" }
    public var debugDescription: String { description }
}

/// Single active authorization per coordinator. Create separate coordinators
/// for distinct providers, or pass the exact returned transactionID at callback.
/// A new begin replaces the previous pending authorization. A late callback for
/// an older transaction cannot clear the replacement session.
@available(watchOS, unavailable, message: "OAuth sessions remain on iPhone.")
public actor CloudAgentOAuthCoordinator {
    private struct Pending {
        let request: CloudAgentOAuthRequest
        let verifier: String
        let startedAt: Date
    }
    private var pending: Pending?
    private let now: @Sendable () -> Date

    public init() { now = { Date() } }
    init(now: @escaping @Sendable () -> Date) { self.now = now }

    /// Call only with a redirect from the concrete provider's audited app
    /// registration. Accepting a syntactically valid URI does not establish that
    /// the provider supports that app/client/redirect or the desired agent API.
    public func begin(provider: CloudAgentProvider, registeredRedirectURI: URL) throws -> CloudAgentOAuthRequest {
        try Self.validateRegisteredRedirect(registeredRedirectURI)
        let startedAt = now()
        guard startedAt.timeIntervalSinceReferenceDate.isFinite else { throw CloudAgentOAuthError.expired }
        let verifier = try Self.secureRandomValue()
        let request = CloudAgentOAuthRequest(transactionID: UUID(), provider: provider, redirectURI: registeredRedirectURI,
                                            state: try Self.secureRandomValue(), nonce: try Self.secureRandomValue(),
                                            codeChallenge: Self.challenge(for: verifier), expiresAt: startedAt.addingTimeInterval(600))
        pending = Pending(request: request, verifier: verifier, startedAt: startedAt)
        return request
    }

    public func consumeCallback(_ callback: URL, transactionID: UUID) throws -> CloudAgentOAuthCodeGrant {
        guard let pending else { throw CloudAgentOAuthError.noPendingAuthorization }
        guard transactionID == pending.request.transactionID else { throw CloudAgentOAuthError.staleTransaction }
        // Every callback for this exact active transaction is single-use,
        // including a malformed/denied response. Start again after rejection.
        self.pending = nil
        let current = now()
        guard current >= pending.startedAt, current < pending.request.expiresAt else { throw CloudAgentOAuthError.expired }
        guard callback.absoluteString.utf8.count <= 32_768,
              let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              let expected = URLComponents(url: pending.request.redirectURI, resolvingAgainstBaseURL: false),
              components.scheme == expected.scheme, components.host == expected.host,
              components.port == expected.port, components.percentEncodedPath == expected.percentEncodedPath,
              components.user == nil, components.password == nil, components.fragment == nil else {
            throw CloudAgentOAuthError.redirectMismatch
        }
        let items = components.queryItems ?? []
        let names = items.map(\.name)
        guard items.count <= 16, names.allSatisfy({ $0.utf8.count <= 64 }), Set(names).count == names.count,
              !names.contains(where: { ["access_token", "id_token", "refresh_token", "token_type"].contains($0) }),
              items.allSatisfy({ ($0.value?.utf8.count ?? 0) <= 8_192 }) else { throw CloudAgentOAuthError.malformedCallback }
        guard let state = items.first(where: { $0.name == "state" })?.value,
              Self.constantTimeEqual(state, pending.request.state) else { throw CloudAgentOAuthError.stateMismatch }
        if names.contains("error") {
            guard !names.contains("code") else { throw CloudAgentOAuthError.malformedCallback }
            throw CloudAgentOAuthError.authorizationDenied
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty,
              !code.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CloudAgentOAuthError.malformedCallback
        }
        return CloudAgentOAuthCodeGrant(transactionID: transactionID, provider: pending.request.provider,
                                       redirectURI: pending.request.redirectURI, authorizationCode: code,
                                       codeVerifier: pending.verifier, expectedNonce: pending.request.nonce,
                                       reportedIssuer: items.first(where: { $0.name == "iss" })?.value)
    }

    public func cancel(transactionID: UUID) {
        if pending?.request.transactionID == transactionID { pending = nil }
    }

    static func validateRegisteredRedirect(_ redirect: URL) throws {
        guard redirect.absoluteString.utf8.count <= 2_048,
              let c = URLComponents(url: redirect, resolvingAgainstBaseURL: false), let scheme = c.scheme,
              !["http", "javascript", "data", "file", "about", "ftp", "ws", "wss", "mailto", "tel", "sms"].contains(scheme.lowercased()),
              !scheme.isEmpty, scheme.utf8.count <= 64,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              !c.percentEncodedPath.contains("%"), !c.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw CloudAgentOAuthError.invalidRedirect
        }
        if scheme == "https" {
            guard let host = c.host, !host.isEmpty, c.port == nil || c.port == 443 else { throw CloudAgentOAuthError.invalidRedirect }
        } else {
            guard c.port == nil else { throw CloudAgentOAuthError.invalidRedirect }
        }
    }
    static func challenge(for verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    private static func secureRandomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw CloudAgentOAuthError.randomGenerationFailed }
        return base64URL(Data(bytes))
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func constantTimeEqual(_ left: String, _ right: String) -> Bool {
        let a = Array(left.utf8), b = Array(right.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// Explicit public-client registration supplied by the app operator. Endpoint
/// constants follow the audited official identity contracts; they are not
/// existing Dot/Grok Bot conversation APIs. This type performs no network calls,
/// stores no client secret and cannot set CloudAgentConnectionStatus.canSend.
@available(watchOS, unavailable, message: "OAuth registration and exchange remain on iPhone.")
public struct CloudAgentOAuthRegistration: Sendable {
    public let provider: CloudAgentProvider
    public let clientID: String
    public let redirectURI: URL
    public let requestsOfflineAccess: Bool

    /// OpenAI must issue/approve a public identity client for this app. A Codex
    /// CLI client or open-source loopback registration is not a substitute.
    public static func chatGPTPublicClient(clientID: String, registeredRedirectURI: URL) throws -> Self {
        guard clientID.hasPrefix("oaiapp_") else { throw CloudAgentOAuthError.invalidRedirect }
        return try Self(provider: .dot, clientID: clientID, redirectURI: registeredRedirectURI, requestsOfflineAccess: false)
    }
    /// Use the developer's own OAuth2-enabled X Native App registration.
    public static func xNativeClient(clientID: String, registeredRedirectURI: URL,
                                     requestsOfflineAccess: Bool = false) throws -> Self {
        try Self(provider: .grokBot, clientID: clientID, redirectURI: registeredRedirectURI,
                 requestsOfflineAccess: requestsOfflineAccess)
    }
    private init(provider: CloudAgentProvider, clientID: String, redirectURI: URL, requestsOfflineAccess: Bool) throws {
        guard (8...512).contains(clientID.utf8.count), clientID.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw CloudAgentOAuthError.invalidRedirect
        }
        try CloudAgentOAuthCoordinator.validateRegisteredRedirect(redirectURI)
        self.provider = provider; self.clientID = clientID; self.redirectURI = redirectURI
        self.requestsOfflineAccess = requestsOfflineAccess
    }
    public var authorizationEndpoint: URL {
        URL(string: provider == .dot ? "https://auth.openai.com/api/accounts/authorize" : "https://x.com/i/oauth2/authorize")!
    }
    public var tokenEndpoint: URL {
        URL(string: provider == .dot ? "https://auth.openai.com/api/accounts/oauth/token" : "https://api.x.com/2/oauth2/token")!
    }
    public var expectedIdentityIssuer: URL? { provider == .dot ? URL(string: "https://auth.openai.com")! : nil }
    public var requestedScopes: [String] {
        provider == .dot ? ["openid", "profile", "email"]
        : ["users.read", "tweet.read"] + (requestsOfflineAccess ? ["offline.access"] : [])
    }
    public func authorizationURL(for request: CloudAgentOAuthRequest) throws -> URL {
        guard request.provider == provider, request.redirectURI.absoluteString == redirectURI.absoluteString else {
            throw CloudAgentOAuthError.redirectMismatch
        }
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var parameters = ["client_id": clientID, "redirect_uri": redirectURI.absoluteString, "response_type": "code",
                          "scope": requestedScopes.joined(separator: " "), "state": request.state,
                          "code_challenge": request.codeChallenge, "code_challenge_method": "S256"]
        if provider == .dot { parameters["nonce"] = request.nonce }
        components.queryItems = parameters.keys.sorted().map { URLQueryItem(name: $0, value: parameters[$0]) }
        guard let url = components.url else { throw CloudAgentOAuthError.invalidRedirect }
        return url
    }
    /// Request construction only. The concrete phone/backend adapter must make
    /// the exchange and verify its result. For SIWC, validate ID-token signature,
    /// discovery issuer, audience, expiry and original nonce before identity.
    public func tokenExchangeRequest(for grant: CloudAgentOAuthCodeGrant) throws -> URLRequest {
        guard grant.provider == provider, grant.redirectURI.absoluteString == redirectURI.absoluteString else {
            throw CloudAgentOAuthError.redirectMismatch
        }
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"; request.timeoutInterval = 20; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let fields = ["grant_type": "authorization_code", "client_id": clientID, "code": grant.authorizationCode,
                      "code_verifier": grant.codeVerifier, "redirect_uri": redirectURI.absoluteString]
        request.httpBody = Data(fields.keys.sorted().map { "\(Self.formEncode($0))=\(Self.formEncode(fields[$0]!))" }
            .joined(separator: "&").utf8)
        return request
    }
    private static func formEncode(_ value: String) -> String {
        value.utf8.map { byte -> String in
            if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45, 46, 95, 126].contains(byte) {
                return String(UnicodeScalar(byte))
            }
            return String(format: "%%%02X", byte)
        }.joined()
    }
}
