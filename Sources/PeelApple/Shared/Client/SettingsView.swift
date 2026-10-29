import SwiftUI
import StoreKit
import PeelShellUI

#if os(iOS)
import UIKit
#endif

#if os(iOS) || os(visionOS)
typealias PeelSettingsNotificationPresenter = PeelLocalRemoteNotificationPresenter
#else
typealias PeelSettingsNotificationPresenter = AnyObject
#endif

struct ClientSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.requestReview) private var requestReview
    @EnvironmentObject private var browser: PeelClientBrowser
    @EnvironmentObject private var store: PeelStore
#if os(iOS)
    @State private var showingAudio = false
    @State private var showingAbout = false
    @State private var showingNotifications = false
#endif
    @AppStorage("peel.showInputModeControls") private var showInputModeControls: Bool = false
    @AppStorage("peel.rightClickModeStaysEnabled") private var rightClickModeStaysEnabled: Bool = false
    @AppStorage("peel.showScrollControlButtons") private var showScrollControlButtons: Bool = true
    @AppStorage("peel.showZoomButtons") private var showZoomButtons: Bool = true
    @AppStorage("peel.showKeyboardMacroKeys") private var showKeyboardMacroKeys: Bool = true
    @AppStorage("peel.showKeyboardArrowKeys") private var showKeyboardArrowKeys: Bool = true
    @AppStorage(PeelSourceControlsVisibility.showVolumeKey) private var showSourceVolume: Bool = true
    @AppStorage(PeelSourceControlsVisibility.showMediaControlsKey) private var showSourceMediaControls: Bool = true
    @AppStorage("peel.useBalancedWindowLayout") private var useBalancedWindowLayout: Bool = true
    @AppStorage("peel.openTopAppsLimit") private var openTopAppsLimit: Int = 5
    @AppStorage(PeelAgentPresentation.optInDefaultsKey) private var allowAgentPresentation: Bool = false
    @AppStorage(PeelManualAgentControl.optInDefaultsKey) private var allowManualAgentControl: Bool = false
    private var manualAgentControlSection: some View {
#if os(iOS) || os(visionOS)
        Section("Visible Window Agent Control") {
            Toggle("Allow agents to control my open stream", isOn: $allowManualAgentControl)
                .disabled(!aiFeaturesAllowed && !allowManualAgentControl)
                .onChange(of: allowManualAgentControl) { _, _ in browser.refreshAgentPresentationCapabilities() }
            if !aiFeaturesAllowed { aiFeatureAccessMessage }
            Text("An agent on the connected computer can inspect and control only the window you have opened and selected in Peel Pro. The computer also requires separate Agent Control consent. Turn this off, close the view, background Peel Pro or send input to stop the agent. Automatic window opening is a separate permission. Spatial views are currently unsupported.")
                .font(.caption).foregroundStyle(.secondary)
        }
#else
        EmptyView()
#endif
    }

#if os(iOS) || os(visionOS)
    @AppStorage(PeelAgentNotifications.optInDefaultsKey) private var allowAgentNotifications: Bool = false
    @State private var notificationAuthorizationPending = false
#endif
#if os(visionOS)
    @AppStorage("peel.peeledWindowHostingMode") private var peeledWindowHostingMode: PeeledWindowHostingMode = .inPlace
    @AppStorage("peel.showHUDTab") private var showHUDTab: Bool = false
#endif

    let showsAgentPresentationSetting: Bool
    let onAgentPresentationOptInChanged: ((Bool) -> Void)?
    let notificationPresenter: PeelSettingsNotificationPresenter?
    let onAgentNotificationsOptInChanged: ((Bool) -> Void)?

    init(
        showsAgentPresentationSetting: Bool = false,
        onAgentPresentationOptInChanged: ((Bool) -> Void)? = nil,
        notificationPresenter: PeelSettingsNotificationPresenter? = nil,
        onAgentNotificationsOptInChanged: ((Bool) -> Void)? = nil
    ) {
        self.showsAgentPresentationSetting = showsAgentPresentationSetting
        self.onAgentPresentationOptInChanged = onAgentPresentationOptInChanged
#if os(iOS) || os(visionOS)
        self.notificationPresenter = notificationPresenter ?? PeelLocalRemoteNotificationPresenter.shared
#else
        self.notificationPresenter = notificationPresenter
#endif
        self.onAgentNotificationsOptInChanged = onAgentNotificationsOptInChanged
    }

