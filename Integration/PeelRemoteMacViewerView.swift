// Remote Desktop › Connect. The model owns the shared connection and its separate stream window.
import AppKit
import Combine
import Foundation
import SwiftUI

struct PeelRemoteMacViewerView: View {
    @ObservedObject var controller: PeelRemoteMacViewerController
    @ObservedObject var presentation: PeelRemoteMacWindowPresentation
    var pairComputer: () -> Void = {}
    var shareThisMac: () -> Void = {}
    @State private var browserID = UUID()
    @State private var addressToEdit: PeelRemoteMacAddressRecord?
    @State private var showingAddressEditor = false
    @State private var showsOtherComputers = false
    @State private var showingICloudPairing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            pairingAccountEntry
            connectionCard
            if controller.isConnected { windowChooser }
            computerList
            connectionOptions
        }
        .background(PeelRemoteMacBrowserWindowProbe(presentation: presentation, browserID: browserID))
        .onAppear {
            presentation.browserDidAppear(browserID)
            controller.startDiscovery()
            controller.iCloudPairing.refresh(automatically: true)
        }
        .onDisappear { presentation.browserDidDisappear(browserID) }
        .sheet(isPresented: $showingAddressEditor) {
            PeelRemoteMacAddressEditor(record: addressToEdit, pairedPeers: controller.pairedPeers,
                onSave: { record in
                    presentation.disableControl()
                    try controller.saveAddress(record)
                }, onCompletion: { showingAddressEditor = false })
        }
        .sheet(isPresented: $showingICloudPairing) {
            PeelICloudMacPairingSheet(controller: controller.iCloudPairing,
                onDone: { showingICloudPairing = false },
                onPairWithCode: {
                    showingICloudPairing = false
                    pairComputer()
                })
        }
    }

    /// Rewords only the controller's two exact instructional defaults; every other
    /// status, progress or error message is shown verbatim.
    private var connectionInstruction: String {
        switch controller.status {
        case "Choose a paired computer to view its desktop.", "Choose a desktop or app window.":
            return controller.isConnected
                ? "Connected. Choose a desktop or app window from the list below."
                : "Choose a paired computer and select Connect. Then pick a desktop or app window from its current list."
        default:
            return controller.status
        }
    }

    /// Sign in with Apple (System Settings) and the account-free pairing code route, first on
    /// the page. Mac Peel Pro has no in-app Apple sign-in; the button opens the system Apple
    /// Account pane and the status shown is the system iCloud account only.
    private var pairingAccountEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            PeelPairingAccountNotice()
            ViewThatFits(in: .horizontal) {
                HStack { pairingAccountButtons }
                VStack(alignment: .leading, spacing: 8) { pairingAccountButtons }
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var pairingAccountButtons: some View {
        Button("Use a Pairing Code…", systemImage: "number", action: pairComputer)
            .help("Show this Mac's 6-digit code, or enter the code shown on your other Mac. No Apple Account needed.")
        Button("Apple pairing options…", systemImage: "apple.logo") { showingICloudPairing = true }
            .help("Optional automatic pairing between your Macs signed in with the same Apple ID")
    }

    /// Current connection first. The OS label comes only from the authenticated
    /// host hello; saved names never imply an operating system.
    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: controller.isConnected ? "display" : "display.trianglebadge.exclamationmark")
                    .font(.title2)
                    .foregroundStyle(controller.isConnected ? Color.accentColor : Color.secondary)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(controller.connectedDisplayName ?? (presentation.hasPresentation ? "Stream paused" : "Not connected"))
                        .font(.headline)
                    if controller.isConnected {
                        Text(controller.connectedPlatform).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(connectionInstruction).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            // Actions wrap under the status so the compact window never squeezes them.
            if presentation.hasPresentation || controller.isConnected {
                ViewThatFits(in: .horizontal) {
                    HStack { connectionActions }
                    VStack(alignment: .leading, spacing: 8) { connectionActions }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Current connection")
    }

    @ViewBuilder
    private var connectionActions: some View {
        if presentation.hasPresentation {
            Button("Show Stream Window", systemImage: "macwindow.on.rectangle", action: presentation.showStreamWindow)
                .help("Bring the separate stream window forward")
        }
        if controller.isConnected {
            Button("Refresh Windows", systemImage: "arrow.clockwise", action: controller.refreshWindows)
                .help("Ask the connected computer for its current desktops and app windows")
            Button("Disconnect") {
                presentation.disableControl()
                controller.disconnect()
            }
        }
    }

    @ViewBuilder
    private var windowChooser: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Open a desktop or app window").font(.headline)
            Text("Each opens in its own window. One remote window at a time: choosing another ends the current stream, then reconnect and pick it from the fresh list.")
                .font(.caption).foregroundStyle(.secondary)
            if controller.windows.isEmpty {
                ProgressView("Waiting for the window list…").controlSize(.small)
            }
            if let inventoryID = controller.currentWindowInventoryID {
                let desktops = controller.windows.filter(PeelRemoteMacViewerController.isDesktop)
                let apps = controller.windows.filter { !PeelRemoteMacViewerController.isDesktop($0) }
                if !desktops.isEmpty {
                    Text("Desktops").font(.subheadline.weight(.semibold))
                    windowGrid(desktops, inventoryID: inventoryID)
                }
                if !apps.isEmpty {
                    Text("App Windows").font(.subheadline.weight(.semibold))
                    windowGrid(apps, inventoryID: inventoryID)
                }
            }
        }
    }

    private func windowGrid(_ windows: [PeelWindow], inventoryID: PeelRemoteMacWindowInventoryID) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), alignment: .topLeading)], spacing: 10) {
            ForEach(windows) { window in
                Button {
                    presentation.open(window, inventoryID: inventoryID)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(PeelRemoteMacWindowPresentation.title(for: window),
                              systemImage: PeelRemoteMacViewerController.isDesktop(window) ? "display" : "macwindow")
                            .lineLimit(2)
                        if let note = windowNote(window) {
                            Text(note).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(8)
                }
                .buttonStyle(.bordered)
                .help("Open in a separate Peel Pro window")
            }
        }
    }

    /// A visual hint only. The previous descriptor never selects or reopens a window.
    private func windowNote(_ window: PeelWindow) -> String? {
        if controller.selectedWindow?.windowId == window.windowId { return "Open now" }
        if let previous = presentation.retainedIntent?.window, previous.windowId == window.windowId,
           previous.appName == window.appName {
            return "Previously open · choose to reopen"
        }
        return nil
    }

    @ViewBuilder
    private var computerList: some View {
        if controller.isConnected {
            DisclosureGroup("Other computers", isExpanded: $showsOtherComputers) {
                computers.padding(.top, 8)
            }
        } else {
            computers
        }
    }

    private var computers: some View {
        VStack(alignment: .leading, spacing: 12) {
            // One row when wide; otherwise the title above the actions, which
            // finally split into finding computers and pairing them.
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("Computers").font(.title3.bold())
                    Spacer()
                    computerFindingActions
                    computerPairingActions
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Computers").font(.title3.bold())
                    HStack {
                        computerFindingActions
                        computerPairingActions
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Computers").font(.title3.bold())
                    HStack { computerFindingActions }
                    HStack { computerPairingActions }
                }
            }
            if controller.availableMacs.isEmpty && controller.savedAddresses.isEmpty {
                ContentUnavailableView("No paired computers nearby", systemImage: "desktopcomputer",
                    description: Text("Open Peel Pro on the other computer and keep it awake. Pair it first, or add a private-network address for an existing pairing."))
            }
            if !controller.availableMacs.isEmpty {
                Text("Nearby").font(.headline)
                ForEach(controller.availableMacs) { mac in
                    HStack {
                        Label(mac.peer.displayName, systemImage: "desktopcomputer")
                        Text(controller.connectedPairingID == mac.id ? controller.connectedPlatform : "Computer")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(controller.connectedPairingID == mac.id && controller.activeSavedAddressID == nil
                               ? "Connected" : "Connect") {
                            presentation.disableControl()
                            controller.connect(mac)
                        }.disabled(controller.connectedPairingID == mac.id && controller.activeSavedAddressID == nil)
                    }
                }
            }
            if !controller.savedAddresses.isEmpty {
                Text("Saved Addresses").font(.headline)
                ForEach(controller.savedAddresses) { address in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Label(address.displayName, systemImage: "network")
                            Text(controller.activeSavedAddressID == address.id ? controller.connectedPlatform : "Computer")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("\(address.host) · \(String(address.port))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(controller.activeSavedAddressID == address.id ? "Connected" : "Connect") {
                            presentation.disableControl()
                            controller.connectDirectAddress(address)
                        }.disabled(controller.activeSavedAddressID == address.id)
                        Menu {
                            Button("Edit Address…") {
                                presentation.disableControl()
                                addressToEdit = address
                                showingAddressEditor = true
                            }
                            Button("Remove Address", role: .destructive) {
                                presentation.disableControl()
                                controller.removeAddress(address)
                            }
                        } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .accessibilityLabel("Address options for \(address.displayName)")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var computerFindingActions: some View {
        Button("Refresh", systemImage: "arrow.clockwise", action: controller.refreshDiscovery)
            .help("Look for paired computers on this network again")
        Button("Add Address…", systemImage: "plus") {
            presentation.disableControl()
            addressToEdit = nil
            showingAddressEditor = true
        }
        .disabled(controller.pairedPeers.isEmpty)
        .help("Save a private-network or VPN address for a computer you already paired")
    }

    @ViewBuilder
    private var computerPairingActions: some View {
        Button("Pair a Computer…", systemImage: "link.badge.plus", action: pairComputer)
            .help("Show this Mac's pairing code. Pair from the other computer or device.")
        Button("Apple pairing options…", systemImage: "apple.logo") { showingICloudPairing = true }
            .help("Optionally pair your other Macs through iCloud Keychain. Pairing never connects automatically.")
    }

    private var connectionOptions: some View {
        DisclosureGroup("Connection options") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Allow AI Window Opening", isOn: Binding(
                    get: { controller.allowsAgentPresentation },
                    set: { controller.setAgentPresentationOptIn($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Allow this paired computer to request a listed window while Peel Pro is visible.")
                Text("Lets an agent on the connected computer open one of its listed windows here while Peel Pro is visible. Control stays off until you turn it on in the stream window.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Share This Mac…", systemImage: "square.and.arrow.up.on.square", action: shareThisMac)
                    .buttonStyle(.link)
                    .help("Set up how other devices connect to this Mac")
            }
            .padding(.top, 6)
        }
    }
}

/// A small retained bridge lets SwiftUI controls release held AppKit state
/// before they lower the controller's input gate.
@MainActor
final class PeelRemoteMacInputCoordinator {
    weak var surface: PeelRemoteMacInputSurfaceView?

    func attach(_ surface: PeelRemoteMacInputSurfaceView) {
        self.surface = surface
    }

    func detach(_ surface: PeelRemoteMacInputSurfaceView) {
        if self.surface === surface {
            self.surface = nil
        }
    }

    func releaseAll() {
        surface?.releaseAll()
    }

    func activate() {
        surface?.activate()
    }

    func resign() {
        surface?.resignControl()
    }
}

@MainActor
struct PeelRemoteMacInputSurfaceRepresentable: NSViewRepresentable {
    let controller: PeelRemoteMacViewerController
    let coordinator: PeelRemoteMacInputCoordinator
    let windowDescriptor: PeelWindow
    let controlEnabled: Bool
    let onControlExit: () -> Void

    func makeNSView(context: Context) -> PeelRemoteMacInputSurfaceView {
        let view = PeelRemoteMacInputSurfaceView()
        view.apply(
            controller: controller,
            windowDescriptor: windowDescriptor,
            controlEnabled: controlEnabled,
            onControlExit: onControlExit
        )
        coordinator.attach(view)
        return view
    }

    func updateNSView(_ nsView: PeelRemoteMacInputSurfaceView, context: Context) {
        if nsView.windowDescriptor?.windowId != windowDescriptor.windowId {
            coordinator.releaseAll()
        }
        nsView.apply(
            controller: controller,
            windowDescriptor: windowDescriptor,
            controlEnabled: controlEnabled,
            onControlExit: onControlExit
        )
    }

    static func dismantleNSView(_ nsView: PeelRemoteMacInputSurfaceView, coordinator: ()) {
        nsView.releaseAll()
        nsView.removeInputObservers()
        nsView.onControlExit = nil
        nsView.controller = nil
    }
}

/// AppKit receives native mouse and keyboard events here so the renderer stays
/// a passive video surface. It has no event tap and never sends input unless
/// both the UI toggle and controller's authenticated/video gates are open.
@MainActor
final class PeelRemoteMacInputSurfaceView: NSView {
    weak var controller: PeelRemoteMacViewerController?
    weak var coordinator: PeelRemoteMacInputCoordinator?
    var windowDescriptor: PeelWindow?
    var onControlExit: (() -> Void)?

    private var controlEnabled = false {
        didSet {
            guard !controlEnabled else { return }
            // This is also called by the representable after the SwiftUI
            // binding changes. The binding releases first while the controller
            // gate is open; this second call simply clears local state.
            releaseAll()
            if window?.firstResponder === self {
                window?.makeFirstResponder(nil)
            }
        }
    }

    private var lastNormPoint = CGPoint(x: 0.5, y: 0.5)
    private var hasLastNormPoint = false
    private var heldButtons = Set<String>()
    private var heldHIDUsages = Set<Int>()
    private var commandKeyUpUsages = Set<Int>()
    private var commandKeyUpMonitor: Any?
    private var lastMoveAt: TimeInterval = 0
    private var lastMovePoint = CGPoint(x: -1, y: -1)
    // Latest throttled hover point, delivered when the interval ends so the
    // Host pointer comes to rest where the local pointer stopped.
    private var pendingMove: (point: CGPoint, windowId: UInt32)?
    private var pendingMoveFlush: DispatchWorkItem?
    private var hoverTrackingArea: NSTrackingArea?
    private var inputObserverTokens: [NSObjectProtocol] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        installHoverTrackingArea()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let commandKeyUpMonitor { NSEvent.removeMonitor(commandKeyUpMonitor) }
        let center = NotificationCenter.default
        for token in inputObserverTokens {
            center.removeObserver(token)
        }
    }

    func apply(
        controller: PeelRemoteMacViewerController,
        windowDescriptor: PeelWindow,
        controlEnabled: Bool,
        onControlExit: @escaping () -> Void
    ) {
        self.controller = controller
        self.windowDescriptor = windowDescriptor
        self.onControlExit = onControlExit
        self.controlEnabled = controlEnabled

        if controlEnabled {
            activate()
        }
    }

    func activate() {
        guard controlEnabled, isInputReady else { return }
        window?.makeFirstResponder(self)
    }

    func resignControl() {
        releaseAll()
        if window?.firstResponder === self {
            window?.makeFirstResponder(nil)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        controlEnabled && isInputReady
    }

    override func resignFirstResponder() -> Bool {
        releaseAll()
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeInputObservers()

        guard let window else {
            releaseAll()
            return
        }

        let center = NotificationCenter.default
        inputObserverTokens.append(
            center.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleInputFocusLoss()
                }
            }
        )
        inputObserverTokens.append(
            center.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: NSApp,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleInputFocusLoss()
                }
            }
        )

        if controlEnabled {
            activate()
        }
    }

    func removeInputObservers() {
        releaseAll()
        let center = NotificationCenter.default
        for token in inputObserverTokens {
            center.removeObserver(token)
        }
        inputObserverTokens.removeAll()
    }

    private func handleInputFocusLoss() {
        releaseAll()
        if window?.firstResponder === self {
            window?.makeFirstResponder(nil)
        }
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        installHoverTrackingArea()
        super.updateTrackingAreas()
    }

    /// Owner-delivered hover, independent of NSHostingView and first-responder routing.
    /// AppKit delivers it only while this window is key in the active app; every
    /// send still passes isInputReady. A duplicate window-level delivery of the
    /// same event resolves to the same point and is dropped by mouseMoved.
    private func installHoverTrackingArea() {
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseExited(with event: NSEvent) {
        // Drops only an undelivered hover point; control, its intent and held state are unchanged.
        cancelPendingMove()
    }

    override func mouseDown(with event: NSEvent) {
        handleMouseDown(event, button: "left")
    }

    override func mouseUp(with event: NSEvent) {
        handleMouseUp(event, button: "left")
    }

    override func rightMouseDown(with event: NSEvent) {
        handleMouseDown(event, button: "right")
    }

    override func rightMouseUp(with event: NSEvent) {
        handleMouseUp(event, button: "right")
    }

    override func mouseDragged(with event: NSEvent) {
        handleMouseDrag(event, button: "left")
    }

    override func rightMouseDragged(with event: NSEvent) {
        handleMouseDrag(event, button: "right")
    }

    override func mouseMoved(with event: NSEvent) {
        guard isInputReady, let windowId = windowDescriptor?.windowId,
              let norm = normalizedPoint(for: event) else { return }
        guard norm != lastMovePoint else {
            cancelPendingMove()
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        // Uniform latest-point cap for every hover distance; buttons/drags stay immediate.
        let interval = 1.0 / 120.0
        guard lastMoveAt == 0 || now - lastMoveAt >= interval else {
            // Coalesce fast moves to the latest point, but never drop the final resting point.
            pendingMove = (norm, windowId)
            guard pendingMoveFlush == nil else { return }
            let flush = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.flushPendingMove() }
            }
            pendingMoveFlush = flush
            DispatchQueue.main.asyncAfter(
                deadline: .now() + max(0.001, interval - (now - lastMoveAt)), execute: flush)
            return
        }

        sendMove(norm, windowId: windowId, at: now)
    }

    private func sendMove(_ norm: CGPoint, windowId: UInt32, at now: TimeInterval) {
        notePointerSent(norm)
        lastMoveAt = now
        send(PeelRequest(
            type: "mouseMove",
            windowId: windowId,
            normX: Double(norm.x),
            normY: Double(norm.y)
        ))
    }

    private func flushPendingMove() {
        pendingMoveFlush = nil
        guard let move = pendingMove else { return }
        pendingMove = nil
        // Button, release and stream-change paths cancel first; never retarget a replaced window.
        guard isInputReady, window?.isKeyWindow == true, NSApp.isActive,
              heldButtons.isEmpty, windowDescriptor?.windowId == move.windowId else { return }
        sendMove(move.point, windowId: move.windowId, at: ProcessInfo.processInfo.systemUptime)
    }

    private func cancelPendingMove() {
        pendingMove = nil
        pendingMoveFlush?.cancel()
        pendingMoveFlush = nil
    }

    /// Every sent pointer position is where the Host pointer now rests.
    private func notePointerSent(_ norm: CGPoint) {
        cancelPendingMove()
        lastMovePoint = norm
        lastNormPoint = norm
        hasLastNormPoint = true
    }

    override func scrollWheel(with event: NSEvent) {
        guard isInputReady,
              let deltaX = boundedScroll(event.scrollingDeltaX),
              let deltaY = boundedScroll(event.scrollingDeltaY),
              deltaX != 0 || deltaY != 0 else {
            return
        }

        send(PeelRequest(
            type: "mouseScroll",
            windowId: windowDescriptor?.windowId,
            normX: deltaX,
            normY: deltaY
        ))
    }

    private func handleMouseDown(_ event: NSEvent, button: String) {
        guard let norm = normalizedPoint(for: event), isInputReady else { return }
        window?.makeFirstResponder(self)
        guard heldButtons.insert(button).inserted else { return }

        notePointerSent(norm)
        send(PeelRequest(
            type: "mouseDown",
            windowId: windowDescriptor?.windowId,
            normX: Double(norm.x),
            normY: Double(norm.y),
            button: button
        ))
    }

    private func handleMouseDrag(_ event: NSEvent, button: String) {
        guard heldButtons.contains(button),
              let norm = normalizedPoint(for: event),
              isInputReady else { return }

        notePointerSent(norm)
        send(PeelRequest(
            type: "mouseDrag",
            windowId: windowDescriptor?.windowId,
            normX: Double(norm.x),
            normY: Double(norm.y),
            button: button
        ))
    }

    private func handleMouseUp(_ event: NSEvent, button: String) {
        guard heldButtons.contains(button) else { return }
        let norm = normalizedPoint(for: event) ?? (hasLastNormPoint ? lastNormPoint : CGPoint(x: 0.5, y: 0.5))
        heldButtons.remove(button)

        guard isInputReady else { return }
        notePointerSent(norm)
        send(PeelRequest(
            type: "mouseUp",
            windowId: windowDescriptor?.windowId,
            normX: Double(norm.x),
            normY: Double(norm.y),
            button: button
        ))
    }

    private func boundedScroll(_ value: CGFloat) -> Double? {
        let value = Double(value)
        guard value.isFinite else { return nil }
        return min(1_000, max(-1_000, value))
    }

    // MARK: - Keyboard

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard ownsKeyboardInput, event.window == nil || event.window === window else { return false }
        if isQuitShortcut(event) {
            // Leave Cmd-Q to the local app/window command chain.
            return false
        }
        if isLocalControlExit(event) {
            onControlExit?()
            return true
        }

        guard event.type == .keyDown else { return false }
        _ = sendHardwareKey(event, action: .down)
        // Consume a command/option/control equivalent even when the HID map
        // deliberately declines an unknown key; this keeps disabled/unknown
        // remote shortcuts from falling through into the local app.
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard ownsKeyboardInput, event.window == nil || event.window === window else { return }
        if isQuitShortcut(event) { return }
        if isLocalControlExit(event) {
            onControlExit?()
            return
        }
        _ = sendHardwareKey(event, action: .down)
    }

    override func keyUp(with event: NSEvent) {
        guard let usage = PeelRemoteMacHIDKeyMap.hidUsage(forVirtualKeyCode: event.keyCode) else { return }
        commandKeyUpUsages.remove(usage)
        if commandKeyUpUsages.isEmpty { removeCommandKeyUpMonitor() }
        // The local monitor consumes a matched up before AppKit dispatch. If a
        // responder path also delivers it, never send a second remote release.
        guard heldHIDUsages.remove(usage) != nil, isInputReady else { return }
        _ = sendHardwareKey(event, action: .up, usage: usage)
    }

    private var ownsKeyboardInput: Bool {
        guard isInputReady, NSApp.isActive, let window,
              window.isKeyWindow, window.firstResponder === self else { return false }
        return true
    }

    private func installCommandKeyUpMonitor() -> Bool {
        guard ownsKeyboardInput else { return false }
        if commandKeyUpMonitor != nil { return true }
        commandKeyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            // AppKit local monitors are synchronous on the main thread. An
            // asynchronous Task here could reorder the release after a new down.
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.handleCommandKeyUp(event) == nil
            }
            return consumed ? nil : event
        }
        return commandKeyUpMonitor != nil
    }

    private func removeCommandKeyUpMonitor() {
        guard let monitor = commandKeyUpMonitor else { return }
        commandKeyUpMonitor = nil
        NSEvent.removeMonitor(monitor)
    }

    private func handleCommandKeyUp(_ event: NSEvent) -> NSEvent? {
        guard ownsKeyboardInput else {
            releaseAll()
            return event
        }
        guard event.type == .keyUp, event.window == nil || event.window === window,
              let usage = PeelRemoteMacHIDKeyMap.hidUsage(forVirtualKeyCode: event.keyCode),
              commandKeyUpUsages.contains(usage), heldHIDUsages.contains(usage) else { return event }
        keyUp(with: event)
        return nil
    }

    override func flagsChanged(with event: NSEvent) {
        // State is owned only while the authenticated stream can accept this down.
        guard isInputReady, let windowId = windowDescriptor?.windowId else { return }
        guard let usage = PeelRemoteMacHIDKeyMap.hidUsage(forVirtualKeyCode: event.keyCode) else { return }

        let action: KeyboardCommandAction
        if let flag = PeelRemoteMacHIDKeyMap.modifierFlag(forHIDUsage: usage) {
            action = event.modifierFlags.contains(flag) ? .down : .up
        } else if usage == 57 {
            action = event.modifierFlags.contains(.capsLock) ? .down : .up
        } else {
            return
        }

        if action == .down {
            heldHIDUsages.insert(usage)
        } else {
            guard heldHIDUsages.remove(usage) != nil else { return }
        }

        send(KeyboardHardwareKeyMessage(
            windowId: windowId,
            keyCode: usage,
            characters: nil,
            charactersIgnoringModifiers: nil,
            // A flagsChanged event is already the exact modifier key. Sending
            // an additional aggregate modifier list would make the Host post
            // a second side's modifier for right-hand keys.
            modifiers: [],
            action: action
        ))
    }

    private func sendHardwareKey(
        _ event: NSEvent,
        action: KeyboardCommandAction,
        usage: Int? = nil
    ) -> Bool {
        guard let resolvedUsage = usage ?? PeelRemoteMacHIDKeyMap.hidUsage(forVirtualKeyCode: event.keyCode),
              let windowId = windowDescriptor?.windowId,
              isInputReady else {
            return false
        }

        if action == .down {
            if event.modifierFlags.contains(.command) {
                // Install before admitting a Command down. If installation
                // fails, do not create remote held state without its release path.
                guard installCommandKeyUpMonitor() else { return false }
                commandKeyUpUsages.insert(resolvedUsage)
            }
            heldHIDUsages.insert(resolvedUsage)
        }

        send(KeyboardHardwareKeyMessage(
            windowId: windowId,
            keyCode: resolvedUsage,
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: PeelRemoteMacHIDKeyMap.modifiers(from: event.modifierFlags),
            action: action
        ))
        return true
    }

    private func isQuitShortcut(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control),
              !event.modifierFlags.contains(.option) else {
            return false
        }
        if event.keyCode == 12 { return true }
        return event.charactersIgnoringModifiers?.lowercased() == "q"
    }

    private func isLocalControlExit(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.contains(.control),
              event.modifierFlags.contains(.option),
              !event.modifierFlags.contains(.command) else {
            return false
        }
        return event.keyCode == 53 || PeelRemoteMacHIDKeyMap.hidUsage(forVirtualKeyCode: event.keyCode) == 41
    }

    // MARK: - Lifecycle and mapping

    private var isInputReady: Bool {
        guard controlEnabled,
              let controller,
              controller.inputEnabled,
              controller.isConnected,
              controller.hasVideo,
              windowDescriptor != nil else {
            return false
        }
        return true
    }

    func releaseAll() {
        cancelPendingMove()
        let buttons = heldButtons.sorted()
        let usages = heldHIDUsages.sorted()
        heldButtons.removeAll()
        heldHIDUsages.removeAll()
        commandKeyUpUsages.removeAll()
        removeCommandKeyUpMonitor()

        // This method is intentionally usable immediately before the caller
        // lowers controller.inputEnabled. Do not require controlEnabled here;
        // the representable's didSet may be clearing it in the same turn.
        guard let controller,
              controller.inputEnabled,
              controller.isConnected,
              controller.hasVideo,
              let windowId = windowDescriptor?.windowId else {
            return
        }

        let norm = hasLastNormPoint ? lastNormPoint : CGPoint(x: 0.5, y: 0.5)
        for button in buttons {
            send(PeelRequest(
                type: "mouseUp",
                windowId: windowId,
                normX: Double(norm.x),
                normY: Double(norm.y),
                button: button
            ))
        }
        for usage in usages {
            send(KeyboardHardwareKeyMessage(
                windowId: windowId,
                keyCode: usage,
                characters: nil,
                charactersIgnoringModifiers: nil,
                modifiers: [],
                action: .up
            ))
        }
    }

    private func send<T: Encodable>(_ message: T) {
        controller?.sendInput(message)
    }

    private func normalizedPoint(for event: NSEvent) -> CGPoint? {
        guard let windowDescriptor else { return nil }
        let size = controller?.streamDisplaySize ?? CGSize(
            width: windowDescriptor.width, height: windowDescriptor.height)
        // Letterbox space remains inert; mouse-up retains the existing last-point fallback.
        return PeelRemoteMacStreamGeometry.normalizedPoint(
            convert(event.locationInWindow, from: nil), in: bounds, stream: size)
    }

}

