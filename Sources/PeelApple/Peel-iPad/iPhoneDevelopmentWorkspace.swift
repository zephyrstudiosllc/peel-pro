import SwiftUI
import UIKit

/// A phone workspace uses the existing paired Mac streams. Its two views keep
/// their identities as the window resizes; only the visible, selected pane owns
/// input. No hardware model, screen orientation, or fold angle is assumed.
struct IPhoneDevelopmentWorkspace: View {
    let hostedWindow: HostedPeelWindow
    @ObservedObject var session: PeelHostSession
    var presentationContext: String? = nil
    var dismissPresentationContext: () -> Void = {}
    var onDone: (() -> Void)? = nil
    @ObservedObject private var workspaceStreams = PeelPhoneWorkspaceStreams.shared

    @EnvironmentObject private var scenes: SceneCoordinator
    @EnvironmentObject private var store: PeelStore
    @EnvironmentObject private var browser: PeelClientBrowser
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var admitted = false
    @State private var showingProPaywall = false
    @State private var pendingCompanionPaywall = false
    @State private var showingWindowCapacityAlert = false
    @State private var pendingCapacityAlert = false
    @State private var companionWindow: HostedPeelWindow?
    @State private var selectedPane: PeelPhoneWorkspacePane = .primary
    @State private var showingWindowPicker = false
    @State private var showingWatchCompanion = false
    @State private var streamOwnerID = UUID()
    @State private var visiblePanes: Set<PeelPhoneWorkspacePane> = []
    @State private var lifetime = PeelPhoneWorkspaceLifetime()
    @State private var currentScene: UIWindowScene?
    @State private var sceneInputVersion = 0

    private var primaryWindow: HostedPeelWindow { refreshedMetadata(for: hostedWindow) }

    private var distinctCompanion: HostedPeelWindow? {
        guard let companionWindow,
              companionWindow.window.windowId != hostedWindow.window.windowId else { return nil }
        return refreshedMetadata(for: companionWindow)
    }

    private var effectiveSelectedPane: PeelPhoneWorkspacePane {
        distinctCompanion == nil ? .primary : selectedPane
    }

