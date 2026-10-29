import CodexBarCore
import Crypto
import Foundation

/// How much account identity a dashboard snapshot exposes. Dashboard commands
/// default to `.full`; `.redacted` remains available as an explicit privacy mode.
enum DashboardIdentityMode: String, Equatable, Sendable {
    case none
    case redacted
    case full
}

enum DashboardSnapshotDetail: String, Equatable, Sendable {
    case full
    case shell
}

struct DashboardSnapshotPayload: Encodable {
    let schemaVersion: Int
    let generatedAt: Date
    let staleAfterSeconds: Int
    let host: DashboardHostPayload
    let providers: [DashboardProviderPayload]
}

struct DashboardHostPayload: Encodable {
    let codexBarVersion: String?
    let refreshIntervalSeconds: Int

    private enum CodingKeys: String, CodingKey {
        case codexBarVersion
        case refreshIntervalSeconds
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.codexBarVersion, forKey: .codexBarVersion)
        try container.encode(self.refreshIntervalSeconds, forKey: .refreshIntervalSeconds)
    }
}

struct DashboardProviderPayload: Encodable {
    let id: String
    let name: String
    let enabled: Bool
    let source: String
    let status: DashboardStatusPayload?
    let identity: DashboardIdentityPayload?
    let windows: [DashboardWindowPayload]
    let credits: DashboardCreditsPayload?
    let cost: DashboardCostPayload?
    let display: DashboardDisplayPayload
    let error: ProviderErrorPayload?
    let updatedAt: Date?
    /// Timestamp of the allowance observation, independent of status, credits and cost freshness.
    let allowanceUpdatedAt: Date?
    /// Per-account entries from a local multi-account source (today: claude-swap).
    /// Additive schema-v1 data; absent for providers without such a source.
    let accounts: [DashboardAccountPayload]?
    /// Row-local failure of the multi-account source; the ambient provider row stays intact.
    let accountsError: String?
    private let detail: DashboardSnapshotDetail

    init(
        id: String,
        name: String,
        enabled: Bool,
        source: String,
        status: DashboardStatusPayload?,
        identity: DashboardIdentityPayload?,
        windows: [DashboardWindowPayload],
        credits: DashboardCreditsPayload?,
        cost: DashboardCostPayload?,
        display: DashboardDisplayPayload,
        error: ProviderErrorPayload?,
        updatedAt: Date?,
        accounts: [DashboardAccountPayload]?,
        accountsError: String?,
        detail: DashboardSnapshotDetail = .full,
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
        self.display = display
        self.error = error
        self.updatedAt = updatedAt
        self.allowanceUpdatedAt = allowanceUpdatedAt
        self.accounts = accounts
        self.accountsError = accountsError
        self.detail = detail
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
        case display
        case error
        case updatedAt
        case allowanceUpdatedAt
        case accounts
        case accountsError
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.name, forKey: .name)
        try container.encode(self.enabled, forKey: .enabled)
        try container.encode(self.display, forKey: .display)
        guard self.detail == .full else { return }
        try container.encode(self.source, forKey: .source)
        try container.encode(self.status, forKey: .status)
        try container.encode(self.identity, forKey: .identity)
        try container.encode(self.windows, forKey: .windows)
        try container.encode(self.credits, forKey: .credits)
        try container.encode(self.cost, forKey: .cost)
        try container.encode(self.error, forKey: .error)
        try container.encode(self.updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(self.allowanceUpdatedAt, forKey: .allowanceUpdatedAt)
        try container.encodeIfPresent(self.accounts, forKey: .accounts)
        try container.encodeIfPresent(self.accountsError, forKey: .accountsError)
    }
}

struct DashboardAccountPayload: Encodable {
    let id: String
    let label: String
    let active: Bool
    let identity: DashboardIdentityPayload?
    let windows: [DashboardWindowPayload]
    let pace: ProviderPacePayload?
    let error: String?
    let updatedAt: Date?

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

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.label, forKey: .label)
        try container.encode(self.active, forKey: .active)
        try container.encode(self.identity, forKey: .identity)
        try container.encode(self.windows, forKey: .windows)
        try container.encode(self.pace, forKey: .pace)
        try container.encode(self.error, forKey: .error)
        try container.encode(self.updatedAt, forKey: .updatedAt)
    }
}

struct DashboardStatusPayload: Encodable {
    let level: String
    let label: String
    let updatedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case level
        case label
        case updatedAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.level, forKey: .level)
        try container.encode(self.label, forKey: .label)
        try container.encode(self.updatedAt, forKey: .updatedAt)
    }
}

