//
//  PeeledWindowView.swift
//  Peel
//
//  Created by Zach on 11/30/25.
//
//  iPad/iPhone parity update: Vision input/client calls, iOS toolbar UI.
//

import SwiftUI
import UIKit
import Combine
import GameController



private enum DirectScrollAxis {
    case horizontal
    case vertical
}

private enum InputCursorFeedbackMode {
    case click
    case scrollVertical
    case scrollHorizontal
    case drag
    case rightClick
}
private enum ActiveClickButton: String {
    case left
    case right

    var cursorMode: InputCursorFeedbackMode {
        switch self {
        case .left:
            return .click
        case .right:
            return .rightClick
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .left:
            return "Left click mode"
        case .right:
            return "Right click mode"
        }
    }
}

private enum IPadToolbarSnapTarget: CaseIterable {
    case topLeading
    case top
    case topTrailing
    case bottomLeading
    case bottom
    case bottomTrailing
}

private struct IPadToolbarSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct PeeledWindowView: View {
    @EnvironmentObject private var browser: PeelClientBrowser
    @EnvironmentObject private var scenes: SceneCoordinator
    @EnvironmentObject private var remoteNotificationPresenter: PeelLocalRemoteNotificationPresenter
    @EnvironmentObject private var agentPresentationCoordinator: IPadAgentPresentationCoordinator

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let window: PeelWindow
    let hostKey: PeelHostKey?
    let hostName: String?

    // Embedded phone workspaces keep both views alive while resizing. Only
    // the selected, visible pane may capture input or show input controls.
    var workspaceAllowsInput = true
    var workspaceSession: PeelHostSession? = nil
    var workspaceInputAdmission: () -> Bool = { true }
    var workspacePointerDidBegin: (UUID) -> Void = { _ in }
    var workspaceMayReleasePointer: (UUID) -> Bool = { _ in true }
    var workspaceViewportFrame: CGRect = .zero
    var workspaceIsVisible = true
    var workspaceManagesStreaming = false
    var workspaceReturnToBrowser: (() -> Void)? = nil

    init(window: PeelWindow) {
        self.window = window
        self.hostKey = nil
        self.hostName = nil
    }

    init(
        hostedWindow: HostedPeelWindow,
        workspaceSession: PeelHostSession? = nil,
        workspaceAllowsInput: Bool = true,
        workspaceInputAdmission: @escaping () -> Bool = { true },
        workspacePointerDidBegin: @escaping (UUID) -> Void = { _ in },
        workspaceMayReleasePointer: @escaping (UUID) -> Bool = { _ in true },
        workspaceViewportFrame: CGRect = .zero,
        workspaceIsVisible: Bool = true,
        workspaceManagesStreaming: Bool = false,
        workspaceReturnToBrowser: (() -> Void)? = nil
    ) {
        self.window = hostedWindow.window
        self.hostKey = hostedWindow.hostKey
        self.hostName = hostedWindow.hostName
        self.workspaceSession = workspaceSession
        self.workspaceAllowsInput = workspaceAllowsInput
        self.workspaceInputAdmission = workspaceInputAdmission
        self.workspacePointerDidBegin = workspacePointerDidBegin
        self.workspaceMayReleasePointer = workspaceMayReleasePointer
        self.workspaceViewportFrame = workspaceViewportFrame
        self.workspaceIsVisible = workspaceIsVisible
        self.workspaceManagesStreaming = workspaceManagesStreaming
        self.workspaceReturnToBrowser = workspaceReturnToBrowser
    }

    init(request: PeeledWindowSceneRequest) {
        self.window = request.window
        self.hostKey = request.hostKey
        self.hostName = request.hostName
    }
    
    @State private var popupWindowStack: [PeelWindow] = []
    
    // MARK: - Tap cursor feedback (client-side)
    @State private var tapCursorNorm: CGPoint? = nil
    @State private var tapCursorFeedbackMode: InputCursorFeedbackMode = .click
    @State private var tapCursorHideWorkItem: DispatchWorkItem? = nil
    @State private var isDirectCursorActive: Bool = false
    @State private var activeClickButton: ActiveClickButton = .left
    @AppStorage("peel.rightClickModeStaysEnabled") private var rightClickModeStaysEnabled: Bool = false
    @State private var isOpeningHome = false
    @State private var showingStreamDetails = false
    @State private var isReturningToBrowser = false
    @State private var didRestoreBrowserWindow = false
    @State private var rootWindowOverride: PeelWindow? = nil
    
    @State private var currentScene: UIWindowScene? = nil
    @State private var showStuckStreamCloseButton = false
    @ObservedObject private var gameControllerInput = PeelGameControllerInput.shared
    @State private var gameControllerOwnerID = UUID()

    @State private var zoomScale: CGFloat = 1.0
    @State private var baseZoomScale: CGFloat = 1.0
    @State private var contentOffset: CGSize = .zero
    @State private var baseContentOffset: CGSize = .zero

    private var runtimeSession: PeelHostSession {
        if let workspaceSession { return workspaceSession }
        if let hostKey, let session = browser.session(for: hostKey) {
            return session
        }

        if (hostKey == nil || hostKey?.rawValue == "legacy"),
           let selectedSession = browser.selectedSession {
            return selectedSession
        }

        preconditionFailure("Missing PeelHostSession for peeled window")
    }

    /// Source media binds only to this window's own session. Unlike
    /// `runtimeSession` it never falls back to the selected session.
    private var sourceMediaOwnerSession: PeelHostSession? {
        if let workspaceSession { return workspaceSession }
        return hostKey.flatMap { browser.session(for: $0) }
    }

    private var sourceMediaComputerName: String {
        let session = sourceMediaOwnerSession
        let name = displayNameWithoutPeelPrefix(hostName ?? session?.connectedHostName ?? session?.host.name ?? "")
        return name.isEmpty ? "your computer" : name
    }

    private var sourceMediaInputAllowed: Bool {
        !isIPadToolbarDragging && workspaceAllowsInput && workspaceIsVisible && workspaceInputAdmission()
    }

    private func sourceMediaControls(style: PeelSourceMediaControlsStyle) -> some View {
        PeelSourceMediaControls(
            session: sourceMediaOwnerSession,
            windowId: presentedWindow.windowId,
            computerName: sourceMediaComputerName,
            style: style,
            canInteract: { sourceMediaInputAllowed }
        )
    }

    private func hostedWindow(_ window: PeelWindow) -> HostedPeelWindow {
        HostedPeelWindow(
            hostKey: runtimeSession.hostKey,
            hostName: hostName ?? runtimeSession.host.name,
            window: window
        )
    }

    private let maxZoomScale: CGFloat = 4.0

    
    private let tapCursorSize: CGFloat = 26

    
    
    // Keyboard focus & enable toggle
    @FocusState private var keyboardFocused: Bool
    @State private var keyboardEnabled: Bool = false
    // Bridge @FocusState to a plain Binding for UIKit view
    @State private var isFocusedBridge: Bool = false
    @State private var keyboardFocusRequestID: Int = 0
    @State private var showPhoneControls: Bool = false
    @State private var isIPadToolbarExpanded: Bool = false
    @State private var showIPadMacroControls: Bool = false
    @State private var isExternalKeyboardConnected: Bool = false
    @State private var iPadToolbarSnapTarget: IPadToolbarSnapTarget = .topLeading
    @State private var iPadToolbarSize: CGSize = .zero
    @State private var isIPadToolbarDragging: Bool = false
    @State private var iPadToolbarDragTranslation: CGSize = .zero
    @State private var heldMacroCommands: [KeyboardCommand] = []
    
    // Per-window chrome style
    @State private var lastTranslation: CGSize = .zero

    // MARK: - Direct hand-scroll inertia
    @State private var directScrollVelocity: CGSize = .zero
    @State private var directScrollLastSampleTime: CFTimeInterval? = nil
    @State private var didDirectScrollDuringGesture: Bool = false
    @State private var directScrollInertiaTask: Task<Void, Never>? = nil
    @State private var directScrollInertiaID: Int = 0
    @State private var directScrollAxis: DirectScrollAxis? = nil
    
    // MARK: - Debug overlay state
#if DEBUG
    @State private var showDebugOverlay: Bool = true

    @State private var lastFrameTimestamp: Date?
    @State private var frameIntervals: [TimeInterval] = []
    @State private var fps: Double = 0
    @State private var estimatedLatencyMs: Double = 0

    private let maxFrameSamples: Int = 60
    private let overlayTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
#endif
    
    // Small per-client calibration to align taps with the captured content.
    // You can tweak these if the cursor feels slightly off.
    private let clickCalibrationOffset = CGSize(width: 0, height: 0)
    
    private let clickThreshold: CGFloat = 8
    private let directScrollStartThreshold: CGFloat = 7
    private let directScrollAxisLockRatio: CGFloat = 1.35
    private let directScrollFrameNoiseThreshold: CGFloat = 0.5
    
    @State private var dragStartTime: Date?
    @State private var dragStartLocation: CGPoint?
    
    // MARK: - Mouse-drag (press-and-hold then move)
    @State private var isMouseDragActive: Bool = false
    @State private var mouseDragDidSendDown: Bool = false
    @State private var mouseDragStartNorm: CGPoint? = nil
    @State private var pointerInteractionID = UUID()

    private let mouseDragHoldDuration: TimeInterval = 0.12
    private let mouseDragBeginDistance: CGFloat = 6

    @State private var lastFocusRequestAt: Date? = nil
    private let focusRequestMinInterval: TimeInterval = 0.35

    private let longPressDuration: TimeInterval = 0.5
    private let longPressMovementThreshold: CGFloat = 12

    
    var body: some View {
        let keyboardSession = runtimeSession
        let keyboardWindowId = presentedWindow.windowId
        // Bridge object that forwards keystrokes into PeelClientBrowser
        //MARK: IGNORE ERRORS HERE _ XCODE IS BROKEN AND BUILD AND KEYBOARD WORK
        let keyboardBridge = KeyboardBridge(
            onText: { text in
                handleKeyboardTextInput(text)
            },
            onBackspace: {
                sendKeyboardControlCommand(.backspace)
            },
            onEnter: {
                sendKeyboardControlCommand(.enter)
            },
            onCommand: { command in
                sendKeyboardControlCommand(command)
            },
            onHardwareKey: { keyCode, characters, charactersIgnoringModifiers, modifiers in
                prepareKeyboardControlTarget()
                runtimeSession.sendKeyboardHardwareKey(
                    keyCode: keyCode,
                    characters: characters,
                    charactersIgnoringModifiers: charactersIgnoringModifiers,
                    modifiers: modifiers
                )
            }
        )

        // let aspect = max(0.5,
        //                  min(2.0, CGFloat(window.width) / CGFloat(window.height)))

        let core = ZStack {
            Group {
                framelessLayout

                // UIKit-backed text input for the software keyboard, dictation, and text composition.
                KeyCaptureTextView(
                    isFocused: $isFocusedBridge,
                    isInputOwner: {
                        browser.session(for: keyboardSession.hostKey) === keyboardSession &&
                            keyboardSession.activeWindowId == keyboardWindowId &&
                            workspaceAllowsInput && workspaceIsVisible && workspaceInputAdmission()
                    },
                    focusRequestID: keyboardFocusRequestID,
                    isMacroHoldModeEnabled: !heldMacroCommands.isEmpty,
                    delegate: keyboardBridge,
                    onFocusChanged: handleKeyboardFocusChanged
                )
                    .frame(width: 4, height: 4)
                    .opacity(0.01)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .background(Color.clear)
        }
        .onAppear {
            if usesSeparatePeeledWindowScene, let currentScene {
                scenes.registerPeeledWindowScene(currentScene, for: hostedWindow(rootWindow))
            }
            if !workspaceManagesStreaming, runtimeSession.activeWindowId == nil {
                runtimeSession.setActiveWindow(rootWindow.windowId)
            }
            if workspaceIsVisible { startStreaming() }
            setSoftwareKeyboardActive(keyboardEnabled)
            refreshExternalInputState(autoEnableKeyboard: true)
            syncGameControllerInputOwner()
        }
        .onDisappear {
            gameControllerInput.release(owner: gameControllerOwnerID)
            cancelPointerInteraction(reason: "view disappeared")

            if usesSeparatePeeledWindowScene {
                scenes.markPeeledWindowSceneClosed(currentScene, for: hostedWindow(rootWindow))
            }

            stopStreaming()

            for popup in popupWindowStack {
                if runtimeSession.windows.contains(where: { $0.windowId == popup.windowId }) {
                    runtimeSession.clearAutoPopupTracking(for: popup.windowId)
                }
            }

            if runtimeSession.isAutoPopupWindow(rootWindow.windowId),
               runtimeSession.windows.contains(where: { $0.windowId == rootWindow.windowId }) {
                runtimeSession.clearAutoPopupTracking(for: rootWindow.windowId)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                gameControllerInput.release(owner: gameControllerOwnerID)
                cancelPointerInteraction(reason: "scene inactive")
            } else {
                refreshKeyboardInputOwnership()
                syncGameControllerInputOwner()
            }
        }
        .onChange(of: workspaceAllowsInput) { _, allowsInput in
            syncGameControllerInputOwner()
            if allowsInput {
                refreshExternalInputState(autoEnableKeyboard: true)
            } else {
                setSoftwareKeyboardActive(false)
                cancelPointerInteraction(reason: "workspace pane changed")
                heldMacroCommands.removeAll()
            }
        }
        .onChange(of: workspaceIsVisible) { _, visible in
            syncGameControllerInputOwner()
            if visible {
                startStreaming()
            } else {
                setSoftwareKeyboardActive(false)
                cancelPointerInteraction(reason: "workspace pane hidden")
                stopStreaming()
            }
        }
        .onChange(of: workspaceViewportFrame) { _, _ in
            cancelPointerInteraction(reason: "workspace layout changed")
        }
        .onReceive(runtimeSession.$isConnectionReady) { ready in
            if !ready { cancelPointerInteraction(reason: "connection ended") }
            // @Published emits before the store; claim the settled connection next turn.
            DispatchQueue.main.async {
                syncGameControllerInputOwner()
            }
        }
        .onReceive(runtimeSession.$activeWindowId) { _ in
            DispatchQueue.main.async {
                syncGameControllerInputOwner()
            }
        }
        .onChange(of: presentedWindow.windowId) { _, _ in
            syncGameControllerInputOwner()
        }
        .onChange(of: keyboardFocused) { _, newValue in
            if isFocusedBridge != newValue { isFocusedBridge = newValue }
        }
        .onChange(of: isFocusedBridge) { _, newValue in
            if keyboardFocused != newValue { keyboardFocused = newValue }
        }
        .onReceive(runtimeSession.$windows) { _ in
            handleAutoPopupLifecycleIfNeeded()
        }
        .onReceive(runtimeSession.$sharedCursor) { sharedCursor in
            syncLocalInputModeFromSharedCursor(sharedCursor)
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)) { _ in
            refreshExternalInputState(autoEnableKeyboard: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidDisconnect)) { _ in
            refreshExternalInputState(autoEnableKeyboard: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCMouseDidConnect)) { _ in
            refreshExternalInputState(autoEnableKeyboard: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCMouseDidDisconnect)) { _ in
            refreshExternalInputState(autoEnableKeyboard: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? UIWindow,
                  window.windowScene === currentScene else { return }
            refreshKeyboardInputOwnership()
            syncGameControllerInputOwner()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIWindow.didResignKeyNotification)) { notification in
            guard let window = notification.object as? UIWindow,
                  window.windowScene === currentScene else { return }
            syncGameControllerInputOwner()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) { notification in
            guard let scene = notification.object as? UIWindowScene,
                  scene === currentScene else { return }
            refreshKeyboardInputOwnership()
            syncGameControllerInputOwner()
        }
        .onChange(of: rootWindow.windowId) { _, _ in
            if usesSeparatePeeledWindowScene, let currentScene {
                scenes.registerPeeledWindowScene(currentScene, for: hostedWindow(rootWindow))
            }
        }
        .background(
            WindowSceneReader { scene in
                let sceneID = scene.session.persistentIdentifier

                DispatchQueue.main.async {
                    if currentScene?.session.persistentIdentifier != sceneID {
                        currentScene = scene
                        if usesSeparatePeeledWindowScene {
                            scenes.registerPeeledWindowScene(scene, for: hostedWindow(rootWindow))
                        }
                        refreshKeyboardInputOwnership()
                        syncGameControllerInputOwner()
                    }
                }
            }
        )
        .background(
            PeelGameControllerEventInteractionAnchor(
                isEnabled: gameControllerInput.routingOwnerID == gameControllerOwnerID &&
                    isKeyboardSceneEligible
            )
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        )
#if DEBUG
        .onReceive(overlayTimer) { now in
            updateLatency(now: now)
        }
#endif


        core
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    PeelRemoteNotificationBanner(inbox: remoteNotificationPresenter.inbox)
                    if let context = agentPresentationCoordinator.presentationContext(for: hostedWindow(rootWindow)) {
                        HStack(alignment: .top, spacing: 12) {
                            Text(verbatim: context).font(.callout).lineLimit(6)
                            Button {
                                agentPresentationCoordinator.clearPresentationContext(for: hostedWindow(rootWindow))
                            } label: { Image(systemName: "xmark.circle.fill") }
                            .accessibilityLabel("Dismiss agent context")
                        }
                        .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .frame(maxWidth: 560).padding(12)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if isPhone && workspaceAllowsInput {
                    phoneControlsOverlay
                }
            }
            .overlay {
                if !isPhone && workspaceAllowsInput {
                    GeometryReader { geometry in
                        iPadControlsOverlay(in: geometry.size)
                    }
                }
            }
            .ignoresSafeArea(.keyboard)
            .sheet(isPresented: $showingStreamDetails) {
                PeelStreamDetailsView {
                    let windowId = presentedWindow.windowId
                    guard runtimeSession.isConnectionReady,
                          let renderer = runtimeSession.videoRenderer(for: windowId) else { return nil }
                    return renderer.streamingDiagnosticSnapshot(windowId: windowId, spatial: false)
                }
                .id(presentedWindow.windowId)
            }

    }
    
   

