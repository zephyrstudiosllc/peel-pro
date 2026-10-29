//
//  PeelGameControllerInput.swift
//  Peel
//
//  Game controller pointer, scroll, click and navigation-key input for peeled
//  windows on iPhone, iPad and Vision. Uses the existing per-host PeelHostSession
//  mouse and keyboard transport only. Decisions live in PeelGameControllerPolicy.
//

import SwiftUI
import UIKit
import Combine
import Network
import GameController

/// One app-wide owner for game controller input. Exactly one eligible peeled
/// window receives controller output, and only while it is its exact host
/// session's active, connected, streaming window on the claimed control connection.
///
/// Mapping:
/// - Extended gamepad (DualSense, Xbox, MFi): left stick moves the pointer, right
///   stick scrolls, Cross/A clicks, Circle/B right-clicks, D-pad sends arrow keys,
///   Triangle/Y sends Return, Square/X sends Escape.
/// - Spatial controller (PlayStation VR2 Sense, each hand independently, Vision
///   only): stick moves the pointer, stick while holding grip scrolls, trigger or
///   the mapped A element clicks, the mapped B element right-clicks.
///
/// Buttons are single click or key-press messages; no mouse button or key is ever
/// held on the host, so ownership loss needs no release message. Dragging is not
/// mapped. After any owner, target, connection or readiness change, held buttons
/// are ignored and each stick must return to neutral before acting.
@MainActor
final class PeelGameControllerInput: ObservableObject {
    static let shared = PeelGameControllerInput()

    @Published private(set) var ownerID: UUID?
    @Published private(set) var hasSupportedController = false
    @Published private(set) var hasSpatialController = false
    /// The owner whose scene may route gamepad events to GameController: a claim
    /// exists, a supported controller is connected and no guide is open. Views
    /// combine it with their own live scene eligibility. Published only on change.
    @Published private(set) var routingOwnerID: UUID?

    private struct Target {
        let owner: UUID
        weak var session: PeelHostSession?
        weak var connection: NWConnection?
        weak var scene: UIWindowScene?
        var window: PeelWindow
        var admission: () -> Bool
    }

    private struct Entry {
        let controller: GCController
        let source: UInt64
        var restoreHandlers: [() -> Void] = []
    }

    private var target: Target?
    private var policy = PeelGameControllerPolicy()
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var nextSource: UInt64 = 0
    private var handlersInstalled = false
    /// Callback generation the installed handlers were registered under.
    private var installedGeneration: UInt64?
    private lazy var relay = PeelControllerCallbackRelay(
        schedule: { work in DispatchQueue.main.async(execute: work) },
        deliver: { [weak self] token, button, pressed in
            self?.buttonChanged(token, button: button, pressed: pressed)
        }
    )
    private var observerTokens: [NSObjectProtocol] = []
    private var pollTask: Task<Void, Never>?

    private let tickInterval: Duration = .nanoseconds(16_666_667)

