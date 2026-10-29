//
//  PeelTrackpadView.swift
//  Peel
//
//  Created by Zach on 5/25/26.
//

import SwiftUI

struct PeelTrackpadView: View {
    @EnvironmentObject private var browser: PeelClientBrowser
    @EnvironmentObject private var scenes: SceneCoordinator

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    @State private var lastTranslation: CGSize = .zero
    @State private var dragStartTime: Date?
    @State private var dragStartLocation: CGPoint?
    @State private var touchCursorNorm: CGPoint?
    @State private var isDragModeArmed = false
    @State private var didSendMouseDown = false
    @State private var isOpeningHome = false
    @State private var pendingAutoDismissTask: Task<Void, Never>? = nil

    private let clickThreshold: CGFloat = 8
    private let longPressDuration: TimeInterval = 0.5
    private let longPressMovementThreshold: CGFloat = 12
    private let trackpadSensitivity: CGFloat = 1.35

    private struct TrackpadTarget {
        let session: PeelHostSession
        let window: PeelWindow
    }

    private var target: TrackpadTarget? {
        if let selectedSession = browser.selectedSession,
           let activeId = selectedSession.activeWindowId,
           let window = selectedSession.windows.first(where: { $0.windowId == activeId }) {
            return TrackpadTarget(session: selectedSession, window: window)
        }

        for session in browser.sessionsByHostKey.values {
            if let activeId = session.activeWindowId,
               let window = session.windows.first(where: { $0.windowId == activeId }) {
                return TrackpadTarget(session: session, window: window)
            }
        }

        if let selectedSession = browser.selectedSession,
           let window = selectedSession.windows.first {
            return TrackpadTarget(session: selectedSession, window: window)
        }

        for session in browser.sessionsByHostKey.values {
            if let window = session.windows.first {
                return TrackpadTarget(session: session, window: window)
            }
        }

        return nil
    }

    private var targetWindow: PeelWindow? {
        target?.window
    }

    private var targetSession: PeelHostSession? {
        target?.session
    }

