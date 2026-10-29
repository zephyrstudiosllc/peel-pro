//
//  Peel_macApp.swift
//  Peel-mac
//
//  Created by Zach on 11/30/25.
//

import SwiftUI
import AppKit
import Foundation
import ApplicationServices
import ScreenCaptureKit

import Sparkle
import ServiceManagement

@main
enum PeelHostMain {
    static func main() {
#if PEEL_HOST_INTEGRATION
        guard !CoffeePowerProtect.runIfRequested(), !ClosedLidSleepGuard.runIfRequested() else { return }
#endif
        if !ProcessInfo.processInfo.arguments.contains("--peel-preview") {
            _ = PeelHostSandboxPreferenceMigration.migrateIfNeeded()
        }
        Peel_HostApp.main()
    }
}
struct Peel_HostApp: App {
    @AppStorage("allowControlThisMac") private var allowControlThisMac: Bool = false
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon: Bool = true
    @AppStorage("hideDockIcon") private var hideDockIcon: Bool = false
    @State private var axTrusted: Bool = AXIsProcessTrusted()
    @State private var screenRecordingTrusted: Bool = CGPreflightScreenCaptureAccess()
    @State private var directScreenCaptureVerified: Bool = false
    @State private var directScreenCaptureCheckInFlight: Bool = false
    // Guards the one-shot auto-relaunch after Accessibility is granted while running.
    @State private var axRelaunchInFlight: Bool = false
    @StateObject private var host = PeelHost()
#if PEEL_HOST_INTEGRATION
    @State private var integration = PeelUnifiedModel()
#endif
    @State private var expandedSection: HostMainSection? = nil
    // @State private var streamDiagnosticsExpanded: Bool = false
    @State private var fallbackPermissionStepsExpanded: Bool = false
    @State private var advancedPairingExpanded: Bool = false
    @State private var showingAbout: Bool = false
    @State private var showingQuitConfirmation: Bool = false
    @State private var pendingEnableDiscoverable: Bool = false
    @State private var awaitingFirewallDecision: Bool = false
    @State private var directConnectionsExpanded: Bool = false
    @State private var trustedPairingExpanded: Bool = false
    
    @StateObject private var updater = PeelUpdaterController()
    @StateObject private var launchAtLogin = LaunchAtLoginManager()
    @NSApplicationDelegateAdaptor(PeelAppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    private enum HostMainSection {
        case setup
        case pair
        case devices
    }


    var body: some Scene {
        WindowGroup("Peel Pro", id: "peelHost") {
#if PEEL_HOST_INTEGRATION
            ContentView(store: integration.sidePulse,
                        peelHostContent: AnyView(unifiedHostHome.disabled(integration.isPreview)),
                        peelHostSettingsContent: AnyView(unifiedHostSettings.disabled(integration.isPreview)))
                .environment(integration)
                .environmentObject(integration.sampler)
                .environmentObject(integration.systemMetrics)
                .background(CommandCenterWindowReader(register: integration.registerWindow))
                .onAppear {
                    integration.configureWindowOpener(host: host) { showPeelHostWindow() }
                    guard !integration.isPreview else { return }
                    reconcileDockAndMenuBarPreferences()
                    applyDockIconPreference()
                    refreshPermissionStates()
                }
                .onChange(of: hideDockIcon) { _, _ in
                    reconcileDockAndMenuBarPreferences()
                    applyDockIconPreference()
                }
                .onChange(of: showMenuBarIcon) { _, _ in
                    reconcileDockAndMenuBarPreferences()
                    applyDockIconPreference()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    integration.shutdown()
                    host.stopLocalAgentBridge()
                }
#else
            legacyHostContent
#endif
        }
#if PEEL_HOST_INTEGRATION
        // A compact utility: every launch opens at the default size rather than
        // a saved frame; ContentView sets the minimum, PeelUtilityWindowPolicy
        // sets the maximum and returns an enlarged/full-screen manager to
        // compact on Show/Open.
        .defaultSize(PeelUtilityWindowPolicy.defaultSize)
        .restorationBehavior(.disabled)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { integration.openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
#else
        .defaultSize(width: 500, height: 820)
#endif

#if !PEEL_HOST_INTEGRATION
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            Button {
                performHostReadinessAction()
            } label: {
                Text(menuBarStatusLabel)
            }

                Divider()

                Button("Copy Pairing Code") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(host.pairingPIN, forType: .string)
                }

                Button("Settings…") {
                    showSettingsWindow()
                }

                Button("Show Peel Pro") {
                    showPeelHostWindow()
                }

                Divider()

                Button("Restart") {
                    restartPeelHost()
                }

                Button("Quit Peel Pro") {
                    NSApplication.shared.terminate(nil)
                }
        } label: {
            if let image = NSImage(named: "PeelHostMenuBarIcon_66x66") {
                let _ = image.size = NSSize(width: 18, height: 18)
                let _ = image.isTemplate = true

                Image(nsImage: image)
            }
        }

        .menuBarExtraStyle(.menu)
#endif

        WindowGroup("Quit Peel Pro", id: "quitPeelHostConfirmation") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Quit Peel Pro?")
                    .font(.title2.bold())

                Text("Peel Pro can only stream and accept connections while it is active. If you quit now, paired devices will not be able to connect until you reopen the app.")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Cancel", role: .cancel) {
                        closeQuitConfirmationWindow()
                    }

                    Spacer()

                    Button("Quit", role: .destructive) {
                        NSApplication.shared.terminate(nil)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 420)
        }
        .windowResizability(.contentSize)

#if !PEEL_HOST_INTEGRATION
        Settings {
            PeelHostSettingsView()
                .environmentObject(updater)
                .environmentObject(launchAtLogin)
        }
