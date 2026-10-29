#if !os(watchOS)
import Foundation

public enum PluginRelayHTTPError: Error, Equatable, Sendable {
    case invalidConfiguration, authorityChanged, invalidResponse, responseTooLarge
    case networkFailure, timeout, cancelled, redirectRejected, busy
    case serviceRejected(String)
}

/// Non-secret EXPECTATION only. Constructing this metadata grants no authority.
public struct PluginRelayHTTPContext: Equatable, Sendable {
    public let provider: CloudAgentProvider
    public let accountGeneration: UUID
    public let pairingEpoch: UUID
    public let localEpoch: UUID
    public init(provider: CloudAgentProvider, accountGeneration: UUID, pairingEpoch: UUID, localEpoch: UUID) {
        self.provider = provider; self.accountGeneration = accountGeneration
        self.pairingEpoch = pairingEpoch; self.localEpoch = localEpoch
    }
    public init(fence: PluginRelayFence) {
        self.init(provider: fence.binding.route.provider, accountGeneration: fence.binding.route.accountGeneration,
                  pairingEpoch: fence.binding.pairingEpoch, localEpoch: fence.localEpoch)
    }
}

public enum PluginRelayHTTPScope: String, Sendable { case connect = "watch.connect", send = "watch.send", read = "watch.read" }

/// Phone-only, non-Codable attachment produced ONLY by a trusted external
/// session/device verifier. It is redacted and never belongs on the Watch wire.
public struct PluginRelayHTTPAuthorization: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let context: PluginRelayHTTPContext
    public let leaseID: UUID
    public let expiresAt: Date
    public let proPermit: PluginRelayProPermit?
    let headers: [String: String]
    public init(context: PluginRelayHTTPContext, leaseID: UUID, expiresAt: Date, headers: [String: String], proPermit: PluginRelayProPermit? = nil) {
        self.context = context; self.leaseID = leaseID; self.expiresAt = expiresAt; self.headers = headers; self.proPermit = proPermit
    }
    public var description: String { "PluginRelayHTTPAuthorization(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["context": context]) }
}

/// REQUIRED external composition: independently verify the broker session and
/// actual current paired-device proof, expiry/revocation/scopes/provider/account
/// generation before issuing an attachment. No implementation/default exists here.
/// Both methods must be bounded, synchronous, thread-safe and nonblocking; login
/// and remote verification happen outside this transport. validateCurrent must
/// also reject invalidated local epochs/leases. It is called during in-flight IO.
/// Device authority may bind account + enrolled phone/Watch route; no online
/// computer/Host/video stream is required. WCSession.isPaired alone is not proof.
public protocol PluginRelayHTTPAuthorizer: Sendable {
    func authorization(for context: PluginRelayHTTPContext, scope: PluginRelayHTTPScope,
                       trustedOrigin: URL) throws -> PluginRelayHTTPAuthorization
    func validateCurrent(_ authorization: PluginRelayHTTPAuthorization, scope: PluginRelayHTTPScope) throws
}

public struct PluginRelayConnectResponse: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let route: PluginRelayReference
    public let confirmationChallenge: String
    public let minimumRoutineIntervalSeconds: Int64?
    public var description: String { "PluginRelayConnectResponse(authorizePlugin, challenge:redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["route": route]) }
}

/// Authenticated remote report only, NOT a native readiness/capability grant.
/// Grok manualReady never reports automatic delivery. Routine cadence metadata
/// is not a minimum phone reply polling/read interval.
public struct PluginRelayHTTPStatus: Equatable, Sendable {
    public enum State: String, Sendable { case authorizePlugin, connected, manualReady }
    public enum DeliveryMode: String, Sendable { case events, manual }
    public let route: PluginRelayReference
    public let remoteReady: Bool
    public let state: State
    public let deliveryMode: DeliveryMode
    public let automaticDeliveryReady: Bool
    public let minimumRoutineIntervalSeconds: Int64?
}

