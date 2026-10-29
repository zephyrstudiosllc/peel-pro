import Foundation

/// The kinds of usage Peel shows. Values of different classes are never summed or substituted for
/// one another: a quota percentage is not a token count, and a local-log estimate is not a bill.
nonisolated public enum PeelUsageMetricClass: String, Codable, Equatable, Sendable, CaseIterable {
    /// Account plan limits and resets from the provider (`dashboard --no-cost`).
    case planQuota
    /// Tokens and models recorded by harness logs on this Mac, across every account used here.
    case observedLocalTokens
    /// Spend reported by the provider's own metering for one account.
    case vendorBilling
    /// Requests served by a local model server outside harness logs. Peel has no counter for these.
    case localInference
}

/// Where an observed-token reading came from. Local-log readings belong to this Mac, not to an
/// account: they are never attached to an account identity and never merged across Macs.
nonisolated public enum PeelObservedTokenScope: String, Codable, Equatable, Sendable {
    case thisMacLocalLogs
    case providerAccount
    case unknown

    public nonisolated init(costSource: String?) {
        switch costSource?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "local": self = .thisMacLocalLogs
        case "web": self = .providerAccount
        default: self = .unknown
        }
    }
}

/// Observed tokens for one period (today, or the producer's history window).
nonisolated public struct PeelObservedTokenPeriod: Codable, Equatable, Sendable {
    public static let maximumModels = 8

    /// 1 for today; otherwise the producer's history window in days.
    public let days: Int
    public let tokens: PeelTokenCounts
    /// API-price estimate (or vendor-metered amount, per `PeelObservedTokenUsage.provenance`).
    /// `nil` means no price was established; it is never zero by default.
    public let estimatedCostUSD: Double?
    /// Largest models first, at most `maximumModels`. Unpriced models keep their tokens.
    public let models: [PeelObservedModelUsage]
    /// Distinct models not listed; their tokens are still part of `tokens`. A lower bound when
    /// `omittedModelCountIsCapped` (a malformed or huge producer count never traps Peel).
    public let omittedModelCount: Int
    public let omittedModelCountIsCapped: Bool

    public nonisolated init(
        days: Int,
        tokens: PeelTokenCounts,
        estimatedCostUSD: Double? = nil,
        models: [PeelObservedModelUsage] = [],
        omittedModelCount: Int = 0)
    {
        self.days = max(1, days)
        self.tokens = tokens
        self.estimatedCostUSD = estimatedCostUSD.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let sorted = PeelObservedTokenPeriod.ordered(models)
        self.models = PeelObservedTokenPeriod.disambiguated(Array(sorted.prefix(Self.maximumModels)))
        let omitted = peelBoundedOmittedCount(declared: omittedModelCount, truncated: sorted.count - Self.maximumModels)
        self.omittedModelCount = omitted.count
        self.omittedModelCountIsCapped = omitted.isCapped
    }

    public nonisolated var hasTokenData: Bool { tokens.hasAnyValue || !models.isEmpty }

    /// Listed models with measured tokens but no known price (for example local-endpoint models).
    public nonisolated var unpricedModelCount: Int { models.filter { !$0.priceKnown }.count }

    nonisolated static func ordered(_ models: [PeelObservedModelUsage]) -> [PeelObservedModelUsage] {
        models.sorted { lhs, rhs in
            switch (lhs.totalTokens, rhs.totalTokens) {
            case let (left?, right?) where left != right: left > right
            case (.some, nil): true
            case (nil, .some): false
            default: lhs.modelID < rhs.modelID
            }
        }
    }

    /// Display labels are bounded and may collide (same local file name, long shared prefix); colliding
    /// labels get a short suffix derived from the stable key so rows stay distinguishable.
    nonisolated static func disambiguated(_ models: [PeelObservedModelUsage]) -> [PeelObservedModelUsage] {
        var counts: [String: Int] = [:]
        for model in models {
            counts[model.displayName, default: 0] += 1
        }
        return models.map { model in
            guard counts[model.displayName, default: 0] > 1 else { return model }
            return model.renamed(model.displayName + " · " + String(peelModelDigestHex(model.modelID).prefix(6)))
        }
    }
}