    private var isSceneInputOwner: Bool {
        _ = sceneInputVersion
        return scenePhase == .active && currentScene?.activationState == .foregroundActive &&
            currentScene?.windows.contains(where: { $0.isKeyWindow }) == true
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let plan = geometryPlan(in: geometry)

                ZStack(alignment: .topLeading) {
                    if admitted {
                        placedPane(primaryWindow, role: .primary, plan: plan)
                        if let companionWindow = distinctCompanion {
                            placedPane(companionWindow, role: .companion, plan: plan)
                        }
                    } else {
                        ContentUnavailableView {
                            Label(store.hasProAccess ? "Window limit reached" : "More windows with Peel Pro", systemImage: "macwindow.on.rectangle")
                        } description: {
                            Text(store.hasProAccess ? "Peel supports up to 12 simultaneous windows. Close another workspace to open this one." : "One window is free. Close another workspace or get Peel Pro to open more windows.")
                        } actions: {
                            if !store.hasProAccess { Button("Get Peel Pro") { showingProPaywall = true } }
                            Button("Try Again") { synchronizeStreams() }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    visiblePanes = plan.visiblePanes
                    synchronizeStreams()
                }
                .onChange(of: plan.visiblePanes) { _, panes in
                    visiblePanes = panes
                    synchronizeStreams()
                }
            }
            .navigationTitle(companionWindow == nil ? windowLabel(primaryWindow.window) : "Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { finishWorkspace() }
                        .accessibilityIdentifier("peel.phoneWorkspace.done")
                }
                if let companionWindow = distinctCompanion {
                    ToolbarItem(placement: .principal) {
                        Menu {
                            Button { select(.primary) } label: {
                                Label(fullWindowLabel(primaryWindow.window), systemImage: effectiveSelectedPane == .primary ? "checkmark" : "macwindow")
                            }
                            Button { select(.companion) } label: {
                                Label(fullWindowLabel(companionWindow.window), systemImage: effectiveSelectedPane == .companion ? "checkmark" : "macwindow")
                            }
                        } label: {
                            Label(
                                windowLabel(effectiveSelectedPane == .primary ? primaryWindow.window : companionWindow.window),
                                systemImage: "macwindow.on.rectangle"
                            )
                            .lineLimit(1)
                        }
                        .accessibilityLabel("Window to control")
                        .accessibilityIdentifier("peel.phoneWorkspace.selection")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingWatchCompanion = true } label: {
                        Image(systemName: "applewatch")
                    }
                    .accessibilityLabel("Share this stream with Apple Watch")
                    .accessibilityIdentifier("peel.phoneWorkspace.watch")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(companionWindow == nil ? "Add Window" : "Change Second Window", systemImage: "plus.rectangle.on.rectangle") {
                            select(effectiveSelectedPane)
                            if companionWindow == nil && !scenes.canOpenAnotherPeeledWindow() {
                                if store.hasProAccess { showingWindowCapacityAlert = true }
                                else { showingProPaywall = true }
                            } else {
                                showingWindowPicker = true
                            }
                        }
                        .disabled(!session.isConnectionReady)

                        if companionWindow != nil {
                            Button("Close Second Window", systemImage: "rectangle.split.2x1", role: .destructive) {
                                closeCompanion()
                            }
                        }
                    } label: {
                        Image(systemName: "rectangle.split.2x1")
                    }
                    .accessibilityLabel("Workspace windows")
                    .accessibilityIdentifier("peel.phoneWorkspace.windows")
                }
            }
        }
        .alert("Window limit reached", isPresented: $showingWindowCapacityAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Peel supports up to 12 simultaneous windows. Close another workspace to open this one.")
        }
        .sheet(isPresented: $showingWatchCompanion) {
            PeelWatchCompanionView(model: .shared).environmentObject(browser)
        }
        .sheet(isPresented: $showingProPaywall) {
            PeelPaywallView(feature: .multipleWindows).environmentObject(store)
        }
        .onChange(of: store.hasProAccess) { _, _ in if !admitted { synchronizeStreams() } }
        .sheet(isPresented: $showingWindowPicker, onDismiss: {
            if pendingCompanionPaywall { pendingCompanionPaywall = false; showingProPaywall = true }
            if pendingCapacityAlert { pendingCapacityAlert = false; showingWindowCapacityAlert = true }
        }) {
            NavigationStack {
                List {
                    Section {
                        ForEach(availableWindows) { window in
                            Button {
                                addCompanion(window)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(windowLabel(window)).foregroundStyle(.primary)
                                    if !window.title.isEmpty {
                                        Text(verbatim: window.title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Windows on \(hostedWindow.hostName)")
                    } footer: {
                        Text("Keep an editor with a terminal or preview. Open the apps on your computer, then choose a second window here. Your workspace adapts to the available regions; compact layouts keep the selected window visible.")
                    }
                }
                .overlay {
                    if availableWindows.isEmpty {
                        ContentUnavailableView("No other windows", systemImage: "macwindow.on.rectangle", description: Text("Open another app window on this computer to add it to your workspace."))
                    }
                }
                .navigationTitle("Add Window")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingWindowPicker = false }
                    }
                }
            }
        }
        .onChange(of: PeelPhoneWorkspaceWindowIdentity(hostedWindow.window)) { _, _ in
            // The existing authenticated phone route also uses this binding
            // for popup/agent handoffs. A new primary must be visible.
            if companionWindow?.window.windowId == hostedWindow.window.windowId {
                companionWindow = nil
            }
            selectedPane = .primary
            select(.primary)
            synchronizeStreams()
        }
        .onReceive(session.$windows) { _ in
            let generation = lifetime.generation
            // @Published emits before the new window list is committed.
            Task { @MainActor in
                await Task.yield()
                guard lifetime.admits(generation) else { return }
                reconcileCompanion()
                synchronizeStreams()
            }
        }
        .onAppear {
            lifetime.appear()
            synchronizeStreams()
        }
        .onDisappear {
            lifetime.disappear()
            workspaceStreams.release(owner: streamOwnerID, session: session)
            scenes.releasePhoneWorkspace(owner: streamOwnerID)
            admitted = false
        }
        .background(WindowSceneReader { scene in
            if currentScene !== scene { currentScene = scene }
        })
        .onReceive(NotificationCenter.default.publisher(for: UIWindow.didBecomeKeyNotification)) { _ in
            sceneInputVersion &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: UIWindow.didResignKeyNotification)) { _ in
            sceneInputVersion &+= 1
        }
        .onChange(of: isSceneInputOwner) { _, _ in synchronizeStreams() }
    }

    private var availableWindows: [PeelWindow] {
        session.windows.filter {
            $0.windowId != hostedWindow.window.windowId &&
                $0.windowId != companionWindow?.window.windowId &&
                $0.width > 0 && $0.height > 0
        }.sorted {
            ($0.appName, $0.title, $0.windowId) < ($1.appName, $1.title, $1.windowId)
        }
    }

    private func geometryPlan(in geometry: GeometryProxy) -> PeelPhoneWorkspaceGeometry {
        var divisions: [CGRect] = []
        var occlusions: [CGRect] = []
        if #available(iOS 27.1, *) {
            // SwiftUI .position mirrors placement in RTL. Query matching
            // mirrored coordinates so panes still avoid the physical hardware.
            // Frames already include Apple's margins in this container's space.
            divisions = geometry.reservedRegions(kind: .division, options: [], layoutDirectionBehavior: .mirrors)
                .filter(\.isActive).map(\.frame)
            occlusions = geometry.reservedRegions(kind: .occlusion, options: [], layoutDirectionBehavior: .mirrors)
                .filter(\.isActive).map(\.frame)
        }
        return PeelPhoneWorkspaceGeometry.resolve(
            size: geometry.size,
            regularWidth: horizontalSizeClass == .regular,
            selected: effectiveSelectedPane,
            hasCompanion: distinctCompanion != nil,
            divisions: divisions,
            occlusions: occlusions
        )
    }

    private func placedPane(_ window: HostedPeelWindow, role: PeelPhoneWorkspacePane, plan: PeelPhoneWorkspaceGeometry) -> some View {
        let frame = plan.frame(for: role)
        return pane(window, role: role, frame: frame)
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
    }

    private func pane(_ window: HostedPeelWindow, role: PeelPhoneWorkspacePane, frame: CGRect) -> some View {
        let visible = !frame.isEmpty
        let selected = effectiveSelectedPane == role
        let allowsInput = PeelPhoneWorkspaceLayout.allowsInput(
            isPresent: lifetime.isPresent, selected: selected, showingPicker: showingWindowPicker,
            sourceIsCurrent: browser.session(for: hostedWindow.hostKey) === session,
            sceneIsInputOwner: isSceneInputOwner && workspaceStreams.ownsInput(owner: streamOwnerID, session: session)
        )
        return PeeledWindowView(
            hostedWindow: window,
            workspaceSession: session,
            workspaceAllowsInput: allowsInput,
            workspaceInputAdmission: {
                PeelPhoneWorkspaceLayout.allowsInput(
                    isPresent: lifetime.isPresent,
                    selected: effectiveSelectedPane == role,
                    showingPicker: showingWindowPicker,
                    sourceIsCurrent: browser.session(for: hostedWindow.hostKey) === session,
                    sceneIsInputOwner: isSceneInputOwner && workspaceStreams.ownsInput(owner: streamOwnerID, session: session)
                )
            },
            workspacePointerDidBegin: { interaction in
                workspaceStreams.claimPointer(owner: streamOwnerID, interaction: interaction, session: session)
            },
            workspaceMayReleasePointer: { interaction in
                workspaceStreams.mayReleasePointer(owner: streamOwnerID, interaction: interaction, session: session)
            },
            workspaceViewportFrame: frame,
            workspaceIsVisible: visible,
            workspaceManagesStreaming: true,
            workspaceReturnToBrowser: { finishWorkspace() }
        )
        .id(window.id)
        .allowsHitTesting(allowsInput && visible)
        .overlay {
            if visible && (!selected || !workspaceStreams.ownsInput(owner: streamOwnerID, session: session)) && !showingWindowPicker {
                Button { select(role) } label: {
                    Color.clear.contentShape(Rectangle())
                        .overlay(alignment: .top) {
                            Label("Tap to control", systemImage: "cursorarrow")
                                .font(.caption).padding(8).background(.regularMaterial, in: Capsule()).padding(8)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Control \(fullWindowLabel(window.window))")
            }
        }
        .overlay(alignment: .top) {
            if visible && role == effectiveSelectedPane, let presentationContext {
                HStack(alignment: .top, spacing: 12) {
                    Text(verbatim: presentationContext).font(.callout).lineLimit(6)
                    Button(action: dismissPresentationContext) {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .accessibilityLabel("Dismiss agent context")
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .frame(maxWidth: 560)
                .padding(12)
            }
        }
        .clipped()
        .opacity(visible ? 1 : 0)
        .accessibilityHidden(!visible)
    }

    private func finishWorkspace() {
        if let onDone { onDone() } else { dismiss() }
    }

    private func windowLabel(_ window: PeelWindow) -> String {
        if !window.title.isEmpty && window.title != window.appName { return window.title }
        return window.appName.isEmpty ? "Window" : window.appName
    }

    private func fullWindowLabel(_ window: PeelWindow) -> String {
        if window.appName.isEmpty { return window.title.isEmpty ? "Window" : window.title }
        return window.title.isEmpty || window.title == window.appName ? window.appName : "\(window.appName) · \(window.title)"
    }

    private func synchronizeStreams() {
        guard lifetime.isPresent,
              browser.session(for: hostedWindow.hostKey) === session else { return }
        // Reserve both panes even when a compact layout hides one. Selection
        // and rotation cannot turn the second paid pane into a free first pane.
        let requested = [primaryWindow, distinctCompanion].compactMap { $0 }
        guard scenes.reservePhoneWorkspace(owner: streamOwnerID, windows: requested) else {
            admitted = false
            workspaceStreams.release(owner: streamOwnerID, session: session)
            return
        }
        admitted = true
        var visibleIDs: Set<UInt32> = []
        if visiblePanes.contains(.primary) { visibleIDs.insert(primaryWindow.window.windowId) }
        if visiblePanes.contains(.companion), let distinctCompanion { visibleIDs.insert(distinctCompanion.window.windowId) }
        let windows = [primaryWindow, distinctCompanion].compactMap { $0 }.map(\.window)
        let desired = Dictionary(uniqueKeysWithValues: windows.filter {
            visibleIDs.contains($0.windowId) && session.currentWindowInstanceMatches($0)
        }.map { ($0.windowId, $0) })
        let selectedID = effectiveSelectedPane == .companion ? distinctCompanion?.window.windowId : primaryWindow.window.windowId
        workspaceStreams.update(
            owner: streamOwnerID, session: session, windows: desired,
            selectedWindowID: selectedID, canRestoreActiveSelection: isSceneInputOwner
        )
    }

    private func select(_ pane: PeelPhoneWorkspacePane) {
        let target = pane == .primary ? primaryWindow : distinctCompanion
        guard lifetime.isPresent, isSceneInputOwner,
              browser.session(for: hostedWindow.hostKey) === session,
              let target, session.currentWindowInstanceMatches(target.window) else { return }
        workspaceStreams.claimInput(owner: streamOwnerID, session: session)
        session.forceMouseUpIfNeeded(reason: "workspace selection")
        session.recordFocusedWindowId(target.window.windowId)
        session.setActiveWindow(target.window.windowId)
        selectedPane = pane
    }

    private func addCompanion(_ window: PeelWindow) {
        guard lifetime.isPresent, isSceneInputOwner,
              browser.session(for: hostedWindow.hostKey) === session,
              session.isConnectionReady,
              window.windowId != hostedWindow.window.windowId,
              session.currentWindowInstanceMatches(window) else { return }
        let candidate = HostedPeelWindow(hostKey: hostedWindow.hostKey, hostName: hostedWindow.hostName, window: window)
        guard scenes.reservePhoneWorkspace(owner: streamOwnerID, windows: [primaryWindow, candidate]) else {
            if store.hasProAccess { pendingCapacityAlert = true }
            else { pendingCompanionPaywall = true }
            showingWindowPicker = false
            return
        }
        if selectedPane == .companion { select(.primary) }
        companionWindow = candidate
        showingWindowPicker = false
        synchronizeStreams()
    }

    private func closeCompanion() {
        select(.primary)
        selectedPane = .primary
        companionWindow = nil
        synchronizeStreams()
    }

    private func reconcileCompanion() {
        guard lifetime.isPresent,
              browser.session(for: hostedWindow.hostKey) === session,
              session.hasFreshWindowListForCurrentConnection,
              let companionWindow else { return }
        let current = companionWindow.window
        if let popup = session.consumeAutoPopupHandoff(from: current.windowId) {
            self.companionWindow = HostedPeelWindow(hostKey: hostedWindow.hostKey, hostName: hostedWindow.hostName, window: popup)
            if selectedPane == .companion { select(.companion) }
        } else if !session.currentWindowInstanceMatches(refreshedMetadata(for: companionWindow).window) {
            if session.isAutoPopupWindow(current.windowId),
               let parent = session.returnParentWindow(forAutoPopup: current.windowId) {
                session.clearAutoPopupTracking(for: current.windowId)
                self.companionWindow = HostedPeelWindow(hostKey: hostedWindow.hostKey, hostName: hostedWindow.hostName, window: parent)
                if selectedPane == .companion { select(.companion) }
            } else {
                closeCompanion()
            }
        }
    }

    private func refreshedMetadata(for window: HostedPeelWindow) -> HostedPeelWindow {
        guard let current = session.windows.first(where: { $0.windowId == window.window.windowId }),
              PeelPhoneWorkspaceWindowIdentity(window.window).isSameLifetime(as: PeelPhoneWorkspaceWindowIdentity(current)) else {
            return window
        }
        return HostedPeelWindow(hostKey: window.hostKey, hostName: window.hostName, window: current)
    }
}

enum PeelPhoneWorkspacePane: String {
    case primary
    case companion
}

enum PeelPhoneWorkspaceLayout {
    static func allowsInput(isPresent: Bool, selected: Bool, showingPicker: Bool, sourceIsCurrent: Bool, sceneIsInputOwner: Bool = true) -> Bool {
        sourceIsCurrent && sceneIsInputOwner && isPresent && selected && !showingPicker
    }

    static func streamTransition(current: Set<UInt32>, desired: Set<UInt32>) -> (start: Set<UInt32>, stop: Set<UInt32>) {
        (desired.subtracting(current), current.subtracting(desired))
    }
}

/// Titles and dimensions change during normal work. A known process launch
/// identity lets the UI refresh metadata while rejecting mismatched app lifetimes.
struct PeelPhoneWorkspaceWindowIdentity: Equatable {
    let windowID: UInt32
    let appName: String
    let title: String
    let launchTime: TimeInterval?

    init(_ window: PeelWindow) {
        windowID = window.windowId
        appName = window.appName
        title = window.title
        launchTime = window.appLaunchTimeIntervalSince1970
    }

    func isSameLifetime(as current: Self) -> Bool {
        guard windowID == current.windowID, appName == current.appName else { return false }
        switch (launchTime, current.launchTime) {
        case let (expected?, actual?):
            return expected.isFinite && actual.isFinite && expected > 0 && actual > 0 && abs(expected - actual) < 1
        case (nil, nil):
            return title == current.title
        default:
            return false
        }
    }
}

struct PeelPhoneWorkspaceLifetime {
    private(set) var isPresent = false
    private(set) var generation: UInt64 = 0

    mutating func appear() {
        generation &+= 1
        isPresent = true
    }

    mutating func disappear() {
        isPresent = false
        generation &+= 1
    }

    func admits(_ capturedGeneration: UInt64) -> Bool {
        isPresent && generation == capturedGeneration
    }
}
