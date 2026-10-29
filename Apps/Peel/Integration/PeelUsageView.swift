import SwiftUI
import Charts

struct PeelUsageView: View {
    @Bindable var store: PeelUsageStore
    var providerID: String? = nil
    /// When set, a compact picker drills into one provider (nil shows all).
    var selectProvider: ((String?) -> Void)? = nil
    @AppStorage("peel.usage.hideProvidersWithoutData.v1") private var hidesProvidersWithoutData = false

    private var displayedProviders: [PeelUsageProvider] {
        guard let providerID else {
            // Providers with readings come first; the helper's order is kept within each group so a
            // healthy provider is never buried behind dozens of unavailable rows.
            let now = Date.now
            let ranked = store.providers.enumerated().map { index, provider in
                (index, provider, store.providerState(provider, now: now))
            }
            return ranked
                .filter { !hidesProvidersWithoutData || hasData($0.1, state: $0.2) }
                .sorted { lhs, rhs in
                    let left = displayRank(lhs.2), right = displayRank(rhs.2)
                    return left == right ? lhs.0 < rhs.0 : left < right
                }
                .map { $0.1 }
        }
        return store.providers.filter { $0.id == providerID }
    }

    private func hasData(_ provider: PeelUsageProvider, state: PeelUsageProviderState) -> Bool {
        state.hasUsableReading || provider.cost != nil || provider.credits != nil
            || store.observedTokenRecord(providerID: provider.id)?.usage != nil
    }

    private func displayRank(_ state: PeelUsageProviderState) -> Int {
        switch state {
        case .ok, .stale: 0
        case .authNeeded: 1
        case .notCollected: 2
        default: 3
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(providerID == nil ? "Usage Limits" : displayedProviders.first?.name ?? "Provider Usage").font(.largeTitle.bold())
                        Text("Account plan limits, tokens observed on this Mac, and estimates.")
                            .foregroundStyle(.secondary)
                        if let selectProvider, !store.providers.isEmpty {
                            Picker("Provider", selection: Binding(get: { providerID }, set: { selectProvider($0) })) {
                                Text("All Providers").tag(String?.none)
                                Divider()
                                ForEach(store.providers) { provider in
                                    Text(provider.name).tag(Optional(provider.id))
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                            .accessibilityLabel("Provider")
                        }
                    }
                    Spacer()
                    if store.isRefreshing {
                        ProgressView().controlSize(.small).padding(.top, 8)
                    }
                    if store.isConnected {
                        Button("Refresh", systemImage: "arrow.clockwise") { store.refresh(includeCost: true) }
                            .disabled(store.isRefreshing)
                        Menu {
                            Toggle("Hide providers without data", isOn: $hidesProvidersWithoutData)
                            Divider()
                            Button("Disconnect usage") { store.disconnect() }
                        } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }

                if store.isPreview {
                    Label("Preview — live connections are paused.", systemImage: "eye")
                        .font(.callout).foregroundStyle(.orange)
                }
                if let error = store.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
                if let error = store.historyErrorMessage {
                    Label(error, systemImage: "clock.badge.exclamationmark")
                        .font(.callout).foregroundStyle(.orange)
                }
                if let error = store.costErrorMessage {
                    Label("Cost refresh unavailable: \(error)", systemImage: "dollarsign.circle")
                        .font(.callout).foregroundStyle(.orange)
                }
                if store.rejectedProviderCount > 0, store.snapshot?.providers.isEmpty == false {
                    Label(
                        "\(store.rejectedProviderCount) provider \(store.rejectedProviderCount == 1 ? "row" : "rows") couldn't be read by this Peel version.",
                        systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
                if store.helperSupportsCompactTokens == false {
                    Label(
                        "Token and model detail needs an updated usage helper. Plan limits are unaffected.",
                        systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let costUpdated = store.costSnapshotGeneratedAt,
                   let snapshot = store.snapshot,
                   snapshot.generatedAt > costUpdated,
                   snapshot.providers.contains(where: { $0.cost != nil }) {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                        Text("Cost values last refreshed")
                        Text(costUpdated, style: .relative)
                        Text("ago")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }

                if let snapshot = store.snapshot {
                    freshness(snapshot)
                    if !store.isPreview {
                        Text("Plan limits shown here were read by this Mac from provider accounts. These are account limits. Local token observations are separate. Shared usage from paired Macs, when available, appears in Agent Hub.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if providerID == nil, let summary = providerSummary {
                        Text(summary).font(.caption).foregroundStyle(.secondary)
                    }
                    if displayedProviders.isEmpty {
                        if store.providers.isEmpty {
                            ContentUnavailableView("No enabled providers", systemImage: "gauge.with.dots.needle.0percent",
                                description: Text("Enable your providers in Usage Limits Settings, then refresh here."))
                        } else {
                            ContentUnavailableView("No providers with data", systemImage: "line.3.horizontal.decrease.circle",
                                description: Text("Turn off “Hide providers without data” to see every enabled provider and its status."))
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 14)],
                                  alignment: .leading, spacing: 14) {
                            ForEach(displayedProviders) { provider in
                                PeelUsageProviderCard(
                                    provider: provider,
                                    state: store.providerState(provider),
                                    tokenRecord: store.observedTokenRecord(providerID: provider.id),
                                    tracksLocalTokens: PeelLocalTokenProvider(rawValue: provider.id) != nil,
                                    costObservedAt: store.costObservedAt[provider.id],
                                    history: store.history)
                            }
                        }
                    }
                    Text("Plan limits belong to each provider account. Observed tokens come from Codex and Claude Code logs on this Mac, across every account used here, and are never combined with another Mac. Cost figures are estimates at public API prices, not a bill.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Local model runs recorded in those logs keep their tokens; a model without a public price shows “price unknown”. Requests served by local model servers outside these logs have no history Peel can read.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if !store.isConnected {
                    connectionPrompt
                } else if store.isRefreshing {
                    ContentUnavailableView("Reading your providers", systemImage: "arrow.triangle.2.circlepath",
                        description: Text("Allowances will appear as soon as the first refresh finishes."))
                }
            }
            .padding(.bottom, 16)
        }
    }

    private var providerSummary: String? {
        let states = store.providers.map { store.providerState($0) }
        guard states.count > 1 else { return nil }
        let usable = states.filter(\.hasUsableReading).count
        let authNeeded = states.filter { state in
            if case .authNeeded = state { return true }
            return false
        }.count
        let other = states.count - usable - authNeeded
        var parts = ["\(usable) with readings"]
        if authNeeded > 0 { parts.append(authNeeded == 1 ? "1 needs sign-in" : "\(authNeeded) need sign-in") }
        if other > 0 { parts.append("\(other) unavailable") }
        return parts.joined(separator: " · ")
    }

    private var connectionPrompt: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 36)).foregroundStyle(.purple)
            Text("Bring your usage into Peel").font(.title2.bold())
            Text("Use your existing provider connections to see allowances, reset times and connection problems here. Monitoring stays silent; providers that need authentication remain unavailable until you connect them.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Connect usage", systemImage: "link") { store.connect() }
                .buttonStyle(.borderedProminent).tint(.purple)
            Text("Refreshes about once a minute while usage is connected. Account emails are redacted.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 600, alignment: .leading)
        .padding(28)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 20))
    }

