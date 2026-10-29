import Foundation

/// These are transport limits, never entitlement decisions. The Host obtains
/// its decision directly from the commerce authority, including Apple freshness.
nonisolated enum PeelProEvidenceLimits {
    static let capability = PeelProEntitlementProtocol.capability
    static let productIDs = ["peel.pro.lifetime", "peel.pro.monthly", "peel.pro.yearly", "peel.pro.3day.freetrial"]
    static let maximumTokens = PeelProEntitlementProtocol.maximumTokens
    static let maximumTokenBytes = PeelProEntitlementProtocol.maximumTokenBytes
    static let maximumWireBytes = PeelProEntitlementProtocol.maximumWireBytes
    static let challengeSeconds = PeelProEntitlementProtocol.challengeSeconds
    static let maximumLeaseSeconds = PeelProEntitlementProtocol.maximumLeaseSeconds
}

/// Constructed by PeelStore only after matching StoreKit's verified case. The
/// raw value is kept in the collection operation, never in preferences or logs.
nonisolated struct PeelVerifiedProTransactionEvidence {
    let productID: String
    let transactionID: UInt64
    let purchaseDate: Date
    let revocationDate: Date?
    let signedTransaction: String
}

nonisolated struct PeelProEvidenceSelection {
    private var byProductID: [String: PeelVerifiedProTransactionEvidence] = [:]

    mutating func include(_ evidence: PeelVerifiedProTransactionEvidence) {
        guard PeelProEvidenceLimits.productIDs.contains(evidence.productID),
              !evidence.signedTransaction.isEmpty,
              evidence.signedTransaction.utf8.count <= PeelProEvidenceLimits.maximumTokenBytes else { return }
        if let existing = byProductID[evidence.productID] {
            // A latest lookup can carry explicit revocation absent from current
            // entitlements. Never replace it with an older snapshot of that ID.
            if existing.transactionID == evidence.transactionID {
                guard existing.revocationDate == nil || evidence.revocationDate != nil else { return }
            } else if evidence.purchaseDate < existing.purchaseDate {
                return
            }
        }
        byProductID[evidence.productID] = evidence
    }

    var signedTransactions: [String] {
        PeelProEvidenceLimits.productIDs.compactMap { byProductID[$0]?.signedTransaction }
    }
}

/// Pure operation fence, exercised without a StoreKit account or real receipt.
/// Socket identity and current pairing are checked independently by the bridge.
nonisolated struct PeelProEvidenceOperation: Equatable {
    let id: UUID
    let requestID: String
    let nonce: String
    let pairingID: String
    let sessionID: String
    let wallDeadline: TimeInterval
    let uptimeDeadline: TimeInterval
}

nonisolated struct PeelProEvidenceFence {
    private(set) var sessionID: String?
    private(set) var operation: PeelProEvidenceOperation?
    // A bounded recent replay window avoids exhausting a healthy multi-day
    // connection. Every expired challenge is also rejected by its deadline;
    // the Host independently accepts only its exact current one-use challenge.
    private var recentChallenges: [(requestID: String, nonce: String)] = []

    mutating func begin(requestID: String, nonce: String, pairingID: String,
                        sessionID: String, expiresAt: TimeInterval,
                        now: TimeInterval, uptime: TimeInterval) -> PeelProEvidenceOperation? {
        guard UUID(uuidString: requestID) != nil, UUID(uuidString: sessionID) != nil,
              !pairingID.isEmpty, pairingID.utf8.count <= 128,
              let nonceBytes = Data(base64Encoded: nonce), nonceBytes.count == 32,
              nonceBytes.base64EncodedString() == nonce,
              now.isFinite, uptime.isFinite, expiresAt.isFinite,
              expiresAt > now, expiresAt - now <= PeelProEvidenceLimits.challengeSeconds,
              self.sessionID == nil || self.sessionID == sessionID,
              !recentChallenges.contains(where: { $0.requestID == requestID || $0.nonce == nonce }) else { return nil }
        self.sessionID = sessionID
        recentChallenges.append((requestID: requestID, nonce: nonce))
        if recentChallenges.count > 64 { recentChallenges.removeFirst() }
        let next = PeelProEvidenceOperation(id: UUID(), requestID: requestID,
            nonce: nonce, pairingID: pairingID, sessionID: sessionID,
            wallDeadline: expiresAt, uptimeDeadline: uptime + (expiresAt - now))
        operation = next
        return next
    }

    func isCurrent(_ expected: PeelProEvidenceOperation, now: TimeInterval, uptime: TimeInterval) -> Bool {
        operation == expected && now.isFinite && uptime.isFinite &&
            now < expected.wallDeadline && uptime < expected.uptimeDeadline
    }

    mutating func cancel(clearSession: Bool) {
        operation = nil
        if clearSession {
            sessionID = nil
            recentChallenges.removeAll()
        }
    }
}

