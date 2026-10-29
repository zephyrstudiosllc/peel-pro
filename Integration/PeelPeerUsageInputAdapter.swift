import Foundation

/// The ONE place the paired-Mac usage summary reads the local usage store.
/// Consumes the usage lane's stable APIs (`providers`, `providerState`,
/// `observedTokenRecord`). Quota rows and observed per-Mac token rows stay
/// separate; tokens are never attributed to an account.
@MainActor
enum PeelPeerUsageInputAdapter {
    static func input(from usage: PeelUsageStore, now: Date) -> PeelPeerUsageLocalInput {
        guard let snapshot = usage.snapshot else { return .empty }
        var withData: [PeelPeerUsageLocalInput.Quota] = []
        var needsSignIn: [PeelPeerUsageLocalInput.Quota] = []
        for provider in usage.providers where provider.enabled {
            let state = usage.providerState(provider, now: now)
            let (status, reason) = wireStatus(state)
            let windows = provider.windows.prefix(3).map {
                PeelPeerUsageWindow(kind: $0.kind, label: $0.label, usedPercent: $0.usedPercent,
                                    resetAt: $0.resetAt.map(\.timeIntervalSince1970))
            }
            let quota = PeelPeerUsageLocalInput.Quota(
                provider: provider.id, name: provider.name, status: status, reason: reason,
                windows: state.hasUsableReading ? Array(windows) : [],
                sampledAt: provider.allowanceUpdatedAt ?? provider.updatedAt ?? snapshot.generatedAt,
                plan: provider.identity?.plan, accountKey: provider.identity?.accountKey)
            if state.hasUsableReading { withData.append(quota) }
            else if case .authNeeded = state { needsSignIn.append(quota) }
            // Generic errors/unsupported rows are not shared (69 enabled stays local noise).
        }
        var observed: [PeelPeerUsageLocalInput.Observed] = []
        for providerID in ["claude", "codex"] {
            guard let usageRecord = usage.observedTokenRecord(providerID: providerID)?.usage,
                  usageRecord.scope == .thisMacLocalLogs else { continue }
            for (period, value) in [(PeelPeerObservedUsage.Period.today, usageRecord.today),
                                    (.history, usageRecord.history)] {
                guard let value else { continue }
                let row = PeelPeerObservedUsage(
                    provider: providerID, period: period, days: period == .today ? 1 : value.days,
                    inputTokens: value.tokens.input, outputTokens: value.tokens.output,
                    cacheReadTokens: value.tokens.cacheRead, cacheCreationTokens: value.tokens.cacheCreation,
                    reasoningTokens: value.tokens.reasoning, totalTokens: value.tokens.total,
                    models: value.models.map {
                        PeelPeerObservedModel(id: $0.modelID, totalTokens: $0.totalTokens, priceKnown: $0.priceKnown)
                    },
                    omittedModelCount: value.omittedModelCount,
                    estimatedCostUSD: value.estimatedCostUSD,
                    provenance: usageRecord.provenance.rawValue,
                    coverageEstablished: period == .today ? nil : usageRecord.historyCoverageIsEstablished)
                observed.append(.init(usage: row, sampledAt: usageRecord.sampledAt ?? usageRecord.receivedAt))
            }
        }
        return PeelPeerUsageLocalInput(quotas: withData + needsSignIn, observed: observed)
    }

    static func wireStatus(_ state: PeelUsageProviderState) -> (PeelPeerUsageStatus, String?) {
        switch state {
        case .ok: (.ok, nil)
        case .stale: (.stale, nil)
        case .authNeeded(let silent): (.authNeeded, silent ? "silent_auth_blocked" : nil)
        case .error(let category): (.error, category.rawValue.lowercased())
        case .unsupported: (.unsupported, nil)
        case .disabled: (.disabled, nil)
        case .notCollected: (.notCollected, nil)
        }
    }
}
