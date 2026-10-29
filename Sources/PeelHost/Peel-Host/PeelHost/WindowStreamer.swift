//
//  CaptureMode.swift
//  Peel-Host
//
//  Created by Zach on 4/14/26.
//


import Foundation
import AppKit
import UniformTypeIdentifiers
import Accelerate
import ImageIO
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import VideoToolbox

enum PeelStreamingSettings {
    // Every visible desktop/window participates in one shared budget. An unset
    // preference uses Balanced (up to 8.3 MP shared, 60 Mbps, 60 fps target).
    // An explicit Responsive or Full Quality selection is always retained.
    static let desktopProfileKey = "peel.streaming.desktopProfile"
    enum DesktopProfile: String, CaseIterable, Identifiable {
        case responsive, balanced, fullQuality
        var id: String { rawValue }
        var title: String {
            switch self {
            case .responsive: return "Responsive"
            case .balanced: return "Balanced"
            case .fullQuality: return "Full Quality"
            }
        }
        var bitRate: Int {
            switch self {
            case .responsive: return 30_000_000
            case .balanced: return 60_000_000
            case .fullQuality: return 120_000_000
            }
        }
        var megapixels: Double {
            switch self {
            case .responsive: return 4.0
            case .balanced: return 8.3
            case .fullQuality: return 12.0
            }
        }
        var detail: String {
            switch self {
            case .responsive: return "Lower bandwidth and resolution for busy Wi-Fi. Keeps 60 fps as the target."
            case .balanced: return "Up to a full 4K desktop, with a smaller bandwidth budget. Targets 60 fps."
            case .fullQuality: return "The highest shared resolution and bandwidth budget for sharp text on a fast local connection. Targets 60 fps."
            }
        }
    }
    static let defaultDesktopProfile: DesktopProfile = .balanced
    static var desktopProfile: DesktopProfile {
        DesktopProfile(rawValue: UserDefaults.standard.string(forKey: desktopProfileKey) ?? "") ?? defaultDesktopProfile
    }
    static var totalBitrateBudget: Int { desktopProfile.bitRate }
    static var totalMegapixelsPerFrameBudget: Double { desktopProfile.megapixels }
    static let preferredFPS = 60
    static let minimumStreamBitrate = 750_000

    // Source-preparation experiment only. Release ignores the launch argument.
    static var nativeExperimentEnabled: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--peel-native-stream-experiment")
#else
        false
#endif
    }
    static let nativeExperimentFramePixels = 5120 * 2880
    static let nativeExperimentMaximumDimension = 5120
    static let nativeExperimentSeconds: Double = 30

    struct NativeSource {
        let width: Int
        let height: Int
        let maximumFPS: Int
    }

    static let snapshotTargetMegapixels = 1.0
    static let snapshotTargetBytes = 120_000
    static let snapshotQMin = 0.45
    static let snapshotQMax = 0.82
    static let snapshotInitialQ = 0.70

    // Legacy hidden settings keys kept only so older defaults/commented settings UI
    // can be restored without renaming persisted values.
    static let activeBitrateMbpsKey = "streaming.active.bitrateMbps"
    static let activeMaxDimensionKey = "streaming.active.maxDimension"
    static let activeFPSKey = "streaming.active.fps"

    static let inactiveBitrateMbpsKey = "streaming.inactive.bitrateMbps"
    static let inactiveMaxDimensionKey = "streaming.inactive.maxDimension"
    static let inactiveFPSKey = "streaming.inactive.fps"

    static let defaultActiveBitrateMbps = 10
    static let defaultActiveMaxDimension = 1920
    static let defaultActiveFPS = 60

    static let defaultInactiveBitrateMbps = 5
    static let defaultInactiveMaxDimension = 1920
    static let defaultInactiveFPS = 24

    static let bitrateRange = 1...30
    static let maxDimensionRange = 960...3840
    static let fpsRange = 10...120

    struct Snapshot: Equatable {
        let totalBitrateBudget: Int
        let totalMegapixelsPerFrameBudget: Double
        let preferredFPS: Int
    }

    struct StreamPolicy: Equatable {
        let fps: Int
        let scale: Double
        let bitRate: Int
        var nativeFramePixelLimit: Int? = nil
        var decision: String = "standardProfile"
    }

    static func snapshot() -> Snapshot {
        Snapshot(
            totalBitrateBudget: totalBitrateBudget,
            totalMegapixelsPerFrameBudget: totalMegapixelsPerFrameBudget,
            preferredFPS: preferredFPS
        )
    }

    static func registerDefaults() {
        // Legacy defaults remain untouched; the profile fallback is shared with Settings.
    }

    static func restoreDefaults() {
        // Streaming quality is now fixed by the production global budget above.
    }

    static func videoPolicies(
        forSourcePixelSizes sourcePixelSizesByWindow: [UInt32: (width: Int, height: Int)],
        profile: DesktopProfile = desktopProfile,
        nativeRequests: [UInt32: PeelVideoStreamRequest] = [:],
        nativeSources: [UInt32: NativeSource] = [:],
        experimentEnabled: Bool = nativeExperimentEnabled
    ) -> [UInt32: StreamPolicy] {
        guard !sourcePixelSizesByWindow.isEmpty else { return [:] }

        var sourcePixelsByWindow: [UInt32: Double] = [:]
        sourcePixelsByWindow.reserveCapacity(sourcePixelSizesByWindow.count)

        for (windowId, size) in sourcePixelSizesByWindow {
            let width = max(1, size.width)
            let height = max(1, size.height)
            sourcePixelsByWindow[windowId] = Double(width) * Double(height)
        }

        let totalSourcePixels = max(1.0, sourcePixelsByWindow.values.reduce(0.0, +))
        let totalTargetPixels = max(1.0, profile.megapixels * 1_000_000.0)
        let scale = min(1.0, sqrt(totalTargetPixels / totalSourcePixels))
        let outputScale = scale * scale

        var outputPixelsByWindow: [UInt32: Double] = [:]
        outputPixelsByWindow.reserveCapacity(sourcePixelsByWindow.count)

        for (windowId, sourcePixels) in sourcePixelsByWindow {
            outputPixelsByWindow[windowId] = max(1.0, sourcePixels * outputScale)
        }

        let bitratesByWindow = bitrateAllocation(outputPixelsByWindow: outputPixelsByWindow, totalBudget: profile.bitRate)

        var policies: [UInt32: StreamPolicy] = [:]
        policies.reserveCapacity(outputPixelsByWindow.count)

        for windowId in outputPixelsByWindow.keys {
            var policy = StreamPolicy(fps: preferredFPS, scale: scale,
                bitRate: bitratesByWindow[windowId] ?? profile.bitRate)
            if let request = nativeRequests[windowId] {
                policy = nativePolicy(request: request, source: nativeSources[windowId],
                    streamCount: sourcePixelSizesByWindow.count, profile: profile,
                    experimentEnabled: experimentEnabled, fallback: policy)
            }
            policies[windowId] = policy
        }

        return policies
    }

    // The extra budget is never shared across multiple streams. It caps one
    // frame at 14.7456 MP, cadence at 120 and bitrate at the existing 120 Mbps.
    // Caps describe requests, not encoder throughput or delivered frame rate.
    static func nativePolicy(request: PeelVideoStreamRequest, source: NativeSource?,
                             streamCount: Int, profile: DesktopProfile,
                             experimentEnabled: Bool, fallback: StreamPolicy) -> StreamPolicy {
        func declined(_ reason: String) -> StreamPolicy {
            var result = fallback
            result.decision = reason
            return result
        }
        guard experimentEnabled else { return declined("experimentDisabled") }
        guard profile == .fullQuality else { return declined("requiresFullQualityProfile") }
        guard request.isValid else { return declined("invalidReceiverRequest") }
        let receiverMaximumFPS = request.receiverDisplay?.maximumFPS ?? 90
        guard streamCount == 1 else { return declined("multipleStreamsUseSharedBudget") }
        guard let source else { return declined("sourceDisplayCapabilityUnavailable") }
        guard (1...240).contains(source.maximumFPS) else { return declined("sourceRefreshUnavailable") }
        guard (2...nativeExperimentMaximumDimension).contains(source.width),
              (2...nativeExperimentMaximumDimension).contains(source.height),
              Double(source.width) * Double(source.height) <= Double(nativeExperimentFramePixels) else {
            return declined("sourceExceedsNativeExperimentBudget")
        }
        let fps = min(request.maximumFPS, receiverMaximumFPS, source.maximumFPS)
        let decision = fps < request.maximumFPS
            ? (receiverMaximumFPS <= source.maximumFPS ? "receiverRefreshLimited" : "sourceRefreshLimited")
            : "nativeTargetRequestedNotMeasured"
        return StreamPolicy(fps: fps, scale: 1, bitRate: profile.bitRate,
            nativeFramePixelLimit: nativeExperimentFramePixels, decision: decision)
    }

    static func singleStreamFallbackPolicy() -> StreamPolicy {
        StreamPolicy(
            fps: preferredFPS,
            scale: 1.0,
            bitRate: totalBitrateBudget
        )
    }

    private static func bitrateAllocation(outputPixelsByWindow: [UInt32: Double], totalBudget: Int) -> [UInt32: Int] {
        guard !outputPixelsByWindow.isEmpty else { return [:] }

        var remainingWindowIds = Set(outputPixelsByWindow.keys)
        var remainingBudget = totalBudget
        var remainingPixels = max(1.0, outputPixelsByWindow.values.reduce(0.0, +))
        var assigned: [UInt32: Int] = [:]
        assigned.reserveCapacity(outputPixelsByWindow.count)

        while !remainingWindowIds.isEmpty {
            if remainingBudget <= minimumStreamBitrate * remainingWindowIds.count {
                let sortedIds = remainingWindowIds.sorted()
                let base = max(1, remainingBudget / max(1, sortedIds.count))
                var remainder = max(0, remainingBudget - (base * sortedIds.count))

                for windowId in sortedIds {
                    let extra = remainder > 0 ? 1 : 0
                    assigned[windowId] = base + extra
                    remainder = max(0, remainder - 1)
                }

                break
            }

            let underMinimum = remainingWindowIds.filter { windowId in
                let pixels = outputPixelsByWindow[windowId] ?? 1.0
                let proposed = Int((Double(remainingBudget) * pixels / remainingPixels).rounded(.toNearestOrAwayFromZero))
                return proposed < minimumStreamBitrate
            }

            if underMinimum.isEmpty {
                let sortedIds = remainingWindowIds.sorted()
                var allocated = 0

                for (index, windowId) in sortedIds.enumerated() {
                    let bitrate: Int
                    if index == sortedIds.count - 1 {
                        bitrate = max(1, remainingBudget - allocated)
                    } else {
                        let pixels = outputPixelsByWindow[windowId] ?? 1.0
                        bitrate = max(1, Int((Double(remainingBudget) * pixels / remainingPixels).rounded(.toNearestOrAwayFromZero)))
                        allocated += bitrate
                    }

                    assigned[windowId] = bitrate
                }

                break
            }

            for windowId in underMinimum {
                assigned[windowId] = minimumStreamBitrate
                remainingBudget -= minimumStreamBitrate
                remainingPixels -= outputPixelsByWindow[windowId] ?? 0.0
                remainingWindowIds.remove(windowId)
            }

            remainingPixels = max(1.0, remainingPixels)
        }

        return assigned
    }
}

private enum PeelPixelBudget {
    static func nativeExperimentDimensions(sourceWidth: Int, sourceHeight: Int,
                                           scale: Double, maximumPixels: Int) -> (width: Int, height: Int) {
        let width = Double(max(2, sourceWidth)), height = Double(max(2, sourceHeight))
        let boundedScale = min(1, max(0, scale),
            sqrt(Double(max(4, maximumPixels)) / (width * height)),
            Double(PeelStreamingSettings.nativeExperimentMaximumDimension) / max(width, height))
        // Round down before even alignment so rounding cannot exceed the bound.
        return (h264CompatibleDimension(Int((width * boundedScale).rounded(.down))),
                h264CompatibleDimension(Int((height * boundedScale).rounded(.down))))
    }

    static func dimensions(
        sourceWidth: Int,
        sourceHeight: Int,
        scale: Double,
        forceEvenDimensions: Bool
    ) -> (width: Int, height: Int) {
        let safeSourceWidth = max(1, sourceWidth)
        let safeSourceHeight = max(1, sourceHeight)
        let safeScale = min(1.0, max(0.01, scale))

        var width = max(1, Int((Double(safeSourceWidth) * safeScale).rounded(.toNearestOrAwayFromZero)))
        var height = max(1, Int((Double(safeSourceHeight) * safeScale).rounded(.toNearestOrAwayFromZero)))

        if forceEvenDimensions {
            width = h264CompatibleDimension(width)
            height = h264CompatibleDimension(height)
        }

        return (width, height)
    }

    static func dimensions(
        sourceWidth: Int,
        sourceHeight: Int,
        targetMegapixels: Double,
        forceEvenDimensions: Bool
    ) -> (width: Int, height: Int) {
        let safeSourceWidth = max(1, sourceWidth)
        let safeSourceHeight = max(1, sourceHeight)
        let sourcePixels = max(1.0, Double(safeSourceWidth) * Double(safeSourceHeight))
        let targetPixels = max(1.0, targetMegapixels * 1_000_000.0)
        let scale = min(1.0, sqrt(targetPixels / sourcePixels))

        return dimensions(
            sourceWidth: safeSourceWidth,
            sourceHeight: safeSourceHeight,
            scale: scale,
            forceEvenDimensions: forceEvenDimensions
        )
    }

    private static func h264CompatibleDimension(_ value: Int) -> Int {
        max(2, value - (value % 2))
    }
}



final class WindowStreamer {
    var sendJSONLine: ((any Encodable) -> Void)?
    var sendBinaryPacket: ((UInt32, Data) -> Void)?
    var canAcceptVideoFrame: ((UInt32) -> Bool)?
    var videoTransportIsAvailable: ((UInt32) -> Bool)?
    weak var streamDiagnostics: StreamDiagnosticsStore?
    let streamingDiagnostics = PeelStreamingDiagnostics()

    var activeWindowProvider: () -> UInt32? = { nil }
    var captureModeProvider: (UInt32) -> CaptureMode = { _ in .composited }
    var focusKick: (UInt32) -> Void = { _ in }

