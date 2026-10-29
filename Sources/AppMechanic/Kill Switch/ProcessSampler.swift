//
//  ProcessSampler.swift
//  Kill Switch
//

import Foundation
import AppKit
import Darwin
import UserNotifications
import Combine

@MainActor
final class ProcessSampler: ObservableObject {
    @Published var topApp: ProcessSample?
    @Published var topApps: [ProcessSample] = []
    @Published var lastUpdated: Date?
    @Published var lastError: String?
    @Published var isInteractionFrozen = false
    @Published var selectedScope: ProcessScope = .appsOnly
    @Published var selectedMetric: UsageMetric = .memory
    @Published var systemCPUPercent: Double = 0
    @Published var systemMemoryUsedPercent: Double = 0
    @Published var systemMemoryPressureState: MemoryPressureState = .normal
    @Published private(set) var hasSystemCPUSample = false
    @Published private(set) var hasSystemMemorySample = false
    let maxListedApps = ProcessSampler.maximumDisplayedApps

    @Published var alertRules: [IntentAlertRule] = []
    @Published var recentAlertEvents: [IntentAlertEvent] = []
    @Published var isNotificationAlertsEnabled = true
    @Published var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var isRefreshing = false
    @Published private(set) var runawayMemoryProtection = RunawayMemoryProtection.defaultRule
    @Published private(set) var heldProcesses: [HeldProcess] = []
    
    private let activeRefreshInterval: TimeInterval = 5.0
    private let elevatedLoadRefreshInterval: TimeInterval = 10.0
    private let lowPowerRefreshInterval: TimeInterval = 15.0
    private let criticalRefreshInterval: TimeInterval = 30.0
    nonisolated private static let psTimeoutSeconds: TimeInterval = 2.5
    nonisolated private static let maxPSOutputBytes = 4 * 1024 * 1024
    nonisolated private static let maxCachedAppIdentities = 96

    var notificationAuthorizationDescription: String {
        switch notificationAuthorizationStatus {
        case .authorized:
            return isNotificationAlertsEnabled
                ? "Notifications are enabled and ready to fire."
                : "Notifications are allowed, but App Mechanic alert notifications are currently turned off."
        case .provisional:
            return isNotificationAlertsEnabled
                ? "Notifications are provisionally allowed. App Mechanic can send alerts quietly."
                : "Notifications are provisionally allowed, but App Mechanic alert notifications are currently turned off."
        case .ephemeral:
            return isNotificationAlertsEnabled
                ? "Notifications are temporarily allowed for this app session."
                : "Notifications are temporarily allowed, but App Mechanic alert notifications are currently turned off."
        case .denied:
            return "Notifications are turned off in macOS settings. Enable them there to receive App Mechanic alerts."
        case .notDetermined:
            return "App Mechanic has not requested notification permission yet. Turn this on to allow alert notifications."
        @unknown default:
            return "Notification permission status is unavailable."
        }
    }

    var canDeliverNotifications: Bool {
        notificationAuthorizationStatus == .authorized || notificationAuthorizationStatus == .provisional
    }

    var menuBarLoadState: MenuBarLoadState {
        switch selectedMetric {
        case .cpu:
            return MenuBarLoadState(cpuPercent: systemCPUPercent)
        case .memory:
            return MenuBarLoadState(memoryPercent: memoryGaugePercent)
        }
    }

    var currentMetricLoadPercent: Double {
        switch selectedMetric {
        case .cpu:
            return systemCPUPercent
        case .memory:
            return memoryGaugePercent
        }
    }

    var mostStressedUsageMetric: UsageMetric {
        memoryGaugePercent > systemCPUPercent ? .memory : .cpu
    }

    var memoryGaugePercent: Double {
        switch systemMemoryPressureState {
        case .normal:
            return min(30, max(12, systemMemoryUsedPercent * 0.35))
        case .warning:
            return min(85, max(60, 60 + ((systemMemoryUsedPercent - 60) * 0.5)))
        case .critical:
            return 100
        }
    }

    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = UUID()
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var previousSystemCPUTicks: SystemCPUTicks?
    private var fullSampledProcesses: [ProcessSample] = []
    private var previousAlertMatchStates: [UUID: Bool] = [:]
    private var consecutiveAlertMatchCounts: [UUID: Int] = [:]
    private var previousTopAppIdentity: String?
    private var lastTriggeredDates: [UUID: Date] = [:]
    private var appIdentityCache: [pid_t: CachedAppIdentity] = [:]
    private var sampledProcessFamilies: [pid_t: [pid_t]] = [:]
    private var protectionMatchCounts: [pid_t: Int] = [:]
    private var hasChosenInitialMetric = false

    private static let alertRulesKey = "intentAlertRules"
    private static let runawayMemoryProtectionKey = "runawayMemoryProtection"
    private static let heldProcessesKey = "heldProcesses"
    static let maximumDisplayedApps = 64

    nonisolated private static let psLineRegex = try? NSRegularExpression(
        pattern: #"^\s*(\d+)\s+(\d+)\s+([\d.]+)\s+(\d+)\s+([\d:-]+)\s+(.+)$"#
    )

    init() {
#if PEEL_HOST_INTEGRATION
        if ProcessInfo.processInfo.arguments.contains("--peel-preview") { return }
#endif
        loadAlertRules()
        loadRunawayMemoryProtection()
        loadHeldProcesses()
        refreshNotificationAuthorizationStatus()
        startMemoryPressureMonitoring()
        refresh()
        start()
    }

    deinit {
        timer?.invalidate()
        refreshTask?.cancel()
        memoryPressureSource?.cancel()
    }

    func start() {
        guard timer == nil else { return }

        scheduleNextRefresh()
    }

    private func scheduleNextRefresh() {
        guard timer == nil else { return }

        let interval = preferredRefreshInterval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }

