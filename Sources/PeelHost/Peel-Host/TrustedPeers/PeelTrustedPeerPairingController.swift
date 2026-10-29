//
//  PeelTrustedPeerPairingController.swift
//  Peel-Host
//

import Foundation
import Combine
import Network

struct PeelTrustedPeerService: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let serviceName: String
    let hostName: String
    let hostId: String
    let pinSalt: Data
    let pinExpiresAt: Date
    let pairPort: UInt16
    let tlsPSKOrder: PeelTLSPSKOrder

    var isPINFresh: Bool {
        pinExpiresAt > Date()
    }
}

enum PeelTrustedPeerPairingError: Error, Equatable, LocalizedError {
    case busy
    case invalidPIN
    case serviceUnavailable
    case serviceChanged
    case invalidAdvertisement
    case expiredPIN
    case legacyTLSOrder
    case resolveFailed
    case connectionFailed(String)
    case timedOut
    case cancelled
    case superseded
    case responseTooLarge
    case malformedResponse
    case rejected(String)
    case duplicatePairingID
    case invalidPairingMaterial
    case keychainWriteFailed

    var errorDescription: String? {
        switch self {
        case .busy:
            return "A Mac pairing attempt is already in progress."
        case .invalidPIN:
            return "Enter the six-digit PIN shown on the other computer."
        case .serviceUnavailable:
            return "That Mac is no longer available for pairing."
        case .serviceChanged:
            return "The selected Mac changed while pairing. Select it again and retry."
        case .invalidAdvertisement:
            return "The selected Mac did not publish valid PIN pairing details."
        case .expiredPIN:
            return "That Mac's PIN has expired. Generate a new PIN and retry."
        case .legacyTLSOrder:
            return "That Mac does not advertise the current TLS pairing order. Update it before pairing."
        case .resolveFailed:
            return "Peel could not refresh the selected Mac's pairing details."
        case let .connectionFailed(detail):
            return detail.isEmpty ? "The pairing connection failed." : "The pairing connection failed: \(detail)"
        case .timedOut:
            return "Pairing timed out after 15 seconds. Check that both computers are reachable and retry."
        case .cancelled:
            return "Pairing cancelled."
        case .superseded:
            return "The earlier pairing attempt was replaced."
        case .responseTooLarge:
            return "The pairing response was too large."
        case .malformedResponse:
            return "The other computer sent an invalid pairing response."
        case let .rejected(reason):
            return reason.isEmpty ? "The other computer rejected pairing." : reason
        case .duplicatePairingID:
            return "The other computer returned a pairing that already exists."
        case .invalidPairingMaterial:
            return "The other computer did not return valid pairing material."
        case .keychainWriteFailed:
            return "Peel could not verify the new pairing in Keychain."
        }
    }
}

enum PeelTrustedPeerPairingResult {
    case paired(PeelPairedPeer)
    case failed(PeelTrustedPeerPairingError)
    case cancelled
    case superseded
}

final class PeelTrustedPeerPairingController: NSObject, ObservableObject {
    typealias Completion = (PeelTrustedPeerPairingResult) -> Void

    @Published private(set) var discoveredPeers: [PeelTrustedPeerService] = []
    @Published private(set) var pairedPeers: [PeelPairedPeer] = []
    @Published private(set) var pairingStatus: String = "Ready to pair with another computer."
    @Published private(set) var isPairing = false
    @Published private(set) var pendingServiceID: String?
    @Published private(set) var retryingSavedPairingID: String?

    /// The caller can observe this without owning a completion per attempt.
    var onPairingResult: Completion?

    let pairingStore: PeelPairingStore
    let localHostID: String
    let localDisplayName: String

    private let onForgetPeer: (String) -> Void
    private let serviceBrowser = NetServiceBrowser()
    private var servicesByID: [String: NetService] = [:]
    private var resolvedPeersByID: [String: PeelTrustedPeerService] = [:]
    private var pairingStoreCancellable: AnyCancellable?
    private var pendingAttempt: PendingAttempt?
    private var generation: UInt64 = 0
    private var isSearching = false
    private var hasPairingResult = false

