import AppKit
import Combine
import SwiftUI

/// One presentation owner for the existing single-stream receiving session.
/// The browser never mounts the renderer, and navigation cannot tear down video.
@MainActor
final class PeelRemoteMacWindowPresentation: NSObject, ObservableObject, NSWindowDelegate {
    private let controller: PeelRemoteMacViewerController
    private let openComputers: () -> Void
    @Published private(set) var hasPresentation = false
    @Published private(set) var retainedIntent: PeelRemoteMacReconnectIntent?
    @Published private(set) var reconnectState = PeelRemoteMacReconnectState()
    @Published private(set) var reconnectMessage = ""
    let inputCoordinator = PeelRemoteMacInputCoordinator()
    private var streamWindow: NSWindow?
    private var presentedIdentity: String?
    private var appliedSize: CGSize?
    private var activeBrowsers: Set<UUID> = []
    private var browserWindows: [UUID: WeakWindow] = [:]
    private var routeRegistered = false
    private var eligibilityIdentifier: ObjectIdentifier?
    private var visibilityObservers: Set<AnyCancellable> = []
    private var isShuttingDown = false
    private let inputReleaseOwnerID = UUID()
    private var autoControl = PeelRemoteMacAutoControlIntent()

    private final class WeakWindow {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }

    init(controller: PeelRemoteMacViewerController, openComputers: @escaping () -> Void) {
        self.controller = controller
        self.openComputers = openComputers
        super.init()
        controller.registerInputRelease(ownerID: inputReleaseOwnerID) { [weak self] in
            self?.inputCoordinator.releaseAll()
        }
        controller.onStreamWillChange = { [weak self] in self?.prepareForStreamChange() }
        controller.onStreamPresentationChanged = { [weak self] in self?.synchronizeSelection() }
        controller.onWindowInventoryUpdated = { [weak self] inventory in self?.windowInventoryUpdated(inventory) }
        controller.onStreamVideoReady = { [weak self] in self?.applyAutoControlIfReady() }
        let center = NotificationCenter.default
        for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didResignKeyNotification, NSApplication.didBecomeActiveNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            center.publisher(for: name).sink { [weak self] note in
                // A window can become key before the app is active (raise without
                // activation); app activation is the later fresh-foreground retry.
                let gainedFocus = note.name == NSWindow.didBecomeKeyNotification
                    || note.name == NSApplication.didBecomeActiveNotification
                Task { @MainActor [weak self] in
                    self?.refreshVisibility()
                    if gainedFocus { self?.streamWindowMayHaveBecomeKey() }
                }
            }.store(in: &visibilityObservers)
        }
    }

    func browserDidAppear(_ id: UUID) {
        activeBrowsers.insert(id)
        refreshVisibility()
    }

    func browserDidDisappear(_ id: UUID) {
        activeBrowsers.remove(id)
        browserWindows.removeValue(forKey: id)
        refreshVisibility()
    }

    func registerBrowserWindow(_ window: NSWindow?, id: UUID) {
        guard let window else {
            browserWindows.removeValue(forKey: id)
            refreshVisibility()
            return
        }
        browserWindows[id] = WeakWindow(window)
        refreshVisibility()
    }

    func open(_ window: PeelWindow, inventoryID: PeelRemoteMacWindowInventoryID) {
        guard controller.isCurrentWindowSelection(window, inventoryID: inventoryID) else {
            reconnectMessage = "The window list changed. Select a window from the current list."
            return
        }
        if controller.selectedWindow?.windowId == window.windowId, streamWindow != nil {
            showStreamWindow()
            return
        }
        if controller.selectedWindow != nil {
            pauseForExplicitReconnect(message: "Reconnect, then choose the window from the current list.")
            showStreamWindow()
            return
        }
        let previousIntent = retainedIntent
        retainedIntent = nil
        reconnectState.userSelectedFreshWindow()
        reconnectMessage = ""
        if !controller.selectWindow(window, inventoryID: inventoryID) {
            retainedIntent = previousIntent
            if previousIntent != nil { reconnectState.pause() }
            reconnectMessage = controller.status
            return
        }
        // Armed after selectWindow's stream-change release; only this user path arms it.
        if let stream = currentStreamIdentity {
            autoControl.armForExplicitSelection(stream: stream)
            applyAutoControlIfReady()
        }
    }

    private var currentStreamIdentity: String? {
        controller.selectedWindow.map { "\(controller.connectedPairingID ?? "")/\($0.windowId)" }
    }

    /// Default-on control for an explicitly selected stream, applied once with fresh foreground focus.
    private func applyAutoControlIfReady() {
        guard !isShuttingDown else { return }
        let window = eligible(streamWindow)
        let gates = PeelRemoteMacAutoControlIntent.Gates(stream: currentStreamIdentity,
            isConnected: controller.isConnected, hasVideo: controller.hasVideo,
            isPaused: retainedIntent != nil, windowIsKey: window?.isKeyWindow == true,
            appIsActive: NSApp.isActive, controlEnabled: controller.inputEnabled)
        guard autoControl.consume(gates), controller.enableInputControl() else { return }
        inputCoordinator.activate()
    }

    /// Returning to the stream window restores keyboard ownership for control the
    /// user already has on; focus loss itself only released held input.
    private func streamWindowMayHaveBecomeKey() {
        guard let window = eligible(streamWindow), window.isKeyWindow, NSApp.isActive,
              retainedIntent == nil else { return }
        if controller.inputEnabled {
            inputCoordinator.activate()
        } else {
            applyAutoControlIfReady()
        }
    }

    func reconnect() {
        guard retainedIntent != nil, eligible(streamWindow) != nil,
              !controller.hasControlConnection, !controller.isConnecting,
              let attempt = reconnectState.beginExplicitReconnect(), let intent = retainedIntent else { return }
        reconnectMessage = "Connecting to \(intent.displayName)…"
        guard let epoch = controller.reconnect(intent) else {
            reconnectState.connectionFailed(attempt: attempt)
            reconnectMessage = controller.status
            return
        }
        guard retainedIntent != nil, eligible(streamWindow) != nil,
              reconnectState.bindControlEpoch(epoch, attempt: attempt) else {
            if retainedIntent != nil { reconnectState.pause() }
            // Closing/hiding while normal explicit authorization is in progress invalidates its attempt.
            if controller.isCurrentConnectionEpoch(epoch) {
                controller.disconnect(reason: "Reconnect was canceled.")
            }
            return
        }
    }

    func chooseWindow() { openComputers() }

    private func windowInventoryUpdated(_ inventory: PeelRemoteMacWindowInventoryID) {
        guard retainedIntent != nil, controller.currentWindowInventoryID == inventory,
              controller.isCurrentConnectionEpoch(inventory.controlEpoch) else { return }
        controller.requireFreshWindowSelection()
        if !reconnectState.inventoryArrived(inventory) {
            // A normal explicit Connect in Computers may supersede the popup's attempt.
            reconnectState.currentInventoryIsChoosable(inventory)
        }
        reconnectMessage = "Connected. Choose a window from the current list."
        // Even a matching old descriptor is only a hint. No window selection happens here.
    }

    private func prepareForStreamChange() {
        disableControl()
        guard !isShuttingDown, streamWindow != nil, retainedIntent == nil,
              let selected = controller.selectedWindow else { return }
        let size = controller.streamDisplaySize ?? CGSize(width: selected.width, height: selected.height)
        retainedIntent = controller.reconnectIntent(for: selected, displaySize: size)
        if retainedIntent != nil {
            reconnectState.pause()
            reconnectMessage = "The connection ended. Reconnect, then choose a window again."
        }
    }

    private func pauseForExplicitReconnect(message: String) {
        prepareForStreamChange()
        disableControl()
        if retainedIntent != nil {
            reconnectState.pause()
            reconnectMessage = message
        }
        // Full control teardown fences old control/video callbacks; never send a window-keyed stop then reopen.
        controller.disconnect(reason: message)
    }

    func showStreamWindow() {
        guard let window = streamWindow else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        refreshVisibility()
    }

    func disableControl() {
        // Explicit Off/Escape/Stop and every stream change also drop a pending default-on intent.
        autoControl.cancel()
        // The safety ups must use the OLD window identity and still-open input gate.
        controller.disableInputControl()
        inputCoordinator.resign()
    }

    private func synchronizeSelection() {
        guard !isShuttingDown else { return }
        guard let selected = controller.selectedWindow else {
            if retainedIntent != nil {
                if !controller.hasControlConnection,
                   reconnectState.phase != .connecting || reconnectState.expectedControlEpoch != nil {
                    reconnectState.pause()
                    reconnectMessage = controller.status
                }
                return // Keep the native window, its frame/aspect and title as a paused placeholder.
            }
            closePresentation()
            return
        }
        retainedIntent = nil
        reconnectState.userSelectedFreshWindow()
        let identity = currentStreamIdentity
        let isNewSelection = presentedIdentity != identity
        if streamWindow == nil {
            let window = NSWindow(contentRect: .zero,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            window.identifier = NSUserInterfaceItemIdentifier("peel.remote.stream")
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            // AppKit otherwise never dispatches hover moves, so the Host pointer
            // (drawn into the video) moved only on click/drag. Moves still reach
            // only the input surface as key-window first responder.
            window.acceptsMouseMovedEvents = true
            window.contentView = NSHostingView(rootView: PeelRemoteMacStreamWindowView(
                controller: controller, presentation: self))
            window.delegate = self
            streamWindow = window
            hasPresentation = true
        }
        presentedIdentity = identity
        streamWindow?.title = Self.nativeTitle(for: selected, computer: controller.connectedPeerDisplayName)
        let size = controller.streamDisplaySize ?? CGSize(width: selected.width, height: selected.height)
        applyAspect(size, initial: isNewSelection)
        if isNewSelection { showStreamWindow() }
        refreshVisibility()
    }

    private func applyAspect(_ size: CGSize, initial: Bool) {
        guard let window = streamWindow, PeelRemoteMacStreamGeometry.validSize(size),
              initial || appliedSize != size else { return }
        let visible = window.screen?.visibleFrame ?? NSApp.keyWindow?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let maximum = CGSize(width: max(1, visible.width * 0.90), height: max(1, visible.height * 0.85))
        let ideal = initial
            ? CGSize(width: min(960, maximum.width), height: min(720, maximum.height))
            : CGSize(width: min(window.contentLayoutRect.width, maximum.width),
                     height: min(window.contentLayoutRect.height, maximum.height))
        guard let content = PeelRemoteMacStreamGeometry.fit(size, inside: ideal),
              let minimum = PeelRemoteMacStreamGeometry.fit(size, inside: CGSize(width: 320, height: 240)),
              let largest = PeelRemoteMacStreamGeometry.fit(size, inside: maximum) else { return }
        appliedSize = size
        window.contentAspectRatio = size
        window.contentMinSize = CGSize(width: min(minimum.width, largest.width),
                                       height: min(minimum.height, largest.height))
        window.contentMaxSize = largest
        window.setContentSize(content)
        if initial {
            window.setFrameOrigin(CGPoint(x: visible.midX - window.frame.width / 2,
                                          y: visible.midY - window.frame.height / 2))
        }
    }

    private func eligible(_ window: NSWindow?) -> NSWindow? {
        guard let window, window.isVisible, !window.isMiniaturized, !NSApp.isHidden else { return nil }
        return window
    }

    private func refreshVisibility() {
        guard !isShuttingDown else { return }
        if streamWindow != nil, eligible(streamWindow) == nil {
            if controller.hasControlConnection {
                pauseForExplicitReconnect(message: "Paused while hidden. Reconnect to resume, then choose a window.")
            } else { disableControl() }
        }
        // Unhiding never connects, reads credentials, or selects a retained window.
        let eligibleWindow = eligible(streamWindow) ?? activeBrowsers.compactMap {
            eligible(browserWindows[$0]?.window)
        }.first
        let nextIdentifier = eligibleWindow.map(ObjectIdentifier.init)
        guard nextIdentifier != eligibilityIdentifier || (eligibleWindow != nil) != routeRegistered else { return }
        eligibilityIdentifier = nextIdentifier
        if eligibleWindow != nil && !routeRegistered {
            routeRegistered = true
            controller.registerAgentPresentationRoute { [weak self] in self?.disableControl() }
        }
        controller.updateAgentPresentationWindow(eligibleWindow)
        if eligibleWindow == nil && routeRegistered {
            controller.unregisterAgentPresentationRoute()
            routeRegistered = false
        }
    }

    private func closePresentation() {
        guard let window = streamWindow else { refreshVisibility(); return }
        disableControl()
        window.delegate = nil
        streamWindow = nil
        hasPresentation = false
        retainedIntent = nil
        reconnectState.close()
        presentedIdentity = nil
        appliedSize = nil
        window.close()
        refreshVisibility()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, streamWindow === window else { return }
        // Remove ownership before the controller publishes the stopped selection.
        disableControl()
        streamWindow = nil
        hasPresentation = false
        retainedIntent = nil
        reconnectState.close()
        reconnectMessage = ""
        presentedIdentity = nil
        appliedSize = nil
        controller.disconnect(reason: "Stream window closed. Choose a computer to reconnect.")
        refreshVisibility()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        if let selected = controller.selectedWindow {
            appliedSize = nil
            applyAspect(controller.streamDisplaySize ?? CGSize(width: selected.width, height: selected.height), initial: false)
        } else if let intent = retainedIntent {
            appliedSize = nil
            applyAspect(intent.displaySize, initial: false)
        }
    }

    func shutdown() {
        disableControl()
        isShuttingDown = true
        controller.unregisterInputRelease(ownerID: inputReleaseOwnerID)
        controller.onStreamWillChange = nil
        controller.onStreamPresentationChanged = nil
        controller.onWindowInventoryUpdated = nil
        controller.onStreamVideoReady = nil
        controller.unregisterAgentPresentationRoute()
        controller.updateAgentPresentationWindow(nil)
        visibilityObservers.removeAll()
        streamWindow?.delegate = nil
        streamWindow?.close()
        streamWindow = nil
        hasPresentation = false
        retainedIntent = nil
        reconnectState.close()
        activeBrowsers.removeAll()
        browserWindows.removeAll()
    }

    static func title(for window: PeelWindow) -> String {
        let app = window.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if PeelRemoteMacViewerController.isDesktop(window) { return title.isEmpty ? "Desktop" : title }
        if app.isEmpty { return title.isEmpty ? "Window" : title }
        return title.isEmpty || title == app ? app : app + " — " + title
    }

    /// Native titlebar only: "<app or Desktop> — <paired computer>", with no brand suffix.
    static func nativeTitle(for window: PeelWindow, computer: String?) -> String {
        let source: String
        if PeelRemoteMacViewerController.isDesktop(window) {
            source = "Desktop"
        } else {
            let app = window.appName.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
            source = !app.isEmpty ? app : title.isEmpty ? "Window" : title
        }
        let name = computer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return source + " — " + (name.isEmpty ? "Computer" : name)
    }
}

