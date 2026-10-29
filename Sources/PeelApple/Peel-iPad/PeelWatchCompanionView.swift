import SwiftUI
import PeelWatchCore

/// Companion settings live inside Peel; commerce and streaming policy are unchanged.
struct PeelWatchCompanionView: View {
    @ObservedObject var model: PeelCompanionModel
    @ObservedObject private var relay = PeelCompanionModel.shared.phoneWatchRelay
    @EnvironmentObject private var browser: PeelClientBrowser
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var composing = false
    @State private var streamChoice = ""

    var body: some View {
        NavigationStack {
            List {
                introductionSection
                liveViewSection
                pairedDevicesSection
                providerSection
                draftsSection
            }
            .navigationTitle("Watch & Cloud Agents")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { composing = true } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("New draft")
                        .accessibilityIdentifier("peel.watch.newDraft")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $composing) { PeelPhoneDraftComposer(model: model) }
            .alert("Draft could not be saved", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.dismissError() } }
            )) {
                Button("OK") { model.dismissError() }
            } message: { Text(model.errorMessage ?? "Please try again.") }
        }
        .tint(.orange)
        .onAppear { relay.bind(browser) }
        .onDisappear { relay.stop() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            relay.stop("Sharing stopped because iPhone is inactive.")
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { relay.stop("Sharing stopped because iPhone is inactive.") } }
    }

    private var introductionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "applewatch.radiowaves.left.and.right")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.orange)
                    Spacer()
                    Text("PEEL ON YOUR WRIST")
                        .font(.caption2.bold()).tracking(1)
                        .foregroundStyle(.secondary)
                }
                Text("A little Peel Pro.\nAlways close.")
                    .font(.largeTitle.bold()).tracking(-1)
                Text("View a window through this iPhone, or keep a thought for your agent. Keep Peel Pro open on both paired devices while viewing.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
        }
        .listRowBackground(Color.orange.opacity(0.07))
    }

    private var liveViewSection: some View {
        Section {
            if relay.isSharing {
                Label(relay.sharedTitle, systemImage: "display")
                Text(relay.status).font(.caption).foregroundStyle(.secondary)
                if relay.waitingForControl {
                    Button("Cancel control request", role: .cancel) { relay.revokeControl() }
                } else if relay.controlAllowed {
                    Button("Revoke Watch Control", role: .destructive) { relay.revokeControl() }
                        .accessibilityIdentifier("peel.watch.revokeControl")
                } else {
                    Button("Allow Watch Control") { Task { await relay.allowControl() } }
                        .accessibilityIdentifier("peel.watch.allowControl")
                }
                Button("Stop sharing", role: .destructive) { relay.stop() }
                    .accessibilityIdentifier("peel.watch.stopSharing")
            } else {
                let choices = relay.choices
                if choices.isEmpty {
                    Text("Open a paired computer’s window or desktop stream in Peel Pro first, then return here.")
                        .font(.subheadline)
                } else {
                    Picker("Open stream", selection: $streamChoice) {
                        Text("Choose a stream").tag("")
                        ForEach(choices) { choice in Text(choice.label).tag(choice.id) }
                    }
                    .accessibilityIdentifier("peel.watch.streamChoice")
                    Button("Share live view with Watch") {
                        if let choice = choices.first(where: { $0.id == streamChoice }) { relay.start(choice) }
                    }
                    .disabled(!choices.contains(where: { $0.id == streamChoice }))
                    .accessibilityIdentifier("peel.watch.shareStream")
                }
                Text(relay.status).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Remote Desktop on Watch")
        } footer: {
            Text("A cropped live view at up to 1 frame per second. Crown zoom and pan reveal source detail. Watch control is off until allowed here, and still requires the computer’s control permission. Leaving this page, locking iPhone, or losing the Watch stops sharing. The original phone stream stays open.")
        }
    }

    private var pairedDevicesSection: some View {
        Section("Paired devices") {
            Label(model.transportStatus, systemImage: "iphone.and.arrow.forward")
                .font(.subheadline)
            Text("Draft delivery is local to your paired Apple devices. It does not send a message to an AI provider.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var providerSection: some View {
        Section("Your provider") {
            NavigationLink("Sign in to your cloud agent") { PeelCloudAgentSettingsView() }
            Picker("Provider", selection: $model.provider) {
                ForEach(CompanionProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("peel.watch.provider")
            NavigationLink {
                PeelWatchProviderView(provider: model.provider)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: model.provider.systemImage)
                        .font(.title2).foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.provider.displayName).font(.headline)
                        Text("Connection not available").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 5)
            }
            Text("Existing-account chat and voice are not connected in this preview. View connection options for the verified limits.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var draftsSection: some View {
        Section {
            Button { composing = true } label: {
                Label("New draft", systemImage: "square.and.pencil")
            }
            .accessibilityIdentifier("peel.watch.newDraft.list")
            ForEach(model.drafts.filter { $0.provider == model.provider }) { draft in
                NavigationLink {
                    PeelPhoneDraftView(model: model, draft: draft)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(draft.text).lineLimit(2)
                        Text(draft.createdAt, style: .relative)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { indices in
                let visible = model.drafts.filter { $0.provider == model.provider }
                for index in indices { model.deleteDraft(visible[index]) }
            }
            if !model.drafts.contains(where: { $0.provider == model.provider }) {
                Text("Your saved drafts will appear here.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        } header: {
            Text("\(model.provider.displayName) drafts")
        } footer: {
            Text("This companion adds no purchase or subscription. Provider eligibility and existing Peel Pro pricing are separate.")
        }
    }
}

private struct PeelPhoneDraftComposer: View {
    @ObservedObject var model: PeelCompanionModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("\(model.provider.displayName) draft") {
                    TextEditor(text: $text).frame(minHeight: 160)
                        .accessibilityIdentifier("peel.watch.draftText")
                    Text("Saved in Peel Pro. No AI message will be sent.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New draft")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { if model.saveDraft(text: text) { dismiss() } }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 4_000)
                        .accessibilityIdentifier("peel.watch.saveDraft")
                }
            }
        }
    }
}

private struct PeelPhoneDraftView: View {
    @ObservedObject var model: PeelCompanionModel
    let draft: CompanionDraft
    var body: some View {
        List {
            Section(draft.provider.displayName) {
                Text(draft.text).textSelection(.enabled)
                Text(draft.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ShareLink(item: draft.text) { Label("Share draft", systemImage: "square.and.arrow.up") }
                Button { model.sendToPhone(draft) } label: {
                    Label("Send to Apple Watch", systemImage: "applewatch")
                }
                Text(model.status(for: draft)).font(.caption).foregroundStyle(.secondary)
            } footer: {
                Text("Sending to the watch saves a draft there. It does not contact \(draft.provider.displayName).")
            }
            NavigationLink("Connection options") { PeelWatchProviderView(provider: draft.provider) }
        }
        .navigationTitle("Draft")
    }
}

struct PeelWatchProviderView: View {
    let provider: CompanionProvider
    @AppStorage("Peel.Watch.claudeSessionURL") private var savedClaudeSessionURL = ""
    @State private var claudeSessionURL = ""
    @State private var invalidSession = false
    @Environment(\.openURL) private var openURL

    private var officialURL: URL {
        switch provider {
        case .openAI: return URL(string: "https://chatgpt.com")!
        case .grok: return URL(string: "https://grok.com")!
        case .claude: return URL(string: "https://claude.ai")!
        }
    }

    var body: some View {
        List {
            Section {
                Label("Not connected", systemImage: "link.badge.plus")
                    .foregroundStyle(.secondary)
                Text(explanation).font(.subheadline)
                Link("Open \(provider.displayName) on iPhone", destination: officialURL)
            } footer: {
                Text("Opens the official service. Signing in there does not connect Peel Pro or grant watch access. Draft text is not included in the link.")
            }
            if provider == .claude {
                Section("Claude Code on your computer") {
                    Text("Start Remote Control in an authenticated Claude Code session on your computer. You can open its official session link here. The computer and session must stay online.")
                        .font(.subheadline)
                    TextField("https://claude.ai/code/…", text: $claudeSessionURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("peel.watch.claudeSession")
                    Button("Open official session") {
                        if let url = try? OfficialClaudeSessionURL.validated(claudeSessionURL) {
                            savedClaudeSessionURL = url.absoluteString
                            openURL(url)
                        } else { invalidSession = true }
                    }
                    .disabled(claudeSessionURL.isEmpty)
                    Text("This opens Claude’s client. Peel Pro does not yet control or read the remote session.")
                        .font(.caption).foregroundStyle(.secondary)
                    Link("Remote Control setup", destination: URL(string: "https://code.claude.com/docs/en/remote-control")!)
                }
            }
            Section("Voice") {
                Text("Live provider voice is unavailable. The watch’s system dictation can enter text into a local draft; it is not a voice conversation.")
                    .font(.subheadline)
            }
            Section("Documentation") {
                Link("Supported integration details", destination: documentationURL)
            }
        }
        .navigationTitle(provider.displayName)
        .onAppear {
            if let url = try? OfficialClaudeSessionURL.validated(savedClaudeSessionURL) {
                claudeSessionURL = url.absoluteString
            }
        }
        .alert("Use an official session link", isPresented: $invalidSession) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Use an HTTPS claude.ai/code link without a password, query, or fragment.")
        }
    }

    private var explanation: String {
        switch provider {
        case .openAI:
            return "Sign in with ChatGPT supports eligible apps, but does not grant existing ChatGPT conversations or dot access. A supported iPhone-to-dot and voice connection has not been established. Peel Pro does not request your password, session cookies, or an API key."
        case .grok:
            return "X sign-in does not document permission for third-party Grok chats or voice. A one-time X login cannot currently be offered here as a supported Grok connection."
        case .claude:
            return "Direct Claude subscription chat in a third-party app requires Anthropic approval. Peel Pro does not reuse Claude login credentials. Claude Code Remote Control is a separate feature in Claude’s official clients."
        }
    }

    private var documentationURL: URL {
        switch provider {
        case .openAI: return URL(string: "https://developers.openai.com/siwc/token-sharing-open-source")!
        case .grok: return URL(string: "https://docs.x.ai/developers/faq/accounts")!
        case .claude: return URL(string: "https://code.claude.com/docs/en/legal-and-compliance")!
        }
    }
}