    private let captureQueue = DispatchQueue(label: "peel.capture", qos: .userInitiated)
    private let videoFrameQueue = DispatchQueue(label: "peel.videoFrame", qos: .userInitiated)
    private let videoTeardownQueue = DispatchQueue(label: "peel.videoTeardown", qos: .utility)
    private let geometryQueue = DispatchQueue(label: "peel.geometry", qos: .utility)
    private let diagnosticsQueue = DispatchQueue(label: "peel.windowStreamer.diagnostics", qos: .utility)
    private let videoCaptureAdmission = PeelVideoCaptureAdmission()
    private lazy var latestVideoSampleQueue: PeelLatestVideoSampleQueue = {
        PeelLatestVideoSampleQueue(consumerQueue: videoFrameQueue) { [weak self] windowId, capture, sampleBuffer in
            self?.handleVideoSampleBuffer_locked(sampleBuffer, windowId: windowId, capture: capture)
        }
    }()
    private var diagnosticsActiveStreamCount: Int = 0
    private var diagnosticsDroppedRawFrames = 0
    private var diagnosticsEncodedFrames = 0
    private var diagnosticsSentFrames = 0
    private var diagnosticsEncodeInFlightCount = 0

    private enum HostPipelineStage: String {
        case sck = "SCK"
        case encodeSubmit = "Sub"
        case encodeOutput = "Out"
        case send = "Send"
    }

    private struct HostPipelineAccumulator {
        var frames: Int = 0
        var intervals: Int = 0
        var totalIntervalMs: Double = 0
        var maxIntervalMs: Double = 0
    }

    private var diagnosticsPipelineFrameCounts: [HostPipelineStage: HostPipelineAccumulator] = [:]
    private var diagnosticsLastPipelineFrameAtByStageWindow: [String: CFAbsoluteTime] = [:]
    private var lastStreamerDiagnosticsFlushAt = CFAbsoluteTimeGetCurrent()

    enum TransportMode {
        case legacyJPEG
        case h264Video
    }

    private var transportMode: TransportMode = .legacyJPEG

    @available(macOS 13.0, *)
    private lazy var sckVideoBridge: SCKVideoBridge = {
        let bridge = SCKVideoBridge()
        bridge.onSampleBuffer = { [weak self] windowId, capture, sampleBuffer in
            self?.receiveVideoSample(sampleBuffer, windowId: windowId, capture: capture)
        }
        bridge.onStop = { [weak self] windowId, capture, error in
            guard let self else { return }
            let retired = self.videoCaptureAdmission.revoke(capture) {
                self.latestVideoSampleQueue.remove(windowId: windowId, capture: capture)
                self.captureQueue.async {
                    self.retireVideoCaptureState_locked(windowId: windowId, capture: capture)
                }
                self.videoFrameQueue.async {
                    self.retireVideoEncoder_locked(windowId: windowId, capture: capture, endCapture: true)
                }
            }
            guard retired else { return }
            if let error {
                print("PeelHost: video stream stopped for \(windowId) with error: \(error.localizedDescription)")
            } else {
                print("PeelHost: video stream stopped for \(windowId)")
            }
        }

        return bridge
    }()

    private var videoEncoderByWindow: [UInt32: VideoH264Encoder] = [:]
    private var videoEncoderCaptureByWindow: [UInt32: PeelVideoCaptureToken] = [:]
    private var videoEncoderAdmissionByWindow: [UInt32: UUID] = [:]
    // Capture-queue state is retired only for its exact admission generation.
    private var activeVideoCaptureByWindow: [UInt32: PeelVideoCaptureToken] = [:]
    private var videoEncoderSettingsByWindow: [UInt32: (bitRate: Int, fps: Int)] = [:]
    private var preferredVideoCodecByWindow: [UInt32: PeelVideoCodec] = [:]
    private let videoPolicyLock = NSLock()
    private var videoPolicyByWindow: [UInt32: PeelStreamingSettings.StreamPolicy] = [:]
    private var forceKeyframeAfterBackpressureWindowIds: Set<UInt32> = []
    private var lastRecoveryKeyframeRequest: [UInt32: TimeInterval] = [:]
    private var streamingSettingsObserver: NSObjectProtocol?
    private var lastAppliedStreamingSettingsSnapshot = PeelStreamingSettings.snapshot()
    private var activeVideoWindowIds: Set<UInt32> = []
    // Capture-queue owned; replaced and cleared with the video socket/session.
    private var nativeVideoRequests: [UInt32: (request: PeelVideoStreamRequest, token: UUID)] = [:]
    // Capture-queue owned. The exact admitted request epoch whose video Hello
    // opted into the receiver's native pointer; only captures begun from that
    // request omit the baked cursor. A successor request never matches.
    private var nativeCursorRequests: [UInt32: PeelVideoCaptureAdmission.Request] = [:]
    private var reportedCursorModes: [UInt32: (capture: PeelVideoCaptureToken, showsCursor: Bool)] = [:]
    private var reportedVideoPolicies: [UInt32: PeelStreamingSettings.StreamPolicy] = [:]
    private var lastClientActiveVideoWindowId: UInt32?
    private var snapshotsInFlight: Set<UInt32> = []
    private var globalHostSnapshotsInFlight: Int = 0
    private let maxHostSnapshotsInFlight: Int = 7

    func requestRecoveryKeyframe(windowId: UInt32) {
        guard let capture = videoCaptureAdmission.currentCapture(windowId: windowId) else { return }
        videoFrameQueue.async { [weak self] in
            guard let self, self.videoCaptureAdmission.isCurrent(capture),
                  self.videoEncoderCaptureByWindow[windowId] == capture,
                  self.videoEncoderByWindow[windowId] != nil else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - (self.lastRecoveryKeyframeRequest[windowId] ?? 0) >= 0.25 else { return }
            self.lastRecoveryKeyframeRequest[windowId] = now
            self.forceKeyframeAfterBackpressureWindowIds.insert(windowId)
        }
    }

    /// Mac receiver keeps its own AppKit pointer; host-rendered-cursor remains
    /// advertised for older hosts. Optional and per video Hello only.
    nonisolated static let receiverNativeCursorCapability = "mac-native-cursor-v1"

    func setVideoCapabilities(_ capabilities: Set<String>, windowId: UInt32, streamRequest: PeelVideoStreamRequest? = nil) {
        let preferredCodec: PeelVideoCodec = capabilities.contains(PeelCapability.hevcVideo.rawValue)
            ? .hevc
            : .h264

        videoCaptureAdmission.enqueueRequest(windowId: windowId) { request in
            self.captureQueue.async { [weak self] in
                guard let self, let request, self.videoCaptureAdmission.isCurrent(request) else { return }
                if let request = streamRequest,
                   capabilities.contains(PeelVideoStreamRequest.capability),
                   capabilities.contains(PeelCapability.hevcVideo.rawValue) {
                    let token = UUID()
                    self.nativeVideoRequests[windowId] = (request, token)
                    // No unattended high-load mode. A fresh socket is required for
                    // another bounded attempt, with a new display observation.
                    self.captureQueue.asyncAfter(deadline: .now() + PeelStreamingSettings.nativeExperimentSeconds) { [weak self] in
                        guard let self, self.nativeVideoRequests[windowId]?.token == token else { return }
                        self.nativeVideoRequests.removeValue(forKey: windowId)
                        self.refreshActiveVideoStreamPolicies_locked()
                    }
                } else {
                    self.nativeVideoRequests.removeValue(forKey: windowId)
                }
                // Absent opt-in (older Mac, iPad, Vision) keeps the baked cursor.
                if capabilities.contains(Self.receiverNativeCursorCapability) {
                    self.nativeCursorRequests[windowId] = request
                } else {
                    self.nativeCursorRequests.removeValue(forKey: windowId)
                }
                self.videoFrameQueue.async { [weak self] in
                    guard let self, self.videoCaptureAdmission.isCurrent(request) else { return }
                    let priorCodec = self.preferredVideoCodecByWindow[windowId] ?? .h264
                    self.preferredVideoCodecByWindow[windowId] = preferredCodec

                    guard priorCodec != preferredCodec else { return }
                    self.retireVideoEncoder_locked(windowId: windowId,
                        capture: self.videoEncoderCaptureByWindow[windowId])
                }
            }
        }
    }

    private struct SnapshotPumpState {
        var isCapturing: Bool
        var pending: Bool
        var lastRequestAt: CFAbsoluteTime
    }

    private var snapshotPumpByWindow: [UInt32: SnapshotPumpState] = [:]
    private var latestSnapshotGenerationByWindow: [UInt32: UInt64] = [:]

    private var lastSentGeometry: [UInt32: CGRect] = [:]
    private var lastSentGeometryAt: [UInt32: CFAbsoluteTime] = [:]
    private let geometryResendInterval: CFTimeInterval = 0.75

    private var lastWindowListSentAt: CFAbsoluteTime = 0
    private var windowListSendPending: Bool = false
    private let minWindowListSendInterval: CFTimeInterval = 1.25
    private var cachedWindowList: [PeelWindow] = []
    private var cachedWindowListGeneratedAt: CFAbsoluteTime = 0
    private let windowListCacheInterval: CFTimeInterval = 1.25
    private var windowListEnumerationInFlight: Bool = false

    private var lastEffectiveCaptureModeByWindow: [UInt32: CaptureMode] = [:]
    private var lastCompositedFocusKickAtByWindow: [UInt32: CFAbsoluteTime] = [:]

    private var jpegQualityByWindow: [UInt32: Double] = [:]
    private var scalerCacheByWindow: [UInt32: WindowFrameScalerCache] = [:]
    private var jpegEncodeCacheByWindow: [UInt32: WindowJPEGEncodeCache] = [:]

    private var lastAnyInputAt: Date = .distantPast
    private var lastInputAtByWindow: [UInt32: Date] = [:]

//    private var lastSCKSampleDebugAtByWindow: [UInt32: CFAbsoluteTime] = [:]
//    private let sckSampleDebugInterval: CFTimeInterval = 1.0

    private var geometryLookupInFlight: Set<UInt32> = []
    private var lastGeometryLookupScheduledAt: [UInt32: CFAbsoluteTime] = [:]

    private var perf_frameCounter: UInt64 = 0
    private let perf_logEveryNFrames: UInt64 = 60

    private struct SnapshotEncodingPolicy {
        let name: String
        let targetMegapixels: Double
        let targetBytes: Int
        let qMin: Double
        let qMax: Double
        let initialQ: Double
    }

    private let snapshotEncodingPolicy = SnapshotEncodingPolicy(
        name: "jpeg",
        targetMegapixels: PeelStreamingSettings.snapshotTargetMegapixels,
        targetBytes: PeelStreamingSettings.snapshotTargetBytes,
        qMin: PeelStreamingSettings.snapshotQMin,
        qMax: PeelStreamingSettings.snapshotQMax,
        initialQ: PeelStreamingSettings.snapshotInitialQ
    )