    private var rootWindow: PeelWindow {
        rootWindowOverride ?? window
    }

    private var presentedWindow: PeelWindow {
        popupWindowStack.last ?? rootWindow
    }

    private var usesSeparatePeeledWindowScene: Bool {
#if os(iOS)
        UIDevice.current.userInterfaceIdiom != .phone
#else
        true
#endif
    }

    private var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    private var supportsSpaceSwitching: Bool {
        runtimeSession.supportsHostCapability(.spaceSwitching)
    }

    private var isPresentedWindowEntireDisplay: Bool {
        let appName = presentedWindow.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = presentedWindow.title.trimmingCharacters(in: .whitespacesAndNewlines)

        return appName.localizedCaseInsensitiveContains("display") ||
            title.localizedCaseInsensitiveContains("display") ||
            title.localizedCaseInsensitiveContains("screen")
    }

    private func displayNameWithoutPeelPrefix(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "Peel on "

        if trimmed.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil {
            return String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return trimmed
    }

    private func isDisplayCaptureWindow(_ window: PeelWindow) -> Bool {
        let appName = window.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)

        return appName.localizedCaseInsensitiveCompare("Peel Display") == .orderedSame ||
            title.localizedCaseInsensitiveContains("Peel Display")
    }

    private func isInputReadyForWindow(_ window: PeelWindow, streamStatus: WindowStreamStatus? = nil) -> Bool {
        guard workspaceAllowsInput, workspaceIsVisible, workspaceInputAdmission() else { return false }
        let resolvedStreamStatus = streamStatus ?? runtimeSession.streamStatus(for: window.windowId)

        guard resolvedStreamStatus != .offline else {
            return false
        }

        // Display capture streams do not map to a normal app window that the host can
        // confirm as AX-focused. If the display stream is online, input can be attempted.
        if isDisplayCaptureWindow(window) {
            return true
        }

        return runtimeSession.isHostConfirmedActiveWindow(window.windowId)
    }

    private func windowChromeTitle(for window: PeelWindow) -> String {
        if isDisplayCaptureWindow(window),
           let connectedHostName = runtimeSession.connectedHostName {
            let hostName = displayNameWithoutPeelPrefix(connectedHostName)

            if !hostName.isEmpty {
                return hostName
            }
        }

        let appName = window.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !appName.isEmpty {
            return appName
        }

        let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            return title
        }