    private static let pairingServiceType = "_peelpair._tcp."
    private static let pairingDomain = "local."
    private static let pairingAttemptTimeout: TimeInterval = 15.0
    private static let resolveTimeout: TimeInterval = 5.0
    private static let maxResponseBytes = 16 * 1024
    private static let maxTextBytes = 256

    private static var isPreviewMode: Bool {
        ProcessInfo.processInfo.arguments.contains("--peel-preview")
    }

    private final class PendingAttempt {
        let generation: UInt64
        let serviceID: String
        let selectedService: PeelTrustedPeerService
        let pin: String
        let completion: Completion?
        var connection: NWConnection?
        var responseBuffer = Data()
        var timeoutWorkItem: DispatchWorkItem?
        var didSendRequest = false

        init(
            generation: UInt64,
            serviceID: String,
            selectedService: PeelTrustedPeerService,
            pin: String,
            completion: Completion?
        ) {
            self.generation = generation
            self.serviceID = serviceID
            self.selectedService = selectedService
            self.pin = pin
            self.completion = completion
        }
    }

    init(
        pairingStore: PeelPairingStore,
        localHostID: String,
        localDisplayName: String,
        onForgetPeer: @escaping (String) -> Void = { _ in }
    ) {
        self.pairingStore = pairingStore
        self.localHostID = localHostID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.localDisplayName = localDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.onForgetPeer = onForgetPeer
        self.pairedPeers = pairingStore.paired
        super.init()

        serviceBrowser.delegate = self
        pairingStoreCancellable = pairingStore.$paired
            .receive(on: DispatchQueue.main)
            .sink { [weak self] peers in
                self?.pairedPeers = peers
            }
    }

    deinit {
        serviceBrowser.stop()
        pairingStoreCancellable?.cancel()
        pendingAttempt?.connection?.cancel()
        pendingAttempt?.timeoutWorkItem?.cancel()
    }

    func startDiscovery() {
        guard !Self.isPreviewMode else { return }
        runOnMain { [weak self] in
            guard let self, !self.isSearching else { return }
            self.servicesByID.removeAll()
            self.resolvedPeersByID.removeAll()
            self.discoveredPeers.removeAll()
            self.isSearching = true
            self.setDiscoveryStatus("Looking for computers running Peel Pro on the local network…")
            self.serviceBrowser.searchForServices(
                ofType: Self.pairingServiceType,
                inDomain: Self.pairingDomain
            )
        }
    }

    func stopDiscovery() {
        runOnMain { [weak self] in
            guard let self else { return }
            if let attempt = pendingAttempt {
                finish(attempt, result: .superseded, cancelConnection: true)
            }
            self.isSearching = false
            self.serviceBrowser.stop()
            self.servicesByID.removeAll()
            self.resolvedPeersByID.removeAll()
            self.discoveredPeers.removeAll()
        }
    }

