import Foundation

/// Fixed categories for a provider error. Classification uses the helper's error code and message
/// shape only; the message itself is never forwarded to another device by this type.
nonisolated public enum PeelUsageErrorCategory: String, Codable, Equatable, Sendable {
    case timedOut
    case rateLimited
    case network
    case provider
}

/// What a provider row can truthfully show right now.
nonisolated public enum PeelUsageProviderState: Equatable, Sendable {
    /// At least one quota window has a percentage (or the row reports credits) and the reading is fresh.
    case ok
    /// Usable readings older than the producer's stale deadline.
    case stale(age: TimeInterval)
    /// The provider needs a sign-in or connection. `silentBlocked` means the credential exists behind a
    /// prompt that Peel deliberately does not show during background refresh.
    case authNeeded(silentBlocked: Bool)
    case error(PeelUsageErrorCategory)
    /// Not installed or not supported in this configuration.
    case unsupported
    case disabled
    /// Enabled and reachable, but no quota or balance was reported.
    case notCollected

    public nonisolated var hasUsableReading: Bool {
        switch self {
        case .ok, .stale: true
        default: false
        }
    }

    public nonisolated var label: String {
        switch self {
        case .ok: "Up to date"
        case let .stale(age): "Previous reading · \(PeelUsageFormatting.age(age)) old"
        case .authNeeded(silentBlocked: true): "Sign-in needed (Peel won't prompt in the background)"
        case .authNeeded(silentBlocked: false): "Sign-in or connection needed"
        case .error(.timedOut): "Timed out"
        case .error(.rateLimited): "Rate limited"
        case .error(.network): "Network unavailable"
        case .error(.provider): "Provider error"
        case .unsupported: "Not available here"
        case .disabled: "Disabled"
        case .notCollected: "No quota reported"
        }
    }

    public nonisolated var shortLabel: String {
        switch self {
        case .ok, .stale: "Available"
        case .authNeeded: "Sign-in needed"
        case .error(.timedOut): "Timed out"
        case .error: "Needs attention"
        case .unsupported: "Unavailable"
        case .disabled: "Disabled"
        case .notCollected: "No quota"
        }
    }

    public nonisolated static func classify(
        _ provider: PeelUsageProvider,
        snapshot: PeelUsageSnapshot?,
        now: Date) -> Self
    {
        guard provider.enabled else { return .disabled }
        if let error = provider.error {
            return classify(error)
        }
        let usableWindows = provider.windows.contains { !$0.idle && $0.displayPercent != nil }
        guard usableWindows || provider.credits != nil else { return .notCollected }
        let observedAt = provider.allowanceUpdatedAt ?? provider.updatedAt ?? snapshot?.generatedAt
        let staleAfter = TimeInterval(snapshot?.staleAfterSeconds ?? 180)
        if let observedAt, now.timeIntervalSince(observedAt) >= staleAfter {
            return .stale(age: now.timeIntervalSince(observedAt))
        }
        if let snapshot, snapshot.isStale(at: now) {
            return .stale(age: snapshot.age(at: now))
        }
        return .ok
    }

    /// Error categories from the helper's exit-code mapping and fixed message patterns.
    public nonisolated static func classify(_ error: PeelUsageError) -> Self {
        let text = error.message.lowercased()
        func has(_ needles: [String]) -> Bool { needles.contains { text.contains($0) } }

        if error.code == 4 || has(["timed out", "timeout"]) { return .error(.timedOut) }
        // "No rate limits found" is a missing-quota parse result, not throttling.
        if has(["rate limited", "rate-limited", "too many requests", "429"]) { return .error(.rateLimited) }
        if has(["keychain", "prompt", "non-interactive", "noninteractive", "user interaction"]) {
            return .authNeeded(silentBlocked: true)
        }
        if has([
            "sign in", "sign-in", "signin", "signed in", "log in", "login", "logged in", "authenticat", "unauthorized",
            "401", "403", "forbidden", "expired", "credential", "api key", "api_key", "apikey", "oauth",
            "cookie", "not connected", "token",
        ]) {
            return .authNeeded(silentBlocked: false)
        }
        if error.code == 2 || has(["not installed", "not supported", "unsupported", "not available"]) {
            return .unsupported
        }
        if has(["network", "offline", "could not connect", "connection", "unreachable", "dns"]) {
            return .error(.network)
        }
        return .error(.provider)
    }
}

/// Why a compact row was chosen.
nonisolated public enum PeelUsageCompactRowReason: String, Equatable, Sendable {
    /// The provider pinned in Menu Bar Indicators.
    case selected
    /// An agent provider the caller marked active (for example Claude or Codex) with a usable reading.
    case activeAgent
    /// An active agent provider whose quota is unavailable; shown so its state is never hidden.
    case activeAgentUnavailable
    /// Another provider with a usable reading, in helper order.
    case usable
}

nonisolated public struct PeelUsageCompactRow: Equatable, Sendable, Identifiable {
    public let providerID: String
    public let name: String
    public let state: PeelUsageProviderState
    public let reason: PeelUsageCompactRowReason
    /// First non-idle window with a percentage, when any.
    public let window: PeelUsageWindow?
    /// Age of the quota reading, from the producer's allowance time.
    public let quotaAge: TimeInterval?

    public nonisolated var id: String { providerID }
}

