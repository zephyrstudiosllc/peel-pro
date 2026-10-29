#if os(iOS)
import Foundation
import CryptoKit
import WatchConnectivity
import Security
import PeelWatchCore

/// Actual native paired-channel verifier, enabled only after the current Watch
/// answered the server's challenge with its enrolled private key. Native pair
/// callbacks synchronously revoke it through the bridge before replacement.
private final class PeelCloudAgentEnrolledWatchPeer: PluginRelayNativePeerVerifier, @unchecked Sendable {
    private let lock = NSLock()
    private let channel: ObjectIdentifier
    private let directory: URL
    private var enabled = true
    init(channel: ObjectIdentifier, directory: URL) { self.channel = channel; self.directory = directory }
    func revoke() { lock.lock(); defer { lock.unlock() }; enabled = false }
    func validateCurrent() throws {
        lock.lock(); defer { lock.unlock() }; guard enabled else { throw PluginRelayEnrollmentError.revoked }
    }
    func validate(_ callback: any PluginRelayNativePeerCallback) throws {
        lock.lock(); defer { lock.unlock() }
        guard enabled, let callback = callback as? PeelCloudAgentWatchCallback,
              callback.channelIdentity == channel, callback.pairedDirectory == directory else { throw PluginRelayEnrollmentError.wrongPeer }
    }
}

/// Uses the existing WC delegate via sendMessageData replies; it never replaces
/// that delegate. Public-key discovery is not enrollment. Only a verified
/// server-challenge signature can create a current peer verifier below.
@MainActor
final class PeelCloudAgentWatchEnrollmentBridge {
    private let session: WCSession
    private var generation = UUID()
    private var publicKey: String?
    private var directory: URL?
    private var peers: [CloudAgentProvider: PeelCloudAgentEnrolledWatchPeer] = [:]
    private var pending: (UUID, CheckedContinuation<Data, Error>, Task<Void, Never>)?
    init(session: WCSession = .default) { self.session = session }

