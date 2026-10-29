//
//  ControlPanelAboutView.swift
//  Kill Switch
//
//  Created by Zach on 4/16/26.
//

//
//  ControlPanelAboutView.swift
//  Kill Switch
//

import SwiftUI
import StoreKit
import Sparkle
import Combine

final class AboutUpdatesViewModel: ObservableObject {
    @Published var automaticallyChecksForUpdates = false
    @Published var canCheckForUpdates = false

    private weak var updater: SPUUpdater?
    private var cancellables = Set<AnyCancellable>()

    func connectIfNeeded(to updater: SPUUpdater?) {
        guard self.updater !== updater else { return }

        self.updater = updater
        cancellables.removeAll()

        guard let updater else {
            automaticallyChecksForUpdates = false
            canCheckForUpdates = false
            return
        }

        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        canCheckForUpdates = updater.canCheckForUpdates

        updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.automaticallyChecksForUpdates = value
            }
            .store(in: &cancellables)

        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.canCheckForUpdates = value
            }
            .store(in: &cancellables)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        updater?.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = updater?.automaticallyChecksForUpdates ?? enabled
    }

    func checkForUpdates() {
        updater?.checkForUpdates()
    }
}

struct ControlPanelAboutView: View {
    @Environment(\.requestReview) private var requestReview

    @StateObject private var updatesViewModel = AboutUpdatesViewModel()

    private var sparkleUpdater: SPUUpdater? {
        MacMechanicUpdaterController.shared.updater
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

    private var termsURL: URL { URL(string: "https://zephyrstudios.dev/terms-of-use.html")! }
    private var privacyURL: URL { URL(string: "https://zephyrstudios.dev/privacy-policy.html")! }
    private var studioURL: URL { URL(string: "https://zephyrstudios.dev")! }

    @State private var isBasicsExpanded = true
    @State private var isMonitorExpanded = false
    @State private var isActionsExpanded = false
    @State private var isTipsExpanded = false

    private let basicsBullets: [String] = [
        "App Mechanic shows what is using your Mac the most.",
        "Use the menu bar for a quick glance at the top app."
    ]

    private let monitorBullets: [String] = [
        "Watch CPU for spikes that can slow your Mac down.",
        "Watch Memory to catch pressure and SSD swap."
    ]

    private let actionsBullets: [String] = [
        "Click an app to open it.",
        "Click a process to open Activity Monitor.",
        "Click the red X button to Force Quit an app or process."
    ]

    private let tipsBullets: [String] = [
        "Some apps may not come forward every time.",
        "Use Apps Only for a simpler view.",
        "Use Everything for the full picture."
    ]

    var body: some View {
        
        List {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {

                    Image(nsImage: NSApp.applicationIconImage)

                        .resizable()

                        .scaledToFit()

                        .frame(width: 32, height: 32)

                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                    Text("About")

                        .font(.largeTitle.weight(.semibold))

                }
            }
            Section {
                DisclosureGroup(isExpanded: $isBasicsExpanded) {
                    BulletList(items: basicsBullets)
                        .padding(.top, 6)
                } label: {
                    Text("Basics")
                        .font(.headline)
                        .textCase(nil)
                }
            } header: {
                Text("Overview")
                    .textCase(nil)
            } footer: {
                EmptyView()
            }

            Section {
                DisclosureGroup(isExpanded: $isMonitorExpanded) {
                    BulletList(items: monitorBullets)
                        .padding(.top, 6)
                } label: {
                    Text("Monitoring")
                        .font(.headline)
                        .textCase(nil)
                }
            } footer: {
                EmptyView()
            }

            Section {
                DisclosureGroup(isExpanded: $isActionsExpanded) {
                    BulletList(items: actionsBullets)
                        .padding(.top, 6)
                    Text("Use Force Quit when an app stops responding.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical)
                } label: {
                    Text("Actions")
                        .font(.headline)
                        .textCase(nil)
                }
            } footer: {
                EmptyView()
            }

//            Section {
//                DisclosureGroup(isExpanded: $isTipsExpanded) {
//                    BulletList(items: tipsBullets)
//                        .padding(.top, 6)
//                } label: {
//                    Text("Tips")
//                        .font(.headline)
//                        .textCase(nil)
//                }
//            } footer: {
//                EmptyView()
//            }

            Section {
                Link(destination: URL(string: "mailto:contact@zephyrstudios.dev")!) {
                    Label("Request a Feature", systemImage: "lightbulb.max")
                }

                Link(destination: URL(string: "mailto:support@zephyrstudios.dev")!) {
                    Label("Email Support", systemImage: "envelope")
                }

                Button {
                    requestReview()
                } label: {
                    Label("Rate App Mechanic", systemImage: "star.bubble")
                }
            } header: {
                Text("Contact")
                    .textCase(nil)
            }

            Section {
                Link(destination: termsURL) {
                    Label("Terms of Service", systemImage: "doc.text")
                }

                Link(destination: privacyURL) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
            } header: {
                Text("Legal")
                    .textCase(nil)
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text(appName)
                        .font(.title2).bold()

                    Text("Version \(version) (\(build))")
                        .foregroundStyle(.secondary)

                    Toggle("Automatically check for updates", isOn: Binding(
                        get: { updatesViewModel.automaticallyChecksForUpdates },
                        set: { updatesViewModel.setAutomaticallyChecksForUpdates($0) }
                    ))
                    .toggleStyle(.switch)

                    Button {
                        updatesViewModel.checkForUpdates()
                    } label: {
                        Label("Check Now", systemImage: "arrow.clockwise")
                    }
                    .disabled(!updatesViewModel.canCheckForUpdates)

                    Text("©2026 Zephyr Studios")
                        .foregroundStyle(.secondary)

                    Link(destination: studioURL) {
                        Label("Zephyr Studios", systemImage: "safari")
                    }
                }
                .padding(.vertical, 6)
            } header: {
                Text("About")
                    .textCase(nil)
            }
        }
        .listStyle(.inset)
        .navigationTitle("App Mechanic")
        .onAppear {
            updatesViewModel.connectIfNeeded(to: sparkleUpdater)
        }
    }
}

private struct BulletList: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items.indices, id: \.self) { idx in
                BulletRow(text: items[idx])
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

private struct BulletRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("•")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