        return "Peel Pro"
    }

    private var ornamentMenuButton: some View {
        Button {
            guard !isIPadToolbarDragging else { return }
            returnToBrowser()
        } label: {
            Image("PeelHostMenuBarIcon_128x128")
                .resizable()
                .frame(width: 28, height: 28)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Return to Peel Pro")
    }
    
    private var ornamentStatus: some View {
        let activeWindow = presentedWindow
        let streamStatus = runtimeSession.streamStatus(for: activeWindow.windowId)
        let isInputReady = isInputReadyForWindow(activeWindow, streamStatus: streamStatus)

        let status: WindowStreamStatus = {
            if streamStatus == .offline {
                return .offline
            }

            return isInputReady ? .active : .sleeping
        }()
        let title = windowChromeTitle(for: activeWindow)

        return HStack(spacing: 8) {
            StatusDot(status: status)

            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .fixedSize(horizontal: true, vertical: false)
        .clipShape(Capsule())
        .accessibilityLabel("\(title). Stream status: \(statusLabel(status)).")
    }

    private func iPadControlsOverlay(in containerSize: CGSize) -> some View {
        VStack(alignment: iPadToolbarHorizontalAlignment, spacing: 10) {
            iPadPrimaryToolbar(in: containerSize)

            if isIPadToolbarExpanded && showIPadMacroControls {
                iPadMacroControlsStrip
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: IPadToolbarSizePreferenceKey.self,
                    value: geometry.size
                )
            }
        }
        .onPreferenceChange(IPadToolbarSizePreferenceKey.self) { newSize in
            if iPadToolbarSize != newSize {
                iPadToolbarSize = newSize
            }
        }
        .offset(iPadToolbarDragTranslation)
        .scaleEffect(isIPadToolbarDragging ? 1.045 : 1)
        .rotationEffect(.degrees(isIPadToolbarDragging ? -0.8 : 0))
        .shadow(
            color: .black.opacity(isIPadToolbarDragging ? 0.34 : 0),
            radius: isIPadToolbarDragging ? 24 : 0,
            y: isIPadToolbarDragging ? 14 : 0
        )
        .zIndex(isIPadToolbarDragging ? 1 : 0)
        .animation(.spring(response: 0.24, dampingFraction: 0.72), value: isIPadToolbarDragging)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(
            width: containerSize.width,
            height: containerSize.height,
            alignment: iPadToolbarContainerAlignment
        )
    }

    private var iPadToolbarContainerAlignment: Alignment {
        switch iPadToolbarSnapTarget {
        case .topLeading:
            return .topLeading
        case .top:
            return .top
        case .topTrailing:
            return .topTrailing
        case .bottomLeading:
            return .bottomLeading
        case .bottom:
            return .bottom
        case .bottomTrailing:
            return .bottomTrailing
        }
    }

    private var iPadToolbarHorizontalAlignment: HorizontalAlignment {
        switch iPadToolbarSnapTarget {
        case .topLeading, .bottomLeading:
            return .leading
        case .top, .bottom:
            return .center
        case .topTrailing, .bottomTrailing:
            return .trailing
        }
    }

    private func iPadPrimaryToolbar(in containerSize: CGSize) -> some View {
        iPadToolbarContents(in: containerSize)
            .fixedSize(horizontal: true, vertical: false)
            .frame(height: 44)
            .contentShape(Capsule())
            .glassEffect(.regular.interactive(), in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
    }

    private func iPadToolbarContents(in containerSize: CGSize) -> some View {
        HStack(spacing: 2) {
            ornamentMenuButton
            iPadToolbarDivider
            ornamentStatus
                .contentShape(Capsule())
                .hoverEffect(.lift)
                .gesture(iPadToolbarDragGesture(in: containerSize))
                .accessibilityHint("Drag to move the toolbar")

            if !isExternalKeyboardConnected {
                iPadToolbarDivider
                keyboardControlButton
                    .transition(.scale.combined(with: .opacity))
            }

            if gameControllerInput.hasSupportedController {
                iPadToolbarDivider
                PeelGameControllerHelpButton(ownerID: gameControllerOwnerID)
            }

            if isIPadToolbarExpanded {
                expandedIPadToolbarControls
            }

            iPadToolbarDivider
            iPadToolbarExpansionButton
        }
    }

    private var iPadToolbarExpansionButton: some View {
        overlayIconButton(
            systemImage: isIPadToolbarExpanded ? "chevron.left" : "chevron.right",
            accessibilityLabel: isIPadToolbarExpanded ? "Collapse toolbar" : "Expand toolbar",
            foregroundColor: .white
        ) {
            let willExpand = !isIPadToolbarExpanded

            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                isIPadToolbarExpanded = willExpand

                if !willExpand {
                    showIPadMacroControls = false
                }
            }
        }
    }

    private var expandedIPadToolbarControls: some View {
        HStack(spacing: 2) {
            if supportsSpaceSwitching && isDisplayCaptureWindow(presentedWindow) {
                iPadSpaceSwitchingControls
            }

            iPadToolbarDivider
            clickModeControlButton
            iPadToolbarDivider
            iPadZoomControls
            iPadToolbarDivider
            iPadMacroToggleButton
            sourceMediaControls(style: .toolbar)
            iPadToolbarDivider
            overlayIconButton(systemImage: "chart.bar.xaxis", accessibilityLabel: "Stream Details") {
                showingStreamDetails = true
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var iPadSpaceSwitchingControls: some View {
        HStack(spacing: 2) {
            iPadToolbarDivider
            overlayIconButton(
                systemImage: "chevron.left.2",
                accessibilityLabel: "Previous Mac Space"
            ) {
                runtimeSession.switchSpaceLeft()
            }
            iPadToolbarDivider
            overlayIconButton(
                systemImage: "chevron.right.2",
                accessibilityLabel: "Next Mac Space"
            ) {
                runtimeSession.switchSpaceRight()
            }
        }
    }

    private var iPadZoomControls: some View {
        HStack(spacing: 2) {
            zoomOutControlButton
            iPadToolbarDivider
            zoomResetControlButton
            iPadToolbarDivider
            zoomInControlButton
        }
    }

    private var iPadMacroToggleButton: some View {
        overlayIconButton(
            systemImage: "keyboard.badge.ellipsis",
            accessibilityLabel: showIPadMacroControls ? "Hide keyboard controls" : "Show keyboard controls",
            isActive: showIPadMacroControls || !heldMacroCommands.isEmpty
        ) {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                showIPadMacroControls.toggle()
            }
        }
    }

    private var iPadToolbarDivider: some View {
        Divider()
            .frame(height: 26)
            .padding(.horizontal, 4)
    }

    private var effectiveIPadToolbarSize: CGSize {
        guard iPadToolbarSize != .zero else {
            return CGSize(
                width: isExternalKeyboardConnected ? 250 : 304,
                height: 44
            )
        }

        return iPadToolbarSize
    }

    private func iPadToolbarPosition(in containerSize: CGSize) -> CGPoint {
        iPadToolbarPosition(
            for: iPadToolbarSnapTarget,
            in: containerSize,
            toolbarSize: effectiveIPadToolbarSize
        )
    }

    private func iPadToolbarPosition(
        for target: IPadToolbarSnapTarget,
        in containerSize: CGSize,
        toolbarSize: CGSize
    ) -> CGPoint {
        let horizontalInset: CGFloat = 18
        let verticalInset: CGFloat = 12
        let halfWidth = toolbarSize.width / 2
        let halfHeight = toolbarSize.height / 2
        let fitsHorizontally = containerSize.width >= toolbarSize.width + (horizontalInset * 2)
        let fitsVertically = containerSize.height >= toolbarSize.height + (verticalInset * 2)
        let leadingX = fitsHorizontally ? horizontalInset + halfWidth : containerSize.width / 2
        let trailingX = fitsHorizontally ? containerSize.width - horizontalInset - halfWidth : containerSize.width / 2
        let topY = fitsVertically ? verticalInset + halfHeight : containerSize.height / 2
        let bottomY = fitsVertically ? containerSize.height - verticalInset - halfHeight : containerSize.height / 2

        switch target {
        case .topLeading:
            return CGPoint(x: leadingX, y: topY)
        case .top:
            return CGPoint(x: containerSize.width / 2, y: topY)
        case .topTrailing:
            return CGPoint(x: trailingX, y: topY)
        case .bottomLeading:
            return CGPoint(x: leadingX, y: bottomY)
        case .bottom:
            return CGPoint(x: containerSize.width / 2, y: bottomY)
        case .bottomTrailing:
            return CGPoint(x: trailingX, y: bottomY)
        }
    }

    private func nearestIPadToolbarSnapTarget(
        to point: CGPoint,
        in containerSize: CGSize
    ) -> IPadToolbarSnapTarget {
        let toolbarSize = effectiveIPadToolbarSize

        return IPadToolbarSnapTarget.allCases.min { lhs, rhs in
            let lhsPosition = iPadToolbarPosition(
                for: lhs,
                in: containerSize,
                toolbarSize: toolbarSize
            )
            let rhsPosition = iPadToolbarPosition(
                for: rhs,
                in: containerSize,
                toolbarSize: toolbarSize
            )
            let lhsDistance = pow(lhsPosition.x - point.x, 2) + pow(lhsPosition.y - point.y, 2)
            let rhsDistance = pow(rhsPosition.x - point.x, 2) + pow(rhsPosition.y - point.y, 2)
            return lhsDistance < rhsDistance
        } ?? .topLeading
    }

    private func iPadToolbarDragGesture(in containerSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                if !isIPadToolbarDragging {
                    isIPadToolbarDragging = true
                }

                if iPadToolbarDragTranslation != value.translation {
                    iPadToolbarDragTranslation = value.translation
                }
            }
            .onEnded { value in
                let currentPosition = iPadToolbarPosition(in: containerSize)
                let releasedPosition = CGPoint(
                    x: currentPosition.x + value.translation.width,
                    y: currentPosition.y + value.translation.height
                )
                let snapTarget = nearestIPadToolbarSnapTarget(
                    to: releasedPosition,
                    in: containerSize
                )
                let snappedPosition = iPadToolbarPosition(
                    for: snapTarget,
                    in: containerSize,
                    toolbarSize: effectiveIPadToolbarSize
                )
                let retainedDropOffset = CGSize(
                    width: releasedPosition.x - snappedPosition.x,
                    height: releasedPosition.y - snappedPosition.y
                )
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true

                withTransaction(transaction) {
                    iPadToolbarSnapTarget = snapTarget
                    iPadToolbarDragTranslation = retainedDropOffset
                }

                DispatchQueue.main.async {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        iPadToolbarDragTranslation = .zero
                        isIPadToolbarDragging = false
                    }
                }
            }
    }

    private var iPadMacroControlsStrip: some View {
        iPadMacroControlsContents
            .fixedSize(horizontal: true, vertical: false)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.14), radius: 12, y: 6)
    }

    private var iPadMacroControlsContents: some View {
        HStack(spacing: 8) {
            modifierControlButton("fn", command: .function)
            modifierControlButton("control", command: .control)
            modifierControlButton("option", command: .option)
            modifierControlButton("command", command: .command)
            modifierControlButton("shift", command: .shift)

            Divider()
                .frame(height: 28)

            macroKeyButton("Esc", command: .escape)
            macroKeyButton("Tab", command: .tab)
            macroKeyButton("Space", command: .space)
            macroKeyButton("Delete", command: .backspace)
            macroKeyButton("Return", command: .enter)

            Divider()
                .frame(height: 28)

            macroKeyButton("←", command: .leftArrow)
            macroKeyButton("↑", command: .upArrow)
            macroKeyButton("↓", command: .downArrow)
            macroKeyButton("→", command: .rightArrow)

            if !heldMacroCommands.isEmpty {
                Button("Clear") {
                    heldMacroCommands.removeAll()
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            }
        }
        .padding(8)
    }

    private var phoneControlsOverlay: some View {
        ZStack(alignment: .bottomTrailing) {
            if showPhoneControls {
                Color.black.opacity(0.12)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showPhoneControls = false
                        }
                    }
            }

            VStack(alignment: .trailing, spacing: 10) {
                if showPhoneControls {
                    phoneControlPanel
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if gameControllerInput.hasSupportedController && !showPhoneControls {
                    PeelGameControllerHelpButton(ownerID: gameControllerOwnerID)
                        .background(.regularMaterial, in: Circle())
                        .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
                }

                overlayIconButton(
                    systemImage: showPhoneControls ? "xmark" : "ellipsis",
                    accessibilityLabel: showPhoneControls ? "Close controls" : "Show controls",
                    isActive: showPhoneControls
                ) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        showPhoneControls.toggle()
                    }
                }
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    private var phoneControlPanel: some View {
        let actionColumns = [
            GridItem(.adaptive(minimum: 76), spacing: 8)
        ]
        let modifierColumns = Array(
            repeating: GridItem(.flexible(), spacing: 8),
            count: 5
        )
        let keyColumns = Array(
            repeating: GridItem(.flexible(), spacing: 8),
            count: 4
        )

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    ornamentStatus
                    Spacer(minLength: 8)

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showPhoneControls = false
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close controls")
                }

                LazyVGrid(columns: actionColumns, spacing: 8) {
                    phoneActionButton("Stream Details", systemImage: "chart.bar.xaxis") {
                        showPhoneControls = false
                        showingStreamDetails = true
                    }
                    phoneActionButton("Peel Pro", systemImage: "rectangle.grid.2x2") {
                        showPhoneControls = false
                        returnToBrowser()
                    }
                    if supportsSpaceSwitching && isDisplayCaptureWindow(presentedWindow) {
                        phoneActionButton("Space Left", systemImage: "chevron.left.2") {
                            runtimeSession.switchSpaceLeft()
                        }
                        phoneActionButton("Space Right", systemImage: "chevron.right.2") {
                            runtimeSession.switchSpaceRight()
                        }
                    }
                    phoneActionButton(
                        activeClickButton == .right ? "Right Click" : "Left Click",
                        systemImage: "cursorarrow.click",
                        isActive: activeClickButton == .right
                    ) {
                        toggleClickMode()
                    }
                    phoneActionButton(
                        keyboardEnabled ? "Hide Keys" : "Keyboard",
                        systemImage: keyboardEnabled ? "keyboard.chevron.compact.down" : "keyboard",
                        isActive: keyboardEnabled
                    ) {
                        toggleSoftwareKeyboard()
                    }
                    phoneActionButton("Zoom Out", systemImage: "minus.magnifyingglass") {
                        zoomOut()
                    }
                    phoneActionButton("Reset", systemImage: "arrow.counterclockwise") {
                        setZoomScale(1.0)
                    }
                    phoneActionButton("Zoom In", systemImage: "plus.magnifyingglass") {
                        zoomIn()
                    }
                }

                sourceMediaControls(style: .panel)

                controlSectionHeader("Macro modifiers")

                LazyVGrid(columns: modifierColumns, spacing: 8) {
                    modifierControlButton("fn", command: .function)
                    modifierControlButton("⌃", command: .control)
                    modifierControlButton("⌥", command: .option)
                    modifierControlButton("⌘", command: .command)
                    modifierControlButton("⇧", command: .shift)
                }

                if !heldMacroCommands.isEmpty {
                    Button("Clear held modifiers") {
                        heldMacroCommands.removeAll()
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                controlSectionHeader("Keys")

                LazyVGrid(columns: keyColumns, spacing: 8) {
                    macroKeyButton("Esc", command: .escape)
                    macroKeyButton("Tab", command: .tab)
                    macroKeyButton("Space", command: .space)
                    macroKeyButton("Delete", command: .backspace)
                    macroKeyButton("Return", command: .enter)
                    macroKeyButton("←", command: .leftArrow)
                    macroKeyButton("↑", command: .upArrow)
                    macroKeyButton("↓", command: .downArrow)
                    macroKeyButton("→", command: .rightArrow)
                }
            }
            .padding(14)
        }
        .frame(maxWidth: 390, maxHeight: 520)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.24), radius: 20, y: 10)
    }

    private var clickModeControlButton: some View {
        overlayIconButton(
            systemImage: "cursorarrow.click",
            accessibilityLabel: activeClickButton.accessibilityLabel,
            isActive: activeClickButton == .right
        ) {
            toggleClickMode()
        }
        .overlay(alignment: .bottomTrailing) {
            Text(activeClickButton == .right ? "R" : "L")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(activeClickButton == .right ? Color.orange : Color.secondary)
                .padding(4)
        }
    }

    private var keyboardControlButton: some View {
        overlayIconButton(
            systemImage: keyboardEnabled ? "keyboard.chevron.compact.down" : "keyboard",
            accessibilityLabel: keyboardEnabled ? "Hide keyboard" : "Show keyboard",
            isActive: keyboardEnabled
        ) {
            toggleSoftwareKeyboard()
        }
    }

    private var zoomOutControlButton: some View {
        overlayIconButton(
            systemImage: "minus.magnifyingglass",
            accessibilityLabel: "Zoom out"
        ) {
            zoomOut()
        }
    }

    private var zoomResetControlButton: some View {
        Button {
            guard !isIPadToolbarDragging else { return }
            setZoomScale(1.0)
        } label: {
            Text("\(Int((zoomScale * 100).rounded()))%")
                .font(.caption.monospacedDigit().weight(.semibold))
                .frame(minWidth: 48, minHeight: 42)
                .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(zoomScale > 1.0001 ? Color.accentColor : Color.secondary)
        .accessibilityLabel("Reset zoom")
    }

    private var zoomInControlButton: some View {
        overlayIconButton(
            systemImage: "plus.magnifyingglass",
            accessibilityLabel: "Zoom in"
        ) {
            zoomIn()
        }
    }

    private func overlayIconButton(
        systemImage: String,
        accessibilityLabel: String,
        isActive: Bool = false,
        foregroundColor: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            guard !isIPadToolbarDragging else { return }
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(foregroundColor ?? (isActive ? Color.accentColor : Color.primary))
                .frame(width: 42, height: 42)
                .background(
                    isActive ? Color.accentColor.opacity(0.16) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func phoneActionButton(
        _ title: String,
        systemImage: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))

                Text(title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isActive ? Color.accentColor : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(
                isActive ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func controlSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func modifierControlButton(_ title: String, command: KeyboardCommand) -> some View {
        let isActive = heldMacroCommands.contains(command)

        return Button {
            toggleHeldMacroCommand(command)
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 38)
                .padding(.horizontal, 7)
                .background(
                    isActive ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isActive ? "Held" : "Not held")
    }

    private func macroKeyButton(_ title: String, command: KeyboardCommand) -> some View {
        Button {
            sendKeyboardControlCommand(command)
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: 38)
                .padding(.horizontal, 7)
                .background(
                    Color.primary.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func openingAppName(for window: PeelWindow) -> String {
        windowChromeTitle(for: window)
    }
    
    private func statusLabel(_ status: WindowStreamStatus) -> String {
        switch status {
        case .active:
            return "Active"
        case .sleeping:
            return "Standby"
        case .offline:
            return "No signal"
        }
    }
    
    private func userFacingInputRejectionMessage(for rejection: InputRejectedMessage) -> String {
        let reason = rejection.reason.lowercased()

        if reason.contains("foreground") || reason.contains("top window") ||
            reason.contains("not frontmost") || reason.contains("activation") ||
            reason.contains("focus") {
            return "Tap once to bring this window forward."
        }

        if reason.contains("disabled") {
            return "Enable remote input in the host app."
        }

        if reason.contains("uipi") || reason.contains("higher-integrity") {
            return "Windows blocked input to this elevated window."
        }

        if reason.contains("accessibility") {
            return "Allow Peel Pro to control the connected computer in its system settings."
        }

        return "Peel Pro could not send that input yet."
    }

    private func returnToBrowser(userInitiated: Bool = true) {
        guard !isOpeningHome, !isReturningToBrowser else { return }

        if let workspaceReturnToBrowser {
            workspaceReturnToBrowser()
            return
        }

        isReturningToBrowser = true
        runtimeSession.forceMouseUpIfNeeded(reason: "returning to browser")

        for popup in popupWindowStack {
            if runtimeSession.isAutoPopupWindow(popup.windowId) {
                runtimeSession.clearAutoPopupTracking(for: popup.windowId)
            }
        }

        if runtimeSession.isAutoPopupWindow(rootWindow.windowId) {
            runtimeSession.clearAutoPopupTracking(for: rootWindow.windowId)
        }

#if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            dismiss()
            return
        }
#endif

        isOpeningHome = true

        let activatedExistingMain = scenes.activateMainIfPossible()

        if !activatedExistingMain && scenes.shouldPresentMainSceneFromUserAction() {
            openWindow(id: "main")
            didRestoreBrowserWindow = true
        }

        if !userInitiated {
            dismiss()
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            isOpeningHome = false
            if userInitiated {
                isReturningToBrowser = false
            }
        }
    }
    
    private var ornamentModes: some View {
        HStack(spacing: 10) {
            Button {
                toggleSoftwareKeyboard()
            } label: {
                Image(systemName: keyboardEnabled ? "keyboard.chevron.compact.down" : "keyboard")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(keyboardEnabled ? "Hide keyboard" : "Show keyboard")
        }
    }

    private struct KeyboardHardwareKey {
        let keyCode: Int
        let characters: String?
        let charactersIgnoringModifiers: String?
    }

    private func toggleClickMode() {
        activeClickButton = activeClickButton == .left ? .right : .left
    }

    private func toggleSoftwareKeyboard() {
        let shouldEnable = !keyboardEnabled
        setSoftwareKeyboardActive(shouldEnable)

        if shouldEnable {
            if isPhone {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showPhoneControls = false
                }
            }
        }
    }

    private var isKeyboardSceneEligible: Bool {
        guard workspaceAllowsInput, workspaceIsVisible, workspaceInputAdmission(),
              scenePhase == .active, let currentScene else { return false }
        return currentScene.activationState == .foregroundActive &&
            currentScene.windows.contains(where: { $0.isKeyWindow })
    }

    private var isKeyboardInputOwner: Bool {
        isKeyboardSceneEligible && runtimeSession.activeWindowId == presentedWindow.windowId
    }

    /// Offers game controller input for this view's presented window. Only the
    /// foreground key scene's selected, visible, admitted pane may claim it, and
    /// only for its exact owning session; passive scenes and panes never offer.
    private func syncGameControllerInputOwner() {
        let window = presentedWindow
        let key = hostKey
        guard isKeyboardSceneEligible,
              let session = workspaceSession ?? PeelControllerSessionResolution.owningSession(
                  hostKeyRawValue: key?.rawValue,
                  exact: { key.flatMap { browser.session(for: $0) } },
                  selected: { browser.selectedSession }
              ),
              session.activeWindowId == window.windowId else {
            gameControllerInput.release(owner: gameControllerOwnerID)
            return
        }

        let admission = workspaceInputAdmission
        let scene = currentScene
        gameControllerInput.offer(
            owner: gameControllerOwnerID,
            session: session,
            window: window,
            scene: scene,
            preempt: true,
            admission: { [weak scene] in
                guard let scene else { return false }
                return admission() &&
                    scene.activationState == .foregroundActive &&
                    scene.windows.contains(where: { $0.isKeyWindow })
            }
        )
    }

    private func refreshKeyboardInputOwnership() {
        guard isKeyboardSceneEligible else { return }
        if keyboardEnabled {
            setSoftwareKeyboardActive(true)
        } else {
            refreshExternalInputState(autoEnableKeyboard: true)
        }
    }

    private func refreshExternalInputState(autoEnableKeyboard: Bool) {
        let hasExternalKeyboard = GCKeyboard.coalesced != nil
        let hasExternalPointingDevice = !GCMouse.mice().isEmpty

        if isExternalKeyboardConnected != hasExternalKeyboard {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExternalKeyboardConnected = hasExternalKeyboard
            }
        }

        // Device connection notifications reach every restored scene. Only the
        // already selected, eligible scene may claim input automatically.
        if autoEnableKeyboard && isKeyboardInputOwner &&
            (hasExternalKeyboard || hasExternalPointingDevice) {
            setSoftwareKeyboardActive(true)
        }
    }

    private func setSoftwareKeyboardActive(_ isActive: Bool) {
        if keyboardEnabled != isActive { keyboardEnabled = isActive }
        if keyboardFocused != isActive { keyboardFocused = isActive }
        if isFocusedBridge != isActive { isFocusedBridge = isActive }

        guard isActive, isKeyboardSceneEligible else { return }

        runtimeSession.setActiveWindow(presentedWindow.windowId)
        keyboardFocusRequestID += 1
    }

    private func handleKeyboardFocusChanged(_ isFocused: Bool) {
        // Responder callbacks already arrive on main. A second queued hop can
        // apply an old resign after a new explicit keyboard request.
        guard isKeyboardInputOwner else { return }
        if keyboardEnabled != isFocused { keyboardEnabled = isFocused }
        if keyboardFocused != isFocused { keyboardFocused = isFocused }
        if isFocusedBridge != isFocused { isFocusedBridge = isFocused }
    }

    private func zoomIn() {
        setZoomScale(zoomScale * 1.25)
    }

    private func zoomOut() {
        setZoomScale(zoomScale / 1.25)
    }

    private func setZoomScale(_ proposedScale: CGFloat) {
        let clampedScale = min(max(proposedScale, 1.0), maxZoomScale)
        zoomScale = clampedScale
        baseZoomScale = clampedScale

        if clampedScale <= 1.0001 {
            contentOffset = .zero
            baseContentOffset = .zero
        }
    }

    private func toggleHeldMacroCommand(_ command: KeyboardCommand) {
        if let index = heldMacroCommands.firstIndex(of: command) {
            heldMacroCommands.remove(at: index)
        } else {
            heldMacroCommands.append(command)
        }
    }

    private func prepareKeyboardControlTarget() {
        if runtimeSession.activeWindowId != presentedWindow.windowId {
            runtimeSession.setActiveWindow(presentedWindow.windowId)
        } else if !isInputReadyForWindow(presentedWindow) {
            runtimeSession.requestHostFocusForWindow(presentedWindow.windowId)
        }
    }

    private func handleKeyboardTextInput(_ text: String) {
        guard !text.isEmpty else { return }

        prepareKeyboardControlTarget()

        guard !heldMacroCommands.isEmpty else {
            runtimeSession.sendKeyboardText(text)
            return
        }

        for character in text {
            guard let key = keyboardHardwareKey(for: character) else {
                runtimeSession.sendKeyboardText(String(character))
                continue
            }

            runtimeSession.sendKeyboardHardwareKey(
                keyCode: key.keyCode,
                characters: key.characters,
                charactersIgnoringModifiers: key.charactersIgnoringModifiers,
                modifiers: heldMacroCommands
            )
        }
    }

    private func sendKeyboardControlCommand(_ command: KeyboardCommand) {
        prepareKeyboardControlTarget()

        if !heldMacroCommands.isEmpty,
           let key = keyboardHardwareKey(for: command) {
            runtimeSession.sendKeyboardHardwareKey(
                keyCode: key.keyCode,
                characters: key.characters,
                charactersIgnoringModifiers: key.charactersIgnoringModifiers,
                modifiers: heldMacroCommands
            )
            return
        }

        runtimeSession.sendKeyboardCommand(command)
    }

    private func keyboardHardwareKey(for command: KeyboardCommand) -> KeyboardHardwareKey? {
        switch command {
        case .escape:
            return KeyboardHardwareKey(keyCode: 0x29, characters: nil, charactersIgnoringModifiers: nil)
        case .tab:
            return KeyboardHardwareKey(keyCode: 0x2B, characters: "\t", charactersIgnoringModifiers: "\t")
        case .space:
            return KeyboardHardwareKey(keyCode: 0x2C, characters: " ", charactersIgnoringModifiers: " ")
        case .enter, .returnKey:
            return KeyboardHardwareKey(keyCode: 0x28, characters: "\r", charactersIgnoringModifiers: "\r")
        case .backspace, .delete:
            return KeyboardHardwareKey(keyCode: 0x2A, characters: nil, charactersIgnoringModifiers: nil)
        case .forwardDelete:
            return KeyboardHardwareKey(keyCode: 0x4C, characters: nil, charactersIgnoringModifiers: nil)
        case .leftArrow:
            return KeyboardHardwareKey(keyCode: 0x50, characters: nil, charactersIgnoringModifiers: nil)
        case .rightArrow:
            return KeyboardHardwareKey(keyCode: 0x4F, characters: nil, charactersIgnoringModifiers: nil)
        case .upArrow:
            return KeyboardHardwareKey(keyCode: 0x52, characters: nil, charactersIgnoringModifiers: nil)
        case .downArrow:
            return KeyboardHardwareKey(keyCode: 0x51, characters: nil, charactersIgnoringModifiers: nil)
        default:
            return nil
        }
    }

    private func keyboardHardwareKey(for character: Character) -> KeyboardHardwareKey? {
        let text = String(character)
        let lower = text.lowercased()

        if let scalar = lower.unicodeScalars.first, lower.unicodeScalars.count == 1 {
            let value = scalar.value

            if value >= 97 && value <= 122 {
                return KeyboardHardwareKey(
                    keyCode: Int(value - 97 + 0x04),
                    characters: lower,
                    charactersIgnoringModifiers: lower
                )
            }

            if value >= 49 && value <= 57 {
                return KeyboardHardwareKey(
                    keyCode: Int(value - 49 + 0x1E),
                    characters: lower,
                    charactersIgnoringModifiers: lower
                )
            }

            if value == 48 {
                return KeyboardHardwareKey(
                    keyCode: 0x27,
                    characters: lower,
                    charactersIgnoringModifiers: lower
                )
            }
        }

        switch lower {
        case " ": return KeyboardHardwareKey(keyCode: 0x2C, characters: " ", charactersIgnoringModifiers: " ")
        case "-", "_": return KeyboardHardwareKey(keyCode: 0x2D, characters: "-", charactersIgnoringModifiers: "-")
        case "=", "+": return KeyboardHardwareKey(keyCode: 0x2E, characters: "=", charactersIgnoringModifiers: "=")
        case "[", "{": return KeyboardHardwareKey(keyCode: 0x2F, characters: "[", charactersIgnoringModifiers: "[")
        case "]", "}": return KeyboardHardwareKey(keyCode: 0x30, characters: "]", charactersIgnoringModifiers: "]")
        case "\\", "|": return KeyboardHardwareKey(keyCode: 0x31, characters: "\\", charactersIgnoringModifiers: "\\")
        case ";", ":": return KeyboardHardwareKey(keyCode: 0x33, characters: ";", charactersIgnoringModifiers: ";")
        case "'", "\"": return KeyboardHardwareKey(keyCode: 0x34, characters: "'", charactersIgnoringModifiers: "'")
        case "`", "~": return KeyboardHardwareKey(keyCode: 0x35, characters: "`", charactersIgnoringModifiers: "`")
        case ",", "<": return KeyboardHardwareKey(keyCode: 0x36, characters: ",", charactersIgnoringModifiers: ",")
        case ".", ">": return KeyboardHardwareKey(keyCode: 0x37, characters: ".", charactersIgnoringModifiers: ".")
        case "/", "?": return KeyboardHardwareKey(keyCode: 0x38, characters: "/", charactersIgnoringModifiers: "/")
        default: return nil
        }
    }

    // MARK: - Layouts
    
    /// Minimal layout: just the peeled window, no extra card/chrome.
    private var framelessLayout: some View {
        GeometryReader { geo in
            let activeWindow = presentedWindow
            let cgImage = runtimeSession.snapshotCGImage(for: activeWindow.windowId)
            let videoRenderer = runtimeSession.videoRenderer(for: activeWindow.windowId)
            let videoSize = runtimeSession.videoContentSize(for: activeWindow.windowId)
            let canShowVideo = videoRenderer != nil && runtimeSession.videoReadyWindowIds.contains(activeWindow.windowId)

            let fallbackAspect = (CGFloat(activeWindow.width) / max(1, CGFloat(activeWindow.height)))
            let contentAspect: CGFloat = {
                if let videoSize, videoSize.width > 0, videoSize.height > 0 {
                    return videoSize.width / max(1, videoSize.height)
                }

                if let cgImage {
                    return CGFloat(cgImage.width) / max(1, CGFloat(cgImage.height))
                }

                return fallbackAspect
            }()
            let viewport = ClientViewportTransform(
                viewSize: geo.size,
                contentAspect: contentAspect,
                zoomScale: zoomScale,
                contentOffset: contentOffset,
                clickCalibrationOffset: clickCalibrationOffset
            )
            let shouldFillUnlockedWindow = false
            let renderRect = shouldFillUnlockedWindow
                ? CGRect(origin: .zero, size: geo.size)
                : viewport.fittedContentRect
            ZStack {
                if let videoRenderer, canShowVideo {
                    let cornerRadius: CGFloat = 24

                    CompressedVideoLayerView(renderer: videoRenderer)
                        .frame(
                            width: renderRect.width,
                            height: renderRect.height,
                            alignment: .center
                        )
                        .scaleEffect(shouldFillUnlockedWindow ? 1.0 : zoomScale)
                        .offset(shouldFillUnlockedWindow ? .zero : contentOffset)
                        .position(
                            x: renderRect.midX,
                            y: renderRect.midY
                        )
                        .clipShape(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        )
                        .contentShape(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        )
                        .overlay(
                            Group {
                                if runtimeSession.activeWindowId == activeWindow.windowId {
                                    IndirectScrollCapture(targetWindowId: activeWindow.windowId, isActive: scenePhase == .active && runtimeSession.isConnectionReady) { dx, dy in
                                        if zoomScale > 1.0001 {
                                            let proposed = CGSize(
                                                width: contentOffset.width + dx,
                                                height: contentOffset.height + dy
                                            )
                                            let transform = ClientViewportTransform(
                                                viewSize: geo.size,
                                                contentAspect: contentAspect,
                                                zoomScale: zoomScale,
                                                contentOffset: proposed,
                                                clickCalibrationOffset: clickCalibrationOffset
                                            )
                                            let clamped = transform.clampedOffset(proposed)
                                            contentOffset = clamped
                                            baseContentOffset = clamped
                                        } else {
                                            runtimeSession.sendScroll(on: activeWindow, deltaX: dx, deltaY: dy)
                                        }
                                    }
                                }
                            }
                        )
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    handleDirectWindowGestureChanged(
                                        value,
                                        in: geo.size,
                                        contentAspect: contentAspect,
                                        viewport: viewport
                                    )
                                }
                                .onEnded { value in
                                    handleDirectWindowGestureEnded(
                                        value,
                                        in: geo.size,
                                        contentAspect: contentAspect,
                                        viewport: viewport
                                    )
                                }
                        )
                        .simultaneousGesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    let newScale = min(max(baseZoomScale * value, 1.0), maxZoomScale)
                                    zoomScale = newScale

                                    let transform = ClientViewportTransform(
                                        viewSize: geo.size,
                                        contentAspect: contentAspect,
                                        zoomScale: newScale,
                                        contentOffset: contentOffset,
                                        clickCalibrationOffset: clickCalibrationOffset
                                    )
                                    contentOffset = transform.clampedOffset(contentOffset)
                                }
                                .onEnded { value in
                                    let finalScale = min(max(baseZoomScale * value, 1.0), maxZoomScale)

                                    if finalScale <= 1.0001 {
                                        zoomScale = 1.0
                                        baseZoomScale = 1.0
                                        contentOffset = .zero
                                        baseContentOffset = .zero
                                    } else {
                                        zoomScale = finalScale
                                        baseZoomScale = finalScale

                                        let transform = ClientViewportTransform(
                                            viewSize: geo.size,
                                            contentAspect: contentAspect,
                                            zoomScale: finalScale,
                                            contentOffset: contentOffset,
                                            clickCalibrationOffset: clickCalibrationOffset
                                        )
                                        let clamped = transform.clampedOffset(contentOffset)
                                        contentOffset = clamped
                                        baseContentOffset = clamped
                                    }
                                }
                        )
                        .simultaneousGesture(
                            mouseDragGesture(in: geo.size, contentAspect: contentAspect)
                        )
                } else if let cgImage {
                    let cornerRadius: CGFloat = 24 // tweak to match iPad window radius

                    ZStack {
                        Image(decorative: cgImage, scale: 1.0, orientation: .up)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentAspect, contentMode: shouldFillUnlockedWindow ? .fill : .fit)
                            .frame(
                                width: renderRect.width,
                                height: renderRect.height,
                                alignment: .center
                            )
                            .scaleEffect(shouldFillUnlockedWindow ? 1.0 : zoomScale)
                            .offset(shouldFillUnlockedWindow ? .zero : contentOffset)
                            .drawingGroup()
                    }
                    .frame(
                        width: renderRect.width,
                        height: renderRect.height,
                        alignment: .center
                    )
                    .position(
                        x: renderRect.midX,
                        y: renderRect.midY
                    )
                    .clipShape(
                        RoundedRectangle(cornerRadius: cornerRadius,
                                         style: .continuous)
                    )
                    .contentShape(
                        RoundedRectangle(cornerRadius: cornerRadius,
                                         style: .continuous)
                    )
                    .overlay(
                        Group {
                            if runtimeSession.activeWindowId == activeWindow.windowId {
                                IndirectScrollCapture(targetWindowId: activeWindow.windowId, isActive: scenePhase == .active && runtimeSession.isConnectionReady) { dx, dy in
                                    if zoomScale > 1.0001 {
                                        let proposed = CGSize(
                                            width: contentOffset.width + dx,
                                            height: contentOffset.height + dy
                                        )
                                        let transform = ClientViewportTransform(
                                            viewSize: geo.size,
                                            contentAspect: contentAspect,
                                            zoomScale: zoomScale,
                                            contentOffset: proposed,
                                            clickCalibrationOffset: clickCalibrationOffset
                                        )
                                        let clamped = transform.clampedOffset(proposed)
                                        contentOffset = clamped
                                        baseContentOffset = clamped
                                    } else {
                                        runtimeSession.sendScroll(on: activeWindow, deltaX: dx, deltaY: dy)
                                    }
                                }
                            }
                        }
                    )
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                handleDirectWindowGestureChanged(
                                    value,
                                    in: geo.size,
                                    contentAspect: contentAspect,
                                    viewport: viewport
                                )
                            }
                            .onEnded { value in
                                handleDirectWindowGestureEnded(
                                    value,
                                    in: geo.size,
                                    contentAspect: contentAspect,
                                    viewport: viewport
                                )
                            }
                    )
                    .simultaneousGesture(
                        MagnificationGesture()
                            .onChanged { value in
                                let newScale = min(max(baseZoomScale * value, 1.0), maxZoomScale)
                                zoomScale = newScale

                                let transform = ClientViewportTransform(
                                    viewSize: geo.size,
                                    contentAspect: contentAspect,
                                    zoomScale: newScale,
                                    contentOffset: contentOffset,
                                    clickCalibrationOffset: clickCalibrationOffset
                                )
                                contentOffset = transform.clampedOffset(contentOffset)
                            }
                            .onEnded { value in
                                let finalScale = min(max(baseZoomScale * value, 1.0), maxZoomScale)

                                if finalScale <= 1.0001 {
                                    zoomScale = 1.0
                                    baseZoomScale = 1.0
                                    contentOffset = .zero
                                    baseContentOffset = .zero
                                } else {
                                    zoomScale = finalScale
                                    baseZoomScale = finalScale

                                    let transform = ClientViewportTransform(
                                        viewSize: geo.size,
                                        contentAspect: contentAspect,
                                        zoomScale: finalScale,
                                        contentOffset: contentOffset,
                                        clickCalibrationOffset: clickCalibrationOffset
                                    )
                                    let clamped = transform.clampedOffset(contentOffset)
                                    contentOffset = clamped
                                    baseContentOffset = clamped
                                }
                            }
                    )
                    .simultaneousGesture(
                        mouseDragGesture(in: geo.size, contentAspect: contentAspect)
                    )
                } else {
                    ZStack(alignment: .center) {
                        VStack(spacing: 12) {
                            PeelLoadingView(
                                header: runtimeSession.isConnectionReady ? "Opening \(openingAppName(for: activeWindow))" : "Connection lost",
                                subhead: runtimeSession.isConnectionReady
                                    ? ""
                                    : "Return to the Peel Pro menu and reconnect to your computer.",
                                delayedHeader: runtimeSession.isConnectionReady ? "Still waiting for \(openingAppName(for: activeWindow))" : nil,
                                delayedSubhead: runtimeSession.isConnectionReady
                                    ? "This is taking longer than expected. Close this window and try opening it again from the Peel Pro menu."
                                    : nil,
                                variant: runtimeSession.isConnectionReady ? .streaming : .connecting
                            )
                            /*
                            if let debugText = runtimeSession.hostStreamDebugText(for: activeWindow.windowId) {
                                Text(debugText)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(3)
                                    .frame(maxWidth: 420)
                            }
                            */
                        }

                        if !runtimeSession.isConnectionReady || showStuckStreamCloseButton {
                            Button {
                                dismiss()
                            } label: {
                                Text("Close window")
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.red)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 9)
                                    .background(.gray.opacity(0.22), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 400)
                            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .task(id: "\(activeWindow.windowId)-\(runtimeSession.isConnectionReady)-\(canShowVideo)-\(runtimeSession.streamStatus(for: activeWindow.windowId))") {
                        showStuckStreamCloseButton = false

                        if !runtimeSession.isConnectionReady || runtimeSession.streamStatus(for: activeWindow.windowId) == .offline {
                            try? await Task.sleep(for: .seconds(5))
                            guard !Task.isCancelled else { return }

                            if !runtimeSession.isConnectionReady || runtimeSession.streamStatus(for: activeWindow.windowId) == .offline {
                                dismiss()
                            }

                            return
                        }

                        try? await Task.sleep(for: .seconds(6))
                        guard !Task.isCancelled else { return }

                        withAnimation(.easeInOut(duration: 0.2)) {
                            showStuckStreamCloseButton = true
                        }
                    }
                }

                // Input rejection hint for this specific peeled window only. Display
                // streams remain input-ready without focus confirmation, so do not hide
                // a real Host rejection merely because their video is online.
                if let rejection = runtimeSession.inputRejectionByWindowId[activeWindow.windowId] {
                    VStack {
                        Text(userFacingInputRejectionMessage(for: rejection))
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .padding(.top, 12)
                        Spacer()
                    }
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .animation(
                        .easeInOut(duration: 0.15),
                        value: runtimeSession.inputRejectionByWindowId[activeWindow.windowId]?.timestamp
                    )
                }
#if DEBUG
                //if showDebugOverlay, lastFrameTimestamp != nil {
                  //  debugOverlay
                    //    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                //}
#endif

                if !runtimeSession.hostRendersCursor {
                    if isDirectCursorActive, let norm = tapCursorNorm {
                        let p = viewPoint(fromNorm: norm, in: geo.size, contentAspect: contentAspect)

                        tapCursorIndicator
                            .position(p)
                            .allowsHitTesting(false)
                    } else if let sharedCursor = runtimeSession.sharedCursor,
                              sharedCursor.isVisible,
                              sharedCursor.windowId == activeWindow.windowId {
                        let p = viewPoint(fromNorm: sharedCursor.norm, in: geo.size, contentAspect: contentAspect)

                        sharedCursorIndicator(for: sharedCursor.mode)
                            .position(p)
                            .allowsHitTesting(false)
                    } else if let norm = tapCursorNorm {
                        let p = viewPoint(fromNorm: norm, in: geo.size, contentAspect: contentAspect)

                        tapCursorIndicator
                            .position(p)
                            .allowsHitTesting(false)
                    }
                }

                if runtimeSession.activeWindowId == activeWindow.windowId {
                    indirectHoverOverlay(
                        activeWindow: activeWindow,
                        viewSize: geo.size,
                        contentAspect: contentAspect
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
#if DEBUG
            .onChange(of: runtimeSession.snapshotCGImages[activeWindow.windowId]) { _, newValue in
                if newValue != nil {
                    registerFrame()
                }
            }
#endif
        }
    }
    
    
    // MARK: - Input (letterboxed-aware mapping)

    private func indirectHoverOverlay(
        activeWindow: PeelWindow,
        viewSize: CGSize,
        contentAspect: CGFloat
    ) -> some View {
        IndirectHoverCapture { location in
            guard let location,
                  let norm = normPoint(for: location, in: viewSize, contentAspect: contentAspect) else {
                runtimeSession.hideSharedCursor(for: activeWindow.windowId)
                return
            }

            tapCursorHideWorkItem?.cancel()
            showSharedCursor(at: norm, mode: .hover)
            runtimeSession.sendMouseMove(
                on: activeWindow,
                normX: Double(norm.x),
                normY: Double(norm.y)
            )
        }
    }

    private func handleDirectWindowGestureChanged(
        _ value: DragGesture.Value,
        in size: CGSize,
        contentAspect: CGFloat,
        viewport: ClientViewportTransform
    ) {
        tapCursorHideWorkItem?.cancel()

        if let norm = viewport.normalizedPoint(for: value.location) {
            showDirectCursor(at: norm, localMode: .click, sharedMode: .hover)
        }

        if dragStartTime == nil {
            beginDirectScrollGesture()
            dragStartTime = Date()
            dragStartLocation = value.startLocation
            requestFocusForPresentedWindow(reason: "touch began")
        }

        if zoomScale > 1.0001 {
            contentOffset = viewport.pannedOffset(
                from: baseContentOffset,
                translation: value.translation
            )
            lastTranslation = .zero
            return
        }

        let dx = value.translation.width - lastTranslation.width
        let dy = value.translation.height - lastTranslation.height
        lastTranslation = value.translation

        let incrementalDelta = CGSize(width: dx, height: dy)
        guard !isMouseDragActive,
              let scrollDelta = directScrollDelta(
                totalTranslation: value.translation,
                incrementalDelta: incrementalDelta
              ) else {
            return
        }

        let activeWindow = presentedWindow
        guard isInputReadyForWindow(activeWindow) else {
            requestFocusForPresentedWindow(reason: "drag scroll")
            return
        }

        recordDirectScrollDelta(dx: scrollDelta.width, dy: scrollDelta.height)
        runtimeSession.sendScroll(
            on: activeWindow,
            deltaX: scrollDelta.width,
            deltaY: scrollDelta.height
        )
    }

    private func handleDirectWindowGestureEnded(
        _ value: DragGesture.Value,
        in size: CGSize,
        contentAspect: CGFloat,
        viewport: ClientViewportTransform
    ) {
        let endTime = Date()
        let duration = endTime.timeIntervalSince(dragStartTime ?? endTime)
        let totalDelta = hypot(value.translation.width, value.translation.height)
        let startLoc = dragStartLocation ?? value.location
        let dx = value.location.x - startLoc.x
        let dy = value.location.y - startLoc.y
        let startToEndDistance = hypot(dx, dy)

        defer {
            resetDirectScrollGesture()
            dragStartTime = nil
            dragStartLocation = nil
            endDirectCursorInteraction()
        }

        if zoomScale > 1.0001 {
            contentOffset = viewport.clampedOffset(contentOffset)
            baseContentOffset = contentOffset
        }

        if isMouseDragActive || mouseDragDidSendDown {
            return
        }

        if didDirectScrollDuringGesture {
            startDirectScrollInertia(on: presentedWindow)
        } else if duration >= longPressDuration,
           startToEndDistance < longPressMovementThreshold {
            sendClick(at: startLoc, in: size, contentAspect: contentAspect, button: "right")
        } else if totalDelta < clickThreshold {
            sendClick(at: value.location, in: size, contentAspect: contentAspect, button: activeClickButton.rawValue)
        }
    }

    private func beginDirectScrollGesture() {
        cancelDirectScrollInertia()
        resetDirectScrollGesture()
        tapCursorFeedbackMode = .click
    }

    private func resetDirectScrollGesture(preserveVelocity: Bool = false) {
        lastTranslation = .zero
        directScrollLastSampleTime = nil
        didDirectScrollDuringGesture = false
        directScrollAxis = nil

        if !preserveVelocity {
            directScrollVelocity = .zero
        }
    }


    private func directScrollDelta(totalTranslation: CGSize, incrementalDelta: CGSize) -> CGSize? {
        if directScrollAxis == nil {
            let absX = abs(totalTranslation.width)
            let absY = abs(totalTranslation.height)
            let distance = hypot(absX, absY)

            guard distance >= directScrollStartThreshold else {
                return nil
            }

            if absX > absY * directScrollAxisLockRatio {
                directScrollAxis = .horizontal
            } else {
                directScrollAxis = .vertical
            }
        }

        switch directScrollAxis {
        case .vertical:
            let dy = incrementalDelta.height
            guard abs(dy) > directScrollFrameNoiseThreshold else { return nil }
            return CGSize(width: 0, height: dy)

        case .horizontal:
            let dx = incrementalDelta.width
            guard abs(dx) > directScrollFrameNoiseThreshold else { return nil }
            return CGSize(width: dx, height: 0)

        case nil:
            return nil
        }
    }

    private func recordDirectScrollDelta(dx: CGFloat, dy: CGFloat) {
        let now = CACurrentMediaTime()

        if let lastSampleTime = directScrollLastSampleTime {
            let dt = CGFloat(now - lastSampleTime)

            if dt > 0.001 && dt < 0.2 {
                directScrollVelocity = CGSize(
                    width: dx / dt,
                    height: dy / dt
                )
            }
        }

        directScrollLastSampleTime = now
        didDirectScrollDuringGesture = true
    }

    private func startDirectScrollInertia(on activeWindow: PeelWindow) {
        let initialVelocity = directScrollVelocity
        let stopVelocityThreshold: CGFloat = 45

        guard abs(initialVelocity.width) > stopVelocityThreshold ||
                abs(initialVelocity.height) > stopVelocityThreshold else {
            resetDirectScrollGesture()
            return
        }

        directScrollInertiaTask?.cancel()
        let inertiaID = directScrollInertiaID + 1
        directScrollInertiaID = inertiaID

        directScrollInertiaTask = Task { @MainActor in
            var velocity = initialVelocity
            var lastTick = CACurrentMediaTime()
            let decelRate: CGFloat = 0.94

            while !Task.isCancelled && directScrollInertiaID == inertiaID {
                try? await Task.sleep(for: .milliseconds(16))

                guard !Task.isCancelled, directScrollInertiaID == inertiaID else {
                    break
                }

                guard runtimeSession.windows.contains(where: { $0.windowId == activeWindow.windowId }) else {
                    break
                }

                let now = CACurrentMediaTime()
                let dt = CGFloat(now - lastTick)
                lastTick = now

                guard dt > 0 else { continue }

                let dx = velocity.width * dt
                let dy = velocity.height * dt

                if abs(dx) > 0.01 || abs(dy) > 0.01 {
                    runtimeSession.sendScroll(on: activeWindow, deltaX: dx, deltaY: dy)
                }

                let decay = pow(decelRate, dt * 60.0)
                velocity.width *= decay
                velocity.height *= decay

                if abs(velocity.width) < stopVelocityThreshold &&
                    abs(velocity.height) < stopVelocityThreshold {
                    break
                }
            }

            if directScrollInertiaID == inertiaID {
                directScrollInertiaTask = nil
                directScrollVelocity = .zero
            }
        }
    }

    private func cancelPointerInteraction(reason: String) {
        cancelDirectScrollInertia()
        if workspaceMayReleasePointer(pointerInteractionID) {
            runtimeSession.forceMouseUpIfNeeded(reason: reason)
        }
        mouseDragDidSendDown = false
        mouseDragStartNorm = nil
        isMouseDragActive = false
        dragStartTime = nil
        dragStartLocation = nil
        resetDirectScrollGesture()
        endDirectCursorInteraction()
    }

    private func cancelDirectScrollInertia() {
        directScrollInertiaID += 1
        directScrollInertiaTask?.cancel()
        directScrollInertiaTask = nil
        directScrollVelocity = .zero
        directScrollLastSampleTime = nil
        directScrollAxis = nil
    }

    private func scheduleTapCursorHide(after delay: TimeInterval = 0.6) {
        tapCursorHideWorkItem?.cancel()
        let work = DispatchWorkItem { tapCursorNorm = nil }
        tapCursorHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    
    /// Map a tap/pinch location in the SwiftUI view to normalized coordinates
    /// inside the actual streamed window content (compensating for .scaledToFit
    /// letterboxing on either axis).
    private func sendClick(at location: CGPoint, in size: CGSize, contentAspect: CGFloat, button: String = "left") {
        guard size.width > 0, size.height > 0, contentAspect > 0 else {
            return
        }

        let viewport = viewportTransform(in: size, contentAspect: contentAspect)
        guard let norm = viewport.normalizedPoint(for: location) else {
            return
        }

        let activeWindow = presentedWindow

        guard isInputReadyForWindow(activeWindow) else {
            requestFocusForPresentedWindow(reason: "click")
            return
        }

        let nx = Double(norm.x)
        let ny = Double(norm.y)

        let sharedMode: PeelSharedCursorMode = button == "right" ? .rightClick : .click
        let localMode: InputCursorFeedbackMode = button == "right" ? .rightClick : .click
        showDirectCursor(at: norm, localMode: localMode, sharedMode: sharedMode)
        scheduleTapCursorHide(after: 0.6)

        runtimeSession.sendClick(on: activeWindow, normX: nx, normY: ny, button: button)

        if button == ActiveClickButton.right.rawValue && !rightClickModeStaysEnabled {
            activeClickButton = .left
        }
    }

    private func showLocalCursor(at norm: CGPoint, mode: InputCursorFeedbackMode) {
        isDirectCursorActive = true
        tapCursorNorm = norm
        tapCursorFeedbackMode = mode
    }

    private func showSharedCursor(at norm: CGPoint, mode: PeelSharedCursorMode = .hover) {
        tapCursorNorm = norm

        runtimeSession.showSharedCursor(
            for: presentedWindow.windowId,
            norm: norm,
            mode: mode
        )
    }

    private func showDirectCursor(
        at norm: CGPoint,
        localMode: InputCursorFeedbackMode,
        sharedMode: PeelSharedCursorMode = .hover
    ) {
        showLocalCursor(at: norm, mode: localMode)

        runtimeSession.showSharedCursor(
            for: presentedWindow.windowId,
            norm: norm,
            mode: sharedMode
        )
    }

    private func endDirectCursorInteraction() {
        isDirectCursorActive = false
    }

    private func syncLocalInputModeFromSharedCursor(_ sharedCursor: PeelSharedCursorState?) {
        guard let sharedCursor,
              sharedCursor.isVisible,
              sharedCursor.windowId == presentedWindow.windowId else {
            return
        }

        // Keep local mouse-down state in sync with the shared cursor without exposing
        // the Vision Pro L/R toggle or armed drag button on iPad/iPhone.
        switch sharedCursor.mode {
        case .drag:
            break
        case .rightClick, .hover, .click:
            releaseLocalMouseDownIfNeeded()
        }
    }

    private func releaseLocalMouseDownIfNeeded() {
        guard mouseDragDidSendDown || isMouseDragActive || mouseDragStartNorm != nil else {
            return
        }

        let activeWindow = presentedWindow
        let norm = tapCursorNorm ?? runtimeSession.currentSharedCursorNorm(for: activeWindow.windowId)

        if mouseDragDidSendDown && workspaceMayReleasePointer(pointerInteractionID) {
            runtimeSession.sendMouseUp(on: activeWindow,
                                normX: Double(norm.x),
                                normY: Double(norm.y),
                                button: "left")
        }

        mouseDragDidSendDown = false
        mouseDragStartNorm = nil
        isMouseDragActive = false
    }
    
    private func contentRect(in size: CGSize, contentAspect: CGFloat) -> CGRect {
        let viewAspect = size.width / max(size.height, 1)
        let windowAspect = contentAspect

        if viewAspect > windowAspect {
            let contentHeight = size.height
            let contentWidth = contentHeight * windowAspect
            let originX = (size.width - contentWidth) / 2
            return CGRect(x: originX, y: 0, width: contentWidth, height: contentHeight)
        } else {
            let contentWidth = size.width
            let contentHeight = contentWidth / windowAspect
            let originY = (size.height - contentHeight) / 2
            return CGRect(x: 0, y: originY, width: contentWidth, height: contentHeight)
        }
    }

    private func viewportTransform(in size: CGSize, contentAspect: CGFloat) -> ClientViewportTransform {
        ClientViewportTransform(
            viewSize: size,
            contentAspect: contentAspect,
            zoomScale: zoomScale,
            contentOffset: contentOffset,
            clickCalibrationOffset: clickCalibrationOffset
        )
    }
    
    /// Convert a normalized point (0–1) in content space (top-left origin)
    /// to a SwiftUI view point (in the GeometryReader coordinate space).
    //private func viewPoint(fromNorm norm: CGPoint, in //size: CGSize, contentAspect: CGFloat) -> CGPoint {
    //    let rect = contentRect(in: size, contentAspect: //contentAspect)
    //
    //    // norm is top-left origin, so no flipping here
    //    var x = rect.minX + (norm.x * rect.width)
    //    var y = rect.minY + (norm.y * rect.height)
    //
    //    // Apply the same calibration you use for clicks //so the cursor matches where clicks land.
    //    x = min(max(x + clickCalibrationOffset.width, //rect.minX), rect.maxX)
    //    y = min(max(y + clickCalibrationOffset.height, //rect.minY), rect.maxY)
    //
    //    return CGPoint(x: x, y: y)
    //}
    
    
    @ViewBuilder
    private var tapCursorIndicator: some View {
        Circle()
            .fill(.white.opacity(0.5))
            .frame(width: 22, height: 22)
            .shadow(radius: 2)
    }

    @ViewBuilder
    private func sharedCursorIndicator(for mode: PeelSharedCursorMode) -> some View {
        tapCursorIndicator
    }

    private func sharedCursorTint(for mode: PeelSharedCursorMode) -> Color {
        switch mode {
        case .hover:
            return .white
        case .click:
            return .white
        case .drag:
            return .green
        case .rightClick:
            return .orange
        }
    }

    @ViewBuilder
    private func sharedCursorGlyph(for mode: PeelSharedCursorMode, tint: Color) -> some View {
        switch mode {
        case .hover:
            Circle()
                .fill(tint.opacity(0.55))
                .frame(width: 6, height: 6)

        case .click:
            Image(systemName: "cursorarrow.click")
                .font(.caption.weight(.bold))
                .foregroundStyle(tint.opacity(0.9))

        case .drag:
            Image(systemName: "hand.draw.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(tint.opacity(0.9))

        case .rightClick:
            Image(systemName: "cursorarrow.click")
                .font(.caption.weight(.bold))
                .foregroundStyle(tint.opacity(0.9))
        }
    }

    private func cursorTint(for mode: InputCursorFeedbackMode) -> Color {
        switch mode {
        case .click:
            return .white
        case .scrollVertical, .scrollHorizontal:
            return .blue
        case .drag:
            return .green
        case .rightClick:
            return .orange
        }
    }

    @ViewBuilder
    private func cursorFeedbackGlyph(tint: Color) -> some View {
        switch tapCursorFeedbackMode {
        case .click:
            Circle()
                .fill(tint.opacity(0.55))
                .frame(width: 6, height: 6)

        case .scrollVertical:
            VStack(spacing: 1) {
                Image(systemName: "chevron.up")
                Image(systemName: "chevron.down")
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(tint.opacity(0.85))

        case .scrollHorizontal:
            HStack(spacing: 1) {
                Image(systemName: "chevron.left")
                Image(systemName: "chevron.right")
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(tint.opacity(0.85))

        case .drag:
            Image(systemName: "hand.draw.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(tint.opacity(0.9))

        case .rightClick:
            Image(systemName: "cursorarrow.click")
                .font(.caption.weight(.bold))
                .foregroundStyle(tint.opacity(0.9))
        }
    }
    
    private func normPoint(for location: CGPoint, in size: CGSize, contentAspect: CGFloat) -> CGPoint? {
        guard size.width > 0, size.height > 0, contentAspect > 0 else { return nil }
        let viewport = viewportTransform(in: size, contentAspect: contentAspect)
        return viewport.normalizedPoint(for: location)
    }

    private func mouseDragGesture(in size: CGSize, contentAspect: CGFloat) -> some Gesture {
        LongPressGesture(minimumDuration: mouseDragHoldDuration)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                switch value {
                case .first(true):
                    break

                case .second(true, let drag?):
                    isMouseDragActive = true

                    let dist = hypot(drag.translation.width, drag.translation.height)
                    guard dist >= mouseDragBeginDistance else { return }

                    let activeWindow = presentedWindow
                    guard isInputReadyForWindow(activeWindow) else {
                        requestFocusForPresentedWindow(reason: "mouse drag")
                        return
                    }

                    if !mouseDragDidSendDown {
                        if let startNorm = normPoint(for: drag.startLocation, in: size, contentAspect: contentAspect) {
                            mouseDragStartNorm = startNorm
                            mouseDragDidSendDown = true
                            showDirectCursor(at: startNorm, localMode: .drag, sharedMode: .drag)
                            runtimeSession.sendMouseDown(on: activeWindow,
                                                  normX: Double(startNorm.x),
                                                  normY: Double(startNorm.y),
                                                  button: "left")
                            workspacePointerDidBegin(pointerInteractionID)
                        }
                    }

                    guard mouseDragDidSendDown else { return }
                    guard workspaceMayReleasePointer(pointerInteractionID) else { return }

                    if let curNorm = normPoint(for: drag.location, in: size, contentAspect: contentAspect) {
                        showDirectCursor(at: curNorm, localMode: .drag, sharedMode: .drag)
                        runtimeSession.sendMouseDrag(on: activeWindow,
                                              normX: Double(curNorm.x),
                                              normY: Double(curNorm.y),
                                              button: "left")
                    }

                default:
                    break
                }
            }
            .onEnded { value in
                defer {
                    isMouseDragActive = false
                    mouseDragDidSendDown = false
                    mouseDragStartNorm = nil
                }

                guard case .second(true, let drag?) = value else { return }
                guard mouseDragDidSendDown else { return }
                guard workspaceMayReleasePointer(pointerInteractionID) else { return }

                let activeWindow = presentedWindow
                let endNorm = normPoint(for: drag.location, in: size, contentAspect: contentAspect)
                    ?? mouseDragStartNorm
                    ?? tapCursorNorm
                    ?? runtimeSession.currentSharedCursorNorm(for: activeWindow.windowId)

                runtimeSession.sendMouseUp(on: activeWindow,
                                    normX: Double(endNorm.x),
                                    normY: Double(endNorm.y),
                                    button: "left")
                showDirectCursor(at: endNorm, localMode: .click, sharedMode: .hover)
            }
    }
    
    private func viewPoint(fromNorm norm: CGPoint, in size: CGSize, contentAspect: CGFloat) -> CGPoint {
        let viewport = viewportTransform(in: size, contentAspect: contentAspect)
        return viewport.viewPoint(fromNormalized: norm)
    }
    private func requestFocusForPresentedWindow(reason: String) {
        guard workspaceAllowsInput, workspaceIsVisible, workspaceInputAdmission() else { return }
        let activeWindow = presentedWindow
        let now = Date()
        let isLocallyActive = runtimeSession.activeWindowId == activeWindow.windowId
        let isHostConfirmedActive = isInputReadyForWindow(activeWindow)

        // Local active means client intent. Host confirmed means the Mac actually raised it.
        if let lastFocusRequestAt,
           now.timeIntervalSince(lastFocusRequestAt) < focusRequestMinInterval,
           isLocallyActive,
           isHostConfirmedActive {
            return
        }

        lastFocusRequestAt = now
        if runtimeSession.activeWindowId != activeWindow.windowId {
            runtimeSession.setActiveWindow(activeWindow.windowId)
        } else if !isInputReadyForWindow(activeWindow) {
            runtimeSession.requestHostFocusForWindow(activeWindow.windowId)
        }
    }
    // MARK: - Debug overlay (FPS / latency)
#if DEBUG
    
    private func registerFrame() {
        let now = Date()
        
        if let last = lastFrameTimestamp {
            let interval = now.timeIntervalSince(last)
            guard interval > 0 else { return }
            
            frameIntervals.append(interval)
            if frameIntervals.count > maxFrameSamples {
                frameIntervals.removeFirst(frameIntervals.count - maxFrameSamples)
            }
            
            let avg = frameIntervals.reduce(0, +) / Double(frameIntervals.count)
            fps = avg > 0 ? 1.0 / avg : 0
        }
        
        lastFrameTimestamp = now
    }
    
    private func updateLatency(now: Date) {
        guard let last = lastFrameTimestamp else {
            estimatedLatencyMs = 0
            return
        }
        
        estimatedLatencyMs = now.timeIntervalSince(last) * 1000.0
    }
    
    private var debugOverlay: some View {
        let fpsString = fps > 0
        ? String(format: "%.1f", fps)
        : "—"
        
        let latencyString: String
        if estimatedLatencyMs > 0 {
            if estimatedLatencyMs >= 1000 {
                latencyString = String(format: "%.1fs", estimatedLatencyMs / 1000.0)
            } else {
                latencyString = String(format: "%.0f ms", estimatedLatencyMs)
            }
        } else {
            latencyString = "—"
        }
        
        return VStack(alignment: .leading, spacing: 2) {
            Text("FPS \(fpsString)")
            Text("Latency \(latencyString)")
        }
        .font(.caption2.monospacedDigit())
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.65))
        )
        .foregroundStyle(.white)
        .padding(8)
    }
#endif
    
    private func handleAutoPopupLifecycleIfNeeded() {
        if isReturningToBrowser {
            return
        }

        guard runtimeSession.hasFreshWindowListForCurrentConnection else {
            return
        }

        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            // iPhone uses fullScreenCover from ContentView, so let ContentView own the swap there.
            return
        }
        #endif

        let currentRoot = rootWindow
        if !runtimeSession.currentWindowInstanceMatches(currentRoot) {
            guard !isReturningToBrowser else { return }

            if let successor = runtimeSession.consumePendingLauncherSuccessor(for: currentRoot.windowId) {
                runtimeSession.forceMouseUpIfNeeded(reason: "launcher successor handoff")
                runtimeSession.endPullStream(for: currentRoot)
                rootWindowOverride = successor
                runtimeSession.setActiveWindow(successor.windowId)
                runtimeSession.beginPullStream(for: successor)
                return
            }

            runtimeSession.forceMouseUpIfNeeded(reason: "peeled root window closed")

            for popup in popupWindowStack.reversed() {
                runtimeSession.endPullStream(for: popup)
                runtimeSession.clearAutoPopupTracking(for: popup.windowId)
            }
            popupWindowStack.removeAll()

            returnToBrowser(userInitiated: false)
            return
        }

        let currentTop = presentedWindow

        if let popup = runtimeSession.consumeAutoPopupHandoff(from: currentTop.windowId) {
            runtimeSession.forceMouseUpIfNeeded(reason: "auto popup handoff")
            runtimeSession.setActiveWindow(popup.windowId)
            popupWindowStack.append(popup)
            runtimeSession.beginPullStream(for: popup)
            return
        }

        while let top = popupWindowStack.last,
              !runtimeSession.currentWindowInstanceMatches(top) {
            runtimeSession.endPullStream(for: top)
            runtimeSession.clearAutoPopupTracking(for: top.windowId)
            popupWindowStack.removeLast()
        }

        // Do not continuously reassert focus from passive window-list updates.
        // Focus should come from explicit user interaction or popup/root handoff only.
    }

    // MARK: - Streaming
    
    private func startStreaming() {
        guard !workspaceManagesStreaming else { return }
        runtimeSession.beginPullStream(for: rootWindow)
        for popup in popupWindowStack {
            runtimeSession.beginPullStream(for: popup)
        }
    }

    private func stopStreaming() {
        guard !workspaceManagesStreaming else { return }
        for popup in popupWindowStack.reversed() {
            runtimeSession.endPullStream(for: popup)
        }
        runtimeSession.endPullStream(for: rootWindow)
    }
    
    private func dotColor(for status: WindowStreamStatus) -> Color {
        switch status {
        case .active: return .green
        case .sleeping: return .orange
        case .offline: return .gray
        }
    }
    // MARK: - Keyboard bridge delegate
    
    
}

