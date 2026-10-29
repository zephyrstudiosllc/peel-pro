#if !os(watchOS)
import Foundation
import CryptoKit
import Security

/// Required native correlation of the actual enrolled WC peer. An implementation
/// is installed only after obtaining that Watch's signature on the server nonce
/// through its attributed native callback. WC flags/restored IDs are insufficient.
public protocol PluginRelayNativePeerVerifier: Sendable {
    func validateCurrent() throws
    func validate(_ callback: any PluginRelayNativePeerCallback) throws
}
public struct PluginRelayEnrolledWatchProof: Sendable {
    public let signature: String
    public let peer: any PluginRelayNativePeerVerifier
    public init(signature: String, peer: any PluginRelayNativePeerVerifier) { self.signature = signature; self.peer = peer }
}
public struct PluginRelayNativeEnrollment: Sendable {
    public let identity: CloudAgentVerifiedIdentity
    public let session: PluginRelayEnrolledPhoneSession
    let continuity: PluginRelayContinuityRecord
    init(identity: CloudAgentVerifiedIdentity, session: PluginRelayEnrolledPhoneSession, continuity: PluginRelayContinuityRecord) {
        self.identity = identity; self.session = session; self.continuity = continuity
    }
}
public struct PluginRelayPluginConsentReview: Sendable {
    public let transactionID: UUID
    public let provider: CloudAgentProvider
    public let clientID: String
    public let redirectURI: URL
    public let resource: URL
    public let requestedScopes: [String]
    public let expiresAt: Date
}

