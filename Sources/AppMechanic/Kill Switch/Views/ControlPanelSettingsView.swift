//
//  ControlPanelSettingsView.swift
//  Kill Switch
//

import SwiftUI
import AppKit

struct ControlPanelSettingsView: View {
    @EnvironmentObject var sampler: ProcessSampler
    private let showsAboutFooter: Bool
    private let embeddedInHost: Bool
    private let openPeelProSettings: (() -> Void)?

    @StateObject private var launchAtLoginManager = MechanicLaunchAtLoginManager()
    @AppStorage("prefersDockIconHidden") private var prefersDockIconHidden = false
    @AppStorage("menuBarGaugeMask") private var menuBarGaugeMask = SystemGaugeSelection.defaultMask
    @AppStorage("showsTopAppInMenuBar") private var showsTopAppInMenuBar = true
    @AppStorage("popupGaugeDisplayMode") private var popupGaugeDisplayModeRawValue = PopupGaugeDisplayMode.individual.rawValue
    @AppStorage("launchAtLoginDesired") private var launchAtLoginDesired = true
    @AppStorage("peel.bar.showGauge") private var embeddedShowGauge = true
    @AppStorage("peel.bar.showTopApp") private var embeddedShowTopApp = true
    @AppStorage("peel.bar.appLimit") private var embeddedAppLimit = 3

    init(
        showsAboutFooter: Bool = false,
        embeddedInHost: Bool = false,
        openPeelProSettings: (() -> Void)? = nil
    ) {
        self.showsAboutFooter = showsAboutFooter
        self.embeddedInHost = embeddedInHost
        self.openPeelProSettings = openPeelProSettings
    }