    func watchPublicKey() async throws -> String {
        let current = try currentDirectory()
        if let directory, directory != current { pairedWatchDidChange() }
        let token = generation
        let request = try PluginRelayEnrollmentWire(courierID: UUID(), kind: .keyRequest)
        let response = try await exchange(request)
        guard token == generation, try currentDirectory() == current, response.kind == .keyResponse,
              let key = response.publicKey else { throw PluginRelayEnrollmentError.wrongPeer }
        if let publicKey, publicKey != key { revokeAll() }
        publicKey = key; directory = current; return key
    }
    func sign(_ challenge: PluginRelayEnrollmentChallenge, phoneSignature: String) async throws -> PluginRelayEnrolledWatchProof {
        let current = try currentDirectory(), token = generation
        guard directory == current, publicKey == challenge.watchPublicKey else { throw PluginRelayEnrollmentError.wrongPeer }
        let request = try PluginRelayEnrollmentWire(courierID: UUID(), kind: .signChallenge, challenge: challenge, phoneSignature: phoneSignature)
        let response = try await exchange(request)
        guard token == generation, try currentDirectory() == current, response.kind == .signatureResponse,
              response.challengeID == challenge.challengeID, let signature = response.watchSignature else { throw PluginRelayEnrollmentError.wrongPeer }
        try PluginRelayEnrollmentCrypto.verify(signature, challenge: challenge, role: .watch, now: Date())
        peers[challenge.provider]?.revoke()
        let peer = PeelCloudAgentEnrolledWatchPeer(channel: ObjectIdentifier(session), directory: current)
        peers[challenge.provider] = peer
        return .init(signature: signature, peer: peer)
    }
    func freshPeer(_ challenge: PluginRelayWatchResumeChallenge, signature: String,
                   callback: PeelCloudAgentWatchCallback) throws -> any PluginRelayNativePeerVerifier {
        let current = try currentDirectory()
        guard callback.nativeSession === session, callback.channelIdentity == ObjectIdentifier(session),
              callback.pairedDirectory == current else { throw PluginRelayEnrollmentError.wrongPeer }
        try challenge.verify(signature, role: .watch, now: Date())
        let provider = challenge.context.fence.binding.route.provider
        peers[provider]?.revoke()
        let peer = PeelCloudAgentEnrolledWatchPeer(channel: ObjectIdentifier(session), directory: current)
        peers[provider] = peer; directory = current
        return peer
    }
    func validateCallback(_ callback: PeelCloudAgentWatchCallback) throws {
        guard callback.nativeSession === session, callback.channelIdentity == ObjectIdentifier(session),
              callback.pairedDirectory == (try currentDirectory()) else { throw PluginRelayEnrollmentError.wrongPeer }
    }
    func requestResume(_ provider: CloudAgentProvider) async throws {
        let response = try await exchange(.init(courierID: UUID(), kind: .resumeRequest, provider: provider))
        guard response.kind == .resumeAcknowledged, response.provider == provider else { throw PluginRelayEnrollmentError.wrongPeer }
    }
    func install(_ compact: String, grantID: UUID) async throws {
        let current = try currentDirectory(), token = generation
        let response = try await exchange(.init(courierID: UUID(), kind: .installGrant, routeGrant: compact))
        guard token == generation, try currentDirectory() == current, response.kind == .installed,
              response.grantID == grantID else { throw PluginRelayEnrollmentError.wrongPeer }
    }
    func invalidate(_ provider: CloudAgentProvider) async {
        peers.removeValue(forKey: provider)?.revoke()
        // Receiver closes its own active grant. No claim of remote work cancel.
        if let data = try? PluginRelayEnrollmentWire(courierID: UUID(), kind: .invalidate, provider: provider).encoded(), session.isReachable {
            session.sendMessageData(data, replyHandler: nil, errorHandler: nil)
        }
    }
    func pairedWatchDidChange() {
        generation = UUID(); revokeAll(); publicKey = nil; directory = nil
        if let pending { finish(pending.0, .failure(PluginRelayEnrollmentError.revoked)) }
    }
    private func revokeAll() { for peer in peers.values { peer.revoke() }; peers.removeAll() }
    private func currentDirectory() throws -> URL {
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
              session.isReachable, let directory = session.watchDirectoryURL else { throw PluginRelayEnrollmentError.wrongPeer }
        return directory
    }
    private func exchange(_ request: PluginRelayEnrollmentWire) async throws -> PluginRelayEnrollmentWire {
        try Task.checkCancellation()
        guard pending == nil else { throw PluginRelayPhoneRouteOwnerError.busy }
        _ = try currentDirectory(); let bytes = try request.encoded()
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: PluginRelayHTTPError.cancelled); return }
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
                    self?.finish(request.courierID, .failure(PluginRelayHTTPError.timeout))
                }
                pending = (request.courierID, continuation, timeout)
                session.sendMessageData(bytes, replyHandler: { [weak self] response in
                    Task { @MainActor in self?.finish(request.courierID, .success(response)) }
                }, errorHandler: { [weak self] _ in
                    Task { @MainActor in self?.finish(request.courierID, .failure(PluginRelayHTTPError.networkFailure)) }
                })
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(request.courierID, .failure(PluginRelayHTTPError.cancelled)) } }
        return try PluginRelayEnrollmentWire.decode(response, expectedCourierID: request.courierID)
    }
    private func finish(_ id: UUID, _ result: Result<Data, Error>) {
        guard let current = pending, current.0 == id else { return }
        pending = nil; current.2.cancel()
        switch result {
        case .success(let data) where data.isEmpty || data.count > PluginRelayEnrollmentWire.maximumBytes:
            current.1.resume(throwing: PluginRelayEnrollmentError.invalidInput)
        default: current.1.resume(with: result)
        }
    }
}

