//
//  Peel_iPadApp.swift
//  Peel-iPad
//
//  Created by Zach on 12/3/25.
//
//  iPad/iPhone parity update: Vision normal scene/client wiring, iOS UI only.
//

import SwiftUI

struct PeeledWindowSceneRequest: Codable, Hashable {
    let id: UUID
    let hostKey: PeelHostKey
    let hostName: String
    let window: PeelWindow

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

    private enum CodingKeys: String, CodingKey {
        case id
        case hostKey
        case hostName
        case window
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.hostKey = try container.decodeIfPresent(PeelHostKey.self, forKey: .hostKey)
            ?? PeelHostKey(rawValue: "legacy")
        self.hostName = try container.decodeIfPresent(String.self, forKey: .hostName) ?? "Computer"
        self.window = try container.decode(PeelWindow.self, forKey: .window)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(hostKey, forKey: .hostKey)
        try container.encode(hostName, forKey: .hostName)
        try container.encode(window, forKey: .window)
    }

    static func == (lhs: PeeledWindowSceneRequest, rhs: PeeledWindowSceneRequest) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

@main
struct Peel_iPadApp: App {
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var browser: PeelClientBrowser
    @StateObject private var scenes: SceneCoordinator
    @StateObject private var store: PeelStore
    @StateObject private var agentPresentationCoordinator: IPadAgentPresentationCoordinator
    @StateObject private var remoteNotificationPresenter: PeelLocalRemoteNotificationPresenter

    init() {
        // Install WatchConnectivity before any restored scene, including a peeled window.
        _ = PeelCompanionModel.shared
        PeelAccountClientLifecycle.start()
        let browser = PeelClientBrowser()
        let scenes = SceneCoordinator()
        let store = PeelStore()
        scenes.configureCommerce(store)
        let remoteNotificationPresenter = PeelLocalRemoteNotificationPresenter.shared

        _browser = StateObject(wrappedValue: browser)
        _scenes = StateObject(wrappedValue: scenes)
        _store = StateObject(wrappedValue: store)
        _agentPresentationCoordinator = StateObject(
            wrappedValue: IPadAgentPresentationCoordinator(
                browser: browser,
                scenes: scenes,
                store: store
            )
        )
        _remoteNotificationPresenter = StateObject(
            wrappedValue: remoteNotificationPresenter
        )
    }

    @MainActor
    private func refreshRemoteNotificationAuthorization() {
        remoteNotificationPresenter.refreshAuthorizationStatus { authorized in
            guard PeelAgentNotifications.isOptedIn, !authorized else { return }
            UserDefaults.standard.set(
                false,
                forKey: PeelAgentNotifications.optInDefaultsKey
            )
            browser.refreshAgentPresentationCapabilities()
        }
    }