    private init() {
        let center = NotificationCenter.default
        observerTokens = [
            center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshControllers() }
            },
            center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshControllers() }
            },
            center.addObserver(forName: UIScene.willDeactivateNotification, object: nil, queue: .main) { [weak self] note in
                let scene = note.object as? UIScene
                MainActor.assumeIsolated { self?.sceneStoppedReceivingInput(scene) }
            },
            center.addObserver(forName: UIScene.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] note in
                let scene = note.object as? UIScene
                MainActor.assumeIsolated { self?.sceneStoppedReceivingInput(scene) }
            }
        ]
        refreshControllers()
    }

    // MARK: - Ownership

    /// Offer a scene's presented window as the controller target. `session` must
    /// be the window's exact owning session (no selected-session fallback for keyed
    /// windows). `admission` carries the view's live gates (scene key/foreground,
    /// selected visible pane, immersive state) and is rechecked every tick. A
    /// different owner replaces a live target only when `preempt` is set.
    func offer(
        owner: UUID,
        session: PeelHostSession,
        window: PeelWindow,
        scene: UIWindowScene?,
        preempt: Bool,
        admission: @escaping () -> Bool
    ) {
        let lifetime = Self.lifetime(of: window)
        // The listed window must be the same app lifetime as the offered one; its
        // current title and size are adopted without fencing.
        guard session.isConnectionReady,
              let connection = session.connection,
              session.activeWindowId == window.windowId,
              let listed = session.windows.first(where: { $0.windowId == window.windowId }),
              Self.lifetime(of: listed) == lifetime,
              session.currentWindowInstanceMatches(listed),
              admission() else {
            release(owner: owner)
            return
        }

        let key = PeelGameControllerPolicy.TargetKey(
            hostKey: session.hostKey.rawValue,
            windowId: window.windowId,
            lifetime: lifetime,
            connection: ObjectIdentifier(connection)
        )
        let currentIsLive = target.map(isLive) ?? false
        let result = policy.offer(
            PeelGameControllerPolicy.Claim(owner: owner, target: key),
            preempt: preempt,
            currentIsLive: currentIsLive
        )

        switch result {
        case .rejected:
            return
        case .unchanged:
            target?.window = listed
            target?.admission = admission
            if let scene { target?.scene = scene }
        case .installed:
            target = Target(
                owner: owner,
                session: session,
                connection: connection,
                scene: scene,
                window: listed,
                admission: admission
            )
            // Arm buttons that are already released so a press right after the
            // switch is not lost; held buttons stay disarmed.
            policy.observeSources(entries.values.map(sample))
            if ownerID != owner { ownerID = owner }
        }
        updateRunning()
        syncCallbackRegistrations()
        updateRouting()
    }

    func release(owner: UUID) {
        guard policy.release(owner: owner) else { return }
        target = nil
        ownerID = nil
        updateRunning()
        syncCallbackRegistrations()
        updateRouting()
    }

    /// Opening a controller guide anywhere in the app revokes controller output
    /// at once: the policy fences and callbacks registered before are retired.
    /// The claim is kept; output resumes only after the last guide closes and
    /// buttons/sticks have been released.
    func suspendForHelp(_ id: UUID) {
        policy.suspend(id)
        syncCallbackRegistrations()
        updateRouting()
    }

    func resumeAfterHelp(_ id: UUID) {
        guard policy.suspensions.contains(id) else { return }
        policy.resume(id)
        updateRouting()
    }

    private func updateRouting() {
        let routing = (hasSupportedController && !policy.isSuspended) ? target?.owner : nil
        if routingOwnerID != routing { routingOwnerID = routing }
    }

    private static func lifetime(of window: PeelWindow) -> PeelControllerWindowLifetime {
        PeelControllerWindowLifetime(appName: window.appName, appLaunch: window.appLaunchTimeIntervalSince1970)
    }

    private func releaseCurrentTarget() {
        if let owner = target?.owner { release(owner: owner) }
    }

    private func sceneStoppedReceivingInput(_ scene: UIScene?) {
        guard let scene, let targetScene = target?.scene, targetScene === scene else { return }
        releaseCurrentTarget()
    }

    /// The exact session and control connection captured at offer time. Nil means
    /// the target is permanently gone: a replaced or closed connection, or the
    /// browser no longer maps this host key to this session.
    private func exactSession(for target: Target) -> PeelHostSession? {
        guard let session = target.session,
              let connection = target.connection,
              session.connection === connection,
              session.browser?.session(for: session.hostKey) === session else {
            return nil
        }
        return session
    }

    private func isLive(_ target: Target) -> Bool {
        guard let session = exactSession(for: target) else { return false }
        return session.isConnectionReady &&
            session.activeWindowId == target.window.windowId &&
            session.currentWindowInstanceMatches(target.window) &&
            target.admission()
    }

    /// Readiness for the claimed window lifetime. A lost session/connection,
    /// replaced window lifetime or lost scene/pane admission releases the target
    /// (the view re-offers when eligible). Other failures are transient and fence.
    /// Requires current stream intent; a retained snapshot is not input authority.
    private func readyTarget() -> (session: PeelHostSession, window: PeelWindow)? {
        guard let current = target else { return nil }
        guard let session = exactSession(for: current), current.admission() else {
            releaseCurrentTarget()
            return nil
        }

        let windowId = current.window.windowId
        if let listed = session.windows.first(where: { $0.windowId == windowId }) {
            // Compared with the lifetime claimed at offer time, not a refreshed copy.
            guard let claimed = policy.claim?.target.lifetime,
                  Self.lifetime(of: listed) == claimed else {
                releaseCurrentTarget()
                return nil
            }
            // Same lifetime: adopt the current title and size, never fencing.
            target?.window = listed
        }

        guard let window = target?.window,
              session.currentWindowInstanceMatches(window),
              session.isClientVisible,
              session.isConnectionReady,
              session.activeWindowId == windowId,
              session.streamStatus(for: windowId) == .active,
              session.videoReadyWindowIds.contains(windowId) || session.snapshotCGImages[windowId] != nil else {
            return nil
        }
        return (session, window)
    }

    // MARK: - Controllers

    private func refreshControllers() {
        let current = GCController.controllers().filter(Self.isSupported)
        let currentIDs = Set(current.map(ObjectIdentifier.init))

        for (id, entry) in entries where !currentIDs.contains(id) {
            entry.restoreHandlers.forEach { $0() }
            policy.removeSource(entry.source)
            entries[id] = nil
        }
        for controller in current where entries[ObjectIdentifier(controller)] == nil {
            nextSource &+= 1
            var entry = Entry(controller: controller, source: nextSource)
            policy.addSource(entry.source)
            if handlersInstalled {
                entry.restoreHandlers = installHandlers(on: controller, token: callbackToken(for: entry.source))
            }
            entries[ObjectIdentifier(controller)] = entry
        }

        let hasController = !entries.isEmpty
        if hasSupportedController != hasController {
            hasSupportedController = hasController
        }
        let hasSpatial = entries.values.contains { Self.isSpatial($0.controller) }
        if hasSpatialController != hasSpatial {
            hasSpatialController = hasSpatial
        }
        updateRunning()
        updateRouting()
    }

    private static func isSpatial(_ controller: GCController) -> Bool {
#if os(visionOS)
        controller.productCategory == GCProductCategorySpatialController
#else
        false
#endif
    }

    private static func isSupported(_ controller: GCController) -> Bool {
        isSpatial(controller) || controller.extendedGamepad != nil
    }

    /// Polling and pressed-state callbacks run only while a target exists and a
    /// supported controller is connected. Nothing is intercepted otherwise.
    private func updateRunning() {
        let shouldRun = target != nil && !entries.isEmpty

        if shouldRun, !handlersInstalled {
            handlersInstalled = true
            installAllHandlers()
        } else if !shouldRun, handlersInstalled {
            handlersInstalled = false
            retireAllHandlers()
        }

        if shouldRun, pollTask == nil {
            let interval = tickInterval
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled, let self else { return }
                    self.tick()
                }
            }
        } else if !shouldRun, let pollTask {
            pollTask.cancel()
            self.pollTask = nil
        }
    }

    // MARK: - Sampling

    private func sample(_ entry: Entry) -> PeelControllerSourceSample {
        let controller = entry.controller
#if os(visionOS)
        if Self.isSpatial(controller) {
            let input = controller.input
            var sticks: [PeelControllerSourceSample.Stick] = []
            if let stick = input.dpads[.thumbstick] {
                let gripHeld = input.buttons[.grip]?.pressedInput.isPressed == true
                sticks.append(.init(
                    index: 0,
                    vector: PeelControllerVector(x: Double(stick.xAxis.value), y: Double(stick.yAxis.value)),
                    role: gripHeld ? .scroll : .pointer
                ))
            }
            return PeelControllerSourceSample(source: entry.source, sticks: sticks, held: heldButtons(controller))
        }
#endif
        guard let gamepad = controller.extendedGamepad else {
            return PeelControllerSourceSample(source: entry.source, sticks: [], held: [])
        }
        return PeelControllerSourceSample(
            source: entry.source,
            sticks: [
                .init(
                    index: 0,
                    vector: PeelControllerVector(
                        x: Double(gamepad.leftThumbstick.xAxis.value),
                        y: Double(gamepad.leftThumbstick.yAxis.value)
                    ),
                    role: .pointer
                ),
                .init(
                    index: 1,
                    vector: PeelControllerVector(
                        x: Double(gamepad.rightThumbstick.xAxis.value),
                        y: Double(gamepad.rightThumbstick.yAxis.value)
                    ),
                    role: .scroll
                )
            ],
            held: heldButtons(controller)
        )
    }

    private func heldButtons(_ controller: GCController) -> Set<PeelControllerButton> {
        var held: Set<PeelControllerButton> = []
#if os(visionOS)
        if Self.isSpatial(controller) {
            for (element, button) in Self.spatialBindings(controller.input)
            where element.pressedInput.isPressed {
                held.insert(button)
            }
            return held
        }
#endif
        guard let gamepad = controller.extendedGamepad else { return held }
        for (element, button) in Self.gamepadBindings(gamepad) where element.isPressed {
            held.insert(button)
        }
        return held
    }

