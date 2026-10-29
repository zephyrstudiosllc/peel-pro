import Combine
import Foundation
import Network

// Focused startup-diagnostic checks for the actual PeelTrustedSidePulseService
// and PeelUnavailableSignalService. Only dependency outcomes are faked here:
// in-memory pairing metadata, synthetic non-secret keys, recording
// listener/browser drivers and a captured retry scheduler. These facades make
// no TLS, authentication, Bonjour or pairing acceptance claim.
#if !PEEL_SIGNAL_STARTUP_TESTS
#error("Build this fixture only with -D PEEL_SIGNAL_STARTUP_TESTS; it must never use real network or pairing storage.")
#endif

// MARK: - In-memory pairing and TLS facades (real PeelTLS.swift is excluded)

enum PeelTLSPSKOrder: String, Codable, Hashable {
    case standard = "psk-identity"
}

struct PeelPairedPeer: Identifiable, Codable, Hashable {
    let id: String
    var displayName: String
    var serviceName: String?
    var stableHostId: String?
}

final class PeelPairingStore: ObservableObject {
    @Published private(set) var paired: [PeelPairedPeer]
    private let keys: [String: Data]
    private(set) var pskReads = 0

    init(paired: [PeelPairedPeer], keys: [String: Data]) {
        self.paired = paired
        self.keys = keys
    }

    func psk(for pairingID: String) -> Data? {
        pskReads += 1
        return keys[pairingID]
    }
}

enum PeelTLS {
    static func makeHostParameters(pairedPeers: [PeelPairedPeer], keyProvider: (String) -> Data?) -> NWParameters {
        .tcp
    }

    static func makeClientParameters(pairingID: String, psk: Data, pskOrder: PeelTLSPSKOrder) -> NWParameters {
        .tcp
    }
}

// MARK: - Recording drivers used through the service's test-only aliases

enum PeelSignalStartupTestHooks {
    static var listenerAttempts = 0
    static var nextListenerError: NWError?
    static var listeners: [PeelSignalStartupTestListener] = []
    static var browsers: [PeelSignalStartupTestBrowser] = []
    static var retries: [(delay: TimeInterval, work: @MainActor () -> Void)] = []

    static func scheduleRetry(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        retries.append((delay, work))
    }

    static func reset() {
        listenerAttempts = 0
        nextListenerError = nil
        listeners = []
        browsers = []
        retries = []
    }
}

final class PeelSignalStartupTestListener {
    var service: NWListener.Service?
    var stateUpdateHandler: (@Sendable (NWListener.State) -> Void)?
    var newConnectionHandler: (@Sendable (NWConnection) -> Void)?
    /// The handler the service registered before start; kept after the
    /// service clears it so late (stale) callbacks can be delivered.
    private(set) var registeredStateHandler: (@Sendable (NWListener.State) -> Void)?
    private(set) var started = false
    private(set) var cancelled = false

    init(using parameters: NWParameters) throws {
        PeelSignalStartupTestHooks.listenerAttempts += 1
        if let error = PeelSignalStartupTestHooks.nextListenerError {
            PeelSignalStartupTestHooks.nextListenerError = nil
            throw error
        }
        PeelSignalStartupTestHooks.listeners.append(self)
    }

    func start(queue: DispatchQueue) {
        started = true
        registeredStateHandler = stateUpdateHandler
    }

    func cancel() { cancelled = true }

    func deliver(_ state: NWListener.State) { registeredStateHandler?(state) }
}

final class PeelSignalStartupTestBrowser {
    var stateUpdateHandler: (@Sendable (NWBrowser.State) -> Void)?
    var browseResultsChangedHandler: (@Sendable (Set<NWBrowser.Result>, Set<NWBrowser.Result.Change>) -> Void)?
    private(set) var registeredStateHandler: (@Sendable (NWBrowser.State) -> Void)?
    private(set) var started = false
    private(set) var cancelled = false

    init(for descriptor: NWBrowser.Descriptor, using parameters: NWParameters) {
        PeelSignalStartupTestHooks.browsers.append(self)
    }

