import Foundation
import Combine

#if canImport(UIKit)
import UIKit
#endif

struct PeelICloudPairingHostSummary: Identifiable {
    let id: String
    let displayName: String
    let detail: String
    let canPairAgain: Bool
}

/// Foreground-only enrollment owns its own temporary connection. It never uses
/// or selects a control session, reconnects a Mac, or opens a stream.
final class PeelICloudPairingClient: ObservableObject {
    private static let enabledKey = "Peel.client.iCloudPairing.enabled.v1"
    private static let consumedHostsKey = "Peel.client.iCloudPairing.consumedHosts.v1"
    private static let pendingAttemptsKey = "Peel.client.iCloudPairing.pendingAttempts.v1"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isBusy = false
    @Published private(set) var status = "Enable iCloud Pairing on this device and your Mac."
    @Published private(set) var hosts: [PeelICloudPairingHostSummary] = []

    var isConfigured: Bool { vault.isConfigured }

    private struct PendingAttempt: Codable {
        let request: PeelICloudPairRequest
        let createdAt: Date
    }

    private final class Enrollment {
        let record: PeelICloudHostRecord
        let request: PeelICloudPairRequest
        let transport: PeelICloudEnrollmentTransport
        let generation: UUID

        init(record: PeelICloudHostRecord, request: PeelICloudPairRequest,
             transport: PeelICloudEnrollmentTransport, generation: UUID) {
            self.record = record
            self.request = request
            self.transport = transport
            self.generation = generation
        }
    }

    private let vault: PeelICloudPairingVault
    private let defaults: UserDefaults
    private weak var browser: PeelClientBrowser?
    private var consumedHosts: Set<String>
    private var pendingAttempts: [String: PendingAttempt]
    private var records: [PeelICloudHostRecord] = []
    private var detailByHost: [String: String] = [:]
    private var pendingRecords: [PeelICloudHostRecord] = []
    private var attemptCounts: [String: Int] = [:]
    private var enrollment: Enrollment?
    private var retryWork: DispatchWorkItem?
    private var generation = UUID()
    private var roundDeadline = Date.distantPast
    private var lastAutomaticRefresh = Date.distantPast
    private var accountObserver: NSObjectProtocol?

