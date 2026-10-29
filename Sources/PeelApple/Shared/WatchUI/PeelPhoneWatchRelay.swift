#if os(iOS)
import Foundation
import Combine
import Network
import UIKit
import PeelWatchCore

@MainActor
final class PeelPhoneWatchRelay: ObservableObject {
    struct Choice: Identifiable {
        let session: PeelHostSession
        let window: PeelWindow
        var id: String { "\(session.hostKey.rawValue):\(window.windowId)" }
        var label: String { "\(session.connectedHostName ?? session.host.name) · \(window.title.isEmpty ? window.appName : window.title)" }
    }
    @Published private(set) var status = "Open a window stream in Peel Pro, then share it here."
    @Published private(set) var isSharing = false
    @Published private(set) var controlAllowed = false
    @Published private(set) var waitingForControl = false
    @Published private(set) var sharedTitle = ""
    private weak var browser: PeelClientBrowser?
    private var source: Choice?
    private var socket: NWConnection?
    private var videoSocket: NWConnection?
    private var sourcePairingID: String?
    private var authority: WatchStreamLease?
    private var decoder: PeelWatchFrameDecoder?
    private var lastIssuedImage: PeelWatchFrameDecoder.ImageResult?
    private var housekeeping: Task<Void, Never>?
    private var busy = false
    private var lastFrameRequest: TimeInterval = 0
    private var lastKeyframeRequest: TimeInterval = 0
    private var controlGrantGeneration = UUID()
    private var controlFocusRequestID: String?

