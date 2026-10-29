//
//  PeelMacSymbolChoice.swift
//  Peel
//
//  Created by Zach on 4/3/26.
//


import Foundation
import Combine

enum PeelMacSymbolChoice: String, Codable, CaseIterable, Identifiable {
    case automatic
    case macBookPro
    case macBookAir
    case macMini
    case macStudio
    case iMac
    case macPro
    case genericMac

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .macBookPro:
            return "MacBook Pro"
        case .macBookAir:
            return "MacBook Air"
        case .macMini:
            return "Mac mini"
        case .macStudio:
            return "Mac Studio"
        case .iMac:
            return "iMac"
        case .macPro:
            return "Mac Pro"
        case .genericMac:
            return "Generic Mac"
        }
    }

    /// SF Symbol to show in the host list.
    var symbolName: String {
        switch self {
        case .automatic:
            // The store resolves `.automatic` to a concrete choice before using this.
            return "macwindow"
        case .macBookPro:
            return "macbook"
        case .macBookAir:
            return "laptopcomputer"
        case .macMini:
            return "macmini"
        case .macStudio:
            return "macstudio"
        case .iMac:
            return "desktopcomputer"
        case .macPro:
            return "macpro.gen3"
        case .genericMac:
            return "macwindow"
        }
    }
}

final class PeelHostAppearanceStore: ObservableObject {
    @Published private(set) var overrides: [String: PeelMacSymbolChoice] = [:]

    private let defaults: UserDefaults
    private let storageKey = "PeelHostAppearanceStore.overrides"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Public API

    func stableKey(for host: PeelHostInfo) -> String {
        if let hostId = host.hostId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hostId.isEmpty {
            return "hostId:\(hostId)"
        }

        let serviceName = host.service.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !serviceName.isEmpty {
            return "service:\(serviceName)"
        }

        let hostName = host.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hostName.isEmpty {
            return "name:\(hostName)"
        }

        return "unknown"
    }

    func overrideChoice(for host: PeelHostInfo) -> PeelMacSymbolChoice {
        overrides[stableKey(for: host)] ?? .automatic
    }

    func setOverride(_ choice: PeelMacSymbolChoice, for host: PeelHostInfo) {
        let key = stableKey(for: host)

        if choice == .automatic {
            overrides.removeValue(forKey: key)
        } else {
            overrides[key] = choice
        }

        save()
    }

    func clearOverride(for host: PeelHostInfo) {
        overrides.removeValue(forKey: stableKey(for: host))
        save()
    }

    func resolvedChoice(for host: PeelHostInfo) -> PeelMacSymbolChoice {
        let override = overrideChoice(for: host)
        if override != .automatic {
            return override
        }

        return inferredChoice(for: host)
    }

    func inferredChoice(for host: PeelHostInfo) -> PeelMacSymbolChoice {
        let normalized = normalizedSearchString(for: host)

        if normalized.contains("macbook pro") {
            return .macBookPro
        }

        if normalized.contains("macbook air") {
            return .macBookAir
        }

        if normalized.contains("mac mini") {
            return .macMini
        }

        if normalized.contains("mac studio") {
            return .macStudio
        }

        if normalized.contains("imac") || normalized.contains("i mac") {
            return .iMac
        }

        if normalized.contains("mac pro") {
            return .macPro
        }

        return .genericMac
    }

    func symbolName(for host: PeelHostInfo) -> String {
        resolvedChoice(for: host).symbolName
    }

    func automaticPreviewTitle(for host: PeelHostInfo) -> String {
        inferredChoice(for: host).title
    }

    // MARK: - Persistence

    private func load() {
        guard let data = defaults.data(forKey: storageKey) else {
            overrides = [:]
            return
        }

        do {
            overrides = try JSONDecoder().decode([String: PeelMacSymbolChoice].self, from: data)
        } catch {
            overrides = [:]
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(overrides)
            defaults.set(data, forKey: storageKey)
        } catch {
            // Keep in-memory state even if persistence fails.
        }
    }

    // MARK: - Helpers

    private func normalizedSearchString(for host: PeelHostInfo) -> String {
        let parts = [
            host.name,
            host.service.name,
            host.hostId ?? ""
        ]

        return parts
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}
