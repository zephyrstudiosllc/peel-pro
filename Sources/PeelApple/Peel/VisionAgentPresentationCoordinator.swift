//
//  VisionAgentPresentationCoordinator.swift
//  Peel
//

import Combine
import Foundation
import SwiftUI

/// Routes one authenticated agent window request into an active visionOS scene
/// provider. Requests remain owned by their source PeelHostSession until the
/// target scene is active and the session is revalidated.
@MainActor
final class VisionAgentPresentationCoordinator: ObservableObject {
    private struct ActiveSceneProvider {
        let representedWindow: HostedPeelWindow?
        let openWindow: (PeeledWindowSceneRequest) -> Void
        let successfulRouteCompletion: () -> Void
        let dismissesMainAfterSuccessfulRoute: Bool
    }

    private struct InFlightRoute {
        let claimID: UUID
        let session: PeelHostSession
        let pendingRequest: PeelPendingAgentPresentationRequest
        let hostedWindow: HostedPeelWindow
        let context: String?
        var createdSceneReservation = false
        var successfulRouteCompletion: (() -> Void)?
    }

    private weak var browser: PeelClientBrowser?
    private weak var scenes: SceneCoordinator?
    private weak var store: PeelStore?

    private var activeProviderIDs: [UUID] = []
    private var providers: [UUID: ActiveSceneProvider] = [:]
    private var inFlightRoute: InFlightRoute?
    private var routingCancellable: AnyCancellable?
    private var accessCancellable: AnyCancellable?
    private var activationTimeoutTask: Task<Void, Never>?
    private var providerLossTask: Task<Void, Never>?
    private var isDraining = false
    @Published private var presentationContextByWindowID: [String: String] = [:]
    private var presentationContextOrder: [String] = []

    private let maximumActiveProviders = 16
    private let maximumPresentationContexts = 64
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

