//
//  PeelApp.swift
//  Peel
//
//  Created by Zach on 11/30/25.
//


import SwiftUI

struct PeeledWindowSceneRequest: Codable, Hashable {
    // Keep the existing single-host initializer working, but allow new multi-host
    // callers to scope scene identity by hostKey + windowId.
    let id: UUID
    let hostKey: PeelHostKey
    let hostName: String
    let window: PeelWindow

    var windowInstanceID: PeelWindowInstanceID {
        PeelWindowInstanceID(hostKey: hostKey, windowId: window.windowId)
    }

    init(window: PeelWindow) {
        self.id = UUID()
        self.hostKey = PeelHostKey(rawValue: "legacy")
        self.hostName = "Mac"
        self.window = window
    }

    init(hostedWindow: HostedPeelWindow) {
        self.id = UUID()
        self.hostKey = hostedWindow.hostKey
        self.hostName = hostedWindow.hostName
        self.window = hostedWindow.window
    }

    init(hostKey: PeelHostKey, hostName: String, window: PeelWindow) {
        self.id = UUID()
        self.hostKey = hostKey
        self.hostName = hostName
        self.window = window
    }

    static func == (lhs: PeeledWindowSceneRequest, rhs: PeeledWindowSceneRequest) -> Bool {
        lhs.hostKey == rhs.hostKey && lhs.window.windowId == rhs.window.windowId
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(hostKey)
        hasher.combine(window.windowId)
    }
}

@main
struct PeelApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("peel.useBalancedWindowLayout") private var useBalancedWindowLayout: Bool = true
    @StateObject private var browser: PeelClientBrowser
    @StateObject private var scenes: SceneCoordinator
    @StateObject private var store: PeelStore
    @StateObject private var agentPresentationCoordinator: VisionAgentPresentationCoordinator
#if os(iOS) || os(visionOS)
    @StateObject private var remoteNotificationPresenter: PeelLocalRemoteNotificationPresenter
#endif

#if os(visionOS)
    @State private var immersiveStyle: ImmersionStyle = .mixed
