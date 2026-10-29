//
//  PeelPeerAgentUsageWire.swift
//  Bounded usage summary a paired owner Mac shares with its viewers.
//
//  Two metric classes stay separate on the wire and in the viewer:
//  - `quotas`: account plan limits as reported by the owner's provider
//    adapters. A quota is one account-wide number; viewers never add quota
//    percentages from different Macs together.
//  - `observed`: tokens/models measured from THIS owner Mac's local logs
//    (all accounts used on that Mac). These are per-Mac observations, never
//    account totals; viewers never add them to another Mac's observations
//    and never attach them to an account tag.
//
//  The raw account key/email never appears. `accountTag` is an HMAC under the
//  specific pairing's PSK, so only the two paired Macs can compare it.
//  `PeelPeerUsageLocalInput` is the narrow projection seam; it does not
//  depend on the usage store's types.
//

import Foundation

nonisolated public enum PeelPeerUsageStatus: String, Codable, Equatable, Sendable {
    case ok, stale, authNeeded, error, unsupported, disabled, notCollected, unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PeelPeerUsageStatus(rawValue: raw) ?? .unknown
    }
}

nonisolated public struct PeelPeerUsageWindow: Codable, Equatable, Sendable {
    public var kind: String
    public var label: String
    /// 0...100, nil when the owner has no percentage (shown as unavailable).
    public var usedPercent: Double?
    /// Unix seconds.
    public var resetAt: Double?

    public init(kind: String, label: String, usedPercent: Double?, resetAt: Double?) {
        self.kind = kind
        self.label = label
        self.usedPercent = usedPercent
        self.resetAt = resetAt
    }

    func validate() throws {
        guard PeelPeerAgentText.isIdentifier(kind, maxBytes: 16),
              PeelPeerAgentText.isValid(label, maxBytes: 24) else {
            throw PeelPeerAgentContractError.invalidField("window")
        }
        if let usedPercent, !(usedPercent.isFinite && (0...100).contains(usedPercent)) {
            throw PeelPeerAgentContractError.invalidField("usedPercent")
        }
        if let resetAt, !(resetAt.isFinite && resetAt >= 0) {
            throw PeelPeerAgentContractError.invalidField("resetAt")
        }
    }
}

nonisolated public struct PeelPeerQuota: Codable, Equatable, Sendable {
    public var provider: String
    public var name: String
    public var status: PeelPeerUsageStatus
    /// Short reason code, e.g. "silent_auth_blocked", "timed_out".
    public var reason: String?
    public var windows: [PeelPeerUsageWindow]
    /// Age of the owner's quota sample at send time (owner clock).
    public var ageSeconds: Double?
    public var plan: String?
    public var accountTag: String?

    public init(provider: String, name: String, status: PeelPeerUsageStatus, reason: String? = nil,
                windows: [PeelPeerUsageWindow], ageSeconds: Double?, plan: String?, accountTag: String?) {
        self.provider = provider
        self.name = name
        self.status = status
        self.reason = reason
        self.windows = windows
        self.ageSeconds = ageSeconds
        self.plan = plan
        self.accountTag = accountTag
    }

    func validate() throws {
        guard PeelPeerAgentText.isIdentifier(provider, maxBytes: 32),
              PeelPeerAgentText.isValid(name, maxBytes: 32),
              windows.count <= 3 else { throw PeelPeerAgentContractError.invalidField("quota") }
        try windows.forEach { try $0.validate() }
        if let reason, !PeelPeerAgentText.isIdentifier(reason, maxBytes: 24) {
            throw PeelPeerAgentContractError.invalidField("reason")
        }
        if let ageSeconds, !(ageSeconds.isFinite && ageSeconds >= 0) {
            throw PeelPeerAgentContractError.invalidField("ageSeconds")
        }
        if let plan, !PeelPeerAgentText.isValid(plan, maxBytes: 24) {
            throw PeelPeerAgentContractError.invalidField("plan")
        }
        if let accountTag, !PeelPeerAgentText.isToken(accountTag) {
            throw PeelPeerAgentContractError.invalidField("accountTag")
        }
    }
}

nonisolated public struct PeelPeerObservedModel: Codable, Equatable, Sendable {
    public var id: String
    public var totalTokens: Int?
    /// False when the producer had no price for this model (shown "price unknown").
    public var priceKnown: Bool?

    public init(id: String, totalTokens: Int?, priceKnown: Bool? = nil) {
        self.id = id
        self.totalTokens = totalTokens
        self.priceKnown = priceKnown
    }
}

