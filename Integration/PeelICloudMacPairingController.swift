import AppKit
import Combine
import Foundation

@MainActor
protocol PeelICloudMacPairingVaultAccess: AnyObject {
    var isConfigured: Bool { get }
    func records() throws -> [PeelICloudHostRecord]
}
extension PeelICloudPairingVault: PeelICloudMacPairingVaultAccess {}

@MainActor
protocol PeelICloudMacPairingTrustAccess: AnyObject {
    var iCloudPeers: [PeelPairedPeer] { get }
    func iCloudKey(for pairingID: String) -> Data?
    func addICloudPair(record: PeelICloudHostRecord, response: PeelICloudPairResponse) throws -> PeelPairedPeer
    func removeICloudPair(pairingID: String)
}

extension PeelPairingStore: PeelICloudMacPairingTrustAccess {
    var iCloudPeers: [PeelPairedPeer] { paired }
    /// Unknown response IDs are checked by addPeerPersistingKey's uncached
    /// absence read; never seed the bounded Keychain read cache with them here.
    func iCloudKey(for pairingID: String) -> Data? {
        guard paired.contains(where: { $0.id == pairingID }) else { return nil }
        return psk(for: pairingID)
    }
    func addICloudPair(record: PeelICloudHostRecord, response: PeelICloudPairResponse) throws -> PeelPairedPeer {
        guard let pairingID = response.pairingID, let key = response.psk else { throw PeelICloudPairingError.invalidRecord }
        return try addPeerPersistingKey(displayName: response.hostName, stableHostId: record.hostID,
            tlsPSKOrder: .standard, pairingID: pairingID, psk: key, iCloudEnrollmentID: record.enrollmentID)
    }
    func removeICloudPair(pairingID: String) { removePeer(pairingID: pairingID) }
}

@MainActor
protocol PeelICloudMacPairingAddressAccess: AnyObject {
    func canSaveICloudAddress(id: UUID) -> Bool
    /// false means an active session owns this address; refresh is deferred.
    func saveICloudAddress(record: PeelICloudHostRecord, pairingID: String, addressID: UUID) throws -> Bool
}

protocol PeelICloudMacEnrollmentConnection: AnyObject {
    func start(completion: @escaping (Result<PeelICloudPairResponse, PeelICloudEnrollmentTransportError>) -> Void)
    func cancel()
}
extension PeelICloudEnrollmentTransport: PeelICloudMacEnrollmentConnection {}

struct PeelICloudMacPairingSummary: Identifiable {
    let id: String
    let displayName: String
    let detail: String
    let canPairAgain: Bool
}

/// Separate receiver enrollment: it owns no viewer/control connection and cannot
/// select a target, open a window, start input, or replace an existing pairing.
@MainActor
final class PeelICloudMacPairingController: ObservableObject {
    static let enabledKey = "peel.remoteMac.iCloudPairing.enabled.v1"
    static let deviceIDKey = "peel.remoteMac.iCloudPairing.installationID.v1"
    static let consumedKey = "peel.remoteMac.iCloudPairing.consumedHosts.v1"
    static let pendingKey = "peel.remoteMac.iCloudPairing.pendingRequests.v1"
    static let addressIDsKey = "peel.remoteMac.iCloudPairing.addressIDs.v1"
    private static let ignoredNotification = Notification.Name("Peel.remoteMac.iCloudPairing.hostIgnored.v1")

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isBusy = false
    @Published private(set) var status = "Enable iCloud Pairing here and on the Mac you want to view."
    @Published private(set) var hosts: [PeelICloudMacPairingSummary] = []
    var isConfigured: Bool { !isPreview && vault.isConfigured }

    private struct PendingRequest: Codable {
        let request: PeelICloudPairRequest
        let createdAt: Date
    }
    private final class Attempt {
        let record: PeelICloudHostRecord
        let request: PeelICloudPairRequest
        let connection: PeelICloudMacEnrollmentConnection
        let generation: UUID
        init(record: PeelICloudHostRecord, request: PeelICloudPairRequest,
             connection: PeelICloudMacEnrollmentConnection, generation: UUID) {
            self.record = record; self.request = request
            self.connection = connection; self.generation = generation
        }
    }

