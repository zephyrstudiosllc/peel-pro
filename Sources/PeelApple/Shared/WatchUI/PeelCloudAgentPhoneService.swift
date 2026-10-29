#if os(iOS)
import Foundation
import Combine
import PeelWatchCore
import AuthenticationServices
import UIKit
import Security

struct PeelCloudAgentPluginConsent: Identifiable {
    let id = UUID()
    let review: PluginRelayPluginConsentReview
    let fence: PluginRelayFence
    let handoffID: UUID
}

/// Phone-owned boundary for the primary ChatGPT/Dot and X/Grok Bot routes.
/// Connect must bind provider identity to a verified route for Watch messages
/// and replies. No generic model endpoint or unregistered callback is used.
@MainActor
final class PeelCloudAgentPhoneService: NSObject, ObservableObject {
    static let shared = PeelCloudAgentPhoneService()

    @Published private(set) var connections: [CloudAgentProvider: CloudAgentConnectionStatus] = [
        .dot: .notIntegrated(provider: .dot),
        .grokBot: .notIntegrated(provider: .grokBot)
    ]
    @Published private(set) var sessionDeadlines: [CloudAgentProvider: Date] = [:]
    @Published private(set) var signingInProvider: CloudAgentProvider?
    @Published private(set) var notices: [CloudAgentProvider: String] = [:]
    @Published private(set) var proNotices: [CloudAgentProvider: String] = [:]
    @Published private(set) var proVerifications: [CloudAgentProvider: UUID] = [:]
    private var proEvidenceCancellable: AnyCancellable?
    private var configurations: [CloudAgentProvider: CloudAgentIdentityConfiguration] = [:]
    private var configurationFailures: [CloudAgentProvider: String] = [:]
    private var identities: [CloudAgentProvider: CloudAgentVerifiedIdentity] = [:]
    private let coordinator = CloudAgentOAuthCoordinator()
    private let store = PeelCloudIdentityKeychain()
    private var browser: ASWebAuthenticationSession?
    private var operationID: UUID?
    private var transactionID: UUID?
    private var operation: Task<Void, Never>?
    private var authorizationDeadline: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var brokerConnector: (any PeelCloudAgentBrokerConnector)?
    private var relayOwners: [CloudAgentProvider: PluginRelayPhoneRouteOwner] = [:]
    private var enrollments: [CloudAgentProvider: PeelCloudAgentVerifiedEnrollment] = [:]
    private var relayDrains: [CloudAgentProvider: Task<Void, Never>] = [:]
    private var publishedRoutes: [CloudAgentProvider: PluginRelayFence] = [:]
    @Published private(set) var connectionStage: [CloudAgentProvider: String] = [:]
    @Published private(set) var pendingPluginConsent: PeelCloudAgentPluginConsent?
    private var setupProvider: CloudAgentProvider?
    @Published private(set) var agentHandoff: PeelCloudAgentHandoffPresentation?
    @Published private(set) var pluginConsentIsApproving = false
    private var initialSetupDeadlineUptime: TimeInterval?
    private var pendingPro: PendingPro?
    private final class PendingPro {
        let id = UUID()
        let operationID: UUID
        let provider: CloudAgentProvider
        let owner: PluginRelayPhoneRouteOwner
        let enrollment: PeelCloudAgentVerifiedEnrollment
        let sessionObject: AnyObject
        let deadlineUptime: TimeInterval
        var continuation: CheckedContinuation<Void, Error>?
        var retryTask: Task<Void, Never>?
        init(operationID: UUID, provider: CloudAgentProvider, owner: PluginRelayPhoneRouteOwner,
             enrollment: PeelCloudAgentVerifiedEnrollment, deadline: TimeInterval) {
            self.operationID = operationID; self.provider = provider; self.owner = owner; self.enrollment = enrollment
            sessionObject = enrollment.session as AnyObject; deadlineUptime = deadline
        }
    }
    private var pendingAgentHandoff: PendingAgentHandoff?
    private final class PendingAgentHandoff {
        let id: UUID, operationID: UUID
        let provider: CloudAgentProvider
        let owner: PluginRelayPhoneRouteOwner
        let enrollment: PeelCloudAgentVerifiedEnrollment
        let sessionObject: AnyObject
        let fence: PluginRelayFence
        let response: PluginRelayConnectResponse
        let deadlineUptime: TimeInterval
        var continuation: CheckedContinuation<Void, Error>?
        var checkTask: Task<Void, Never>?
        var checkID: UUID?
        var consentTask: Task<Void, Never>?
        var consentID: UUID?
        var approvingConsentID: UUID?
        init(id: UUID, operationID: UUID, provider: CloudAgentProvider, owner: PluginRelayPhoneRouteOwner,
             enrollment: PeelCloudAgentVerifiedEnrollment, fence: PluginRelayFence,
             response: PluginRelayConnectResponse, deadlineUptime: TimeInterval) {
            self.id = id; self.operationID = operationID; self.provider = provider; self.owner = owner
            self.enrollment = enrollment; sessionObject = enrollment.session as AnyObject
            self.fence = fence; self.response = response; self.deadlineUptime = deadlineUptime
        }
    }
    private var savedChecks: [CloudAgentProvider: UUID] = [:]
    private var relayGenerations: [CloudAgentProvider: UUID] = [:]
    private var renewals: [UUID: (provider: CloudAgentProvider, owner: PluginRelayPhoneRouteOwner?, pause: UUID?, generation: UUID?)] = [:]

    private override init() {
        super.init()
        let info = Bundle.main.infoDictionary ?? [:]
        let entries = info["PeelCloudIdentityRegistrations"] as? [String: [String: String]] ?? [:]
        let schemes = (info["CFBundleURLTypes"] as? [[String: Any]] ?? [])
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        for provider in [CloudAgentProvider.dot, .grokBot] {
            do {
                guard let values = entries[provider.rawValue], let bundleID = Bundle.main.bundleIdentifier else {
                    throw CloudAgentIdentityError.registrationRequired
                }
                let configuration = try CloudAgentIdentityConfiguration(provider: provider, values: values,
                    bundleID: bundleID, registeredURLSchemes: schemes)
                configurations[provider] = configuration
                connections[provider] = disconnected(provider)
                // Identity metadata alone never restores live account or peer
                // authority. The connector checks its phone-only checkpoint,
                // fresh Watch key proof and current signed broker grant later.
            } catch let error as CloudAgentIdentityError {
                configurationFailures[provider] = error.localizedDescription
            } catch {
                notices[provider] = CloudAgentIdentityError.secureStorageUnavailable.localizedDescription
            }
        }
        // PeelStore posts synchronously on the main actor before yielding to
        // finish/refresh. No dispatch scheduler may open a known-revocation gap.
        proEvidenceCancellable = NotificationCenter.default.publisher(for: PeelStore.proEvidenceDidChangeNotification)
            .sink { [weak self] _ in self?.proEvidenceDidChange() }
        scheduleIdentityExpiry()
    }

