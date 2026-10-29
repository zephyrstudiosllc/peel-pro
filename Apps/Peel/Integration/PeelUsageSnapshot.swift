import CryptoKit
import Foundation

/// The display percentage selected for a usage window.
///
/// A dashboard window can provide either a used percentage, a remaining
/// percentage, or both. `basis` records which value a display chose so that a
/// consumer never has to guess whether `value` means used or remaining.
nonisolated public enum PeelUsagePercentBasis: String, Codable, Equatable, Sendable {
    case used
    case remaining
}

nonisolated public struct PeelUsageDisplayPercent: Codable, Equatable, Sendable {
    public let value: Double
    public let basis: PeelUsagePercentBasis

    public nonisolated init(value: Double, basis: PeelUsagePercentBasis) {
        self.value = value
        self.basis = basis
    }

    /// The percentage represented as usage, regardless of the source basis.
    public nonisolated var usedPercent: Double {
        switch basis {
        case .used:
            value
        case .remaining:
            100 - value
        }
    }

    /// The percentage represented as remaining capacity, regardless of the
    /// source basis.
    public nonisolated var remainingPercent: Double {
        switch basis {
        case .used:
            100 - value
        case .remaining:
            value
        }
    }

    /// Alias that makes the meaning explicit at call sites that render a bar.
    public nonisolated var semantics: PeelUsagePercentBasis { basis }
}

nonisolated public struct PeelUsageIdentity: Codable, Equatable, Sendable {
    public let accountEmail: String?
    public let plan: String?
    public let accountKey: String?

    public nonisolated init(accountEmail: String? = nil, plan: String? = nil, accountKey: String? = nil) {
        self.accountEmail = accountEmail
        self.plan = plan
        self.accountKey = accountKey
    }

    /// Short alias for UI code that calls the field an email address.
    public nonisolated var email: String? { accountEmail }

    nonisolated var isEmpty: Bool {
        accountEmail == nil && plan == nil && accountKey == nil
    }

    private enum CodingKeys: String, CodingKey {
        case accountEmail
        case plan
        case accountKey
    }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            accountEmail: peelDecodeLossy(String.self, from: container, forKey: .accountEmail),
            plan: peelDecodeLossy(String.self, from: container, forKey: .plan),
            accountKey: peelDecodeLossy(String.self, from: container, forKey: .accountKey))
    }
}

nonisolated public struct PeelUsageStatus: Codable, Equatable, Sendable {
    public let level: String
    public let label: String
    public let updatedAt: Date?

    public nonisolated init(level: String, label: String, updatedAt: Date? = nil) {
        self.level = level
        self.label = label
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case level
        case label
        case updatedAt
    }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard
            let level = peelDecodeLossy(String.self, from: container, forKey: .level),
            let label = peelDecodeLossy(String.self, from: container, forKey: .label),
            !level.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw peelDecodingError(
                decoder,
                "A usage status requires non-empty level and label values.")
        }
        self.init(
            level: level,
            label: label,
            updatedAt: peelDecodeISO8601Date(from: container, forKey: .updatedAt))
    }
}

nonisolated public struct PeelUsageWindow: Codable, Equatable, Sendable, Identifiable {
    public let kind: String
    public let label: String
    /// Usage percentage in the contract's 0...100 percent units, when known.
    public let usedPercent: Double?
    /// Remaining percentage in the contract's 0...100 percent units, when known.
    public let remainingPercent: Double?
    public let resetAt: Date?
    public let idle: Bool

    public nonisolated init(
        kind: String,
        label: String,
        usedPercent: Double? = nil,
        remainingPercent: Double? = nil,
        resetAt: Date? = nil,
        idle: Bool = false)
    {
        self.kind = kind
        self.label = label
        self.usedPercent = peelNormalizedPercent(usedPercent)
        self.remainingPercent = peelNormalizedPercent(remainingPercent)
        self.resetAt = resetAt
        self.idle = idle
    }

    public nonisolated var id: String { kind }

    /// A valid used percentage, inferring it from remaining capacity when
    /// used percentage was omitted.
    public nonisolated var normalizedUsedPercent: Double? {
        if let usedPercent { return usedPercent }
        return remainingPercent.map { 100 - $0 }
    }

    /// A valid remaining percentage, inferring it from usage when remaining
    /// percentage was omitted.
    public nonisolated var normalizedRemainingPercent: Double? {
        if let remainingPercent { return remainingPercent }
        return usedPercent.map { 100 - $0 }
    }

    /// The value a compact display should use. When both values are present,
    /// usage is preferred; `basis` keeps that choice explicit.
    public nonisolated var displayPercent: PeelUsageDisplayPercent? {
        if let usedPercent {
            return PeelUsageDisplayPercent(value: usedPercent, basis: .used)
        }
        if let remainingPercent {
            return PeelUsageDisplayPercent(value: remainingPercent, basis: .remaining)
        }
        return nil
    }

    /// Convenience for consumers whose bar is always expressed as usage.
    public nonisolated var displayUsedPercent: Double? { normalizedUsedPercent }

    private enum CodingKeys: String, CodingKey {
        case kind
        case label
        case usedPercent
        case remainingPercent
        case resetAt
        case idle
    }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard
            let kind = peelDecodeLossy(String.self, from: container, forKey: .kind),
            let label = peelDecodeLossy(String.self, from: container, forKey: .label),
            !kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw peelDecodingError(
                decoder,
                "A usage window requires non-empty kind and label values.")
        }
        self.init(
            kind: kind,
            label: label,
            usedPercent: peelDecodePercent(from: container, forKey: .usedPercent),
            remainingPercent: peelDecodePercent(from: container, forKey: .remainingPercent),
            resetAt: peelDecodeISO8601Date(from: container, forKey: .resetAt),
            idle: peelDecodeLossy(Bool.self, from: container, forKey: .idle) ?? false)
    }
}

