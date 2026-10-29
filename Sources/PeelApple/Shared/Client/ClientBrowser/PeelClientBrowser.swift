import Foundation
import Combine
import Network
import ImageIO
import AVFoundation
import VideoToolbox


#if canImport(UIKit)
import UIKit
#endif

// MARK: - Temporary client streaming diagnostics
// Print-only instrumentation. Safe to remove after diagnosing motion latency/smearing.
enum PeelClientDiagnostics {
    static var enabled = true

    private static let summaryInterval: TimeInterval = 1.0
    private static let lock = NSLock()
    private static var receiveStatsByKey: [String: ReceiveStats] = [:]
    private static var videoStatsByKey: [String: VideoStats] = [:]
    private static var rendererStatsByKey: [String: RendererStats] = [:]
    private static var lastEventLogByKey: [String: TimeInterval] = [:]

    private struct ReceiveStats {
        var lastLogAt: TimeInterval
        var chunks: Int = 0
        var bytes: Int = 0
        var maxChunkBytes: Int = 0
        var lastMuxBufferBytes: Int = 0
        var lastBinaryBufferBytes: Int = 0

        init(now: TimeInterval) {
            self.lastLogAt = now
        }
    }

    private struct VideoStats {
        var lastLogAt: TimeInterval
        var frames: Int = 0
        var bytes: Int = 0
        var keyframes: Int = 0
        var maxPayloadBytes: Int = 0
        var lastBufferRemainingBytes: Int = 0

        init(now: TimeInterval) {
            self.lastLogAt = now
        }
    }

    private struct RendererStats {
        var lastLogAt: TimeInterval
        var framesSeen: Int = 0
        var bytes: Int = 0
        var keyframes: Int = 0
        var immediateEnqueues: Int = 0
        var pendingStores: Int = 0
        var pendingReplacements: Int = 0
        var pendingDrains: Int = 0
        var maxPayloadBytes: Int = 0
        var maxMainHopMs: Double = 0
        var lastReady: Bool = false
        var lastLayerStatus: String = "unknown"

        init(now: TimeInterval) {
            self.lastLogAt = now
        }
    }

    private static func currentTime() -> TimeInterval {
        Date().timeIntervalSinceReferenceDate
    }

    private static func prefix() -> String {
        "PeelClientDiag \(String(format: "%.3f", Date().timeIntervalSince1970))"
    }

    private static func key(ownerName: String, suffix: String) -> String {
        "\(ownerName)|\(suffix)"
    }

    private static func bytesText(_ bytes: Int) -> String {
        if bytes >= 1024 * 1024 {
            return "\(String(format: "%.2f", Double(bytes) / 1_048_576.0))MB"
        }
        if bytes >= 1024 {
            return "\(String(format: "%.1f", Double(bytes) / 1024.0))KB"
        }
        return "\(bytes)B"
    }

    private static func mbpsText(bytes: Int, seconds: TimeInterval) -> String {
        String(format: "%.2f", (Double(bytes) * 8.0) / max(seconds, 0.001) / 1_000_000.0)
    }

    static func logEvent(_ message: String) {
        guard enabled else { return }
        print("\(prefix()) \(message)")
    }

    static func logRateLimitedEvent(key eventKey: String, interval: TimeInterval = 1.0, message: String) {
        guard enabled else { return }

        let now = currentTime()
        var shouldPrint = false

        lock.lock()
        let last = lastEventLogByKey[eventKey] ?? 0
        if now - last >= interval {
            lastEventLogByKey[eventKey] = now
            shouldPrint = true
        }
        lock.unlock()

        guard shouldPrint else { return }
        print("\(prefix()) \(message)")
    }

    static func logStreamEvent(ownerName: String, windowId: UInt32? = nil, message: String) {
        guard enabled else { return }

        if let windowId {
            print("\(prefix()) [stream \(ownerName)] window=\(windowId) \(message)")
        } else {
            print("\(prefix()) [stream \(ownerName)] \(message)")
        }
    }