    init(vault: PeelICloudPairingVault = PeelICloudPairingVault(),
         defaults: UserDefaults = .standard) {
        self.vault = vault
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        consumedHosts = Set((defaults.stringArray(forKey: Self.consumedHostsKey) ?? [])
            .filter { PeelICloudPairingValidation.validDeviceID($0) }
            .map { $0.lowercased() })
        if let data = defaults.data(forKey: Self.pendingAttemptsKey),
           let decoded = try? JSONDecoder().decode([String: PendingAttempt].self, from: data) {
            pendingAttempts = decoded.filter {
                PeelICloudPairingValidation.validDeviceID($0.value.request.requestID) &&
                $0.value.createdAt.timeIntervalSince1970.isFinite
            }
        } else {
            pendingAttempts = [:]
        }
        // Initializing this object never queries iCloud Keychain.
        accountObserver = NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.accountDidChange()
        }
    }

    deinit {
        retryWork?.cancel()
        enrollment?.transport.cancel()
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
    }

    func attach(to browser: PeelClientBrowser) {
        self.browser = browser
    }

    func setEnabled(_ enabled: Bool) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.setEnabled(enabled) }
            return
        }
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled {
            refresh(automatically: false)
        } else {
            cancelRound(message: "iCloud Pairing is off. Your existing pairings are kept.")
            records = []
            hosts = []
        }
    }

    /// Called by Settings appearance, explicit Refresh, and the existing app
    /// activation observer. No timer, background task, or new polling owner.
    func refresh(automatically: Bool = true) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.refresh(automatically: automatically) }
            return
        }
        guard isEnabled else { return }
        guard isConfigured else {
            status = "iCloud Pairing is unavailable in this build. Use a pairing code."
            return
        }
        guard let browser, browser.isClientVisible, !isBusy else { return }
        if automatically, Date().timeIntervalSince(lastAutomaticRefresh) < 30 { return }
        lastAutomaticRefresh = Date()
        generation = UUID()
        detailByHost = [:]
        do {
            records = try vault.records().filter(\.isValid)
        } catch {
            status = (error as? PeelICloudPairingError)?.localizedDescription ??
                "iCloud Keychain could not be read. Check Passwords & Keychain in iCloud settings."
            return
        }
        pendingRecords = []
        for record in records {
            if let peer = pairedPeer(for: record) {
                consume(record.hostID)
                updateAddress(record, for: peer)
            } else if consumedHosts.contains(record.hostID.lowercased()) {
                detailByHost[record.hostID] = "Previously paired or ignored. Choose Pair Again to retry."
            } else {
                pendingRecords.append(record)
            }
        }
        rebuildSummaries()
        guard !records.isEmpty else {
            status = "No Macs have synced yet. Enable iCloud Pairing on your Mac; Keychain sync may take a moment."
            return
        }
        attemptCounts = [:]
        roundDeadline = Date().addingTimeInterval(45)
        isBusy = true
        startNext()
    }

    func pairAgain(hostID: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.pairAgain(hostID: hostID) }
            return
        }
        guard isEnabled, isConfigured, !isBusy,
              let browser, browser.isClientVisible,
              let record = records.first(where: { $0.hostID == hostID }),
              pairedPeer(for: record) == nil else { return }
        consumedHosts.remove(hostID.lowercased())
        persistConsumedHosts()
        detailByHost[hostID] = "Waiting to pair…"
        pendingRecords = [record]
        attemptCounts = [:]
        generation = UUID()
        roundDeadline = Date().addingTimeInterval(45)
        isBusy = true
        startNext()
    }

    /// Remember a local forget/revocation even while the feature is disabled.
    /// An epoch change must not silently undo the user's earlier removal.
    func ignoreHost(_ hostID: String?) {
        guard let hostID, PeelICloudPairingValidation.validDeviceID(hostID) else { return }
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.ignoreHost(hostID) }
            return
        }
        consume(hostID)
        pendingRecords.removeAll { $0.hostID.lowercased() == hostID.lowercased() }
        if enrollment?.record.hostID.lowercased() == hostID.lowercased() {
            cancelRound(message: "Pairing was removed. Choose Pair Again when you want to pair this Mac.")
        }
        detailByHost[hostID] = "Pairing was removed. Choose Pair Again to retry."
        rebuildSummaries()
    }

    func pause() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.pause() }
            return
        }
        if isBusy { cancelRound(message: "Pairing paused. Refresh when this device is active.") }
    }

    func manualPairingWillBegin() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.manualPairingWillBegin() }
            return
        }
        if isBusy { cancelRound(message: "Finish code pairing, then refresh iCloud Pairing.") }
    }

    func localPairingsChanged() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.localPairingsChanged() }
            return
        }
        rebuildSummaries()
    }

    private func accountDidChange() {
        // Best effort only: this notification is not a guarantee that Keychain
        // identity changed. Local peer trust still requires host-side revocation.
        isEnabled = false
        defaults.set(false, forKey: Self.enabledKey)
        cancelRound(message: "iCloud account settings changed. Enable iCloud Pairing again when ready. Existing pairings remain until forgotten or revoked on the Mac.")
        records = []
        hosts = []
        pendingAttempts = [:]
        persistPendingAttempts()
    }

    private func pairedPeer(for record: PeelICloudHostRecord) -> PeelPairedPeer? {
        browser?.pairingStore.paired.first {
            $0.stableHostId?.lowercased() == record.hostID.lowercased()
        }
    }

    private func updateAddress(_ record: PeelICloudHostRecord, for peer: PeelPairedPeer) {
        guard let browser,
              let endpoint = PeelDirectEndpoint(host: record.endpointHost, port: record.controlPort) else { return }
        // This updates transport metadata only. It neither replaces a PSK nor
        // connects/selects a session, even when a control session is already live.
        let result = browser.saveDirectEndpoint(for: peer.id, endpoint: endpoint)
        if let epoch = peer.iCloudEnrollmentID, epoch != record.enrollmentID {
            detailByHost[record.hostID] = "The Mac changed its iCloud pairing. Forget the old pairing, then choose Pair Again."
        } else {
            detailByHost[record.hostID] = result == .saved ? "Paired. Address is up to date." : result.userMessage
        }
    }

    private func startNext() {
        guard isEnabled, let browser, browser.isClientVisible else {
            cancelRound(message: "Pairing paused. Refresh when this device is active.")
            return
        }
        guard Date() < roundDeadline else {
            cancelRound(message: "Some Macs could not be reached yet. Connect to your private network or Tailscale, then refresh.")
            return
        }
        guard browser.pendingPairHost == nil, browser.pairingConnection == nil else {
            cancelRound(message: "Finish code pairing, then refresh iCloud Pairing.")
            return
        }
        guard !pendingRecords.isEmpty else {
            isBusy = false
            status = "Finished checking Macs. Choose a paired Mac to connect."
            rebuildSummaries()
            return
        }
        let record = pendingRecords.removeFirst()
        if let peer = pairedPeer(for: record) {
            consume(record.hostID)
            updateAddress(record, for: peer)
            startNext()
            return
        }
        guard !consumedHosts.contains(record.hostID.lowercased()) else {
            startNext()
            return
        }
        guard browser.directEndpointStore.records.count < PeelDirectEndpointStore.maxEntries else {
            detailByHost[record.hostID] = "Remove an unused saved address before pairing another Mac."
            cancelRound(message: "Saved addresses are full. Remove an unused address, then refresh.")
            return
        }
        guard record.isValid,
              let request = request(for: record, browser: browser), request.isValid(for: record) else {
            detailByHost[record.hostID] = "This Mac's pairing information is unavailable. Refresh it on the Mac."
            startNext()
            return
        }
        let key = attemptKey(record)
        attemptCounts[key, default: 0] += 1
        let transport = PeelICloudEnrollmentTransport(record: record, request: request)
        let attempt = Enrollment(record: record, request: request, transport: transport, generation: generation)
        enrollment = attempt
        detailByHost[record.hostID] = "Pairing…"
        status = "Pairing with \(record.displayName)…"
        rebuildSummaries()
        transport.start { [weak self, weak attempt] result in
            guard let self, let attempt, self.isCurrent(attempt) else { return }
            switch result {
            case .success(let response):
                guard response.isValid(for: attempt.request) else {
                    self.consume(attempt.record.hostID)
                    self.finish(attempt, message: "The Mac's pairing response could not be verified. Choose Pair Again after checking the Mac.", retryable: false)
                    return
                }
                guard response.accepted else {
                    self.consume(attempt.record.hostID)
                    self.pendingAttempts[self.attemptKey(attempt.record)] = nil
                    self.persistPendingAttempts()
                    self.finish(attempt, message: "The Mac declined pairing. Check its paired devices, then choose Pair Again.", retryable: false)
                    return
                }
                self.save(response, for: attempt)
            case .failure(let error):
                let retryable = error == .timedOut || error == .connectionFailed
                if error == .invalidResponse || error == .invalidRequest {
                    self.consume(record.hostID)
                }
                self.finish(attempt, message: retryable ?
                    "Not reachable yet. Check the Mac and your private network or Tailscale." :
                    "Pairing did not complete. Check iCloud Pairing on the Mac, then choose Pair Again.",
                    retryable: retryable)
            }
        }
    }

    private func save(_ response: PeelICloudPairResponse, for attempt: Enrollment) {
        guard isCurrent(attempt), response.isValid(for: attempt.request), response.accepted,
              let browser, let pairingID = response.pairingID, let psk = response.psk,
              let endpoint = PeelDirectEndpoint(host: attempt.record.endpointHost, port: attempt.record.controlPort) else { return }
        // Recheck immediately before the only local credential write. A manual
        // pairing or endpoint edit may have completed while the network waited.
        guard pairedPeer(for: attempt.record) == nil else {
            consume(attempt.record.hostID)
            finish(attempt, message: "Already paired. Existing pairing was kept.", retryable: false)
            return
        }
        guard browser.directEndpointStore.records.count < PeelDirectEndpointStore.maxEntries else {
            consume(attempt.record.hostID)
            finish(attempt, message: "Saved addresses are full. Remove an address, then choose Pair Again.", retryable: false)
            return
        }
        consume(attempt.record.hostID)
        let peer: PeelPairedPeer
        do {
            peer = try browser.pairingStore.addPeerPersistingKey(
                displayName: response.hostName, stableHostId: attempt.record.hostID,
                tlsPSKOrder: .standard, pairingID: pairingID, psk: psk,
                iCloudEnrollmentID: attempt.record.enrollmentID
            )
        } catch {
            finish(attempt, message: "Could not save this pairing on this device. Unlock it, then choose Pair Again.", retryable: false)
            return
        }
        guard isCurrent(attempt) else {
            browser.pairingStore.removePeer(pairingID: peer.id)
            browser.markPairingStateChanged()
            return
        }
        let result = browser.saveDirectEndpoint(for: peer.id, endpoint: endpoint)
        guard result == .saved else {
            // Roll back only the brand-new credential. No existing peer/session
            // was replaced, and enrollment never creates a control connection.
            browser.pairingStore.removePeer(pairingID: peer.id)
            browser.markPairingStateChanged()
            finish(attempt, message: result.userMessage + " Choose Pair Again to retry.", retryable: false)
            return
        }
        pendingAttempts[attemptKey(attempt.record)] = nil
        persistPendingAttempts()
        browser.markPairingStateChanged()
        finish(attempt, message: "Paired. Choose Connect by Address to connect.", retryable: false)
    }

    private func request(for record: PeelICloudHostRecord, browser: PeelClientBrowser) -> PeelICloudPairRequest? {
        guard PeelICloudPairingValidation.validDeviceID(browser.clientDeviceId) else { return nil }
        let key = attemptKey(record)
        let now = Date()
        let saved = pendingAttempts[key]
        let pending: PendingAttempt
        if let saved, (0..<300).contains(now.timeIntervalSince(saved.createdAt)),
           saved.request.isValid(for: record), saved.request.clientDeviceID == browser.clientDeviceId {
            pending = saved
        } else {
            pendingAttempts = pendingAttempts.filter { (0..<300).contains(now.timeIntervalSince($0.value.createdAt)) }
            guard pendingAttempts.count < PeelICloudPairingVault.maxHosts else { return nil }
            let name: String
#if canImport(UIKit)
            name = PeelICloudPairingValidation.cleanName(UIDevice.current.name) ?? "Peel device"
#else
            name = "Peel device"
#endif
            let request = PeelICloudPairRequest(hostID: record.hostID, enrollmentID: record.enrollmentID,
                clientDeviceID: browser.clientDeviceId, clientName: name)
            pending = PendingAttempt(request: request, createdAt: now)
            pendingAttempts[key] = pending
            persistPendingAttempts()
        }
        return pending.request
    }

    private func attemptKey(_ record: PeelICloudHostRecord) -> String {
        record.hostID.lowercased() + "/" + record.enrollmentID.lowercased()
    }

    private func isCurrent(_ attempt: Enrollment) -> Bool {
        isEnabled && isBusy && browser?.isClientVisible == true &&
        enrollment === attempt && generation == attempt.generation
    }

    private func finish(_ attempt: Enrollment, message: String, retryable: Bool) {
        guard isCurrent(attempt) else { return }
        attempt.transport.cancel()
        enrollment = nil
        detailByHost[attempt.record.hostID] = message
        rebuildSummaries()
        if retryable, !consumedHosts.contains(attempt.record.hostID.lowercased()),
           attemptCounts[attemptKey(attempt.record), default: 0] < 2,
           Date().addingTimeInterval(1) < roundDeadline {
            pendingRecords.insert(attempt.record, at: 0)
            let currentGeneration = generation
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.generation == currentGeneration, self.isEnabled, self.isBusy else { return }
                self.retryWork = nil
                self.startNext()
            }
            retryWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
        } else {
            startNext()
        }
    }

    private func cancelRound(message: String) {
        generation = UUID()
        retryWork?.cancel()
        retryWork = nil
        enrollment?.transport.cancel()
        enrollment = nil
        pendingRecords = []
        isBusy = false
        status = message
        rebuildSummaries()
    }

    private func consume(_ hostID: String) {
        consumedHosts.insert(hostID.lowercased())
        persistConsumedHosts()
    }

    private func persistConsumedHosts() {
        defaults.set(consumedHosts.sorted(), forKey: Self.consumedHostsKey)
    }

    private func persistPendingAttempts() {
        guard let data = try? JSONEncoder().encode(pendingAttempts) else { return }
        defaults.set(data, forKey: Self.pendingAttemptsKey)
    }

    private func rebuildSummaries() {
        hosts = records.map { record in
            let peer = pairedPeer(for: record)
            let consumed = consumedHosts.contains(record.hostID.lowercased())
            return PeelICloudPairingHostSummary(id: record.hostID, displayName: record.displayName,
                detail: detailByHost[record.hostID] ?? (peer == nil ? "Not paired yet." : "Paired."),
                canPairAgain: peer == nil && consumed)
        }
    }
}
