//
//  PeelHostSettingsView.swift
//  Peel-Host
//
//  Created by Zach on 3/13/26.
//


//
//  PeelHostSettingsView.swift
//  Peel
//

import SwiftUI

struct PeelHostSettingsView: View {
    var embeddedInHost = false
    @EnvironmentObject private var updater: PeelUpdaterController
    @EnvironmentObject private var launchAtLogin: LaunchAtLoginManager
    @AppStorage(PeelStreamingSettings.desktopProfileKey) private var desktopProfile: PeelStreamingSettings.DesktopProfile = PeelStreamingSettings.defaultDesktopProfile
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon: Bool = true
    @AppStorage("hideDockIcon") private var hideDockIcon: Bool = false
    @AppStorage(WindowEnumerator.enumerationScopeDefaultsKey) private var windowEnumerationScopeRawValue: String = WindowEnumerationScope.allSpaces.rawValue
    // Same keys as PeelRemoteMacSourceMediaPreferences (contract v1); default on.
    @AppStorage("peel.controls.showVolume") private var showStreamVolumeControls: Bool = true
    @AppStorage("peel.controls.showMediaControls") private var showStreamMediaControls: Bool = true

/*
    @AppStorage(PeelStreamingSettings.activeBitrateMbpsKey) private var activeBitrateMbps: Int = PeelStreamingSettings.defaultActiveBitrateMbps
    @AppStorage(PeelStreamingSettings.activeMaxDimensionKey) private var activeMaxDimension: Int = PeelStreamingSettings.defaultActiveMaxDimension
    @AppStorage(PeelStreamingSettings.activeFPSKey) private var activeFPS: Int = PeelStreamingSettings.defaultActiveFPS

    @AppStorage(PeelStreamingSettings.inactiveBitrateMbpsKey) private var inactiveBitrateMbps: Int = PeelStreamingSettings.defaultInactiveBitrateMbps
    @AppStorage(PeelStreamingSettings.inactiveMaxDimensionKey) private var inactiveMaxDimension: Int = PeelStreamingSettings.defaultInactiveMaxDimension
    @AppStorage(PeelStreamingSettings.inactiveFPSKey) private var inactiveFPS: Int = PeelStreamingSettings.defaultInactiveFPS
*/

    private var visibilityMode: Binding<String> {
        Binding(
            get: {
                if showMenuBarIcon && hideDockIcon {
                    return "menuBar"
                }

                if showMenuBarIcon && !hideDockIcon {
                    return "both"
                }

                return "dock"
            },
            set: { newValue in
                switch newValue {
                case "menuBar":
                    showMenuBarIcon = true
                    hideDockIcon = true
                case "dock":
                    showMenuBarIcon = false
                    hideDockIcon = false
                default:
                    showMenuBarIcon = true
                    hideDockIcon = false
                }
            }
        )
    }

    private var windowEnumerationScope: Binding<WindowEnumerationScope> {
        Binding(
            get: {
                WindowEnumerationScope(rawValue: windowEnumerationScopeRawValue) ?? .allSpaces
            },
            set: { newValue in
                windowEnumerationScopeRawValue = newValue.rawValue
                WindowEnumerator.enumerationScope = newValue
            }
        )
    }

    private var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "Version \(version) (\(build))"
    }

    private func restoreDefaults() {
        launchAtLogin.setEnabled(true)
        showMenuBarIcon = true
        hideDockIcon = false
        showStreamVolumeControls = true
        showStreamMediaControls = true
        windowEnumerationScopeRawValue = WindowEnumerationScope.allSpaces.rawValue
        WindowEnumerator.enumerationScope = .allSpaces
        PeelStreamingSettings.restoreDefaults()
        updater.setAutomaticUpdatesEnabled(true)
    }