    private func freshness(_ snapshot: PeelUsageSnapshot) -> some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            HStack(spacing: 8) {
                Circle().fill(snapshot.isStale(at: context.date) ? Color.orange : Color.green)
                    .frame(width: 6, height: 6)
                Text(snapshot.isStale(at: context.date) ? "Previous snapshot" : "Snapshot refreshed")
                Text("·")
                Text(snapshot.generatedAt, style: .relative)
                Text("ago")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct PeelUsageProviderCard: View {
    let provider: PeelUsageProvider
    let state: PeelUsageProviderState
    let tokenRecord: PeelObservedTokenRecord?
    let tracksLocalTokens: Bool
    let costObservedAt: Date?
    let history: PeelUsageHistory

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Text(String(provider.name.prefix(1)).uppercased())
                    .font(.headline)
                    .frame(width: 36, height: 36)
                    .background(.purple.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.name).font(.headline)
                    if let plan = provider.identity?.plan { Text(plan).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
            if let email = provider.identity?.accountEmail {
                Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if state != .ok {
                Label(state.label, systemImage: stateSymbol)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(state.hasUsableReading ? Color.secondary : Color.orange)
            }
            if let credits = provider.credits {
                PeelUsageCreditsRow(credits: credits)
            }
            if let error = provider.error {
                Label(error.message, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            if case .authNeeded = state {
                Text("Peel checks providers silently and never opens a sign-in prompt in the background. Connect this provider in Z-CodexBar, then refresh.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !provider.windows.isEmpty {
                Text("Plan limits").font(.subheadline.weight(.semibold))
                PeelUsageWindowRows(windows: provider.windows)
                PeelUsageHistoryView(provider: provider, history: history)
            }
            if let tokenRecord {
                PeelUsageObservedTokensView(record: tokenRecord)
            } else if tracksLocalTokens {
                Text("Token and model detail from this Mac's logs appears after the next local scan.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // Local-log estimates are shown with the observed tokens above; a row-level cost is shown only
            // when no observed reading exists, labeled by how it was produced.
            if let cost = provider.cost, tokenRecord?.usage == nil {
                PeelUsageCostRows(cost: cost, observedAt: costObservedAt)
            }
            if let accounts = provider.accounts {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Accounts").font(.subheadline.weight(.semibold))
                    if accounts.isEmpty {
                        Text("No account entries reported")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(accounts) { account in
                            PeelUsageAccountCard(account: account, provider: provider, history: history)
                        }
                    }
                }
            }
            if let accountsError = provider.accountsError {
                Label("Account details unavailable: \(accountsError)", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            if let status = provider.status?.label {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if let updated = provider.allowanceUpdatedAt ?? provider.updatedAt {
                HStack(spacing: 4) {
                    Text(provider.allowanceUpdatedAt == nil ? "Reading updated" : "Limits read")
                    Text(updated, style: .relative)
                    Text("ago")
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.primary.opacity(0.06), lineWidth: 1))
    }

    private var stateSymbol: String {
        switch state {
        case .ok, .stale: "clock"
        case .authNeeded: "person.crop.circle.badge.exclamationmark"
        case .error: "exclamationmark.triangle"
        case .unsupported, .disabled: "slash.circle"
        case .notCollected: "gauge.with.dots.needle.0percent"
        }
    }
}

/// This Mac's observed tokens for one provider. Kept visually separate from plan limits and never
/// described as account usage or a bill.
private struct PeelUsageObservedTokensView: View {
    let record: PeelObservedTokenRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text("Observed on this Mac").font(.subheadline.weight(.semibold))
                Spacer()
                if let usage = record.usage {
                    HStack(spacing: 3) {
                        Text(usage.sampledAt ?? usage.receivedAt, style: .relative)
                        Text("ago")
                    }.font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let usage = record.usage {
                if usage.recordsNoUsage {
                    Text("No usage recorded in this Mac's logs for the covered period.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let today = usage.today {
                    PeelUsageTokenPeriodRow(label: "Today", period: today, currencyCode: usage.currencyCode)
                }
                if let period = usage.history {
                    PeelUsageTokenPeriodRow(
                        label: period.days == 1 ? "Today" : "Last \(period.days) days",
                        period: period,
                        currencyCode: usage.currencyCode)
                    PeelUsageTokenClassRow(tokens: period.tokens)
                    if !period.models.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(period.models.prefix(5)) { model in
                                HStack(spacing: 6) {
                                    Text(model.displayName).lineLimit(1).truncationMode(.middle)
                                    if model.endpoint != .unspecified {
                                        Text(model.localProviderID.map { "local · " + $0 } ?? "custom provider")
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 6)
                                    Text(PeelUsageFormatting.tokens(model.totalTokens)).monospacedDigit()
                                    Text(model.estimatedCostUSD.map { usd(usage.currencyCode, $0) } ?? "price unknown")
                                        .foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                            let more = peelBoundedOmittedCount(
                                declared: period.omittedModelCount,
                                truncated: period.models.count - 5)
                            let atLeast = more.isCapped || period.omittedModelCountIsCapped
                            if more.count > 0 {
                                Text("+" + String(more.count) + (atLeast ? " or more" : " more")
                                    + (more.count == 1 ? " model" : " models"))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                    }
                }
                if usage.historyCoverageIsEstablished == false {
                    Text("Local history is still being scanned; totals may be incomplete.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let coverage = usage.coverage, coverage.unpriced > 0 || coverage.unmetered > 0 {
                    let unpriced = PeelTokenCounts.adding(coverage.unpriced, coverage.unmetered).map(String.init) ?? "Many"
                    let total = coverage.total.map(String.init) ?? "—"
                    Text(unpriced + " of " + total + " recorded requests have no known price; their tokens are counted, their cost is not.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if usage.history?.models.contains(where: { $0.endpoint != .unspecified }) == true {
                    Text("Local and custom-provider models are measured from the logs; their infrastructure cost is unknown and never counted as spend.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(provenanceNote(usage))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure = record.failure {
                Label(
                    failure.summary + (record.usage == nil ? "" : " Showing the previous reading."),
                    systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func provenanceNote(_ usage: PeelObservedTokenUsage) -> String {
        let scope = usage.scope == .thisMacLocalLogs
            ? "All accounts used on this Mac · not combined with other Macs."
            : "Reported for this provider account."
        switch usage.provenance {
        case .listPriceEstimate, .mixed:
            return scope + " Costs are estimates at public API prices, not a bill; the logs can't tell local or proxy endpoints apart."
        case .vendorMetered:
            return scope + " Amounts are the provider's own metering."
        case .unknown:
            return scope + " No price was established for these tokens."
        }
    }
}

private struct PeelUsageTokenPeriodRow: View {
    let label: String
    let period: PeelObservedTokenPeriod
    let currencyCode: String?

    var body: some View {
        HStack(spacing: 8) {
            Label(label, systemImage: "number.circle")
            Spacer(minLength: 8)
            Text("\(PeelUsageFormatting.tokens(period.tokens.total)) tokens")
                .font(.callout.weight(.semibold)).monospacedDigit()
            if let cost = period.estimatedCostUSD {
                Text("≈\(usd(currencyCode, cost))").font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

private struct PeelUsageTokenClassRow: View {
    let tokens: PeelTokenCounts

    var body: some View {
        let parts: [String] = [
            tokens.input.map { "In \(PeelUsageFormatting.tokens($0))" },
            tokens.output.map { "Out \(PeelUsageFormatting.tokens($0))" },
            tokens.cacheRead.map { "Cache read \(PeelUsageFormatting.tokens($0))" },
            tokens.cacheCreation.map { "Cache write \(PeelUsageFormatting.tokens($0))" },
            tokens.reasoning.map { "Reasoning \(PeelUsageFormatting.tokens($0))" },
        ].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

private func usd(_ currencyCode: String?, _ amount: Double) -> String {
    amount.formatted(.currency(code: currencyCode ?? "USD").locale(Locale(identifier: "en_US")))
}

private struct PeelUsageCreditsRow: View {
    let credits: PeelUsageCredits

    var body: some View {
        HStack(spacing: 8) {
            Label("Credits remaining", systemImage: "circlebadge.2")
            Spacer(minLength: 8)
            Text("\(credits.remaining.formatted(.number.precision(.fractionLength(0...2)))) \(credits.unit)")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
        }
    }
}

private struct PeelUsageCostRows: View {
    let cost: PeelUsageCost
    var observedAt: Date? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let todayUSD = cost.todayUSD {
                PeelUsageCostRow(label: "Today", amountUSD: todayUSD)
            }
            if let last30DaysUSD = cost.last30DaysUSD {
                PeelUsageCostRow(label: "Last \(cost.historyDays ?? 30) days", amountUSD: last30DaysUSD)
            }
            HStack(spacing: 4) {
                Text(caption)
                if let observedAt {
                    Text("·")
                    Text(observedAt, style: .relative)
                    Text("ago")
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var caption: String {
        switch cost.provenance {
        case .vendorMetered?: "Provider-reported spend for this account"
        case .listPriceEstimate?, .mixed?: "Estimate at public API prices · not a bill"
        case .unknown?, nil: "Estimate · not a bill"
        }
    }
}

private struct PeelUsageCostRow: View {
    let label: String
    let amountUSD: Double

    var body: some View {
        HStack(spacing: 8) {
            Label(label, systemImage: "dollarsign.circle")
            Spacer(minLength: 8)
            Text(amountUSD.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US"))))
                .font(.callout.weight(.semibold))
                .monospacedDigit()
        }
    }
}

private struct PeelUsageWindowRows: View {
    let windows: [PeelUsageWindow]

    var body: some View {
        ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(window.label).font(.subheadline)
                    Spacer()
                    if let remaining = window.normalizedRemainingPercent {
                        Text("\(remaining.formatted(.number.precision(.fractionLength(0))))% left")
                            .font(.subheadline.weight(.semibold)).monospacedDigit()
                    } else {
                        Text("Unavailable").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let remaining = window.normalizedRemainingPercent {
                    ProgressView(value: remaining, total: 100)
                        .tint(remaining <= 20 ? .orange : .purple)
                }
                if let reset = window.resetAt {
                    HStack(spacing: 4) {
                        Text("Resets")
                        Text(reset, style: .relative)
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct PeelUsageAccountCard: View {
    let account: PeelUsageAccount
    let provider: PeelUsageProvider
    let history: PeelUsageHistory

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.label).font(.callout.weight(.semibold))
                    if let email = account.identity?.accountEmail, email != account.label {
                        Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let plan = account.identity?.plan {
                        Text(plan).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Text(account.active ? "Active" : "Inactive")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(account.active ? .green : .secondary)
            }
            if let error = account.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if account.windows.isEmpty && account.error == nil {
                Text("Allowance unavailable").font(.caption).foregroundStyle(.secondary)
            }
            if !account.windows.isEmpty {
                PeelUsageWindowRows(windows: account.windows)
                PeelUsageHistoryView(provider: provider, history: history, account: account)
            }
            if let pace = account.pace {
                PeelUsagePaceRows(pace: pace)
            }
            if let updated = account.updatedAt {
                HStack(spacing: 4) {
                    Text("Reading updated")
                    Text(updated, style: .relative)
                    Text("ago")
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct PeelUsagePaceRows: View {
    let pace: PeelUsagePaceSet

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pace").font(.caption.weight(.semibold))
            if let primary = pace.primary {
                PeelUsagePaceRow(label: "Primary", pace: primary)
            }
            if let secondary = pace.secondary {
                PeelUsagePaceRow(label: "Secondary", pace: secondary)
            }
            if let tertiary = pace.tertiary {
                PeelUsagePaceRow(label: "Tertiary", pace: tertiary)
            }
        }
    }
}

private struct PeelUsagePaceRow: View {
    let label: String
    let pace: PeelUsagePace

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(pace.summary).font(.caption)
        }
    }
}

/// Bars contain only measured allowance increases within each hour. Reset and missing intervals stay unknown.
private struct PeelUsageHistoryView: View {
    let provider: PeelUsageProvider
    let history: PeelUsageHistory
    var account: PeelUsageAccount? = nil
    @State private var selectedWindow = ""

    private var windows: [PeelUsageWindow] { (account?.windows ?? provider.windows).filter { !$0.idle } }
    private var window: PeelUsageWindow? {
        windows.first(where: { $0.kind == selectedWindow }) ?? windows.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Text("Usage history").font(.subheadline.weight(.semibold))
                Spacer()
                if windows.count > 1 {
                    Picker("Allowance window", selection: Binding(
                        get: { window?.kind ?? "" }, set: { selectedWindow = $0 })) {
                        ForEach(windows) { item in Text(item.label).tag(item.kind) }
                    }
                    .labelsHidden().controlSize(.small).fixedSize()
                }
            }
            if let window, let key = PeelUsageHistory.key(provider: provider, window: window, account: account) {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let hours = history.hours(for: key, endingAt: context.date)
                    let recent = hours.last!
                    Text(summary(recent)).font(.callout.weight(.medium)).monospacedDigit()
                    if hours.contains(where: { $0.percentagePoints != nil }) {
                        Chart(hours) { hour in
                            if let points = hour.percentagePoints {
                                RectangleMark(
                                    xStart: .value("Hour start", hour.start.addingTimeInterval(360)),
                                    xEnd: .value("Hour end", hour.end.addingTimeInterval(-360)),
                                    yStart: .value("Baseline", 0),
                                    yEnd: .value("Percentage points used", points))
                                    .foregroundStyle(hour.isComplete ? Color.purple : Color.orange.opacity(0.7))
                                    .accessibilityLabel(hour.start.formatted(date: .omitted, time: .shortened))
                                    .accessibilityValue("\(points.formatted(.number.precision(.fractionLength(0...2)))) percentage points\(hour.isComplete ? "" : ", partial observations")")
                                if points == 0 {
                                    PointMark(x: .value("Hour", hour.start), y: .value("Percentage points used", 0))
                                        .symbolSize(8).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .chartXScale(domain: hours.first!.start...context.date)
                        .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                            AxisValueLabel(format: .dateTime.hour())
                        } }
                        .chartYAxis { AxisMarks(position: .leading) }
                        .frame(height: 115)
                    } else {
                        Text("History starts with fresh readings from this account. Two readings are needed to measure a change.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Last 24 hours · percentage points of allowance. Orange bars are partial; gaps and resets are not estimated.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("History unavailable — the provider has not supplied a stable account identity.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func summary(_ hour: PeelUsageHistory.Hour) -> String {
        guard let points = hour.percentagePoints else { return "Last hour unavailable" }
        let value = points.formatted(.number.precision(.fractionLength(0...2)))
        return hour.isComplete ? "≈\(value)% used in the last hour" : "\(value)% observed in the last hour · partial"
    }
}
