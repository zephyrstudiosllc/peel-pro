//
//  iPadAgentPresentationCoordinator.swift
//  Peel-iPad
//

import Combine
import SwiftUI
import UIKit

@MainActor
final class IPadAgentPresentationCoordinator: ObservableObject {
    private struct ActiveSceneProvider {
        let representedWindow: HostedPeelWindow?
        let openWindow: (PeeledWindowSceneRequest) -> Void
        let successfulRouteCompletion: () -> Void
    }

    private struct InFlightRoute {
        let claimID: UUID
        let session: PeelHostSession
        let pendingRequest: PeelPendingAgentPresentationRequest
        let hostedWindow: HostedPeelWindow
        var createdSceneReservation = false
        var successfulRouteCompletion: (() -> Void)?
    }

    private weak var browser: PeelClientBrowser?
    private weak var scenes: SceneCoordinator?
    private weak var store: PeelStore?

    private var routeState = IPadAgentPresentationRouteState<UUID, UUID>()
    private var providers: [UUID: ActiveSceneProvider] = [:]
    private var inFlightRoute: InFlightRoute?
    private var routingCancellable: AnyCancellable?
    private var activationTimeoutTask: Task<Void, Never>?
    private var providerLossTask: Task<Void, Never>?
    private var isDraining = false
    @Published private var presentationContexts: [String: String] = [:]
    private var contextOrder: [String] = []

    func presentationContext(for window: HostedPeelWindow) -> String? {
        presentationContexts[window.id]
    }

    func clearPresentationContext(for window: HostedPeelWindow) {
        presentationContexts[window.id] = nil
        contextOrder.removeAll { $0 == window.id }
    }

