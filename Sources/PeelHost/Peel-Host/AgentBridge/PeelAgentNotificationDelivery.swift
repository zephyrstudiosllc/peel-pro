import Foundation

/// Delivery completes only on an acknowledgment from the proved target session.
/// An accepted notification is not a claim that the person has read it.
final class PeelAgentNotificationDelivery {
    private struct Pending {
        let session: PeelControlSession
        let admissionPermit: PeelHostProAdmissionPermit
        let deadline: UInt64
        let completion: PeelLocalAgentServer.Completion
    }
    private let network: HostNetworkServer
    private let isAllowed: (PeelControlSession) -> Bool
    private var pending: [UUID: Pending] = [:]
    private var sentTimes: [UInt64] = []

    init(network: HostNetworkServer, isAllowed: @escaping (PeelControlSession) -> Bool) {
        self.network = network
        self.isAllowed = isAllowed
    }

    func send(_ request: PeelLocalAgentRequest, session: PeelControlSession,
              admissionPermit: PeelHostProAdmissionPermit,
              completion: @escaping PeelLocalAgentServer.Completion) {
        guard Set(request.params.keys) == ["targetPairingId", "title", "message"],
              case .string(let title) = request.params["title"],
              case .string(let body) = request.params["message"],
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.count <= 120, title.utf8.count <= 480,
              body.count <= 2000, body.utf8.count <= 8000,
              !title.utf8.contains(0), !body.utf8.contains(0) else {
            completion(.failure(.init(code: "invalid_params", message: "Use a title up to 120 characters and a message up to 2000 characters.")))
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        guard isAllowed(session), admissionPermit.allows(session), request.deadlineUptimeNanoseconds > now + 100_000_000 else {
            completion(.failure(.init(code: "target_unavailable", message: "Connect and enable agent notifications on the paired iPad.")))
            return
        }
        sentTimes.removeAll { now >= $0 && now - $0 >= 60_000_000_000 }
        guard pending.count < 4, sentTimes.count < 5 else {
            completion(.failure(.init(code: "rate_limited", message: "Wait before sending another notification.")))
            return
        }
        sentTimes.append(now)
        let id = UUID()
        let deadline = request.deadlineUptimeNanoseconds - 100_000_000
        pending[id] = Pending(session: session, admissionPermit: admissionPermit, deadline: deadline, completion: completion)
        let remaining = min(Double(deadline - now) / 1_000_000_000, 60)
        let message = PeelAgentNotificationMessage(requestId: id.uuidString, pairingId: session.pairingID,
            title: title, message: body, expiresAt: Date().timeIntervalSince1970 + remaining)
        network.sendTargetedJSONLine(message, session: session, deadlineUptimeNanoseconds: deadline,
            authorization: { submit in admissionPermit.withValidAdmission(for: session, submit) }) { [weak self] sent in
            guard !sent else { return }
            self?.finish(id, error: .init(code: "target_unavailable", message: "Notification could not reach the paired iPad."))
        }
        DispatchQueue.main.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadline)) { [weak self] in
            self?.finish(id, error: .init(code: "timeout", message: "The iPad did not acknowledge this notification."))
        }
    }

    func receive(_ result: PeelAgentNotificationResultMessage, generation: UInt64) {
        guard let id = UUID(uuidString: result.requestId), let context = pending[id],
              context.session.generation == generation, context.session.pairingID == result.pairingId else { return }
        guard DispatchTime.now().uptimeNanoseconds < context.deadline, isAllowed(context.session), context.admissionPermit.allows(context.session) else {
            finish(id, error: .init(code: "target_unavailable", message: "Notification authorization ended.")); return
        }
        pending.removeValue(forKey: id)
        if result.status == "accepted" {
            context.completion(.success(.object([
                "requestId": .string(id.uuidString),
                "targetPairingId": .string(context.session.pairingID),
                "status": .string("accepted"),
                "message": .string("The iPad accepted the notification; this does not confirm it was read.")
            ])))
        } else {
            context.completion(.failure(.init(code: "notification_rejected", message: "The iPad declined this notification.")))
        }
    }

    func cancelAll() {
        let old = pending
        pending.removeAll()
        sentTimes.removeAll()
        for context in old.values {
            context.completion(.failure(.init(code: "target_unavailable", message: "Notification authorization ended.")))
        }
    }

    private func finish(_ id: UUID, error: PeelLocalAgentResponseError) {
        pending.removeValue(forKey: id)?.completion(.failure(error))
    }
}
