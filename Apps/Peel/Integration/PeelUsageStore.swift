import Foundation
import Observation

@MainActor
@Observable
final class PeelUsageStore {
    private(set) var snapshot: PeelUsageSnapshot?
    private(set) var isRefreshing = false
    private(set) var isConnected = false
    private(set) var errorMessage: String?
    private(set) var costErrorMessage: String?
    private(set) var costSnapshotGeneratedAt: Date?
    /// Producer time of each provider row's cost reading. Quota polls never refresh it.
    private(set) var costObservedAt: [String: Date] = [:]
    /// Rows in the latest readable dashboard response that could not be decoded.
    private(set) var rejectedProviderCount = 0
    /// Tokens and models recorded by harness logs on this Mac. Never attached to an account, never
    /// merged with another Mac's readings, and untouched by quota polls.
    private(set) var tokenLedger = PeelObservedTokenLedger()
    private(set) var isCollectingTokens = false
    /// `nil` until probed; `false` when the bundled helper can't return compact, path-free token detail.
    private(set) var helperSupportsCompactTokens: Bool?
    private(set) var history = PeelUsageHistory()
    private(set) var historyErrorMessage: String?
    private(set) var isHistoryLoaded = false
    let isPreview = ProcessInfo.processInfo.arguments.contains("--peel-preview")

    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private var cancellation: PeelUsageCancellation?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var nextRefresh = Date.distantPast
    @ObservationIgnored private var failureCount = 0

    @ObservationIgnored private var tokenCancellation: PeelUsageCancellation?
    @ObservationIgnored private var tokenGeneration = UUID()
    @ObservationIgnored private var nextTokenRefresh = Date.distantPast
    @ObservationIgnored private var tokenFailureCount = 0
    @ObservationIgnored private var tokenRefreshForced = false
    @ObservationIgnored private var tokenPassHadFailure = false
    @ObservationIgnored private var lastTokenPassFinishedAt: Date?
    @ObservationIgnored private var dashboardTokenProviders: [String: Date] = [:]

    @ObservationIgnored private let historyQueue = DispatchQueue(label: "peel.usage.history", qos: .utility)
    @ObservationIgnored private var pendingHistorySnapshots: [(PeelUsageSnapshot, Date)] = []
    @ObservationIgnored private var historyCanPersist = true
    @ObservationIgnored private let historyURL = FileManager.default.urls(for: .applicationSupportDirectory,
        in: .userDomainMask)[0].appendingPathComponent("Peel/usage-history-v1.json")

    private static let connectionPreferenceKey = "peel.usage.connected"

    init() {
        loadHistory()
        if !isPreview && UserDefaults.standard.bool(forKey: Self.connectionPreferenceKey) {
            connect()
        }
    }

    var providers: [PeelUsageProvider] { snapshot?.providers.filter(\.enabled) ?? [] }

    /// Latest observed-token record for one provider on this Mac.
    func observedTokenRecord(providerID: String) -> PeelObservedTokenRecord? {
        tokenLedger[providerID]
    }

    /// Truthful state for one provider row.
    func providerState(_ provider: PeelUsageProvider, now: Date = .now) -> PeelUsageProviderState {
        PeelUsageProviderState.classify(provider, snapshot: snapshot, now: now)
    }

    /// Ranked compact rows plus a summary of hidden providers. See `PeelUsageCompactRanking`.
    func compactSummary(
        selectedProviderID: String?,
        activeAgentProviderIDs: [String] = PeelUsageCompactRanking.defaultActiveAgentProviderIDs,
        maxRows: Int = PeelUsageCompactRanking.defaultMaxRows,
        now: Date = .now) -> PeelUsageCompactSummary
    {
        PeelUsageCompactRanking.rank(
            providers: providers,
            snapshot: snapshot,
            selectedProviderID: selectedProviderID,
            activeAgentProviderIDs: activeAgentProviderIDs,
            maxRows: maxRows,
            now: now)
    }

    func connect() {
        guard !isPreview else { return }
        UserDefaults.standard.set(true, forKey: Self.connectionPreferenceKey)
        isConnected = true
        // The first local-log scan waits briefly so it never competes with launch or the first quota read.
        nextTokenRefresh = Date.now.addingTimeInterval(PeelLocalTokenLanePolicy.minimumSpacing)
        refresh()
        startPresentation()
    }

    func disconnect() {
        guard !isPreview else { return }
        UserDefaults.standard.set(false, forKey: Self.connectionPreferenceKey)
        isConnected = false
        stopPresentation()
        snapshot = nil
        errorMessage = nil
        costErrorMessage = nil
        costSnapshotGeneratedAt = nil
        costObservedAt = [:]
        rejectedProviderCount = 0
        tokenLedger.removeAll()
        helperSupportsCompactTokens = nil
        dashboardTokenProviders = [:]
        nextTokenRefresh = .distantPast
        tokenFailureCount = 0
    }