/// Tokens measured from the owner Mac's own local logs for one provider and
/// period. Every count is optional: unknown is not zero.
nonisolated public struct PeelPeerObservedUsage: Codable, Equatable, Sendable {
    public enum Period: String, Codable, Equatable, Sendable { case today, history }
    public static let maximumModels = 5

    public var provider: String
    public var period: Period
    /// 1 for today; the producer's own history window otherwise (never assumed).
    public var days: Int
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheCreationTokens: Int?
    public var reasoningTokens: Int?
    public var totalTokens: Int?
    public var models: [PeelPeerObservedModel]
    /// Models not listed (their tokens are still in the totals).
    public var omittedModelCount: Int
    /// API-price estimate for the period, when the producer had prices.
    public var estimatedCostUSD: Double?
    /// "listPriceEstimate", "vendorMetered", "mixed" or "unknown".
    public var provenance: String?
    /// False/nil when the owner's log coverage for the window is partial or unknown.
    public var coverageEstablished: Bool?
    /// Age of the producer's observation at send time (owner clock).
    public var ageSeconds: Double?

    public init(provider: String, period: Period, days: Int, inputTokens: Int? = nil, outputTokens: Int? = nil,
                cacheReadTokens: Int? = nil, cacheCreationTokens: Int? = nil, reasoningTokens: Int? = nil,
                totalTokens: Int? = nil, models: [PeelPeerObservedModel] = [], omittedModelCount: Int = 0,
                estimatedCostUSD: Double? = nil, provenance: String? = nil, coverageEstablished: Bool? = nil,
                ageSeconds: Double? = nil) {
        self.provider = provider
        self.period = period
        self.days = days
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.reasoningTokens = reasoningTokens
        self.totalTokens = totalTokens
        self.models = models
        self.omittedModelCount = omittedModelCount
        self.estimatedCostUSD = estimatedCostUSD
        self.provenance = provenance
        self.coverageEstablished = coverageEstablished
        self.ageSeconds = ageSeconds
    }

    var counts: [Int?] { [inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens, reasoningTokens, totalTokens] }

    func validate() throws {
        guard PeelPeerAgentText.isIdentifier(provider, maxBytes: 32), models.count <= Self.maximumModels,
              (1...3_660).contains(days), omittedModelCount >= 0,
              period != .today || days == 1 else {
            throw PeelPeerAgentContractError.invalidField("observed")
        }
        for count in counts {
            if let count, count < 0 { throw PeelPeerAgentContractError.invalidField("tokens") }
        }
        for model in models {
            guard PeelPeerAgentText.isValid(model.id, maxBytes: 64),
                  (model.totalTokens ?? 0) >= 0 else { throw PeelPeerAgentContractError.invalidField("model") }
        }
        if let estimatedCostUSD, !(estimatedCostUSD.isFinite && estimatedCostUSD >= 0) {
            throw PeelPeerAgentContractError.invalidField("estimatedCostUSD")
        }
        if let provenance, !PeelPeerAgentText.isValid(provenance, maxBytes: 24) {
            throw PeelPeerAgentContractError.invalidField("provenance")
        }
        if let ageSeconds, !(ageSeconds.isFinite && ageSeconds >= 0) {
            throw PeelPeerAgentContractError.invalidField("ageSeconds")
        }
    }
}

nonisolated public struct PeelPeerUsageSummary: Codable, Equatable, Sendable {
    public static let messageType = "peelPeerUsage"
    public static let version = 1
    public static let maximumQuotas = 16
    public static let maximumObserved = 4
    public static let budgetBytes = 11_264

    public var type: String
    public var v: Int
    public var bootEpoch: UUID
    public var revision: UInt64
    public var quotas: [PeelPeerQuota]
    public var observed: [PeelPeerObservedUsage]
    /// Rows the owner had but could not fit; never silently dropped.
    public var omittedQuotas: Int
    public var omittedObserved: Int

    public init(bootEpoch: UUID, revision: UInt64, quotas: [PeelPeerQuota], observed: [PeelPeerObservedUsage],
                omittedQuotas: Int = 0, omittedObserved: Int = 0) {
        type = Self.messageType
        v = Self.version
        self.bootEpoch = bootEpoch
        self.revision = revision
        self.quotas = quotas
        self.observed = observed
        self.omittedQuotas = omittedQuotas
        self.omittedObserved = omittedObserved
    }

    func validate() throws {
        guard type == Self.messageType else { throw PeelPeerAgentContractError.unknownType(type) }
        guard v == Self.version else { throw PeelPeerAgentContractError.unsupportedVersion(v) }
        guard quotas.count <= Self.maximumQuotas, observed.count <= Self.maximumObserved,
              omittedQuotas >= 0, omittedObserved >= 0 else {
            throw PeelPeerAgentContractError.tooManyEntries("usage")
        }
        try quotas.forEach { try $0.validate() }
        try observed.forEach { try $0.validate() }
    }
}