@MainActor
private struct PeelRemoteMacStreamWindowView: View {
    @ObservedObject var controller: PeelRemoteMacViewerController
    @ObservedObject var presentation: PeelRemoteMacWindowPresentation

    var body: some View {
        ZStack {
            Color.black
            if let intent = presentation.retainedIntent {
                VStack(spacing: 12) {
                    Image(systemName: "pause.circle").font(.largeTitle)
                    Text("Stream Paused").font(.headline)
                    Text(PeelRemoteMacWindowPresentation.title(for: intent.window))
                        .font(.callout).lineLimit(2)
                    Text(presentation.reconnectMessage.isEmpty ? controller.status : presentation.reconnectMessage)
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if presentation.reconnectState.phase == .connecting || controller.isConnecting {
                        ProgressView().controlSize(.small)
                    } else if controller.isConnected && controller.currentWindowInventoryID != nil {
                        Button("Choose Window", action: presentation.chooseWindow).buttonStyle(.borderedProminent)
                    } else {
                        Button("Reconnect", action: presentation.reconnect).buttonStyle(.borderedProminent)
                        Button("Show in Remote Desktop", action: presentation.chooseWindow)
                            .help("Open Remote Desktop to choose a computer or window")
                    }
                    Text("Control stays off until you choose a window from the fresh list after reconnecting.")
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(20)
                .frame(maxWidth: 380)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(12)
            } else if let window = controller.selectedWindow {
                PeelRemoteMacVideoLayerView(renderer: controller.renderer)
                PeelRemoteMacInputSurfaceRepresentable(controller: controller,
                    coordinator: presentation.inputCoordinator, windowDescriptor: window,
                    controlEnabled: controller.inputEnabled, onControlExit: presentation.disableControl)
                if !controller.hasVideo {
                    ProgressView("Waiting for video…")
                        .padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                if controller.selectedWindow != nil, presentation.retainedIntent == nil {
                    PeelRemoteMacSourceMediaControls(controller: controller, audio: controller.audio,
                                                     media: controller.sourceMedia)
                }
                Toggle("Control", isOn: Binding(
                    get: { controller.inputEnabled },
                    set: { enabled in
                        if enabled {
                            guard controller.enableInputControl() else { return }
                            presentation.inputCoordinator.activate()
                        } else { presentation.disableControl() }
                    }))
                    .toggleStyle(.switch)
                    .disabled(!controller.hasVideo || !controller.isConnected)
                    .help("Send your keyboard and pointer to this remote window. Press Control-Option-Escape to stop.")
                Menu {
                    Text(controller.status)
                    Text(controller.inputEnabled ? "Control enabled on this viewer." : controller.inputStatus)
                    if let context = controller.agentPresentationContext {
                        Text(context)
                        Button("Dismiss AI Context", action: controller.dismissAgentPresentationContext)
                    }
                } label: { Image(systemName: "info.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Stream status and context")
            }
            .controlSize(.small)
            .padding(8)
            .background(.regularMaterial, in: Capsule())
            .padding(8)
        }
    }
}

@MainActor
struct PeelRemoteMacBrowserWindowProbe: NSViewRepresentable {
    let presentation: PeelRemoteMacWindowPresentation
    let browserID: UUID
    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.presentation = presentation
        view.browserID = browserID
        return view
    }
    func updateNSView(_ nsView: Probe, context: Context) {}
    static func dismantleNSView(_ nsView: Probe, coordinator: ()) {
        nsView.presentation?.registerBrowserWindow(nil, id: nsView.browserID)
        nsView.presentation = nil
    }
    final class Probe: NSView {
        weak var presentation: PeelRemoteMacWindowPresentation?
        var browserID = UUID()
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.presentation?.registerBrowserWindow(self.window, id: self.browserID)
            }
        }
    }
}
