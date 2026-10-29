#if os(iOS) || os(visionOS)
import Foundation
import Network

/// Apple client receiver for the authenticated control-session notification
/// message. The legacy browser receiver intentionally has no corresponding
/// case, so a legacy socket cannot advertise or consume this capability.
extension PeelHostSession {
    /// Start a fresh local admission scope at every control-socket boundary.
    /// This does not revoke OS permission or clear the app-owned inbox.
    func resetRemoteNotificationState() {
        remoteNotificationSessionID = UUID()
        remoteNotificationAdmissionPolicy.reset()
    }

    @MainActor
    func receiveAgentNotification(
        _ message: PeelAgentNotificationMessage,
        sourceConnection: NWConnection
    ) {
        let now = Date().timeIntervalSince1970
        let sessionID = remoteNotificationSessionID
        let pairingID = message.pairingId
        let requestID = message.requestId

        // Keep the originating socket and pairing in the closure. A selected
        // session or a replacement socket must never receive this request's
        // result or complete its local delivery.
        let isCurrent: PeelLocalRemoteNotificationPresenter.IsCurrent = {
            [weak self] admission in
            guard let self else { return false }
            return self.isCurrentRemoteNotification(
                admission,
                sourceConnection: sourceConnection,
                pairingID: pairingID,
                sessionID: sessionID
            )
        }

        guard isCurrentAdmissionContext(
            sourceConnection: sourceConnection,
            pairingID: pairingID,
            sessionID: sessionID,
            now: now
        ) else {
            sendAgentNotificationResult(
                requestID: requestID,
                pairingID: pairingID,
                status: "rejected",
                sourceConnection: sourceConnection
            )
            return
        }

        let localMessage = PeelRemoteNotificationMessage(
            requestId: requestID,
            sessionId: sessionID.uuidString,
            title: message.title,
            body: message.message,
            issuedAt: now,
            expiresAt: message.expiresAt
        )

        let admission: PeelRemoteNotificationAdmission
        switch remoteNotificationAdmissionPolicy.admit(localMessage, now: now) {
        case .success(let accepted):
            admission = accepted
        case .failure:
            sendAgentNotificationResult(
                requestID: requestID,
                pairingID: pairingID,
                status: "rejected",
                sourceConnection: sourceConnection
            )
            return
        }

        PeelLocalRemoteNotificationPresenter.shared.enqueue(
            admission: admission,
            isCurrent: isCurrent
        ) { [weak self] result in
            guard let self else { return }

            let status: String
            switch result {
            case .success:
                status = "accepted"
            case .failure:
                status = "rejected"
            }

            // A stale completion is rejected on the original socket only if
            // that socket is still the current pairing. The presenter has
            // already removed its exact pending/delivered identifier before
            // this callback when the generation or callback check failed.
            self.sendAgentNotificationResult(
                requestID: requestID,
                pairingID: pairingID,
                status: status,
                sourceConnection: sourceConnection
            )
        }
    }

    private func isCurrentAdmissionContext(
        sourceConnection: NWConnection,
        pairingID: String,
        sessionID: UUID,
        now: TimeInterval
    ) -> Bool {
        guard connection === sourceConnection,
              isConnectionReady,
              isClientVisible,
              activePairingID == pairingID,
              remoteNotificationSessionID == sessionID,
              PeelAgentNotifications.isOptedIn,
              now.isFinite else {
            return false
        }
        return true
    }

    private func isCurrentRemoteNotification(
        _ admission: PeelRemoteNotificationAdmission,
        sourceConnection: NWConnection,
        pairingID: String,
        sessionID: UUID
    ) -> Bool {
        let now = Date().timeIntervalSince1970
        guard isCurrentAdmissionContext(
            sourceConnection: sourceConnection,
            pairingID: pairingID,
            sessionID: sessionID,
            now: now
        ) else {
            return false
        }
        return admission.expiresAt > now
    }

    private func sendAgentNotificationResult(
        requestID: String,
        pairingID: String,
        status: String,
        sourceConnection: NWConnection
    ) {
        guard connection === sourceConnection,
              isConnectionReady,
              activePairingID == pairingID else {
            return
        }

        sendJSONMessage(
            PeelAgentNotificationResultMessage(
                requestId: requestID,
                pairingId: pairingID,
                status: status
            )
        )
    }
}
#endif