    init() {
        // Materialize once before any concurrent ScreenCaptureKit callbacks.
        _ = latestVideoSampleQueue
        PeelStreamingSettings.registerDefaults()

        streamingSettingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: nil
        ) { [weak self] _ in
            self?.streamingSettingsDidChange()
        }
    }

    deinit {
        if let streamingSettingsObserver {
            NotificationCenter.default.removeObserver(streamingSettingsObserver)
        }
    }

    private func streamingSettingsDidChange() {
        captureQueue.async {
            guard self.transportMode == .h264Video else { return }

            let snapshot = PeelStreamingSettings.snapshot()
            guard snapshot != self.lastAppliedStreamingSettingsSnapshot else { return }
            self.lastAppliedStreamingSettingsSnapshot = snapshot

            for activeVideoWindowId in self.activeVideoWindowIds {
                self.ensureVideoStream_locked(windowId: activeVideoWindowId)
            }
        }
    }

    func setTransportMode(_ mode: TransportMode) {
        captureQueue.async {
            self.transportMode = mode
        }
    }

    func resetSessionState() {
        streamingDiagnostics.reset()
        // Invalidate queued raw samples before asynchronous bridge/encoder
        // teardown can run. A later generation gets a fresh token.
        videoCaptureAdmission.revokeAll {
            self.latestVideoSampleQueue.clearAll()
            self.resetDiagnosticsCounters()
            self.captureQueue.async {
                self.snapshotsInFlight.removeAll()
                self.globalHostSnapshotsInFlight = 0
                self.snapshotPumpByWindow.removeAll()
                self.latestSnapshotGenerationByWindow.removeAll()

                self.lastSentGeometry.removeAll()
                self.lastSentGeometryAt.removeAll()
                self.lastEffectiveCaptureModeByWindow.removeAll()
                self.lastCompositedFocusKickAtByWindow.removeAll()
                self.jpegQualityByWindow.removeAll()
                self.scalerCacheByWindow.removeAll()
                self.jpegEncodeCacheByWindow.removeAll()
                self.lastAnyInputAt = .distantPast
                self.lastInputAtByWindow.removeAll()

                self.lastWindowListSentAt = 0
                self.windowListSendPending = false
                self.cachedWindowList.removeAll()
                self.cachedWindowListGeneratedAt = 0
                self.windowListEnumerationInFlight = false

                if #available(macOS 13.0, *) {
                    self.sckVideoBridge.stopAll()
                }

                self.activeVideoWindowIds.removeAll()
                self.activeVideoCaptureByWindow.removeAll()
                self.nativeVideoRequests.removeAll()
                self.nativeCursorRequests.removeAll()
                self.reportedCursorModes.removeAll()
                self.reportedVideoPolicies.removeAll()
                self.clearVideoPolicies()
                self.lastClientActiveVideoWindowId = nil
                self.lastAppliedStreamingSettingsSnapshot = PeelStreamingSettings.snapshot()
                self.noteActiveStreamCountForDiagnostics(0)
                self.geometryLookupInFlight.removeAll()
                self.lastGeometryLookupScheduledAt.removeAll()

                self.videoFrameQueue.async {
                    let encodersToInvalidate = Array(self.videoEncoderByWindow.values)
                    self.videoEncoderByWindow.removeAll()
                    self.videoEncoderCaptureByWindow.removeAll()
                    self.videoEncoderAdmissionByWindow.removeAll()
                    self.videoEncoderSettingsByWindow.removeAll()
                    self.preferredVideoCodecByWindow.removeAll()
                    self.forceKeyframeAfterBackpressureWindowIds.removeAll()
                    self.lastRecoveryKeyframeRequest.removeAll()
    //                self.lastSCKSampleDebugAtByWindow.removeAll()

                    for encoder in encodersToInvalidate {
                        encoder.invalidateAsync()
                    }
                }
            }
        }
    }

    func markInput(windowId: UInt32?) {
        let now = Date()
        captureQueue.async {
            self.lastAnyInputAt = now
            if let windowId {
                self.lastInputAtByWindow[windowId] = now
            }
        }
    }

    func requestSendWindowList() {
        captureQueue.async { [weak self] in
            guard let self else { return }

            let now = CFAbsoluteTimeGetCurrent()
            let elapsed = now - self.lastWindowListSentAt

            if elapsed >= self.minWindowListSendInterval {
                self.lastWindowListSentAt = now
                self.sendWindowList_locked(now: now)
                return
            }

            guard !self.windowListSendPending else { return }
            self.windowListSendPending = true

            let delay = max(0, self.minWindowListSendInterval - elapsed)
            self.captureQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.windowListSendPending = false
                let now = CFAbsoluteTimeGetCurrent()
                self.lastWindowListSentAt = now
                self.sendWindowList_locked(now: now)
            }
        }
    }

    func requestSnapshot(windowId: UInt32) {
//        streamDebug(windowId: windowId, stage: "streamer_requestSnapshot_called_before_queue")

        videoCaptureAdmission.enqueueRequest(windowId: windowId) { request in
            self.captureQueue.async {
    //            self.streamDebug(windowId: windowId, stage: "streamer_requestSnapshot_entered")

                _ = self.nextSnapshotGeneration_locked(for: windowId)

                switch self.transportMode {
                case .legacyJPEG:
                    var st = self.snapshotPumpByWindow[windowId] ?? SnapshotPumpState(isCapturing: false, pending: false, lastRequestAt: 0)
                    st.pending = true
                    st.lastRequestAt = CFAbsoluteTimeGetCurrent()
                    self.snapshotPumpByWindow[windowId] = st
                    self.maybeStartCoalescedSnapshots_locked()

                case .h264Video:
    //                self.streamDebug(windowId: windowId, stage: "streamer_request_h264")
                    guard let request else { return }
                    self.ensureVideoStream_locked(windowId: windowId, request: request)
                }
            }
        }
    }

    private func sendWindowList_locked(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        let cacheAge = now - cachedWindowListGeneratedAt
        if !cachedWindowList.isEmpty, cacheAge < windowListCacheInterval {
            sendJSONLine?(WindowListMessage(windows: cachedWindowList))
            print("PeelHost: sent cached windowList with \(cachedWindowList.count) windows")
            return
        }

        guard !windowListEnumerationInFlight else {
            if !cachedWindowList.isEmpty {
                sendJSONLine?(WindowListMessage(windows: cachedWindowList))
                print("PeelHost: sent stale cached windowList with \(cachedWindowList.count) windows while enumeration in flight")
            }
            return
        }

        windowListEnumerationInFlight = true

        let windows = WindowEnumerator.enumerateWindows()
        cachedWindowList = windows
        cachedWindowListGeneratedAt = CFAbsoluteTimeGetCurrent()
        windowListEnumerationInFlight = false

        sendJSONLine?(WindowListMessage(windows: windows))
        print("PeelHost: sent windowList with \(windows.count) windows")
    }

    private func nextSnapshotGeneration_locked(for windowId: UInt32) -> UInt64 {
        let next = (latestSnapshotGenerationByWindow[windowId] ?? 0) &+ 1
        latestSnapshotGenerationByWindow[windowId] = next
        return next
    }

    private func isSnapshotGenerationFresh_locked(windowId: UInt32, generation: UInt64) -> Bool {
        (latestSnapshotGenerationByWindow[windowId] ?? 0) == generation
    }

    private func maybeStartCoalescedSnapshots_locked() {
        while globalHostSnapshotsInFlight < maxHostSnapshotsInFlight {
            let candidate = snapshotPumpByWindow
                .filter { $0.value.pending && !$0.value.isCapturing }
                .max { $0.value.lastRequestAt < $1.value.lastRequestAt }

            guard let (windowId, state) = candidate else { return }

            var st = state
            st.pending = false
            st.isCapturing = true
            snapshotPumpByWindow[windowId] = st

            let admittedGeneration = latestSnapshotGenerationByWindow[windowId] ?? 0
            performSnapshotCapture_locked(windowId: windowId, admittedGeneration: admittedGeneration)
        }
    }

    @preconcurrency
    @available(*, deprecated, message: "CGWindowListCreateImage is intentionally used for ultra-low-latency snapshots.")
    private func performSnapshotCapture_locked(windowId: UInt32, admittedGeneration: UInt64) {
        if globalHostSnapshotsInFlight >= maxHostSnapshotsInFlight {
            var st = snapshotPumpByWindow[windowId] ?? SnapshotPumpState(isCapturing: false, pending: true, lastRequestAt: CFAbsoluteTimeGetCurrent())
            st.isCapturing = false
            st.pending = true
            snapshotPumpByWindow[windowId] = st
            return
        }

        if snapshotsInFlight.contains(windowId) {
            var st = snapshotPumpByWindow[windowId] ?? SnapshotPumpState(isCapturing: false, pending: true, lastRequestAt: CFAbsoluteTimeGetCurrent())
            st.isCapturing = false
            st.pending = true
            snapshotPumpByWindow[windowId] = st
            return
        }

        snapshotsInFlight.insert(windowId)
        globalHostSnapshotsInFlight += 1

        var didReleaseCaptureAdmission = false

        let clearInFlight: () -> Void = {
            guard !didReleaseCaptureAdmission else { return }
            didReleaseCaptureAdmission = true

            self.snapshotsInFlight.remove(windowId)
            self.globalHostSnapshotsInFlight = max(0, self.globalHostSnapshotsInFlight - 1)

            var st = self.snapshotPumpByWindow[windowId] ?? SnapshotPumpState(isCapturing: false, pending: false, lastRequestAt: 0)
            st.isCapturing = false
            self.snapshotPumpByWindow[windowId] = st
            self.maybeStartCoalescedSnapshots_locked()
        }

        let dropIfStale: () -> Bool = {
            !self.isSnapshotGenerationFresh_locked(windowId: windowId, generation: admittedGeneration)
        }

        defer { clearInFlight() }

        let t0 = CFAbsoluteTimeGetCurrent()
        let baseBounds = WindowEnumerator.bounds(for: windowId) ?? .null

        let requestedMode = captureModeProvider(windowId)
        let isClientActive = activeWindowProvider() == windowId
        let effectiveMode: CaptureMode = (requestedMode == .composited && !isClientActive) ? .isolated : requestedMode

        let priorEffective = lastEffectiveCaptureModeByWindow[windowId]
        if priorEffective != effectiveMode {
            lastEffectiveCaptureModeByWindow[windowId] = effectiveMode

            if effectiveMode == .composited {
                let nowT = CFAbsoluteTimeGetCurrent()
                let last = lastCompositedFocusKickAtByWindow[windowId] ?? 0
                if (nowT - last) > 0.25 {
                    lastCompositedFocusKickAtByWindow[windowId] = nowT
                    DispatchQueue.main.async {
                        guard self.activeWindowProvider() == windowId else { return }
                        self.focusKick(windowId)
                    }
                }
            }
        }

        let listOptions: CGWindowListOption = {
            switch effectiveMode {
            case .isolated:
                return [.optionIncludingWindow, .excludeDesktopElements]
            case .composited:
                return [.optionOnScreenAboveWindow, .optionIncludingWindow, .excludeDesktopElements]
            }
        }()

        let imageOptions: CGWindowImageOption = {
            switch effectiveMode {
            case .isolated:
                return [.boundsIgnoreFraming]
            case .composited:
                return [.bestResolution]
            }
        }()

        guard let cgImage = CGWindowListCreateImageShim(
            baseBounds,
            listOptions,
            CGWindowID(windowId),
            imageOptions
        ) else {
            print("PeelHost: failed snapshot \(windowId)")
            return
        }

        let tCapture = CFAbsoluteTimeGetCurrent()
        guard !dropIfStale() else { return }

        let snapshotPolicy = snapshotEncodingPolicy
        let dimensions = PeelPixelBudget.dimensions(
            sourceWidth: cgImage.width,
            sourceHeight: cgImage.height,
            targetMegapixels: snapshotPolicy.targetMegapixels,
            forceEvenDimensions: false
        )
        let targetW = dimensions.width
        let targetH = dimensions.height

        guard let scaledImage = scalerCache(for: windowId).scale(cgImage: cgImage, targetW: targetW, targetH: targetH) else {
            return
        }

        let tScale = CFAbsoluteTimeGetCurrent()
        guard !dropIfStale() else { return }

        let jpegQ = currentJPEGQuality(for: windowId, initial: snapshotPolicy.initialQ)
        let encodeCache = jpegEncodeCache(for: windowId)
        encodeCache.reset()

        guard let dest = CGImageDestinationCreateWithData(encodeCache.data, kUTTypeJPEG, 1, nil) else {
            return
        }

        CGImageDestinationAddImage(dest, scaledImage, [
            kCGImageDestinationLossyCompressionQuality: jpegQ as CFNumber
        ] as CFDictionary)

        CGImageDestinationFinalize(dest)
        let tEncode = CFAbsoluteTimeGetCurrent()
        let bytes = CFDataGetLength(encodeCache.data)

        updateJPEGQuality(
            for: windowId,
            encodedBytes: bytes,
            targetBytes: snapshotPolicy.targetBytes,
            qMin: snapshotPolicy.qMin,
            qMax: snapshotPolicy.qMax,
            initial: snapshotPolicy.initialQ
        )

        guard !dropIfStale() else { return }


        maybeSendWindowGeometry(windowId: windowId, capturePxW: targetW, capturePxH: targetH)

        var header = Data(count: 9)
        header.withUnsafeMutableBytes { raw in
            guard let p = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            p[0] = 0x02

            var idLE = windowId.littleEndian
            withUnsafeBytes(of: &idLE) { idBytes in
                memcpy(p.advanced(by: 1), idBytes.baseAddress!, 4)
            }

            var lenLE = UInt32(bytes).littleEndian
            withUnsafeBytes(of: &lenLE) { lenBytes in
                memcpy(p.advanced(by: 5), lenBytes.baseAddress!, 4)
            }
        }

        guard !dropIfStale() else { return }

        let jpegData = encodeCache.data as Data
        clearInFlight()

        sendBinaryPacket?(windowId, header)
        sendBinaryPacket?(windowId, jpegData)

        perf_frameCounter += 1
        if perf_frameCounter % perf_logEveryNFrames == 0 {
            let capMs = (tCapture - t0) * 1000
            let scaleMs = (tScale - tCapture) * 1000
            let encMs = (tEncode - tScale) * 1000
            let totalMs = (tEncode - t0) * 1000
            print(String(format: "HOST win=%u gen=%llu bytes=%d mode=%@ q=%.2f cap=%.1fms scale=%.1fms enc=%.1fms total=%.1fms",
                         windowId, admittedGeneration, bytes, snapshotPolicy.name as NSString, jpegQ, capMs, scaleMs, encMs, totalMs))
        }
    }
    private func currentVideoStreamPolicy(for windowId: UInt32) -> PeelStreamingSettings.StreamPolicy {
        videoPolicyLock.lock()
        let policy = videoPolicyByWindow[windowId]
        videoPolicyLock.unlock()

        return policy ?? PeelStreamingSettings.singleStreamFallbackPolicy()
    }

    private func replaceVideoPolicies(_ policies: [UInt32: PeelStreamingSettings.StreamPolicy]) {
        videoPolicyLock.lock()
        videoPolicyByWindow = policies
        videoPolicyLock.unlock()
    }

    private func removeVideoPolicy(windowId: UInt32) {
        videoPolicyLock.lock()
        videoPolicyByWindow.removeValue(forKey: windowId)
        videoPolicyLock.unlock()
    }

    private func clearVideoPolicies() {
        videoPolicyLock.lock()
        videoPolicyByWindow.removeAll()
        videoPolicyLock.unlock()
    }

    private func estimatedSourcePixelSizeForPolicy(windowId: UInt32) -> (width: Int, height: Int) {
        let fallback = (width: 1280, height: 720)
        guard let bounds = WindowEnumerator.bounds(for: windowId), !bounds.isNull, !bounds.isEmpty else {
            return fallback
        }

        let pixelScale = estimatedBackingScale(for: bounds)
        return (
            width: max(1, Int((bounds.width * pixelScale).rounded(.toNearestOrAwayFromZero))),
            height: max(1, Int((bounds.height * pixelScale).rounded(.toNearestOrAwayFromZero)))
        )
    }

    private func estimatedBackingScale(for bounds: CGRect) -> CGFloat {
        let midpoint = CGPoint(x: bounds.midX, y: bounds.midY)

        if let screen = NSScreen.screens.first(where: { $0.frame.contains(midpoint) }) {
            return max(1.0, screen.backingScaleFactor)
        }

        return max(1.0, NSScreen.main?.backingScaleFactor ?? 1.0)
    }

    private func refreshActiveVideoStreamPolicies_locked() {
        guard transportMode == .h264Video else { return }

        var sourceSizesByWindow: [UInt32: (width: Int, height: Int)] = [:]
        sourceSizesByWindow.reserveCapacity(activeVideoWindowIds.count)

        for windowId in activeVideoWindowIds {
            sourceSizesByWindow[windowId] = estimatedSourcePixelSizeForPolicy(windowId: windowId)
        }

        var nativeSources: [UInt32: PeelStreamingSettings.NativeSource] = [:]
        for windowId in activeVideoWindowIds where nativeVideoRequests[windowId] != nil {
            // Native experiments are restricted to an actual display source.
            // Unknown/variable refresh (zero) never establishes a 120 Hz source.
            if let displayId = WindowEnumerator.displayCaptureDisplayId(for: windowId),
               let mode = CGDisplayCopyDisplayMode(displayId), mode.refreshRate.isFinite,
               mode.refreshRate >= 1, mode.refreshRate <= 240 {
                nativeSources[windowId] = .init(width: mode.pixelWidth, height: mode.pixelHeight,
                    maximumFPS: Int(mode.refreshRate.rounded(.down)))
            }
        }
        let policies = PeelStreamingSettings.videoPolicies(forSourcePixelSizes: sourceSizesByWindow,
            nativeRequests: nativeVideoRequests.mapValues(\.request), nativeSources: nativeSources)
        replaceVideoPolicies(policies)
        for (windowId, policy) in policies where reportedVideoPolicies[windowId] != policy {
            // Content-free target/configuration breadcrumb, never a performance claim.
            sendJSONLine?(HostStreamDebugMessage(windowId: windowId, stage: "host_stream_policy",
                detail: "targetFPS=\(policy.fps) scale=\(policy.scale) bitrate=\(policy.bitRate) decision=\(policy.decision); deliveredFPS=unmeasured"))
        }
        reportedVideoPolicies = policies

        for windowId in activeVideoWindowIds {
            guard let policy = policies[windowId] else { continue }
            guard videoTransportIsAvailable?(windowId) == true else { continue }
            applyVideoStreamPolicy_locked(windowId: windowId, policy: policy)
        }
    }

    func clientActiveWindowDidChange(windowId: UInt32?) {
        captureQueue.async {
            self.lastClientActiveVideoWindowId = windowId
        }
    }

    private func ensureVideoStream_locked(windowId: UInt32,
        request: PeelVideoCaptureAdmission.Request? = nil) {
        guard #available(macOS 13.0, *) else {
            print("PeelHost: h264 video streaming requires macOS 13+")
            return
        }

        guard videoTransportIsAvailable?(windowId) == true else {
            print("PeelHost: video transport unavailable for window \(windowId); waiting for per-window video socket")
            return
        }

        let capture: PeelVideoCaptureToken?
        if let request { capture = videoCaptureAdmission.begin(request) }
        else { capture = videoCaptureAdmission.currentCapture(windowId: windowId) }
        guard let capture else { return }
        activeVideoCaptureByWindow[windowId] = capture
        activeVideoWindowIds.insert(windowId)
        noteActiveStreamCountForDiagnostics(activeVideoWindowIds.count)
        refreshActiveVideoStreamPolicies_locked()
    }

    private func applyVideoStreamPolicy_locked(windowId: UInt32, policy: PeelStreamingSettings.StreamPolicy) {
        guard #available(macOS 13.0, *) else { return }
        // Capture-queue ordering matches Stop/reset. The bridge schedules the
        // expensive work asynchronously and retains the newest pending descriptor.
        // Do not skip a downgrade just because a prior start is still pending.
        guard let capture = activeVideoCaptureByWindow[windowId],
              videoCaptureAdmission.isCurrent(capture) else { return }
        let showsCursor = nativeCursorRequests[windowId] != capture.request
        if reportedCursorModes[windowId].map({ $0.capture != capture || $0.showsCursor != showsCursor }) ?? true {
            reportedCursorModes[windowId] = (capture, showsCursor)
            // Content-free; once per capture or mode change, never per frame.
            sendJSONLine?(HostStreamDebugMessage(windowId: windowId, stage: "host_stream_cursor",
                detail: "showsCursor=\(showsCursor) receiverNativePointer=\(!showsCursor)"))
        }
        sckVideoBridge.ensureStreaming(windowId: windowId, capture: capture, descriptor: SCKVideoBridge.Descriptor(
            scale: policy.scale, preferredFPS: policy.fps, showsCursor: showsCursor,
            nativeFramePixelLimit: policy.nativeFramePixelLimit))
    }


    private func receiveVideoSample(_ sampleBuffer: CMSampleBuffer, windowId: UInt32, capture: PeelVideoCaptureToken) {
        guard PeelScreenSampleAdmission.isUsable(sampleBuffer) else { return }
        videoCaptureAdmission.withCapture(capture) {
            _ = latestVideoSampleQueue.offer(sampleBuffer, windowId: windowId, capture: capture)
        }
    }

    private func handleVideoSampleBuffer_locked(_ sampleBuffer: CMSampleBuffer, windowId: UInt32, capture: PeelVideoCaptureToken) {
        guard videoCaptureAdmission.isCurrent(capture) else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        noteHostPipelineFrameForDiagnostics(.sck, windowId: windowId)

        guard videoTransportIsAvailable?(windowId) == true else {
            noteDroppedRawFrameForDiagnostics()
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        guard width.isMultiple(of: 2), height.isMultiple(of: 2) else {
//            streamDebug(
//                windowId: windowId,
//                stage: "host_h264_odd_sample_dropped",
//                detail: "\(width)x\(height)"
//            )
            return
        }

        // Latest-frame-wins: when the socket already has too much compressed
        // video queued/in flight, drop this raw SCK sample before VideoToolbox.
        // Dropping here is decoder-safe; dropping arbitrary encoded P-frames is not.
        // Do not force a keyframe here; the encoder never saw this dropped raw sample,
        // and forced keyframes can amplify send backpressure during motion.
        if canAcceptVideoFrame?(windowId) == false {
            noteDroppedRawFrameForDiagnostics()
            return
        }

//        let sampleDebugNow = CFAbsoluteTimeGetCurrent()
//        let lastSampleDebugAt = lastSCKSampleDebugAtByWindow[windowId] ?? 0
//        if (sampleDebugNow - lastSampleDebugAt) >= sckSampleDebugInterval {
//            lastSCKSampleDebugAtByWindow[windowId] = sampleDebugNow
//            streamDebug(
//                windowId: windowId,
//                stage: "host_sck_sample_received",
//                detail: "\(width)x\(height)"
//            )
//        }

        let policy = currentVideoStreamPolicy(for: windowId)
        let fps = policy.fps
        let bitRate = policy.bitRate

        VideoColorMetadata.applyRec709FullRange(to: pixelBuffer)

        let encoder: VideoH264Encoder
        let shouldForceKeyframe: Bool

        if let existing = videoEncoderByWindow[windowId],
           videoEncoderCaptureByWindow[windowId] == capture, existing.matches(width: width, height: height) {
            let priorSettings = videoEncoderSettingsByWindow[windowId]
            if priorSettings?.bitRate != bitRate || priorSettings?.fps != fps {
                videoEncoderSettingsByWindow[windowId] = (bitRate, fps)
                existing.updateAsync(bitRate: bitRate, fps: fps)
            }

            encoder = existing
            shouldForceKeyframe = forceKeyframeAfterBackpressureWindowIds.contains(windowId)
            if shouldForceKeyframe {
                forceKeyframeAfterBackpressureWindowIds.remove(windowId)
            }
        } else {
            retireVideoEncoder_locked(windowId: windowId, capture: videoEncoderCaptureByWindow[windowId])
            guard let outputAdmission = videoCaptureAdmission.bindEncoder(for: capture) else { return }

            let fresh = VideoH264Encoder(
                windowId: windowId,
                width: width,
                height: height,
                bitRate: bitRate,
                fps: fps,
                preferredCodec: preferredVideoCodecByWindow[windowId] ?? .h264,
                teardownQueue: videoTeardownQueue,
                diagnostics: streamingDiagnostics
            )
            fresh.onInFlightCountChanged = { [weak self] count in
                self?.noteEncodeInFlightForDiagnostics(count)
            }
            fresh.onEncodeSubmit = { [weak self] windowId in
                self?.noteHostPipelineFrameForDiagnostics(.encodeSubmit, windowId: windowId)
            }
            fresh.onEncodeOutput = { [weak self] windowId in
                self?.noteHostPipelineFrameForDiagnostics(.encodeOutput, windowId: windowId)
            }
            fresh.onOutput = { [weak self] accessUnit in
                guard let self else { return }
                guard self.videoTransportIsAvailable?(accessUnit.windowId) == true else { return }
                // Prepare bytes outside the admission lock. Only immediate
                // enqueue is serialized with Stop/encoder replacement below.
                let configData: Data?
                if let sps = accessUnit.sps, let pps = accessUnit.pps {
                    configData = VideoConfigPacket(
                        windowId: accessUnit.windowId,
                        codec: accessUnit.codec,
                        width: UInt32(accessUnit.width),
                        height: UInt32(accessUnit.height),
                        timescale: UInt32(max(1, accessUnit.pts.timescale)),
                        nalUnitHeaderLength: UInt8(accessUnit.nalUnitHeaderLength),
                        sps: sps,
                        pps: pps,
                        vps: accessUnit.vps
                    ).encode()
                } else {
                    configData = nil
                }
                let frameData = VideoFramePacket(
                    windowId: accessUnit.windowId,
                    isKeyframe: accessUnit.isKeyframe,
                    ptsValue: accessUnit.pts.value,
                    durationValue: accessUnit.duration.isValid ? accessUnit.duration.value : 0,
                    payload: accessUnit.payload
                ).encode()
                self.videoCaptureAdmission.withEncoder(capture: capture, encoder: outputAdmission) {
                    if let configData { self.sendBinaryPacket?(accessUnit.windowId, configData) }
                    self.sendBinaryPacket?(accessUnit.windowId, frameData)
                    self.noteHostPipelineFrameForDiagnostics(.send, windowId: accessUnit.windowId)
                    self.noteEncodedFrameForDiagnostics()
                }

//                if accessUnit.isKeyframe {
//                    self.sendJSONLine?(HostStreamDebugMessage(
//                        windowId: accessUnit.windowId,
//                        stage: "host_video_keyframe_sent",
//                        detail: "bytes=\(accessUnit.payload.count)"
//                    ))
//                }
            }

//            fresh.onDebug = { [weak self] windowId, stage, detail in
//                self?.streamDebug(windowId: windowId, stage: stage, detail: detail)
//            }
            
            videoEncoderByWindow[windowId] = fresh
            videoEncoderCaptureByWindow[windowId] = capture
            videoEncoderAdmissionByWindow[windowId] = outputAdmission
            videoEncoderSettingsByWindow[windowId] = (bitRate, fps)
            encoder = fresh
            shouldForceKeyframe = true
        }

//        streamDebug(
//            windowId: windowId,
//            stage: "host_encoder_encode_enqueued",
//            detail: shouldForceKeyframe ? "keyframe" : nil
//        )
        encoder.encodeAsync(sampleBuffer: sampleBuffer, forceKeyframe: shouldForceKeyframe)

        scheduleWindowGeometryUpdate(windowId: windowId, capturePxW: width, capturePxH: height)
    }

    private func resetDiagnosticsCounters() {
        diagnosticsQueue.async { [weak self] in
            guard let self else { return }
            self.diagnosticsActiveStreamCount = 0
            self.diagnosticsDroppedRawFrames = 0
            self.diagnosticsEncodedFrames = 0
            self.diagnosticsSentFrames = 0
            self.diagnosticsEncodeInFlightCount = 0
            self.diagnosticsPipelineFrameCounts.removeAll()
            self.diagnosticsLastPipelineFrameAtByStageWindow.removeAll()
            self.lastStreamerDiagnosticsFlushAt = CFAbsoluteTimeGetCurrent()

            let diagnostics = self.streamDiagnostics
            Task { @MainActor in
                diagnostics?.activeStreamCount = 0
                diagnostics?.droppedRawFramesPerSecond = 0
                diagnostics?.encodedFramesPerSecond = 0
                diagnostics?.sentFramesPerSecond = 0
                diagnostics?.encodeInFlightCount = 0
                diagnostics?.hostPipelineSummary = "SCK -- | Sub -- | Out -- | Send -- | Drop --"
            }
        }
    }

    private func noteActiveStreamCountForDiagnostics(_ count: Int) {
        diagnosticsQueue.async { [weak self] in
            guard let self else { return }
            self.diagnosticsActiveStreamCount = count

            let diagnostics = self.streamDiagnostics
            Task { @MainActor in
                diagnostics?.activeStreamCount = count
            }
        }
    }

    private func noteHostPipelineFrameForDiagnostics(_ stage: HostPipelineStage, windowId: UInt32) {
        let now = CFAbsoluteTimeGetCurrent()
        diagnosticsQueue.async { [weak self] in
            guard let self else { return }

            var accumulator = self.diagnosticsPipelineFrameCounts[stage] ?? HostPipelineAccumulator()
            accumulator.frames += 1

            let key = "\(stage.rawValue):\(windowId)"
            if let lastAt = self.diagnosticsLastPipelineFrameAtByStageWindow[key] {
                let intervalMs = max(0, (now - lastAt) * 1000.0)
                accumulator.intervals += 1
                accumulator.totalIntervalMs += intervalMs
                accumulator.maxIntervalMs = max(accumulator.maxIntervalMs, intervalMs)
            }

            self.diagnosticsLastPipelineFrameAtByStageWindow[key] = now
            self.diagnosticsPipelineFrameCounts[stage] = accumulator
            self.flushStreamerDiagnosticsIfNeeded_locked()
        }
    }

    private func noteDroppedRawFrameForDiagnostics() {
        diagnosticsQueue.async { [weak self] in
            guard let self else { return }
            self.diagnosticsDroppedRawFrames += 1
            self.flushStreamerDiagnosticsIfNeeded_locked()
        }
    }

    private func noteEncodedFrameForDiagnostics() {
        diagnosticsQueue.async { [weak self] in
            guard let self else { return }
            self.diagnosticsEncodedFrames += 1
            self.diagnosticsSentFrames += 1
            self.flushStreamerDiagnosticsIfNeeded_locked()
        }
    }

    private func noteEncodeInFlightForDiagnostics(_ count: Int) {
        diagnosticsQueue.async { [weak self] in
            guard let self else { return }
            self.diagnosticsEncodeInFlightCount = max(0, count)
            self.flushStreamerDiagnosticsIfNeeded_locked()
        }
    }

    private func flushStreamerDiagnosticsIfNeeded_locked() {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastStreamerDiagnosticsFlushAt
        guard elapsed >= 1.0 else { return }

        let divisor = max(0.001, elapsed)
        let activeCount = diagnosticsActiveStreamCount
        let dropped = Int((Double(diagnosticsDroppedRawFrames) / divisor).rounded())
        let encoded = Int((Double(diagnosticsEncodedFrames) / divisor).rounded())
        let sent = Int((Double(diagnosticsSentFrames) / divisor).rounded())
        let encodeInFlight = diagnosticsEncodeInFlightCount

        func stageText(_ stage: HostPipelineStage) -> String {
            let accumulator = diagnosticsPipelineFrameCounts[stage] ?? HostPipelineAccumulator()
            let fps = Double(accumulator.frames) / divisor
            let avgMs = accumulator.intervals > 0
                ? accumulator.totalIntervalMs / Double(accumulator.intervals)
                : 0.0
            let maxMs = accumulator.maxIntervalMs

            if accumulator.frames == 0 {
                return "\(stage.rawValue) --"
            }

            return String(
                format: "\(stage.rawValue) %.0ff %.1f/%.1fms",
                fps,
                avgMs,
                maxMs
            )
        }

        let pipelineSummary = [
            stageText(.sck),
            stageText(.encodeSubmit),
            stageText(.encodeOutput),
            stageText(.send),
            "Drop \(dropped)f"
        ].joined(separator: " | ")

        print("PeelHostPipeline \(pipelineSummary)")

        diagnosticsDroppedRawFrames = 0
        diagnosticsEncodedFrames = 0
        diagnosticsSentFrames = 0
        diagnosticsPipelineFrameCounts.removeAll()
        lastStreamerDiagnosticsFlushAt = now

        let diagnostics = streamDiagnostics
        Task { @MainActor in
            diagnostics?.activeStreamCount = activeCount
            diagnostics?.droppedRawFramesPerSecond = dropped
            diagnostics?.encodedFramesPerSecond = encoded
            diagnostics?.sentFramesPerSecond = sent
            diagnostics?.encodeInFlightCount = encodeInFlight
            diagnostics?.hostPipelineSummary = pipelineSummary
        }
    }

    private func currentJPEGQuality(for windowId: UInt32, initial: Double) -> Double {
        jpegQualityByWindow[windowId] ?? initial
    }

    private func updateJPEGQuality(
        for windowId: UInt32,
        encodedBytes: Int,
        targetBytes: Int,
        qMin: Double,
        qMax: Double,
        initial: Double
    ) {
        let oldQ = currentJPEGQuality(for: windowId, initial: initial)
        guard encodedBytes > 0 else {
            jpegQualityByWindow[windowId] = oldQ
            return
        }

        let ratio = Double(targetBytes) / Double(encodedBytes)
        let adjusted = oldQ * pow(ratio, 0.5)
        let clamped = min(qMax, max(qMin, adjusted))
        let smoothed = (oldQ * 0.75) + (clamped * 0.25)
        jpegQualityByWindow[windowId] = smoothed
    }

    private func maybeSendWindowGeometry(windowId: UInt32, capturePxW: Int?, capturePxH: Int?) {
        guard let bounds = WindowEnumerator.bounds(for: windowId) else { return }
        sendWindowGeometryIfNeeded_locked(windowId: windowId, bounds: bounds, capturePxW: capturePxW, capturePxH: capturePxH)
    }

    private func scheduleWindowGeometryUpdate(windowId: UInt32, capturePxW: Int?, capturePxH: Int?) {
        captureQueue.async { [weak self] in
            guard let self else { return }

            let now = CFAbsoluteTimeGetCurrent()
            let lastSentAt = self.lastSentGeometryAt[windowId] ?? 0
            let lastScheduledAt = self.lastGeometryLookupScheduledAt[windowId] ?? 0

            guard (now - lastSentAt) >= self.geometryResendInterval else { return }
            guard (now - lastScheduledAt) >= self.geometryResendInterval else { return }
            guard !self.geometryLookupInFlight.contains(windowId) else { return }

            self.geometryLookupInFlight.insert(windowId)
            self.lastGeometryLookupScheduledAt[windowId] = now

            self.geometryQueue.async { [weak self] in
                let bounds = WindowEnumerator.bounds(for: windowId)

                self?.captureQueue.async { [weak self] in
                    guard let self else { return }
                    self.geometryLookupInFlight.remove(windowId)

                    guard let bounds else { return }
                    self.sendWindowGeometryIfNeeded_locked(
                        windowId: windowId,
                        bounds: bounds,
                        capturePxW: capturePxW,
                        capturePxH: capturePxH
                    )
                }
            }
        }
    }

    private func sendWindowGeometryIfNeeded_locked(windowId: UInt32, bounds: CGRect, capturePxW: Int?, capturePxH: Int?) {
        let now = CFAbsoluteTimeGetCurrent()
        let lastBounds = lastSentGeometry[windowId]
        let lastAt = lastSentGeometryAt[windowId] ?? 0

        let changed: Bool
        if let lastBounds {
            changed = !approximatelyEqual(bounds, lastBounds)
        } else {
            changed = true
        }

        let stale = (now - lastAt) >= geometryResendInterval
        guard changed || stale else { return }

        lastSentGeometry[windowId] = bounds
        lastSentGeometryAt[windowId] = now

        let msg = WindowGeometryMessage(
            windowId: windowId,
            bounds: bounds,
            inset: .zero,
            capturePx: (capturePxW != nil && capturePxH != nil) ? CGSize(width: capturePxW!, height: capturePxH!) : nil,
            origin: "topLeft"
        )

        sendJSONLine?(msg)
    }

    private func approximatelyEqual(_ a: CGRect, _ b: CGRect, eps: CGFloat = 0.5) -> Bool {
        abs(a.origin.x - b.origin.x) <= eps &&
        abs(a.origin.y - b.origin.y) <= eps &&
        abs(a.size.width - b.size.width) <= eps &&
        abs(a.size.height - b.size.height) <= eps
    }

    private func scalerCache(for windowId: UInt32) -> WindowFrameScalerCache {
        if let existing = scalerCacheByWindow[windowId] { return existing }
        let fresh = WindowFrameScalerCache()
        scalerCacheByWindow[windowId] = fresh
        return fresh
    }

    private func jpegEncodeCache(for windowId: UInt32) -> WindowJPEGEncodeCache {
        if let existing = jpegEncodeCacheByWindow[windowId] { return existing }
        let fresh = WindowJPEGEncodeCache()
        jpegEncodeCacheByWindow[windowId] = fresh
        return fresh
    }
    
//    private func streamDebug(windowId: UInt32, stage: String, detail: String? = nil) {
//        sendJSONLine?(HostStreamDebugMessage(windowId: windowId, stage: stage, detail: detail))
//    }
    
    private func retireVideoEncoder_locked(windowId: UInt32, capture: PeelVideoCaptureToken?, endCapture: Bool = false) {
        if let capture { guard videoEncoderCaptureByWindow[windowId] == capture else { return } }
        else if videoEncoderCaptureByWindow[windowId] != nil { return }
        let oldCapture = videoEncoderCaptureByWindow.removeValue(forKey: windowId)
        let oldAdmission = videoEncoderAdmissionByWindow.removeValue(forKey: windowId)
        if let oldCapture, let oldAdmission {
            videoCaptureAdmission.retireEncoder(capture: oldCapture, encoder: oldAdmission)
        }
        let encoder = videoEncoderByWindow.removeValue(forKey: windowId)
        videoEncoderSettingsByWindow.removeValue(forKey: windowId)
        if endCapture {
            preferredVideoCodecByWindow.removeValue(forKey: windowId)
            forceKeyframeAfterBackpressureWindowIds.remove(windowId)
            lastRecoveryKeyframeRequest.removeValue(forKey: windowId)
        }
        encoder?.invalidateAsync()
    }

    private func retireVideoCaptureState_locked(windowId: UInt32, capture: PeelVideoCaptureToken?) {
        if let capture { guard activeVideoCaptureByWindow[windowId] == capture else { return } }
        else if activeVideoCaptureByWindow[windowId] != nil { return }
        activeVideoCaptureByWindow.removeValue(forKey: windowId)
        activeVideoWindowIds.remove(windowId)
        nativeVideoRequests.removeValue(forKey: windowId)
        // Revoked epochs never become current again, so a late cleanup can
        // drop only its own retired opt-in, never a successor request's.
        if let cursorRequest = nativeCursorRequests[windowId],
           !videoCaptureAdmission.isCurrent(cursorRequest) {
            nativeCursorRequests.removeValue(forKey: windowId)
        }
        reportedCursorModes.removeValue(forKey: windowId)
        reportedVideoPolicies.removeValue(forKey: windowId)
        removeVideoPolicy(windowId: windowId)
        refreshActiveVideoStreamPolicies_locked()
        if lastClientActiveVideoWindowId == windowId { lastClientActiveVideoWindowId = nil }
        noteActiveStreamCountForDiagnostics(activeVideoWindowIds.count)
        lastSentGeometry.removeValue(forKey: windowId)
        lastSentGeometryAt.removeValue(forKey: windowId)
        lastEffectiveCaptureModeByWindow.removeValue(forKey: windowId)
        lastCompositedFocusKickAtByWindow.removeValue(forKey: windowId)
        lastInputAtByWindow.removeValue(forKey: windowId)
        geometryLookupInFlight.remove(windowId)
        lastGeometryLookupScheduledAt.removeValue(forKey: windowId)
    }

    func stopStreaming(windowId: UInt32) {
        videoCaptureAdmission.revoke(windowId: windowId) { capture in
            latestVideoSampleQueue.remove(windowId: windowId, capture: capture)
            captureQueue.async {
                if #available(macOS 13.0, *), let capture {
                    self.sckVideoBridge.stopStreaming(windowId: windowId, ifCurrentCapture: capture)
                }
                self.retireVideoCaptureState_locked(windowId: windowId, capture: capture)
            }
            videoFrameQueue.async {
                self.retireVideoEncoder_locked(windowId: windowId, capture: capture, endCapture: true)
            }
        }
    }

}