// MARK: - Projection seam (owner side)

/// Narrow, in-process input for the usage summary. The Host fills it from
/// the usage store; the raw `accountKey` stays in process and is converted to
/// a pair-specific tag per socket.
nonisolated public struct PeelPeerUsageLocalInput: Equatable, Sendable {
    public struct Quota: Equatable, Sendable {
        public var provider: String
        public var name: String
        public var status: PeelPeerUsageStatus
        public var reason: String?
        public var windows: [PeelPeerUsageWindow]
        public var sampledAt: Date?
        public var plan: String?
        /// Stable nonsecret account key from the usage adapter, if any.
        public var accountKey: String?

        public init(provider: String, name: String, status: PeelPeerUsageStatus, reason: String? = nil,
                    windows: [PeelPeerUsageWindow], sampledAt: Date?, plan: String?, accountKey: String?) {
            self.provider = provider
            self.name = name
            self.status = status
            self.reason = reason
            self.windows = windows
            self.sampledAt = sampledAt
            self.plan = plan
            self.accountKey = accountKey
        }
    }

    /// Observed measurement with the producer's own sample time.
    public struct Observed: Equatable, Sendable {
        public var usage: PeelPeerObservedUsage
        public var sampledAt: Date?

        public init(usage: PeelPeerObservedUsage, sampledAt: Date?) {
            self.usage = usage
            self.sampledAt = sampledAt
        }
    }

    public var quotas: [Quota]
    public var observed: [Observed]

    public init(quotas: [Quota], observed: [Observed]) {
        self.quotas = quotas
        self.observed = observed
    }

    public static let empty = PeelPeerUsageLocalInput(quotas: [], observed: [])
}

