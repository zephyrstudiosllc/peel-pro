//
//  PeelHostSession.swift
//  Peel
//
//  Created by Zach on 6/15/26.
//


import Foundation
import Combine
import Network
import ImageIO
import AVFoundation
import VideoToolbox

#if canImport(UIKit)
import UIKit
#endif

struct PeelPendingAgentPresentationRequest {
    let message: PresentWindowMessage
    let sourceConnection: NWConnection

    var requestId: String {
        message.requestId
    }
}

final class PeelHostSession: ObservableObject, Identifiable {
    var id: PeelHostKey { hostKey }

    let hostKey: PeelHostKey
    weak var browser: PeelClientBrowser?

    @Published var host: PeelHostInfo
    @Published var status: String
    /// Metadata can survive a missing or inaccessible Keychain item. Keep the
    /// record intact and offer explicit pairing recovery after a failed read.
    @Published var requiresPairingRepair: Bool = false
    @Published var windows: [PeelWindow] = []
    @Published var activeWindowId: UInt32? = nil {
        didSet {
            if oldValue != activeWindowId { watchFocusProof.invalidate() }
        }
    }
    @Published var sharedCursor: PeelSharedCursorState? = nil
    @Published var isConnectBusy: Bool = false
    @Published var isConnectionReady: Bool = false {
        didSet {
            if !isConnectionReady { watchFocusProof.invalidate() }
            if oldValue && !isConnectionReady { advanceSourceMediaControlEpoch() }
        }
    }
    @Published var connectedHostName: String? = nil

#if os(iOS) || os(visionOS)
    @Published var systemAudioRequested = false
    @Published var systemAudioStatus = "Off"
    /// True only while computer audio PCM is actually being admitted to the
    /// playback graph; requested or connecting audio stays false.
    @Published var systemAudioPlaying = false
    lazy var audioController = PeelClientAudioController(session: self)

    /// One connection-bound Mac Status controller is owned by this session.
    /// Its weak session reference prevents a browser removal cycle.
    lazy var machineStatusController = PeelClientMachineStatusController(session: self)

    /// Source media keys and volume for this session's own stream windows.
    lazy var sourceMediaController = PeelSourceMediaController(session: self)

#if os(iOS) || os(visionOS)

    /// Client-generated identity for the current authenticated control socket.
    /// The notification wire carries only request and pairing IDs; this local
    /// UUID scopes admission and dedupe to one control session.
    var remoteNotificationSessionID = UUID()
    var remoteNotificationAdmissionPolicy = PeelRemoteNotificationAdmissionPolicy()
#endif
#endif

    func stopSystemAudio(reason: String) {
#if os(iOS) || os(visionOS)
        audioController.stop(reason: reason)
#endif
    }

    var connection: NWConnection? {
        didSet {
            if oldValue !== connection {
                watchFocusConnectionGeneration &+= 1
                watchFocusProof.invalidate()
                advanceSourceMediaControlEpoch()
            }
        }
    }

    /// Source media requests and replies are fenced to one control connection
    /// generation; a replaced, closed or not-ready connection advances it.
    private(set) var sourceMediaControlEpoch: UInt64 = 0

    private func advanceSourceMediaControlEpoch() {
        sourceMediaControlEpoch &+= 1
#if os(iOS) || os(visionOS)
        DispatchQueue.main.async { [weak self] in
            self?.sourceMediaController.controlConnectionDidChange()
        }
#endif
    }

#if os(iOS) || os(visionOS)
    /// An ended stream cancels its source media work before any reopen of the
    /// same window can be streamed, so nothing carries over to the new stream.
    private func sourceMediaStreamsDidEnd(_ windowIds: Set<UInt32>) {
        guard !windowIds.isEmpty else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { sourceMediaController.streamsDidEnd(windowIds) }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.sourceMediaController.streamsDidEnd(windowIds)
            }
        }
    }
#endif
    /// Watch grants require an acknowledgment for this request and control socket.
    /// The ordinary Host focus cache is never sufficient to grant Watch control.
    var watchFocusProof = PeelWatchFocusProof()
    var watchFocusConnectionGeneration: UInt64 = 0
#if os(iOS)
    private let watchRelayConsumerLock = NSLock()
    private var watchRelayConsumer: ((UInt32, UUID, CMSampleBuffer, Bool) -> Void)?
    func setWatchRelayConsumer(_ consumer: ((UInt32, UUID, CMSampleBuffer, Bool) -> Void)?) {
        watchRelayConsumerLock.lock()
        watchRelayConsumer = consumer
        watchRelayConsumerLock.unlock()
    }
    func deliverWatchRelaySample(windowID: UInt32, rendererID: UUID, sample: CMSampleBuffer, keyframe: Bool) {
        watchRelayConsumerLock.lock()
        let consumer = watchRelayConsumer
        watchRelayConsumerLock.unlock()
        consumer?(windowID, rendererID, sample, keyframe)
    }
