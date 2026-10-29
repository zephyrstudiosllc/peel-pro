import Foundation

/// Synthetic fixtures only: no helper, provider, network, credential, log or transcript access.
@main
enum PeelUsageLaneSmoke {
    static let t0 = Date(timeIntervalSince1970: 1_792_600_000)

    static func main() throws {
        try testBudgetOnlyClaudeStaysMeaningful()
        try testFullTokenDetailSurvives()
        try testUnknownPriceAndLocalModelKeepTokens()
        try testCostOutputFailuresAreDistinct()
        try testAccountSwitchNeverCarriesCost()
        try testRedactedStableAccountReuse()
        try testMetricAgesStaySeparate()
        try testLocalLogAttributionIsNotBilling()
        try testNoCostPollKeepsLocalTokens()
        testCommandFailureMapping()
        try testProviderStatesAreDistinct()
        try testCompactRankingMiniFixture()
        try testCompactRankingMacBookFixture()
        try testTokenAmountsAreSafe()
        testLanePolicy()
        try testNameOnlyModelsSurviveBesideBreakdowns()
        try testModelIdentityIsSeparateFromDisplay()
        testNonFiniteCostSumsAreUnknown()
        try testOmittedModelCountsNeverTrap()
        try testRecordedModelProviderIsNeverPriced()
        print("PeelUsageLaneSmoke: PASS")
    }

    // MARK: - Fixtures

    static func snapshot(_ providers: String, generatedAt: String = "2026-10-21T18:00:00Z") throws -> PeelUsageSnapshot {
        try PeelUsageSnapshotParser.parse("""
        {"schemaVersion": 1, "generatedAt": "\(generatedAt)", "staleAfterSeconds": 180, "providers": \(providers)}
        """)
    }