    func start(queue: DispatchQueue) {
        started = true
        registeredStateHandler = stateUpdateHandler
    }

    func cancel() { cancelled = true }

    func deliver(_ state: NWBrowser.State) { registeredStateHandler?(state) }
}

/// Records what the actual service emits. Optionally passes each snapshot
/// through the production log gate for the given install token.
nonisolated final class StartupCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSnapshots: [NearbySignalServiceSnapshot] = []
    private var storedStatuses: [String] = []
    private var storedCodes: [NearbySignalStartupCode] = []
    private let gate: NearbySignalStartupLogGate?
    private let install: UUID?

    init(gate: NearbySignalStartupLogGate? = nil, install: UUID? = nil) {
        self.gate = gate
        self.install = install
    }

    var onSnapshot: @Sendable (NearbySignalServiceSnapshot) -> Void {
        { [self] snapshot in
            let code = install.flatMap { token in gate?.admit(snapshot.startup, install: token) }
            lock.withLock {
                storedSnapshots.append(snapshot)
                if let code { storedCodes.append(code) }
            }
        }
    }

    var onStatus: @Sendable (String) -> Void {
        { [self] status in lock.withLock { storedStatuses.append(status) } }
    }

    var snapshots: [NearbySignalServiceSnapshot] { lock.withLock { storedSnapshots } }
    var statuses: [String] { lock.withLock { storedStatuses } }
    var codes: [NearbySignalStartupCode] { lock.withLock { storedCodes } }
    var latest: NearbySignalStartupAvailability? { snapshots.last?.startup }
}

// MARK: - Checks

@main
enum PeelTrustedSidePulseStartupChecks {
    private static let localHostID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private static let localNodeID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private static let remoteHostID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private static let pairingID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private static let syntheticKey = Data(repeating: 0x5A, count: 32)

    private typealias Hooks = PeelSignalStartupTestHooks

    static func main() async {
        await testAgentsOnLEDOffEmptyTrust()
        await testKeyUnavailable()
        testUnavailableIdentityStub()
        await testListenerConstructorFailure()
        await testAsyncFailureRetryRecoveryAndStaleCallbacks()
        await testBothComponentsFailListenerFirst()
        await testBothComponentsFailBrowserFirst()
        await testConfigurationScopes()
        await testAllOffUnchangedConfigure()
        testLogGate()
        await testLogGateWithServiceAndNewInstall()
        print("Peel trusted SidePulse startup checks passed")
    }

    // Agents ON, LED sharing/discovery OFF, no usable trust.
    private static func testAgentsOnLEDOffEmptyTrust() async {
        Hooks.reset()
        let store = PeelPairingStore(paired: [], keys: [:])
        let (service, capture) = await makeService(store)
        service.configurePeerAgents(agents(share: true, receive: true, activate: true, usage: true))
        service.configure(.localOnly)
        await settle()
        check(Hooks.listenerAttempts == 0, "Empty usable trust must not request a listener")
        check(Hooks.browsers.count == 1 && Hooks.browsers[0].started, "Agent receive requests the browser")
        check(capture.latest == .noUsablePairedTrust(pairedKeyUnavailable: false),
              "Agents ON with empty trust must report no usable paired trust")
        check(store.pskReads == 0, "No credential reads without paired records")

        let snapshots = capture.snapshots.count
        let statuses = capture.statuses.count
        service.configure(.localOnly)
        await settle()
        check(capture.snapshots.count == snapshots && capture.statuses.count == statuses,
              "Unchanged configure must not republish")
        check(Hooks.browsers.count == 1 && !Hooks.browsers[0].cancelled, "Unchanged configure must not restart")

        service.stop()
        check(Hooks.browsers[0].cancelled, "Stop cancels the browser")
        check(capture.latest == .disabled, "Stop reports disabled")
        check(Hooks.retries.isEmpty, "No retry was scheduled")
    }