#if os(iOS) || os(visionOS)
    private func updateAgentNotificationsOptIn(_ enabled: Bool) {
        if let onAgentNotificationsOptInChanged {
            onAgentNotificationsOptInChanged(enabled)
        } else {
            browser.refreshAgentPresentationCapabilities()
        }
    }

    private var shouldShowAgentNotificationsSetting: Bool {
#if os(iOS)
        return true
#else
        return true
#endif
    }

    private var agentNotificationsBinding: Binding<Bool> {
        Binding(
            get: { allowAgentNotifications },
            set: { newValue in
                if newValue {
                    guard aiFeaturesAllowed else {
                        allowAgentNotifications = false
                        updateAgentNotificationsOptIn(false)
                        return
                    }

                    guard !notificationAuthorizationPending,
                          let notificationPresenter else {
                        allowAgentNotifications = false
                        updateAgentNotificationsOptIn(false)
                        return
                    }

                    notificationAuthorizationPending = true
                    notificationPresenter.requestAuthorizationFromUser { result in
                        notificationAuthorizationPending = false
                        switch result {
                        case .success(true):
                            guard aiFeaturesAllowed else {
                                allowAgentNotifications = false
                                notificationPresenter.disableLocalDelivery()
                                updateAgentNotificationsOptIn(false)
                                return
                            }
                            allowAgentNotifications = true
                            updateAgentNotificationsOptIn(true)
                        case .success(false), .failure:
                            allowAgentNotifications = false
                            notificationPresenter.disableLocalDelivery()
                            updateAgentNotificationsOptIn(false)
                        }
                    }
                } else {
                    allowAgentNotifications = false
                    notificationPresenter?.disableLocalDelivery()
                    updateAgentNotificationsOptIn(false)
                }
            }
        )
    }

    @ViewBuilder
    private var agentNotificationsControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: agentNotificationsBinding) {
                Label("Allow AI notifications", systemImage: "bell.badge")
            }
            .disabled(notificationAuthorizationPending || (!aiFeaturesAllowed && !allowAgentNotifications))

            if notificationAuthorizationPending {
                ProgressView("Requesting permission…")
                    .font(.footnote)
                    .padding(.leading, 44)
            }

            settingFootnote("Let approved actions from your computer send plain text notifications to this device")

#if os(iOS)
            if notificationPresenter != nil {
                Button {
                    showingNotifications = true
                } label: {
                    Label("View notification history", systemImage: "bell")
                }
            }
#endif
        }
    }
#endif

    private var selectedWindowLayout: Binding<WindowLayoutSetting> {
        Binding(
            get: { useBalancedWindowLayout ? .balanced : .horizontal },
            set: { useBalancedWindowLayout = ($0 == .balanced) }
        )
    }

    private var showZoomButtonsBinding: Binding<Bool> {
        Binding(
            get: { showZoomButtons },
            set: { newValue in
                showZoomButtons = newValue
                if newValue {
                    showInputModeControls = false
                    rightClickModeStaysEnabled = false
                }
            }
        )
    }

    private var showInputModeControlsBinding: Binding<Bool> {
        Binding(
            get: { showInputModeControls },
            set: { newValue in
                showInputModeControls = newValue
                if newValue {
                    showZoomButtons = false
                } else {
                    rightClickModeStaysEnabled = false
                }
            }
        )
    }

    private var holdLeftRightModeBinding: Binding<Bool> {
        Binding(
            get: { showInputModeControls && rightClickModeStaysEnabled },
            set: { newValue in
                rightClickModeStaysEnabled = showInputModeControls && newValue
            }
        )
    }

    private var appName: String {
        if let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return displayName
        }
#if os(visionOS)
        return "Peel Pro"
#elseif os(iOS)
        return "Peel Pro"
#else
        return "Peel Pro"
#endif
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var termsURL: URL { URL(string: "https://zephyrstudios.dev/terms-of-use.html")! }
    private var privacyURL: URL { URL(string: "https://zephyrstudios.dev/privacy-policy.html")! }

    private var aiFeaturesAllowed: Bool {
        store.canUse(.agentCoordination)
    }

    private var aiFeatureAccessMessage: some View {
        Text("Peel Pro unlocks agent automation and notifications. Monthly, yearly and lifetime plans include the same access. Existing lifetime buyers are included.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private func settingFootnote(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.leading, 44)
    }

    /// Presentation only: hiding these never changes audio playback, the
    /// computer's volume or any permission.
    @ViewBuilder
    private var sourceControlsVisibilityToggles: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $showSourceVolume) {
                Label("Computer Volume", systemImage: "speaker.wave.2")
            }

            settingFootnote("Show mute and volume controls that change the streamed computer's own sound. Listening on this device is separate")
        }

        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $showSourceMediaControls) {
                Label("Media Controls", systemImage: "playpause")
            }

            settingFootnote("Show previous, play/pause and next for the streamed computer")
        }
    }

    private enum WindowLayoutSetting: String, CaseIterable, Identifiable {
        case horizontal
        case balanced

        var id: String { rawValue }

        var title: String {
            switch self {
            case .horizontal: "Panorama"
            case .balanced: "Grid"
            }
        }

        var systemImage: String {
            switch self {
            case .horizontal: "rectangle.split.3x1.fill"
            case .balanced: "square.grid.3x3.fill"
            }
        }
    }

