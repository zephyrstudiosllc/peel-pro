import SwiftUI
import PeelWatchCore

private enum PeelWatchRoute: Hashable {
    case composer
    case drafts
    case voice
    case connection
    case demo
    case stream
    case cloud
}

struct PeelWatchHome: View {
    @ObservedObject var model: PeelCompanionModel
    @State private var showsMenu = false
    @State private var showsOptions = false
    @State private var showsProviders = false
    @State private var confirmsDelete = false
    @State private var path: [PeelWatchRoute] = []

    init(model: PeelCompanionModel) {
        _model = ObservedObject(wrappedValue: model)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--peel-watch-demo") {
            _path = State(initialValue: [.demo])
        } else if ProcessInfo.processInfo.arguments.contains("--peel-watch-voice-preview") {
            _path = State(initialValue: [.voice])
        }
        #endif
    }

    private var currentDrafts: [CompanionDraft] {
        model.drafts.filter { $0.provider == model.provider }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 8) {
                    HStack {
                        Button {
                            showsMenu = true
                        } label: {
                            PeelWatchCircleSymbol(symbol: "line.3.horizontal")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Peel Pro menu")
                        .accessibilityIdentifier("watch.home.menu")

                        Spacer(minLength: 4)
                        Text("Peel Pro")
                            .font(.system(.headline, design: .rounded))
                            .accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 4)

                        Button {
                            showsOptions = true
                        } label: {
                            PeelWatchCircleSymbol(symbol: "ellipsis")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("More options")
                        .accessibilityIdentifier("watch.home.more")
                    }

                    Button {
                        showsProviders = true
                    } label: {
                        HStack(spacing: 6) {
                            PeelWatchOrb()
                                .frame(width: 32, height: 32)
                                .accessibilityHidden(true)
                            Text(model.provider.displayName)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Provider, \(model.provider.displayName)")
                    .accessibilityHint("Choose OpenAI, Grok, or Claude")
                    .accessibilityIdentifier("watch.provider.selector")

                    Text("Connection needed")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    NavigationLink(value: PeelWatchRoute.stream) {
                        Label("Remote Desktop", systemImage: "display")
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .accessibilityIdentifier("watch.home.liveView")

                    NavigationLink(value: PeelWatchRoute.cloud) {
                        Label("Cloud agents", systemImage: "bubble.left.and.bubble.right")
                    }.buttonStyle(.bordered).accessibilityIdentifier("watch.home.cloudAgents")

                    NavigationLink(value: PeelWatchRoute.composer) {
                        Label("New message", systemImage: "square.and.pencil")
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .accessibilityIdentifier("watch.home.newMessage")

                    HStack(spacing: 8) {
                        NavigationLink(value: PeelWatchRoute.drafts) {
                            Label("Drafts \(currentDrafts.count)", systemImage: "tray")
                                .font(.caption)
                                .frame(maxWidth: .infinity, minHeight: 32)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Saved drafts, \(currentDrafts.count)")
                        .accessibilityIdentifier("watch.home.drafts")

                        NavigationLink(value: PeelWatchRoute.voice) {
                            Image(systemName: "waveform")
                                .font(.title3)
                                .frame(minWidth: 36, minHeight: 36)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Voice connection details")
                        .accessibilityIdentifier("watch.home.voice")
                    }

                    Text("Draft now. Continue on iPhone.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .containerBackground(.black, for: .navigation)
            .navigationDestination(for: PeelWatchRoute.self) { route in
                switch route {
                case .composer:
                    PeelWatchComposer(model: model)
                case .drafts:
                    PeelWatchDrafts(model: model)
                case .voice:
                    PeelWatchVoice(model: model)
                case .connection:
                    PeelWatchConnection(model: model)
                case .demo:
                    PeelWatchInterfaceDemo(model: model)
                case .stream:
                    PeelWatchStreamView(model: model)
                case .cloud:
                    PeelWatchCloudView(model: model)
                }
            }
            .sheet(isPresented: $showsProviders) {
                PeelWatchProviderPicker(model: model)
            }
            .sheet(isPresented: $showsMenu) {
                NavigationStack {
                    List {
                        Button {
                            showsMenu = false
                            path.append(.drafts)
                        } label: {
                            Label("Saved drafts", systemImage: "tray")
                        }
                        Button {
                            showsMenu = false
                            showsProviders = true
                        } label: {
                            Label("Choose provider", systemImage: "circle.grid.2x2")
                        }
                        Button {
                            showsMenu = false
                            path.append(.connection)
                        } label: {
                            Label("Connections", systemImage: "iphone")
                        }
                    }
                    .navigationTitle("Peel Pro")
                }
            }
            .confirmationDialog("Peel Pro options", isPresented: $showsOptions, titleVisibility: .visible) {
                Button("Connection details") { path.append(.connection) }
                Button("Interface demo") { path.append(.demo) }
                if !model.drafts.isEmpty {
                    Button("Delete all drafts", role: .destructive) { confirmsDelete = true }
                }
                Button("Cancel", role: .cancel) { }
            }
            .confirmationDialog("Delete all local drafts?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete all drafts", role: .destructive) { model.clearDrafts() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This removes drafts for every provider from this watch.")
            }
            .alert("Peel Pro", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.dismissError() } }
            )) {
                Button("OK", role: .cancel) { model.dismissError() }
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }
}

private struct PeelWatchProviderPicker: View {
    @ObservedObject var model: PeelCompanionModel
    @Environment(\.dismiss) private var dismiss

    private let providers: [CompanionProvider] = [.openAI, .grok, .claude]

    var body: some View {
        NavigationStack {
            List(providers, id: \.self) { provider in
                Button {
                    model.provider = provider
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: provider.systemImage)
                            .frame(width: 20)
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(provider.displayName)
                                .font(.headline)
                            Text(provider.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if model.provider == provider {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .accessibilityLabel("\(provider.displayName), \(model.provider == provider ? "selected" : "not selected")")
            }
            .navigationTitle("Provider")
        }
    }
}

private struct PeelWatchComposer: View {
    @ObservedObject var model: PeelCompanionModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(model.provider.displayName, systemImage: model.provider.systemImage)
                    .font(.caption)
                    .foregroundStyle(.orange)

                TextField("Message", text: $text, axis: .vertical)
                    .lineLimit(3...8)
                    .accessibilityLabel("Message draft")
                    .accessibilityHint("Use the watch keyboard or dictation to enter a message")
                    .accessibilityIdentifier("watch.composer.message")

                Text("Use the watch keyboard or dictation. Your draft stays local; saving does not contact an AI provider.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let error {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("watch.composer.error")
                }

                Button {
                    if model.saveDraft(text: trimmedText) {
                        dismiss()
                    } else {
                        error = model.errorMessage ?? "This draft could not be saved. Delete an older draft and try again."
                    }
                } label: {
                    Label("Save draft", systemImage: "tray.and.arrow.down")
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedText.isEmpty)
                .accessibilityIdentifier("watch.composer.save")
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 12)
        }
        .navigationTitle("New message")
    }
}

private struct PeelWatchDrafts: View {
    @ObservedObject var model: PeelCompanionModel

    private var drafts: [CompanionDraft] {
        model.drafts
            .filter { $0.provider == model.provider }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        Group {
            if drafts.isEmpty {
                ScrollView {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text("No saved drafts")
                            .font(.headline)
                        Text("Messages you save for \(model.provider.displayName) appear here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        NavigationLink(value: PeelWatchRoute.composer) {
                            Label("New message", systemImage: "square.and.pencil")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.horizontal, 4)
                }
                .accessibilityIdentifier("watch.drafts.empty")
            } else {
                List(drafts, id: \.id) { draft in
                    NavigationLink {
                        PeelWatchDraftDetail(model: model, draft: draft)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(draft.text)
                                .font(.body)
                                .lineLimit(3)
                            Text(draft.createdAt, style: .date)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            model.deleteDraft(draft)
                        }
                    }
                }
                .accessibilityIdentifier("watch.drafts.list")
            }
        }
        .navigationTitle("\(model.provider.displayName) drafts")
    }
}

private struct PeelWatchDraftDetail: View {
    @ObservedObject var model: PeelCompanionModel
    let draft: CompanionDraft
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Local draft · \(draft.provider.displayName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                PeelWatchMessageBubble(text: draft.text, isOutgoing: true)

                Text("No AI reply has been requested.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    model.sendToPhone(draft)
                } label: {
                    Label("Send to iPhone", systemImage: "iphone.and.arrow.forward")
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Transfers this draft to the companion. It does not send it to the AI provider.")
                .accessibilityIdentifier("watch.draft.sendToPhone")

                Text(model.status(for: draft))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("watch.draft.deliveryStatus")

                Text(model.transportStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("watch.draft.transportStatus")

                Button("Delete draft", role: .destructive) { confirmsDelete = true }
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 12)
        }
        .navigationTitle("Draft")
        .confirmationDialog("Delete this local draft?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete draft", role: .destructive) {
                model.deleteDraft(draft)
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        }
    }
}

private struct PeelWatchVoice: View {
    @ObservedObject var model: PeelCompanionModel

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                PeelWatchOrb()
                    .frame(width: 112, height: 112)
                    .accessibilityHidden(true)

                Text("Voice connection needed")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("watch.voice.status")

                Text("\(model.provider.displayName) voice is not connected. Peel Pro is not recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                NavigationLink(value: PeelWatchRoute.connection) {
                    Label("Connection details", systemImage: "iphone")
                }
                .buttonStyle(.bordered)

                NavigationLink(value: PeelWatchRoute.composer) {
                    Label("Write a draft", systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 12)
        }
        .navigationTitle("Voice")
    }
}

private struct PeelWatchConnection: View {
    @ObservedObject var model: PeelCompanionModel

    private var detail: String {
        switch model.provider {
        case .openAI:
            "Existing ChatGPT account and dot access are not connected. Drafts cannot start text or voice chats."
        case .grok:
            "X account sign-in and Grok chats are not connected. No API key or paid API billing is enabled."
        case .claude:
            "Claude chat and Claude Code on your computer are not connected. Peel Pro will not run remote session commands."
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(model.provider.displayName, systemImage: model.provider.systemImage)
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("Connection unavailable")
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                Text("The iPhone companion shows supported connection options and current limits. Local draft transfer is separate from provider access.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(model.transportStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 12)
        }
        .navigationTitle("Connections")
        .accessibilityIdentifier("watch.connection.details")
    }
}

private struct PeelWatchInterfaceDemo: View {
    @ObservedObject var model: PeelCompanionModel

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("INTERFACE DEMO")
                    .font(.caption2.bold())
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("watch.demo.badge")
                Text("Sample conversation. No provider is connected.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                PeelWatchMessageBubble(text: "Help me plan a focused morning.", isOutgoing: true)
                PeelWatchMessageBubble(text: "Choose one priority, reserve a quiet hour, and take a short break afterward.", isOutgoing: false)

                HStack(spacing: 8) {
                    NavigationLink(value: PeelWatchRoute.composer) {
                        Text("Message")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                            .padding(.leading, 10)
                            .background(Color(white: 0.2), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Create a real local message draft")

                    NavigationLink(value: PeelWatchRoute.voice) {
                        PeelWatchCircleSymbol(symbol: "waveform")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Voice connection details")
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 12)
        }
        .navigationTitle("Interface demo")
    }
}

private struct PeelWatchMessageBubble: View {
    let text: String
    let isOutgoing: Bool

    var body: some View {
        HStack {
            if isOutgoing { Spacer(minLength: 14) }
            Text(text)
                .font(.body)
                .foregroundStyle(isOutgoing ? .black : .white)
                .padding(10)
                .background(isOutgoing ? Color.cyan : Color(white: 0.15), in: RoundedRectangle(cornerRadius: 17))
                .fixedSize(horizontal: false, vertical: true)
            if !isOutgoing { Spacer(minLength: 8) }
        }
        .accessibilityLabel("\(isOutgoing ? "Your message" : "Sample reply"): \(text)")
    }
}

private struct PeelWatchCircleSymbol: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(Color(white: 0.14), in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.08), lineWidth: 1))
            .contentShape(Circle())
    }
}

/// Original abstract Peel artwork, drawn entirely from SwiftUI shapes.
struct PeelWatchOrb: View {
    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            ZStack {
                Circle()
                    .fill(.radialGradient(colors: [.orange.opacity(0.26), .clear], center: .center, startRadius: 0, endRadius: size / 2))
                Ellipse()
                    .fill(.linearGradient(colors: [Color(red: 1, green: 0.76, blue: 0.28), .orange, Color(red: 0.85, green: 0.24, blue: 0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: size * 0.64, height: size * 0.78)
                    .rotationEffect(.degrees(-28))
                Ellipse()
                    .trim(from: 0.08, to: 0.82)
                    .stroke(.black.opacity(0.5), style: StrokeStyle(lineWidth: size * 0.065, lineCap: .round))
                    .frame(width: size * 0.4, height: size * 0.66)
                    .rotationEffect(.degrees(38))
                Ellipse()
                    .trim(from: 0.1, to: 0.68)
                    .stroke(Color(red: 1, green: 0.87, blue: 0.59), style: StrokeStyle(lineWidth: size * 0.035, lineCap: .round))
                    .frame(width: size * 0.34, height: size * 0.62)
                    .rotationEffect(.degrees(36))
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

#Preview("Peel orb") {
    PeelWatchOrb()
        .frame(width: 130, height: 130)
        .padding()
        .background(.black)
}