    func status(for provider: CloudAgentProvider) -> CloudAgentConnectionStatus {
        if let enrollment = enrollments[provider], enrollment.applicationDeadline <= Date() { return disconnected(provider) }
        if let enrollment = enrollments[provider], (try? enrollment.session.validateSession()) == nil {
            return disconnected(provider)
        }
        if let enrollment = enrollments[provider], let session = enrollment.session as? PluginRelayEnrolledPhoneSession,
           !session.hasCurrentPro() { return signedIn(enrollment.identity) }
        return connections[provider] ?? .notIntegrated(provider: provider)
    }

    func canCheckSavedConnection(for provider: CloudAgentProvider) -> Bool {
        configurations[provider] != nil && brokerConnector != nil && signingInProvider == nil
    }
    func canStartSignIn(for provider: CloudAgentProvider) -> Bool {
        configurations[provider] != nil && brokerConnector != nil && signingInProvider == nil
    }

    func setupDescription(for provider: CloudAgentProvider) -> String {
        if let failure = configurationFailures[provider] { return failure }
        if brokerConnector == nil {
            return "This build is waiting for Peel’s approved account and agent connection setup."
        }
        if let notice = proNotices[provider] { return notice }
        if let enrollment = enrollments[provider], let session = enrollment.session as? PluginRelayEnrolledPhoneSession,
           !session.hasCurrentPro() { return "Verify Peel Pro to use Watch cloud messages. Your account and saved messages are retained." }
        if status(for: provider).canSend {
            return provider == .dot ? "Dot is connected for new Watch messages and replies."
                : "Grok Bot is connected. Replies require Grok Bot to check its Peel inbox; automatic wake is not verified."
        }
        if let stage = connectionStage[provider] { return stage }
        if case .signedIn = status(for: provider).identity {
            return "Finish connecting \(provider == .dot ? "Dot" : "Grok Bot") to send and receive Watch messages."
        }
        switch provider {
        case .dot:
            return "Connect your ChatGPT account and Dot on this iPhone to send and receive Watch messages."
        case .grokBot:
            return "Connect your X account and Grok Bot on this iPhone to send and receive Watch messages."
        }
    }