final class KeyboardBridge: NSObject, InvisibleTextInputDelegate {
    let onText: (String) -> Void
    let onBackspace: () -> Void
    let onEnter: () -> Void
    let onCommand: (KeyboardCommand) -> Void
    let onHardwareKey: (Int, String?, String?, [KeyboardCommand]) -> Void
    
    init(onText: @escaping (String) -> Void,
         onBackspace: @escaping () -> Void,
         onEnter: @escaping () -> Void,
         onCommand: @escaping (KeyboardCommand) -> Void,
         onHardwareKey: @escaping (Int, String?, String?, [KeyboardCommand]) -> Void) {
        self.onText = onText
        self.onBackspace = onBackspace
        self.onEnter = onEnter
        self.onCommand = onCommand
        self.onHardwareKey = onHardwareKey
    }
    
    func didInsertText(_ text: String) {
        onText(text)
    }
    
    func didPressBackspace() {
        onBackspace()
    }
    
    func didPressEnter() {
        onEnter()
    }

    func didPressKeyboardCommand(_ command: KeyboardCommand) {
        onCommand(command)
    }

    func didPressKeyboardHardwareKey(
        keyCode: Int,
        characters: String?,
        charactersIgnoringModifiers: String?,
        modifiers: [KeyboardCommand]
    ) {
        onHardwareKey(keyCode, characters, charactersIgnoringModifiers, modifiers)
    }
}


