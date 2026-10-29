import SwiftUI
import PeelWatchCore

struct PeelWatchCloudView: View {
    @ObservedObject var model: PeelCompanionModel
    @ObservedObject private var client = PeelWatchCloudClient.shared
    @State private var provider: CloudAgentProvider = .dot
    @State private var text = ""
    @State private var composing = false
    @State private var composingContext: PeelWatchCloudActionContext?
    private var selectedRouteMatches: Bool { provider == client.provider }
    var body: some View {
        List {
            Section {
                Picker("Agent", selection: $provider) {
                    Text("Your dot").tag(CloudAgentProvider.dot)
                    Text("Grok Bot").tag(CloudAgentProvider.grokBot)
                }
                Text(client.status).font(.caption)
                    .accessibilityIdentifier("watch.cloud.status")
                if client.busy { ProgressView() }
                Button("New message") {
                    composingContext = client.actionContext; composing = true
                }
                    .disabled(!selectedRouteMatches || !client.ready || client.busy)
                Button("Check connection") {
                    let context = client.actionContext, selected = provider
                    Task { await client.refreshStatus(context: context, selectedProvider: selected) }
                }
                    .disabled(!selectedRouteMatches || client.busy)
                Button("Check replies") {
                    let context = client.actionContext, selected = provider
                    Task { await client.refreshReply(context: context, selectedProvider: selected) }
                }
                    .disabled(!selectedRouteMatches || !client.ready || client.busy)
                if client.provider == .grokBot, selectedRouteMatches, client.ready {
                    Text("Grok Bot checks Peel when you ask it to, or through a configured routine. Reply checking here does not wake it.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            ForEach(client.outgoing, id: \.message.messageID) { record in
                Section("Your message") {
                    Text(record.message.text)
                    Text(delivery(record)).font(.caption2).foregroundStyle(.secondary)
                    if record.state == .reserved || record.state == .uncertain {
                        Button("Retry saved message") {
                            let context = client.actionContext, selected = provider
                            Task { await client.retry(record, context: context, selectedProvider: selected) }
                        }
                            .disabled(!selectedRouteMatches || !client.ready || client.busy)
                            .accessibilityHint("Checks or resends the same saved message ID. Does not create a second message.")
                    }
                }
            }
            if client.outgoing.isEmpty, let sent = client.lastSentText {
                Section("Your message") {
                    Text(sent)
                    Button("Retry message") {
                        let context = client.actionContext, selected = provider
                        Task { await client.retryPending(context: context, selectedProvider: selected) }
                    }
                        .disabled(!selectedRouteMatches || !client.ready || client.busy)
                }
            }
            Section("Agent replies") {
                ForEach(client.replies, id: \.requestID) { reply in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(reply.text)
                        Text(client.provider == .dot ? "Your configured dot" : "Your configured Grok Bot")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if client.replies.isEmpty {
                    Text("Replies appear after they are received and saved on this Watch.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Text("Connect Dot with ChatGPT, or Grok Bot with X, in Peel Pro on iPhone.")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("Stop checking") {
                    let context = client.actionContext, selected = provider
                    Task { await client.stop(context: context, selectedProvider: selected) }
                }.disabled(!selectedRouteMatches)
                Text("Stops checking here. Your remote agent may keep working.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Cloud agents")
        .task { provider = client.provider; await client.refreshStatus() }
        .onChange(of: provider) { _, value in
            composing = false; composingContext = nil; text = ""
            Task { await client.select(value) }
        }
        .onChange(of: client.actionContext) { _, _ in composing = false; composingContext = nil }
        .onDisappear {
            let context = client.actionContext, selected = provider
            Task { await client.stop(context: context, selectedProvider: selected) }
        }
        .sheet(isPresented: $composing) {
            NavigationStack {
                Form {
                    TextField("Type or dictate", text: $text)
                    Text("Send to your \(provider == .dot ? "dot" : "Grok Bot").")
                        .font(.caption2)
                    Button("Send") {
                        guard let context = composingContext else { return }
                        let message = text, selected = provider
                        text = ""; composing = false; composingContext = nil
                        Task { await client.send(message, context: context, selectedProvider: selected) }
                    }.disabled(!selectedRouteMatches || !client.ready || client.busy
                               || composingContext != client.actionContext
                               || (try? PluginRelayMessage(messageID: UUID(), text: text)) == nil)
                    Button("Cancel", role: .cancel) { composing = false }
                }.navigationTitle("Agent message")
            }
        }
    }
    private func delivery(_ record: PluginRelaySendRecord) -> String {
        switch record.state {
        case .reserved: "Saved on this Watch; awaiting delivery."
        case .uncertain: "Delivery uncertain. Retry this saved message to check."
        case .accepted: "Received by Peel. Waiting for your agent’s reply."
        case .replied: "Your agent has replied. Check replies to receive it."
        }
    }
}