nonisolated public enum PeelPeerUsageProjection {
    public static let accountTagDomain = "peel.usage.account.v1"

    /// Builds one bounded summary for one socket. `pairKey` is that pairing's
    /// PSK; it is used only to derive tags and never leaves the process.
    /// Deterministic size bound: first trims model lists, then observed rows,
    /// then extra quota windows, then quota rows (from the end), counting
    /// everything omitted. Quota and observed scopes are never merged.
    public static func summary(_ input: PeelPeerUsageLocalInput, pairKey: Data, bootEpoch: UUID,
                               revision: UInt64, now: Date) -> PeelPeerUsageSummary {
        var quotas = input.quotas.compactMap { quota(from: $0, pairKey: pairKey, now: now) }
        var observed = input.observed.compactMap { observedRow(from: $0, now: now) }
        var omittedQuotas = max(0, quotas.count - PeelPeerUsageSummary.maximumQuotas)
        var omittedObserved = max(0, observed.count - PeelPeerUsageSummary.maximumObserved)
        quotas = Array(quotas.prefix(PeelPeerUsageSummary.maximumQuotas))
        observed = Array(observed.prefix(PeelPeerUsageSummary.maximumObserved))

        func make() -> PeelPeerUsageSummary {
            PeelPeerUsageSummary(bootEpoch: bootEpoch, revision: revision, quotas: quotas, observed: observed,
                                 omittedQuotas: omittedQuotas, omittedObserved: omittedObserved)
        }
        func fits() -> Bool {
            // Size with maximum-width counters so a later count change can't overflow.
            var probe = make()
            probe.revision = UInt64.max
            probe.omittedQuotas = Int(Int32.max)
            probe.omittedObserved = Int(Int32.max)
            return ((try? JSONEncoder().encode(probe).count) ?? Int.max) <= PeelPeerUsageSummary.budgetBytes
        }
        while !fits() {
            if let index = observed.lastIndex(where: { !$0.models.isEmpty }) {
                observed[index].models.removeLast()
                observed[index].omittedModelCount += 1
            } else if !observed.isEmpty {
                observed.removeLast()
                omittedObserved += 1
            } else if let index = quotas.lastIndex(where: { $0.windows.count > 1 }) {
                quotas[index].windows.removeLast()
            } else if !quotas.isEmpty {
                quotas.removeLast()
                omittedQuotas += 1
            } else {
                break
            }
        }
        return make()
    }

    static func quota(from quota: PeelPeerUsageLocalInput.Quota, pairKey: Data, now: Date) -> PeelPeerQuota? {
        let provider = quota.provider.lowercased()
        guard PeelPeerAgentText.isIdentifier(provider, maxBytes: 32) else { return nil }
        let name = PeelPeerAgentText.sanitize(quota.name, maxBytes: 32)
        let windows = quota.windows.prefix(3).compactMap { window -> PeelPeerUsageWindow? in
            let kind = window.kind.lowercased()
            guard PeelPeerAgentText.isIdentifier(kind, maxBytes: 16) else { return nil }
            let label = PeelPeerAgentText.sanitize(window.label, maxBytes: 24)
            let used = window.usedPercent.flatMap { $0.isFinite ? min(100, max(0, $0)) : nil }
            let reset = window.resetAt.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            return PeelPeerUsageWindow(kind: kind, label: label.isEmpty ? kind : label, usedPercent: used, resetAt: reset)
        }
        let age = quota.sampledAt.map { max(0, now.timeIntervalSince($0)) }
        let plan = quota.plan.map { PeelPeerAgentText.sanitize($0, maxBytes: 24) }.flatMap { $0.isEmpty ? nil : $0 }
        let reason = quota.reason.flatMap { PeelPeerAgentText.isIdentifier($0, maxBytes: 24) ? $0 : nil }
        return PeelPeerQuota(provider: provider, name: name.isEmpty ? provider : name, status: quota.status,
                             reason: reason, windows: Array(windows), ageSeconds: age, plan: plan,
                             accountTag: localAccountTag(provider: provider, accountKey: quota.accountKey,
                                                         pairKey: pairKey))
    }

    static func observedRow(from input: PeelPeerUsageLocalInput.Observed, now: Date) -> PeelPeerObservedUsage? {
        var copy = input.usage
        copy.provider = copy.provider.lowercased()
        let sanitizedModels = copy.models.map {
            PeelPeerObservedModel(id: PeelPeerAgentText.sanitize($0.id, maxBytes: 64), totalTokens: $0.totalTokens,
                                  priceKnown: $0.priceKnown)
        }.filter { !$0.id.isEmpty }
        copy.omittedModelCount = max(0, copy.omittedModelCount)
            + max(0, sanitizedModels.count - PeelPeerObservedUsage.maximumModels)
        copy.models = Array(sanitizedModels.prefix(PeelPeerObservedUsage.maximumModels))
        copy.provenance = copy.provenance.map { PeelPeerAgentText.sanitize($0, maxBytes: 24) }.flatMap { $0.isEmpty ? nil : $0 }
        copy.ageSeconds = input.sampledAt.map { max(0, now.timeIntervalSince($0)) }
        return (try? copy.validate()) == nil ? nil : copy
    }

    /// The tag either Mac derives for its own account on a provider under one
    /// pairing. Nil when there is no stable account key: unknown identity is
    /// never collapsed with anything.
    public static func localAccountTag(provider: String, accountKey: String?, pairKey: Data) -> String? {
        guard let key = accountKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty,
              !key.lowercased().hasPrefix("redacted"), key.lowercased() != "unknown",
              pairKey.count == 32 else { return nil }
        return PeelPeerAgentToken.pairTag(pairKey: pairKey, domain: accountTagDomain,
                                          value: provider.lowercased() + "\u{1F}" + key)
    }
}

// MARK: - Viewer presentation (pure)

/// One display line for another Mac's usage. Quota lines and observed lines
/// are separate kinds; nothing here ever adds values across Macs.
nonisolated public struct PeelPeerUsageLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case quota, observed, note }

    public var ownerHostID: UUID
    public var ownerLabel: String
    public var kind: Kind
    public var provider: String
    public var title: String
    public var detail: String
    /// Viewer-clock age of the producer sample, when known.
    public var age: TimeInterval?
    public var isProblem: Bool
}

