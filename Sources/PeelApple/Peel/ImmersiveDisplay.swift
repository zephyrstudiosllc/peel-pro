//
//  PeeledImmersiveSurface.swift
//  Peel
//
//  Created by Zach on 5/25/26.
//


//
//  PeeledImmersiveSurface.swift
//  Peel
//
//  A small fork of PeeledWindowView's stream/input surface for use as a RealityView attachment.
//  Keep this additive until the immersive path proves itself, then extract shared surface code later.
//

import SwiftUI
import UIKit
import QuartzCore

struct PeeledImmersiveSurface: View {
    @EnvironmentObject private var browser: PeelClientBrowser
    @EnvironmentObject private var scenes: SceneCoordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace


    let hostedWindow: HostedPeelWindow
    @ObservedObject var session: PeelHostSession
    let isPrimary: Bool

    private var window: PeelWindow { hostedWindow.window }
    let homeButtonCorner: PeelImmersiveHomeButtonCorner
    @Binding var surfaceScale: CGFloat
    @Binding var layoutMode: PeelImmersiveLayoutMode
    @Binding var hudX: Float
    @Binding var hudY: Float
    @Binding var hudScale: Float
    let onMakePrimary: () -> Void
    let onClose: () -> Void

    @State private var tapCursorNorm: CGPoint? = nil
    @State private var tapCursorHideWorkItem: DispatchWorkItem? = nil

    @State private var zoomScale: CGFloat = 1.0
    @State private var baseZoomScale: CGFloat = 1.0
    @State private var contentOffset: CGSize = .zero
    @State private var baseContentOffset: CGSize = .zero
    @State private var lastTranslation: CGSize = .zero

    @FocusState private var keyboardFocused: Bool
    @State private var keyboardEnabled: Bool = false
    @State private var isFocusedBridge: Bool = false

    @State private var dragStartTime: Date?
    @State private var dragStartLocation: CGPoint?
    @State private var isMouseDragActive: Bool = false
    @State private var mouseDragDidSendDown: Bool = false
    @State private var mouseDragStartNorm: CGPoint? = nil
    @State private var lastFocusRequestAt: Date? = nil
    @State private var dragBaseHudX: Float = 0
    @State private var dragBaseHudY: Float = 0

    private let maxZoomScale: CGFloat = 4.0
    private let tapCursorSize: CGFloat = 26
    private let clickThreshold: CGFloat = 8
    private let longPressDuration: TimeInterval = 0.5
    private let longPressMovementThreshold: CGFloat = 12
    private let mouseDragHoldDuration: TimeInterval = 0.12
    private let mouseDragBeginDistance: CGFloat = 6
    private let focusRequestMinInterval: TimeInterval = 0.35
    private let clickCalibrationOffset = CGSize(width: 0, height: 0)
    private let showImmersiveSurfaceControls = false