/// Counts of enabled providers not shown as compact rows. Account quotas are never summed.
nonisolated public struct PeelUsageCompactSummary: Equatable, Sendable {
    public let rows: [PeelUsageCompactRow]
    public let hiddenUsableCount: Int
    public let authNeededCount: Int
    public let unavailableCount: Int
    public let enabledCount: Int

    /// For example "1 more with readings · 15 need sign-in · 44 unavailable", or `nil` when nothing
    /// is hidden.
    public nonisolated var hiddenSummaryText: String? {
        var parts: [String] = []
        if hiddenUsableCount > 0 { parts.append("\(hiddenUsableCount) more with readings") }
        if authNeededCount > 0 {
            parts.append(authNeededCount == 1 ? "1 needs sign-in" : "\(authNeededCount) need sign-in")
        }
        if unavailableCount > 0 { parts.append("\(unavailableCount) unavailable") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Stable ranking for compact usage surfaces (menu, notch, Hub header). It never mutates provider
/// configuration. Order:
/// 1. the provider selected in Menu Bar Indicators, in whatever state it is;
/// 2. active agent providers with usable readings, in `activeAgentProviderIDs` order;
/// 3. active agent providers without a usable reading, with their truthful state;
/// 4. other providers with usable readings, in helper order;
/// then a summary of everything else.
nonisolated public enum PeelUsageCompactRanking {
    public static let defaultMaxRows = 3
    /// CodexBar provider IDs for the agent harnesses Peel shows. Callers may pass the providers of
    /// currently visible agent sessions instead.
    public static let defaultActiveAgentProviderIDs = ["claude", "codex"]

    public nonisolated static func rank(
        providers: [PeelUsageProvider],
        snapshot: PeelUsageSnapshot?,
        selectedProviderID: String?,
        activeAgentProviderIDs: [String] = defaultActiveAgentProviderIDs,
        maxRows: Int = defaultMaxRows,
        now: Date) -> PeelUsageCompactSummary
    {
        let enabled = providers.filter(\.enabled)
        let limit = max(0, maxRows)
        var rows: [PeelUsageCompactRow] = []
        var chosen = Set<String>()
        var states: [String: PeelUsageProviderState] = [:]
        for provider in enabled {
            states[provider.id] = PeelUsageProviderState.classify(provider, snapshot: snapshot, now: now)
        }
        let byID = Dictionary(enabled.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        func append(_ provider: PeelUsageProvider, _ reason: PeelUsageCompactRowReason) {
            guard rows.count < limit, chosen.insert(provider.id).inserted,
                  let state = states[provider.id] else { return }
            let window = provider.windows.first { !$0.idle && $0.displayPercent != nil }
            let observedAt = provider.allowanceUpdatedAt ?? provider.updatedAt
            rows.append(PeelUsageCompactRow(
                providerID: provider.id,
                name: provider.name,
                state: state,
                reason: reason,
                window: state.hasUsableReading ? window : nil,
                quotaAge: state.hasUsableReading ? observedAt.map { max(0, now.timeIntervalSince($0)) } : nil))
        }

        if let selectedProviderID, !selectedProviderID.isEmpty, let selected = byID[selectedProviderID] {
            append(selected, .selected)
        }
        var seenActive = Set<String>()
        let active = activeAgentProviderIDs.filter { seenActive.insert($0).inserted }.compactMap { byID[$0] }
        for provider in active where states[provider.id]?.hasUsableReading == true {
            append(provider, .activeAgent)
        }
        for provider in active where states[provider.id]?.hasUsableReading != true {
            append(provider, .activeAgentUnavailable)
        }
        for provider in enabled where states[provider.id]?.hasUsableReading == true {
            append(provider, .usable)
        }

        var hiddenUsable = 0
        var authNeeded = 0
        var unavailable = 0
        for provider in enabled where !chosen.contains(provider.id) {
            switch states[provider.id] {
            case .ok?, .stale?: hiddenUsable += 1
            case .authNeeded?: authNeeded += 1
            default: unavailable += 1
            }
        }
        return PeelUsageCompactSummary(
            rows: rows,
            hiddenUsableCount: hiddenUsable,
            authNeededCount: authNeeded,
            unavailableCount: unavailable,
            enabledCount: enabled.count)
    }
}

nonisolated public enum PeelUsageFormatting {
    /// Compact token count, for example 950, 12.4K, 3.1M. Unknown stays "—".
    public nonisolated static func tokens(_ value: Int?) -> String {
        guard let value else { return "—" }
        let number = Double(value)
        switch value {
        case ..<1_000: return "\(value)"
        case ..<1_000_000: return String(format: "%.1fK", number / 1_000)
        case ..<1_000_000_000: return String(format: "%.1fM", number / 1_000_000)
        default: return String(format: "%.1fB", number / 1_000_000_000)
        }
    }

    public nonisolated static func age(_ seconds: TimeInterval) -> String {
        let seconds = max(0, seconds)
        switch seconds {
        case ..<90: return "\(Int(seconds.rounded()))s"
        case ..<5_400: return "\(Int((seconds / 60).rounded()))m"
        case ..<129_600: return "\(Int((seconds / 3_600).rounded()))h"
        default: return "\(Int((seconds / 86_400).rounded()))d"
        }
    }
}
