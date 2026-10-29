//
//  PeeledWindowView.swift
//  Peel
//
//  Created by Zach on 11/30/25.
//

import SwiftUI
import UIKit
import Combine



enum PeelFrameMode {
    case locked
    case resizable
}


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

private enum IndirectPointerEvent {
    case hover(location: CGPoint)
    case hoverEnded
    case primaryClick(location: CGPoint)
    case secondaryClick(location: CGPoint)
    case dragBegan(location: CGPoint)
    case dragChanged(location: CGPoint)
    case dragEnded(location: CGPoint)
    case dragCancelled
    case scroll(location: CGPoint, deltaX: CGFloat, deltaY: CGFloat)
}

struct PeeledWindowView: View {
    @EnvironmentObject private var browser: PeelClientBrowser
    @EnvironmentObject private var scenes: SceneCoordinator
    @EnvironmentObject private var store: PeelStore
    @State private var showingWindowPaywall = false
#if os(iOS) || os(visionOS)
    @EnvironmentObject private var remoteNotificationPresenter: PeelLocalRemoteNotificationPresenter
#endif
#if os(visionOS)
    @EnvironmentObject private var agentPresentationCoordinator: VisionAgentPresentationCoordinator
#endif

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
#if os(visionOS)
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
#endif
    
    
    let window: PeelWindow
    let hostKey: PeelHostKey?
    let hostName: String?
    let frameMode: PeelFrameMode

    init(window: PeelWindow, frameMode: PeelFrameMode) {
        self.window = window
        self.hostKey = nil
        self.hostName = nil
        self.frameMode = frameMode
    }

    init(request: PeeledWindowSceneRequest, frameMode: PeelFrameMode) {
        self.window = request.window
        self.hostKey = request.hostKey
        self.hostName = request.hostName
        self.frameMode = frameMode
    }
    
    @State private var popupWindowStack: [PeelWindow] = []
    
    // MARK: - Tap cursor feedback (client-side)
    @State private var tapCursorNorm: CGPoint? = nil
    @State private var tapCursorFeedbackMode: InputCursorFeedbackMode = .click
    @State private var tapCursorHideWorkItem: DispatchWorkItem? = nil
    @State private var isDirectCursorActive: Bool = false
    @State private var activeClickButton: ActiveClickButton = .left
    @AppStorage("peel.showInputModeControls") private var showInputModeControls: Bool = false
    @AppStorage("peel.rightClickModeStaysEnabled") private var rightClickModeStaysEnabled: Bool = false
    @AppStorage("peel.showScrollControlButtons") private var showScrollControlButtons: Bool = false
    @State private var isOpeningHome = false
    @State private var showingStreamDetails = false
#if os(iOS) || os(visionOS)
    @State private var showingNotifications = false
#endif
#if os(visionOS)
    @State private var isOpeningImmersive = false
#endif
    @State private var isReturningToBrowser = false
    @State private var isSwitchingFrameMode = false
    @State private var didRestoreBrowserWindow = false
    @State private var rootWindowOverride: PeelWindow? = nil
    
    @State private var currentScene: UIWindowScene? = nil
    @State private var lastAppliedResizableAspect: CGFloat = 0
    @State private var showStuckStreamCloseButton = false
    @State private var passiveRootWindowCloseTask: Task<Void, Never>? = nil
    @State private var currentPeeledWindowSize: CGSize = .zero
    @ObservedObject private var gameControllerInput = PeelGameControllerInput.shared
    @State private var gameControllerOwnerID = UUID()

    @State private var zoomScale: CGFloat = 1.0
    @State private var baseZoomScale: CGFloat = 1.0
    @State private var contentOffset: CGSize = .zero
    @State private var baseContentOffset: CGSize = .zero
    private var isPresentedWindowActive: Bool {
        runtimeSession.activeWindowId == presentedWindow.windowId
    }
    @AppStorage("peel.showZoomButtons") private var showZoomButtons: Bool = true
    @AppStorage("peel.showKeyboardMacroKeys") private var showKeyboardMacroKeys: Bool = true
    @AppStorage("peel.showKeyboardArrowKeys") private var showKeyboardArrowKeys: Bool = true
    @AppStorage("peel.peeledWindowHostingMode") private var peeledWindowHostingMode: PeeledWindowHostingMode = .inPlace

    private var runtimeSession: PeelHostSession {
        if let hostKey, let session = browser.session(for: hostKey) {
            return session
        }

        if let selectedSession = browser.selectedSession {
            return selectedSession
        }

        preconditionFailure("Missing PeelHostSession for peeled window")
    }

    /// Source media binds only to the session that owns this window's host
    /// key. Unlike `runtimeSession` it never falls back to the selected session.
    private var sourceMediaOwnerSession: PeelHostSession? {
        hostKey.flatMap { browser.session(for: $0) }
    }

    private var sourceMediaComputerName: String {
        let session = sourceMediaOwnerSession
        let name = displayNameWithoutPeelPrefix(hostName ?? session?.connectedHostName ?? session?.host.name ?? "")
        return name.isEmpty ? "your computer" : name
    }

    // Mac Space switching only applies to whole-display streams, never to
    // individual app windows.
    private var supportsSpaceSwitching: Bool {
        isDisplayCaptureWindow(presentedWindow) &&
            runtimeSession.supportsHostCapability(.spaceSwitching)
    }

    private func switchSpaceIfPresentingDisplay(_ switchSpace: (PeelHostSession) -> Void) {
        guard supportsSpaceSwitching else { return }
        switchSpace(runtimeSession)
    }

    private func hostedWindow(_ window: PeelWindow) -> HostedPeelWindow {
        HostedPeelWindow(
            hostKey: runtimeSession.hostKey,
            hostName: hostName ?? runtimeSession.host.name,
            window: window
        )
    }

    private var windowsHostedByScene: [PeelWindow] {
        var seen: Set<UInt32> = []
        return ([rootWindow] + popupWindowStack).filter { seen.insert($0.windowId).inserted }
    }

    private func sendHostingMode(_ mode: PeeledWindowHostingMode, for window: PeelWindow) {
        runtimeSession.setPeeledWindowHostingMode(mode, for: window)
    }

    private func sendSceneWindowActivity(_ isActive: Bool) {
        for hostedWindow in windowsHostedByScene {
            runtimeSession.setClientWindowActive(isActive, for: hostedWindow)
        }
    }

    private let maxZoomScale: CGFloat = 4.0
    private let minimumVisionWindowSize = CGSize(width: 420, height: 260)
    private let videoPixelsPerPoint: CGFloat = 2.0
    private let fallbackContentAspect: CGFloat = 16.0 / 9.0
    private let minimumContentAspect: CGFloat = 0.05
    private let maximumContentAspect: CGFloat = 20.0

    private func sanitizedContentAspect(_ rawAspect: CGFloat) -> CGFloat? {
        guard rawAspect.isFinite, rawAspect > 0 else { return nil }
        return min(max(rawAspect, minimumContentAspect), maximumContentAspect)
    }

    private func sanitizedWindowSize(_ proposedSize: CGSize, minimumSize: CGSize) -> CGSize {
        let safeMinimumWidth = (minimumSize.width.isFinite && minimumSize.width > 0) ? minimumSize.width : minimumVisionWindowSize.width
        let safeMinimumHeight = (minimumSize.height.isFinite && minimumSize.height > 0) ? minimumSize.height : minimumVisionWindowSize.height

        let width = (proposedSize.width.isFinite && proposedSize.width > 0) ? max(safeMinimumWidth, proposedSize.width) : safeMinimumWidth
        let height = (proposedSize.height.isFinite && proposedSize.height > 0) ? max(safeMinimumHeight, proposedSize.height) : safeMinimumHeight

        return CGSize(width: width, height: height)
    }

    private var preferredVisionWindowSize: CGSize {
        let minimumSize = minimumVisionWindowSize

        // Map streamed pixels to visionOS window points.
        // 2.0 keeps 4K from becoming enormous while still letting higher host
        // resolutions request a larger, sharper client surface.
        if let videoSize = runtimeSession.videoContentSize(for: presentedWindow.windowId),
           videoSize.width.isFinite,
           videoSize.height.isFinite,
           videoSize.width > 0,
           videoSize.height > 0 {
            return sanitizedWindowSize(
                CGSize(
                    width: videoSize.width / videoPixelsPerPoint,
                    height: videoSize.height / videoPixelsPerPoint
                ),
                minimumSize: minimumSize
            )
        }

        let aspect = preferredContentAspect
        var width = max(minimumSize.width, 720 * aspect)
        var height = width / max(aspect, 0.01)

        if height < minimumSize.height {
            height = minimumSize.height
            width = height * aspect
        }

        return sanitizedWindowSize(CGSize(width: width, height: height), minimumSize: minimumSize)
    }

    private var preferredContentAspect: CGFloat {
        if let videoSize = runtimeSession.videoContentSize(for: presentedWindow.windowId),
           videoSize.width.isFinite,
           videoSize.height.isFinite,
           videoSize.width > 0,
           videoSize.height > 0,
           let aspect = sanitizedContentAspect(videoSize.width / videoSize.height) {
            return aspect
        }

        if let geometry = runtimeSession.windowGeometry(for: presentedWindow.windowId) {
            if let capturePxW = geometry.capturePxW,
               let capturePxH = geometry.capturePxH,
               capturePxW > 0,
               capturePxH > 0,
               let aspect = sanitizedContentAspect(CGFloat(capturePxW) / CGFloat(capturePxH)) {
                return aspect
            }

            let contentW = max(1.0, geometry.boundsW - geometry.insetX * 2.0)
            let contentH = max(1.0, geometry.boundsH - geometry.insetY * 2.0)
            if let aspect = sanitizedContentAspect(CGFloat(contentW / contentH)) {
                return aspect
            }
        }

        let fallbackAspect = CGFloat(presentedWindow.width) / max(1, CGFloat(presentedWindow.height))
        return sanitizedContentAspect(fallbackAspect) ?? fallbackContentAspect
    }

    private var preferredResizableMinimumSize: CGSize {
        // Keep the scene minimum as a plain platform-safe lower bound.
        // Do not inflate this by content aspect; very wide/tall streams can otherwise
        // produce impossible min/ideal constraints and make visionOS collapse the scene.
        minimumVisionWindowSize
    }

    private var preferredResizableIdealSize: CGSize {
        sanitizedWindowSize(preferredVisionWindowSize, minimumSize: preferredResizableMinimumSize)
    }

    private func applyResizableAspectLock(reason: String) {
        guard frameMode == .resizable else { return }
        guard let scene = currentScene else { return }

        let aspect = preferredContentAspect
        guard aspect.isFinite, aspect > 0 else { return }

        if abs(lastAppliedResizableAspect - aspect) < 0.001 {
            return
        }

        let preferredSize = preferredResizableIdealSize
        let minimumSize = preferredResizableMinimumSize

        guard preferredSize.width.isFinite,
              preferredSize.height.isFinite,
              minimumSize.width.isFinite,
              minimumSize.height.isFinite,
              preferredSize.width >= minimumSize.width,
              preferredSize.height >= minimumSize.height else {
            return
        }

        lastAppliedResizableAspect = aspect

        scene.requestGeometryUpdate(
            UIWindowScene.GeometryPreferences.Vision(
                size: preferredSize,
                minimumSize: minimumSize,
                resizingRestrictions: .uniform
            )
        ) { error in
#if DEBUG
            print("Peel resizable aspect lock failed (\(reason)): \(error)")
#endif
        }
    }

    
    private let tapCursorSize: CGFloat = 26

    
    
    // Keyboard focus & enable toggle
    @FocusState private var keyboardFocused: Bool
    @State private var keyboardEnabled: Bool = false
    @State private var showKeyboardMacroPopover: Bool = false
    @State private var showKeyboardCommandsPopover: Bool = false
    @State private var isMacroHoldModeEnabled: Bool = false
    @State private var heldMacroCommands: [KeyboardCommand] = []
    @State private var macroPreviewKeyText: String? = nil
    @State private var macroPreviewClearTask: Task<Void, Never>? = nil
    @State private var macroHoldPulse: Bool = false
    // Bridge @FocusState to a plain Binding for UIKit view
    @State private var isFocusedBridge: Bool = false
    @State private var keyboardFocusRequestID: Int = 0
    
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

    private let mouseDragHoldDuration: TimeInterval = 0.12
    private let mouseDragBeginDistance: CGFloat = 6

    @State private var lastFocusRequestAt: Date? = nil
    private let focusRequestMinInterval: TimeInterval = 0.35

