import Foundation

/// The small set of system readings that can be represented in Peel's notch
/// and menu surfaces without creating another sampler or ownership boundary.
enum PeelMachineStatusMetric: String, CaseIterable, Hashable, Identifiable, Sendable {
    case cpu
    case memory
    case disk
    case storage
    case gpu

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu:
            return "CPU"
        case .memory:
            return "Memory"
        case .disk:
            return "Disk"
        case .storage:
            return "Storage"
        case .gpu:
            return "GPU"
        }
    }
}

enum PeelMachineStatusSeverity: String, CaseIterable, Comparable, Hashable, Sendable {
    case unavailable
    case normal
    case elevated
    case critical

    private var rank: Int {
        switch self {
        case .unavailable:
            return 0
        case .normal:
            return 1
        case .elevated:
            return 2
        case .critical:
            return 3
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }

    var title: String {
        switch self {
        case .unavailable:
            return "Unavailable"
        case .normal:
            return "Normal"
        case .elevated:
            return "Elevated"
        case .critical:
            return "Critical"
        }
    }
}

enum PeelMachineStatusAttribution: String, CaseIterable, Hashable, Sendable {
    case network
    case battery
    case gpu

    var title: String {
        switch self {
        case .network:
            return "Network"
        case .battery:
            return "Battery"
        case .gpu:
            return "GPU"
        }
    }
}

struct PeelMachineStatusBadge: Identifiable, Equatable, Sendable {
    let metric: PeelMachineStatusMetric
    let title: String
    let value: String?
    let detail: String?
    let severity: PeelMachineStatusSeverity
    let sampledAt: Date?
    let isStale: Bool

    var id: PeelMachineStatusMetric { metric }

    var isAvailable: Bool {
        !isStale && value != nil && severity != .unavailable
    }

    /// Consumers can use this directly in a compact badge; nil measurements
    /// remain visibly unavailable instead of being rendered as zero.
    var displayValue: String {
        value ?? "Unavailable"
    }
}

/// A value-only snapshot for lightweight Peel presentation surfaces.
///
/// Construction reads the host-owned App Mechanic instances once. It does not
/// retain either instance, start sampling, add a timer, or create a probe.
struct PeelMachineStatus: Equatable, Sendable {
    static let freshnessWindow: TimeInterval = 90

    let generatedAt: Date
    let badges: [PeelMachineStatusBadge]
    let unavailableAttributions: [PeelMachineStatusAttribution]
    let attributionNote: String

    @MainActor
    init(
        sampler: ProcessSampler,
        systemMetrics: SystemMetricsStore,
        now: Date = Date()
    ) {
        generatedAt = now

        let diskSnapshot = systemMetrics.diskSnapshot
        let diskActivity = SystemGaugeReadings.diskActivity(from: diskSnapshot)

        badges = [
            Self.cpuBadge(sampler: sampler, now: now),
            Self.memoryBadge(sampler: sampler, now: now),
            Self.diskBadge(
                snapshot: diskSnapshot,
                activity: diskActivity,
                now: now
            ),
            Self.storageBadge(snapshot: diskSnapshot, now: now),
            Self.gpuBadge(snapshot: systemMetrics.gpuSnapshot, now: now)
        ]
        unavailableAttributions = [.network, .battery, .gpu]
        attributionNote = "Per-app network, battery, and GPU attribution is unavailable. GPU activity, when present, is system-wide."
    }

    var availableBadges: [PeelMachineStatusBadge] {
        badges.filter(\.isAvailable)
    }

    var overallSeverity: PeelMachineStatusSeverity {
        availableBadges.map(\.severity).max() ?? .unavailable
    }

    var hasUnavailableMetrics: Bool {
        badges.contains { !$0.isAvailable }
    }

    func badge(for metric: PeelMachineStatusMetric) -> PeelMachineStatusBadge? {
        badges.first { $0.metric == metric }
    }