// MARK: - Reliable keyboard capture (software + hardware)

private struct KeyCaptureTextView: UIViewRepresentable {
    @Binding var isFocused: Bool
    let isInputOwner: () -> Bool
    let focusRequestID: Int
    let isMacroHoldModeEnabled: Bool
    let delegate: InvisibleTextInputDelegate
    let onFocusChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PassthroughTextView {
        let tv = PassthroughTextView()
        tv.backgroundColor = .clear
        tv.isOpaque = false
        tv.isScrollEnabled = false
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.spellCheckingType = .no
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.smartInsertDeleteType = .no
        tv.keyboardType = .default
        tv.returnKeyType = .default
        tv.enablesReturnKeyAutomatically = false
        tv.tintColor = .clear
        tv.textColor = .clear
        tv.keyDelegate = delegate
        tv.onFocusChanged = onFocusChanged
        tv.isMacroHoldModeEnabled = isMacroHoldModeEnabled
        tv.delegate = tv
        tv.resetCapturedTextStorage()
        tv.observeSoftwareKeyboardDismissal()
        tv.observeKeyboardInputOwnership()

        return tv
    }

    func updateUIView(_ uiView: PassthroughTextView, context: Context) {
        uiView.keyDelegate = delegate
        uiView.onFocusChanged = onFocusChanged
        uiView.isMacroHoldModeEnabled = isMacroHoldModeEnabled

        let isExplicitFocusRequest = context.coordinator.lastFocusRequestID != focusRequestID
        context.coordinator.lastFocusRequestID = focusRequestID

        // Defer responder changes to avoid fights with toolbar taps / SwiftUI focus churn.
        // Do not call reloadInputViews() here; that can tear down the active remote text
        // input session and is especially rough on dictation.
        uiView.applyFocus(isFocused, force: isExplicitFocusRequest, isInputOwner: isInputOwner)
    }