#endif

    init() {
        PeelAccountClientLifecycle.start()
        let browser = PeelClientBrowser()
        let scenes = SceneCoordinator()
        let store = PeelStore()
        scenes.configureCommerce(store)

        _browser = StateObject(wrappedValue: browser)
        _scenes = StateObject(wrappedValue: scenes)
        _store = StateObject(wrappedValue: store)
        _agentPresentationCoordinator = StateObject(
            wrappedValue: VisionAgentPresentationCoordinator(
                browser: browser,
                scenes: scenes,
                store: store
            )
        )
#if os(iOS) || os(visionOS)
        _remoteNotificationPresenter = StateObject(
            wrappedValue: PeelLocalRemoteNotificationPresenter.shared
        )
#endif
    }

    var body: some Scene {
        // Main selector window: single definitive Peel menu/browser.
        Window("Peel Pro", id: "main") {
            ContentView()
                .environmentObject(browser)
                .environmentObject(scenes)
                .environmentObject(store)
#if os(iOS) || os(visionOS)
                .environmentObject(remoteNotificationPresenter)
#endif
                .visionAgentPresentationSceneProvider(
                    dismissesMainAfterSuccessfulRoute: true
                )
                .environmentObject(agentPresentationCoordinator)
                .task {
                    await store.start()
#if os(iOS) || os(visionOS)
                    remoteNotificationPresenter.refreshAuthorizationStatus { authorized in
                        guard PeelAgentNotifications.isOptedIn, !authorized else { return }
                        UserDefaults.standard.set(
                            false,
                            forKey: PeelAgentNotifications.optInDefaultsKey
                        )
                        browser.refreshAgentPresentationCapabilities()
                    }
#endif
                }
                .onAppear {
                    scenes.peeledWindowPlacementMode = useBalancedWindowLayout ? .balancedSlots : .trailingCascade
                }
                .onChange(of: useBalancedWindowLayout) { _, newValue in
                    scenes.peeledWindowPlacementMode = newValue ? .balancedSlots : .trailingCascade
                }
                
        }
        .defaultSize(width: 500, height: 900)
#if os(visionOS)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.presented)
#endif

        // Blank input surface for controlling the active peeled window without starting a stream.
        Window("Peel Pro Trackpad", id: "peel-trackpad") {
            PeelTrackpadView()
                .environmentObject(browser)
                .environmentObject(scenes)
                .task { await store.start() }
#if os(iOS) || os(visionOS)
                .environmentObject(remoteNotificationPresenter)
#endif
                .visionAgentPresentationSceneProvider()
                .environmentObject(agentPresentationCoordinator)
                .background(MainWindowActivationRestorer(scenes: scenes))
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 520, height: 360)
#if os(visionOS)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
#endif

        // Each peeled window is its own window scene.
        WindowGroup("Peeled Window", id: "peeled-window", for: PeeledWindowSceneRequest.self) { $request in
            Group {
                if let request {
                    PeelWindowSceneAdmission(hostedWindow: HostedPeelWindow(
                        hostKey: request.hostKey, hostName: request.hostName, window: request.window
                    )) {
                        PeeledWindowView(request: request, frameMode: .locked)
                    }
                } else {
                    Text("No window selected")
                }
            }
            .environmentObject(browser)
            .environmentObject(scenes)
            .environmentObject(store)
            .task { await store.start() }
#if os(iOS) || os(visionOS)
            .environmentObject(remoteNotificationPresenter)
#endif
            .visionAgentPresentationSceneProvider(
                representedWindow: request.map {
                    HostedPeelWindow(
                        hostKey: $0.hostKey,
                        hostName: $0.hostName,
                        window: $0.window
                    )
                }
            )
            .environmentObject(agentPresentationCoordinator)
            .background(MainWindowActivationRestorer(scenes: scenes))
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 900, height: 600)
#if os(visionOS)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .defaultWindowPlacement { request, context in
            if scenes.peeledWindowPlacementMode == .trailingCascade {
                if let lastPeeledWindow = context.windows.reversed().first(where: { window in
                    window.id == "peeled-window" || window.id == "peeled-window-resizable"
                }) {
                    return WindowPlacement(.trailing(lastPeeledWindow))
                }

                if let mainWindow = context.windows.first(where: { $0.id == "main" }) {
                    return WindowPlacement(.trailing(mainWindow))
                }

                return WindowPlacement(.utilityPanel)
            }

            guard let slot = scenes.consumeNextPendingPeeledWindowPlacementSlot() else {
                if let lastPeeledWindow = context.windows.reversed().first(where: { window in
                    window.id == "peeled-window" || window.id == "peeled-window-resizable"
                }) {
                    return WindowPlacement(.trailing(lastPeeledWindow))
                }

                if let mainWindow = context.windows.first(where: { $0.id == "main" }) {
                    return WindowPlacement(.trailing(mainWindow))
                }

                return WindowPlacement(.utilityPanel)
            }

            let peeledWindows = context.windows.filter { window in
                window.id == "peeled-window" || window.id == "peeled-window-resizable"
            }
            let registeredSlots = scenes.registeredPeeledWindowPlacementSlots()

            if let anchorSlot = scenes.anchorSlotForPeeledWindowPlacementSlot(slot),
               let anchorIndex = registeredSlots.firstIndex(of: anchorSlot),
               peeledWindows.indices.contains(anchorIndex) {
                let anchorWindow = peeledWindows[anchorIndex]

                if scenes.shouldPlacePeeledWindowSlotAbove(slot) {
                    return WindowPlacement(.above(anchorWindow))
                }

                if scenes.shouldPlacePeeledWindowSlotBelow(slot) {
                    return WindowPlacement(.below(anchorWindow))
                }

                if scenes.shouldPlacePeeledWindowSlotLeading(slot) {
                    return WindowPlacement(.leading(anchorWindow))
                }

                return WindowPlacement(.trailing(anchorWindow))
            }

            if let mainWindow = context.windows.first(where: { $0.id == "main" }) {
                if scenes.shouldPlacePeeledWindowSlotAbove(slot) {
                    return WindowPlacement(.above(mainWindow))
                }

                if scenes.shouldPlacePeeledWindowSlotBelow(slot) {
                    return WindowPlacement(.below(mainWindow))
                }

                if scenes.shouldPlacePeeledWindowSlotLeading(slot) {
                    return WindowPlacement(.leading(mainWindow))
                }

                return WindowPlacement(.trailing(mainWindow))
            }

            return WindowPlacement(.utilityPanel)
        }
