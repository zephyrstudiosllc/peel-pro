import Foundation

@main
enum PeelUsageSnapshotSmoke {
    @MainActor
    static func main() throws {
        let snapshot = try testValidSnapshotAndOptionalData()
        testFreshness(snapshot)
        testSchemaAndRootErrors()
        testDuplicateProviderIDs()
        testNonfiniteConstruction()
        testDecodeHealth()
        try testCostTokenDetail()
        print("PeelUsageSnapshotSmoke: PASS")
    }

    private nonisolated static func testValidSnapshotAndOptionalData() throws -> PeelUsageSnapshot {
        let json = """
        {
          "schemaVersion": 1,
          "generatedAt": "2026-09-05T12:00:00Z",
          "staleAfterSeconds": 180,
          "host": {
            "codexBarVersion": "fixture",
            "refreshIntervalSeconds": 60,
            "futureHostField": true
          },
          "providers": [
            {
              "id": "codex",
              "name": "Codex",
              "enabled": true,
              "source": "oauth",
              "status": {
                "level": "ok",
                "label": "Operational",
                "updatedAt": "2026-09-05T11:59:00Z"
              },
              "identity": {
                "accountEmail": "codex@example.test",
                "plan": "Plus"
              },
              "windows": [
                {
                  "kind": "session",
                  "label": "Session",
                  "usedPercent": 28,
                  "remainingPercent": 72,
                  "resetAt": "2026-09-05T17:15:00Z",
                  "idle": false
                },
                {
                  "kind": "weekly",
                  "label": "Weekly",
                  "usedPercent": null,
                  "remainingPercent": 55,
                  "resetAt": null
                },
                {
                  "kind": "malformed-optional-fields",
                  "label": "Still available",
                  "usedPercent": "NaN",
                  "remainingPercent": 101,
                  "resetAt": "not-a-timestamp"
                }
              ],
              "credits": {
                "remaining": 112.4,
                "unit": "credits"
              },
              "cost": {
                "todayUSD": 1.04,
                "last30DaysUSD": 18.22
              },
              "error": null,
              "updatedAt": "2026-09-05T11:59:30Z",
              "futureProviderField": ["ignored"]
            },
            {
              "id": "claude",
              "name": "Claude",
              "enabled": false,
              "source": 42,
              "status": {
                "level": 7,
                "label": "Broken status"
              },
              "identity": {
                "accountEmail": "claude@example.test",
                "plan": "Team",
                "futureIdentityField": "ignored"
              },
              "windows": null,
              "accounts": [
                {
                  "id": "claude-swap:2",
                  "label": "personal@example.test",
                  "active": true,
                  "identity": {
                    "accountEmail": "personal@example.test",
                    "plan": null
                  },
                  "windows": [
                    {
                      "kind": "session",
                      "label": "Session",
                      "usedPercent": 40,
                      "remainingPercent": 60,
                      "resetAt": "2026-09-05T17:00:00Z"
                    },
                    {
                      "kind": "weekly",
                      "label": "Weekly",
                      "usedPercent": 60,
                      "remainingPercent": 40,
                      "resetAt": "2026-09-07T12:00:00Z"
                    }
                  ],
                  "pace": {
                    "primary": {
                      "stage": "ahead",
                      "deltaPercent": 20,
                      "expectedUsedPercent": 20,
                      "willLastToReset": true,
                      "etaSeconds": null,
                      "runOutProbability": null,
                      "summary": "20% in deficit | Expected 20% used | Lasts to reset"
                    },
                    "secondary": {
                      "stage": "ahead",
                      "deltaPercent": 31,
                      "expectedUsedPercent": 29,
                      "willLastToReset": false,
                      "etaSeconds": 144000,
                      "runOutProbability": null,
                      "summary": "31% in deficit | Expected 29% used | Runs out in 1d 16h"
                    }
                  },
                  "error": null,
                  "updatedAt": "2026-09-05T12:00:00Z"
                },
                {
                  "id": "claude-swap:1",
                  "label": "expired@example.test",
                  "active": false,
                  "identity": {
                    "accountEmail": "expired@example.test",
                    "plan": null
                  },
                  "windows": [],
                  "pace": null,
                  "error": "Token expired. Switch to this account in claude-swap to refresh it.",
                  "updatedAt": null
                },
                {
                  "id": 42,
                  "label": "Dropped malformed account",
                  "active": true
                }
              ],
              "error": {
                "code": 429,
                "message": "Rate limited",
                "kind": "provider"
              },
              "updatedAt": "not-a-timestamp"
            },
            {
              "id": "empty",
              "name": "Empty",
              "enabled": true,
              "source": null,
              "status": null,
              "identity": null,
              "windows": null,
              "accounts": null,
              "accountsError": "The claude-swap adapter timed out.",
              "error": null,
              "updatedAt": null
            },
            42
          ]
        }
        """

        let snapshot = try PeelUsageSnapshotParser.parse(json)
        precondition(snapshot.schemaVersion == 1)
        precondition(snapshot.staleAfterSeconds == 180)
        precondition(snapshot.providers.count == 3)
        // The bare `42` row is unreadable: counted, never silently dropped.
        precondition(snapshot.rejectedProviderCount == 1)
        precondition(snapshot.rejectedProviderIDs.isEmpty)
        precondition(snapshot.decodeHealth == .partial(rejected: 1))

        let codex = try provider("codex", in: snapshot)
        let claude = try provider("claude", in: snapshot)
        let empty = try provider("empty", in: snapshot)
        precondition(codex.identity?.accountEmail == "codex@example.test")
        precondition(codex.identity?.plan == "Plus")
        precondition(codex.credits?.remaining == 112.4)
        precondition(codex.credits?.unit == "credits")
        precondition(codex.cost?.todayUSD == 1.04)
        precondition(codex.cost?.last30DaysUSD == 18.22)
        precondition(claude.identity?.accountEmail == "claude@example.test")
        precondition(claude.identity?.plan == "Team")
        precondition(codex.identity?.accountEmail != claude.identity?.accountEmail)

        guard let accounts = claude.accounts, accounts.count == 2 else {
            throw PeelUsageSnapshotError.malformedPayload("Expected two decoded account rows.")
        }
        guard let activeAccount = accounts.first(where: { $0.id == "claude-swap:2" }) else {
            throw PeelUsageSnapshotError.malformedPayload("Expected the active account row.")
        }
        precondition(activeAccount.label == "personal@example.test")
        precondition(activeAccount.active)
        precondition(activeAccount.identity?.accountEmail == "personal@example.test")
        precondition(activeAccount.windows.count == 2)
        precondition(activeAccount.windows[0].normalizedRemainingPercent == 60)
        precondition(activeAccount.pace?.primary?.summary == "20% in deficit | Expected 20% used | Lasts to reset")
        precondition(activeAccount.pace?.secondary?.etaSeconds == 144000)
        guard let expiredAccount = accounts.first(where: { $0.id == "claude-swap:1" }) else {
            throw PeelUsageSnapshotError.malformedPayload("Expected the expired account row.")
        }
        precondition(!expiredAccount.active)
        precondition(expiredAccount.windows.isEmpty)
        precondition(expiredAccount.error?.hasPrefix("Token expired") == true)

        precondition(codex.source == "oauth")
        precondition(codex.status?.level == "ok")
        precondition(codex.status?.label == "Operational")
        precondition(codex.status?.updatedAt != nil)
        precondition(codex.updatedAt != nil)

        let session = codex.windows[0]
        precondition(session.usedPercent == 28)
        precondition(session.remainingPercent == 72)
        precondition(session.normalizedUsedPercent == 28)
        precondition(session.normalizedRemainingPercent == 72)
        precondition(session.displayPercent?.value == 28)
        precondition(session.displayPercent?.basis == .used)
        precondition(session.displayPercent?.semantics == .used)
        precondition(session.resetAt != nil)

        let weekly = codex.windows[1]
        precondition(weekly.usedPercent == nil)
        precondition(weekly.remainingPercent == 55)
        precondition(weekly.normalizedUsedPercent == 45)
        precondition(weekly.normalizedRemainingPercent == 55)
        precondition(weekly.displayPercent?.value == 55)
        precondition(weekly.displayPercent?.basis == .remaining)

        let malformedOptional = codex.windows[2]
        precondition(malformedOptional.usedPercent == nil)
        precondition(malformedOptional.remainingPercent == nil)
        precondition(malformedOptional.resetAt == nil)
        precondition(malformedOptional.displayPercent == nil)

        precondition(claude.status == nil)
        precondition(claude.source == nil)
        precondition(claude.windows.isEmpty)
        precondition(claude.updatedAt == nil)
        precondition(claude.error?.code == 429)
        precondition(claude.error?.message == "Rate limited")
        precondition(claude.error?.kind == "provider")
        precondition(empty.source == nil)
        precondition(empty.status == nil)
        precondition(empty.identity == nil)
        precondition(empty.windows.isEmpty)
        precondition(empty.error == nil)
        precondition(empty.accounts == nil)
        precondition(empty.accountsError == "The claude-swap adapter timed out.")
        precondition(empty.updatedAt == nil)

        let directDataInit = try PeelUsageSnapshot(data: Data(json.utf8))
        precondition(directDataInit == snapshot)
        return snapshot
    }

