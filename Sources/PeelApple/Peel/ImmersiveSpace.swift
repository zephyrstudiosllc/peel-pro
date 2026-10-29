//
//  PeelImmersiveLayoutMode.swift
//  Peel
//
//  Created by Zach on 5/25/26.
//


//
//  PeelImmersiveSpaceView.swift
//  Peel
//
//  Additive immersive fork for Peel windows. visionOS only.
//

import SwiftUI
import RealityKit
import UIKit
import simd
import Combine

enum PeelImmersiveLayoutMode: String, CaseIterable, Identifiable {
    case hud
    case focus
    case field

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hud: return "HUD"
        case .focus: return "Focus"
        case .field: return "Field"
        }
    }

    var systemImage: String {
        switch self {
        case .hud: return "viewfinder"
        case .focus: return "rectangle.center.inset.filled"
        case .field: return "rectangle.3.group"
        }
    }
}

enum PeelImmersiveHomeButtonCorner {
    case topLeading
    case bottomLeading
    case bottomTrailing
    case topTrailing
}

struct PeelImmersiveSpaceView: View {
    @EnvironmentObject private var browser: PeelClientBrowser
    @EnvironmentObject private var scenes: SceneCoordinator
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow

    @State private var rootEntity: AnchorEntity?
    @State private var surfaceScale: CGFloat = 1.0
    @State private var layoutMode: PeelImmersiveLayoutMode = .field
    @State private var selectedWindowInstanceID: PeelWindowInstanceID? = nil

    @State private var hudX: Float = 0.26
    @State private var hudY: Float = 0.16
    @State private var hudDistance: Float = 0.78
    @State private var hudScale: Float = 0.72

    private let rootName = "peel-immersive-head-root"
    private let controlsAttachmentId = "peel-immersive-controls"
    private let showImmersiveSpaceControls = false