    func startSignIn(for provider: CloudAgentProvider) {
        guard canStartSignIn(for: provider), let configuration = configurations[provider],
              let connector = brokerConnector else { return }
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .filter({ $0.activationState == .foregroundActive }).flatMap(\.windows).first(where: \.isKeyWindow) else {
            notices[provider] = "Open sign-in from an active iPhone window."
            return
        }
        let id = UUID()
        operationID = id; signingInProvider = provider; notices[provider] = nil
        connectionStage[provider] = "Signing in…"
        setupProvider = provider
        let previousRelayDrain = beginRelayInvalidation(provider)
        // A reauthentication cannot retain an old identity/conversation binding.
        identities[provider] = nil
        connections[provider] = CloudAgentConnectionStatus(provider: provider, identity: .authorizing,
            conversationCapability: .unavailable(.existingAgentAPIUnverified))
        do { try store.remove(namespace: configuration.storageNamespace) }
        catch { fail(provider, id: id, message: CloudAgentIdentityError.secureStorageUnavailable.localizedDescription); return }
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                await previousRelayDrain.value
                try Task.checkCancellation()
                guard operationID == id else { return }
                _ = connector // Retain this exact trusted adapter for the flow.
                let request = try await coordinator.begin(provider: provider, registeredRedirectURI: configuration.registration.redirectURI)
                guard operationID == id else { await coordinator.cancel(transactionID: request.transactionID); return }
                transactionID = request.transactionID
                let url = try configuration.registration.authorizationURL(for: request)
                let presentation = PeelCloudIdentityPresentationContext(window: window)
                let completion: ASWebAuthenticationSession.CompletionHandler = { [weak self, presentation] callback, error in
                    _ = presentation // Retain the exact presentation window for this session.
                    Task { @MainActor in self?.complete(callback: callback, error: error, provider: provider, id: id, configuration: configuration) }
                }
                let session: ASWebAuthenticationSession
                switch configuration.callback {
                case .customScheme(let scheme):
                    session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme, completionHandler: completion)
                case .https(let host, let path):
                    if #available(iOS 17.4, *) {
                        session = ASWebAuthenticationSession(url: url, callback: .https(host: host, path: path), completionHandler: completion)
                    } else {
                        // Never broaden an HTTPS registration to a scheme-only
                        // matcher or silently fall back to another callback.
                        throw CloudAgentIdentityError.unsupportedCallback
                    }
                }
                session.presentationContextProvider = presentation
                session.prefersEphemeralWebBrowserSession = true
                browser = session
                guard session.start() else { throw CloudAgentIdentityError.requestFailed }
                authorizationDeadline = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 600_000_000_000)
                    guard !Task.isCancelled, let self, operationID == id else { return }
                    cancelSignIn(message: "The sign-in session expired. Start again.")
                }
            } catch {
                fail(provider, id: id, message: "Sign-in could not be started. Try again.")
            }
        }
    }

    func cancelSignIn(message: String = "Sign-in was cancelled.") {
        guard let provider = signingInProvider else { return }
        let pending = transactionID
        if let handoff = pendingAgentHandoff { finishAgentHandoff(handoff.id, result: .failure(CancellationError())) }
        if let pending = pendingPro { finishPro(pending.id, result: .failure(CancellationError())) }
        initialSetupDeadlineUptime = nil; setupProvider = nil; pendingPluginConsent = nil
        operationID = nil; transactionID = nil; signingInProvider = nil
        operation?.cancel(); operation = nil
        authorizationDeadline?.cancel(); authorizationDeadline = nil
        browser?.cancel(); browser = nil
        _ = beginRelayInvalidation(provider)
        connectionStage[provider] = nil
        connections[provider] = disconnected(provider); notices[provider] = message
        if let pending { Task { await coordinator.cancel(transactionID: pending) } }
    }

    func signOut(_ provider: CloudAgentProvider) {
        if signingInProvider == provider { cancelSignIn() }
        _ = beginRelayInvalidation(provider)
        identities[provider] = nil; sessionDeadlines[provider] = nil
        connectionStage[provider] = nil
        connections[provider] = disconnected(provider)
        notices[provider] = nil
        if let configuration = configurations[provider] {
            do { try store.remove(namespace: configuration.storageNamespace) }
            catch { notices[provider] = CloudAgentIdentityError.secureStorageUnavailable.localizedDescription }
        }
        scheduleIdentityExpiry()
    }

    private func complete(callback: URL?, error: Error?, provider: CloudAgentProvider, id: UUID,
                          configuration: CloudAgentIdentityConfiguration) {
        guard operationID == id, let transaction = transactionID else { return }
        authorizationDeadline?.cancel(); authorizationDeadline = nil
        browser = nil
        if error != nil || callback == nil {
            let cancelled = (error as NSError?)?.domain == ASWebAuthenticationSessionErrorDomain
                && (error as NSError?)?.code == ASWebAuthenticationSessionError.canceledLogin.rawValue
            cancelSignIn(message: cancelled ? "Sign-in was cancelled." : "Sign-in could not be completed. Try again.")
            return
        }
        initialSetupDeadlineUptime = ProcessInfo.processInfo.systemUptime + 300
        authorizationDeadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 300_000_000_000) } catch { return }
            guard !Task.isCancelled, let self, operationID == id else { return }
            cancelSignIn(message: "The agent connection expired. Start again.")
        }
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                guard let connector = brokerConnector else { throw CloudAgentIdentityError.registrationRequired }
                let grant = try await coordinator.consumeCallback(callback!, transactionID: transaction)
                connectionStage[provider] = "Connecting your agent…"
                // The trusted adapter redeems this grant exactly once and verifies
                // provider identity PLUS broker session and actual peer enrollment.
                // Never redeem once locally and try to reuse the code at a broker.
                let enrollment = try await connector.complete(grant, configuration: configuration)
                try Task.checkCancellation()
                guard operationID == id else { enrollment.session.revokeLocal(); return }
                let identity = enrollment.identity
                guard identity.provider == provider, identity.isCurrent(for: configuration, now: Date()),
                      enrollment.session.context.provider == provider else { throw CloudAgentIdentityError.invalidIdentity }
                try enrollment.session.validateSession()
                let owner = try PeelCloudAgentRelayPersistence.makeOwner()
                enrollments[provider] = enrollment; relayOwners[provider] = owner
                sessionDeadlines[provider] = enrollment.applicationDeadline
                // Keep the SAME verified enrollment/operation pending for an
                // explicit purchase/restore/evidence retry. No reauthentication
                // or route/store creation occurs merely because Pro is denied.
                try await requireInitialPro(provider, owner: owner, enrollment: enrollment, connector: connector, operationID: id)
                let response = try await owner.connect(using: enrollment.session)
                try await connector.didBindRoute(try await owner.currentFence())
                try Task.checkCancellation()
                guard operationID == id else { _ = beginRelayInvalidation(provider); return }
                try store.save(identity, namespace: configuration.storageNamespace)
                identities[provider] = identity; connections[provider] = signedIn(identity)
                connectionStage[provider] = "Finish connecting in \(provider == .dot ? "Dot" : "Grok Bot")…"
                try await connector.authorizeAgent(response, enrollment: enrollment)
                try Task.checkCancellation()
                guard operationID == id else { _ = beginRelayInvalidation(provider); return }
                try await updateRelayStatus(provider, owner: owner, enrollment: enrollment, initialOperationID: id)
                notices[provider] = nil
                initialSetupDeadlineUptime = nil; setupProvider = nil
                operationID = nil; transactionID = nil; signingInProvider = nil; operation = nil
                authorizationDeadline?.cancel(); authorizationDeadline = nil
                scheduleIdentityExpiry()
            } catch {
                guard operationID == id else { return }
                if let enrollment = enrollments[provider], relayOwners[provider] != nil,
                   (try? enrollment.session.validateSession()) != nil {
                    connections[provider] = signedIn(enrollment.identity)
                    operationID = nil; transactionID = nil; signingInProvider = nil; operation = nil
                    authorizationDeadline?.cancel(); authorizationDeadline = nil
                    initialSetupDeadlineUptime = nil; setupProvider = nil
                    notices[provider] = "The agent connection needs attention. Connect again to finish setting it up."
                    scheduleIdentityExpiry()
                } else {
                    fail(provider, id: id, message: error is CancellationError ? "Connection was cancelled." : "The account and agent connection could not be verified. Try again.")
                }
            }
        }
    }

    private func fail(_ provider: CloudAgentProvider, id: UUID, message: String) {
        guard operationID == id else { return }
        cancelSignIn(message: message)
    }

    private func disconnected(_ provider: CloudAgentProvider) -> CloudAgentConnectionStatus {
        CloudAgentConnectionStatus(provider: provider, identity: .signedOut,
            conversationCapability: .unavailable(.existingAgentAPIUnverified))
    }

    private func signedIn(_ identity: CloudAgentVerifiedIdentity) -> CloudAgentConnectionStatus {
        guard let binding = try? identity.binding() else { return disconnected(identity.provider) }
        return CloudAgentConnectionStatus(provider: identity.provider, identity: .signedIn(binding),
            conversationCapability: .unavailable(.existingAgentAPIUnverified))
    }

    private func scheduleIdentityExpiry() {
        expiryTask?.cancel()
        guard let deadline = enrollments.values.map(\.applicationDeadline).min() else { return }
        let delay = max(0, min(deadline.timeIntervalSinceNow, 86_400))
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            guard let self else { return }
            let expired = enrollments.filter { $0.value.applicationDeadline <= Date() }.map(\.key)
            for provider in expired { signOut(provider); notices[provider] = "Connect again to renew your account session. Saved message IDs are retained." }
            scheduleIdentityExpiry()
        }
    }

    private func proMessage(_ error: Error) -> String {
        switch error as? PluginRelayProError {
        case .required, .denied, .expired:
            return "Peel Pro is required for Watch cloud messages. Purchase or restore, then verify Pro again. Your account and message IDs are retained."
        default:
            return "Peel Pro could not be verified. Check the connection and verify again; your account and saved messages are retained."
        }
    }
    private func requireInitialPro(_ provider: CloudAgentProvider, owner: PluginRelayPhoneRouteOwner,
                                   enrollment: PeelCloudAgentVerifiedEnrollment,
                                   connector: any PeelCloudAgentBrokerConnector, operationID id: UUID) async throws {
        do {
            try await connector.ensurePro(enrollment, fence: nil, force: false)
            try Task.checkCancellation()
            guard operationID == id else { throw CancellationError() }
            proNotices[provider] = nil; return
        } catch {
            guard error is PluginRelayProError, operationID == id,
                  let deadline = initialSetupDeadlineUptime else { throw error }
            let context = PendingPro(operationID: id, provider: provider, owner: owner, enrollment: enrollment, deadline: deadline)
            let contextID = context.id
            try validatePro(context)
            proNotices[provider] = proMessage(error)
            connectionStage[provider] = "Verify Peel Pro to finish connecting…"
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    do {
                        try validatePro(context)
                        guard pendingPro == nil else { throw PluginRelayProError.superseded }
                        context.continuation = continuation; pendingPro = context
                    } catch { continuation.resume(throwing: error) }
                }
            } onCancel: { Task { @MainActor [weak self] in self?.finishPro(contextID, result: .failure(CancellationError())) } }
        }
    }
    private func validatePro(_ context: PendingPro) throws {
        try Task.checkCancellation(); try context.enrollment.session.validateSession()
        let now = ProcessInfo.processInfo.systemUptime
        guard now.isFinite, now < context.deadlineUptime,
              operationID == context.operationID, signingInProvider == context.provider, setupProvider == context.provider,
              initialSetupDeadlineUptime == context.deadlineUptime,
              relayOwners[context.provider] === context.owner,
              let current = enrollments[context.provider], current.identity == context.enrollment.identity,
              (current.session as AnyObject) === context.sessionObject else { throw PluginRelayProError.superseded }
    }
    private func finishPro(_ id: UUID, result: Result<Void, Error>) {
        guard let context = pendingPro, context.id == id else { return }
        pendingPro = nil; context.retryTask?.cancel(); context.retryTask = nil
        proVerifications[context.provider] = nil
        let continuation = context.continuation; context.continuation = nil
        continuation?.resume(with: result)
    }
    func canVerifyPro(_ provider: CloudAgentProvider) -> Bool {
        guard proVerifications[provider] == nil, brokerConnector != nil, enrollments[provider] != nil else { return false }
        return signingInProvider == nil || pendingPro?.provider == provider
    }
    func retryProVerification(_ provider: CloudAgentProvider) {
        guard canVerifyPro(provider), let connector = brokerConnector else { return }
        if let context = pendingPro, context.provider == provider {
            do { try validatePro(context) } catch { finishPro(context.id, result: .failure(error)); return }
            let attempt = UUID(); proVerifications[provider] = attempt
            context.retryTask = Task { [weak self] in
                guard let self else { return }
                defer { if pendingPro === context, proVerifications[provider] == attempt {
                    proVerifications[provider] = nil; context.retryTask = nil
                } }
                do {
                    try validatePro(context)
                    try await connector.ensurePro(context.enrollment, fence: nil, force: true)
                    try validatePro(context)
                    guard pendingPro === context, proVerifications[provider] == attempt else { return }
                    proNotices[provider] = nil; finishPro(context.id, result: .success(()))
                } catch {
                    if pendingPro === context, proVerifications[provider] == attempt { proNotices[provider] = proMessage(error) }
                }
            }
            return
        }
        guard let enrollment = enrollments[provider] else { return }
        let generation = relayGenerations[provider], session = enrollment.session as AnyObject
        let attempt = UUID(); proVerifications[provider] = attempt
        Task { [weak self] in
            guard let self else { return }
            defer { if proVerifications[provider] == attempt { proVerifications[provider] = nil } }
            @MainActor func current() -> Bool {
                guard proVerifications[provider] == attempt, signingInProvider == nil,
                      generation == relayGenerations[provider], let value = enrollments[provider] else { return false }
                return (value.session as AnyObject) === session
            }
            do {
                guard current() else { return }
                let fence = try await relayOwners[provider]?.currentFence()
                guard current() else { return }
                try await connector.ensurePro(enrollment, fence: fence, force: true)
                guard current() else { return }
                proNotices[provider] = nil
                // Normal same-fence renewal, not a new identity or store epoch.
                await checkConnection(provider)
            } catch { if current() { proNotices[provider] = proMessage(error) } }
        }
    }
    private func proEvidenceDidChange() {
        // Close EVERY provider before launching any asynchronous withdrawal.
        // This observes actual verified evidence change, never hasProAccess.
        var withdrawals: [(PeelCloudAgentVerifiedEnrollment, UUID)] = []
        for (provider, enrollment) in enrollments {
            if let session = enrollment.session as? PluginRelayEnrolledPhoneSession {
                withdrawals.append((enrollment, session.withdrawProLocally()))
            }
            proNotices[provider] = "Purchase evidence changed. Verify Peel Pro again to resume cloud messages."
        }
        guard let connector = brokerConnector else { return }
        for (enrollment, revision) in withdrawals {
            Task { try? await connector.withdrawPro(enrollment, revision: revision) }
        }
    }

    /// Install only the reviewed production account/enrollment adapter. This is
    /// app composition, never a Settings text field, remote config or default grant.
    func installBrokerConnector(_ connector: any PeelCloudAgentBrokerConnector) async {
        if brokerConnector != nil {
            cancelSignIn()
            let drains = [CloudAgentProvider.dot, .grokBot].map(beginRelayInvalidation)
            for drain in drains { await drain.value }
        }
        brokerConnector = connector
        for provider in [CloudAgentProvider.dot, .grokBot] where configurations[provider] != nil {
            configurationFailures[provider] = nil
            // This date is display metadata only. It never changes connection
            // readiness or installs account/session/peer authority.
            sessionDeadlines[provider] = try? await connector.savedSessionDeadline(provider)
        }
    }

    private func beginRelayInvalidation(_ provider: CloudAgentProvider) -> Task<Void, Never> {
        if let pending = pendingPro, pending.provider == provider { finishPro(pending.id, result: .failure(PluginRelayProError.superseded)) }
        proVerifications[provider] = nil; proNotices[provider] = nil
        relayGenerations[provider] = UUID()
        savedChecks[provider] = nil
        renewals = renewals.filter { $0.value.provider != provider }
        if let handoff = pendingAgentHandoff, handoff.provider == provider {
            finishAgentHandoff(handoff.id, result: .failure(PluginRelayPhoneRouteOwnerError.superseded))
        }
        if pendingPluginConsent?.review.provider == provider { pendingPluginConsent = nil }
        let owner = relayOwners.removeValue(forKey: provider)
        publishedRoutes[provider] = nil
        let enrollment = enrollments.removeValue(forKey: provider)
        // Admission closes synchronously; a late operation cannot win an await.
        enrollment?.session.revokeLocal()
        let previous = relayDrains[provider]
        let connector = brokerConnector
        let drain = Task { [weak self] in
            await previous?.value
            var failed = false
            do { try await owner?.invalidate() } catch { failed = true }
            do { try await connector?.invalidate(provider) } catch { failed = true }
            if failed {
                self?.notices[provider] = "The connection closed locally. Its saved credentials could not be fully removed; reconnect after resolving secure storage."
            }
        }
        relayDrains[provider] = drain
        return drain
    }

    /// Invoke before reactivating/replacing the actual WC peer, on inactivity or
    /// Watch state change. Account/route replacement uses the same awaited drain.
    func pairedWatchDidChange() async {
        brokerConnector?.pairedWatchDidChange()
        cancelSignIn()
        let drains = [CloudAgentProvider.dot, .grokBot].map { provider in
            connections[provider] = disconnected(provider)
            connectionStage[provider] = nil
            return beginRelayInvalidation(provider)
        }
        for drain in drains { await drain.value }
    }

    func checkConnection(_ provider: CloudAgentProvider) async {
        guard signingInProvider == nil, savedChecks[provider] == nil, let connector = brokerConnector else { return }
        let token = UUID(), generation = relayGenerations[provider]
        savedChecks[provider] = token
        defer { if savedChecks[provider] == token { savedChecks[provider] = nil } }
        func isCurrentCheck() -> Bool {
            savedChecks[provider] == token && relayGenerations[provider] == generation
                && brokerConnector === connector && signingInProvider == nil
        }
        do {
            // The same generation may renew its owner/session during this
            // request. Capture the refreshed owner only after resume returns.
            try await connector.requestWatchResume(provider)
            guard isCurrentCheck(), let owner = relayOwners[provider], let enrollment = enrollments[provider] else { return }
            try await updateRelayStatus(provider, owner: owner, enrollment: enrollment)
            guard isCurrentCheck() else { return }
            notices[provider] = nil
        } catch {
            guard isCurrentCheck() else { return }
            if let enrollment = enrollments[provider], (try? enrollment.session.validateSession()) != nil {
                connections[provider] = signedIn(enrollment.identity)
                if error is PluginRelayProError { proNotices[provider] = proMessage(error) }
            } else { connections[provider] = disconnected(provider) }
            notices[provider] = "The connection needs a fresh check or Connect on iPhone. Saved message IDs and replies are retained."
        }
    }

    /// Explicit manual first-Connect. Copying instructions never grants readiness.
    func authorizeExistingAgent(_ response: PluginRelayConnectResponse,
                                enrollment: PeelCloudAgentVerifiedEnrollment) async throws {
        try Task.checkCancellation()
        guard pendingAgentHandoff == nil, let id = operationID, let provider = signingInProvider,
              provider == response.route.provider, setupProvider == provider,
              let owner = relayOwners[provider], let current = enrollments[provider],
              current.identity == enrollment.identity,
              (current.session as AnyObject) === (enrollment.session as AnyObject),
              let deadline = initialSetupDeadlineUptime,
              ProcessInfo.processInfo.systemUptime < deadline else { throw PluginRelayPhoneRouteOwnerError.superseded }
        let fence = try await owner.currentFence()
        let token = UUID()
        let context = PendingAgentHandoff(id: token, operationID: id, provider: provider, owner: owner,
            enrollment: enrollment, fence: fence, response: response, deadlineUptime: deadline)
        guard operationID == id, signingInProvider == provider, setupProvider == provider,
              relayOwners[provider] === owner, let current = enrollments[provider],
              current.identity == enrollment.identity, (current.session as AnyObject) === context.sessionObject,
              initialSetupDeadlineUptime == deadline, ProcessInfo.processInfo.systemUptime < deadline,
              fence.binding.route == response.route else { throw PluginRelayPhoneRouteOwnerError.superseded }
        try enrollment.session.validateSession()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled, operationID == id, signingInProvider == provider, setupProvider == provider,
                      pendingAgentHandoff == nil, relayOwners[provider] === owner,
                      let current = enrollments[provider], current.identity == enrollment.identity,
                      (current.session as AnyObject) === context.sessionObject,
                      initialSetupDeadlineUptime == deadline, ProcessInfo.processInfo.systemUptime < deadline else {
                    continuation.resume(throwing: CancellationError()); return
                }
                context.continuation = continuation; pendingAgentHandoff = context
                setupProvider = provider
                agentHandoff = .init(id: token, provider: provider, routeID: response.route.routeID)
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finishAgentHandoff(token, result: .failure(CancellationError())) } }
    }

    private func validateAgentHandoff(_ context: PendingAgentHandoff, foreground: Bool = true) throws {
        try Task.checkCancellation()
        let now = ProcessInfo.processInfo.systemUptime
        guard pendingAgentHandoff === context, context.continuation != nil,
              operationID == context.operationID, signingInProvider == context.provider, setupProvider == context.provider,
              relayOwners[context.provider] === context.owner,
              let current = enrollments[context.provider], current.identity == context.enrollment.identity,
              (current.session as AnyObject) === context.sessionObject,
              initialSetupDeadlineUptime == context.deadlineUptime, now.isFinite, now < context.deadlineUptime else {
            throw PluginRelayPhoneRouteOwnerError.superseded
        }
        try context.enrollment.session.validateSession()
        if foreground, UIApplication.shared.applicationState != .active { throw PluginRelayPhoneRouteOwnerError.inactive }
    }

    private func finishAgentHandoff(_ id: UUID, result: Result<Void, Error>) {
        guard let context = pendingAgentHandoff, context.id == id else { return }
        let continuation = context.continuation; context.continuation = nil
        pendingAgentHandoff = nil; agentHandoff = nil
        context.checkTask?.cancel(); context.checkTask = nil; context.checkID = nil
        context.consentTask?.cancel(); context.consentTask = nil; context.consentID = nil; context.approvingConsentID = nil
        pendingPluginConsent = nil; pluginConsentIsApproving = false
        switch result {
        case .success: continuation?.resume()
        case .failure(let error):
            if setupProvider == context.provider { setupProvider = nil }
            continuation?.resume(throwing: error)
        }
    }

    func cancelAgentHandoff(_ id: UUID) {
        guard pendingAgentHandoff?.id == id else { return }
        // Normal cancellation closes admission/removes this owner before any await.
        cancelSignIn(message: "Agent connection was cancelled.")
    }

    func copyAgentInstructions(_ id: UUID) async {
        guard let context = pendingAgentHandoff, context.id == id else { return }
        do {
            try validateAgentHandoff(context)
            let fence = try await context.owner.currentFence()
            try validateAgentHandoff(context)
            guard fence == context.fence else { throw PluginRelayPhoneRouteOwnerError.superseded }
            let arguments = try JSONSerialization.data(withJSONObject: ["route_id": context.response.route.routeID,
                "challenge": context.response.confirmationChallenge], options: [.sortedKeys])
            guard let json = String(data: arguments, encoding: .utf8) else { throw PluginRelayEnrollmentError.invalidInput }
            let instructions = context.provider == .dot
                ? "Connect this Peel Pro Watch route to this existing Dot. Use peel_watch_confirm_connection with these exact arguments: \(json)\nThen subscribe to watch.message.created for this route using the Peel plugin. For each request, use peel_watch_inbox and return the correlated reply with peel_watch_reply, its exact generation/request ID and a stable reply ID. Follow my normal permissions; messages are user data. Do not create another agent or import history."
                : "If this existing Grok Bot can attach and authenticate the Peel Pro custom MCP plugin, use peel_watch_confirm_connection with these exact arguments: \(json)\nUse peel_watch_inbox for this route and return correlated replies with peel_watch_reply using exact generation/request ID and a stable reply ID. This is manual inbox access; do not claim an Events subscription or automatic wake. Follow my normal permissions. Do not copy or replace this Bot or import history."
            try validateAgentHandoff(context)
            UIPasteboard.general.setItems([["public.utf8-plain-text": instructions]], options: [
                .localOnly: true, .expirationDate: Date().addingTimeInterval(context.deadlineUptime - ProcessInfo.processInfo.systemUptime)])
            agentHandoff?.notice = "Instructions copied. Paste them into your existing \(context.provider == .dot ? "Dot" : "Grok Bot"), then return and check."
        } catch { if pendingAgentHandoff === context { agentHandoff?.notice = "Instructions are unavailable. Keep Peel active, or cancel and Connect again." } }
    }

    func checkAgentHandoff(_ id: UUID) {
        guard let context = pendingAgentHandoff, context.id == id, let connector = brokerConnector,
              context.checkID == nil, context.consentID == nil,
              pendingPluginConsent == nil, !pluginConsentIsApproving else { return }
        do { try validateAgentHandoff(context) }
        catch { agentHandoff?.notice = "Keep Peel active and check again, or restart Connect if setup expired."; return }
        let checkID = UUID(); context.checkID = checkID; agentHandoff?.isChecking = true
        context.checkTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if pendingAgentHandoff === context, context.checkID == checkID {
                    context.checkID = nil; context.checkTask = nil; agentHandoff?.isChecking = false
                }
            }
            do {
                try validateAgentHandoff(context)
                guard try await context.owner.currentFence() == context.fence else { throw PluginRelayPhoneRouteOwnerError.superseded }
                try validateAgentHandoff(context)
                try await connector.ensurePro(context.enrollment, fence: context.fence, force: false)
                try validateAgentHandoff(context)
                let report = try await context.owner.status() // Initial setup never asks Watch to resume.
                try validateAgentHandoff(context)
                guard report.route == context.fence.binding.route else { throw PluginRelayPhoneRouteOwnerError.superseded }
                guard report.remoteReady else {
                    agentHandoff?.notice = context.provider == .dot ? "Finish plugin authorization, confirmation and the Dot subscription, then check again." : "Finish confirmation in the actual Bot's authenticated Peel plugin, then check again."
                    return
                }
                guard report.deliveryMode == (context.provider == .dot ? .events : .manual),
                      report.automaticDeliveryReady == (context.provider == .dot) else { throw PluginRelayHTTPError.invalidResponse }
                guard try await context.owner.currentFence() == context.fence else { throw PluginRelayPhoneRouteOwnerError.superseded }
                try validateAgentHandoff(context)
                // The pending closure finishes only after authenticated readiness.
                // Its original Connect task then publishes the verified Watch grant.
                finishAgentHandoff(context.id, result: .success(()))
            } catch {
                if pendingAgentHandoff === context {
                    if error is PluginRelayProError { proNotices[context.provider] = proMessage(error) }
                    agentHandoff?.notice = "The live connection could not be verified. Check again or cancel and Connect again."
                }
            }
        }
    }

    /// Incoming link supplies only a transaction ID. Consent remains reachable
    /// in the handoff sheet and is tied to this exact first-Connect context.
    func handlePluginApprovalURL(_ url: URL) {
        guard let context = pendingAgentHandoff, let connector = brokerConnector,
              context.consentID == nil, context.checkID == nil, pendingPluginConsent == nil,
              let transaction = connector.approvalTransaction(in: url) else { return }
        let consentID = UUID(); context.consentID = consentID
        context.consentTask = Task { [weak self] in
            guard let self else { return }
            defer { if pendingAgentHandoff === context, context.consentID == consentID {
                context.consentID = nil; context.consentTask = nil
            } }
            do {
                try validateAgentHandoff(context)
                let review = try await connector.pluginReview(transactionID: transaction, enrollment: context.enrollment)
                try validateAgentHandoff(context)
                guard try await context.owner.currentFence() == context.fence, review.provider == context.provider else { return }
                try validateAgentHandoff(context)
                guard pendingPluginConsent == nil else { return }
                pendingPluginConsent = .init(review: review, fence: context.fence, handoffID: context.id)
            } catch { if pendingAgentHandoff === context { agentHandoff?.notice = "The agent authorization request could not be verified. Restart it in your agent." } }
        }
    }
    func dismissPluginConsent(_ consentID: UUID, handoffID: UUID) {
        guard let context = pendingAgentHandoff, context.id == handoffID,
              let consent = pendingPluginConsent, consent.id == consentID, consent.handoffID == handoffID else { return }
        pendingPluginConsent = nil
    }
    func approvePluginConsent(_ consentID: UUID, handoffID: UUID) {
        guard let context = pendingAgentHandoff, context.id == handoffID,
              let consent = pendingPluginConsent, consent.id == consentID, consent.handoffID == handoffID,
              consent.review.provider == context.provider, consent.fence == context.fence,
              let connector = brokerConnector, !pluginConsentIsApproving,
              context.checkID == nil, context.consentID == nil else { return }
        do { try validateAgentHandoff(context) } catch { return }
        let authorizationID = UUID(); context.consentID = authorizationID; context.approvingConsentID = consentID
        pendingPluginConsent = nil; pluginConsentIsApproving = true
        context.consentTask = Task { [weak self] in
            guard let self else { return }
            defer { if pendingAgentHandoff === context, context.consentID == authorizationID {
                context.consentID = nil; context.consentTask = nil; context.approvingConsentID = nil
                pluginConsentIsApproving = false
            } }
            @MainActor func validateConsent(foreground: Bool = true) throws {
                try validateAgentHandoff(context, foreground: foreground)
                guard context.consentID == authorizationID, context.approvingConsentID == consentID,
                      context.id == handoffID else { throw PluginRelayPhoneRouteOwnerError.superseded }
            }
            do {
                try validateConsent()
                guard try await context.owner.currentFence() == context.fence else { throw PluginRelayEnrollmentError.wrongPeer }
                try validateConsent()
                let callback = try await connector.approvePlugin(consent.review, fence: context.fence, enrollment: context.enrollment)
                try validateConsent()
                let opened = await withCheckedContinuation { continuation in
                    UIApplication.shared.open(callback, options: [:]) { continuation.resume(returning: $0) }
                }
                try validateConsent(foreground: false)
                guard opened else { throw PluginRelayEnrollmentError.invalidInput }
            } catch { if pendingAgentHandoff === context { agentHandoff?.notice = "Agent authorization could not finish. Return here and retry from the agent." } }
        }
    }
    /// One foreground check per route; no timer or continuous background poll.
    func resumeConnections() async {
        for provider in [CloudAgentProvider.dot, .grokBot] {
            await checkConnection(provider)
        }
    }

    private func updateRelayStatus(_ provider: CloudAgentProvider, owner: PluginRelayPhoneRouteOwner,
                                   enrollment: PeelCloudAgentVerifiedEnrollment, initialOperationID: UUID? = nil) async throws {
        func validateAdmission() throws {
            try Task.checkCancellation()
            try enrollment.session.validateSession()
            guard relayOwners[provider] === owner, let current = enrollments[provider],
                  current.identity == enrollment.identity,
                  (current.session as AnyObject) === (enrollment.session as AnyObject) else {
                throw PluginRelayPhoneRouteOwnerError.superseded
            }
            if let id = initialOperationID {
                let now = ProcessInfo.processInfo.systemUptime
                guard operationID == id, signingInProvider == provider, setupProvider == provider,
                      let deadline = initialSetupDeadlineUptime, now.isFinite, now < deadline else {
                    throw PluginRelayPhoneRouteOwnerError.superseded
                }
            }
        }
        try validateAdmission()
        let currentFence = try await owner.currentFence()
        try validateAdmission()
        guard let connector = brokerConnector else { throw CloudAgentIdentityError.registrationRequired }
        try await connector.ensurePro(enrollment, fence: currentFence, force: false)
        try validateAdmission()
        let report = try await owner.status()
        try validateAdmission()
        let fence = try await owner.currentFence()
        try validateAdmission()
        guard report.route == fence.binding.route else { throw PluginRelayPhoneRouteOwnerError.superseded }
        if report.remoteReady {
            guard report.deliveryMode == (provider == .dot ? .events : .manual),
                  report.automaticDeliveryReady == (provider == .dot) else { throw PluginRelayHTTPError.invalidResponse }
            if publishedRoutes[provider] != fence {
                guard let connector = brokerConnector else { throw CloudAgentIdentityError.registrationRequired }
                try validateAdmission()
                try await connector.publishRoute(fence, enrollment: enrollment)
                try validateAdmission()
                guard try await owner.currentFence() == fence else { throw PluginRelayPhoneRouteOwnerError.superseded }
                try validateAdmission()
                publishedRoutes[provider] = fence
            }
            let local = try enrollment.identity.binding()
            let binding = try CloudAgentAccountBinding(provider: provider, accountID: local.accountID,
                generation: report.route.accountGeneration)
            connections[provider] = .init(provider: provider, identity: .signedIn(binding), conversationCapability: .verified(binding))
            connectionStage[provider] = nil
        } else {
            connections[provider] = signedIn(enrollment.identity)
            connectionStage[provider] = "Finish authorizing Peel in \(provider == .dot ? "Dot" : "Grok Bot"), then check the connection."
        }
    }

    /// The discriminator selects an owner only. The original bytes always reach
    /// the coordinator's strict duplicate/unknown-field/fence/direction decoder.
    func handlePluginRelay(_ data: Data, from callback: PeelCloudAgentWatchCallback) async -> Data {
        if PluginRelayEnrollmentWire.claims(data) { return await handleEnrollmentRenewal(data, from: callback) }
        guard let output = await handlePluginRelayOutput(data, from: callback) else { return Data() }
        var result = Data()
        do { try output.submit { result = $0 }; return result } catch { return Data() }
    }
    func handlePluginRelayOutput(_ data: Data, from callback: PeelCloudAgentWatchCallback) async -> PluginRelayPhoneOutput? {
        guard !data.isEmpty, data.count <= WatchStreamWire.maximumBytes,
              let header = try? JSONDecoder().decode(RelayDiscriminator.self, from: data),
              header.channel == "peel.watch.cloud.v2", header.version == 2,
              let request = try? PluginRelayV2Envelope.decode(data, expectedFence: header.fence),
              let owner = relayOwners[header.fence.binding.route.provider],
              let enrollment = enrollments[header.fence.binding.route.provider], let connector = brokerConnector else { return nil }
        let provider = header.fence.binding.route.provider, generation = relayGenerations[header.fence.binding.route.provider]
        let sessionObject = enrollment.session as AnyObject
        @MainActor func current() -> Bool {
            guard generation == relayGenerations[provider], relayOwners[provider] === owner,
                  let value = enrollments[provider] else { return false }
            return (value.session as AnyObject) === sessionObject
        }
        do {
            _ = try enrollment.session.peerEvidence(for: callback)
            guard try await owner.currentFence() == header.fence, current() else { return nil }
            if request.kind != .localStop {
                try await connector.ensurePro(enrollment, fence: header.fence, force: false)
                guard current() else { return nil }; proNotices[provider] = nil
            }
            let output = try await owner.handleOutput(data, from: callback)
            guard current() else { return nil }
            return output
        } catch {
            if current(), error is PluginRelayProError { proNotices[provider] = proMessage(error) }
            return nil // No legacy fallback, identity reset or automatic resubmit.
        }
    }

    /// Called only by the exact enrollment channel's finite WC adapter. Wrong
    /// directions/malformed packets are rejected without older-channel fallback.
    private func handleEnrollmentRenewal(_ data: Data, from callback: PeelCloudAgentWatchCallback) async -> Data {
        guard let request = try? PluginRelayEnrollmentWire.decode(data), let connector = brokerConnector else { return Data() }
        do {
            switch request.kind {
            case .renewChallengeRequest:
                guard let context = request.resumeContext else { return Data() }
                let provider = context.fence.binding.route.provider, generation = relayGenerations[context.fence.binding.route.provider]
                let expected = try await connector.continuityContext(provider)
                guard context == expected, generation == relayGenerations[provider] else { throw PluginRelayEnrollmentError.wrongPeer }
                let owner = relayOwners[provider]
                let pause = try await owner?.pauseForAuthorityRenewal()
                let (challenge, signature) = try await connector.beginRenewal(context, from: callback)
                guard generation == relayGenerations[provider], relayOwners[provider] === owner else { throw PluginRelayEnrollmentError.revoked }
                renewals = renewals.filter { $0.value.provider != provider }
                renewals[challenge.challengeID] = (provider, owner, pause, generation)
                return try PluginRelayEnrollmentWire(courierID: request.courierID, kind: .renewChallenge,
                    phoneSignature: signature, resumeChallenge: challenge).encoded()
            case .renewProof:
                guard let id = request.challengeID, let signature = request.watchSignature,
                      let pending = renewals.removeValue(forKey: id), pending.generation == relayGenerations[pending.provider] else { return Data() }
                let restored = try await connector.finishRenewal(id, signature: signature, from: callback)
                try Task.checkCancellation()
                let provider = pending.provider
                guard pending.generation == relayGenerations[provider], restored.fence.binding.route.provider == provider,
                      relayOwners[provider] === pending.owner else { throw PluginRelayEnrollmentError.revoked }
                let owner: PluginRelayPhoneRouteOwner
                if let current = pending.owner, let pause = pending.pause {
                    try await current.resumeAfterAuthorityRenewal(pause, verified: restored); owner = current
                } else {
                    owner = try PeelCloudAgentRelayPersistence.makeOwner(); try await owner.restore(restored)
                }
                guard pending.generation == relayGenerations[provider] else { throw PluginRelayEnrollmentError.revoked }
                let descriptor = try await connector.continuityContext(provider)
                guard descriptor.fence == restored.fence, pending.generation == relayGenerations[provider],
                      relayOwners[provider] === pending.owner else {
                    if pending.owner == nil { try? await owner.invalidate() }
                    throw PluginRelayEnrollmentError.wrongPeer
                }
                // Historical provider identity is display/account binding only.
                // Current session and readiness are checked independently.
                let identity = restored.identity
                relayOwners[provider] = owner; enrollments[provider] = .init(identity: identity, session: restored.session)
                identities[provider] = identity; connections[provider] = signedIn(identity)
                sessionDeadlines[provider] = enrollments[provider]?.applicationDeadline
                publishedRoutes[provider] = restored.fence
                scheduleIdentityExpiry()
                return try PluginRelayEnrollmentWire(courierID: request.courierID, kind: .renewed, routeGrant: restored.compactGrant).encoded()
            default: return Data()
            }
        } catch {
            let terminal = (error as? PluginRelayContinuityError).map { [.explicitConnectRequired, .rotationUncertain, .expired, .invalidRecord, .authorityChanged].contains($0) } ?? false
            return (try? PluginRelayEnrollmentWire(courierID: request.courierID, kind: .renewalUnavailable,
                renewalFailure: terminal ? "explicitConnectRequired" : "temporarilyUnavailable").encoded()) ?? Data()
        }
    }
    func requireBrokerSetup() {
        guard brokerConnector == nil else { return }
        for provider in [CloudAgentProvider.dot, .grokBot] where configurations[provider] != nil {
            configurationFailures[provider] = "This build needs Peel’s approved service registration and broker configuration before Connect is available."
        }
    }

    private struct RelayDiscriminator: Decodable {
        let channel: String
        let version: Int
        let fence: PluginRelayFence
    }

    func handle(_ request: WatchCloudRequest) async -> WatchCloudResponse {
        let connection = status(for: request.provider)
        do {
            try request.validate()
        } catch {
            return WatchCloudResponse(requestID: request.requestID, provider: request.provider,
                                      ready: false, message: "The agent request was rejected.",
                                      connectionStatus: connection)
        }

        let message: String
        switch request.kind {
        case .cancel:
            // No remote task was submitted. Never describe local polling
            // cancellation as cancellation of an existing cloud agent's work.
            message = "Stopped checking on this device. No remote task was cancelled."
        case .status, .send, .replies:
            message = setupDescription(for: request.provider)
        }
        return WatchCloudResponse(requestID: request.requestID, provider: request.provider,
                                  ready: false, message: message, connectionStatus: connection)
    }
}

