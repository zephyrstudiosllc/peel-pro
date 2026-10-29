#if !os(watchOS)
import Foundation
import CryptoKit

public enum CloudAgentIdentityError: Error, Equatable, LocalizedError, Sendable {
    case registrationRequired, unsupportedCallback, invalidConfiguration, invalidResponse, requestFailed
    case invalidIdentity, unsupportedSigningAlgorithm, cancelled, secureStorageUnavailable

    public var errorDescription: String? {
        switch self {
        case .registrationRequired: return "Peel Pro needs its own approved native sign-in registration for this provider."
        case .unsupportedCallback: return "This build needs an approved HTTPS callback or custom URL callback registered for this app."
        case .invalidConfiguration: return "The provider sign-in registration does not match this app."
        case .invalidResponse, .requestFailed: return "The provider sign-in response could not be verified. Try again."
        case .invalidIdentity, .unsupportedSigningAlgorithm: return "The provider identity could not be verified."
        case .cancelled: return "Sign-in was cancelled."
        case .secureStorageUnavailable: return "Secure identity storage is unavailable. Unlock this iPhone and try again."
        }
    }
}

/// Native matcher selected from an exact approved registration, not a domain
/// association or an authorization grant by itself.
public enum CloudAgentIdentityCallback: Equatable, Sendable {
    case customScheme(String)
    case https(host: String, path: String)
}

/// Operator-supplied public native-client registration, never remote or user-entered config.
/// Validation cannot prove provider approval: approvalReference records the developer's
/// provisioning evidence. The issued client ID and exact callback must be reconciled
/// against that evidence before release. No default/borrowed client is supplied.
public struct CloudAgentIdentityConfiguration: Sendable {
    public let registration: CloudAgentOAuthRegistration
    public let callback: CloudAgentIdentityCallback
    public let bundleID: String
    public let approvalReference: String

    public init(provider: CloudAgentProvider, values: [String: String], bundleID: String,
                registeredURLSchemes: [String]) throws {
        let keys: Set<String> = ["ClientID", "RedirectURI", "BundleID", "ClientType", "TokenEndpointAuthMethod", "ApprovalReference"]
        guard Set(values.keys) == keys, values["BundleID"] == bundleID,
              values["ClientType"] == "public-native", values["TokenEndpointAuthMethod"] == "none",
              let client = values["ClientID"], let rawRedirect = values["RedirectURI"],
              let redirect = URL(string: rawRedirect), redirect.absoluteString == rawRedirect,
              let approval = values["ApprovalReference"], (8...512).contains(approval.utf8.count),
              !approval.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              ![client, rawRedirect, approval].contains(where: Self.isPlaceholder) else {
            throw CloudAgentIdentityError.registrationRequired
        }
        // Derive the native callback matcher only from this exact operator
        // registration. Apple separately verifies the HTTPS webcredentials
        // association; this value does not grant an entitlement or domain.
        do { try CloudAgentOAuthCoordinator.validateRegisteredRedirect(redirect) }
        catch { throw CloudAgentIdentityError.unsupportedCallback }
        guard let components = URLComponents(url: redirect, resolvingAgainstBaseURL: false),
              let scheme = components.scheme, scheme == scheme.lowercased(),
              let host = components.host, !host.isEmpty,
              components.path.hasPrefix("/"), !components.path.isEmpty else {
            throw CloudAgentIdentityError.unsupportedCallback
        }
        if scheme == "https" {
            // The native HTTPS API takes host/path, not an origin or a port.
            // Reject aliases its matcher cannot represent exactly. Callback
            // consumption still checks the original full URI and transaction.
            guard components.port == nil, host == host.lowercased(), components.percentEncodedHost == host,
                  host.utf8.count <= 253,
                  !host.hasPrefix("."), !host.hasSuffix("."), !host.contains(".."),
                  host.utf8.allSatisfy({ $0 == 45 || $0 == 46 || (48...57).contains($0) || (97...122).contains($0) }) else {
                throw CloudAgentIdentityError.unsupportedCallback
            }
            callback = .https(host: host, path: components.percentEncodedPath)
        } else {
            guard scheme.contains("."), registeredURLSchemes.contains(scheme), scheme != "http" else {
                throw CloudAgentIdentityError.unsupportedCallback
            }
            callback = .customScheme(scheme)
        }
        if provider == .dot {
            registration = try .chatGPTPublicClient(clientID: client, registeredRedirectURI: redirect)
        } else {
            registration = try .xNativeClient(clientID: client, registeredRedirectURI: redirect, requestsOfflineAccess: false)
        }
        self.bundleID = bundleID
        self.approvalReference = approval
    }

    private static func isPlaceholder(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("example") || lower.contains("fixture") || lower.contains("replace")
            || lower.contains("your_") || lower.contains("todo") || lower.contains("dynamic_agent_client")
    }

    public var storageNamespace: String {
        CloudAgentVerifiedIdentity.digest([registration.provider.rawValue, bundleID,
                                           registration.clientID, registration.redirectURI.absoluteString])
    }
}

/// Minimum verified mapping only. No email/name/picture, raw ID token, bearer,
/// refresh token, code or verifier is retained. This local record is NOT an
/// authorization to call the provider or an existing-agent conversation session.
public struct CloudAgentVerifiedIdentity: Codable, Equatable, Sendable {
    public let provider: CloudAgentProvider
    public let issuer: String
    public let clientID: String
    public let subject: String
    public let verifiedAt: Date
    public let identityExpiresAt: Date

