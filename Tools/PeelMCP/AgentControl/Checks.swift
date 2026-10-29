import Foundation
import AppKit
import Darwin

nonisolated final class ControlResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: PeelLocalAgentHandlerResult?
    func set(_ value: PeelLocalAgentHandlerResult) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> PeelLocalAgentHandlerResult? { lock.lock(); defer { lock.unlock() }; return value }
}

nonisolated final class ControlReceiverClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 100.0
    func now() -> Double { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ amount: Double) { lock.lock(); value += amount; lock.unlock() }
}

final class LegacyManualClientFixture {
    var sent: [PeelManualAgentControlProofMessage] = []
    /* CLIENT_BROWSER_MANUAL_METHOD */
}
final class ManualClientFixture {
    final class Connection {}
    final class PairingStore {
        var key = Data(repeating: 9, count: 32)
        var onRead: (() -> Void)?
        func psk(for id: String) -> Data? { let action = onRead; onRead = nil; action?(); return key }
    }
    final class Browser { let pairingStore = PairingStore() }
    var manualPermission = true, isConnectionReady = true
    var connection: Connection? = Connection()
    var activePairingID: String? = "paired-fixture"
    var browser: Browser? = Browser()
    var lastHandledManualAgentControlChallengeRequestID: String?
    var sent: [PeelManualAgentControlProofMessage] = []
    func sendJSONMessage(_ message: PeelManualAgentControlProofMessage) { sent.append(message) }
    /* CLIENT_SESSION_MANUAL_METHOD */
}

final class ManualProofFixtureHost {
    final class Network {
        var current = PeelControlSession(pairingID: "paired-fixture", generation: 7)
        func isCurrentControlSession(_ session: PeelControlSession) -> Bool { session == current }
    }
    final class PairingStore { struct Peer { let id: String }; var paired = [Peer(id: "paired-fixture")] }
    var agentBridgeEnabled = true, agentControlAllowed = true, hostIsLockedOrAsleep = false, clientIsVisible = true
    var localAgentEpoch = UUID(), agentBridgeStatus = "Ready", agentControlStatus = ""
    var agentClientSession: PeelControlSession? = .init(pairingID: "paired-fixture", generation: 7)
    var agentClientCapabilities: Set<String> = [PeelManualAgentControl.capability]
    let manualAgentTargetSnapshot = PeelAgentTargetSnapshot()
    var manualAgentAuthorizedSession: PeelControlSession?
    var pendingManualAgentChallenge: (message: PeelManualAgentControlChallenge, session: PeelControlSession, key: Data)?
    let network = Network(), pairingStore = PairingStore()
    let input: InputSynthesizer
    let agentWindowControl: PeelAgentWindowControl
    init(input: InputSynthesizer, control: PeelAgentWindowControl) { self.input = input; agentWindowControl = control }
    /// Controlled paid admission: only an exactly admitted session is allowed.
    /// The real permit is compiled by the PaidNotificationAdmission harness.
    var admittedSessions: Set<PeelControlSession> = []
    func commerceAllows(_ session: PeelControlSession) -> Bool { admittedSessions.contains(session) }
    /* HOST_MANUAL_METHODS */
}

