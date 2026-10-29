//
//  ContentView.swift
//  Peel-iPad
//
//  Created by Zach on 12/3/25.
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

enum PeelIOSAppWindowSortOrder: String, CaseIterable, Identifiable {
    case recentlyUsed
    case leastRecentlyUsed
    case longestRunning
    case shortestRunning

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentlyUsed:
            return "Recently Used"
        case .leastRecentlyUsed:
            return "Least Recently Used"
        case .longestRunning:
            return "Longest Running"
        case .shortestRunning:
            return "Shortest Running"
        }
    }
}

#if os(iOS)
private struct IPhoneAgentPresentationModifier: ViewModifier {
    @Binding var presentedWindow: HostedPeelWindow?

    @EnvironmentObject private var browser: PeelClientBrowser
    @EnvironmentObject private var store: PeelStore
    @EnvironmentObject private var coordinator: IPhoneAgentPresentationCoordinator
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $presentedWindow, onDismiss: {
                coordinator.phonePresentationDidDismiss()
            }) { hostedWindow in
                IPhoneAgentPresentationWindow(hostedWindow: hostedWindow)
                    .environmentObject(browser)
                    .environmentObject(store)
                    .environmentObject(coordinator)
            }
            .onAppear {
                coordinator.bindStore(store)
                coordinator.registerPhoneRoute(
                    presentedWindow: $presentedWindow,
                    scenePhase: scenePhase
                )
            }
            .onChange(of: scenePhase) { _, newPhase in
                coordinator.scenePhaseChanged(newPhase)
            }
            .onDisappear {
                // A full-screen cover can make the presenting view disappear
                // while the app remains active. Keep the route registered in
                // that case; the scene phase handles the real boundary.
                if scenePhase != .active {
                    coordinator.unregisterPhoneRoute()
                }
            }
    }
}
#endif

struct ContentView: View {
    @EnvironmentObject private var browser: PeelClientBrowser
    @EnvironmentObject private var scenes: SceneCoordinator
    @EnvironmentObject private var store: PeelStore
    @EnvironmentObject private var remoteNotificationPresenter: PeelLocalRemoteNotificationPresenter

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openURL) private var openURL
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @AppStorage("Peel.iOS.appWindowSortOrder") private var appWindowSortOrderRawValue: String = PeelIOSAppWindowSortOrder.recentlyUsed.rawValue

    @State private var showingPairSheet: Bool = false
    @State private var pairingHost: PeelHostInfo? = nil
    @State private var pairingToken: String = ""
    @State private var pairingAttemptStarted: Bool = false
    @State private var pairingAttemptStatus: String = ""

    @StateObject private var watchCompanion = PeelCompanionModel.shared
    @State private var showingWatchCompanion = ProcessInfo.processInfo.arguments.contains("--peel-watch-preview")
    @State private var showingSettings: Bool = false
    @State private var showingMachineStatus: Bool = false
    @State private var showingAudio: Bool = false
    @State private var showingAbout: Bool = false
    @State private var showingConnectByAddress: Bool = false
    @State private var showingWindowCapacityAlert = false
    @State private var proFeature: PeelProFeature? = nil
    @State private var locallyPendingHostIDs: Set<PeelHostInfo.ID> = []
    @State private var disconnectCooldownUntilByHostKey: [PeelHostKey: Date] = [:]

    @State private var pairingPIN: String = ""
    @State private var showAdvancedToken: Bool = false
    @State private var presentedPhoneWindow: HostedPeelWindow? = nil
    @StateObject private var hostAppearanceStore = PeelHostAppearanceStore()
    @State private var appearanceEditorHost: PeelHostInfo? = nil
    @State private var forgetPairingHost: PeelHostInfo? = nil
    @State private var forgetSavedPairingMac: PeelSavedPairedMac? = nil
    @State private var isIndividualAppWindowsExpanded = false
    @State private var isOtherComputersExpanded = false

    private let peelHostDownloadURL = URL(string: "https://peelpro.app")!

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemBackground)
                    .ignoresSafeArea()

                mainContent

                // Commerce resolves independently; free streaming stays usable.
            }
            .overlay(alignment: .top) {
                PeelRemoteNotificationBanner(
                    inbox: remoteNotificationPresenter.inbox
                )
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showingMachineStatus = true } label: {
                        Text(horizontalSizeClass == .regular ? "Computer Status" : "Status")
                    }
                    .accessibilityLabel("Computer Status")
                    .accessibilityIdentifier("peel.home.status")

                    // Regular width has room for Audio beside Status, matching
                    // the Vision ornament; compact width keeps it under More.
                    if horizontalSizeClass == .regular {
                        Button { showingAudio = true } label: {
                            Label("Audio", systemImage: "speaker.wave.2")
                        }
                        .accessibilityLabel("Audio")
                        .accessibilityIdentifier("peel.home.audio")
                    }

                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier("peel.home.settings")

                    Menu {
                        if horizontalSizeClass != .regular {
                            Button { showingAudio = true } label: {
                                Label("Audio", systemImage: "speaker.wave.2")
                            }
                            .accessibilityIdentifier("peel.home.audio")
                        }

                        Button { showingWatchCompanion = true } label: {
                            Label("Apple Watch & Cloud Agents", systemImage: "applewatch")
                        }
                        .accessibilityIdentifier("peel.watch.open")

                        Button { showingConnectByAddress = true } label: {
                            Label("Connect by Address…", systemImage: "network")
                        }
                        .accessibilityIdentifier("peel.home.connectByAddress")

                        Divider()

                        Button { showingAbout = true } label: {
                            Label("About Peel Pro", systemImage: "info.circle")
                        }
                        .accessibilityIdentifier("peel.home.about")
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More Options")
                    .accessibilityIdentifier("peel.home.more")
                }
            }
        }
        .sheet(isPresented: $showingWatchCompanion) {
            PeelWatchCompanionView(model: watchCompanion).environmentObject(browser)
        }
        .sheet(isPresented: $showingMachineStatus) {
            PeelMachineStatusSheet().environmentObject(browser)
        }
        .sheet(isPresented: $showingAudio) {
            PeelAudioControls().environmentObject(browser)
        }
        .sheet(isPresented: $showingAbout) {
            AboutPeelView()
        }
        .sheet(isPresented: $showingConnectByAddress) {
            connectByAddressSheet
        }
        .sheet(isPresented: $showingSettings) {
            ClientSettingsView(
                showsAgentPresentationSetting: true,
                onAgentPresentationOptInChanged: { _ in
                    browser.refreshAgentPresentationCapabilities()
                },
                notificationPresenter: remoteNotificationPresenter,
                onAgentNotificationsOptInChanged: { _ in
                    browser.refreshAgentPresentationCapabilities()
                }
            )
                .environmentObject(store)
        }
        .sheet(isPresented: $showingPairSheet) {
            pairSheet
        }
        .onReceive(browser.$pairingStatus) { status in
            guard showingPairSheet,
                  pairingAttemptStarted,
                  let status else { return }
            pairingAttemptStatus = status
        }
        .onChange(of: browser.pairingStateVersion) { _, _ in
            guard showingPairSheet,
                  let pairingHost,
                  browser.isPaired(pairingHost) else { return }
            showingPairSheet = false
        }
        .sheet(item: $appearanceEditorHost) { host in
            appearanceEditor(for: host)
        }
        .alert("Window limit reached", isPresented: $showingWindowCapacityAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Peel supports up to 12 simultaneous windows. Close another window to open this one.")
        }
        .sheet(item: $proFeature) { feature in
            PeelPaywallView(feature: feature)
                .environmentObject(store)
        }
        .alert("Purchase Error", isPresented: purchaseErrorBinding) {
            Button("OK") {
                store.clearError()
            }
        } message: {
            Text(store.purchaseErrorMessage ?? "Something went wrong.")
        }
        .alert(
            "Forget pairing?",
            isPresented: Binding(
                get: { forgetPairingHost != nil },
                set: { newValue in
                    if !newValue {
                        forgetPairingHost = nil
                    }
                }
            ),
            presenting: forgetPairingHost
        ) { host in
            Button("Cancel", role: .cancel) {
                forgetPairingHost = nil
            }

            Button("Forget", role: .destructive) {
                if browser.hasOwnedReadyConnection(to: host) {
                    browser.disconnect(from: host)
                }

                browser.forgetPairing(for: host)
                forgetPairingHost = nil
            }
        } message: { host in
            Text("This will remove the saved pairing for \(hostDisplayName(for: host)). You’ll need to pair again before reconnecting.")
        }

        .alert(
            "Forget pairing?",
            isPresented: Binding(
                get: { forgetSavedPairingMac != nil },
                set: { newValue in
                    if !newValue {
                        forgetSavedPairingMac = nil
                    }
                }
            ),
            presenting: forgetSavedPairingMac
        ) { savedMac in
            Button("Cancel", role: .cancel) {
                forgetSavedPairingMac = nil
            }

            Button("Forget", role: .destructive) {
                browser.forgetSavedPairing(savedMac)
                forgetSavedPairingMac = nil
            }
        } message: { savedMac in
            Text("This will remove the saved pairing for \(savedMacDisplayName(for: savedMac)). You’ll need to pair again before reconnecting.")
        }