    init(provider: CloudAgentProvider, issuer: String, clientID: String, subject: String,
         verifiedAt: Date, identityExpiresAt: Date) throws {
        guard (1...256).contains(subject.utf8.count),
              !subject.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              identityExpiresAt > verifiedAt else { throw CloudAgentIdentityError.invalidIdentity }
        self.provider = provider; self.issuer = issuer; self.clientID = clientID; self.subject = subject
        self.verifiedAt = verifiedAt; self.identityExpiresAt = identityExpiresAt
    }

    public func binding() throws -> CloudAgentAccountBinding {
        // Keep raw provider account identifiers off the Watch courier as well.
        try CloudAgentAccountBinding(provider: provider, accountID: Self.digest([provider.rawValue, issuer, clientID, subject]))
    }

    public func isCurrent(for configuration: CloudAgentIdentityConfiguration, now: Date) -> Bool {
        provider == configuration.registration.provider && clientID == configuration.registration.clientID
            && issuer == (provider == .dot ? "https://auth.openai.com" : "https://api.x.com")
            && verifiedAt <= now.addingTimeInterval(5) && identityExpiresAt > now
            && identityExpiresAt.timeIntervalSince(verifiedAt) <= 86_405
            && (1...256).contains(subject.utf8.count)
            && !subject.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    static func digest(_ fields: [String]) -> String {
        let framed = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(framed.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Redeems an already verified, single-use PKCE callback. Never returns tokens.
/// Public identity success leaves CloudAgentConversationCapability unestablished.
public struct CloudAgentIdentityClient: Sendable {
    private let http: CloudAgentIdentityHTTP
    private let now: @Sendable () -> Date
    public init() { http = CloudAgentIdentityHTTP(); now = { Date() } }
    init(http: CloudAgentIdentityHTTP, now: @escaping @Sendable () -> Date) { self.http = http; self.now = now }

    public func verify(_ grant: CloudAgentOAuthCodeGrant,
                       configuration: CloudAgentIdentityConfiguration) async throws -> CloudAgentVerifiedIdentity {
        try Task.checkCancellation()
        let registration = configuration.registration
        if let reported = grant.reportedIssuer {
            guard registration.provider == .dot, reported == "https://auth.openai.com" else {
                throw CloudAgentIdentityError.invalidIdentity
            }
        }
        let tokenData = try await http.perform(registration.tokenExchangeRequest(for: grant))
        try Task.checkCancellation()
        switch registration.provider {
        case .dot:
            let tokens = try JSONDecoder().decode(OpenAIIdentityTokens.self, from: tokenData)
            let discovery = try JSONDecoder().decode(CloudAgentOIDCDiscovery.self, from:
                await http.get(CloudAgentIdentityHTTP.discoveryURL))
            try discovery.validate()
            var keys = try await http.get(CloudAgentIdentityHTTP.jwksURL)
            // Each sign-in loads fresh keys; a rotation racing this request gets
            // one bounded refresh for unknown kid, without trusting token URLs.
            let verifier = CloudAgentIDTokenVerifier()
            if try !verifier.containsKey(for: tokens.idToken, jwks: keys) {
                keys = try await http.get(CloudAgentIdentityHTTP.jwksURL)
            }
            try Task.checkCancellation()
            return try verifier.verify(tokens.idToken, jwks: keys, discovery: discovery,
                                       clientID: registration.clientID, nonce: grant.expectedNonce, now: now())
        case .grokBot:
            let tokens = try JSONDecoder().decode(XIdentityTokens.self, from: tokenData)
            guard tokens.tokenType.lowercased() == "bearer", !tokens.accessToken.isEmpty,
                  tokens.accessToken.utf8.count <= 16_384,
                  tokens.accessToken.utf8.allSatisfy({ (33...126).contains($0) }),
                  tokens.expiresIn.isFinite, tokens.expiresIn > 0,
                  Set(tokens.scope.split(separator: " ").map(String.init)).isSuperset(of: ["users.read", "tweet.read"]) else {
                throw CloudAgentIdentityError.invalidResponse
            }
            var request = URLRequest(url: CloudAgentIdentityHTTP.xMeURL)
            request.setValue("Bearer " + tokens.accessToken, forHTTPHeaderField: "Authorization")
            let profile = try JSONDecoder().decode(XCurrentUser.self, from: await http.perform(request))
            try Task.checkCancellation()
            guard profile.errors?.isEmpty != false, let id = profile.data?.id,
                  (1...32).contains(id.count), id.utf8.allSatisfy({ (48...57).contains($0) }) else {
                throw CloudAgentIdentityError.invalidIdentity
            }
            let current = now()
            // Access is used only for the documented current-user request and
            // discarded. No offline scope/refresh token/session is persisted.
            return try CloudAgentVerifiedIdentity(provider: .grokBot, issuer: "https://api.x.com", clientID: registration.clientID,
                                                  subject: id, verifiedAt: current,
                                                  identityExpiresAt: current.addingTimeInterval(min(tokens.expiresIn, 7_200)))
        }
    }
}

private struct OpenAIIdentityTokens: Decodable {
    let idToken: String
    enum CodingKeys: String, CodingKey { case idToken = "id_token" }
}
private struct XIdentityTokens: Decodable {
    let accessToken: String; let tokenType: String; let expiresIn: Double; let scope: String
    enum CodingKeys: String, CodingKey { case accessToken = "access_token", tokenType = "token_type", expiresIn = "expires_in", scope }
}
private struct XCurrentUser: Decodable {
    struct User: Decodable { let id: String }
    struct Failure: Decodable {}
    let data: User?; let errors: [Failure]?
}
#endif