#endif

        WindowGroup("Resizable Peeled Window", id: "peeled-window-resizable", for: PeeledWindowSceneRequest.self) { $request in
            Group {
                if let request {
                    PeelWindowSceneAdmission(hostedWindow: HostedPeelWindow(
                        hostKey: request.hostKey, hostName: request.hostName, window: request.window
                    )) {
                        PeeledWindowView(request: request, frameMode: .resizable)
                    }
                } else {
                    Text("No window selected")
                }
            }
            .environmentObject(browser)
            .environmentObject(scenes)
            .environmentObject(store)
            .task { await store.start() }
#if os(iOS) || os(visionOS)
            .environmentObject(remoteNotificationPresenter)
#endif
            .visionAgentPresentationSceneProvider(
                representedWindow: request.map {
                    HostedPeelWindow(
                        hostKey: $0.hostKey,
                        hostName: $0.hostName,
                        window: $0.window
                    )
                }
            )
            .environmentObject(agentPresentationCoordinator)
            .background(MainWindowActivationRestorer(scenes: scenes))
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 960, height: 540)
#if os(visionOS)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .defaultWindowPlacement { request, context in
            if scenes.peeledWindowPlacementMode == .trailingCascade {
                if let lastPeeledWindow = context.windows.reversed().first(where: { window in
                    window.id == "peeled-window" || window.id == "peeled-window-resizable"
                }) {
                    return WindowPlacement(.trailing(lastPeeledWindow))
                }

                if let mainWindow = context.windows.first(where: { $0.id == "main" }) {
                    return WindowPlacement(.trailing(mainWindow))
                }

                return WindowPlacement(.utilityPanel)
            }

            guard let slot = scenes.consumeNextPendingPeeledWindowPlacementSlot() else {
                if let lastPeeledWindow = context.windows.reversed().first(where: { window in
                    window.id == "peeled-window" || window.id == "peeled-window-resizable"
                }) {
                    return WindowPlacement(.trailing(lastPeeledWindow))
                }

                if let mainWindow = context.windows.first(where: { $0.id == "main" }) {
                    return WindowPlacement(.trailing(mainWindow))
                }

                return WindowPlacement(.utilityPanel)
            }

            let peeledWindows = context.windows.filter { window in
                window.id == "peeled-window" || window.id == "peeled-window-resizable"
            }
            let registeredSlots = scenes.registeredPeeledWindowPlacementSlots()

            if let anchorSlot = scenes.anchorSlotForPeeledWindowPlacementSlot(slot),
               let anchorIndex = registeredSlots.firstIndex(of: anchorSlot),
               peeledWindows.indices.contains(anchorIndex) {
                let anchorWindow = peeledWindows[anchorIndex]

                if scenes.shouldPlacePeeledWindowSlotAbove(slot) {
                    return WindowPlacement(.above(anchorWindow))
                }

                if scenes.shouldPlacePeeledWindowSlotBelow(slot) {
                    return WindowPlacement(.below(anchorWindow))
                }

                if scenes.shouldPlacePeeledWindowSlotLeading(slot) {
                    return WindowPlacement(.leading(anchorWindow))
                }

                return WindowPlacement(.trailing(anchorWindow))
            }

            if let mainWindow = context.windows.first(where: { $0.id == "main" }) {
                if scenes.shouldPlacePeeledWindowSlotAbove(slot) {
                    return WindowPlacement(.above(mainWindow))
                }

                if scenes.shouldPlacePeeledWindowSlotBelow(slot) {
                    return WindowPlacement(.below(mainWindow))
                }

                if scenes.shouldPlacePeeledWindowSlotLeading(slot) {
                    return WindowPlacement(.leading(mainWindow))
                }

                return WindowPlacement(.trailing(mainWindow))
            }

            return WindowPlacement(.utilityPanel)
        }
#endif

#if os(visionOS)
        ImmersiveSpace(id: "peel-immersive") {
            PeelImmersiveSpaceView()
                .environmentObject(browser)
                .environmentObject(scenes)
                .task { await store.start() }
#if os(iOS) || os(visionOS)
                .environmentObject(remoteNotificationPresenter)
#endif
                .visionAgentPresentationSceneProvider()
                .environmentObject(agentPresentationCoordinator)
        }
        .immersionStyle(selection: $immersiveStyle, in: .mixed)
#endif
    }
    
}