#if os(visionOS)
    /// Apple maps Sense `.a` to Cross (right) / Square (left) and `.b` to
    /// Circle (right) / Triangle (left); both halves share these semantics.
    private static func spatialBindings(_ input: GCControllerLiveInput) -> [(any GCButtonElement, PeelControllerButton)] {
        var bindings: [(any GCButtonElement, PeelControllerButton)] = []
        if let trigger = input.buttons[.trigger] { bindings.append((trigger, .primaryClick)) }
        if let a = input.buttons[.a] { bindings.append((a, .primaryClick)) }
        if let b = input.buttons[.b] { bindings.append((b, .secondaryClick)) }
        return bindings
    }
#endif

    private static func gamepadBindings(_ gamepad: GCExtendedGamepad) -> [(GCControllerButtonInput, PeelControllerButton)] {
        [
            (gamepad.buttonA, .primaryClick),
            (gamepad.buttonB, .secondaryClick),
            (gamepad.buttonY, .enter),
            (gamepad.buttonX, .escape),
            (gamepad.dpad.up, .up),
            (gamepad.dpad.down, .down),
            (gamepad.dpad.left, .left),
            (gamepad.dpad.right, .right)
        ]
    }

    // MARK: - Pressed-state callbacks

    private func callbackToken(for source: UInt64) -> PeelControllerCallbackToken {
        PeelControllerCallbackToken(source: source, generation: installedGeneration ?? policy.callbackGeneration)
    }

    private func installAllHandlers() {
        installedGeneration = policy.callbackGeneration
        for (id, entry) in entries {
            entries[id]?.restoreHandlers = installHandlers(on: entry.controller, token: callbackToken(for: entry.source))
        }
    }

    private func retireAllHandlers() {
        installedGeneration = nil
        for (id, entry) in entries {
            entry.restoreHandlers.forEach { $0() }
            entries[id]?.restoreHandlers = []
        }
    }

    /// Every fence (claim change, release, readiness loss) and readiness regain
    /// advances the policy's callback generation. Handlers registered under an
    /// older generation are retired and replaced so their late deliveries are
    /// rejected by token before touching button state.
    private func syncCallbackRegistrations() {
        guard handlersInstalled, installedGeneration != policy.callbackGeneration else { return }
        retireAllHandlers()
        installAllHandlers()
    }

    /// Pressed-edge callbacks catch presses shorter than one poll. Existing
    /// handlers are chained and restored when the registration is retired.
    private func installHandlers(on controller: GCController, token: PeelControllerCallbackToken) -> [() -> Void] {
        var restore: [() -> Void] = []
        let relay = self.relay
#if os(visionOS)
        if Self.isSpatial(controller) {
            for (element, button) in Self.spatialBindings(controller.input) {
                let pressedInput = element.pressedInput
                let previous = pressedInput.pressedDidChangeHandler
                pressedInput.pressedDidChangeHandler = { element, state, pressed in
                    previous?(element, state, pressed)
                    relay.post(token, button, pressed: pressed)
                }
                restore.append { pressedInput.pressedDidChangeHandler = previous }
            }
            return restore
        }
#endif
        guard let gamepad = controller.extendedGamepad else { return restore }
        for (element, button) in Self.gamepadBindings(gamepad) {
            let previous = element.pressedChangedHandler
            element.pressedChangedHandler = { input, value, pressed in
                previous?(input, value, pressed)
                relay.post(token, button, pressed: pressed)
            }
            restore.append { element.pressedChangedHandler = previous }
        }
        return restore
    }

    /// Relay delivery on main. Stale registrations, a missing target or a removed
    /// source are rejected before any button state changes.
    private func buttonChanged(_ token: PeelControllerCallbackToken, button: PeelControllerButton, pressed: Bool) {
        guard handlersInstalled,
              target != nil,
              !policy.isSuspended,
              token.generation == installedGeneration,
              let entry = entries.values.first(where: { $0.source == token.source }) else { return }
        // Two physical elements can share one action (trigger and A). Releasing
        // one only rearms when no alias is still held.
        let isHeld = pressed || heldButtons(entry.controller).contains(button)
        policy.callbackChanged(token, button: button, pressed: isHeld)
    }

    // MARK: - Tick

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let samples = entries.values.map(sample)
        let ready = readyTarget()
        let aspect = ready.map { contentAspect(session: $0.session, window: $0.window) } ?? 16.0 / 9.0

        let frame = policy.tick(
            now: now,
            ready: ready != nil,
            sources: samples,
            aspect: aspect,
            pointerOrigin: { ready.map { sharedPointer(session: $0.session, window: $0.window) } ?? PeelControllerPoint(x: 0.5, y: 0.5) }
        )
        syncCallbackRegistrations()
        guard let ready, !frame.isEmpty else { return }
        let session = ready.session
        let window = ready.window

        if let next = frame.moveTo {
            let norm = CGPoint(x: next.x, y: next.y)
            session.showSharedCursor(for: window.windowId, norm: norm, mode: .hover)
            session.sendMouseMove(on: window, normX: next.x, normY: next.y)
        }

        if let scroll = frame.scroll, isInputReady(session: session, window: window) {
            session.sendScroll(on: window, deltaX: scroll.x, deltaY: scroll.y)
        }

        for button in frame.presses {
            perform(button, session: session, window: window)
        }
    }

    private func perform(_ button: PeelControllerButton, session: PeelHostSession, window: PeelWindow) {
        guard isInputReady(session: session, window: window) else { return }

        switch button {
        case .primaryClick, .secondaryClick:
            let isRight = button == .secondaryClick
            let point = policy.pointerForClick { sharedPointer(session: session, window: window) }
            let norm = CGPoint(x: point.x, y: point.y)
            session.showSharedCursor(for: window.windowId, norm: norm, mode: isRight ? .rightClick : .click)
            session.sendClick(on: window, normX: point.x, normY: point.y, button: isRight ? "right" : "left")
        case .enter, .escape, .up, .down, .left, .right:
            // Keyboard messages target the session's active window; readiness has
            // already required it to be this window, host-confirmed.
            guard session.activeWindowId == window.windowId,
                  let command = Self.keyboardCommand(for: button) else { return }
            session.sendKeyboardCommand(command)
        }
    }

    private static func keyboardCommand(for button: PeelControllerButton) -> KeyboardCommand? {
        switch button {
        case .enter: return .enter
        case .escape: return .escape
        case .up: return .upArrow
        case .down: return .downArrow
        case .left: return .leftArrow
        case .right: return .rightArrow
        case .primaryClick, .secondaryClick: return nil
        }
    }

    /// Mirrors the views' readiness gate for clicks, scrolls and keys: the host
    /// must have confirmed focus, except for display capture streams.
    private func isInputReady(session: PeelHostSession, window: PeelWindow) -> Bool {
        if window.appName.trimmingCharacters(in: .whitespacesAndNewlines) == "Peel Display" {
            return true
        }
        guard session.isHostConfirmedActiveWindow(window.windowId) else {
            session.requestHostFocusForWindow(window.windowId)
            return false
        }
        return true
    }

    private func sharedPointer(session: PeelHostSession, window: PeelWindow) -> PeelControllerPoint {
        let fallback = session.lastMouseMoveNormByWindow[window.windowId] ?? CGPoint(x: 0.5, y: 0.5)
        let norm = session.currentSharedCursorNorm(for: window.windowId, fallback: fallback)
        return PeelControllerPoint(x: Double(norm.x), y: Double(norm.y))
    }

    private func contentAspect(session: PeelHostSession, window: PeelWindow) -> Double {
        if let size = session.videoContentSize(for: window.windowId), size.width > 0, size.height > 0 {
            return Double(size.width / size.height)
        }
        return Double(window.width) / Double(max(window.height, 1))
    }
}