nonisolated public struct PeelUsageError: Codable, Equatable, Sendable {
    public let code: Int?
    public let message: String
    public let kind: String?

    public nonisolated init(code: Int? = nil, message: String, kind: String? = nil) {
        self.code = code
        self.message = message
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case message
        case kind
    }

    public nonisolated init(from decoder: Decoder) throws {
        let singleValue = try decoder.singleValueContainer()
        if let message = try? singleValue.decode(String.self) {
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw peelDecodingError(decoder, "An error message cannot be empty.")
            }
            self.init(message: message)
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let code = peelDecodeLossy(Int.self, from: container, forKey: .code)
        let kind = peelDecodeLossy(String.self, from: container, forKey: .kind)
        let message = peelDecodeLossy(String.self, from: container, forKey: .message)
            ?? ((code != nil || kind != nil) ? "Provider error" : nil)
        guard let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw peelDecodingError(decoder, "A provider error requires a message.")
        }
        self.init(code: code, message: message, kind: kind)
    }
}

/// Provider credits or balance when the dashboard exposes one.
nonisolated public struct PeelUsageCredits: Codable, Equatable, Sendable {
    public let remaining: Double
    public let unit: String

    public nonisolated init(remaining: Double, unit: String) {
        self.remaining = remaining
        self.unit = unit
    }

    private enum CodingKeys: String, CodingKey {
        case remaining
        case unit
    }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let remaining = peelDecodeNonNegativeDouble(from: container, forKey: .remaining),
              let unit = peelDecodeNonEmptyString(from: container, forKey: .unit) else {
            throw peelDecodingError(decoder, "A credits value requires a finite remaining value and non-empty unit.")
        }
        self.init(remaining: remaining, unit: unit)
    }
}

/// Token amounts by class. Every class is a non-negative integer; `nil` means the source did not
/// establish that class and must never be shown or summed as zero. Negative, fractional, non-finite
/// or out-of-range JSON numbers decode as unknown.
nonisolated public struct PeelTokenCounts: Codable, Equatable, Sendable {
    public let input: Int?
    public let output: Int?
    public let cacheRead: Int?
    public let cacheCreation: Int?
    public let reasoning: Int?
    public let total: Int?

    public nonisolated init(
        input: Int? = nil,
        output: Int? = nil,
        cacheRead: Int? = nil,
        cacheCreation: Int? = nil,
        reasoning: Int? = nil,
        total: Int? = nil)
    {
        self.input = peelNormalizedTokenCount(input)
        self.output = peelNormalizedTokenCount(output)
        self.cacheRead = peelNormalizedTokenCount(cacheRead)
        self.cacheCreation = peelNormalizedTokenCount(cacheCreation)
        self.reasoning = peelNormalizedTokenCount(reasoning)
        self.total = peelNormalizedTokenCount(total)
    }

    public nonisolated var hasAnyValue: Bool {
        input != nil || output != nil || cacheRead != nil || cacheCreation != nil || reasoning != nil || total != nil
    }

    /// Adds two known amounts. Unknown on either side, or an overflow, stays unknown.
    public nonisolated static func adding(_ lhs: Int?, _ rhs: Int?) -> Int? {
        guard let lhs, let rhs else { return nil }
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : sum
    }

    private enum CodingKeys: String, CodingKey {
        case input = "inputTokens"
        case output = "outputTokens"
        case cacheRead = "cacheReadTokens"
        case cacheCreation = "cacheCreationTokens"
        case reasoning = "reasoningTokens"
        case total = "totalTokens"
    }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            input: peelDecodeTokenCount(from: container, forKey: .input),
            output: peelDecodeTokenCount(from: container, forKey: .output),
            cacheRead: peelDecodeTokenCount(from: container, forKey: .cacheRead),
            cacheCreation: peelDecodeTokenCount(from: container, forKey: .cacheCreation),
            reasoning: peelDecodeTokenCount(from: container, forKey: .reasoning),
            total: peelDecodeTokenCount(from: container, forKey: .total))
    }
}

/// How a cost figure was produced. None of these values is a billing receipt.
nonisolated public enum PeelCostProvenance: String, Codable, Equatable, Sendable {
    /// Observed tokens multiplied by public API list prices.
    case listPriceEstimate
    /// Spend reported by the provider's own metering (for example Cursor plan deductions).
    case vendorMetered
    case mixed
    case unknown

    public nonisolated init(rawProvenance: String?) {
        self = rawProvenance.flatMap { Self(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            ?? .unknown
    }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawProvenance: try? container.decode(String.self))
    }
}

/// Request/row coverage of a cost window, as counted by the producer.
nonisolated public struct PeelCostCoverage: Codable, Equatable, Sendable {
    public let priced: Int
    public let unpriced: Int
    public let unmetered: Int
    public let estimated: Int

    public nonisolated init(priced: Int = 0, unpriced: Int = 0, unmetered: Int = 0, estimated: Int = 0) {
        self.priced = max(0, priced)
        self.unpriced = max(0, unpriced)
        self.unmetered = max(0, unmetered)
        self.estimated = max(0, estimated)
    }

    /// Total counted rows, or `nil` if the counts cannot be added safely.
    public nonisolated var total: Int? {
        [unpriced, unmetered, estimated].reduce(Optional(priced)) { PeelTokenCounts.adding($0, $1) }
    }

    /// True only when every counted row had a known price.
    public nonisolated var isFullyPriced: Bool {
        unpriced == 0 && unmetered == 0 && (total ?? 0) > 0
    }

    private enum CodingKeys: String, CodingKey {
        case priced
        case unpriced
        case unmetered
        case estimated
    }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let priced = peelDecodeTokenCount(from: container, forKey: .priced)
        let unpriced = peelDecodeTokenCount(from: container, forKey: .unpriced)
        let unmetered = peelDecodeTokenCount(from: container, forKey: .unmetered)
        let estimated = peelDecodeTokenCount(from: container, forKey: .estimated)
        guard priced != nil || unpriced != nil || unmetered != nil || estimated != nil else {
            throw peelDecodingError(decoder, "A coverage value requires at least one count.")
        }
        self.init(priced: priced ?? 0, unpriced: unpriced ?? 0, unmetered: unmetered ?? 0, estimated: estimated ?? 0)
    }
}