    var body: some View {
        let windows = orderedImmersiveHostedWindows
        let primaryWindowInstanceID = selectedWindowInstanceID ?? scenes.peelImmersivePrimaryWindowInstanceID ?? windows.first?.instanceID

        RealityView { content, attachments in
            let anchor = AnchorEntity(.head)
            anchor.name = rootName
            rootEntity = anchor
            content.add(anchor)
            syncAttachments(rootEntity: anchor, windows: windows, primaryWindowInstanceID: primaryWindowInstanceID, attachments: attachments)
        } update: { content, attachments in
            let anchor: AnchorEntity
            if let existingRoot = rootEntity {
                anchor = existingRoot
                if anchor.parent == nil {
                    content.add(anchor)
                }
            } else {
                let newRoot = AnchorEntity(.head)
                newRoot.name = rootName
                rootEntity = newRoot
                content.add(newRoot)
                anchor = newRoot
            }

            syncAttachments(rootEntity: anchor, windows: windows, primaryWindowInstanceID: primaryWindowInstanceID, attachments: attachments)
        } attachments: {
            ForEach(windows) { hostedWindow in
                Attachment(id: attachmentId(for: hostedWindow)) {
                    let index = windows.firstIndex(where: { $0.id == hostedWindow.id }) ?? 0
                    let isPrimary = hostedWindow.instanceID == primaryWindowInstanceID
                    let placement = placementForWindow(
                        index: index,
                        count: windows.count,
                        isPrimary: isPrimary
                    )

                    if let session = browser.session(for: hostedWindow.hostKey) {
                        PeeledImmersiveSurface(
                            hostedWindow: hostedWindow,
                            session: session,
                            isPrimary: isPrimary,
                            homeButtonCorner: homeButtonCorner(for: placement),
                            surfaceScale: $surfaceScale,
                            layoutMode: $layoutMode,
                            hudX: $hudX,
                            hudY: $hudY,
                            hudScale: $hudScale,
                            onMakePrimary: {
                                selectedWindowInstanceID = hostedWindow.instanceID
                                scenes.setPeelImmersivePrimaryWindow(hostedWindow)
                                session.setActiveWindow(hostedWindow.window.windowId)
                            },
                            onClose: {
                                Task { @MainActor in
                                    session.forceMouseUpIfNeeded(reason: "closing Peel immersive display")
                                    await dismissImmersiveSpace()
                                    scenes.markPeelImmersiveSpaceClosed()
                                    selectedWindowInstanceID = nil
                                }
                            }
                        )
                        .environmentObject(browser)
                        .frame(width: 1240, height: 780)
                    } else {
                        PeelLoadingView(
                            header: "Host unavailable",
                            subhead: "Return to Peel Pro and reconnect to this computer.",
                            variant: .connecting,
                            showsLogo: true
                        )
                        .frame(width: 1240, height: 780)
                    }
                }
            }

            if showImmersiveSpaceControls {
                Attachment(id: controlsAttachmentId) {
                    let controlWindows = windows.map(\.window)
                    PeelImmersiveControlPanel(
                        windows: controlWindows,
                        primaryWindowId: primaryWindowInstanceID?.windowId,
                        surfaceScale: $surfaceScale,
                        layoutMode: $layoutMode,
                        selectWindow: { window in
                            guard let hostedWindow = windows.first(where: { $0.window.windowId == window.windowId }) else { return }
                            selectedWindowInstanceID = hostedWindow.instanceID
                            scenes.setPeelImmersivePrimaryWindow(hostedWindow)
                            browser.session(for: hostedWindow.hostKey)?.setActiveWindow(hostedWindow.window.windowId)
                        },
                        openHome: {
                            if scenes.activateMainIfPossible() == false, scenes.canRequestMainSceneRestore() {
                                scenes.markMainSceneOpenRequested()
                                openWindow(id: "main")
                            }
                        },
                        openTrackpad: {
                            if let primaryWindowInstanceID,
                               let hostedWindow = windows.first(where: { $0.instanceID == primaryWindowInstanceID }) {
                                browser.session(for: hostedWindow.hostKey)?.setActiveWindow(hostedWindow.window.windowId)
                            }
                            openWindow(id: "peel-trackpad")
                        },
                        close: {
                            Task { @MainActor in
                                for hostedWindow in windows {
                                    browser.session(for: hostedWindow.hostKey)?.forceMouseUpIfNeeded(reason: "closing Peel immersive space")
                                }
                                await dismissImmersiveSpace()
                                scenes.markPeelImmersiveSpaceClosed()
                                selectedWindowInstanceID = nil
                            }
                        }
                    )
                    .environmentObject(browser)
                    .frame(width: 520, height: 150)
                }
            }
        }
        .onAppear {
            print("✅ PeelImmersiveSpaceView appeared with \(windows.count) windows")
            scenes.markPeelImmersiveSpaceOpen()
            selectedWindowInstanceID = selectedWindowInstanceID ?? scenes.peelImmersivePrimaryWindowInstanceID ?? windows.first?.instanceID
            beginStreams(for: windows)
        }
        .onDisappear {
            print("👋 PeelImmersiveSpaceView disappeared")
            for hostedWindow in windows {
                browser.session(for: hostedWindow.hostKey)?.forceMouseUpIfNeeded(reason: "Peel immersive space disappeared")
            }
            scenes.markPeelImmersiveSpaceClosed()
            selectedWindowInstanceID = nil
            // Do not call endPullStream here. Normal peeled windows may still own the same stream ids,
            // and PeelClientBrowser is currently set-based rather than reference-counted.
        }
        .onChange(of: windows.map(\.id)) { _, _ in
            reconcileSelectedWindow(with: orderedImmersiveHostedWindows)
            beginStreams(for: orderedImmersiveHostedWindows)
        }
        .onReceive(browser.objectWillChange) { _ in
            reconcileSelectedWindow(with: orderedImmersiveHostedWindows)
            beginStreams(for: orderedImmersiveHostedWindows)
        }
    }

    private var orderedImmersiveHostedWindows: [HostedPeelWindow] {
        let prepared = scenes.peelImmersiveHostedWindows
        let fallback: [HostedPeelWindow] = {
            if !prepared.isEmpty { return prepared }

            if let selectedSession = browser.selectedSession {
                if let activeWindowId = selectedSession.activeWindowId,
                   let activeWindow = selectedSession.windows.first(where: { $0.windowId == activeWindowId }) {
                    return [hostedWindow(for: selectedSession, window: activeWindow)]
                }

                return selectedSession.windows.prefix(1).map { hostedWindow(for: selectedSession, window: $0) }
            }

            return browser.windows.prefix(1).map { legacyHostedWindow(for: $0) }
        }()

        let refreshed = fallback.compactMap { refreshedHostedWindow($0) }
        let candidates = refreshed.isEmpty ? fallback : refreshed
        let primaryID = selectedWindowInstanceID ?? scenes.peelImmersivePrimaryWindowInstanceID

        return stableUniquedByWindowInstanceId(candidates).sorted { lhs, rhs in
            if lhs.instanceID == primaryID { return true }
            if rhs.instanceID == primaryID { return false }

            if lhs.hostName != rhs.hostName {
                return lhs.hostName.localizedCaseInsensitiveCompare(rhs.hostName) == .orderedAscending
            }

            return lhs.window.windowId < rhs.window.windowId
        }
    }

