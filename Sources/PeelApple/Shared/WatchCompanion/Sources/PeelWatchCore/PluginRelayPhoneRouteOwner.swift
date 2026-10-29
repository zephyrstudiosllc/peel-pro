#if !os(watchOS)
import Foundation

/// Attributed native callback, never decoded from a courier. Its required
/// verifier must bind the actual callback channel to the enrolled Watch.
public protocol PluginRelayNativePeerCallback: Sendable {}

/// Required trusted broker/enrollment adapter. Public metadata and WC flags do
/// not implement this contract. The adapter owns its independently verified
/// credential and live session/peer/lease registry; no default is provided.
public protocol PluginRelayPhoneVerifiedSession: PluginRelayHTTPRequestAuthorizer, PluginRelayPhoneAuthority {
    var context: PluginRelayHTTPContext { get }
    var trustedOrigin: URL { get }
    var actualAgentReference: String { get }
    func validateSession() throws
    /// Add only the exact broker-returned route to the current live registry.
    func bind(_ fence: PluginRelayFence) throws
    func peerEvidence(for callback: any PluginRelayNativePeerCallback) throws -> any PluginRelayPhonePeerEvidence
    /// Synchronously close local credential/peer/lease admission before awaits.
    /// The caller separately performs provider/broker sign-out and key deletion.
    func revokeLocal()
}

public protocol PluginRelayPhoneConnectingTransport: PluginRelayPhoneTransport {
    func connect(agentReference: String, context: PluginRelayHTTPContext) async throws -> PluginRelayConnectResponse
}
extension PluginRelayHTTPClient: PluginRelayPhoneConnectingTransport {}

public enum PluginRelayPhoneRouteOwnerError: Error, Equatable, Sendable {
    case inactive, busy, superseded, authorityChanged
}