/// Where a model's requests were served, as recorded by the producer. `.unspecified` means the log
/// recorded OpenAI's own provider or nothing at all; it is not a claim about billing.
nonisolated public enum PeelModelEndpoint: String, Codable, Equatable, Sendable {
    case unspecified
    /// A recorded built-in local provider (Codex `oss`, `ollama`, `lmstudio`). Never priced.
    case local
    /// Any other recorded provider (proxy, other cloud, self-hosted). Infrastructure cost unknown.
    case custom

    public nonisolated init(rawEndpoint: String?) {
        switch rawEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "local": self = .local
        case "custom": self = .custom
        default: self = .unspecified
        }
    }
}

/// One model's observed tokens. `modelID` is a stable, non-secret identity used for grouping; it is the
/// producer's label when that label is bounded and path-free (`org/model`, `model:tag`), otherwise an
/// opaque digest of the full label. `displayName` is a bounded label that may be shortened or shared.
/// `estimatedCostUSD` is `nil` when no price is known (always for local or custom providers).
nonisolated public struct PeelObservedModelUsage: Codable, Equatable, Sendable, Identifiable {
    public let modelID: String
    public let displayName: String
    public let totalTokens: Int?
    public let estimatedCostUSD: Double?
    public let endpoint: PeelModelEndpoint
    /// Codex's fixed built-in local provider ID for `.local` rows; never a custom provider ID.
    public let localProviderID: String?

    /// Builds a row from the producer's full model label. Grouping uses the derived `modelID`.
    public nonisolated init?(
        rawModelName: String,
        totalTokens: Int? = nil,
        estimatedCostUSD: Double? = nil,
        endpoint: PeelModelEndpoint? = nil,
        localProviderID: String? = nil)
    {
        guard let identity = peelModelIdentity(rawModelName) else { return nil }
        let qualification = peelModelQualification(identity)
        let resolvedEndpoint = endpoint.flatMap { $0 == .unspecified ? nil : $0 } ?? qualification.endpoint
        self.init(
            modelID: peelModelKey(identity),
            displayName: peelSanitizedModelID(qualification.model) ?? "Unknown model",
            totalTokens: totalTokens,
            estimatedCostUSD: estimatedCostUSD,
            endpoint: resolvedEndpoint,
            localProviderID: localProviderID ?? qualification.localProviderID)
    }

    /// Source-compatible convenience: `modelID` here is the producer's raw label.
    public nonisolated init?(modelID: String, totalTokens: Int? = nil, estimatedCostUSD: Double? = nil) {
        self.init(rawModelName: modelID, totalTokens: totalTokens, estimatedCostUSD: estimatedCostUSD)
    }

    nonisolated init(
        modelID: String,
        displayName: String,
        totalTokens: Int?,
        estimatedCostUSD: Double?,
        endpoint: PeelModelEndpoint,
        localProviderID: String?)
    {
        self.modelID = modelID
        self.displayName = displayName
        self.totalTokens = peelNormalizedTokenCount(totalTokens)
        self.endpoint = endpoint
        // A local or custom provider never accrues a vendor price, whatever the label resembles.
        self.estimatedCostUSD = endpoint == .unspecified ? peelNormalizedNonNegativeDouble(estimatedCostUSD) : nil
        self.localProviderID = endpoint == .local ? localProviderID.flatMap(peelKnownLocalProviderID) : nil
    }

    public nonisolated var id: String { modelID }
    public nonisolated var priceKnown: Bool { estimatedCostUSD != nil }

    nonisolated func renamed(_ displayName: String) -> PeelObservedModelUsage {
        PeelObservedModelUsage(
            modelID: modelID,
            displayName: displayName,
            totalTokens: totalTokens,
            estimatedCostUSD: estimatedCostUSD,
            endpoint: endpoint,
            localProviderID: localProviderID)
    }

    private enum CodingKeys: String, CodingKey {
        case modelID = "modelKey"
        case displayName = "modelName"
        case totalTokens
        case estimatedCostUSD = "cost"
        case endpoint
        case localProviderID = "localProvider"
    }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let rawName = peelDecodeLossy(String.self, from: container, forKey: .displayName),
              let derived = Self(
                  rawModelName: rawName,
                  totalTokens: peelDecodeTokenCount(from: container, forKey: .totalTokens),
                  estimatedCostUSD: peelDecodeNonNegativeDouble(from: container, forKey: .estimatedCostUSD),
                  endpoint: PeelModelEndpoint(
                      rawEndpoint: peelDecodeLossy(String.self, from: container, forKey: .endpoint)),
                  localProviderID: peelDecodeLossy(String.self, from: container, forKey: .localProviderID))
        else {
            throw peelDecodingError(decoder, "A model row requires a usable model name.")
        }
        // A producer-supplied key (dashboard rows) is kept when it has the safe key shape; the label is
        // then already a display label.
        if let key = peelDecodeLossy(String.self, from: container, forKey: .modelID), peelIsSafeModelKey(key) {
            self = PeelObservedModelUsage(
                modelID: key,
                displayName: peelSanitizedModelID(rawName) ?? derived.displayName,
                totalTokens: derived.totalTokens,
                estimatedCostUSD: derived.estimatedCostUSD,
                endpoint: derived.endpoint,
                localProviderID: derived.localProviderID)
        } else {
            self = derived
        }
    }
}

nonisolated public enum PeelModelListBounds {
    /// Model lists are bounded; this many omitted models is the most Peel reports exactly.
    public static let maximumReportedOmittedModels = 99_999
}

/// Adds a producer-declared omitted count and a local truncation count without trapping. Negative inputs
/// are zero; an overflowing or implausible total is capped and flagged as a lower bound.
public nonisolated func peelBoundedOmittedCount(declared: Int, truncated: Int) -> (count: Int, isCapped: Bool) {
    let (sum, overflow) = max(0, declared).addingReportingOverflow(max(0, truncated))
    guard !overflow, sum <= PeelModelListBounds.maximumReportedOmittedModels else {
        return (PeelModelListBounds.maximumReportedOmittedModels, true)
    }
    return (sum, false)
}