    // A paired record whose key cannot be read.
    private static func testKeyUnavailable() async {
        Hooks.reset()
        let store = PeelPairingStore(paired: [pairedRecord()], keys: [:])
        let (service, capture) = await makeService(store)
        check(store.pskReads == 1, "Trust delivery reads the key once")
        check(capture.latest == .disabled, "Nothing requested yet")

        service.configurePeerAgents(agents(share: true, receive: false))
        check(capture.latest == .noUsablePairedTrust(pairedKeyUnavailable: true),
              "An unreadable paired key is reported distinctly")
        service.configure(led(share: true, discover: false))
        check(capture.latest == .noUsablePairedTrust(pairedKeyUnavailable: true), "LED sharing alone cannot start without trust")
        check(Hooks.listenerAttempts == 0 && Hooks.browsers.isEmpty, "No listener or browser without usable trust")
        check(store.pskReads == 1, "Diagnostic publication adds no credential reads")
        service.stop()
    }

    // The actual identity-unavailable stub.
    private static func testUnavailableIdentityStub() {
        Hooks.reset()
        let capture = StartupCapture()
        let stub = PeelUnavailableSignalService(onStatus: capture.onStatus, onSnapshot: capture.onSnapshot)
        stub.configure(led(share: true, discover: true))
        var expected = NearbySignalServiceSnapshot.localOnly
        expected.startup = .identityUnavailable
        check(capture.snapshots == [expected], "Stub publishes one typed identity-unavailable snapshot")
        check(capture.statuses.count == 1, "Stub status publication is unchanged")
        check(Hooks.listenerAttempts == 0 && Hooks.browsers.isEmpty && Hooks.retries.isEmpty,
              "Stub starts no listener, browser or retry")
        stub.stop()

        // The pre-existing initializer remains valid.
        let legacy = PeelUnavailableSignalService(onStatus: { _ in })
        legacy.configure(.localOnly)
        check(NearbySignalServiceSnapshot.localOnly.startup == .notStarted, "Default snapshot is not started")
    }

    // NWListener constructor throws; the following normal publish keeps the failure.
    private static func testListenerConstructorFailure() async {
        Hooks.reset()
        let store = PeelPairingStore(paired: [pairedRecord()], keys: [pairingID.uuidString: syntheticKey])
        let (service, capture) = await makeService(store)
        let reads = store.pskReads
        Hooks.nextListenerError = .posix(.EADDRINUSE)
        let statusesBefore = capture.statuses.count
        service.configurePeerAgents(agents(share: true, receive: true))
        check(Hooks.listenerAttempts == 1 && Hooks.listeners.isEmpty, "Constructor was attempted and failed")
        check(capture.statuses.count >= statusesBefore + 2, "Failure status and the normal publication both ran")
        check(capture.latest == .failed(.listenerCreate), "Normal publish after the constructor failure keeps it")
        check(Hooks.retries.isEmpty, "Constructor failure schedules no retry, as before")

        check(Hooks.browsers.count == 1, "Browser still starts")
        Hooks.browsers[0].deliver(.ready)
        await settle()
        check(capture.latest == .failed(.listenerCreate), "Browser ready does not clear a listener failure")

        // An explicit stop and a new configuration clear it.
        service.stop()
        check(capture.latest == .disabled, "Stop clears to disabled")
        service.configurePeerAgents(agents(share: true, receive: false))
        check(Hooks.listeners.count == 1 && Hooks.listeners[0].started, "New configuration creates a listener")
        check(capture.latest == .preparing(.listenOnly), "Failure does not survive a configuration change")
        Hooks.listeners[0].deliver(.ready)
        await settle()
        check(capture.latest == .localReady(.listenOnly), "Current listener ready is local readiness")
        check(store.pskReads == reads, "Diagnostic publication adds no credential reads")
        service.stop()
    }