/// One provider's observed token/model reading with its own producer sample time and coverage.
/// Stable API: the peer/notch/Hub layers consume this type; it never carries paths, projects,
/// sessions, prompts or account identity.
nonisolated public struct PeelObservedTokenUsage: Codable, Equatable, Sendable {
    public let providerID: String
    public let scope: PeelObservedTokenScope
    /// Time the producer observed these logs. `nil` when the producer did not say.
    public let sampledAt: Date?
    /// Time this Mac received the reading.
    public let receivedAt: Date
    public let currencyCode: String?
    public let historyDays: Int?
    /// `true` only when the producer says its local history covers the requested window.
    public let historyCoverageIsEstablished: Bool?
    public let today: PeelObservedTokenPeriod?
    public let history: PeelObservedTokenPeriod?
    public let provenance: PeelCostProvenance
    public let coverage: PeelCostCoverage?
    /// Vendor-metered amount over the history window, only when the producer reports one.
    public let meteredCostUSD: Double?

    public nonisolated init(
        providerID: String,
        scope: PeelObservedTokenScope,
        sampledAt: Date?,
        receivedAt: Date,
        currencyCode: String? = "USD",
        historyDays: Int? = nil,
        historyCoverageIsEstablished: Bool? = nil,
        today: PeelObservedTokenPeriod? = nil,
        history: PeelObservedTokenPeriod? = nil,
        provenance: PeelCostProvenance = .unknown,
        coverage: PeelCostCoverage? = nil,
        meteredCostUSD: Double? = nil)
    {
        self.providerID = providerID
        self.scope = scope
        self.sampledAt = sampledAt
        self.receivedAt = receivedAt
        self.currencyCode = currencyCode
        self.historyDays = historyDays
        self.historyCoverageIsEstablished = historyCoverageIsEstablished
        self.today = today?.hasTokenData == true || today?.estimatedCostUSD != nil ? today : nil
        self.history = history?.hasTokenData == true || history?.estimatedCostUSD != nil ? history : nil
        self.provenance = provenance
        self.coverage = coverage
        self.meteredCostUSD = meteredCostUSD.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }

    /// Local logs are observations; only provider-reported metering is billing.
    public nonisolated var metricClass: PeelUsageMetricClass {
        scope == .providerAccount && provenance == .vendorMetered ? .vendorBilling : .observedLocalTokens
    }

    /// Producer age, falling back to receive age when the producer gave no time.
    public nonisolated func age(at now: Date) -> TimeInterval {
        now.timeIntervalSince(sampledAt ?? receivedAt)
    }

    /// Unpriced models listed in either period.
    public nonisolated var unpricedModelIDs: [String] {
        var seen = Set<String>()
        return ((today?.models ?? []) + (history?.models ?? []))
            .filter { !$0.priceKnown && seen.insert($0.modelID).inserted }
            .map(\.modelID)
    }

    /// True when the reading proves no local usage was recorded in the covered window.
    public nonisolated var recordsNoUsage: Bool {
        historyCoverageIsEstablished == true && today == nil && history == nil
    }
}

