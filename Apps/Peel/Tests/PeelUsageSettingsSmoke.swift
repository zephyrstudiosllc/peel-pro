import Foundation

@main
enum PeelUsageSettingsSmoke {
    static func main() throws {
        let statuses = try PeelUsageSettingsParser.parseStatuses(Data(#"""
        [
          {"provider":"codex","displayName":"Codex","enabled":true,"defaultEnabled":true},
          {"provider":"cursor","displayName":"Cursor","enabled":false,"defaultEnabled":false}
        ]
        """#.utf8))
        precondition(statuses.map(\.id) == ["codex", "cursor"])
        precondition(statuses[0].options.isEmpty)

        let dump = try PeelUsageSettingsParser.parseConfigurationDump(Data(#"""
        {
          "version": 1,
          "providers": [
            {
              "id": "codex",
              "enabled": true,
              "source": "oauth",
              "cookieSource": "off",
              "region": "international",
              "quotaWarnings": {"weekly": {"thresholds": [50, 20]}},
              "apiKey": "[REDACTED]",
              "tokenAccounts": {"accounts": [{"token": "[REDACTED]"}]},
              "pluginSettings": {"mode": "fixture"},
              "pluginSecrets": {"secret": "[REDACTED]"}
            }
          ]
        }
        """#.utf8))
        let snapshot = PeelUsageSettingsParser.merge(statuses: statuses, optionsByProvider: dump)
        precondition(snapshot.hasConfigurationDetails)
        let codexOptions = snapshot.providers[0].options
        precondition(codexOptions.contains { $0.kind == .dataSource && $0.detail == "oauth" })
        precondition(codexOptions.contains { $0.kind == .browserSession && $0.detail == "off" })
        precondition(codexOptions.contains { $0.kind == .credentials })
        precondition(codexOptions.contains { $0.kind == .tokenAccounts })
        precondition(codexOptions.contains { $0.kind == .providerExtensions })
        precondition(codexOptions.allSatisfy { !$0.detail.contains("REDACTED") })
        precondition(snapshot.providers[1].options.isEmpty)

        try PeelUsageSettingsParser.parseToggle(
            Data(#"{"provider":"codex","enabled":false}"#.utf8),
            providerID: "codex",
            enabled: false)

        do {
            _ = try PeelUsageSettingsParser.parseStatuses(Data(#"""
            [
              {"provider":"codex","displayName":"Codex","enabled":true,"defaultEnabled":true},
              {"provider":"codex","displayName":"Duplicate","enabled":false,"defaultEnabled":false}
            ]
            """#.utf8))
            fatalError("Duplicate provider accepted")
        } catch PeelUsageSettingsParseError.duplicateProvider(let provider) {
            precondition(provider == "codex")
        }

        do {
            try PeelUsageSettingsParser.parseToggle(
                Data(#"{"provider":"cursor","enabled":true}"#.utf8),
                providerID: "codex",
                enabled: true)
            fatalError("Mismatched toggle accepted")
        } catch PeelUsageSettingsParseError.toggleMismatch {}

        print("PeelUsageSettingsSmoke: PASS (provider/config parsing, redaction and toggle validation)")
    }
}