#endif

    private let videoStateQueueKey = DispatchSpecificKey<Void>()
    let videoStateQueue: DispatchQueue

    var videoConnectionsByWindowId: [UInt32: NWConnection] = [:]
    var videoReceiveBuffersByWindowId: [UInt32: Data] = [:]
    var videoConnectInProgressWindowIds: Set<UInt32> = []

    func onVideoStateQueue(_ work: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: videoStateQueueKey) != nil {
            work()
        } else {
            videoStateQueue.async(execute: work)
        }
    }

    func assertVideoStateQueue() {
        assert(
            DispatchQueue.getSpecific(key: videoStateQueueKey) != nil,
            "video state accessed off videoStateQueue"
        )
    }

    var receiveBuffer = Data()
    var binaryBuffer = Data()
    var expectedBinaryLength: Int? = nil
    var muxBuffer = Data()
    let useMuxParser = false

    var lastAnyDataAt: Date = .distantPast
    var lastWindowListAt: Date = .distantPast

    var pendingWindowListRequest = false
    var pendingConnectHost: PeelHostInfo? = nil
    var pendingConnectIsAutoReconnect = false
    var isWaitingForResolve = false

    var resolveTimeoutWorkItem: DispatchWorkItem?
    let resolveTimeoutSeconds: TimeInterval = 6.0

    var waitingTimeoutWorkItem: DispatchWorkItem?
    let waitingTimeoutSeconds: TimeInterval = 4.0
    var isInWaitingState = false

    var windowListRefreshTimer: DispatchSourceTimer?
    let windowListRefreshInterval: TimeInterval = 2.0

    var pingTimer: DispatchSourceTimer?
    let streamDiagnosticReporter = PeelClientStreamDiagnosticsReporter()

    var lastConnectedHost: PeelHostInfo?
    var reconnectAttempt: Int = 0
    var reconnectWorkItem: DispatchWorkItem?
    let maxReconnectAttempts: Int = 8
    var lastConnectedHostName: String?
    var suppressAutoReconnect: Bool = false
    var pendingReconnectWhenVisible: Bool = false
    var pendingReconnectReason: String? = nil
    var didHandleDisconnectForCurrentConnection = false

    var delayedConnectWorkItem: DispatchWorkItem?
    var nextAllowedConnectAt: Date = .distantPast
    let postDisconnectConnectCooldown: TimeInterval = 0.8
    let postPairConnectCooldown: TimeInterval = 1.1

    @Published var snapshots: [UInt32: Data] = [:]

#if canImport(UIKit)
    var appIconImageCache: [String: UIImage] = [:]
#endif

    @Published var snapshotCGImages: [UInt32: CGImage] = [:]
    @Published var videoRendererWindowIds: Set<UInt32> = []
    @Published var videoContentSizeByWindow: [UInt32: CGSize] = [:]
    @Published var videoReadyWindowIds: Set<UInt32> = [] {
        didSet {
#if os(iOS) || os(visionOS)
            // A first received frame marks an active authenticated stream.
            // The audio controller decides whether default playback applies.
            if videoReadyWindowIds.count > oldValue.count {
                DispatchQueue.main.async { [weak self] in
                    self?.audioController.startDefaultPlaybackIfEligible()
                }
            }
            sourceMediaStreamsDidEnd(oldValue.subtracting(videoReadyWindowIds))
#endif
        }
    }

    var videoRenderers: [UInt32: CompressedVideoRenderer] = [:]

#if os(visionOS)
    var spatialVideoRenderers: [UInt32: SpatialCompressedVideoRenderer] = [:]
    var activeSpatialWindowIds: Set<UInt32> = []