    @MainActor
    private static func cpuBadge(
        sampler: ProcessSampler,
        now: Date
    ) -> PeelMachineStatusBadge {
        let sampledAt = sampler.lastUpdated
        let hasSample = sampler.hasSystemCPUSample
        let isStale = hasSample && !isFresh(sampledAt, now: now)
        let percent = boundedPercent(sampler.systemCPUPercent)
        let isAvailable = hasSample && !isStale && percent != nil

        return PeelMachineStatusBadge(
            metric: .cpu,
            title: PeelMachineStatusMetric.cpu.title,
            value: isAvailable ? SystemMetricFormatting.percent(percent, fractionDigits: 1) : nil,
            detail: isAvailable ? "System processor load" : nil,
            severity: isAvailable ? severity(for: percent) : .unavailable,
            sampledAt: sampledAt,
            isStale: isStale
        )
    }

    @MainActor
    private static func memoryBadge(
        sampler: ProcessSampler,
        now: Date
    ) -> PeelMachineStatusBadge {
        let sampledAt = sampler.lastUpdated
        let hasSample = sampler.hasSystemMemorySample
        let isStale = hasSample && !isFresh(sampledAt, now: now)
        let usedPercent = boundedPercent(sampler.systemMemoryUsedPercent)
        let gaugePercent = boundedPercent(sampler.memoryGaugePercent)
        let isAvailable = hasSample && !isStale && usedPercent != nil && gaugePercent != nil

        let value = isAvailable
            ? "\(SystemMetricFormatting.percent(usedPercent, fractionDigits: 1)) used"
            : nil

        return PeelMachineStatusBadge(
            metric: .memory,
            title: PeelMachineStatusMetric.memory.title,
            value: value,
            detail: isAvailable ? memoryDetail(for: sampler.systemMemoryPressureState) : nil,
            severity: isAvailable ? memorySeverity(sampler.systemMemoryPressureState) : .unavailable,
            sampledAt: sampledAt,
            isStale: isStale
        )
    }

    private static func diskBadge(
        snapshot: DiskMetricsSnapshot?,
        activity: DiskGaugeActivity?,
        now: Date
    ) -> PeelMachineStatusBadge {
        let sampledAt = snapshot?.sampledAt
        let hasSample = snapshot != nil
        let isStale = hasSample && !isFresh(sampledAt, now: now)

        guard let snapshot, !isStale else {
            return unavailableBadge(
                for: .disk,
                sampledAt: sampledAt,
                isStale: isStale
            )
        }

        guard snapshot.availability != .unavailable else {
            return PeelMachineStatusBadge(
                metric: .disk,
                title: PeelMachineStatusMetric.disk.title,
                value: nil,
                detail: snapshot.errorDescription ?? "Disk availability is unavailable.",
                severity: .unavailable,
                sampledAt: sampledAt,
                isStale: false
            )
        }

        guard let activity,
              let dailyDriveEquivalents = activity.dailyDriveEquivalents,
              dailyDriveEquivalents.isFinite,
              dailyDriveEquivalents >= 0 else {
            return PeelMachineStatusBadge(
                metric: .disk,
                title: PeelMachineStatusMetric.disk.title,
                value: nil,
                detail: diskUnavailableDetail(snapshot: snapshot),
                severity: .unavailable,
                sampledAt: sampledAt,
                isStale: false
            )
        }

        return PeelMachineStatusBadge(
            metric: .disk,
            title: PeelMachineStatusMetric.disk.title,
            value: activity.gaugeValue,
            detail: diskDetail(activity: activity, snapshot: snapshot),
            severity: diskSeverity(for: dailyDriveEquivalents),
            sampledAt: sampledAt,
            isStale: false
        )
    }

    private static func memorySeverity(_ pressure: MemoryPressureState) -> PeelMachineStatusSeverity {
        switch pressure {
        case .normal: return .normal
        case .warning: return .elevated
        case .critical: return .critical
        }
    }

