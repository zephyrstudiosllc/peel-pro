import Foundation

struct PeelCompanyAccountConfiguration: Sendable {
    static let clientID = "com.zephyrstudiosllc.Peel"
    static let consentVersion = "2026-10-18.v1"
    let origin: URL
    let privacyURL: URL

    init?(origin: String, privacyURL: String) {
        guard let components = URLComponents(string: origin), Self.validHTTPS(components),
              components.path.isEmpty || components.path == "/",
              let privacy = URLComponents(string: privacyURL), Self.validHTTPS(privacy),
              let policy = privacy.url,
              let host = components.host,
              let canonical = URL(string: "https://" + host.lowercased()) else { return nil }
        self.origin = canonical
        self.privacyURL = policy
    }

    init?(bundle: Bundle) {
#if os(macOS)
        return nil // Native Apple sign-in is unsupported in the Developer ID Host.
#else
        guard bundle.object(forInfoDictionaryKey: "PeelCompanyAccountEnabled") as? Bool == true,
              bundle.object(forInfoDictionaryKey: "PeelNativeAppleSignInEnabled") as? Bool == true,
              bundle.bundleIdentifier == Self.clientID,
              let origin = bundle.object(forInfoDictionaryKey: "PeelCompanyAccountOrigin") as? String,
              let privacy = bundle.object(forInfoDictionaryKey: "PeelCompanyAccountPrivacyURL") as? String else { return nil }
        self.init(origin: origin, privacyURL: privacy)
#endif
    }

    private static func validHTTPS(_ value: URLComponents) -> Bool {
        guard value.scheme == "https", value.user == nil, value.password == nil,
              value.query == nil, value.fragment == nil, value.port == nil || value.port == 443,
              let host = value.host, host.utf8.count <= 253, host.contains("."),
              host == host.lowercased(), ![".local", ".invalid", ".test", ".example", ".localhost"].contains(where: host.hasSuffix),
              !["example.com", "example.net", "example.org"].contains(where: { host == $0 || host.hasSuffix("." + $0) }),
              host.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }),
              !host.split(separator: ".").allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-")
        }
    }
}

struct PeelCompanyChallenge: Decodable, Sendable {
    let challenge_id: String
    let apple_nonce: String
    let expires_in: Int
    let client_id: String
    let consent_version: String
    var isValid: Bool {
        PeelCompanyValidation.opaque(challenge_id, maximum: 128)
            && PeelCompanyValidation.opaque(apple_nonce, maximum: 128)
            && (1...300).contains(expires_in)
            && client_id == PeelCompanyAccountConfiguration.clientID
            && consent_version == PeelCompanyAccountConfiguration.consentVersion
    }
}

struct PeelCompanyAccountProfile: Codable, Equatable, Sendable {
    let account_id: String
    let email: String?
    let email_collection_consent: Bool
    let marketing_consent: Bool
    let consent_version: String
    let marketing_delivery_configured: Bool
    var isValid: Bool {
        PeelCompanyValidation.opaque(account_id, maximum: 128)
            && consent_version == PeelCompanyAccountConfiguration.consentVersion
            && !marketing_consent && !marketing_delivery_configured
            && (email_collection_consent ? email.map(PeelCompanyValidation.email) == true : email == nil)
    }
}

struct PeelCompanySession: Codable, Sendable {
    let profile: PeelCompanyAccountProfile
    let bearer: String
    let appleUserID: String
    let origin: String
    let issuedAt: Date
    let expiresAt: Date
    func isValid(at now: Date, origin expectedOrigin: URL) -> Bool {
        profile.isValid && PeelCompanyValidation.bearer(bearer)
            && PeelCompanyValidation.text(appleUserID, maximum: 1024)
            && origin == expectedOrigin.absoluteString && issuedAt <= now.addingTimeInterval(60)
            && expiresAt > now && expiresAt > issuedAt && expiresAt.timeIntervalSince(issuedAt) <= 30 * 86_400
    }
}

struct PeelCompanySignInResponse: Decodable, Sendable {
    let account: PeelCompanyAccountProfile
    let session_token: String
    let expires_in: Int
}
struct PeelCompanyProfileResponse: Decodable, Sendable { let account: PeelCompanyAccountProfile }

struct PeelCompanyDeletionResponse: Decodable, Sendable {
    let account_deleted: Bool
    let apple_revocation_complete: Bool
    let apple_revocation_pending: Bool
    let manual_apple_revocation_required: Bool?
    func outcome(status: Int) throws -> PeelCompanyDeletionOutcome {
        guard account_deleted, !(apple_revocation_complete && apple_revocation_pending) else { throw PeelCompanyAccountError.invalidResponse }
        if status == 202, apple_revocation_pending, !apple_revocation_complete { return .pending }
        guard status == 200, !apple_revocation_pending else { throw PeelCompanyAccountError.invalidResponse }
        if apple_revocation_complete, manual_apple_revocation_required != true { return .complete }
        if !apple_revocation_complete, manual_apple_revocation_required == true { return .manualRevocation }
        throw PeelCompanyAccountError.invalidResponse
    }
}