    // Async listener/browser failure, actual retry, recovery and stale callbacks.
    private static func testAsyncFailureRetryRecoveryAndStaleCallbacks() async {
        Hooks.reset()
        let store = PeelPairingStore(paired: [pairedRecord()], keys: [pairingID.uuidString: syntheticKey])
        let (service, capture) = await makeService(store)
        let reads = store.pskReads
        service.configurePeerAgents(agents(share: true, receive: true))
        check(Hooks.listeners.count == 1 && Hooks.browsers.count == 1, "Listen and browse requested")
        let firstListener = Hooks.listeners[0]
        let firstBrowser = Hooks.browsers[0]
        check(capture.latest == .preparing(.listenAndBrowse), "Preparing before ready")
        firstListener.deliver(.ready)
        await settle()
        check(capture.latest == .preparing(.listenAndBrowse), "Both components must be ready")
        firstBrowser.deliver(.ready)
        await settle()
        check(capture.latest == .localReady(.listenAndBrowse), "Both ready")

        firstListener.deliver(.failed(.posix(.ECONNABORTED)))
        await settle()
        check(capture.latest == .failed(.listenerFailed), "Async listener failure is retained")
        check(Hooks.retries.count == 1 && Hooks.retries[0].delay == 3, "Existing 3 second retry is scheduled")
        firstBrowser.deliver(.ready)
        await settle()
        check(capture.latest == .failed(.listenerFailed), "A later normal publish keeps the failure")

        let firstRetry = Hooks.retries[0].work
        firstRetry()
        check(firstListener.cancelled && firstBrowser.cancelled, "Retry restart cancels the old generation")
        check(Hooks.listeners.count == 2 && Hooks.browsers.count == 2, "Retry creates a new generation")
        let secondListener = Hooks.listeners[1]
        let secondBrowser = Hooks.browsers[1]
        check(secondListener.started && secondBrowser.started, "New generation started")
        check(capture.latest == .failed(.listenerFailed), "Failure survives the actual retry until a real ready")

        // Stale callbacks and the stale retry change nothing.
        firstListener.deliver(.ready)
        firstBrowser.deliver(.failed(.posix(.ECONNABORTED)))
        await settle()
        check(capture.latest == .failed(.listenerFailed), "Stale ready/failure cannot change current state")
        check(Hooks.retries.count == 1, "Stale failure schedules no retry")
        firstRetry()
        check(Hooks.listeners.count == 2 && Hooks.browsers.count == 2, "Stale retry does not restart")

        secondBrowser.deliver(.ready)
        await settle()
        check(capture.latest == .failed(.listenerFailed), "Browser ready does not clear a listener failure")
        secondListener.deliver(.ready)
        await settle()
        check(capture.latest == .localReady(.listenAndBrowse), "Current listener ready recovers")

        secondBrowser.deliver(.failed(.posix(.ECONNABORTED)))
        await settle()
        check(capture.latest == .failed(.browserFailed), "Async browser failure is retained")
        check(Hooks.retries.count == 2 && Hooks.retries[1].delay == 3, "Existing 3 second retry is scheduled")
        secondListener.deliver(.ready)
        await settle()
        check(capture.latest == .failed(.browserFailed), "A later normal publish keeps the browser failure")

        let secondRetry = Hooks.retries[1].work
        service.stop()
        check(secondListener.cancelled && secondBrowser.cancelled, "Stop cancels listener and browser")
        check(capture.latest == .disabled, "Stop reports disabled")
        secondRetry()
        secondListener.deliver(.ready)
        await settle()
        check(Hooks.listeners.count == 2 && Hooks.browsers.count == 2, "Retry after stop does not restart")
        check(capture.latest == .disabled, "Callbacks after stop do not change state")
        check(store.pskReads == reads, "Retries and diagnostics add no credential reads")
    }