    static func dismantleUIView(_ uiView: PassthroughTextView, coordinator: Coordinator) {
        uiView.stopManagingFocus()
    }

    final class Coordinator {
        var lastFocusRequestID: Int = -1
    }

    final class PassthroughTextView: UITextView, UITextViewDelegate {
        weak var keyDelegate: InvisibleTextInputDelegate?
        var onFocusChanged: ((Bool) -> Void)?
        var isMacroHoldModeEnabled: Bool = false {
            didSet {
                if isMacroHoldModeEnabled, !oldValue {
                    resetCapturedTextStorage()
                }
            }
        }

        private var focusRequestGeneration = 0
        private var focusRetryWorkItems: [DispatchWorkItem] = []
        private var keyboardWillHideObserver: NSObjectProtocol?
        private var keyboardOwnershipObservers: [NSObjectProtocol] = []
        private var requestedKeyboardFocus = false
        private var sceneInputOwner: () -> Bool = { false }
        private var isSuspendingInputOwnership = false
        private var lastObservedText = ""
        private var pendingComposedText = ""
        private var compositionFlushTask: Task<Void, Never>?
        private var isProgrammaticTextChange = false
        private var isDictationActive = false
        private var dictationBaseText = ""
        private var pendingDictationText = ""
        private var recentEmittedTextSamples: [(text: String, time: CFTimeInterval)] = []
        private var lastComposedTextFlushAt: CFTimeInterval = 0
        private let compositionFlushDelayNanoseconds: UInt64 = 650_000_000
        private let dictationFinalDuplicateWindow: CFTimeInterval = 120