/// Token classes and a bounded model breakdown for one dashboard cost period.
nonisolated public struct PeelUsageTokenPeriodDetail: Codable, Equatable, Sendable {
    public static let maximumModels = 32

    public let tokens: PeelTokenCounts
    public let costUSD: Double?
    public let models: [PeelObservedModelUsage]
    /// Models not listed (their tokens remain in `tokens`); a lower bound when `omittedModelCountIsCapped`.
    public let omittedModelCount: Int
    public let omittedModelCountIsCapped: Bool

    public nonisolated init(
        tokens: PeelTokenCounts,
        costUSD: Double? = nil,
        models: [PeelObservedModelUsage] = [],
        omittedModelCount: Int = 0)
    {
        self.tokens = tokens
        self.costUSD = peelNormalizedNonNegativeDouble(costUSD)
        self.models = Array(models.prefix(Self.maximumModels))
        let omitted = peelBoundedOmittedCount(
            declared: omittedModelCount,
            truncated: models.count - Self.maximumModels)
        self.omittedModelCount = omitted.count
        self.omittedModelCountIsCapped = omitted.isCapped
    }

    public nonisolated var hasTokenData: Bool { tokens.hasAnyValue || !models.isEmpty }

    private enum CodingKeys: String, CodingKey {
        case costUSD = "totalCost"
        case models
        case omittedModelCount
    }

    public nonisolated func encode(to encoder: Encoder) throws {
        try tokens.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(costUSD, forKey: .costUSD)
        try container.encode(models, forKey: .models)
        try container.encode(omittedModelCount, forKey: .omittedModelCount)
    }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            tokens: try PeelTokenCounts(from: decoder),
            costUSD: peelDecodeNonNegativeDouble(from: container, forKey: .costUSD),
            models: peelDecodeLossy(
                [PeelLossy<PeelObservedModelUsage>].self,
                from: container,
                forKey: .models)?.compactMap { $0.value } ?? [],
            omittedModelCount: peelDecodeTokenCount(from: container, forKey: .omittedModelCount) ?? 0)
    }
}

/// Cost values attached to one provider's dashboard row. The token fields are an additive
/// dashboard-v1 extension; older helpers send only the two USD amounts.
nonisolated public struct PeelUsageCost: Codable, Equatable, Sendable {
    public let todayUSD: Double?
    public let last30DaysUSD: Double?
    /// `local` for this Mac's harness logs, `web` for a provider dashboard, when reported.
    public let source: String?
    /// Producer observation time for this cost reading, independent of quota freshness.
    public let updatedAt: Date?
    public let historyDays: Int?
    public let historyCoverageIsEstablished: Bool?
    public let provenance: PeelCostProvenance?
    public let coverage: PeelCostCoverage?
    public let meteredCostUSD: Double?
    public let todayTokens: PeelUsageTokenPeriodDetail?
    public let historyTokens: PeelUsageTokenPeriodDetail?

    public nonisolated init(
        todayUSD: Double? = nil,
        last30DaysUSD: Double? = nil,
        source: String? = nil,
        updatedAt: Date? = nil,
        historyDays: Int? = nil,
        historyCoverageIsEstablished: Bool? = nil,
        provenance: PeelCostProvenance? = nil,
        coverage: PeelCostCoverage? = nil,
        meteredCostUSD: Double? = nil,
        todayTokens: PeelUsageTokenPeriodDetail? = nil,
        historyTokens: PeelUsageTokenPeriodDetail? = nil)
    {
        self.todayUSD = peelNormalizedNonNegativeDouble(todayUSD)
        self.last30DaysUSD = peelNormalizedNonNegativeDouble(last30DaysUSD)
        self.source = source
        self.updatedAt = updatedAt
        self.historyDays = historyDays.flatMap { (1...366).contains($0) ? $0 : nil }
        self.historyCoverageIsEstablished = historyCoverageIsEstablished
        self.provenance = provenance
        self.coverage = coverage
        self.meteredCostUSD = peelNormalizedNonNegativeDouble(meteredCostUSD)
        self.todayTokens = todayTokens?.hasTokenData == true ? todayTokens : nil
        self.historyTokens = historyTokens?.hasTokenData == true ? historyTokens : nil
    }

    /// True when the row carries observed token detail rather than only amounts.
    public nonisolated var hasTokenDetail: Bool { todayTokens != nil || historyTokens != nil }

    private enum CodingKeys: String, CodingKey {
        case todayUSD
        case last30DaysUSD
        case source
        case updatedAt
        case historyDays
        case historyCoverageIsEstablished
        case provenance
        case coverage
        case meteredCostUSD
        case todayTokens
        case historyTokens
    }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let todayUSD = peelDecodeNonNegativeDouble(from: container, forKey: .todayUSD)
        let last30DaysUSD = peelDecodeNonNegativeDouble(from: container, forKey: .last30DaysUSD)
        let todayTokens = peelDecodeLossy(PeelUsageTokenPeriodDetail.self, from: container, forKey: .todayTokens)
        let historyTokens = peelDecodeLossy(PeelUsageTokenPeriodDetail.self, from: container, forKey: .historyTokens)
        guard todayUSD != nil || last30DaysUSD != nil
            || todayTokens?.hasTokenData == true || historyTokens?.hasTokenData == true
        else {
            throw peelDecodingError(
                decoder,
                "A cost value requires a finite non-negative amount or observed token detail.")
        }
        self.init(
            todayUSD: todayUSD,
            last30DaysUSD: last30DaysUSD,
            source: peelDecodeNonEmptyString(from: container, forKey: .source),
            updatedAt: peelDecodeISO8601Date(from: container, forKey: .updatedAt),
            historyDays: peelDecodeLossy(Int.self, from: container, forKey: .historyDays),
            historyCoverageIsEstablished: peelDecodeLossy(Bool.self, from: container, forKey: .historyCoverageIsEstablished),
            provenance: peelDecodeLossy(String.self, from: container, forKey: .provenance)
                .map { PeelCostProvenance(rawProvenance: $0) },
            coverage: peelDecodeLossy(PeelCostCoverage.self, from: container, forKey: .coverage),
            meteredCostUSD: peelDecodeNonNegativeDouble(from: container, forKey: .meteredCostUSD),
            todayTokens: todayTokens,
            historyTokens: historyTokens)
    }
}