    private func hostedWindow(for session: PeelHostSession, window: PeelWindow) -> HostedPeelWindow {
        HostedPeelWindow(
            hostKey: session.hostKey,
            hostName: session.host.name,
            window: window
        )
    }

    private func legacyHostedWindow(for window: PeelWindow) -> HostedPeelWindow {
        HostedPeelWindow(
            hostKey: PeelHostKey(rawValue: "legacy"),
            hostName: browser.connectedHostName ?? "Computer",
            window: window
        )
    }

    private func refreshedHostedWindow(_ hostedWindow: HostedPeelWindow) -> HostedPeelWindow? {
        if let session = browser.session(for: hostedWindow.hostKey) {
            if let liveWindow = session.windows.first(where: { $0.windowId == hostedWindow.window.windowId }) {
                return self.hostedWindow(for: session, window: liveWindow)
            }

            return session.windows.isEmpty ? hostedWindow : nil
        }

        if hostedWindow.hostKey.rawValue == "legacy" {
            if let liveWindow = browser.windows.first(where: { $0.windowId == hostedWindow.window.windowId }) {
                return legacyHostedWindow(for: liveWindow)
            }
            return browser.windows.isEmpty ? hostedWindow : nil
        }

        return hostedWindow
    }

    private func stableUniquedByWindowInstanceId(_ windows: [HostedPeelWindow]) -> [HostedPeelWindow] {
        var seen = Set<String>()
        var result: [HostedPeelWindow] = []

        for window in windows where seen.insert(window.id).inserted {
            result.append(window)
        }

        return result
    }

    private func beginStreams(for windows: [HostedPeelWindow]) {
        for hostedWindow in windows {
            browser.session(for: hostedWindow.hostKey)?.beginPullStream(for: hostedWindow.window)
        }
    }

    private func reconcileSelectedWindow(with windows: [HostedPeelWindow]) {
        let ids = Set(windows.map(\.instanceID))
        if let selectedWindowInstanceID, !ids.contains(selectedWindowInstanceID) {
            self.selectedWindowInstanceID = windows.first?.instanceID
        } else if selectedWindowInstanceID == nil {
            selectedWindowInstanceID = scenes.peelImmersivePrimaryWindowInstanceID ?? windows.first?.instanceID
        }
    }

    private func syncAttachments(
        rootEntity: AnchorEntity,
        windows: [HostedPeelWindow],
        primaryWindowInstanceID: PeelWindowInstanceID?,
        attachments: RealityViewAttachments
    ) {
        let validNames = Set(windows.map { attachmentId(for: $0) } + (showImmersiveSpaceControls ? [controlsAttachmentId] : []))

        for child in rootEntity.children where child.name.hasPrefix("peel-immersive-") && !validNames.contains(child.name) {
            child.removeFromParent()
        }

        for (index, hostedWindow) in windows.enumerated() {
            let id = attachmentId(for: hostedWindow)
            guard let entity = attachments.entity(for: id) else { continue }
            entity.name = id

            if entity.parent == nil {
                rootEntity.addChild(entity)
            }

            let placement = placementForWindow(
                index: index,
                count: windows.count,
                isPrimary: hostedWindow.instanceID == primaryWindowInstanceID
            )

            entity.position = placement.position
            let yawRotation = simd_quatf(angle: placement.yaw, axis: SIMD3<Float>(0, 1, 0))
            let pitchRotation = simd_quatf(angle: placement.pitch, axis: SIMD3<Float>(1, 0, 0))
            entity.orientation = yawRotation * pitchRotation
            entity.scale = SIMD3<Float>(repeating: placement.scale)
            entity.components.set(OpacityComponent(opacity: max(0.2, min(1.0, scenes.immersiveFieldOpacity))))
        }

        if showImmersiveSpaceControls, let controls = attachments.entity(for: controlsAttachmentId) {
            controls.name = controlsAttachmentId
            if controls.parent == nil {
                rootEntity.addChild(controls)
            }

            switch layoutMode {
            case .hud:
                controls.position = SIMD3<Float>(hudX, hudY - 0.34, -hudDistance + 0.02)
                controls.scale = SIMD3<Float>(repeating: max(0.64, hudScale * 0.86))
            case .focus, .field:
                controls.position = SIMD3<Float>(0.0, -0.32, -0.65)
                controls.scale = SIMD3<Float>(repeating: 1.0)
            }

            controls.orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        }
    }