#endif

    let jpegDecodeQueue: DispatchQueue
    let networkQueue: DispatchQueue
    let pullTimerQueue: DispatchQueue
    let stateQueue: DispatchQueue

    var snapshotGenCounter: UInt64 = 0
    var latestSnapshotGenByWindow: [UInt32: UInt64] = [:]

    var snapshotTimers: [UInt32: DispatchSourceTimer] = [:]
    var pullStreamTimers: [UUID: Timer] = [:]

    var inFlight: Set<UInt32> = []
    var globalSnapshotsInFlight: Int = 0
    let maxGlobalSnapshotsInFlight: Int = 2
    var inFlightSince: [UInt32: Date] = [:]
    let inFlightTimeout: TimeInterval = 1.5

    var desiredPullWindowIds: Set<UInt32> = [] {
        didSet {
#if os(iOS) || os(visionOS)
            // The last desired stream closed: end only automatic audio. The
            // controller rechecks emptiness when this queued call runs.
            if desiredPullWindowIds.isEmpty, !oldValue.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    self?.audioController.stopAutomaticPlaybackIfStreamsEnded()
                }
            }
            sourceMediaStreamsDidEnd(oldValue.subtracting(desiredPullWindowIds))
#endif
        }
    }
    var desiredPullWindowIdentityByWindow: [UInt32: PeelWindow] = [:]
    var startedStreamWindowIds: Set<UInt32> = []

    var streamWatchdog: Timer?
    let stallTimeout: TimeInterval = 6.0
    var isStreamWatchdogRunning = false
    var streamRepairInProgressWindowIds: Set<UInt32> = []

    var hasFreshWindowListForCurrentConnection = false

    var streamStartAttemptAtByWindow: [UInt32: Date] = [:]
    var streamLastRepairAtByWindow: [UInt32: Date] = [:]
    var streamRepairAttemptByWindow: [UInt32: Int] = [:]
    var videoConfigReceivedAtByWindow: [UInt32: Date] = [:]
    var latestVideoConfigByWindow: [UInt32: VideoConfigPacket] = [:]

    let streamFirstFrameTimeout: TimeInterval = 2.5
    let streamRepairCooldown: TimeInterval = 1.25
    let maxStreamRepairsBeforeReconnect: Int = 3

    var lastFrameAt: [UInt32: Date] = [:]

    var videoFrameCountByWindow: [UInt32: Int] = [:]
    var videoLastFrameByteCountByWindow: [UInt32: Int] = [:]
    var videoLastFrameWasKeyframeByWindow: [UInt32: Bool] = [:]
    var videoLastFrameReceivedAtByWindow: [UInt32: Date] = [:]

    @Published var windowGeometryById: [UInt32: WindowGeometryMessage] = [:]
    @Published var hostCapabilities: Set<String> = []
    var desiredPeeledWindowHostingModes: [UInt32: PeeledWindowHostingMode] = [:]
    var desiredClientWindowActivity: [UInt32: Bool] = [:]
    var desiredPeeledWindowHostingIdentityByWindow: [UInt32: PeelWindow] = [:]
    @Published var hostConfirmedActiveWindowId: UInt32? = nil
    @Published var lastWindowFocusState: WindowFocusStateMessage? = nil
    @Published var recentlyFocusedWindowIds: [UInt32] = []
    @Published var hostStreamDebugByWindow: [UInt32: HostStreamDebugMessage] = [:]

    @Published var lastInputRejection: InputRejectedMessage?
    @Published var showInputRejectionBanner: Bool = false
    @Published var inputRejectionByWindowId: [UInt32: InputRejectedMessage] = [:]

    var isMouseDownLocally = false
    var mouseDownWindowId: UInt32? = nil
    var mouseDownButton: String = "left"
    var lastNX: Double = 0.5
    var lastNY: Double = 0.5

    var lastMouseMoveSentAtByWindow: [UInt32: Date] = [:]
    var lastMouseMoveNormByWindow: [UInt32: CGPoint] = [:]
    let mouseMoveMinInterval: TimeInterval = 1.0 / 90.0
    let mouseMoveMinNormalizedDistance: CGFloat = 0.0015

    var activePairingID: String? = nil

    /// The saved address selected for this session, if any. It survives
    /// connection resets so automatic reconnects keep using the same route.
    var directEndpointRecord: PeelDirectEndpointRecord?

    /// Transport endpoint used by the current control connection. Keeping this
    /// beside the direct record lets an edited address force a later explicit
    /// connect to replace an otherwise-ready socket.
    var connectedTransportEndpoint: PeelSessionTransportEndpoint?

    // Popup / launcher handoff state should also be per-session.
    var lastWindowListById: [UInt32: PeelWindow] = [:]
    var lastUserInteractionWindowId: UInt32? = nil
    var lastUserInteractionAt: Date = .distantPast
    var pendingAutoPopupBySource: [UInt32: PeelWindow] = [:]
    var autoPopupParentByChild: [UInt32: UInt32] = [:]
    var lastAutoPopupAtBySource: [UInt32: Date] = [:]

    var pendingHostCommandAutoOpenWindow: PeelWindow? = nil
    var pendingLauncherCommandIssuedAt: Date? = nil
    var pendingLauncherExistingFinderWindowIds: Set<UInt32> = []

    /// Validated, one-shot requests from an opted-in agent presentation host.
    /// Each request retains its originating socket so scene routing and the result
    /// can never move to a replacement connection for the same host.
    @Published var pendingAgentPresentationRequests: [PeelPendingAgentPresentationRequest] = []
    var handledAgentPresentationRequestIDs: Set<String> = []
    var handledAgentPresentationRequestOrder: [String] = []
    let maxHandledAgentPresentationRequestIDs = 64

    /// Only the most recent pairing challenge is retained for this connection.
    /// The request UUID prevents duplicate proof sends without retaining an
    /// unbounded set across a long-lived connection.
    var lastHandledAgentPairingChallengeRequestID: String?
    var lastHandledManualAgentControlChallengeRequestID: String?

    var _pendingLauncherSuccessorWindow: PeelWindow?
    var _pendingLauncherTrackedFinderWindowId: UInt32?
    var _pendingLauncherSuccessorIssuedAt: Date?

    var lastClientActiveWindowRequestAtByWindow: [UInt32: Date] = [:]
    let clientActiveWindowRequestMinInterval: TimeInterval = 0.75

    let activeFPS: Double = 30.0
    let inactiveFPS: Double = 1.0

    let offlineThreshold: TimeInterval = 2.0
    let offlineThresholdActive: TimeInterval = 2.0
    let offlineThresholdInactive: TimeInterval = 12.0

    let autoPopupInteractionWindow: TimeInterval = 2.0
    let autoPopupCooldown: TimeInterval = 1.0
    let launcherCommandAutoOpenTimeout: TimeInterval = 3.0

    let minAutoPopupWidth: Int = 140
    let minAutoPopupHeight: Int = 80
    let maxAutoPopupAreaRatio: Double = 0.97
    let maxAutoPopupDimensionRatio: Double = 1.08

    var isClientVisible: Bool {
        browser?.isClientVisible ?? true
    }

    init(host: PeelHostInfo, browser: PeelClientBrowser) {
        self.host = host
        self.hostKey = host.hostKey
        self.browser = browser
        self.status = "Disconnected"

        let queueSuffix = host.hostKey.rawValue
            .replacingOccurrences(of: ":", with: ".")
            .replacingOccurrences(of: "/", with: ".")

        self.networkQueue = DispatchQueue(label: "peel.client.session.\(queueSuffix).network", qos: .userInitiated)
        self.pullTimerQueue = DispatchQueue(label: "peel.client.session.\(queueSuffix).pullTimers", qos: .userInitiated)
        self.stateQueue = DispatchQueue(label: "peel.client.session.\(queueSuffix).state")
        self.videoStateQueue = DispatchQueue(label: "peel.client.session.\(queueSuffix).videoState", qos: .userInitiated)
        self.jpegDecodeQueue = DispatchQueue(label: "peel.client.session.\(queueSuffix).jpegDecode", qos: .userInitiated)

        self.videoStateQueue.setSpecific(key: videoStateQueueKey, value: ())
    }


    func showSharedCursor(
        for windowId: UInt32,
        norm: CGPoint,
        mode: PeelSharedCursorMode = .hover
    ) {
        let clamped = CGPoint(
            x: min(max(norm.x, 0), 1),
            y: min(max(norm.y, 0), 1)
        )

        DispatchQueue.main.async {
            self.sharedCursor = PeelSharedCursorState(
                windowId: windowId,
                norm: clamped,
                mode: mode,
                isVisible: true
            )
        }
    }

    func hideSharedCursor(for windowId: UInt32? = nil) {
        DispatchQueue.main.async {
            guard var cursor = self.sharedCursor else { return }

            if let windowId, cursor.windowId != windowId {
                return
            }

            cursor.isVisible = false
            self.sharedCursor = cursor
        }
    }

    func currentSharedCursorNorm(for windowId: UInt32, fallback: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> CGPoint {
        guard let sharedCursor,
              sharedCursor.windowId == windowId,
              sharedCursor.isVisible else {
            return fallback
        }

        return sharedCursor.norm
    }

    var hostRendersCursor: Bool {
        hostCapabilities.contains(PeelRuntimeCapability.hostRenderedCursor)
    }

    func hostStreamDebugText(for windowId: UInt32) -> String? {
        guard let msg = hostStreamDebugByWindow[windowId] else { return nil }

        if let detail = msg.detail, !detail.isEmpty {
            return "\(msg.stage): \(detail)"
        }

        return msg.stage
    }

    func reconcileRecentFocusOrder(with visibleWindows: [PeelWindow]) {
        let visibleWindowIds = Set(visibleWindows.map(\.windowId))

        recentlyFocusedWindowIds.removeAll { windowId in
            !visibleWindowIds.contains(windowId)
        }

        for window in visibleWindows {
            if !recentlyFocusedWindowIds.contains(window.windowId) {
                recentlyFocusedWindowIds.append(window.windowId)
            }
        }
    }

    func recordFocusedWindowId(_ windowId: UInt32) {
        recentlyFocusedWindowIds.removeAll { $0 == windowId }
        recentlyFocusedWindowIds.insert(windowId, at: 0)
    }

    func updateHost(_ host: PeelHostInfo) {
        // A saved-address session owns its transport target. Bonjour refreshes
        // must not replace that target with a stale service hostname or port.
        if isUsingDirectEndpoint && !host.isDirectEndpoint {
            return
        }
        self.host = host
    }

    func sendHardwareKey(
        _ key: Int,
        characters: String?,
        modifiers charactersIgnoringModifiers: String?,
        commands: [KeyboardCommand]
    ) {
        let hasShortcutModifier = commands.contains(.command) ||
            commands.contains(.control) ||
            commands.contains(.option)

        if hasShortcutModifier {
            sendKeyboardHardwareKey(
                keyCode: key,
                characters: characters,
                charactersIgnoringModifiers: charactersIgnoringModifiers,
                modifiers: commands
            )
            return
        }

        if let characters, !characters.isEmpty {
            sendKeyboardText(characters)
            return
        }

        switch key {
        case 40, 88, 36:
            sendKeyboardCommand(.enter)
        case 43, 48:
            sendKeyboardCommand(.tab)
        case 42, 51:
            sendKeyboardCommand(.backspace)
        case 76, 117:
            sendKeyboardCommand(.forwardDelete)
        case 41, 53:
            sendKeyboardCommand(.escape)
        case 80, 123:
            sendKeyboardCommand(.leftArrow)
        case 79, 124:
            sendKeyboardCommand(.rightArrow)
        case 82, 126:
            sendKeyboardCommand(.upArrow)
        case 81, 125:
            sendKeyboardCommand(.downArrow)
        default:
            if !commands.isEmpty {
                sendKeyboardHardwareKey(
                    keyCode: key,
                    characters: characters,
                    charactersIgnoringModifiers: charactersIgnoringModifiers,
                    modifiers: commands
                )
            }
        }
    }
}