/// ScreenCaptureKit Started frames are usable too; readiness alone does not
/// imply that a screen sample owns an image. Reject before mailbox replacement.
nonisolated enum PeelScreenSampleAdmission {
    static func isUsable(_ sampleBuffer: CMSampleBuffer) -> Bool {
        CMSampleBufferDataIsReady(sampleBuffer) && CMSampleBufferGetImageBuffer(sampleBuffer) != nil
    }
}

/// A CMBlockBuffer may consist of separately backed blocks. The fast pointer is
/// safe only for its reported contiguous range; the checked copy spans blocks.
nonisolated enum PeelEncodedPayloadCopy {
    static func copy(_ blockBuffer: CMBlockBuffer) -> Data? {
        let totalLength = CMBlockBufferGetDataLength(blockBuffer)
        guard totalLength > 0 else { return nil }
        var contiguousLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0,
            lengthAtOffsetOut: &contiguousLength, totalLengthOut: nil, dataPointerOut: &dataPointer)
        if status == kCMBlockBufferNoErr, contiguousLength >= totalLength, let dataPointer {
            return Data(bytes: dataPointer, count: totalLength)
        }
        var data = Data(count: totalLength)
        let copyStatus = data.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: totalLength,
                                      destination: bytes.baseAddress!)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }
        return data
    }
}