/// One provider pace value from a multi-account dashboard entry.
nonisolated public struct PeelUsagePace: Codable, Equatable, Sendable {
    public let stage: String
    public let deltaPercent: Double
    public let expectedUsedPercent: Double
    public let willLastToReset: Bool
    public let etaSeconds: TimeInterval?
    public let runOutProbability: Double?
    public let summary: String

    public nonisolated init(
        stage: String,
        deltaPercent: Double,
        expectedUsedPercent: Double,
        willLastToReset: Bool,
        etaSeconds: TimeInterval? = nil,
        runOutProbability: Double? = nil,
        summary: String)
    {
        self.stage = stage
        self.deltaPercent = deltaPercent
        self.expectedUsedPercent = expectedUsedPercent
        self.willLastToReset = willLastToReset
        self.etaSeconds = peelNormalizedNonNegativeDouble(etaSeconds)
        self.runOutProbability = peelNormalizedFraction(runOutProbability)
        self.summary = summary
    }

    private enum CodingKeys: String, CodingKey {
        case stage
        case deltaPercent
        case expectedUsedPercent
        case willLastToReset
        case etaSeconds
        case runOutProbability
        case summary
    }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let stage = peelDecodeNonEmptyString(from: container, forKey: .stage),
              let deltaPercent = peelDecodeFiniteDouble(from: container, forKey: .deltaPercent),
              let expectedUsedPercent = peelDecodePercent(from: container, forKey: .expectedUsedPercent),
              let willLastToReset = peelDecodeLossy(Bool.self, from: container, forKey: .willLastToReset),
              let summary = peelDecodeNonEmptyString(from: container, forKey: .summary) else {
            throw peelDecodingError(decoder, "A pace value is missing a valid required field.")
        }
        self.init(
            stage: stage,
            deltaPercent: deltaPercent,
            expectedUsedPercent: expectedUsedPercent,
            willLastToReset: willLastToReset,
            etaSeconds: peelDecodeNonNegativeDouble(from: container, forKey: .etaSeconds),
            runOutProbability: peelDecodeFraction(from: container, forKey: .runOutProbability),
            summary: summary)
    }
}

/// Primary, secondary and tertiary pace values for one account.
nonisolated public struct PeelUsagePaceSet: Codable, Equatable, Sendable {
    public let primary: PeelUsagePace?
    public let secondary: PeelUsagePace?
    public let tertiary: PeelUsagePace?

    public nonisolated init(
        primary: PeelUsagePace? = nil,
        secondary: PeelUsagePace? = nil,
        tertiary: PeelUsagePace? = nil)
    {
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
    }

    private enum CodingKeys: String, CodingKey {
        case primary
        case secondary
        case tertiary
    }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let primary = peelDecodeLossy(PeelUsagePace.self, from: container, forKey: .primary)
        let secondary = peelDecodeLossy(PeelUsagePace.self, from: container, forKey: .secondary)
        let tertiary = peelDecodeLossy(PeelUsagePace.self, from: container, forKey: .tertiary)
        guard primary != nil || secondary != nil || tertiary != nil else {
            throw peelDecodingError(decoder, "A pace set contains no usable pace values.")
        }
        self.init(primary: primary, secondary: secondary, tertiary: tertiary)
    }
}

/// One source-owned account entry from a multi-account provider adapter.
nonisolated public struct PeelUsageAccount: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let active: Bool
    public let identity: PeelUsageIdentity?
    public let windows: [PeelUsageWindow]
    public let pace: PeelUsagePaceSet?
    public let error: String?
    public let updatedAt: Date?

    public nonisolated init(
        id: String,
        label: String,
        active: Bool,
        identity: PeelUsageIdentity? = nil,
        windows: [PeelUsageWindow] = [],
        pace: PeelUsagePaceSet? = nil,
        error: String? = nil,
        updatedAt: Date? = nil)
    {
        self.id = id
        self.label = label
        self.active = active
        self.identity = identity
        self.windows = windows
        self.pace = pace
        self.error = error
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case active
        case identity
        case windows
        case pace
        case error
        case updatedAt
    }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = peelDecodeNonEmptyString(from: container, forKey: .id),
              let label = peelDecodeNonEmptyString(from: container, forKey: .label),
              let active = peelDecodeLossy(Bool.self, from: container, forKey: .active) else {
            throw peelDecodingError(decoder, "An account requires non-empty id and label values plus active.")
        }

        let identity = peelDecodeLossy(PeelUsageIdentity.self, from: container, forKey: .identity)
        let windows = peelDecodeLossy(
            [PeelLossy<PeelUsageWindow>].self,
            from: container,
            forKey: .windows)?.compactMap { $0.value } ?? []
        self.init(
            id: id,
            label: label,
            active: active,
            identity: identity?.isEmpty == true ? nil : identity,
            windows: windows,
            pace: peelDecodeLossy(PeelUsagePaceSet.self, from: container, forKey: .pace),
            error: peelDecodeNonEmptyString(from: container, forKey: .error),
            updatedAt: peelDecodeISO8601Date(from: container, forKey: .updatedAt))
    }
}

