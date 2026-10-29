#if os(iOS)
import SwiftUI
import PeelWatchCore

struct PeelCloudAgentSettingsView: View {
    @ObservedObject private var service = PeelCloudAgentPhoneService.shared

    var body: some View {
        List {
            Section {
                Text("Connect Dot or Grok Bot on this iPhone to send and receive messages on your Watch.")
            }
            agentSection(.dot, title: "Dot", symbol: "circle.dotted")
            agentSection(.grokBot, title: "Grok Bot", symbol: "sparkle")
            Section("On your Watch") {
                Text("Finish connecting your selected agent here before sending messages from your Watch.")
                Text("Open the agent on your Watch to check for replies. Background delivery depends on the paired devices and the agent connection.")
            }
        }
        .navigationTitle("Cloud agents")
        .sheet(item: Binding(get: { service.agentHandoff }, set: { value in
            if value == nil, let current = service.agentHandoff { service.cancelAgentHandoff(current.id) }
        })) { handoff in
            PeelCloudAgentManualHandoffView(service: service, handoffID: handoff.id)
        }
    }

    private func agentSection(_ provider: CloudAgentProvider, title: String, symbol: String) -> some View {
        Section {
            Label(title, systemImage: symbol)
                .font(.headline)
            Text(service.setupDescription(for: provider))
                .foregroundStyle(.secondary)
            Button(service.status(for: provider).canSend ? "Reconnect \(title)" : "Connect \(title)") {
                service.startSignIn(for: provider)
            }
            .disabled(!service.canStartSignIn(for: provider))
            if service.signingInProvider == provider {
                ProgressView(service.connectionStage[provider] ?? "Connecting…")
                Button("Cancel connection", role: .cancel) { service.cancelSignIn() }
            } else if case .signedIn = service.status(for: provider).identity {
                if service.status(for: provider).canSend {
                    Label(provider == .dot ? "Dot connected" : "Grok Bot connected · manual inbox", systemImage: "checkmark.circle")
                }
                Button("Disconnect on this iPhone", role: .destructive) { service.signOut(provider) }
            } else {
                Text(CloudAgentSignInMethod.primary(for: provider).title)
                    .foregroundStyle(.secondary)
            }
            if service.signingInProvider == nil {
                Button("Check saved connection") { Task { await service.checkConnection(provider) } }
                    .disabled(!service.canCheckSavedConnection(for: provider))
            }
            if let deadline = service.sessionDeadlines[provider] {
                Text("Account session ends \(deadline.formatted(date: .abbreviated, time: .shortened)). Connect again after it expires.")
                    .font(.footnote).foregroundStyle(.secondary)
                if case .signedOut = service.status(for: provider).identity {
                    Button("Disconnect saved connection", role: .destructive) { service.signOut(provider) }
                }
            }
            if let notice = service.notices[provider] {
                Text(notice).foregroundStyle(.secondary)
            }
            PeelCloudAgentProControls(service: service, provider: provider)
            PeelCloudAgentConsentControls(service: service, provider: provider)
        }
    }
}

/// The existing purchase/restore surface is opened only by an explicit action.
/// Its local state is UX; only the signed broker exchange grants cloud permits.
struct PeelCloudAgentProControls: View {
    @ObservedObject var service: PeelCloudAgentPhoneService
    @EnvironmentObject private var store: PeelStore
    let provider: CloudAgentProvider
    var handoffID: UUID? = nil
    @State private var showingPlans = false
    var body: some View {
        if let notice = service.proNotices[provider] {
            Text(notice).foregroundStyle(.secondary)
        }
        Button("Peel Pro plans") { showingPlans = true }
            .sheet(isPresented: $showingPlans) { PeelPaywallView().environmentObject(store) }
        Button("Restore Purchases") { Task { await store.restorePurchases() } }
            .disabled(store.isPurchasing || store.isRestoring)
        if let id = handoffID {
            Button("Verify Pro and check connection") { service.checkAgentHandoff(id) }
                .disabled(service.agentHandoff?.id != id || service.agentHandoff?.isChecking == true ||
                          service.pluginConsentIsApproving || service.pendingPluginConsent != nil)
        } else {
            Button("Verify Peel Pro") { service.retryProVerification(provider) }
                .disabled(!service.canVerifyPro(provider))
            if service.proVerifications[provider] != nil { ProgressView("Verifying Peel Pro…") }
        }
    }
}
#endif