/// Real issuance adapter for the locked backend contract. The operator supplies
/// the approved HTTPS origin and own identity registration. No endpoint/client,
/// broker key, account, credential or device authority is invented by defaults.
public actor PluginRelayNativeBrokerClient {
    private let origin: URL
    private let configuration: URLSessionConfiguration
    private let proEvidence: (any PluginRelayProEvidenceSource)?
    private var operation: PluginRelayHTTPOperation?
    private var enrolling = false
    public init(trustedOrigin: URL, proEvidence: (any PluginRelayProEvidenceSource)? = nil) throws {
        guard let parts = URLComponents(url: trustedOrigin, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host?.isEmpty == false, parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443, parts.percentEncodedPath.isEmpty,
              parts.query == nil, parts.fragment == nil else { throw PluginRelayHTTPError.invalidConfiguration }
        origin = trustedOrigin; configuration = .ephemeral; self.proEvidence = proEvidence
    }
    /// No implicit retry after provider-code exchange uncertainty. The Watch
    /// signer must use the actual native paired-channel request and return its
    /// independently current peer verifier, not one derived from the signature.
    public func enroll(_ grant: CloudAgentOAuthCodeGrant, configuration identityConfig: CloudAgentIdentityConfiguration,
                       phoneKey: P256.Signing.PrivateKey, watchPublicKey: String, actualAgentReference: String,
                       signOnWatch: @Sendable (PluginRelayEnrollmentChallenge, String) async throws -> PluginRelayEnrolledWatchProof) async throws -> PluginRelayNativeEnrollment {
        guard !enrolling, operation == nil else { throw PluginRelayHTTPError.busy }
        enrolling = true; defer { enrolling = false }
        try Task.checkCancellation()
        guard grant.provider == identityConfig.registration.provider,
              grant.redirectURI == identityConfig.registration.redirectURI,
              grant.reportedIssuer == nil || (grant.provider == .dot && grant.reportedIssuer == "https://auth.openai.com"),
              PluginRelayValidation.opaque(actualAgentReference) else { throw PluginRelayHTTPError.invalidConfiguration }
        let phoneSPKI = PluginRelayEnrollmentCrypto.base64URL(phoneKey.publicKey.derRepresentation)
        _ = try PluginRelayEnrollmentCrypto.publicKey(watchPublicKey)
        let localEpoch = UUID()
        let challengeInput: [String: Any] = ["provider": grant.provider.rawValue,
            "transactionID": grant.transactionID.uuidString.lowercased(), "clientID": identityConfig.registration.clientID,
            "redirectURI": grant.redirectURI.absoluteString,
            "codeChallenge": PluginRelayEnrollmentCrypto.base64URL(Data(SHA256.hash(data: Data(grant.codeVerifier.utf8)))),
            "expectedNonce": grant.expectedNonce, "phonePublicKey": phoneSPKI,
            "watchPublicKey": watchPublicKey, "localEpoch": localEpoch.uuidString.lowercased()]
        let rawChallenge = try await request(path: "/v1/native/challenge", body: challengeInput)
        let fields = try rawChallenge.object(keys: ["challengeID", "challenge", "expiresAt"])
        let challenge = PluginRelayEnrollmentChallenge(challengeID: try Self.uuid(fields.required("challengeID")),
            challenge: try fields.required("challenge").string(), provider: grant.provider, transactionID: grant.transactionID,
            clientID: identityConfig.registration.clientID, redirectURI: grant.redirectURI.absoluteString,
            codeChallenge: challengeInput["codeChallenge"] as! String, expectedNonce: grant.expectedNonce,
            phonePublicKey: phoneSPKI, watchPublicKey: watchPublicKey, localEpoch: localEpoch,
            expiresAt: try fields.required("expiresAt").integer())
        let phoneSignature = try PluginRelayEnrollmentCrypto.sign(challenge, role: .phone, key: phoneKey, now: Date())
        let watchProof = try await signOnWatch(challenge, phoneSignature)
        try Task.checkCancellation(); try watchProof.peer.validateCurrent()
        try PluginRelayEnrollmentCrypto.verify(watchProof.signature, challenge: challenge, role: .watch, now: Date())
        // This exact challenge is consumed before the backend's ONE provider
        // redemption. A timeout here remains uncertain; never replay the code.
        let value = try await request(path: "/v1/native/session", body: ["challengeID": challenge.challengeID.uuidString.lowercased(),
            "code": grant.authorizationCode, "codeVerifier": grant.codeVerifier,
            "phoneSignature": phoneSignature, "watchSignature": watchProof.signature])
        try Task.checkCancellation(); try watchProof.peer.validateCurrent()
        let result = try value.object(keys: ["sessionToken", "sessionExpiresAt", "enrollmentID", "phoneDeviceID", "accountGeneration", "pairingGeneration", "localEpoch", "phoneKeySHA256", "watchKeySHA256", "grantedScopes", "identity", "refreshToken", "refreshExpiresAt", "applicationSessionExpiresAt", "provider"])
        let identityObject = try result.required("identity").object(keys: ["provider", "issuer", "clientID", "subject", "verifiedAt", "identityExpiresAt"])
        guard let provider = CloudAgentProvider(rawValue: try identityObject.required("provider").string()), provider == grant.provider else { throw PluginRelayHTTPError.invalidResponse }
        let identity = try CloudAgentVerifiedIdentity(provider: provider, issuer: identityObject.required("issuer").string(),
            clientID: identityObject.required("clientID").string(), subject: identityObject.required("subject").string(),
            verifiedAt: Self.date(identityObject.required("verifiedAt")), identityExpiresAt: Self.date(identityObject.required("identityExpiresAt")))
        let now = Date(), expiry = try Self.date(result.required("sessionExpiresAt"))
        let appExpiry = try Self.date(result.required("applicationSessionExpiresAt"))
        let refreshExpiry = try Self.date(result.required("refreshExpiresAt"))
        let phoneHash = PluginRelayEnrollmentCrypto.fingerprint(phoneKey.publicKey.derRepresentation)
        let watchHash = PluginRelayEnrollmentCrypto.fingerprint(try PluginRelayEnrollmentCrypto.publicKey(watchPublicKey).derRepresentation)
        guard identity.isCurrent(for: identityConfig, now: now), expiry > now,
              expiry <= now.addingTimeInterval(900), expiry <= appExpiry,
              appExpiry > now, appExpiry <= now.addingTimeInterval(604_830), refreshExpiry == appExpiry,
              try result.required("provider").string() == provider.rawValue,
              try Self.uuid(result.required("localEpoch")) == localEpoch,
              try result.required("phoneKeySHA256").string() == phoneHash,
              try result.required("watchKeySHA256").string() == watchHash,
              case .array(let scopes) = try result.required("grantedScopes"),
              scopes.count == 3,
              try Set(scopes.map({ try $0.string() })) == Set(["watch.connect", "watch.read", "watch.send"]) else { throw PluginRelayHTTPError.invalidResponse }
        let token = try result.required("sessionToken").string(), device = try result.required("phoneDeviceID").string()
        let refreshToken = try result.required("refreshToken").string()
        guard (try? PluginRelayEnrollmentCrypto.decodeBase64URL(token, maximum: 32).count) == 32,
              (try? PluginRelayEnrollmentCrypto.decodeBase64URL(refreshToken, maximum: 32).count) == 32, refreshToken != token,
              PluginRelayEnrollmentCrypto.ascii(device, maximum: 256) else { throw PluginRelayHTTPError.invalidResponse }
        let context = PluginRelayHTTPContext(provider: provider, accountGeneration: try Self.uuid(result.required("accountGeneration")),
            pairingEpoch: try Self.uuid(result.required("pairingGeneration")), localEpoch: localEpoch)
        let session = PluginRelayEnrolledPhoneSession(context: context, trustedOrigin: origin, actualAgentReference: actualAgentReference,
            token: token, expiry: expiry, enrollmentID: try Self.uuid(result.required("enrollmentID")), phoneDeviceID: device,
            phoneKey: phoneKey, watchKeySHA256: watchHash, peer: watchProof.peer, applicationSessionExpiresAt: appExpiry)
        let record = PluginRelayContinuityRecord(state: .ready, accessToken: token,
            accessExpiresAt: try result.required("sessionExpiresAt").integer(), refreshToken: refreshToken,
            refreshExpiresAt: try result.required("refreshExpiresAt").integer(), applicationExpiresAt: try result.required("applicationSessionExpiresAt").integer(),
            provider: provider, enrollmentID: session.enrollmentID, phoneDeviceID: device, accountGeneration: context.accountGeneration,
            pairingGeneration: context.pairingEpoch, localEpoch: localEpoch, phoneKeySHA256: phoneHash, watchKeySHA256: watchHash,
            watchPublicKey: watchPublicKey, origin: origin.absoluteString, identity: identity, fence: nil)
        return .init(identity: identity, session: session, continuity: record)
    }
    public func routeGrant(using session: PluginRelayEnrolledPhoneSession, fence: PluginRelayFence) async throws -> String {
        guard !enrolling, operation == nil, session.trustedOrigin == origin else { throw PluginRelayHTTPError.busy }
        try await ensurePro(using: session, fence: fence)
        try session.validateSession()
        let response = try await request(path: "/v1/native/route-grant", body: ["routeID": fence.binding.route.routeID,
            "localEpoch": fence.localEpoch.uuidString.lowercased()], session: session)
        try session.validateSession()
        let object = try response.object(keys: ["routeGrant"]), compact = try object.required("routeGrant").string()
        guard compact.utf8.count <= 8_192 else { throw PluginRelayHTTPError.invalidResponse }; return compact
    }
    /// Trusted review readback before native displays an explicit consent button.
    /// No target/client/provider claim from an incoming URL is used for consent.
    public func pluginReview(transactionID: UUID, using session: PluginRelayEnrolledPhoneSession) async throws -> PluginRelayPluginConsentReview {
        let response = try await request(path: "/v1/native/plugin/review", body: ["oauthTransactionID": transactionID.uuidString.lowercased()], session: session)
        let object = try response.object(keys: ["oauthTransactionID", "provider", "clientID", "redirectURI", "resource", "requestedScopes", "expiresAt"])
        guard try Self.uuid(object.required("oauthTransactionID")) == transactionID,
              let provider = CloudAgentProvider(rawValue: try object.required("provider").string()), provider == session.context.provider,
              case .array(let rawScopes) = try object.required("requestedScopes") else { throw PluginRelayHTTPError.invalidResponse }
        let scopes = try rawScopes.map { try $0.string() }, expiry = try Self.date(object.required("expiresAt"))
        let client = try object.required("clientID").string(), callback = try object.required("redirectURI").string()
        let resource = try object.required("resource").string()
        guard PluginRelayEnrollmentCrypto.ascii(client, maximum: 256), PluginRelayEnrollmentCrypto.ascii(callback, maximum: 2_048),
              let redirect = URL(string: callback), redirect.absoluteString == callback,
              redirect.scheme == "https", redirect.user == nil, redirect.password == nil, redirect.query == nil, redirect.fragment == nil,
              resource == origin.appendingPathComponent("mcp").absoluteString, let resourceURL = URL(string: resource),
              expiry > Date(), expiry <= Date().addingTimeInterval(600),
              Set(scopes) == ["agent.inbox", "agent.reply", "agent.confirm", "agent.subscribe"], scopes.count == 4 else { throw PluginRelayHTTPError.invalidResponse }
        return .init(transactionID: transactionID, provider: provider, clientID: client, redirectURI: redirect,
            resource: resourceURL, requestedScopes: scopes, expiresAt: expiry)
    }
    /// Invoke ONLY from the explicit native consent action after pluginReview.
    /// The returned one-time callback code stays in this URL, never WC or logs.
    public func approvePlugin(_ review: PluginRelayPluginConsentReview, fence: PluginRelayFence,
                              using session: PluginRelayEnrolledPhoneSession) async throws -> URL {
        guard review.expiresAt > Date(), review.provider == session.context.provider,
              fence.binding.route.accountGeneration == session.context.accountGeneration else { throw PluginRelayHTTPError.authorityChanged }
        let response = try await request(path: "/v1/native/plugin/approve", body: ["oauthTransactionID": review.transactionID.uuidString.lowercased(),
            "routeID": fence.binding.route.routeID], session: session)
        let object = try response.object(keys: ["authorizationRedirect", "expiresAt"])
        let expiry = try Self.date(object.required("expiresAt"))
        guard expiry > Date(), expiry <= Date().addingTimeInterval(60),
              let url = URLComponents(string: try object.required("authorizationRedirect").string()),
              let expected = URLComponents(url: review.redirectURI, resolvingAgainstBaseURL: false),
              url.scheme == expected.scheme, url.host == expected.host, url.port == expected.port,
              url.percentEncodedPath == expected.percentEncodedPath, url.user == nil, url.password == nil, url.fragment == nil,
              let items = url.queryItems, Set(items.map(\.name)) == ["code", "state", "iss"], items.count == 3,
              items.first(where: { $0.name == "iss" })?.value == origin.absoluteString,
              items.allSatisfy({ $0.value?.isEmpty == false }), let result = url.url else { throw PluginRelayHTTPError.invalidResponse }
        return result
    }
    public func cancelCurrent() { operation?.cancel() }

    /// Authentication-only signed paths obtain a separate finite commerce
    /// lease. Existing identity/currentness remains mandatory, never an isPro
    /// shortcut. No transaction JWS or trusted verdict is persisted here.
    public func ensurePro(using session: PluginRelayEnrolledPhoneSession, fence: PluginRelayFence? = nil,
                          force: Bool = false) async throws {
        guard !enrolling, operation == nil, session.trustedOrigin == origin else { throw PluginRelayHTTPError.busy }
        let binding = try session.proBinding(fence: fence)
        if !force, session.proRegistry.hasLease(binding: binding, minimumRemaining: 20) { return }
        guard let proEvidence else { throw PluginRelayProError.unavailable }
        enrolling = true; defer { enrolling = false }
        if let revision = session.proRegistry.pendingWithdrawal() {
            try await submitProWithdrawal(session, revision: revision)
        }
        let id = try session.proRegistry.begin(); defer { session.proRegistry.finish(id) }
        func current() -> Bool {
            !Task.isCancelled && session.proRegistry.isPending(id) &&
                (try? session.proBinding(fence: fence)) == binding
        }
        var body: [String: Any] = [:]
        if let route = binding.route { body = ["routeID": route.routeID, "routeGeneration": route.generation.uuidString.lowercased()] }
        let submission = PluginRelayProPendingSubmission(registry: session.proRegistry, operation: id)
        let raw = try await request(path: "/v1/native/pro/challenge", body: body, session: session, proSubmission: submission)
        guard current() else { throw PluginRelayProError.superseded }
        let challenge = try PluginRelayProWire.challenge(raw, expected: binding)
        let transactions = try await proEvidence.signedTransactions {
            session.proRegistry.isPending(id) && (try? session.proBinding(fence: fence)) == binding &&
                Date().timeIntervalSince1970 < Double(challenge.expiresAt) &&
                ProcessInfo.processInfo.systemUptime < challenge.monotonicDeadline
        }
        guard current(), Date().timeIntervalSince1970 < Double(challenge.expiresAt),
              ProcessInfo.processInfo.systemUptime < challenge.monotonicDeadline,
              transactions.count <= 4, Set(transactions).count == transactions.count,
              transactions.allSatisfy(Self.validProJWS) else { throw PluginRelayProError.superseded }
        let response = try await request(path: "/v1/native/pro/evidence", body: ["type": "proEntitlementProof",
            "requestId": challenge.requestID.uuidString.lowercased(), "nonce": challenge.nonce,
            "pairingId": challenge.pairingID.uuidString.lowercased(), "sessionId": challenge.sessionID.uuidString.lowercased(),
            "signedTransactions": transactions], session: session, proSubmission: submission)
        guard current() else { throw PluginRelayProError.superseded }
        let verified = try PluginRelayProWire.readback(response, challenge: challenge)
        try session.validateSession()
        try session.proRegistry.install(verified, operation: id)
    }
    public func withdrawPro(using session: PluginRelayEnrolledPhoneSession, revision: UUID) async throws {
        // A deferred flush NEVER creates another withdrawal. The caller closes
        // synchronously and carries that exact immutable revision through here.
        guard session.proRegistry.pendingWithdrawal() == revision else { return }
        try await submitProWithdrawal(session, revision: revision)
    }
    private func submitProWithdrawal(_ session: PluginRelayEnrolledPhoneSession, revision: UUID) async throws {
        let response = try await request(path: "/v1/native/pro/withdraw", body: [:], session: session,
            proSubmission: PluginRelayProWithdrawalSubmission(registry: session.proRegistry, revision: revision))
        let fields = try response.object(keys: ["withdrawn"])
        guard case .bool(true) = try fields.required("withdrawn") else { throw PluginRelayProError.invalidResponse }
        try session.proRegistry.acknowledgeWithdrawal(revision)
    }
    private static func validProJWS(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.utf8.count <= 32_768 else { return false }
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        } }
    }

    private func request(path: String, body: [String: Any], session: PluginRelayEnrolledPhoneSession? = nil,
                         proSubmission: (any PluginRelayHTTPSubmissionAdmission)? = nil,
                         renewalSigner: (@Sendable (Data) throws -> PluginRelayHTTPAuthorization)? = nil) async throws -> PluginRelayJSON {
        guard operation == nil else { throw PluginRelayHTTPError.busy }; try Task.checkCancellation()
        let bytes = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        guard bytes.count <= (path == "/v1/native/pro/evidence" ? 140_000 : 32_768) else { throw PluginRelayHTTPError.invalidConfiguration }
        var request = URLRequest(url: origin.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = "POST"; request.httpBody = bytes; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(String(bytes.count), forHTTPHeaderField: "Content-Length")
        let validate: @Sendable () throws -> Void
        let submission: (any PluginRelayHTTPSubmissionAdmission)?
        if let session {
            let scope: PluginRelayHTTPScope = path.hasPrefix("/v1/native/plugin/") ? .connect : .read
            let attachment = try session.authorization(for: session.context, scope: scope, trustedOrigin: origin,
                request: .init(method: "POST", path: path, body: bytes))
            for (name, value) in attachment.headers { request.setValue(value, forHTTPHeaderField: name) }
            validate = {
                try session.validateCurrent(attachment, scope: scope)
                if let proSubmission { try proSubmission.submit {} }
            }
            if let proSubmission { submission = proSubmission } else { submission = attachment.proPermit }
        } else if let renewalSigner {
            guard path == "/v1/native/renew", body.isEmpty else { throw PluginRelayHTTPError.invalidConfiguration }
            let renewal = try renewalSigner(bytes)
            guard renewal.expiresAt > Date() else { throw PluginRelayHTTPError.authorityChanged }
            for (name, value) in renewal.headers { request.setValue(value, forHTTPHeaderField: name) }
            validate = { guard renewal.expiresAt > Date() else { throw PluginRelayHTTPError.authorityChanged } }
            submission = nil
        } else { validate = {}; submission = nil } // Enrollment itself is authenticated by the dual signatures+provider code.
        let task = PluginRelayHTTPOperation(); operation = task; defer { operation = nil }
        let response = try await task.perform(request, configuration: configuration, timeout: 15,
            submission: submission, validateAuthority: validate)
        try Task.checkCancellation(); try validate()
        if response.status == 503, path.hasPrefix("/v1/native/pro/") { throw PluginRelayProError.unavailable }
        if response.status != 200, let fields = try? PluginRelayJSON.parse(response.body).object(keys: ["error"]),
           let code = try? fields.required("error").string() {
            if code == "pro_required" || code == "pro_expired" {
                session?.proRegistry.withdraw(); throw code == "pro_expired" ? PluginRelayProError.expired : PluginRelayProError.required
            }
            if code == "commerce_unavailable" { throw PluginRelayProError.unavailable }
        }
        guard response.status == 200 else { throw PluginRelayHTTPError.serviceRejected("native_connection_rejected") }
        return try PluginRelayJSON.parse(response.body)
    }
    private static func uuid(_ value: PluginRelayJSON) throws -> UUID {
        let raw = try value.string()
        guard let id = UUID(uuidString: raw), id.uuidString.lowercased() == raw else { throw PluginRelayHTTPError.invalidResponse }; return id
    }
    private static func date(_ value: PluginRelayJSON) throws -> Date {
        let number = try value.integer(); guard number >= 0 else { throw PluginRelayHTTPError.invalidResponse }
        return Date(timeIntervalSince1970: Double(number))
    }
}