nonisolated public struct PeelUsageProvider: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let enabled: Bool
    /// Empty or shell snapshots may omit the source; full snapshots normally
    /// carry the producer's source string.
    public let source: String?
    public let status: PeelUsageStatus?
    public let identity: PeelUsageIdentity?
    public let windows: [PeelUsageWindow]
    public let credits: PeelUsageCredits?
    public let cost: PeelUsageCost?
    public let accounts: [PeelUsageAccount]?
    public let accountsError: String?
    public let error: PeelUsageError?
    public let updatedAt: Date?
    public let allowanceUpdatedAt: Date?

    public nonisolated init(
        id: String,
        name: String,
        enabled: Bool,
        source: String? = nil,
        status: PeelUsageStatus? = nil,
        identity: PeelUsageIdentity? = nil,
        windows: [PeelUsageWindow] = [],
        credits: PeelUsageCredits? = nil,
        cost: PeelUsageCost? = nil,
        accounts: [PeelUsageAccount]? = nil,
        accountsError: String? = nil,
        error: PeelUsageError? = nil,
        updatedAt: Date? = nil,
        allowanceUpdatedAt: Date? = nil)
    {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.source = source
        self.status = status
        self.identity = identity
        self.windows = windows
        self.credits = credits
        self.cost = cost
        self.accounts = accounts
        self.accountsError = accountsError
        self.error = error
        self.updatedAt = updatedAt
        self.allowanceUpdatedAt = allowanceUpdatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case enabled
        case source
        case status
        case identity
        case windows
        case credits
        case cost
        case accounts
        case accountsError
        case error
        case updatedAt
        case allowanceUpdatedAt
    }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard
            let id = try? container.decode(String.self, forKey: .id),
            let name = try? container.decode(String.self, forKey: .name),
            let enabled = try? container.decode(Bool.self, forKey: .enabled),
            !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw peelDecodingError(
                decoder,
                "A provider requires non-empty id and name values plus enabled.")
        }

        let identity = peelDecodeLossy(PeelUsageIdentity.self, from: container, forKey: .identity)
        let windows = peelDecodeLossy(
            [PeelLossy<PeelUsageWindow>].self,
            from: container,
            forKey: .windows)?.compactMap { $0.value } ?? []
        let accounts = peelDecodeLossy(
            [PeelLossy<PeelUsageAccount>].self,
            from: container,
            forKey: .accounts)?.compactMap { $0.value }

        self.init(
            id: id,
            name: name,
            enabled: enabled,
            source: peelDecodeLossy(String.self, from: container, forKey: .source),
            status: peelDecodeLossy(PeelUsageStatus.self, from: container, forKey: .status),
            identity: identity?.isEmpty == true ? nil : identity,
            windows: windows,
            credits: peelDecodeLossy(PeelUsageCredits.self, from: container, forKey: .credits),
            cost: peelDecodeLossy(PeelUsageCost.self, from: container, forKey: .cost),
            accounts: accounts,
            accountsError: peelDecodeNonEmptyString(from: container, forKey: .accountsError),
            error: peelDecodeLossy(PeelUsageError.self, from: container, forKey: .error),
            updatedAt: peelDecodeISO8601Date(from: container, forKey: .updatedAt),
            allowanceUpdatedAt: peelDecodeISO8601Date(from: container, forKey: .allowanceUpdatedAt))
    }
}

nonisolated public enum PeelUsageSnapshotError: Error, Codable, Equatable, Sendable, LocalizedError {
    case invalidJSON
    case malformedPayload(String)
    case invalidRootField(String)
    case malformedTimestamp(field: String, value: String)
    case unsupportedSchemaVersion(Int)
    case duplicateProviderID(String)

    public nonisolated var errorDescription: String? {
        switch self {
        case .invalidJSON:
            "The dashboard response is not valid JSON."
        case let .malformedPayload(reason):
            "The dashboard response is malformed: \(reason)"
        case let .invalidRootField(field):
            "The dashboard response has an invalid root field: \(field)"
        case let .malformedTimestamp(field, value):
            "The dashboard response has an invalid timestamp for \(field): \(value)"
        case let .unsupportedSchemaVersion(version):
            "Unsupported dashboard schema version: \(version)"
        case let .duplicateProviderID(id):
            "The dashboard response contains duplicate provider id: \(id)"
        }
    }
}

/// Whether every provider row in a dashboard response could be read.
nonisolated public enum PeelUsageDecodeHealth: Equatable, Sendable {
    case complete
    /// The producer returned no provider rows, which is a real empty selection.
    case emptySelection
    /// Some rows were unreadable; the readable rows are kept and the rest are counted.
    case partial(rejected: Int)
    /// Rows were returned but none could be read. This is an incompatible helper, never "no providers".
    case incompatible(rejected: Int)
}