/// Why the latest observed-token attempt produced no new reading. Any previous reading is retained.
nonisolated public enum PeelObservedTokenFailure: Error, Equatable, Sendable {
    /// The provider reported an error for its local history (message is the helper's JSON message).
    case providerError(String)
    /// The bundled helper predates `cost --omit-projects`; Peel will not fall back to path-bearing output.
    case helperRejectedArguments
    /// The response was not the expected cost JSON.
    case incompatibleOutput
    /// The response did not contain the requested provider.
    case providerMissing
    case outputTooLarge
    case timedOut
    case cancelled
    case helperMissing
    case helperFailed(Int32)

    public nonisolated var summary: String {
        switch self {
        case let .providerError(message): message
        case .helperRejectedArguments: "This Peel build's usage helper can't return compact token detail."
        case .incompatibleOutput: "The usage helper returned token detail this Peel version can't read."
        case .providerMissing: "The usage helper returned no token detail for this provider."
        case .outputTooLarge: "Token detail was larger than Peel accepts."
        case .timedOut: "Reading local token history timed out."
        case .cancelled: "Token refresh was cancelled."
        case .helperMissing: "The usage helper is missing."
        case let .helperFailed(code): "The usage helper exited with code \(code)."
        }
    }

    /// Whether retrying with the same helper can help. An argument rejection needs a newer helper.
    public nonisolated var isRetryable: Bool {
        switch self {
        case .helperRejectedArguments, .incompatibleOutput, .helperMissing: false
        default: true
        }
    }

    public nonisolated init(commandError: Error) {
        switch commandError as? PeelUsageCommandError {
        case .missingHelper: self = .helperMissing
        case .cancelled: self = .cancelled
        case .timedOut: self = .timedOut
        case .outputTooLarge: self = .outputTooLarge
        case let .failed(code): self = .helperFailed(code)
        case .emptyOutput: self = .incompatibleOutput
        case nil: self = .incompatibleOutput
        }
    }
}

/// Latest observed-token state for one provider on this Mac. A failure never clears the last reading.
nonisolated public struct PeelObservedTokenRecord: Equatable, Sendable {
    public let providerID: String
    public private(set) var usage: PeelObservedTokenUsage?
    public private(set) var failure: PeelObservedTokenFailure?
    public private(set) var failedAt: Date?
    public private(set) var lastAttemptAt: Date?

    public nonisolated init(providerID: String) {
        self.providerID = providerID
    }

    public nonisolated mutating func recordSuccess(_ usage: PeelObservedTokenUsage, at date: Date) {
        self.usage = usage
        failure = nil
        failedAt = nil
        lastAttemptAt = date
    }

    public nonisolated mutating func recordFailure(_ failure: PeelObservedTokenFailure, at date: Date) {
        self.failure = failure
        failedAt = date
        lastAttemptAt = date
    }

    /// The retained reading is older than a failed refresh.
    public nonisolated var isShowingRetainedReading: Bool { usage != nil && failure != nil }
}

/// This Mac's observed-token records by provider ID. Pure state so refresh rules are testable:
/// allowance polls never touch it, failures keep the last reading, and only local-log dashboard rows
/// with token detail are recorded from a dashboard snapshot.
nonisolated public struct PeelObservedTokenLedger: Equatable, Sendable {
    public private(set) var records: [String: PeelObservedTokenRecord] = [:]

    public nonisolated init() {}

    public nonisolated subscript(providerID: String) -> PeelObservedTokenRecord? { records[providerID] }

    /// Applies one lane result. Returns `true` when the result counts as a failed attempt.
    @discardableResult
    public nonisolated mutating func apply(
        _ result: Result<PeelObservedTokenUsage, PeelObservedTokenFailure>,
        providerID: String,
        at date: Date) -> Bool
    {
        var record = records[providerID] ?? PeelObservedTokenRecord(providerID: providerID)
        switch result {
        case let .success(usage):
            record.recordSuccess(usage, at: date)
            records[providerID] = record
            return false
        case .failure(.cancelled):
            return false
        case let .failure(failure):
            record.recordFailure(failure, at: date)
            records[providerID] = record
            return true
        }
    }

    /// Records local-log token detail carried by a dashboard snapshot. A no-cost snapshot has no
    /// cost rows, so it leaves every record unchanged. Returns the provider IDs that were recorded.
    @discardableResult
    public nonisolated mutating func applyDashboard(_ snapshot: PeelUsageSnapshot, receivedAt: Date) -> [String] {
        var recorded: [String] = []
        for provider in snapshot.providers where PeelLocalTokenProvider(rawValue: provider.id) != nil {
            guard let cost = provider.cost,
                  let usage = PeelObservedTokenUsage(dashboardCost: cost, providerID: provider.id, receivedAt: receivedAt)
            else { continue }
            apply(.success(usage), providerID: provider.id, at: receivedAt)
            recorded.append(provider.id)
        }
        return recorded
    }

    /// Marks every eligible provider unsupported by the bundled helper, keeping retained readings.
    public nonisolated mutating func markHelperUnsupported(_ providerIDs: [String], at date: Date) {
        for id in providerIDs {
            apply(.failure(.helperRejectedArguments), providerID: id, at: date)
        }
    }

    /// Drops records for providers that are no longer enabled or eligible.
    public nonisolated mutating func prune(keeping providerIDs: Set<String>) {
        records = records.filter { providerIDs.contains($0.key) }
    }

    public nonisolated mutating func removeAll() {
        records.removeAll()
    }
}

