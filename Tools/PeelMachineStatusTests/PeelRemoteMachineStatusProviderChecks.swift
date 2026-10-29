import Foundation

@main
enum PeelRemoteMachineStatusProviderChecks {
    @MainActor
    static func main() throws {
        let sampleDate = Date(timeIntervalSince1970: 1_700_000_100)
        let usageDate = sampleDate.addingTimeInterval(4)
        let now = sampleDate.addingTimeInterval(5)
        let resetDate = Date(timeIntervalSince1970: 1_800_000_000)

        let providers = [
            PeelUsageProvider(
                id: "codex",
                name: "Codex",
                enabled: true,
                identity: PeelUsageIdentity(accountEmail: "private@example.test"),
                windows: [
                    PeelUsageWindow(kind: "session", label: "Session", usedPercent: 28, resetAt: resetDate),
                    PeelUsageWindow(kind: "weekly", label: "Weekly", usedPercent: 45)
                ],
                updatedAt: usageDate),
            PeelUsageProvider(
                id: "cursor",
                name: "Cursor",
                enabled: true,
                windows: [
                    PeelUsageWindow(kind: "total", label: "Total", usedPercent: 60),
                    PeelUsageWindow(kind: "cursor", label: "Cursor", usedPercent: 20),
                    PeelUsageWindow(kind: "third-party", label: "Third Party", usedPercent: 10),
                    PeelUsageWindow(kind: "grok-bot", label: "Grok Bot", usedPercent: 5)
                ],
                updatedAt: usageDate),
            PeelUsageProvider(
                id: "missing",
                name: "Missing",
                enabled: true,
                windows: [PeelUsageWindow(kind: "weekly", label: "Weekly")],
                updatedAt: usageDate),
            PeelUsageProvider(
                id: "overflow",
                name: "Overflow",
                enabled: true,
                windows: [
                    PeelUsageWindow(kind: "one", label: "One", usedPercent: 1),
                    PeelUsageWindow(kind: "two", label: "Two", usedPercent: 2),
                    PeelUsageWindow(kind: "three", label: "Three", usedPercent: 3),
                    PeelUsageWindow(kind: "four", label: "Four", usedPercent: 4)
                ],
                updatedAt: usageDate),
            PeelUsageProvider(
                id: "disabled",
                name: "Disabled",
                enabled: false,
                windows: [PeelUsageWindow(kind: "hidden", label: "Hidden", usedPercent: 99)],
                updatedAt: usageDate),
            PeelUsageProvider(
                id: "failed",
                name: "Failed",
                enabled: true,
                windows: [PeelUsageWindow(kind: "failed", label: "Failed", usedPercent: 99)],
                error: PeelUsageError(message: "Rate limited"),
                updatedAt: usageDate),
            PeelUsageProvider(
                id: "no-windows",
                name: "No Windows",
                enabled: true,
                windows: [],
                updatedAt: usageDate),
            PeelUsageProvider(
                id: "too-long",
                name: String(repeating: "x", count: 257),
                enabled: true,
                windows: [PeelUsageWindow(kind: "too-long", label: "Too Long", usedPercent: 12)],
                updatedAt: usageDate),
            PeelUsageProvider(
                id: "stale",
                name: "Stale",
                enabled: true,
                windows: [PeelUsageWindow(kind: "old", label: "Old", usedPercent: 12)],
                updatedAt: now.addingTimeInterval(-601))
        ]

        let model = PeelUnifiedModel(
            sidePulse: CommandCenterStore(batteryState: nil, batterySampledAt: nil),
            usage: PeelUsageStore(
                snapshot: PeelUsageSnapshot(
                    generatedAt: usageDate,
                    staleAfterSeconds: 180,
                    providers: providers),
                providers: providers),
            sampler: ProcessSampler(
                topApps: [],
                lastUpdated: sampleDate,
                hasSystemCPUSample: true,
                systemCPUPercent: 37.5,
                hasSystemMemorySample: true,
                systemMemoryUsedPercent: 66),
            systemMetrics: SystemMetricsStore(
                diskSnapshot: nil,
                gpuSnapshot: nil),
            isPreview: false)

        let requestID = "A7D3F8B4-17C7-4A01-A07E-3A6F773E33A2"
        guard let message = PeelRemoteMachineStatusProvider.snapshot(
            requestId: requestID,
            model: model,
            now: now) else {
            preconditionFailure("Expected a cached status reply")
        }

        precondition(message.usage.count == PeelMachineStatusValidation.maxUsageEntries)
        precondition(message.usage.map { $0.providerName } == [
            "Codex · Session",
            "Codex · Weekly",
            "Cursor · Total",
            "Cursor · Cursor",
            "Cursor · Third Party",
            "Cursor · Grok Bot",
            "Missing · Weekly",
            "Overflow · One"
        ])
        precondition(message.usage[0].usedPercent == 28)
        precondition(message.usage[0].resetAt == resetDate.timeIntervalSince1970)
        precondition(message.usage[6].usedPercent == nil)
        precondition(message.memoryFraction == 0.66)
        precondition(message.memoryUsedBytes == nil)
        precondition(message.memoryTotalBytes == nil)
        precondition(message.networkReceiveBytesPerSecond == nil)
        precondition(message.networkSendBytesPerSecond == nil)

        let encodedMessage = try JSONEncoder().encode(message)
        let encodedText = String(decoding: encodedMessage, as: UTF8.self)
        precondition(!encodedText.contains("private@example.test"))
        precondition(!encodedText.contains("Rate limited"))

        let combinedOverflowProviderName = String(repeating: "p", count: 200)
        let combinedOverflowWindowName = String(repeating: "w", count: 54)
        let filteredProviders = [
            PeelUsageProvider(
                id: "valid",
                name: "Valid",
                enabled: true,
                windows: [PeelUsageWindow(
                    kind: "remaining",
                    label: "Remaining",
                    remainingPercent: 80)],
                updatedAt: usageDate),
            PeelUsageProvider(
                id: "disabled-under-cap",
                name: "Disabled",
                enabled: false,
                windows: [PeelUsageWindow(kind: "hidden", label: "Hidden", usedPercent: 99)],
                updatedAt: usageDate),
            PeelUsageProvider(
                id: "failed-under-cap",
                name: "Failed",
                enabled: true,
                windows: [PeelUsageWindow(kind: "failed", label: "Failed", usedPercent: 99)],
                error: PeelUsageError(message: "Unavailable"),
                updatedAt: usageDate),
            PeelUsageProvider(
                id: "empty-under-cap",
                name: "No Windows",
                enabled: true,
                windows: [],
                updatedAt: usageDate),
            PeelUsageProvider(
                id: "long-component-under-cap",
                name: String(repeating: "x", count: 257),
                enabled: true,
                windows: [PeelUsageWindow(kind: "long", label: "Long", usedPercent: 12)],
                updatedAt: usageDate),
            PeelUsageProvider(
                id: "long-combined-under-cap",
                name: combinedOverflowProviderName,
                enabled: true,
                windows: [PeelUsageWindow(
                    kind: "combined",
                    label: combinedOverflowWindowName,
                    usedPercent: 12)],
                updatedAt: usageDate),
            PeelUsageProvider(
                id: "stale-under-cap",
                name: "Stale",
                enabled: true,
                windows: [PeelUsageWindow(kind: "old", label: "Old", usedPercent: 12)],
                updatedAt: now.addingTimeInterval(-601))
        ]
        let filteredModel = PeelUnifiedModel(
            sidePulse: model.sidePulse,
            usage: PeelUsageStore(
                snapshot: PeelUsageSnapshot(
                    generatedAt: usageDate,
                    staleAfterSeconds: 180,
                    providers: filteredProviders),
                providers: filteredProviders),
            sampler: ProcessSampler(
                topApps: [],
                lastUpdated: nil,
                hasSystemCPUSample: false,
                systemCPUPercent: 0,
                hasSystemMemorySample: false,
                systemMemoryUsedPercent: 0),
            systemMetrics: SystemMetricsStore(diskSnapshot: nil, gpuSnapshot: nil),
            isPreview: false)
        guard let filteredMessage = PeelRemoteMachineStatusProvider.snapshot(
            requestId: requestID,
            model: filteredModel,
            now: now) else {
            preconditionFailure("Expected the valid usage row to keep the reply available")
        }
        precondition(filteredMessage.usage.count == 1)
        precondition(filteredMessage.usage[0].providerName == "Valid · Remaining")
        precondition(filteredMessage.usage[0].usedPercent == 20)

        let staleModel = PeelUnifiedModel(
            sidePulse: model.sidePulse,
            usage: PeelUsageStore(
                snapshot: PeelUsageSnapshot(
                    generatedAt: sampleDate,
                    staleAfterSeconds: 4,
                    providers: []),
                providers: [PeelUsageProvider(
                    id: "stale-snapshot",
                    name: "Stale Snapshot",
                    enabled: true,
                    windows: [PeelUsageWindow(kind: "weekly", label: "Weekly", usedPercent: 10)],
                    updatedAt: usageDate)]),
            sampler: model.sampler,
            systemMetrics: model.systemMetrics,
            isPreview: false)
        guard let staleMessage = PeelRemoteMachineStatusProvider.snapshot(
            requestId: requestID,
            model: staleModel,
            now: now) else {
            preconditionFailure("Fresh system sample should keep the reply available")
        }
        precondition(staleMessage.usage.isEmpty)

        print("PeelRemoteMachineStatusProviderChecks: PASS")
    }
}