#endif

    }

    private var legacyHostContent: some View {
            VStack(spacing: 0) {
                Spacer()

                HostHeroCard(
                    status: hostReadinessStatus,
                    statusTitle: hostReadinessTitle,
                    cardTitle: hostReadinessCardTitle,
                    message: hostReadinessMessage,
                    actionTitle: hostReadinessActionTitle,
                    action: {
                        performHostReadinessAction()
                    }
                )
                .padding(.horizontal, 48)


                Divider()
                    .padding(.top, 36)
                    .padding(.horizontal, 56)

                Spacer()
                    .frame(height: 32)
               
                hostConnectionSettings
                    .padding(.horizontal, 32)

                Spacer(minLength: 32)

                Divider()
                    .padding(.horizontal, 56)

                VStack(spacing: 10) {
                    Button {
                        closeMainWindowToDock()
                    } label: {
                        Text("Close")
                            .font(.headline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: 240)
                    .clipShape(Capsule())
                    .help("Minimize Peel Pro. Peel Pro keeps running until you choose Quit Peel Pro or press Command-Q.")

                    VStack(spacing: 8) {
                        Button {
                            restartPeelHost()
                        } label: {
                            Text("Restart")
                                .font(.callout.weight(.semibold))
                                .frame(width: 100)
                        }
                        .controlSize(.large)
                        .buttonStyle(.bordered)
                        .clipShape(Capsule())

                        Button {
                            showingQuitConfirmation = true
                        } label: {
                            Text("Quit")
                                .font(.callout.weight(.semibold))
                                .frame(width: 100)
                        }
                        .controlSize(.large)
                        .buttonStyle(.bordered)
                        .clipShape(Capsule())
                    }
                }
                .padding(48)
            }
            .frame(width: 500, height: 820)
            .overlay(alignment: .topTrailing) {
                if let pendingUpdate = updater.pendingUpdate {
                    UpdateAvailableBanner(
                        update: pendingUpdate,
                        onUpdateNow: {
                            updater.showPendingUpdateNow()
                        },
                        onNotNow: {
                            updater.dismissPendingUpdate()
                        }
                    )
                }
            }
            .toolbar {
                // Match Vision ornament placement (top-left). If you prefer standard iOS, use .topBarTrailing.
                ToolbarItem {
                         SettingsLink {
                             Image(systemName: "gearshape")
                         }
                         .help("Settings")
                     }
                ToolbarItem() {
                    Button {
                        showingAbout = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("About Peel Pro")
                }
            }
            .sheet(isPresented: $showingAbout) {
                AboutPeelView()
                    .frame(minWidth: 480, minHeight: 640)

            }
            // Removed sheets for showingAXSetupSheet, showingNetworkPermissionSheet, showingScreenRecordingPermissionSheet
            .alert("Quit Peel Pro?", isPresented: $showingQuitConfirmation) {
                Button("Quit", role: .destructive) {
                    NSApplication.shared.terminate(nil)
                }

                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Peel Pro can only stream and accept connections while it is active. If you quit now, paired devices will not be able to connect until you reopen the app.")
            }
            .onAppear {
#if PEEL_HOST_INTEGRATION
                guard !integration.isPreview else { return }
#endif
                reconcileDockAndMenuBarPreferences()
                applyDockIconPreference()
                refreshPermissionStates()
            }
            .onChange(of: hideDockIcon) { _, _ in
                reconcileDockAndMenuBarPreferences()
                applyDockIconPreference()
            }
            .onChange(of: showMenuBarIcon) { _, _ in
                reconcileDockAndMenuBarPreferences()
                applyDockIconPreference()
            }
    }

    private var hostConnectionSettings: some View {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 14) {
                        PeelDirectConnectionSection(host: host, isExpanded: $directConnectionsExpanded)
                        PeelICloudHostPairingSection(controller: host.iCloudPairing)
                        PeelAgentBridgeControls(host: host)
                        DisclosureGroup("Pair With Another Computer · Notch Pulse Sharing", isExpanded: $trustedPairingExpanded) {
                            PeelTrustedPeerPairingSection(controller: host.trustedPeerPairing)
                                .padding(.top, 10)
                        }
                        .padding(14)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                        // ---- Setup Checklist UI ----
                        VStack(alignment: .leading, spacing: 0) {
                            DisclosureCardLabel(
                                title: "Setup",
                                subtitle: "Peel Pro needs these permissions to function.",
                                trailingText: setupChecklistSummary,
                                isExpanded: expandedSection == .setup,
                                onTap: {
                                    toggleSection(.setup)
                                }
                            )

                            if expandedSection == .setup {
                                VStack(alignment: .leading, spacing: 14) {
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text("Peel Pro needs these permissions in order to function:")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)

                                        PermissionStatusToggleRow(
                                            title: "Local Network",
                                            message: localNetworkMessage,
                                            statusText: localNetworkStatusText,
                                            status: localNetworkStatus,
                                            isOn: Binding(
                                                get: { host.isDiscoverable },
                                                set: { newValue in
                                                    if newValue {
                                                        host.isDiscoverable = true
                                                        pendingEnableDiscoverable = false
                                                        awaitingFirewallDecision = true
                                                    } else {
                                                        host.isDiscoverable = false
                                                        pendingEnableDiscoverable = false
                                                        awaitingFirewallDecision = false
                                                    }
                                                }
                                            )
                                        )

                                        if unavailableFixedPort != nil {
                                            HStack {
                                                Spacer()

                                                Button("Open Direct Connections") {
                                                    openDirectConnectionsSettings()
                                                }
                                                .controlSize(.small)
                                                .tint(.accentColor)
                                            }
                                        } else if host.discoveryState == .failed {
                                            HStack {
                                                Spacer()

                                                Button("Open Local Network Settings") {
                                                    openLocalNetworkSettings()
                                                }
                                                .controlSize(.small)
                                                .tint(.accentColor)
                                            }
                                        }

                                        PermissionStatusRow(
                                            title: "Screen Recording",
                                            message: "Needed so Peel Pro can capture and stream Mac app windows.",
                                            statusText: screenRecordingTrusted ? "Ready" : "Needs Permission",
                                            status: screenRecordingTrusted ? .active : .offline,
                                            actionTitle: screenRecordingTrusted ? "Open Settings" : "Allow",
                                            action: {
                                                if screenRecordingTrusted {
                                                    openScreenRecordingSettings()
                                                } else {
                                                    requestScreenRecordingAccess()
                                                    openScreenRecordingSettings()
                                                }
                                            }
                                        )

                                        PermissionStatusRow(
                                            title: "Accessibility",
                                            message: accessibilityStatusMessage,
                                            statusText: accessibilityStatusText,
                                            status: accessibilityStatus,
                                            actionTitle: accessibilityActionTitle,
                                            action: {
                                                performAccessibilityAction()
                                            }
                                        )
                                    }

                                    Divider()

                                    VStack(alignment: .leading, spacing: 0) {
                                        HStack(spacing: 8) {
                                            Image(systemName: "questionmark.circle")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)

                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("Fallback Permission Steps")
                                                    .font(.caption.weight(.semibold))

                                                Text("Manual System Settings paths if the normal buttons fail.")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }

                                            Spacer(minLength: 0)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            fallbackPermissionStepsExpanded.toggle()
                                        }

                                        if fallbackPermissionStepsExpanded {
                                            VStack(alignment: .leading, spacing: 10) {
                                                VStack(alignment: .leading, spacing: 5) {
                                                    Text("Local Network")
                                                        .font(.caption.weight(.semibold))

                                                    Text("System Settings > Privacy & Security > Local Network > enable this app (it may appear as Peel Pro).")
                                                        .font(.caption2)
                                                        .foregroundStyle(.secondary)

                                                    HStack {
                                                        Spacer()

                                                        Button("Open Local Network Settings") {
                                                            openLocalNetworkSettings()
                                                        }
                                                        .controlSize(.small)
                                                        .tint(.accentColor)
                                                    }
                                                }

                                                Divider()
                                                    .opacity(0.45)

                                                VStack(alignment: .leading, spacing: 5) {
                                                    Text("Screen Recording")
                                                        .font(.caption.weight(.semibold))

                                                    Text("System Settings > Privacy & Security > Screen Recording > enable this app (it may appear as Peel Pro).")
                                                        .font(.caption2)
                                                        .foregroundStyle(.secondary)

                                                    HStack {
                                                        Spacer()

                                                        Button("Open Screen Recording Settings") {
                                                            openScreenRecordingSettings()
                                                        }
                                                        .controlSize(.small)
                                                        .tint(.accentColor)
                                                    }
                                                }

                                                Divider()
                                                    .opacity(0.45)

                                                VStack(alignment: .leading, spacing: 5) {
                                                    Text("Accessibility")
                                                        .font(.caption.weight(.semibold))

                                                    Text("System Settings > Privacy & Security > Accessibility > enable this app (it may appear as Peel Pro).")
                                                        .font(.caption2)
                                                        .foregroundStyle(.secondary)

                                                    HStack {
                                                        Spacer()

                                                        Button("Open Accessibility Settings") {
                                                            openAccessibilitySettings()
                                                        }
                                                        .controlSize(.small)
                                                        .tint(.accentColor)
                                                    }
                                                }
                                            }
                                            .padding(.top, 8)
                                            .padding(10)
                                            .background(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .fill(Color.secondary.opacity(0.06))
                                            )
                                        }
                                    }
                                }
                                .padding(.top, 10)
                            }
                        }
                        .padding(12)
                        .background {
                            RoundedRectangle(cornerRadius: 14)
                                .fill(.ultraThinMaterial)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .onAppear {
                            refreshPermissionStates()
                        }
                        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                            refreshPermissionStates()

                            if awaitingFirewallDecision {
                                awaitingFirewallDecision = false
                            }
                        }