    private let longPressDuration: TimeInterval = 0.5
    private let longPressMovementThreshold: CGFloat = 12
    
    @State private var isDragModeArmed = false
    @State private var isDragModeTemporarilySuppressed = false

    
    var body: some View {
        // Bridge object that forwards keystrokes into PeelClientBrowser
        //MARK: IGNORE ERRORS HERE _ XCODE IS BROKEN AND BUILD AND KEYBOARD WORK
        let keyboardBridge = KeyboardBridge(
            onText: { text in
                handleSoftwareKeyboardTextInput(text)
            },
            onBackspace: {
                handleSoftwareKeyboardSpecialKey(.backspace)
            },
            onEnter: {
                handleSoftwareKeyboardSpecialKey(.enter)
            },
            onTab: {
                handleSoftwareKeyboardSpecialKey(.tab)
            },
            onCommand: { command in
                runtimeSession.sendKeyboardCommand(command)
            },
            onHardwareKey: { keyCode, characters, charactersIgnoringModifiers, modifiers in
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

                // Raw hardware-key capture is only a fallback when text input mode is off.
                // IME input (Chinese/Japanese/Korean, etc.) needs KeyCaptureTextView so
                // UIKit can own composition and emit committed Unicode text.
                HardwareKeyboardCaptureView(isActive: !keyboardEnabled, delegate: keyboardBridge)
                    .frame(width: 4, height: 4)
                    .opacity(0.01)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                // UIKit-backed text input for the software keyboard, dictation, and text composition.
                KeyCaptureTextView(
                    isFocused: $isFocusedBridge,
                    focusRequestID: keyboardFocusRequestID,
                    isMacroHoldModeEnabled: isMacroHoldModeEnabled,
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
#if os(iOS) || os(visionOS)
        .overlay(alignment: .top) {
            PeelRemoteNotificationBanner(
                inbox: remoteNotificationPresenter.inbox
            )
        }
#endif
#if os(visionOS)
        .overlay(alignment: .top) {
            if scenePhase == .active,
               let context = agentPresentationCoordinator.presentationContext(
                   for: hostedWindow(rootWindow)
               ) {
                VisionAgentPresentationContextBanner(context: context)
                    .padding(.top, 58)
            }
        }
#endif
        .onAppear {
            sendHostingMode(peeledWindowHostingMode, for: rootWindow)
            runtimeSession.setClientWindowActive(scenePhase == .active, for: rootWindow)
            if let currentScene {
                scenes.registerPeeledWindowScene(
                    currentScene,
                    for: hostedWindow(rootWindow),
                    mode: frameMode == .resizable ? .resizable : .locked
                )
                applyResizableAspectLock(reason: "appear")
            }
            if runtimeSession.activeWindowId == nil {
                runtimeSession.setActiveWindow(rootWindow.windowId)
            }
            startStreaming()
            setSoftwareKeyboardActive(keyboardEnabled)
            syncGameControllerInputOwner()
        }
        .onDisappear {
            gameControllerInput.release(owner: gameControllerOwnerID)
            cancelDirectScrollInertia()
            cancelPassiveRootWindowClose()
            runtimeSession.forceMouseUpIfNeeded(reason: "view disappeared")

#if os(visionOS)
            if isOpeningImmersive || scenes.isPeelImmersiveSpaceOpen {
                return
            }
#endif

            scenes.markPeeledWindowSceneClosed(currentScene, for: hostedWindow(rootWindow))

            guard !isSwitchingFrameMode else {
                return
            }

#if os(visionOS)
            agentPresentationCoordinator.clearPresentationContext(for: hostedWindow(rootWindow))
#endif

            sendSceneWindowActivity(false)
            for hostedWindow in windowsHostedByScene {
                sendHostingMode(.inPlace, for: hostedWindow)
            }

        #if os(visionOS)
            if scenes.shouldRestoreMainAfterPeeledWindowClosed() {
                openWindow(id: "main")
            }
        #endif

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
            if newPhase == .active {
                syncGameControllerInputOwner()
            } else {
                gameControllerInput.release(owner: gameControllerOwnerID)
            }
#if os(visionOS)
            if isOpeningImmersive || scenes.isPeelImmersiveSpaceOpen || isSwitchingFrameMode {
                return
            }
#endif
            if newPhase != .active {
                cancelDirectScrollInertia()
                releaseLocalMouseDownIfNeeded()
            }
            sendSceneWindowActivity(newPhase == .active)
        }
        .onChange(of: peeledWindowHostingMode) { _, newMode in
            sendHostingMode(newMode, for: rootWindow)
            let popupMode: PeeledWindowHostingMode = newMode == .restorePreviousMacContext
                ? .restorePreviousMacContext
                : .inPlace
            for popupWindow in popupWindowStack {
                sendHostingMode(popupMode, for: popupWindow)
            }
            sendSceneWindowActivity(scenePhase == .active)
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
        .onReceive(runtimeSession.$activeWindowId) { _ in
            // @Published emits before the store; read settled session state next turn.
            DispatchQueue.main.async {
                syncGameControllerInputOwner()
            }
        }
        .onChange(of: presentedWindow.windowId) { _, _ in
            syncGameControllerInputOwner()
        }
        .onChange(of: scenes.isPeelImmersiveSpaceOpen) { _, _ in
            syncGameControllerInputOwner()
        }
        .onReceive(runtimeSession.$isConnectionReady) { _ in
            // A replacement connection needs a fresh claim; read settled state next turn.
            DispatchQueue.main.async {
                syncGameControllerInputOwner()
            }
        }
        .background(
            PeelGameControllerEventInteractionAnchor(
                isEnabled: gameControllerInput.routingOwnerID == gameControllerOwnerID &&
                    scenePhase == .active &&
                    !isOpeningImmersive &&
                    !scenes.isPeelImmersiveSpaceOpen
            )
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        )
        .onChange(of: rootWindow.windowId) { _, _ in
            if let currentScene {
                scenes.registerPeeledWindowScene(
                    currentScene,
                    for: hostedWindow(rootWindow),
                    mode: frameMode == .resizable ? .resizable : .locked
                )
                lastAppliedResizableAspect = 0
                applyResizableAspectLock(reason: "root window changed")
            }
        }
        .onChange(of: preferredContentAspect) { _, _ in
            lastAppliedResizableAspect = 0
            applyResizableAspectLock(reason: "content aspect changed")
        }
        .background(
            WindowSceneReader { scene in
                let sceneID = scene.session.persistentIdentifier

                DispatchQueue.main.async {
                    if currentScene?.session.persistentIdentifier != sceneID {
                        currentScene = scene
                        scenes.registerPeeledWindowScene(
                            scene,
                            for: hostedWindow(rootWindow),
                            mode: frameMode == .resizable ? .resizable : .locked
                        )
                        lastAppliedResizableAspect = 0
                        applyResizableAspectLock(reason: "scene resolved")
                        syncGameControllerInputOwner()
                    }
                }
            }
        )
#if DEBUG
        .onReceive(overlayTimer) { now in
            updateLatency(now: now)
        }
#endif

        
        Group {
            switch frameMode {
            case .locked:
                core
                    .frame(
                        width: preferredVisionWindowSize.width,
                        height: preferredVisionWindowSize.height
                    )

            case .resizable:
                core
                    .frame(
                        minWidth: preferredResizableMinimumSize.width,
                        idealWidth: preferredResizableIdealSize.width,
                        minHeight: preferredResizableMinimumSize.height,
                        idealHeight: preferredResizableIdealSize.height
                    )
            }
        }
        .ornament(
            visibility: .visible,
            attachmentAnchor: .scene(.topLeading),
            contentAlignment: .bottomLeading
        ) {
            ornamentMenuButton
        }

            .ornament(
                visibility: .visible,
                attachmentAnchor: .scene(.top),
                contentAlignment: .bottom
            ) {
                HStack(spacing: 8) {
                    ornamentStatus
                    if gameControllerInput.hasSupportedController {
                        PeelGameControllerHelpButton(ownerID: gameControllerOwnerID, size: 44)
                            .glassBackgroundEffect(in: Circle())
                    }
                }
                .padding()
            }
        
        
        .ornament(
            visibility: .visible,
            attachmentAnchor: .scene(.topTrailing),
            contentAlignment: .bottomTrailing
        ) {
            if isPresentedWindowActive {
                if showInputModeControls {
                    ornamentInputModes
                        .padding()
                }

            }
        }
        .ornament(
            visibility: .visible,
            attachmentAnchor: .scene(.bottom),
            contentAlignment: .top
        ){
            if isPresentedWindowActive{
                ornamentUtilityModes
                    .padding()
            }
        }
        .ornament(
            visibility: showZoomButtons ? .visible : .hidden,
            attachmentAnchor: .scene(.topTrailing),
            contentAlignment: .bottomTrailing
        ) {
            zoomButtonsOrnament
        }
        
        .ornament(
            visibility: showKeyboardMacroKeys && !shouldCollapseKeyboardCommandOrnaments ? .visible : .hidden,
            attachmentAnchor: .scene(.leading),
            contentAlignment: .trailing
        ) {
            if isPresentedWindowActive {
                VStack(spacing: 10) {
                    KeyboardMacroKeysOverlay(
                        onEscape: {
                            sendKeyboardMacroCommand(.escape)
                        },
                        onTab: {
                            sendKeyboardMacroText("\t")
                        },
                        isShiftEnabled: true,
                        isShiftActive: heldMacroCommands.contains(.shift),
                        onShift: {
                            handleModifierMacroCommand(.shift)
                        }
                    )
                    
                    
                }
                .padding()
            }
        }
        .ornament(
            visibility: showKeyboardMacroKeys && !shouldCollapseKeyboardCommandOrnaments ? .visible : .hidden,
            attachmentAnchor: .scene(.bottomLeading),
            contentAlignment: .topLeading
        ) {
            if isPresentedWindowActive {
                VStack(alignment: .leading, spacing: 10) {
                    KeyboardModifierKeysOverlay(
                        heldCommands: heldMacroCommands,
                        onFunction: {
                            handleModifierMacroCommand(.function)
                        },
                        onControl: {
                            handleModifierMacroCommand(.control)
                        },
                        onOption: {
                            handleModifierMacroCommand(.option)
                        },
                        onCommand: {
                            handleModifierMacroCommand(.command)
                        }
                    )

                    macroHoldControlsOrnament
                }
                .padding()
            }
        }
        .ornament(
            visibility: (showScrollControlButtons || (showKeyboardMacroKeys && !shouldCollapseKeyboardCommandOrnaments)) ? .visible : .hidden,
            attachmentAnchor: .scene(.trailing),
            contentAlignment: .leading
        ) {
            if isPresentedWindowActive {
                trailingKeyboardAndScrollOrnament
                    .padding()
            }
        }
        .ornament(
            visibility: showKeyboardArrowKeys && !shouldCollapseKeyboardCommandOrnaments ? .visible : .hidden,
            attachmentAnchor: .scene(.bottomTrailing),
            contentAlignment: .topTrailing
        ) {if isPresentedWindowActive {
            KeyboardArrowKeysOverlay(
                onLeft: {
                    sendKeyboardMacroCommand(.leftArrow)
                },
                onUp: {
                    sendKeyboardMacroCommand(.upArrow)
                },
                onDown: {
                    sendKeyboardMacroCommand(.downArrow)
                },
                onRight: {
                    sendKeyboardMacroCommand(.rightArrow)
                }
            )
            .padding()
        }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: shouldCollapseKeyboardCommandOrnaments)
        .onAppear {
            if !showInputModeControls {
                resetAdvancedInputControls()
            }
        }
        .onChange(of: showInputModeControls) { _, newValue in
            if !newValue {
                resetAdvancedInputControls()
            }
        }
        .sheet(isPresented: $showingWindowPaywall) {
            PeelPaywallView(feature: .multipleWindows).environmentObject(store)
        }
        .sheet(isPresented: $showingStreamDetails) {
            PeelStreamDetailsView(requestNativeExperiment: nativeStreamExperimentAction) {
                let windowId = presentedWindow.windowId
                guard runtimeSession.isConnectionReady,
                      let renderer = runtimeSession.videoRenderer(for: windowId) else { return nil }
#if os(visionOS)
                let spatial = runtimeSession.activeSpatialWindowIds.contains(windowId)
#else
                let spatial = false
#endif
                var row = renderer.streamingDiagnosticSnapshot(windowId: windowId, spatial: spatial)
#if os(visionOS)
                if spatial { row?.spatialPipeline = runtimeSession.spatialVideoRenderers[windowId]?.streamingDiagnosticSnapshot() }
#endif
                return row
            }
            .id(presentedWindow.windowId)
        }
#if os(iOS) || os(visionOS)
        .sheet(isPresented: $showingNotifications) {
            NavigationStack {
                PeelRemoteNotificationInboxView(
                    inbox: remoteNotificationPresenter.inbox
                )
            }
        }
#endif
        
    }
    
   

    private var nativeStreamExperimentAction: (() -> Void)? {
#if DEBUG
        guard PeelHostSession.nativeStreamExperimentFPS != nil else { return nil }
        return { runtimeSession.requestNativeStreamExperiment(windowId: presentedWindow.windowId) }
#else
        return nil
#endif
    }

    private var rootWindow: PeelWindow {
        rootWindowOverride ?? window
    }

    private var presentedWindow: PeelWindow {
        popupWindowStack.last ?? rootWindow
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
        window.appName.trimmingCharacters(in: .whitespacesAndNewlines) == "Peel Display"
    }

    private func isInputReadyForWindow(_ window: PeelWindow, streamStatus: WindowStreamStatus? = nil) -> Bool {
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
           let connectedHostName = connectedHostComputerName(for: window) {
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

    private func windowChromeSubtitle(for window: PeelWindow) -> String? {
        guard !isDisplayCaptureWindow(window),
              let connectedHostName = connectedHostComputerName(for: window) else {
            return nil
        }

        let hostName = displayNameWithoutPeelPrefix(connectedHostName)
        return hostName.isEmpty ? nil : hostName
    }

    private func connectedHostComputerName(for window: PeelWindow) -> String? {
        hostName ?? runtimeSession.connectedHostName
    }

    private var allPresentedWindows: [PeelWindow] {
        [rootWindow] + popupWindowStack
    }

    private var shouldCollapseKeyboardCommandOrnaments: Bool {
        guard currentPeeledWindowSize.width > 0, currentPeeledWindowSize.height > 0 else {
            return false
        }

        // Keep the original floating key ornaments on normal windows.
        // Collapse only when the bottom-corner / side ornaments are likely to collide.
        return currentPeeledWindowSize.width < 620 || currentPeeledWindowSize.height < 360
    }
    
    private var ornamentMenuButton: some View {
        HStack(spacing: 10) {
            Button {
                returnToBrowser()
            } label: {
                Image("PeelHostMenuBarIcon_128x128")
                    .resizable()
                    .frame(width: 28, height: 28)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassBackgroundEffect(in: Circle())
            .accessibilityLabel("Return to Peel Pro")
            Button {
                showingStreamDetails = true
            } label: {
                Image(systemName: "chart.bar.xaxis")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassBackgroundEffect(in: Circle())
            .accessibilityLabel("Stream Details")
#if os(iOS) || os(visionOS)
            Button {
                showingNotifications = true
            } label: {
                Image(
                    systemName: remoteNotificationPresenter.latestNotifications.isEmpty
                        ? "bell"
                        : "bell.badge"
                )
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassBackgroundEffect(in: Circle())
            .accessibilityLabel("Notifications")
#endif
            PeelSourceMediaControls(
                session: sourceMediaOwnerSession,
                windowId: presentedWindow.windowId,
                computerName: sourceMediaComputerName,
                style: shouldCollapseKeyboardCommandOrnaments ? .menu : .ornament,
                canInteract: { scenePhase == .active }
            )
     /*
            Button {
                switchFrameMode()
            } label: {
                Image(systemName: frameMode == .locked ? "lock.fill" : "lock.open")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .tint(frameMode == .locked ? .blue : .primary)
            }
            .buttonStyle(.plain)
            .glassBackgroundEffect(in: Circle())
            .disabled(isSwitchingFrameMode)
            .accessibilityLabel(frameMode == .locked ? "Unlock window resizing" : "Lock window size")

*/
        }
        .padding()
    }
    
    @ViewBuilder
    private var zoomButtonsOrnament: some View {
        HStack(spacing: 12) {
            
            Button {
                zoomOut()
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassBackgroundEffect(in: Circle())
            Button {
                zoomIn()
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassBackgroundEffect(in: Circle())


        }


        .padding(.vertical)

    }

    private func zoomIn() {
        setZoomScale(zoomScale * 1.25)
    }

    private func zoomOut() {
        setZoomScale(zoomScale / 1.25)
    }

    private func setZoomScale(_ proposedScale: CGFloat) {
        let clampedScale = min(max(proposedScale, 1.0), 4.0)
        zoomScale = clampedScale

        if clampedScale <= 1.0001 {
            contentOffset = .zero
            baseContentOffset = .zero
        }
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
        let subtitle = windowChromeSubtitle(for: activeWindow)

        return HStack(spacing: 8) {
            StatusDot(status: status)

            VStack(alignment: .center, spacing: 2) {
                Text(title)
                    .font(.caption.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: 260, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, subtitle == nil ? 8 : 7)
        .glassBackgroundEffect(in: Capsule())
        .accessibilityLabel(accessibilityStatusLabel(title: title, subtitle: subtitle, status: status))
    }

    private func openingAppName(for window: PeelWindow) -> String {
        windowChromeTitle(for: window)
    }

    private func accessibilityStatusLabel(title: String, subtitle: String?, status: WindowStreamStatus) -> String {
        if let subtitle {
            return "\(title) on \(subtitle). Stream status: \(statusLabel(status))."
        }

        return "\(title). Stream status: \(statusLabel(status))."
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

        if reason.contains("top window") || reason.contains("not frontmost") || reason.contains("activation") {
            return "Tap once to bring this window forward."
        }

        if reason.contains("remote control is disabled") || reason.contains("accessibility") {
            return "Allow Peel Pro to control this Mac in Settings."
        }

        return "Peel Pro could not send that input yet."
    }
#if os(visionOS)
    private func openPeelImmersiveMode() {
        guard !isOpeningImmersive else {
            return
        }

        runtimeSession.forceMouseUpIfNeeded(reason: "opening Peel immersive mode")

        let windowsForImmersive = stableUniquedWindows(
            allPresentedWindows + scenes.openPeeledWindows()
        )

        guard scenes.preparePeelImmersiveSpace(
            primary: presentedWindow,
            windows: windowsForImmersive
        ) else {
            if !store.hasProAccess { showingWindowPaywall = true }
            return
        }

        // print("🪟 Prepared Peel Field with \(windowsForImmersive.count) windows. Primary=\(presentedWindow.windowId)")

        if scenes.isPeelImmersiveSpaceOpen {
            // print("⏭️ Peel Field already marked open")
            return
        }

        scenes.preparePeelImmersiveLaunch(context: .regular)
        isOpeningImmersive = true
        // The window gives up controller input as soon as the transition starts.
        gameControllerInput.release(owner: gameControllerOwnerID)

        Task { @MainActor in
            // print("2️⃣ requesting immersive space")
            let result = await openImmersiveSpace(id: "peel-immersive")
            // print("3️⃣ immersive result returned: \(result)")
            switch result {
            case .opened:
                // print("✅ Peel Field opened")
                scenes.markPeelImmersiveSpaceOpen()

            case .userCancelled:
                // print("⚠️ Peel Field open cancelled")
                scenes.markPeelImmersiveSpaceClosed()

            case .error:
                // print("❌ Peel Field failed to open")
                scenes.markPeelImmersiveSpaceClosed()

            @unknown default:
                // print("❌ Peel Field unknown open result: \(result)")
                scenes.markPeelImmersiveSpaceClosed()
            }

            isOpeningImmersive = false
            // Opened: the sync guard keeps it released. Cancelled or failed: the
            // normal eligible offer restores it.
            syncGameControllerInputOwner()
        }
    }
#endif

    private func stableUniquedWindows(_ windows: [PeelWindow]) -> [PeelWindow] {
        var seen = Set<UInt32>()
        var result: [PeelWindow] = []

        for window in windows where seen.insert(window.windowId).inserted {
            result.append(window)
        }

        return result
    }
    private func returnToBrowser(userInitiated: Bool = true) {
#if os(visionOS)
        guard userInitiated else {
            closeThisPeeledWindow()
            return
        }

        guard !isOpeningHome else { return }

        runtimeSession.forceMouseUpIfNeeded(reason: "opening browser from peeled window")
        isOpeningHome = true

        _ = scenes.activateMainIfPossible()

        if scenes.shouldPresentMainSceneFromUserAction() {
            openWindow(id: "main")
            didRestoreBrowserWindow = true
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            isOpeningHome = false
        }
#else
        guard !isOpeningHome, !isReturningToBrowser else { return }

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

        _ = scenes.activateMainIfPossible()

        if scenes.shouldPresentMainSceneFromUserAction() {
            openWindow(id: "main")
            didRestoreBrowserWindow = true
        }

        dismiss()

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            isOpeningHome = false
        }
#endif
    }
    
    private func closeThisPeeledWindow() {
        runtimeSession.forceMouseUpIfNeeded(reason: "closing peeled window")

#if os(visionOS)
        if !scenes.closePeeledWindowScene(for: hostedWindow(rootWindow)) {
            dismiss()
        }
#else
        dismiss()
#endif
    }
    
    private func switchFrameMode() {
        guard !isSwitchingFrameMode else { return }

        isSwitchingFrameMode = true
        runtimeSession.forceMouseUpIfNeeded(reason: "switching peeled window frame mode")

        let targetSceneId: String
        switch frameMode {
        case .locked:
            targetSceneId = "peeled-window-resizable"
        case .resizable:
            targetSceneId = "peeled-window"
        }

        guard scenes.reservePeeledWindowScene(
            for: hostedWindow(presentedWindow),
            mode: frameMode == .locked ? .resizable : .locked
        ) else {
            isSwitchingFrameMode = false
            if !store.hasProAccess { showingWindowPaywall = true }
            return
        }
        openWindow(id: targetSceneId, value: PeeledWindowSceneRequest(hostedWindow: hostedWindow(presentedWindow)))

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            dismiss()
        }
    }

    private func resetAdvancedInputControls() {
        rightClickModeStaysEnabled = false
        activeClickButton = .left

        if isDragModeArmed || mouseDragDidSendDown || isMouseDragActive || mouseDragStartNorm != nil {
            finishArmedDirectDragIfNeeded()
        } else {
            isDragModeTemporarilySuppressed = false
        }
    }

    private var ornamentInputModes: some View {
        HStack(spacing: 10) {
            // Button {
            //     switchFrameMode()
            // } label: {
            //     Image(systemName: frameMode == .locked ? "lock.fill" : "lock.open")
            //         .font(.title3.weight(.semibold))
            //         .frame(width: 44, height: 44)
            //         .contentShape(Circle())
            // }
            // .buttonStyle(.plain)
            // .glassBackgroundEffect(in: Circle())
            Button {
                activeClickButton = activeClickButton == .left ? .right : .left
            } label: {
                let isRightClickArmed = activeClickButton == .right

                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "cursorarrow.click")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(isRightClickArmed ? Color.blue : Color.primary)

                    Text("R")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(isRightClickArmed ? Color.blue : Color.primary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.thinMaterial, in: Capsule())
                        .offset(x: 6, y: 6)
                }
                .frame(width: 44, height: 44)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassBackgroundEffect(in: Circle())
            .accessibilityLabel(activeClickButton.accessibilityLabel)

            Button {
                if isDragModeArmed {
                    finishArmedDirectDragIfNeeded()
                } else {
                    isDragModeArmed = true
                    isDragModeTemporarilySuppressed = false

                    if let norm = tapCursorNorm {
                        showSharedCursor(at: norm, mode: .drag)
                    } else {
                        runtimeSession.showSharedCursor(
                            for: presentedWindow.windowId,
                            norm: runtimeSession.currentSharedCursorNorm(for: presentedWindow.windowId),
                            mode: .drag
                        )
                    }
                }
            } label: {
                Image(systemName: isDragModeArmed ? "hand.point.up.left.fill" : "hand.point.up.left")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isDragModeArmed && !isDragModeTemporarilySuppressed ? Color.blue : Color.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassBackgroundEffect(in: Circle())
            .accessibilityLabel(isDragModeArmed ? "Disable drag mode" : "Enable drag mode")
        }
    }

    private func setSoftwareKeyboardActive(_ isActive: Bool) {
        if keyboardEnabled != isActive { keyboardEnabled = isActive }
        if keyboardFocused != isActive { keyboardFocused = isActive }
        if isFocusedBridge != isActive { isFocusedBridge = isActive }

        guard isActive else { return }

        runtimeSession.setActiveWindow(presentedWindow.windowId)
        keyboardFocusRequestID += 1
    }

    private func handleKeyboardFocusChanged(_ isFocused: Bool) {
        DispatchQueue.main.async {
            if keyboardEnabled != isFocused { keyboardEnabled = isFocused }
            if keyboardFocused != isFocused { keyboardFocused = isFocused }
            if isFocusedBridge != isFocused { isFocusedBridge = isFocused }
        }
    }

    private func prepareKeyboardMacroTarget() {
        runtimeSession.setActiveWindow(presentedWindow.windowId)

        // Keep the software keyboard state unchanged. Macro buttons should target the
        // Mac window without unexpectedly opening or closing the software keyboard.
        setSoftwareKeyboardActive(keyboardEnabled)
    }

    private enum SoftwareKeyboardSpecialKey {
        case backspace
        case enter
        case tab
    }

    private struct SoftwareKeyboardHardwareKey {
        let keyCode: Int
        let characters: String?
        let charactersIgnoringModifiers: String?
    }

    private func showMacroPreviewKey(_ text: String) {
        guard isMacroHoldModeEnabled else { return }

        pulseMacroHoldChrome()
        macroPreviewKeyText = text
        macroPreviewClearTask?.cancel()
        macroPreviewClearTask = Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                macroPreviewKeyText = nil
            }
        }
    }

    private func displayTextForSoftwareMacroCharacter(_ character: Character) -> String {
        let text = String(character)
        if text == " " { return "Space" }
        if text == "\t" { return "Tab" }
        if text == "\n" || text == "\r" { return "Return" }
        return text.uppercased()
    }

    private func handleSoftwareKeyboardTextInput(_ text: String) {
        guard !text.isEmpty else { return }

        guard isMacroHoldModeEnabled else {
            runtimeSession.sendKeyboardText(text)
            return
        }

        runtimeSession.setActiveWindow(presentedWindow.windowId)

        // While Macro Hold is active, software keyboard commits should become
        // hardware-style key presses. Do not insert text into the Mac here.
        for character in text {
            guard let key = softwareKeyboardHardwareKey(for: character) else { continue }
            showMacroPreviewKey(displayTextForSoftwareMacroCharacter(character))
            runtimeSession.sendKeyboardHardwareKey(
                keyCode: key.keyCode,
                characters: key.characters,
                charactersIgnoringModifiers: key.charactersIgnoringModifiers,
                modifiers: heldMacroCommands
            )
        }
    }

    private func handleSoftwareKeyboardSpecialKey(_ key: SoftwareKeyboardSpecialKey) {
        // Esc / Tab / Enter / Backspace should stay as normal software-key controls.
        // They do not participate in Macro Hold, do not update the macro preview,
        // and do not inherit held modifiers.
        switch key {
        case .backspace:
            runtimeSession.sendKeyboardText("\u{8}")
        case .enter:
            runtimeSession.sendKeyboardText("\n")
        case .tab:
            runtimeSession.sendKeyboardText("\t")
        }
    }

    private func softwareKeyboardHardwareKey(for character: Character) -> SoftwareKeyboardHardwareKey? {
        let text = String(character)
        let lower = text.lowercased()

        if let scalar = lower.unicodeScalars.first, lower.unicodeScalars.count == 1 {
            let value = scalar.value

            if value >= 97 && value <= 122 {
                return SoftwareKeyboardHardwareKey(
                    keyCode: Int(value - 97 + 0x04),
                    characters: lower,
                    charactersIgnoringModifiers: lower
                )
            }

            if value >= 49 && value <= 57 {
                return SoftwareKeyboardHardwareKey(
                    keyCode: Int(value - 49 + 0x1E),
                    characters: lower,
                    charactersIgnoringModifiers: lower
                )
            }

            if value == 48 {
                return SoftwareKeyboardHardwareKey(keyCode: 0x27, characters: lower, charactersIgnoringModifiers: lower)
            }
        }

        switch lower {
        case " ": return SoftwareKeyboardHardwareKey(keyCode: 0x2C, characters: " ", charactersIgnoringModifiers: " ")
        case "-", "_": return SoftwareKeyboardHardwareKey(keyCode: 0x2D, characters: "-", charactersIgnoringModifiers: "-")
        case "=", "+": return SoftwareKeyboardHardwareKey(keyCode: 0x2E, characters: "=", charactersIgnoringModifiers: "=")
        case "[", "{": return SoftwareKeyboardHardwareKey(keyCode: 0x2F, characters: "[", charactersIgnoringModifiers: "[")
        case "]", "}": return SoftwareKeyboardHardwareKey(keyCode: 0x30, characters: "]", charactersIgnoringModifiers: "]")
        case "\\", "|": return SoftwareKeyboardHardwareKey(keyCode: 0x31, characters: "\\", charactersIgnoringModifiers: "\\")
        case ";", ":": return SoftwareKeyboardHardwareKey(keyCode: 0x33, characters: ";", charactersIgnoringModifiers: ";")
        case "'", "\"": return SoftwareKeyboardHardwareKey(keyCode: 0x34, characters: "'", charactersIgnoringModifiers: "'")
        case "`", "~": return SoftwareKeyboardHardwareKey(keyCode: 0x35, characters: "`", charactersIgnoringModifiers: "`")
        case ",", "<": return SoftwareKeyboardHardwareKey(keyCode: 0x36, characters: ",", charactersIgnoringModifiers: ",")
        case ".", ">": return SoftwareKeyboardHardwareKey(keyCode: 0x37, characters: ".", charactersIgnoringModifiers: ".")
        case "/", "?": return SoftwareKeyboardHardwareKey(keyCode: 0x38, characters: "/", charactersIgnoringModifiers: "/")
        default: return nil
        }
    }

    private func hardwareKey(for command: KeyboardCommand) -> SoftwareKeyboardHardwareKey? {
        switch command {
        case .escape:
            return SoftwareKeyboardHardwareKey(keyCode: 0x29, characters: nil, charactersIgnoringModifiers: nil)
        case .enter:
            return SoftwareKeyboardHardwareKey(keyCode: 0x28, characters: "\r", charactersIgnoringModifiers: "\r")
        case .backspace:
            return SoftwareKeyboardHardwareKey(keyCode: 0x2A, characters: nil, charactersIgnoringModifiers: nil)
        case .leftArrow:
            return SoftwareKeyboardHardwareKey(keyCode: 0x50, characters: nil, charactersIgnoringModifiers: nil)
        case .rightArrow:
            return SoftwareKeyboardHardwareKey(keyCode: 0x4F, characters: nil, charactersIgnoringModifiers: nil)
        case .upArrow:
            return SoftwareKeyboardHardwareKey(keyCode: 0x52, characters: nil, charactersIgnoringModifiers: nil)
        case .downArrow:
            return SoftwareKeyboardHardwareKey(keyCode: 0x51, characters: nil, charactersIgnoringModifiers: nil)
        default:
            return nil
        }
    }

    private func sendKeyboardMacroText(_ text: String) {
        prepareKeyboardMacroTarget()

        guard isMacroHoldModeEnabled else {
            runtimeSession.sendKeyboardText(text)
            return
        }

        // While Macro Hold is active, printable button-originated text should behave
        // like software keyboard input. Special keys stay detached from Macro Hold.
        for character in text {
            if character == "\t" {
                runtimeSession.sendKeyboardText("\t")
                continue
            }
            if character == "\n" || character == "\r" {
                runtimeSession.sendKeyboardText("\n")
                continue
            }
            if character == "\u{8}" {
                runtimeSession.sendKeyboardText("\u{8}")
                continue
            }

            guard let key = softwareKeyboardHardwareKey(for: character) else { continue }
            showMacroPreviewKey(displayTextForSoftwareMacroCharacter(character))
            runtimeSession.sendKeyboardHardwareKey(
                keyCode: key.keyCode,
                characters: key.characters,
                charactersIgnoringModifiers: key.charactersIgnoringModifiers,
                modifiers: heldMacroCommands
            )
        }
    }

    private func sendKeyboardMacroCommand(_ command: KeyboardCommand) {
        prepareKeyboardMacroTarget()

        // Esc / Enter / Backspace stay detached from Macro Hold. They should always
        // behave like immediate software-key buttons, with no preview and no held modifiers.
        switch command {
        case .escape, .enter, .backspace:
            runtimeSession.sendKeyboardCommand(command)
            return
        default:
            break
        }

        guard isMacroHoldModeEnabled, let hardwareKey = hardwareKey(for: command) else {
            runtimeSession.sendKeyboardCommand(command)
            return
        }

        // Arrow buttons use the same preview + hardware-key route as software
        // keyboard commits while Macro Hold is on.
        showMacroPreviewKey(macroDisplayTitle(for: command))
        runtimeSession.sendKeyboardHardwareKey(
            keyCode: hardwareKey.keyCode,
            characters: hardwareKey.characters,
            charactersIgnoringModifiers: hardwareKey.charactersIgnoringModifiers,
            modifiers: heldMacroCommands
        )
    }

    private func handleModifierMacroCommand(_ command: KeyboardCommand) {
        // Modifier keys are not useful as standalone taps in Peel's software UI.
        // Treat them as the natural entry point into Macro Hold instead.
        if !isMacroHoldModeEnabled {
            setMacroHoldModeEnabled(true)
        }

        toggleHeldMacroCommand(command)
        pulseMacroHoldChrome()
    }

    private func toggleHeldMacroCommand(_ command: KeyboardCommand) {
        prepareKeyboardMacroTarget()

        if let existingIndex = heldMacroCommands.firstIndex(of: command) {
            heldMacroCommands.remove(at: existingIndex)
        } else {
            heldMacroCommands.append(command)
        }
    }

    private func pulseMacroHoldChrome() {
        guard isMacroHoldModeEnabled else { return }

        withAnimation(.easeOut(duration: 0.18)) {
            macroHoldPulse = true
        }

        Task {
            try? await Task.sleep(nanoseconds: 420_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.32)) {
                    macroHoldPulse = false
                }
            }
        }
    }

    private func setMacroHoldModeEnabled(_ isEnabled: Bool) {
        isMacroHoldModeEnabled = isEnabled

        if !isEnabled {
            heldMacroCommands.removeAll()
            macroPreviewKeyText = nil
            macroPreviewClearTask?.cancel()
            macroPreviewClearTask = nil
            macroHoldPulse = false
        } else {
            runtimeSession.setActiveWindow(presentedWindow.windowId)
            setSoftwareKeyboardActive(true)
            pulseMacroHoldChrome()
        }
    }

    private func macroDisplayTitle(for command: KeyboardCommand) -> String {
        switch command {
        case .command:
            return "⌘"
        case .option:
            return "⌥"
        case .control:
            return "⌃"
        case .shift:
            return "⇧"
        case .function:
            return "fn"
        case .escape:
            return "Esc"
        case .enter:
            return "Return"
        case .backspace:
            return "Delete"
        case .leftArrow:
            return "←"
        case .rightArrow:
            return "→"
        case .upArrow:
            return "↑"
        case .downArrow:
            return "↓"
        default:
            return String(describing: command)
        }
    }

    private var heldMacroDisplayText: String {
        let heldText = heldMacroCommands.map { macroDisplayTitle(for: $0) }
        let previewText = macroPreviewKeyText.map { [$0] } ?? []
        return (heldText + previewText).joined(separator: " ")
    }

    private var macroHoldControlsOrnament: some View {
        HStack(spacing: 10) {
            MacroHoldButton(
                            isEnabled: isMacroHoldModeEnabled,
                        isPulsing: false,
                            action: {
                    setMacroHoldModeEnabled(!isMacroHoldModeEnabled)
                }
            )

            MacroHeldStatusView(
                text: heldMacroDisplayText,
                isRecording: isMacroHoldModeEnabled,
                isPulsing: macroHoldPulse
            )

            if isMacroHoldModeEnabled && (!heldMacroCommands.isEmpty || macroPreviewKeyText != nil) {
              //  MacroSaveButton {
                    // Phase 1 placeholder. This button is intentionally wired for UI testing only.
                    // The save flow should be added after macro recording/persistence exists.
              //  }
            }
        }
    }

    private var trailingKeyboardAndScrollOrnament: some View {
        VStack(spacing: 10) {
            if showScrollControlButtons {
                scrollControlOrnament
            }
            if showKeyboardMacroKeys && !shouldCollapseKeyboardCommandOrnaments {
                EnterBackspaceKeysOverlay(
                    onEnter: {
                        sendKeyboardMacroCommand(.enter)
                    },
                    onBackspace: {
                        sendKeyboardMacroCommand(.backspace)
                    }
                )
                .padding(.top, 80)
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            }


        }
    }

    private var keyboardCommandsMenu: some View {
        Button {
            showKeyboardCommandsPopover.toggle()
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassBackgroundEffect(in: Circle())
        .accessibilityLabel("Keyboard commands")
        .popover(isPresented: $showKeyboardCommandsPopover, arrowEdge: .bottom) {
            keyboardCommandsPopoverContent
        }
    }

    private var keyboardCommandsPopoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showKeyboardMacroKeys {
                HStack(spacing: 8) {
                    compactCommandButton("fn") { sendKeyboardMacroCommand(.function) }
                    compactCommandButton("control") { sendKeyboardMacroCommand(.control) }
                    compactCommandButton("option") { sendKeyboardMacroCommand(.option) }
                    compactCommandButton("command") { sendKeyboardMacroCommand(.command) }
                }

                HStack(spacing: 8) {
                    compactCommandButton("esc") { sendKeyboardMacroCommand(.escape) }
                    compactCommandButton("tab") { sendKeyboardMacroText("\t") }
                    compactCommandButton("shift") { sendKeyboardMacroCommand(.shift) }
                }

                HStack(spacing: 8) {
                    compactCommandButton("return") { sendKeyboardMacroCommand(.enter) }
                    compactCommandButton("delete") { sendKeyboardMacroCommand(.backspace) }
                }
            }

            if showKeyboardMacroKeys && showKeyboardArrowKeys {
                Divider()
            }

            if showKeyboardArrowKeys {
                HStack(spacing: 8) {
                    compactCommandButton("←") { sendKeyboardMacroCommand(.leftArrow) }
                    compactCommandButton("↑") { sendKeyboardMacroCommand(.upArrow) }
                    compactCommandButton("↓") { sendKeyboardMacroCommand(.downArrow) }
                    compactCommandButton("→") { sendKeyboardMacroCommand(.rightArrow) }
                }
            }
        }
        .padding(14)
        .frame(minWidth: 260, alignment: .leading)
    }

    private func compactCommandButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            showKeyboardCommandsPopover = false
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .frame(minWidth: 44, minHeight: 36)
                .padding(.horizontal, 8)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassBackgroundEffect(in: Capsule())
        .accessibilityLabel(title)
    }

    private var keyboardMacroMenu: some View {
        Button {
            showKeyboardMacroPopover.toggle()
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassBackgroundEffect(in: Circle())
        .accessibilityLabel("Keyboard commands")
        .popover(isPresented: $showKeyboardMacroPopover, arrowEdge: .bottom) {
            keyboardMacroPopoverContent
        }
    }

    private var keyboardMacroPopoverContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            macroButton("Tab") { sendKeyboardMacroText("\t") }
            macroButton("Enter") { sendKeyboardMacroText("\n") }
            macroButton("Backspace") { sendKeyboardMacroText("\u{8}") }
            macroButton("Space") { sendKeyboardMacroText(" ") }

            Divider()
                .padding(.vertical, 2)

            macroButton("Escape") { sendKeyboardMacroCommand(.escape) }
            macroButton("← Left") { sendKeyboardMacroCommand(.leftArrow) }
            macroButton("→ Right") { sendKeyboardMacroCommand(.rightArrow) }
            macroButton("↑ Up") { sendKeyboardMacroCommand(.upArrow) }
            macroButton("↓ Down") { sendKeyboardMacroCommand(.downArrow) }
        }
        .padding(14)
        .frame(minWidth: 190, alignment: .leading)
    }

    private func macroButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            showKeyboardMacroPopover = false
        } label: {
            Text(title)
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var ornamentUtilityModes: some View {
        VStack(alignment: .center, spacing: 10) {
            if supportsSpaceSwitching {
                HStack(spacing: 10) {
                    Button {
                        switchSpaceIfPresentingDisplay { $0.switchSpaceLeft() }
                    } label: {
                        Image(systemName: "chevron.left.2")
                            .font(.title3.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glassBackgroundEffect(in: Circle())
                    .accessibilityLabel("Previous Mac Space")

                    Button {
                        switchSpaceIfPresentingDisplay { $0.switchSpaceRight() }
                    } label: {
                        Image(systemName: "chevron.right.2")
                            .font(.title3.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glassBackgroundEffect(in: Circle())
                    .accessibilityLabel("Next Mac Space")
                }
            }

            HStack(spacing: 10) {
                if shouldCollapseKeyboardCommandOrnaments && (showKeyboardMacroKeys || showKeyboardArrowKeys) {
                    keyboardCommandsMenu
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                }

                Button {
                    setSoftwareKeyboardActive(!keyboardEnabled)
                } label: {
                    ZStack {
                        if keyboardEnabled {
                            Circle()
                                .fill(Color.blue)
                        }

                        Image(systemName: "keyboard")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Color.primary)
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassBackgroundEffect(in: Circle())
                .accessibilityLabel(keyboardEnabled ? "Hide keyboard" : "Show keyboard")

               // keyboardMacroMenu

                if browser.sessionsByHostKey.count <= 1 {
                    Button {
                        runtimeSession.setActiveWindow(presentedWindow.windowId)
                        openWindow(id: "peel-trackpad")
                    } label: {
                        Image(systemName: "rectangle.and.hand.point.up.left")
                            .font(.title3.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glassBackgroundEffect(in: Circle())
                    .accessibilityLabel("Open trackpad")
                }
            }
        }
    }

    private var scrollControlOrnament: some View {
        ScrollControlOverlay { dx, dy in
            let activeWindow = presentedWindow

            guard isInputReadyForWindow(activeWindow) else {
                requestFocusForPresentedWindow(reason: "scroll ornament")
                return
            }

            runtimeSession.sendScroll(on: activeWindow, deltaX: dx, deltaY: dy)
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

            let fallbackAspect = sanitizedContentAspect(
                CGFloat(activeWindow.width) / max(1, CGFloat(activeWindow.height))
            ) ?? fallbackContentAspect
            let contentAspect: CGFloat = {
                if let videoSize,
                   videoSize.width.isFinite,
                   videoSize.height.isFinite,
                   videoSize.width > 0,
                   videoSize.height > 0,
                   let aspect = sanitizedContentAspect(videoSize.width / videoSize.height) {
                    return aspect
                }

                if let cgImage,
                   let aspect = sanitizedContentAspect(CGFloat(cgImage.width) / max(1, CGFloat(cgImage.height))) {
                    return aspect
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
            let renderRect = viewport.fittedContentRect
            ZStack {
                if let videoRenderer, canShowVideo {
                    let cornerRadius: CGFloat = 24

                    CompressedVideoLayerView(renderer: videoRenderer)
                        .frame(
                            width: renderRect.width,
                            height: renderRect.height,
                            alignment: .center
                        )
                        .scaleEffect(zoomScale)
                        .offset(contentOffset)
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
                            .aspectRatio(contentAspect, contentMode: .fit)                            .frame(
                                width: renderRect.width,
                                height: renderRect.height,
                                alignment: .center
                            )
                            .scaleEffect(zoomScale)
                            .offset(contentOffset)
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
                                closeThisPeeledWindow()
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
                                closeThisPeeledWindow()
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

                // Input unavailable hint for this specific peeled window only.
                if !isInputReadyForWindow(activeWindow),
                   runtimeSession.inputRejectionByWindowId[activeWindow.windowId] != nil {
                    VStack {
                        Spacer()

                        VStack(spacing: 12) {
                            Text("Bring to Front")
                                .font(.title2.weight(.bold))
                                .multilineTextAlignment(.center)

                            Text("This app isn't currently able to receive input. Bring the app to the front on your computer and try again.")
                                .font(.body.weight(.medium))
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 24)
                        .frame(maxWidth: 440)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .shadow(radius: 18, y: 8)

                        Spacer()
                    }
                    .padding(24)
                    .transition(.opacity)
                    .allowsHitTesting(false)
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
                    indirectPointerOverlay(
                        activeWindow: activeWindow,
                        viewSize: geo.size,
                        contentAspect: contentAspect
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                }


            }
            .onAppear {
                currentPeeledWindowSize = geo.size
            }
            .onChange(of: geo.size) { _, newSize in
                currentPeeledWindowSize = newSize
            }
            .onChange(of: runtimeSession.snapshotCGImages[activeWindow.windowId]) { _, newValue in
                #if DEBUG
                if newValue != nil {
                    registerFrame()
                }
                #endif
            }
        }
    }
    
    
    // MARK: - Input (letterboxed-aware mapping)

    private func indirectPointerOverlay(
        activeWindow: PeelWindow,
        viewSize: CGSize,
        contentAspect: CGFloat
    ) -> some View {
        IndirectPointerCapture(targetWindowId: activeWindow.windowId, isActive: scenePhase == .active && runtimeSession.isConnectionReady) { event in
            handleIndirectPointerEvent(
                event,
                activeWindow: activeWindow,
                viewSize: viewSize,
                contentAspect: contentAspect
            )
        }
    }

    private func handleIndirectPointerEvent(
        _ event: IndirectPointerEvent,
        activeWindow: PeelWindow,
        viewSize: CGSize,
        contentAspect: CGFloat
    ) {
        switch event {
        case .hover(let location):
            guard let norm = normPoint(for: location, in: viewSize, contentAspect: contentAspect) else {
                runtimeSession.hideSharedCursor(for: activeWindow.windowId)
                return
            }

            tapCursorHideWorkItem?.cancel()
            showSharedCursor(at: norm, mode: .hover)

            runtimeSession.sendMouseMove(on: activeWindow,
                                  normX: Double(norm.x),
                                  normY: Double(norm.y))

        case .hoverEnded:
            guard !isMouseDragActive, !mouseDragDidSendDown else { return }
            endDirectCursorInteraction()
            runtimeSession.hideSharedCursor(for: activeWindow.windowId)

        case .primaryClick(let location):
            sendIndirectClick(at: location, in: viewSize, contentAspect: contentAspect, button: "left")

        case .secondaryClick(let location):
            sendIndirectClick(at: location, in: viewSize, contentAspect: contentAspect, button: "right")

        case .dragBegan(let location):
            guard let norm = normPoint(for: location, in: viewSize, contentAspect: contentAspect) else {
                return
            }

            tapCursorHideWorkItem?.cancel()
            isMouseDragActive = true
            mouseDragStartNorm = norm
            showSharedCursor(at: norm, mode: .drag)

            guard isInputReadyForWindow(activeWindow) else {
                requestFocusForPresentedWindow(reason: "trackpad drag")
                return
            }

            mouseDragDidSendDown = true
            runtimeSession.sendMouseDown(on: activeWindow,
                                  normX: Double(norm.x),
                                  normY: Double(norm.y),
                                  button: "left")

        case .dragChanged(let location):
            guard let norm = normPoint(for: location, in: viewSize, contentAspect: contentAspect) else {
                return
            }

            tapCursorHideWorkItem?.cancel()
            isMouseDragActive = true
            showSharedCursor(at: norm, mode: .drag)

            guard isInputReadyForWindow(activeWindow) else {
                requestFocusForPresentedWindow(reason: "trackpad drag")
                return
            }

            if !mouseDragDidSendDown {
                let startNorm = mouseDragStartNorm ?? norm
                mouseDragStartNorm = startNorm
                mouseDragDidSendDown = true
                runtimeSession.sendMouseDown(on: activeWindow,
                                      normX: Double(startNorm.x),
                                      normY: Double(startNorm.y),
                                      button: "left")
            }

            runtimeSession.sendMouseDrag(on: activeWindow,
                                  normX: Double(norm.x),
                                  normY: Double(norm.y),
                                  button: "left")

        case .dragCancelled:
            runtimeSession.forceMouseUpIfNeeded(reason: "indirect pointer cancelled")
            mouseDragDidSendDown = false
            mouseDragStartNorm = nil
            isMouseDragActive = false

        case .dragEnded(let location):
            let norm = normPoint(for: location, in: viewSize, contentAspect: contentAspect)
                ?? mouseDragStartNorm
                ?? tapCursorNorm
                ?? runtimeSession.currentSharedCursorNorm(for: activeWindow.windowId)

            if mouseDragDidSendDown {
                runtimeSession.sendMouseUp(on: activeWindow,
                                    normX: Double(norm.x),
                                    normY: Double(norm.y),
                                    button: "left")
            } else if isInputReadyForWindow(activeWindow) {
                runtimeSession.sendMouseMove(on: activeWindow,
                                      normX: Double(norm.x),
                                      normY: Double(norm.y))
            }

            mouseDragDidSendDown = false
            mouseDragStartNorm = nil
            isMouseDragActive = false
            showSharedCursor(at: norm, mode: .hover)

        case .scroll(let location, let deltaX, let deltaY):
            guard let norm = normPoint(for: location, in: viewSize, contentAspect: contentAspect) else {
                return
            }

            tapCursorHideWorkItem?.cancel()
            showSharedCursor(at: norm, mode: .hover)

            if zoomScale > 1.0001 {
                let proposed = CGSize(
                    width: contentOffset.width + deltaX,
                    height: contentOffset.height + deltaY
                )
                let transform = ClientViewportTransform(
                    viewSize: viewSize,
                    contentAspect: contentAspect,
                    zoomScale: zoomScale,
                    contentOffset: proposed,
                    clickCalibrationOffset: clickCalibrationOffset
                )
                let clamped = transform.clampedOffset(proposed)
                contentOffset = clamped
                baseContentOffset = clamped
                return
            }

            guard isInputReadyForWindow(activeWindow) else {
                requestFocusForPresentedWindow(reason: "trackpad scroll")
                return
            }

            runtimeSession.sendScroll(on: activeWindow, deltaX: deltaX, deltaY: deltaY)
        }
    }

    private func handleDirectWindowGestureChanged(
        _ value: DragGesture.Value,
        in size: CGSize,
        contentAspect: CGFloat,
        viewport: ClientViewportTransform
    ) {
        tapCursorHideWorkItem?.cancel()

        // Alternative direct-drag mode is still available from the existing debug/control UI,
        // but the default direct window path below is the old drag-to-scroll behavior.
        if isDragModeArmed && !isDragModeTemporarilySuppressed {
            handleArmedDirectDragChanged(value, in: size, contentAspect: contentAspect)
            return
        }

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

        guard !isMouseDragActive, abs(dy) > directScrollFrameNoiseThreshold else {
            return
        }

        let activeWindow = presentedWindow
        guard isInputReadyForWindow(activeWindow) else {
            requestFocusForPresentedWindow(reason: "drag scroll")
            return
        }

        runtimeSession.sendScroll(on: activeWindow, deltaX: dx, deltaY: dy)
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

        if isDragModeArmed && !isDragModeTemporarilySuppressed {
            handleArmedDirectDragEnded(value, in: size, contentAspect: contentAspect)
            return
        }

        if zoomScale > 1.0001 {
            contentOffset = viewport.clampedOffset(contentOffset)
            baseContentOffset = contentOffset
        }

        if isMouseDragActive || mouseDragDidSendDown {
            return
        }

        if duration >= longPressDuration,
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

    private func sendIndirectClick(at location: CGPoint, in size: CGSize, contentAspect: CGFloat, button: String) {
        guard size.width > 0, size.height > 0, contentAspect > 0 else {
            return
        }

        let viewport = viewportTransform(in: size, contentAspect: contentAspect)
        guard let norm = viewport.normalizedPoint(for: location) else {
            return
        }

        let activeWindow = presentedWindow

        guard isInputReadyForWindow(activeWindow) else {
            requestFocusForPresentedWindow(reason: "indirect click")
            return
        }

        let sharedMode: PeelSharedCursorMode = button == "right" ? .rightClick : .click
        showSharedCursor(at: norm, mode: sharedMode)

        runtimeSession.sendClick(
            on: activeWindow,
            normX: Double(norm.x),
            normY: Double(norm.y),
            button: button
        )
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

    private func handleArmedDirectDragChanged(_ value: DragGesture.Value, in size: CGSize, contentAspect: CGFloat) {
        guard let norm = normPoint(for: value.location, in: size, contentAspect: contentAspect) else {
            return
        }

        let activeWindow = presentedWindow
        showDirectCursor(at: norm, localMode: .drag, sharedMode: .drag)

        guard isInputReadyForWindow(activeWindow) else {
            requestFocusForPresentedWindow(reason: "armed mouse drag")
            return
        }

        if !mouseDragDidSendDown {
            let startNorm = normPoint(for: value.startLocation, in: size, contentAspect: contentAspect) ?? norm
            mouseDragStartNorm = startNorm
            mouseDragDidSendDown = true
            showDirectCursor(at: startNorm, localMode: .drag, sharedMode: .drag)
            runtimeSession.sendMouseDown(on: activeWindow,
                                  normX: Double(startNorm.x),
                                  normY: Double(startNorm.y),
                                  button: "left")
        }

        runtimeSession.sendMouseDrag(on: activeWindow,
                              normX: Double(norm.x),
                              normY: Double(norm.y),
                              button: "left")
    }

    private func handleArmedDirectDragEnded(_ value: DragGesture.Value, in size: CGSize, contentAspect: CGFloat) {
        let activeWindow = presentedWindow
        let endNorm = normPoint(for: value.location, in: size, contentAspect: contentAspect)
            ?? mouseDragStartNorm
            ?? tapCursorNorm
            ?? runtimeSession.currentSharedCursorNorm(for: activeWindow.windowId)

        if mouseDragDidSendDown {
            runtimeSession.sendMouseUp(on: activeWindow,
                                normX: Double(endNorm.x),
                                normY: Double(endNorm.y),
                                button: "left")
        }

        mouseDragDidSendDown = false
        mouseDragStartNorm = nil
        isMouseDragActive = false
        showDirectCursor(at: endNorm, localMode: .drag, sharedMode: .drag)
    }

    private func finishArmedDirectDragIfNeeded() {
        let activeWindow = presentedWindow
        let norm = tapCursorNorm ?? runtimeSession.currentSharedCursorNorm(for: activeWindow.windowId)

        if mouseDragDidSendDown {
            runtimeSession.sendMouseUp(on: activeWindow,
                                normX: Double(norm.x),
                                normY: Double(norm.y),
                                button: "left")
        }

        mouseDragDidSendDown = false
        mouseDragStartNorm = nil
        isMouseDragActive = false
        isDragModeArmed = false
        isDragModeTemporarilySuppressed = false
        showSharedCursor(at: norm, mode: .hover)
        endDirectCursorInteraction()
    }

    private func syncLocalInputModeFromSharedCursor(_ sharedCursor: PeelSharedCursorState?) {
        guard let sharedCursor,
              sharedCursor.isVisible,
              sharedCursor.windowId == presentedWindow.windowId else {
            return
        }

        // Shared cursor mode reflects the last input source. It may temporarily suppress
        // local drag input, but it must not mutate this window's own L/R click mode.
        // The L/R button remains a local peeled-window control and must continue to
        // respect rightClickModeStaysEnabled.
        switch sharedCursor.mode {
        case .drag:
            isDragModeTemporarilySuppressed = false

        case .rightClick, .hover, .click:
            releaseLocalMouseDownIfNeeded()
            isDragModeTemporarilySuppressed = true
        }
    }

    private func releaseLocalMouseDownIfNeeded() {
        guard mouseDragDidSendDown || isMouseDragActive || mouseDragStartNorm != nil else {
            return
        }

        let activeWindow = presentedWindow
        let norm = tapCursorNorm ?? runtimeSession.currentSharedCursorNorm(for: activeWindow.windowId)

        if mouseDragDidSendDown {
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
                        }
                    }

                    guard mouseDragDidSendDown else { return }

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
    /// Offers game controller input for this scene's presented window while it is the
    /// host's active window. Only a recent direct interaction here takes it from another
    /// scene; otherwise this fills an empty slot or follows a same-host window switch.
    /// A keyed window binds only to its own host's session, never the selected one.
    private func syncGameControllerInputOwner(preempt: Bool = false) {
        let window = presentedWindow
        let key = hostKey
        guard scenePhase == .active,
              !isOpeningImmersive,
              !scenes.isPeelImmersiveSpaceOpen,
              let session = PeelControllerSessionResolution.owningSession(
                  hostKeyRawValue: key?.rawValue,
                  exact: { key.flatMap { browser.session(for: $0) } },
                  selected: { browser.selectedSession }
              ),
              session.activeWindowId == window.windowId else {
            gameControllerInput.release(owner: gameControllerOwnerID)
            return
        }

        let recentlyUsedHere = session.lastUserInteractionWindowId == window.windowId
            && Date().timeIntervalSince(session.lastUserInteractionAt) < 1.0
        let coordinator = scenes
        let openingImmersive = $isOpeningImmersive
        let scene = currentScene
        gameControllerInput.offer(
            owner: gameControllerOwnerID,
            session: session,
            window: window,
            scene: scene,
            preempt: preempt || recentlyUsedHere,
            admission: { [weak coordinator, weak scene] in
                guard coordinator?.isPeelImmersiveSpaceOpen == false,
                      !openingImmersive.wrappedValue else { return false }
                // Before the scene resolves, the scenePhase guard above applies.
                return scene.map { $0.activationState == .foregroundActive } ?? true
            }
        )
    }

    private func requestFocusForPresentedWindow(reason: String) {
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
    
    private func schedulePassiveRootWindowCloseIfNeeded(expectedWindowId: UInt32) {
        guard passiveRootWindowCloseTask == nil else { return }

        passiveRootWindowCloseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            passiveRootWindowCloseTask = nil

            let liveWindowIds = Set(runtimeSession.windows.map(\.windowId))
            guard rootWindow.windowId == expectedWindowId,
                  !liveWindowIds.contains(expectedWindowId),
                  !isReturningToBrowser else {
                return
            }

            runtimeSession.forceMouseUpIfNeeded(reason: "peeled root window closed")

            for popup in popupWindowStack.reversed() {
                runtimeSession.endPullStream(for: popup)
                runtimeSession.clearAutoPopupTracking(for: popup.windowId)
            }
            popupWindowStack.removeAll()

            closeThisPeeledWindow()
        }
    }

    private func cancelPassiveRootWindowClose() {
        passiveRootWindowCloseTask?.cancel()
        passiveRootWindowCloseTask = nil
    }
    
    private func handleAutoPopupLifecycleIfNeeded() {
        if isReturningToBrowser {
            return
        }

        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            // iPhone uses fullScreenCover from ContentView, so let ContentView own the swap there.
            return
        }
        #endif

        let liveWindowIds = Set(runtimeSession.windows.map(\.windowId))
        let currentRoot = rootWindow
        if !liveWindowIds.contains(currentRoot.windowId) {
            guard !isReturningToBrowser else { return }

            if let successor = runtimeSession.consumePendingLauncherSuccessor(for: currentRoot.windowId) {
                cancelPassiveRootWindowClose()
                runtimeSession.forceMouseUpIfNeeded(reason: "launcher successor handoff")
                runtimeSession.setClientWindowActive(false, for: currentRoot)
                sendHostingMode(.inPlace, for: currentRoot)
                runtimeSession.endPullStream(for: currentRoot)
                rootWindowOverride = successor
                sendHostingMode(peeledWindowHostingMode, for: successor)
                runtimeSession.setClientWindowActive(scenePhase == .active, for: successor)
                runtimeSession.setActiveWindow(successor.windowId)
                runtimeSession.beginPullStream(for: successor)
                return
            }

            schedulePassiveRootWindowCloseIfNeeded(expectedWindowId: currentRoot.windowId)
            return
        }

        cancelPassiveRootWindowClose()

        let currentTop = presentedWindow

        if let popup = runtimeSession.consumeAutoPopupHandoff(from: currentTop.windowId) {
            runtimeSession.forceMouseUpIfNeeded(reason: "auto popup handoff")
            let popupMode: PeeledWindowHostingMode = peeledWindowHostingMode == .restorePreviousMacContext
                ? .restorePreviousMacContext
                : .inPlace
            sendHostingMode(popupMode, for: popup)
            runtimeSession.setClientWindowActive(scenePhase == .active, for: popup)
            runtimeSession.setActiveWindow(popup.windowId)
            popupWindowStack.append(popup)
            runtimeSession.beginPullStream(for: popup)
            return
        }

        while let top = popupWindowStack.last,
              !liveWindowIds.contains(top.windowId) {
            runtimeSession.setClientWindowActive(false, for: top)
            sendHostingMode(.inPlace, for: top)
            runtimeSession.endPullStream(for: top)
            runtimeSession.clearAutoPopupTracking(for: top.windowId)
            popupWindowStack.removeLast()
        }

        // Do not continuously reassert focus from passive window-list updates.
        // Focus should come from explicit user interaction or popup/root handoff only.
    }

    // MARK: - Streaming
    
    private func startStreaming() {
        runtimeSession.beginPullStream(for: rootWindow)
        for popup in popupWindowStack {
            runtimeSession.beginPullStream(for: popup)
        }
    }

    private func stopStreaming() {
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

private struct MacroHoldButton: View {
    let isEnabled: Bool
    let isPulsing: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if isEnabled {
                Button(action: action) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.blue)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassBackgroundEffect(in: Circle())
                .overlay {
                    Circle()
                        .stroke(Color.blue.opacity(isPulsing ? 0.95 : 0.55), lineWidth: isPulsing ? 2 : 1.25)
                        .scaleEffect(isPulsing ? 1.08 : 1.0)
                }
                .shadow(color: Color.blue.opacity(isPulsing ? 0.42 : 0.16), radius: isPulsing ? 12 : 5)
                .scaleEffect(isPulsing ? 1.06 : 1.0)
                .transition(.scale(scale: 0.82).combined(with: .opacity))
                .animation(.snappy(duration: 0.22, extraBounce: 0.18), value: isPulsing)
                .animation(.snappy(duration: 0.20, extraBounce: 0.10), value: isEnabled)
                .accessibilityLabel("Clear macro hold mode")
            }
        }
    }
}

private struct MacroHeldStatusView: View {
    let text: String
    let isRecording: Bool
    let isPulsing: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(isRecording ? "Held" : "Macro")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isRecording ? Color.blue : Color.secondary)

            Text(text.isEmpty ? "—" : text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(text.isEmpty ? Color.secondary : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(minWidth: 90, minHeight: 36, alignment: .leading)
        .padding(.horizontal, 12)
        .glassBackgroundEffect(in: Capsule())
        .overlay {
            Capsule()
                .stroke(isRecording ? Color.blue.opacity(isPulsing ? 0.95 : 0.55) : Color.clear, lineWidth: isPulsing ? 2.0 : 1.25)
                .scaleEffect(isPulsing ? 1.035 : 1.0)
                .opacity(isRecording ? 1 : 0)
        }
        .shadow(color: isRecording ? Color.blue.opacity(isPulsing ? 0.42 : 0.16) : Color.clear, radius: isPulsing ? 12 : 5)
        .animation(.easeOut(duration: 0.22), value: isPulsing)
        .animation(.easeOut(duration: 0.18), value: isRecording)
        .accessibilityLabel(text.isEmpty ? "No held macro keys" : "Held macro keys: \(text)")
    }
}

private struct MacroSaveButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassBackgroundEffect(in: Circle())
        .accessibilityLabel("Save macro")
    }
}

final class KeyboardBridge: NSObject, InvisibleTextInputDelegate {
    let onText: (String) -> Void
    let onBackspace: () -> Void
    let onEnter: () -> Void
    let onTab: () -> Void
    let onCommand: (KeyboardCommand) -> Void
    let onHardwareKey: (Int, String?, String?, [KeyboardCommand]) -> Void

    init(onText: @escaping (String) -> Void,
         onBackspace: @escaping () -> Void,
         onEnter: @escaping () -> Void,
         onTab: @escaping () -> Void,
         onCommand: @escaping (KeyboardCommand) -> Void,
         onHardwareKey: @escaping (Int, String?, String?, [KeyboardCommand]) -> Void) {
        self.onText = onText
        self.onBackspace = onBackspace
        self.onEnter = onEnter
        self.onTab = onTab
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

    func didPressTab() {
        onTab()
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

// MARK: - Hardware keyboard handling shared by the capture views

@discardableResult
private func handlePeelHardwareKey(_ key: UIKey, delegate: InvisibleTextInputDelegate?) -> Bool {
    let shortcutModifierFlags: UIKeyModifierFlags = [.command, .control, .alternate]
    let hasShortcutModifier = !key.modifierFlags.intersection(shortcutModifierFlags).isEmpty

    if hasShortcutModifier {
        delegate?.didPressKeyboardHardwareKey(
            keyCode: Int(key.keyCode.rawValue),
            characters: key.characters.isEmpty ? nil : key.characters,
            charactersIgnoringModifiers: key.charactersIgnoringModifiers.isEmpty ? nil : key.charactersIgnoringModifiers,
            modifiers: key.peelKeyboardCommandModifiers
        )
        return true
    }

    switch key.keyCode {
    case .keyboardDeleteOrBackspace:
        delegate?.didPressBackspace()
        return true
    case .keyboardReturnOrEnter:
        delegate?.didPressEnter()
        return true
    case .keyboardTab:
        delegate?.didPressTab()
        return true
    case .keyboardEscape:
        delegate?.didPressKeyboardCommand(.escape)
        return true
    case .keyboardLeftArrow:
        delegate?.didPressKeyboardCommand(.leftArrow)
        return true
    case .keyboardRightArrow:
        delegate?.didPressKeyboardCommand(.rightArrow)
        return true
    case .keyboardUpArrow:
        delegate?.didPressKeyboardCommand(.upArrow)
        return true
    case .keyboardDownArrow:
        delegate?.didPressKeyboardCommand(.downArrow)
        return true
    default:
        break
    }

    guard !key.characters.isEmpty else { return false }
    delegate?.didInsertText(key.characters)
    return true
}

private func shouldLetTextInputHandleHardwareKey(
    _ key: UIKey,
    hasMarkedText: Bool,
    primaryLanguage: String?
) -> Bool {
    let shortcutModifierFlags: UIKeyModifierFlags = [.command, .control, .alternate]

    // Command/control/option shortcuts should stay on the raw hardware-key path so
    // remote Mac shortcuts such as command-option-left arrow still work.
    if !key.modifierFlags.intersection(shortcutModifierFlags).isEmpty {
        return false
    }

    // During IME composition, the local text input system needs ownership of
    // printable keys plus enter/backspace/escape/arrows for candidate handling.
    if hasMarkedText {
        return true
    }

    switch key.keyCode {
    case .keyboardDeleteOrBackspace,
         .keyboardReturnOrEnter,
         .keyboardTab,
         .keyboardEscape,
         .keyboardLeftArrow,
         .keyboardRightArrow,
         .keyboardUpArrow,
         .keyboardDownArrow:
        return false
    default:
        break
    }

    guard !key.characters.isEmpty else { return false }
    return isCompositionalHardwareInputMode(primaryLanguage)
}

private func isCompositionalHardwareInputMode(_ primaryLanguage: String?) -> Bool {
    guard let primaryLanguage = primaryLanguage?.lowercased(), !primaryLanguage.isEmpty else {
        return false
    }

    // These input modes commonly need marked-text composition before committed
    // Unicode text exists. For non-compositional layouts, keep the existing
    // immediate raw-character forwarding path.
    return primaryLanguage.hasPrefix("zh") ||
        primaryLanguage.hasPrefix("ja") ||
        primaryLanguage.hasPrefix("ko") ||
        primaryLanguage.hasPrefix("yue") ||
        primaryLanguage.hasPrefix("vi")
}

private extension UIKey {
    var peelKeyboardCommandModifiers: [KeyboardCommand] {
        var result: [KeyboardCommand] = []

        if modifierFlags.contains(.command) {
            result.append(.command)
        }

        if modifierFlags.contains(.shift) {
            result.append(.shift)
        }

        if modifierFlags.contains(.alternate) {
            result.append(.option)
        }

        if modifierFlags.contains(.control) {
            result.append(.control)
        }

        if modifierFlags.contains(.alphaShift), !result.contains(.shift) {
            result.append(.shift)
        }

        return result
    }
}

private struct EnterBackspaceKeysOverlay: View {
    let onEnter: () -> Void
    let onBackspace: () -> Void

    var body: some View {
        VStack(spacing: KeyboardMacroOrnamentMetrics.spacing) {
            KeyboardMacroOrnamentButton(accessibilityLabel: "Backspace") {
                onBackspace()
            } label: {
                Image(systemName: "delete.left")
                    .font(.system(size: 17, weight: .semibold))
            }

            KeyboardMacroOrnamentButton(accessibilityLabel: "Enter") {
                onEnter()
            } label: {
                Image(systemName: "return")
                    .font(.system(size: 17, weight: .semibold))
            }
        }
    }
}

// MARK: - Hardware keyboard capture without showing the software keyboard

private struct HardwareKeyboardCaptureView: UIViewRepresentable {
    let isActive: Bool
    let delegate: InvisibleTextInputDelegate

    func makeUIView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.backgroundColor = .clear
        view.isOpaque = false
        // Must be interactive enough to become first responder. SwiftUI keeps this
        // view out of hit-testing, so it will not steal taps from the peeled window.
        view.isUserInteractionEnabled = true
        view.keyDelegate = delegate
        view.isCaptureActive = isActive

        DispatchQueue.main.async { [weak view] in
            view?.refreshFirstResponderState()
        }

        return view
    }

    func updateUIView(_ uiView: CaptureView, context: Context) {
        uiView.keyDelegate = delegate
        uiView.isCaptureActive = isActive

        DispatchQueue.main.async { [weak uiView] in
            uiView?.refreshFirstResponderState()
        }
    }

    final class CaptureView: UIView {
        weak var keyDelegate: InvisibleTextInputDelegate?
        var isCaptureActive: Bool = false

        override var canBecomeFirstResponder: Bool { true }

        func refreshFirstResponderState() {
            guard window != nil else { return }

            if isCaptureActive {
                if !isFirstResponder {
                    _ = becomeFirstResponder()
                }
            } else if isFirstResponder {
                resignFirstResponder()
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()

            DispatchQueue.main.async { [weak self] in
                self?.refreshFirstResponderState()
            }
        }

        override func resignFirstResponder() -> Bool {
            let didResign = super.resignFirstResponder()

            if didResign, isCaptureActive {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCaptureActive else { return }
                    self.refreshFirstResponderState()
                }
            }

            return didResign
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var unhandled = Set<UIPress>()

            for press in presses {
                guard let key = press.key,
                      handlePeelHardwareKey(key, delegate: keyDelegate) else {
                    unhandled.insert(press)
                    continue
                }
            }

            if !unhandled.isEmpty {
                super.pressesBegan(unhandled, with: event)
            }
        }
    }
}

// MARK: - Software keyboard / dictation capture

private struct KeyCaptureTextView: UIViewRepresentable {
    @Binding var isFocused: Bool
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
        uiView.applyFocus(isFocused, force: isExplicitFocusRequest)
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
        private var lastObservedText = ""
        private var pendingComposedText = ""
        private var compositionFlushTask: Task<Void, Never>?
        private var isProgrammaticTextChange = false
        private var isDictationActive = false
        private var dictationBaseText = ""
        private var pendingDictationText = ""
        private var dictationFinalFlushTask: Task<Void, Never>?
        private var recentEmittedTextSamples: [(text: String, time: CFTimeInterval)] = []
        private var lastComposedTextFlushAt: CFTimeInterval = 0
        private let compositionFlushDelayNanoseconds: UInt64 = 450_000_000
        private let dictationFinalFlushDelayNanoseconds: UInt64 = 700_000_000
        private let dictationFinalDuplicateWindow: CFTimeInterval = 120

        override var canBecomeFirstResponder: Bool { true }

        func applyFocus(_ shouldFocus: Bool, force: Bool) {
            if !shouldFocus {
                focusRequestGeneration += 1
                let generation = focusRequestGeneration
                cancelFocusRetries()

                DispatchQueue.main.async { [weak self] in
                    guard let self, self.focusRequestGeneration == generation else { return }

                    if self.isFirstResponder {
                        self.resignFirstResponder()
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
                guard let self, self.focusRequestGeneration == generation else { return }

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
                      self.window != nil,
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

            return didBecome
        }

        override func insertText(_ text: String) {
            if isMacroHoldModeEnabled {
                flushPendingComposedText()
                if text == "\n" || text == "\r" {
                    keyDelegate?.didPressEnter()
                } else if text == "\t" {
                    keyDelegate?.didPressTab()
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

        override func dictationRecordingDidEnd() {
            super.dictationRecordingDidEnd()
        }

        override func dictationRecognitionFailed() {
            super.dictationRecognitionFailed()
            resetDictationCapture()
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var unhandled = Set<UIPress>()
            let hasMarkedText = markedTextRange != nil
            let primaryLanguage = textInputMode?.primaryLanguage

            for press in presses {
                guard let key = press.key else {
                    unhandled.insert(press)
                    continue
                }

                if shouldLetTextInputHandleHardwareKey(
                    key,
                    hasMarkedText: hasMarkedText,
                    primaryLanguage: primaryLanguage
                ) {
                    unhandled.insert(press)
                    continue
                }

                guard handlePeelHardwareKey(key, delegate: keyDelegate) else {
                    unhandled.insert(press)
                    continue
                }
            }

            if !unhandled.isEmpty {
                super.pressesBegan(unhandled, with: event)
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isProgrammaticTextChange else { return }

            if isMacroHoldModeEnabled {
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
            pendingComposedText += insertedText
            scheduleComposedTextFlush()
        }

        override func resignFirstResponder() -> Bool {
            let wasFirstResponder = isFirstResponder

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
            dictationFinalFlushTask?.cancel()
        }

        func resetCapturedTextStorage() {
            compositionFlushTask?.cancel()
            compositionFlushTask = nil
            dictationFinalFlushTask?.cancel()
            dictationFinalFlushTask = nil
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
            dictationFinalFlushTask?.cancel()
            dictationFinalFlushTask = nil
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

        private func scheduleDictationFinalFallbackFlush() {
            guard isDictationActive else { return }

            dictationFinalFlushTask?.cancel()
            dictationFinalFlushTask = Task { [weak self] in
                guard let self else { return }

                try? await Task.sleep(nanoseconds: dictationFinalFlushDelayNanoseconds)
                guard !Task.isCancelled else { return }

                await MainActor.run { [weak self] in
                    guard let self, self.isDictationActive else { return }
                    self.commitDictationText(self.pendingDictationText)
                }
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

            // Dictation on visionOS can first resolve through textViewDidChange,
            // then later fire insertDictationResult when the system tears down
            // dictation. If we already flushed text, the final callback is a
            // duplicate/cleanup signal, not a second send path.
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
            dictationFinalFlushTask?.cancel()
            dictationFinalFlushTask = nil
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

            guard !pendingComposedText.isEmpty else { return }
            lastComposedTextFlushAt = CACurrentMediaTime()
            emitTextToHost(pendingComposedText)
            pendingComposedText = ""
        }
    }
}

// MARK: - Indirect pointer capture (trackpad + mouse)

private struct IndirectPointerCapture: UIViewRepresentable {
    var targetWindowId: UInt32
    var isActive: Bool
    var onEvent: (IndirectPointerEvent) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEvent: onEvent)
    }

    func makeUIView(context: Context) -> PointerCaptureView {
        let v = PointerCaptureView(frame: .zero)
        v.backgroundColor = .clear
        v.isOpaque = false
        v.isUserInteractionEnabled = true

        if #available(iOS 13.4, visionOS 1.0, *) {
            let hover = UIHoverGestureRecognizer(target: context.coordinator,
                                                 action: #selector(Coordinator.handleHover(_:)))
            hover.delegate = context.coordinator
            v.addGestureRecognizer(hover)
        }

        let primaryTap = UITapGestureRecognizer(target: context.coordinator,
                                                action: #selector(Coordinator.handlePrimaryTap(_:)))
        primaryTap.delegate = context.coordinator
        primaryTap.cancelsTouchesInView = false
        if #available(iOS 13.4, visionOS 1.0, *) {
            primaryTap.buttonMaskRequired = .primary
        }
        v.addGestureRecognizer(primaryTap)
        context.coordinator.primaryTapRecognizer = primaryTap

        let secondaryTap = UITapGestureRecognizer(target: context.coordinator,
                                                  action: #selector(Coordinator.handleSecondaryTap(_:)))
        secondaryTap.delegate = context.coordinator
        secondaryTap.cancelsTouchesInView = false
        if #available(iOS 13.4, visionOS 1.0, *) {
            secondaryTap.buttonMaskRequired = .secondary
        }
        v.addGestureRecognizer(secondaryTap)
        context.coordinator.secondaryTapRecognizer = secondaryTap

        let pointerDrag = UIPanGestureRecognizer(target: context.coordinator,
                                                 action: #selector(Coordinator.handlePointerDrag(_:)))
        pointerDrag.delegate = context.coordinator
        pointerDrag.cancelsTouchesInView = false
        if #available(iOS 13.4, visionOS 1.0, *) {
            pointerDrag.allowedTouchTypes = [
                NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
            ]
        }
        v.addGestureRecognizer(pointerDrag)
        context.coordinator.pointerDragRecognizer = pointerDrag

        let scroll = UIPanGestureRecognizer(target: context.coordinator,
                                            action: #selector(Coordinator.handleScroll(_:)))
        scroll.delegate = context.coordinator
        scroll.cancelsTouchesInView = false
        scroll.minimumNumberOfTouches = 0
        scroll.maximumNumberOfTouches = 0
        if #available(iOS 13.4, visionOS 1.0, *) {
            scroll.allowedScrollTypesMask = [.all]
        }
        v.addGestureRecognizer(scroll)
        context.coordinator.scrollRecognizer = scroll

        context.coordinator.view = v
        context.coordinator.updateTarget(windowId: targetWindowId, isActive: isActive, onEvent: onEvent)
        return v
    }

    func updateUIView(_ uiView: PointerCaptureView, context: Context) {
        context.coordinator.updateTarget(windowId: targetWindowId, isActive: isActive, onEvent: onEvent)
    }

    static func dismantleUIView(_ uiView: PointerCaptureView, coordinator: Coordinator) {
        coordinator.invalidate()
    }

    final class PointerCaptureView: UIView {
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            guard super.point(inside: point, with: event) else { return false }
            guard let event else { return false }

            if #available(iOS 13.4, visionOS 1.0, *) {
                if event.type == .hover || event.type == .scroll {
                    return true
                }
            }

            guard event.type == .touches else {
                return false
            }

            if #available(iOS 13.4, visionOS 1.0, *) {
                // In modern indirect-input mode the touch type is .indirectPointer.
                // In compatibility mode, pointing-device clicks can still be
                // identified by a non-empty button mask. Finger/hand touches have
                // no button mask and pass through to SwiftUI.
                if !event.buttonMask.isEmpty {
                    return true
                }

                return event.allTouches?.contains(where: { $0.type == .indirectPointer }) == true
            }

            return false
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onEvent: (IndirectPointerEvent) -> Void
        weak var view: UIView?

        private var isActive = true
        private var targetWindowId: UInt32?
        private var scrollGestureActive = false
        private var displayLink: CADisplayLink?
        private var inertialVelocity: CGPoint = .zero
        private var lastTick: CFTimeInterval = 0
        private var lastScrollLocation: CGPoint? = nil
        private var activeDragLocation: CGPoint?

        weak var primaryTapRecognizer: UIGestureRecognizer?
        weak var secondaryTapRecognizer: UIGestureRecognizer?
        weak var pointerDragRecognizer: UIGestureRecognizer?
        weak var scrollRecognizer: UIGestureRecognizer?

        private let decelRate: CGFloat = UIScrollView.DecelerationRate.normal.rawValue
        private let stopVelocityThreshold: CGFloat = 12

        init(onEvent: @escaping (IndirectPointerEvent) -> Void) {
            self.onEvent = onEvent
        }

        deinit {
            stopInertia()
        }

        func updateTarget(windowId: UInt32, isActive: Bool, onEvent: @escaping (IndirectPointerEvent) -> Void) {
            if targetWindowId != windowId {
                // Cancel using the previous target's callback before replacing it.
                setActive(false)
                targetWindowId = windowId
            }
            self.onEvent = onEvent
            setActive(isActive)
        }

        func setActive(_ active: Bool) {
            isActive = active
            guard !active else { return }
            scrollGestureActive = false
            stopInertia()
            lastScrollLocation = nil
            if activeDragLocation != nil {
                activeDragLocation = nil
                onEvent(.dragCancelled)
            }
        }

        func invalidate() {
            setActive(false)
            onEvent = { _ in }
            view = nil
        }

        @available(iOS 13.4, visionOS 1.0, *)
        @objc func handleHover(_ gr: UIHoverGestureRecognizer) {
            guard isActive, let view else { return }

            switch gr.state {
            case .began, .changed:
                onEvent(.hover(location: gr.location(in: view)))
            case .ended, .cancelled, .failed:
                onEvent(.hoverEnded)
            default:
                break
            }
        }

        @objc func handlePrimaryTap(_ gr: UITapGestureRecognizer) {
            guard isActive, gr.state == .ended, let view else { return }
            onEvent(.primaryClick(location: gr.location(in: view)))
        }

        @objc func handleSecondaryTap(_ gr: UITapGestureRecognizer) {
            guard isActive, gr.state == .ended, let view else { return }
            onEvent(.secondaryClick(location: gr.location(in: view)))
        }

        @objc func handlePointerDrag(_ gr: UIPanGestureRecognizer) {
            guard isActive, let view else { return }
            let location = gr.location(in: view)

            switch gr.state {
            case .began:
                stopInertia()
                activeDragLocation = location
                onEvent(.dragBegan(location: location))
            case .changed:
                guard activeDragLocation != nil else { return }
                activeDragLocation = location
                onEvent(.dragChanged(location: location))
            case .ended:
                guard activeDragLocation != nil else { return }
                activeDragLocation = nil
                onEvent(.dragEnded(location: location))
            case .cancelled, .failed:
                guard activeDragLocation != nil else { return }
                activeDragLocation = nil
                onEvent(.dragCancelled)
            default:
                break
            }
        }

        @objc func handleScroll(_ gr: UIPanGestureRecognizer) {
            guard isActive, let view else { return }

            switch gr.state {
            case .began:
                scrollGestureActive = true
                stopInertia()

            case .changed:
                guard scrollGestureActive else { return }
                let t = gr.translation(in: view)
                gr.setTranslation(.zero, in: view)

                if abs(t.x) < 0.5 && abs(t.y) < 0.5 { return }
                let location = gr.location(in: view)
                lastScrollLocation = location
                onEvent(.scroll(location: location, deltaX: t.x, deltaY: t.y))

            case .ended:
                guard scrollGestureActive else { return }
                scrollGestureActive = false
                startInertia(with: gr.velocity(in: view))

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

            let dx = inertialVelocity.x * dt
            let dy = inertialVelocity.y * dt

            if abs(dx) > 0.01 || abs(dy) > 0.01 {
                let location = lastScrollLocation ?? CGPoint(x: view?.bounds.midX ?? 0, y: view?.bounds.midY ?? 0)
                onEvent(.scroll(location: location, deltaX: dx, deltaY: dy))
            }

            let decay = pow(decelRate, dt * 60.0)
            inertialVelocity.x *= decay
            inertialVelocity.y *= decay

            if abs(inertialVelocity.x) < stopVelocityThreshold && abs(inertialVelocity.y) < stopVelocityThreshold {
                stopInertia()
            }
        }

        @available(iOS 13.4, visionOS 1.0, *)
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldReceive event: UIEvent) -> Bool {
            if let scrollRecognizer = scrollRecognizer,
               gestureRecognizer === scrollRecognizer {
                return event.type == .scroll
            }

            if let primaryTapRecognizer = primaryTapRecognizer,
               gestureRecognizer === primaryTapRecognizer {
                guard event.type != .scroll, event.type != .hover else { return false }
                return event.buttonMask == .primary
            }

            if let secondaryTapRecognizer = secondaryTapRecognizer,
               gestureRecognizer === secondaryTapRecognizer {
                guard event.type != .scroll, event.type != .hover else { return false }
                return event.buttonMask == .secondary
            }

            if let pointerDragRecognizer = pointerDragRecognizer,
               gestureRecognizer === pointerDragRecognizer {
                guard event.type != .scroll, event.type != .hover else { return false }
                return event.buttonMask == .primary
            }

            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            if #available(iOS 13.4, visionOS 1.0, *) {
                return touch.type == .indirectPointer
            }

            return false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
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
        let v = ScrollCaptureView(frame: .zero)
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = true

        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = context.coordinator
        pan.cancelsTouchesInView = false

        // Key bit: allow indirect scrolling (trackpad + mouse wheel)
        if #available(iOS 13.4, visionOS 1.0, *) {
            pan.allowedScrollTypesMask = [.all]
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

    final class ScrollCaptureView: UIView {
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            guard super.point(inside: point, with: event) else { return false }

            if #available(iOS 13.4, visionOS 1.0, *) {
                return event?.type == .scroll
            }

            return false
        }
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

        @available(iOS 13.4, visionOS 1.0, *)
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldReceive event: UIEvent) -> Bool {
            event.type == .scroll
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            false
        }
    }
}