@MainActor
final class PeelUnifiedModel {
    let sidePulse: CommandCenterStore
    let usage: PeelUsageStore
    let sampler: ProcessSampler
    let systemMetrics: SystemMetricsStore
    let isPreview: Bool

    init(
        sidePulse: CommandCenterStore,
        usage: PeelUsageStore,
        sampler: ProcessSampler,
        systemMetrics: SystemMetricsStore,
        isPreview: Bool
    ) {
        self.sidePulse = sidePulse
        self.usage = usage
        self.sampler = sampler
        self.systemMetrics = systemMetrics
        self.isPreview = isPreview
    }
}

@MainActor
final class CommandCenterStore {
    let batteryState: BatteryState?
    let batterySampledAt: Date?

    init(batteryState: BatteryState?, batterySampledAt: Date?) {
        self.batteryState = batteryState
        self.batterySampledAt = batterySampledAt
    }
}

struct BatteryState {
    let chargeFraction: Double
}

struct ProcessSample {
    let pid: Int32
    let cpu: Double
    let memoryMB: Double
    let appName: String
}

@MainActor
final class ProcessSampler {
    let topApps: [ProcessSample]
    let lastUpdated: Date?
    let hasSystemCPUSample: Bool
    let systemCPUPercent: Double
    let hasSystemMemorySample: Bool
    let systemMemoryUsedPercent: Double

