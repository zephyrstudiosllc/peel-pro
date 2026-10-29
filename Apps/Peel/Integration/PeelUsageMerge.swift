import Foundation

/// Whether two readings provably belong to the same provider account.
nonisolated public enum PeelUsageAccountOwnership: Equatable, Sendable {
    case same
    case different
    /// Identity is missing, redacted without a stable key, or only one side has a key.
    case unknown

    /// A non-empty `accountKey` on both sides is authoritative; it is a stable provider-scoped
    /// pseudonym that survives email redaction. Without keys on both sides, only equal non-redacted
    /// emails prove ownership. Anything else is unknown and must not carry account-bound readings.
    public nonisolated static func compare(
        _ current: PeelUsageIdentity?,
        _ previous: PeelUsageIdentity?) -> Self
    {
        let currentKey = normalized(current?.accountKey)
        let previousKey = normalized(previous?.accountKey)
        switch (currentKey, previousKey) {
        case let (current?, previous?):
            return current == previous ? .same : .different
        case (.some, nil), (nil, .some):
            return .unknown
        case (nil, nil):
            break
        }
        guard let currentEmail = normalized(current?.accountEmail),
              let previousEmail = normalized(previous?.accountEmail),
              !isRedacted(currentEmail), !isRedacted(previousEmail)
        else {
            return .unknown
        }
        return currentEmail == previousEmail ? .same : .different
    }

    private nonisolated static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty, value != "unknown"
        else { return nil }
        return value
    }

    private nonisolated static func isRedacted(_ email: String) -> Bool {
        email.hasPrefix("redacted")
    }
}

/// Pure merge of a fast allowance poll into the previous snapshot. A no-cost poll carries quota and
/// status only, so account-bound details from the previous full reading are reused only when the
/// source and the account owner both provably match.
nonisolated public enum PeelUsageSnapshotMerge {
    public nonisolated static func mergeAllowance(
        incoming: PeelUsageSnapshot,
        previous: PeelUsageSnapshot?) -> PeelUsageSnapshot
    {
        guard let previous else { return incoming }

        var previousProviders: [String: PeelUsageProvider] = [:]
        for provider in previous.providers {
            previousProviders[provider.id] = provider
        }

        let providers = incoming.providers.map { provider in
            guard let old = previousProviders[provider.id] else { return provider }
            let reuse = canReuseAccountDetails(current: provider, previous: old)
            let accounts = provider.accounts ?? (reuse ? old.accounts : nil)
            let accountsError = provider.accounts == nil && reuse
                ? (provider.accountsError ?? old.accountsError)
                : provider.accountsError
            return PeelUsageProvider(
                id: provider.id,
                name: provider.name,
                enabled: provider.enabled,
                source: provider.source,
                status: provider.status,
                identity: provider.identity,
                windows: provider.windows,
                credits: provider.credits ?? (reuse ? old.credits : nil),
                // Cost on the provider row is presented with that account, so it follows the same
                // ownership rule. This Mac's local-log tokens live in `PeelObservedTokenRecord` and are
                // never attached to an account.
                cost: provider.cost ?? (reuse ? old.cost : nil),
                accounts: accounts,
                accountsError: accountsError,
                error: provider.error,
                updatedAt: provider.updatedAt,
                allowanceUpdatedAt: provider.allowanceUpdatedAt)
        }
        return PeelUsageSnapshot(
            schemaVersion: incoming.schemaVersion,
            generatedAt: incoming.generatedAt,
            staleAfterSeconds: incoming.staleAfterSeconds,
            providers: providers,
            rejectedProviderCount: incoming.rejectedProviderCount,
            rejectedProviderIDs: incoming.rejectedProviderIDs)
    }

    public nonisolated static func canReuseAccountDetails(
        current: PeelUsageProvider,
        previous: PeelUsageProvider) -> Bool
    {
        stableSourceMatches(current.source, previous.source)
            && PeelUsageAccountOwnership.compare(current.identity, previous.identity) == .same
    }

    public nonisolated static func stableSourceMatches(_ current: String?, _ previous: String?) -> Bool {
        guard let current, let previous else { return false }
        let normalizedCurrent = current.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedPrevious = previous.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedCurrent.isEmpty, normalizedCurrent != "unknown" else { return false }
        return normalizedCurrent == normalizedPrevious
    }

    /// Per-provider cost observation times after a merge. A freshly reported cost uses its producer
    /// time (or the snapshot time for older helpers); a carried cost keeps its original time; a
    /// dropped cost has no time. Quota freshness never refreshes cost age.
    public nonisolated static func costObservationDates(
        merged: PeelUsageSnapshot,
        incoming: PeelUsageSnapshot,
        previous: [String: Date]) -> [String: Date]
    {
        var incomingCost: [String: PeelUsageCost] = [:]
        for provider in incoming.providers {
            if let cost = provider.cost { incomingCost[provider.id] = cost }
        }
        var dates: [String: Date] = [:]
        for provider in merged.providers where provider.cost != nil {
            if let fresh = incomingCost[provider.id] {
                dates[provider.id] = fresh.updatedAt ?? incoming.generatedAt
            } else if let carried = previous[provider.id] {
                dates[provider.id] = carried
            }
        }
        return dates
    }
}