/// HID usages expected by Host InputSynthesizer.swift. NSEvent.keyCode is a
/// macOS virtual key code, so the viewer sends this inverse map instead of
/// passing virtual key codes through as if they were HID usages.
private enum PeelRemoteMacHIDKeyMap {
    private static let virtualKeyCodeToHIDUsage: [UInt16: Int] = [
        0: 4, 11: 5, 8: 6, 2: 7, 14: 8, 3: 9, 5: 10, 4: 11,
        34: 12, 38: 13, 40: 14, 37: 15, 46: 16, 45: 17, 31: 18,
        35: 19, 12: 20, 15: 21, 1: 22, 17: 23, 32: 24, 9: 25,
        13: 26, 7: 27, 16: 28, 6: 29,
        18: 30, 19: 31, 20: 32, 21: 33, 23: 34, 22: 35,
        26: 36, 28: 37, 25: 38, 29: 39,
        36: 40, 53: 41, 51: 42, 48: 43, 49: 44, 27: 45, 24: 46,
        33: 47, 30: 48, 42: 49, 41: 51, 39: 52, 50: 53, 43: 54,
        47: 55, 44: 56, 57: 57,
        122: 58, 120: 59, 99: 60, 118: 61, 96: 62, 97: 63,
        98: 64, 100: 65, 101: 66, 109: 67, 103: 68, 111: 69,
        114: 73, 115: 74, 116: 75, 117: 76, 119: 77, 121: 78,
        124: 79, 123: 80, 125: 81, 126: 82,
        71: 83, 75: 84, 67: 85, 78: 86, 69: 87, 76: 88,
        83: 89, 84: 90, 85: 91, 86: 92, 87: 93, 88: 94,
        89: 95, 91: 96, 92: 97, 82: 98, 65: 99, 81: 103,
        59: 224, 56: 225, 58: 226, 55: 227, 62: 228, 60: 229,
        61: 230, 54: 231
    ]

    static func hidUsage(forVirtualKeyCode keyCode: UInt16) -> Int? {
        virtualKeyCodeToHIDUsage[keyCode]
    }

    static func modifierFlag(forHIDUsage usage: Int) -> NSEvent.ModifierFlags? {
        switch usage {
        case 224, 228: return .control
        case 225, 229: return .shift
        case 226, 230: return .option
        case 227, 231: return .command
        default: return nil
        }
    }

    static func modifiers(from flags: NSEvent.ModifierFlags) -> [KeyboardCommand] {
        var result: [KeyboardCommand] = []
        if flags.contains(.command) { result.append(.command) }
        if flags.contains(.option) { result.append(.option) }
        if flags.contains(.control) { result.append(.control) }
        if flags.contains(.shift) { result.append(.shift) }
        if flags.contains(.function) { result.append(.function) }
        return result
    }
}