    private let vault: PeelICloudMacPairingVaultAccess
    private let trust: PeelICloudMacPairingTrustAccess
    private weak var addresses: PeelICloudMacPairingAddressAccess?
    private let defaults: UserDefaults
    private let localHostID: String
    private let isPreview: Bool
    private let now: () -> Date
    private let isForeground: @MainActor () -> Bool
    private let displayName: () -> String
    private let makeConnection: @MainActor (PeelICloudHostRecord, PeelICloudPairRequest) -> PeelICloudMacEnrollmentConnection
    private var records: [PeelICloudHostRecord] = []
    private var details: [String: String] = [:]
    private var consumed: Set<String>
    private var pendingRequests: [String: PendingRequest]
    private var addressIDs: [String: UUID]
    private var queue: [PeelICloudHostRecord] = []
    private var counts: [String: Int] = [:]
    private var attempt: Attempt?
    private var retry: DispatchWorkItem?
    private var generation = UUID()
    private var deadline = Date.distantPast
    private var lastRefresh = Date.distantPast
    private var observers: [AnyCancellable] = []

    init(trust: PeelICloudMacPairingTrustAccess, addresses: PeelICloudMacPairingAddressAccess,
         localHostID: String, vault: PeelICloudMacPairingVaultAccess = PeelICloudPairingVault(),
         defaults: UserDefaults = .standard,
         isPreview: Bool = ProcessInfo.processInfo.arguments.contains("--peel-preview"),
         now: @escaping () -> Date = Date.init,
         isForeground: @escaping @MainActor () -> Bool = { NSApplication.shared.isActive },
         displayName: @escaping () -> String = { Host.current().localizedName ?? "Mac" },
         makeConnection: @escaping @MainActor (PeelICloudHostRecord, PeelICloudPairRequest) -> PeelICloudMacEnrollmentConnection = {
             PeelICloudEnrollmentTransport(record: $0, request: $1)
         }) {
        self.trust = trust; self.addresses = addresses; self.localHostID = localHostID
        self.vault = vault; self.defaults = defaults; self.isPreview = isPreview
        self.now = now; self.isForeground = isForeground; self.displayName = displayName
        self.makeConnection = makeConnection
        isEnabled = !isPreview && defaults.bool(forKey: Self.enabledKey)
        consumed = Set((defaults.stringArray(forKey: Self.consumedKey) ?? [])
            .filter(PeelICloudPairingValidation.validDeviceID).map { $0.lowercased() })
        if let data = defaults.data(forKey: Self.pendingKey), data.count <= 64 * 1024,
           let decoded = try? JSONDecoder().decode([String: PendingRequest].self, from: data), decoded.count <= 32 {
            pendingRequests = decoded.filter { $0.value.createdAt.timeIntervalSince1970.isFinite &&
                PeelICloudPairingValidation.validDeviceID($0.value.request.requestID) }
        } else { pendingRequests = [:] }
        addressIDs = (defaults.dictionary(forKey: Self.addressIDsKey) as? [String: String] ?? [:])
            .reduce(into: [:]) { result, item in
                if PeelICloudPairingValidation.validDeviceID(item.key), let value = UUID(uuidString: item.value) { result[item.key] = value }
            }
        guard !isPreview else { status = "Preview · iCloud Pairing paused"; return }
        // Initialization does not read iCloud Keychain or generate an install ID.
        observers.append(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.refresh(automatically: true) } })
        observers.append(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.pause() } })
        observers.append(NotificationCenter.default.publisher(for: .NSUbiquityIdentityDidChange)
            .sink { [weak self] _ in Task { @MainActor in self?.accountChangeSignal() } })
        observers.append(NotificationCenter.default.publisher(for: Self.ignoredNotification)
            .sink { [weak self] notification in
                guard let hostID = notification.userInfo?["hostID"] as? String else { return }
                Task { @MainActor in self?.applyIgnoredHost(hostID) }
            })
    }

    /// Explicit Forget must stick even before this receiver controller exists or
    /// while account pairing is off. This stores public IDs only; no vault access.
    static func noteExplicitForget(hostID: String?, defaults: UserDefaults = .standard,
                                   isPreview: Bool = ProcessInfo.processInfo.arguments.contains("--peel-preview")) {
        guard !isPreview, let hostID, PeelICloudPairingValidation.validDeviceID(hostID) else { return }
        var removed = Set((defaults.stringArray(forKey: consumedKey) ?? [])
            .filter(PeelICloudPairingValidation.validDeviceID).map { $0.lowercased() })
        removed.insert(hostID.lowercased())
        defaults.set(removed.sorted(), forKey: consumedKey)
        NotificationCenter.default.post(name: ignoredNotification, object: defaults,
            userInfo: ["hostID": hostID.lowercased()])
    }

    private func applyIgnoredHost(_ hostID: String) {
        // A notification may come from another test/defaults domain. The
        // persisted namespace remains authoritative for this controller.
        guard (defaults.stringArray(forKey: Self.consumedKey) ?? []).contains(hostID.lowercased()) else { return }
        consumed.insert(hostID.lowercased())
        queue.removeAll { $0.hostID.lowercased() == hostID.lowercased() }
        if attempt?.record.hostID.lowercased() == hostID.lowercased() {
            cancelRound("Pairing was removed. Choose Pair Again only when you want to approve it again.")
        }
        details[hostID] = "Pairing was removed. Choose Pair Again to retry."
        rebuildSummaries()
    }

    func setEnabled(_ enabled: Bool) {
        guard !isPreview else { return }
        guard !enabled || isConfigured else { status = PeelICloudPairingError.unavailable.localizedDescription; return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled { refresh() }
        else { cancelRound("Account pairing is off. Existing device pairings are kept."); records = []; hosts = [] }
    }

    func refresh(automatically: Bool = false) {
        guard !isPreview, isEnabled, isConfigured, isForeground(), !isBusy else { return }
        if automatically, now().timeIntervalSince(lastRefresh) < 30 { return }
        lastRefresh = now()
        reloadConsumed()
        generation = UUID()
        details = [:]
        do {
            records = try vault.records().filter { $0.isValid && $0.hostID.lowercased() != localHostID.lowercased() }
        } catch { status = error.localizedDescription; return }
        queue = []
        for record in records {
            if let peer = existingPeer(record) {
                consume(record.hostID)
                updateAddress(record, peer: peer)
            } else if hasAnyExistingPeer(record) {
                consume(record.hostID)
                details[record.hostID] = "Existing pairing needs attention. Use a code; account pairing will not replace it."
            } else if consumed.contains(record.hostID.lowercased()) {
                details[record.hostID] = "Previously paired or removed. Choose Pair Again to retry."
            } else { queue.append(record) }
        }
        rebuildSummaries()
        guard !records.isEmpty else { status = "No other Macs have synced yet. Enable iCloud Pairing on the other Mac and allow time for Keychain sync."; return }
        counts = [:]
        deadline = now().addingTimeInterval(45)
        isBusy = true
        startNext()
    }

    func pairAgain(hostID: String) {
        guard !isPreview, isEnabled, isConfigured, isForeground(), !isBusy,
              let record = records.first(where: { $0.hostID == hostID }), !hasAnyExistingPeer(record) else { return }
        consumed.remove(hostID.lowercased())
        defaults.set(consumed.sorted(), forKey: Self.consumedKey)
        queue = [record]; counts = [:]; generation = UUID()
        deadline = now().addingTimeInterval(45); isBusy = true
        startNext()
    }

    func pause() { if isBusy { cancelRound("Pairing paused. Refresh when Peel is active.") } }

    private func accountChangeSignal() {
        guard isEnabled || isBusy else { return }
        isEnabled = false
        defaults.set(false, forKey: Self.enabledKey)
        cancelRound("An iCloud account change was reported. Enable again when ready. Existing pairings need explicit Forget or remote Host revocation.")
        records = []; hosts = []; pendingRequests = [:]
        persistPendingRequests()
    }

    private func matchingPeers(_ record: PeelICloudHostRecord) -> [PeelPairedPeer] {
        trust.iCloudPeers.filter { $0.stableHostId?.lowercased() == record.hostID.lowercased() }
    }
    private func hasAnyExistingPeer(_ record: PeelICloudHostRecord) -> Bool { !matchingPeers(record).isEmpty }
    private func existingPeer(_ record: PeelICloudHostRecord) -> PeelPairedPeer? {
        let peers = matchingPeers(record)
        guard peers.count == 1, let peer = peers.first,
              PeelICloudPairingValidation.validDeviceID(peer.id), peer.tlsPSKOrder != nil,
              trust.iCloudKey(for: peer.id)?.count == 32 else { return nil }
        return peer
    }

    private func updateAddress(_ record: PeelICloudHostRecord, peer: PeelPairedPeer) {
        guard let addresses else { return }
        do {
            let id = addressID(record.hostID)
            guard addresses.canSaveICloudAddress(id: id) else { throw PeelRemoteMacAddressStoreError.capacityReached }
            let saved = try addresses.saveICloudAddress(record: record, pairingID: peer.id, addressID: id)
            if let oldEpoch = peer.iCloudEnrollmentID, oldEpoch != record.enrollmentID {
                details[record.hostID] = "The Mac rotated account pairing. Review the old pairing on both Macs before pairing again."
            } else { details[record.hostID] = saved ? "Paired. Saved address is current." : "Paired. Address refresh deferred until this viewer disconnects." }
        } catch { details[record.hostID] = error.localizedDescription }
    }

    private func startNext() {
        reloadConsumed()
        guard isEnabled, isForeground(), let addresses else { cancelRound("Pairing paused. Refresh when Peel is active."); return }
        guard now() < deadline else { cancelRound("Some Macs are not reachable yet. Check Tailscale or your private network, then refresh."); return }
        guard !queue.isEmpty else { isBusy = false; status = "Finished checking Macs. Choose a saved Mac address to connect."; rebuildSummaries(); return }
        let record = queue.removeFirst()
        if let peer = existingPeer(record) { consume(record.hostID); updateAddress(record, peer: peer); startNext(); return }
        guard !hasAnyExistingPeer(record), !consumed.contains(record.hostID.lowercased()) else { startNext(); return }
        guard consumed.count < 1024, addresses.canSaveICloudAddress(id: addressID(record.hostID)) else {
            details[record.hostID] = "Remove an unused saved address before pairing another Mac."
            cancelRound("Saved addresses or pairing history are full. Use code pairing after reviewing saved devices."); return
        }
        guard let request = request(record), request.isValid(for: record) else {
            details[record.hostID] = "This Mac's pairing details need refreshing."; startNext(); return
        }
        counts[key(record), default: 0] += 1
        let connection = makeConnection(record, request)
        let active = Attempt(record: record, request: request, connection: connection, generation: generation)
        attempt = active
        details[record.hostID] = "Pairing…"; status = "Pairing with \(record.displayName)…"; rebuildSummaries()
        connection.start { [weak self, weak active] result in
            Task { @MainActor in
                guard let self, let active, self.isCurrent(active) else { return }
                switch result {
                case .success(let response):
                    guard response.isValid(for: active.request), response.accepted else {
                        self.consume(record.hostID)
                        self.finish(active, message: "The Mac declined or could not verify pairing. Check its paired devices, then choose Pair Again."); return
                    }
                    self.save(response, attempt: active)
                case .failure(let error):
                    let retryable = error == .connectionFailed || error == .timedOut
                    if !retryable { self.consume(record.hostID) }
                    self.finish(active, message: "Not paired yet. Check the other Mac and Tailscale or your private network.", retryable: retryable)
                }
            }
        }
    }

    private func save(_ response: PeelICloudPairResponse, attempt active: Attempt) {
        guard isCurrent(active), response.isValid(for: active.request), response.accepted,
              let addresses, let pairingID = response.pairingID else { return }
        let id = addressID(active.record.hostID)
        reloadConsumed()
        guard !consumed.contains(active.record.hostID.lowercased()),
              !hasAnyExistingPeer(active.record), !trust.iCloudPeers.contains(where: { $0.id == pairingID }),
              trust.iCloudKey(for: pairingID) == nil, addresses.canSaveICloudAddress(id: id) else {
            consume(active.record.hostID)
            finish(active, message: "Pairing or saved addresses changed. Existing devices were kept. Review them before retrying."); return
        }
        consume(active.record.hostID)
        var newPair: PeelPairedPeer?
        do {
            let peer = try trust.addICloudPair(record: active.record, response: response)
            newPair = peer
            guard isCurrent(active) else { trust.removeICloudPair(pairingID: peer.id); return }
            guard try addresses.saveICloudAddress(record: active.record, pairingID: peer.id, addressID: id) else {
                throw PeelRemoteMacAddressStoreError.encodingFailed
            }
            pendingRequests[key(active.record)] = nil
            persistPendingRequests()
            finish(active, message: "Paired. Choose this Mac under Saved Addresses to connect.")
        } catch {
            // Remove exactly the newly created credential, never existing peers.
            if let newPair { trust.removeICloudPair(pairingID: newPair.id) }
            finish(active, message: "Could not save this pairing and address. Existing pairings were kept. Choose Pair Again to retry.")
        }
    }

    private func request(_ record: PeelICloudHostRecord) -> PeelICloudPairRequest? {
        let instant = now()
        let installationID: String
        if let saved = defaults.string(forKey: Self.deviceIDKey), PeelICloudPairingValidation.validDeviceID(saved),
           saved.lowercased() != localHostID.lowercased() { installationID = saved }
        else { installationID = UUID().uuidString; defaults.set(installationID, forKey: Self.deviceIDKey) }
        if let saved = pendingRequests[key(record)], (0..<300).contains(instant.timeIntervalSince(saved.createdAt)),
           saved.request.isValid(for: record), saved.request.clientDeviceID == installationID { return saved.request }
        pendingRequests = pendingRequests.filter { (0..<300).contains(instant.timeIntervalSince($0.value.createdAt)) }
        guard pendingRequests.count < 32 else { return nil }
        let name = PeelICloudPairingValidation.cleanName(displayName()) ?? "Mac"
        let fresh = PeelICloudPairRequest(hostID: record.hostID, enrollmentID: record.enrollmentID,
            clientDeviceID: installationID, clientName: name)
        pendingRequests[key(record)] = PendingRequest(request: fresh, createdAt: instant)
        persistPendingRequests()
        return fresh
    }
    private func key(_ record: PeelICloudHostRecord) -> String { record.hostID.lowercased() + "/" + record.enrollmentID.lowercased() }
    private func addressID(_ hostID: String) -> UUID {
        let key = hostID.lowercased()
        if let existing = addressIDs[key] { return existing }
        let newID = UUID(); addressIDs[key] = newID
        defaults.set(addressIDs.mapValues(\.uuidString), forKey: Self.addressIDsKey)
        return newID
    }
    private func isCurrent(_ active: Attempt) -> Bool {
        !isPreview && isEnabled && isBusy && isForeground() && attempt === active && generation == active.generation
    }
    private func finish(_ active: Attempt, message: String, retryable: Bool = false) {
        guard isCurrent(active) else { return }
        active.connection.cancel(); attempt = nil
        details[active.record.hostID] = message; rebuildSummaries()
        if retryable, !consumed.contains(active.record.hostID.lowercased()),
           counts[key(active.record), default: 0] < 2, now().addingTimeInterval(1) < deadline {
            queue.insert(active.record, at: 0)
            let current = generation
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.generation == current, self.isEnabled, self.isBusy else { return }
                self.retry = nil; self.startNext()
            }
            retry = work; DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
        } else { startNext() }
    }
    private func cancelRound(_ message: String) {
        generation = UUID(); retry?.cancel(); retry = nil
        attempt?.connection.cancel(); attempt = nil
        queue = []; isBusy = false; status = message; rebuildSummaries()
    }
    private func consume(_ hostID: String) {
        reloadConsumed()
        consumed.insert(hostID.lowercased()); defaults.set(consumed.sorted(), forKey: Self.consumedKey)
    }
    private func reloadConsumed() {
        consumed.formUnion((defaults.stringArray(forKey: Self.consumedKey) ?? [])
            .filter(PeelICloudPairingValidation.validDeviceID).map { $0.lowercased() })
    }
    private func persistPendingRequests() {
        if let data = try? JSONEncoder().encode(pendingRequests) { defaults.set(data, forKey: Self.pendingKey) }
    }
    private func rebuildSummaries() {
        hosts = records.map { record in
            PeelICloudMacPairingSummary(id: record.hostID, displayName: record.displayName,
                detail: details[record.hostID] ?? (existingPeer(record) == nil ? "Not paired yet." : "Paired."),
                canPairAgain: !hasAnyExistingPeer(record) && consumed.contains(record.hostID.lowercased()))
        }
    }
}
