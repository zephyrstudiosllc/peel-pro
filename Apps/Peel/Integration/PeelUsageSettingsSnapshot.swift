import Foundation

/// A provider setting that can be shown without exposing credential material.
nonisolated struct PeelUsageSettingsOption: Identifiable, Equatable, Sendable {
    nonisolated enum Kind: String, Sendable {
        case credentials
        case dataSource
        case browserSession
        case extras
        case region
        case workspace
        case enterpriseHost
        case quotaWarnings
        case accentColor
        case tokenAccounts
        case providerExtensions
    }

    let kind: Kind
    let title: String
    let detail: String

    var id: String { self.kind.rawValue }
}

/// One actual provider reported by the bundled CodexBar CLI.
nonisolated struct PeelUsageSettingsProvider: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let enabled: Bool
    let defaultEnabled: Bool
    let options: [PeelUsageSettingsOption]
}

nonisolated struct PeelUsageSettingsSnapshot: Equatable, Sendable {
    let providers: [PeelUsageSettingsProvider]
    let hasConfigurationDetails: Bool
}

nonisolated enum PeelUsageSettingsParseError: LocalizedError, Equatable, Sendable {
    case invalidJSON(String)
    case invalidPayload(String)
    case duplicateProvider(String)
    case providerNotListed(String)
    case toggleMismatch

    nonisolated var errorDescription: String? {
        switch self {
        case let .invalidJSON(details):
            "Codex Bar returned invalid settings JSON: \(details)"
        case let .invalidPayload(details):
            "Codex Bar returned an invalid settings response: \(details)"
        case let .duplicateProvider(provider):
            "Codex Bar returned duplicate provider \(provider)."
        case let .providerNotListed(provider):
            "Codex Bar did not list provider \(provider)."
        case .toggleMismatch:
            "Codex Bar did not confirm the requested provider change."
        }
    }
}