#if os(iOS)
    private var connectionSettings: some View {
        List {
            Section {
                Button {
                    showingAudio = true
                } label: {
                    Label("Audio & Voice", systemImage: "speaker.wave.2")
                }
            }

            PeelICloudPairingSection()
            PeelDirectEndpointSection()
            manualAgentControlSection
            if showsAgentPresentationSetting {
                Section("Automation") {
                    if !aiFeaturesAllowed {
                        aiFeatureAccessMessage
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: $allowAgentPresentation) {
                            Label("Allow AI window opening", systemImage: "sparkles.rectangle.stack")
                        }
                        .disabled(!aiFeaturesAllowed && !allowAgentPresentation)
                        .onChange(of: allowAgentPresentation) { _, newValue in
                            onAgentPresentationOptInChanged?(newValue)
                        }

                        settingFootnote("Let approved actions from your computer open a window on this device. Keep Peel Pro open with a paired computer connection active, and allow local agents in Peel Pro.")
                    }

                    if shouldShowAgentNotificationsSetting {
                        agentNotificationsControl
                    }
                }
            } else if shouldShowAgentNotificationsSetting {
                Section("Automation") {
                    if !aiFeaturesAllowed {
                        aiFeatureAccessMessage
                    }
                    agentNotificationsControl
                }
            }

            PeelAISubscriptionSection()
        }
        .navigationTitle("Connection Options")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingAudio) {
            PeelAudioControls()
        }
        .sheet(isPresented: $showingNotifications) {
            if let notificationPresenter {
                NavigationStack {
                    PeelRemoteNotificationInboxView(inbox: notificationPresenter.inbox)
                }
            }
        }
    }
#endif

    private var locallyTrustedCloudDiscoveryIDs: Set<String> {
        Set(browser.pairingStore.paired.compactMap { peer -> String? in
            guard browser.pairingStore.psk(for: peer.id)?.count == 32 else { return nil }
            return peer.stableHostId
        })
    }

    private var accountSettingsSection: some View {
        Section("Optional Apple Account & iCloud") {
            NavigationLink {
                List {
                    Section { PeelAccountView(locallyTrustedDiscoveryIDs: locallyTrustedCloudDiscoveryIDs) }
                }
                .navigationTitle("Apple Account & iCloud")
            } label: {
                Label("Apple Account & Device Sync", systemImage: "person.crop.circle")
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                accountSettingsSection
#if os(iOS)
                Section {
                    NavigationLink {
                        connectionSettings
                    } label: {
                        Label("Connection Options", systemImage: "network")
                    }
                }

                Section("Stream Controls") {
                    sourceControlsVisibilityToggles
                }
#else
                PeelAISubscriptionSection()
                PeelICloudPairingSection()
                PeelDirectEndpointSection()
            manualAgentControlSection
#endif
#if os(visionOS)
                Section("Windows") {
                    Picker("Window Layout", selection: selectedWindowLayout) {
                        ForEach(WindowLayoutSetting.allCases) { layout in
                            Label(layout.title, systemImage: layout.systemImage)
                                .tag(layout)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Quick Open Limit")
                            Spacer()
                            Text("\(openTopAppsLimit)")
                                .foregroundStyle(.secondary)
                        }

                        Slider(
                            value: Binding(
                                get: { Double(openTopAppsLimit) },
                                set: { openTopAppsLimit = Int($0.rounded()) }
                            ),
                            in: 2...8,
                            step: 1
                        )
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Computer Window Placement", selection: $peeledWindowHostingMode) {
                            Text("In Place").tag(PeeledWindowHostingMode.inPlace)
                            Text("Peel Display").tag(PeeledWindowHostingMode.peelDisplay)
                            Text("Restore Previous Context").tag(PeeledWindowHostingMode.restorePreviousMacContext)
                        }

                        settingFootnote("Choose whether peeled windows stay put, move to an app-sized display, or restore the computer's previous context when you look away")
                    }
                }

                Section("Input") {


                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: $showScrollControlButtons) {
                            Label("Scroll", systemImage: "arrow.up.and.down")
                        }

                        settingFootnote("Show vertical scroll arrows")
                    }


                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: $showKeyboardMacroKeys) {
                            Label("Keyboard Controls", systemImage: "keyboard.badge.ellipsis")
                        }

                        settingFootnote("Show esc, tab, shift, etc.")
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: $showKeyboardArrowKeys) {
                            Label("Arrow Keys", systemImage: "arrow.left.arrow.right")
                        }

                        settingFootnote("Show directional arrow keys")
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: showZoomButtonsBinding) {
                            Label("Zoom", systemImage: "plus.magnifyingglass")
                        }

                        settingFootnote("Show zoom buttons")
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: showInputModeControlsBinding) {
                            Label("Cursor Modes", systemImage: "cursorarrow.click")
                        }

                        settingFootnote("Show right click and drag buttons")
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: holdLeftRightModeBinding) {
                            Label("Right Click Lock", systemImage: "cursorarrow.click.badge.clock")
                        }
                        .disabled(!showInputModeControls)

                        settingFootnote("Keep right click mode on until turned off")
                    }

                    sourceControlsVisibilityToggles
                }

                Section("Advanced") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: $showHUDTab) {
                            Label("Show HUD Tab", systemImage: "inset.filled.bottomleading.rectangle")
                        }

                        settingFootnote("Show experimental immersive HUD controls")
                    }
                }
                