private final class PeelCloudIdentityPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let window: UIWindow
    init(window: UIWindow) { self.window = window }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { window }
}

/// This-device-only phone Keychain; no shared access group, Watch transfer,
/// synchronizable item, token cache, profile storage or user-defaults fallback.
private final class PeelCloudIdentityKeychain {
    private func query(_ namespace: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "\(Bundle.main.bundleIdentifier ?? "Peel").cloud-identity",
         kSecAttrAccount as String: namespace,
         kSecAttrSynchronizable as String: false]
    }
    func load(namespace: String) throws -> CloudAgentVerifiedIdentity? {
        var request = query(namespace)
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 4_096,
              let identity = try? JSONDecoder().decode(CloudAgentVerifiedIdentity.self, from: data) else {
            throw CloudAgentIdentityError.secureStorageUnavailable
        }
        return identity
    }
    func save(_ identity: CloudAgentVerifiedIdentity, namespace: String) throws {
        let data = try JSONEncoder().encode(identity)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query(namespace) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(namespace); attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw CloudAgentIdentityError.secureStorageUnavailable }
        } else if status != errSecSuccess { throw CloudAgentIdentityError.secureStorageUnavailable }
    }
    func remove(namespace: String) throws {
        let status = SecItemDelete(query(namespace) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CloudAgentIdentityError.secureStorageUnavailable }
    }
}
#endif