        private var hasKeyboardInputOwnership: Bool {
            guard sceneInputOwner(), let window else { return false }
            return window.isKeyWindow && window.windowScene?.activationState == .foregroundActive
        }

        override var canBecomeFirstResponder: Bool { hasKeyboardInputOwnership }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            refreshKeyboardInputOwnership()
        }

        func observeKeyboardInputOwnership() {
            guard keyboardOwnershipObservers.isEmpty else { return }
            let names: [Notification.Name] = [
                UIWindow.didBecomeKeyNotification, UIWindow.didResignKeyNotification,
                UIScene.didActivateNotification, UIScene.willDeactivateNotification,
                UIScene.didEnterBackgroundNotification
            ]
            keyboardOwnershipObservers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                    guard let self else { return }
                    if let changedWindow = notification.object as? UIWindow {
                        guard changedWindow === self.window else { return }
                    } else if let changedScene = notification.object as? UIScene {
                        guard changedScene === self.window?.windowScene else { return }
                    }
                    self.refreshKeyboardInputOwnership()
                }
            }
        }

        private func refreshKeyboardInputOwnership() {
            applyFocus(requestedKeyboardFocus, force: true, isInputOwner: sceneInputOwner)
        }

        func stopManagingFocus() {
            requestedKeyboardFocus = false
            sceneInputOwner = { false }
            focusRequestGeneration += 1
            cancelFocusRetries()
            compositionFlushTask?.cancel()
            compositionFlushTask = nil
            onFocusChanged = nil
            isSuspendingInputOwnership = true
            _ = resignFirstResponder()
            isSuspendingInputOwnership = false
            keyboardOwnershipObservers.forEach(NotificationCenter.default.removeObserver)
            keyboardOwnershipObservers.removeAll()
            if let keyboardWillHideObserver {
                NotificationCenter.default.removeObserver(keyboardWillHideObserver)
                self.keyboardWillHideObserver = nil
            }
        }

        func observeSoftwareKeyboardDismissal() {
            guard keyboardWillHideObserver == nil else { return }

            keyboardWillHideObserver = NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillHideNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self, self.isFirstResponder,
                      self.hasKeyboardInputOwnership, !self.isSuspendingInputOwnership else { return }
                guard GCKeyboard.coalesced == nil else { return }
                self.onFocusChanged?(false)
            }
        }

        func applyFocus(_ shouldFocus: Bool, force: Bool, isInputOwner: @escaping () -> Bool) {
            requestedKeyboardFocus = shouldFocus
            sceneInputOwner = isInputOwner
            if !shouldFocus || !hasKeyboardInputOwnership {
                focusRequestGeneration += 1
                let generation = focusRequestGeneration
                cancelFocusRetries()
                let preserveIntent = shouldFocus
                if preserveIntent {
                    compositionFlushTask?.cancel()
                    compositionFlushTask = nil
                }

                DispatchQueue.main.async { [weak self] in
                    guard let self, self.focusRequestGeneration == generation else { return }

                    if self.isFirstResponder {
                        self.isSuspendingInputOwnership = preserveIntent
                        _ = self.resignFirstResponder()
                        self.isSuspendingInputOwnership = false
                    }
                }
                return
            }

            let generation: Int
            if force {
                focusRequestGeneration += 1
                generation = focusRequestGeneration
                cancelFocusRetries()
            } else {
                generation = focusRequestGeneration
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.focusRequestGeneration == generation,
                      self.requestedKeyboardFocus, self.hasKeyboardInputOwnership else { return }

                if force || !self.isFirstResponder {
                    _ = self.becomeFirstResponder()
                }

                if force {
                    self.scheduleFocusRetry(after: 0.08, generation: generation)
                    self.scheduleFocusRetry(after: 0.22, generation: generation)
                }
            }
        }

        private func scheduleFocusRetry(after delay: TimeInterval, generation: Int) {
            let work = DispatchWorkItem { [weak self] in
                guard let self,
                      self.focusRequestGeneration == generation,
                      self.requestedKeyboardFocus, self.hasKeyboardInputOwnership,
                      !self.isFirstResponder else { return }

                _ = self.becomeFirstResponder()
            }

            focusRetryWorkItems.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        private func cancelFocusRetries() {
            focusRetryWorkItems.forEach { $0.cancel() }
            focusRetryWorkItems.removeAll()
        }

        override func becomeFirstResponder() -> Bool {
            let wasFirstResponder = isFirstResponder
            let didBecome = super.becomeFirstResponder()

            if didBecome, !wasFirstResponder {
                onFocusChanged?(true)
            }
            if didBecome, !pendingComposedText.isEmpty {
                scheduleComposedTextFlush()
            }

            return didBecome
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard hasKeyboardInputOwnership else { return }
            var unhandled = Set<UIPress>()

            for press in presses {
                guard let key = press.key, handleHardwareKey(key) else {
                    unhandled.insert(press)
                    continue
                }
            }

            if !unhandled.isEmpty {
                super.pressesBegan(unhandled, with: event)
            }
        }

        private func handleHardwareKey(_ key: UIKey) -> Bool {
            guard hasKeyboardInputOwnership else { return false }
            let modifiers = keyboardCommands(for: key.modifierFlags)
            let hasShortcutModifier = modifiers.contains(.command) ||
                modifiers.contains(.control) ||
                modifiers.contains(.option)

            if hasShortcutModifier {
                sendHardwareKey(key, modifiers: modifiers)
                return true
            }

            let command: KeyboardCommand?
            switch key.keyCode {
            case .keyboardDeleteOrBackspace: command = .backspace
            case .keyboardReturnOrEnter: command = .enter
            case .keyboardTab: command = .tab
            case .keyboardEscape: command = .escape
            case .keyboardDeleteForward: command = .forwardDelete
            case .keyboardHome: command = .home
            case .keyboardEnd: command = .end
            case .keyboardPageUp: command = .pageUp
            case .keyboardPageDown: command = .pageDown
            case .keyboardLeftArrow: command = .leftArrow
            case .keyboardRightArrow: command = .rightArrow
            case .keyboardUpArrow: command = .upArrow
            case .keyboardDownArrow: command = .downArrow
            case .keyboardF1: command = .f1
            case .keyboardF2: command = .f2
            case .keyboardF3: command = .f3
            case .keyboardF4: command = .f4
            case .keyboardF5: command = .f5
            case .keyboardF6: command = .f6
            case .keyboardF7: command = .f7
            case .keyboardF8: command = .f8
            case .keyboardF9: command = .f9
            case .keyboardF10: command = .f10
            case .keyboardF11: command = .f11
            case .keyboardF12: command = .f12
            default: command = nil
            }

            guard let command else { return false }

            if modifiers.isEmpty {
                keyDelegate?.didPressKeyboardCommand(command)
            } else {
                sendHardwareKey(key, modifiers: modifiers)
            }
            return true
        }

        private func sendHardwareKey(_ key: UIKey, modifiers: [KeyboardCommand]) {
            keyDelegate?.didPressKeyboardHardwareKey(
                keyCode: Int(key.keyCode.rawValue),
                characters: key.characters.isEmpty ? nil : key.characters,
                charactersIgnoringModifiers: key.charactersIgnoringModifiers.isEmpty
                    ? nil
                    : key.charactersIgnoringModifiers,
                modifiers: modifiers
            )
        }

        private func keyboardCommands(for flags: UIKeyModifierFlags) -> [KeyboardCommand] {
            var commands: [KeyboardCommand] = []
            if flags.contains(.command) { commands.append(.command) }
            if flags.contains(.shift) { commands.append(.shift) }
            if flags.contains(.alternate) { commands.append(.option) }
            if flags.contains(.control) { commands.append(.control) }
            return commands
        }

        override func insertText(_ text: String) {
            guard hasKeyboardInputOwnership else { return }
            if isMacroHoldModeEnabled {
                flushPendingComposedText()
                if text == "\n" || text == "\r" {
                    keyDelegate?.didPressEnter()
                } else {
                    keyDelegate?.didInsertText(text)
                }
                resetCapturedTextStorage()
                return
            }

            if text == "\n", markedTextRange == nil {
                flushPendingComposedText()
                keyDelegate?.didPressEnter()
                return
            }

            super.insertText(text)
        }

        override func deleteBackward() {
            guard hasKeyboardInputOwnership else { return }
            if isMacroHoldModeEnabled {
                flushPendingComposedText()
                keyDelegate?.didPressBackspace()
                resetCapturedTextStorage()
                return
            }

            if markedTextRange != nil {
                super.deleteBackward()
                syncObservedTextAfterLocalDeletion()
                return
            }

            flushPendingComposedText()
            keyDelegate?.didPressBackspace()
            super.deleteBackward()
            syncObservedTextAfterLocalDeletion()
        }

        override var insertDictationResultPlaceholder: Any {
            beginDictationCapture(baseText: lastObservedText)
            return super.insertDictationResultPlaceholder
        }

        override func removeDictationResultPlaceholder(_ placeholder: Any, willInsertResult: Bool) {
            super.removeDictationResultPlaceholder(placeholder, willInsertResult: willInsertResult)

            if !willInsertResult {
                resetDictationCapture()
            }
        }

        override func insertDictationResult(_ dictationResult: [UIDictationPhrase]) {
            let finalText = dictationResult.map { $0.text }.joined()
            commitDictationText(finalText)
        }

        override func dictationRecognitionFailed() {
            super.dictationRecognitionFailed()
            resetDictationCapture()
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isProgrammaticTextChange else { return }

            if isMacroHoldModeEnabled {
                guard hasKeyboardInputOwnership else { return }
                let committedText = textView.text ?? ""
                resetCapturedTextStorage()
                if !committedText.isEmpty {
                    keyDelegate?.didInsertText(committedText)
                }
                return
            }

            let previousText = lastObservedText
            let currentText = textView.text ?? ""
            let insertedText = insertedSuffix(from: previousText, to: currentText)
            lastObservedText = currentText

            guard hasKeyboardInputOwnership else {
                pendingComposedText += insertedText
                return
            }

            if isDictationActive || isCurrentInputModeDictation {
                if !isDictationActive {
                    beginDictationCapture(baseText: previousText)
                }
                updatePendingDictationText(currentText: currentText, insertedText: insertedText)
                return
            }

            if markedTextRange != nil {
                scheduleComposedTextFlush()
                return
            }

            guard !insertedText.isEmpty else { return }

            if insertedText.count == 1, pendingComposedText.isEmpty {
                emitTextToHost(insertedText)
                resetCapturedTextStorage()
                return
            }

            pendingComposedText += insertedText
            scheduleComposedTextFlush()
        }

        override func resignFirstResponder() -> Bool {
            let wasFirstResponder = isFirstResponder

            // Keep composition and keyboard intent while another scene owns
            // input. Manual dismissal in the eligible scene still flushes.
            if isSuspendingInputOwnership {
                return super.resignFirstResponder()
            }

            if isDictationActive || isCurrentInputModeDictation {
                resetCapturedTextStorage()
            } else {
                flushPendingComposedText()
                resetCapturedTextStorage()
            }

            let didResign = super.resignFirstResponder()

            if didResign, wasFirstResponder {
                onFocusChanged?(false)
            }

            return didResign
        }

        deinit {
            cancelFocusRetries()
            compositionFlushTask?.cancel()
            keyboardOwnershipObservers.forEach(NotificationCenter.default.removeObserver)
            if let keyboardWillHideObserver {
                NotificationCenter.default.removeObserver(keyboardWillHideObserver)
            }
        }

        func resetCapturedTextStorage() {
            compositionFlushTask?.cancel()
            compositionFlushTask = nil
            pendingComposedText = ""
            isDictationActive = false
            dictationBaseText = ""
            pendingDictationText = ""
            lastObservedText = ""

            isProgrammaticTextChange = true
            text = ""
            selectedRange = NSRange(location: 0, length: 0)
            isProgrammaticTextChange = false
        }

        private var isCurrentInputModeDictation: Bool {
            textInputMode?.primaryLanguage == "dictation"
        }

        private func beginDictationCapture(baseText: String) {
            guard !isDictationActive else { return }

            lastComposedTextFlushAt = 0
            compositionFlushTask?.cancel()
            compositionFlushTask = nil
            pendingComposedText = ""
            isDictationActive = true
            dictationBaseText = baseText
            pendingDictationText = ""
        }

        private func updatePendingDictationText(currentText: String, insertedText: String) {
            if currentText.hasPrefix(dictationBaseText) {
                pendingDictationText = String(currentText.dropFirst(dictationBaseText.count))
            } else if !insertedText.isEmpty {
                pendingDictationText = insertedText
            } else {
                pendingDictationText = currentText
            }
        }

        private func commitDictationText(_ text: String) {
            let finalText = text

            if shouldSuppressDictationFinalText(finalText) {
                resetCapturedTextStorage()
                return
            }

            resetCapturedTextStorage()
            emitTextToHost(finalText)
        }

        private func emitTextToHost(_ text: String) {
            guard !text.isEmpty else { return }
            guard hasKeyboardInputOwnership else {
                pendingComposedText += text
                return
            }
            keyDelegate?.didInsertText(text)
            rememberEmittedText(text)
        }

        private func rememberEmittedText(_ text: String) {
            let now = CACurrentMediaTime()
            pruneRecentEmittedTextSamples(now: now)
            recentEmittedTextSamples.append((text: text, time: now))
        }

        private func pruneRecentEmittedTextSamples(now: CFTimeInterval = CACurrentMediaTime()) {
            recentEmittedTextSamples.removeAll { now - $0.time > dictationFinalDuplicateWindow }
        }

        private func shouldSuppressDictationFinalText(_ text: String) -> Bool {
            let finalText = normalizedDictationDuplicateText(text)
            guard !finalText.isEmpty else { return false }

            let now = CACurrentMediaTime()

            // Dictation can first resolve through textViewDidChange, then later fire
            // insertDictationResult while the system tears down dictation. If the text
            // already flushed, the final callback is a duplicate rather than a second send path.
            if lastComposedTextFlushAt > 0,
               now - lastComposedTextFlushAt <= dictationFinalDuplicateWindow {
                return true
            }

            pruneRecentEmittedTextSamples(now: now)

            let combinedRecentText = recentEmittedTextSamples
                .map(\.text)
                .joined(separator: " ")

            if isDuplicateDictationFinal(finalText, ofRecentlyEmittedText: normalizedDictationDuplicateText(combinedRecentText)) {
                return true
            }

            return recentEmittedTextSamples.contains { sample in
                isDuplicateDictationFinal(finalText, ofRecentlyEmittedText: normalizedDictationDuplicateText(sample.text))
            }
        }

        private func isDuplicateDictationFinal(_ finalText: String, ofRecentlyEmittedText emittedText: String) -> Bool {
            guard !finalText.isEmpty, !emittedText.isEmpty else { return false }

            if finalText == emittedText || emittedText.contains(finalText) {
                return true
            }

            let finalWords = Set(finalText.split(separator: " "))
            let emittedWords = Set(emittedText.split(separator: " "))
            guard !finalWords.isEmpty else { return false }

            let overlap = finalWords.intersection(emittedWords).count
            let finalCoverage = Double(overlap) / Double(finalWords.count)
            return finalCoverage >= 0.85
        }

        private func normalizedDictationDuplicateText(_ value: String) -> String {
            value
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        private func resetDictationCapture() {
            isDictationActive = false
            dictationBaseText = ""
            pendingDictationText = ""
        }

        private func syncObservedTextAfterLocalDeletion() {
            guard !isProgrammaticTextChange else { return }
            lastObservedText = text ?? ""
        }

        private func insertedSuffix(from oldText: String, to newText: String) -> String {
            guard !newText.isEmpty else { return "" }

            if newText.hasPrefix(oldText) {
                return String(newText.dropFirst(oldText.count))
            }

            let oldScalars = Array(oldText.unicodeScalars)
            let newScalars = Array(newText.unicodeScalars)
            var sharedPrefixCount = 0

            while sharedPrefixCount < oldScalars.count,
                  sharedPrefixCount < newScalars.count,
                  oldScalars[sharedPrefixCount] == newScalars[sharedPrefixCount] {
                sharedPrefixCount += 1
            }

            guard newScalars.count > sharedPrefixCount else { return "" }
            let startIndex = newText.unicodeScalars.index(newText.unicodeScalars.startIndex,
                                                          offsetBy: sharedPrefixCount)
            return String(newText.unicodeScalars[startIndex...])
        }

        private func scheduleComposedTextFlush() {
            compositionFlushTask?.cancel()

            compositionFlushTask = Task { [weak self] in
                guard let self else { return }

                try? await Task.sleep(nanoseconds: compositionFlushDelayNanoseconds)
                guard !Task.isCancelled else { return }

                await MainActor.run { [weak self] in
                    guard let self else { return }

                    if self.isCurrentInputModeDictation || self.isDictationActive {
                        let heldText = self.pendingComposedText
                        let currentText = self.text ?? ""
                        let baseText: String

                        if !heldText.isEmpty, currentText.hasSuffix(heldText) {
                            baseText = String(currentText.dropLast(heldText.count))
                        } else {
                            baseText = self.dictationBaseText.isEmpty ? self.lastObservedText : self.dictationBaseText
                        }

                        if !self.isDictationActive {
                            self.beginDictationCapture(baseText: baseText)
                        }

                        if !heldText.isEmpty {
                            self.pendingDictationText = heldText
                        }

                        return
                    }

                    if self.markedTextRange != nil {
                        self.scheduleComposedTextFlush()
                    } else {
                        self.flushPendingComposedText()
                    }
                }
            }
        }

        private func flushPendingComposedText() {
            compositionFlushTask?.cancel()
            compositionFlushTask = nil

            guard hasKeyboardInputOwnership, !pendingComposedText.isEmpty else { return }
            lastComposedTextFlushAt = CACurrentMediaTime()
            emitTextToHost(pendingComposedText)
            pendingComposedText = ""
        }
    }
}