    static func logReceiveChunk(
        ownerName: String,
        byteCount: Int,
        muxBufferBytes: Int,
        binaryBufferBytes: Int
    ) {
        guard enabled else { return }

        let now = currentTime()
        let statKey = key(ownerName: ownerName, suffix: "receive")
        var message: String?

        lock.lock()
        var stats = receiveStatsByKey[statKey] ?? ReceiveStats(now: now)
        stats.chunks += 1
        stats.bytes += byteCount
        stats.maxChunkBytes = max(stats.maxChunkBytes, byteCount)
        stats.lastMuxBufferBytes = muxBufferBytes
        stats.lastBinaryBufferBytes = binaryBufferBytes

        let seconds = now - stats.lastLogAt
        if seconds >= summaryInterval {
            let chunksPerSecond = Double(stats.chunks) / max(seconds, 0.001)
            let averageChunkBytes = stats.bytes / max(stats.chunks, 1)
            message = "\(prefix()) [receive \(ownerName)] chunksPerSec=\(String(format: "%.1f", chunksPerSecond)) mbps=\(mbpsText(bytes: stats.bytes, seconds: seconds)) avgChunk=\(bytesText(averageChunkBytes)) maxChunk=\(bytesText(stats.maxChunkBytes)) muxBuffer=\(bytesText(stats.lastMuxBufferBytes)) binaryBuffer=\(bytesText(stats.lastBinaryBufferBytes))"
            stats = ReceiveStats(now: now)
        }

        receiveStatsByKey[statKey] = stats
        lock.unlock()

        if let message {
            print(message)
        }
    }

    static func logParserWait(
        ownerName: String,
        parser: String,
        reason: String,
        bufferBytes: Int,
        neededBytes: Int? = nil
    ) {
        guard enabled else { return }

        let waitKey = key(ownerName: ownerName, suffix: "parserWait|\(parser)|\(reason)")
        let neededText = neededBytes.map { " needed=\(bytesText($0))" } ?? ""
        logRateLimitedEvent(
            key: waitKey,
            interval: 1.0,
            message: "[parser \(ownerName)] \(parser) wait reason=\(reason) buffer=\(bytesText(bufferBytes))\(neededText)"
        )
    }

    static func logParserEvent(
        ownerName: String,
        reason: String,
        bufferBytes: Int,
        detail: String = ""
    ) {
        guard enabled else { return }

        let eventKey = key(ownerName: ownerName, suffix: "parserEvent|\(reason)")
        let detailText = detail.isEmpty ? "" : " \(detail)"
        logRateLimitedEvent(
            key: eventKey,
            interval: 1.0,
            message: "[parser \(ownerName)] \(reason) buffer=\(bytesText(bufferBytes))\(detailText)"
        )
    }

    static func logVideoConfig(
        ownerName: String,
        windowId: UInt32,
        width: Int,
        height: Int,
        timescale: Int,
        nalUnitHeaderLength: Int,
        spsBytes: Int,
        ppsBytes: Int,
        codec: String
    ) {
        guard enabled else { return }

        print("\(prefix()) [videoConfig \(ownerName)] window=\(windowId) codec=\(codec) size=\(width)x\(height) timescale=\(timescale) nalLen=\(nalUnitHeaderLength) sps=\(bytesText(spsBytes)) pps=\(bytesText(ppsBytes))")
    }

    static func logVideoFrame(
        ownerName: String,
        stage: String,
        windowId: UInt32,
        payloadByteCount: Int,
        isKeyframe: Bool,
        bufferRemainingBytes: Int
    ) {
        guard enabled else { return }

        let now = currentTime()
        let statKey = key(ownerName: ownerName, suffix: "video|\(stage)|\(windowId)")
        var message: String?

        lock.lock()
        var stats = videoStatsByKey[statKey] ?? VideoStats(now: now)
        stats.frames += 1
        stats.bytes += payloadByteCount
        if isKeyframe {
            stats.keyframes += 1
        }
        stats.maxPayloadBytes = max(stats.maxPayloadBytes, payloadByteCount)
        stats.lastBufferRemainingBytes = bufferRemainingBytes

        let seconds = now - stats.lastLogAt
        if seconds >= summaryInterval {
            let fps = Double(stats.frames) / max(seconds, 0.001)
            let avgPayloadBytes = stats.bytes / max(stats.frames, 1)
            message = "\(prefix()) [video \(stage) \(ownerName)] window=\(windowId) fps=\(String(format: "%.1f", fps)) mbps=\(mbpsText(bytes: stats.bytes, seconds: seconds)) avgFrame=\(bytesText(avgPayloadBytes)) maxFrame=\(bytesText(stats.maxPayloadBytes)) keyframes=\(stats.keyframes) bufferRemaining=\(bytesText(stats.lastBufferRemainingBytes))"
            stats = VideoStats(now: now)
        }

        videoStatsByKey[statKey] = stats
        lock.unlock()

        if let message {
            print(message)
        }
    }