private final class WindowJPEGEncodeCache {
    let data: CFMutableData = CFDataCreateMutable(nil, 0)!
    func reset() { CFDataSetLength(data, 0) }
}

private enum VideoColorMetadata {
    static func applyRec709FullRange(to pixelBuffer: CVPixelBuffer) {
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            .shouldPropagate
        )
    }
}

private final class WindowFrameScalerCache {
    private(set) var width: Int = 0
    private(set) var height: Int = 0
    private var destData: UnsafeMutableRawPointer?
    private var destRowBytes: Int = 0
    private var tempData: UnsafeMutableRawPointer?
    private var tempSize: Int = 0

    private let colorSpace: CGColorSpace = CGColorSpaceCreateDeviceRGB()
    private lazy var format: vImage_CGImageFormat = {
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        return vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            colorSpace: Unmanaged.passRetained(colorSpace),
            bitmapInfo: bitmapInfo,
            version: 0,
            decode: nil,
            renderingIntent: .defaultIntent
        )
    }()

    deinit {
        if let destData { free(destData) }
        if let tempData { free(tempData) }
        if let cs = format.colorSpace { cs.release() }
    }

    func ensureDestination(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        if self.width == width, self.height == height, destData != nil { return }

        if let destData { free(destData) }
        self.width = width
        self.height = height
        self.destRowBytes = width * 4
        self.destData = malloc(height * destRowBytes)
    }

    func ensureTempBuffer(minimumBytes: Int) {
        guard minimumBytes > 0 else { return }
        if tempSize >= minimumBytes, tempData != nil { return }
        if let tempData { free(tempData) }
        tempSize = minimumBytes
        tempData = malloc(minimumBytes)
    }

    func scale(cgImage: CGImage, targetW: Int, targetH: Int) -> CGImage? {
        if cgImage.width == targetW, cgImage.height == targetH {
            return cgImage
        }

        var error = kvImageNoError
        var src = vImage_Buffer()
        error = vImageBuffer_InitWithCGImage(&src, &format, nil, cgImage, vImage_Flags(kvImageNoFlags))
        guard error == kvImageNoError else { return nil }
        defer { free(src.data) }

        ensureDestination(width: targetW, height: targetH)
        guard let destData else { return nil }

        var dst = vImage_Buffer(
            data: destData,
            height: vImagePixelCount(targetH),
            width: vImagePixelCount(targetW),
            rowBytes: destRowBytes
        )

        let tempReq = vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageGetTempBufferSize))
        if tempReq > 0 {
            ensureTempBuffer(minimumBytes: Int(tempReq))
        }

        let scaleErr = vImageScale_ARGB8888(&src, &dst, tempData, vImage_Flags(kvImageNoFlags))
        guard scaleErr == kvImageNoError else { return nil }

        var createErr: vImage_Error = kvImageNoError
        guard let cg = vImageCreateCGImageFromBuffer(
            &dst,
            &format,
            { _, _ in },
            nil,
            vImage_Flags(kvImageNoFlags),
            &createErr
        ), createErr == kvImageNoError else {
            return nil
        }

        return cg.takeRetainedValue()
    }
}

