//
//  PeelMachineStatusSheet.swift
//  Shared iPhone, iPad, and visionOS Mac Status entry point.
//
//  The sheet chooses an already-connected session, makes the local permission
//  explicit, and exposes only a manual refresh. It does not connect, launch a
//  sampler, or create a second session.
//

#if os(iOS) || os(visionOS)

import SwiftUI

public struct PeelMachineStatusSheet: View {
    @EnvironmentObject private var browser: PeelClientBrowser
    @EnvironmentObject private var store: PeelStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PeelClientMachineStatusPolicy.optInDefaultsKey)
    private var allowMachineStatus = false
    @State private var explicitlySelectedHostRawValue: String?

    public init() {}

    private var connectedSessions: [PeelHostSession] {
        browser.sessionsByHostKey.values
            .filter { $0.isConnectionReady && $0.connection != nil }
            .sorted { lhs, rhs in
                lhs.host.name.localizedCaseInsensitiveCompare(rhs.host.name) == .orderedAscending
            }
    }

    private var selectedSession: PeelHostSession? {
        if let explicitlySelectedHostRawValue,
           let selected = connectedSessions.first(where: {
               $0.hostKey.rawValue == explicitlySelectedHostRawValue
           }) {
            return selected
        }

        if let selectedHostKey = browser.selectedHostKey,
           let selected = connectedSessions.first(where: { $0.hostKey == selectedHostKey }) {
            return selected
        }

        return connectedSessions.first
    }

    private var hostSelection: Binding<String> {
        Binding(
            get: { selectedSession?.hostKey.rawValue ?? "" },
            set: { rawValue in
                explicitlySelectedHostRawValue = rawValue.isEmpty ? nil : rawValue
            }
        )
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls
                Divider()

                if let selectedSession {
                    PeelMachineStatusSessionView(
                        controller: selectedSession.machineStatusController)
                        .id(selectedSession.hostKey)
                } else {
                    noConnectedMac
                }
            }
            .navigationTitle("Computer Status")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if connectedSessions.count > 1 {
                Picker("Computer", selection: hostSelection) {
                    ForEach(connectedSessions) { session in
                        Text(session.host.name)
                            .tag(session.hostKey.rawValue)
                    }
                }
                .pickerStyle(.menu)
            } else if let session = connectedSessions.first {
                Label(session.host.name, systemImage: "desktopcomputer")
                    .font(.headline)
            } else {
                Label("No connected computer", systemImage: "desktopcomputer")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            Toggle("Allow this device to request Computer Status", isOn: Binding(
                get: { allowMachineStatus },
                set: updateOptIn
            ))
            .disabled(!PeelClientMachineStatusPolicy.isSupportedPlatform)

            DisclosureGroup {
                Text("This device requests one fresh snapshot at a time. The paired computer must also allow sharing in Peel Pro.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } label: {
                Label("How sharing works", systemImage: "info.circle")
                    .font(.caption.weight(.medium))
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    private var noConnectedMac: some View {
        VStack(spacing: 10) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Connect a paired computer from the main screen, then return here.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func updateOptIn(_ enabled: Bool) {
        allowMachineStatus = enabled
        // Reuse the existing capability refresh path. It sends a new hello on
        // each ready session; no status request is sent here.
        browser.refreshAgentPresentationCapabilities()
        for session in browser.sessionsByHostKey.values {
            session.machineStatusController.handleLocalOptInChanged()
        }
    }

}

private struct PeelMachineStatusSessionView: View {
    @ObservedObject var controller: PeelClientMachineStatusController

    var body: some View {
        PeelMachineStatusView(
            model: controller.viewModel,
            onRefresh: { _ = controller.refresh() }
        )
        .onAppear {
            controller.refreshAvailability()
        }
    }
}

#endif
