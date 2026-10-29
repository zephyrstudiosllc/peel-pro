//
//  iPhoneAgentPresentationCoordinator.swift
//  Peel-iPad
//

#if os(iOS)
import Combine
import SwiftUI
import UIKit

/// Routes one authenticated agent window request at a time through the
/// existing iPhone full-screen presentation binding.
///
/// The binding is only assigned after the source session has passed its normal
/// admission checks. The Host acknowledgement is delayed until the presented
/// view is active and the requested window has produced a real video frame.
@MainActor
final class IPhoneAgentPresentationCoordinator: ObservableObject {
    private struct InFlightRoute {
        let claimID: UUID
        let session: PeelHostSession
        let pendingRequest: PeelPendingAgentPresentationRequest
        let hostedWindow: HostedPeelWindow
    }

    private weak var browser: PeelClientBrowser?
    private weak var store: PeelStore?
    private var presentedWindowBinding: Binding<HostedPeelWindow?>?
    private let onRouteAvailabilityChanged: (Bool) -> Void
    private let sceneRouteID = UUID()

    private var inFlightRoute: InFlightRoute?
    private var activationTimeoutTask: Task<Void, Never>?
    private var routingCancellable: AnyCancellable?
    private var sceneDisconnectCancellable: AnyCancellable?
    private weak var boundScene: UIWindowScene?
    private var isDraining = false
    private var isSceneActive = false
    private var routeGeneration: UInt64 = 0

    @Published private(set) var isRouteRegistered = false
    @Published private var presentationContexts: [String: String] = [:]
    private var contextOrder: [String] = []

    private let sceneActivationTimeout: TimeInterval = 5
    private let maxContextScalars = 1000
    private let maxContextBytes = 4000