/// UI coordination only: none of these states authorize a paid Host action.
nonisolated enum PeelProMacVerificationStatus: String, Equatable, Sendable {
    case waitingForMac = "waiting_for_mac"
    case checking = "checking"
    case verified = "verified"
    case noEvidence = "no_verified_evidence"
    case denied = "verification_denied"
    case unavailable = "verification_unavailable"
    case unsupported = "host_update_required"
    case inactive = "client_inactive"

    var userMessage: String {
        switch self {
        case .verified: return "The computer verified Peel Pro for this connection."
        case .checking: return "The computer is verifying Peel Pro."
        case .unsupported: return "Update Peel Pro on the computer to verify Pro. Local Pro access may still be available."
        case .inactive: return "Pro verification by the computer is paused while Peel is inactive."
        case .denied, .noEvidence: return "The computer could not verify Peel Pro. Local Pro access may still be available."
        case .waitingForMac, .unavailable: return "Pro verification by the computer is unavailable. Local Pro access may still be available."
        }
    }
}

#if canImport(Network) && canImport(StoreKit) && !PEEL_PRO_EVIDENCE_CORE_ONLY
import Network

/// Main-queue-owned, ephemeral coordinator for one actual per-host session.
/// It performs no purchase, restore, AppStore.sync, account prompt or authority request.
final class PeelProEvidenceClient {
    weak var session: PeelHostSession?
    private weak var boundConnection: NWConnection?
    private var fence = PeelProEvidenceFence()
    private var collectionTask: Task<Void, Never>?
    private var deadlineWork: DispatchWorkItem?
    private var statusExpiryWork: DispatchWorkItem?
    private var proofWasSent = false
    private var receivedFinalStatus = false

    init(session: PeelHostSession) { self.session = session }

    deinit {
        collectionTask?.cancel()
        deadlineWork?.cancel()
        statusExpiryWork?.cancel()
    }

    private func publish(_ status: PeelProMacVerificationStatus) {
        guard let session, let browser = session.browser,
              browser.session(for: session.hostKey) === session else { return }
        browser.proMacVerificationByHostKey[session.hostKey] = status
    }

    func connectionDidChange() {
        cancel(withdraw: false, clearSession: true)
        boundConnection = session?.connection
        publish(.waitingForMac)
    }

    func hostHelloDidChange(sourceConnection: NWConnection) {
        guard isAuthenticated(sourceConnection, pairingID: session?.activePairingID) else { return }
        if boundConnection !== sourceConnection { connectionDidChange() }
        if session?.hostCapabilities.contains(PeelProEvidenceLimits.capability) != true {
            cancel(withdraw: true, clearSession: false)
            publish(.unsupported)
        }
    }

    /// Withdrawal is deny-only on the Host. It is sent before losing visibility
    /// or local access and can never grant a different connection's entitlement.
    func localAccessOrVisibilityChanged() {
        cancel(withdraw: true, clearSession: false)
        publish(session?.isClientVisible == false ? .inactive : .waitingForMac)
    }

    func reset() {
        cancel(withdraw: true, clearSession: true)
        boundConnection = nil
        publish(.unavailable)
    }

    private func isAuthenticated(_ source: NWConnection, pairingID: String?) -> Bool {
        guard let session, let browser = session.browser,
              browser.session(for: session.hostKey) === session,
              session.connection === source, session.isConnectionReady,
              !session.didHandleDisconnectForCurrentConnection,
              let pairingID, session.activePairingID == pairingID,
              browser.pairedPeer(forPairingID: pairingID) != nil else { return false }
        return true
    }

    private func isCurrent(_ operation: PeelProEvidenceOperation, source: NWConnection) -> Bool {
        isAuthenticated(source, pairingID: operation.pairingID) && boundConnection === source &&
            session?.isClientVisible == true &&
            session?.hostCapabilities.contains(PeelProEvidenceLimits.capability) == true &&
            fence.isCurrent(operation, now: Date().timeIntervalSince1970,
                            uptime: ProcessInfo.processInfo.systemUptime)
    }

