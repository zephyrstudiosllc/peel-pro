import Foundation
import Combine
import Network
import Darwin

/// Admission is independent of transport and storage so its trust decisions can
/// be exercised without reading a real Keychain or starting a listener.
enum PeelICloudHostEnrollmentPolicy {
    static let maxCloudDevices = 32

    static func isLocallyIssued(_ peer: PeelPairedPeer, ownedEnrollmentIDs: Set<String>) -> Bool {
        peer.stableHostId == nil && peer.iCloudEnrollmentID.map(ownedEnrollmentIDs.contains) == true
    }

    static func rejection(for request: PeelICloudPairRequest, record: PeelICloudHostRecord,
                          peers: [PeelPairedPeer], blockedDeviceIDs: Set<String>,
                          ownedEnrollmentIDs: Set<String>) -> String? {
        guard request.isValid(for: record) else { return "Invalid account pairing request." }
        let deviceID = request.clientDeviceID.lowercased()
        guard !blockedDeviceIDs.contains(deviceID) else {
            return "This device was revoked on the Mac. Pair with a code to approve it again."
        }
        // An installation ID is a label supplied by the client, not proof that
        // it owns an existing credential. Never export or replace that key.
        guard !peers.contains(where: { $0.serviceName?.lowercased() == deviceID }) else {
            return "This device already has a pairing. Use it, or pair again with a code."
        }
        guard peers.filter({ isLocallyIssued($0, ownedEnrollmentIDs: ownedEnrollmentIDs) }).count < maxCloudDevices else {
            return "This Mac has too many account-paired devices. Remove an unused device."
        }
        return nil
    }
}

/// A lost response may be repeated only for the same unguessable request ID and
/// exact installation/request tuple, while the originally issued key still exists.
/// The installation label alone never grants access to another device's key.
struct PeelICloudHostEnrollmentRetryCache {
    private struct Entry {
        let request: PeelICloudPairRequest
        let response: PeelICloudPairResponse
        let expiresAt: Date
    }
    private var entries: [String: Entry] = [:]
    var count: Int { entries.count }

    mutating func response(for request: PeelICloudPairRequest, record: PeelICloudHostRecord,
                           peers: [PeelPairedPeer], blockedDeviceIDs: Set<String>, now: Date = Date(),
                           keyForPairing: (String) -> Data?) -> PeelICloudPairResponse? {
        entries = entries.filter { $0.value.expiresAt > now }
        guard request.isValid(for: record), let cached = entries[request.requestID],
              cached.request.hostID == request.hostID, cached.request.enrollmentID == request.enrollmentID,
              cached.request.clientDeviceID == request.clientDeviceID, cached.request.clientName == request.clientName,
              !blockedDeviceIDs.contains(request.clientDeviceID.lowercased()),
              let pairingID = cached.response.pairingID,
              peers.contains(where: { $0.id == pairingID && $0.iCloudEnrollmentID == record.enrollmentID &&
                  $0.stableHostId == nil && $0.serviceName?.lowercased() == request.clientDeviceID.lowercased() }),
              keyForPairing(pairingID) == cached.response.psk else { return nil }
        return cached.response
    }

    mutating func insert(request: PeelICloudPairRequest, response: PeelICloudPairResponse, now: Date = Date()) {
        guard response.isValid(for: request), response.accepted else { return }
        entries = entries.filter { $0.value.expiresAt > now }
        if entries.count >= PeelICloudHostEnrollmentPolicy.maxCloudDevices,
           let oldest = entries.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key { entries.removeValue(forKey: oldest) }
        entries[request.requestID] = Entry(request: request, response: response,
            expiresAt: now.addingTimeInterval(300))
    }

    mutating func remove(pairingID: String) { entries = entries.filter { $0.value.response.pairingID != pairingID } }
    mutating func removeAll() { entries.removeAll() }
}