/// Parses `cost --format json --json-only --provider <id> --omit-projects`. The `projects` key is not
/// decoded even if an older producer sends it; nothing raw is logged or persisted.
nonisolated public enum PeelObservedTokenParser {
    static let maximumDailyEntries = 400
    static let maximumModelRowsPerEntry = 256

    public nonisolated static func parse(
        _ data: Data,
        providerID: String,
        receivedAt: Date,
        calendar: Calendar = .current) -> Result<PeelObservedTokenUsage, PeelObservedTokenFailure>
    {
        let decoder = JSONDecoder()
        guard let rows = try? decoder.decode([PeelLossyCostRow].self, from: data) else {
            return .failure(.incompatibleOutput)
        }
        let decoded = rows.compactMap(\.row)
        if decoded.contains(where: { $0.provider == "cli" && $0.error?.kind == "args" }) {
            return .failure(.helperRejectedArguments)
        }
        guard let row = decoded.first(where: { $0.provider == providerID }) else {
            return .failure(rows.isEmpty || decoded.isEmpty ? .incompatibleOutput : .providerMissing)
        }
        guard row.daily.count <= maximumDailyEntries else { return .failure(.incompatibleOutput) }
        let usage = makeUsage(row, providerID: providerID, receivedAt: receivedAt, calendar: calendar)
        if let error = row.error, usage.today == nil, usage.history == nil {
            return .failure(.providerError(error.message))
        }
        return .success(usage)
    }

    private nonisolated static func makeUsage(
        _ row: PeelCostRow,
        providerID: String,
        receivedAt: Date,
        calendar: Calendar) -> PeelObservedTokenUsage
    {
        let observed = row.updatedAt ?? receivedAt
        let dayKey = Self.dayKey(observed, calendar: calendar)
        let todayEntry = row.daily.first { String($0.date.prefix(10)) == dayKey }
        // The producer may bucket days in a pinned time zone. Use the entry's classes only when it
        // agrees with the producer's own "today" total; otherwise keep just that total.
        let consistentToday = todayEntry.flatMap { entry -> PeelCostDailyRow? in
            guard let sessionTokens = row.sessionTokens else { return entry }
            return entry.tokens.total == sessionTokens ? entry : nil
        }
        var today: PeelObservedTokenPeriod?
        if let entry = consistentToday {
            today = PeelObservedTokenPeriod(
                days: 1,
                tokens: entry.tokens,
                estimatedCostUSD: row.sessionCostUSD ?? entry.costUSD,
                models: models(in: [entry]))
        } else if row.sessionTokens != nil || row.sessionCostUSD != nil {
            today = PeelObservedTokenPeriod(
                days: 1,
                tokens: PeelTokenCounts(total: row.sessionTokens),
                estimatedCostUSD: row.sessionCostUSD)
        }

        let totals = row.totals
        let historyTokens = PeelTokenCounts(
            input: totals?.tokens.input,
            output: totals?.tokens.output,
            cacheRead: totals?.tokens.cacheRead,
            cacheCreation: totals?.tokens.cacheCreation,
            reasoning: totals?.tokens.reasoning,
            total: totals?.tokens.total ?? row.last30DaysTokens)
        let history = PeelObservedTokenPeriod(
            days: row.historyDays ?? 30,
            tokens: historyTokens,
            estimatedCostUSD: row.last30DaysCostUSD ?? totals?.costUSD,
            models: models(in: row.daily))

        return PeelObservedTokenUsage(
            providerID: providerID,
            scope: PeelObservedTokenScope(costSource: row.source),
            sampledAt: row.updatedAt,
            receivedAt: receivedAt,
            currencyCode: row.currencyCode ?? "USD",
            historyDays: row.historyDays,
            historyCoverageIsEstablished: row.historyCoverageIsEstablished,
            today: today,
            history: history,
            provenance: PeelCostProvenance(rawProvenance: row.provenance ?? totals?.provenance),
            coverage: row.coverage ?? totals?.coverage,
            meteredCostUSD: row.meteredCostUSD)
    }

    /// Per-model sums across entries, grouped by stable `modelID` (never by the shortened display label).
    /// Rows without tokens make that model's tokens unknown; rows without a price, or a non-finite sum,
    /// make its cost unknown. Names in `modelsUsed` without a breakdown row stay listed with unknown
    /// tokens and price. Nothing is estimated from text or substituted with zero.
    nonisolated static func models(in entries: [PeelCostDailyRow]) -> [PeelObservedModelUsage] {
        struct Sum {
            var first: PeelObservedModelUsage
            var tokens: Int?
            var cost: Double?
        }
        var order: [String] = []
        var sums: [String: Sum] = [:]
        func record(_ model: PeelObservedModelUsage) {
            guard let existing = sums[model.modelID] else {
                order.append(model.modelID)
                sums[model.modelID] = Sum(first: model, tokens: model.totalTokens, cost: model.estimatedCostUSD)
                return
            }
            let cost = existing.cost.flatMap { current in
                model.estimatedCostUSD.flatMap { addition in
                    let sum = current + addition
                    return sum.isFinite ? sum : nil
                }
            }
            sums[model.modelID] = Sum(
                first: existing.first,
                tokens: PeelTokenCounts.adding(existing.tokens, model.totalTokens),
                cost: cost)
        }
        for entry in entries {
            var detailed = Set<String>()
            for model in entry.modelBreakdowns.prefix(maximumModelRowsPerEntry) {
                detailed.insert(model.modelID)
                record(model)
            }
            for raw in entry.modelsUsed.prefix(maximumModelRowsPerEntry) {
                guard let named = PeelObservedModelUsage(rawModelName: raw), !detailed.contains(named.modelID) else {
                    continue
                }
                detailed.insert(named.modelID)
                record(named)
            }
        }
        return order.compactMap { id in
            guard let sum = sums[id] else { return nil }
            return PeelObservedModelUsage(
                modelID: id,
                displayName: sum.first.displayName,
                totalTokens: sum.tokens,
                estimatedCostUSD: sum.cost,
                endpoint: sum.first.endpoint,
                localProviderID: sum.first.localProviderID)
        }
    }

    private nonisolated static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

extension PeelObservedTokenUsage {
    /// Projects a dashboard row's additive token detail. Only local-log rows qualify: a provider
    /// dashboard (`web`) cost belongs to that account and stays on the account-bound provider row.
    public nonisolated init?(dashboardCost cost: PeelUsageCost, providerID: String, receivedAt: Date) {
        guard PeelObservedTokenScope(costSource: cost.source) == .thisMacLocalLogs, cost.hasTokenDetail else {
            return nil
        }
        let days = cost.historyDays ?? 30
        self.init(
            providerID: providerID,
            scope: .thisMacLocalLogs,
            sampledAt: cost.updatedAt,
            receivedAt: receivedAt,
            historyDays: cost.historyDays,
            historyCoverageIsEstablished: cost.historyCoverageIsEstablished,
            today: cost.todayTokens.map {
                PeelObservedTokenPeriod(
                    days: 1,
                    tokens: $0.tokens,
                    estimatedCostUSD: $0.costUSD ?? cost.todayUSD,
                    models: $0.models,
                    omittedModelCount: $0.omittedModelCountIsCapped ? Int.max : $0.omittedModelCount)
            },
            history: cost.historyTokens.map {
                PeelObservedTokenPeriod(
                    days: days,
                    tokens: $0.tokens,
                    estimatedCostUSD: cost.last30DaysUSD ?? $0.costUSD,
                    models: $0.models,
                    omittedModelCount: $0.omittedModelCountIsCapped ? Int.max : $0.omittedModelCount)
            },
            provenance: cost.provenance ?? .unknown,
            coverage: cost.coverage,
            meteredCostUSD: cost.meteredCostUSD)
    }
}

/// Bounded cadence of the automatic local-token lane. It runs one provider per helper invocation,
/// sequentially, only while the quota lane is idle, with the same silent no-prompt environment.
nonisolated public enum PeelLocalTokenLanePolicy {
    /// Normal spacing between automatic lane passes (10 minutes).
    public static let interval: TimeInterval = 600
    /// Low Power Mode spacing (30 minutes).
    public static let lowPowerInterval: TimeInterval = 1_800
    /// Earliest a requested refresh (for example after an agent finishes) may follow the last pass.
    public static let minimumSpacing: TimeInterval = 120
    /// Failures double the spacing up to 2^3 × interval.
    public static let maximumBackoffExponent = 3

    /// Eligible providers in a stable order. Cursor and every network-cost provider are excluded by type.
    static func eligibleProviders(enabledProviderIDs: [String]) -> [PeelLocalTokenProvider] {
        let enabled = Set(enabledProviderIDs)
        return PeelLocalTokenProvider.allCases.filter { enabled.contains($0.rawValue) }
    }

    /// `cost --help` lists `--omit-projects` only in helpers that can return compact, path-free output.
    /// An older helper is treated as unsupported; Peel never falls back to the path-bearing shape.
    public static func helperSupportsCompactCost(helpOutput: Data) -> Bool {
        String(decoding: helpOutput.prefix(64 * 1024), as: UTF8.self).contains("--omit-projects")
    }

    public static func nextAttempt(after date: Date, consecutiveFailures: Int, lowPower: Bool) -> Date {
        let base = lowPower ? lowPowerInterval : interval
        let exponent = min(max(0, consecutiveFailures), maximumBackoffExponent)
        return date.addingTimeInterval(base * pow(2, Double(exponent)))
    }
}

// MARK: - Cost CLI JSON rows (decoding only)

nonisolated private struct PeelLossyCostRow: Decodable {
    let row: PeelCostRow?

    init(from decoder: Decoder) {
        row = try? PeelCostRow(from: decoder)
    }
}

nonisolated struct PeelCostErrorRow: Decodable, Sendable {
    let message: String
    let kind: String?

    private enum CodingKeys: String, CodingKey {
        case message
        case kind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let message = ((try? container.decodeIfPresent(String.self, forKey: .message)) ?? nil)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.message = String((message.isEmpty ? "Provider error" : message).prefix(240))
        kind = try? container.decodeIfPresent(String.self, forKey: .kind)
    }
}

nonisolated struct PeelCostDailyRow: Decodable, Sendable {
    let date: String
    let tokens: PeelTokenCounts
    let costUSD: Double?
    let modelsUsed: [String]
    let modelBreakdowns: [PeelObservedModelUsage]

    private enum CodingKeys: String, CodingKey {
        case date
        case costUSD = "totalCost"
        case modelsUsed
        case modelBreakdowns
    }

    init(
        date: String,
        tokens: PeelTokenCounts,
        costUSD: Double? = nil,
        modelsUsed: [String] = [],
        modelBreakdowns: [PeelObservedModelUsage] = [])
    {
        self.date = date
        self.tokens = tokens
        self.costUSD = costUSD.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.modelsUsed = modelsUsed
        self.modelBreakdowns = modelBreakdowns
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            date: try container.decode(String.self, forKey: .date),
            tokens: try PeelTokenCounts(from: decoder),
            costUSD: try? container.decodeIfPresent(Double.self, forKey: .costUSD),
            modelsUsed: (try? container.decodeIfPresent([PeelLossyString].self, forKey: .modelsUsed))?
                .compactMap(\.value) ?? [],
            modelBreakdowns: (try? container.decodeIfPresent(
                [PeelLossyModel].self,
                forKey: .modelBreakdowns))?.compactMap(\.value) ?? [])
    }
}