        accessCancellable = store.$hasResolvedAccessState
            .dropFirst()
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.routingStateDidChange()
            }
    }

    func registerActiveSceneProvider(
        id: UUID,
        representedWindow: HostedPeelWindow?,
        openWindow: @escaping (PeeledWindowSceneRequest) -> Void,
        successfulRouteCompletion: @escaping () -> Void,
        dismissesMainAfterSuccessfulRoute: Bool
    ) {
        providerLossTask?.cancel()
        providerLossTask = nil

        if let existingIndex = activeProviderIDs.firstIndex(of: id) {
            activeProviderIDs.remove(at: existingIndex)
        } else if activeProviderIDs.count >= maximumActiveProviders {
            return
        }

        activeProviderIDs.append(id)
        providers[id] = ActiveSceneProvider(
            representedWindow: representedWindow,
            openWindow: openWindow,
            successfulRouteCompletion: successfulRouteCompletion,
            dismissesMainAfterSuccessfulRoute: dismissesMainAfterSuccessfulRoute
        )

        if let representedWindow {
            completeActivatedRouteIfMatching(representedWindow)
        }
        routingStateDidChange()
    }

    func unregisterActiveSceneProvider(id: UUID) {
        activeProviderIDs.removeAll { $0 == id }
        providers[id] = nil

        guard activeProviderIDs.isEmpty,
              let claimID = inFlightRoute?.claimID else {
            return
        }

        // Scene handoffs briefly make the old scene inactive before the target
        // provider becomes active. Give that registration one transition beat.
        providerLossTask?.cancel()
        providerLossTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self,
                  self.activeProviderIDs.isEmpty,
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

    /// Returns the bounded plain-text context associated with an agent-opened
    /// scene. The context is display-only and never becomes a link or action.
    func presentationContext(for hostedWindow: HostedPeelWindow) -> String? {
        presentationContextByWindowID[hostedWindow.id]
    }

    func clearPresentationContext(for hostedWindow: HostedPeelWindow) {
        presentationContextByWindowID[hostedWindow.id] = nil
        presentationContextOrder.removeAll { $0 == hostedWindow.id }
    }

    private func routingStateDidChange() {
        if let route = inFlightRoute, finishIfInvalid(route) {
            return
        }

        drainPendingRequests()
    }

    private func drainPendingRequests() {
        guard !isDraining,
              store?.hasResolvedAccessState == true else {
            return
        }

        isDraining = true
        defer { isDraining = false }

        while inFlightRoute == nil {
            guard let (session, pendingRequest) = claimNextPendingRequest() else {
                return
            }

            let claimID = UUID()
            inFlightRoute = InFlightRoute(
                claimID: claimID,
                session: session,
                pendingRequest: pendingRequest,
                hostedWindow: HostedPeelWindow(
                    hostKey: session.hostKey,
                    hostName: displayNameWithoutPeelPrefix(session.host.name),
                    window: pendingRequest.message.window
                ),
                context: boundedContext(pendingRequest.message.context)
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

        let alreadyOpen = scenes.isPeeledWindowOpen(route.hostedWindow)
        let provider = providerRepresenting(route.hostedWindow) ?? selectedProvider()

        guard let provider else {
            finishCurrentRoute(
                claimID: route.claimID,
                status: "declined",
                reason: "No active Peel window can open this request."
            )
            return
        }
        inFlightRoute?.successfulRouteCompletion =
            mainSceneRouteCompletion() ?? provider.successfulRouteCompletion

        if !alreadyOpen {
            guard scenes.canOpenAnotherPeeledWindow() else {
                finishCurrentRoute(
                    claimID: route.claimID,
                    status: "declined",
                    reason: "Peel's window limit has been reached."
                )
                return
            }

            scenes.reservePeeledWindowScene(
                for: route.hostedWindow,
                mode: .locked
            )
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
        } else {
            guard scenes.activatePeeledWindowIfPossible(for: route.hostedWindow) else {
                finishCurrentRoute(
                    claimID: route.claimID,
                    status: "declined",
                    reason: "Peel could not activate the requested window."
                )
                return
            }
        }

        if providerRepresenting(route.hostedWindow) != nil {
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
            route.pendingRequest.message.expiresAt - Date().timeIntervalSince1970
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

        // An "opened" result has a second full source-session validation at
        // the scene activation boundary. A failure replaces the success.
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
            _ = scenes?.closePeeledWindowScene(for: route.hostedWindow)
        }

        inFlightRoute = nil
        _ = route.session.sendAgentPresentationResult(
            for: route.pendingRequest,
            status: status,
            reason: reason
        )

        if status == "opened" {
            setPresentationContext(route.context, for: route.hostedWindow)
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

    private func revalidate(_ route: InFlightRoute) -> AgentPresentationValidation {
        guard let browser,
              browser.session(for: route.session.hostKey) === route.session else {
            return .unavailable(reason: "This request's Mac session changed.")
        }

        return route.session.revalidateAgentPresentation(route.pendingRequest)
    }

    private func setPresentationContext(
        _ context: String?,
        for hostedWindow: HostedPeelWindow
    ) {
        let key = hostedWindow.id
        presentationContextByWindowID[key] = context
        presentationContextOrder.removeAll { $0 == key }

        guard context != nil else { return }

        presentationContextOrder.append(key)
        while presentationContextOrder.count > maximumPresentationContexts {
            let evictedKey = presentationContextOrder.removeFirst()
            presentationContextByWindowID[evictedKey] = nil
        }
    }

    private func boundedContext(_ rawContext: String?) -> String? {
        guard let rawContext else { return nil }

        var result = ""
        result.reserveCapacity(min(rawContext.count, 1_000))

        for scalar in rawContext.unicodeScalars {
            let isAllowedWhitespace = scalar.value == 0x09
                || scalar.value == 0x0A
                || scalar.value == 0x0D
            if CharacterSet.controlCharacters.contains(scalar),
               !isAllowedWhitespace {
                continue
            }

            let character = String(scalar)
            guard result.count < 1_000,
                  result.utf8.count + character.utf8.count <= 4_000 else {
                break
            }
            result.append(contentsOf: character)
        }

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func selectedProvider() -> ActiveSceneProvider? {
        activeProviderIDs.reversed()
            .compactMap { providers[$0] }
            .first(where: { $0.dismissesMainAfterSuccessfulRoute })
            ?? activeProviderIDs.reversed().compactMap { providers[$0] }.first
    }

    private func mainSceneRouteCompletion() -> (() -> Void)? {
        activeProviderIDs.reversed()
            .compactMap { providers[$0] }
            .first(where: { $0.dismissesMainAfterSuccessfulRoute })?
            .successfulRouteCompletion
    }

    private func providerRepresenting(_ hostedWindow: HostedPeelWindow) -> ActiveSceneProvider? {
        activeProviderIDs.reversed().compactMap { id -> ActiveSceneProvider? in
            guard let provider = providers[id],
                  let representedWindow = provider.representedWindow,
                  windowInstance(representedWindow, matches: hostedWindow) else {
                return nil
            }
            return provider
        }.first
    }

    private func displayNameWithoutPeelPrefix(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Peel Pro on ", "Peel on "]
            where trimmed.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil {
            return String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private func isDisplayCaptureWindow(_ window: PeelWindow) -> Bool {
        let appName = window.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        return appName == "Peel Display" || appName == "Peel Pro Display"
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

private struct VisionAgentPresentationSceneProvider: ViewModifier {
    @EnvironmentObject private var coordinator: VisionAgentPresentationCoordinator
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
                openWindow(id: "peeled-window", value: request)
            },
            successfulRouteCompletion: {
                guard dismissesMainAfterSuccessfulRoute else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    dismissWindow(id: "main")
                }
            },
            dismissesMainAfterSuccessfulRoute: dismissesMainAfterSuccessfulRoute
        )
    }
}

extension View {
    func visionAgentPresentationSceneProvider(
        representedWindow: HostedPeelWindow? = nil,
        dismissesMainAfterSuccessfulRoute: Bool = false
    ) -> some View {
        modifier(
            VisionAgentPresentationSceneProvider(
                representedWindow: representedWindow,
                dismissesMainAfterSuccessfulRoute: dismissesMainAfterSuccessfulRoute
            )
        )
    }
}

struct VisionAgentPresentationContextBanner: View {
    let context: String

    var body: some View {
        Text(verbatim: context)
            .font(.caption.weight(.medium))
            .multilineTextAlignment(.leading)
            .lineLimit(4)
            .frame(maxWidth: 520, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityLabel("Agent context")
    }
}