    var body: some View {
        let keyboardBridge = KeyboardBridge(
            onText: { text in session.sendKeyboardText(text) },
            onBackspace: { session.sendKeyboardText("\u{8}") },
            onEnter: { session.sendKeyboardText("\n") },
            onTab: { session.sendKeyboardText("\t") },
            onCommand: { command in session.sendKeyboardCommand(command) },
            onHardwareKey: { key, characters, modifiers, commands in
                session.sendHardwareKey(
                    key,
                    characters: characters,
                    modifiers: modifiers,
                    commands: commands
                )
            }
        )

        ZStack {
            if showImmersiveSurfaceControls {
                VStack(spacing: 0) {
                    immersiveWindowBar
                    streamSurface
                }
            } else {
                streamSurface
            }

            ImmersiveKeyCaptureTextView(isFocused: $isFocusedBridge, delegate: keyboardBridge)
                .frame(width: 1, height: 1)
                .opacity(0.0)
                .allowsHitTesting(false)
        }
        .background(Color.clear)
        .overlay(alignment: homeButtonAlignment) {
            HStack(spacing: 10) {
                if homeButtonCorner.isTrailing {
                    closeImmersiveButton
                    peelHomeButton
                } else {
                    peelHomeButton
                    closeImmersiveButton
                }
            }
            .scaleEffect(homeButtonCompensatingScale)
            .padding(12)
        }
        .overlay(alignment: .topLeading) {
            if showImmersiveSurfaceControls && !isPrimary {
                Button {
                    onMakePrimary()
                } label: {
                    Label("Focus", systemImage: "scope")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .padding(14)
            }
        }
        .overlay(alignment: .trailing) {
            if showImmersiveSurfaceControls {
                VStack(spacing: 8) {
                    Button {
                        hudY = min(0.36, hudY + 0.04)
                    } label: {
                        Image(systemName: "chevron.up")
                    }

                    Button {
                        hudX = min(0.56, hudX + 0.04)
                    } label: {
                        Image(systemName: "chevron.right")
                    }

                    Button {
                        hudY = max(-0.28, hudY - 0.04)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
                .glassBackgroundEffect(in: Capsule())
                .padding(.trailing, 14)
            }
        }
        .overlay(alignment: .leading) {
            if showImmersiveSurfaceControls {
                VStack(spacing: 8) {
                    Button {
                        hudX = max(-0.56, hudX - 0.04)
                    } label: {
                        Image(systemName: "chevron.left")
                    }

                    Button {
                        hudScale = min(1.16, hudScale + 0.06)
                        surfaceScale = min(1.42, surfaceScale + 0.04)
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }

                    Button {
                        hudScale = max(0.42, hudScale - 0.06)
                        surfaceScale = max(0.72, surfaceScale - 0.04)
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
                .glassBackgroundEffect(in: Capsule())
                .padding(.leading, 14)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if showImmersiveSurfaceControls {
                HStack(spacing: 8) {
                    Button {
                        keyboardEnabled.toggle()
                        keyboardFocused = keyboardEnabled
                        isFocusedBridge = keyboardEnabled
                        if keyboardEnabled {
                            requestFocusForWindow(reason: "immersive keyboard")
                        }
                    } label: {
                        Image(systemName: keyboardEnabled ? "keyboard.chevron.compact.down" : "keyboard")
                    }

                    Button {
                        switch layoutMode {
                        case .hud:
                            layoutMode = .focus
                        case .focus:
                            layoutMode = .field
                        case .field:
                            layoutMode = .hud
                        }
                    } label: {
                        Image(systemName: layoutMode.systemImage)
                    }
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .glassBackgroundEffect(in: Capsule())
                .padding(14)
            }
        }
        .onAppear {
            session.beginPullStream(for: window)

            if scenes.peelImmersiveLaunchContext == .hudEnvironment {
                session.activeSpatialWindowIds.insert(window.windowId)

                if let config = session.latestVideoConfigByWindow[window.windowId] {
                    session.spatialVideoRenderer(for: window.windowId).applyConfig(config)
                }
            }

            if session.activeWindowId == nil || isPrimary {
                session.setActiveWindow(window.windowId)
            }
            isFocusedBridge = keyboardEnabled
        }
        .onDisappear {
            session.deactivateSpatialVideoRenderer(for: window.windowId)

            if session.activeWindowId == window.windowId {
                session.forceMouseUpIfNeeded(reason: "immersive surface disappeared")
            }
        }
        .onChange(of: keyboardFocused) { _, newValue in
            if isFocusedBridge != newValue { isFocusedBridge = newValue }
        }
        .onChange(of: isFocusedBridge) { _, newValue in
            if keyboardFocused != newValue { keyboardFocused = newValue }
        }
        .onChange(of: isPrimary) { _, newValue in
            if newValue {
                session.setActiveWindow(window.windowId)
            }
        }
    }


    private var homeButtonAlignment: Alignment {
        switch homeButtonCorner {
        case .topLeading:
            return .topLeading
        case .bottomLeading:
            return .bottomLeading
        case .bottomTrailing:
            return .bottomTrailing
        case .topTrailing:
            return .topTrailing
        }
    }

    private var peelHomeButton: some View {
        Button {
            returnToPeelHome()
        } label: {
            Image("PeelHostMenuBarIcon_128x128")
                .resizable()
                .scaledToFit()
                .frame(width: 27, height: 27)
                .frame(width: 45, height: 45)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassBackgroundEffect(in: Circle())
        .accessibilityLabel("Return to Peel Pro")
    }

    private var closeImmersiveButton: some View {
        Button(role: .destructive) {
            Task {
                await dismissImmersiveSpace()
            }
        } label: {
            Image(systemName: "xmark")
                .font(.caption.bold())
                .frame(width: 45, height: 45)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.red)
        .glassBackgroundEffect(in: Circle())
        .accessibilityLabel("Close Field")
    }

    private var homeButtonCompensatingScale: CGFloat {
        let scale = max(0.01, CGFloat(scenes.immersiveFieldScale))
        guard scale > 1.0 else { return 1.0 }
        return 1.0 / scale
    }

    private func returnToPeelHome() {
        session.forceMouseUpIfNeeded(reason: "opening Peel home from immersive display")

        if scenes.activateMainIfPossible() == false, scenes.canRequestMainSceneRestore() {
            scenes.markMainSceneOpenRequested()
            openWindow(id: "main")
        }
    }

    private var streamSurface: some View {
        GeometryReader { geo in
            let videoSize = session.videoContentSize(for: window.windowId)
            let contentAspect = resolvedContentAspect(videoSize: videoSize, cgImage: nil)
            let viewport = viewportTransform(in: geo.size, contentAspect: contentAspect)

            ZStack {
                SpatialCompressedVideoView(
                    renderer: session.spatialVideoRenderer(for: window.windowId)
                )
                .background(Color.black)
                .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 32, style: .continuous))
                .scaleEffect(zoomScale)
                .offset(contentOffset)
                .allowsHitTesting(false)

                Color.clear
                    .contentShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                    .overlay(scrollCaptureOverlay(size: geo.size, contentAspect: contentAspect))
                    .gesture(primaryTouchGesture(viewport: viewport, size: geo.size, contentAspect: contentAspect))
                    .simultaneousGesture(magnificationGesture(size: geo.size, contentAspect: contentAspect))
                    .simultaneousGesture(mouseDragGesture(in: geo.size, contentAspect: contentAspect))

                if session.showInputRejectionBanner, let rejection = session.lastInputRejection {
                    VStack {
                        Text(userFacingInputRejectionMessage(for: rejection))
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.top, 14)
                        Spacer()
                    }
                    .transition(.opacity)
                    .allowsHitTesting(false)
                }

                if let norm = tapCursorNorm {
                    tapCursorIndicator
                        .position(viewPoint(fromNorm: norm, in: geo.size, contentAspect: contentAspect))
                        .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        }
    }

    private func renderedVideo(
        _ videoRenderer: CompressedVideoRenderer,
        renderRect: CGRect,
        viewport: ClientViewportTransform,
        size: CGSize,
        contentAspect: CGFloat
    ) -> some View {
        CompressedVideoLayerView(renderer: videoRenderer)
            .frame(width: renderRect.width, height: renderRect.height, alignment: .center)
            .scaleEffect(zoomScale)
            .offset(contentOffset)
            .position(x: renderRect.midX, y: renderRect.midY)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(scrollCaptureOverlay(size: size, contentAspect: contentAspect))
            .gesture(primaryTouchGesture(viewport: viewport, size: size, contentAspect: contentAspect))
            .simultaneousGesture(magnificationGesture(size: size, contentAspect: contentAspect))
            .simultaneousGesture(mouseDragGesture(in: size, contentAspect: contentAspect))
    }

    private func renderedSnapshot(
        _ cgImage: CGImage,
        renderRect: CGRect,
        viewport: ClientViewportTransform,
        size: CGSize,
        contentAspect: CGFloat
    ) -> some View {
        Image(decorative: cgImage, scale: 1.0, orientation: .up)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentAspect, contentMode: .fit)
            .frame(width: renderRect.width, height: renderRect.height, alignment: .center)
            .scaleEffect(zoomScale)
            .offset(contentOffset)
            .drawingGroup()
            .position(x: renderRect.midX, y: renderRect.midY)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(scrollCaptureOverlay(size: size, contentAspect: contentAspect))
            .gesture(primaryTouchGesture(viewport: viewport, size: size, contentAspect: contentAspect))
            .simultaneousGesture(magnificationGesture(size: size, contentAspect: contentAspect))
            .simultaneousGesture(mouseDragGesture(in: size, contentAspect: contentAspect))
    }

    private var loadingView: some View {
        PeelLoadingView(
            header: session.isConnectionReady ? "Opening \(openingAppName(for: window))" : "Connection lost",
            subhead: session.isConnectionReady ? "" : "Return to Peel Pro and reconnect to your computer.",
            delayedHeader: session.isConnectionReady ? "Still waiting for \(openingAppName(for: window))" : nil,
            delayedSubhead: session.isConnectionReady ? "Close Field and try opening it again from Peel Pro." : nil,
            variant: session.isConnectionReady ? .streaming : .connecting
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scrollCaptureOverlay(size: CGSize, contentAspect: CGFloat) -> some View {
        Group {
            if session.activeWindowId == window.windowId {
                ImmersiveIndirectScrollCapture { dx, dy in
                    if zoomScale > 1.0001 {
                        let proposed = CGSize(width: contentOffset.width + dx, height: contentOffset.height + dy)
                        let transform = viewportTransform(in: size, contentAspect: contentAspect, contentOffset: proposed)
                        let clamped = transform.clampedOffset(proposed)
                        contentOffset = clamped
                        baseContentOffset = clamped
                    } else {
                        session.sendScroll(on: window, deltaX: dx, deltaY: dy)
                    }
                }
            }
        }
    }

    private func primaryTouchGesture(
        viewport: ClientViewportTransform,
        size: CGSize,
        contentAspect: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if let norm = viewport.normalizedPoint(for: value.location) {
                    tapCursorNorm = norm
                }

                tapCursorHideWorkItem?.cancel()

                if dragStartTime == nil {
                    dragStartTime = Date()
                    dragStartLocation = value.startLocation
                    requestFocusForWindow(reason: "immersive touch began")
                }

                if zoomScale > 1.0001 {
                    contentOffset = viewport.pannedOffset(from: baseContentOffset, translation: value.translation)
                    lastTranslation = .zero
                    return
                }

                let dy = value.translation.height - lastTranslation.height
                let dx = value.translation.width - lastTranslation.width
                lastTranslation = value.translation

                if !isMouseDragActive, abs(dy) > 0.5 {
                    guard isInputReadyForWindow() else {
                        requestFocusForWindow(reason: "immersive drag scroll")
                        return
                    }
                    session.sendScroll(on: window, deltaX: dx, deltaY: dy)
                }
            }
            .onEnded { value in
                let endTime = Date()
                let duration = endTime.timeIntervalSince(dragStartTime ?? endTime)
                let totalDelta = hypot(value.translation.width, value.translation.height)
                let startLoc = dragStartLocation ?? value.location
                let dx = value.location.x - startLoc.x
                let dy = value.location.y - startLoc.y
                let startToEndDistance = hypot(dx, dy)

                if zoomScale > 1.0001 {
                    contentOffset = viewport.clampedOffset(contentOffset)
                    baseContentOffset = contentOffset
                }

                if isMouseDragActive || mouseDragDidSendDown {
                    resetDragState()
                    return
                }

                if duration >= longPressDuration && startToEndDistance < longPressMovementThreshold {
                    sendClick(at: startLoc, in: size, contentAspect: contentAspect, button: "right")
                } else if totalDelta < clickThreshold {
                    sendClick(at: value.location, in: size, contentAspect: contentAspect, button: "left")
                }

                resetDragState()
            }
    }

    private func magnificationGesture(size: CGSize, contentAspect: CGFloat) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let newScale = min(max(baseZoomScale * value, 1.0), maxZoomScale)
                zoomScale = newScale
                let transform = viewportTransform(in: size, contentAspect: contentAspect, zoomScale: newScale)
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
                    let transform = viewportTransform(in: size, contentAspect: contentAspect, zoomScale: finalScale)
                    let clamped = transform.clampedOffset(contentOffset)
                    contentOffset = clamped
                    baseContentOffset = clamped
                }
            }
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

                    guard isInputReadyForWindow() else {
                        requestFocusForWindow(reason: "immersive mouse drag")
                        return
                    }

                    if !mouseDragDidSendDown {
                        if let startNorm = normPoint(for: drag.startLocation, in: size, contentAspect: contentAspect) {
                            mouseDragStartNorm = startNorm
                            mouseDragDidSendDown = true
                            session.sendMouseDown(on: window,
                                                  normX: Double(startNorm.x),
                                                  normY: Double(startNorm.y),
                                                  button: "left")
                        }
                    }

                    guard mouseDragDidSendDown else { return }

                    if let curNorm = normPoint(for: drag.location, in: size, contentAspect: contentAspect) {
                        tapCursorNorm = curNorm
                        session.sendMouseDrag(on: window,
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

                if let endNorm = normPoint(for: drag.location, in: size, contentAspect: contentAspect) {
                    session.sendMouseUp(on: window,
                                        normX: Double(endNorm.x),
                                        normY: Double(endNorm.y),
                                        button: "left")
                } else if let startNorm = mouseDragStartNorm {
                    session.sendMouseUp(on: window,
                                        normX: Double(startNorm.x),
                                        normY: Double(startNorm.y),
                                        button: "left")
                }
            }
    }

    private func sendClick(at location: CGPoint, in size: CGSize, contentAspect: CGFloat, button: String = "left") {
        guard let norm = normPoint(for: location, in: size, contentAspect: contentAspect) else { return }

        if !isInputReadyForWindow() {
            requestFocusForWindow(reason: "immersive click")
            return
        }

        tapCursorNorm = norm
        tapCursorHideWorkItem?.cancel()
        let work = DispatchWorkItem { tapCursorNorm = nil }
        tapCursorHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)

        session.sendClick(on: window, normX: Double(norm.x), normY: Double(norm.y), button: button)
    }

    private func requestFocusForWindow(reason: String) {
        let now = Date()
        let isLocallyActive = session.activeWindowId == window.windowId
        let isInputReady = isInputReadyForWindow()

        if let lastFocusRequestAt,
           now.timeIntervalSince(lastFocusRequestAt) < focusRequestMinInterval,
           isLocallyActive,
           isInputReady {
            return
        }

        lastFocusRequestAt = now

        if session.activeWindowId != window.windowId {
            session.setActiveWindow(window.windowId)
        } else if !isInputReady {
            session.requestHostFocusForWindow(window.windowId)
        }
    }

    private func isInputReadyForWindow() -> Bool {
        let streamStatus = session.streamStatus(for: window.windowId)

        guard streamStatus != .offline else {
            return false
        }

        if isDisplayCaptureWindow(window) {
            return true
        }

        return session.isHostConfirmedActiveWindow(window.windowId)
    }

    private func isDisplayCaptureWindow(_ window: PeelWindow) -> Bool {
        window.appName.trimmingCharacters(in: .whitespacesAndNewlines) == "Peel Display"
    }

    private func resetDragState() {
        lastTranslation = .zero
        dragStartTime = nil
        dragStartLocation = nil
    }

    private func resolvedContentAspect(videoSize: CGSize?, cgImage: CGImage?) -> CGFloat {
        if let videoSize, videoSize.width > 0, videoSize.height > 0 {
            return videoSize.width / max(1, videoSize.height)
        }

        if let cgImage {
            return CGFloat(cgImage.width) / max(1, CGFloat(cgImage.height))
        }

        if let geometry = session.windowGeometry(for: window.windowId) {
            if let capturePxW = geometry.capturePxW,
               let capturePxH = geometry.capturePxH,
               capturePxW > 0,
               capturePxH > 0 {
                return CGFloat(capturePxW) / CGFloat(capturePxH)
            }

            let contentW = max(1.0, geometry.boundsW - geometry.insetX * 2.0)
            let contentH = max(1.0, geometry.boundsH - geometry.insetY * 2.0)
            return CGFloat(contentW / contentH)
        }

        return CGFloat(window.width) / max(1, CGFloat(window.height))
    }

    private func viewportTransform(
        in size: CGSize,
        contentAspect: CGFloat,
        zoomScale: CGFloat? = nil,
        contentOffset: CGSize? = nil
    ) -> ClientViewportTransform {
        ClientViewportTransform(
            viewSize: size,
            contentAspect: contentAspect,
            zoomScale: zoomScale ?? self.zoomScale,
            contentOffset: contentOffset ?? self.contentOffset,
            clickCalibrationOffset: clickCalibrationOffset
        )
    }

    private func normPoint(for location: CGPoint, in size: CGSize, contentAspect: CGFloat) -> CGPoint? {
        guard size.width > 0, size.height > 0, contentAspect > 0 else { return nil }
        return viewportTransform(in: size, contentAspect: contentAspect).normalizedPoint(for: location)
    }

    private func viewPoint(fromNorm norm: CGPoint, in size: CGSize, contentAspect: CGFloat) -> CGPoint {
        viewportTransform(in: size, contentAspect: contentAspect).viewPoint(fromNormalized: norm)
    }

    private func openingAppName(for window: PeelWindow) -> String {
        let appName = window.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !appName.isEmpty { return appName }

        let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }

        return "Peel Pro"
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

    private var tapCursorIndicator: some View {
        Circle()
            .fill(.clear)
            .frame(width: tapCursorSize, height: tapCursorSize)
            .glassBackgroundEffect(in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
            .overlay(Circle().fill(.white.opacity(0.45)).frame(width: 6, height: 6))
            .shadow(radius: 2)
    }

    private var immersiveWindowBar: some View {
        HStack(spacing: 10) {
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.bold())
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .background(.white.opacity(0.88), in: Circle())
            .foregroundStyle(.black.opacity(0.78))

            Text(window.title.isEmpty ? "Peel Pro" : window.title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)

            Spacer(minLength: 12)

            Image(systemName: "line.3.horizontal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.72))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if value.translation == .zero {
                        dragBaseHudX = hudX
                        dragBaseHudY = hudY
                    }

                    hudX = min(0.58, max(-0.58, dragBaseHudX + Float(value.translation.width / 900.0)))
                    hudY = min(0.38, max(-0.32, dragBaseHudY - Float(value.translation.height / 900.0)))
                }
        )
    }
}

private extension PeelImmersiveHomeButtonCorner {
    var isTrailing: Bool {
        switch self {
        case .topTrailing, .bottomTrailing:
            return true
        case .topLeading, .bottomLeading:
            return false
        }
    }
}

private struct ImmersiveKeyCaptureTextView: UIViewRepresentable {
    @Binding var isFocused: Bool
    let delegate: InvisibleTextInputDelegate

    func makeUIView(context: Context) -> PassthroughTextView {
        let textView = PassthroughTextView()
        textView.backgroundColor = .clear
        textView.isOpaque = false
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.keyboardType = .default
        textView.returnKeyType = .default
        textView.enablesReturnKeyAutomatically = false
        textView.keyDelegate = delegate
        textView.text = ""
        textView.selectedRange = NSRange(location: 0, length: 0)
        return textView
    }

    func updateUIView(_ uiView: PassthroughTextView, context: Context) {
        uiView.keyDelegate = delegate

        DispatchQueue.main.async {
            if isFocused {
                if !uiView.isFirstResponder {
                    _ = uiView.becomeFirstResponder()
                    uiView.reloadInputViews()
                }
            } else if uiView.isFirstResponder {
                uiView.resignFirstResponder()
            }
        }
    }

    final class PassthroughTextView: UITextView {
        weak var keyDelegate: InvisibleTextInputDelegate?
        override var canBecomeFirstResponder: Bool { true }

        override func insertText(_ text: String) {
            if text == "\n" {
                keyDelegate?.didPressEnter()
            } else {
                keyDelegate?.didInsertText(text)
            }
            self.text = ""
            self.selectedRange = NSRange(location: 0, length: 0)
        }

        override func deleteBackward() {
            keyDelegate?.didPressBackspace()
            self.text = ""
            self.selectedRange = NSRange(location: 0, length: 0)
        }
    }
}

private struct ImmersiveIndirectScrollCapture: UIViewRepresentable {
    var onScroll: (_ dx: CGFloat, _ dy: CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScroll: onScroll)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = context.coordinator
        pan.cancelsTouchesInView = false

        if #available(iOS 13.4, visionOS 1.0, *) {
            pan.allowedScrollTypesMask = [.continuous, .discrete]
        }

        pan.minimumNumberOfTouches = 0
        pan.maximumNumberOfTouches = 0

        view.addGestureRecognizer(pan)
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onScroll: (_ dx: CGFloat, _ dy: CGFloat) -> Void
        weak var view: UIView?

        private var displayLink: CADisplayLink?
        private var inertialVelocity: CGPoint = .zero
        private var lastTick: CFTimeInterval = 0
        private let decelRate: CGFloat = UIScrollView.DecelerationRate.normal.rawValue
        private let stopVelocityThreshold: CGFloat = 12

        init(onScroll: @escaping (_ dx: CGFloat, _ dy: CGFloat) -> Void) {
            self.onScroll = onScroll
        }

        deinit {
            stopInertia()
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view else { return }

            switch recognizer.state {
            case .began:
                stopInertia()

            case .changed:
                let translation = recognizer.translation(in: view)
                recognizer.setTranslation(.zero, in: view)
                guard abs(translation.x) >= 0.5 || abs(translation.y) >= 0.5 else { return }
                onScroll(translation.x, translation.y)

            case .ended, .cancelled, .failed:
                startInertia(with: recognizer.velocity(in: view))

            default:
                break
            }
        }

        private func startInertia(with velocity: CGPoint) {
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
            let now = CACurrentMediaTime()
            let dt = CGFloat(now - lastTick)
            lastTick = now

            let dx = inertialVelocity.x * dt
            let dy = inertialVelocity.y * dt

            if abs(dx) > 0.01 || abs(dy) > 0.01 {
                onScroll(dx, dy)
            }

            let decay = pow(decelRate, dt * 60.0)
            inertialVelocity.x *= decay
            inertialVelocity.y *= decay

            if abs(inertialVelocity.x) < stopVelocityThreshold && abs(inertialVelocity.y) < stopVelocityThreshold {
                stopInertia()
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }
    }
}
