import SwiftUI

struct PeelUsageSettingsView: View {
    let store: PeelUsageStore

    @State private var settings: PeelUsageSettingsStore
    @State private var filter = ""

    init(store: PeelUsageStore) {
        self.store = store
        self._settings = State(
            initialValue: PeelUsageSettingsStore(isPreview: store.isPreview))
    }

    private var visibleProviders: [PeelUsageSettingsProvider] {
        let query = self.filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return self.settings.providers }
        return self.settings.providers.filter { provider in
            provider.name.localizedCaseInsensitiveContains(query)
                || provider.id.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                self.header

                if self.settings.isPreview {
                    Label(
                        "Preview — live Codex Bar settings are paused.",
                        systemImage: "eye")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if let error = self.settings.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if let detailsError = self.settings.detailsErrorMessage {
                    Label(detailsError, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Toggle("Monitor provider limits", isOn: self.connectionBinding)
                        .disabled(self.settings.isPreview)
                    Text("Peel checks enabled providers silently. Providers that need a connection stay unavailable until you connect them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TextField("Filter providers", text: self.$filter)
                    .textFieldStyle(.roundedBorder)

                if self.settings.isRefreshing && self.settings.providers.isEmpty {
                    ContentUnavailableView(
                        "Loading Codex Bar providers",
                        systemImage: "arrow.triangle.2.circlepath",
                        description: Text("Reading the bundled provider configuration."))
                } else if self.visibleProviders.isEmpty {
                    ContentUnavailableView(
                        self.settings.providers.isEmpty ? "No providers reported" : "No matching providers",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text(
                            self.settings.providers.isEmpty
                                ? "Codex Bar did not return an available provider list."
                                : "Try a different provider name or identifier."))
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(self.visibleProviders) { provider in
                            self.providerRow(provider)
                        }
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
        .task {
            self.settings.refresh()
        }
        .onDisappear {
            self.settings.cancelPendingWork()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Usage Limits Settings")
                    .font(.largeTitle.bold())
                Text("Choose which providers appear in Usage Limits.")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Reload", systemImage: "arrow.clockwise") {
                self.settings.refresh()
            }
            .disabled(
                self.settings.isPreview
                    || self.settings.isRefreshing
                    || self.settings.isUpdating)
        }
    }

    private func providerRow(_ provider: PeelUsageSettingsProvider) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.name)
                        .font(.headline)
                    Text(provider.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Toggle(
                    provider.enabled ? "Enabled" : "Disabled",
                    isOn: self.enabledBinding(for: provider))
                    .toggleStyle(.switch)
                    .disabled(
                        self.settings.isPreview
                            || self.settings.isRefreshing
                            || self.settings.isUpdating)
            }

            if !provider.options.isEmpty {
                DisclosureGroup("Connection details") {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(provider.options) { option in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(option.title)
                                    .font(.subheadline.weight(.semibold))
                                Spacer(minLength: 8)
                                Text(option.detail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }
                    .padding(.top, 5)
                }
                .font(.subheadline)
            } else if self.settings.snapshot?.hasConfigurationDetails == true {
                Text("No additional stored options reported for this provider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 14))
    }

    private func enabledBinding(for provider: PeelUsageSettingsProvider) -> Binding<Bool> {
        Binding(
            get: {
                self.settings.providers.first(where: { $0.id == provider.id })?.enabled
                    ?? provider.enabled
            },
            set: { enabled in
                self.settings.setProviderEnabled(providerID: provider.id, enabled: enabled) {
                    self.store.reloadProviderConfiguration()
                }
            })
    }

    private var connectionBinding: Binding<Bool> {
        Binding(
            get: { self.store.isConnected },
            set: { enabled in
                if enabled {
                    self.store.connect()
                } else {
                    self.store.disconnect()
                }
            })
    }
}