/*
                        StreamDiagnosticsSection(
                            diagnostics: host.streamDiagnostics,
                            isExpanded: $streamDiagnosticsExpanded
                        )
*/

                        // ---- Pairing UI ----
                        VStack(alignment: .leading, spacing: 0) {
                            DisclosureCardLabel(
                                title: "Pair",
                                subtitle: "Expand for 6-digit code. No Apple Account needed.",
                                trailingText: nil,
                                isExpanded: expandedSection == .pair,
                                onTap: {
                                    toggleSection(.pair)
                                }
                            )

                            if expandedSection == .pair {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Text("6-digit Pairing Code")
                                            .font(.headline)
                                            .fontWeight(.semibold)

                                        Spacer()

                                        Button {
                                            host.refreshPairingPIN()
                                        } label: {
                                            Image(systemName: "arrow.clockwise")
                                        }
                                        .buttonStyle(.bordered)

                                        Button {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(host.pairingPIN, forType: .string)
                                        } label: {
                                            Image(systemName: "doc.on.doc")
                                        }
                                        .buttonStyle(.bordered)
                                    }

                                    Text(host.pairingPIN)
                                        .font(.system(size: 48, weight: .bold, design: .monospaced))
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        .padding(.vertical, 6)
                                        .background(
                                            RoundedRectangle(cornerRadius: 12)
                                                .fill(Color.secondary.opacity(0.08))
                                        )

                                    HStack {
                                        Text("On your other device, open Peel Pro, tap Pair, and enter this code.")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)

                                        Spacer()

                                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                            let remaining = max(0, Int(host.pairingPinExpiresAt.timeIntervalSince(ctx.date)))
                                            Text(remaining > 0 ? "Expires in \(remaining)s" : "Expired (regenerating…)")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    PeelPairingAccountNotice()
                                        .padding(10)
                                        .background(
                                            RoundedRectangle(cornerRadius: 10)
                                                .fill(Color.secondary.opacity(0.06))
                                        )

                                    VStack(alignment: .leading, spacing: 0) {
                                        Text("Having trouble? Use advanced pairing")
                                            .font(.body)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .contentShape(Rectangle())
                                            .onTapGesture {
                                                advancedPairingExpanded.toggle()
                                            }

                                        if advancedPairingExpanded {
                                            VStack(alignment: .leading, spacing: 8) {
                                                Text("Most people should use the 6-digit code above. Generate a token only if the code flow is not working or support asks you to use advanced pairing.")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                    .fixedSize(horizontal: false, vertical: true)

                                                HStack {
                                                    Button("Generate Advanced Token") {
                                                        _ = host.generatePairingToken(clientLabel: "Peel Client (pending)")
                                                    }

                                                    if let token = host.lastPairingToken, !token.isEmpty {
                                                        Button("Copy Token") {
                                                            NSPasteboard.general.clearContents()
                                                            NSPasteboard.general.setString(token, forType: .string)
                                                        }
                                                        .buttonStyle(.bordered)
                                                    }
                                                }

                                                if let token = host.lastPairingToken, !token.isEmpty {
                                                    Text("Paste this token into Peel Pro on the other device from Advanced Pairing.")
                                                        .font(.caption2)
                                                        .foregroundStyle(.secondary)
                                                        .fixedSize(horizontal: false, vertical: true)

                                                    TextEditor(text: .constant(token))
                                                        .font(.system(.caption, design: .monospaced))
                                                        .frame(height: 80)
                                                        .overlay(
                                                            RoundedRectangle(cornerRadius: 8)
                                                                .stroke(Color.secondary.opacity(0.25))
                                                        )
                                                        .disabled(true)
                                                }
                                            }
                                            .padding(.top, 6)
                                        }
                                    }
                                }
                                .padding(.top, 10)
                            }
                        }
                        .padding(12)
                        .background {
                            RoundedRectangle(cornerRadius: 14)
                                .fill(.ultraThinMaterial)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        
                        PairedDevicesSection(
                            store: host.pairingStore,
                            connectedPairingID: host.connectedClientPairingID,
                            isExpanded: Binding(
                                get: { expandedSection == .devices },
                                set: { isExpanded in
                                    if isExpanded {
                                        expandedSection = .devices
                                    } else if expandedSection == .devices {
                                        expandedSection = nil
                                    }
                                }
                            ),
                            onUnpair: { id in
                                host.forgetPairedClient(pairingID: id)
                            }
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
                .padding(.horizontal, 16)
    }

#if PEEL_HOST_INTEGRATION
    /// Remote Desktop: connect to another computer, or share this Mac. The
    /// streamed desktop/app window is a separate native window; switching tabs
    /// or pages never connects, disconnects or selects a stream.
    private var unifiedHostHome: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Side by side when the utility window is wide; mode picker below otherwise.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    remoteDesktopTitle
                    Spacer()
                    remoteDesktopModePicker
                }
                VStack(alignment: .leading, spacing: 10) {
                    remoteDesktopTitle
                    remoteDesktopModePicker
                }
            }
            if integration.remoteDesktopTab == .connect {
                ScrollView {
                    if let viewer = integration.remoteMacViewer,
                       let presentation = integration.remoteMacPresentation {
                        PeelRemoteMacViewerView(controller: viewer, presentation: presentation,
                            pairComputer: { openShareThisMac(expanding: .pair, trustedPairing: true) },
                            shareThisMac: { openShareThisMac(expanding: nil) })
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    } else {
                        ContentUnavailableView("Remote Desktop is starting", systemImage: "display",
                            description: Text("Paired computers appear here once Peel Pro is ready."))
                    }
                }
            } else {
                shareThisMac
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var remoteDesktopTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Remote Desktop").font(.largeTitle.bold())
            Text(integration.remoteDesktopTab == .connect
                 ? "Connect to another computer, then open its desktop or an app window in its own window."
                 : "Let your paired devices view and control this Mac.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var remoteDesktopModePicker: some View {
        Picker("Remote Desktop", selection: Binding(
            get: { integration.remoteDesktopTab },
            set: { integration.remoteDesktopTab = $0 }
        )) {
            ForEach(PeelRemoteDesktopTab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Remote Desktop mode")
    }

    /// The single home for hosting: availability, permissions, pairing,
    /// direct connections, paired devices, audio/status sharing and AI access.
    private var shareThisMac: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Status beside its actions when wide; actions on their own row otherwise.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    shareThisMacStatus
                    Spacer(minLength: 8)
                    shareThisMacActions
                }
                VStack(alignment: .leading, spacing: 8) {
                    shareThisMacStatus
                    HStack(spacing: 8) { shareThisMacActions }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    shareThisMacCounts
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 4) { shareThisMacCounts }
            }
            .font(.callout)
            .padding(.bottom, 4)
            hostConnectionSettings
                .padding(.horizontal, -16)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onAppear { if !integration.isPreview { refreshPermissionStates() } }
    }

    private var shareThisMacStatus: some View {
        HStack(alignment: .center, spacing: 12) {
            StatusDot(status: hostReadinessStatus,
                      accessibilityLabelOverride: "Share This Mac: \(hostReadinessTitle)")
            VStack(alignment: .leading, spacing: 2) {
                Text(hostReadinessTitle).font(.headline)
                Text(hostReadinessMessage).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var shareThisMacActions: some View {
        if let actionTitle = hostReadinessActionTitle {
            Button(actionTitle, action: performHostReadinessAction)
        }
        Button("Copy Pairing Code", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(host.pairingPIN, forType: .string)
        }
        .help("Copy this Mac's current 6-digit pairing code")
    }

    @ViewBuilder
    private var shareThisMacCounts: some View {
        LabeledContent("Paired devices", value: String(host.pairingStore.paired.count))
        LabeledContent("Connected now", value: host.pairingStore.paired.first {
            $0.id == host.connectedClientPairingID
        }?.displayName ?? "None")
    }

    private func openShareThisMac(expanding section: HostMainSection?, trustedPairing: Bool = false) {
        if let section { expandedSection = section }
        if trustedPairing { trustedPairingExpanded = true }
        integration.openRemoteDesktop(.share)
    }

    private var unifiedHostSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    Text("App & Streaming").font(.title2.bold())
                    Spacer()
                    sharingAndPermissionsButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("App & Streaming").font(.title2.bold())
                    sharingAndPermissionsButton
                }
            }
            Text("Streaming, startup, updates and app appearance. Sharing this Mac is set up in Remote Desktop › Share This Mac.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            PeelHostSettingsView(embeddedInHost: true)
                .environmentObject(updater)
                .environmentObject(launchAtLogin)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { if !integration.isPreview { refreshPermissionStates() } }
    }

    private var sharingAndPermissionsButton: some View {
        Button("Sharing & Permissions…", systemImage: "display") {
            openShareThisMac(expanding: nil)
        }
        .help("Pairing, permissions, direct connections and AI access are in Remote Desktop › Share This Mac")
    }
#endif

    private func toggleSection(_ section: HostMainSection) {
        expandedSection = expandedSection == section ? nil : section
    }

    private func reconcileDockAndMenuBarPreferences() {
        if hideDockIcon && !showMenuBarIcon {
            showMenuBarIcon = true
        }

        if !showMenuBarIcon && hideDockIcon {
            hideDockIcon = false
        }
    }

    private func applyDockIconPreference() {
        NSApplication.shared.setActivationPolicy(hideDockIcon ? .accessory : .regular)
    }

    private var setupChecklistSummary: String {
        let localNetworkReady = host.discoveryState == .published
        let screenRecordingReady = screenRecordingTrusted
        let accessibilityReady = axTrusted
        let readyCount = [localNetworkReady, screenRecordingReady, accessibilityReady].filter { $0 }.count

        return "\(readyCount)/3"
    }

    private var hasLiveConnectedClient: Bool {
        host.isDiscoverable && host.connectedClientPairingID != nil
    }

    private var unavailableFixedPort: UInt16? {
        guard case .portUnavailable(let port) = host.discoveryState else { return nil }
        return port
    }

    private var localNetworkStatus: WindowStreamStatus {
        guard host.isDiscoverable else { return .offline }

        switch host.discoveryState {
        case .disabled, .starting:
            return .sleeping
        case .published:
            return .active
        case .failed, .portUnavailable:
            return .offline
        }
    }

    private var localNetworkStatusText: String {
        guard host.isDiscoverable else { return "Off" }

        switch host.discoveryState {
        case .disabled, .starting:
            return "Checking"
        case .published:
            return "Listening"
        case .failed, .portUnavailable:
            return "Unavailable"
        }
    }

    private var localNetworkMessage: String {
        guard host.isDiscoverable else {
            return "This Mac is hidden from paired Peel devices."
        }

        switch host.discoveryState {
        case .disabled, .starting:
            return "Checking whether this Mac is available to paired Peel devices."
        case .published:
            return "This Mac is available to paired Peel devices."
        case .failed:
            return "Local Network discovery is unavailable. Check Local Network access in System Settings."
        case .portUnavailable(let port):
            return "Fixed port \(port) is unavailable. Choose another port in Direct Connections and apply it."
        }
    }

    private var accessibilityStatus: WindowStreamStatus {
        guard axTrusted else { return .offline }
        return allowControlThisMac ? .active : .sleeping
    }
    
    private var accessibilityStatusText: String {
        guard axTrusted else { return "Needs Permission" }
        return allowControlThisMac ? "Ready" : "Allowed, Control Off"
    }

    private var accessibilityStatusMessage: String {
        guard axTrusted else {
            return "Needed for remote input and window focusing. Enable this permission in System Settings."
        }

        if allowControlThisMac {
            return "Remote input and window focusing are enabled."
        }

        return "Accessibility is allowed, but remote input and window focusing are off."
    }
    
    private var accessibilityActionTitle: String? {
        if !axTrusted { return "Allow" }
        return "Open Settings"
    }

    private var hostReadinessStatus: WindowStreamStatus {
        guard host.isDiscoverable else { return .offline }

        if !hasLiveConnectedClient {
            switch host.discoveryState {
            case .disabled, .starting:
                return .sleeping
            case .failed:
                return .offline
            case .portUnavailable:
                return .offline
            case .published:
                break
            }
        }

        guard screenRecordingTrusted else { return .offline }
        
        if allowControlThisMac && !axTrusted {
            return .sleeping
        }
        
        return .active
    }

    private var hostReadinessMenuColor: Color {
        switch hostReadinessStatus {
        case .active:
            return .green
        case .sleeping:
            return .yellow
        case .offline:
            return .gray
        }
    }

    private var menuBarStatusLabel: AttributedString {
        let maxMessageLength = 20
        let trimmedMessage = hostReadinessMessage.count > maxMessageLength
            ? String(hostReadinessMessage.prefix(maxMessageLength)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
            : hostReadinessMessage
        let title = hostReadinessTitle
        let dot = "●"
        var label = AttributedString("\(dot)  \(title) – \(trimmedMessage)")

        if let dotRange = label.range(of: dot) {
            label[dotRange].foregroundColor = hostReadinessMenuColor
        }

        return label
    }
    
    private var hostReadinessTitle: String {
        if host.isDiscoverable && !hasLiveConnectedClient {
            switch host.discoveryState {
            case .disabled, .starting:
                return "Checking"
            case .failed:
                return "Not Available"
            case .portUnavailable:
                return "Port Unavailable"
            case .published:
                break
            }
        }

        switch hostReadinessStatus {
        case .active:
            if host.connectedClientPairingID != nil {
                return "Connected"
            }
            
            return "Available"
        case .sleeping:
            return "Almost Ready"
        case .offline:
            return "Not Available"
        }
    }
    
    private var hostReadinessCardTitle: String {
        if !host.isDiscoverable {
            return "Peel Pro is Off"
        }

        if !hasLiveConnectedClient {
            switch host.discoveryState {
            case .disabled, .starting:
                return "Checking Local Network"
            case .failed:
                return "Local Network Unavailable"
            case .portUnavailable:
                return "Direct Connection Port Unavailable"
            case .published:
                break
            }
        }
        
        if !screenRecordingTrusted {
            return "Screen Recording Needed"
        }
        
        if allowControlThisMac && !axTrusted {
            return "Accessibility Needed"
        }
        
        if hasLiveConnectedClient {
            return "Connected"
        }
        
        return "Ready for Peel"
    }
    
    private var hostReadinessActionTitle: String? {
        if !host.isDiscoverable {
            return "Turn On Host"
        }

        if hasLiveConnectedClient {
            if !screenRecordingTrusted {
                return "Allow Screen Recording"
            }

            if allowControlThisMac && !axTrusted {
                return "Allow Accessibility"
            }

            if unavailableFixedPort != nil {
                return "Open Direct Connections"
            }

            return host.discoveryState == .failed ? "Open Local Network Settings" : nil
        }

        if unavailableFixedPort != nil {
            return "Open Direct Connections"
        }

        if host.discoveryState == .failed {
            return "Open Local Network Settings"
        }

        if host.discoveryState != .published {
            return nil
        }

        if !screenRecordingTrusted {
            return "Allow Screen Recording"
        }

        if allowControlThisMac && !axTrusted {
            return "Allow Accessibility"
        }
        
        return nil
    }
    
    private var hostReadinessMessage: String {
        if !host.isDiscoverable {
            return "Turn on Peel Pro so paired devices can find this Mac."
        }

        if !hasLiveConnectedClient {
            switch host.discoveryState {
            case .disabled, .starting:
                return "Checking whether Peel Pro is visible on the local network."
            case .failed:
                return "Peel Pro cannot advertise on the local network. Check Local Network access in System Settings."
            case .portUnavailable(let port):
                return "Peel Pro cannot use fixed port \(port). Open Direct Connections and choose another port."
            case .published:
                break
            }
        }
        
        if !screenRecordingTrusted {
            return "Screen Recording permission is required before Peel Pro can stream Mac windows."
        }
        
        if allowControlThisMac && !axTrusted {
            return "Accessibility permission is still needed for remote input and window focusing."
        }
        
        if hasLiveConnectedClient {
            switch host.discoveryState {
            case .failed:
                return "A Peel device is connected. Local Network discovery is unavailable for new connections."
            case .disabled, .starting:
                return "A Peel device is connected. Checking Local Network discovery for new connections."
            case .portUnavailable(let port):
                return "A Peel device is connected. Fixed port \(port) is unavailable for new connections."
            case .published:
                return "A Peel device is connected to this Mac."
            }
        }
        
        if host.pairingStore.paired.isEmpty {
            return "Looking for clients to pair with."
        }
        
        return "Waiting for a paired Peel device to connect."
    }
    
    private func closeMainWindowToDock() {
        closeSettingsWindows()

        guard let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first(where: { $0.isVisible && $0.canBecomeMain && $0.title != "Settings" }) else {
            NSApplication.shared.hide(nil)
            return
        }

        window.miniaturize(nil)
    }

    private func restartPeelHost() {
        let appPath = Bundle.main.bundlePath
        let quotedAppPath = appPath.replacingOccurrences(of: "'", with: "'\\''")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c",
            "sleep 0.6; /usr/bin/open '\(quotedAppPath)'"
        ]

        do {
            try task.run()
            NSApplication.shared.terminate(nil)
        } catch {
            print("Failed to restart Peel Pro: \(error.localizedDescription)")
        }
    }

    private func closeSettingsWindows() {
        for window in NSApplication.shared.windows where isSettingsWindow(window) {
            window.close()
        }
    }

    private func isSettingsWindow(_ window: NSWindow) -> Bool {
#if PEEL_HOST_INTEGRATION
        // Settings are pages of the main window, not separate settings windows.
        false
#else
        window.title.localizedCaseInsensitiveContains("settings")
#endif
    }

    private func showPeelHostWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)

        if let window = NSApplication.shared.windows.first(where: { window in
#if PEEL_HOST_INTEGRATION
            window.identifier == PeelUtilityWindowPolicy.identifier
#else
            window.canBecomeMain && !isSettingsWindow(window) && window.title != "Quit Peel Pro"
#endif
        }) {
#if PEEL_HOST_INTEGRATION
            PeelUtilityWindowPolicy.normalize(window)
#endif
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }

            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        openWindow(id: "peelHost")
    }

    private func showSettingsWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)

        if let settingsWindow = NSApplication.shared.windows.first(where: isSettingsWindow(_:)) {
            if settingsWindow.isMiniaturized {
                settingsWindow.deminiaturize(nil)
            }

            settingsWindow.makeKeyAndOrderFront(nil)
            settingsWindow.orderFrontRegardless()
            return
        }

        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    private func closeQuitConfirmationWindow() {
        for window in NSApplication.shared.windows where window.title == "Quit Peel Pro" {
            window.close()
        }
    }

    private func performHostReadinessAction() {
        if !host.isDiscoverable {
            host.isDiscoverable = true
            pendingEnableDiscoverable = false
            awaitingFirewallDecision = true
            return
        }

        if hasLiveConnectedClient {
            if !screenRecordingTrusted {
                requestScreenRecordingAccess()
                openScreenRecordingSettings()
                return
            }

            if allowControlThisMac && !axTrusted {
                requestAccessibilityPromptIfNeeded()
                openAccessibilitySettings()
                return
            }

            if unavailableFixedPort != nil {
                openDirectConnectionsSettings()
                return
            }

            if host.discoveryState == .failed {
                openLocalNetworkSettings()
            }
            return
        }

        if unavailableFixedPort != nil {
            openDirectConnectionsSettings()
            return
        }

        if host.discoveryState == .failed {
            openLocalNetworkSettings()
            return
        }

        guard host.discoveryState == .published else { return }

        if !screenRecordingTrusted {
            requestScreenRecordingAccess()
            openScreenRecordingSettings()
            return
        }

        if allowControlThisMac && !axTrusted {
            requestAccessibilityPromptIfNeeded()
            openAccessibilitySettings()
        }
    }
    
    private func performAccessibilityAction() {
        refreshPermissionStates()

        if axTrusted {
            allowControlThisMac = true
            openAccessibilitySettings()
            return
        }

        allowControlThisMac = true
        requestAccessibilityPromptIfNeeded()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            refreshPermissionStates()
        }

        openAccessibilitySettings()
    }

    private func refreshAXTrusted() {
        let wasAXTrusted = axTrusted
        axTrusted = AXIsProcessTrusted()
        handleAXTrustTransition(wasTrusted: wasAXTrusted, isTrusted: axTrusted)
    }

    /// macOS does not apply a newly-granted Accessibility permission to the running
    /// process's AX element calls — a relaunch is required. When trust flips false→true
    /// while the user wants to control this Mac, auto-relaunch once so remote input and
    /// window focusing start working without a manual restart. Guarded so it fires once.
    private func handleAXTrustTransition(wasTrusted: Bool, isTrusted: Bool) {
        guard isTrusted, !wasTrusted else { return }
        guard allowControlThisMac, !axRelaunchInFlight else { return }
        axRelaunchInFlight = true
        restartPeelHost()
    }
    
    private func refreshPermissionStates() {
        let wasAXTrusted = axTrusted
        axTrusted = AXIsProcessTrusted()
        handleAXTrustTransition(wasTrusted: wasAXTrusted, isTrusted: axTrusted)

        let wasScreenRecordingTrusted = screenRecordingTrusted
        screenRecordingTrusted = CGPreflightScreenCaptureAccess()

        if !screenRecordingTrusted {
            directScreenCaptureVerified = false
            directScreenCaptureCheckInFlight = false
        } else if !directScreenCaptureVerified && (!wasScreenRecordingTrusted || !directScreenCaptureCheckInFlight) {
            confirmDirectScreenCaptureAccess()
        }
    }

    private func requestAccessibilityPromptIfNeeded() {
        refreshPermissionStates()
        guard !axTrusted else { return }

        // This is the only supported “prompt” mechanism for Accessibility trust.
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        let trustedNow = AXIsProcessTrustedWithOptions(options)

        // This will almost always still be false until the user enables Peel in Settings,
        // and may still require a relaunch.
        axTrusted = trustedNow
    }

    private func openAccessibilitySettings() {
        // Your URL is fine; it just navigates.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openLocalNetworkSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
            return
        }
        
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openDirectConnectionsSettings() {
        directConnectionsExpanded = true
#if PEEL_HOST_INTEGRATION
        integration.openRemoteDesktop(.share)
#else
        showPeelHostWindow()
#endif
    }
    
    private func hasScreenRecordingAccess() -> Bool {
        // Returns true if Screen Recording permission is already granted.
        CGPreflightScreenCaptureAccess()
    }

    private func requestScreenRecordingAccess() {
        // Triggers the system flow (prompt and/or directs to System Settings).
        _ = CGRequestScreenCaptureAccess()
        screenRecordingTrusted = CGPreflightScreenCaptureAccess()

        if screenRecordingTrusted && !directScreenCaptureVerified {
            confirmDirectScreenCaptureAccess()
        }
    }

    private func confirmDirectScreenCaptureAccess() {
        guard !directScreenCaptureCheckInFlight else { return }

        screenRecordingTrusted = CGPreflightScreenCaptureAccess()
        guard screenRecordingTrusted else {
            directScreenCaptureVerified = false
            return
        }

        directScreenCaptureCheckInFlight = true

        if #available(macOS 14.0, *) {
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                if error != nil {
                    DispatchQueue.main.async {
                        directScreenCaptureCheckInFlight = false
                        directScreenCaptureVerified = false
                        screenRecordingTrusted = CGPreflightScreenCaptureAccess()
                    }
                    return
                }

                guard let display = content?.displays.first else {
                    DispatchQueue.main.async {
                        directScreenCaptureCheckInFlight = false
                        directScreenCaptureVerified = false
                        screenRecordingTrusted = CGPreflightScreenCaptureAccess()
                    }
                    return
                }

                let filter = SCContentFilter(display: display, excludingWindows: [])
                let configuration = SCStreamConfiguration()
                configuration.width = display.width
                configuration.height = display.height
                configuration.showsCursor = false
                configuration.capturesAudio = false

                SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                    DispatchQueue.main.async {
                        directScreenCaptureCheckInFlight = false
                        screenRecordingTrusted = CGPreflightScreenCaptureAccess()

                        if error != nil {
                            directScreenCaptureVerified = false
                            return
                        }

                        guard image != nil else {
                            directScreenCaptureVerified = false
                            return
                        }

                        directScreenCaptureVerified = true
                    }
                }
            }
        } else {
            DispatchQueue.main.async {
                directScreenCaptureCheckInFlight = false
                screenRecordingTrusted = CGPreflightScreenCaptureAccess()
                directScreenCaptureVerified = screenRecordingTrusted
            }
        }
    }
    
    private func openScreenRecordingSettings() {
        // “Screen Recording” anchor (works on modern macOS).
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
            return
        }

        // Fallback: open Privacy & Security.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct HostHeroCard: View {
    let status: WindowStreamStatus
    let statusTitle: String
    let cardTitle: String
    let message: String
    let actionTitle: String?
    let action: () -> Void
    
    var body: some View {
        VStack(spacing: 14) {
            Image("PeelHostMenuBarIcon_256x256")
                .resizable()
                .scaledToFit()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 8) {
                StatusDot(status: status)
                    .opacity(status == .active ? 1.0 : 1.0)

                Text(statusTitle)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
            }

            VStack(spacing: 6) {
                Text(message)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)
            
            if let actionTitle {
                Button(actionTitle) {
                    action()
                }
                .controlSize(.small)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct PermissionStatusToggleRow: View {
    let title: String
    let message: String
    let statusText: String
    let status: WindowStreamStatus
    @Binding var isOn: Bool

    
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(status: status)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.callout.weight(.semibold))

                    Text(statusText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(status == .active ? .primary : .secondary)
                }

                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 6) {
                Toggle(isOn: $isOn) { }
                    .toggleStyle(.switch)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PermissionStatusRow: View {
    let title: String
    let message: String
    let statusText: String
    let status: WindowStreamStatus
    let actionTitle: String?
    let action: (() -> Void)?
    
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(status: status)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.callout.weight(.semibold))

                    Text(statusText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(status == .active ? .primary : .secondary)
                }

                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            if let actionTitle, let action {
                Button(actionTitle) {
                    action()
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}




/*
private struct StreamDiagnosticsSection: View {
    @ObservedObject var diagnostics: StreamDiagnosticsStore
    @Binding var isExpanded: Bool

    private var summaryText: String {
        if diagnostics.activeStreamCount > 0 {
            return "\(diagnostics.activeStreamCount) active"
        }

        if !diagnostics.lastDisconnectReason.isEmpty {
            return "Last disconnect"
        }

        return "Idle"
    }

    private var healthStatus: WindowStreamStatus {
        if diagnostics.outstandingVideoBytes > 2_000_000 || diagnostics.droppedRawFramesPerSecond > 20 {
            return .sleeping
        }

        if diagnostics.activeStreamCount > 0 || diagnostics.estimatedVideoMbps > 0.1 {
            return .active
        }

        return .offline
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DisclosureCardLabel(
                title: "Stream Status",
                subtitle: "Live diagnostics for quality, latency, and backpressure.",
                trailingText: summaryText,
                isExpanded: isExpanded,
                onTap: {
                    isExpanded.toggle()
                }
            )

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        StatusDot(status: healthStatus)
                            .padding(.top, 3)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(streamHealthTitle)
                                .font(.callout.weight(.semibold))

                            Text(streamHealthMessage)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }

                    Divider()
                        .opacity(0.45)

                    VStack(alignment: .leading, spacing: 6) {
                        StreamDiagnosticMetricRow(
                            title: "Active Streams",
                            value: "\(diagnostics.activeStreamCount)"
                        )

                        StreamDiagnosticMetricRow(
                            title: "Video Out",
                            value: String(format: "%.1f Mbps", diagnostics.estimatedVideoMbps)                        )

                        StreamDiagnosticMetricRow(
                            title: "Outstanding Video",
                            value: formattedBytes(diagnostics.outstandingVideoBytes)
                        )

                        StreamDiagnosticMetricRow(
                            title: "Dropped Raw Frames",
                            value: "\(diagnostics.droppedRawFramesPerSecond)/s"
                        )

                        StreamDiagnosticMetricRow(
                            title: "Encoded Frames",
                            value: "\(diagnostics.encodedFramesPerSecond)/s"
                        )

                        StreamDiagnosticMetricRow(
                            title: "Encode In Flight",
                            value: "\(diagnostics.encodeInFlightCount)"
                        )

                        StreamDiagnosticMetricRow(
                            title: "Sent Frames",
                            value: "\(diagnostics.sentFramesPerSecond)/s"
                        )

                        StreamDiagnosticMetricRow(
                            title: "Host Pipeline",
                            value: diagnostics.hostPipelineSummary
                        )
                    }
                    .font(.system(.caption, design: .monospaced))

                    if !diagnostics.lastDisconnectReason.isEmpty {
                        Divider()
                            .opacity(0.45)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Last Disconnect")
                                .font(.caption.weight(.semibold))

                            Text(diagnostics.lastDisconnectReason)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 10)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var streamHealthTitle: String {
        if diagnostics.outstandingVideoBytes > 2_000_000 {
            return "Network Backpressure"
        }

        if diagnostics.droppedRawFramesPerSecond > 20 {
            return "Dropping Frames"
        }

        if diagnostics.activeStreamCount > 0 {
            return "Streaming"
        }

        return "Idle"
    }

    private var streamHealthMessage: String {
        if diagnostics.outstandingVideoBytes > 2_000_000 {
            return "Video is queued faster than it is clearing. Peel may reduce quality or drop frames to stay live."
        }

        if diagnostics.droppedRawFramesPerSecond > 20 {
            return "Peel Pro is dropping stale frames before encode to keep latency down."
        }

        if diagnostics.activeStreamCount > 0 {
            return "The stream is active. Watch outstanding video and dropped frames when motion or window count increases."
        }

        return "No active video streams."
    }

    private func formattedBytes(_ bytes: Int) -> String {
        if bytes >= 1_000_000 {
            return String(format: "%.1f MB", Double(bytes) / 1_000_000.0)
        }

        if bytes >= 1_000 {
            return String(format: "%.0f KB", Double(bytes) / 1_000.0)
        }

        return "\(bytes) B"
    }
}

private struct StreamDiagnosticMetricRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            Text(value)
                .foregroundStyle(.primary)
        }
    }
}

*/

private struct PairedDevicesSection: View {
    @ObservedObject var store: PeelPairingStore
    let connectedPairingID: String?
    @Binding var isExpanded: Bool
    let onUnpair: (String) -> Void

    @State private var confirmUnpair: PeelPairedPeer?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private func formatDate(_ d: Date) -> String {
        Self.dateFormatter.string(from: d)
    }

    var body: some View {
        // Pull this out so the compiler isn’t chasing store.paired through the whole tree.
        let peers = store.paired

        return VStack(alignment: .leading, spacing: 0) {
            DisclosureCardLabel(
                title: "Devices",
                subtitle: peers.isEmpty ? "No paired devices yet." : "Manage devices that can connect to this Mac.",
                trailingText: "\(peers.count)",
                isExpanded: isExpanded,
                onTap: {
                    isExpanded.toggle()
                }
            )

            if isExpanded {
                content(peers: peers)
                    .padding(.top, 10)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .alert("Unpair device?", isPresented: Binding(
            get: { confirmUnpair != nil },
            set: { if !$0 { confirmUnpair = nil } }
        )) {
            Button("Unpair", role: .destructive) {
                if let peer = confirmUnpair {
                    onUnpair(peer.id)
                }
                confirmUnpair = nil
            }
            Button("Cancel", role: .cancel) {
                confirmUnpair = nil
            }
        } message: {
            if let peer = confirmUnpair {
                Text("This will revoke access for “\(peer.displayName)”. If it’s currently connected, it will be disconnected immediately.")
            } else {
                Text("")
            }
        }
    }

    @ViewBuilder
    private func content(peers: [PeelPairedPeer]) -> some View {
        if peers.isEmpty {
            Text("No paired devices yet.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    // Explicit id helps inference + avoids Identifiable gymnastics.
                    ForEach(peers, id: \.id) { peer in
                        PeerRow(
                            peer: peer,
                            isConnected: peer.id == connectedPairingID,
                            pairedText: "Paired: \(formatDate(peer.createdAt))",
                            lastSeenText: peer.lastSeenAt.map { "Last seen: \(formatDate($0))" },
                            onUnpairTap: { confirmUnpair = peer }
                        )
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 4)
            }
            .frame(maxHeight: 190)
        }
    }

    private struct PeerRow: View {
        let peer: PeelPairedPeer
        let isConnected: Bool
        let pairedText: String
        let lastSeenText: String?
        let onUnpairTap: () -> Void

        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(peer.displayName)
                            .font(.headline)

                        if isConnected {
                            Text("Connected")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.green.opacity(0.20)))
                        }

                        Spacer(minLength: 0)
                    }

                    Text(pairedText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if let lastSeenText {
                        Text(lastSeenText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button(role: .destructive) {
                    onUnpairTap()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .help("Unpair this device")
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.08))
            )
        }
    }
}

private struct DisclosureCardLabel: View {
    let title: String
    let subtitle: String
    let trailingText: String?
    let isExpanded: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.headline.weight(.semibold))
                
                if let trailingText {
                    Text(trailingText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                }
                
                Spacer(minLength: 0)
            }
            
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
    }
}
//@State private var //showingAbout = false
//
//Button {
//    showingAbout = true
//} label: {
//    Image(systemName: //"info.circle")
//}
//
//.sheet(isPresented: //$showingAbout) {
//    AboutPeelView()
//}

