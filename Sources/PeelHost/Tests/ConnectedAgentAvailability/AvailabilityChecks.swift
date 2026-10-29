import Foundation
import Darwin

/* PRODUCTION_TYPES */

// This availability-only fixture does not issue real commerce grants. The
// separate PaidNotificationAdmission harness compiles the actual permit.
nonisolated final class PeelHostProAdmissionPermit: @unchecked Sendable {
    func allows(_ session: PeelControlSession) -> Bool { true }
    func withValidAdmission(for session: PeelControlSession, _ submit: () -> Void) -> Bool { submit(); return true }
}

final class HostNetworkServer {
    var current = PeelControlSession(pairingID: "fixture-pair", generation: 1)
    var sent: [PeelAgentNotificationMessage] = []
    func isCurrentControlSession(_ session: PeelControlSession) -> Bool { session == current }
    func sendTargetedJSONLine(_ message: PeelAgentNotificationMessage, session: PeelControlSession,
                             deadlineUptimeNanoseconds: UInt64,
                             authorization: (@Sendable (_ submit: () -> Void) -> Bool)? = nil,
                             completion: @escaping (Bool) -> Void) {
        let submit = { self.sent.append(message); completion(true) }
        if let authorization { if !authorization(submit) { completion(false) } }
        else { submit() }
    }
}

final class FixturePairingStore {
    struct Peer { let id: String }
    var paired = [Peer(id: "fixture-pair")]
}

final class FixtureHost {
    var agentBridgeEnabled = true
    var localAgentEpoch = UUID()
    var agentBridgeStatus = "Ready"
    var hostIsLockedOrAsleep = false
    var clientIsVisible = true
    let network = HostNetworkServer()
    let pairingStore = FixturePairingStore()
    let agentTargetSnapshot = PeelAgentTargetSnapshot()
    var agentClientSession: PeelControlSession? = .init(pairingID: "fixture-pair", generation: 1)
    var agentAuthorizedSession: PeelControlSession? = .init(pairingID: "fixture-pair", generation: 1)
    var agentClientCapabilities: Set<String> = [PeelCapability.agentPresentationV1.rawValue,
                                              PeelCapability.agentNotificationsV1.rawValue]
    init() { agentTargetSnapshot.set(agentAuthorizedSession) }

    /* PRODUCTION_HOST_BOUNDARIES */
}

nonisolated final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: PeelLocalAgentHandlerResult?
    func set(_ value: PeelLocalAgentHandlerResult) { lock.lock(); result = value; lock.unlock() }
    func get() -> PeelLocalAgentHandlerResult? { lock.lock(); defer { lock.unlock() }; return result }
}

@main
struct AvailabilityChecks {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
    }

    static func main() {
        let preview: Bool
#if DEBUG
        preview = ProcessInfo.processInfo.arguments.contains("--peel-agent-preview")
#else
        preview = false
#endif
        let host = FixtureHost()
        let target = host.network.current
        let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
        func request(_ method: PeelLocalAgentMethod) -> PeelLocalAgentRequest {
            .init(version: 1, id: UUID(), method: method,
                  params: ["targetPairingId": .string(target.pairingID),
                           "title": .string("Fixture"), "message": .string("Fixture body")],
                  deadlineUptimeNanoseconds: deadline)
        }
        for method in PeelLocalAgentMethod.allCases {
            let result = ResultBox()
            host.handleLocalAgentRequest(request(method), epoch: host.localAgentEpoch, target: target,
                                         completion: { result.set($0) })
            let paid = [.launchApp, .presentWindow, .notify].contains(method)
            if paid && !preview {
                require(result.get() == .failure(.init(code: "unavailable",
                    message: PeelConnectedAgentAvailability.unavailableMessage)),
                    "Paired/capable client must not reach production paid dispatch")
            } else {
                require(result.get() == .success(.string("dispatch reached")),
                        "Local observations or explicit Debug preview must reach existing dispatch checks")
            }
        }
        let expired = PeelLocalAgentRequest(version: 1, id: UUID(), method: .getStreamDiagnostics,
                                            params: [:], deadlineUptimeNanoseconds: 0)
        let expiredResult = ResultBox()
        host.handleLocalAgentRequest(expired, epoch: host.localAgentEpoch, target: target,
                                     completion: { expiredResult.set($0) })
        require(expiredResult.get() != .success(.string("dispatch reached")), "Expired local request remains denied")
        require(host.agentTargetPolicyAllows(epoch: host.localAgentEpoch, target: target,
                                              deadlineUptimeNanoseconds: deadline), "Local inventory retains session policy")
        require(host.agentPresentationPolicyAllows(epoch: host.localAgentEpoch, target: target,
                                                    deadlineUptimeNanoseconds: deadline) == preview,
                "Presentation continuations require serving-side availability")
        host.network.current = .init(pairingID: target.pairingID, generation: 2)
        require(!host.agentTargetPolicyAllows(epoch: host.localAgentEpoch, target: target,
                                               deadlineUptimeNanoseconds: deadline), "Old session cannot continue inventory")
        require(!host.agentPresentationPolicyAllows(epoch: host.localAgentEpoch, target: target,
                                                     deadlineUptimeNanoseconds: deadline), "Preview cannot bypass stale session")
        host.network.current = target
        let notificationResult = ResultBox()
        host.notificationDelivery.send(request(.notify), session: target, admissionPermit: PeelHostProAdmissionPermit(), completion: { notificationResult.set($0) })
        require(host.network.sent.count == (preview ? 1 : 0), "Unavailable notification must never be sent")
        if preview {
            let sent = host.network.sent[0]
            host.agentBridgeEnabled = false
            host.notificationDelivery.receive(.init(requestId: sent.requestId, pairingId: target.pairingID,
                                                     status: "accepted"), generation: target.generation)
            require(notificationResult.get() == .failure(.init(code: "target_unavailable",
                message: "Notification authorization ended.")), "Async acknowledgment cannot outlive opt-in")
        } else {
            require(notificationResult.get() != nil, "Unavailable notification completes with failure")
        }
        print("Connected-agent availability, actual admission, session continuations and notification checks passed")
    }
}
