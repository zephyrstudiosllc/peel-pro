//
//  PeelClientMachineStatusController.swift
//  Connection-bound, opt-in client admission for Mac Status.
//
//  This controller owns no sampler and performs no background refresh. Each
//  request is explicit and has one five-second deadline. The live integration
//  supplies the existing PeelHostSession and sendJSONMessage transport.
//

import Foundation

nonisolated public enum PeelClientMachineStatusState: Equatable, Sendable {
    case unavailable
    case idle
    case refreshing
    case available
    case failed
}

/// Client-only policy constants. Keeping the defaults key and capability next
/// to the controller makes the opt-in gate auditable when the live files are
/// patched; no entitlement is inferred from pairing alone.
nonisolated public enum PeelClientMachineStatusPolicy {
    public static let capability = "machine-status-v1"
    public static let optInDefaultsKey = "peel.ai.allowMachineStatus"
    public static let requestTimeout: TimeInterval = 5.0
    /// Cached usage can legitimately be several minutes old. Host-side CPU /
    /// GPU adapters own their shorter source-age filters; the client only
    /// applies this bounded transport admission window.
    public static let maximumSampleAge: TimeInterval = 10.0 * 60.0
    public static let maximumFutureSkew: TimeInterval = 5.0
    public static let maximumErrorReasonUTF8Bytes = 256

    public static var isSupportedPlatform: Bool {
#if os(iOS) || os(visionOS)
        return true
#else
        return false
#endif
    }

    public static var isLocallyOptedIn: Bool {
#if os(iOS) || os(visionOS)
        return PeelMachineStatusAccess.isOptedIn
#else
        return false
#endif
    }

    public static func normalizedRequestID(_ value: String) -> String? {
        UUID(uuidString: value)?.uuidString
    }

    public static func isFreshSample(
        sampledAt: TimeInterval,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        guard sampledAt.isFinite, now.isFinite, sampledAt >= 0 else { return false }
        return sampledAt <= now + maximumFutureSkew
            && sampledAt >= now - maximumSampleAge
    }
}

#if os(iOS) || os(visionOS)

import Combine
import Network

@MainActor
public final class PeelClientMachineStatusController: ObservableObject {
    public static let initialAvailability = "Choose a connected computer, allow Computer Status, then tap Refresh."
    public static let unsupportedPlatformMessage = "Computer Status is unavailable on this client platform."
    public static let optedOutMessage = "Allow Computer Status to request a snapshot from this computer."

    /// The session is the owner. A weak reference avoids making the session's
    /// lazy controller keep the session alive after browser removal.
    weak var session: PeelHostSession?

    @Published public private(set) var viewModel: PeelMachineStatusViewModel
    @Published public private(set) var state: PeelClientMachineStatusState
    @Published public private(set) var snapshot: PeelMachineStatusMessage?
    @Published public private(set) var error: String?
    @Published public private(set) var isRefreshing: Bool

    private var availability: String?
    private var pendingRequestID: String?
    private var pendingPairingID: String?
    private weak var pendingConnection: NWConnection?
    private var pendingDeadline: Date?
    private var deadlineWorkItem: DispatchWorkItem?

    /// Internal because PeelHostSession is intentionally module-scoped. The
    /// public controller remains usable by shared client UI and tests through
    /// its published state and explicit methods.
    init(session: PeelHostSession) {
        self.session = session
        self.viewModel = PeelMachineStatusViewModel(
            availability: Self.initialAvailability)
        self.state = .unavailable
        self.snapshot = nil
        self.error = nil
        self.isRefreshing = false
        self.availability = Self.initialAvailability
    }

    deinit {
        deadlineWorkItem?.cancel()
    }

    /// Refresh is a manual action. It never starts a repeating task.
    @discardableResult
    public func refresh() -> Bool {
        request()
    }

    /// Send one status request on the current session control socket.
    @discardableResult
    public func request() -> Bool {
        guard PeelClientMachineStatusPolicy.isLocallyOptedIn else {
            reset(reason: Self.optedOutMessage)
            return false
        }

        // A second tap cannot replace the request or its connection binding.
        guard pendingRequestID == nil else { return false }

        guard let session else {
            showUnavailable("Connect to a paired computer before requesting status.")
            return false
        }
        guard session.isConnectionReady, let connection = session.connection else {
            showUnavailable("Connect to a paired computer before requesting status.")
            return false
        }
        guard let pairingID = session.activePairingID,
              !pairingID.isEmpty,
              session.browser?.pairedPeer(forPairingID: pairingID) != nil else {
            showUnavailable("This computer is not paired on the current connection.")
            return false
        }
        guard session.hostCapabilities.contains(PeelClientMachineStatusPolicy.capability) else {
            showUnavailable("This computer does not offer Computer Status in this connection.")
            return false
        }

        let requestUUID = UUID()
        let requestID = requestUUID.uuidString
        pendingRequestID = requestID
        pendingPairingID = pairingID
        pendingConnection = connection
        let deadline = Date().addingTimeInterval(PeelClientMachineStatusPolicy.requestTimeout)
        pendingDeadline = deadline
        availability = nil
        error = nil
        isRefreshing = true
        state = .refreshing
        publish()

        let work = DispatchWorkItem { [weak self] in
            self?.expirePendingRequest(requestID: requestID)
        }
        deadlineWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + PeelClientMachineStatusPolicy.requestTimeout,
            execute: work)