    @discardableResult
    func beginPairing(
        remote: PeelTrustedPeerService,
        pin rawPIN: String,
        completion: Completion? = nil
    ) -> Bool {
        guard !Self.isPreviewMode else { return false }
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                _ = self?.beginPairing(remote: remote, pin: rawPIN, completion: completion)
            }
            return true
        }

        // Only another explicit pairing action retires the previous result.
        hasPairingResult = false

        if pendingAttempt != nil || retryingSavedPairingID != nil {
            let error = PeelTrustedPeerPairingError.busy
            setPairingResultStatus(error.localizedDescription)
            completion?(PeelTrustedPeerPairingResult.failed(error))
            return false
        }

        let pin = rawPIN.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSixDigitPIN(pin) else {
            let error = PeelTrustedPeerPairingError.invalidPIN
            setPairingResultStatus(error.localizedDescription)
            completion?(PeelTrustedPeerPairingResult.failed(error))
            return false
        }

        guard !localHostID.isEmpty, Self.boundedText(localHostID) != nil else {
            let error = PeelTrustedPeerPairingError.invalidPairingMaterial
            setPairingResultStatus(error.localizedDescription)
            completion?(PeelTrustedPeerPairingResult.failed(error))
            return false
        }

        guard let service = resolvedPeersByID[remote.id],
              let trackedService = servicesByID[remote.id],
              let current = discoveredPeers.first(where: { $0.id == remote.id }),
              current.hostId == remote.hostId,
              service.hostId == remote.hostId else {
            let error = PeelTrustedPeerPairingError.serviceUnavailable
            setPairingResultStatus(error.localizedDescription)
            completion?(PeelTrustedPeerPairingResult.failed(error))
            return false
        }

        guard current.isPINFresh else {
            let error = PeelTrustedPeerPairingError.expiredPIN
            setPairingResultStatus(error.localizedDescription)
            completion?(PeelTrustedPeerPairingResult.failed(error))
            return false
        }

        generation &+= 1
        let attempt = PendingAttempt(
            generation: generation,
            serviceID: remote.id,
            selectedService: current,
            pin: pin,
            completion: completion
        )
        pendingAttempt = attempt
        isPairing = true
        pendingServiceID = remote.id
        pairingStatus = "Refreshing \(current.serviceName)…"

        let timeout = DispatchWorkItem { [weak self, weak attempt] in
            guard let self, let attempt, self.isCurrent(attempt) else { return }
            self.finish(attempt, result: .failed(.timedOut), cancelConnection: true)
        }
        attempt.timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.pairingAttemptTimeout,
            execute: timeout
        )

        trackedService.delegate = self
        trackedService.resolve(withTimeout: Self.resolveTimeout)
        return true
    }

    func cancelPairing() {
        runOnMain { [weak self] in
            guard let self, let attempt = self.pendingAttempt else { return }
            self.finish(attempt, result: .cancelled, cancelConnection: true)
        }
    }

    /// Cache status only: rendering the row must never query Keychain.
    func canRetrySavedConnection(pairingID: String) -> Bool {
        guard pairedPeers.contains(where: { $0.id == pairingID }) else { return false }
        switch pairingStore.cachedPSKReadResult(for: pairingID) {
        case .available(let data) where data.count < 32:
            return true
        case .notFound, .authorizationUnavailable, .failure, .invalidData, .readInvalidated, .cacheCapacityReached:
            return true
        default: return false
        }
    }

    /// Exceptional recovery from a selected row click, never discovery/startup.
    /// This synchronous OS operation may show authentication for that ONE item.
    func retrySavedConnection(pairingID: String) {
        guard pendingAttempt == nil, retryingSavedPairingID == nil,
              canRetrySavedConnection(pairingID: pairingID),
              let peer = pairingStore.paired.first(where: { $0.id == pairingID }) else { return }
        retryingSavedPairingID = pairingID
        defer { retryingSavedPairingID = nil }
        setPairingResultStatus("Authorizing saved connection for \(peer.displayName)…")
        let result = pairingStore.pskReadForExplicitConnection(for: pairingID)
        guard pairingStore.paired.contains(where: {
            $0.id == peer.id && $0.serviceName == peer.serviceName &&
            $0.stableHostId == peer.stableHostId && $0.tlsPSKOrder == peer.tlsPSKOrder
        }) else {
            setPairingResultStatus("This pairing changed while authorizing. No saved connection was restored.")
            return
        }
        switch result {
        case .available(let data) where data.count >= 32:
            setPairingResultStatus("Saved connection ready for \(peer.displayName).")
        case .notFound:
            setPairingResultStatus("The saved connection key was not found. Its pairing record has been kept. Pair again to replace it.")
        case .readInProgress:
            setPairingResultStatus("Saved connection authorization is already in progress.")
        default:
            setPairingResultStatus("Saved connection authorization is unavailable. Its pairing record has been kept. Select Retry saved connection to try again.")
        }
    }

    /// Forgetting is deliberately delegated to the caller. The controller
    /// never sends a revocation or mutates the trust store implicitly.
    @discardableResult
    func forgetPeer(pairingID rawPairingID: String, onForget: ((String) -> Void)? = nil) -> Bool {
        let pairingID = rawPairingID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pairingID.isEmpty,
              pairedPeers.contains(where: { $0.id == pairingID }) else {
            return false
        }
        (onForget ?? self.onForgetPeer)(pairingID)
        return true
    }

    private func handleFreshResolution(_ service: NetService, serviceID: String) {
        guard let attempt = pendingAttempt, attempt.serviceID == serviceID else {
            refreshResolvedPeer(service, serviceID: serviceID)
            return
        }

        do {
            let refreshed = try makePeerService(from: service, serviceID: serviceID)
            guard refreshed.hostId == attempt.selectedService.hostId else {
                finish(attempt, result: .failed(.serviceChanged), cancelConnection: true)
                return
            }
            guard refreshed.isPINFresh else {
                finish(attempt, result: .failed(.expiredPIN), cancelConnection: true)
                return
            }
            guard refreshed.tlsPSKOrder == .standard else {
                finish(attempt, result: .failed(.legacyTLSOrder), cancelConnection: true)
                return
            }
            guard attempt.connection == nil else { return }
            startPairingConnection(attempt, service: refreshed)
        } catch let error as PeelTrustedPeerPairingError {
            finish(attempt, result: .failed(error), cancelConnection: true)
        } catch {
            finish(attempt, result: .failed(.invalidAdvertisement), cancelConnection: true)
        }
    }

    private func refreshResolvedPeer(_ service: NetService, serviceID: String) {
        do {
            let peer = try makePeerService(from: service, serviceID: serviceID)
            servicesByID[serviceID] = service
            resolvedPeersByID[serviceID] = peer
            discoveredPeers.removeAll { $0.id == serviceID }
            discoveredPeers.append(peer)
            discoveredPeers.sort {
                $0.serviceName.localizedCaseInsensitiveCompare($1.serviceName) == .orderedAscending
            }
            setDiscoveryStatus("Found \(discoveredPeers.count) Mac\(discoveredPeers.count == 1 ? "" : "s").")
        } catch let error as PeelTrustedPeerPairingError {
            resolvedPeersByID[serviceID] = nil
            discoveredPeers.removeAll { $0.id == serviceID }
            setDiscoveryStatus(error.localizedDescription)
        } catch {
            resolvedPeersByID[serviceID] = nil
            discoveredPeers.removeAll { $0.id == serviceID }
            setDiscoveryStatus(PeelTrustedPeerPairingError.invalidAdvertisement.localizedDescription)
        }
    }

    private func startPairingConnection(_ attempt: PendingAttempt, service: PeelTrustedPeerService) {
        guard isCurrent(attempt), let netService = servicesByID[attempt.serviceID] else { return }
        guard let hostName = netService.hostName,
              let endpointHost = Self.validHost(hostName),
              let port = NWEndpoint.Port(rawValue: service.pairPort) else {
            finish(attempt, result: .failed(.resolveFailed), cancelConnection: true)
            return
        }

        let pinPSK = PeelTLS.derivePairingPinPSK(
            pin: attempt.pin,
            salt: service.pinSalt,
            hostId: service.hostId
        )
        guard pinPSK.count >= 32 else {
            finish(attempt, result: .failed(.invalidPairingMaterial), cancelConnection: true)
            return
        }

        let pinProof = PeelTLS.makePairingPinProof(
            pinPSK: pinPSK,
            hostId: service.hostId,
            clientDeviceId: localHostID
        )
        let request = PairRequestMessage(
            clientName: boundedDisplayName,
            clientDeviceId: localHostID,
            pinProof: pinProof
        )
        guard var requestData = try? JSONEncoder().encode(request),
              requestData.count < Self.maxResponseBytes else {
            finish(attempt, result: .failed(.invalidPairingMaterial), cancelConnection: true)
            return
        }
        requestData.append(0x0A)

        let parameters = PeelTLS.makeClientParameters(
            pairingID: PeelTLS.pairingPinIdentity,
            psk: pinPSK,
            pskOrder: service.tlsPSKOrder
        )
        let connection = NWConnection(host: endpointHost, port: port, using: parameters)
        attempt.connection = connection
        connection.stateUpdateHandler = { [weak self, weak attempt] state in
            self?.runOnMain { [weak self, weak attempt] in
                guard let self, let attempt, self.isCurrent(attempt) else { return }
                switch state {
                case .ready:
                    guard !attempt.didSendRequest else { return }
                    attempt.didSendRequest = true
                    self.pairingStatus = "Sending a pairing request to \(service.serviceName)…"
                    connection.send(content: requestData, completion: .contentProcessed { [weak self, weak attempt] error in
                        self?.runOnMain { [weak self, weak attempt] in
                            guard let self, let attempt, self.isCurrent(attempt) else { return }
                            if let error {
                                self.finish(
                                    attempt,
                                    result: .failed(.connectionFailed(error.localizedDescription)),
                                    cancelConnection: true
                                )
                                return
                            }
                            self.receiveResponse(for: attempt)
                        }
                    })

                case .waiting:
                    self.pairingStatus = "Waiting for \(service.serviceName)…"

                case .failed(let error):
                    self.finish(
                        attempt,
                        result: .failed(.connectionFailed(error.localizedDescription)),
                        cancelConnection: true
                    )

                case .cancelled:
                    guard self.pendingAttempt != nil else { return }
                    self.finish(attempt, result: .failed(.cancelled), cancelConnection: false)

                default:
                    break
                }
            }
        }
        pairingStatus = "Connecting to \(service.serviceName)…"
        connection.start(queue: .main)
    }

    private func receiveResponse(for attempt: PendingAttempt) {
        guard isCurrent(attempt), let connection = attempt.connection else { return }
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: Self.maxResponseBytes
        ) { [weak self, weak attempt] data, _, isComplete, error in
            self?.runOnMain { [weak self, weak attempt] in
                guard let self, let attempt, self.isCurrent(attempt) else { return }

                if let data, !data.isEmpty {
                    attempt.responseBuffer.append(data)
                    if attempt.responseBuffer.count > Self.maxResponseBytes {
                        self.finish(attempt, result: .failed(.responseTooLarge), cancelConnection: true)
                        return
                    }

                    if let response = Self.decodePairResponse(from: attempt.responseBuffer) {
                        self.handleResponse(response, for: attempt)
                        return
                    }
                }

                if let error {
                    self.finish(
                        attempt,
                        result: .failed(.connectionFailed(error.localizedDescription)),
                        cancelConnection: true
                    )
                    return
                }

                if isComplete {
                    self.finish(attempt, result: .failed(.malformedResponse), cancelConnection: true)
                    return
                }

                self.receiveResponse(for: attempt)
            }
        }
    }

    private func handleResponse(_ response: PairResponseMessage, for attempt: PendingAttempt) {
        guard isCurrent(attempt) else { return }
        guard response.accepted else {
            finish(
                attempt,
                result: .failed(.rejected(Self.boundedReason(response.reason))),
                cancelConnection: true
            )
            return
        }

        guard let pairingID = Self.validUUIDString(response.pairingId),
              response.psk.count >= 32,
              response.psk.count <= 64,
              let responseHostName = Self.boundedText(response.hostName),
              let responseServiceName = Self.boundedText(response.serviceName),
              !responseHostName.isEmpty,
              !responseServiceName.isEmpty else {
            finish(attempt, result: .failed(.invalidPairingMaterial), cancelConnection: true)
            return
        }

        guard !pairingStore.paired.contains(where: { $0.id == pairingID }) else {
            finish(attempt, result: .failed(.duplicatePairingID), cancelConnection: true)
            return
        }

        do {
            // The new throwing store API writes and verifies the new credential
            // before any duplicate metadata cleanup. The controller then reads
            // it back and compares the exact key before reporting success.
            let peer = try pairingStore.addPeerPersistingKey(
                displayName: responseHostName,
                serviceName: responseServiceName,
                stableHostId: attempt.selectedService.hostId,
                tlsPSKOrder: attempt.selectedService.tlsPSKOrder,
                pairingID: pairingID,
                psk: response.psk
            )
            guard let storedPSK = pairingStore.psk(for: pairingID), storedPSK == response.psk else {
                finish(attempt, result: .failed(.keychainWriteFailed), cancelConnection: true)
                return
            }
            finish(attempt, result: .paired(peer), cancelConnection: true)
        } catch {
            finish(attempt, result: .failed(.keychainWriteFailed), cancelConnection: true)
        }
    }

    private func finish(
        _ attempt: PendingAttempt,
        result: PeelTrustedPeerPairingResult,
        cancelConnection: Bool
    ) {
        guard isCurrent(attempt) else { return }
        // Discovery can continue updating its list without hiding this outcome.
        hasPairingResult = true
        pendingAttempt = nil
        isPairing = false
        pendingServiceID = nil
        generation &+= 1
        attempt.timeoutWorkItem?.cancel()
        attempt.timeoutWorkItem = nil
        if cancelConnection {
            attempt.connection?.stateUpdateHandler = nil
            attempt.connection?.cancel()
        }
        attempt.connection = nil

        switch result {
        case let .paired(peer):
            pairingStatus = "Paired with \(peer.displayName)."
        case let .failed(error):
            pairingStatus = error.localizedDescription
        case .cancelled:
            pairingStatus = PeelTrustedPeerPairingError.cancelled.localizedDescription
        case .superseded:
            pairingStatus = PeelTrustedPeerPairingError.superseded.localizedDescription
        }

        attempt.completion?(result)
        onPairingResult?(result)
    }

    private func setPairingResultStatus(_ status: String) {
        hasPairingResult = true
        pairingStatus = status
    }

    private func setDiscoveryStatus(_ status: String) {
        guard !isPairing, !hasPairingResult else { return }
        pairingStatus = status
    }

    private func makePeerService(from service: NetService, serviceID: String) throws -> PeelTrustedPeerService {
        guard let hostName = service.hostName,
              Self.validHost(hostName) != nil,
              let serviceName = Self.boundedText(service.name),
              !serviceName.isEmpty else {
            throw PeelTrustedPeerPairingError.invalidAdvertisement
        }

        let txt = NetService.dictionary(fromTXTRecord: service.txtRecordData() ?? Data())
        guard let pairMode = Self.txtString(txt, key: "pairMode"), pairMode == "pin" else {
            throw PeelTrustedPeerPairingError.invalidAdvertisement
        }
        guard let hostId = Self.boundedText(Self.txtString(txt, key: "hostId")), !hostId.isEmpty else {
            throw PeelTrustedPeerPairingError.invalidAdvertisement
        }
        guard let saltText = Self.txtString(txt, key: "pinSalt"),
              let pinSalt = Data(base64Encoded: saltText),
              pinSalt.count == 16 else {
            throw PeelTrustedPeerPairingError.invalidAdvertisement
        }
        guard let expirationText = Self.txtString(txt, key: "pinExp"),
              let expiration = Double(expirationText),
              expiration.isFinite else {
            throw PeelTrustedPeerPairingError.invalidAdvertisement
        }
        let pinExpiresAt = Date(timeIntervalSince1970: expiration)
        guard pinExpiresAt > Date(),
              expiration <= Date().addingTimeInterval(Self.pairingAttemptTimeout + 10 * 60).timeIntervalSince1970 else {
            throw PeelTrustedPeerPairingError.expiredPIN
        }
        guard let portText = Self.txtString(txt, key: "pairPort"),
              let pairPort = UInt16(portText), pairPort > 0 else {
            throw PeelTrustedPeerPairingError.invalidAdvertisement
        }
        guard let pskOrderText = Self.txtString(txt, key: PeelTLS.pskOrderTXTKey),
              let tlsPSKOrder = PeelTLSPSKOrder(rawValue: pskOrderText) else {
            throw PeelTrustedPeerPairingError.invalidAdvertisement
        }
        guard tlsPSKOrder == .standard else {
            throw PeelTrustedPeerPairingError.legacyTLSOrder
        }

        return PeelTrustedPeerService(
            id: serviceID,
            serviceName: serviceName,
            hostName: hostName,
            hostId: hostId,
            pinSalt: pinSalt,
            pinExpiresAt: pinExpiresAt,
            pairPort: pairPort,
            tlsPSKOrder: tlsPSKOrder
        )
    }

    private func isCurrent(_ attempt: PendingAttempt) -> Bool {
        pendingAttempt === attempt && attempt.generation == generation
    }

    private var boundedDisplayName: String {
        let value = Self.boundedText(localDisplayName) ?? "Peel Pro"
        return value.isEmpty ? "Peel Pro" : value
    }

    private static func serviceID(_ service: NetService) -> String {
        [service.domain, service.type, service.name].joined(separator: "\u{1F}")
    }

    private static func txtString(_ txt: [String: Data], key: String) -> String? {
        guard let data = txt[key], let value = String(data: data, encoding: .utf8) else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func boundedText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= maxTextBytes,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            return nil
        }
        return value
    }

    private static func validHost(_ raw: String) -> NWEndpoint.Host? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= maxTextBytes,
              !value.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value == 0x7F }),
              !value.contains(where: { $0 == "/" || $0 == "\\" || $0 == "?" || $0 == "#" || $0 == "%" || $0 == "@" }) else {
            return nil
        }
        return NWEndpoint.Host(value)
    }

    private static func validUUIDString(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: value) != nil else { return nil }
        return value
    }

    private static func isSixDigitPIN(_ value: String) -> Bool {
        value.count == 6 && value.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
    }

    private static func decodePairResponse(from data: Data) -> PairResponseMessage? {
        if let response = try? JSONDecoder().decode(PairResponseMessage.self, from: data) {
            return response
        }
        guard let newline = data.firstIndex(of: 0x0A) else { return nil }
        let line = data.prefix(upTo: newline)
        return try? JSONDecoder().decode(PairResponseMessage.self, from: line)
    }

    private static func boundedReason(_ raw: String?) -> String {
        boundedText(raw) ?? "The other computer rejected pairing."
    }

    private func runOnMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread {
            action()
        } else {
            DispatchQueue.main.async(execute: action)
        }
    }
}