@available(macOS 13.0, *)
private final class SCKVideoBridge: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Descriptor: Equatable {
        let scale: Double
        let preferredFPS: Int
        let showsCursor: Bool
        var nativeFramePixelLimit: Int? = nil
    }

    var onSampleBuffer: ((UInt32, PeelVideoCaptureToken, CMSampleBuffer) -> Void)?
    var onStop: ((UInt32, PeelVideoCaptureToken, Error?) -> Void)?

    private struct Entry {
        let capture: PeelVideoCaptureToken
        let stream: SCStream
        let filter: SCContentFilter
        var descriptor: Descriptor
    }

    private struct PendingStart {
        let capture: PeelVideoCaptureToken
        let generation: UInt64
        var stream: SCStream?
        let descriptor: Descriptor
    }

    private var entriesByWindow: [UInt32: Entry] = [:]
    private var pendingStartsByWindow: [UInt32: PendingStart] = [:]
    private var updatingWindowIds: Set<UInt32> = []
    private var requestedDescriptorsByWindow: [UInt32: Descriptor] = [:]
    private struct StreamContext {
        let windowId: UInt32
        let capture: PeelVideoCaptureToken
    }
    private var windowByStreamIdentity: [ObjectIdentifier: StreamContext] = [:]
    private var nextStartGeneration: UInt64 = 0

    private let startCaptureTimeout: TimeInterval = 10.0
    private let lock = NSLock()
    private let sampleQueue = DispatchQueue(label: "peel.sck.video.samples", qos: .userInitiated)

    private func nextStartGeneration_locked() -> UInt64 {
        nextStartGeneration &+= 1
        return nextStartGeneration
    }

    func ensureStreaming(windowId: UInt32, capture: PeelVideoCaptureToken, descriptor: Descriptor) {
        lock.lock()
        // A replacement capture cannot inherit an old stream or pending start.
        if let oldCapture = entriesByWindow[windowId]?.capture ?? pendingStartsByWindow[windowId]?.capture,
           oldCapture != capture {
            lock.unlock()
            stopStreaming(windowId: windowId, ifCurrentCapture: oldCapture)
            ensureStreaming(windowId: windowId, capture: capture, descriptor: descriptor)
            return
        }
        requestedDescriptorsByWindow[windowId] = descriptor

        if let entry = entriesByWindow[windowId] {
            let shouldUpdate = entry.descriptor != descriptor && !updatingWindowIds.contains(windowId)

            if shouldUpdate {
                updatingWindowIds.insert(windowId)
            }

            lock.unlock()

            guard shouldUpdate else { return }

            Task {
                await updateStream(windowId: windowId, entry: entry, descriptor: descriptor)
            }
            return
        }

        if pendingStartsByWindow[windowId] != nil {
            lock.unlock()
            return
        }

        let generation = nextStartGeneration_locked()
        pendingStartsByWindow[windowId] = PendingStart(
            capture: capture,
            generation: generation,
            stream: nil,
            descriptor: descriptor
        )

        lock.unlock()

        Task {
            await startStream(windowId: windowId, capture: capture, descriptor: descriptor, generation: generation)
        }

        scheduleStartCaptureTimeout(windowId: windowId, generation: generation)
    }

    func stopAll() {
        let entries: [Entry]
        let pendingStreams: [SCStream]

        lock.lock()
        entries = Array(entriesByWindow.values)
        pendingStreams = pendingStartsByWindow.values.compactMap(\.stream)

        entriesByWindow.removeAll()
        pendingStartsByWindow.removeAll()
        updatingWindowIds.removeAll()
        requestedDescriptorsByWindow.removeAll()
        windowByStreamIdentity.removeAll()
        lock.unlock()

        Task {
            for entry in entries {
                try? await entry.stream.stopCapture()
            }

            for stream in pendingStreams {
                try? await stream.stopCapture()
            }
        }
    }

    private func scheduleStartCaptureTimeout(windowId: UInt32, generation: UInt64) {
        let nanoseconds = UInt64(startCaptureTimeout * 1_000_000_000)

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            self?.expireStartCaptureIfNeeded(windowId: windowId, generation: generation)
        }
    }

    private func expireStartCaptureIfNeeded(windowId: UInt32, generation: UInt64) {
        let stream: SCStream?

        lock.lock()

        if let pending = pendingStartsByWindow[windowId],
           pending.generation == generation {
            stream = pending.stream
            pendingStartsByWindow.removeValue(forKey: windowId)

            if let stream {
                windowByStreamIdentity.removeValue(forKey: ObjectIdentifier(stream))
            }
        } else {
            stream = nil
        }

        lock.unlock()

        if let stream {
            Task {
                try? await stream.stopCapture()
            }
        }
    }

    private func updateStream(windowId: UInt32, entry: Entry, descriptor: Descriptor) async {
        let config = makeConfiguration(
            windowId: windowId,
            descriptor: descriptor,
            filter: entry.filter
        )

        do {
            try await entry.stream.updateConfiguration(config)

            var followUpEntry: Entry?
            var followUpDescriptor: Descriptor?

            lock.lock()
            if var current = entriesByWindow[windowId], current.stream === entry.stream {
                current.descriptor = descriptor
                entriesByWindow[windowId] = current

                if let requested = requestedDescriptorsByWindow[windowId], requested != descriptor {
                    followUpEntry = current
                    followUpDescriptor = requested
                    updatingWindowIds.insert(windowId)
                }
            }

            if followUpDescriptor == nil, entriesByWindow[windowId]?.stream === entry.stream {
                updatingWindowIds.remove(windowId)
            }
            lock.unlock()

            if let followUpEntry, let followUpDescriptor {
                await updateStream(windowId: windowId, entry: followUpEntry, descriptor: followUpDescriptor)
            }
        } catch {
            lock.lock()
            let isCurrentEntry = entriesByWindow[windowId]?.stream === entry.stream
            if isCurrentEntry { updatingWindowIds.remove(windowId) }
            lock.unlock()
            guard isCurrentEntry else { return }

            print("PeelHost: failed to update video stream config for \(windowId): \(error.localizedDescription)")
            if entry.descriptor.nativeFramePixelLimit != nil {
                // A failed downgrade must not leave the experimental capture
                // running indefinitely. Stop only this entry, never a replacement.
                // Removing its identity also rejects subsequent sample callbacks.
                if let stoppedCapture = stopStreaming(windowId: windowId,
                        ifCurrentStream: entry.stream, ifCurrentCapture: entry.capture) {
                    onStop?(windowId, stoppedCapture, error)
                }
            }
        }
    }


    private func makeConfiguration(
        windowId: UInt32,
        descriptor: Descriptor,
        filter: SCContentFilter? = nil
    ) -> SCStreamConfiguration {
        let sourceWidth: Int
        let sourceHeight: Int

        if let filter {
            let pixelScale = CGFloat(max(1.0, Double(filter.pointPixelScale)))
            sourceWidth = max(1, Int((filter.contentRect.width * pixelScale).rounded(.toNearestOrAwayFromZero)))
            sourceHeight = max(1, Int((filter.contentRect.height * pixelScale).rounded(.toNearestOrAwayFromZero)))
        } else {
            let bounds = WindowEnumerator.bounds(for: windowId) ?? CGRect(x: 0, y: 0, width: 1280, height: 720)
            sourceWidth = max(1, Int(bounds.width.rounded(.toNearestOrAwayFromZero)))
            sourceHeight = max(1, Int(bounds.height.rounded(.toNearestOrAwayFromZero)))
        }

        let dimensions: (width: Int, height: Int)
        if let limit = descriptor.nativeFramePixelLimit {
            dimensions = PeelPixelBudget.nativeExperimentDimensions(sourceWidth: sourceWidth,
                sourceHeight: sourceHeight, scale: descriptor.scale, maximumPixels: limit)
        } else {
            dimensions = PeelPixelBudget.dimensions(sourceWidth: sourceWidth,
                sourceHeight: sourceHeight, scale: descriptor.scale, forceEvenDimensions: true)
        }

        let config = SCStreamConfiguration()
        config.width = dimensions.width
        config.height = dimensions.height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, descriptor.preferredFPS)))
        config.queueDepth = 3
        config.showsCursor = descriptor.showsCursor
        return config
    }

    private func targetWindow(for windowId: UInt32, in content: SCShareableContent) throws -> SCWindow {
        if let target = content.windows.first(where: { $0.windowID == windowId }) {
            return target
        }

        throw NSError(
            domain: "Peel.SCKVideoBridge",
            code: 404,
            userInfo: [NSLocalizedDescriptionKey: "No SCWindow found for CGWindowID \(windowId)"]
        )
    }

    private func targetDisplay(forDisplayCaptureWindowId windowId: UInt32, in content: SCShareableContent) throws -> SCDisplay {
        guard let displayId = WindowEnumerator.displayCaptureDisplayId(for: windowId) else {
            throw NSError(
                domain: "Peel.SCKVideoBridge",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "No display mapping found for synthetic windowId \(windowId)"]
            )
        }

        if let target = content.displays.first(where: { $0.displayID == displayId }) {
            return target
        }

        throw NSError(
            domain: "Peel.SCKVideoBridge",
            code: 404,
            userInfo: [NSLocalizedDescriptionKey: "No SCDisplay found for displayID \(displayId)"]
        )
    }

    private func startStream(windowId: UInt32, capture: PeelVideoCaptureToken, descriptor: Descriptor, generation: UInt64) async {
        var createdStream: SCStream?
        var createdStreamIdentity: ObjectIdentifier?

        do {
            let content = try await SCShareableContent.current
            let isDisplayCapture = WindowEnumerator.isDisplayCaptureWindowId(windowId)

            let filter: SCContentFilter

            if isDisplayCapture {
                let display = try targetDisplay(forDisplayCaptureWindowId: windowId, in: content)
                filter = SCContentFilter(
                    display: display,
                    excludingApplications: [],
                    exceptingWindows: []
                )
            } else {
                let window = try targetWindow(for: windowId, in: content)
                filter = SCContentFilter(desktopIndependentWindow: window)
            }

            let config = makeConfiguration(
                windowId: windowId,
                descriptor: descriptor,
                filter: filter
            )

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            let streamIdentity = ObjectIdentifier(stream)

            createdStream = stream
            createdStreamIdentity = streamIdentity

            lock.lock()
            guard let pending = pendingStartsByWindow[windowId],
                  pending.generation == generation, pending.capture == capture else {
                lock.unlock()
                try? await stream.stopCapture()
                return
            }

            var updatedPending = pending
            updatedPending.stream = stream
            pendingStartsByWindow[windowId] = updatedPending
            windowByStreamIdentity[streamIdentity] = StreamContext(windowId: windowId, capture: capture)
            lock.unlock()

            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()

            lock.lock()
            guard let pending = pendingStartsByWindow[windowId],
                  pending.generation == generation, pending.capture == capture,
                  let pendingStream = pending.stream,
                  ObjectIdentifier(pendingStream) == streamIdentity else {
                windowByStreamIdentity.removeValue(forKey: streamIdentity)
                lock.unlock()

                try? await stream.stopCapture()
                return
            }

            pendingStartsByWindow.removeValue(forKey: windowId)
            let entry = Entry(capture: capture, stream: stream, filter: filter, descriptor: descriptor)
            entriesByWindow[windowId] = entry
            windowByStreamIdentity[streamIdentity] = StreamContext(windowId: windowId, capture: capture)
            let followUpDescriptor = requestedDescriptorsByWindow[windowId]
            let needsFollowUpUpdate = followUpDescriptor != nil && followUpDescriptor != descriptor
            if needsFollowUpUpdate {
                updatingWindowIds.insert(windowId)
            }
            lock.unlock()
            if needsFollowUpUpdate, let followUpDescriptor {
                await updateStream(windowId: windowId, entry: entry, descriptor: followUpDescriptor)
            }
        } catch {
            let shouldNotifyStop: Bool

            lock.lock()

            if let pending = pendingStartsByWindow[windowId],
               pending.generation == generation, pending.capture == capture {
                shouldNotifyStop = true
                pendingStartsByWindow.removeValue(forKey: windowId)
            } else {
                shouldNotifyStop = false
            }

            if let createdStreamIdentity {
                windowByStreamIdentity.removeValue(forKey: createdStreamIdentity)
            }

            if let createdStream,
               let currentEntry = entriesByWindow[windowId],
               currentEntry.stream === createdStream {
                entriesByWindow.removeValue(forKey: windowId)
            }

            if shouldNotifyStop {
                updatingWindowIds.remove(windowId)
                requestedDescriptorsByWindow.removeValue(forKey: windowId)
            }
            lock.unlock()

            if let createdStream {
                try? await createdStream.stopCapture()
            }

            if shouldNotifyStop {
                onStop?(windowId, capture, error)
            }
        }
    }
    


    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        let identity = ObjectIdentifier(stream)
        let context = windowByStreamIdentity.removeValue(forKey: identity)
        if let context {
            let windowId = context.windowId
            var removedCurrent = false
            if let entry = entriesByWindow[windowId], entry.capture == context.capture,
               entry.stream === stream {
                entriesByWindow.removeValue(forKey: windowId)
                removedCurrent = true
            }
            if let pending = pendingStartsByWindow[windowId], pending.capture == context.capture,
               pending.stream === stream {
                pendingStartsByWindow.removeValue(forKey: windowId)
                removedCurrent = true
            }
            if removedCurrent {
                updatingWindowIds.remove(windowId)
                requestedDescriptorsByWindow.removeValue(forKey: windowId)
            }
        }
        lock.unlock()
        if let context { onStop?(context.windowId, context.capture, error) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen else { return }
        lock.lock()
        let context = windowByStreamIdentity[ObjectIdentifier(stream)]
        lock.unlock()
        guard let context else { return }
        // Stop may race after lookup; the receiver checks this exact capture,
        // rather than treating a later stream for the same window as authority.
        onSampleBuffer?(context.windowId, context.capture, sampleBuffer)
    }

    @discardableResult
    func stopStreaming(windowId: UInt32, ifCurrentStream expectedStream: SCStream? = nil,
                       ifCurrentCapture expectedCapture: PeelVideoCaptureToken? = nil) -> PeelVideoCaptureToken? {
        lock.lock()
        let currentCapture = entriesByWindow[windowId]?.capture ?? pendingStartsByWindow[windowId]?.capture
        if let expectedCapture, currentCapture != expectedCapture {
            lock.unlock()
            return nil
        }
        if let expectedStream, entriesByWindow[windowId]?.stream !== expectedStream {
            lock.unlock()
            return nil
        }
        let entry = entriesByWindow.removeValue(forKey: windowId)
        let pendingStream = pendingStartsByWindow.removeValue(forKey: windowId)?.stream
        updatingWindowIds.remove(windowId)
        requestedDescriptorsByWindow.removeValue(forKey: windowId)
        if let stream = entry?.stream { windowByStreamIdentity.removeValue(forKey: ObjectIdentifier(stream)) }
        if let pendingStream { windowByStreamIdentity.removeValue(forKey: ObjectIdentifier(pendingStream)) }
        lock.unlock()
        Task {
            if let entry { try? await entry.stream.stopCapture() }
            if let pendingStream { try? await pendingStream.stopCapture() }
        }
        return currentCapture
    }
}

private final class VideoH264Encoder {
    private enum SessionMode {
        case lowLatency
        case legacy
    }

    struct EncodedAccessUnit {
        let windowId: UInt32
        let codec: PeelVideoCodec
        let width: Int
        let height: Int
        let isKeyframe: Bool
        let pts: CMTime
        let duration: CMTime
        let payload: Data
        let vps: Data?
        let sps: Data?
        let pps: Data?
        let nalUnitHeaderLength: Int32
    }