    private nonisolated static func testFreshness(_ snapshot: PeelUsageSnapshot) {
        let generatedAt = snapshot.generatedAt
        precondition(snapshot.age(at: generatedAt.addingTimeInterval(179)) == 179)
        precondition(snapshot.isFresh(at: generatedAt.addingTimeInterval(179)))
        precondition(!snapshot.isStale(at: generatedAt.addingTimeInterval(179)))
        precondition(snapshot.isStale(at: generatedAt.addingTimeInterval(180)))
        precondition(!snapshot.isFresh(at: generatedAt.addingTimeInterval(180)))
        precondition(!snapshot.isStale(at: generatedAt.addingTimeInterval(-1)))
    }

    private nonisolated static func testSchemaAndRootErrors() {
        let valid = """
        {
          "schemaVersion": 1,
          "generatedAt": "2026-09-05T12:00:00Z",
          "staleAfterSeconds": 180,
          "providers": []
        }
        """

        let unsupported = valid.replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 2")
        let unsupportedError = expectError {
            _ = try PeelUsageSnapshotParser.parse(unsupported)
        }
        if case let .unsupportedSchemaVersion(version) = unsupportedError {
            precondition(version == 2)
        } else {
            preconditionFailure("Expected unsupported schema error, got \(unsupportedError)")
        }

        let malformedTimestamp = valid.replacingOccurrences(
            of: "\"generatedAt\": \"2026-09-05T12:00:00Z\"",
            with: "\"generatedAt\": \"tomorrow\"")
        let timestampError = expectError {
            _ = try PeelUsageSnapshotParser.parse(malformedTimestamp)
        }
        if case let .malformedTimestamp(field, value) = timestampError {
            precondition(field == "generatedAt")
            precondition(value == "tomorrow")
        } else {
            preconditionFailure("Expected timestamp error, got \(timestampError)")
        }

        let invalidRoot = valid.replacingOccurrences(of: "\"providers\": []", with: "\"providers\": true")
        let rootError = expectError {
            _ = try PeelUsageSnapshotParser.parse(invalidRoot)
        }
        if case let .invalidRootField(field) = rootError {
            precondition(field == "providers")
        } else {
            preconditionFailure("Expected invalid root field error, got \(rootError)")
        }

        let invalidJSONError = expectError {
            _ = try PeelUsageSnapshotParser.parse("{")
        }
        if case .invalidJSON = invalidJSONError {
            // Expected.
        } else {
            preconditionFailure("Expected invalid JSON error, got \(invalidJSONError)")
        }
    }