/// Routes game controller events to the Game Controller framework for the owning
/// scene only. Without it, visionOS converts controller buttons into pinches at the
/// gaze location, which would double-click alongside the controller pointer.
/// Disabled scenes leave the system's default controller behavior untouched.
struct PeelGameControllerEventInteractionAnchor: UIViewRepresentable {
    let isEnabled: Bool

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.isUserInteractionEnabled = false
        view.isEnabled = isEnabled
        return view
    }

    func updateUIView(_ uiView: AnchorView, context: Context) {
        uiView.isEnabled = isEnabled
    }

    static func dismantleUIView(_ uiView: AnchorView, coordinator: ()) {
        uiView.isEnabled = false
    }

    final class AnchorView: UIView {
        private let interaction: GCEventInteraction = {
            let interaction = GCEventInteraction()
            interaction.handledEventTypes = .gamepad
            return interaction
        }()
        private weak var installedOn: UIView?

        var isEnabled = false {
            didSet { reconcile() }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            reconcile()
        }

        private func reconcile() {
            let desired: UIView? = isEnabled ? window : nil
            guard installedOn !== desired else { return }
            installedOn?.removeInteraction(interaction)
            installedOn = nil
            if let desired {
                desired.addInteraction(interaction)
                installedOn = desired
            }
        }
    }
}

