import Foundation

/// Count host-scoped windows across scenes, reservations and embedded panes.
/// An existing stream survives expiry; only a new window consumes allowance.
enum PeelWindowAdmissionPolicy {
    static func allowsUpdate(
        otherWindows: Set<String>, previousWindows: Set<String>, requestedWindows: Set<String>,
        freeLimit: Int, hasProAccess: Bool, resourceLimit: Int = 12,
        allowsWindowReplacement: Bool = false
    ) -> Bool {
        let current = otherWindows.union(previousWindows)
        let requested = otherWindows.union(requestedWindows)
        if requestedWindows.isSubset(of: current) { return true }
        guard requested.count <= resourceLimit else { return false }
        if hasProAccess || requested.count <= freeLimit { return true }
        // Popup handoff / changing an existing phone pane replaces its slot.
        // Adding a second pane still increases the owner's count and is gated.
        return allowsWindowReplacement && !previousWindows.isEmpty &&
            requestedWindows.count <= previousWindows.count && requested.count <= current.count
    }
}

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// Restored/external value scenes pass the same admission boundary as buttons.
/// The streaming view is mounted only after its reservation is accepted.
struct PeelWindowSceneAdmission<Content: View>: View {
    let hostedWindow: HostedPeelWindow
    @ViewBuilder var content: () -> Content
    @EnvironmentObject private var scenes: SceneCoordinator
    @EnvironmentObject private var store: PeelStore
    @EnvironmentObject private var browser: PeelClientBrowser
    @Environment(\.dismiss) private var dismiss
    @State private var admittedWindow: HostedPeelWindow?
    @State private var mountOwner = UUID()
    @State private var isPresent = false
    @State private var showingPaywall = false

    private var resolvedWindow: HostedPeelWindow {
        guard hostedWindow.hostKey.rawValue == "legacy", let session = browser.selectedSession else { return hostedWindow }
        return HostedPeelWindow(hostKey: session.hostKey, hostName: hostedWindow.hostName, window: hostedWindow.window)
    }

    private var admitted: Bool { admittedWindow?.id == resolvedWindow.id }

    var body: some View {
        Group {
            if admitted {
                content()
            } else {
                ContentUnavailableView {
                    Label(store.hasProAccess ? "Window limit reached" : "More windows with Peel Pro", systemImage: "macwindow.on.rectangle")
                } description: {
                    if store.hasProAccess {
                        Text("Peel supports up to 12 simultaneous windows. Close another window to open this one.")
                    } else {
                        Text("Your free plan includes \(store.freeWindowLimit) simultaneous \(store.freeWindowLimit == 1 ? "window" : "windows"). Close another window or upgrade to open this one.")
                    }
                } actions: {
                    if !store.hasProAccess { Button("Get Peel Pro") { showingPaywall = true } }
                    Button("Try Again") { admit() }
                    Button("Close", role: .cancel) { dismiss() }
                }
            }
        }
        .onAppear {
            isPresent = true
            admit()
        }
        .onChange(of: resolvedWindow.id) { _, _ in admit() }
        .onDisappear {
            isPresent = false
            if let admittedWindow { scenes.unmountPeeledWindow(owner: mountOwner, for: admittedWindow) }
            admittedWindow = nil
        }
        .onChange(of: store.hasProAccess) { _, _ in if !admitted { admit() } }
        .sheet(isPresented: $showingPaywall) {
            PeelPaywallView(feature: .multipleWindows).environmentObject(store)
        }
    }

    private func admit() {
        guard isPresent, !admitted else { return }
        if let admittedWindow { scenes.unmountPeeledWindow(owner: mountOwner, for: admittedWindow) }
        admittedWindow = nil
        let target = resolvedWindow
        if scenes.mountPeeledWindow(owner: mountOwner, for: target) { admittedWindow = target }
    }
}
#endif