    // Listener then browser fail; after the actual retry only the new browser
    // becomes ready, so the listener failure must still be reported.
    private static func testBothComponentsFailListenerFirst() async {
        Hooks.reset()
        let store = PeelPairingStore(paired: [pairedRecord()], keys: [pairingID.uuidString: syntheticKey])
        let (service, capture) = await makeService(store)
        let reads = store.pskReads
        service.configurePeerAgents(agents(share: true, receive: true))
        let firstListener = Hooks.listeners[0]
        let firstBrowser = Hooks.browsers[0]
        firstListener.deliver(.ready)
        firstBrowser.deliver(.ready)
        await settle()
        check(capture.latest == .localReady(.listenAndBrowse), "Both ready before failures")

        firstListener.deliver(.failed(.posix(.ECONNABORTED)))
        firstBrowser.deliver(.failed(.posix(.ECONNABORTED)))
        await settle()
        check(capture.latest == .failed(.listenerFailed), "Listener failure is reported while both are outstanding")
        check(Hooks.retries.count == 2 && Hooks.retries.allSatisfy { $0.delay == 3 }, "Each failure schedules the existing retry")

        let currentRetry = Hooks.retries[0].work
        let staleRetry = Hooks.retries[1].work
        currentRetry()
        check(Hooks.listeners.count == 2 && Hooks.browsers.count == 2, "Actual retry creates a new generation")
        let secondListener = Hooks.listeners[1]
        let secondBrowser = Hooks.browsers[1]
        check(capture.latest == .failed(.listenerFailed), "Both failures survive the actual retry")
        staleRetry()
        check(Hooks.listeners.count == 2 && Hooks.browsers.count == 2, "Second retry for the old generation is stale")

        secondBrowser.deliver(.ready)
        await settle()
        check(capture.latest == .failed(.listenerFailed), "New browser ready must not clear the listener failure")
        secondListener.deliver(.ready)
        await settle()
        check(capture.latest == .localReady(.listenAndBrowse), "New listener ready recovers")
        check(store.pskReads == reads, "Retries and diagnostics add no credential reads")
        service.stop()
    }

    // Browser then listener fail; after the actual retry only the new listener
    // becomes ready, so the browser failure must still be reported.
    private static func testBothComponentsFailBrowserFirst() async {
        Hooks.reset()
        let store = PeelPairingStore(paired: [pairedRecord()], keys: [pairingID.uuidString: syntheticKey])
        let (service, capture) = await makeService(store)
        let reads = store.pskReads
        service.configurePeerAgents(agents(share: true, receive: true))
        let firstListener = Hooks.listeners[0]
        let firstBrowser = Hooks.browsers[0]
        firstListener.deliver(.ready)
        firstBrowser.deliver(.ready)
        await settle()

        firstBrowser.deliver(.failed(.posix(.ECONNABORTED)))
        firstListener.deliver(.failed(.posix(.ECONNABORTED)))
        await settle()
        check(capture.latest == .failed(.listenerFailed), "Failure selection is deterministic when both are outstanding")
        check(Hooks.retries.count == 2, "Each failure schedules the existing retry")

        Hooks.retries[0].work()
        check(Hooks.listeners.count == 2 && Hooks.browsers.count == 2, "Actual retry creates a new generation")
        let secondListener = Hooks.listeners[1]
        let secondBrowser = Hooks.browsers[1]
        Hooks.retries[1].work()
        check(Hooks.listeners.count == 2 && Hooks.browsers.count == 2, "Second retry for the old generation is stale")

        // Old-generation callbacks still change nothing.
        firstBrowser.deliver(.ready)
        await settle()
        check(capture.latest == .failed(.listenerFailed), "Stale browser ready cannot clear a failure")

        secondListener.deliver(.ready)
        await settle()
        check(capture.latest == .failed(.browserFailed), "New listener ready must not clear the browser failure")
        secondBrowser.deliver(.ready)
        await settle()
        check(capture.latest == .localReady(.listenAndBrowse), "New browser ready recovers")
        check(store.pskReads == reads, "Retries and diagnostics add no credential reads")
        service.stop()
    }