    static func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else { preconditionFailure("Bad fixture date \(value)") }
        return date
    }

    static var gmt: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    static func provider(_ id: String, in snapshot: PeelUsageSnapshot) -> PeelUsageProvider {
        guard let provider = snapshot.providers.first(where: { $0.id == id }) else {
            preconditionFailure("Fixture provider \(id) missing")
        }
        return provider
    }

    /// Cost CLI JSON as `cost --format json --json-only --provider claude --omit-projects` shapes it, plus a
    /// `projects` key an older producer could send. Paths there must never be decoded.
    static let fullCostJSON = """
    [{"provider": "claude", "source": "local", "updatedAt": "2026-10-21T17:58:00Z", "currencyCode": "USD",
      "sessionTokens": 1700, "sessionCostUSD": 1.25, "historyDays": 30, "historyCoverageIsEstablished": true,
      "last30DaysTokens": 5200, "last30DaysCostUSD": 3.5, "provenance": "listPriceEstimate",
      "coverage": {"priced": 12, "unpriced": 2, "unmetered": 0, "estimated": 0},
      "daily": [
        {"date": "2026-10-21", "inputTokens": 1000, "outputTokens": 200, "cacheReadTokens": 400,
         "cacheCreationTokens": 50, "reasoningTokens": 50, "totalTokens": 1700, "totalCost": 1.25,
         "modelsUsed": ["claude-sonnet-4-5", "/Users/fixture/models/local-fixture-8b.gguf"],
         "modelBreakdowns": [{"modelName": "claude-sonnet-4-5", "cost": 1.25, "totalTokens": 1200},
                             {"modelName": "/Users/fixture/models/local-fixture-8b.gguf", "totalTokens": 500}]},
        {"date": "2026-10-20", "inputTokens": 3000, "outputTokens": 500, "totalTokens": 3500, "totalCost": 2.25,
         "modelsUsed": ["claude-sonnet-4-5"],
         "modelBreakdowns": [{"modelName": "claude-sonnet-4-5", "cost": 2.25, "totalTokens": 3500}]}
      ],
      "projects": [{"name": "secret-client", "path": "/Users/fixture/secret-client", "daily": []}],
      "totals": {"inputTokens": 4000, "outputTokens": 700, "cacheReadTokens": 400, "cacheCreationTokens": 50,
                 "reasoningTokens": 50, "totalTokens": 5200, "totalCost": 3.5, "provenance": "listPriceEstimate",
                 "coverage": {"priced": 12, "unpriced": 2, "unmetered": 0, "estimated": 0}},
      "error": null}]
    """

    static func parsedFull() throws -> PeelObservedTokenUsage {
        switch PeelObservedTokenParser.parse(
            Data(fullCostJSON.utf8), providerID: "claude", receivedAt: date("2026-10-21T18:00:00Z"), calendar: gmt)
        {
        case let .success(usage): return usage
        case let .failure(failure): preconditionFailure("Full fixture failed: \(failure)")
        }
    }

    // MARK: - Tests

    static func testBudgetOnlyClaudeStaysMeaningful() throws {
        let snap = try snapshot("""
        [{"id": "claude", "name": "Claude", "enabled": true, "source": "oauth",
          "windows": [{"kind": "session", "label": "Session", "usedPercent": 41, "remainingPercent": 59},
                      {"kind": "weekly", "label": "Weekly", "usedPercent": 12, "remainingPercent": 88},
                      {"kind": "tertiary", "label": "Opus", "usedPercent": 3, "remainingPercent": 97}],
          "allowanceUpdatedAt": "2026-10-21T17:59:51Z", "cost": null, "error": null}]
        """)
        let claude = provider("claude", in: snap)
        precondition(PeelUsageProviderState.classify(claude, snapshot: snap, now: date("2026-10-21T18:00:00Z")) == .ok)
        precondition(claude.cost == nil)
        // A budget percentage is not a token count: nothing is recorded as observed tokens.
        var ledger = PeelObservedTokenLedger()
        precondition(ledger.applyDashboard(snap, receivedAt: t0).isEmpty)
        precondition(ledger["claude"] == nil)
    }

    static func testFullTokenDetailSurvives() throws {
        let usage = try parsedFull()
        precondition(usage.providerID == "claude")
        precondition(usage.scope == .thisMacLocalLogs)
        precondition(usage.metricClass == .observedLocalTokens)
        precondition(usage.sampledAt == date("2026-10-21T17:58:00Z"))
        precondition(usage.receivedAt == date("2026-10-21T18:00:00Z"))
        precondition(usage.historyDays == 30 && usage.historyCoverageIsEstablished == true)
        precondition(usage.provenance == .listPriceEstimate)
        precondition(usage.coverage == PeelCostCoverage(priced: 12, unpriced: 2))

        guard let today = usage.today, let history = usage.history else { preconditionFailure("Periods missing") }
        precondition(today.days == 1)
        precondition(today.tokens == PeelTokenCounts(
            input: 1000, output: 200, cacheRead: 400, cacheCreation: 50, reasoning: 50, total: 1700))
        precondition(today.estimatedCostUSD == 1.25)
        precondition(today.models.map(\.displayName) == ["claude-sonnet-4-5", "local-fixture-8b.gguf"])
        // The path-bearing label groups under an opaque key; the readable label keeps only the file name.
        precondition(today.models[1].modelID.hasPrefix("sha256:") && today.models[1].modelID.count == 23)

        precondition(history.days == 30)
        precondition(history.tokens == PeelTokenCounts(
            input: 4000, output: 700, cacheRead: 400, cacheCreation: 50, reasoning: 50, total: 5200))
        precondition(history.estimatedCostUSD == 3.5)
        precondition(history.models.first?.modelID == "claude-sonnet-4-5")
        precondition(history.models.first?.totalTokens == 4700)
        precondition(history.models.first?.estimatedCostUSD == 3.5)

        // Paths and project names from the response are never retained anywhere in the record.
        let encoded = String(decoding: try JSONEncoder().encode(usage), as: UTF8.self)
        precondition(!encoded.contains("secret-client"))
        precondition(!encoded.contains("/Users/"))
        precondition(!encoded.contains("\\/Users\\/"))

        // The same detail arriving through the enriched dashboard projects to the same record type.
        let snap = try snapshot("""
        [{"id": "claude", "name": "Claude", "enabled": true, "source": "oauth",
          "cost": {"todayUSD": 1.25, "last30DaysUSD": 3.5, "source": "local",
                   "updatedAt": "2026-10-21T17:58:00Z", "historyDays": 30, "historyCoverageIsEstablished": true,
                   "provenance": "listPriceEstimate", "coverage": {"priced": 12, "unpriced": 2},
                   "todayTokens": {"inputTokens": 1000, "totalTokens": 1700, "totalCost": 1.25,
                                   "models": [{"modelName": "claude-sonnet-4-5", "totalTokens": 1200, "cost": 1.25}],
                                   "omittedModelCount": 0},
                   "historyTokens": {"totalTokens": 5200, "totalCost": 3.5, "models": [], "omittedModelCount": 0}}}]
        """)
        let fromDashboard = PeelObservedTokenUsage(
            dashboardCost: try requireCost(provider("claude", in: snap)), providerID: "claude", receivedAt: t0)
        precondition(fromDashboard?.today?.tokens.total == 1700)
        precondition(fromDashboard?.history?.tokens.total == 5200)
        precondition(fromDashboard?.history?.estimatedCostUSD == 3.5)
        precondition(fromDashboard?.sampledAt == date("2026-10-21T17:58:00Z"))
    }

    static func requireCost(_ provider: PeelUsageProvider) throws -> PeelUsageCost {
        guard let cost = provider.cost else { preconditionFailure("Fixture cost missing for \(provider.id)") }
        return cost
    }

    static func testUnknownPriceAndLocalModelKeepTokens() throws {
        let usage = try parsedFull()
        guard let local = usage.today?.models.first(where: { $0.displayName == "local-fixture-8b.gguf" }) else {
            preconditionFailure("Local model row missing")
        }
        // The producer had no price for this (local-endpoint) model: tokens stay, spend stays unknown.
        precondition(local.totalTokens == 500)
        precondition(local.estimatedCostUSD == nil && !local.priceKnown)
        precondition(usage.unpricedModelIDs == [local.modelID])
        precondition(usage.today?.unpricedModelCount == 1)

        // Entirely unpriced history: counts survive, period spend is unknown rather than zero.
        let unpriced = """
        [{"provider": "codex", "source": "local", "updatedAt": "2026-10-21T17:00:00Z", "historyDays": 7,
          "historyCoverageIsEstablished": false, "last30DaysTokens": 900, "provenance": "unknown",
          "coverage": {"priced": 0, "unpriced": 3, "unmetered": 0, "estimated": 0},
          "daily": [{"date": "2026-10-19", "totalTokens": 900, "modelsUsed": ["fixture-local-coder"],
                     "modelBreakdowns": [{"modelName": "fixture-local-coder", "totalTokens": 900}]}],
          "totals": {"totalTokens": 900}}]
        """
        guard case let .success(codex) = PeelObservedTokenParser.parse(
            Data(unpriced.utf8), providerID: "codex", receivedAt: t0, calendar: gmt)
        else { preconditionFailure("Unpriced fixture failed") }
        precondition(codex.history?.tokens.total == 900)
        precondition(codex.history?.estimatedCostUSD == nil)
        precondition(codex.history?.days == 7)
        precondition(codex.today == nil)
        precondition(codex.historyCoverageIsEstablished == false)
        precondition(codex.recordsNoUsage == false)
        precondition(codex.provenance == .unknown)
        precondition(codex.history?.models.first?.priceKnown == false)

        // Model names without breakdowns prove a model ran, not its token count.
        let namesOnly = PeelObservedTokenParser.models(in: [
            PeelCostDailyRow(date: "2026-10-21", tokens: PeelTokenCounts(total: 10), modelsUsed: ["fixture-a"]),
        ])
        precondition(namesOnly.count == 1 && namesOnly[0].totalTokens == nil && namesOnly[0].estimatedCostUSD == nil)
    }

    static func testCostOutputFailuresAreDistinct() throws {
        func failure(_ json: String, provider: String = "claude") -> PeelObservedTokenFailure? {
            if case let .failure(failure) = PeelObservedTokenParser.parse(
                Data(json.utf8), providerID: provider, receivedAt: t0, calendar: gmt) { return failure }
            return nil
        }
        precondition(failure("{\"provider\": \"claude\"}") == .incompatibleOutput)
        precondition(failure("not json") == .incompatibleOutput)
        precondition(failure("[42, \"x\"]") == .incompatibleOutput)
        // An older helper rejects `--omit-projects`; Peel never retries without it.
        precondition(failure("""
        [{"provider": "cli", "source": "cli", "error": {"code": 1, "message": "Unknown option --omit-projects", "kind": "args"}}]
        """) == .helperRejectedArguments)
        precondition(PeelObservedTokenFailure.helperRejectedArguments.isRetryable == false)
        precondition(failure("[{\"provider\": \"codex\", \"source\": \"local\", \"daily\": []}]") == .providerMissing)
        precondition(failure("""
        [{"provider": "claude", "source": "local", "daily": [], "error": {"code": 4, "message": "Scan timed out", "kind": "provider"}}]
        """) == .providerError("Scan timed out"))

        // A row with no tokens but established coverage is a real "nothing recorded", not an error.
        guard case let .success(empty) = PeelObservedTokenParser.parse(
            Data("""
            [{"provider": "claude", "source": "local", "historyDays": 30, "historyCoverageIsEstablished": true,
              "daily": []}]
            """.utf8), providerID: "claude", receivedAt: t0, calendar: gmt)
        else { preconditionFailure("Empty coverage fixture failed") }
        precondition(empty.recordsNoUsage)
        precondition(empty.today == nil && empty.history == nil)
    }

    static func identityProvider(
        key: String?,
        email: String?,
        cost: String,
        credits: String = "null",
        source: String = "oauth",
        accounts: String = "null") -> String
    {
        let keyJSON = key.map { "\"\($0)\"" } ?? "null"
        let emailJSON = email.map { "\"\($0)\"" } ?? "null"
        return """
        {"id": "claude", "name": "Claude", "enabled": true, "source": "\(source)",
         "identity": {"accountEmail": \(emailJSON), "plan": "Max", "accountKey": \(keyJSON)},
         "windows": [{"kind": "session", "label": "Session", "usedPercent": 10, "remainingPercent": 90}],
         "credits": \(credits), "cost": \(cost), "accounts": \(accounts),
         "allowanceUpdatedAt": "2026-10-21T18:00:00Z"}
        """
    }

    static let costA = #"{"todayUSD": 9.5, "last30DaysUSD": 40}"#
    static let creditsA = #"{"remaining": 12, "unit": "credits"}"#
    static let costOne = #"{"todayUSD": 1}"#
    static let costTwo = #"{"todayUSD": 2}"#
    static let costFresh = #"{"todayUSD": 3, "updatedAt": "2026-10-21T17:30:00Z"}"#

    static func one(_ row: String, generatedAt: String = "2026-10-21T18:00:00Z") throws -> PeelUsageSnapshot {
        try snapshot("[" + row + "]", generatedAt: generatedAt)
    }

    static func merged(_ incoming: PeelUsageSnapshot, _ previous: PeelUsageSnapshot) -> PeelUsageProvider {
        provider("claude", in: PeelUsageSnapshotMerge.mergeAllowance(incoming: incoming, previous: previous))
    }

    static func testAccountSwitchNeverCarriesCost() throws {
        let previous = try one(
            identityProvider(key: "sha256:aaaa", email: "redacted@example.test", cost: costA, credits: creditsA, accounts: "[]"),
            generatedAt: "2026-10-21T17:00:00Z")
        let incoming = try one(identityProvider(key: "sha256:bbbb", email: "redacted@example.test", cost: "null"))
        let claude = merged(incoming, previous)
        precondition(claude.cost == nil)
        precondition(claude.credits == nil)
        precondition(claude.accounts == nil)
        precondition(claude.windows.count == 1)
        precondition(PeelUsageAccountOwnership.compare(claude.identity, provider("claude", in: previous).identity) == .different)

        // The same account through a different source never carries details either.
        let otherSource = try one(identityProvider(key: "sha256:aaaa", email: nil, cost: "null", source: "web"))
        precondition(merged(otherSource, previous).cost == nil)
    }

    static func testRedactedStableAccountReuse() throws {
        let previous = try one(
            identityProvider(key: "sha256:aaaa", email: "redacted@example.test", cost: costA, credits: creditsA, accounts: "[]"),
            generatedAt: "2026-10-21T17:00:00Z")
        let sameAccount = try one(identityProvider(key: "SHA256:AAAA ", email: "redacted@example.test", cost: "null"))
        let carried = merged(sameAccount, previous)
        precondition(carried.cost?.todayUSD == 9.5)
        precondition(carried.credits?.remaining == 12)
        precondition(carried.accounts == [])

        // A key on only one side is ambiguous ownership: nothing is carried.
        let noKey = try one(identityProvider(key: nil, email: "redacted@example.test", cost: "null"))
        precondition(merged(noKey, previous).cost == nil)

        // Neither side keyed: only equal non-redacted emails prove the same owner.
        let plainPrevious = try one(identityProvider(key: nil, email: "Owner@Example.test", cost: costOne))
        let plainIncoming = try one(identityProvider(key: nil, email: "owner@example.test", cost: "null"))
        precondition(merged(plainIncoming, plainPrevious).cost?.todayUSD == 1)
        let redactedPrevious = try one(identityProvider(key: nil, email: "redacted@example.test", cost: costOne))
        let redactedIncoming = try one(identityProvider(key: nil, email: "redacted@example.test", cost: "null"))
        precondition(merged(redactedIncoming, redactedPrevious).cost == nil)
        precondition(PeelUsageAccountOwnership.compare(nil, nil) == .unknown)
    }

    static func testMetricAgesStaySeparate() throws {
        let costAt = date("2026-10-21T17:00:00Z")
        let previous = try one(
            identityProvider(key: "sha256:aaaa", email: nil, cost: costTwo), generatedAt: "2026-10-21T17:00:00Z")
        let incoming = try one(identityProvider(key: "sha256:aaaa", email: nil, cost: "null"))
        let mergedSnapshot = PeelUsageSnapshotMerge.mergeAllowance(incoming: incoming, previous: previous)
        let dates = PeelUsageSnapshotMerge.costObservationDates(
            merged: mergedSnapshot, incoming: incoming, previous: ["claude": costAt])
        // A fresh quota poll does not make the carried cost look fresh.
        precondition(dates["claude"] == costAt)
        precondition(provider("claude", in: mergedSnapshot).cost?.todayUSD == 2)
        precondition(provider("claude", in: mergedSnapshot).allowanceUpdatedAt == date("2026-10-21T18:00:00Z"))

        // A freshly reported cost uses its own producer time when present.
        let fresh = try one(identityProvider(key: "sha256:aaaa", email: nil, cost: costFresh))
        let freshDates = PeelUsageSnapshotMerge.costObservationDates(
            merged: fresh, incoming: fresh, previous: ["claude": costAt])
        precondition(freshDates["claude"] == date("2026-10-21T17:30:00Z"))

        // An account switch drops the cost and its age together.
        let switched = try one(identityProvider(key: "sha256:bbbb", email: nil, cost: "null"))
        let switchedMerged = PeelUsageSnapshotMerge.mergeAllowance(incoming: switched, previous: previous)
        precondition(PeelUsageSnapshotMerge.costObservationDates(
            merged: switchedMerged, incoming: switched, previous: ["claude": costAt]).isEmpty)

        // Observed tokens carry their own producer time, distinct from quota and cost.
        let usage = try parsedFull()
        precondition(usage.age(at: date("2026-10-21T18:00:00Z")) == 120)
    }

    static func testLocalLogAttributionIsNotBilling() throws {
        let usage = try parsedFull()
        precondition(usage.scope == .thisMacLocalLogs && usage.metricClass == .observedLocalTokens)

        // Provider-dashboard (web) cost stays on the account-bound provider row; it is not local tokens.
        let web = PeelUsageCost(
            todayUSD: 4, source: "web", provenance: .vendorMetered,
            historyTokens: PeelUsageTokenPeriodDetail(tokens: PeelTokenCounts(total: 100)))
        precondition(PeelObservedTokenUsage(dashboardCost: web, providerID: "cursor", receivedAt: t0) == nil)
        let metered = PeelObservedTokenUsage(
            providerID: "cursor", scope: .providerAccount, sampledAt: t0, receivedAt: t0,
            history: PeelObservedTokenPeriod(days: 30, tokens: PeelTokenCounts(total: 100), estimatedCostUSD: 4),
            provenance: .vendorMetered)
        precondition(metered.metricClass == .vendorBilling)
        let estimate = PeelObservedTokenUsage(
            providerID: "codex", scope: .thisMacLocalLogs, sampledAt: t0, receivedAt: t0,
            history: PeelObservedTokenPeriod(days: 30, tokens: PeelTokenCounts(total: 100), estimatedCostUSD: 4),
            provenance: .listPriceEstimate)
        precondition(estimate.metricClass == .observedLocalTokens)

        // Dashboard rows for providers outside the local-log lane are never recorded as local tokens.
        let snap = try snapshot("""
        [{"id": "antigravity", "name": "Antigravity", "enabled": true,
          "cost": {"todayUSD": null, "last30DaysUSD": null, "source": "local",
                   "historyTokens": {"totalTokens": 10, "models": []}}}]
        """)
        var ledger = PeelObservedTokenLedger()
        precondition(ledger.applyDashboard(snap, receivedAt: t0).isEmpty)
    }

    static func testNoCostPollKeepsLocalTokens() throws {
        var ledger = PeelObservedTokenLedger()
        let usage = try parsedFull()
        precondition(ledger.apply(.success(usage), providerID: "claude", at: t0) == false)

        let poll = try one(identityProvider(key: "sha256:aaaa", email: nil, cost: "null"))
        precondition(ledger.applyDashboard(poll, receivedAt: t0.addingTimeInterval(60)).isEmpty)
        precondition(ledger["claude"]?.usage == usage)

        // A failed refresh keeps the previous reading and says so.
        precondition(ledger.apply(.failure(.timedOut), providerID: "claude", at: t0.addingTimeInterval(120)))
        precondition(ledger["claude"]?.usage == usage)
        precondition(ledger["claude"]?.failure == .timedOut)
        precondition(ledger["claude"]?.isShowingRetainedReading == true)

        // Cancellation is not a failure and changes nothing.
        let before = ledger
        precondition(ledger.apply(.failure(.cancelled), providerID: "claude", at: t0.addingTimeInterval(180)) == false)
        precondition(ledger == before)

        // Success clears the failure; pruning removes providers no longer eligible.
        _ = ledger.apply(.success(usage), providerID: "claude", at: t0.addingTimeInterval(240))
        precondition(ledger["claude"]?.failure == nil)
        _ = ledger.apply(.failure(.outputTooLarge), providerID: "codex", at: t0)
        ledger.prune(keeping: ["claude"])
        precondition(ledger["codex"] == nil && ledger["claude"] != nil)
        ledger.markHelperUnsupported(["claude"], at: t0)
        precondition(ledger["claude"]?.failure == .helperRejectedArguments && ledger["claude"]?.usage == usage)
    }

    static func testCommandFailureMapping() {
        precondition(PeelObservedTokenFailure(commandError: PeelUsageCommandError.outputTooLarge) == .outputTooLarge)
        precondition(PeelObservedTokenFailure(commandError: PeelUsageCommandError.timedOut) == .timedOut)
        precondition(PeelObservedTokenFailure(commandError: PeelUsageCommandError.cancelled) == .cancelled)
        precondition(PeelObservedTokenFailure(commandError: PeelUsageCommandError.missingHelper) == .helperMissing)
        precondition(PeelObservedTokenFailure(commandError: PeelUsageCommandError.failed(3)) == .helperFailed(3))
        precondition(PeelObservedTokenFailure(commandError: CocoaError(.fileReadUnknown)) == .incompatibleOutput)
    }

    static func testProviderStatesAreDistinct() throws {
        let now = date("2026-10-21T18:00:00Z")
        let snap = try snapshot("""
        [{"id": "ok", "name": "Ok", "enabled": true, "allowanceUpdatedAt": "2026-10-21T17:59:00Z",
          "windows": [{"kind": "session", "label": "Session", "usedPercent": 10, "remainingPercent": 90}]},
         {"id": "old", "name": "Old", "enabled": true, "allowanceUpdatedAt": "2026-10-21T17:00:00Z",
          "windows": [{"kind": "session", "label": "Session", "usedPercent": 10, "remainingPercent": 90}]},
         {"id": "off", "name": "Off", "enabled": false},
         {"id": "auth", "name": "Auth", "enabled": true,
          "error": {"code": 3, "message": "Claude OAuth authentication failed. Run claude to sign in again.", "kind": "provider"}},
         {"id": "silent", "name": "Silent", "enabled": true,
          "error": {"code": 1, "message": "Keychain access requires a prompt, which background refresh does not show.", "kind": "provider"}},
         {"id": "slow", "name": "Slow", "enabled": true, "error": {"code": 4, "message": "Request failed", "kind": "provider"}},
         {"id": "missing", "name": "Missing", "enabled": true, "error": {"code": 2, "message": "CLI not installed", "kind": "provider"}},
         {"id": "limited", "name": "Limited", "enabled": true, "error": {"code": 1, "message": "429 Too Many Requests"}},
         {"id": "norates", "name": "NoRates", "enabled": true, "error": {"code": 3, "message": "No rate limits found"}},
         {"id": "empty", "name": "Empty", "enabled": true},
         {"id": "credits", "name": "Credits", "enabled": true, "credits": {"remaining": 4, "unit": "credits"}}]
        """)
        func state(_ id: String) -> PeelUsageProviderState {
            PeelUsageProviderState.classify(provider(id, in: snap), snapshot: snap, now: now)
        }
        precondition(state("ok") == .ok)
        precondition(state("old") == .stale(age: 3600))
        precondition(state("off") == .disabled)
        precondition(state("auth") == .authNeeded(silentBlocked: false))
        precondition(state("silent") == .authNeeded(silentBlocked: true))
        precondition(state("slow") == .error(.timedOut))
        precondition(state("missing") == .unsupported)
        precondition(state("limited") == .error(.rateLimited))
        precondition(state("norates") == .error(.provider))
        precondition(state("empty") == .notCollected)
        precondition(state("credits") == .ok)
        // A whole stale snapshot (previous readings kept after failures) is stale, never fresh.
        precondition(PeelUsageProviderState.classify(
            provider("ok", in: snap), snapshot: snap, now: now.addingTimeInterval(600)).hasUsableReading)
        if case .stale = PeelUsageProviderState.classify(
            provider("ok", in: snap), snapshot: snap, now: now.addingTimeInterval(600)) {} else {
            preconditionFailure("Expected stale after the producer deadline")
        }
    }

    /// The 69 provider IDs in the order both installed build-228 helpers returned them.
    static let installedOrder = [
        "codex", "openai", "azureopenai", "claude", "cursor", "opencode", "opencodego", "alibaba",
        "alibabatokenplan", "factory", "gemini", "antigravity", "copilot", "devin", "zai", "minimax", "manus",
        "kimi", "kilo", "kiro", "vertexai", "augment", "jetbrains", "moonshot", "amp", "t3chat", "ollama",
        "synthetic", "warp", "openrouter", "elevenlabs", "windsurf", "zed", "perplexity", "mimo", "doubao",
        "sakana", "abacus", "mistral", "deepseek", "codebuff", "crof", "venice", "commandcode", "qoder",
        "stepfun", "bedrock", "grok", "groq", "llmproxy", "litellm", "deepgram", "poe", "chutes", "clawrouter",
        "wayfinder", "clinepass", "qwencloud", "fireworks", "deepinfra", "neuralwatt", "longcat", "sub2api",
        "zenmux", "aiand", "zoommate", "xai", "notion", "ibmbob",
    ]
    static let authNeededIDs: Set<String> = [
        "cursor", "alibabatokenplan", "factory", "gemini", "devin", "kilo", "kiro", "augment", "amp", "t3chat",
        "ollama", "zed", "mimo", "doubao", "abacus", "codebuff", "commandcode", "qoder", "qwencloud", "zoommate",
        "notion",
    ]

    static func installedFixture(claudeHealthy: Bool) throws -> PeelUsageSnapshot {
        let rows = installedOrder.map { id -> String in
            switch id {
            case "codex":
                return """
                {"id": "codex", "name": "Codex", "enabled": true, "source": "oauth",
                 "allowanceUpdatedAt": "2026-10-21T17:59:51Z",
                 "windows": [{"kind": "session", "label": "Session", "usedPercent": 20, "remainingPercent": 80}]}
                """
            case "claude" where claudeHealthy:
                return """
                {"id": "claude", "name": "Claude", "enabled": true, "source": "oauth",
                 "allowanceUpdatedAt": "2026-10-21T17:59:51Z",
                 "windows": [{"kind": "session", "label": "Session", "usedPercent": 41, "remainingPercent": 59},
                             {"kind": "weekly", "label": "Weekly", "usedPercent": 12, "remainingPercent": 88},
                             {"kind": "tertiary", "label": "Opus", "usedPercent": 3, "remainingPercent": 97}]}
                """
            case "claude":
                return """
                {"id": "claude", "name": "Claude", "enabled": true, "source": "oauth", "windows": [],
                 "error": {"code": 3, "message": "Claude OAuth authentication failed. Sign in to Claude again.", "kind": "provider"}}
                """
            case _ where authNeededIDs.contains(id):
                return """
                {"id": "\(id)", "name": "\(id)", "enabled": true, "source": "auto",
                 "error": {"code": 1, "message": "Not signed in.", "kind": "provider"}}
                """
            default:
                return """
                {"id": "\(id)", "name": "\(id)", "enabled": true, "source": "auto",
                 "error": {"code": 1, "message": "Provider request failed.", "kind": "provider"}}
                """
            }
        }
        let snap = try snapshot("[" + rows.joined(separator: ",") + "]")
        precondition(snap.providers.count == 69 && snap.decodeHealth == .complete)
        return snap
    }

    static func testCompactRankingMiniFixture() throws {
        let snap = try installedFixture(claudeHealthy: true)
        let now = date("2026-10-21T18:00:00Z")
        // The previous compact surface took the first three rows and hid Claude.
        precondition(snap.providers.prefix(3).map(\.id) == ["codex", "openai", "azureopenai"])

        let summary = PeelUsageCompactRanking.rank(
            providers: snap.providers, snapshot: snap, selectedProviderID: nil, now: now)
        precondition(summary.rows.map(\.providerID) == ["claude", "codex"])
        precondition(summary.rows.allSatisfy { $0.reason == .activeAgent && $0.state == .ok })
        precondition(summary.rows[0].window?.kind == "session")
        precondition(summary.rows[0].quotaAge == 9)
        precondition(summary.enabledCount == 69)
        precondition(summary.hiddenUsableCount == 0)
        precondition(summary.authNeededCount == 21)
        precondition(summary.unavailableCount == 46)
        precondition(summary.hiddenSummaryText == "21 need sign-in · 46 unavailable")

        // A pinned provider comes first in whatever state it is; quotas are never summed.
        let pinned = PeelUsageCompactRanking.rank(
            providers: snap.providers, snapshot: snap, selectedProviderID: "cursor", now: now)
        precondition(pinned.rows.map(\.providerID) == ["cursor", "claude", "codex"])
        precondition(pinned.rows[0].reason == .selected && pinned.rows[0].state == .authNeeded(silentBlocked: false))
        precondition(pinned.rows[0].window == nil)
        precondition(pinned.authNeededCount == 20)
    }

    static func testCompactRankingMacBookFixture() throws {
        let snap = try installedFixture(claudeHealthy: false)
        let now = date("2026-10-21T18:00:00Z")
        let summary = PeelUsageCompactRanking.rank(
            providers: snap.providers, snapshot: snap, selectedProviderID: "", now: now)
        // Codex keeps its usable reading; Claude is shown with its truthful state, not hidden or zeroed.
        precondition(summary.rows.map(\.providerID) == ["codex", "claude"])
        precondition(summary.rows[0].reason == .activeAgent)
        precondition(summary.rows[1].reason == .activeAgentUnavailable)
        precondition(summary.rows[1].state == .authNeeded(silentBlocked: false))
        precondition(summary.rows[1].state.shortLabel == "Sign-in needed")
        precondition(summary.rows[1].window == nil && summary.rows[1].quotaAge == nil)
        precondition(summary.authNeededCount == 21)
        precondition(summary.unavailableCount == 46)

        // Peer worker may pass the providers of visible agent sessions instead.
        let codexOnly = PeelUsageCompactRanking.rank(
            providers: snap.providers, snapshot: snap, selectedProviderID: nil,
            activeAgentProviderIDs: ["codex"], maxRows: 1, now: now)
        precondition(codexOnly.rows.map(\.providerID) == ["codex"])
        precondition(codexOnly.authNeededCount == 22)
    }

    static func testTokenAmountsAreSafe() throws {
        let json = """
        {"inputTokens": -1, "outputTokens": 1e30, "cacheReadTokens": 1.5, "cacheCreationTokens": "4",
         "reasoningTokens": null, "totalTokens": 9223372036854775807}
        """
        let counts = try JSONDecoder().decode(PeelTokenCounts.self, from: Data(json.utf8))
        precondition(counts == PeelTokenCounts(total: Int.max))
        precondition(PeelTokenCounts(input: -5).input == nil)

        // Per-model sums overflow to unknown rather than wrapping or clamping.
        let a = PeelObservedModelUsage(modelID: "fixture-model", totalTokens: Int.max, estimatedCostUSD: 1)
        let b = PeelObservedModelUsage(modelID: "fixture-model", totalTokens: 1, estimatedCostUSD: .infinity)
        let rows = [
            PeelCostDailyRow(date: "2026-10-20", tokens: PeelTokenCounts(), modelBreakdowns: [a].compactMap { $0 }),
            PeelCostDailyRow(date: "2026-10-21", tokens: PeelTokenCounts(), modelBreakdowns: [b].compactMap { $0 }),
        ]
        let models = PeelObservedTokenParser.models(in: rows)
        precondition(models.count == 1 && models[0].totalTokens == nil)
        // A non-finite price is dropped at the row, so the summed price is unknown.
        precondition(models[0].estimatedCostUSD == nil)

        // Periods bound model lists and count the remainder.
        // The closure is typed explicitly: an inferred `Int?` parameter once produced "fixture-Optional(11)".
        let many = (0..<12).compactMap { (index: Int) -> PeelObservedModelUsage? in
            PeelObservedModelUsage(modelID: "fixture-" + String(index), totalTokens: index, estimatedCostUSD: nil)
        }
        precondition(many.count == 12 && many[11].modelID == "fixture-11")
        let period = PeelObservedTokenPeriod(days: 30, tokens: PeelTokenCounts(total: 66), models: many)
        precondition(period.models.count == PeelObservedTokenPeriod.maximumModels)
        precondition(period.models.first?.modelID == "fixture-11")
        precondition(period.omittedModelCount == 4)
        precondition(PeelObservedTokenPeriod(days: 1, tokens: PeelTokenCounts(), estimatedCostUSD: -2).estimatedCostUSD == nil)
        precondition(PeelUsageFormatting.tokens(nil) == "—")
        precondition(PeelUsageFormatting.tokens(950) == "950")
        precondition(PeelUsageFormatting.tokens(12_400) == "12.4K")
    }

    static func testLanePolicy() {
        precondition(PeelLocalTokenLanePolicy.eligibleProviders(
            enabledProviderIDs: ["cursor", "codex", "openai", "claude", "litellm"]) == [.claude, .codex])
        precondition(PeelLocalTokenLanePolicy.eligibleProviders(enabledProviderIDs: ["cursor"]).isEmpty)
        precondition(PeelLocalTokenLanePolicy.nextAttempt(after: t0, consecutiveFailures: 0, lowPower: false)
            == t0.addingTimeInterval(600))
        precondition(PeelLocalTokenLanePolicy.nextAttempt(after: t0, consecutiveFailures: 9, lowPower: false)
            == t0.addingTimeInterval(4_800))
        precondition(PeelLocalTokenLanePolicy.nextAttempt(after: t0, consecutiveFailures: 0, lowPower: true)
            == t0.addingTimeInterval(1_800))
        precondition(PeelLocalTokenLanePolicy.helperSupportsCompactCost(
            helpOutput: Data("[--group-by project|session] [--omit-projects]".utf8)))
        precondition(!PeelLocalTokenLanePolicy.helperSupportsCompactCost(
            helpOutput: Data("[--group-by project|session]".utf8)))
    }

    // MARK: - Review findings UD1–UD4 and recorded model providers

    static func costJSON(daily: String, extra: String = "") -> Data {
        Data("""
        [{"provider": "codex", "source": "local", "updatedAt": "2026-10-21T17:00:00Z", "historyDays": 30,
          "historyCoverageIsEstablished": true, \(extra) "daily": \(daily)}]
        """.utf8)
    }

    static func parsedCodex(_ data: Data) -> PeelObservedTokenUsage {
        switch PeelObservedTokenParser.parse(data, providerID: "codex", receivedAt: t0, calendar: gmt) {
        case let .success(usage): return usage
        case let .failure(failure): preconditionFailure("Codex fixture failed: \(failure)")
        }
    }

    /// UD1: a priced breakdown and an extra name-only (local/unpriced) model in the same entry both survive.
    static func testNameOnlyModelsSurviveBesideBreakdowns() throws {
        let usage = parsedCodex(costJSON(daily: """
        [{"date": "2026-10-20", "totalTokens": 100, "totalCost": 0.5,
          "modelsUsed": ["gpt-5.4", "fixture-local-coder:7b"],
          "modelBreakdowns": [{"modelName": "gpt-5.4", "cost": 0.5, "totalTokens": 100}]}]
        """))
        guard let models = usage.history?.models else { preconditionFailure("History missing") }
        precondition(models.count == 2)
        precondition(models[0].modelID == "gpt-5.4" && models[0].totalTokens == 100 && models[0].estimatedCostUSD == 0.5)
        precondition(models[1].modelID == "fixture-local-coder:7b")
        precondition(models[1].totalTokens == nil && models[1].estimatedCostUSD == nil)
        // A name listed again with its own breakdown is not double counted.
        let direct = PeelObservedTokenParser.models(in: [
            PeelCostDailyRow(
                date: "2026-10-21",
                tokens: PeelTokenCounts(total: 7),
                modelsUsed: ["gpt-5.4"],
                modelBreakdowns: [PeelObservedModelUsage(modelID: "gpt-5.4", totalTokens: 7, estimatedCostUSD: 0.1)]
                    .compactMap { $0 }),
        ])
        precondition(direct.count == 1 && direct[0].totalTokens == 7)
    }

    /// UD2: grouping uses a stable identity; shortened display labels never merge distinct models.
    static func testModelIdentityIsSeparateFromDisplay() throws {
        let longA = "fixture-provider-org/" + String(repeating: "x", count: 60) + "-alpha"
        let longB = "fixture-provider-org/" + String(repeating: "x", count: 60) + "-beta"
        let usage = parsedCodex(costJSON(daily: """
        [{"date": "2026-10-20", "totalTokens": 66,
          "modelBreakdowns": [
            {"modelName": "/Users/fixture/models/a/model.gguf", "totalTokens": 10},
            {"modelName": "/Users/fixture/models/b/model.gguf", "totalTokens": 20},
            {"modelName": "\(longA)", "totalTokens": 11},
            {"modelName": "\(longB)", "totalTokens": 12},
            {"modelName": "meta-fixture/Fixture-Model-8B-Instruct", "totalTokens": 7, "cost": 0.01},
            {"modelName": "fixture-model:7b-q4", "totalTokens": 6}]}]
        """))
        guard let models = usage.history?.models else { preconditionFailure("History missing") }
        precondition(models.count == 6 && usage.history?.omittedModelCount == 0)
        func model(_ key: String) -> PeelObservedModelUsage {
            guard let found = models.first(where: { $0.modelID == key }) else { preconditionFailure("Missing \(key)") }
            return found
        }
        // Same file name in different directories: two keys, two token totals, no path anywhere.
        let a = model("sha256:3eb447fba2156354")
        let b = model("sha256:db228ca76f41da41")
        precondition(a.totalTokens == 10 && b.totalTokens == 20)
        precondition(a.displayName.hasPrefix("model.gguf · ") && b.displayName.hasPrefix("model.gguf · "))
        precondition(a.displayName != b.displayName)
        // IDs sharing their first 64 characters stay distinct.
        let alpha = model("sha256:6b9a39e7710a85a5")
        let beta = model("sha256:27d000462d29ff52")
        precondition(alpha.totalTokens == 11 && beta.totalTokens == 12 && alpha.displayName != beta.displayName)
        // Legitimate org/model and model:tag identities are kept verbatim.
        precondition(model("meta-fixture/Fixture-Model-8B-Instruct").estimatedCostUSD == 0.01)
        precondition(model("fixture-model:7b-q4").displayName == "fixture-model:7b-q4")
        let encoded = String(decoding: try JSONEncoder().encode(models), as: UTF8.self)
        precondition(!encoded.contains("Users") && !encoded.contains("fixture/models"))

        // A dashboard row's key is honored; its label is display text only.
        let row = try JSONDecoder().decode(PeelObservedModelUsage.self, from: Data("""
        {"modelName": "model.gguf · 1a2b3c", "modelKey": "sha256:3eb447fba2156354", "totalTokens": 10}
        """.utf8))
        precondition(row.modelID == "sha256:3eb447fba2156354" && row.displayName == "model.gguf · 1a2b3c")
        let unsafeKey = try JSONDecoder().decode(PeelObservedModelUsage.self, from: Data("""
        {"modelName": "/Users/fixture/models/a/model.gguf", "modelKey": "/Users/fixture/models/a/model.gguf"}
        """.utf8))
        precondition(unsafeKey.modelID == "sha256:3eb447fba2156354" && unsafeKey.displayName == "model.gguf")
    }

    /// UD3: finite costs whose sum overflows become unknown; tokens stay usable.
    static func testNonFiniteCostSumsAreUnknown() {
        let big = Double.greatestFiniteMagnitude
        let rows = [
            PeelCostDailyRow(
                date: "2026-10-20",
                tokens: PeelTokenCounts(total: 5),
                modelBreakdowns: [PeelObservedModelUsage(modelID: "gpt-5.4", totalTokens: 5, estimatedCostUSD: big)]
                    .compactMap { $0 }),
            PeelCostDailyRow(
                date: "2026-10-21",
                tokens: PeelTokenCounts(total: 6),
                modelBreakdowns: [PeelObservedModelUsage(modelID: "gpt-5.4", totalTokens: 6, estimatedCostUSD: big)]
                    .compactMap { $0 }),
        ]
        let models = PeelObservedTokenParser.models(in: rows)
        precondition(models.count == 1 && models[0].totalTokens == 11)
        precondition(models[0].estimatedCostUSD == nil)
        precondition((try? JSONEncoder().encode(models)) != nil)
    }

    /// UD4: a malformed huge omitted count never traps; it is capped and flagged as a lower bound.
    static func testOmittedModelCountsNeverTrap() throws {
        let rows = (0..<33).map { (index: Int) -> String in
            "{\"modelName\": \"fixture-" + String(index) + "\", \"totalTokens\": " + String(index) + "}"
        }
        let json = "{\"totalTokens\": 1, \"models\": [" + rows.joined(separator: ",")
            + "], \"omittedModelCount\": 9223372036854775807}"
        let detail = try JSONDecoder().decode(PeelUsageTokenPeriodDetail.self, from: Data(json.utf8))
        precondition(detail.models.count == PeelUsageTokenPeriodDetail.maximumModels)
        precondition(detail.omittedModelCount == PeelModelListBounds.maximumReportedOmittedModels)
        precondition(detail.omittedModelCountIsCapped)

        let many = (0..<12).compactMap { (index: Int) -> PeelObservedModelUsage? in
            PeelObservedModelUsage(modelID: "fixture-" + String(index), totalTokens: index)
        }
        let period = PeelObservedTokenPeriod(days: 30, tokens: PeelTokenCounts(total: 1), models: many, omittedModelCount: Int.max)
        precondition(period.models.count == PeelObservedTokenPeriod.maximumModels)
        precondition(period.omittedModelCount == PeelModelListBounds.maximumReportedOmittedModels)
        precondition(period.omittedModelCountIsCapped)
        let negative = PeelObservedTokenPeriod(days: 30, tokens: PeelTokenCounts(total: 1), omittedModelCount: Int.min)
        precondition(negative.omittedModelCount == 0 && !negative.omittedModelCountIsCapped)
        let bounded = peelBoundedOmittedCount(declared: 3, truncated: 4)
        precondition(bounded.count == 7 && !bounded.isCapped)
    }

    /// Recorded `model_provider` provenance: local and custom providers keep tokens and never carry a price,
    /// even when the label matches a cloud catalog model or the producer sent a cost.
    static func testRecordedModelProviderIsNeverPriced() throws {
        let usage = parsedCodex(costJSON(daily: """
        [{"date": "2026-10-20", "totalTokens": 900, "totalCost": 0.2,
          "modelsUsed": ["gpt-5.4", "model-provider:ollama/gpt-oss:20b", "model-provider:custom/gpt-5.4"],
          "modelBreakdowns": [
            {"modelName": "gpt-5.4", "cost": 0.2, "totalTokens": 100},
            {"modelName": "model-provider:ollama/gpt-oss:20b", "totalTokens": 500, "cost": 9.99,
             "endpoint": "local", "localProvider": "ollama", "baseModel": "gpt-oss:20b"},
            {"modelName": "model-provider:custom/gpt-5.4", "totalTokens": 300,
             "endpoint": "custom", "localProvider": "my-private-proxy", "baseModel": "gpt-5.4"}]}]
        """))
        guard let models = usage.history?.models else { preconditionFailure("History missing") }
        precondition(models.count == 3)
        let local = models[0]
        precondition(local.modelID == "model-provider:ollama/gpt-oss:20b" && local.displayName == "gpt-oss:20b")
        precondition(local.endpoint == .local && local.localProviderID == "ollama")
        precondition(local.totalTokens == 500 && local.estimatedCostUSD == nil)
        let custom = models[1]
        precondition(custom.endpoint == .custom && custom.localProviderID == nil)
        // Custom and OpenAI rows share the base label, so both labels carry their own key-digest suffix:
        // distinct, deterministic, and derived from separate stable IDs.
        precondition(custom.modelID == "model-provider:custom/gpt-5.4")
        precondition(custom.displayName == "gpt-5.4 · fab585")
        precondition(custom.totalTokens == 300 && custom.estimatedCostUSD == nil)
        let vendor = models[2]
        precondition(vendor.modelID == "gpt-5.4" && vendor.endpoint == .unspecified && vendor.estimatedCostUSD == 0.2)
        precondition(vendor.displayName == "gpt-5.4 · 6b7dcc" && vendor.displayName != custom.displayName)
        // The same cloud label from OpenAI and from a custom provider never merge.
        precondition(custom.modelID != vendor.modelID)
        precondition(Set(usage.unpricedModelIDs) == [local.modelID, custom.modelID])
        // Name-only qualified labels classify the same way without a breakdown.
        let nameOnly = PeelObservedModelUsage(rawModelName: "model-provider:lmstudio/fixture-model")
        precondition(nameOnly?.endpoint == .local && nameOnly?.localProviderID == "lmstudio")
        precondition(PeelObservedModelUsage(rawModelName: "model-provider:ollama//Users/fixture/m.gguf")?.modelID
            == "sha256:384cb955801a828a")
        // An unqualified label stays unspecified: no local or cloud claim is inferred from the name.
        precondition(PeelObservedModelUsage(rawModelName: "llama3.1:8b")?.endpoint == .unspecified)
    }
}
