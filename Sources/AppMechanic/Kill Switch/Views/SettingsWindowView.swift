//
//  SettingsWindowView.swift
//  Kill Switch
//
//  Created by Zach on 4/16/26.
//


//
//  SettingsWindowView.swift
//  Kill Switch
//

import SwiftUI
import AppKit

struct SettingsWindowView: View {
    @EnvironmentObject var sampler: ProcessSampler
    @EnvironmentObject var systemMetrics: SystemMetricsStore
    @State private var selection: ControlPanelSection? = .home
    private let embeddedInHost: Bool

    init(embeddedInHost: Bool = false) {
        self.embeddedInHost = embeddedInHost
    }

    var body: some View {
        Group {
            if embeddedInHost {
                embeddedBody
            } else {
                standaloneBody
            }
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 360, idealHeight: 420)
        .onAppear {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)

                if let window = NSApp.windows.first(where: {
                    $0.title == "App Mechanic"
                }) {
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                }
            }
        }
    }

    private var standaloneBody: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    navigationRows(ControlPanelSection.overviewSections)
                }

                Section("Tools") {
                    navigationRows(ControlPanelSection.utilitySections)
                }

                Section {
                    navigationRows(ControlPanelSection.applicationSections)
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
            .listStyle(.sidebar)
        } detail: {
            detailBody
        }
    }

    private var embeddedBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Mechanic", systemImage: "gauge.with.dots.needle.67percent")
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 10)

            Picker("Mechanic section", selection: embeddedSelection) {
                ForEach(ControlPanelSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 18)
            .padding(.bottom, 12)

            Divider()

            detailBody
        }
    }

    private var embeddedSelection: Binding<ControlPanelSection> {
        Binding(
            get: { selection ?? .home },
            set: { selection = $0 }
        )
    }

    @ViewBuilder
    private var detailBody: some View {
        Group {
            switch selection ?? .home {
            case .home:
                ControlPanelHomeView()
                    .environmentObject(sampler)
                    .environmentObject(systemMetrics)
            case .alerts:
                ControlPanelAlertsView()
                    .environmentObject(sampler)
            case .settings:
                ControlPanelSettingsView()
                    .environmentObject(sampler)
            case .about:
                ControlPanelAboutView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func navigationRows(_ sections: [ControlPanelSection]) -> some View {
        ForEach(sections) { section in
            Label(section.title, systemImage: section.systemImage)
                .tag(section)
        }
    }
}