@main struct AgentWindowControlChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
    static func main() async throws {
        func fingerprint(title: String = "Fixture", pid: Int32 = 99, launch: Double = 100) -> PeelAgentWindowInstanceFingerprint {
            .init(windowID: 42, ownerProcessID: pid, appBundleIdentifier: "org.peel.fixture", appName: "Fixture",
                title: title, width: 400, height: 300, appLaunchTimeIntervalSince1970: launch, isDisplay: false, displayID: nil)
        }
        let scope = PeelAgentPresentationScope(pairingID: "paired-fixture", generation: 7)
        var leases = PeelAgentControlLeases()
        let instance = fingerprint()
        leases.replace(scope: scope, instances: [instance], now: 100)
        let entry = leases.entry(windowID: 42)!
        require(leases.validate(windowID: 42, token: entry.token, scope: scope, fingerprint: instance, now: 130) != nil, "30s boundary")
        for (candidate, changedScope, now) in [(fingerprint(title: "changed"), scope, 101.0), (fingerprint(pid: 100), scope, 101),
            (fingerprint(launch: 101), scope, 101), (instance, .init(pairingID: "other", generation: 7), 101),
            (instance, .init(pairingID: "paired-fixture", generation: 8), 101), (instance, scope, 130.01), (instance, scope, 99)] {
            require(leases.validate(windowID: 42, token: entry.token, scope: changedScope, fingerprint: candidate, now: now) == nil,
                "stale/recycled/renamed/other-device targets must fail")
        }
        let renderer = UUID(), bounds = [10.0, 20, 400, 300]
        let inspection = leases.inspect(entry, renderer: renderer, bounds: bounds, now: 110)
        require(!leases.takeInspection(id: inspection.id, listed: entry, renderer: UUID(), bounds: bounds, now: 111), "renderer replacement")
        require(!leases.takeInspection(id: inspection.id, listed: entry, renderer: renderer, bounds: bounds, now: 111), "failed take consumes authorization")
        let fresh = leases.inspect(entry, renderer: renderer, bounds: bounds, now: 110)
        require(!leases.takeInspection(id: fresh.id, listed: entry, renderer: renderer, bounds: [11,20,400,300], now: 111), "moved window")
        let expired = leases.inspect(entry, renderer: renderer, bounds: bounds, now: 110)
        require(!leases.takeInspection(id: expired.id, listed: entry, renderer: renderer, bounds: bounds, now: 120.01), "10s inspection expiry")
        let once = leases.inspect(entry, renderer: renderer, bounds: bounds, now: 110)
        require(leases.takeInspection(id: once.id, listed: entry, renderer: renderer, bounds: bounds, now: 120), "inspection boundary")
        require(!leases.takeInspection(id: once.id, listed: entry, renderer: renderer, bounds: bounds, now: 120), "no replay")
        require(leases.admit(now: 100) && !leases.admit(now: 100.249) && leases.admit(now: 100.25), "bounded cadence")
        leases.clear(); require(leases.entry(windowID: 42) == nil, "Stop removes listed capabilities")

        // Real receiver telemetry admission must reject stale, replaced,
        // hidden, unnegotiated and receipt-only spatial views.
        let receiverClock = ControlReceiverClock()
        let receiver = PeelReceiverDiagnostics(uptime: receiverClock.now)
        let receivingRenderer = UUID()
        func metric(kind: PeelClientStreamMetric.RendererKind = .displayLayer, frames: Int64 = 1,
                    enqueued: Int64? = 1, lastAge: Double? = 0, status: Int? = 1,
                    flush: Bool? = false, error: Int? = nil) -> PeelClientStreamMetric {
            .init(windowId: 42, rendererGeneration: receivingRenderer, rendererKind: kind, width: 400, height: 300,
                receivedFrames: frames, receivedBytes: 100, enqueuedFrames: enqueued,
                applicationDroppedFrames: nil, recoveryRequests: nil, queuedFrames: nil, queuedBytes: nil,
                oldestQueuedFrameAgeMilliseconds: nil, lastReceivedFrameAgeMilliseconds: lastAge,
                screenMaximumFPS: nil, displayLayerStatus: status, displayLayerRequiresFlush: flush,
                displayLayerErrorCode: error, avPerformance: nil)
        }
        let healthy = PeelClientStreamMetricsMessage(sequence: 1, sampledAtClientUptimeSeconds: 100, streams: [metric()])
        require(!receiver.accept(healthy, generation: 7), "unnegotiated receiver")
        receiver.setSession(generation: 7, negotiated: true)
        require(receiver.accept(healthy, generation: 7) && receiver.agentControlRenderer(windowID: 42, generation: 7).id == receivingRenderer, "fresh healthy display layer")
        require(receiver.agentControlRenderer(windowID: 42, generation: 8).id == nil && receiver.agentControlRenderer(windowID: 43, generation: 7).id == nil, "exact receiving generation/window")
        receiverClock.advance(6.001)
        require(receiver.agentControlRenderer(windowID: 42, generation: 7).id == nil, "stale report rejected")
        var sequence: UInt64 = 2
        for candidate in [metric(frames: 0), metric(enqueued: 0), metric(lastAge: nil), metric(lastAge: 5001),
            metric(status: 0), metric(status: 2), metric(flush: true), metric(error: 1),
            metric(kind: .spatialUninstrumented, enqueued: nil, status: nil, flush: nil)] {
            receiverClock.advance(1.1)
            let report = PeelClientStreamMetricsMessage(sequence: sequence, sampledAtClientUptimeSeconds: 100, streams: [candidate]); sequence += 1
            require(report.isValid && receiver.accept(report, generation: 7), "bounded peer report accepted")
            require(receiver.agentControlRenderer(windowID: 42, generation: 7).id == nil, "unhealthy/uninstrumented layer never grants control")
        }
        receiver.clearObservation(); require(receiver.agentControlRenderer(windowID: 42, generation: 7).id == nil, "hidden clears control telemetry")
        receiver.setSession(generation: nil, negotiated: false)
        require(receiver.agentControlRenderer(windowID: 42, generation: 7).id == nil, "disconnect clears presentation admission")

        var params: [String: PeelLocalAgentJSONValue] = ["action": .string("click"), "x": .number(0.5), "y": .number(0.5)]
        require(PeelAgentControlCommand.parse(params)?.minimumPostedEvents == 2, "real click parser")
        params["x"] = .number(.nan); require(PeelAgentControlCommand.parse(params) == nil, "NaN rejected")
        params = ["action": .string("type"), "text": .string(String(repeating: "😀", count: 257))]
        require(PeelAgentControlCommand.parse(params) == nil, "UTF8 text bound")
        for text in ["\n", "\t", "\u{85}"] {
            require(PeelAgentControlCommand.parse(["action": .string("type"), "text": .string(text)]) == nil, "text does not hide key commands")
        }
        require(PeelAgentControlCommand.parse(["action": .string("key"), "key": .string("a"), "modifiers": .array([.string("command"), .string("command")])]) == nil, "duplicate modifiers")
        require(PeelAgentControlCommand.parse(["action": .string("mouseDown")]) == nil, "no held state API")

        // Actual Unix descriptor lifecycle: supported SHUT_WR request half-close
        // must remain usable; full close and invalidation must stop deferred input.
        var descriptors: [Int32] = [0,0]
        require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0, "socketpair")
        var enabled: Int32 = 1
        require(setsockopt(descriptors[0], SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0, "nosigpipe")
        let lifetime = PeelLocalAgentRequestLifetime(descriptor: descriptors[0])
        require(lifetime.isActive, "live local request")
        shutdown(descriptors[1], SHUT_WR); require(lifetime.isActive, "request half-close is not disconnect")
        close(descriptors[1]); require(!lifetime.isActive, "full local disconnect detected without payload")
        lifetime.invalidate(); close(descriptors[0]); require(!lifetime.isActive, "closed fd never reused by stale request")

        let focus = AccessibilityManager()
        var events: [CGEvent] = [], admitted = true, hitTarget = true
        var clock = 100.0, activeGeneration: UInt64 = 7
        var cancelAfterDown = false
        var afterDown: (() -> Void)?
        var additionalPolicy: () -> Bool = { true }
        let input = InputSynthesizer(accessibility: focus, eventSink: { event, _ in
            events.append(event)
            if cancelAfterDown && (event.type == .keyDown || event.type == .leftMouseDown) { admitted = false; cancelAfterDown = false }
            if event.type == .keyDown || event.type == .leftMouseDown {
                let callback = afterDown; afterDown = nil; callback?()
            }
        })
        input.isRemoteControlAllowed = { true }
        input.isControlGenerationCurrent = { $0 == activeGeneration }
        input.activeWindowProvider = { 42 }
        // Release/manual consent is independent of unverified paid AI access.
        require(!PeelAIFeatureAccess.isAllowed, "Release fixture has no paid AI subscription")
        require(PeelManualAgentControl.allows(platformSupported: true, optedIn: true), "manual consent works without paid AI")
        require(!PeelManualAgentControl.allows(platformSupported: true, optedIn: false) &&
            !PeelManualAgentControl.allows(platformSupported: false, optedIn: true), "manual permission defaults off/unsupported platforms rejected")
        let challenge = PeelManualAgentControlChallenge(requestId: UUID().uuidString, pairingId: scope.pairingID,
            nonce: Data(repeating: 7, count: 32).base64EncodedString(), expiresAt: Date().timeIntervalSince1970 + 30)
        let key = Data(repeating: 9, count: 32), proof = PeelManualAgentControlProof.make(challenge, key: Data(repeating: 9, count: 32))!
        require(PeelManualAgentControlProof.verify(proof, challenge: challenge, key: key), "manual HMAC")
        let legacyClient = LegacyManualClientFixture()
        legacyClient.receiveManualAgentControlChallenge(challenge)
        require(legacyClient.sent.isEmpty, "legacy browser never answers manual proof")
        let manualClient = ManualClientFixture()
        manualClient.receiveManualAgentControlChallenge(challenge)
        require(manualClient.sent.count == 1 && PeelManualAgentControlProof.verify(manualClient.sent[0].proof, challenge: challenge, key: key), "actual mobile session handler emits bound manual proof without paid AI")
        manualClient.receiveManualAgentControlChallenge(challenge)
        require(manualClient.sent.count == 1, "mobile challenge replay ignored")
        for reason in ["optout", "wrongpair", "closed", "replaced", "revoked-during-proof", "shortkey"] {
            let client = ManualClientFixture()
            switch reason {
            case "optout": client.manualPermission = false
            case "wrongpair": client.activePairingID = "other"
            case "closed": client.connection = nil
            case "replaced": client.browser?.pairingStore.onRead = { client.connection = .init() }
            case "revoked-during-proof": client.browser?.pairingStore.onRead = { client.manualPermission = false }
            default: client.browser?.pairingStore.key = Data(repeating: 9, count: 31)
            }
            client.receiveManualAgentControlChallenge(challenge)
            require(client.sent.isEmpty, "mobile proof must fail closed: \(reason)")
        }
        let paidChallenge = PeelAgentPairingChallengeMessage(requestId: challenge.requestId, pairingId: challenge.pairingId,
            nonce: challenge.nonce, expiresAt: challenge.expiresAt)
        require(!PeelAgentPairingProof.verify(proof, challenge: paidChallenge, key: key), "manual proof cannot authorize old paid actions")
        let paidProof = PeelAgentPairingProof.make(paidChallenge, key: key)!
        require(!PeelManualAgentControlProof.verify(paidProof, challenge: challenge, key: key), "old paid proof cannot authorize manual control")
        let proofHost = ManualProofFixtureHost(input: input, control: PeelAgentWindowControl(capture: { _, _ in nil }))
        let proofSession = proofHost.network.current
        let message = PeelManualAgentControlProofMessage(requestId: challenge.requestId, pairingId: challenge.pairingId, proof: proof)
        proofHost.pendingManualAgentChallenge = (challenge, proofSession, key)
        proofHost.handleManualAgentProof(message, generation: 6)
        require(proofHost.manualAgentAuthorizedSession == nil, "stale proof epoch denied")
        proofHost.agentClientCapabilities = []
        proofHost.handleManualAgentProof(message, generation: 7)
        require(proofHost.manualAgentAuthorizedSession == nil, "old/incapable or withdrawn client rejected")
        proofHost.agentClientCapabilities = [PeelManualAgentControl.capability]
        proofHost.handleManualAgentProof(message, generation: 7)
        require(proofHost.manualAgentAuthorizedSession == proofSession && proofHost.manualAgentTargetSnapshot.current() == proofSession, "exact production manual proof handler authorizes only manual session")
        let proofDeadline = DispatchTime.now().uptimeNanoseconds + 4_000_000_000
        require(!proofHost.manualAgentTargetPolicyAllows(epoch: proofHost.localAgentEpoch, target: proofSession, deadlineUptimeNanoseconds: proofDeadline), "manual policy refuses without paid admission")
        proofHost.admittedSessions = [PeelControlSession(pairingID: proofSession.pairingID, generation: proofSession.generation + 1)]
        require(!proofHost.manualAgentTargetPolicyAllows(epoch: proofHost.localAgentEpoch, target: proofSession, deadlineUptimeNanoseconds: proofDeadline), "admission for another generation does not transfer")
        proofHost.admittedSessions = [PeelControlSession(pairingID: "other-pair", generation: proofSession.generation)]
        require(!proofHost.manualAgentTargetPolicyAllows(epoch: proofHost.localAgentEpoch, target: proofSession, deadlineUptimeNanoseconds: proofDeadline), "admission for another pairing does not transfer")
        proofHost.admittedSessions = [proofSession]
        require(proofHost.manualAgentTargetPolicyAllows(epoch: proofHost.localAgentEpoch, target: proofSession, deadlineUptimeNanoseconds: proofDeadline), "separate production manual policy")
        proofHost.agentClientCapabilities = []
        require(!proofHost.manualAgentTargetPolicyAllows(epoch: proofHost.localAgentEpoch, target: proofSession, deadlineUptimeNanoseconds: proofDeadline), "capability withdrawn blocks deferred actions")
        proofHost.clearManualAgentAuthorization(reason: "withdrawn")
        require(proofHost.manualAgentAuthorizedSession == nil && proofHost.manualAgentTargetSnapshot.current() == nil, "withdrawal clears separate proof generation")

        let session = PeelControlSession(pairingID: scope.pairingID, generation: scope.generation)
        let controller = PeelAgentWindowControl(capture: { windowID, capturedBounds in
            precondition(windowID == 42 && capturedBounds == CGRect(x: 10, y: 20, width: 400, height: 300))
            return .init(data: Data([255,216,255,0]), width: 400, height: 300)
        }, uptime: { clock })
        func context(rendererID: UUID = renderer, rectangle: CGRect = CGRect(x: 10, y: 20, width: 400, height: 300)) -> PeelAgentControlContext {
            .init(session: session, fingerprint: instance, bounds: rectangle, renderer: rendererID,
                validate: { admitted && additionalPolicy() && activeGeneration == session.generation }, validateEvent: { _ in hitTarget })
        }
        func request(_ method: PeelLocalAgentMethod, _ params: [String: PeelLocalAgentJSONValue], lifetime: PeelLocalAgentRequestLifetime = .init()) -> PeelLocalAgentRequest {
            .init(version: 1, id: UUID(), method: method, params: params,
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 4_000_000_000, lifetime: lifetime)
        }
        func wait(_ result: ControlResultBox) async throws -> PeelLocalAgentHandlerResult {
            for _ in 0..<500 { if let value = result.get() { return value }; try await Task.sleep(nanoseconds: 2_000_000) }
            fatalError("operation did not finish")
        }
        func object(_ result: PeelLocalAgentHandlerResult) -> [String: PeelLocalAgentJSONValue] {
            guard case .success(.object(let value)) = result else { fatalError("expected receipt, got \(result)") }; return value
        }
        func listed() -> [String: PeelLocalAgentJSONValue] {
            controller.replace(scope: scope, instances: [instance]); clock += 1
            return ["targetPairingId": .string(scope.pairingID), "windowId": .integer(42), "windowToken": .string(controller.token(windowID: 42)!)]
        }
        func inspect(_ base: [String: PeelLocalAgentJSONValue]) async throws -> String {
            let result = ControlResultBox()
            controller.handle(request(.inspectWindow, base), context: context(), input: input, completion: result.set)
            let snapshot = object(try await wait(result))
            require(snapshot["status"] == .string("captured") && snapshot["imageBase64"] != nil, "real controller capture result")
            guard case .string(let id) = snapshot["inspectionId"] else { fatalError("inspectionId") }
            return id
        }
        for action: [String: PeelLocalAgentJSONValue] in [
            ["action": .string("click"), "x": .number(0.25), "y": .number(0.5)],
            ["action": .string("type"), "text": .string("A😀B")],
            ["action": .string("key"), "key": .string("a"), "modifiers": .array([.string("command"), .string("shift")])],
            ["action": .string("scroll"), "deltaX": .integer(0), "deltaY": .integer(80)],
            ["action": .string("drag"), "x": .number(0.2), "y": .number(0.3), "toX": .number(0.8), "toY": .number(0.7)]
        ] {
            events.removeAll(); let base = listed(); let inspectionID = try await inspect(base)
            var args = base.merging(action, uniquingKeysWith: { _, new in new }); args["inspectionId"] = .string(inspectionID)
            let result = ControlResultBox()
            controller.handle(request(.controlWindow, args), context: context(), input: input, completion: result.set)
            let receipt = object(try await wait(result))
            require(receipt["status"] == .string("events_posted"), "normal real input path: \(action)")
            let expected = PeelAgentControlCommand.parse(args)!.minimumPostedEvents
            require(events.count == expected && receipt["postedEvents"] == .integer(Int64(expected)), "exact real Quartz event count")
            if action["action"] == .string("click") { require(events[0].location == CGPoint(x: 110, y: 170), "inspection geometry is authoritative, not fullscreen heuristics") }
            let replay = ControlResultBox(); clock += 0.3
            controller.handle(request(.controlWindow, args), context: context(), input: input, completion: replay.set)
            guard case .failure(let failure) = replay.get() else { fatalError("replay must fail") }
            require(failure.code == "inspection_required", "single use")
        }
        // Captures and input have separate four-per-second limits. An inspect
        // followed immediately by its action succeeds, while a rate rejection
        // preserves a second valid inspection for a later single use.
        let rateBase = listed(), firstInspection = try await inspect(rateBase)
        clock += 0.25
        let secondInspection = try await inspect(rateBase)
        func rateArgs(_ inspection: String) -> [String: PeelLocalAgentJSONValue] {
            rateBase.merging(["inspectionId": .string(inspection), "action": .string("click"), "x": .number(0.2), "y": .number(0.3)], uniquingKeysWith: { _, new in new })
        }
        let firstRate = ControlResultBox()
        controller.handle(request(.controlWindow, rateArgs(firstInspection)), context: context(), input: input, completion: firstRate.set)
        let firstRateReceipt = object(try await wait(firstRate))
        require(firstRateReceipt["status"] == .string("events_posted"), "immediate capture-to-input admission")
        let rejectedRate = ControlResultBox()
        controller.handle(request(.controlWindow, rateArgs(secondInspection)), context: context(), input: input, completion: rejectedRate.set)
        guard case .failure(let rateError) = rejectedRate.get() else { fatalError("input rate must reject") }
        require(rateError.code == "rate_limited", "actual input cadence")
        clock += 0.25
        let retryRate = ControlResultBox()
        controller.handle(request(.controlWindow, rateArgs(secondInspection)), context: context(), input: input, completion: retryRate.set)
        let retryRateReceipt = object(try await wait(retryRate))
        require(retryRateReceipt["status"] == .string("events_posted"), "rate rejection does not consume inspection")
        let replayRate = ControlResultBox()
        controller.handle(request(.controlWindow, rateArgs(secondInspection)), context: context(), input: input, completion: replayRate.set)
        guard case .failure(let replayError) = replayRate.get() else { fatalError("replay must reject") }
        require(replayError.code == "inspection_required", "accepted inspection is single-use")

        let idleBase = listed(), idleInspection = try await inspect(idleBase)
        require(!controller.isBusy, "inspection has completed before user input")
        controller.cancel(input: input, reason: "Paired user input")
        var idleAction = idleBase
        idleAction.merge(["inspectionId": .string(idleInspection), "action": .string("click"), "x": .number(0.2), "y": .number(0.3)], uniquingKeysWith: { _, new in new })
        let idleRejected = ControlResultBox()
        controller.handle(request(.controlWindow, idleAction), context: context(), input: input, completion: idleRejected.set)
        guard case .failure(let idleError) = idleRejected.get() else { fatalError("user input must revoke idle inspection") }
        require(idleError.code == "window_changed", "manual input revokes even an idle inspected image")

        // Simulate permission/consent/session loss immediately after a down.
        // The real input queue releases the posted down and stops remaining work.
        for drag in [false, true] {
            admitted = true; hitTarget = true; events.removeAll()
            let base = listed(), inspectionID = try await inspect(base)
            var args = base; args["inspectionId"] = .string(inspectionID)
            if drag { args.merge(["action": .string("drag"), "x": .number(0.2), "y": .number(0.3), "toX": .number(0.8), "toY": .number(0.7)], uniquingKeysWith: { _, new in new }) }
            else { args.merge(["action": .string("type"), "text": .string("never finish")], uniquingKeysWith: { _, new in new }) }
            cancelAfterDown = true
            let result = ControlResultBox(); controller.handle(request(.controlWindow, args), context: context(), input: input, completion: result.set)
            let receipt = object(try await wait(result))
            require(receipt["status"] == .string("interrupted") && receipt["postedEvents"] == .integer(1), "cancelled down has honest partial receipt")
            require(events.count == 2 && (events.last!.type == .keyUp || events.last!.type == .leftMouseUp), "held state released once")
        }
        // Explicit Stop, full request lifetime invalidation, replacement control
        // generation and capability withdrawal all stop the real queued drag.
        for reason in ["stop", "disconnect", "generation", "capability"] {
            admitted = true; hitTarget = true; activeGeneration = 7; additionalPolicy = { true }; events.removeAll()
            proofHost.agentClientCapabilities = [PeelManualAgentControl.capability]
            proofHost.manualAgentAuthorizedSession = proofSession; proofHost.manualAgentTargetSnapshot.set(proofSession)
            if reason == "capability" {
                additionalPolicy = { proofHost.manualAgentTargetPolicyAllows(epoch: proofHost.localAgentEpoch,
                    target: proofSession, deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 1_000_000_000) }
            }
            let base = listed(), inspectionID = try await inspect(base)
            let lifetime = PeelLocalAgentRequestLifetime()
            var args = base
            args.merge(["inspectionId": .string(inspectionID), "action": .string("drag"), "x": .number(0.2), "y": .number(0.3), "toX": .number(0.8), "toY": .number(0.7)], uniquingKeysWith: { _, new in new })
            afterDown = {
                switch reason {
                case "stop": controller.cancel(input: input, reason: "Stopped by user")
                case "disconnect": lifetime.invalidate()
                case "generation": activeGeneration = 8
                default: proofHost.agentClientCapabilities = []
                }
            }
            let result = ControlResultBox()
            controller.handle(request(.controlWindow, args, lifetime: lifetime), context: context(), input: input, completion: result.set)
            let receipt = object(try await wait(result))
            require(receipt["status"] == .string("interrupted") && receipt["postedEvents"] == .integer(1), "honest partial receipt after \(reason)")
            require(events.count == 2 && events[0].type == .leftMouseDown && events[1].type == .leftMouseUp,
                "\(reason) releases down once without reviving held pointer state")
            input.resetSessionState()
            require(events.count == 2, "\(reason) cleanup leaves no held input for later reset")
        }
        additionalPolicy = { true }; activeGeneration = 7
        admitted = true; events.removeAll()
        let blockedBase = listed(), blockedInspection = try await inspect(blockedBase)
        var blockedArgs = blockedBase; blockedArgs.merge(["inspectionId": .string(blockedInspection), "action": .string("click"), "x": .number(0.2), "y": .number(0.3)], uniquingKeysWith: { _, new in new })
        hitTarget = false
        let blocked = ControlResultBox(); controller.handle(request(.controlWindow, blockedArgs), context: context(), input: input, completion: blocked.set)
        let blockedReceipt = object(try await wait(blocked))
        require(blockedReceipt["status"] == .string("interrupted") && events.isEmpty, "overlay rejects pointer without input")
        hitTarget = true; admitted = false
        let denied = ControlResultBox(); controller.handle(request(.inspectWindow, listed()), context: context(), input: input, completion: denied.set)
        guard case .failure = denied.get() else { fatalError("revoked consent must fail") }
        admitted = true
        controller.cancel(input: input, reason: "Stopped")
        require(controller.token(windowID: 42) == nil && !controller.isBusy, "Stop clears tokens and active operation")
        activeGeneration = 8
        let stale = ControlResultBox(); controller.handle(request(.inspectWindow, listed()), context: context(), input: input, completion: stale.set)
        guard case .failure = stale.get() else { fatalError("session replaced") }
        print("PASS exact-source window leases, validation, capture protocol, real click/text/key/scroll/drag event path, mis-targeting and cleanup; no OS events posted")
    }
}