    private func recordContext(_ raw: String?, for window: HostedPeelWindow) {
        clearPresentationContext(for: window)
        guard let raw else { return }
        let plain = String(raw.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0.value == 9 || $0.value == 10
        }.prefix(1000).reduce(into: "") { $0.unicodeScalars.append($1) })
        let context = plain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !context.isEmpty, context.utf8.count <= 4000 else { return }
        presentationContexts[window.id] = context
        contextOrder.append(window.id)
        while contextOrder.count > 32 {
            presentationContexts[contextOrder.removeFirst()] = nil
        }
    }

    private let sceneActivationTimeout: TimeInterval = 5

    init(
        browser: PeelClientBrowser,
        scenes: SceneCoordinator,
        store: PeelStore
    ) {
        self.browser = browser
        self.scenes = scenes
        self.store = store

        routingCancellable = browser.$agentPresentationRoutingVersion
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.routingStateDidChange()
            }
    }

    func registerActiveSceneProvider(
        id: UUID,
        representedWindow: HostedPeelWindow?,
        openWindow: @escaping (PeeledWindowSceneRequest) -> Void,
        successfulRouteCompletion: @escaping () -> Void
    ) {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }

        providerLossTask?.cancel()
        providerLossTask = nil

        guard routeState.registerProvider(id) else { return }
        providers[id] = ActiveSceneProvider(
            representedWindow: representedWindow,
            openWindow: openWindow,
            successfulRouteCompletion: successfulRouteCompletion
        )

        if let representedWindow {
            completeActivatedRouteIfMatching(representedWindow)
        }
        routingStateDidChange()
    }

    func unregisterActiveSceneProvider(id: UUID) {
        routeState.unregisterProvider(id)
        providers[id] = nil

        guard routeState.selectedProviderID == nil,
              let claimID = inFlightRoute?.claimID else {
            return
        }

        // Scene handoffs briefly make the old scene inactive before the target
        // provider becomes active. Give that registration one transition beat.
        providerLossTask?.cancel()
        providerLossTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self,
                  self.routeState.selectedProviderID == nil,
                  self.inFlightRoute?.claimID == claimID else {
                return
            }
            self.finishCurrentRoute(
                claimID: claimID,
                status: "declined",
                reason: "No active Peel window can open this request."
            )
        }
    }

    private func routingStateDidChange() {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }

        if let route = inFlightRoute, finishIfInvalid(route) {
            return
        }

        drainPendingRequests()
    }

    private func drainPendingRequests() {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }

        while inFlightRoute == nil {
            guard let (session, pendingRequest) = claimNextPendingRequest() else {
                return
            }

            let claimID = UUID()
            guard routeState.claim(claimID) else {
                return
            }

            let hostedWindow = HostedPeelWindow(
                hostKey: session.hostKey,
                hostName: displayNameWithoutPeelPrefix(session.host.name),
                window: pendingRequest.message.window
            )

            inFlightRoute = InFlightRoute(
                claimID: claimID,
                session: session,
                pendingRequest: pendingRequest,
                hostedWindow: hostedWindow
            )
            beginRoutingCurrentRequest()
        }
    }

    private func claimNextPendingRequest()
        -> (PeelHostSession, PeelPendingAgentPresentationRequest)? {
        guard let browser else { return nil }

        let sessions = browser.sessionsByHostKey.values.sorted {
            $0.hostKey.rawValue < $1.hostKey.rawValue
        }

        for session in sessions {
            if let request = session.claimPendingAgentPresentationRequest() {
                return (session, request)
            }
        }

        return nil
    }

    private func beginRoutingCurrentRequest() {
        guard let route = inFlightRoute,
              let scenes else {
            return
        }

        if finishIfInvalid(route) {
            return
        }

        guard let providerID = routeState.selectedProviderID,
              let provider = providers[providerID] else {
            finishCurrentRoute(
                claimID: route.claimID,
                status: "declined",
                reason: "No active Peel window can open this request."
            )
            return
        }
        inFlightRoute?.successfulRouteCompletion =
            provider.successfulRouteCompletion

        let isAlreadyOpen = scenes.isPeeledWindowOpen(route.hostedWindow)
        if !isAlreadyOpen {
            guard scenes.canOpenAnotherPeeledWindow() else {
                finishCurrentRoute(
                    claimID: route.claimID,
                    status: "declined",
                    reason: "Peel's iPad window limit has been reached."
                )
                return
            }
        }

        // This is intentionally repeated immediately before the UIKit/SwiftUI
        // route. No selection changes or replacement sockets are consulted.
        if finishIfInvalid(route) {
            return
        }

        route.session.recordFocusedWindowId(route.hostedWindow.window.windowId)
        route.session.setActiveWindow(route.hostedWindow.window.windowId)

        if isAlreadyOpen {
            let claimID = route.claimID
            let accepted = scenes.activatePeeledWindowIfPossible(
                for: route.hostedWindow,
                onFailure: { [weak self] _ in
                    self?.finishCurrentRoute(
                        claimID: claimID,
                        status: "declined",
                        reason: "Peel could not activate the requested window."
                    )
                }
            )

            guard accepted else {
                finishCurrentRoute(
                    claimID: route.claimID,
                    status: "declined",
                    reason: "Peel could not activate the requested window."
                )
                return
            }
        } else {
            scenes.reservePeeledWindowScene(for: route.hostedWindow)
            guard scenes.isPeeledWindowOpen(route.hostedWindow) else {
                finishCurrentRoute(
                    claimID: route.claimID,
                    status: "declined",
                    reason: "Peel could not reserve another window."
                )
                return
            }

            inFlightRoute?.createdSceneReservation = true
            provider.openWindow(
                PeeledWindowSceneRequest(hostedWindow: route.hostedWindow)
            )
        }

        if scenes.isPeeledWindowSceneForegroundActive(route.hostedWindow) {
            finishCurrentRoute(
                claimID: route.claimID,
                status: "opened",
                reason: nil
            )
        } else {
            scheduleActivationTimeout(for: route)
        }
    }

    private func completeActivatedRouteIfMatching(_ representedWindow: HostedPeelWindow) {
        guard let route = inFlightRoute,
              windowInstance(representedWindow, matches: route.hostedWindow) else {
            return
        }

        finishCurrentRoute(
            claimID: route.claimID,
            status: "opened",
            reason: nil
        )
    }

    private func scheduleActivationTimeout(for route: InFlightRoute) {
        activationTimeoutTask?.cancel()

        let remainingFreshness = max(
            0,
            route.pendingRequest.message.expiresAt -
                Date().timeIntervalSince1970
        )
        let delay = min(sceneActivationTimeout, remainingFreshness)

        activationTimeoutTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }

            guard let self,
                  self.inFlightRoute?.claimID == route.claimID else {
                return
            }

            if !self.finishIfInvalid(route) {
                self.finishCurrentRoute(
                    claimID: route.claimID,
                    status: "declined",
                    reason: "Peel did not activate the requested window."
                )
            }
        }
    }

    private func finishCurrentRoute(
        claimID: UUID,
        status requestedStatus: String,
        reason requestedReason: String?
    ) {
        guard let route = inFlightRoute,
              route.claimID == claimID else {
            return
        }

        var status = requestedStatus
        var reason = requestedReason

        // An "opened" result has a second full source-session validation at the
        // scene activation boundary. A failure replaces, rather than follows,
        // the success result.
        if requestedStatus == "opened" {
            switch revalidate(route) {
            case .accepted:
                break
            case .declined(let validationReason):
                status = "declined"
                reason = validationReason
            case .unavailable(let validationReason):
                status = "unavailable"
                reason = validationReason
            }
        }

        activationTimeoutTask?.cancel()
        activationTimeoutTask = nil
        providerLossTask?.cancel()
        providerLossTask = nil

        if status != "opened", route.createdSceneReservation {
            scenes?.cancelPendingPeeledWindowSceneReservation(
                for: route.hostedWindow
            )
        }

        _ = routeState.complete(claimID)
        inFlightRoute = nil

        _ = route.session.sendAgentPresentationResult(
            for: route.pendingRequest,
            status: status,
            reason: reason
        )

        if status == "opened" {
            recordContext(route.pendingRequest.message.context, for: route.hostedWindow)
            route.successfulRouteCompletion?()
        }

        drainPendingRequests()
    }

    @discardableResult
    private func finishIfInvalid(_ route: InFlightRoute) -> Bool {
        switch revalidate(route) {
        case .accepted:
            return false
        case .declined(let reason):
            finishCurrentRoute(
                claimID: route.claimID,
                status: "declined",
                reason: reason
            )
        case .unavailable(let reason):
            finishCurrentRoute(
                claimID: route.claimID,
                status: "unavailable",
                reason: reason
            )
        }
        return true
    }

    private func displayNameWithoutPeelPrefix(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)

        for prefix in ["Peel Pro on ", "Peel on "]
            where trimmed.range(
                of: prefix,
                options: [.caseInsensitive, .anchored]
            ) != nil {
            return String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return trimmed
    }

    private func revalidate(_ route: InFlightRoute) -> AgentPresentationValidation {
        guard let browser,
              browser.session(for: route.session.hostKey) === route.session else {
            return .unavailable(reason: "This request's computer session changed.")
        }

        return route.session.revalidateAgentPresentation(route.pendingRequest)
    }

    private func windowInstance(
        _ candidate: HostedPeelWindow,
        matches expected: HostedPeelWindow
    ) -> Bool {
        guard candidate.hostKey == expected.hostKey,
              candidate.window.windowId == expected.window.windowId,
              candidate.window.appName == expected.window.appName,
              candidate.window.title == expected.window.title else {
            return false
        }

        switch (
            candidate.window.appLaunchTimeIntervalSince1970,
            expected.window.appLaunchTimeIntervalSince1970
        ) {
        case let (candidateLaunch?, expectedLaunch?):
            return abs(candidateLaunch - expectedLaunch) < 1
        case (nil, nil):
            return true
        default:
            return false
        }
    }
}