/*
    private func streamingProfileControls(
        title: String,
        bitrateMbps: Binding<Int>,
        maxDimension: Binding<Int>,
        fps: Binding<Int>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            Stepper(
                "Bitrate: \(bitrateMbps.wrappedValue) Mbps",
                value: bitrateMbps,
                in: PeelStreamingSettings.bitrateRange,
                step: 1
            )

            Stepper(
                "Max dim: \(maxDimension.wrappedValue) px",
                value: maxDimension,
                in: PeelStreamingSettings.maxDimensionRange,
                step: 160
            )

            Stepper(
                "FPS: \(fps.wrappedValue)",
                value: fps,
                in: PeelStreamingSettings.fpsRange,
                step: 1
            )
        }
        .padding(.vertical, 4)
    }
*/

    var body: some View {
        Form {
#if PEEL_HOST_INTEGRATION
            PeelHostAccountSection()
#endif
            Section("Desktop Streaming") {
                Picker("Quality", selection: $desktopProfile) {
                    ForEach(PeelStreamingSettings.DesktopProfile.allCases) { profile in
                        Text(profile.title).tag(profile)
                    }
                }
                .pickerStyle(.segmented)
                Text(desktopProfile.detail).font(.caption).foregroundStyle(.secondary)
                Text("The budget is shared across open desktops and app windows. Changes apply to active streams.")
                    .font(.caption).foregroundStyle(.secondary)
            }

#if PEEL_HOST_INTEGRATION
            // Presentation only: hides stream-window groups; playback, Host
            // state, permissions and the microphone are unaffected.
            Section("Stream Window Controls") {
                Toggle("Show source volume", isOn: $showStreamVolumeControls)
                Toggle("Show media controls", isOn: $showStreamMediaControls)
            }
#endif
            
/*
            Section("Streaming") {
                Picker("Window list", selection: windowEnumerationScope) {
                    Text("Current Space").tag(WindowEnumerationScope.currentSpaceOnly)
                    Text("All Spaces").tag(WindowEnumerationScope.allSpaces)
                }
                .pickerStyle(.segmented)

                Text(windowEnumerationScope.wrappedValue.helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

         Divider()

                streamingProfileControls(
                    title: "Active Window",
                    bitrateMbps: $activeBitrateMbps,
                    maxDimension: $activeMaxDimension,
                    fps: $activeFPS
                )

                streamingProfileControls(
                    title: "Inactive Windows",
                    bitrateMbps: $inactiveBitrateMbps,
                    maxDimension: $inactiveMaxDimension,
                    fps: $inactiveFPS
                )

                Text("Defaults: active 10 Mbps / 1920 px / 60 fps, inactive 5 Mbps / 1920 px / 24 fps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            }
 
 */

            Section("Menu & Dock") {
                Toggle(
                    "Open Peel Pro at login",
                    isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    )
                )

                Picker("App visibility", selection: visibilityMode) {
                    Text("Menu Bar").tag("menuBar")
                    Text("Both").tag("both")
                    Text("Dock").tag("dock")
                }
                .pickerStyle(.segmented)


                if let errorMessage = launchAtLogin.errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Updates") {
                Toggle(
                    "Automatically keep Peel Pro up to date",
                    isOn: Binding(
                        get: { updater.automaticUpdatesEnabled },
                        set: { updater.setAutomaticUpdatesEnabled($0) }
                    )
                )

                Button(updater.updateActionTitle) {
                    updater.performUpdateAction()
                }
                .disabled(!updater.canCheckForUpdates)

                Text("Peel Pro checks for, downloads, and installs updates automatically. Manual checks use the same Sparkle update flow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Restore Defaults") {
                restoreDefaults()
            }
            Section("Support") {
                Link(destination: URL(string: "mailto:contact@zephyrstudios.dev")!) {
                    Label("Request Feature", systemImage: "lightbulb.max")
                }

                Link(destination: URL(string: "mailto:support@zephyrstudios.dev")!) {
                    Label("Email Support", systemImage: "envelope")
                }
            }

            Section("Legal") {
                Link(destination: URL(string: "https://zephyrstudios.dev/terms-of-use.html")!) {
                    Label("Terms of Service", systemImage: "doc.text")
                }

                Link(destination: URL(string: "https://zephyrstudios.dev/privacy-policy.html")!) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
            }

            Section("About") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Peel Pro")
                        .font(.title3.bold())

                    Text(versionString)
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
        .formStyle(.grouped)
        .padding(20)
        .frame(width: embeddedInHost ? nil : 520, height: embeddedInHost ? nil : 760)
        .onAppear {
            PeelStreamingSettings.registerDefaults()
            launchAtLogin.startLiveRefresh()
        }
        .onDisappear {
            launchAtLogin.stopLiveRefresh()
        }
    }
}