    static func logVideoDrop(
        ownerName: String,
        windowId: UInt32,
        reason: String,
        payloadByteCount: Int? = nil
    ) {
        guard enabled else { return }

        let dropKey = key(ownerName: ownerName, suffix: "videoDrop|\(windowId)|\(reason)")
        let payloadText = payloadByteCount.map { " payload=\(bytesText($0))" } ?? ""
        logRateLimitedEvent(
            key: dropKey,
            interval: 1.0,
            message: "[video drop \(ownerName)] window=\(windowId) reason=\(reason)\(payloadText)"
        )
    }

    static func logRendererFrame(
        label: String,
        windowId: UInt32?,
        action: String,
        frameIndex: Int64,
        payloadByteCount: Int,
        isKeyframe: Bool,
        mainHopMs: Double?,
        displayReady: Bool,
        layerStatus: String
    ) {
        guard enabled else { return }

        let now = currentTime()
        let windowText = windowId.map { String($0) } ?? "unknown"
        let statKey = key(ownerName: label, suffix: "renderer|\(windowText)")
        var message: String?

        lock.lock()
        var stats = rendererStatsByKey[statKey] ?? RendererStats(now: now)
        stats.framesSeen += 1
        stats.bytes += payloadByteCount
        if isKeyframe {
            stats.keyframes += 1
        }
        switch action {
        case "immediate":
            stats.immediateEnqueues += 1
        case "pendingStore":
            stats.pendingStores += 1
        case "pendingReplace":
            stats.pendingReplacements += 1
        case "pendingDrain":
            stats.pendingDrains += 1
        default:
            break
        }
        stats.maxPayloadBytes = max(stats.maxPayloadBytes, payloadByteCount)
        if let mainHopMs {
            stats.maxMainHopMs = max(stats.maxMainHopMs, mainHopMs)
        }
        stats.lastReady = displayReady
        stats.lastLayerStatus = layerStatus

        let seconds = now - stats.lastLogAt
        if seconds >= summaryInterval {
            let fps = Double(stats.framesSeen) / max(seconds, 0.001)
            message = "\(prefix()) [renderer \(label)] window=\(windowText) inputFPS=\(String(format: "%.1f", fps)) mbps=\(mbpsText(bytes: stats.bytes, seconds: seconds)) immediate=\(stats.immediateEnqueues) pendingStore=\(stats.pendingStores) pendingReplace=\(stats.pendingReplacements) pendingDrain=\(stats.pendingDrains) keyframes=\(stats.keyframes) maxFrame=\(bytesText(stats.maxPayloadBytes)) maxMainHopMs=\(String(format: "%.1f", stats.maxMainHopMs)) ready=\(stats.lastReady) status=\(stats.lastLayerStatus) lastFrameIndex=\(frameIndex)"
            stats = RendererStats(now: now)
        }

        rendererStatsByKey[statKey] = stats
        lock.unlock()

        if let message {
            print(message)
        }
    }