    func receive(_ challenge: PeelProEntitlementChallenge, sourceConnection: NWConnection) {
        guard isAuthenticated(sourceConnection, pairingID: challenge.pairingId),
              session?.isClientVisible == true,
              session?.hostCapabilities.contains(PeelProEvidenceLimits.capability) == true else { return }
        if boundConnection !== sourceConnection { connectionDidChange() }
        guard let operation = fence.begin(requestID: challenge.requestId, nonce: challenge.nonce,
            pairingID: challenge.pairingId, sessionID: challenge.sessionId,
            expiresAt: challenge.expiresAt, now: Date().timeIntervalSince1970,
            uptime: ProcessInfo.processInfo.systemUptime) else { return }

        collectionTask?.cancel()
        deadlineWork?.cancel()
        statusExpiryWork?.cancel()
        proofWasSent = false
        receivedFinalStatus = false
        publish(.checking)
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.fence.operation == operation else { return }
            self.cancel(withdraw: true, clearSession: false)
            self.publish(.unavailable)
        }
        deadlineWork = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, operation.uptimeDeadline - ProcessInfo.processInfo.systemUptime), execute: deadline)

        collectionTask = Task { @MainActor [weak self, weak sourceConnection] in
            guard let self, let sourceConnection, self.isCurrent(operation, source: sourceConnection),
                  !Task.isCancelled else { return }
            // The closure fences both sides of every StoreKit suspension, and a
            // verified update invalidates collection even when local Pro remains.
            let tokens = await PeelStore.signedProTransactionEvidence {
                !Task.isCancelled && self.isCurrent(operation, source: sourceConnection)
            }
            guard !Task.isCancelled, self.isCurrent(operation, source: sourceConnection),
                  let tokens, tokens.count <= PeelProEvidenceLimits.maximumTokens,
                  tokens.allSatisfy({ !$0.isEmpty && $0.utf8.count <= PeelProEvidenceLimits.maximumTokenBytes }) else { return }
            let proof = PeelProEntitlementProof(requestId: operation.requestID,
                nonce: operation.nonce, pairingId: operation.pairingID,
                sessionId: operation.sessionID, signedTransactions: tokens)
            guard let data = try? JSONEncoder().encode(proof),
                  data.count <= PeelProEvidenceLimits.maximumWireBytes,
                  self.isCurrent(operation, source: sourceConnection), !Task.isCancelled else { return }
            self.proofWasSent = true
            if tokens.isEmpty { self.publish(.noEvidence) }
            self.send(data, on: sourceConnection, operation: operation)
        }
    }

    func receive(_ message: PeelProEntitlementStatus, sourceConnection: NWConnection) {
        guard let operation = fence.operation, proofWasSent, !receivedFinalStatus,
              message.requestId == operation.requestID, message.sessionId == operation.sessionID,
              isCurrent(operation, source: sourceConnection) else { return }
        switch message.state {
        case "pending": publish(.checking)
        case "verified":
            let now = Date().timeIntervalSince1970
            guard let expiresAt = message.expiresAt, expiresAt.isFinite, expiresAt > now,
                  expiresAt - now <= PeelProEvidenceLimits.maximumLeaseSeconds else {
                cancel(withdraw: true, clearSession: false)
                publish(.unavailable)
                return
            }
            deadlineWork?.cancel()
            deadlineWork = nil
            receivedFinalStatus = true
            publish(.verified)
            // A wall-clock rollback must not extend the UI's reported lease.
            let uptimeDeadline = ProcessInfo.processInfo.systemUptime + (expiresAt - now)
            let expiry = DispatchWorkItem { [weak self] in
                guard let self, self.fence.operation == operation else { return }
                self.cancel(withdraw: true, clearSession: false)
                self.publish(.unavailable)
            }
            statusExpiryWork?.cancel()
            statusExpiryWork = expiry
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, uptimeDeadline - ProcessInfo.processInfo.systemUptime), execute: expiry)
        case "denied", "unavailable":
            cancel(withdraw: false, clearSession: false)
            publish(message.state == "denied" ? .denied : .unavailable)
        default: break // Never display arbitrary peer-provided reason text.
        }
    }

    private func send(_ data: Data, on source: NWConnection, operation: PeelProEvidenceOperation) {
        guard isCurrent(operation, source: source) else { return }
        var framed = data
        framed.append(0x0A)
        source.send(content: framed, completion: .contentProcessed { [weak self, weak source] error in
            guard error != nil else { return }
            DispatchQueue.main.async {
                guard let self, let source, self.boundConnection === source,
                      self.fence.operation == operation else { return }
                self.cancel(withdraw: false, clearSession: false)
                self.publish(.unavailable)
            }
        })
    }

    private func cancel(withdraw: Bool, clearSession: Bool) {
        let hadOperation = fence.operation != nil
        collectionTask?.cancel()
        collectionTask = nil
        deadlineWork?.cancel()
        deadlineWork = nil
        statusExpiryWork?.cancel()
        statusExpiryWork = nil
        proofWasSent = false
        receivedFinalStatus = false
        if withdraw, hadOperation, let source = boundConnection, let sessionID = fence.sessionID,
           let pairingID = session?.activePairingID, isAuthenticated(source, pairingID: pairingID),
           let data = try? JSONEncoder().encode(PeelProEntitlementWithdrawal(pairingId: pairingID, sessionId: sessionID)) {
            var framed = data
            framed.append(0x0A)
            source.send(content: framed, completion: .contentProcessed { _ in })
        }
        fence.cancel(clearSession: clearSession)
    }
}

extension PeelClientBrowser {
    func proEvidenceClient(for session: PeelHostSession) -> PeelProEvidenceClient {
        if let existing = proEvidenceClients[session.hostKey], existing.session === session { return existing }
        proEvidenceClients[session.hostKey]?.reset()
        let client = PeelProEvidenceClient(session: session)
        proEvidenceClients[session.hostKey] = client
        return client
    }

    func resetProEvidence(for session: PeelHostSession) {
        guard proEvidenceClients[session.hostKey]?.session === session else { return }
        proEvidenceClients.removeValue(forKey: session.hostKey)?.reset()
        proMacVerificationByHostKey.removeValue(forKey: session.hostKey)
    }

    /// Called synchronously on the main queue for a verified StoreKit update,
    /// visibility/lock transition or local Pro-to-free transition, before Hello.
    func invalidateProEvidence() {
        for client in proEvidenceClients.values { client.localAccessOrVisibilityChanged() }
    }
}
#endif