    func startPresentation() {
        guard isConnected, !isPreview, refreshTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if Date.now >= self.nextRefresh {
                    self.refresh()
                } else {
                    self.startTokenLaneIfDue()
                }
            }
        }
        timer.tolerance = 5
        refreshTimer = timer
    }

    func stopPresentation() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        cancellation?.cancel()
        cancellation = nil
        generation = UUID()
        isRefreshing = false
        stopTokenLane()
    }

    func reloadProviderConfiguration() {
        guard isConnected, !isPreview else { return }
        // A config change supersedes any snapshot already being collected.
        stopPresentation()
        refresh()
        startPresentation()
    }

    /// Asks for a local-token pass soon, for example after an agent session finishes. The lane keeps
    /// its minimum spacing, runs only while quota polling is idle, and never prompts.
    func requestObservedTokenRefresh(after delay: TimeInterval = PeelLocalTokenLanePolicy.minimumSpacing) {
        guard isConnected, !isPreview else { return }
        let earliest = (lastTokenPassFinishedAt ?? .distantPast)
            .addingTimeInterval(PeelLocalTokenLanePolicy.minimumSpacing)
        let requested = max(Date.now.addingTimeInterval(max(0, delay)), earliest)
        if requested < nextTokenRefresh {
            nextTokenRefresh = requested
        }
    }

    func refresh(includeCost: Bool = false) {
        guard isConnected, !isPreview, !isRefreshing else { return }
        let executable = helperURL
        let token = PeelUsageCancellation()
        let requestID = UUID()
        let mode: PeelUsageCommandMode = includeCost ? .full : .allowances
        generation = requestID
        cancellation = token
        isRefreshing = true
        errorMessage = nil
        if includeCost {
            costErrorMessage = nil
            // An explicit Refresh also refreshes this Mac's token detail once quota is read.
            tokenRefreshForced = true
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result {
                let data = try PeelUsageCommand.run(executable: executable, cancellation: token, mode: mode)
                return try PeelUsageSnapshotParser.parse(data)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == requestID else { return }
                self.cancellation = nil
                self.isRefreshing = false
                switch result {
                case .success(let snapshot):
                    if case let .incompatible(rejected) = snapshot.decodeHealth {
                        // Every row was unreadable: this is a helper/contract mismatch, not an empty
                        // provider selection. Keep the previous readings and back off.
                        self.failureCount = min(self.failureCount + 1, 4)
                        self.rejectedProviderCount = rejected
                        let message = "The usage helper returned \(rejected) provider "
                            + (rejected == 1 ? "row" : "rows")
                            + " this Peel version can't read. Previous readings are kept."
                        if mode == .full {
                            self.costErrorMessage = message
                        } else {
                            self.errorMessage = message
                        }
                    } else {
                        self.apply(snapshot, mode: mode, receivedAt: .now)
                        self.failureCount = 0
                        if mode == .full {
                            self.costErrorMessage = nil
                        }
                    }
                case .failure(let error):
                    self.failureCount = min(self.failureCount + 1, 4)
                    if mode == .full {
                        self.costErrorMessage = error.localizedDescription
                    } else {
                        self.errorMessage = error.localizedDescription
                    }
                }
                let base: TimeInterval = ProcessInfo.processInfo.isLowPowerModeEnabled ? 180 : 60
                self.nextRefresh = Date.now.addingTimeInterval(base * pow(2, Double(self.failureCount)))
                self.startTokenLaneIfDue()
            }
        }
    }

    private var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/CodexBarCLI")
    }

    private func apply(_ incoming: PeelUsageSnapshot, mode: PeelUsageCommandMode, receivedAt: Date) {
        recordHistory(incoming, at: receivedAt)
        rejectedProviderCount = incoming.rejectedProviderCount
        let merged: PeelUsageSnapshot
        if mode == .allowances {
            merged = PeelUsageSnapshotMerge.mergeAllowance(incoming: incoming, previous: snapshot)
            if snapshotContainsCost(incoming) {
                costSnapshotGeneratedAt = incoming.generatedAt
            }
            costObservedAt = PeelUsageSnapshotMerge.costObservationDates(
                merged: merged,
                incoming: incoming,
                previous: costObservedAt)
        } else {
            merged = incoming
            costSnapshotGeneratedAt = snapshotContainsCost(incoming) ? incoming.generatedAt : nil
            costObservedAt = PeelUsageSnapshotMerge.costObservationDates(
                merged: merged,
                incoming: incoming,
                previous: [:])
        }
        snapshot = merged
        // Only local-log rows with token detail are recorded; a no-cost poll changes nothing here.
        for id in tokenLedger.applyDashboard(incoming, receivedAt: receivedAt) {
            dashboardTokenProviders[id] = receivedAt
        }
    }

    // MARK: - Local token lane

    private func startTokenLaneIfDue(now: Date = .now) {
        guard isConnected, !isPreview, !isRefreshing, !isCollectingTokens, snapshot != nil else { return }
        guard tokenRefreshForced || now >= nextTokenRefresh else { return }
        let eligible = PeelLocalTokenLanePolicy.eligibleProviders(enabledProviderIDs: providers.map(\.id))
        tokenLedger.prune(keeping: Set(eligible.map(\.rawValue)))
        let forced = tokenRefreshForced
        tokenRefreshForced = false
        // A forced pass skips providers whose token detail just arrived with the full dashboard.
        let pending = eligible.filter { provider in
            guard forced, let received = dashboardTokenProviders[provider.rawValue] else { return true }
            return now.timeIntervalSince(received) >= 60
        }
        guard helperSupportsCompactTokens != false, !pending.isEmpty else {
            if helperSupportsCompactTokens == false {
                tokenLedger.markHelperUnsupported(eligible.map(\.rawValue), at: now)
            }
            scheduleNextTokenPass(after: now)
            return
        }

        let executable = helperURL
        let token = PeelUsageCancellation()
        let laneID = UUID()
        let needsProbe = helperSupportsCompactTokens == nil
        let probe = PeelUsageCommandMode.costCapabilities
        let requests = pending.map { ($0, PeelUsageCommandMode.localTokens($0)) }
        tokenGeneration = laneID
        tokenCancellation = token
        tokenPassHadFailure = false
        isCollectingTokens = true

        // One provider per helper invocation, sequentially, on a background queue. Each result is
        // published as it arrives; nothing raw is logged or persisted.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            if needsProbe {
                let supported = (try? PeelUsageCommand.run(
                    executable: executable,
                    cancellation: token,
                    mode: probe))
                    .map { PeelLocalTokenLanePolicy.helperSupportsCompactCost(helpOutput: $0) }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.tokenGeneration == laneID, let supported else { return }
                    self.helperSupportsCompactTokens = supported
                    if !supported {
                        self.tokenLedger.markHelperUnsupported(pending.map(\.rawValue), at: .now)
                    }
                }
                if supported == false {
                    DispatchQueue.main.async { [weak self] in self?.finishTokenLane(laneID) }
                    return
                }
            }
            for (provider, mode) in requests {
                if token.isCancelled { break }
                let result: Result<PeelObservedTokenUsage, PeelObservedTokenFailure>
                do {
                    let output = try PeelUsageCommand.runCapturingStatus(
                        executable: executable,
                        cancellation: token,
                        mode: mode)
                    result = PeelObservedTokenParser.parse(
                        output.data,
                        providerID: provider.rawValue,
                        receivedAt: .now)
                } catch {
                    result = .failure(PeelObservedTokenFailure(commandError: error))
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.tokenGeneration == laneID else { return }
                    if self.tokenLedger.apply(result, providerID: provider.rawValue, at: .now) {
                        self.tokenPassHadFailure = true
                    }
                    if case .failure(.helperRejectedArguments) = result {
                        self.helperSupportsCompactTokens = false
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in self?.finishTokenLane(laneID) }
        }
    }

    private func finishTokenLane(_ laneID: UUID) {
        guard tokenGeneration == laneID else { return }
        tokenCancellation = nil
        isCollectingTokens = false
        let now = Date.now
        lastTokenPassFinishedAt = now
        tokenFailureCount = tokenPassHadFailure
            ? min(tokenFailureCount + 1, PeelLocalTokenLanePolicy.maximumBackoffExponent)
            : 0
        scheduleNextTokenPass(after: now)
    }

    private func scheduleNextTokenPass(after date: Date) {
        nextTokenRefresh = PeelLocalTokenLanePolicy.nextAttempt(
            after: date,
            consecutiveFailures: tokenFailureCount,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    private func stopTokenLane() {
        tokenCancellation?.cancel()
        tokenCancellation = nil
        tokenGeneration = UUID()
        isCollectingTokens = false
    }

    // MARK: - History

    private func loadHistory() {
        guard !isPreview else { isHistoryLoaded = true; return }
        let url = historyURL
        historyQueue.async { [weak self] in
            let result = Result { try PeelUsageHistory.load(from: url) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let loaded): self.history = loaded
                case .failure:
                    // Preserve unreadable data for recovery instead of silently overwriting it.
                    self.historyCanPersist = false
                    self.historyErrorMessage = "Saved usage history could not be read. New readings remain in memory."
                }
                self.isHistoryLoaded = true
                let pending = self.pendingHistorySnapshots
                self.pendingHistorySnapshots.removeAll()
                for (snapshot, date) in pending { self.recordHistory(snapshot, at: date) }
            }
        }
    }

    private func recordHistory(_ snapshot: PeelUsageSnapshot, at date: Date) {
        guard isHistoryLoaded else {
            pendingHistorySnapshots.append((snapshot, date))
            pendingHistorySnapshots = Array(pendingHistorySnapshots.suffix(8))
            return
        }
        guard history.record(snapshot, receivedAt: date), historyCanPersist else { return }
        let recorded = history
        let url = historyURL
        // One queue preserves write order across refreshes; disk work never blocks UI sampling.
        historyQueue.async { [weak self] in
            let result = Result { try recorded.save(to: url) }
            DispatchQueue.main.async { [weak self] in
                switch result {
                case .success: self?.historyErrorMessage = nil
                case .failure:
                    self?.historyErrorMessage = "Usage history could not be saved. Readings are available for this session."
                }
            }
        }
    }

    private func snapshotContainsCost(_ snapshot: PeelUsageSnapshot) -> Bool {
        snapshot.providers.contains { $0.cost != nil }
    }
}