    static func logRendererEvent(
        label: String,
        windowId: UInt32?,
        reason: String,
        frameIndex: Int64? = nil,
        payloadByteCount: Int? = nil,
        status: String? = nil,
        interval: TimeInterval = 1.0
    ) {
        guard enabled else { return }

        let windowText = windowId.map { String($0) } ?? "unknown"
        let eventKey = key(ownerName: label, suffix: "rendererEvent|\(windowText)|\(reason)")
        let frameText = frameIndex.map { " frame=\($0)" } ?? ""
        let payloadText = payloadByteCount.map { " payload=\(bytesText($0))" } ?? ""
        let statusText = status.map { " status=\($0)" } ?? ""
        logRateLimitedEvent(
            key: eventKey,
            interval: interval,
            message: "[renderer \(label)] window=\(windowText) reason=\(reason)\(frameText)\(payloadText)\(statusText)"
        )
    }
}

// Wraps a discovered Mac host
struct PeelHostInfo: Identifiable, Equatable {
    var id: PeelHostKey { hostKey }
    let name: String
    let service: NetService
    var hostId: String?
    let directPairingID: String?
    let directEndpoint: PeelDirectEndpoint?

    var isDirectEndpoint: Bool {
        directPairingID != nil && directEndpoint != nil
    }

    init(
        name: String,
        service: NetService,
        hostId: String? = nil,
        directPairingID: String? = nil,
        directEndpoint: PeelDirectEndpoint? = nil
    ) {
        self.name = name
        self.service = service
        self.hostId = hostId
        self.directPairingID = directPairingID
        self.directEndpoint = directEndpoint
    }

    var stableIdentityKey: String {
        if let directPairingID, !directPairingID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A direct descriptor is keyed by the explicit pairing identity,
            // never by a user-entered hostname or display name.
            return "pairingID:\(directPairingID)"
        }

        if let hostId, !hostId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "hostId:\(hostId)"
        }

        let serviceName = service.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !serviceName.isEmpty {
            return "service:\(serviceName)"
        }

        let hostName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hostName.isEmpty {
            return "name:\(hostName)"
        }

        return "unknown"
    }

    var appearanceSearchText: String {
        [name, service.name, hostId ?? ""]
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}


struct PeelSavedPairedMac: Identifiable, Equatable {
    let id: String
    let displayName: String
    let serviceName: String?
    let stableHostId: String?
}

enum PeelSharedCursorMode: Equatable {
    case hover
    case click
    case drag
    case rightClick
}

enum PeelRuntimeCapability {
    static let hostRenderedCursor = "host-rendered-cursor"
}


struct PeelSharedCursorState: Equatable {
    var windowId: UInt32
    var norm: CGPoint
    var mode: PeelSharedCursorMode
    var isVisible: Bool
}

enum HostAppListMode: String, CaseIterable, Codable {
    case combined
    case separated
}

final class PeelClientBrowser: NSObject, ObservableObject {
    @Published var status: String = "Searching for hosts…"
    @Published var pairingStatus: String? = nil
    @Published var hosts: [PeelHostInfo] = []
    @Published var windows: [PeelWindow] = []
    @Published var activeWindowId: UInt32? = nil
    @Published private(set) var sharedCursor: PeelSharedCursorState? = nil
    var lastFrameAt: [UInt32: Date] = [:]
    @Published var isConnectBusy: Bool = false   // true while connecting/reconnecting
    @Published var isClientVisible: Bool = true  // unlocked/foreground
    
    @Published var pairingStateVersion: Int = 0

    @Published var sessionsByHostKey: [PeelHostKey: PeelHostSession] = [:]
    /// Informational status only. Paid Host actions require the Host's own lease.
    @Published var proMacVerificationByHostKey: [PeelHostKey: PeelProMacVerificationStatus] = [:]
    var proEvidenceClients: [PeelHostKey: PeelProEvidenceClient] = [:]
    @Published var selectedHostKey: PeelHostKey? = nil
    @Published var appListMode: HostAppListMode = .combined
    @Published var directEndpointStore = PeelDirectEndpointStore()
    let iCloudPairingClient = PeelICloudPairingClient()

    /// Process-wide wake-up signal for the iPad scene router. Requests remain
    /// owned by their source sessions; this only publishes that routing state
    /// changed when the main launcher scene may no longer exist.
    @Published private(set) var agentPresentationRoutingVersion: UInt64 = 0

    private var sessionCancellables: [PeelHostKey: AnyCancellable] = [:]
    private var aiAccessCancellable: AnyCancellable?
    private var proEvidenceCancellable: AnyCancellable?