/// Tappable controller mapping help. Shown while a supported controller is
/// connected; readable by touch, pointer, gaze and VoiceOver.
struct PeelGameControllerHelpButton: View {
    @ObservedObject private var input = PeelGameControllerInput.shared
    let ownerID: UUID
    var size: CGFloat = 42

    @State private var isPresented = false
    /// This button's own guide suspension; each instance holds at most one.
    @State private var suspensionID = UUID()

    private var isOwner: Bool { input.ownerID == ownerID }

    var body: some View {
        Button {
            // Revoke controller output before the guide is shown, not on a later render.
            input.suspendForHelp(suspensionID)
            isPresented = true
        } label: {
            Image(systemName: "gamecontroller.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(isOwner ? Color.accentColor : Color.secondary)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .hoverEffect()
        .accessibilityLabel("Controller controls")
        .accessibilityValue(isOwner ? "Controlling this window" : "Not controlling this window")
        .accessibilityHint("Shows what each controller button does")
        .popover(isPresented: $isPresented) {
            PeelGameControllerHelpContent(
                isOwner: isOwner,
                showsSpatial: Self.supportsSpatial
            )
            .presentationCompactAdaptation(.popover)
            .onDisappear { input.resumeAfterHelp(suspensionID) }
        }
        .onChange(of: isPresented) { _, presented in
            if !presented { input.resumeAfterHelp(suspensionID) }
        }
        .onDisappear {
            isPresented = false
            input.resumeAfterHelp(suspensionID)
        }
    }

    private static var supportsSpatial: Bool {
#if os(visionOS)
        true
#else
        false
#endif
    }
}

private struct PeelGameControllerHelpContent: View {
    let isOwner: Bool
    let showsSpatial: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Game Controller")
                        .font(.headline)
                    Text(isOwner
                         ? "Controlling this window."
                         : "Use this window to give it the controller.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                section("DualSense, Xbox or other controller", rows: [
                    ("Left stick", "Move pointer"),
                    ("Right stick", "Scroll"),
                    ("Cross / A", "Click"),
                    ("Circle / B", "Right-click"),
                    ("D-pad", "Arrow keys"),
                    ("Triangle / Y", "Return"),
                    ("Square / X", "Escape")
                ])

                if showsSpatial {
                    section("PlayStation VR2 Sense, either hand", rows: [
                        ("Stick", "Move pointer"),
                        ("Grip + stick", "Scroll"),
                        ("Trigger, Cross or Square", "Click"),
                        ("Circle or Triangle", "Right-click")
                    ])
                }

                Text("Buttons send single clicks and key presses. Drag with touch, a trackpad or a mouse.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
        }
        .frame(idealWidth: 320, maxWidth: 360, maxHeight: 520)
    }

    private func section(_ title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            ForEach(rows, id: \.0) { control, action in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(control)
                        .font(.subheadline.weight(.medium))
                        .frame(minWidth: 120, alignment: .leading)
                    Text(action)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