#endif // os(visionOS)

#if os(visionOS)
                if showsAgentPresentationSetting || shouldShowAgentNotificationsSetting {
                    Section("Automation") {
                        if !aiFeaturesAllowed {
                            aiFeatureAccessMessage
                        }

                        if showsAgentPresentationSetting {
                            VStack(alignment: .leading, spacing: 4) {
                                Toggle(isOn: $allowAgentPresentation) {
                                    Label("Allow AI window opening", systemImage: "sparkles.rectangle.stack")
                                }
                                .disabled(!aiFeaturesAllowed && !allowAgentPresentation)
                                .onChange(of: allowAgentPresentation) { _, newValue in
                                    onAgentPresentationOptInChanged?(newValue)
                                }

                                settingFootnote("Let approved actions from your computer open a window in Peel Pro")
                            }
                        }

                        if shouldShowAgentNotificationsSetting {
                            agentNotificationsControl
                        }
                    }
                }
#endif

                Section("Help") {
#if os(iOS)
                    Button {
                        showingAbout = true
                    } label: {
                        Label("About Peel Pro", systemImage: "info.circle")
                    }
#endif

                    NavigationLink {
                        PeelPaywallView()
                            .navigationTitle("Peel Pro")
#if os(iOS)
                            .navigationBarTitleDisplayMode(.inline)
#endif
                    } label: {
                        Label("Peel Pro & Restore Purchases", systemImage: "creditcard")
                    }

                    Link(destination: URL(string: "https://zephyrstudios.dev/contact.html")!) {
                        Label("Contact Us", systemImage: "envelope")
                    }

                    Button {
                        requestReview()
                    } label: {
                        Label("Write a Review", systemImage: "star.bubble")
                    }
                }

#if DEBUG
                if PeelShellPreviewPolicy.isEnabled {
                    Section("Development") {
                        NavigationLink {
                            PeelShellPreviewView(pairingStore: browser.pairingStore)
                        } label: {
                            Label("Shell Preview", systemImage: "terminal")
                        }
                        .accessibilityIdentifier("shell-preview-entry")
                    }
                }
#endif

                Section("Legal") {
                    NavigationLink {
                        PeelShellNoticesView()
                    } label: {
                        Label("Open-source notices", systemImage: "doc.plaintext")
                    }

                    Link(destination: termsURL) {
                        Label("Terms of Service", systemImage: "doc.text")
                    }

                    Link(destination: privacyURL) {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }
                }

                Section("About") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(appName)
                            .font(.title2.bold())

                        Text("Version \(version)")
                            .foregroundStyle(.secondary)

                        Text("©2026 Zephyr Studios")
                            .foregroundStyle(.secondary)

                        Link(destination: URL(string: "https://zephyrstudios.dev")!) {
                            Label("Zephyr Studios", systemImage: "safari")
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle("Settings")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
#if os(iOS)
            .sheet(isPresented: $showingAbout) {
                AboutPeelView()
            }
#endif
            .onAppear {
#if os(iOS) || os(visionOS)
                if allowAgentNotifications {
                    notificationPresenter?.refreshAuthorizationStatus { authorized in
                        guard !authorized else { return }
                        allowAgentNotifications = false
                        updateAgentNotificationsOptIn(false)
                    }
                }
#endif
                if showZoomButtons && showInputModeControls {
                    showInputModeControls = false
                    rightClickModeStaysEnabled = false
                }

                if !showInputModeControls {
                    rightClickModeStaysEnabled = false
                }
            }
            .onChange(of: showInputModeControls) { _, newValue in
                if newValue {
                    showZoomButtons = false
                } else {
                    rightClickModeStaysEnabled = false
                }
            }
            .onChange(of: showZoomButtons) { _, newValue in
                if newValue {
                    showInputModeControls = false
                    rightClickModeStaysEnabled = false
                }
            }
        }
    }
}