    init(
        browser: PeelClientBrowser,
        onRouteAvailabilityChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.browser = browser
        self.onRouteAvailabilityChanged = onRouteAvailabilityChanged

        routingCancellable = browser.$agentPresentationRoutingVersion
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.routingStateDidChange()
            }
    }

    deinit {
        let route = sceneRouteID
        Task { @MainActor in
            PeelPhoneSceneAvailability.setRegistered(false, route: route)
        }
    }

    func bindScene(_ scene: UIWindowScene) {
        boundScene = scene
        guard sceneDisconnectCancellable == nil else { return }
        sceneDisconnectCancellable = NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self, let disconnected = notification.object as? UIWindowScene,
                      disconnected === self.boundScene else { return }
                self.unregisterPhoneRoute()
            }
    }

    /// Supplies the same StoreKit access state used by ContentView's manual
    /// phone opening path. The reference is bound only while the real phone
    /// route is present; no access state is persisted here.
    func bindStore(_ store: PeelStore) {
        self.store = store
    }

    /// Registers the real presentation binding owned by ContentView.
    /// Registration is separate from user opt-in; the caller supplies the
    /// shared gate callback so a phone capability cannot be advertised before
    /// this route exists.
    func registerPhoneRoute(
        presentedWindow: Binding<HostedPeelWindow?>,
        scenePhase: ScenePhase
    ) {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }

        presentedWindowBinding = presentedWindow
        isSceneActive = scenePhase == .active
        setRouteRegistered(isSceneActive)
    }

    func unregisterPhoneRoute() {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }

        isSceneActive = false
        setRouteRegistered(false)
        presentedWindowBinding = nil
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }

        isSceneActive = phase == .active
        setRouteRegistered(isSceneActive && presentedWindowBinding != nil)
    }

    /// Called by the full-screen cover onDismiss callback. A pending route that
    /// was dismissed before its first frame is declined; after an opened ACK,
    /// this only permits the next queued request to drain.
    func phonePresentationDidDismiss() {
        if let route = inFlightRoute {
            finishCurrentRoute(
                claimID: route.claimID,
                status: "declined",
                reason: "The iPhone window was dismissed before it became ready."
            )
        } else {
            drainPendingRequests()
        }
    }

    /// Reports actual view lifecycle and stream readiness from the full-screen
    /// content wrapper. Assignment of the full-screen binding alone never
    /// acknowledges a request.
    func phoneWindowStateChanged(
        hostedWindow: HostedPeelWindow,
        isActive: Bool,
        streamReady: Bool
    ) {
        guard let route = inFlightRoute,
              windowInstance(hostedWindow, matches: route.hostedWindow) else {
            return
        }

        guard isRouteRegistered, isSceneActive else {
            finishCurrentRoute(
                claimID: route.claimID,
                status: "unavailable",
                reason: "Phone presentation is unavailable while Peel Pro is inactive."
            )
            return
        }

        guard isActive else {
            finishCurrentRoute(
                claimID: route.claimID,
                status: "declined",
                reason: "The iPhone window did not remain active."
            )
            return
        }

        // Recheck the source session before waiting for the first frame. A
        // disconnect or opt-out must abort the pending route immediately;
        // stream readiness alone is intentionally not an admission signal.
        switch revalidate(route) {
        case .accepted:
            guard streamReady else { return }
            finishCurrentRoute(claimID: route.claimID, status: "opened", reason: nil)
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
    }

    func phoneWindowDidDisappear(_ hostedWindow: HostedPeelWindow) {
        guard let route = inFlightRoute,
              windowInstance(hostedWindow, matches: route.hostedWindow) else {
            return
        }

        finishCurrentRoute(
            claimID: route.claimID,
            status: "declined",
            reason: "The iPhone window disappeared before it became ready."
        )
    }

    func presentationContext(for window: HostedPeelWindow) -> String? {
        presentationContexts[window.id]
    }

    func clearPresentationContext(for window: HostedPeelWindow) {
        presentationContexts[window.id] = nil
        contextOrder.removeAll { $0 == window.id }
    }

    private func setRouteRegistered(_ registered: Bool) {
        guard isRouteRegistered != registered else {
            if registered { drainPendingRequests() }
            return
        }

        isRouteRegistered = registered
        PeelPhoneSceneAvailability.setRegistered(registered, route: sceneRouteID)
        if !registered {
            if let route = inFlightRoute {
                finishCurrentRoute(
                    claimID: route.claimID,
                    status: "unavailable",
                    reason: "Phone presentation is unavailable while Peel Pro is inactive."
                )
            }
            if !PeelPhoneSceneAvailability.isAvailable {
                declinePendingRequests(
                    reason: "Phone presentation is unavailable while Peel Pro is inactive."
                )
            }
        }

        onRouteAvailabilityChanged(registered)
        browser?.refreshAgentPresentationCapabilities()

        if registered {
            drainPendingRequests()
        }
    }

    private func routingStateDidChange() {
        guard isRouteRegistered, isSceneActive else { return }

        if let route = inFlightRoute {
            switch revalidate(route) {
            case .accepted:
                break
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
            return
        }

        drainPendingRequests()
    }

    private func drainPendingRequests() {
        guard isRouteRegistered,
              isSceneActive,
              presentedWindowBinding != nil,
              presentedWindowBinding?.wrappedValue == nil,
              inFlightRoute == nil,
              !isDraining else {
            return
        }

        isDraining = true
        defer { isDraining = false }

        while inFlightRoute == nil,
              presentedWindowBinding?.wrappedValue == nil {
            guard let (session, pendingRequest) = claimNextPendingRequest() else {
                return
            }

            let candidate = InFlightRoute(
                claimID: UUID(),
                session: session,
                pendingRequest: pendingRequest,
                hostedWindow: HostedPeelWindow(
                    hostKey: session.hostKey,
                    hostName: displayNameWithoutPeelPrefix(session.host.name),
                    window: pendingRequest.message.window
                )
            )

            switch revalidate(candidate) {
            case .accepted:
                routeGeneration &+= 1
                let route = candidate
                inFlightRoute = route

                session.recordFocusedWindowId(route.hostedWindow.window.windowId)
                session.setActiveWindow(route.hostedWindow.window.windowId)
                presentedWindowBinding?.wrappedValue = route.hostedWindow

                guard presentedWindowBinding?.wrappedValue != nil else {
                    finishCurrentRoute(
                        claimID: route.claimID,
                        status: "declined",
                        reason: "Peel could not present the requested iPhone window."
                    )
                    return
                }

                scheduleActivationTimeout(for: route)

            case .declined(let reason):
                session.sendAgentPresentationResult(
                    for: pendingRequest,
                    status: "declined",
                    reason: reason
                )

            case .unavailable(let reason):
                session.sendAgentPresentationResult(
                    for: pendingRequest,
                    status: "unavailable",
                    reason: reason
                )
            }
        }
    }

    private func claimNextPendingRequest()
        -> (PeelHostSession, PeelPendingAgentPresentationRequest)? {
        guard let browser else { return nil }

        for session in browser.sessionsByHostKey.values.sorted(by: {
            $0.hostKey.rawValue < $1.hostKey.rawValue
        }) {
            if let pendingRequest = session.claimPendingAgentPresentationRequest() {
                return (session, pendingRequest)
            }
        }

        return nil
    }

    private func declinePendingRequests(reason: String) {
        guard let browser else { return }

        for session in browser.sessionsByHostKey.values {
            while let pendingRequest = session.claimPendingAgentPresentationRequest() {
                session.sendAgentPresentationResult(
                    for: pendingRequest,
                    status: "unavailable",
                    reason: reason
                )
            }
        }
    }

    private func scheduleActivationTimeout(for route: InFlightRoute) {
        activationTimeoutTask?.cancel()
        let remainingFreshness = max(
            0,
            route.pendingRequest.message.expiresAt -
                Date().timeIntervalSince1970
        )
        let delay = min(sceneActivationTimeout, remainingFreshness)
        let generation = routeGeneration

        activationTimeoutTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }

            guard let self,
                  self.routeGeneration == generation,
                  self.inFlightRoute?.claimID == route.claimID else {
                return
            }

            self.finishCurrentRoute(
                claimID: route.claimID,
                status: "declined",
                reason: "The iPhone window did not become ready."
            )
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
        inFlightRoute = nil
        routeGeneration &+= 1

        if status != "opened",
           let presented = presentedWindowBinding?.wrappedValue,
           windowInstance(presented, matches: route.hostedWindow) {
            presentedWindowBinding?.wrappedValue = nil
        }

        _ = route.session.sendAgentPresentationResult(
            for: route.pendingRequest,
            status: status,
            reason: reason
        )

        if status == "opened" {
            recordContext(
                route.pendingRequest.message.context,
                for: route.hostedWindow
            )
        }

        drainPendingRequests()
    }

    private func revalidate(_ route: InFlightRoute) -> AgentPresentationValidation {
        guard let browser,
              browser.session(for: route.session.hostKey) === route.session else {
            return .unavailable(reason: "This request's computer session changed.")
        }

        switch route.session.revalidateAgentPresentation(route.pendingRequest) {
        case .accepted(let normalizedRequestID):
            return .accepted(normalizedRequestID: normalizedRequestID)
        case .declined(let reason):
            return .declined(reason: reason)
        case .unavailable(let reason):
            return .unavailable(reason: reason)
        }
    }

    private func isDisplayCaptureWindow(_ window: PeelWindow) -> Bool {
        let appName = window.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        return appName == "Peel Display" || appName == "Peel Pro Display"
    }

    private func recordContext(_ raw: String?, for window: HostedPeelWindow) {
        clearPresentationContext(for: window)
        guard let raw else { return }

        let plainScalars = raw.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) ||
                $0.value == 9 ||
                $0.value == 10
        }
        let plain = String(
            plainScalars
                .prefix(maxContextScalars)
                .reduce(into: "") { result, scalar in
                    result.unicodeScalars.append(scalar)
                }
        )
        let context = plain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !context.isEmpty,
              context.utf8.count <= maxContextBytes else {
            return
        }

        presentationContexts[window.id] = context
        contextOrder.append(window.id)
        while contextOrder.count > 32 {
            presentationContexts[contextOrder.removeFirst()] = nil
        }
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