private struct IPadAgentPresentationSceneProvider: ViewModifier {
    @EnvironmentObject private var coordinator: IPadAgentPresentationCoordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase

    @State private var providerID = UUID()

    let representedWindow: HostedPeelWindow?
    let dismissesMainAfterSuccessfulRoute: Bool

    func body(content: Content) -> some View {
        content
            .onAppear {
                synchronizeProvider()
            }
            .onDisappear {
                coordinator.unregisterActiveSceneProvider(id: providerID)
            }
            .onChange(of: scenePhase) { _, _ in
                synchronizeProvider()
            }
            .onChange(of: representedWindow) { _, _ in
                synchronizeProvider()
            }
    }

    private func synchronizeProvider() {
        guard scenePhase == .active else {
            coordinator.unregisterActiveSceneProvider(id: providerID)
            return
        }

        coordinator.registerActiveSceneProvider(
            id: providerID,
            representedWindow: representedWindow,
            openWindow: { request in
                openWindow(
                    id: "peeled-window",
                    value: request
                )
            },
            successfulRouteCompletion: {
                guard dismissesMainAfterSuccessfulRoute else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    dismissWindow(id: "main")
                }
            }
        )
    }
}

extension View {
    func iPadAgentPresentationSceneProvider(
        representedWindow: HostedPeelWindow? = nil,
        dismissesMainAfterSuccessfulRoute: Bool = false
    ) -> some View {
        modifier(
            IPadAgentPresentationSceneProvider(
                representedWindow: representedWindow,
                dismissesMainAfterSuccessfulRoute:
                    dismissesMainAfterSuccessfulRoute
            )
        )
    }
}