    func publishAgentPresentationRoutingChange() {
        if Thread.isMainThread {
            agentPresentationRoutingVersion &+= 1
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.agentPresentationRoutingVersion &+= 1
            }
        }
    }
    
    func markPairingStateChanged() {
        DispatchQueue.main.async {
            self.pairingStateVersion &+= 1
        }
    }
    
    @Published var pairingHostName: String? = nil
    // Tune this. 1–2s is usually enough to mean “not receiving frames”
    let offlineThreshold: TimeInterval = 2.0
    // "No signal" should mean the connection is actually down, or a window has been stale for a *while*.
    // Inactive windows are intentionally low-FPS (or can be temporarily backpressured), so they get a larger threshold.
    let offlineThresholdActive: TimeInterval = 2.0
    let offlineThresholdInactive: TimeInterval = 12.0

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
    
    var pullStreamTimers: [UUID: Timer] = [:]
    
    /// Latest snapshot bytes for each windowId (PNG/JPEG).
    @Published var snapshots: [UInt32: Data] = [:]

#if canImport(UIKit)
    /// Decoded app icons received from the Mac host, keyed by the base64 payload.
    var appIconImageCache: [String: UIImage] = [:]
#endif
    
    // MARK: - Decoded frame cache (avoid UIImage(data:) in SwiftUI body)
    /// Latest decoded frame for each windowId. The UI should render from this to avoid decoding JPEG on the main thread.
    @Published var snapshotCGImages: [UInt32: CGImage] = [:]
    @Published var videoRendererWindowIds: Set<UInt32> = []
    @Published var videoContentSizeByWindow: [UInt32: CGSize] = [:]
    @Published var videoReadyWindowIds: Set<UInt32> = []
    
    var videoRenderers: [UInt32: CompressedVideoRenderer] = [:]
#if os(visionOS)
    var spatialVideoRenderers: [UInt32: SpatialCompressedVideoRenderer] = [:]

    /// WindowIds currently being rendered by immersive/spatial UI.
    /// Normal peeled windows should not feed this path, otherwise visionOS decodes the same stream twice.
    var activeSpatialWindowIds: Set<UInt32> = []