struct DashboardIdentityPayload: Encodable {
    let accountEmail: String?
    let plan: String?
    /// Stable, provider-scoped pseudonym for local history; never an authorization credential.
    let accountKey: String?

    init(accountEmail: String?, plan: String?, accountKey: String? = nil) {
        self.accountEmail = accountEmail
        self.plan = plan
        self.accountKey = accountKey
    }

    static func historyAccountKey(
        providerID: String,
        email: String?,
        accountID: String? = nil,
        organization: String? = nil) -> String?
    {
        let accountID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let owner: String
        if let accountID, !accountID.isEmpty, accountID != "unknown", !accountID.hasPrefix("redacted") {
            guard accountID.utf8.count <= 512 else { return nil }
            owner = "id:" + accountID
        } else if let email,
                  let at = email.lastIndex(of: "@"), at > email.startIndex,
                  email.index(after: at) < email.endIndex,
                  !email.hasPrefix("redacted@"), email.utf8.count <= 512
        {
            owner = "email:" + email
        } else {
            return nil
        }
        let organization = organization?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard organization.utf8.count <= 512,
              let scope = try? JSONEncoder().encode(["peel-usage-account-v1", providerID, owner, organization])
        else { return nil }
        return "sha256:" + SHA256.hash(data: scope).map { String(format: "%02x", $0) }.joined()
    }

    private enum CodingKeys: String, CodingKey {
        case accountEmail
        case plan
        case accountKey
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.accountEmail, forKey: .accountEmail)
        try container.encode(self.plan, forKey: .plan)
        try container.encodeIfPresent(self.accountKey, forKey: .accountKey)
    }
}

struct DashboardWindowPayload: Encodable {
    let kind: String
    let label: String
    let usedPercent: Double
    let remainingPercent: Double
    let resetAt: Date?
    /// Whether a display client should skip this window. The producer sets it when the window belongs
    /// to a model family that reports no usage at all, which a client cannot work out on its own
    /// because a zero `usedPercent` also stands for a lane whose usage the provider never reported.
    /// Additive schema-v1 extension: the key appears only when it is `true`, so every payload that
    /// carries no idle window is byte-identical to the previous shape.
    let idle: Bool

    init(
        kind: String,
        label: String,
        usedPercent: Double,
        remainingPercent: Double,
        resetAt: Date?,
        idle: Bool = false)
    {
        self.kind = kind
        self.label = label
        self.usedPercent = usedPercent
        self.remainingPercent = remainingPercent
        self.resetAt = resetAt
        self.idle = idle
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case label
        case usedPercent
        case remainingPercent
        case resetAt
        case idle
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.kind, forKey: .kind)
        try container.encode(self.label, forKey: .label)
        try container.encode(self.usedPercent, forKey: .usedPercent)
        try container.encode(self.remainingPercent, forKey: .remainingPercent)
        try container.encode(self.resetAt, forKey: .resetAt)
        if self.idle {
            try container.encode(true, forKey: .idle)
        }
    }
}

struct DashboardCreditsPayload: Encodable {
    let remaining: Double
    let unit: String
}

struct DashboardCostPayload: Encodable {
    let todayUSD: Double?
    let last30DaysUSD: Double?
    /// Additive schema-v1 detail. Every key below is omitted when the cost source did not establish
    /// it, so payloads without token detail stay byte-identical to the previous shape. Token counts are
    /// observations from this Mac's local logs (or a provider's own dashboard for `source == "web"`);
    /// they are never account quota and never a billing receipt.
    let source: String?
    let updatedAt: Date?
    let historyDays: Int?
    let historyCoverageIsEstablished: Bool?
    let provenance: String?
    let coverage: CostUsageCoverageCounts?
    let meteredCostUSD: Double?
    let todayTokens: DashboardTokenPeriodPayload?
    let historyTokens: DashboardTokenPeriodPayload?

