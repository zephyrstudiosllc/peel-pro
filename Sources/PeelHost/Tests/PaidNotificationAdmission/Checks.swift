import Foundation
/* TYPES */
/* LEASE_TYPES */
nonisolated final class ResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: T?
    private var waiters: [CheckedContinuation<T, Never>] = []
    private var calls = 0
    func set(_ value: T) {
        lock.lock(); calls += 1; result = value; let old = waiters; waiters = []; lock.unlock()
        for waiter in old { waiter.resume(returning: value) }
    }
    func get() async -> T {
        await withCheckedContinuation { continuation in
            lock.lock(); if let result { lock.unlock(); continuation.resume(returning: result) }
            else { waiters.append(continuation); lock.unlock() }
        }
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
}
nonisolated final class FixtureConnection: @unchecked Sendable {
    enum Completion { case contentProcessed((Error?) -> Void) }
    private let lock = NSLock()
    private var payloads: [Data] = []
    var data: [Data] { lock.lock(); defer { lock.unlock() }; return payloads }
    func send(content: Data, completion: Completion) {
        lock.lock(); payloads.append(content); lock.unlock()
        if case .contentProcessed(let callback) = completion { callback(nil) }
    }
}
nonisolated final class HostNetworkServer: @unchecked Sendable {
    let outboundSendQueue = DispatchQueue(label: "fixture.outbound")
    let connection = FixtureConnection()
    private let lock = NSLock()
    private var current = PeelControlSession(pairingID: "fixture", generation: 1)
    typealias SendSnapshot = (connection: FixtureConnection, generation: UInt64)
    func replace() { lock.lock(); current = .init(pairingID: "fixture", generation: 2); lock.unlock() }
    func targetSendSnapshot(_ session: PeelControlSession) -> SendSnapshot? {
        lock.lock(); defer { lock.unlock() }; return session == current ? (connection, current.generation) : nil
    }
    func isCurrentSendSnapshot(_ snapshot: SendSnapshot) -> Bool {
        lock.lock(); defer { lock.unlock() }; return snapshot.generation == current.generation && snapshot.connection === connection
    }
    func isCurrentControlSession(_ session: PeelControlSession) -> Bool { targetSendSnapshot(session) != nil }
    /* PRODUCTION_SEND */
}
@main struct Checks {
    static func permit(_ session: PeelControlSession) -> PeelHostProAdmissionPermit {
        .init(lease: .init(binding: .init(pairingID: session.pairingID, generation: session.generation, sessionID: UUID().uuidString),
            wallExpiry: Date().timeIntervalSince1970 + 300, monotonicExpiry: ProcessInfo.processInfo.systemUptime + 300))
    }
    static func request(deadline: UInt64 = DispatchTime.now().uptimeNanoseconds + 10_000_000_000) -> PeelLocalAgentRequest {
        .init(version: 1, id: UUID(), method: .notify, params: ["targetPairingId": .string("fixture"), "title": .string("Fixture"), "message": .string("Body")], deadlineUptimeNanoseconds: deadline)
    }
    static func blocked(_ network: HostNetworkServer) -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0); network.outboundSendQueue.async { gate.wait() }; return gate
    }
    static func failed(_ result: PeelLocalAgentHandlerResult) -> Bool { if case .failure = result { return true }; return false }
    static func main() async {
        let session = PeelControlSession(pairingID: "fixture", generation: 1)
        // Revoked after admission but before actual outbound enqueue: no packet.
        do {
            let network = HostNetworkServer(), captured = permit(session), result = ResultBox<PeelLocalAgentHandlerResult>()
            let delivery = PeelAgentNotificationDelivery(network: network, isAllowed: { _ in true })
            let gate = blocked(network)
            delivery.send(request(), session: session, admissionPermit: captured, completion: { result.set($0) })
            captured.invalidate(); gate.signal()
            let outcome = await result.get(); precondition(failed(outcome) && network.connection.data.isEmpty)
            delivery.cancelAll(); precondition(result.count == 1, "Queued revoke completes once")
        }
        // Nil authorization remains the normal free path, with one completion.
        do {
            let network = HostNetworkServer(), result = ResultBox<Bool>()
            network.sendTargetedJSONLine(["free": "ordinary"], session: session) { result.set($0) }
            let outcome = await result.get(); precondition(outcome); precondition(network.connection.data.count == 1 && result.count == 1)
        }
        // The synchronous mock callback must not run user completion under permit.
        do {
            let network = HostNetworkServer(), captured = permit(session), result = ResultBox<Bool>()
            network.sendTargetedJSONLine(["paid": "fixture"], session: session,
                authorization: { submit in captured.withValidAdmission(for: session, submit) }) { sent in
                    captured.invalidate(); result.set(sent)
                }
            let outcome = await result.get(); precondition(outcome); precondition(network.connection.data.count == 1 && result.count == 1)
        }
        // Existing socket-generation guard precedes optional authorization.
        do {
            let network = HostNetworkServer(), captured = permit(session), result = ResultBox<Bool>()
            let gate = blocked(network)
            network.sendTargetedJSONLine(["paid": "fixture"], session: session,
                authorization: { submit in captured.withValidAdmission(for: session, submit) }) { result.set($0) }
            network.replace(); gate.signal()
            let outcome = await result.get(); precondition(!outcome && network.connection.data.isEmpty && result.count == 1)
        }
        // A new current grant cannot revive pending work under the old permit.
        do {
            let network = HostNetworkServer(), captured = permit(session), result = ResultBox<PeelLocalAgentHandlerResult>()
            let delivery = PeelAgentNotificationDelivery(network: network, isAllowed: { _ in true })
            delivery.send(request(), session: session, admissionPermit: captured, completion: { result.set($0) })
            let enqueued = ResultBox<Bool>()
            network.outboundSendQueue.async { enqueued.set(true) }; _ = await enqueued.get()
            precondition(network.connection.data.count == 1)
            let sent = try! JSONDecoder().decode(PeelAgentNotificationMessage.self, from: network.connection.data[0])
            captured.invalidate(); let replacement = permit(session); precondition(replacement.allows(session))
            delivery.receive(.init(requestId: sent.requestId, pairingId: session.pairingID, status: "accepted"), generation: session.generation)
            let outcome = await result.get(); precondition(failed(outcome))
            delivery.receive(.init(requestId: sent.requestId, pairingId: session.pairingID, status: "accepted"), generation: session.generation)
            delivery.cancelAll(); precondition(result.count == 1)
        }
        // Initial invalid permit is rejected even with an allowed current policy.
        do {
            let network = HostNetworkServer(), captured = permit(session), result = ResultBox<PeelLocalAgentHandlerResult>()
            captured.invalidate()
            let delivery = PeelAgentNotificationDelivery(network: network, isAllowed: { _ in true })
            delivery.send(request(), session: session, admissionPermit: captured, completion: { result.set($0) })
            let outcome = await result.get(); precondition(failed(outcome) && network.connection.data.isEmpty && result.count == 1)
        }
        print("PaidNotificationAdmission PASS: queued revoke, original ACK permit, free nil path, socket generation, immediate enqueue/callback separation and exactly-once completion. No sockets or devices.")
    }
}