/// Wraps the existing PeeledWindowView so the coordinator can observe the
/// actual full-screen view and the first decoded video frame.
struct IPhoneAgentPresentationWindow: View {
    let hostedWindow: HostedPeelWindow

    @EnvironmentObject private var browser: PeelClientBrowser
    @EnvironmentObject private var coordinator: IPhoneAgentPresentationCoordinator
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let session = browser.session(for: hostedWindow.hostKey) {
                IPhoneDevelopmentWorkspace(
                    hostedWindow: hostedWindow, session: session,
                    presentationContext: coordinator.presentationContext(for: hostedWindow),
                    dismissPresentationContext: { coordinator.clearPresentationContext(for: hostedWindow) }
                )
                .id(ObjectIdentifier(session))
                .onAppear {
                    reportState(for: session)
                }
                .onChange(of: scenePhase) { _, _ in
                    deferStateReport(for: session)
                }
                .onReceive(session.$videoReadyWindowIds) { _ in
                    deferStateReport(for: session)
                }
                .onReceive(session.$isConnectionReady) { _ in
                    deferStateReport(for: session)
                }
                .onReceive(session.$windows) { _ in
                    deferStateReport(for: session)
                }
                .onDisappear {
                    coordinator.phoneWindowDidDisappear(hostedWindow)
                }
            } else {
                Color.clear
                    .onAppear {
                        coordinator.phoneWindowDidDisappear(hostedWindow)
                    }
            }
        }
    }

    private func deferStateReport(for session: PeelHostSession) {
        // @Published emits from willSet. Yield one MainActor turn so the
        // coordinator reads the committed frame/connection/window state.
        Task { @MainActor in
            await Task.yield()
            reportState(for: session)
        }
    }

    private func reportState(for session: PeelHostSession) {
        let isActive = scenePhase == .active
        let streamReady = isActive &&
            session.isConnectionReady &&
            session.videoReadyWindowIds.contains(hostedWindow.window.windowId) &&
            session.currentWindowInstanceMatches(hostedWindow.window)

        coordinator.phoneWindowStateChanged(
            hostedWindow: hostedWindow,
            isActive: isActive,
            streamReady: streamReady
        )
    }
}
#endif