// MARK: - Indirect pointer hover capture (trackpad + mouse)

private struct IndirectHoverCapture: UIViewRepresentable {
    var onHover: (CGPoint?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onHover: onHover)
    }

    func makeUIView(context: Context) -> HoverCaptureView {
        let view = HoverCaptureView(frame: .zero)
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isUserInteractionEnabled = true

        let hover = UIHoverGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleHover(_:))
        )
        view.addGestureRecognizer(hover)
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ uiView: HoverCaptureView, context: Context) {
        context.coordinator.onHover = onHover
    }

    final class HoverCaptureView: UIView {
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            guard super.point(inside: point, with: event) else { return false }
            return event?.type == .hover
        }
    }

    final class Coordinator: NSObject {
        var onHover: (CGPoint?) -> Void
        weak var view: UIView?

        init(onHover: @escaping (CGPoint?) -> Void) {
            self.onHover = onHover
        }

        @objc func handleHover(_ recognizer: UIHoverGestureRecognizer) {
            guard let view else { return }

            switch recognizer.state {
            case .began, .changed:
                onHover(recognizer.location(in: view))
            case .ended, .cancelled, .failed:
                onHover(nil)
            default:
                break
            }
        }
    }
}

// MARK: - Indirect scroll capture (trackpad + mouse wheel)

private struct IndirectScrollCapture: UIViewRepresentable {
    var targetWindowId: UInt32
    var isActive: Bool
    var onScroll: (_ dx: CGFloat, _ dy: CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScroll: onScroll)
    }

    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = true

        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = context.coordinator
        pan.cancelsTouchesInView = false

        // Key bit: allow indirect scrolling (trackpad + mouse wheel)
        if #available(iOS 13.4, visionOS 1.0, *) {
            pan.allowedScrollTypesMask = [.continuous, .discrete]
        }

        // Keep this recognizer from acting like a normal touch-pan.
        pan.minimumNumberOfTouches = 0
        pan.maximumNumberOfTouches = 0

        v.addGestureRecognizer(pan)
        context.coordinator.view = v
        context.coordinator.updateTarget(windowId: targetWindowId, isActive: isActive, onScroll: onScroll)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.updateTarget(windowId: targetWindowId, isActive: isActive, onScroll: onScroll)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.invalidate()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onScroll: (_ dx: CGFloat, _ dy: CGFloat) -> Void
        weak var view: UIView?

        private var isActive = true
        private var targetWindowId: UInt32?
        private var scrollGestureActive = false
        private var displayLink: CADisplayLink?
        private var inertialVelocity: CGPoint = .zero
        private var lastTick: CFTimeInterval = 0

        // Use UIKit’s own deceleration constant so it feels “native-ish”.
        private let decelRate: CGFloat = UIScrollView.DecelerationRate.normal.rawValue
        private let stopVelocityThreshold: CGFloat = 12 // points/sec; tune if needed

        init(onScroll: @escaping (_ dx: CGFloat, _ dy: CGFloat) -> Void) {
            self.onScroll = onScroll
        }

        deinit {
            stopInertia()
        }

        func updateTarget(windowId: UInt32, isActive: Bool, onScroll: @escaping (CGFloat, CGFloat) -> Void) {
            if targetWindowId != windowId {
                // Cancel using the previous target's callback before replacing it.
                setActive(false)
                targetWindowId = windowId
            }
            self.onScroll = onScroll
            setActive(isActive)
        }

        func setActive(_ active: Bool) {
            isActive = active
            if !active {
                scrollGestureActive = false
                stopInertia()
            }
        }

        func invalidate() {
            setActive(false)
            onScroll = { _, _ in }
            view = nil
        }

        @objc func handlePan(_ gr: UIPanGestureRecognizer) {
            guard isActive, let v = view else { return }

            switch gr.state {
            case .began:
                scrollGestureActive = true
                // If the user starts scrolling again, kill any active inertia.
                stopInertia()

            case .changed:
                guard scrollGestureActive else { return }
                let t = gr.translation(in: v)
                gr.setTranslation(.zero, in: v)

                if abs(t.x) < 0.5 && abs(t.y) < 0.5 { return }
                onScroll(t.x, t.y)

            case .ended:
                guard scrollGestureActive else { return }
                scrollGestureActive = false
                // Only a completed gesture may continue with inertia.
                let vel = gr.velocity(in: v) // points/sec
                startInertia(with: vel)

            case .cancelled, .failed:
                scrollGestureActive = false
                stopInertia()

            default:
                break
            }
        }

        private func startInertia(with velocity: CGPoint) {
            stopInertia()
            guard isActive else { return }
            // If it’s basically stopped, do nothing.
            guard abs(velocity.x) > stopVelocityThreshold || abs(velocity.y) > stopVelocityThreshold else {
                stopInertia()
                return
            }

            inertialVelocity = velocity
            lastTick = CACurrentMediaTime()

            let link = CADisplayLink(target: self, selector: #selector(stepInertia))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        private func stopInertia() {
            displayLink?.invalidate()
            displayLink = nil
            inertialVelocity = .zero
            lastTick = 0
        }

        @objc private func stepInertia() {
            guard isActive, displayLink != nil else { return }

            let now = CACurrentMediaTime()
            let dt = CGFloat(now - lastTick)
            lastTick = now

            // Convert velocity (points/sec) into a delta (points) for this frame.
            let dx = inertialVelocity.x * dt
            let dy = inertialVelocity.y * dt

            if abs(dx) > 0.01 || abs(dy) > 0.01 {
                onScroll(dx, dy)
            }

            // Exponential decay: rate^(frames)
            let decay = pow(decelRate, dt * 60.0)
            inertialVelocity.x *= decay
            inertialVelocity.y *= decay

            if abs(inertialVelocity.x) < stopVelocityThreshold && abs(inertialVelocity.y) < stopVelocityThreshold {
                stopInertia()
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            false
        }
    }
}