/// Tracks only a fresh Watch grant request; ordinary client focus remains separate.
/// The session owns connection generations and invalidates this proof on resets.
struct PeelWatchFocusProof {
    private struct Request {
        let id: String
        let windowID: UInt32
        let connectionGeneration: UInt64
        let deadline: TimeInterval
        var confirmed = false
    }
    private var request: Request?

    mutating func begin(
        requestID: String, windowID: UInt32, connectionGeneration: UInt64,
        now: TimeInterval, timeout: TimeInterval = 2
    ) {
        invalidate()
        guard PeelFocusRequestID.isValid(requestID), now.isFinite,
              timeout.isFinite, timeout > 0, (now + timeout).isFinite else { return }
        request = Request(id: requestID, windowID: windowID,
                          connectionGeneration: connectionGeneration, deadline: now + timeout)
    }

    mutating func receive(
        requestID: String?, requestedWindowID: UInt32?, activeWindowID: UInt32?,
        didActivate: Bool, connectionGeneration: UInt64, now: TimeInterval
    ) {
        guard let current = request,
              current.connectionGeneration == connectionGeneration else { return }
        guard now.isFinite else { invalidate(); return }
        if !current.confirmed, now >= current.deadline {
            invalidate()
            return
        }
        // Legacy, unsolicited, replaced and earlier same-window replies cannot grant.
        guard requestID == current.id else { return }
        guard requestedWindowID == current.windowID,
              activeWindowID == current.windowID, didActivate else {
            invalidate()
            return
        }
        request?.confirmed = true
    }

    func isConfirmed(requestID: String, windowID: UInt32, connectionGeneration: UInt64) -> Bool {
        guard let request else { return false }
        return request.confirmed && request.id == requestID &&
            request.windowID == windowID && request.connectionGeneration == connectionGeneration
    }

    mutating func cancel(requestID: String) {
        if request?.id == requestID { invalidate() }
    }

    mutating func invalidate() { request = nil }
}