private struct EnrolledPhonePeer: PluginRelayPhonePeerEvidence { let sessionID: UUID }

extension PluginRelayNativeBrokerClient: PluginRelayContinuityTransport {
    /// Refresh grants only this exact rotation endpoint. It cannot construct a
    /// normal HTTP/Watch authority lease or establish a native paired peer.
    public func rotate(_ input: PluginRelayContinuityRotationInput, phoneKey: P256.Signing.PrivateKey) async throws -> PluginRelayVerifiedContinuityRotation {
        guard !enrolling, operation == nil else { throw PluginRelayContinuityError.busy }
        enrolling = true; defer { enrolling = false }
        let old = input.record
        guard old.state == .rotationUncertain, old.origin == origin.absoluteString,
              old.refreshExpiresAt > (try PluginRelayEnrollmentCrypto.unixSeconds(Date())),
              old.applicationExpiresAt > (try PluginRelayEnrollmentCrypto.unixSeconds(Date())),
              old.phoneKeySHA256 == PluginRelayEnrollmentCrypto.fingerprint(phoneKey.publicKey.derRepresentation) else {
            throw PluginRelayContinuityError.explicitConnectRequired
        }
        let value = try await request(path: "/v1/native/renew", body: [:], renewalSigner: { bytes in
            var random = Data(count: 32)
            let status = random.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
            guard status == errSecSuccess else { throw PluginRelayHTTPError.invalidConfiguration }
            let nonce = PluginRelayEnrollmentCrypto.base64URL(random), timestamp = try PluginRelayEnrollmentCrypto.unixSeconds(Date())
            let proof = try PluginRelayHTTPRequestProof(method: "POST", path: "/v1/native/renew", body: bytes)
            let canonical = try proof.canonicalBytes(enrollmentID: old.enrollmentID.uuidString.lowercased(), unixSeconds: timestamp, nonce: nonce)
            let signature = PluginRelayEnrollmentCrypto.base64URL(try phoneKey.signature(for: canonical).derRepresentation)
            return .init(context: old.context, leaseID: UUID(), expiresAt: min(Date().addingTimeInterval(20), Date(timeIntervalSince1970: Double(old.refreshExpiresAt))),
                headers: ["authorization": "Bearer " + old.refreshToken, "x-peel-enrollment": old.enrollmentID.uuidString.lowercased(),
                    "x-peel-timestamp": String(timestamp), "x-peel-nonce": nonce, "x-peel-signature": signature])
        })
        let result = try value.object(keys: ["sessionToken", "sessionExpiresAt", "refreshToken", "refreshExpiresAt", "applicationSessionExpiresAt", "provider",
            "enrollmentID", "phoneDeviceID", "accountGeneration", "pairingGeneration", "localEpoch", "phoneKeySHA256", "watchKeySHA256", "grantedScopes"])
        let access = try result.required("sessionToken").string(), refresh = try result.required("refreshToken").string()
        let expiry = try result.required("sessionExpiresAt").integer(), refreshExpiry = try result.required("refreshExpiresAt").integer()
        let now = try PluginRelayEnrollmentCrypto.unixSeconds(Date())
        guard (try? PluginRelayEnrollmentCrypto.decodeBase64URL(access, maximum: 32).count) == 32,
              (try? PluginRelayEnrollmentCrypto.decodeBase64URL(refresh, maximum: 32).count) == 32,
              access != old.accessToken, refresh != old.refreshToken, access != refresh,
              expiry > now, expiry <= now + 900, expiry <= old.applicationExpiresAt,
              refreshExpiry == old.applicationExpiresAt,
              try result.required("applicationSessionExpiresAt").integer() == old.applicationExpiresAt,
              try result.required("provider").string() == old.provider.rawValue,
              try Self.uuid(result.required("enrollmentID")) == old.enrollmentID,
              try result.required("phoneDeviceID").string() == old.phoneDeviceID,
              try Self.uuid(result.required("accountGeneration")) == old.accountGeneration,
              try Self.uuid(result.required("pairingGeneration")) == old.pairingGeneration,
              try Self.uuid(result.required("localEpoch")) == old.localEpoch,
              try result.required("phoneKeySHA256").string() == old.phoneKeySHA256,
              try result.required("watchKeySHA256").string() == old.watchKeySHA256,
              case .array(let scopes) = try result.required("grantedScopes"), scopes.count == 3,
              try Set(scopes.map({ try $0.string() })) == ["watch.connect", "watch.read", "watch.send"] else {
            throw PluginRelayContinuityError.authorityChanged
        }
        var replacement = old; replacement.accessToken = access; replacement.accessExpiresAt = expiry
        replacement.refreshToken = refresh; replacement.refreshExpiresAt = refreshExpiry; replacement.state = .ready
        return .init(replacement)
    }
}