    // Effective listen = LED share || agent share; browse = LED discover || agent receive.
    private static func testConfigurationScopes() async {
        Hooks.reset()
        let store = PeelPairingStore(paired: [pairedRecord()], keys: [pairingID.uuidString: syntheticKey])
        let (service, capture) = await makeService(store)
        let reads = store.pskReads
        check(capture.latest == .disabled, "Trusted but nothing requested")

        service.configure(led(share: true, discover: false))
        check(Hooks.listeners.count == 1 && Hooks.browsers.isEmpty, "LED share is listen-only")
        Hooks.listeners[0].deliver(.ready)
        await settle()
        check(capture.latest == .localReady(.listenOnly), "Listen-only ready")

        service.configure(led(share: false, discover: false))
        check(Hooks.listeners[0].cancelled, "Both disabled stops the listener")
        check(capture.latest == .disabled, "Both disabled")

        service.configure(led(share: false, discover: true))
        check(Hooks.listeners.count == 1 && Hooks.browsers.count == 1, "LED discover is browse-only")
        check(capture.latest == .preparing(.browseOnly), "Browse-only preparing")
        Hooks.browsers[0].deliver(.ready)
        await settle()
        check(capture.latest == .localReady(.browseOnly), "Browse-only ready")

        service.configure(.localOnly)
        check(Hooks.browsers[0].cancelled, "Disabled stops the browser")
        service.configurePeerAgents(agents(share: false, receive: false, activate: true, usage: true))
        check(Hooks.listeners.count == 1 && Hooks.browsers.count == 1, "Activate/usage alone start nothing")
        check(capture.latest == .disabled, "Activate/usage alone are disabled")

        service.configurePeerAgents(agents(share: true, receive: false))
        check(Hooks.listeners.count == 2 && Hooks.browsers.count == 1, "Agent share is listen-only")
        check(capture.latest == .preparing(.listenOnly), "Agent listen-only preparing")
        Hooks.listeners[1].deliver(.waiting(.posix(.ENETDOWN)))
        await settle()
        check(capture.latest == .failed(.listenerWaiting), "Listener waiting is reported")
        check(Hooks.retries.isEmpty, "Waiting schedules no retry, as before")
        Hooks.listeners[1].deliver(.ready)
        await settle()
        check(capture.latest == .localReady(.listenOnly), "Ready replaces waiting")

        service.configurePeerAgents(agents(share: false, receive: true))
        check(Hooks.listeners[1].cancelled, "Changing settings restarts")
        check(Hooks.listeners.count == 2 && Hooks.browsers.count == 2, "Agent receive is browse-only")
        check(capture.latest == .preparing(.browseOnly), "Agent browse-only preparing")

        service.configurePeerAgents(.disabled)
        check(Hooks.browsers[1].cancelled, "Disabled stops resources")
        check(capture.latest == .disabled, "Disabled")
        check(store.pskReads == reads, "Configuration diagnostics add no credential reads")
        service.stop()

        Hooks.reset()
        let empty = PeelPairingStore(paired: [], keys: [:])
        let (emptyService, emptyCapture) = await makeService(empty)
        emptyService.configure(led(share: true, discover: false))
        check(Hooks.listenerAttempts == 0, "LED share with empty trust requests no listener")
        check(emptyCapture.latest == .noUsablePairedTrust(pairedKeyUnavailable: false), "Empty trust reported")
        emptyService.stop()
    }

    // All off: the unchanged first configure publishes a disabled snapshot once.
    private static func testAllOffUnchangedConfigure() async {
        Hooks.reset()
        let store = PeelPairingStore(paired: [], keys: [:])
        let (service, capture) = await makeService(store)
        check(capture.snapshots.isEmpty, "Nothing published before configuration")
        service.configurePeerAgents(.disabled)
        service.configure(.localOnly)
        check(capture.snapshots.map(\.startup) == [.disabled], "Unchanged all-off configure reports disabled once")
        check(capture.statuses.isEmpty, "No status change")
        service.configure(.localOnly)
        check(capture.snapshots.count == 1, "Only once")
        check(Hooks.listenerAttempts == 0 && Hooks.browsers.isEmpty && Hooks.retries.isEmpty, "No network")
        service.stop()
    }