nonisolated public enum PeelPeerUsagePresentation {
    /// - Parameters:
    ///   - localAccountTags: per owner, the tags THIS Mac derives for its own
    ///     provider accounts under that owner's pairing key.
    ///   - live: whether the owner link is currently live (otherwise lines are
    ///     marked as previous readings).
    public static func lines(ownerHostID: UUID, ownerLabel: String, summary: PeelPeerUsageSummary,
                             receivedAt: Date, live: Bool, localAccountTags: Set<String>,
                             now: Date) -> [PeelPeerUsageLine] {
        let transit = max(0, now.timeIntervalSince(receivedAt))
        var lines: [PeelPeerUsageLine] = []
        var sameAccount = 0
        for quota in summary.quotas {
            // Collapse only on a real pair-scoped tag match; nil never matches.
            if let tag = quota.accountTag, localAccountTags.contains(tag) {
                sameAccount += 1
                continue
            }
            let age = quota.ageSeconds.map { $0 + transit }
            let windowText = quota.windows.first(where: { $0.usedPercent != nil }).map { window in
                "\(window.label) · \(Int((window.usedPercent ?? 0).rounded()))% used"
            }
            let detail: String
            switch quota.status {
            case .ok, .stale:
                detail = windowText ?? "No percentage reported"
            case .authNeeded:
                detail = quota.reason == "silent_auth_blocked"
                    ? "Sign-in needed (won't prompt in the background)" : "Sign-in needed"
            case .error: detail = "Needs attention"
            case .unsupported: detail = "Not available"
            case .disabled: detail = "Disabled"
            case .notCollected: detail = "No quota reported"
            case .unknown: detail = "Unknown state"
            }
            let staleNote = (!live || quota.status == .stale) ? " · previous reading" : ""
            lines.append(PeelPeerUsageLine(ownerHostID: ownerHostID, ownerLabel: ownerLabel, kind: .quota,
                                           provider: quota.provider, title: quota.name, detail: detail + staleNote,
                                           age: age, isProblem: !(quota.status == .ok || quota.status == .stale)))
        }
        if sameAccount > 0 {
            lines.append(PeelPeerUsageLine(ownerHostID: ownerHostID, ownerLabel: ownerLabel, kind: .note,
                                           provider: "", title: "Same account",
                                           detail: sameAccount == 1
                                               ? "1 limit is the same account as This Mac (shown once, not added)"
                                               : "\(sameAccount) limits are the same accounts as This Mac (shown once, not added)",
                                           age: nil, isProblem: false))
        }
        for observed in summary.observed {
            let period = observed.period == .today ? "Today" : "Last \(observed.days) days"
            let tokens = observed.totalTokens.map { "\(compact($0)) tokens" } ?? "tokens unknown"
            let models = observed.models.prefix(2).map(\.id).joined(separator: ", ")
            var parts = ["\(period) · \(tokens)"]
            if !models.isEmpty { parts.append(models + (observed.omittedModelCount > 0 ? " +\(observed.omittedModelCount)" : "")) }
            if observed.coverageEstablished != true { parts.append("partial log coverage") }
            if observed.models.contains(where: { $0.priceKnown == false }) { parts.append("some prices unknown") }
            lines.append(PeelPeerUsageLine(ownerHostID: ownerHostID, ownerLabel: ownerLabel, kind: .observed,
                                           provider: observed.provider,
                                           title: "\(observed.provider.capitalized) · observed on \(ownerLabel)",
                                           detail: parts.joined(separator: " · ") + (live ? "" : " · previous reading"),
                                           age: observed.ageSeconds.map { $0 + transit }, isProblem: false))
        }
        if summary.omittedQuotas + summary.omittedObserved > 0 {
            lines.append(PeelPeerUsageLine(ownerHostID: ownerHostID, ownerLabel: ownerLabel, kind: .note,
                                           provider: "", title: "More on \(ownerLabel)",
                                           detail: "\(summary.omittedQuotas + summary.omittedObserved) more not shown",
                                           age: nil, isProblem: false))
        }
        return lines
    }

    static func compact(_ value: Int) -> String {
        switch value {
        case ..<1_000: return "\(value)"
        case ..<1_000_000: return String(format: "%.1fK", Double(value) / 1_000)
        case ..<1_000_000_000: return String(format: "%.1fM", Double(value) / 1_000_000)
        default: return String(format: "%.1fB", Double(value) / 1_000_000_000)
        }
    }
}