    var onOutput: ((EncodedAccessUnit) -> Void)?
    var onInFlightCountChanged: ((Int) -> Void)?
    var onEncodeSubmit: ((UInt32) -> Void)?
    var onEncodeOutput: ((UInt32) -> Void)?
//    var onDebug: ((UInt32, String, String?) -> Void)?

    private let windowId: UInt32
    private(set) var width: Int
    private(set) var height: Int
    private var bitRate: Int
    private var fps: Int
    private var activeCodec: PeelVideoCodec
    private var session: VTCompressionSession?
    private var sessionMode: SessionMode?
    private var sessionRetainedSelf: Unmanaged<VideoH264Encoder>?
    private var recovery: PeelVideoEncoderRecovery
    private var needsForcedKeyframe = true
    private var lastKeyframeOutputUptime: TimeInterval?
    private let periodicKeyframeInterval: TimeInterval = 2.0
    private var lastSentConfigSignature: String?
    private var encodeInFlightCount: Int = 0
    private let maxEncodeInFlightCount: Int = 1
    private var pendingSampleBuffer: CMSampleBuffer?
    private var pendingForceKeyframe: Bool = false
    private var encodeSequence: UInt64 = 0
    private let encodeWatchdogInterval: TimeInterval = 0.75
    private var isInvalidated: Bool = false
    private let callbackQueue: DispatchQueue
    private let inputMailbox = VideoEncoderInputMailbox()
    private let teardownQueue: DispatchQueue
    private let diagnostics: PeelStreamingDiagnostics
    private let diagnosticToken: UUID?
    private var encodeSubmittedAt: TimeInterval?
    private var submittedForceKeyframe = false

    init(
        windowId: UInt32,
        width: Int,
        height: Int,
        bitRate: Int,
        fps: Int,
        preferredCodec: PeelVideoCodec,
        teardownQueue: DispatchQueue,
        diagnostics: PeelStreamingDiagnostics
    ) {
        self.windowId = windowId
        self.width = width
        self.height = height
        self.bitRate = bitRate
        self.fps = fps
        self.activeCodec = preferredCodec
        self.recovery = PeelVideoEncoderRecovery(prefersHEVC: preferredCodec == .hevc)
        self.callbackQueue = DispatchQueue(
            label: "peel.videoEncode.window.\(windowId).\(UUID().uuidString)",
            qos: .userInitiated
        )
        self.teardownQueue = teardownQueue
        self.diagnostics = diagnostics
        self.diagnosticToken = diagnostics.begin(windowID: windowId, width: width, height: height,
            targetFPS: fps, targetBitrate: bitRate, preferredCodec: preferredCodec == .hevc ? "hevc" : "h264")
    }


    func matches(width: Int, height: Int) -> Bool {
        self.width == width && self.height == height
    }

    func updateAsync(bitRate: Int, fps: Int) {
        callbackQueue.async { [weak self] in
            self?.update(bitRate: bitRate, fps: fps)
        }
    }

    func invalidateAsync() {
        // Stop retaining new raw frames even if session creation is currently
        // blocking the encoder queue. Its queued drain will become a no-op.
        inputMailbox.close()
        callbackQueue.async { [self] in
            invalidate()
        }
    }

    func encodeAsync(sampleBuffer: CMSampleBuffer, forceKeyframe: Bool) {
        guard let admission = inputMailbox.offer(sampleBuffer, forceKeyframe: forceKeyframe) else { return }
        if admission.replacedPending {
            diagnostics.replacedPending(windowID: windowId, token: diagnosticToken)
        }
        guard admission.shouldSchedule else { return }
        // Capture only the encoder. A slow VideoToolbox call must not retain a
        // separate full-resolution raw frame in every queued dispatch closure.
        callbackQueue.async { [weak self] in
            self?.drainInputMailbox()
        }
    }

    private func drainInputMailbox() {
        if let input = inputMailbox.take() {
            encode(sampleBuffer: input.sampleBuffer, forceKeyframe: input.forceKeyframe)
        }
        // Yield between passes so output callbacks, policy changes, watchdogs
        // and invalidation cannot be starved by incoming capture frames.
        if inputMailbox.finishDrain() {
            callbackQueue.async { [weak self] in
                self?.drainInputMailbox()
            }
        }
    }

    func update(bitRate: Int, fps: Int) {
        self.bitRate = bitRate
        self.fps = fps
        diagnostics.setPolicy(windowID: windowId, token: diagnosticToken, fps: fps, bitrate: bitRate)
        guard let session, let sessionMode else { return }
        if !applyProperties(to: session, mode: sessionMode), sessionMode == .lowLatency {
            resetSessionAfterEncodeFailure(reason: "low-latency property update")
        }
    }

    func invalidate() {
        inputMailbox.close()
        isInvalidated = true
        diagnostics.end(windowID: windowId, token: diagnosticToken)
        encodeSubmittedAt = nil
        submittedForceKeyframe = false
        onOutput = nil
        encodeInFlightCount = 0
        pendingSampleBuffer = nil
        pendingForceKeyframe = false
        onInFlightCountChanged?(0)
        onInFlightCountChanged = nil
        onEncodeSubmit = nil
        onEncodeOutput = nil
        encodeSequence &+= 1
        lastSentConfigSignature = nil

        let oldSession = session
        let oldRetainedSelf = sessionRetainedSelf
        session = nil
        sessionMode = nil
        sessionRetainedSelf = nil
        lastKeyframeOutputUptime = nil
        invalidateDetachedSession(oldSession, retainedSelf: oldRetainedSelf)
    }

    func encode(sampleBuffer: CMSampleBuffer, forceKeyframe: Bool) {
        guard !isInvalidated else {
//            onDebug?(windowId, "host_encoder_encode_after_invalidated", nil)
            return
        }

        if session == nil {
//            onDebug?(windowId, "host_encoder_create_session_before_encode", "\(width)x\(height)")
            createSession()
        }

        guard let session else {
//            onDebug?(windowId, "host_encoder_encode_no_session", nil)
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
//            onDebug?(windowId, "host_encoder_encode_no_pixelbuffer", nil)
            return
        }

        VideoColorMetadata.applyRec709FullRange(to: pixelBuffer)

        let now = ProcessInfo.processInfo.systemUptime
        let periodicKeyframeIsDue = sessionMode == .lowLatency && (
            lastKeyframeOutputUptime == nil ||
            now - (lastKeyframeOutputUptime ?? now) >= periodicKeyframeInterval
        )
        if encodeInFlightCount >= maxEncodeInFlightCount {
            if pendingSampleBuffer != nil {
                diagnostics.replacedPending(windowID: windowId, token: diagnosticToken)
            }
            pendingSampleBuffer = sampleBuffer
            // Preserve explicit caller/recovery intent. Recompute policy intent
            // only when this frame can submit, after the in-flight IDR completes.
            pendingForceKeyframe = pendingForceKeyframe || forceKeyframe
//            onDebug?(windowId, "host_encoder_encode_coalesced_backpressure", "inFlight=\(encodeInFlightCount)")
            return
        }

        let effectiveForceKeyframe = forceKeyframe || needsForcedKeyframe || periodicKeyframeIsDue
        submittedForceKeyframe = effectiveForceKeyframe
        encodeInFlightCount += 1
        onInFlightCountChanged?(encodeInFlightCount)
        encodeSequence &+= 1
        let currentEncodeSequence = encodeSequence
//        onDebug?(windowId, "host_encoder_encode_entered", forceKeyframe ? "keyframe inFlight=\(encodeInFlightCount)" : "inFlight=\(encodeInFlightCount)")
        scheduleEncodeWatchdog(sequence: currentEncodeSequence)

        var flags = VTEncodeInfoFlags()
        let frameProperties: CFDictionary? = effectiveForceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
            : nil

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        // Verify the actual SCK display timestamp against the PTS before using
        // that PTS with the negotiated Host media-clock bounds.
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]]
        let displayTicks = (attachments?.first?[.displayTime] as? NSNumber)?.uint64Value
        let displaySeconds = displayTicks.map { CMTimeGetSeconds(CMClockMakeHostTimeFromSystemUnits($0)) }
        let ptsSeconds = CMTimeGetSeconds(pts)
        let verified = displaySeconds.map { $0.isFinite && ptsSeconds.isFinite && abs($0 - ptsSeconds) <= 0.001 } ?? false
        diagnostics.noteSourceClock(windowID: windowId, token: diagnosticToken, verified: verified)

        onEncodeSubmit?(windowId)
        encodeSubmittedAt = ProcessInfo.processInfo.systemUptime
        diagnostics.submitted(windowID: windowId, token: diagnosticToken)

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: frameProperties,
            sourceFrameRefcon: UnsafeMutableRawPointer(bitPattern: UInt(currentEncodeSequence)),
            infoFlagsOut: &flags
        )

        if status == noErr, flags.contains(.frameDropped) {
            // VT may also report this terminal event through its callback.
            // Enqueue instead of recursively submitting pending frames inline.
            callbackQueue.async { [weak self] in
                self?.settleExplicitDrop(sequence: currentEncodeSequence)
            }
        } else if status != noErr {
            encodeInFlightCount = max(0, encodeInFlightCount - 1)
            onInFlightCountChanged?(encodeInFlightCount)
            encodeSequence &+= 1
            resetSessionAfterEncodeFailure(reason: "status=\(status)")
//            onDebug?(windowId, "host_encoder_encode_failed", "status=\(status)")
            print("PeelHost: VTCompressionSessionEncodeFrame failed with status \(status)")
        }
    }

    private func createSession() {
        guard !isInvalidated else { return }
        guard width.isMultiple(of: 2), height.isMultiple(of: 2) else {
//            onDebug?(windowId, "host_encoder_rejected_odd_dimensions", "\(width)x\(height)")
            return
        }

        while recovery.canAttempt(at: ProcessInfo.processInfo.systemUptime) {
            let candidate = recovery.candidate
            let mode: SessionMode = candidate == .h264Legacy ? .legacy : .lowLatency
            activeCodec = candidate == .hevcLowLatency ? .hevc : .h264
            if let created = makeSession(mode: mode, codec: activeCodec) {
                session = created.session
                sessionMode = mode
                sessionRetainedSelf = created.retainedSelf
                recordRecovery(state: "waitingForOutput")
                return
            }
            // Creation/configuration/preparation can be slow. Cooldown starts
            // after the failed attempt, not before the candidate burst.
            recovery.creationFailed(at: ProcessInfo.processInfo.systemUptime)
            recordRecovery(state: recovery.retryAfterUptime == nil ? "retrying" : "cooldown")
        }
    }

    private func recordRecovery(state: String) {
        diagnostics.setRecovery(windowID: windowId, token: diagnosticToken, state: state,
            nextCandidate: recovery.candidate.rawValue,
            consecutiveFailures: recovery.consecutiveRuntimeFailures,
            retryAfterUptime: recovery.retryAfterUptime)
    }

    private func makeSession(
        mode: SessionMode,
        codec: PeelVideoCodec
    ) -> (session: VTCompressionSession, retainedSelf: Unmanaged<VideoH264Encoder>)? {
        var newSession: VTCompressionSession?
        let retainedSelf = Unmanaged.passRetained(self)
        let encoderSpecification: CFDictionary? = mode == .lowLatency
            ? [
                kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String: true,
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
            ] as CFDictionary
            : nil
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: encoderSpecification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: VideoH264Encoder.outputCallback,
            refcon: retainedSelf.toOpaque(),
            compressionSessionOut: &newSession
        )

        guard status == noErr, let newSession else {
            diagnostics.sessionFailure(windowID: windowId, token: diagnosticToken,
                reason: "\(codec == .hevc ? "hevc" : "h264") \(mode) create status=\(status)")
            retainedSelf.release()
//            onDebug?(windowId, "host_encoder_create_failed", "status=\(status)")
            if mode == .legacy {
                print("PeelHost: VTCompressionSessionCreate failed with status \(status)")
            }
            return nil
        }

        if mode == .lowLatency {
            // Configure and prepare before inspecting the selected encoder. Some
            // hardware-only low-latency modes do not expose the inspection key.
            guard applyProperties(to: newSession, mode: mode, codec: codec) else {
                VTCompressionSessionInvalidate(newSession)
                retainedSelf.release()
                return nil
            }
            let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(newSession)
            guard prepareStatus == noErr else {
                diagnostics.sessionFailure(windowID: windowId, token: diagnosticToken,
                    reason: "\(codec == .hevc ? "hevc" : "h264") \(mode) prepare status=\(prepareStatus)")
                VTCompressionSessionInvalidate(newSession)
                retainedSelf.release()
                return nil
            }
        } else {
            _ = applyProperties(to: newSession, mode: mode, codec: codec)
            let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(newSession)
            if prepareStatus != noErr {
                diagnostics.sessionFailure(windowID: windowId, token: diagnosticToken,
                    reason: "h264 legacy prepare status=\(prepareStatus)")
                VTCompressionSessionInvalidate(newSession)
                retainedSelf.release()
                return nil
            }
        }

        var hardwareProperty: Unmanaged<CFTypeRef>?
        let hardwareStatus = VTSessionCopyProperty(newSession,
            key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
            allocator: nil, valueOut: &hardwareProperty)
        let hardwareValue = hardwareProperty?.takeRetainedValue() as? NSNumber
        let hardwareVerification = PeelVideoEncoderHardwarePolicy.verification(
            status: hardwareStatus, reportedHardware: hardwareValue?.boolValue,
            hardwareRequired: mode == .lowLatency)
        if mode == .lowLatency, hardwareVerification == .unavailable {
            diagnostics.sessionFailure(windowID: windowId, token: diagnosticToken,
                reason: "\(codec == .hevc ? "hevc" : "h264") \(mode) hardware verification status=\(hardwareStatus)")
            VTCompressionSessionInvalidate(newSession)
            retainedSelf.release()
            return nil
        }
        var encoderIDProperty: Unmanaged<CFTypeRef>?
        let encoderIDStatus = VTSessionCopyProperty(newSession,
            key: kVTCompressionPropertyKey_EncoderID, allocator: nil, valueOut: &encoderIDProperty)
        let encoderID = encoderIDProperty?.takeRetainedValue() as? String
        diagnostics.setEncoder(windowID: windowId, token: diagnosticToken,
            codec: codec == .hevc ? "hevc" : "h264",
            mode: mode == .lowLatency ? "lowLatency" : "legacy",
            hardwareAccelerated: hardwareVerification == .requiredAtCreation ? true
                : (hardwareStatus == noErr ? hardwareValue?.boolValue : nil),
            hardwareVerification: hardwareVerification.rawValue,
            encoderID: encoderIDStatus == noErr ? encoderID : nil)
        return (newSession, retainedSelf)
    }

    @discardableResult
    private func applyProperties(
        to session: VTCompressionSession,
        mode: SessionMode,
        codec: PeelVideoCodec? = nil
    ) -> Bool {
        if mode == .lowLatency {
            let codec = codec ?? activeCodec
            let bytesPerSecond = max(1, bitRate / 8)
            let limits: [NSNumber] = [NSNumber(value: bytesPerSecond * 2), NSNumber(value: 1)]
            let properties: [(CFString, CFTypeRef)] = [
                (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
                (
                    kVTCompressionPropertyKey_ProfileLevel,
                    codec == .hevc
                        ? kVTProfileLevel_HEVC_Main_AutoLevel
                        : kVTProfileLevel_H264_High_AutoLevel
                ),
                (kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2),
                (kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2),
                (kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
                (kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitRate)),
                (kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps)),
                (kVTCompressionPropertyKey_DataRateLimits, limits as CFArray)
            ]

            return properties.allSatisfy { key, value in
                let status = VTSessionSetProperty(session, key: key, value: value)
                if status != noErr {
                    diagnostics.sessionFailure(windowID: windowId, token: diagnosticToken,
                        reason: "\(codec == .hevc ? "hevc" : "h264") \(mode) \(key) status=\(status)")
                }
                return status == noErr
            }
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: NSNumber(value: 1))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_709_2)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TransferFunction, value: kCVImageBufferTransferFunction_ITU_R_709_2)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitRate))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: max(30, fps * 2)))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 2))
        let bytesPerSecond = max(1, bitRate / 8)
        let limits: [NSNumber] = [NSNumber(value: bytesPerSecond * 2), NSNumber(value: 1)]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits as CFArray)
        return true
    }

    private func scheduleEncodeWatchdog(sequence: UInt64) {
        callbackQueue.asyncAfter(deadline: .now() + encodeWatchdogInterval) { [weak self] in
            guard let self else { return }
            guard !self.isInvalidated else { return }
            guard self.encodeInFlightCount > 0, self.encodeSequence == sequence else { return }

//            self.onDebug?(self.windowId, "host_encoder_encode_watchdog_reset", "inFlight=\(self.encodeInFlightCount)")
            self.resetSessionAfterEncodeFailure(reason: "watchdog")
        }
    }

    private func resetSessionAfterEncodeFailure(reason: String) {
        diagnostics.resetEncoder(windowID: windowId, token: diagnosticToken, reason: reason)
        encodeSubmittedAt = nil
        submittedForceKeyframe = false
        recovery.runtimeFailed(at: ProcessInfo.processInfo.systemUptime)
        recordRecovery(state: recovery.retryAfterUptime == nil ? "retrying" : "cooldown")
        let oldSession = session
        let oldRetainedSelf = sessionRetainedSelf
        session = nil
        sessionMode = nil
        sessionRetainedSelf = nil
        encodeInFlightCount = 0
        pendingSampleBuffer = nil
        pendingForceKeyframe = false
        onInFlightCountChanged?(0)
        encodeSequence &+= 1
        lastSentConfigSignature = nil
        needsForcedKeyframe = true
        lastKeyframeOutputUptime = nil

        invalidateDetachedSession(oldSession, retainedSelf: oldRetainedSelf)

//        onDebug?(windowId, "host_encoder_session_reset", reason)
    }

    private func invalidateDetachedSession(
        _ sessionToInvalidate: VTCompressionSession?,
        retainedSelf: Unmanaged<VideoH264Encoder>?
    ) {
        guard sessionToInvalidate != nil || retainedSelf != nil else { return }

        teardownQueue.async {
            if let sessionToInvalidate {
                VTCompressionSessionInvalidate(sessionToInvalidate)
            }

            retainedSelf?.release()
        }
    }

    private func handleEncodedSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard !isInvalidated else { return }
        let encodeMilliseconds = encodeSubmittedAt.map {
            max(0, ProcessInfo.processInfo.systemUptime - $0) * 1000
        }
        encodeSubmittedAt = nil
        // A forced submission is not fulfilled by dropped/unusable/non-sync
        // output. Only a valid keyframe below discharges this intent.
        if submittedForceKeyframe { needsForcedKeyframe = true }
        submittedForceKeyframe = false

        encodeInFlightCount = max(0, encodeInFlightCount - 1)
        onInFlightCountChanged?(encodeInFlightCount)
        encodeSequence &+= 1