nonisolated public struct PeelUsageSnapshot: Codable, Equatable, Sendable {
    nonisolated public static let supportedSchemaVersion = 1
    nonisolated public static let maximumReportedRejectedIDs = 8

    public let schemaVersion: Int
    public let generatedAt: Date
    public let staleAfterSeconds: Int
    public let providers: [PeelUsageProvider]
    /// Provider rows present in the response that could not be decoded. Not encoded.
    public let rejectedProviderCount: Int
    /// Safe identifiers of up to `maximumReportedRejectedIDs` rejected rows, when they had one.
    public let rejectedProviderIDs: [String]

    public nonisolated init(
        schemaVersion: Int = PeelUsageSnapshot.supportedSchemaVersion,
        generatedAt: Date,
        staleAfterSeconds: Int,
        providers: [PeelUsageProvider],
        rejectedProviderCount: Int = 0,
        rejectedProviderIDs: [String] = [])
    {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.staleAfterSeconds = staleAfterSeconds
        self.providers = providers
        self.rejectedProviderCount = max(0, rejectedProviderCount)
        self.rejectedProviderIDs = Array(rejectedProviderIDs.prefix(Self.maximumReportedRejectedIDs))
    }

    public nonisolated var decodeHealth: PeelUsageDecodeHealth {
        switch (providers.isEmpty, rejectedProviderCount > 0) {
        case (true, false): .emptySelection
        case (true, true): .incompatible(rejected: rejectedProviderCount)
        case (false, true): .partial(rejected: rejectedProviderCount)
        case (false, false): .complete
        }
    }

    public nonisolated init(jsonData: Data) throws {
        self = try PeelUsageSnapshotParser.parse(jsonData)
    }

    public nonisolated init(data: Data) throws {
        self = try PeelUsageSnapshotParser.parse(data)
    }

    public nonisolated init(json: String) throws {
        self = try PeelUsageSnapshotParser.parse(json)
    }

    /// Age in seconds at the supplied clock instant. A future generatedAt
    /// produces a negative age, which remains useful diagnostic information.
    public nonisolated func age(at now: Date = .now) -> TimeInterval {
        now.timeIntervalSince(generatedAt)
    }

    /// True at or after the producer's staleness deadline.
    public nonisolated func isStale(at now: Date = .now) -> Bool {
        age(at: now) >= TimeInterval(staleAfterSeconds)
    }

    public nonisolated func isFresh(at now: Date = .now) -> Bool {
        !isStale(at: now)
    }

    public nonisolated var isStale: Bool { isStale(at: .now) }
    public nonisolated var isFresh: Bool { !isStale }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case generatedAt
        case staleAfterSeconds
        case providers
    }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion: Int
        do {
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        } catch {
            throw PeelUsageSnapshotError.invalidRootField("schemaVersion")
        }
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw PeelUsageSnapshotError.unsupportedSchemaVersion(schemaVersion)
        }

        let generatedAtString: String
        do {
            generatedAtString = try container.decode(String.self, forKey: .generatedAt)
        } catch {
            throw PeelUsageSnapshotError.invalidRootField("generatedAt")
        }
        guard let generatedAt = peelISO8601Date(from: generatedAtString) else {
            throw PeelUsageSnapshotError.malformedTimestamp(field: "generatedAt", value: generatedAtString)
        }

        let staleAfterSeconds: Int
        do {
            staleAfterSeconds = try container.decode(Int.self, forKey: .staleAfterSeconds)
        } catch {
            throw PeelUsageSnapshotError.invalidRootField("staleAfterSeconds")
        }
        guard staleAfterSeconds >= 0 else {
            throw PeelUsageSnapshotError.invalidRootField("staleAfterSeconds")
        }

        let rawProviders: [PeelRejectableProvider]
        do {
            rawProviders = try container.decode([PeelRejectableProvider].self, forKey: .providers)
        } catch {
            throw PeelUsageSnapshotError.invalidRootField("providers")
        }

        var seenProviderIDs = Set<String>()
        var providers: [PeelUsageProvider] = []
        var rejectedCount = 0
        var rejectedIDs: [String] = []
        providers.reserveCapacity(rawProviders.count)
        for raw in rawProviders {
            guard let provider = raw.value else {
                // Count every unreadable row so an incompatible helper is never mistaken for an
                // empty provider selection.
                rejectedCount += 1
                if let id = raw.rejectedID, rejectedIDs.count < Self.maximumReportedRejectedIDs {
                    rejectedIDs.append(id)
                }
                continue
            }
            guard seenProviderIDs.insert(provider.id).inserted else {
                throw PeelUsageSnapshotError.duplicateProviderID(provider.id)
            }
            providers.append(provider)
        }
        self.init(
            schemaVersion: schemaVersion,
            generatedAt: generatedAt,
            staleAfterSeconds: staleAfterSeconds,
            providers: providers,
            rejectedProviderCount: rejectedCount,
            rejectedProviderIDs: rejectedIDs)
    }
}

/// Pure data parser for CodexBar's dashboard-v1 JSON response. It does not
/// perform transport, credential, keychain, process, or account access.
nonisolated public enum PeelUsageSnapshotParser {
    public nonisolated static func parse(_ data: Data) throws -> PeelUsageSnapshot {
        let rootObject: Any
        do {
            rootObject = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw PeelUsageSnapshotError.invalidJSON
        }
        guard rootObject is [String: Any] else {
            throw PeelUsageSnapshotError.malformedPayload("The root value must be a JSON object.")
        }

        do {
            return try JSONDecoder().decode(PeelUsageSnapshot.self, from: data)
        } catch let error as PeelUsageSnapshotError {
            throw error
        } catch let error as DecodingError {
            throw PeelUsageSnapshotError.malformedPayload(peelDecodingDescription(error))
        } catch {
            throw PeelUsageSnapshotError.malformedPayload(error.localizedDescription)
        }
    }

    public nonisolated static func parse(_ json: String) throws -> PeelUsageSnapshot {
        try parse(Data(json.utf8))
    }
}

nonisolated private struct PeelLossy<Value: Decodable & Sendable>: Decodable {
    nonisolated let value: Value?

    nonisolated init(from decoder: Decoder) {
        value = try? Value(from: decoder)
    }
}

/// A provider row that may be unreadable. When it is, a safe identifier is kept for diagnostics only.
nonisolated private struct PeelRejectableProvider: Decodable {
    nonisolated let value: PeelUsageProvider?
    nonisolated let rejectedID: String?

    private enum CodingKeys: String, CodingKey {
        case id
    }

    nonisolated init(from decoder: Decoder) {
        if let provider = try? PeelUsageProvider(from: decoder) {
            value = provider
            rejectedID = nil
            return
        }
        value = nil
        let raw = (try? decoder.container(keyedBy: CodingKeys.self))
            .flatMap { try? $0.decodeIfPresent(String.self, forKey: .id) }
        rejectedID = raw.flatMap(peelSafeProviderID)
    }
}

/// Provider identifiers shown in diagnostics are limited to the helper's own `[a-z0-9_-]` shape.
public nonisolated func peelSafeProviderID(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...32).contains(trimmed.utf8.count),
          trimmed.unicodeScalars.allSatisfy({ scalar in
              ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "-" || scalar == "_"
          })
    else { return nil }
    return trimmed
}

/// Model display labels. Local runtimes may report a model file path or URL; only its final component
/// is kept so a path or endpoint never reaches the UI or a paired device. Labels are bounded to 64
/// characters and may therefore be shared by distinct models; group by `peelModelKey` instead.
public nonisolated func peelSanitizedModelID(_ raw: String) -> String? {
    guard var name = peelModelIdentity(raw) else { return nil }
    if peelLooksLikePathOrURL(name) {
        name = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
    }
    name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return nil }
    return String(name.prefix(64))
}