    private nonisolated static func testDuplicateProviderIDs() {
        let duplicate = """
        {
          "schemaVersion": 1,
          "generatedAt": "2026-09-05T12:00:00Z",
          "staleAfterSeconds": 180,
          "providers": [
            {"id": "same", "name": "One", "enabled": true},
            {"id": "same", "name": "Two", "enabled": true}
          ]
        }
        """
        let error = expectError {
            _ = try PeelUsageSnapshotParser.parse(duplicate)
        }
        if case let .duplicateProviderID(id) = error {
            precondition(id == "same")
        } else {
            preconditionFailure("Expected duplicate provider error, got \(error)")
        }
    }

    private nonisolated static func testNonfiniteConstruction() {
        let window = PeelUsageWindow(
            kind: "finite-check",
            label: "Finite check",
            usedPercent: .infinity,
            remainingPercent: .nan)
        precondition(window.usedPercent == nil)
        precondition(window.remainingPercent == nil)
        precondition(window.displayPercent == nil)
    }

    private nonisolated static func testDecodeHealth() {
        func parse(_ providers: String) -> PeelUsageSnapshot {
            let json = """
            {"schemaVersion": 1, "generatedAt": "2026-09-05T12:00:00Z", "staleAfterSeconds": 180,
             "providers": \(providers)}
            """
            do { return try PeelUsageSnapshotParser.parse(json) } catch {
                preconditionFailure("Fixture should parse: \(error)")
            }
        }

        let empty = parse("[]")
        precondition(empty.decodeHealth == .emptySelection)

        // Every row unreadable: incompatible output, not "no providers".
        let allInvalid = parse("""
            [{"id": "claude", "name": 7, "enabled": true},
             {"id": "codex", "enabled": "yes"},
             {"id": "../../etc", "name": "Bad", "enabled": null},
             "row"]
            """)
        precondition(allInvalid.providers.isEmpty)
        precondition(allInvalid.decodeHealth == .incompatible(rejected: 4))
        // Only safe helper-shaped identifiers are kept for diagnostics.
        precondition(allInvalid.rejectedProviderIDs == ["claude", "codex"])

        let mixed = parse("""
            [{"id": "codex", "name": "Codex", "enabled": true},
             {"id": "claude", "name": "Claude", "enabled": true, "error": {"code": 3, "message": "Sign in required"}},
             {"id": "broken", "enabled": true}]
            """)
        precondition(mixed.providers.map(\.id) == ["codex", "claude"])
        precondition(mixed.decodeHealth == .partial(rejected: 1))
        precondition(mixed.rejectedProviderIDs == ["broken"])
        // A provider error is a valid row, not a rejected one.
        precondition(mixed.providers[1].error?.code == 3)
    }