//        onDebug?(windowId, "host_encoder_output_handling", "inFlight=\(encodeInFlightCount)")

        guard CMSampleBufferDataIsReady(sampleBuffer) else {
            encodePendingSampleBufferIfNeeded()
            return
        }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            encodePendingSampleBufferIfNeeded()
            return
        }
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            encodePendingSampleBufferIfNeeded()
            return
        }

        var isKeyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let attachment = attachments.first,
           let notSync = attachment[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKeyframe = !notSync
        }
        guard let payload = PeelEncodedPayloadCopy.copy(dataBuffer) else {
            encodePendingSampleBufferIfNeeded()
            return
        }
        onEncodeOutput?(windowId)
//        onDebug?(windowId, "host_encoder_output_payload", "bytes=\(payload.count)")

        let outputCodec = activeCodec
        var vpsData: Data?
        var spsData: Data?
        var ppsData: Data?
        var nalUnitHeaderLength: Int32 = 4
        var parameterSetCount = 0

        if outputCodec == .hevc {
            var vpsPointer: UnsafePointer<UInt8>?
            var vpsSize = 0
            if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: 0,
                parameterSetPointerOut: &vpsPointer,
                parameterSetSizeOut: &vpsSize,
                parameterSetCountOut: &parameterSetCount,
                nalUnitHeaderLengthOut: &nalUnitHeaderLength
            ) == noErr, let vpsPointer {
                vpsData = Data(bytes: vpsPointer, count: vpsSize)
            }

            var spsPointer: UnsafePointer<UInt8>?
            var spsSize = 0
            if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: 1,
                parameterSetPointerOut: &spsPointer,
                parameterSetSizeOut: &spsSize,
                parameterSetCountOut: &parameterSetCount,
                nalUnitHeaderLengthOut: &nalUnitHeaderLength
            ) == noErr, let spsPointer {
                spsData = Data(bytes: spsPointer, count: spsSize)
            }

            var ppsPointer: UnsafePointer<UInt8>?
            var ppsSize = 0
            if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: 2,
                parameterSetPointerOut: &ppsPointer,
                parameterSetSizeOut: &ppsSize,
                parameterSetCountOut: &parameterSetCount,
                nalUnitHeaderLengthOut: &nalUnitHeaderLength
            ) == noErr, let ppsPointer {
                ppsData = Data(bytes: ppsPointer, count: ppsSize)
            }
        } else {
            var spsPointer: UnsafePointer<UInt8>?
            var spsSize = 0
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: 0,
                parameterSetPointerOut: &spsPointer,
                parameterSetSizeOut: &spsSize,
                parameterSetCountOut: &parameterSetCount,
                nalUnitHeaderLengthOut: &nalUnitHeaderLength
            ) == noErr, let spsPointer {
                spsData = Data(bytes: spsPointer, count: spsSize)
            }

            var ppsPointer: UnsafePointer<UInt8>?
            var ppsSize = 0
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: 1,
                parameterSetPointerOut: &ppsPointer,
                parameterSetSizeOut: &ppsSize,
                parameterSetCountOut: &parameterSetCount,
                nalUnitHeaderLengthOut: &nalUnitHeaderLength
            ) == noErr, let ppsPointer {
                ppsData = Data(bytes: ppsPointer, count: ppsSize)
            }
        }

        if outputCodec == .hevc,
           (vpsData == nil || spsData == nil || ppsData == nil) {
            resetSessionAfterEncodeFailure(reason: "missing HEVC parameter sets")
            return
        }

        if isKeyframe {
            needsForcedKeyframe = false
            lastKeyframeOutputUptime = ProcessInfo.processInfo.systemUptime
        }
        recovery.producedValidOutput()
        diagnostics.output(windowID: windowId, token: diagnosticToken, bytes: payload.count,
            keyframe: isKeyframe, encodeMilliseconds: encodeMilliseconds)

        if let spsData, let ppsData {
            let signature = String(outputCodec.rawValue) + ":" +
                (vpsData?.base64EncodedString() ?? "") + ":" +
                spsData.base64EncodedString() + ":" +
                ppsData.base64EncodedString()
            if signature == lastSentConfigSignature {
                onOutput?(EncodedAccessUnit(
                    windowId: windowId,
                    codec: outputCodec,
                    width: width,
                    height: height,
                    isKeyframe: isKeyframe,
                    pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                    duration: CMSampleBufferGetDuration(sampleBuffer),
                    payload: payload,
                    vps: nil,
                    sps: nil,
                    pps: nil,
                    nalUnitHeaderLength: nalUnitHeaderLength
                ))
                encodePendingSampleBufferIfNeeded()
                return
            }
            lastSentConfigSignature = signature
        }

        onOutput?(EncodedAccessUnit(
            windowId: windowId,
            codec: outputCodec,
            width: width,
            height: height,
            isKeyframe: isKeyframe,
            pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            duration: CMSampleBufferGetDuration(sampleBuffer),
            payload: payload,
            vps: vpsData,
            sps: spsData,
            pps: ppsData,
            nalUnitHeaderLength: nalUnitHeaderLength
        ))
        encodePendingSampleBufferIfNeeded()
    }

    private func encodePendingSampleBufferIfNeeded() {
        guard !isInvalidated else {
            pendingSampleBuffer = nil
            pendingForceKeyframe = false
            return
        }

        guard encodeInFlightCount < maxEncodeInFlightCount else { return }
        if let newestInput = inputMailbox.take() {
            if let pending = pendingSampleBuffer {
                let pendingPTS = CMSampleBufferGetPresentationTimeStamp(pending)
                let newestPTS = CMSampleBufferGetPresentationTimeStamp(newestInput.sampleBuffer)
                let isOlder = pendingPTS.isNumeric && newestPTS.isNumeric &&
                    pendingPTS.epoch == newestPTS.epoch && CMTimeCompare(newestPTS, pendingPTS) < 0
                if !isOlder { pendingSampleBuffer = newestInput.sampleBuffer }
                diagnostics.replacedPending(windowID: windowId, token: diagnosticToken)
            } else {
                pendingSampleBuffer = newestInput.sampleBuffer
            }
            pendingForceKeyframe = pendingForceKeyframe || newestInput.forceKeyframe
        }
        guard let nextSampleBuffer = pendingSampleBuffer else { return }

        let forceKeyframe = pendingForceKeyframe
        pendingSampleBuffer = nil
        pendingForceKeyframe = false
        encode(sampleBuffer: nextSampleBuffer, forceKeyframe: forceKeyframe)
    }

    private func settleExplicitDrop(sequence: UInt64) {
        guard !isInvalidated, encodeSequence == sequence, encodeInFlightCount > 0 else { return }
        encodeSubmittedAt = nil
        if submittedForceKeyframe { needsForcedKeyframe = true }
        submittedForceKeyframe = false
        encodeInFlightCount -= 1
        onInFlightCountChanged?(encodeInFlightCount)
        encodeSequence &+= 1
        diagnostics.explicitFrameDropped(windowID: windowId, token: diagnosticToken)
        encodePendingSampleBufferIfNeeded()
    }

    private func handleCompressionCallback(status: OSStatus, infoFlags: VTEncodeInfoFlags,
                                           sampleBuffer: CMSampleBuffer?, sequence: UInt64) {
        guard !isInvalidated, encodeSequence == sequence else { return }
        if status == noErr, infoFlags.contains(.frameDropped) {
            settleExplicitDrop(sequence: sequence)
            return
        }
        // Only the documented noErr + FrameDropped combination is a drop.
        // Unexplained nil output and real errors retain existing recovery.
        guard status == noErr, let sampleBuffer else {
            encodeInFlightCount = max(0, encodeInFlightCount - 1)
            onInFlightCountChanged?(encodeInFlightCount)
            encodeSequence &+= 1
            resetSessionAfterEncodeFailure(reason: "callback_status=\(status)")
            return
        }
        handleEncodedSampleBuffer(sampleBuffer)
    }

    private static let outputCallback: VTCompressionOutputCallback = { refcon, sourceFrameRefcon, status, infoFlags, sampleBuffer in
        guard let refcon, let sourceFrameRefcon else { return }
        let encoder = Unmanaged<VideoH264Encoder>.fromOpaque(refcon).takeUnretainedValue()
        let callbackSequence = UInt64(UInt(bitPattern: sourceFrameRefcon))
        encoder.callbackQueue.async { [encoder] in
            encoder.handleCompressionCallback(status: status, infoFlags: infoFlags,
                                               sampleBuffer: sampleBuffer, sequence: callbackSequence)
        }
    }

}

/// One replaceable raw frame ahead of the encoder queue, including while a
/// synchronous VideoToolbox call is slow. Keyframe intent survives replacement.
nonisolated private final class VideoEncoderInputMailbox: @unchecked Sendable {
    struct Input {
        let sampleBuffer: CMSampleBuffer
        let forceKeyframe: Bool
    }
    struct Admission {
        let shouldSchedule: Bool
        let replacedPending: Bool
    }
    private let lock = NSLock()
    private var pending: Input?
    private var drainScheduled = false
    private var closed = false

    func offer(_ sampleBuffer: CMSampleBuffer, forceKeyframe: Bool) -> Admission? {
        var replaced: Input?
        lock.lock()
        guard !closed else { lock.unlock(); return nil }
        replaced = pending
        pending = Input(sampleBuffer: sampleBuffer,
                        forceKeyframe: forceKeyframe || (replaced?.forceKeyframe ?? false))
        let admission = Admission(shouldSchedule: !drainScheduled, replacedPending: replaced != nil)
        drainScheduled = true
        lock.unlock()
        // Release replaced CoreMedia storage outside the critical section.
        withExtendedLifetime(replaced) {}
        return admission
    }

    func take() -> Input? {
        lock.lock(); defer { lock.unlock() }
        let input = pending
        pending = nil
        return input
    }

    func finishDrain() -> Bool {
        lock.lock(); defer { lock.unlock() }
        drainScheduled = pending != nil
        return drainScheduled
    }

    func close() {
        let removed: Input?
        lock.lock()
        closed = true
        removed = pending
        pending = nil
        lock.unlock()
        withExtendedLifetime(removed) {}
    }
}