/// The producer's full model label without control characters. Owner-local only: never displayed or sent.
nonisolated func peelModelIdentity(_ raw: String) -> String? {
    let scalars = raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
    let identity = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
    return identity.isEmpty ? nil : identity
}

/// Stable model key, identical to CodexBar's dashboard `modelKey`: the identity when bounded and
/// path-free, otherwise `sha256:` plus 16 hex digits of a domain-separated digest of the full identity.
nonisolated func peelModelKey(_ identity: String) -> String {
    let model = peelModelQualification(identity).model
    if identity.count <= 64, !peelLooksLikePathOrURL(model) {
        return identity
    }
    return "sha256:" + String(peelModelDigestHex(identity).prefix(16))
}

nonisolated func peelModelDigestHex(_ value: String) -> String {
    SHA256.hash(data: Data(("peel-model-id-v1\n" + value).utf8)).map { String(format: "%02x", $0) }.joined()
}

nonisolated func peelIsSafeModelKey(_ key: String) -> Bool {
    (1...80).contains(key.count)
        && !peelLooksLikePathOrURL(peelModelQualification(key).model)
        && key.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
}

nonisolated func peelLooksLikePathOrURL(_ name: String) -> Bool {
    name.hasPrefix("/") || name.hasPrefix("~") || name.hasPrefix("./") || name.hasPrefix("../")
        || name.contains("\\") || name.contains("://")
}

nonisolated func peelKnownLocalProviderID(_ raw: String) -> String? {
    let id = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return ["oss", "ollama", "lmstudio"].contains(id) ? id : nil
}

/// Parses CodexBar's provider-qualified model keys (`model-provider:<token>/<model>`), written for Codex
/// sessions whose structured `model_provider` was a built-in local provider or a custom provider.
nonisolated func peelModelQualification(_ identity: String) -> (
    endpoint: PeelModelEndpoint, localProviderID: String?, model: String)
{
    let prefix = "model-provider:"
    guard identity.hasPrefix(prefix) else { return (.unspecified, nil, identity) }
    let rest = identity.dropFirst(prefix.count)
    guard let slash = rest.firstIndex(of: "/"), slash > rest.startIndex else { return (.unspecified, nil, identity) }
    let token = String(rest[..<slash])
    let model = String(rest[rest.index(after: slash)...])
    if let local = peelKnownLocalProviderID(token) {
        return (.local, local, model)
    }
    return (.custom, nil, model)
}

private nonisolated func peelNormalizedTokenCount(_ value: Int?) -> Int? {
    guard let value, value >= 0 else { return nil }
    return value
}

private nonisolated func peelDecodeTokenCount<Key: CodingKey>(
    from container: KeyedDecodingContainer<Key>,
    forKey key: Key) -> Int?
{
    peelNormalizedTokenCount(peelDecodeLossy(Int.self, from: container, forKey: key))
}

private nonisolated func peelDecodeLossy<Value: Decodable, Key: CodingKey>(
    _ type: Value.Type,
    from container: KeyedDecodingContainer<Key>,
    forKey key: Key) -> Value?
{
    do {
        return try container.decodeIfPresent(type, forKey: key)
    } catch {
        return nil
    }
}

private nonisolated func peelDecodePercent<Key: CodingKey>(
    from container: KeyedDecodingContainer<Key>,
    forKey key: Key) -> Double?
{
    guard let value = peelDecodeLossy(Double.self, from: container, forKey: key) else {
        return nil
    }
    return peelNormalizedPercent(value)
}

private nonisolated func peelDecodeFiniteDouble<Key: CodingKey>(
    from container: KeyedDecodingContainer<Key>,
    forKey key: Key) -> Double?
{
    guard let value = peelDecodeLossy(Double.self, from: container, forKey: key), value.isFinite else {
        return nil
    }
    return value
}

private nonisolated func peelDecodeNonNegativeDouble<Key: CodingKey>(
    from container: KeyedDecodingContainer<Key>,
    forKey key: Key) -> Double?
{
    guard let value = peelDecodeFiniteDouble(from: container, forKey: key), value >= 0 else {
        return nil
    }
    return value
}

private nonisolated func peelDecodeFraction<Key: CodingKey>(
    from container: KeyedDecodingContainer<Key>,
    forKey key: Key) -> Double?
{
    guard let value = peelDecodeFiniteDouble(from: container, forKey: key), (0...1).contains(value) else {
        return nil
    }
    return value
}

private nonisolated func peelDecodeNonEmptyString<Key: CodingKey>(
    from container: KeyedDecodingContainer<Key>,
    forKey key: Key) -> String?
{
    guard let value = peelDecodeLossy(String.self, from: container, forKey: key) else {
        return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private nonisolated func peelNormalizedNonNegativeDouble(_ value: Double?) -> Double? {
    guard let value, value.isFinite, value >= 0 else { return nil }
    return value
}

private nonisolated func peelNormalizedFraction(_ value: Double?) -> Double? {
    guard let value, value.isFinite, (0...1).contains(value) else { return nil }
    return value
}

private nonisolated func peelNormalizedPercent(_ value: Double?) -> Double? {
    guard let value, value.isFinite, (0...100).contains(value) else {
        return nil
    }
    return value
}

private nonisolated func peelDecodeISO8601Date<Key: CodingKey>(
    from container: KeyedDecodingContainer<Key>,
    forKey key: Key) -> Date?
{
    guard let value = peelDecodeLossy(String.self, from: container, forKey: key) else {
        return nil
    }
    return peelISO8601Date(from: value)
}

private nonisolated func peelISO8601Date(from value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) {
        return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
}

private nonisolated func peelDecodingError(_ decoder: Decoder, _ description: String) -> DecodingError {
    .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: description))
}

private nonisolated func peelDecodingDescription(_ error: DecodingError) -> String {
    switch error {
    case let .typeMismatch(_, context), let .valueNotFound(_, context), let .keyNotFound(_, context):
        context.debugDescription
    case let .dataCorrupted(context):
        context.debugDescription
    @unknown default:
        "The JSON value could not be decoded."
    }
}