    private func placementForWindow(index: Int, count: Int, isPrimary: Bool) -> PeelImmersiveAttachmentPlacement {
        let baseScale = Float(surfaceScale)

        switch layoutMode {
        case .hud:
            if isPrimary || count == 1 {
                return PeelImmersiveAttachmentPlacement(
                    position: SIMD3<Float>(hudX, hudY, -hudDistance),
                    yaw: 0,
                    pitch: 0,
                    scale: Float(surfaceScale) * hudScale
                )
            }

            let sideIndex = max(0, index - 1)
            let direction: Float = sideIndex.isMultiple(of: 2) ? -1 : 1
            let lane = Float((sideIndex / 2) + 1)
            let x = hudX + direction * min(0.54, 0.30 * lane)
            let y = hudY - 0.22 - min(0.16, 0.04 * lane)
            let z = -hudDistance - 0.18 - min(0.18, 0.05 * lane)
            let yaw = direction * Float.pi / 18

            return PeelImmersiveAttachmentPlacement(
                position: SIMD3<Float>(x, y, z),
                yaw: yaw,
                pitch: 0,
                scale: Float(surfaceScale) * hudScale * 0.56
            )

        case .focus:
            if isPrimary || count == 1 {
                return PeelImmersiveAttachmentPlacement(
                    position: SIMD3<Float>(0.0, 0.0, -0.95),
                    yaw: 0,
                    pitch: 0,
                    scale: baseScale
                )
            }

            let sideIndex = max(0, index - 1)
            let direction: Float = sideIndex.isMultiple(of: 2) ? -1 : 1
            let lane = Float((sideIndex / 2) + 1)
            let x = direction * min(0.95, 0.46 * lane)
            let y = -0.12 - min(0.22, 0.05 * lane)
            let z: Float = -1.56 - min(0.22, 0.06 * lane)
            let yaw = direction * Float.pi / 14

            return PeelImmersiveAttachmentPlacement(
                position: SIMD3<Float>(x, y, z),
                yaw: yaw,
                pitch: 0,
                scale: baseScale * 0.64
            )

        case .field:
            let distance = scenes.immersiveFieldDistance
            let arc = scenes.immersiveFieldArc
            let xOffset = scenes.immersiveFieldOffsetX
            let yOffset = scenes.immersiveFieldOffsetY
            let isPrimaryWindow = isPrimary || count == 1

            let baseX: Float
            let baseY: Float
            let scaleMultiplier: Float
            let laneDepth: Float

            if isPrimaryWindow {
                baseX = 0
                baseY = -0.02
                scaleMultiplier = 1.0
                laneDepth = 0
            } else {
                let sideIndex = max(0, index - 1)
                let direction: Float = sideIndex.isMultiple(of: 2) ? -1 : 1
                let lane = Float((sideIndex / 2) + 1)
                baseX = direction * min(1.42, 0.72 * lane)
                baseY = -0.08
                scaleMultiplier = 0.78
                laneDepth = min(0.24, 0.06 * lane)
            }

            let finalX = xOffset + baseX
            let finalY = baseY + yOffset
            let normalizedX = max(-1.0, min(1.0, finalX / max(0.001, distance)))
            let normalizedY = max(-1.0, min(1.0, finalY / max(0.001, distance)))
            let arcAngle = normalizedX * arc * 0.85
            let verticalAngle = normalizedY * arc * 0.65
            let shouldCurve = arc > 0.001
            let curvedZ = -cos(arcAngle) * cos(verticalAngle) * distance - laneDepth
            let flatZ = -distance - laneDepth
            let z = shouldCurve ? curvedZ : flatZ
            let yaw = shouldCurve ? -arcAngle : 0
            let pitch = shouldCurve ? verticalAngle : 0

            return PeelImmersiveAttachmentPlacement(
                position: SIMD3<Float>(
                    finalX,
                    finalY,
                    z
                ),
                yaw: yaw,
                pitch: pitch,
                scale: baseScale * scenes.immersiveFieldScale * scaleMultiplier
            )
        }
    }

    private func homeButtonCorner(for placement: PeelImmersiveAttachmentPlacement) -> PeelImmersiveHomeButtonCorner {
        let x = placement.position.x
        let y = placement.position.y

        if x >= 0, y < 0 {
            return .topLeading
        } else if x >= 0, y >= 0 {
            return .bottomLeading
        } else if x < 0, y >= 0 {
            return .bottomTrailing
        } else {
            return .topTrailing
        }
    }

    private func attachmentId(for hostedWindow: HostedPeelWindow) -> String {
        "peel-immersive-window-\(hostedWindow.id)"
    }
}

private struct PeelImmersiveAttachmentPlacement {
    let position: SIMD3<Float>
    let yaw: Float
    let pitch: Float
    let scale: Float
}