    private static func storageBadge(snapshot: DiskMetricsSnapshot?, now: Date) -> PeelMachineStatusBadge {
        let stale = snapshot.map { !isFresh($0.sampledAt, now: now) } ?? false
        guard let snapshot, !stale, let volume = snapshot.volume, volume.totalBytes > 0 else {
            return unavailableBadge(for: .storage, sampledAt: snapshot?.sampledAt, isStale: stale)
        }
        let freePercent = Double(volume.freeBytes) / Double(volume.totalBytes) * 100
        let severity: PeelMachineStatusSeverity = volume.freeBytes < 1_073_741_824 || freePercent < 2
            ? .critical : (freePercent < 10 ? .elevated : .normal)
        return PeelMachineStatusBadge(metric: .storage, title: "Storage",
            value: SystemMetricFormatting.bytes(volume.freeBytes), detail: "Free space",
            severity: severity, sampledAt: snapshot.sampledAt, isStale: false)
    }

    private static func gpuBadge(
        snapshot: GPUMetricsSnapshot?,
        now: Date
    ) -> PeelMachineStatusBadge {
        let sampledAt = snapshot?.sampledAt
        let hasSample = snapshot != nil
        let isStale = hasSample && !isFresh(sampledAt, now: now)

        guard let snapshot, !isStale else {
            return unavailableBadge(
                for: .gpu,
                sampledAt: sampledAt,
                isStale: isStale
            )
        }

        guard let percent = boundedPercent(snapshot.utilizationPercent) else {
            return PeelMachineStatusBadge(
                metric: .gpu,
                title: PeelMachineStatusMetric.gpu.title,
                value: nil,
                detail: snapshot.deviceName.map { "\($0) · Utilization unavailable" }
                    ?? "Utilization unavailable",
                severity: .unavailable,
                sampledAt: sampledAt,
                isStale: false
            )
        }

        return PeelMachineStatusBadge(
            metric: .gpu,
            title: PeelMachineStatusMetric.gpu.title,
            value: SystemMetricFormatting.percent(percent, fractionDigits: 1),
            detail: snapshot.deviceName ?? "System GPU utilization",
            severity: severity(for: percent),
            sampledAt: sampledAt,
            isStale: false
        )
    }

    private static func unavailableBadge(
        for metric: PeelMachineStatusMetric,
        sampledAt: Date?,
        isStale: Bool
    ) -> PeelMachineStatusBadge {
        PeelMachineStatusBadge(
            metric: metric,
            title: metric.title,
            value: nil,
            detail: isStale ? nil : "Unavailable",
            severity: .unavailable,
            sampledAt: sampledAt,
            isStale: isStale
        )
    }

    private static func isFresh(_ sampledAt: Date?, now: Date) -> Bool {
        guard let sampledAt else { return false }
        let age = now.timeIntervalSince(sampledAt)
        return age >= 0 && age <= freshnessWindow
    }

    private static func boundedPercent(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, 0), 100)
    }

    private static func severity(for percent: Double?) -> PeelMachineStatusSeverity {
        guard let percent = boundedPercent(percent) else { return .unavailable }
        if percent >= 90 { return .critical }
        if percent >= 70 { return .elevated }
        return .normal
    }

    private static func diskSeverity(for dailyDriveEquivalents: Double) -> PeelMachineStatusSeverity {
        if dailyDriveEquivalents > 1 { return .critical }
        if dailyDriveEquivalents > (1.0 / 3.0) { return .elevated }
        return .normal
    }

    private static func memoryDetail(for pressure: MemoryPressureState) -> String {
        switch pressure {
        case .normal:
            return "Memory pressure normal"
        case .warning:
            return "Memory pressure elevated"
        case .critical:
            return "Memory pressure critical"
        }
    }

    private static func diskDetail(
        activity: DiskGaugeActivity,
        snapshot: DiskMetricsSnapshot
    ) -> String {
        var details = [activity.detail]
        if let volume = snapshot.volume {
            details.append("\(SystemMetricFormatting.bytes(volume.freeBytes)) available")
        } else {
            details.append("Capacity unavailable")
        }
        return details.joined(separator: " · ")
    }

    private static func diskUnavailableDetail(snapshot: DiskMetricsSnapshot) -> String {
        if let error = snapshot.errorDescription, !error.isEmpty {
            return error
        }

        if snapshot.volume != nil {
            return "Write activity unavailable"
        }

        return "Disk availability and write activity unavailable"
    }
}