enum PeelCompanyDeletionOutcome: String, Sendable { case complete, pending, manualRevocation, unconfirmed }

struct PeelCompanyDeletionIntent: Codable, Sendable {
    let appleUserID: String
    let origin: String
    let createdAt: Date
    let outcome: String
    var result: PeelCompanyDeletionOutcome? { PeelCompanyDeletionOutcome(rawValue: outcome) }
    func isValid(at now: Date, origin expected: URL) -> Bool {
        PeelCompanyValidation.text(appleUserID, maximum: 1024) && origin == expected.absoluteString
            && createdAt.timeIntervalSince1970.isFinite && createdAt <= now.addingTimeInterval(60) && result != nil
    }
}

enum PeelCompanyAccountError: Error, Equatable, LocalizedError {
    case notConfigured, unavailable, invalidResponse, unauthorized, freshAppleProofRequired
    case pendingRevocation, grantCapacity, verifiedEmailUnavailable, rateLimited, invalidRequest
    case redirectRejected, cancelled, expiredChallenge, invalidAuthorization, secureStorage
    var errorDescription: String? {
        switch self {
        case .notConfigured: "Company accounts are not available in this build yet."
        case .unavailable: "The account service is unavailable. Your local pairing is still available."
        case .invalidResponse, .invalidRequest: "The account request could not be verified."
        case .unauthorized: "The company session ended. You can choose to sign in again."
        case .freshAppleProofRequired: "Use a fresh Apple authorization to continue."
        case .pendingRevocation: "Apple authorization is awaiting revocation. Use account deletion or contact support; signing in again will not resolve this."
        case .grantCapacity: "This account has reached its Apple authorization limit. Use account deletion or contact support."
        case .verifiedEmailUnavailable: "Apple did not provide a verified email. You can try a fresh Apple flow or continue without saving email."
        case .rateLimited: "Too many account requests. Try again later."
        case .redirectRejected: "The account service address changed. No credentials were forwarded."
        case .cancelled: "Apple sign-in was canceled."
        case .expiredChallenge: "The Apple sign-in request expired. Start a fresh Apple flow."
        case .invalidAuthorization: "The Apple response did not match this request."
        case .secureStorage: "The company session could not be stored securely."
        }
    }
}

enum PeelCompanyValidation {
    static func text(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
    static func opaque(_ value: String, maximum: Int) -> Bool {
        text(value, maximum: maximum) && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
    static func bearer(_ value: String) -> Bool { value.utf8.count == 43 && opaque(value, maximum: 43) }
    static func email(_ value: String) -> Bool { text(value, maximum: 254) && value.contains("@") }
    static func identityToken(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return text(value, maximum: 16_384) && parts.count == 3
            && parts.allSatisfy { opaque(String($0), maximum: 16_384) }
    }
}

struct PeelCompanyAppleAuthorization: Sendable {
    let userID: String
    let state: String?
    let identityToken: String
    let authorizationCode: String?
    let localEmail: String? // Local Apple profile only. Never enters a network DTO.
}

struct PeelCompanyLocalIdentity: Sendable {
    let userID: String
    let email: String?
    let sessionID: UUID
}

@MainActor
protocol PeelCompanyAppleAuthorizing: AnyObject {
    func authorize(nonce: String, state: String, requestEmail: Bool) async throws -> PeelCompanyAppleAuthorization
    func cancel()
}

@MainActor
protocol PeelCompanySessionStorage {
    func load() throws -> PeelCompanySession?
    func save(_ session: PeelCompanySession) throws
    func remove() throws
    func loadDeletionIntent() throws -> PeelCompanyDeletionIntent?
    func saveDeletionIntent(_ intent: PeelCompanyDeletionIntent) throws
    func removeDeletionIntent() throws
}

@MainActor
protocol PeelCompanySessionFencing: AnyObject {
    var isDiscarded: Bool { get }
    func discard()
    func acceptVerifiedSession()
}

@MainActor
final class PeelCompanyMemorySessionFence: PeelCompanySessionFencing {
    private(set) var isDiscarded = false
    func discard() { isDiscarded = true }
    func acceptVerifiedSession() { isDiscarded = false }
}

@MainActor
final class PeelCompanyDefaultsSessionFence: PeelCompanySessionFencing {
    private let defaults: UserDefaults
    private let key = "peel.company.localSessionDiscarded.v1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var isDiscarded: Bool { defaults.bool(forKey: key) }
    func discard() { defaults.set(true, forKey: key) }
    func acceptVerifiedSession() { defaults.removeObject(forKey: key) }
}

@MainActor
protocol PeelCompanyAccountAPI {
    var configuration: PeelCompanyAccountConfiguration { get }
    func challenge() async throws -> PeelCompanyChallenge
    func signIn(challenge: String, identityToken: String, code: String, collectEmail: Bool, consentVersion: String) async throws -> PeelCompanySignInResponse
    func account(bearer: String) async throws -> PeelCompanyAccountProfile
    func withdrawEmail(bearer: String) async throws -> PeelCompanyAccountProfile
    func signOut(bearer: String) async throws
    func delete(bearer: String?, challenge: String?, identityToken: String?) async throws -> PeelCompanyDeletionOutcome
}
