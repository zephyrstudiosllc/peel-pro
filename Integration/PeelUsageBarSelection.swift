import Foundation
import SwiftUI

/// The persisted CodexBar selection used by the unified menu bar label.
/// Empty IDs mean that the label may choose an available provider/window.
enum PeelUsageBarSelection {
    static let providerDefaultsKey = "peel.bar.usageProviderID.v1"
    static let windowDefaultsKey = "peel.bar.usageWindowKind.v1"

    static func resolve(
        providers: [PeelUsageProvider],
        providerID: String,
        windowKind: String
    ) -> PeelUsageBarSelectionResolution {
        let hasExplicitProvider = !providerID.isEmpty
        let hasExplicitWindow = !windowKind.isEmpty

        if hasExplicitProvider {
            guard let provider = providers.first(where: { $0.id == providerID }) else {
                return .unavailable(providerName: providerID, windowLabel: hasExplicitWindow ? windowKind : nil)
            }
            return resolve(provider: provider, windowKind: windowKind)
        }

        // With no provider pinned, an explicit window can still be useful:
        // choose the first available provider that exposes that window. This
        // is the only fallback path; a pinned provider never switches.
        let candidates = providers.filter { provider in
            guard provider.enabled, provider.error == nil else { return false }
            if hasExplicitWindow {
                return provider.windows.contains {
                    $0.kind == windowKind && $0.displayPercent != nil
                }
            }
            return provider.windows.contains { $0.displayPercent != nil }
        }

        guard let provider = candidates.first else {
            return providers.isEmpty ? .noProvider :
                .unavailable(providerName: nil, windowLabel: hasExplicitWindow ? windowKind : nil)
        }
        return resolve(provider: provider, windowKind: windowKind)
    }

    static func valueText(_ display: PeelUsageDisplayPercent) -> String {
        let percent = Int(display.value.rounded())
        return display.basis == .remaining ? "\(percent)% left" : "\(percent)% used"
    }

    static func valueHelp(
        provider: PeelUsageProvider,
        window: PeelUsageWindow,
        display: PeelUsageDisplayPercent
    ) -> String {
        "CodexBar · \(provider.name) · \(window.label) · \(valueText(display))"
    }

    static func unavailableHelp(providerName: String?, windowLabel: String?) -> String {
        var description = "Selected CodexBar usage is unavailable"
        if let providerName, !providerName.isEmpty {
            description += " for \(providerName)"
        }
        if let windowLabel, !windowLabel.isEmpty {
            description += " (\(windowLabel))"
        }
        return description + "."
    }

    private static func resolve(
        provider: PeelUsageProvider,
        windowKind: String
    ) -> PeelUsageBarSelectionResolution {
        guard provider.enabled, provider.error == nil else {
            return .unavailable(providerName: provider.name, windowLabel: windowKind.isEmpty ? nil : windowKind)
        }

        let window: PeelUsageWindow?
        if windowKind.isEmpty {
            window = provider.windows.first(where: { $0.displayPercent != nil })
        } else {
            window = provider.windows.first(where: { $0.kind == windowKind })
        }

        guard let window, let display = window.displayPercent else {
            return .unavailable(providerName: provider.name, windowLabel: windowKind.isEmpty ? nil : windowKind)
        }
        return .value(provider: provider, window: window, display: display)
    }
}

enum PeelUsageBarSelectionResolution {
    case value(
        provider: PeelUsageProvider,
        window: PeelUsageWindow,
        display: PeelUsageDisplayPercent)
    case unavailable(providerName: String?, windowLabel: String?)
    case noProvider
}

/// Controls persisted in Menu Bar Indicators. The selected provider remains
/// visible as unavailable while it is absent, so a temporary provider refresh
/// cannot silently change the menu bar's meaning.
struct PeelUsageBarSelectionControls: View {
    @Bindable var store: PeelUsageStore
    @AppStorage(PeelUsageBarSelection.providerDefaultsKey) private var selectedProviderID = ""
    @AppStorage(PeelUsageBarSelection.windowDefaultsKey) private var selectedWindowKind = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Usage provider", selection: providerSelection) {
                Text("Automatic (available)").tag("")
                ForEach(store.providers.filter { !$0.id.isEmpty }) { provider in
                    Text(provider.name).lineLimit(1).tag(provider.id)
                }
                if !selectedProviderID.isEmpty,
                   !store.providers.contains(where: { $0.id == selectedProviderID }) {
                    Text("Unavailable selection").tag(selectedProviderID)
                }
            }
            .pickerStyle(.menu)

            Picker("Usage window", selection: $selectedWindowKind) {
                Text("Automatic (first usable)").tag("")
                if let provider = windowPickerProvider {
                    ForEach(provider.windows) { window in
                        Text(window.label).lineLimit(1).tag(window.kind)
                    }
                }
                if !selectedWindowKind.isEmpty,
                   !(windowPickerProvider?.windows.contains { $0.kind == selectedWindowKind } ?? false) {
                    Text("Unavailable selection").tag(selectedWindowKind)
                }
            }
            .pickerStyle(.menu)

            Text(selectionDescription)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var providerSelection: Binding<String> {
        Binding(
            get: { selectedProviderID },
            set: { newValue in
                selectedProviderID = newValue
                guard !newValue.isEmpty,
                      !selectedWindowKind.isEmpty,
                      let provider = store.providers.first(where: { $0.id == newValue }) else {
                    return
                }
                // Keep a chosen window when the new provider has it; otherwise
                // return to that provider's first usable window.
                if !provider.windows.contains(where: { $0.kind == selectedWindowKind }) {
                    selectedWindowKind = ""
                }
            })
    }

    private var windowPickerProvider: PeelUsageProvider? {
        if !selectedProviderID.isEmpty {
            return store.providers.first(where: { $0.id == selectedProviderID })
        }
        return store.providers.first(where: { provider in
            provider.error == nil && provider.windows.contains { $0.displayPercent != nil }
        })
    }

    private var selectionDescription: String {
        switch PeelUsageBarSelection.resolve(
            providers: store.providers,
            providerID: selectedProviderID,
            windowKind: selectedWindowKind)
        {
        case let .value(provider, window, display):
            return "Menu bar: \(provider.name) · \(window.label) · \(PeelUsageBarSelection.valueText(display))"
        case let .unavailable(providerName, windowLabel):
            return PeelUsageBarSelection.unavailableHelp(
                providerName: providerName,
                windowLabel: windowLabel)
        case .noProvider:
            return "Menu bar: no available CodexBar usage."
        }
    }
}