#if os(iOS)
        .modifier(
            IPhoneAgentPresentationModifier(
                presentedWindow: $presentedPhoneWindow
            )
        )
#else
        .fullScreenCover(item: $presentedPhoneWindow) { hostedWindow in
            PeeledWindowView(hostedWindow: hostedWindow)
                .environmentObject(browser)
                .environmentObject(store)
        }
#endif
        .onChange(of: connectedSessionWindowSnapshot) { _, _ in
            handleLauncherAutoOpenHandoffIfNeeded()
            if let presentedPhoneWindow,
               let session = browser.session(for: presentedPhoneWindow.hostKey) {
                handlePhoneAutoPopupHandoffIfNeeded(windows: session.windows)
            }
        }
        .onReceive(browser.$hosts) { hosts in
            let inactivePendingIDs = locallyPendingHostIDs.filter { pendingID in
                guard let host = hosts.first(where: { $0.id == pendingID }) else { return true }
                return !browser.isConnecting(host) && !browser.hasOwnedReadyConnection(to: host)
            }

            for pendingID in inactivePendingIDs {
                locallyPendingHostIDs.remove(pendingID)
            }
        }
    }

    private var mainContent: some View {
        VStack(alignment: .center, spacing: 16) {
            HStack(spacing: 12) {
                Image("PeelHostMenuBarIcon_256x256")
                    .resizable()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Text("Remote Desktop")
                    .font(.largeTitle.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            VStack(alignment: .leading, spacing: 16) {
                // Saved-address sessions are not in Bonjour discovery; the
                // projection keeps them visible by their saved pairing.
                let computers = browser.homeComputerProjection()

                if !computers.showsComputerList(hasConnectedSession: hasConnectedHost) {
                    noHostsView
                } else {
                    List {
                        let _ = browser.pairingStateVersion
                        let connectedHosts = computers.connected

                        // Remote Desktop order: the connected computer first,
                        // then its desktops and app windows, then everything else.
                        if !connectedHosts.isEmpty {
                            Section(connectedHosts.count == 1 ? "Connected Computer" : "Connected Computers") {
                                ForEach(connectedHosts, id: \.id) { host in
                                    hostRow(for: host)
                                }
                            }
                        } else {
                            if !computers.other.isEmpty {
                                Section(header: Text("Computers")) {
                                    ForEach(computers.other, id: \.id) { host in
                                        hostRow(for: host)
                                    }
                                }
                            }

                            if !computers.saved.isEmpty {
                                Section("Saved Computers") {
                                    ForEach(computers.saved) { savedMac in
                                        savedMacRow(for: savedMac)
                                    }
                                }
                            }
                        }

                        if hasConnectedHost {
                            displaySection

                            if !hostedAppWindows.isEmpty {
                                Section {
                                    DisclosureGroup(isExpanded: $isIndividualAppWindowsExpanded) {
                                        ForEach(hostedAppWindows) { hostedWindow in
                                            appRow(for: hostedWindow)
                                        }
                                    } label: {
                                        HStack(spacing: 12) {
                                            Text("App Windows")
                                            Spacer()
                                            Menu {
                                                Picker("App Order", selection: appWindowSortOrderBinding) {
                                                    ForEach(PeelIOSAppWindowSortOrder.allCases) { sortOrder in
                                                        Text(sortOrder.title)
                                                            .tag(sortOrder)
                                                    }
                                                }
                                            } label: {
                                                Image(systemName: "arrow.up.arrow.down")
                                            }
                                        }
                                    }
                                }
                            } else if hostedDisplayCaptureWindows.isEmpty {
                                Section("App Windows") {
                                    PeelLoadingView(
                                        header: "No apps available",
                                        subhead: "Your computer may be locked, asleep, closed, or not currently showing any app windows. Unlock it and open an app to see it here.",
                                        variant: .minimal,
                                        showsLogo: false
                                    )
                                    .frame(maxWidth: .infinity)
                                    .frame(minHeight: 220)
                                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                                    .listRowBackground(Color.clear)
                                }
                            }

                            launcherSection
                        }

                        if !connectedHosts.isEmpty {
                            otherComputersSection(computers)
                        }

                        connectionOptionsSection
                    }
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                }

                Spacer()
            }
            .padding()
        }
    }


    private var noHostsView: some View {
        VStack(spacing: 22) {
            PeelLoadingView(
                title: "Looking for Computers",
                message: "Your computer must be awake and unlocked, with Peel Pro running. Both devices need the same Wi‑Fi and Local Network access.",
                variant: .searching
            )
            .frame(maxHeight: 520)

            VStack(spacing: 10) {
                Text("Need Peel Pro?")
                    .font(.headline)

                VStack(spacing: 3) {
                    Text("Open the download page on the computer you want to connect.")
                        .foregroundStyle(.secondary)

                    Button {
                        openURL(peelHostDownloadURL)
                    } label: {
                        Text("peelpro.app")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.blue)
                            .underline()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open the Peel Pro download page")

                    Button {
                        copyPeelHostDownloadLink()
                    } label: {
                        Label("Copy Link", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: 420)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            if !browser.pairingStore.paired.isEmpty {
                Button {
                    showingConnectByAddress = true
                } label: {
                    Label("Connect by Address…", systemImage: "network")
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Connect to a paired computer on your private network or VPN")
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Other discovered and saved computers stay one tap away while connected,
    /// like the computer list in a remote desktop app.
    private func otherComputersSection(
        _ computers: PeelHomeComputerProjection<PeelHostInfo, PeelSavedPairedMac>
    ) -> some View {
        let otherHosts = computers.other
        let savedMacs = computers.saved
        let count = otherHosts.count + savedMacs.count

        return Group {
            if count > 0 {
                Section {
                    DisclosureGroup(isExpanded: $isOtherComputersExpanded) {
                        ForEach(otherHosts, id: \.id) { host in
                            hostRow(for: host)
                        }

                        ForEach(savedMacs) { savedMac in
                            savedMacRow(for: savedMac)
                        }
                    } label: {
                        Text(count == 1 ? "1 Other Computer" : "\(count) Other Computers")
                    }
                    .accessibilityIdentifier("peel.home.otherComputers")
                }
            }
        }
    }

    private var connectionOptionsSection: some View {
        Section {
            Button {
                showingConnectByAddress = true
            } label: {
                Label("Connect by Address…", systemImage: "network")
            }
        } header: {
            Text("Connection Options")
        } footer: {
            Text("To pair another computer, choose it in the list and enter the 6-digit code shown in Peel Pro on that computer. More options are in Settings.")
        }
    }

    private var connectByAddressSheet: some View {
        NavigationStack {
            List {
                PeelDirectEndpointSection()
            }
            .navigationTitle("Connect by Address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingConnectByAddress = false }
                }
            }
        }
        .environmentObject(browser)
    }


    private var launcherSection: some View {
        Section("Launcher") {
            ForEach(connectedAppSessions.filter(\.isConnectionReady)) { session in
                Button {
                    if store.canUse(.legacyAppLauncher) {
                        session.openLauncherFolder()
                    } else {
                        presentProPaywall(.appLauncher)
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "folder.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text("Applications Folder")
                                    .font(.headline)
                                    .foregroundStyle(.primary)

                                if !store.canUse(.legacyAppLauncher) {
                                    proBadge
                                }
                            }

                            Text(connectedAppSessions.count > 1 ? session.host.name : "Finder")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }


    private var displaySection: some View {
        Section("Desktops") {
            if hostedDisplayCaptureWindows.isEmpty {
                PeelLoadingView(
                    header: "No desktops available",
                    subhead: "Your computer may be locked, asleep, closed, or not currently available for display mirroring.",
                    variant: .minimal,
                    showsLogo: false
                )
                .frame(maxWidth: .infinity)
                .frame(minHeight: 180)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
            } else {
                ForEach(hostedDisplayCaptureWindows) { hostedDisplayWindow in
                    Button {
                        openSelectedWindow(hostedDisplayWindow)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: displaySymbolName(for: hostedDisplayWindow.window))
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(displayWindowTitle(for: hostedDisplayWindow))
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                Text(displayCaptureSubtitle(for: hostedDisplayWindow.window))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }


    private var proBadge: some View {
        Image(systemName: "lock.fill")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.blue.opacity(0.15), in: Capsule())
            .foregroundStyle(.blue)
            .accessibilityLabel("Requires Pro")
    }

    private var pairSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                PeelLoadingView(
                    title: showAdvancedToken
                    ? "Advanced pairing"
                    : pairingHost.map { "Enter code from \(hostDisplayName(for: $0))" } ?? "Enter code from your computer",
                    message: showAdvancedToken
                    ? "Only use this if the 6-digit code is not working. Paste the advanced token from Peel Pro."
                    : "Use the 6-digit code shown in Peel Pro.",
                    variant: .minimal,
                    showsLogo: true
                )
                .frame(maxWidth: .infinity)

                if !showAdvancedToken {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Button("Paste") {
                                pastePairingPINFromClipboard()
                            }
                            .buttonStyle(.bordered)

                            TextField("6-digit code", text: $pairingPIN)
                                .keyboardType(.numberPad)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: pairingPIN) { _, newValue in
                                    sanitizePairingPIN(newValue)
                                }
                        }
                    }
                    .padding(14)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                if pairingAttemptStarted {
                    HStack(alignment: .top, spacing: 10) {
                        if isPairingInProgress {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(.orange)
                        }

                        Text(pairingAttemptStatus)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityElement(children: .combine)
                }

                HStack(spacing: 14) {
                    Button("Cancel") {
                        showingPairSheet = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: 150, minHeight: 48)

                    Button("Pair") {
                        submitPairingInput()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: 150, minHeight: 48)
                    .disabled(!canSubmitPairingInput || isPairingInProgress)
                }
                .frame(maxWidth: .infinity, alignment: .center)

                DisclosureGroup("Having trouble?", isExpanded: $showAdvancedToken) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Use the normal 6-digit code unless Peel Pro specifically gives you an advanced token.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(alignment: .top, spacing: 10) {
                            Button("Paste") {
                                pastePairingTokenFromClipboard()
                            }
                            .buttonStyle(.bordered)

                            TextField("Advanced pairing token", text: $pairingToken, axis: .vertical)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                                .lineLimit(3...8)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: pairingToken) { _, newValue in
                                    if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !pairingPIN.isEmpty {
                                        pairingPIN = ""
                                    }
                                }
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: showAdvancedToken) { _, isExpanded in
                    if isExpanded {
                        pairingPIN = ""
                    } else {
                        pairingToken = ""
                    }
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Pair")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        showingPairSheet = false
                    }
                }
            }
        }
    }

    private var purchaseErrorBinding: Binding<Bool> {
        Binding(
            get: { store.purchaseErrorMessage != nil },
            set: { newValue in
                if !newValue {
                    store.clearError()
                }
            }
        )
    }


    private func hostRow(for host: PeelHostInfo) -> some View {
        let updateMessage = updateRequiredMessage(for: host)

        return HStack(spacing: 12) {
            Image(systemName: hostSymbolName(for: host))
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(hostDisplayName(for: host))
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Label(
                    updateMessage ?? hostStatusText(for: host),
                    systemImage: updateMessage == nil ? hostStatusSymbolName(for: host) : "exclamationmark.triangle.fill"
                )
                .font(.subheadline)
                .foregroundStyle(updateMessage == nil ? hostStatusColor(for: host) : .orange)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            if updateMessage == nil &&
                (browser.isPairing(host) ||
                 (!browser.needsPairingRepair(host) &&
                  (isLocallyPending(host) || browser.isConnecting(host)))) {
                ProgressView()
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
            } else if updateMessage != nil {
                Button("Needs Update") { }
                    .buttonStyle(.bordered)
                    .disabled(true)
            } else if needsLocalPairingRepair(host) &&
                        !browser.hasOwnedReadyConnection(to: host) &&
                        !browser.isPairing(host) {
                Button("Pair again") {
                    requestPairing(for: host)
                }
                .buttonStyle(.borderedProminent)
            }

            Menu {
                if updateMessage == nil {
                    hostPrimaryMenuItems(for: host)

                    Divider()
                }

                Button("Set icon") {
                    presentAppearanceEditor(for: host)
                }

                if browser.isPaired(host) || browser.hasOwnedReadyConnection(to: host) || browser.isConnecting(host) {
                    Button("Forget pairing", role: .destructive) {
                        forgetPairingHost = host
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .padding(6)
            }
            .disabled(browser.isPairing(host))
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private func hostPrimaryMenuItems(for host: PeelHostInfo) -> some View {
        if browser.isPairing(host) {
            Text("Pairing…")
                .foregroundStyle(.secondary)
        } else if needsLocalPairingRepair(host) && !browser.hasOwnedReadyConnection(to: host) {
            Button("Pair again") {
                requestPairing(for: host)
            }
        } else if isLocallyPending(host) || browser.isConnecting(host) {
            Button("Cancel Connection", role: .destructive) {
                clearHostLocallyPending(host)
                browser.disconnect(from: host, reason: "Connection cancelled")
            }
        } else if browser.hasOwnedReadyConnection(to: host) {
            Button("Disconnect", role: .destructive) {
                guard !isDisconnectOnCooldown(for: host) else { return }
                beginDisconnectCooldown(for: host)
                browser.disconnect(from: host)
            }
            .disabled(isDisconnectOnCooldown(for: host))
        } else if browser.isPaired(host) {
            Button("Connect") {
                primaryHostAction(for: host)
            }
        } else {
            Button {
                primaryHostAction(for: host)
            } label: {
                Label(
                    "Pair",
                    systemImage: "link"
                )
            }
        }
    }


    private func savedMacRow(for savedMac: PeelSavedPairedMac) -> some View {
        let hasSavedAddress = browser.directEndpointRecord(for: savedMac.id) != nil

        return HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(savedMacDisplayName(for: savedMac))
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Label(
                    hasSavedAddress ? "Paired, saved address" : "Paired, not available",
                    systemImage: "link.circle.fill"
                )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Menu {
                if hasSavedAddress {
                    Button {
                        browser.connectToDirectEndpoint(for: savedMac.id)
                    } label: {
                        Label("Connect by Address", systemImage: "network")
                    }

                    Divider()
                }

                Button("Forget pairing", role: .destructive) {
                    forgetSavedPairingMac = savedMac
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .padding(6)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.clear)
    }


    private func appRow(for hostedWindow: HostedPeelWindow) -> some View {
        let window = hostedWindow.window

        return HStack(spacing: 12) {
#if canImport(UIKit)
            if let iconImage = browser.session(for: hostedWindow.hostKey)?.appIconImage(for: window) ?? browser.appIconImage(for: window) {
                Image(uiImage: iconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                Image(systemName: "macwindow")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
            }
#else
            Image(systemName: "macwindow")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
#endif

            VStack(alignment: .leading, spacing: 4) {
                Text(window.appName.isEmpty ? "(Untitled window)" : window.appName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if connectedAppSessions.count > 1 {
                    Text(hostedWindow.hostName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if !window.title.isEmpty,
                   window.title != window.appName {
                    Text(window.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button("Open") {
                openSelectedWindow(hostedWindow)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func appearanceEditor(for host: PeelHostInfo) -> some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: hostAppearanceStore.symbolName(for: host))
                            .font(.title3)
                            .frame(width: 28)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(hostDisplayName(for: host))
                                .font(.headline)

                            Text("Automatic currently resolves to \(hostAppearanceStore.automaticPreviewTitle(for: host)).")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Computer Icon") {
                    ForEach(PeelMacSymbolChoice.allCases) { choice in
                        Button {
                            hostAppearanceStore.setOverride(choice, for: host)
                            appearanceEditorHost = nil
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: choice == .automatic
                                      ? hostAppearanceStore.inferredChoice(for: host).symbolName
                                      : choice.symbolName)
                                    .frame(width: 24)
                                    .foregroundStyle(.secondary)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(choice.title)
                                        .foregroundStyle(.primary)

                                    if choice == .automatic {
                                        Text("Uses \(hostAppearanceStore.automaticPreviewTitle(for: host)) for this computer")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()

                                if hostAppearanceStore.overrideChoice(for: host) == choice {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Computer Icon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        appearanceEditorHost = nil
                    }
                }
            }
        }
    }

    private func displayNameWithoutPeelPrefix(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let proPrefix = "Peel Pro on "
        let legacyPrefix = "Peel on "

        if trimmed.range(of: proPrefix, options: [.caseInsensitive, .anchored]) != nil {
            return String(trimmed.dropFirst(proPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if trimmed.range(of: legacyPrefix, options: [.caseInsensitive, .anchored]) != nil {
            return String(trimmed.dropFirst(legacyPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return trimmed
    }

    private func hostDisplayName(for host: PeelHostInfo) -> String {
        displayNameWithoutPeelPrefix(host.name)
    }

    private func savedMacDisplayName(for savedMac: PeelSavedPairedMac) -> String {
        displayNameWithoutPeelPrefix(savedMac.displayName)
    }

    private func displayWindowTitle(for window: PeelWindow) -> String {
        if isDisplayCaptureWindow(window),
           let connectedHostName = browser.connectedHostName {
            return displayNameWithoutPeelPrefix(connectedHostName)
        }

        let cleanedTitle = displayNameWithoutPeelPrefix(window.title)

        if !cleanedTitle.isEmpty,
           cleanedTitle != "Mac Display",
           cleanedTitle != "Peel Display" &&
           cleanedTitle != "Peel Pro Display" {
            return cleanedTitle
        }

        return "Display"
    }

    private func displayWindowTitle(for hostedWindow: HostedPeelWindow) -> String {
        displayNameWithoutPeelPrefix(hostedWindow.hostName)
    }

    private func isDisplayCaptureWindow(_ window: PeelWindow) -> Bool {
        let appName = window.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        return appName == "Peel Display" || appName == "Peel Pro Display"
    }


    private var appWindowSortOrder: PeelIOSAppWindowSortOrder {
        PeelIOSAppWindowSortOrder(rawValue: appWindowSortOrderRawValue) ?? .recentlyUsed
    }

    private var appWindowSortOrderBinding: Binding<PeelIOSAppWindowSortOrder> {
        Binding(
            get: { appWindowSortOrder },
            set: { appWindowSortOrderRawValue = $0.rawValue }
        )
    }

    private func focusRankByWindowId(for session: PeelHostSession) -> [UInt32: Int] {
        var result: [UInt32: Int] = [:]

        for (index, windowId) in session.recentlyFocusedWindowIds.enumerated() {
            if result[windowId] == nil {
                result[windowId] = index
            }
        }

        let fallbackStartIndex = result.count

        for (index, window) in session.windows.enumerated() {
            if result[window.windowId] == nil {
                result[window.windowId] = fallbackStartIndex + index
            }
        }

        return result
    }

    private func appSortName(for window: PeelWindow) -> String {
        let appName = window.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)

        if appName.isEmpty {
            return title.isEmpty ? "(Untitled window)" : title
        }

        if title.isEmpty || title == "Window" {
            return appName
        }

        return "\(appName) \(title)"
    }

    private func isAppWindowTieBreakerOrderedBefore(_ lhs: PeelWindow, _ rhs: PeelWindow) -> Bool {
        let lhsName = appSortName(for: lhs)
        let rhsName = appSortName(for: rhs)

        let nameComparison = lhsName.localizedCaseInsensitiveCompare(rhsName)
        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }

        return lhs.windowId < rhs.windowId
    }

    private func compareLaunchTime(_ lhs: PeelWindow, _ rhs: PeelWindow, newestFirst: Bool) -> Bool? {
        switch (lhs.appLaunchTimeIntervalSince1970, rhs.appLaunchTimeIntervalSince1970) {
        case let (lhsLaunch?, rhsLaunch?):
            if lhsLaunch != rhsLaunch {
                return newestFirst ? lhsLaunch > rhsLaunch : lhsLaunch < rhsLaunch
            }
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            break
        }

        return nil
    }

    private func compareFocusRank(
        _ lhs: PeelWindow,
        _ rhs: PeelWindow,
        focusRankByWindowId: [UInt32: Int],
        mostRecentFirst: Bool
    ) -> Bool? {
        switch (focusRankByWindowId[lhs.windowId], focusRankByWindowId[rhs.windowId]) {
        case let (lhsRank?, rhsRank?):
            if lhsRank != rhsRank {
                return mostRecentFirst ? lhsRank < rhsRank : lhsRank > rhsRank
            }
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            break
        }

        return nil
    }

    private func isHostedAppWindow(_ lhs: HostedPeelWindow, orderedBefore rhs: HostedPeelWindow) -> Bool {
        let lhsWindow = lhs.window
        let rhsWindow = rhs.window

        switch appWindowSortOrder {
        case .recentlyUsed:
            if lhs.hostKey == rhs.hostKey,
               let session = browser.session(for: lhs.hostKey),
               let focusSort = compareFocusRank(
                   lhsWindow,
                   rhsWindow,
                   focusRankByWindowId: focusRankByWindowId(for: session),
                   mostRecentFirst: true
               ) {
                return focusSort
            }
        case .leastRecentlyUsed:
            if lhs.hostKey == rhs.hostKey,
               let session = browser.session(for: lhs.hostKey),
               let focusSort = compareFocusRank(
                   lhsWindow,
                   rhsWindow,
                   focusRankByWindowId: focusRankByWindowId(for: session),
                   mostRecentFirst: false
               ) {
                return focusSort
            }
        case .longestRunning:
            if let launchSort = compareLaunchTime(lhsWindow, rhsWindow, newestFirst: false) {
                return launchSort
            }
        case .shortestRunning:
            if let launchSort = compareLaunchTime(lhsWindow, rhsWindow, newestFirst: true) {
                return launchSort
            }
        }

        let nameComparison = appSortName(for: lhsWindow).localizedCaseInsensitiveCompare(appSortName(for: rhsWindow))
        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }

        let hostComparison = lhs.hostName.localizedCaseInsensitiveCompare(rhs.hostName)
        if hostComparison != .orderedSame {
            return hostComparison == .orderedAscending
        }

        return lhsWindow.windowId < rhsWindow.windowId
    }

    private var connectedAppSessions: [PeelHostSession] {
        browser.sessionsByHostKey.values
            .filter { session in
                session.isConnectionReady || session.connection != nil || !session.windows.isEmpty
            }
            .sorted { lhs, rhs in
                displayNameWithoutPeelPrefix(lhs.host.name)
                    .localizedCaseInsensitiveCompare(displayNameWithoutPeelPrefix(rhs.host.name)) == .orderedAscending
            }
    }

    private var hasConnectedHost: Bool {
        browser.isConnectionReady || connectedAppSessions.contains { $0.isConnectionReady || $0.connection != nil }
    }

    private var connectedSessionWindowSnapshot: [HostedPeelWindow] {
        connectedAppSessions.flatMap { session in
            session.windows.map { hostedWindow(for: session, window: $0) }
        }
    }

    private var hostedAppWindows: [HostedPeelWindow] {
        connectedAppSessions
            .flatMap { session in
                session.windows
                    .filter { !isDisplayCaptureWindow($0) }
                    .map { hostedWindow(for: session, window: $0) }
            }
            .sorted { lhs, rhs in
                isHostedAppWindow(lhs, orderedBefore: rhs)
            }
    }

    private var hostedDisplayCaptureWindows: [HostedPeelWindow] {
        connectedAppSessions
            .flatMap { session in
                session.windows
                    .filter { isDisplayCaptureWindow($0) }
                    .map { hostedWindow(for: session, window: $0) }
            }
            .sorted { lhs, rhs in
                let hostComparison = lhs.hostName.localizedCaseInsensitiveCompare(rhs.hostName)
                if hostComparison != .orderedSame {
                    return hostComparison == .orderedAscending
                }

                return lhs.window.windowId < rhs.window.windowId
            }
    }

    private func displayCaptureSubtitle(for window: PeelWindow) -> String {
        if window.width > 0, window.height > 0 {
            return "\(window.width) × \(window.height)"
        }

        return "Full display stream"
    }

    private func presentProPaywall(_ feature: PeelProFeature) {
        if showingPairSheet {
            showingPairSheet = false

            Task { @MainActor in
                await Task.yield()
                proFeature = feature
            }
        } else {
            proFeature = feature
        }
    }

    private func beginPairing(for host: PeelHostInfo) {
        pairingHost = host
        pairingPIN = ""
        pairingToken = ""
        pairingAttemptStarted = false
        pairingAttemptStatus = ""
        browser.pairingStatus = nil
        showAdvancedToken = false
        showingPairSheet = true
    }

    private func requestPairing(for host: PeelHostInfo) {
        guard host.directPairingID == nil else { return }
        beginPairing(for: host)
    }

    private var pairingPINTrimmed: String {
        pairingPIN.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var pairingTokenTrimmed: String {
        pairingToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmitPairingInput: Bool {
        pairingHost != nil &&
        ((pairingPINTrimmed.isEmpty && !pairingTokenTrimmed.isEmpty) ||
         (pairingPINTrimmed.count == 6 &&
          pairingPINTrimmed.allSatisfy(\.isNumber) &&
          pairingTokenTrimmed.isEmpty))
    }

    private var isPairingInProgress: Bool {
        guard let pairingHost else { return false }
        return browser.isPairing(pairingHost) || browser.isConnecting(pairingHost)
    }

    private func sanitizePairingPIN(_ newValue: String) {
        let digitsOnly = newValue.filter { $0.isNumber }
        let limitedDigits = String(digitsOnly.prefix(6))

        if pairingPIN != limitedDigits {
            pairingPIN = limitedDigits
        }

        if !limitedDigits.isEmpty && !pairingToken.isEmpty {
            pairingToken = ""
        }
    }

    private func pastePairingPINFromClipboard() {
#if canImport(UIKit)
        let pasted = UIPasteboard.general.string ?? ""
        showAdvancedToken = false
        pairingToken = ""
        sanitizePairingPIN(pasted)
#endif
    }

    private func pastePairingTokenFromClipboard() {
#if canImport(UIKit)
        let pasted = UIPasteboard.general.string ?? ""
        pairingPIN = ""
        showAdvancedToken = true
        pairingToken = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
#endif
    }

    private func copyPeelHostDownloadLink() {
#if canImport(UIKit)
        UIPasteboard.general.string = peelHostDownloadURL.absoluteString
#endif
    }

    private func submitPairingInput() {
        guard let host = pairingHost, canSubmitPairingInput else { return }

        pairingAttemptStarted = true
        pairingAttemptStatus = "Starting pairing with \(hostDisplayName(for: host))…"

        if !pairingPINTrimmed.isEmpty {
            browser.pairWithPIN(host: host, pin: pairingPINTrimmed)
        } else {
            _ = browser.pair(host: host, token: pairingTokenTrimmed)
        }
    }

    /// Pairing runs only against a discovered service. A saved-address
    /// descriptor's service is never resolved, so it is never offered pairing.
    private func needsLocalPairingRepair(_ host: PeelHostInfo) -> Bool {
        host.directPairingID == nil && browser.needsPairingRepair(host)
    }

    private func primaryHostAction(for host: PeelHostInfo) {
        guard !browser.isPairing(host), !browser.isConnecting(host), !isLocallyPending(host) else { return }

        // Saved-address sessions reconnect only through their exact saved
        // pairing and endpoint.
        if let directPairingID = host.directPairingID {
            guard !browser.hasOwnedReadyConnection(to: host) else { return }
            browser.connectToDirectEndpoint(for: directPairingID)
            return
        }

        if browser.needsPairingRepair(host) {
            requestPairing(for: host)
            return
        }

        if browser.isPaired(host) {
            guard !browser.hasOwnedReadyConnection(to: host) else { return }
            markHostLocallyPending(host)
            browser.connectAndRequestWindows(for: host)

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if !browser.isConnecting(host), !browser.hasOwnedReadyConnection(to: host) {
                    clearHostLocallyPending(host)
                }
            }
        } else {
            requestPairing(for: host)
        }
    }

    private func isLocallyPending(_ host: PeelHostInfo) -> Bool {
        locallyPendingHostIDs.contains(host.id)
    }

    private func markHostLocallyPending(_ host: PeelHostInfo) {
        locallyPendingHostIDs.insert(host.id)
    }

    private func clearHostLocallyPending(_ host: PeelHostInfo) {
        locallyPendingHostIDs.remove(host.id)
    }

    private func isDisconnectOnCooldown(for host: PeelHostInfo) -> Bool {
        guard let disconnectCooldownUntil = disconnectCooldownUntilByHostKey[host.hostKey] else { return false }
        return Date() < disconnectCooldownUntil
    }

    private func beginDisconnectCooldown(for host: PeelHostInfo) {
        let hostKey = host.hostKey
        let cooldownEnd = Date().addingTimeInterval(0.85)
        disconnectCooldownUntilByHostKey[hostKey] = cooldownEnd

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 850_000_000)

            if disconnectCooldownUntilByHostKey[hostKey] == cooldownEnd {
                withAnimation(.easeInOut(duration: 0.2)) {
                    disconnectCooldownUntilByHostKey[hostKey] = nil
                }
            }
        }
    }

    private func presentAppearanceEditor(for host: PeelHostInfo) {
        guard store.canUse(.customMacIcons) else {
            presentProPaywall(.macIcon)
            return
        }

        appearanceEditorHost = host
    }


    private func updateRequiredMessage(for host: PeelHostInfo) -> String? {
        let sessionStatus = browser.session(for: host.hostKey)?.status.trimmingCharacters(in: .whitespacesAndNewlines)

        let status: String
        if let sessionStatus, !sessionStatus.isEmpty {
            status = sessionStatus
        } else if browser.selectedHostKey == host.hostKey {
            status = browser.status.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            return nil
        }

        let lowercasedStatus = status.lowercased()

        guard lowercasedStatus.contains("not compatible") ||
                lowercasedStatus.contains("needs update") ||
                lowercasedStatus.contains("update peel") ||
                lowercasedStatus.contains("protocol mismatch") else {
            return nil
        }

        guard browser.isPaired(host) || browser.hasOwnedReadyConnection(to: host) || browser.isConnecting(host) else {
            return nil
        }

        if lowercasedStatus.contains("update peel host") {
            return "Update Peel Pro"
        }

        if lowercasedStatus.contains("update peel pro") {
            return "Update Peel Pro"
        }

        return "Needs Update"
    }

    private func displaySymbolName(for window: PeelWindow) -> String {
        guard let aspectRatio = displayAspectRatio(for: window) else {
            return "display"
        }

        switch aspectRatio {
        case ..<1.70:
            return "macbook"
        case 1.70..<2.05:
            return "display"
        default:
            return "display"
        }
    }

    private func displayAspectRatio(for window: PeelWindow) -> Float? {
        let text = "\(displayWindowTitle(for: window)) \(displayCaptureSubtitle(for: window))"
        let pattern = #"(\d{3,5})\s*[x×]\s*(\d{3,5})"#

        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
              ),
              match.numberOfRanges >= 3,
              let widthRange = Range(match.range(at: 1), in: text),
              let heightRange = Range(match.range(at: 2), in: text),
              let width = Float(text[widthRange]),
              let height = Float(text[heightRange]),
              width > 0,
              height > 0
        else {
            return nil
        }

        let longSide = max(width, height)
        let shortSide = min(width, height)
        return longSide / shortSide
    }

    @ViewBuilder
    private func hostPrimaryActionButton(for host: PeelHostInfo) -> some View {
        if isLocallyPending(host) || browser.isConnecting(host) || browser.isPairing(host) {
            ProgressView()
                .controlSize(.small)
                .foregroundStyle(.secondary)
        } else if browser.hasOwnedReadyConnection(to: host) || browser.isPaired(host) {
            EmptyView()
        } else {
            HStack(spacing: 8) {
                Button("Pair") {
                    primaryHostAction(for: host)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func hostSymbolName(for host: PeelHostInfo) -> String {
        hostAppearanceStore.symbolName(for: host)
    }

    private func hostStatusText(for host: PeelHostInfo) -> String {
        if browser.hasOwnedReadyConnection(to: host) {
            return "Connected"
        } else if browser.isPairing(host) {
            return "Pairing…"
        } else if browser.needsPairingRepair(host) {
            return "Pair again"
        } else if browser.isConnecting(host) || isLocallyPending(host) {
            return "Connecting…"
        } else if browser.isPaired(host) {
            return "Paired"
        } else {
            return "Not paired"
        }
    }

    private func hostStatusSymbolName(for host: PeelHostInfo) -> String {
        if browser.hasOwnedReadyConnection(to: host) {
            return "checkmark.circle.fill"
        } else if browser.needsPairingRepair(host) {
            return "exclamationmark.triangle.fill"
        } else if browser.isPaired(host) {
            return "link.circle.fill"
        } else {
            return "circle"
        }
    }

    private func hostStatusColor(for host: PeelHostInfo) -> Color {
        if browser.hasOwnedReadyConnection(to: host) {
            return .green
        } else if browser.isPairing(host) {
            return .secondary
        } else if browser.needsPairingRepair(host) {
            return .orange
        } else if browser.isConnecting(host) || isLocallyPending(host) {
            return .secondary
        } else if browser.isPaired(host) {
            return .blue
        } else {
            return .secondary
        }
    }

    private func hostedWindow(for session: PeelHostSession, window: PeelWindow) -> HostedPeelWindow {
        HostedPeelWindow(
            hostKey: session.hostKey,
            hostName: displayNameWithoutPeelPrefix(session.host.name),
            window: window
        )
    }

    private func hostedWindowForSelectedSession(_ window: PeelWindow) -> HostedPeelWindow? {
        guard let session = browser.selectedSession else { return nil }
        return hostedWindow(for: session, window: window)
    }

    private func handleWindowOpenButtonTapped(_ window: PeelWindow) {
        guard let hostedWindow = hostedWindowForSelectedSession(window) else { return }
        openSelectedWindow(hostedWindow)
    }

    private func handleLauncherAutoOpenHandoffIfNeeded() {
        for session in connectedAppSessions {
            if let window = session.consumePendingHostCommandAutoOpenWindow() {
                session.setActiveWindow(window.windowId)
                openSelectedWindow(hostedWindow(for: session, window: window))
                return
            }
        }

        guard let window = browser.consumePendingHostCommandAutoOpenWindow(),
              let hostedWindow = hostedWindowForSelectedSession(window) else { return }

        browser.selectedSession?.setActiveWindow(window.windowId)
        openSelectedWindow(hostedWindow)
    }

    private func handlePhoneAutoPopupHandoffIfNeeded(windows: [PeelWindow]) {
#if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        guard let currentHostedWindow = presentedPhoneWindow,
              let session = browser.session(for: currentHostedWindow.hostKey) else { return }

        let current = currentHostedWindow.window

        if let popup = session.consumeAutoPopupHandoff(from: current.windowId) {
            session.forceMouseUpIfNeeded(reason: "auto popup handoff")
            session.setActiveWindow(popup.windowId)
            presentedPhoneWindow = hostedWindow(for: session, window: popup)
            return
        }

        let currentStillExists = windows.contains(where: { $0.windowId == current.windowId })

        if !currentStillExists, session.isAutoPopupWindow(current.windowId) {
            let parent = session.returnParentWindow(forAutoPopup: current.windowId)
            session.clearAutoPopupTracking(for: current.windowId)
            presentedPhoneWindow = parent.map { hostedWindow(for: session, window: $0) }
        }
#endif
    }

    @discardableResult
    private func transitionToPeeledWindowOnPad(_ hostedWindow: HostedPeelWindow) -> Bool {
        if scenes.activatePeeledWindowIfPossible(for: hostedWindow) {
            dismissMainAfterPeeledWindowTransition()
            return true
        }

        // A pending request already owns its slot; repeated taps must not
        // create another value scene or prompt for the same stream.
        if scenes.isPeeledWindowOpen(hostedWindow) { return true }
        guard scenes.reservePeeledWindowScene(for: hostedWindow) else {
            if !store.hasProAccess { presentProPaywall(.multipleWindows) }
            else { showingWindowCapacityAlert = true }
            return false
        }
        openWindow(id: "peeled-window", value: PeeledWindowSceneRequest(hostedWindow: hostedWindow))

        dismissMainAfterPeeledWindowTransition()
        return true
    }

    private func dismissMainAfterPeeledWindowTransition() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            dismissWindow(id: "main")
        }
    }

    @discardableResult
    private func openSelectedWindow(_ hostedWindow: HostedPeelWindow) -> Bool {
        guard let session = browser.session(for: hostedWindow.hostKey) else { return false }

        let window = hostedWindow.window

#if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            session.recordFocusedWindowId(window.windowId)
            session.setActiveWindow(window.windowId)
            presentedPhoneWindow = hostedWindow
            return true
        } else {
            let isAlreadyOpen = scenes.isPeeledWindowOpen(hostedWindow)

            if !isAlreadyOpen {
                guard scenes.canOpenAnotherPeeledWindow() else {
                    if !store.hasProAccess { presentProPaywall(.multipleWindows) }
                    else { showingWindowCapacityAlert = true }
                    return false
                }
            }

            session.recordFocusedWindowId(window.windowId)
            session.setActiveWindow(window.windowId)
            return transitionToPeeledWindowOnPad(hostedWindow)
        }
#else
        session.recordFocusedWindowId(window.windowId)
        session.setActiveWindow(window.windowId)
        openWindow(id: "peeled-window", value: PeeledWindowSceneRequest(hostedWindow: hostedWindow))
        dismissWindow(id: "main")
        return true
#endif
    }

}