/// Concrete short-lived session registry created only by validated live issuance.
/// It signs exact requests with the enrolled phone key and never transfers its
/// bearer/private key to Watch. Local close clears all leases before any awaits.
public final class PluginRelayEnrolledPhoneSession: PluginRelayPhoneVerifiedSession, @unchecked Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let context: PluginRelayHTTPContext
    public let trustedOrigin: URL
    public let actualAgentReference: String
    public let enrollmentID: UUID
    public let phoneDeviceID: String
    public let watchKeySHA256: String
    public var phoneKeySHA256: String { PluginRelayEnrollmentCrypto.fingerprint(phoneKey.publicKey.derRepresentation) }
    public var expiresAt: Date { lock.lock(); defer { lock.unlock() }; return accessExpiry }
    public let applicationSessionExpiresAt: Date
    private var accessExpiry: Date
    private var accessMonotonicDeadline: TimeInterval
    private var suspended = false
    private var permanentlyRevoked = false
    private let phoneKey: P256.Signing.PrivateKey
    private var peer: any PluginRelayNativePeerVerifier
    private let id = UUID(), lock = NSLock()
    private var credential: String?
    private var bound: PluginRelayFence?
    let proRegistry = PluginRelayProRegistry()
    private struct HTTPLease {
        let scope: PluginRelayHTTPScope
        let expiry: Date
        let digest: String
        let paid: PluginRelayProPermit?
    }
    private struct PeerLease {
        let action: PluginRelayPhoneAction
        let expiry: Date
        let paid: PluginRelayProPermit?
    }
    private var httpLeases: [UUID: HTTPLease] = [:]
    private var peerLeases: [UUID: PeerLease] = [:]
    init(context: PluginRelayHTTPContext, trustedOrigin: URL, actualAgentReference: String,
                     token: String, expiry: Date, enrollmentID: UUID, phoneDeviceID: String,
                     phoneKey: P256.Signing.PrivateKey, watchKeySHA256: String, peer: any PluginRelayNativePeerVerifier,
                     applicationSessionExpiresAt: Date? = nil) {
        self.context = context; self.trustedOrigin = trustedOrigin; self.actualAgentReference = actualAgentReference
        credential = token; accessExpiry = expiry
        accessMonotonicDeadline = ProcessInfo.processInfo.systemUptime + max(0, min(900, expiry.timeIntervalSinceNow))
        self.applicationSessionExpiresAt = applicationSessionExpiresAt ?? expiry
        self.enrollmentID = enrollmentID; self.phoneDeviceID = phoneDeviceID
        self.phoneKey = phoneKey; self.watchKeySHA256 = watchKeySHA256; self.peer = peer
    }
    public func validateSession() throws { lock.lock(); defer { lock.unlock() }; try current() }
    private func current() throws {
        guard !permanentlyRevoked, !suspended, credential != nil, accessExpiry > Date(),
              applicationSessionExpiresAt > Date(), ProcessInfo.processInfo.systemUptime < accessMonotonicDeadline else { throw PluginRelayHTTPError.authorityChanged }
        try peer.validateCurrent()
    }
    public func bind(_ fence: PluginRelayFence) throws {
        lock.lock(); defer { lock.unlock() }; try current()
        guard fence.binding.route.provider == context.provider, fence.binding.route.accountGeneration == context.accountGeneration,
              fence.binding.pairingEpoch == context.pairingEpoch, fence.localEpoch == context.localEpoch,
              bound == nil || bound == fence else { throw PluginRelayHTTPError.authorityChanged }
        try proRegistry.bind(fence); bound = fence
    }
    public func revokeLocal() {
        lock.lock(); defer { lock.unlock() }; permanentlyRevoked = true; suspended = true; credential = nil; bound = nil
        proRegistry.withdraw()
        httpLeases.removeAll(); peerLeases.removeAll()
    }
    public func peerEvidence(for callback: any PluginRelayNativePeerCallback) throws -> any PluginRelayPhonePeerEvidence {
        lock.lock(); defer { lock.unlock() }; try current(); try peer.validate(callback)
        guard bound != nil else { throw PluginRelayHTTPError.authorityChanged }; return EnrolledPhonePeer(sessionID: id)
    }
    public func authorize(_ action: PluginRelayPhoneAction, fence: PluginRelayFence,
                          peer: any PluginRelayPhonePeerEvidence) throws -> PluginRelayPhoneAuthorityLease {
        lock.lock(); defer { lock.unlock() }; try current()
        guard fence == bound, (peer as? EnrolledPhonePeer)?.sessionID == id else { throw PluginRelayHTTPError.authorityChanged }
        let paid = action.requiresPro ? try proRegistry.permit(binding: proBindingLocked(fence: fence)) : nil
        peerLeases = peerLeases.filter { $0.value.expiry > Date() }
        guard peerLeases.count < 128 else { throw PluginRelayHTTPError.busy }
        let lease = UUID(), expiry = min(accessExpiry, paid?.expiresAt ?? Date().addingTimeInterval(20))
        peerLeases[lease] = .init(action: action, expiry: expiry, paid: paid)
        return .init(id: lease, fence: fence, action: action, expiresAt: expiry, proPermit: paid)
    }
    public func validateCurrent(_ lease: PluginRelayPhoneAuthorityLease) throws {
        lock.lock(); defer { lock.unlock() }; try current()
        guard lease.fence == bound, let registered = peerLeases[lease.id], registered.action == lease.action,
              registered.expiry == lease.expiresAt, registered.paid?.id == lease.proPermit?.id,
              lease.expiresAt > Date() else { throw PluginRelayHTTPError.authorityChanged }
        if let paid = registered.paid { try paid.validate(for: lease.fence) }
    }
    public func authorization(for context: PluginRelayHTTPContext, scope: PluginRelayHTTPScope,
                              trustedOrigin: URL) throws -> PluginRelayHTTPAuthorization {
        throw PluginRelayHTTPError.invalidConfiguration // Production never permits bearer-only requests.
    }
    public func authorization(for context: PluginRelayHTTPContext, scope: PluginRelayHTTPScope,
                              trustedOrigin: URL, request: PluginRelayHTTPRequestProof) throws -> PluginRelayHTTPAuthorization {
        lock.lock(); defer { lock.unlock() }; try current()
        guard context == self.context, trustedOrigin == self.trustedOrigin, let credential else { throw PluginRelayHTTPError.authorityChanged }
        let expected: PluginRelayHTTPScope
        switch request.path {
        case "/v1/watch/connect", "/v1/watch/disconnect", "/v1/native/plugin/review", "/v1/native/plugin/approve": expected = .connect
        case "/v1/watch/send": expected = .send
        default: expected = .read
        }
        guard scope == expected else { throw PluginRelayHTTPError.authorityChanged }
        let needsPro = ["/v1/watch/connect", "/v1/watch/status", "/v1/watch/send", "/v1/watch/replies", "/v1/native/route-grant"].contains(request.path)
        let paid = needsPro ? try proRegistry.permit(binding: proBindingLocked(fence: bound)) : nil
        httpLeases = httpLeases.filter { $0.value.expiry > Date() }; guard httpLeases.count < 128 else { throw PluginRelayHTTPError.busy }
        var random = Data(count: 32)
        let status = random.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw PluginRelayHTTPError.invalidConfiguration }
        let nonce = PluginRelayEnrollmentCrypto.base64URL(random), timestamp = try PluginRelayEnrollmentCrypto.unixSeconds(Date())
        let canonical = try request.canonicalBytes(enrollmentID: enrollmentID.uuidString.lowercased(), unixSeconds: timestamp, nonce: nonce)
        let signature = PluginRelayEnrollmentCrypto.base64URL(try phoneKey.signature(for: canonical).derRepresentation)
        let headers = ["authorization": "Bearer " + credential,
            "x-peel-enrollment": enrollmentID.uuidString.lowercased(), "x-peel-timestamp": String(timestamp),
            "x-peel-nonce": nonce, "x-peel-signature": signature]
        let lease = UUID(), expiry = min(accessExpiry, paid?.expiresAt ?? Date().addingTimeInterval(20))
        httpLeases[lease] = .init(scope: scope, expiry: expiry, digest: Self.headerDigest(headers), paid: paid)
        return .init(context: context, leaseID: lease, expiresAt: expiry, headers: headers, proPermit: paid)
    }
    public func validateCurrent(_ authorization: PluginRelayHTTPAuthorization, scope: PluginRelayHTTPScope) throws {
        lock.lock(); defer { lock.unlock() }; try current()
        guard authorization.context == context, let lease = httpLeases[authorization.leaseID], lease.scope == scope,
              lease.expiry == authorization.expiresAt, lease.digest == Self.headerDigest(authorization.headers), authorization.expiresAt > Date() else { throw PluginRelayHTTPError.authorityChanged }
        if let paid = lease.paid { try paid.withAdmission {} }
    }
    func suspendForContinuity() {
        lock.lock(); defer { lock.unlock() }; suspended = true; proRegistry.retirePermits()
        httpLeases.removeAll(); peerLeases.removeAll()
    }
    func applyContinuity(_ value: PluginRelayContinuityRecord, peer: any PluginRelayNativePeerVerifier) throws {
        try peer.validateCurrent()
        lock.lock(); defer { lock.unlock() }
        guard !permanentlyRevoked, value.state == .ready, value.context == context, value.origin == trustedOrigin.absoluteString,
              value.enrollmentID == enrollmentID, value.phoneDeviceID == phoneDeviceID,
              value.watchKeySHA256 == watchKeySHA256,
              value.phoneKeySHA256 == PluginRelayEnrollmentCrypto.fingerprint(phoneKey.publicKey.derRepresentation),
              Date(timeIntervalSince1970: Double(value.applicationExpiresAt)) == applicationSessionExpiresAt,
              Date(timeIntervalSince1970: Double(value.accessExpiresAt)) > Date() else { throw PluginRelayContinuityError.authorityChanged }
        credential = value.accessToken; accessExpiry = Date(timeIntervalSince1970: Double(value.accessExpiresAt))
        accessMonotonicDeadline = ProcessInfo.processInfo.systemUptime + max(0, min(900, accessExpiry.timeIntervalSinceNow))
        self.peer = peer; proRegistry.retirePermits(); httpLeases.removeAll(); peerLeases.removeAll(); suspended = false
    }
    func proBinding(fence: PluginRelayFence? = nil) throws -> PluginRelayProBinding {
        lock.lock(); defer { lock.unlock() }; try current(); return try proBindingLocked(fence: fence ?? bound)
    }
    private func proBindingLocked(fence: PluginRelayFence?) throws -> PluginRelayProBinding {
        var value = PluginRelayProBinding(provider: context.provider, accountGeneration: context.accountGeneration,
            enrollmentID: enrollmentID, phoneDeviceID: phoneDeviceID,
            phoneKeySHA256: PluginRelayEnrollmentCrypto.fingerprint(phoneKey.publicKey.derRepresentation), watchKeySHA256: watchKeySHA256,
            pairingGeneration: context.pairingEpoch, localEpoch: context.localEpoch, route: nil,
            applicationSessionExpiresAt: try PluginRelayEnrollmentCrypto.unixSeconds(applicationSessionExpiresAt))
        if let fence {
            guard bound == nil || bound == fence else { throw PluginRelayProError.contextChanged }
            value = try value.adding(fence)
        }
        return value
    }
    @discardableResult
    public func withdrawProLocally() -> UUID {
        // Separate from identity invalidation: evidence renewal and authenticated
        // cleanup remain available, while all old cloud effects close now.
        proRegistry.withdraw(needsRemoteAcknowledgement: true)!
    }
    public func isProWithdrawalPending(_ revision: UUID) -> Bool { proRegistry.pendingWithdrawal() == revision }
    /// UX readback only; callers still need captured permits at each effect.
    public func hasCurrentPro() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard (try? current()) != nil, let binding = try? proBindingLocked(fence: bound) else { return false }
        return proRegistry.hasLease(binding: binding, minimumRemaining: 0)
    }
    private static func headerDigest(_ headers: [String: String]) -> String {
        let framed = headers.keys.sorted().map { "\($0.utf8.count):\($0)\(headers[$0]!.utf8.count):\(headers[$0]!)" }.joined()
        return PluginRelayEnrollmentCrypto.fingerprint(Data(framed.utf8))
    }
    public var description: String { "PluginRelayEnrolledPhoneSession(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["context": context, "enrollmentID": enrollmentID]) }
}
#endif