    // Production log gate: install token, de-duplication, stale tokens, fixed codes.
    private static func testLogGate() {
        let gate = NearbySignalStartupLogGate()
        let first = gate.beginInstall()
        check(gate.admit(.notStarted, install: first) == .notStarted, "First code is admitted")
        check(gate.admit(.notStarted, install: first) == nil, "Same code is not repeated")
        check(gate.admit(.disabled, install: first) == .disabled, "Changed code is admitted")
        let second = gate.beginInstall()
        check(gate.admit(.preparing(.listenOnly), install: first) == nil, "Older install token is rejected")
        check(gate.admit(.disabled, install: second) == .disabled, "A new install restarts de-duplication")
        check(gate.admit(.failed(.listenerFailed), install: second) == .failedListener, "Failure code")
        check(gate.admit(.failed(.listenerFailed), install: second) == nil, "Repeated failure is not re-logged")

        let codes = NearbySignalStartupCode.allCases.map(\.rawValue)
        check(Set(codes).count == codes.count, "Codes are unique")
        let allowed = Set("abcdefghijklmnopqrstuvwxyz.-")
        check(codes.allSatisfy { !$0.isEmpty && $0.allSatisfy(allowed.contains) }, "Codes are fixed public ASCII")
    }

    // Actual service publications through the gate, then a newer install.
    private static func testLogGateWithServiceAndNewInstall() async {
        Hooks.reset()
        let gate = NearbySignalStartupLogGate()
        let install = gate.beginInstall()
        let store = PeelPairingStore(paired: [pairedRecord()], keys: [pairingID.uuidString: syntheticKey])
        let capture = StartupCapture(gate: gate, install: install)
        let service = await makeService(store, capture: capture)
        service.configurePeerAgents(agents(share: true, receive: true))
        Hooks.listeners[0].deliver(.ready)
        Hooks.browsers[0].deliver(.ready)
        await settle()
        Hooks.browsers[0].deliver(.ready)
        await settle()
        let codes = capture.codes
        check(capture.snapshots.count > codes.count, "Repeated same-state publications are de-duplicated")
        check(zip(codes, codes.dropFirst()).allSatisfy { $0 != $1 }, "No consecutive duplicate codes")
        check(codes.last == .localReadyListenAndBrowse, "Current code reflects the actual service state")

        // A newer install invalidates this callback even though the service's
        // own epoch still matches.
        _ = gate.beginInstall()
        Hooks.listeners[0].deliver(.failed(.posix(.ECONNABORTED)))
        await settle()
        check(capture.latest == .failed(.listenerFailed), "Snapshot still forwarded")
        check(capture.codes == codes, "Older install token cannot log")
        service.stop()
    }

    // MARK: Helpers

    private static func makeService(_ store: PeelPairingStore) async -> (PeelTrustedSidePulseService, StartupCapture) {
        let capture = StartupCapture()
        let service = await makeService(store, capture: capture)
        return (service, capture)
    }

    private static func makeService(_ store: PeelPairingStore, capture: StartupCapture) async -> PeelTrustedSidePulseService {
        let service = PeelTrustedSidePulseService(nodeID: localNodeID, hostID: localHostID, displayName: "Fixture",
            pairingStore: store, onPeers: { _ in }, onSignal: { _ in },
            onStatus: capture.onStatus, onSnapshot: capture.onSnapshot)
        await settle()
        return service
    }

    private static func pairedRecord() -> PeelPairedPeer {
        PeelPairedPeer(id: pairingID.uuidString, displayName: "Synthetic", serviceName: nil,
                       stableHostId: remoteHostID.uuidString)
    }

    private static func led(share: Bool, discover: Bool) -> NearbySignalServiceConfiguration {
        NearbySignalServiceConfiguration(sharesLocalSignal: share, discoversPeers: discover,
                                         followedPeerIDs: [], followsAllPeers: false)
    }

    private static func agents(share: Bool, receive: Bool, activate: Bool = false,
                               usage: Bool = false) -> PeelPeerAgentConfiguration {
        PeelPeerAgentConfiguration(sharesAgents: share, receivesAgents: receive,
                                   allowsPeerActivation: activate, sharesUsage: usage)
    }

    /// Lets the service's own main-actor callback hops run. No sleeps.
    private static func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private static func check(_ condition: Bool, _ message: String) {
        guard condition else {
            FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
            exit(1)
        }
    }
}