    func bind(_ browser: PeelClientBrowser) { self.browser = browser; objectWillChange.send() }
    var choices: [Choice] {
        guard let browser else { return [] }
        return browser.sessionsByHostKey.values.filter {
            $0.isConnectionReady && $0.connection != nil && $0.activePairingID != nil
        }.flatMap { session in
            session.windows.filter { session.desiredPullWindowIds.contains($0.windowId) }
                .prefix(32).map { Choice(session: session, window: $0) }
        }.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    func start(_ choice: Choice) {
        stop("Watch sharing stopped")
        guard UIDevice.current.userInterfaceIdiom == .phone,
              choice.session.isConnectionReady, choice.session.activePairingID != nil,
              choice.session.currentWindowInstanceMatches(choice.window),
              choice.session.desiredPullWindowIds.contains(choice.window.windowId),
              let videoSocket = choice.session.videoConnectionsByWindowId[choice.window.windowId],
              UIApplication.shared.applicationState == .active else {
            status = "Keep the paired iPhone and its window stream open in Peel Pro."; return
        }
        source = choice; socket = choice.session.connection; sourcePairingID = choice.session.activePairingID
        self.videoSocket = videoSocket
        authority = WatchStreamLease(now: ProcessInfo.processInfo.systemUptime)
        decoder = PeelWatchFrameDecoder()
        isSharing = true; sharedTitle = choice.label; status = "Ready. Open Live view on your Watch."
        let capturedID = authority!.id
        let frameDecoder = decoder!
        let selectedWindowID = choice.window.windowId
        choice.session.setWatchRelayConsumer { windowID, rendererID, sample, keyframe in
            guard windowID == selectedWindowID else { return }
            frameDecoder.submit(sample, keyframe: keyframe, rendererID: rendererID)
        }
        requestKeyframeIfPossible()
        housekeeping = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.authority?.id == capturedID else { return }
                guard self.sourceIsCurrent else { self.stop("Sharing ended: the iPhone or source changed."); return }
                do { try self.authority?.check(sessionID: capturedID, now: ProcessInfo.processInfo.systemUptime) }
                catch { self.stop("Watch view timed out. Start sharing again on iPhone."); return }
                if self.controlAllowed, !self.hasExactFocus { self.revokeControl("Control revoked: the active window changed.") }
                self.revokeIfDecoderChanged()
            }
        }
    }

    private var sourceIsCurrent: Bool {
        guard let source, let browser, let socket, let videoSocket, isSharing,
              UIApplication.shared.applicationState == .active,
              browser.isClientVisible, browser.session(for: source.session.hostKey) === source.session,
              source.session.connection === socket, source.session.isConnectionReady,
              source.session.videoConnectionsByWindowId[source.window.windowId] === videoSocket,
              sourcePairingID != nil, source.session.activePairingID == sourcePairingID,
              source.session.currentWindowInstanceMatches(source.window),
              source.session.desiredPullWindowIds.contains(source.window.windowId) else { return false }
        return true
    }
    private var hasExactFocus: Bool {
        guard let source, let controlFocusRequestID,
              source.session.isWatchControlFocusConfirmed(
                requestID: controlFocusRequestID, windowID: source.window.windowId
              ) else { return false }
        return WatchStreamSourcePolicy.hasInputFocus(windowID: source.window.windowId,
            activeWindowID: source.session.activeWindowId,
            hostConfirmedWindowID: source.session.hostConfirmedActiveWindowId)
    }
    private var info: WatchStreamInfo? {
        guard let source, let authority else { return nil }
        return WatchStreamInfo(sessionID: authority.id, hostName: source.session.connectedHostName ?? source.session.host.name,
            windowTitle: source.window.title.isEmpty ? source.window.appName : source.window.title,
            controlToken: controlAllowed ? authority.controlToken : nil)
    }

    func allowControl() async {
        guard sourceIsCurrent, !waitingForControl, let source, let leaseID = authority?.id else { return }
        revokeControl("Waiting for Host focus…")
        let grant = UUID(); controlGrantGeneration = grant; waitingForControl = true
        defer { if controlGrantGeneration == grant { waitingForControl = false } }
        guard let requestID = source.session.beginWatchControlFocusRequest(windowID: source.window.windowId) else {
            status = "Host focus could not be requested for this window."
            return
        }
        controlFocusRequestID = requestID
        for _ in 0..<20 {
            guard sourceIsCurrent, authority?.id == leaseID, controlGrantGeneration == grant else { return }
            if hasExactFocus {
                authority?.setControlAllowed(true); controlAllowed = true
                status = "Watch control allowed for this window. Host permissions still apply."; return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        revokeControl("Host did not confirm this window. Check its control permissions and try again.")
    }
    func revokeControl(_ message: String = "Watch control is off.") {
        if let controlFocusRequestID {
            source?.session.cancelWatchControlFocusRequest(requestID: controlFocusRequestID)
        }
        controlFocusRequestID = nil
        controlGrantGeneration = UUID(); waitingForControl = false
        authority?.setControlAllowed(false); controlAllowed = false; status = message
    }
    func stop(_ message: String = "Watch sharing stopped.") {
        revokeControl(message)
        housekeeping?.cancel(); housekeeping = nil
        source?.session.setWatchRelayConsumer(nil)
        decoder?.invalidate(); decoder = nil
        authority = nil; source = nil; socket = nil; videoSocket = nil; sourcePairingID = nil; lastIssuedImage = nil
        controlGrantGeneration = UUID(); waitingForControl = false
        controlAllowed = false; isSharing = false; busy = false; sharedTitle = ""; status = message
        // This lease observes an already-open phone stream. It never owns or stops
        // another scene's stream, changes visibility, or retains a held input.
    }

    func handle(_ request: WatchStreamRequest) async -> WatchStreamResponse {
        func reply(_ message: String, accepted: Bool, frame: WatchStreamFrame? = nil) -> WatchStreamResponse {
            WatchStreamResponse(requestID: request.requestID, info: info, frame: frame, message: message, accepted: accepted)
        }
        guard sourceIsCurrent, let currentID = authority?.id else {
            if isSharing { stop("The shared source changed. Start sharing again on iPhone.") }
            return reply(status, accepted: false)
        }
        do {
            revokeIfDecoderChanged()
            if request.kind == .status {
                try authority?.check(sessionID: currentID, now: ProcessInfo.processInfo.systemUptime)
                return reply("Paired iPhone relay · up to 1 frame/sec", accepted: true)
            }
            try authority?.check(sessionID: request.sessionID, now: ProcessInfo.processInfo.systemUptime)
            if request.kind == .stop { stop(); return reply(status, accepted: true) }
            guard !busy else { return reply("Relay is busy. Try again.", accepted: false) }
            if request.kind == .input {
                guard hasExactFocus else { revokeControl("Control revoked: Host focus changed."); throw WatchStreamError.controlDenied }
                guard let image = lastIssuedImage, decoder?.isCurrent(image) == true else {
                    revokeControl("Control revoked: the source stream refreshed."); throw WatchStreamError.staleFrame
                }
                try authority?.admit(request, now: ProcessInfo.processInfo.systemUptime)
                guard let input = request.input, let source else { throw WatchStreamError.invalid }
                // One-shot actions only. The Host's authenticated normal input and
                // Accessibility/consent gate remains the final authority.
                switch input.kind {
                case .click: source.session.sendClick(on: source.window, normX: input.x!, normY: input.y!)
                case .text: source.session.sendKeyboardText(input.text!)
                case .enter: source.session.sendKeyboardCommand(.enter)
                case .backspace: source.session.sendKeyboardCommand(.backspace)
                case .scrollUp: source.session.sendScroll(on: source.window, deltaX: 0, deltaY: 120)
                case .scrollDown: source.session.sendScroll(on: source.window, deltaX: 0, deltaY: -120)
                }
                return reply("Input sent through your paired Host session.", accepted: true)
            }
            guard request.kind == .frame else { throw WatchStreamError.invalid }
            try authority?.poll(sessionID: request.sessionID, now: ProcessInfo.processInfo.systemUptime)
            let now = ProcessInfo.processInfo.systemUptime
            guard now-lastFrameRequest >= 0.85 else { return reply("Waiting for the next frame…", accepted: true) }
            lastFrameRequest = now; busy = true
            defer { if authority?.id == currentID { busy = false } }
            let viewport = request.viewport ?? .full
            guard let image = await decoder?.jpeg(viewport: viewport) else {
                requestKeyframeIfPossible()
                return reply("Waiting for a fresh source frame…", accepted: true)
            }
            guard sourceIsCurrent, authority?.id == currentID,
                  decoder?.isCurrent(image) == true,
                  ProcessInfo.processInfo.systemUptime-image.capturedAt <= 3 else { throw WatchStreamError.expired }
            let sequence = authority!.issuedFrame(now: image.capturedAt)
            lastIssuedImage = image
            let frame = WatchStreamFrame(sequence: sequence, jpeg: image.data,
                width: image.width, height: image.height, viewport: viewport)
            return reply("Live via iPhone · up to 1 frame/sec", accepted: true, frame: frame)
        } catch {
            return reply(error.localizedDescription, accepted: false)
        }
    }
    private func revokeIfDecoderChanged() {
        if controlAllowed, let image = lastIssuedImage, decoder?.isCurrent(image) != true {
            revokeControl("Control revoked: the source stream refreshed.")
        }
    }
    private func requestKeyframeIfPossible() {
        let now = ProcessInfo.processInfo.systemUptime
        guard let source, now-lastKeyframeRequest >= 2,
              source.session.hostCapabilities.contains(PeelCapability.videoKeyframeRequestV1.rawValue) else { return }
        lastKeyframeRequest = now
        source.session.sendJSONMessage(PeelVideoKeyframeRequestMessage(windowId: source.window.windowId))
    }
}
#endif
