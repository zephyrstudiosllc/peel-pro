import SwiftUI

/// Retains the existing call-site name while presenting the unified Pro offer.
struct PeelAISubscriptionSection: View {
    @EnvironmentObject private var store: PeelStore

    var body: some View {
        Section("Peel Pro") {
            NavigationLink {
                PeelPaywallView()
                    .navigationTitle("Peel Pro")
#if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
#endif
            } label: {
                Label(store.hasProAccess ? "Manage Pro & Restore" : "Get Peel Pro", systemImage: "checkmark.seal")
            }
            .accessibilityIdentifier("peel.pro.settingsEntry")

            Text("More simultaneous remote windows, remote agent coordination and automation. Monthly, yearly or lifetime—with the same Pro features.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