nonisolated struct PeelCostTotalsRow: Decodable, Sendable {
    let tokens: PeelTokenCounts
    let costUSD: Double?
    let provenance: String?
    let coverage: PeelCostCoverage?

    private enum CodingKeys: String, CodingKey {
        case costUSD = "totalCost"
        case provenance
        case coverage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tokens = try PeelTokenCounts(from: decoder)
        costUSD = ((try? container.decodeIfPresent(Double.self, forKey: .costUSD)) ?? nil)
            .flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        provenance = try? container.decodeIfPresent(String.self, forKey: .provenance)
        coverage = try? container.decodeIfPresent(PeelCostCoverage.self, forKey: .coverage)
    }
}

nonisolated struct PeelCostRow: Decodable, Sendable {
    let provider: String
    let source: String?
    let updatedAt: Date?
    let currencyCode: String?
    let sessionTokens: Int?
    let sessionCostUSD: Double?
    let historyDays: Int?
    let historyCoverageIsEstablished: Bool?
    let last30DaysTokens: Int?
    let last30DaysCostUSD: Double?
    let meteredCostUSD: Double?
    let daily: [PeelCostDailyRow]
    let totals: PeelCostTotalsRow?
    let provenance: String?
    let coverage: PeelCostCoverage?
    let error: PeelCostErrorRow?

    // `projects` is intentionally absent: project names and paths are never decoded.
    private enum CodingKeys: String, CodingKey {
        case provider
        case source
        case updatedAt
        case currencyCode
        case sessionTokens
        case sessionCostUSD
        case historyDays
        case historyCoverageIsEstablished
        case last30DaysTokens
        case last30DaysCostUSD
        case meteredCostUSD
        case daily
        case totals
        case provenance
        case coverage
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(String.self, forKey: .provider)
        source = try? container.decodeIfPresent(String.self, forKey: .source)
        updatedAt = ((try? container.decodeIfPresent(String.self, forKey: .updatedAt)) ?? nil)
            .flatMap(PeelCostRow.date(from:))
        currencyCode = try? container.decodeIfPresent(String.self, forKey: .currencyCode)
        sessionTokens = Self.count(container, .sessionTokens)
        sessionCostUSD = Self.amount(container, .sessionCostUSD)
        historyDays = ((try? container.decodeIfPresent(Int.self, forKey: .historyDays)) ?? nil)
            .flatMap { (1...366).contains($0) ? $0 : nil }
        historyCoverageIsEstablished = try? container.decodeIfPresent(Bool.self, forKey: .historyCoverageIsEstablished)
        last30DaysTokens = Self.count(container, .last30DaysTokens)
        last30DaysCostUSD = Self.amount(container, .last30DaysCostUSD)
        meteredCostUSD = Self.amount(container, .meteredCostUSD)
        daily = (try? container.decodeIfPresent([PeelLossyDaily].self, forKey: .daily))?
            .compactMap(\.value) ?? []
        totals = try? container.decodeIfPresent(PeelCostTotalsRow.self, forKey: .totals)
        provenance = try? container.decodeIfPresent(String.self, forKey: .provenance)
        coverage = try? container.decodeIfPresent(PeelCostCoverage.self, forKey: .coverage)
        error = try? container.decodeIfPresent(PeelCostErrorRow.self, forKey: .error)
    }

    private static func count(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        guard let value = (try? container.decodeIfPresent(Int.self, forKey: key)) ?? nil, value >= 0 else {
            return nil
        }
        return value
    }

    private static func amount(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double? {
        guard let value = (try? container.decodeIfPresent(Double.self, forKey: key)) ?? nil,
              value.isFinite, value >= 0 else { return nil }
        return value
    }

    static func date(from value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

nonisolated private struct PeelLossyDaily: Decodable {
    let value: PeelCostDailyRow?
    init(from decoder: Decoder) { value = try? PeelCostDailyRow(from: decoder) }
}

nonisolated private struct PeelLossyModel: Decodable {
    let value: PeelObservedModelUsage?
    init(from decoder: Decoder) { value = try? PeelObservedModelUsage(from: decoder) }
}

nonisolated private struct PeelLossyString: Decodable {
    let value: String?
    init(from decoder: Decoder) { value = try? decoder.singleValueContainer().decode(String.self) }
}