                self.timer = nil
                self.refresh()
                self.scheduleNextRefresh()
            }
        }

        timer?.tolerance = interval * 0.25
    }

    private var preferredRefreshInterval: TimeInterval {
        let processInfo = ProcessInfo.processInfo

        if processInfo.thermalState == .critical || systemMemoryPressureState == .critical {
            return criticalRefreshInterval
        }

        if processInfo.isLowPowerModeEnabled
            || processInfo.thermalState == .serious
            || systemMemoryPressureState == .warning {
            return lowPowerRefreshInterval
        }

        if systemCPUPercent >= 85 {
            return elevatedLoadRefreshInterval
        }

        return activeRefreshInterval
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        refreshGeneration = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
    }

    func updateSelectedScope(_ scope: ProcessScope) {
        guard scope == .appsOnly else {
            if selectedScope != .appsOnly {
                selectedScope = .appsOnly
                refresh()
            }
            return
        }

        guard selectedScope != .appsOnly else { return }
        selectedScope = .appsOnly
        refresh()
    }

    func updateSelectedMetric(_ metric: UsageMetric) {
        hasChosenInitialMetric = true
        guard selectedMetric != metric else { return }
        selectedMetric = metric
        sortApplications()
    }

    func selectMostStressedMetric() {
        updateSelectedMetric(mostStressedUsageMetric)
    }

    func setInteractionFrozen(_ frozen: Bool) {
        let wasFrozen = isInteractionFrozen
        isInteractionFrozen = frozen

        if wasFrozen && !frozen {
            sortApplications()
        }
    }

    func refresh() {
        guard !isRefreshing else { return }

        refreshTask?.cancel()
        isRefreshing = true

        refreshSystemMetrics()

        let selectedScope: ProcessScope = .appsOnly
        if self.selectedScope != .appsOnly {
            self.selectedScope = .appsOnly
        }
        let selectedMetric = self.selectedMetric
        let maxListedApps = self.maxListedApps
        let appIdentityCache = self.appIdentityCache
        let myPID = ProcessInfo.processInfo.processIdentifier
        let currentBundleIdentifier = Bundle.main.bundleIdentifier
        let currentExecutableName = Bundle.main.executableURL?
            .deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let currentDisplayName = (
            Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ""
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        let regularApplications = regularApplicationIdentities(
            excludingPID: myPID,
            currentBundleIdentifier: currentBundleIdentifier
        )

        let generation = UUID()
        refreshGeneration = generation
        // A priority alone does not leave MainActor. Keep process I/O and parsing
        // off the UI thread; publish only the finished, current sample on MainActor.
        refreshTask = Task.detached(priority: .utility) { [weak self] in
            do {
                try Task.checkCancellation()

                let samplingResult = try autoreleasepool {
                    guard let sampler = self else { throw CancellationError() }
                    return try sampler.sampleTopApplications(
                        selectedScope: selectedScope,
                        selectedMetric: selectedMetric,
                        myPID: myPID,
                        currentBundleIdentifier: currentBundleIdentifier,
                        currentExecutableName: currentExecutableName,
                        currentDisplayName: currentDisplayName,
                        maxListedApps: maxListedApps,
                        appIdentityCache: appIdentityCache,
                        regularApplications: regularApplications
                    )
                }

                try Task.checkCancellation()

                let latestSamples = samplingResult.samples

                await MainActor.run {
                    guard let self, self.refreshGeneration == generation, !Task.isCancelled else { return }

                    self.appIdentityCache = samplingResult.appIdentityCache
                    self.fullSampledProcesses = latestSamples
                    self.sampledProcessFamilies = samplingResult.processFamilies
                    self.reconcileHeldProcesses(using: latestSamples)
                    self.evaluateAlerts(using: latestSamples)
                    let didHoldRunawayApp = self.evaluateRunawayMemoryProtection(using: latestSamples)

                    if self.topApps.isEmpty || didHoldRunawayApp {
                        self.topApps = latestSamples
                        self.sortApplications()
                    } else if self.isInteractionFrozen {
                        self.mergeLatestSamplesPreservingOrder(latestSamples)
                        self.refreshDisplayedValuesPreservingOrder()
                    } else if self.samplesNeedDisplayUpdate(self.topApps, latestSamples) {
                        self.topApps = latestSamples
                        self.sortApplications()
                    } else {
                        self.refreshDisplayedValuesPreservingOrder()
                    }

                    self.lastUpdated = Date()
                    self.lastError = nil
                    self.isRefreshing = false
                    self.refreshTask = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard let self, self.refreshGeneration == generation else { return }
                    self.isRefreshing = false
                    self.refreshTask = nil
                }
            } catch {
                await MainActor.run {
                    guard let self, self.refreshGeneration == generation else { return }
                    self.lastError = error.localizedDescription
                    self.isRefreshing = false
                    self.refreshTask = nil
                }
            }
        }
    }

    func metricText(for sample: ProcessSample) -> String {
        switch selectedMetric {
        case .cpu:
            return String(format: "CPU: %.1f%%", sample.cpu)
        case .memory:
            return String(format: "Memory: %.1f MB", sample.memoryMB)
        }
    }

    func isHeld(_ sample: ProcessSample) -> Bool {
        heldProcesses.contains { $0.pid == sample.pid }
    }

    func updateRunawayMemoryProtection(_ rule: RunawayMemoryProtection) {
        runawayMemoryProtection = rule.sanitized
        protectionMatchCounts.removeAll()
        saveRunawayMemoryProtection()
    }

    func hold(_ sample: ProcessSample) {
        _ = holdProcessFamily(sample, automatically: false)
    }

    func resume(_ sample: ProcessSample) {
        guard let held = heldProcesses.first(where: { $0.pid == sample.pid }) else {
            lastError = "\(sample.appName) is not currently held by App Mechanic."
            return
        }

        let failures = signalProcessIDs(
            held.processIDs,
            signal: SIGCONT,
            rootPID: held.pid,
            rootLast: false
        )

        if failures.isEmpty {
            heldProcesses.removeAll { $0.pid == held.pid }
            saveHeldProcesses()
            lastError = nil
            recordProtectionEvent(
                name: "App resumed",
                message: "\(held.appName) was resumed."
            )
            refresh()
        } else {
            lastError = "Could not fully resume \(held.appName): \(failures.joined(separator: ", "))."
        }
    }

    func resumeAllHeldForTermination() {
        for held in heldProcesses {
            _ = signalProcessIDs(
                held.processIDs,
                signal: SIGCONT,
                rootPID: held.pid,
                rootLast: false
            )
        }
        heldProcesses.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.heldProcessesKey)
    }

    func forceQuit(_ sample: ProcessSample) {
        guard isCurrentProcess(sample) else {
            lastError = "Force Quit skipped for PID \(sample.pid): the sampled process identity is unavailable or changed. Refresh and try again."
            return
        }

        if let app = NSRunningApplication(processIdentifier: sample.pid) {
            let didTerminate = app.forceTerminate()

            if didTerminate {
                removeHeldProcess(pid: sample.pid)
                lastError = nil
                refresh()
                return
            }
        }

        let result = kill(sample.pid, SIGKILL)
        if result == 0 {
            removeHeldProcess(pid: sample.pid)
            lastError = nil
            refresh()
        } else {
            lastError = "Failed to kill \(sample.appName)."
        }
    }

    /// Rechecks the kernel process identity immediately before an action.
    /// Callers may use this for UI feedback, but forceQuit repeats the check at
    /// its termination boundary as well.
    func isCurrentProcess(_ sample: ProcessSample) -> Bool {
        guard let expectedStartTime = sample.processStartTime,
              let currentStartTime = Self.currentProcessStartTime(for: sample.pid),
              currentStartTime == expectedStartTime else {
            return false
        }

        guard let running = NSRunningApplication(processIdentifier: sample.pid) else {
            // A matching kernel start time is sufficient for a non-application process
            // that has no NSRunningApplication wrapper.
            return true
        }

        if let expectedBundleIdentifier = normalizedIdentity(sample.bundleIdentifier),
           running.bundleIdentifier != expectedBundleIdentifier {
            return false
        }

        if let expectedBundleURLPath = normalizedPath(sample.bundleURLPath),
           normalizedPath(running.bundleURL?.path) != expectedBundleURLPath {
            return false
        }

        if let expectedExecutablePath = normalizedPath(sample.executablePath),
           normalizedPath(running.executableURL?.path) != expectedExecutablePath {
            return false
        }

        return true
    }

    private func normalizedIdentity(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedPath(_ value: String?) -> String? {
        guard let value = normalizedIdentity(value) else { return nil }

        return URL(fileURLWithPath: value)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    func open(_ sample: ProcessSample) {
        guard !isHeld(sample) else {
            lastError = "\(sample.appName) is held. Resume or Force Quit it first."
            return
        }

        if let app = NSRunningApplication(processIdentifier: sample.pid),
           app.activationPolicy == .regular {
            let didActivate = app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            if !didActivate {
                lastError = "Failed to open \(sample.appName)."
            } else {
                lastError = nil
            }
            return
        }

        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            Task { @MainActor in
                if let error {
                    self.lastError = error.localizedDescription
                } else {
                    self.lastError = nil
                }
            }
        }
    }

    
    private func refreshSystemMetrics() {
        let hadPreviousSystemCPUTicks = previousSystemCPUTicks != nil

        if let cpuPercent = sampleSystemCPUPercent() {
            systemCPUPercent = cpuPercent
            hasSystemCPUSample = true
        }

        if let memoryUsedPercent = sampleSystemMemoryUsedPercent() {
            systemMemoryUsedPercent = memoryUsedPercent
            hasSystemMemorySample = true
        }

        if !hasChosenInitialMetric,
           hadPreviousSystemCPUTicks,
           hasSystemCPUSample,
           hasSystemMemorySample {
            selectMostStressedMetric()
        }
    }

    private func startMemoryPressureMonitoring() {
        guard memoryPressureSource == nil else { return }

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .main
        )

        source.setEventHandler { [weak self, weak source] in
            guard let event = source?.data else { return }
            self?.systemMemoryPressureState = MemoryPressureState(event: event)
        }

        source.resume()
        memoryPressureSource = source
    }

    private func sampleSystemCPUPercent() -> Double? {
        guard let currentTicks = readSystemCPUTicks() else { return nil }
        defer { previousSystemCPUTicks = currentTicks }

        guard let previousTicks = previousSystemCPUTicks else { return 0 }

        let userDelta = max(0, currentTicks.user - previousTicks.user)
        let systemDelta = max(0, currentTicks.system - previousTicks.system)
        let idleDelta = max(0, currentTicks.idle - previousTicks.idle)
        let niceDelta = max(0, currentTicks.nice - previousTicks.nice)

        let activeDelta = userDelta + systemDelta + niceDelta
        let totalDelta = activeDelta + idleDelta

        guard totalDelta > 0 else { return 0 }

        let percent = (Double(activeDelta) / Double(totalDelta)) * 100.0
        return min(max(percent, 0), 100)
    }

    private func readSystemCPUTicks() -> SystemCPUTicks? {
        var cpuInfo = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)

        let result = withUnsafeMutablePointer(to: &cpuInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { integerPointer in
                host_statistics(
                    mach_host_self(),
                    host_flavor_t(HOST_CPU_LOAD_INFO),
                    integerPointer,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else { return nil }

        return SystemCPUTicks(
            user: UInt64(cpuInfo.cpu_ticks.0),
            system: UInt64(cpuInfo.cpu_ticks.1),
            idle: UInt64(cpuInfo.cpu_ticks.2),
            nice: UInt64(cpuInfo.cpu_ticks.3)
        )
    }

    private func sampleSystemMemoryUsedPercent() -> Double? {
        var vmStats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)

        let result = withUnsafeMutablePointer(to: &vmStats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { integerPointer in
                host_statistics64(
                    mach_host_self(),
                    host_flavor_t(HOST_VM_INFO64),
                    integerPointer,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else { return nil }

        let pageSize = Double(vm_kernel_page_size)
        let physicalMemoryBytes = Double(ProcessInfo.processInfo.physicalMemory)
        guard pageSize > 0, physicalMemoryBytes > 0 else { return nil }

        let activeBytes = Double(vmStats.active_count) * pageSize
        let wiredBytes = Double(vmStats.wire_count) * pageSize
        let compressedBytes = Double(vmStats.compressor_page_count) * pageSize
        let cachedInactivePages = max(Int64(vmStats.inactive_count) - Int64(vmStats.speculative_count), 0)
        let cachedInactiveBytes = Double(cachedInactivePages) * pageSize

        let usedBytes = activeBytes + wiredBytes + compressedBytes + cachedInactiveBytes
        let percent = (usedBytes / physicalMemoryBytes) * 100.0
        return min(max(percent, 0), 100)
    }

    // MARK: - Runaway Memory Protection

    private func evaluateRunawayMemoryProtection(
        using latestSamples: [ProcessSample]
    ) -> Bool {
        let rule = runawayMemoryProtection.sanitized
        guard rule.isEnabled else {
            protectionMatchCounts.removeAll()
            return false
        }

        let matchValue = rule.appMatch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !matchValue.isEmpty else {
            protectionMatchCounts.removeAll()
            return false
        }

        let matchingSamples = latestSamples.filter { sample in
            matchesWatchedApp(matchValue, sample: sample)
        }
        let matchingPIDs = Set(matchingSamples.map(\.pid))
        protectionMatchCounts = protectionMatchCounts.filter { matchingPIDs.contains($0.key) }

        guard let offender = matchingSamples.max(by: { $0.memoryMB < $1.memoryMB }),
              !isHeld(offender) else {
            return false
        }

        guard offender.memoryMB >= rule.memoryThresholdMB else {
            protectionMatchCounts[offender.pid] = 0
            return false
        }

        protectionMatchCounts[offender.pid] = 1
        return holdProcessFamily(offender, automatically: true)
    }

    @discardableResult
    private func holdProcessFamily(
        _ sample: ProcessSample,
        automatically: Bool
    ) -> Bool {
        guard !isHeld(sample) else { return false }

        let myPID = ProcessInfo.processInfo.processIdentifier
        let family = sampledProcessFamilies[sample.pid] ?? [sample.pid]
        let processIDs = Array(
            Set(family.filter { $0 > 1 && $0 != myPID } + [sample.pid])
        )
        .prefix(4_096)
        .map { $0 }

        let failures = signalProcessIDs(
            processIDs,
            signal: SIGSTOP,
            rootPID: sample.pid,
            rootLast: true
        )

        guard !failures.contains(where: { $0.hasPrefix("PID \(sample.pid)") }) else {
            _ = signalProcessIDs(
                processIDs,
                signal: SIGCONT,
                rootPID: sample.pid,
                rootLast: false
            )
            lastError = "Could not hold \(sample.appName): \(failures.joined(separator: ", "))."
            return false
        }

        let held = HeldProcess(
            pid: sample.pid,
            appName: sample.appName,
            bundleIdentifier: sample.bundleIdentifier,
            executablePath: sample.executablePath,
            memoryMBAtHold: sample.memoryMB,
            heldAt: Date(),
            processIDs: processIDs
        )
        heldProcesses.removeAll { $0.pid == sample.pid }
        heldProcesses.insert(held, at: 0)
        saveHeldProcesses()

        hasChosenInitialMetric = true
        selectedMetric = .memory
        topApps = fullSampledProcesses
        sortApplications()
        lastError = nil

        let memoryText = Self.formattedMemory(sample.memoryMB)
        let message: String
        if automatically {
            message = "\(sample.appName) reached \(memoryText) across its app processes and was held. Resume it or Force Quit it in App Mechanic."
        } else {
            message = "\(sample.appName) was held at \(memoryText). Resume it or Force Quit it when ready."
        }

        recordProtectionEvent(name: "App held", message: message)
        if isNotificationAlertsEnabled {
            deliverUserNotification(
                identifier: "runaway-memory-held-\(sample.pid)",
                title: "App held",
                body: message
            )
        }
        return true
    }

    private func signalProcessIDs(
        _ processIDs: [pid_t],
        signal: Int32,
        rootPID: pid_t,
        rootLast: Bool
    ) -> [String] {
        let unique = Array(Set(processIDs))
        let ordered = unique.sorted { lhs, rhs in
            if lhs == rootPID { return !rootLast }
            if rhs == rootPID { return rootLast }
            return lhs < rhs
        }

        var failures: [String] = []
        for pid in ordered {
            errno = 0
            if kill(pid, signal) == 0 {
                continue
            }

            let errorCode = errno
            if errorCode == ESRCH {
                continue
            }

            failures.append("PID \(pid) \(String(cString: strerror(errorCode)))")
        }
        return failures
    }

    private func reconcileHeldProcesses(using samples: [ProcessSample]) {
        guard !heldProcesses.isEmpty else { return }
        let samplesByPID = Dictionary(uniqueKeysWithValues: samples.map { ($0.pid, $0) })
        let original = heldProcesses

        heldProcesses.removeAll { held in
            guard let sample = samplesByPID[held.pid] else { return true }
            if let heldBundleID = held.bundleIdentifier,
               let currentBundleID = sample.bundleIdentifier {
                return heldBundleID != currentBundleID
            }
            return held.appName != sample.appName
        }

        if heldProcesses != original {
            saveHeldProcesses()
        }
    }

    private func removeHeldProcess(pid: pid_t) {
        let originalCount = heldProcesses.count
        heldProcesses.removeAll { $0.pid == pid }
        if heldProcesses.count != originalCount {
            saveHeldProcesses()
        }
    }

    private func recordProtectionEvent(name: String, message: String) {
        recentAlertEvents.insert(
            IntentAlertEvent(ruleName: name, message: message, date: Date()),
            at: 0
        )
        if recentAlertEvents.count > 30 {
            recentAlertEvents = Array(recentAlertEvents.prefix(30))
        }
    }

    private static func formattedMemory(_ memoryMB: Double) -> String {
        if memoryMB >= 1_024 {
            return String(format: "%.1f GB", memoryMB / 1_024)
        }
        return String(format: "%.0f MB", memoryMB)
    }

    // MARK: - Alerts

    func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.isNotificationAlertsEnabled = granted
                self?.refreshNotificationAuthorizationStatus()
            }
        }
    }

    func setNotificationAlertsEnabled(_ isEnabled: Bool) {
        if isEnabled {
            switch notificationAuthorizationStatus {
            case .authorized, .provisional, .ephemeral:
                isNotificationAlertsEnabled = true

            case .notDetermined:
                requestNotificationAuthorization()

            case .denied:
                isNotificationAlertsEnabled = false
                openNotificationSettings()

            @unknown default:
                isNotificationAlertsEnabled = false
            }
        } else {
            isNotificationAlertsEnabled = false
        }
    }

    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    func refreshNotificationAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.notificationAuthorizationStatus = settings.authorizationStatus

                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    if self?.isNotificationAlertsEnabled == false {
                        // preserve the user's local off toggle
                    } else {
                        self?.isNotificationAlertsEnabled = true
                    }
                case .denied:
                    self?.isNotificationAlertsEnabled = false
                case .notDetermined:
                    self?.isNotificationAlertsEnabled = true
                @unknown default:
                    self?.isNotificationAlertsEnabled = false
                }
            }
        }
    }

    func addWatchedAppAlert(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let newRule = IntentAlertRule.appWatch(named: trimmed)
        alertRules.append(newRule)
        saveAlertRules()
    }

    func updateAlert(_ rule: IntentAlertRule) {
        guard let index = alertRules.firstIndex(where: { $0.id == rule.id }) else { return }
        alertRules[index] = rule
        saveAlertRules()
    }
    
    func resetAlertsToDefaults() {
        alertRules = IntentAlertRule.defaultRules
        runawayMemoryProtection = .defaultRule
        previousAlertMatchStates.removeAll()
        consecutiveAlertMatchCounts.removeAll()
        protectionMatchCounts.removeAll()
        previousTopAppIdentity = nil
        lastTriggeredDates.removeAll()
        saveAlertRules()
        saveRunawayMemoryProtection()
    }

    func removeAlert(_ ruleID: UUID) {
        alertRules.removeAll { $0.id == ruleID }
        previousAlertMatchStates.removeValue(forKey: ruleID)
        consecutiveAlertMatchCounts.removeValue(forKey: ruleID)
        lastTriggeredDates.removeValue(forKey: ruleID)
        saveAlertRules()
    }

    func testAlert(_ ruleID: UUID) {
        guard let rule = alertRules.first(where: { $0.id == ruleID }) else { return }

        recordAlertEvent(
            rule: rule,
            message: "Manual test notification fired."
        )

        deliverUserNotification(
            identifier: "intent-alert-test-\(rule.id.uuidString)",
            title: rule.name,
            body: "Manual test notification fired."
        )
    }

    func clearAlertHistory() {
        recentAlertEvents.removeAll()
    }

    private func evaluateAlerts(using latestSamples: [ProcessSample]) {
        let currentTopIdentity = topIdentity(from: latestSamples.first)

        for rule in alertRules {
            guard rule.isEnabled else {
                previousAlertMatchStates[rule.id] = false
                consecutiveAlertMatchCounts[rule.id] = 0
                continue
            }

            switch rule.trigger {
            case .topAppChanged:
                guard let currentTop = latestSamples.first else {
                    previousTopAppIdentity = currentTopIdentity
                    continue
                }

                if previousTopAppIdentity == nil {
                    previousTopAppIdentity = currentTopIdentity
                    continue
                }

                let didChange = currentTopIdentity != nil && currentTopIdentity != previousTopAppIdentity
                if didChange, canTrigger(rule) {
                    let message = "\(currentTop.appName) is now the most active \(selectedMetric.displayName.lowercased()) item."
                    fireAlert(rule: rule, message: message)
                }

                previousTopAppIdentity = currentTopIdentity

            case .cpuThresholdExceeded:
                guard let offender = latestSamples.max(by: { $0.cpu < $1.cpu }) else {
                    previousAlertMatchStates[rule.id] = false
                    consecutiveAlertMatchCounts[rule.id] = 0
                    continue
                }

                let isMatched = offender.cpu >= rule.cpuThreshold
                handleThresholdTransition(
                    rule: rule,
                    isMatched: isMatched,
                    message: "\(offender.appName) reached \(String(format: "%.1f", offender.cpu))% CPU."
                )

            case .memoryThresholdExceeded:
                guard let offender = latestSamples.max(by: { $0.memoryMB < $1.memoryMB }) else {
                    previousAlertMatchStates[rule.id] = false
                    consecutiveAlertMatchCounts[rule.id] = 0
                    continue
                }

                let isMatched = offender.memoryMB >= rule.memoryThresholdMB
                handleThresholdTransition(
                    rule: rule,
                    isMatched: isMatched,
                    message: "\(offender.appName) reached \(String(format: "%.1f", offender.memoryMB)) MB memory."
                )

            case .appAppeared:
                let matchValue = rule.watchedAppName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !matchValue.isEmpty else {
                    previousAlertMatchStates[rule.id] = false
                    consecutiveAlertMatchCounts[rule.id] = 0
                    continue
                }

                let matchingSample = latestSamples.first { sample in
                    matchesWatchedApp(matchValue, sample: sample)
                }

                let isMatched = matchingSample != nil
                let message = matchingSample.map { "\($0.appName) appeared in the current sampled set." }
                    ?? "\(matchValue) appeared."

                handleThresholdTransition(
                    rule: rule,
                    isMatched: isMatched,
                    message: message
                )
            }
        }
    }

    private func handleThresholdTransition(rule: IntentAlertRule, isMatched: Bool, message: String) {
        if isMatched {
            let newCount = (consecutiveAlertMatchCounts[rule.id] ?? 0) + 1
            consecutiveAlertMatchCounts[rule.id] = newCount

            let wasMatched = previousAlertMatchStates[rule.id] ?? false
            let metRequiredMatches = newCount >= rule.requiredConsecutiveMatches

            if metRequiredMatches && !wasMatched && canTrigger(rule) {
                fireAlert(rule: rule, message: message)
            }

            previousAlertMatchStates[rule.id] = metRequiredMatches
        } else {
            consecutiveAlertMatchCounts[rule.id] = 0
            previousAlertMatchStates[rule.id] = false
        }
    }

    private func fireAlert(rule: IntentAlertRule, message: String) {
        guard isNotificationAlertsEnabled else { return }

        lastTriggeredDates[rule.id] = Date()
        recordAlertEvent(rule: rule, message: message)
        deliverUserNotification(
            identifier: "intent-alert-\(rule.id.uuidString)",
            title: rule.name,
            body: message
        )
    }

    private func recordAlertEvent(rule: IntentAlertRule, message: String) {
        recentAlertEvents.insert(
            IntentAlertEvent(ruleName: rule.name, message: message, date: Date()),
            at: 0
        )

        if recentAlertEvents.count > 30 {
            recentAlertEvents = Array(recentAlertEvents.prefix(30))
        }
    }

    private func deliverUserNotification(identifier: String, title: String, body: String) {
        guard canDeliverNotifications else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    private func canTrigger(_ rule: IntentAlertRule) -> Bool {
        guard let lastTriggered = lastTriggeredDates[rule.id] else { return true }
        return Date().timeIntervalSince(lastTriggered) >= rule.cooldownSeconds
    }

    private func matchesWatchedApp(_ matchValue: String, sample: ProcessSample) -> Bool {
        let needle = matchValue.lowercased()

        if sample.appName.lowercased().contains(needle) {
            return true
        }

        if sample.command.lowercased().contains(needle) {
            return true
        }

        if let bundleIdentifier = sample.bundleIdentifier?.lowercased(),
           bundleIdentifier.contains(needle) {
            return true
        }

        return false
    }

    private func topIdentity(from sample: ProcessSample?) -> String? {
        guard let sample else { return nil }
        return sample.bundleIdentifier ?? "\(sample.appName.lowercased())-\(sample.pid)"
    }

    private func saveAlertRules() {
        do {
            let data = try JSONEncoder().encode(alertRules)
            UserDefaults.standard.set(data, forKey: Self.alertRulesKey)
        } catch {
            lastError = "Failed to save alerts."
        }
    }

    private func saveRunawayMemoryProtection() {
        do {
            let data = try JSONEncoder().encode(runawayMemoryProtection.sanitized)
            UserDefaults.standard.set(data, forKey: Self.runawayMemoryProtectionKey)
        } catch {
            lastError = "Failed to save runaway memory protection."
        }
    }

    private func loadRunawayMemoryProtection() {
        guard let data = UserDefaults.standard.data(forKey: Self.runawayMemoryProtectionKey),
              let decoded = try? JSONDecoder().decode(
                RunawayMemoryProtection.self,
                from: data
              ) else {
            runawayMemoryProtection = .defaultRule
            return
        }
        runawayMemoryProtection = decoded.sanitized
    }

    private func saveHeldProcesses() {
        do {
            let data = try JSONEncoder().encode(heldProcesses)
            UserDefaults.standard.set(data, forKey: Self.heldProcessesKey)
        } catch {
            lastError = "Failed to preserve held-app state."
        }
    }

    private func loadHeldProcesses() {
        guard let data = UserDefaults.standard.data(forKey: Self.heldProcessesKey),
              let decoded = try? JSONDecoder().decode([HeldProcess].self, from: data) else {
            heldProcesses = []
            return
        }
        heldProcesses = Array(decoded.prefix(16))
    }

    private func loadAlertRules() {
        guard let data = UserDefaults.standard.data(forKey: Self.alertRulesKey) else {
            alertRules = IntentAlertRule.defaultRules
            return
        }

        do {
            alertRules = try JSONDecoder().decode([IntentAlertRule].self, from: data)
        } catch {
            alertRules = IntentAlertRule.defaultRules
        }
    }

    // MARK: - Display Sorting

    private func sortApplications() {
        topApps.sort { lhs, rhs in
            switch selectedMetric {
            case .cpu:
                if lhs.cpu == rhs.cpu {
                    return lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
                }
                return lhs.cpu > rhs.cpu
            case .memory:
                if lhs.memoryMB == rhs.memoryMB {
                    return lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
                }
                return lhs.memoryMB > rhs.memoryMB
            }
        }

        topApps = Array(topApps.prefix(maxListedApps))
        topApp = topApps.first
    }

    private func mergeLatestSamplesPreservingOrder(_ latestSamples: [ProcessSample]) {
        let latestByPID = Dictionary(uniqueKeysWithValues: latestSamples.map { ($0.pid, $0) })

        let existingOrder = topApps.compactMap { current in
            latestByPID[current.pid]
        }

        let existingPIDs = Set(existingOrder.map(\.pid))
        let newSamples = latestSamples.filter { !existingPIDs.contains($0.pid) }

        topApps = Array((existingOrder + newSamples).prefix(maxListedApps))
    }

    private func refreshDisplayedValuesPreservingOrder() {
        topApps = Array(topApps.prefix(maxListedApps))
        topApp = topApps.first
    }

    
    private func samplesNeedDisplayUpdate(_ currentSamples: [ProcessSample], _ latestSamples: [ProcessSample]) -> Bool {
        let currentVisible = Array(currentSamples.prefix(maxListedApps))
        let latestVisible = Array(latestSamples.prefix(maxListedApps))

        guard currentVisible.count == latestVisible.count else { return true }

        for (current, latest) in zip(currentVisible, latestVisible) {
            guard current.pid == latest.pid else { return true }
            guard current.appName == latest.appName else { return true }
            guard current.bundleIdentifier == latest.bundleIdentifier,
                  current.bundleURLPath == latest.bundleURLPath,
                  current.executablePath == latest.executablePath,
                  current.processStartTime == latest.processStartTime else {
                return true
            }

            switch selectedMetric {
            case .cpu:
                if abs(current.cpu - latest.cpu) >= 0.5 {
                    return true
                }
            case .memory:
                if abs(current.memoryMB - latest.memoryMB) >= 10 {
                    return true
                }
            }
        }

        return false
    }

    private func memoryPressurePercent(for sample: ProcessSample) -> Double {
        let physicalMemoryMB = Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576.0
        guard physicalMemoryMB > 0 else { return 0 }
        return (sample.memoryMB / physicalMemoryMB) * 100.0
    }

    // MARK: - Sampling

    nonisolated private struct CachedAppIdentity: Sendable {
        let appName: String
        let bundleIdentifier: String?
        let bundleURLPath: String?
        let executablePath: String?
        let processType: String
    }

    nonisolated private struct SamplingResult {
        let samples: [ProcessSample]
        let appIdentityCache: [pid_t: CachedAppIdentity]
        let processFamilies: [pid_t: [pid_t]]
    }

    nonisolated private struct RawProcess {
        let pid: pid_t
        let parentPID: pid_t
        let cpu: Double
        let memoryMB: Double
        let elapsedTime: String
        let command: String
    }

    nonisolated private struct AppAggregate {
        var cpu: Double = 0
        var memoryMB: Double = 0
        var processIDs: [pid_t] = []
    }

    private struct SystemCPUTicks {
        let user: UInt64
        let system: UInt64
        let idle: UInt64
        let nice: UInt64
    }

    private func regularApplicationIdentities(
        excludingPID myPID: pid_t,
        currentBundleIdentifier: String?
    ) -> [pid_t: CachedAppIdentity] {
        var identities: [pid_t: CachedAppIdentity] = [:]

        let applications = NSWorkspace.shared.runningApplications.lazy.filter { app in
            guard app.processIdentifier != myPID,
                  app.activationPolicy == .regular else {
                return false
            }
            if let currentBundleIdentifier {
                return app.bundleIdentifier != currentBundleIdentifier
            }
            return true
        }

        for app in applications.prefix(256) {
            let executablePath = app.executableURL?.path
            let fallbackName = app.bundleURL?.deletingPathExtension().lastPathComponent
                ?? executablePath.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? "App \(app.processIdentifier)"

            identities[app.processIdentifier] = CachedAppIdentity(
                appName: app.localizedName ?? fallbackName,
                bundleIdentifier: app.bundleIdentifier,
                bundleURLPath: app.bundleURL?.path,
                executablePath: executablePath,
                processType: "App"
            )
        }
        return identities
    }

    private nonisolated static func currentProcessStartTime(for pid: pid_t) -> UInt64? {
        var processInfo = proc_bsdinfo()
        let result = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &processInfo,
            Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        guard result == MemoryLayout<proc_bsdinfo>.size else { return nil }

        let startTime = processInfo.pbi_start_tvsec * 1_000_000 + processInfo.pbi_start_tvusec
        return startTime > 0 ? startTime : nil
    }

    private nonisolated func regularAppRoot(
        for pid: pid_t,
        rawProcesses: [pid_t: RawProcess],
        regularApplications: [pid_t: CachedAppIdentity]
    ) -> pid_t? {
        var currentPID = pid
        var visited = Set<pid_t>()

        for _ in 0..<64 {
            if regularApplications[currentPID] != nil {
                return currentPID
            }
            guard visited.insert(currentPID).inserted,
                  let process = rawProcesses[currentPID],
                  process.parentPID > 1,
                  process.parentPID != currentPID else {
                return nil
            }
            currentPID = process.parentPID
        }
        return nil
    }

    private nonisolated func sampleTopApplications(
        selectedScope: ProcessScope,
        selectedMetric: UsageMetric,
        myPID: pid_t,
        currentBundleIdentifier: String?,
        currentExecutableName: String?,
        currentDisplayName: String,
        maxListedApps: Int,
        appIdentityCache: [pid_t: CachedAppIdentity],
        regularApplications: [pid_t: CachedAppIdentity]
    ) throws -> SamplingResult {
        let output = try runPS(selectedMetric: selectedMetric)
        let rawLines = output.split(whereSeparator: \.isNewline).prefix(4_096)
        var rawProcesses: [pid_t: RawProcess] = [:]
        rawProcesses.reserveCapacity(rawLines.count)

        for rawLine in rawLines {
            if Task.isCancelled { break }
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  let parsed = parsePSLine(String(line)),
                  parsed.pid != myPID else {
                continue
            }

            rawProcesses[parsed.pid] = RawProcess(
                pid: parsed.pid,
                parentPID: parsed.parentPID,
                cpu: parsed.cpu,
                memoryMB: parsed.memoryMB,
                elapsedTime: parsed.elapsedTime,
                command: parsed.command
            )
        }

        var aggregates: [pid_t: AppAggregate] = [:]
        aggregates.reserveCapacity(regularApplications.count)

        for process in rawProcesses.values {
            if Task.isCancelled { break }
            guard let rootPID = regularAppRoot(
                for: process.pid,
                rawProcesses: rawProcesses,
                regularApplications: regularApplications
            ) else {
                continue
            }

            var aggregate = aggregates[rootPID] ?? AppAggregate()
            aggregate.cpu += process.cpu
            aggregate.memoryMB += process.memoryMB
            aggregate.processIDs.append(process.pid)
            aggregates[rootPID] = aggregate
        }

        var results: [ProcessSample] = []
        results.reserveCapacity(max(regularApplications.count, maxListedApps))
        var processFamilies: [pid_t: [pid_t]] = [:]

        for (rootPID, identity) in regularApplications {
            guard let rootProcess = rawProcesses[rootPID],
                  let aggregate = aggregates[rootPID] else {
                continue
            }

            results.append(
                ProcessSample(
                    pid: rootPID,
                    cpu: aggregate.cpu,
                    memoryMB: aggregate.memoryMB,
                    uptimeText: rootProcess.elapsedTime,
                    processType: identity.processType,
                    command: rootProcess.command,
                    appName: identity.appName,
                    bundleIdentifier: identity.bundleIdentifier,
                    bundleURLPath: identity.bundleURLPath,
                    executablePath: identity.executablePath,
                    // This function runs inside the detached sampler task;
                    // keep the kernel identity lookup off the UI actor.
                    processStartTime: Self.currentProcessStartTime(for: rootPID)
                )
            )
            processFamilies[rootPID] = Array(Set(aggregate.processIDs)).sorted()
        }

        results.sort { lhs, rhs in
            switch selectedMetric {
            case .cpu:
                return lhs.cpu == rhs.cpu
                    ? lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
                    : lhs.cpu > rhs.cpu
            case .memory:
                return lhs.memoryMB == rhs.memoryMB
                    ? lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
                    : lhs.memoryMB > rhs.memoryMB
            }
        }

        var updatedAppIdentityCache = appIdentityCache
        for (pid, identity) in regularApplications {
            updatedAppIdentityCache[pid] = identity
        }
        let livePIDs = Set(regularApplications.keys)
        updatedAppIdentityCache = updatedAppIdentityCache.filter { livePIDs.contains($0.key) }
        if updatedAppIdentityCache.count > Self.maxCachedAppIdentities {
            updatedAppIdentityCache = Dictionary(
                uniqueKeysWithValues: updatedAppIdentityCache
                    .prefix(Self.maxCachedAppIdentities)
                    .map { ($0.key, $0.value) }
            )
        }

        return SamplingResult(
            samples: results,
            appIdentityCache: updatedAppIdentityCache,
            processFamilies: processFamilies
        )
    }

    private nonisolated func runPS(selectedMetric _: UsageMetric) throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/ps")

        // App-family aggregation needs the complete bounded table, and results are sorted in Swift.
        // `command=` can be huge on developer machines; `comm=` keeps enough executable identity
        // without retaining massive argv strings every few seconds.
        process.arguments = [
            "-A",
            "-o", "pid=,ppid=,%cpu=,rss=,etime=,comm="
        ]

        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let outputFD = outputPipe.fileHandleForReading.fileDescriptor
        let errorFD = errorPipe.fileHandleForReading.fileDescriptor
        var outputData = Data()
        var errorData = Data()
        var outputOpen = true
        var errorOpen = true
        defer {
            if process.isRunning {
                stopPSProcess(process)
            }
            outputPipe.fileHandleForReading.closeFile()
            outputPipe.fileHandleForWriting.closeFile()
            errorPipe.fileHandleForReading.closeFile()
            errorPipe.fileHandleForWriting.closeFile()
        }

        try makeNonBlocking(outputFD)
        try makeNonBlocking(errorFD)

        try process.run()
        // The parent must release its write ends so EOF becomes observable once /bin/ps exits.
        outputPipe.fileHandleForWriting.closeFile()
        errorPipe.fileHandleForWriting.closeFile()

        let deadline = ProcessInfo.processInfo.systemUptime + Self.psTimeoutSeconds
        while process.isRunning || outputOpen || errorOpen {
            if Task.isCancelled {
                stopPSProcess(process)
                throw CancellationError()
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                stopPSProcess(process)
                throw SamplerError.psTimedOut
            }

            var didRead = false
            if outputOpen {
                switch try readAvailablePSData(outputFD, into: &outputData) {
                case .eof:
                    outputOpen = false
                case .progress:
                    didRead = true
                case .wouldBlock:
                    break
                }
            }
            if errorOpen {
                switch try readAvailablePSData(errorFD, into: &errorData) {
                case .eof:
                    errorOpen = false
                case .progress:
                    didRead = true
                case .wouldBlock:
                    break
                }
            }

            if !didRead {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }

        guard process.terminationStatus == 0 else {
            let errorText = String(data: errorData, encoding: .utf8) ?? "Unknown ps error"
            throw SamplerError.psFailedWithMessage(process.terminationStatus, errorText)
        }

        guard let string = String(data: outputData, encoding: .utf8) else {
            throw SamplerError.invalidOutput
        }

        return string
    }

    private enum PSReadResult {
        case eof
        case progress
        case wouldBlock
    }

    private nonisolated func makeNonBlocking(_ fileDescriptor: Int32) throws {
        let flags = fcntl(fileDescriptor, F_GETFL)
        guard flags >= 0, fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
    }

    private nonisolated func readAvailablePSData(
        _ fileDescriptor: Int32,
        into data: inout Data) throws -> PSReadResult
    {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var didRead = false
        // Yield regularly so cancellation and the deadline remain effective.
        for _ in 0..<32 {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fileDescriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                didRead = true
                guard data.count + Int(count) <= Self.maxPSOutputBytes else {
                    throw SamplerError.psOutputTooLarge
                }
                data.append(contentsOf: buffer.prefix(Int(count)))
                continue
            }
            if count == 0 {
                return .eof
            }
            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return didRead ? .progress : .wouldBlock
            }
            throw CocoaError(.fileReadUnknown)
        }
        return didRead ? .progress : .wouldBlock
    }

    private nonisolated func stopPSProcess(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let graceDeadline = Date().addingTimeInterval(0.25)
        while process.isRunning && Date() < graceDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }

    private nonisolated func parsePSLine(_ line: String) -> (
        pid: pid_t,
        parentPID: pid_t,
        cpu: Double,
        memoryMB: Double,
        elapsedTime: String,
        command: String
    )? {
        guard let regex = Self.psLineRegex else { return nil }

        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range), match.numberOfRanges == 7 else {
            return nil
        }

        func capture(_ index: Int) -> String? {
            let nsRange = match.range(at: index)
            guard let range = Range(nsRange, in: line) else { return nil }
            return String(line[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard
            let pidString = capture(1),
            let parentPIDString = capture(2),
            let cpuString = capture(3),
            let rssString = capture(4),
            let elapsedTime = capture(5),
            let command = capture(6),
            let pidInt = Int32(pidString),
            let parentPID = Int32(parentPIDString),
            let cpu = Double(cpuString),
            let rssKB = Double(rssString)
        else {
            return nil
        }

        return (
            pid: pidInt,
            parentPID: parentPID,
            cpu: cpu,
            memoryMB: rssKB / 1024.0,
            elapsedTime: elapsedTime,
            command: command
        )
    }

    enum SamplerError: LocalizedError {
        case psFailed(Int32)
        case psFailedWithMessage(Int32, String)
        case invalidOutput
        case psTimedOut
        case psOutputTooLarge

        var errorDescription: String? {
            switch self {
            case .psFailed(let status):
                return "`ps` failed with exit code \(status)."
            case .psFailedWithMessage(let status, let message):
                return "`ps` failed with exit code \(status): \(message)"
            case .invalidOutput:
                return "Could not decode sampler output."
            case .psTimedOut:
                return "`ps` timed out while sampling processes."
            case .psOutputTooLarge:
                return "The process list exceeded the sampling limit."
            }
        }
    }
}

enum MemoryPressureState: String, Equatable {
    case normal
    case warning
    case critical

    init(event: DispatchSource.MemoryPressureEvent) {
        if event.contains(.critical) {
            self = .critical
        } else if event.contains(.warning) {
            self = .warning
        } else {
            self = .normal
        }
    }
}

enum MenuBarLoadState: Equatable {
    case idle
    case low
    case moderate
    case elevated
    case high

    init(cpuPercent: Double) {
        self = Self.state(for: cpuPercent)
    }

    init(memoryPercent: Double) {
        self = Self.state(for: memoryPercent)
    }

    private static func state(for percent: Double) -> MenuBarLoadState {
        let clamped = max(0, percent)

        switch clamped {
        case ..<1:
            return .idle
        case ..<25:
            return .low
        case ..<50:
            return .moderate
        case ..<80:
            return .elevated
        default:
            return .high
        }
    }

    var symbolName: String {
        switch self {
        case .idle, .low:
            return "gauge.open.with.lines.needle.33percent"
        case .moderate:
            return "gauge.open.with.lines.needle.67percent.and.arrowtriangle"
        case .elevated:
            return "gauge.open.with.lines.needle.67percent.and.arrowtriangle"
        case .high:
            return "gauge.open.with.lines.needle.84percent.exclamation"
        }
    }
}

// MARK: - Alert Models

enum IntentAlertTrigger: String, Codable, CaseIterable, Identifiable {
    case topAppChanged
    case cpuThresholdExceeded
    case memoryThresholdExceeded
    case appAppeared

    var id: String { rawValue }
}

struct IntentAlertRule: Identifiable, Codable, Hashable {
    let id: UUID
    var isEnabled: Bool
    var name: String
    var trigger: IntentAlertTrigger
    var watchedAppName: String
    var cpuThreshold: Double
    var memoryThresholdMB: Double
    var cooldownSeconds: Double
    var requiredConsecutiveMatches: Int

    init(
        id: UUID = UUID(),
        isEnabled: Bool,
        name: String,
        trigger: IntentAlertTrigger,
        watchedAppName: String = "",
        cpuThreshold: Double = 60,
        memoryThresholdMB: Double = Self.defaultAdaptiveMemoryThresholdMB,
        cooldownSeconds: Double = 300,
        requiredConsecutiveMatches: Int = 1
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.name = name
        self.trigger = trigger
        self.watchedAppName = watchedAppName
        self.cpuThreshold = cpuThreshold
        self.memoryThresholdMB = memoryThresholdMB
        self.cooldownSeconds = cooldownSeconds
        self.requiredConsecutiveMatches = requiredConsecutiveMatches
    }

    enum CodingKeys: String, CodingKey {
        case id
        case isEnabled
        case name
        case trigger
        case watchedAppName
        case cpuThreshold
        case memoryThresholdMB
        case cooldownSeconds
        case requiredConsecutiveMatches
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Alert"
        trigger = try container.decodeIfPresent(IntentAlertTrigger.self, forKey: .trigger) ?? .cpuThresholdExceeded
        watchedAppName = try container.decodeIfPresent(String.self, forKey: .watchedAppName) ?? ""
        cpuThreshold = try container.decodeIfPresent(Double.self, forKey: .cpuThreshold) ?? 60
        memoryThresholdMB = try container.decodeIfPresent(Double.self, forKey: .memoryThresholdMB) ?? Self.defaultAdaptiveMemoryThresholdMB
        cooldownSeconds = try container.decodeIfPresent(Double.self, forKey: .cooldownSeconds) ?? 300
        requiredConsecutiveMatches = try container.decodeIfPresent(Int.self, forKey: .requiredConsecutiveMatches) ?? 1
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(name, forKey: .name)
        try container.encode(trigger, forKey: .trigger)
        try container.encode(watchedAppName, forKey: .watchedAppName)
        try container.encode(cpuThreshold, forKey: .cpuThreshold)
        try container.encode(memoryThresholdMB, forKey: .memoryThresholdMB)
        try container.encode(cooldownSeconds, forKey: .cooldownSeconds)
        try container.encode(requiredConsecutiveMatches, forKey: .requiredConsecutiveMatches)
    }

    static var defaultRules: [IntentAlertRule] {
        [
            IntentAlertRule(
                isEnabled: true,
                name: "High CPU",
                trigger: .cpuThresholdExceeded,
                cpuThreshold: 60,
                cooldownSeconds: 300,
                requiredConsecutiveMatches: 6
            ),
            IntentAlertRule(
                isEnabled: true,
                name: "High Memory",
                trigger: .memoryThresholdExceeded,
                memoryThresholdMB: defaultAdaptiveMemoryThresholdMB,
                cooldownSeconds: 300,
                requiredConsecutiveMatches: 10
            ),
            IntentAlertRule(
                isEnabled: false,
                name: "Most Active App Changed",
                trigger: .topAppChanged,
                cooldownSeconds: 120
            )
        ]
    }

    static func appWatch(named name: String) -> IntentAlertRule {
        IntentAlertRule(
            isEnabled: true,
            name: "\(name) Appeared",
            trigger: .appAppeared,
            watchedAppName: name,
            cooldownSeconds: 300,
            requiredConsecutiveMatches: 1
        )
    }

    static var defaultAdaptiveMemoryThresholdMB: Double {
        let physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory
        let physicalMemoryMB = Double(physicalMemoryBytes) / 1_048_576.0
        let adaptiveThreshold = physicalMemoryMB * 0.08
        return max(1280, min(adaptiveThreshold, 4096))
    }

    var summaryText: String {
        switch trigger {
        case .topAppChanged:
            return "Notifies when the most active item changes."
        case .cpuThresholdExceeded:
            return "Notifies when any sampled item stays at or above \(Int(cpuThreshold))% CPU for about \(sustainedSecondsText)."
        case .memoryThresholdExceeded:
            return "Notifies when any sampled item stays at or above \(Int(memoryThresholdMB)) MB memory for about \(sustainedSecondsText)."
        case .appAppeared:
            let trimmed = watchedAppName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
            ? "Notifies when a matching app or process appears."
            : "Notifies when “\(trimmed)” appears in the current sampled set."
        }
    }

    private var sustainedSecondsText: String {
        let seconds = requiredConsecutiveMatches * 2
        return "\(seconds) sec"
    }
}

struct RunawayMemoryProtection: Codable, Equatable {
    var isEnabled: Bool
    var appMatch: String
    var memoryThresholdMB: Double

    static let defaultRule = RunawayMemoryProtection(
        isEnabled: true,
        appMatch: "ChatGPT",
        memoryThresholdMB: 4_096
    )

    var sanitized: RunawayMemoryProtection {
        RunawayMemoryProtection(
            isEnabled: isEnabled,
            appMatch: String(
                appMatch
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .prefix(128)
            ),
            memoryThresholdMB: min(max(memoryThresholdMB, 512), 32_768)
        )
    }
}

struct HeldProcess: Identifiable, Codable, Hashable {
    let pid: pid_t
    let appName: String
    let bundleIdentifier: String?
    let executablePath: String?
    let memoryMBAtHold: Double
    let heldAt: Date
    let processIDs: [pid_t]

    var id: pid_t { pid }
}

struct IntentAlertEvent: Identifiable, Hashable {
    let id = UUID()
    let ruleName: String
    let message: String
    let date: Date
}