nonisolated enum PeelUsageSettingsParser {
    nonisolated private static let maximumProviderCount = 256
    nonisolated private static let maximumIdentifierBytes = 128
    nonisolated private static let maximumDisplayNameBytes = 256

    nonisolated private struct ProviderStatusPayload: Decodable, Sendable {
        let provider: String
        let displayName: String
        let enabled: Bool
        let defaultEnabled: Bool
    }

    nonisolated private struct ConfigurationDumpPayload: Decodable, Sendable {
        let providers: [ConfigurationProviderPayload]
    }

    nonisolated private struct ConfigurationProviderPayload: Decodable, Sendable {
        let id: String
        let options: [PeelUsageSettingsOption]

        private enum Key: String, CodingKey {
            case id
            case source
            case extrasEnabled
            case apiKey
            case secretKey
            case cookieHeader
            case cookieSource
            case region
            case workspaceID
            case enterpriseHost
            case tokenAccounts
            case quotaWarnings
            case accentColor
            case pluginSettings
            case pluginSecrets
        }

        nonisolated init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            self.id = try container.decode(String.self, forKey: .id)
            var options: [PeelUsageSettingsOption] = []

            if let source = try? container.decode(String.self, forKey: .source), !source.isEmpty {
                options.append(PeelUsageSettingsOption(
                    kind: .dataSource,
                    title: "Data source",
                    detail: Self.safeValue(source)))
            }

            if let extras = try? container.decode(Bool.self, forKey: .extrasEnabled) {
                options.append(PeelUsageSettingsOption(
                    kind: .extras,
                    title: "Provider extras",
                    detail: extras ? "Enabled" : "Disabled"))
            }

            if let cookieSource = try? container.decode(String.self, forKey: .cookieSource),
               !cookieSource.isEmpty
            {
                options.append(PeelUsageSettingsOption(
                    kind: .browserSession,
                    title: "Browser session source",
                    detail: Self.safeValue(cookieSource)))
            }

            if Self.hasValue(container, key: .region) {
                options.append(PeelUsageSettingsOption(
                    kind: .region,
                    title: "Region",
                    detail: "Configured in Codex Bar"))
            }
            if Self.hasValue(container, key: .workspaceID) {
                options.append(PeelUsageSettingsOption(
                    kind: .workspace,
                    title: "Workspace",
                    detail: "Configured in Codex Bar"))
            }
            if Self.hasValue(container, key: .enterpriseHost) {
                options.append(PeelUsageSettingsOption(
                    kind: .enterpriseHost,
                    title: "Enterprise endpoint",
                    detail: "Configured in Codex Bar"))
            }
            if Self.hasValue(container, key: .quotaWarnings) {
                options.append(PeelUsageSettingsOption(
                    kind: .quotaWarnings,
                    title: "Quota warnings",
                    detail: "Customized in Codex Bar"))
            }
            if Self.hasValue(container, key: .accentColor) {
                options.append(PeelUsageSettingsOption(
                    kind: .accentColor,
                    title: "Accent color",
                    detail: "Custom color in Codex Bar"))
            }
            if Self.hasValue(container, key: .tokenAccounts) {
                options.append(PeelUsageSettingsOption(
                    kind: .tokenAccounts,
                    title: "Token accounts",
                    detail: "Configured"))
            }

            let hasCredential = Self.hasValue(container, key: .apiKey)
                || Self.hasValue(container, key: .secretKey)
                || Self.hasValue(container, key: .cookieHeader)
                || Self.hasValue(container, key: .pluginSecrets)
            if hasCredential {
                options.append(PeelUsageSettingsOption(
                    kind: .credentials,
                    title: "Credentials",
                    detail: "Configured"))
            }
            if Self.hasValue(container, key: .pluginSettings) {
                options.append(PeelUsageSettingsOption(
                    kind: .providerExtensions,
                    title: "Provider extensions",
                    detail: "Configured"))
            }

            self.options = options
        }

        private nonisolated static func hasValue(
            _ container: KeyedDecodingContainer<Key>,
            key: Key) -> Bool
        {
            guard container.contains(key) else { return false }
            return (try? container.decodeNil(forKey: key)) == false
        }

        private nonisolated static func safeValue(_ value: String) -> String {
            let cleaned = value
                .filter { !$0.isNewline }
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return "Configured" }
            let bounded = String(cleaned.prefix(64))
            return bounded.isEmpty ? "Configured" : bounded
        }
    }

    nonisolated private struct TogglePayload: Decodable, Sendable {
        let provider: String
        let enabled: Bool
    }

    nonisolated static func parseStatuses(_ data: Data) throws -> [PeelUsageSettingsProvider] {
        let payload: [ProviderStatusPayload]
        do {
            payload = try JSONDecoder().decode([ProviderStatusPayload].self, from: data)
        } catch {
            throw PeelUsageSettingsParseError.invalidJSON(error.localizedDescription)
        }
        guard payload.count <= self.maximumProviderCount else {
            throw PeelUsageSettingsParseError.invalidPayload("Too many providers.")
        }

        var seen: Set<String> = []
        return try payload.map { status in
            guard self.isSafeIdentifier(status.provider),
                  self.isSafeDisplayName(status.displayName) else {
                throw PeelUsageSettingsParseError.invalidPayload("Provider identity is out of bounds.")
            }
            guard seen.insert(status.provider).inserted else {
                throw PeelUsageSettingsParseError.duplicateProvider(status.provider)
            }
            return PeelUsageSettingsProvider(
                id: status.provider,
                name: status.displayName,
                enabled: status.enabled,
                defaultEnabled: status.defaultEnabled,
                options: [])
        }
    }

    nonisolated static func parseConfigurationDump(_ data: Data) throws -> [String: [PeelUsageSettingsOption]] {
        let payload: ConfigurationDumpPayload
        do {
            payload = try JSONDecoder().decode(ConfigurationDumpPayload.self, from: data)
        } catch {
            throw PeelUsageSettingsParseError.invalidJSON(error.localizedDescription)
        }
        guard payload.providers.count <= self.maximumProviderCount else {
            throw PeelUsageSettingsParseError.invalidPayload("Too many configured providers.")
        }

        var optionsByProvider: [String: [PeelUsageSettingsOption]] = [:]
        for provider in payload.providers {
            guard self.isSafeIdentifier(provider.id) else {
                throw PeelUsageSettingsParseError.invalidPayload("Configured provider identity is out of bounds.")
            }
            guard optionsByProvider[provider.id] == nil else {
                throw PeelUsageSettingsParseError.duplicateProvider(provider.id)
            }
            optionsByProvider[provider.id] = provider.options
        }
        return optionsByProvider
    }

    nonisolated static func merge(
        statuses: [PeelUsageSettingsProvider],
        optionsByProvider: [String: [PeelUsageSettingsOption]]?) -> PeelUsageSettingsSnapshot
    {
        let providers = statuses.map { status in
            PeelUsageSettingsProvider(
                id: status.id,
                name: status.name,
                enabled: status.enabled,
                defaultEnabled: status.defaultEnabled,
                options: optionsByProvider?[status.id] ?? [])
        }
        return PeelUsageSettingsSnapshot(
            providers: providers,
            hasConfigurationDetails: optionsByProvider != nil)
    }

    nonisolated static func parseToggle(
        _ data: Data,
        providerID: String,
        enabled: Bool) throws
    {
        let payload: TogglePayload
        do {
            payload = try JSONDecoder().decode(TogglePayload.self, from: data)
        } catch {
            throw PeelUsageSettingsParseError.invalidJSON(error.localizedDescription)
        }
        guard payload.provider == providerID, payload.enabled == enabled else {
            throw PeelUsageSettingsParseError.toggleMismatch
        }
    }

    private nonisolated static func isSafeIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= self.maximumIdentifierBytes
            && !value.contains(where: { $0.isNewline || $0.isWhitespace })
            && !self.hasControlScalar(value)
    }

    private nonisolated static func isSafeDisplayName(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= self.maximumDisplayNameBytes
            && !value.contains(where: { $0.isNewline })
            && !self.hasControlScalar(value)
    }

    private nonisolated static func hasControlScalar(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            $0.properties.generalCategory == .control
        }
    }
}
