#if os(iOS)
import SwiftUI
import PeelWatchCore

struct PeelCloudAgentHandoffPresentation: Identifiable {
    let id: UUID
    let provider: CloudAgentProvider
    let routeID: String
    var isChecking = false
    var notice: String?
}

/// The same authenticated consent review is reachable from Settings and from
/// the pending first-Connect sheet. Display text is never a readiness grant.
struct PeelCloudAgentConsentControls: View {
    @ObservedObject var service: PeelCloudAgentPhoneService
    let provider: CloudAgentProvider
    private var title: String { provider == .dot ? "Dot" : "Grok Bot" }
    var body: some View {
        if let consent = service.pendingPluginConsent, consent.review.provider == provider {
            Text("Allow this agent connection?").font(.headline)
            Text("Client: \(consent.review.clientID)")
            Text("Service: \(consent.review.resource.absoluteString)")
            Text("Callback: \(consent.review.redirectURI.absoluteString)")
            Text("Requested access: \(consent.review.requestedScopes.joined(separator: ", "))")
            Text("This authorizes the selected \(title) plugin and enrolled Watch route.")
                .foregroundStyle(.secondary)
            Button("Allow \(title) connection") { service.approvePluginConsent(consent.id, handoffID: consent.handoffID) }
                .disabled(service.pluginConsentIsApproving || service.agentHandoff?.isChecking == true)
            Button("Cancel authorization", role: .cancel) { service.dismissPluginConsent(consent.id, handoffID: consent.handoffID) }
                .disabled(service.pluginConsentIsApproving)
        }
        if service.pluginConsentIsApproving {
            ProgressView("Finishing plugin authorization…")
        }
    }
}

struct PeelCloudAgentManualHandoffView: View {
    @ObservedObject var service: PeelCloudAgentPhoneService
    let handoffID: UUID
    private var current: PeelCloudAgentHandoffPresentation? {
        guard let value = service.agentHandoff, value.id == handoffID else { return nil }
        return value
    }
    var body: some View {
        NavigationStack {
            List {
                if let value = current {
                    Section("Use your existing \(value.provider == .dot ? "Dot" : "Grok Bot")") {
                        Text(value.provider == .dot
                            ? "Connect the Peel plugin in your existing Dot. Copy the instructions below, paste them there, and let Dot confirm the connection and subscribe to new Watch messages."
                            : "Your existing Grok Bot must support and authenticate the Peel custom MCP plugin. Copy the instructions below and paste them into that Bot. This connection uses a manual inbox; automatic wake is not verified.")
                        Text("Return here to approve any plugin request and check the connection. Setup expires after five minutes; start Connect again if it expires.")
                            .foregroundStyle(.secondary)
                        Button("Copy live connection instructions") {
                            let id = handoffID
                            Task { await service.copyAgentInstructions(id) }
                        }
                        .disabled(value.isChecking || service.pluginConsentIsApproving)
                        Text("Route: \(value.routeID)").font(.footnote).textSelection(.enabled)
                    }
                    Section {
                        PeelCloudAgentConsentControls(service: service, provider: value.provider)
                    }
                    Section("Peel Pro") {
                        PeelCloudAgentProControls(service: service, provider: value.provider, handoffID: handoffID)
                    }
                    Section {
                        Button("Check connection") { service.checkAgentHandoff(handoffID) }
                            .disabled(value.isChecking || service.pluginConsentIsApproving || service.pendingPluginConsent != nil)
                        if value.isChecking { ProgressView("Checking the live connection…") }
                        if let notice = value.notice { Text(notice).foregroundStyle(.secondary) }
                    }
                } else {
                    ProgressView("Finishing connection…")
                }
            }
            .navigationTitle("Connect \(current?.provider == .grokBot ? "Grok Bot" : "Dot")")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { service.cancelAgentHandoff(handoffID) }
                }
            }
            .interactiveDismissDisabled()
        }
    }
}
#endif