    private var targetWindowLabel: String {
        guard let targetWindow else {
            return "No active peeled window"
        }

        let appName = targetWindow.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = targetWindow.title.trimmingCharacters(in: .whitespacesAndNewlines)

        if !appName.isEmpty {
            return appName
        }

        if !title.isEmpty {
            return title
        }

        return "Active window"
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.clear

/*
                if let touchCursorNorm {
                    Circle()
                        .fill(.white.opacity(0.16))
                        .frame(width: 24, height: 24)
                        .overlay {
                            Circle()
                                .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                        }
                        .overlay {
                            Circle()
                                .fill(.white.opacity(0.45))
                                .frame(width: 5, height: 5)
                        }
                        .position(viewPoint(from: touchCursorNorm, in: geo.size))
                        .allowsHitTesting(false)
                }
*/
            }
            .contentShape(Rectangle())
            .gesture(trackpadGesture(in: geo.size))
        }
        .padding(18)
        .ornament(
            visibility: .visible,
            attachmentAnchor: .scene(.top),
            contentAlignment: .center
        ) {
            clickButtonsOrnament
        }


        .onAppear {
            if let target {
                let initialNorm = target.session.currentSharedCursorNorm(for: target.window.windowId)
                touchCursorNorm = initialNorm
                target.session.showSharedCursor(for: target.window.windowId, norm: initialNorm, mode: .hover)
            }

            scheduleDismissIfNoPeeledWindows()
        }
        .onReceive(scenes.objectWillChange) { _ in
            scheduleDismissIfNoPeeledWindows()
        }
        .onDisappear {
            pendingAutoDismissTask?.cancel()
            pendingAutoDismissTask = nil

            if didSendMouseDown, let target {
                let norm = target.session.currentSharedCursorNorm(for: target.window.windowId, fallback: touchCursorNorm ?? CGPoint(x: 0.5, y: 0.5))
                target.session.sendMouseUp(on: target.window, normX: Double(norm.x), normY: Double(norm.y), button: "left")
            }

            didSendMouseDown = false
            isDragModeArmed = false
        }
    }


    private var trackpadTitleOrnament: some View {
        VStack(spacing: 2) {
            Text("Trackpad")
                .font(.headline)
                .lineLimit(1)

            Text("Adjust size to change sensitivity")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .glassBackgroundEffect(in: Capsule())
    }

    private var ornamentMenuButton: some View {
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
    }

    private var clickButtonsOrnament: some View {
        HStack(spacing: 14) {
            Button {
                sendExplicitClick(button: "left")
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "cursorarrow.click")
                        .font(.headline.weight(.semibold))

                    Text("L")
                        .font(.headline.weight(.bold))
                }
                .frame(width: 208, height: 52)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassBackgroundEffect(in: Capsule())
            .disabled(targetWindow == nil)
            .accessibilityLabel("Left click")
            
            ornamentMenuButton
            
            Button {
                sendExplicitClick(button: "right")
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "cursorarrow.click")
                        .font(.headline.weight(.semibold))

                    Text("R")
                        .font(.headline.weight(.bold))
                }
                .frame(width: 208, height: 52)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassBackgroundEffect(in: Capsule())
            .disabled(targetWindow == nil)
            .accessibilityLabel("Right click")
        }
    }

    private func returnToBrowser() {
        guard !isOpeningHome else { return }

        browser.forceMouseUpIfNeeded(reason: "opening browser from trackpad")
        isOpeningHome = true

        _ = scenes.activateMainIfPossible()

        if scenes.shouldPresentMainSceneFromUserAction() {
            openWindow(id: "main")
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            isOpeningHome = false
        }
    }

    private func scheduleDismissIfNoPeeledWindows() {
        pendingAutoDismissTask?.cancel()
        pendingAutoDismissTask = Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(250))

            guard !Task.isCancelled else { return }
            let hasPeeledWindow = scenes.hasOpenPeeledWindows()
            let hasImmersiveWindow = scenes.isPeelImmersiveSpaceOpen || !scenes.peelImmersiveWindows.isEmpty

            guard !(hasPeeledWindow || hasImmersiveWindow) else { return }

            dismiss()
        }
    }

    private func trackpadGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let target else {
                    return
                }

                let targetWindow = target.window
                let targetSession = target.session

                if dragStartTime == nil {
                    dragStartTime = Date()
                    dragStartLocation = value.startLocation
                    lastTranslation = .zero
                }

                let incrementalDelta = CGSize(
                    width: value.translation.width - lastTranslation.width,
                    height: value.translation.height - lastTranslation.height
                )

                lastTranslation = value.translation

                let currentNorm = targetSession.currentSharedCursorNorm(
                    for: targetWindow.windowId,
                    fallback: touchCursorNorm ?? CGPoint(x: 0.5, y: 0.5)
                )

                let nextNorm = movedCursor(from: currentNorm, delta: incrementalDelta, in: size)
                touchCursorNorm = nextNorm

                targetSession.showSharedCursor(for: targetWindow.windowId, norm: nextNorm, mode: .hover)
                targetSession.sendMouseMove(
                    on: targetWindow,
                    normX: Double(nextNorm.x),
                    normY: Double(nextNorm.y)
                )
            }
            .onEnded { value in
                defer {
                    lastTranslation = .zero
                    dragStartTime = nil
                    dragStartLocation = nil
                }

                guard let target else {
                    touchCursorNorm = nil
                    return
                }

                let targetWindow = target.window
                let targetSession = target.session

                let norm = targetSession.currentSharedCursorNorm(for: targetWindow.windowId, fallback: touchCursorNorm ?? CGPoint(x: 0.5, y: 0.5))
                touchCursorNorm = norm
                targetSession.showSharedCursor(for: targetWindow.windowId, norm: norm, mode: .hover)

                let totalMovement = hypot(value.translation.width, value.translation.height)
                if totalMovement <= clickThreshold {
                    targetSession.showSharedCursor(for: targetWindow.windowId, norm: norm, mode: .click)
                    targetSession.sendClick(on: targetWindow, normX: Double(norm.x), normY: Double(norm.y), button: "left")
                }
            }
    }

    private func sendDragInput(to window: PeelWindow, at norm: CGPoint) {
        guard let targetSession else { return }

        if !didSendMouseDown {
            didSendMouseDown = true
            targetSession.showSharedCursor(for: window.windowId, norm: norm, mode: .drag)
            targetSession.sendMouseDown(on: window, normX: Double(norm.x), normY: Double(norm.y), button: "left")
        }

        targetSession.showSharedCursor(for: window.windowId, norm: norm, mode: .drag)
        targetSession.sendMouseDrag(on: window, normX: Double(norm.x), normY: Double(norm.y), button: "left")
    }

    private func finishDragInput(to window: PeelWindow) {
        guard let targetSession else { return }

        let norm = targetSession.currentSharedCursorNorm(for: window.windowId, fallback: touchCursorNorm ?? CGPoint(x: 0.5, y: 0.5))

        if didSendMouseDown {
            targetSession.sendMouseUp(on: window, normX: Double(norm.x), normY: Double(norm.y), button: "left")
        }

        didSendMouseDown = false
        isDragModeArmed = false
        touchCursorNorm = norm
        targetSession.showSharedCursor(for: window.windowId, norm: norm, mode: .hover)
    }

    private func sendExplicitClick(button: String) {
        guard let target else { return }

        let targetWindow = target.window
        let targetSession = target.session
        let norm = targetSession.currentSharedCursorNorm(for: targetWindow.windowId, fallback: touchCursorNorm ?? CGPoint(x: 0.5, y: 0.5))
        touchCursorNorm = norm

        let mode: PeelSharedCursorMode = button == "right" ? .rightClick : .click
        targetSession.showSharedCursor(for: targetWindow.windowId, norm: norm, mode: mode)
        targetSession.sendClick(on: targetWindow, normX: Double(norm.x), normY: Double(norm.y), button: button)
    }

    private func movedCursor(from current: CGPoint, delta: CGSize, in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else {
            return current
        }

        let dx = (delta.width / size.width) * trackpadSensitivity
        let dy = (delta.height / size.height) * trackpadSensitivity

        return CGPoint(
            x: min(max(current.x + dx, 0), 1),
            y: min(max(current.y + dy, 0), 1)
        )
    }

    private func requestFocusIfNeeded(for window: PeelWindow) {
        guard let targetSession else { return }

        if targetSession.activeWindowId != window.windowId || !targetSession.isHostConfirmedActiveWindow(window.windowId) {
            targetSession.setActiveWindow(window.windowId)
        }
    }

    private func normalizedPoint(_ location: CGPoint, in size: CGSize) -> CGPoint? {
        guard size.width > 0, size.height > 0 else {
            return nil
        }

        return CGPoint(
            x: min(max(location.x / size.width, 0), 1),
            y: min(max(location.y / size.height, 0), 1)
        )
    }

    private func viewPoint(from norm: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(norm.x * size.width, 0), size.width),
            y: min(max(norm.y * size.height, 0), size.height)
        )
    }
}