    private var embeddedAppLimitBinding: Binding<Int> {
        Binding(
            get: { embeddedAppLimit == 5 ? 5 : 3 },
            set: { embeddedAppLimit = $0 == 5 ? 5 : 3 }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {

                    Image(nsImage: NSApp.applicationIconImage)

                        .resizable()

                        .scaledToFit()

                        .frame(width: 32, height: 32)

                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                    Text(embeddedInHost ? "App Mechanic Settings" : "Settings")

                        .font(.largeTitle.weight(.semibold))

                }


                VStack(alignment: .leading, spacing: 12) {
                    Text("Menu Bar")
                        .font(.headline)
                    
                    Text(embeddedInHost
                         ? "Choose the gauges and app controls shown in Peel’s menu bar."
                         : "App Mechanic lives in your menu bar. If you do not see it, your menu bar may be crowded or App Mechanic may be hidden.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !embeddedInHost {
                        Text("If hidden, open System Settings > Menu Bar and make sure App Mechanic is turned on.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Popup Gauges")
                            .font(.subheadline.weight(.medium))

                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading)
                            ],
                            spacing: 8
                        ) {
                            ForEach(SystemGaugeMetric.allCases) { metric in
                                Toggle(
                                    metric.displayName,
                                    isOn: gaugeBinding(for: metric)
                                )
                                .toggleStyle(.checkbox)
                            }
                        }

                        Text("Choose the system gauges shown in the popup. The menu bar itself uses one lightweight activity gauge.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    if embeddedInHost {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Menu Bar Indicators")
                                .font(.subheadline.weight(.medium))

                            Toggle("My gauge", isOn: $embeddedShowGauge)
                            Toggle("Top app name", isOn: $embeddedShowTopApp)

                            Picker("Top apps in Mechanic", selection: embeddedAppLimitBinding) {
                                Text("Top 3").tag(3)
                                Text("Top 5").tag(5)
                            }
                            .pickerStyle(.segmented)

                            Text("These settings control the unified Peel menu bar indicator and App Mechanic list.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Top App Name")
                                .font(.subheadline.weight(.medium))

                            HStack(alignment: .top, spacing: 12) {
                                Text("Show the busiest app beside the menu-bar gauge.")

                                Spacer(minLength: 12)

                                Toggle("", isOn: $showsTopAppInMenuBar)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                            }

                            Text("The gauge and optional app name follow the current CPU or Memory app ranking.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Popup Gauge Layout")
                            .font(.subheadline.weight(.medium))

                        Picker(
                            "Popup gauge layout",
                            selection: $popupGaugeDisplayModeRawValue
                        ) {
                            ForEach(PopupGaugeDisplayMode.allCases) { mode in
                                Text(mode.displayName)
                                    .tag(mode.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        Text("Combined Average excludes unavailable readings instead of treating them as zero.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )

                if embeddedInHost {
                    embeddedGlobalSettingsRoute
                } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Startup")
                        .font(.headline)

                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Launch at Login")

                            Text(launchAtLoginManager.statusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 12)

                        Toggle("", isOn: Binding(
                            get: { launchAtLoginDesired },
                            set: { newValue in
                                launchAtLoginDesired = newValue
                                launchAtLoginManager.setEnabled(newValue)
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }

                    if launchAtLoginManager.requiresApproval {
                        Text("macOS needs approval before this can turn on.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Spacer()

                        Button("Open Login Items Settings") {
                            launchAtLoginManager.openLoginItemsSettings()
                        }
                    }

                    if let errorMessage = launchAtLoginManager.errorMessage, !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )

                VStack(alignment: .leading, spacing: 12) {
                    Text("Appearance")
                        .font(.headline)

                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Don’t Show App in Dock")

                            Text("Keeps App Mechanic out of the Dock and app switcher.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 12)

                        Toggle("", isOn: Binding(
                            get: { prefersDockIconHidden },
                            set: { newValue in
                                prefersDockIconHidden = newValue
                                applyDockPreference(hidden: newValue)
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
                }

                HStack {
                    Spacer()

                    Button("Reset to Defaults") {
                        resetToDefaults()
                    }
                }
                .padding(.top, 4)

                if showsAboutFooter {
                    aboutFooter
                }
            }
            .padding(20)
        }
        .onAppear {
            launchAtLoginManager.refreshStatus()

            if !embeddedInHost && launchAtLoginDesired {
                launchAtLoginManager.registerIfNeeded()
            }
        }
        .navigationTitle(embeddedInHost ? "App Mechanic Settings" : "App Mechanic")
    }

    @ViewBuilder
    private var embeddedGlobalSettingsRoute: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Peel Pro Settings")
                .font(.headline)

            Text("Startup, Dock visibility, and host menu-bar presence are managed by Peel Pro for the unified app.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let openPeelProSettings {
                Button("Open Peel Pro Settings", action: openPeelProSettings)
            } else {
                Text("Open Peel Pro Settings from the Peel Pro section.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var aboutFooter: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("About")
                .font(.headline)

            Text(appName)
                .font(.title3.weight(.semibold))

            Text("Version \(version) (\(build))")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("©2026 Zephyr Studios")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "App Mechanic"
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    private func resetToDefaults() {
        DispatchQueue.main.async {
            sampler.selectMostStressedMetric()
            sampler.updateSelectedScope(.appsOnly)
        }

        menuBarGaugeMask = SystemGaugeSelection.defaultMask
        popupGaugeDisplayModeRawValue = PopupGaugeDisplayMode.individual.rawValue

        if embeddedInHost {
            // The unified indicator preferences belong to Peel Host. Keep
            // Reset scoped to App Mechanic's metric and gauge mode settings.
            return
        }

        showsTopAppInMenuBar = true
        prefersDockIconHidden = true
        applyDockPreference(hidden: true)
        launchAtLoginDesired = true
        launchAtLoginManager.setEnabled(true)
    }

    private func gaugeBinding(for metric: SystemGaugeMetric) -> Binding<Bool> {
        Binding(
            get: {
                SystemGaugeSelection.contains(metric, in: menuBarGaugeMask)
            },
            set: { isEnabled in
                menuBarGaugeMask = SystemGaugeSelection.setting(
                    metric,
                    enabled: isEnabled,
                    in: menuBarGaugeMask
                )
            }
        )
    }

    private func applyDockPreference(hidden: Bool) {
        let policy: NSApplication.ActivationPolicy = hidden ? .accessory : .regular
        _ = NSApp.setActivationPolicy(policy)

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)

            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                window.makeKeyAndOrderFront(nil)
            } else if let controlPanelWindow = NSApp.windows.first(where: { window in
                let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
                return title == "App Mechanic" && !window.isMiniaturized
            }) {
                controlPanelWindow.makeKeyAndOrderFront(nil)
            }
        }
    }

}