/// Fixed-origin, phone-side HTTP boundary only. No OAuth/session verifier, UI,
/// credential lookup, retry, persistent inbox, Watch route or ready enabling.
public actor PluginRelayHTTPClient {
    private let origin: URL
    private let authorizer: any PluginRelayHTTPAuthorizer
    private let credentialHeaders: Set<String>
    private let configuration: URLSessionConfiguration
    private let timeout: TimeInterval
    private var operation: PluginRelayHTTPOperation?

    public init(trustedOrigin: URL, allowedAuthorizationHeaderNames: Set<String>,
                authorizer: any PluginRelayHTTPAuthorizer, timeout: TimeInterval = 15) throws {
        try self.init(trustedOrigin: trustedOrigin, allowedAuthorizationHeaderNames: allowedAuthorizationHeaderNames,
                      authorizer: authorizer, timeout: timeout, configuration: .ephemeral)
    }
    init(trustedOrigin: URL, allowedAuthorizationHeaderNames: Set<String>, authorizer: any PluginRelayHTTPAuthorizer,
         timeout: TimeInterval, configuration: URLSessionConfiguration) throws {
        guard let components = URLComponents(url: trustedOrigin, resolvingAgainstBaseURL: false),
              components.scheme == "https", let host = components.host, !host.isEmpty,
              host.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 }),
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.port == nil || components.port == 443, ["", "/"].contains(components.percentEncodedPath),
              timeout.isFinite, (0.05...20).contains(timeout), (1...8).contains(allowedAuthorizationHeaderNames.count) else {
            throw PluginRelayHTTPError.invalidConfiguration
        }
        let forbidden: Set<String> = ["host", "content-type", "content-length", "accept", "cookie", "set-cookie",
            "proxy-authorization", "connection", "transfer-encoding", "cache-control"]
        let names = Set(allowedAuthorizationHeaderNames.map { $0.lowercased() })
        guard names.count == allowedAuthorizationHeaderNames.count, names.isDisjoint(with: forbidden),
              names.allSatisfy({ (1...64).contains($0.utf8.count) && $0.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 } }) else {
            throw PluginRelayHTTPError.invalidConfiguration
        }
        var normalized = URLComponents(); normalized.scheme = "https"; normalized.host = host.lowercased()
        guard let origin = normalized.url else { throw PluginRelayHTTPError.invalidConfiguration }
        self.origin = origin; self.authorizer = authorizer; credentialHeaders = names; self.timeout = timeout
        self.configuration = configuration.copy() as! URLSessionConfiguration
    }

    public func connect(agentReference: String, context: PluginRelayHTTPContext) async throws -> PluginRelayConnectResponse {
        guard PluginRelayValidation.opaque(agentReference) else { throw PluginRelayHTTPError.invalidConfiguration }
        return try await perform("connect", body: ["agent_reference": agentReference], context: context, scope: .connect) { value in
            let object = try value.object(keys: ["route", "confirmationChallenge", "state", "minimumRoutineIntervalSeconds"])
            let route = try Self.route(object.required("route")); try Self.match(route, context: context)
            let challenge = try object.required("confirmationChallenge").string()
            guard try object.required("state").string() == "authorizePlugin", PluginRelayValidation.opaque(challenge) else { throw PluginRelayHTTPError.invalidResponse }
            let routine = try object.required("minimumRoutineIntervalSeconds").optionalInteger()
            try Self.routine(routine, provider: route.provider)
            return PluginRelayConnectResponse(route: route, confirmationChallenge: challenge, minimumRoutineIntervalSeconds: routine)
        }
    }
    public func status(using fence: PluginRelayFence) async throws -> PluginRelayHTTPStatus {
        let context = PluginRelayHTTPContext(fence: fence)
        return try await perform("status", body: ["route_id": fence.binding.route.routeID], context: context, scope: .read) { value in
            let object = try value.object(keys: ["route", "ready", "state", "deliveryMode", "automaticDeliveryReady", "minimumRoutineIntervalSeconds"])
            let route = try Self.route(object.required("route")); guard route == fence.binding.route else { throw PluginRelayHTTPError.authorityChanged }
            let ready = try object.required("ready").bool(), automatic = try object.required("automaticDeliveryReady").bool()
            guard let state = PluginRelayHTTPStatus.State(rawValue: try object.required("state").string()),
                  let mode = PluginRelayHTTPStatus.DeliveryMode(rawValue: try object.required("deliveryMode").string()) else { throw PluginRelayHTTPError.invalidResponse }
            let routine = try object.required("minimumRoutineIntervalSeconds").optionalInteger(); try Self.routine(routine, provider: route.provider)
            let expectedState: PluginRelayHTTPStatus.State = ready ? (route.provider == .dot ? .connected : .manualReady) : .authorizePlugin
            guard state == expectedState, mode == (route.provider == .dot ? .events : .manual), automatic == (ready && route.provider == .dot) else {
                throw PluginRelayHTTPError.invalidResponse
            }
            return PluginRelayHTTPStatus(route: route, remoteReady: ready, state: state, deliveryMode: mode,
                                        automaticDeliveryReady: automatic, minimumRoutineIntervalSeconds: routine)
        }
    }
    public func send(_ message: PluginRelayMessage, using fence: PluginRelayFence) async throws -> PluginRelayReceipt {
        try message.validate()
        return try await perform("send", body: ["route_id": fence.binding.route.routeID, "generation": fence.binding.route.generation.uuidString.lowercased(),
            "request_id": message.messageID.uuidString.lowercased(), "text": message.text], context: .init(fence: fence), scope: .send) { value in
            let object = try value.object(keys: ["requestID", "route", "receiptID", "state", "agentReplyReceived"])
            let route = try Self.route(object.required("route"))
            guard route == fence.binding.route, let id = UUID(uuidString: try object.required("requestID").string()), id == message.messageID else { throw PluginRelayHTTPError.authorityChanged }
            guard let state = PluginRelayReceipt.State(rawValue: try object.required("state").string()) else { throw PluginRelayHTTPError.invalidResponse }
            return try PluginRelayReceipt(requestID: id, route: route, receiptID: object.required("receiptID").string(),
                                          state: state, agentReplyReceived: object.required("agentReplyReceived").bool())
        }
    }
    public func replies(after cursor: Int64, using fence: PluginRelayFence) async throws -> PluginRelayReplyPage {
        guard cursor >= 0 else { throw PluginRelayHTTPError.invalidConfiguration }
        return try await perform("replies", body: ["route_id": fence.binding.route.routeID,
            "generation": fence.binding.route.generation.uuidString.lowercased(), "after": cursor], context: .init(fence: fence), scope: .read) { value in
            let object = try value.object(keys: ["route", "replies", "cursor"]), route = try Self.route(object.required("route"))
            guard route == fence.binding.route else { throw PluginRelayHTTPError.authorityChanged }
            guard case .array(let values) = try object.required("replies"), values.count <= 15 else { throw PluginRelayHTTPError.invalidResponse }
            let replies = try values.map { value -> PluginRelayReply in
                let reply = try value.object(keys: ["requestID", "replyID", "text"])
                guard let id = UUID(uuidString: try reply.required("requestID").string()) else { throw PluginRelayHTTPError.invalidResponse }
                return try PluginRelayReply(requestID: id, replyID: reply.required("replyID").string(), text: reply.required("text").string())
            }
            let next = try object.required("cursor").integer()
            guard replies.isEmpty ? next == cursor : next > cursor else { throw PluginRelayHTTPError.invalidResponse }
            return try PluginRelayReplyPage(route: route, replies: replies, cursor: next)
        }
    }
    public func disconnect(using fence: PluginRelayFence) async throws {
        _ = try await perform("disconnect", body: ["route_id": fence.binding.route.routeID], context: .init(fence: fence), scope: .connect) { value in
            let object = try value.object(keys: ["disconnected"])
            guard try object.required("disconnected").bool() else { throw PluginRelayHTTPError.invalidResponse }; return true
        }
    }
    /// Cancels local IO only; an already submitted message may still be accepted.
    public func cancelCurrent() { operation?.cancel() }

    private func perform<T>(_ endpoint: String, body: [String: Any], context: PluginRelayHTTPContext,
                            scope: PluginRelayHTTPScope, decode: (PluginRelayJSON) throws -> T) async throws -> T {
        guard operation == nil else { throw PluginRelayHTTPError.busy }
        guard !Task.isCancelled else { throw PluginRelayHTTPError.cancelled }
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count <= 256 * 1_024 else { throw PluginRelayHTTPError.invalidConfiguration }
        let path = "/v1/watch/\(endpoint)"
        let proof = try PluginRelayHTTPRequestProof(method: "POST", path: path, body: data)
        let grant: PluginRelayHTTPAuthorization
        do {
            if let signer = authorizer as? any PluginRelayHTTPRequestAuthorizer {
                grant = try signer.authorization(for: context, scope: scope, trustedOrigin: origin, request: proof)
            } else {
                grant = try authorizer.authorization(for: context, scope: scope, trustedOrigin: origin)
            }
        }
        catch let paid as PluginRelayProError { throw paid }
        catch { throw PluginRelayHTTPError.authorityChanged }
        let paid: PluginRelayProPermit?
        if endpoint == "disconnect" { paid = nil }
        else {
            guard let permit = grant.proPermit else { throw PluginRelayProError.required }
            paid = permit
        }
        let routeID = body["route_id"] as? String, generation = body["generation"] as? String
        let validate: @Sendable () throws -> Void = { [authorizer] in
            guard grant.context == context, grant.expiresAt.timeIntervalSinceReferenceDate.isFinite, grant.expiresAt > Date() else { throw PluginRelayHTTPError.authorityChanged }
            do { try authorizer.validateCurrent(grant, scope: scope) }
            catch let paid as PluginRelayProError { throw paid }
            catch { throw PluginRelayHTTPError.authorityChanged }
            if let paid { try paid.validateHTTP(context: context, routeID: routeID, generation: generation) }
        }
        try validate()
        let names = grant.headers.keys.map { $0.lowercased() }
        guard !names.isEmpty, Set(names).count == names.count, Set(names).isSubset(of: credentialHeaders),
              grant.headers.values.reduce(0, { $0 + $1.utf8.count }) <= 16_384,
              grant.headers.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty && $0.utf8.count <= 8_192 && $0.utf8.allSatisfy { (32...126).contains($0) } }) else {
            throw PluginRelayHTTPError.invalidConfiguration
        }
        var request = URLRequest(url: origin.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = "POST"; request.httpBody = data; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        for (name, value) in grant.headers { request.setValue(value, forHTTPHeaderField: name) }
        let task = PluginRelayHTTPOperation(); operation = task; defer { operation = nil }
        let response = try await task.perform(request, configuration: configuration, timeout: timeout,
            submission: paid, validateAuthority: validate)
        try validate(); guard !Task.isCancelled else { throw PluginRelayHTTPError.cancelled }
        let value = try PluginRelayJSON.parse(response.body)
        guard response.status == 200 else {
            let object = try value.object(keys: ["error"]), code = try object.required("error").string()
            if code == "pro_required" || code == "pro_expired" {
                paid?.closeOnTrustedDenial()
                throw code == "pro_expired" ? PluginRelayProError.expired : PluginRelayProError.required
            }
            if code == "commerce_unavailable" { throw PluginRelayProError.unavailable }
            let safeCodes: Set<String> = ["authentication_required", "route_revoked", "principal_expired", "route_generation_changed", "device_access_denied",
                "reused_request_id", "connection_not_confirmed", "inbox_capacity", "route_capacity", "access_denied", "unknown_request", "reply_conflict", "invalid_confirmation"]
            throw PluginRelayHTTPError.serviceRejected(safeCodes.contains(code) ? code : "service_rejected")
        }
        let result: T
        do { result = try decode(value) }
        catch let error as PluginRelayHTTPError { throw error }
        catch { throw PluginRelayHTTPError.invalidResponse }
        try validate()
        guard !Task.isCancelled else { throw PluginRelayHTTPError.cancelled }
        return result
    }
    private static func routine(_ value: Int64?, provider: CloudAgentProvider) throws {
        guard value == (provider == .dot ? nil : 300) else { throw PluginRelayHTTPError.invalidResponse }
    }
    private static func match(_ route: PluginRelayReference, context: PluginRelayHTTPContext) throws {
        guard route.provider == context.provider, route.accountGeneration == context.accountGeneration else { throw PluginRelayHTTPError.authorityChanged }
    }
    private static func route(_ value: PluginRelayJSON) throws -> PluginRelayReference {
        let object = try value.object(keys: ["kind", "provider", "routeID", "generation", "accountGeneration"])
        guard try object.required("kind").string() == "pluginRelay", let provider = CloudAgentProvider(rawValue: try object.required("provider").string()),
              let generation = UUID(uuidString: try object.required("generation").string()),
              let account = UUID(uuidString: try object.required("accountGeneration").string()) else { throw PluginRelayHTTPError.invalidResponse }
        return try PluginRelayReference(provider: provider, routeID: object.required("routeID").string(), generation: generation, accountGeneration: account)
    }
}
#endif