/// Concrete broker/Watch composition. The ONLY remaining agent handoff closure
/// is the actual approved Dot/Grok plugin authorization UI, whose registration
/// cannot be guessed. Core issuance/keys/callback verification are implemented.
@MainActor
final class PeelCloudAgentNativeBrokerConnector: PeelCloudAgentBrokerConnector {
    typealias AgentAuthorization = @MainActor (PluginRelayConnectResponse, PeelCloudAgentVerifiedEnrollment) async throws -> Void
    private let broker: PluginRelayNativeBrokerClient
    private let brokerGate = PluginRelayNativeBrokerOperationGate()
    private let trust: PluginRelayBrokerTrust
    private let watch: PeelCloudAgentWatchEnrollmentBridge
    private let phoneKey: P256.Signing.PrivateKey
    private let authorize: AgentAuthorization
    private let approvalURI: URL
    private let origin: URL
    private let vault: PeelCloudAgentBrokerCredentialStore
    private let bundle: Bundle
    private var controllers: [CloudAgentProvider: PluginRelayPhoneContinuityController] = [:]
    private var pendingRenewals: [UUID: (challenge: PluginRelayWatchResumeChallenge, callback: PeelCloudAgentWatchCallback, deadline: TimeInterval, generation: UUID)] = [:]
    private var generation = UUID()
    init(bundle: Bundle = .main, watch: PeelCloudAgentWatchEnrollmentBridge,
         authorizeAgent: @escaping AgentAuthorization) throws {
        guard let config = bundle.object(forInfoDictionaryKey: "PeelCloudBrokerRegistration") as? [String: String],
              Set(config.keys) == ["Origin", "Audience", "KeyID", "PublicKeySPKI", "ApprovalReference", "ApprovalURI"],
              let origin = config["Origin"].flatMap(URL.init(string:)), let audience = config["Audience"],
              let kid = config["KeyID"], let key = config["PublicKeySPKI"], let approval = config["ApprovalReference"],
              approval.utf8.count >= 8, !["example", "replace", "fixture", "synthetic", "todo"].contains(where: { approval.lowercased().contains($0) }),
              let approvalURI = config["ApprovalURI"].flatMap(URL.init(string:)), approvalURI.scheme == "https",
              approvalURI.host?.isEmpty == false, approvalURI.user == nil, approvalURI.password == nil,
              approvalURI.query == nil, approvalURI.fragment == nil,
              let bundleID = bundle.bundleIdentifier else { throw CloudAgentIdentityError.registrationRequired }
        trust = try .init(issuer: origin.absoluteString, audience: audience, keysSPKI: [kid: key])
        broker = try .init(trustedOrigin: origin, proEvidence: PeelCloudAgentProEvidenceController())
        self.watch = watch; authorize = authorizeAgent
        self.approvalURI = approvalURI; self.origin = origin; self.bundle = bundle
        let vault = try PeelCloudAgentBrokerCredentialStore(bundleID: bundleID)
        self.vault = vault
        let namespace = "phone_enrollment_signing_key_v1"
        if let bytes = try vault.load(namespace: namespace) { phoneKey = try .init(rawRepresentation: bytes) }
        else {
            let generated = P256.Signing.PrivateKey(); try vault.save(generated.rawRepresentation, namespace: namespace)
            phoneKey = generated
        }
    }
    func complete(_ grant: CloudAgentOAuthCodeGrant, configuration: CloudAgentIdentityConfiguration) async throws -> PeelCloudAgentVerifiedEnrollment {
        let operation = try brokerGate.begin(grant.provider)
        defer { brokerGate.finish(operation) }
        let key = try await watch.watchPublicKey()
        try brokerGate.validate(operation)
        let value = try await broker.enroll(grant, configuration: configuration, phoneKey: phoneKey, watchPublicKey: key,
            actualAgentReference: grant.provider == .dot ? "Dot" : "Grok Bot") { [watch] challenge, signature in
                try await watch.sign(challenge, phoneSignature: signature)
            }
        try brokerGate.validate(operation)
        let controller = try controller(grant.provider, configuration: configuration)
        try await controller.install(value)
        try brokerGate.validate(operation)
        return .init(identity: value.identity, session: value.session)
    }
    func authorizeAgent(_ response: PluginRelayConnectResponse, enrollment: PeelCloudAgentVerifiedEnrollment) async throws {
        try await authorize(response, enrollment)
    }
    func ensurePro(_ enrollment: PeelCloudAgentVerifiedEnrollment, fence: PluginRelayFence?, force: Bool) async throws {
        let provider = enrollment.session.context.provider
        let operation = try brokerGate.begin(provider)
        defer { brokerGate.finish(operation) }
        guard let session = enrollment.session as? PluginRelayEnrolledPhoneSession else { throw PluginRelayEnrollmentError.wrongPeer }
        try await broker.ensurePro(using: session, fence: fence, force: force)
        try brokerGate.validate(operation)
    }
    func withdrawPro(_ enrollment: PeelCloudAgentVerifiedEnrollment, revision: UUID) async throws {
        guard let session = enrollment.session as? PluginRelayEnrolledPhoneSession else { throw PluginRelayEnrollmentError.wrongPeer }
        guard session.isProWithdrawalPending(revision) else { return }
        let operation = try brokerGate.begin(session.context.provider)
        defer { brokerGate.finish(operation) }
        guard session.isProWithdrawalPending(revision) else { return }
        try await broker.withdrawPro(using: session, revision: revision)
        try brokerGate.validate(operation)
    }
    func publishRoute(_ fence: PluginRelayFence, enrollment: PeelCloudAgentVerifiedEnrollment) async throws {
        let operation = try brokerGate.begin(fence.binding.route.provider)
        defer { brokerGate.finish(operation) }
        guard let session = enrollment.session as? PluginRelayEnrolledPhoneSession else { throw PluginRelayEnrollmentError.wrongPeer }
        let compact = try await broker.routeGrant(using: session, fence: fence)
        let expected = try PluginRelayWatchBootstrapExpectation(provider: fence.binding.route.provider, localEpoch: fence.localEpoch,
            phoneKeySHA256: PluginRelayEnrollmentCrypto.fingerprint(phoneKey.publicKey.derRepresentation), watchKeySHA256: session.watchKeySHA256)
        let grant = try PluginRelayWatchBootstrapVerifier.verify(compact, trust: trust, expected: expected, now: Date())
        guard grant.fence == fence, grant.enrollmentID == session.enrollmentID, grant.phoneDeviceID == session.phoneDeviceID else { throw PluginRelayEnrollmentError.wrongPeer }
        try brokerGate.validate(operation)
        try await watch.install(compact, grantID: grant.grantID)
        try brokerGate.validate(operation)
    }
    func invalidate(_ provider: CloudAgentProvider) async throws {
        pendingRenewals = pendingRenewals.filter { $0.value.challenge.context.fence.binding.route.provider != provider }
        // Reserve cancellation ownership synchronously before the actor hop.
        // Even if the old operation returns meanwhile, a replacement cannot
        // start until this exact cancellation barrier has finished.
        let cancellation = brokerGate.beginCancellation(provider)
        defer { if let cancellation { brokerGate.finishCancellation(cancellation) } }
        if cancellation != nil { await broker.cancelCurrent() }
        await watch.invalidate(provider)
        if let controller = controllers.removeValue(forKey: provider) { try await controller.invalidate(removeCredential: true) }
        else { try PeelCloudAgentContinuityPersistence(vault: vault, provider: provider).remove() }
    }
    func pairedWatchDidChange() { generation = UUID(); pendingRenewals.removeAll(); watch.pairedWatchDidChange() }
    private func controller(_ provider: CloudAgentProvider, configuration: CloudAgentIdentityConfiguration? = nil) throws -> PluginRelayPhoneContinuityController {
        if let controller = controllers[provider] { return controller }
        let registration: CloudAgentIdentityConfiguration
        if let configuration { registration = configuration }
        else {
            guard let entries = bundle.object(forInfoDictionaryKey: "PeelCloudIdentityRegistrations") as? [String: [String: String]],
                  let values = entries[provider.rawValue], let bundleID = bundle.bundleIdentifier else { throw CloudAgentIdentityError.registrationRequired }
            let schemes = (bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? [])
                .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
            registration = try .init(provider: provider, values: values, bundleID: bundleID, registeredURLSchemes: schemes)
        }
        let controller = try PluginRelayPhoneContinuityController(persistence: PeelCloudAgentContinuityPersistence(vault: vault, provider: provider),
            transport: broker, trustedOrigin: origin, registration: registration, phoneKey: phoneKey, trust: trust)
        controllers[provider] = controller; return controller
    }
    func savedSessionDeadline(_ provider: CloudAgentProvider) async throws -> Date {
        try await controller(provider).descriptor().applicationSessionExpiresAt
    }
    func requestWatchResume(_ provider: CloudAgentProvider) async throws { try await watch.requestResume(provider) }
    func didBindRoute(_ fence: PluginRelayFence) async throws { try await controller(fence.binding.route.provider).bind(fence) }
    func continuityContext(_ provider: CloudAgentProvider) async throws -> PluginRelayWatchResumeContext {
        let descriptor = try await controller(provider).descriptor()
        return try .init(issuer: origin.absoluteString, enrollmentID: descriptor.enrollmentID, phoneDeviceID: descriptor.phoneDeviceID,
            fence: descriptor.fence, phonePublicKey: PluginRelayEnrollmentCrypto.base64URL(phoneKey.publicKey.derRepresentation),
            watchPublicKey: descriptor.watchPublicKey)
    }
    func beginRenewal(_ context: PluginRelayWatchResumeContext, from callback: PeelCloudAgentWatchCallback) async throws -> (PluginRelayWatchResumeChallenge, String) {
        try watch.validateCallback(callback)
        let token = generation
        let expected = try await continuityContext(context.fence.binding.route.provider)
        guard token == generation, context == expected else { throw PluginRelayEnrollmentError.wrongPeer }
        pendingRenewals = pendingRenewals.filter { $0.value.challenge.context.fence.binding.route.provider != context.fence.binding.route.provider && $0.value.deadline > ProcessInfo.processInfo.systemUptime }
        var nonce = Data(count: 32)
        let status = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw PluginRelayEnrollmentError.invalidInput }
        let challenge = PluginRelayWatchResumeChallenge(challengeID: UUID(), nonce: PluginRelayEnrollmentCrypto.base64URL(nonce),
            expiresAt: try PluginRelayEnrollmentCrypto.unixSeconds(Date()) + 30, context: context)
        let signature = try challenge.sign(role: .phone, key: phoneKey, now: Date())
        pendingRenewals[challenge.challengeID] = (challenge, callback, ProcessInfo.processInfo.systemUptime + 30, token)
        return (challenge, signature)
    }
    func finishRenewal(_ challengeID: UUID, signature: String, from callback: PeelCloudAgentWatchCallback) async throws -> PluginRelayVerifiedPhoneRestoration {
        guard let pending = pendingRenewals.removeValue(forKey: challengeID), pending.generation == generation,
              pending.deadline > ProcessInfo.processInfo.systemUptime,
              pending.callback.channelIdentity == callback.channelIdentity, pending.callback.pairedDirectory == callback.pairedDirectory else { throw PluginRelayEnrollmentError.wrongPeer }
        // Admission is acquired BEFORE refreshAuthority can persist an
        // unusable marker. A busy other provider makes no checkpoint change.
        let operation = try brokerGate.begin(pending.challenge.context.fence.binding.route.provider)
        defer { brokerGate.finish(operation) }
        try watch.validateCallback(callback)
        let peer = try watch.freshPeer(pending.challenge, signature: signature, callback: callback)
        let restored = try await controller(pending.challenge.context.fence.binding.route.provider).refreshAuthority(from: peer)
        try brokerGate.validate(operation)
        guard pending.generation == generation else { throw PluginRelayEnrollmentError.revoked }
        try watch.validateCallback(callback)
        return restored
    }
    func approvalTransaction(in url: URL) -> UUID? {
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let expected = URLComponents(url: approvalURI, resolvingAgainstBaseURL: false),
              value.scheme == expected.scheme, value.host == expected.host, value.port == expected.port,
              value.percentEncodedPath == expected.percentEncodedPath, value.user == nil, value.password == nil, value.fragment == nil,
              let items = value.queryItems, items.count == 1, items[0].name == "oauthTransactionID",
              let raw = items[0].value, let id = UUID(uuidString: raw), id.uuidString.lowercased() == raw else { return nil }
        return id
    }
    func pluginReview(transactionID: UUID, enrollment: PeelCloudAgentVerifiedEnrollment) async throws -> PluginRelayPluginConsentReview {
        guard let session = enrollment.session as? PluginRelayEnrolledPhoneSession else { throw PluginRelayEnrollmentError.wrongPeer }
        let operation = try brokerGate.begin(session.context.provider)
        defer { brokerGate.finish(operation) }
        let review = try await broker.pluginReview(transactionID: transactionID, using: session)
        try brokerGate.validate(operation)
        return review
    }
    func approvePlugin(_ review: PluginRelayPluginConsentReview, fence: PluginRelayFence,
                       enrollment: PeelCloudAgentVerifiedEnrollment) async throws -> URL {
        guard let session = enrollment.session as? PluginRelayEnrolledPhoneSession else { throw PluginRelayEnrollmentError.wrongPeer }
        let operation = try brokerGate.begin(session.context.provider)
        defer { brokerGate.finish(operation) }
        let result = try await broker.approvePlugin(review, fence: fence, using: session)
        try brokerGate.validate(operation)
        return result
    }
}
#endif