/// Main-queue owner. The bootstrap listener is never a control/video socket and
/// does not present windows, select a client, or alter an existing control session.
final class PeelICloudHostPairingController: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var status: String = "Off"
    @Published private(set) var endpoint: String = ""
    @Published private(set) var pairingPort: UInt16
    @Published private(set) var manualEndpoint: String
    @Published private(set) var cloudDeviceCount = 0

    var isConfigured: Bool { !isPreview && vault.isConfigured }
    static let defaultPairingPort: UInt16 = 49753

    private static let enabledKey = "PeelHost.iCloudPairing.enabled.v1"
    private static let endpointKey = "PeelHost.iCloudPairing.endpoint.v1"
    private static let portKey = "PeelHost.iCloudPairing.port.v1"
    private static let blockedKey = "PeelHost.iCloudPairing.blockedInstallations.v1"
    private static let ownedEpochsKey = "PeelHost.iCloudPairing.ownedEnrollmentIDs.v1"
    private static let localService = "com.zephyrstudios.peel.icloud-enrollment.host-local.v1"
    private static let maxConnections = 8

    private let pairingStore: PeelPairingStore
    private let hostID: String
    private let hostName: String
    private let defaults: UserDefaults
    private let vault: PeelICloudPairingVault
    private let isPreview: Bool
    private let revokePeer: (String) -> Void
    private var controlPort: UInt16?
    private var hostAvailable = false
    private var record: PeelICloudHostRecord?
    private var publishedRecord: PeelICloudHostRecord?
    private var forceFreshRecord = false
    private var blockedDeviceIDs: Set<String>
    private var ownedEnrollmentIDs: Set<String>
    private var listener: NWListener?
    private var listenerReady = false
    private var generation = UUID()
    private var peersObservation: AnyCancellable?
    private var accountChangeObservation: AnyCancellable?
    private var connections: [UUID: PendingConnection] = [:]
    private var replies = PeelICloudHostEnrollmentRetryCache()

    private final class PendingConnection {
        let connection: NWConnection
        var buffer = Data()
        var didReceive = false
        var timeout: DispatchWorkItem?
        init(_ connection: NWConnection) { self.connection = connection }
    }

    init(pairingStore: PeelPairingStore, hostID: String, hostName: String,
         defaults: UserDefaults = .standard, vault: PeelICloudPairingVault = PeelICloudPairingVault(),
         isPreview: Bool = ProcessInfo.processInfo.arguments.contains("--peel-preview"),
         revokePeer: @escaping (String) -> Void) {
        self.pairingStore = pairingStore
        self.hostID = hostID
        self.hostName = PeelICloudPairingValidation.cleanName(hostName) ?? "Mac"
        self.defaults = defaults
        self.vault = vault
        self.isPreview = isPreview
        self.revokePeer = revokePeer
        self.isEnabled = !isPreview && defaults.bool(forKey: Self.enabledKey)
        self.manualEndpoint = defaults.string(forKey: Self.endpointKey) ?? ""
        let savedPort = defaults.integer(forKey: Self.portKey)
        self.pairingPort = (1...65535).contains(savedPort) ? UInt16(savedPort) : Self.defaultPairingPort
        self.blockedDeviceIDs = Set((defaults.stringArray(forKey: Self.blockedKey) ?? [])
            .filter(PeelICloudPairingValidation.validDeviceID).map { $0.lowercased() })
        self.ownedEnrollmentIDs = Set((defaults.stringArray(forKey: Self.ownedEpochsKey) ?? [])
            .filter(PeelICloudPairingValidation.validDeviceID))
        cloudDeviceCount = pairingStore.paired.filter { peer in
            PeelICloudHostEnrollmentPolicy.isLocallyIssued(peer, ownedEnrollmentIDs: ownedEnrollmentIDs)
        }.count
        if isPreview { status = "Preview · Account pairing paused"; return }
        peersObservation = pairingStore.$paired.receive(on: DispatchQueue.main).sink { [weak self] peers in
            guard let self else { return }
            self.cloudDeviceCount = peers.filter(self.isLocallyIssued).count
        }
        // This iCloud Drive notification is only a best-effort extra signal; it
        // cannot prove the identity or detect every iCloud Keychain account change.
        accountChangeObservation = NotificationCenter.default.publisher(for: .NSUbiquityIdentityDidChange)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.pauseAfterAccountChangeSignal() }
        // No synchronized Keychain access or listener at initialization. Host
        // supplies actual availability after its ordinary control listener starts.
        status = isEnabled ? "Waiting for the Mac's connection listener…" : "Off"
    }

    func updateHostAvailability(controlPort: UInt16?, discoverable: Bool) {
        self.controlPort = controlPort
        hostAvailable = discoverable
        refresh()
    }

    func setEnabled(_ enabled: Bool) {
        guard !isPreview else { return }
        if enabled {
            guard isConfigured else { status = PeelICloudPairingError.unavailable.localizedDescription; return }
            guard !isEnabled else { refresh(); return }
            forceFreshRecord = true
            isEnabled = true
            defaults.set(true, forKey: Self.enabledKey)
            refresh()
        } else {
            // Local acceptance ends before asynchronous cloud deletion can matter.
            isEnabled = false
            defaults.set(false, forKey: Self.enabledKey)
            stopListener(clearReplies: true)
            record = nil
            publishedRecord = nil
            forceFreshRecord = true
            PeelKeychain.delete(service: Self.localService, account: hostID)
            do {
                try vault.remove(hostID: hostID)
                status = "Off · Existing device pairings still work."
            } catch {
                status = "Enrollment stopped locally. Could not remove the synced entry; retry turning this off. Existing pairings still work."
            }
        }
    }

    @discardableResult
    func saveEndpoint(_ rawEndpoint: String, portText: String) -> Bool {
        guard !isPreview else { return false }
        let raw = rawEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.isEmpty || PeelICloudPairingValidation.endpointHost(raw) != nil else {
            status = "Enter a Tailscale address, .ts.net name, or private network address."; return false
        }
        guard let port = UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0,
              port != controlPort else {
            status = "Use a port from 1 to 65535, different from the connection port."; return false
        }
        manualEndpoint = raw.isEmpty ? "" : PeelICloudPairingValidation.endpointHost(raw)!
        defaults.set(manualEndpoint, forKey: Self.endpointKey)
        if port != pairingPort { stopListener() }
        pairingPort = port
        defaults.set(Int(port), forKey: Self.portKey)
        refresh()
        return true
    }

    /// Rotation revokes account keys issued by this Host, including older local
    /// epochs. Code pairings and outbound Mac receiver pairings are retained.
    func rotateAndRevokeAccountDevices() {
        guard isEnabled, !isPreview else { return }
        stopListener(clearReplies: true)
        record = nil
        publishedRecord = nil
        forceFreshRecord = true
        // The old credential cannot be loaded again after a failed rotation.
        isEnabled = false
        defaults.set(false, forKey: Self.enabledKey)
        PeelKeychain.delete(service: Self.localService, account: hostID)
        let ids = pairingStore.paired.filter(isLocallyIssued).map(\.id)
        ids.forEach(revokePeer)
        do { try vault.remove(hostID: hostID) } catch {
            status = "Old account enrollment stopped and account devices revoked. Synced entry removal failed; enable again to replace it."
            return
        }
        isEnabled = true
        defaults.set(true, forKey: Self.enabledKey)
        refresh()
    }

    /// Call before a user's explicit Host Forget action removes peer metadata.
    func noteExplicitRevocation(_ peer: PeelPairedPeer) {
        guard !isPreview, isLocallyIssued(peer),
              let deviceID = peer.serviceName, PeelICloudPairingValidation.validDeviceID(deviceID) else { return }
        blockedDeviceIDs.insert(deviceID.lowercased())
        defaults.set(blockedDeviceIDs.sorted(), forKey: Self.blockedKey)
        replies.remove(pairingID: peer.id)
    }

    func shutdown() { stopListener(clearReplies: true) }

    /// Explicit Refresh is the only path that retries an unavailable local read.
    func refreshRegistration() { refresh(explicitRetry: true) }

    private func pauseAfterAccountChangeSignal() {
        let issuedIDs = pairingStore.paired.filter(isLocallyIssued).map(\.id)
        guard isEnabled || record != nil || !issuedIDs.isEmpty else { return }
        // Disable acceptance and its persisted opt-in before touching any cloud
        // state. A cached bootstrap from the old account must never resume later.
        isEnabled = false
        defaults.set(false, forKey: Self.enabledKey)
        stopListener(clearReplies: true)
        record = nil
        publishedRecord = nil
        forceFreshRecord = true
        PeelKeychain.delete(service: Self.localService, account: hostID)
        issuedIDs.forEach(revokePeer)
        // Do not query/delete the synchronized namespace after an identity change:
        // it may already belong to a different account. The old local credential
        // is inactive, and explicit reenable always generates a new epoch and key.
        status = "An iCloud account change was reported. Account pairing is off and this Mac's account-issued device keys were revoked. Enable again to create new enrollment."
    }

    private func refresh(explicitRetry: Bool = false) {
        guard !isPreview, isEnabled else { return }
        guard isConfigured else { stopListener(); status = PeelICloudPairingError.unavailable.localizedDescription; return }
        guard hostAvailable, let controlPort else {
            stopListener(); status = "Waiting for the Mac's connection listener. Enable discovery to accept pairing."; return
        }
        guard pairingPort != controlPort else {
            stopListener(); status = "Account pairing needs a different port from the connection listener."; return
        }
        let detected = manualEndpoint.isEmpty ? Self.tailscaleIPv4Address() : manualEndpoint
        guard let detected, let cleanEndpoint = PeelICloudPairingValidation.endpointHost(detected) else {
            stopListener(); endpoint = ""
            status = "Connect Tailscale, or enter this Mac's private address below."; return
        }
        endpoint = cleanEndpoint
        do {
            if record == nil, !forceFreshRecord,
               let saved = try savedLocalRecordData(explicitRetry: explicitRetry) {
                guard saved.count <= 4096,
                      let decoded = try? JSONDecoder().decode(PeelICloudHostRecord.self, from: saved),
                      decoded.isValid, decoded.hostID == hostID else { throw PeelICloudPairingError.invalidRecord }
                record = decoded
                rememberOwnedEpoch(decoded.enrollmentID)
            }
            let needsUpdate = record.map {
                $0.endpointHost != cleanEndpoint || $0.controlPort != controlPort ||
                $0.pairingPort != pairingPort || $0.displayName != hostName
            } ?? true
            if needsUpdate || forceFreshRecord {
                let old = forceFreshRecord ? nil : record
                let updated = try PeelICloudHostRecord(hostID: hostID,
                    enrollmentID: old?.enrollmentID ?? UUID().uuidString,
                    displayName: hostName, endpointHost: cleanEndpoint, controlPort: controlPort,
                    pairingPort: pairingPort, bootstrapSecret: try old?.bootstrapSecret ?? PeelICloudPairingValidation.generateSecret())
                let data = try JSONEncoder().encode(updated)
                try PeelKeychain.setData(data, service: Self.localService, account: hostID)
                guard PeelKeychain.getData(service: Self.localService, account: hostID) == data else {
                    throw PeelICloudPairingError.invalidRecord
                }
                record = updated
                rememberOwnedEpoch(updated.enrollmentID)
                forceFreshRecord = false
            }
            if listener == nil { try startListener() }
            publishIfReady()
        } catch {
            stopListener()
            status = "Account pairing paused. \(error.localizedDescription)"
        }
    }

    /// Only an actual notFound permits minting a new enrollment record. Denied,
    /// unavailable or in-flight reads pause instead of replacing the saved key.
    private func savedLocalRecordData(explicitRetry: Bool) throws -> Data? {
        let cached = PeelKeychain.cachedReadResult(service: Self.localService, account: hostID)
        let result: PeelKeychainReadResult
        if explicitRetry, let cached, cached.data == nil {
            result = PeelKeychain.retryDataResult(service: Self.localService, account: hostID)
        } else {
            result = PeelKeychain.readDataResult(service: Self.localService, account: hostID)
        }
        switch result {
        case .available(let data): return data
        case .notFound: return nil
        case .invalidData: throw PeelICloudPairingError.invalidRecord
        case .authorizationUnavailable(let status), .failure(let status):
            throw PeelICloudPairingError.keychain(status)
        case .readInProgress, .readInvalidated, .cacheCapacityReached:
            throw PeelICloudPairingError.keychain(errSecInteractionNotAllowed)
        }
    }

    private func startListener() throws {
        guard let record else { return }
        let identity = record.tlsIdentity
        let parameters = PeelTLS.makeHostParameters(
            pairedPeers: [PeelPairedPeer(id: identity, displayName: "Account enrollment")],
            keyProvider: { $0 == identity ? record.bootstrapSecret : nil })
        parameters.allowLocalEndpointReuse = false
        let newListener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: pairingPort)!)
        let epoch = generation
        listener = newListener
        status = "Starting account pairing listener…"
        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            guard let self, let newListener, self.listener === newListener, self.generation == epoch else { return }
            switch state {
            case .ready:
                self.listenerReady = true
                self.publishIfReady()
            case .failed, .waiting:
                self.stopListener()
                self.status = "Account pairing port is unavailable. Check the port and retry."
            case .cancelled:
                self.listenerReady = false
            default: break
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            guard let self, self.generation == epoch, self.isEnabled, self.hostAvailable,
                  self.listenerReady, self.publishedRecord == self.record else { connection.cancel(); return }
            self.accept(connection, epoch: epoch)
        }
        newListener.start(queue: .main)
    }

    private func publishIfReady() {
        guard isEnabled, hostAvailable, controlPort != nil, listenerReady, let record else { return }
        if record == publishedRecord {
            status = "Enrollment saved to iCloud Keychain. Sync to your other devices may take time."
            return
        }
        do {
            try vault.upsert(record)
            publishedRecord = record
            status = "Enrollment saved to iCloud Keychain. Sync to your other devices may take time."
        } catch {
            // Never leave an accepting listener behind a failed publication.
            stopListener()
            status = error.localizedDescription
        }
    }

    private func stopListener(clearReplies: Bool = false) {
        generation = UUID()
        listenerReady = false
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for pending in connections.values {
            pending.timeout?.cancel()
            pending.connection.stateUpdateHandler = nil
            pending.connection.cancel()
        }
        connections.removeAll()
        if clearReplies { replies.removeAll() }
    }

    private func accept(_ connection: NWConnection, epoch: UUID) {
        guard connections.count < Self.maxConnections else { connection.cancel(); return }
        let id = UUID()
        let pending = PendingConnection(connection)
        connections[id] = pending
        let timeout = DispatchWorkItem { [weak self] in self?.finishConnection(id) }
        pending.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
        connection.stateUpdateHandler = { [weak self, weak pending] state in
            guard let self, let pending, self.connections[id] === pending, self.generation == epoch else { return }
            switch state {
            case .ready:
                guard !pending.didReceive else { return }
                pending.didReceive = true
                self.receive(id: id, epoch: epoch)
            case .failed, .cancelled: self.finishConnection(id)
            default: break
            }
        }
        connection.start(queue: .main)
    }

    private func receive(id: UUID, epoch: UUID) {
        guard let pending = connections[id] else { return }
        pending.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak pending] data, _, complete, error in
            guard let self, let pending, self.connections[id] === pending, self.generation == epoch else { return }
            guard error == nil else { self.finishConnection(id); return }
            if let data { pending.buffer.append(data) }
            switch PeelICloudPairRequestFrameDecoder.decode(pending.buffer, isComplete: complete) {
            case .request(let request):
                self.respond(to: request, id: id)
            case .invalid: self.finishConnection(id)
            case .incomplete: self.receive(id: id, epoch: epoch)
            }
        }
    }

    private func respond(to request: PeelICloudPairRequest, id: UUID) {
        guard let pending = connections[id], isEnabled, hostAvailable,
              listenerReady, let record, publishedRecord == record else { finishConnection(id); return }
        guard request.isValid(for: record) else { finishConnection(id); return }
        let response: PeelICloudPairResponse
        if let cached = replies.response(for: request, record: record, peers: pairingStore.paired,
            blockedDeviceIDs: blockedDeviceIDs, keyForPairing: pairingStore.psk(for:)) {
            response = cached
        } else if let reason = PeelICloudHostEnrollmentPolicy.rejection(for: request, record: record,
                    peers: pairingStore.paired, blockedDeviceIDs: blockedDeviceIDs, ownedEnrollmentIDs: ownedEnrollmentIDs) {
            response = rejection(request, record: record, reason: reason)
        } else {
            do {
                let secret = try PeelICloudPairingValidation.generateSecret()
                let pairingID = UUID().uuidString
                _ = try pairingStore.addPeerPersistingKey(displayName: request.clientName,
                    serviceName: request.clientDeviceID, tlsPSKOrder: .standard,
                    pairingID: pairingID, psk: secret, iCloudEnrollmentID: record.enrollmentID)
                response = PeelICloudPairResponse(hostID: record.hostID, enrollmentID: record.enrollmentID,
                    requestID: request.requestID, hostName: hostName, accepted: true, pairingID: pairingID, psk: secret)
                replies.insert(request: request, response: response)
            } catch {
                response = rejection(request, record: record, reason: "The Mac could not save a pairing key. Try again after unlocking it.")
            }
        }
        guard var data = try? JSONEncoder().encode(response) else { finishConnection(id); return }
        data.append(0x0a)
        pending.connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.finishConnection(id)
        })
    }

    private func rejection(_ request: PeelICloudPairRequest, record: PeelICloudHostRecord,
                           reason: String) -> PeelICloudPairResponse {
        PeelICloudPairResponse(hostID: record.hostID, enrollmentID: record.enrollmentID,
            requestID: request.requestID, hostName: hostName, accepted: false, reason: reason)
    }

    private func isLocallyIssued(_ peer: PeelPairedPeer) -> Bool {
        PeelICloudHostEnrollmentPolicy.isLocallyIssued(peer, ownedEnrollmentIDs: ownedEnrollmentIDs)
    }

    private func rememberOwnedEpoch(_ id: String) {
        let liveEpochs = Set(pairingStore.paired.compactMap(\.iCloudEnrollmentID))
        ownedEnrollmentIDs = ownedEnrollmentIDs.intersection(liveEpochs)
        ownedEnrollmentIDs.insert(id)
        defaults.set(ownedEnrollmentIDs.sorted(), forKey: Self.ownedEpochsKey)
        cloudDeviceCount = pairingStore.paired.filter(isLocallyIssued).count
    }

    private func finishConnection(_ id: UUID) {
        guard let pending = connections.removeValue(forKey: id) else { return }
        pending.timeout?.cancel()
        pending.connection.stateUpdateHandler = nil
        pending.connection.cancel()
    }

    private static func tailscaleIPv4Address() -> String? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { return nil }
        defer { freeifaddrs(addresses) }
        var candidates = [String]()
        var cursor = addresses
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr, Int32(address.pointee.sa_family) == AF_INET,
                  current.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            let ipv4 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            let value = UInt32(bigEndian: ipv4.s_addr)
            guard (value & 0xffc00000) == 0x64400000 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            candidates.append(String(cString: buffer))
        }
        return candidates.sorted().first
    }
}