private final class PeelAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        installCloseToMinimizeDelegate()
    }

    func applicationDidUpdate(_ notification: Notification) {
        installCloseToMinimizeDelegate()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isSettingsWindow(sender) else {
            return true
        }

        closeSettingsWindows()
        sender.miniaturize(nil)
        return false
    }

    private func installCloseToMinimizeDelegate() {
        for window in NSApplication.shared.windows where shouldManageCloseButton(for: window) {
            if window.delegate == nil || window.delegate === self {
                window.delegate = self
            }
        }
    }

    private func shouldManageCloseButton(for window: NSWindow) -> Bool {
        guard window.canBecomeMain else { return false }
#if PEEL_HOST_INTEGRATION
        guard window.identifier != NSUserInterfaceItemIdentifier("peel.remote.stream") else { return false }
#endif
        guard window.isVisible else { return false }
        guard window.styleMask.contains(.closable) else { return false }
        guard !isSettingsWindow(window) else { return false }
        guard window.title != "Quit Peel Pro" else { return false }
        return true
    }

    private func closeSettingsWindows() {
        for window in NSApplication.shared.windows where isSettingsWindow(window) {
            window.close()
        }
    }

    private func isSettingsWindow(_ window: NSWindow) -> Bool {
#if PEEL_HOST_INTEGRATION
        // Settings are pages of the main window, not separate settings windows.
        false
#else
        window.title.localizedCaseInsensitiveContains("settings")
#endif
    }
}