extension PeelTrustedPeerPairingController: NetServiceBrowserDelegate {
    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {}

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        runOnMain { [weak self] in
            guard let self else { return }
            let id = Self.serviceID(service)
            servicesByID[id] = service
            service.delegate = self
            service.resolve(withTimeout: Self.resolveTimeout)
        }
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        runOnMain { [weak self] in
            guard let self else { return }
            let id = Self.serviceID(service)
            servicesByID[id] = nil
            resolvedPeersByID[id] = nil
            discoveredPeers.removeAll { $0.id == id }
            if let attempt = pendingAttempt, attempt.serviceID == id {
                finish(attempt, result: .failed(.serviceUnavailable), cancelConnection: true)
            }
        }
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        runOnMain { [weak self] in
            self?.isSearching = false
        }
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        runOnMain { [weak self] in
            guard let self else { return }
            isSearching = false
            setDiscoveryStatus("Mac discovery failed.")
        }
    }
}

extension PeelTrustedPeerPairingController: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        runOnMain { [weak self] in
            guard let self else { return }
            let id = Self.serviceID(sender)
            handleFreshResolution(sender, serviceID: id)
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        runOnMain { [weak self] in
            guard let self else { return }
            let id = Self.serviceID(sender)
            if let attempt = pendingAttempt, attempt.serviceID == id {
                finish(attempt, result: .failed(.resolveFailed), cancelConnection: true)
            } else {
                resolvedPeersByID[id] = nil
                discoveredPeers.removeAll { $0.id == id }
                setDiscoveryStatus("Could not read pairing details from the selected Mac.")
            }
        }
    }
}