    private nonisolated static func testCostTokenDetail() throws {
        let json = """
        {"schemaVersion": 1, "generatedAt": "2026-10-21T18:00:00Z", "staleAfterSeconds": 180,
         "providers": [
          {"id": "claude", "name": "Claude", "enabled": true, "source": "oauth",
           "cost": {"todayUSD": null, "last30DaysUSD": null, "source": "local",
                    "updatedAt": "2026-10-21T17:59:00Z", "historyDays": 30,
                    "historyCoverageIsEstablished": true, "provenance": "listPriceEstimate",
                    "coverage": {"priced": 3, "unpriced": 1, "unmetered": 0, "estimated": 0},
                    "historyTokens": {"inputTokens": 900, "outputTokens": -5, "cacheReadTokens": 1e30,
                                      "cacheCreationTokens": 12.5, "reasoningTokens": "7", "totalTokens": 1400,
                                      "models": [{"modelName": "/Users/fixture/models/local-fixture.gguf",
                                                  "totalTokens": 400},
                                                 {"modelName": "claude-sonnet-4-5", "totalTokens": 1000, "cost": 0.5},
                                                 {"modelName": "   "}],
                                      "omittedModelCount": 2}}},
          {"id": "codex", "name": "Codex", "enabled": true,
           "cost": {"todayUSD": null, "last30DaysUSD": null}}
         ]}
        """
        let snapshot = try PeelUsageSnapshotParser.parse(json)
        let claude = try provider("claude", in: snapshot)
        let codex = try provider("codex", in: snapshot)
        guard let cost = claude.cost, let history = cost.historyTokens else {
            throw PeelUsageSnapshotError.malformedPayload("Expected token-only cost detail to survive.")
        }
        // Tokens without a USD amount are still a meaningful cost row; USD stays unknown, never zero.
        precondition(cost.todayUSD == nil && cost.last30DaysUSD == nil)
        precondition(cost.source == "local")
        precondition(cost.provenance == .listPriceEstimate)
        precondition(cost.coverage == PeelCostCoverage(priced: 3, unpriced: 1))
        precondition(cost.coverage?.isFullyPriced == false)
        precondition(cost.historyCoverageIsEstablished == true)
        precondition(history.tokens.input == 900)
        precondition(history.tokens.output == nil)          // negative
        precondition(history.tokens.cacheRead == nil)       // out of range
        precondition(history.tokens.cacheCreation == nil)   // fractional
        precondition(history.tokens.reasoning == nil)       // string
        precondition(history.tokens.total == 1400)
        precondition(history.models.map(\.displayName) == ["local-fixture.gguf", "claude-sonnet-4-5"])
        // A path-bearing label groups under an opaque digest key; a plain label is its own key.
        precondition(history.models[0].modelID.hasPrefix("sha256:") && history.models[0].modelID.count == 23)
        precondition(history.models[1].modelID == "claude-sonnet-4-5")
        precondition(history.models[0].priceKnown == false && history.models[0].totalTokens == 400)
        precondition(history.omittedModelCount == 2)
        precondition(codex.cost == nil)   // no amounts and no tokens: nothing invented
        precondition(PeelTokenCounts.adding(Int.max, 1) == nil)
        precondition(PeelTokenCounts.adding(nil, 1) == nil)
        precondition(peelSanitizedModelID("file:///tmp/m/b.gguf") == "b.gguf")
        precondition(peelSanitizedModelID("C:\\models\\x.bin") == "x.bin")
        precondition(peelSanitizedModelID("org/model") == "org/model")
        // Same digest derivation as CodexBar's dashboard `modelKey` (fixed expected values).
        precondition(peelModelKey("/Users/fixture/models/a/model.gguf") == "sha256:3eb447fba2156354")
        precondition(peelModelKey("fixture-model:7b") == "fixture-model:7b")
        // Omitted-model arithmetic saturates instead of trapping on malformed producer counts.
        let capped = try JSONDecoder().decode(PeelUsageTokenPeriodDetail.self, from: Data("""
        {"totalTokens": 3, "models": [], "omittedModelCount": 9223372036854775807}
        """.utf8))
        precondition(capped.omittedModelCount == PeelModelListBounds.maximumReportedOmittedModels)
        precondition(capped.omittedModelCountIsCapped)
        precondition(peelSafeProviderID("claude") == "claude" && peelSafeProviderID("../x") == nil)
    }

    private nonisolated static func provider(
        _ id: String,
        in snapshot: PeelUsageSnapshot) throws -> PeelUsageProvider
    {
        guard let provider = snapshot.providers.first(where: { $0.id == id }) else {
            throw PeelUsageSnapshotError.malformedPayload("Fixture provider \(id) was not decoded.")
        }
        return provider
    }

    private nonisolated static func expectError(
        _ operation: () throws -> Void) -> PeelUsageSnapshotError
    {
        do {
            try operation()
            preconditionFailure("Expected parser to throw.")
        } catch let error as PeelUsageSnapshotError {
            return error
        } catch {
            preconditionFailure("Expected PeelUsageSnapshotError, got \(error).")
        }
    }
}