/// Phone lifecycle owner for one account/provider/Watch route. Construction
/// grants nothing. Connect requires a real verified session, performs the
/// accepted HTTP request, binds its exact route, and opens dedicated persistence
/// before exposing a coordinator. Pending plugin confirmation remains pending.
public actor PluginRelayPhoneRouteOwner {
    public typealias PersistenceFactory = @Sendable (PluginRelayFence) throws -> any PluginRelayPersistence
    public typealias TransportFactory = @Sendable (any PluginRelayPhoneVerifiedSession) throws -> any PluginRelayPhoneConnectingTransport
    private let persistence: PersistenceFactory
    private let transportFactory: TransportFactory
    private struct Attempt {
        let nonce: UUID
        let session: any PluginRelayPhoneVerifiedSession
        let transport: any PluginRelayPhoneConnectingTransport
        let context: PluginRelayHTTPContext
        let origin: URL
        let agentReference: String
    }
    private struct Active {
        let attempt: Attempt
        let fence: PluginRelayFence
        let coordinator: PluginRelayPhoneCoordinator
    }
    private var pending: Attempt?
    private var active: Active?
    private var closing = false
    private var pendingWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var closeTask: Task<Void, Error>?
    private var setupStatus: UUID?
    private var courierCount = 0
    private var requestDrain: [CheckedContinuation<Void, Never>] = []
    private var renewal: (id: UUID, coordinatorToken: UUID?)?
    private var renewalPauseTask: Task<UUID, Error>?

    public init(persistence: @escaping PersistenceFactory) {
        self.persistence = persistence
        transportFactory = { session in
            try PluginRelayHTTPClient(trustedOrigin: session.trustedOrigin,
                allowedAuthorizationHeaderNames: ["authorization", "x-peel-enrollment", "x-peel-timestamp", "x-peel-nonce", "x-peel-signature"], authorizer: session)
        }
    }
    /// Explicit transport injection for deterministic fixtures. It does not
    /// relax the mandatory session, authority or raw-byte coordinator checks.
    public init(persistence: @escaping PersistenceFactory, transport: @escaping TransportFactory) {
        self.persistence = persistence; transportFactory = transport
    }

    public func connect(using session: any PluginRelayPhoneVerifiedSession) async throws -> PluginRelayConnectResponse {
        guard !closing else { throw PluginRelayPhoneRouteOwnerError.inactive }
        guard pending == nil, active == nil else { throw PluginRelayPhoneRouteOwnerError.busy }
        try Task.checkCancellation(); try session.validateSession()
        let attempt = Attempt(nonce: UUID(), session: session, transport: try transportFactory(session),
            context: session.context, origin: session.trustedOrigin, agentReference: session.actualAgentReference)
        pending = attempt
        defer { finishPending(attempt.nonce) }
        do {
            let response = try await attempt.transport.connect(agentReference: attempt.agentReference, context: attempt.context)
            try checkPending(attempt)
            try response.route.validate()
            guard response.route.provider == attempt.context.provider,
                  response.route.accountGeneration == attempt.context.accountGeneration else {
                throw PluginRelayPhoneRouteOwnerError.authorityChanged
            }
            let fence = PluginRelayFence(binding: .init(route: response.route, pairingEpoch: attempt.context.pairingEpoch),
                                         localEpoch: attempt.context.localEpoch)
            try session.bind(fence)
            try checkPending(attempt)
            let store = try PluginRelayPhoneStore(persistence: persistence(fence), fence: fence, limits: .init())
            let coordinator = try PluginRelayPhoneCoordinator(fence: fence, store: store,
                transport: attempt.transport, authority: session)
            try checkPending(attempt)
            active = Active(attempt: attempt, fence: fence, coordinator: coordinator)
            return response
        } catch {
            // Commerce loss is not account/peer revocation. No active route is
            // exposed on this failed Connect; the same identity may obtain a
            // fresh paid lease through its authenticated evidence endpoint.
            if !(error is PluginRelayProError) { session.revokeLocal() }
            await attempt.transport.cancelCurrent()
            throw error
        }
    }

    public func currentFence() throws -> PluginRelayFence {
        let current = try current(); return current.fence
    }

    /// This is a phone-owned setup check, not a Watch/native authority grant.
    /// No polling loop is installed and no readiness is inferred from Connect.
    public func status() async throws -> PluginRelayHTTPStatus {
        guard renewal == nil else { throw PluginRelayPhoneRouteOwnerError.busy }
        let value = try current()
        guard setupStatus == nil, courierCount == 0 else { throw PluginRelayPhoneRouteOwnerError.busy }
        let nonce = UUID(); setupStatus = nonce
        defer { if setupStatus == nonce { setupStatus = nil }; finishRequest() }
        let report = try await value.attempt.transport.status(using: value.fence)
        try checkActive(value)
        guard report.route == value.fence.binding.route else { throw PluginRelayPhoneRouteOwnerError.authorityChanged }
        return report
    }

    public func handle(_ bytes: Data, from callback: any PluginRelayNativePeerCallback) async throws -> Data {
        try await handleOutput(bytes, from: callback).copyBytes()
    }
    public func handleOutput(_ bytes: Data, from callback: any PluginRelayNativePeerCallback) async throws -> PluginRelayPhoneOutput {
        guard renewal == nil else { throw PluginRelayPhoneRouteOwnerError.busy }
        let value = try current()
        guard setupStatus == nil else { throw PluginRelayPhoneRouteOwnerError.busy }
        let peer = try value.attempt.session.peerEvidence(for: callback)
        try checkActive(value)
        courierCount += 1
        defer { courierCount -= 1; finishRequest() }
        let result = try await value.coordinator.handleOutput(bytes, from: peer)
        try checkActive(value)
        return result
    }

    /// Always trusted local lifecycle, independent of expired inbound grants.
    /// A replacement owner/session must wait for this drain to finish. Failed
    /// store invalidation stays failed/closed; it never restores old admission.
    public func invalidate() async throws {
        if let closeTask { try await closeTask.value; return }
        closing = true
        let oldPending = pending, oldActive = active
        oldPending?.session.revokeLocal(); oldActive?.attempt.session.revokeLocal()
        let task = Task { [self] in
            if let oldPending {
                await oldPending.transport.cancelCurrent()
                await waitForPending(oldPending.nonce)
            }
            if let oldActive {
                await oldActive.attempt.transport.cancelCurrent()
                do { try await oldActive.coordinator.invalidate() }
                catch { await waitForRequests(); throw error }
                await waitForRequests()
            }
        }
        closeTask = task
        do { try await task.value; active = nil }
        catch { active = nil; throw error }
    }

    private func current() throws -> Active {
        guard !closing, let active else { throw PluginRelayPhoneRouteOwnerError.inactive }
        try Task.checkCancellation(); try validateSession(active.attempt); return active
    }
    private func checkPending(_ value: Attempt) throws {
        guard !closing, pending?.nonce == value.nonce else { throw PluginRelayPhoneRouteOwnerError.superseded }
        try Task.checkCancellation(); try validateSession(value)
    }
    private func checkActive(_ value: Active) throws {
        guard !closing, renewal == nil, active?.attempt.nonce == value.attempt.nonce else { throw PluginRelayPhoneRouteOwnerError.superseded }
        try Task.checkCancellation(); try validateSession(value.attempt)
    }
    private func validateSession(_ value: Attempt) throws {
        try value.session.validateSession()
        guard value.session.context == value.context, value.session.trustedOrigin == value.origin,
              value.session.actualAgentReference == value.agentReference else {
            throw PluginRelayPhoneRouteOwnerError.authorityChanged
        }
    }
    private func finishPending(_ nonce: UUID) {
        if pending?.nonce == nonce { pending = nil }
        for continuation in pendingWaiters.removeValue(forKey: nonce) ?? [] { continuation.resume() }
    }
    private func waitForPending(_ nonce: UUID) async {
        guard pending?.nonce == nonce else { return }
        await withCheckedContinuation { pendingWaiters[nonce, default: []].append($0) }
    }
    private func finishRequest() {
        guard setupStatus == nil, courierCount == 0 else { return }
        for continuation in requestDrain { continuation.resume() }; requestDrain.removeAll()
    }
    private func waitForRequests() async {
        guard setupStatus != nil || courierCount != 0 else { return }
        await withCheckedContinuation { requestDrain.append($0) }
    }

    /// Cold restore requires a result constructed by the continuity controller
    /// after fresh peer proof, online rotation and a pinned current broker JWS.
    /// Stored route metadata cannot invoke this initializer on its own.
    public func restore(_ verified: PluginRelayVerifiedPhoneRestoration) throws {
        guard !closing, pending == nil, active == nil else { throw PluginRelayPhoneRouteOwnerError.busy }
        try verified.session.validateSession()
        let attempt = Attempt(nonce: UUID(), session: verified.session, transport: try transportFactory(verified.session),
            context: verified.session.context, origin: verified.session.trustedOrigin, agentReference: verified.session.actualAgentReference)
        try verified.session.bind(verified.fence)
        let store = try PluginRelayPhoneStore(persistence: persistence(verified.fence), fence: verified.fence, limits: .init())
        let coordinator = try PluginRelayPhoneCoordinator(fence: verified.fence, store: store, transport: attempt.transport, authority: verified.session)
        try verified.session.validateSession()
        active = Active(attempt: attempt, fence: verified.fence, coordinator: coordinator)
    }
    public func pauseForAuthorityRenewal() async throws -> UUID {
        guard !closing, let value = active else { throw PluginRelayPhoneRouteOwnerError.inactive }
        if let renewalPauseTask { return try await renewalPauseTask.value }
        let id = UUID(); renewal = (id, nil)
        let task = Task { [self] in
            await value.attempt.transport.cancelCurrent()
            let token = try await value.coordinator.pauseForAuthorityRenewal()
            await waitForRequests()
            guard !closing, active?.attempt.nonce == value.attempt.nonce, renewal?.id == id else { throw PluginRelayPhoneRouteOwnerError.superseded }
            renewal = (id, token); return id
        }
        renewalPauseTask = task
        return try await task.value
    }
    public func resumeAfterAuthorityRenewal(_ token: UUID, verified: PluginRelayVerifiedPhoneRestoration) async throws {
        guard !closing, let value = active, renewal?.id == token, let coordinatorToken = renewal?.coordinatorToken,
              verified.fence == value.fence, let original = value.attempt.session as? PluginRelayEnrolledPhoneSession,
              original === verified.session else { throw PluginRelayPhoneRouteOwnerError.authorityChanged }
        try verified.session.validateSession()
        try await value.coordinator.resumeAfterAuthorityRenewal(coordinatorToken)
        guard !closing, renewal?.id == token, active?.attempt.nonce == value.attempt.nonce else { throw PluginRelayPhoneRouteOwnerError.superseded }
        renewal = nil; renewalPauseTask = nil
    }
}
#endif