    init(
        topApps: [ProcessSample],
        lastUpdated: Date?,
        hasSystemCPUSample: Bool,
        systemCPUPercent: Double,
        hasSystemMemorySample: Bool,
        systemMemoryUsedPercent: Double
    ) {
        self.topApps = topApps
        self.lastUpdated = lastUpdated
        self.hasSystemCPUSample = hasSystemCPUSample
        self.systemCPUPercent = systemCPUPercent
        self.hasSystemMemorySample = hasSystemMemorySample
        self.systemMemoryUsedPercent = systemMemoryUsedPercent
    }
}

@MainActor
final class PeelUsageStore {
    let snapshot: PeelUsageSnapshot?
    let providers: [PeelUsageProvider]

    init(snapshot: PeelUsageSnapshot?, providers: [PeelUsageProvider]) {
        self.snapshot = snapshot
        self.providers = providers
    }
}

enum DiskMetricsAvailability {
    case available
    case unavailable
}

struct DiskVolumeCapacity {
    let freeBytes: UInt64
    let totalBytes: UInt64
}

struct DiskMetricsSnapshot {
    let sampledAt: Date
    let volume: DiskVolumeCapacity?
    let availability: DiskMetricsAvailability
}

struct GPUMetricsSnapshot {
    let sampledAt: Date
    let utilizationPercent: Double?
}

@MainActor
final class SystemMetricsStore {
    let diskSnapshot: DiskMetricsSnapshot?
    let gpuSnapshot: GPUMetricsSnapshot?

    init(
        diskSnapshot: DiskMetricsSnapshot?,
        gpuSnapshot: GPUMetricsSnapshot?
    ) {
        self.diskSnapshot = diskSnapshot
        self.gpuSnapshot = gpuSnapshot
    }
}