    var body: some Scene {
        Group {
        WindowGroup("Peel Pro", id: "main") {
            PhoneMainSceneContent(browser: browser)
                .environmentObject(browser)
                .environmentObject(scenes)
                .environmentObject(store)
                .environmentObject(remoteNotificationPresenter)
                .iPadAgentPresentationSceneProvider(
                    dismissesMainAfterSuccessfulRoute: true
                )
                .environmentObject(agentPresentationCoordinator)
                .background(
                    WindowSceneReader { scene in
                        scenes.registerMainScene(scene)
                    }
                )
                .task {
                    await store.start()
                    refreshRemoteNotificationAuthorization()
                }
                .task {
                    await PeelCloudAgentAppComposition.start()
                    await PeelCloudAgentAppComposition.resumeForeground()
                }
                .onOpenURL { PeelCloudAgentPhoneService.shared.handlePluginApprovalURL($0) }
                .onChange(of: scenePhase) { _, newPhase in
                    scenes.noteAppScenePhaseChanged(newPhase)
                }
        }

        WindowGroup("Peeled Window", id: "peeled-window", for: PeeledWindowSceneRequest.self) { $request in
            PeeledWindowSceneContent(request: request)
            .environmentObject(browser)
            .environmentObject(scenes)
            .environmentObject(store)
            // This scene can be restored without opening the main window.
            .task { await store.start() }
            .task {
                await PeelCloudAgentAppComposition.start()
                await PeelCloudAgentAppComposition.resumeForeground()
            }
            .onOpenURL { PeelCloudAgentPhoneService.shared.handlePluginApprovalURL($0) }
            .environmentObject(remoteNotificationPresenter)
            .iPadAgentPresentationSceneProvider(
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
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            refreshRemoteNotificationAuthorization()
            Task { await PeelCloudAgentAppComposition.resumeForeground() }
        }
    }
}

/// SwiftUI instantiates this state for each main WindowGroup scene. A phone
/// scene must never replace a sibling scene's presentation binding.
private struct PhoneMainSceneContent: View {
    @StateObject private var coordinator: IPhoneAgentPresentationCoordinator

    init(browser: PeelClientBrowser) {
        _coordinator = StateObject(wrappedValue: IPhoneAgentPresentationCoordinator(browser: browser))
    }

    var body: some View {
        ContentView().environmentObject(coordinator)
            .background(WindowSceneReader { scene in coordinator.bindScene(scene) })
    }
}

/// Observe connection publications inside the window's view tree, including
/// sessions created after SwiftUI restores this scene's saved request.
private struct PeeledWindowSceneContent: View {
    let request: PeeledWindowSceneRequest?
    @EnvironmentObject private var browser: PeelClientBrowser
    @Environment(\.dismissWindow) private var dismissWindow

    private var resolvedSession: PeelHostSession? {
        guard let request else { return nil }
        return browser.session(for: request.hostKey) ??
            (request.hostKey.rawValue == "legacy" ? browser.selectedSession : nil)
    }

    var body: some View {
        if let request, let session = resolvedSession {
            if UIDevice.current.userInterfaceIdiom == .phone {
                IPhoneDevelopmentWorkspace(
                    hostedWindow: HostedPeelWindow(hostKey: session.hostKey, hostName: request.hostName, window: request.window),
                    session: session,
                    onDone: { dismissWindow(id: "peeled-window", value: request) }
                )
                .id(ObjectIdentifier(session))
            } else {
                PeelWindowSceneAdmission(hostedWindow: HostedPeelWindow(
                    hostKey: session.hostKey, hostName: request.hostName, window: request.window
                )) {
                    PeeledWindowView(request: request)
                }
            }
        } else {
            PeeledWindowConnectionRecoveryView(request: request)
        }
    }
}

/// A restored window can outlive its in-memory Mac session. This is an idle
/// recovery state, not a connection attempt, so it must always offer a way out.
private struct PeeledWindowConnectionRecoveryView: View {
    let request: PeeledWindowSceneRequest?

    @EnvironmentObject private var browser: PeelClientBrowser
    @EnvironmentObject private var scenes: SceneCoordinator
    @Environment(\.openWindow) private var openWindow

    private var pairedHost: PeelHostInfo? {
        guard let request, request.hostKey.rawValue != "legacy" else { return nil }
        // A saved title/name is display metadata, never authority to reconnect
        // a restored window to a different Mac with the same name.
        return browser.hosts.first {
            $0.hostKey == request.hostKey && browser.isPaired($0)
        }
    }

    var body: some View {
        ContentUnavailableView {
            Label(
                request == nil ? "No window selected" : "Computer disconnected",
                systemImage: "desktopcomputer"
            )
        } description: {
            if let request {
                Text("This window was restored without its connection to \(request.hostName). Open Peel Pro to reconnect and choose a desktop or app.")
            } else {
                Text("Open Peel Pro to choose a desktop or app window.")
            }
        } actions: {
            if let host = pairedHost {
                Button("Reconnect") {
                    browser.connectAndRequestWindows(for: host)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("peel.restoredWindow.reconnect")
            }

            Button("Open Peel Pro", systemImage: "square.grid.2x2") {
                if let request {
                    scenes.cancelPendingPeeledWindowSceneReservation(
                        for: HostedPeelWindow(
                            hostKey: request.hostKey,
                            hostName: request.hostName,
                            window: request.window
                        )
                    )
                }
                if !scenes.activateMainIfPossible(),
                   scenes.shouldPresentMainSceneFromUserAction() {
                    openWindow(id: "main")
                }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("peel.restoredWindow.openMain")
        }
    }
}