        // sendJSONMessage is the existing NDJSON control path. The controller
        // does not open a second socket or create a provider/sampler.
        session.sendJSONMessage(PeelMachineStatusRequest(requestID: requestUUID))
        return true
    }

    /// Revalidate availability after hostHello, connection-ready, or a local
    /// preference change. This method does not request or poll.
    public func refreshAvailability() {
        guard PeelClientMachineStatusPolicy.isLocallyOptedIn else {
            reset(reason: Self.optedOutMessage)
            return
        }
        guard let session else {
            showUnavailable("Connect to a paired computer before requesting status.")
            return
        }
        guard session.isConnectionReady, session.connection != nil else {
            showUnavailable("Connect to a paired computer before requesting status.")
            return
        }
        guard let pairingID = session.activePairingID,
              !pairingID.isEmpty,
              session.browser?.pairedPeer(forPairingID: pairingID) != nil else {
            showUnavailable("This computer is not paired on the current connection.")
            return
        }
        guard session.hostCapabilities.contains(PeelClientMachineStatusPolicy.capability) else {
            showUnavailable("This computer does not offer Computer Status in this connection.")
            return
        }

        guard pendingRequestID == nil else { return }
        if snapshot == nil, error == nil {
            availability = nil
            state = .idle
            publish()
        }
    }

    /// Accept a reply only for the exact control connection and pairing that
    /// originated the pending request. The wire model has already enforced its
    /// bounded fields during Codable decoding.
    public func receive(
        _ message: PeelMachineStatusMessage,
        sourceConnection: NWConnection
    ) {
        guard admits(message.requestId, sourceConnection: sourceConnection),
              PeelClientMachineStatusPolicy.isFreshSample(
                  sampledAt: message.sampledAt) else {
            return
        }

        clearPending()
        snapshot = message
        availability = nil
        error = nil
        isRefreshing = false
        state = .available
        publish()
    }

    /// An error is admitted with the same request, socket, pairing, freshness,
    /// and opt-in gates as a data reply. Its reason is bounded by the staged
    /// error envelope before this method is called.
    public func receive(
        _ message: PeelMachineStatusErrorMessage,
        sourceConnection: NWConnection
    ) {
        guard admits(message.requestId, sourceConnection: sourceConnection),
              (try? PeelMachineStatusValidation.text(
                  message.reason,
                  field: "reason",
                  maximumUTF8Bytes: PeelClientMachineStatusPolicy.maximumErrorReasonUTF8Bytes)) != nil else {
            return
        }

        clearPending()
        snapshot = nil
        availability = nil
        error = message.reason
        isRefreshing = false
        state = .failed
        publish()
    }

    /// Called by the existing session disconnect/revoke path and by opt-out.
    /// It clears both the pending deadline and all retained remote status.
    public func reset(reason: String = "Computer Status is unavailable.") {
        clearPending()
        snapshot = nil
        error = nil
        isRefreshing = false
        state = .unavailable
        availability = reason
        publish()
    }

    /// Called after `refreshAgentPresentationCapabilities()` updates the
    /// existing client hello. Opt-out is destructive to retained status so a
    /// later opt-in cannot display data from the prior permission window.
    func handleLocalOptInChanged() {
        if PeelClientMachineStatusPolicy.isLocallyOptedIn {
            refreshAvailability()
        } else {
            reset(reason: Self.optedOutMessage)
        }
    }

    private func admits(_ requestID: String, sourceConnection: NWConnection) -> Bool {
        guard PeelClientMachineStatusPolicy.isLocallyOptedIn,
              let session,
              let pendingRequestID,
              let pendingPairingID,
              let pendingConnection,
              let pendingDeadline,
              let normalizedRequestID = PeelClientMachineStatusPolicy.normalizedRequestID(requestID),
              normalizedRequestID == pendingRequestID,
              session.connection === sourceConnection,
              pendingConnection === sourceConnection,
              session.isConnectionReady,
              session.activePairingID == pendingPairingID,
              session.browser?.pairedPeer(forPairingID: pendingPairingID) != nil,
              Date() <= pendingDeadline else {
            return false
        }
        return true
    }

    private func expirePendingRequest(requestID: String) {
        guard pendingRequestID == requestID else { return }
        clearPending()
        snapshot = nil
        availability = nil
        error = "The computer did not return a fresh status snapshot in time."
        isRefreshing = false
        state = .failed
        publish()
    }

    private func clearPending() {
        deadlineWorkItem?.cancel()
        deadlineWorkItem = nil
        pendingRequestID = nil
        pendingPairingID = nil
        pendingConnection = nil
        pendingDeadline = nil
        isRefreshing = false
    }

    private func showUnavailable(_ message: String) {
        guard pendingRequestID == nil else { return }
        availability = PeelClientMachineStatusPolicy.isSupportedPlatform
            ? message
            : Self.unsupportedPlatformMessage
        error = nil
        isRefreshing = false
        state = .unavailable
        publish()
    }

    private func publish() {
        viewModel = PeelMachineStatusViewModel(
            snapshot: snapshot,
            availability: availability,
            errorMessage: error,
            isRefreshing: isRefreshing)
    }
}

#endif