    init(
        todayUSD: Double?,
        last30DaysUSD: Double?,
        source: String? = nil,
        updatedAt: Date? = nil,
        historyDays: Int? = nil,
        historyCoverageIsEstablished: Bool? = nil,
        provenance: String? = nil,
        coverage: CostUsageCoverageCounts? = nil,
        meteredCostUSD: Double? = nil,
        todayTokens: DashboardTokenPeriodPayload? = nil,
        historyTokens: DashboardTokenPeriodPayload? = nil)
    {
        self.todayUSD = todayUSD
        self.last30DaysUSD = last30DaysUSD
        self.source = source
        self.updatedAt = updatedAt
        self.historyDays = historyDays
        self.historyCoverageIsEstablished = historyCoverageIsEstablished
        self.provenance = provenance
        self.coverage = coverage
        self.meteredCostUSD = meteredCostUSD
        self.todayTokens = todayTokens
        self.historyTokens = historyTokens
    }

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

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.todayUSD, forKey: .todayUSD)
        try container.encode(self.last30DaysUSD, forKey: .last30DaysUSD)
        try container.encodeIfPresent(self.source, forKey: .source)
        try container.encodeIfPresent(self.updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(self.historyDays, forKey: .historyDays)
        try container.encodeIfPresent(self.historyCoverageIsEstablished, forKey: .historyCoverageIsEstablished)
        try container.encodeIfPresent(self.provenance, forKey: .provenance)
        try container.encodeIfPresent(self.coverage, forKey: .coverage)
        try container.encodeIfPresent(self.meteredCostUSD, forKey: .meteredCostUSD)
        try container.encodeIfPresent(self.todayTokens, forKey: .todayTokens)
        try container.encodeIfPresent(self.historyTokens, forKey: .historyTokens)
    }
}

/// Token classes and a bounded model breakdown for one cost period. A `nil` class means the source
/// did not establish it, never zero. Model rows carry no project, path or session detail.
struct DashboardTokenPeriodPayload: Encodable {
    static let maximumModels = 8

    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadTokens: Int?
    let cacheCreationTokens: Int?
    let reasoningTokens: Int?
    let totalTokens: Int?
    let costUSD: Double?
    let models: [DashboardModelUsagePayload]
    /// Distinct models beyond `maximumModels`; their tokens remain in the period totals.
    let omittedModelCount: Int

    private enum CodingKeys: String, CodingKey {
        case inputTokens
        case outputTokens
        case cacheReadTokens
        case cacheCreationTokens
        case reasoningTokens
        case totalTokens
        case costUSD = "totalCost"
        case models
        case omittedModelCount
    }

    var hasTokenData: Bool {
        self.inputTokens != nil || self.outputTokens != nil || self.cacheReadTokens != nil
            || self.cacheCreationTokens != nil || self.reasoningTokens != nil || self.totalTokens != nil
            || !self.models.isEmpty
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.inputTokens, forKey: .inputTokens)
        try container.encodeIfPresent(self.outputTokens, forKey: .outputTokens)
        try container.encodeIfPresent(self.cacheReadTokens, forKey: .cacheReadTokens)
        try container.encodeIfPresent(self.cacheCreationTokens, forKey: .cacheCreationTokens)
        try container.encodeIfPresent(self.reasoningTokens, forKey: .reasoningTokens)
        try container.encodeIfPresent(self.totalTokens, forKey: .totalTokens)
        try container.encodeIfPresent(self.costUSD, forKey: .costUSD)
        try container.encode(self.models, forKey: .models)
        try container.encode(self.omittedModelCount, forKey: .omittedModelCount)
    }
}

/// One model's observed tokens. `cost` is absent when the model has no known price (for example a
/// local or custom-endpoint model); its tokens are still reported. `modelKey` is the stable identity
/// (the stored label, or an opaque digest when that label is long or path-like); `modelName` is a
/// bounded display label that may be shared, so consumers must group by `modelKey`.
struct DashboardModelUsagePayload: Encodable, Equatable {
    var modelName: String
    let modelKey: String
    let totalTokens: Int?
    let costUSD: Double?
    /// `local` or `custom` when a Codex session recorded a non-OpenAI `model_provider`; absent otherwise.
    var endpoint: String?
    /// Codex's fixed built-in local provider ID; never a custom provider ID.
    var localProvider: String?

    private enum CodingKeys: String, CodingKey {
        case modelName
        case modelKey
        case totalTokens
        case costUSD = "cost"
        case endpoint
        case localProvider
    }

    init(
        modelName: String,
        modelKey: String,
        totalTokens: Int?,
        costUSD: Double?,
        endpoint: String? = nil,
        localProvider: String? = nil)
    {
        self.modelName = modelName
        self.modelKey = modelKey
        self.totalTokens = totalTokens
        self.costUSD = costUSD
        self.endpoint = endpoint
        self.localProvider = localProvider
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.modelName, forKey: .modelName)
        try container.encode(self.modelKey, forKey: .modelKey)
        try container.encodeIfPresent(self.totalTokens, forKey: .totalTokens)
        try container.encodeIfPresent(self.costUSD, forKey: .costUSD)
        try container.encodeIfPresent(self.endpoint, forKey: .endpoint)
        try container.encodeIfPresent(self.localProvider, forKey: .localProvider)
    }
}

struct DashboardDisplayPayload: Encodable {
    let accentColor: String
    let sortKey: Int
    let priority: String
}