#endif
    
    let jpegDecodeQueue = DispatchQueue(label: "peel.client.jpegDecode", qos: .userInitiated)
    var snapshotGenCounter: UInt64 = 0
    var latestSnapshotGenByWindow: [UInt32: UInt64] = [:]
    
    /// Tracks whether a snapshot request is already in-flight for a given window.
    var inFlight: Set<UInt32> = []
    /// Global backpressure: max snapshot requests allowed in-flight at once (across all windows).
    var globalSnapshotsInFlight: Int = 0
    let maxGlobalSnapshotsInFlight: Int = 2
    
    /// Optional timers for per-window pull-loop streaming.
    // Use DispatchSourceTimer so it keeps firing even when the main run loop is busy.
    var snapshotTimers: [UInt32: DispatchSourceTimer] = [:]
    /// WindowIds that currently have an on-screen PeeledWindowView and therefore should be pulling frames.
    /// This survives disconnects so we can automatically resume after reconnect.
    var desiredPullWindowIds: Set<UInt32> = []
    /// Exact window identities paired with desired ids so a reconnect cannot
    /// silently retarget a restored stream when a host reuses an id.
    var desiredPullWindowIdentityByWindow: [UInt32: PeelWindow] = [:]

    /// WindowIds we have already sent a startStream request for on the current connection.
    /// This prevents SwiftUI re-appears/window-list refreshes from spamming startStream.
    var startedStreamWindowIds: Set<UInt32> = []
    
    // MARK: - Client-side popup handoff (v1)
    
    /// Last authoritative window list we saw from the host.
    var lastWindowListById: [UInt32: PeelWindow] = [:]
    
    /// The most recent peeled window the user actively interacted with.
    var lastUserInteractionWindowId: UInt32? = nil
    var lastUserInteractionAt: Date = .distantPast
    
    /// Source windowId -> newly detected popup window to auto-open.
    var pendingAutoPopupBySource: [UInt32: PeelWindow] = [:]
    
    /// Child popup windowId -> parent/source windowId to return to when the popup disappears.
    var autoPopupParentByChild: [UInt32: UInt32] = [:]
    
    /// Per-source cooldown so we do not thrash.
    var lastAutoPopupAtBySource: [UInt32: Date] = [:]
    
    let autoPopupInteractionWindow: TimeInterval = 2.0
    let autoPopupCooldown: TimeInterval = 1.0
    
    /// One-shot host-command auto-open handoff (for launcher/finder windows).
    var pendingHostCommandAutoOpenWindow: PeelWindow? = nil
    var pendingLauncherCommandIssuedAt: Date? = nil
    var pendingLauncherExistingFinderWindowIds: Set<UInt32> = []
    let launcherCommandAutoOpenTimeout: TimeInterval = 3.0
    
    let minAutoPopupWidth: Int = 140
    let minAutoPopupHeight: Int = 80
    let maxAutoPopupAreaRatio: Double = 0.97
    let maxAutoPopupDimensionRatio: Double = 1.08
    
    let browser = NetServiceBrowser()
    var serviceToHost: [NetService: PeelHostInfo] = [:]
    var connection: NWConnection?
    /// Buffer for NDJSON (newline-delimited) messages from the host.
    var receiveBuffer = Data()
    // Binary frame assembler for high-performance streaming
    var binaryBuffer = Data()
    var expectedBinaryLength: Int? = nil
    
    let activeFPS: Double = 30.0
    let inactiveFPS: Double = 1.0
    
    // MARK: - Reconnect state
    var lastConnectedHost: PeelHostInfo?
    var reconnectAttempt: Int = 0
    var reconnectWorkItem: DispatchWorkItem?
    let maxReconnectAttempts: Int = 8
    var lastConnectedHostName: String?
    var pendingConnectIsAutoReconnect: Bool = false
    
    var resolveTimeoutWorkItem: DispatchWorkItem?
    let resolveTimeoutSeconds: TimeInterval = 6.0
    var waitingTimeoutWorkItem: DispatchWorkItem?
    let waitingTimeoutSeconds: TimeInterval = 4.0
    var isInWaitingState: Bool = false
    
    @Published var lastInputRejection: InputRejectedMessage?
    @Published var showInputRejectionBanner: Bool = false
    @Published var inputRejectionByWindowId: [UInt32: InputRejectedMessage] = [:]
    
    var isMouseDownLocally = false
    var mouseDownWindowId: UInt32? = nil
    var mouseDownButton: String = "left"
    var lastNX: Double = 0.5
    var lastNY: Double = 0.5

    // Trackpad / pointer hover can fire very frequently. Keep mouseMove smooth
    // without flooding the Mac host with identical high-rate packets.
    var lastMouseMoveSentAtByWindow: [UInt32: Date] = [:]
    var lastMouseMoveNormByWindow: [UInt32: CGPoint] = [:]
    let mouseMoveMinInterval: TimeInterval = 1.0 / 90.0
    let mouseMoveMinNormalizedDistance: CGFloat = 0.0015
    
    @Published var isConnectionReady: Bool = false
    
    /// If a window-list request happens before we become ready, we defer it and run it on `.ready`.
    var pendingWindowListRequest: Bool = false
    
    /// If the user taps Connect before the NetService has finished resolving,
    /// we stash the target here and auto-connect as soon as `netServiceDidResolveAddress` fires.
    var pendingConnectHost: PeelHostInfo? = nil
    
    var windowListRefreshTimer: DispatchSourceTimer? = nil
    let windowListRefreshInterval: TimeInterval = 2.0
    
    var lifecycleObservers: [Any] = []
    var pingTimer: DispatchSourceTimer?
    let streamDiagnosticReporter = PeelClientStreamDiagnosticsReporter()
    
    var muxBuffer = Data()
    var lastAnyDataAt: Date = .distantPast
    var lastWindowListAt: Date = .distantPast
    let useMuxParser = false
    
    var inFlightSince: [UInt32: Date] = [:]
    let inFlightTimeout: TimeInterval = 1.5
    
    var streamWatchdog: Timer?
    let stallTimeout: TimeInterval = 6.0
    var isStreamWatchdogRunning = false
    var didHandleDisconnectForCurrentConnection = false
    var streamRepairInProgressWindowIds: Set<UInt32> = []
    
    var hasFreshWindowListForCurrentConnection = false
    
    var delayedConnectWorkItem: DispatchWorkItem?
    var nextAllowedConnectAt: Date = .distantPast
    let postDisconnectConnectCooldown: TimeInterval = 0.8
    let postPairConnectCooldown: TimeInterval = 1.1
    
    /// When the client last sent startStream for each window.

    var streamStartAttemptAtByWindow: [UInt32: Date] = [:]

    /// Last automatic repair time, used to avoid repair loops.

    var streamLastRepairAtByWindow: [UInt32: Date] = [:]

    /// Consecutive repairs for a window before escalating to socket reconnect.

    var streamRepairAttemptByWindow: [UInt32: Int] = [:]

    /// Last videoConfig receipt. This is NOT a displayed frame.

    var videoConfigReceivedAtByWindow: [UInt32: Date] = [:]

    /// Latest video config packet per window. Used to lazily configure spatial renderers only
    /// when an immersive/spatial view actually asks for one.
    var latestVideoConfigByWindow: [UInt32: VideoConfigPacket] = [:]

    /// A stream should produce its first real videoFrame quickly after startStream.

    let streamFirstFrameTimeout: TimeInterval = 2.5

    /// Prevents stop/start spam if the host is still tearing down capture.

    let streamRepairCooldown: TimeInterval = 1.25

    /// After this many failed local stream repairs, reconnect the socket.

    let maxStreamRepairsBeforeReconnect: Int = 3
    
    let pairingStore = PeelPairingStore(role: .client)
    
    var pskMismatchCount: [String: Int] = [:]
    var pskMismatchLastAt: [String: Date] = [:]
    let pskMismatchWindow: TimeInterval = 20
    let pskMismatchThreshold: Int = 3
    
    var pendingReconnectWhenVisible: Bool = false
    var pendingReconnectReason: String? = nil
    
    // Bonjour can occasionally hold stale NetService objects across host restarts
    // or app foreground/background transitions. These fields let us restart
    // browsing without spamming NetServiceBrowser or touching active streams.
    var discoveryRestartWorkItem: DispatchWorkItem?
    var lastDiscoveryRestartAt: Date = .distantPast
    let minDiscoveryRestartInterval: TimeInterval = 1.25
    
    var _pendingLauncherSuccessorWindow: PeelWindow?
    var _pendingLauncherTrackedFinderWindowId: UInt32?
    var _pendingLauncherSuccessorIssuedAt: Date?
    
    var lastClientActiveWindowRequestAtByWindow: [UInt32: Date] = [:]
    let clientActiveWindowRequestMinInterval: TimeInterval = 0.75
    
    static let clientDeviceIdDefaultsKey = "PeelClient.deviceId"
    lazy var clientDeviceId: String = {
        if let existing = UserDefaults.standard.string(forKey: Self.clientDeviceIdDefaultsKey),
           !existing.isEmpty { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: Self.clientDeviceIdDefaultsKey)
        return fresh
    }()
    
    var pendingPairHost: PeelHostInfo?
    var pendingPairPIN: String?
    var pairingResolveService: NetService?
    var pairingFreshResolveRetryUsed = false
    var pairingConnection: NWConnection?
    
    var pairingResolveTimeoutWorkItem: DispatchWorkItem?
    var pairingWaitingTimeoutWorkItem: DispatchWorkItem?
    var pairingResponseTimeoutWorkItem: DispatchWorkItem?
    
    let pairingResolveTimeoutSeconds: TimeInterval = 6.0
    let pairingWaitingTimeoutSeconds: TimeInterval = 4.0
    let pairingResponseTimeoutSeconds: TimeInterval = 5.0
    
    /// Name of the currently connected host (set when the NWConnection becomes `.ready`).
    /// This lets the UI show Connect vs Disconnect per host row.
    @Published var connectedHostName: String? = nil
    
    /// When true, we suppress auto-reconnect loops until the user explicitly connects again.
    /// (Example: user taps Disconnect.)
    var suppressAutoReconnect: Bool = false
    
    var activePairingID: String? = nil
    
    // Dedicated queues to keep streaming alive during heavy UI / gesture activity.
    let networkQueue = DispatchQueue(label: "peel.client.network", qos: .userInitiated)
    let pullTimerQueue = DispatchQueue(label: "peel.client.pullTimers", qos: .userInitiated)
    let stateQueue = DispatchQueue(label: "peel.client.state")

    // MARK: - Published media / focus state

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


    /// Minimal envelope for peeking at the "type" field.
    struct MessageEnvelope: Decodable {
        let type: String
    }
    
    func session(for host: PeelHostInfo) -> PeelHostSession {
        let key = host.hostKey

        if let existing = sessionsByHostKey[key] {
            existing.updateHost(host)
            return existing
        }

        if host.isDirectEndpoint {
            if let existing = sessionsByHostKey.values.first(where: { $0.directPairingID == host.directPairingID }) {
                existing.updateHost(host)
                return existing
            }

            let session = PeelHostSession(host: host, browser: self)
            sessionsByHostKey[key] = session
            bindSession(session)
            return session
        }

        // The Bonjour TXT hostId may appear after the first service object is discovered.
        // Do not create a second session for the same Mac just because the preferred key
        // upgraded from service-name identity to stable-hostId identity.
        if let hostId = host.hostId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hostId.isEmpty,
           let existing = sessionsByHostKey.values.first(where: { session in
               guard !session.isUsingDirectEndpoint else { return false }
               guard let sessionHostId = session.host.hostId?.trimmingCharacters(in: .whitespacesAndNewlines),
                     !sessionHostId.isEmpty else {
                   return false
               }
               return sessionHostId == hostId
           }) {
            existing.updateHost(host)
            return existing
        }

        if let existing = sessionsByHostKey.values.first(where: { session in
            guard !session.isUsingDirectEndpoint else { return false }
            return session.host.service.name == host.service.name || session.host.name == host.name
        }) {
            existing.updateHost(host)
            return existing
        }

        let session = PeelHostSession(host: host, browser: self)
        sessionsByHostKey[key] = session
        bindSession(session)
        return session
    }

    func session(for key: PeelHostKey) -> PeelHostSession? {
        sessionsByHostKey[key]
    }

    var selectedSession: PeelHostSession? {
        guard let selectedHostKey else { return nil }
        return sessionsByHostKey[selectedHostKey]
    }

    private func bindSession(_ session: PeelHostSession) {
        sessionCancellables[session.hostKey] = session.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    func removeSession(for key: PeelHostKey) {
        if let session = sessionsByHostKey[key] { resetProEvidence(for: session) }
        sessionsByHostKey[key]?.stopSystemAudio(reason: "Mac disconnected")
        sessionsByHostKey[key]?.closeAllVideoConnections(reason: "remove session")
        sessionsByHostKey[key] = nil
        sessionCancellables[key] = nil

        if selectedHostKey == key {
            selectedHostKey = sessionsByHostKey.keys.first
        }
    }

    override init() {
        super.init()
        browser.delegate = self
        aiAccessCancellable = NotificationCenter.default.publisher(for: PeelAIFeatureAccess.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshAgentPresentationCapabilities() }
        // PeelStore posts this on the main actor before awaiting finish/refresh.
        // No receipt, purchase ID or arbitrary error text enters the notification.
        proEvidenceCancellable = NotificationCenter.default.publisher(for: PeelStore.proEvidenceDidChangeNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.invalidateProEvidence()
                self.refreshAgentPresentationCapabilities()
            }

        loadDirectEndpointStore()
        iCloudPairingClient.attach(to: self)

        primeReconnectFromSavedPairingIfNeeded()

        // Empty domain lets Bonjour pick the default (local.)
        browser.searchForServices(ofType: "_peel._tcp.", inDomain: "")
        setupLifecycleObservers()
    }
}
