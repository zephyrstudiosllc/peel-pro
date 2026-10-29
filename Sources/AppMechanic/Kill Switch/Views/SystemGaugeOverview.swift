//
//  SystemGaugeOverview.swift
//  Kill Switch
//

import SwiftUI
import Foundation

struct SystemGaugeReading: Identifiable {
    let metric: SystemGaugeMetric
    let percent: Double?
    let detail: String
    private let customValueText: String?
    private let customGaugeValue: String?
    private let customTint: Color?
    private let customSeveritySortValue: Double?

    init(
        metric: SystemGaugeMetric,
        percent: Double?,
        detail: String,
        valueText: String? = nil,
        gaugeValue: String? = nil,
        tint: Color? = nil,
        severitySortValue: Double? = nil
    ) {
        self.metric = metric
        self.percent = percent
        self.detail = detail
        self.customValueText = valueText
        self.customGaugeValue = gaugeValue
        self.customTint = tint
        self.customSeveritySortValue = severitySortValue
    }

    var id: SystemGaugeMetric { metric }

    var progress: Double? {
        percent.map { min(max($0 / 100, 0), 1) }
    }

    var valueText: String {
        customValueText ?? SystemMetricFormatting.percent(percent)
    }

    var gaugeValue: String {
        customGaugeValue ?? (percent == nil ? "—" : valueText)
    }

    var tint: Color {
        if let customTint {
            return customTint
        }

        guard let percent else { return .secondary }

        if percent > 66 { return .red }
        if percent >= 33 { return .yellow }
        return .green
    }

    var severitySortValue: Double {
        if let customSeveritySortValue {
            return customSeveritySortValue
        }

        guard let percent, percent.isFinite else {
            return -.infinity
        }

        let clampedPercent = max(percent, 0)
        if clampedPercent > 66 { return 200 + clampedPercent }
        if clampedPercent >= 33 { return 100 + clampedPercent }
        return clampedPercent
    }
}

struct DiskGaugeActivity {
    let readBytes: UInt64
    let writeBytes: UInt64
    let currentWriteBytesPerSecond: Double?
    let capacityBytes: UInt64?
    let dailyDriveEquivalents: Double?

    var intensityPercent: Double? {
        dailyDriveEquivalents.map { $0 * 100 }
    }

    var tint: Color {
        guard let dailyDriveEquivalents else { return .secondary }
        if dailyDriveEquivalents > 1 { return .red }
        if dailyDriveEquivalents > (1.0 / 3.0) { return .yellow }
        return .green
    }

    var valueText: String {
        "\(SystemMetricFormatting.bytes(writeBytes)) written since boot"
    }

    var gaugeValue: String {
        guard let dailyDriveEquivalents else { return "—" }

        if dailyDriveEquivalents < 0.1 {
            return String(format: "%.2f×/d", dailyDriveEquivalents)
        }

        if dailyDriveEquivalents < 10 {
            return String(format: "%.1f×/d", dailyDriveEquivalents)
        }

        return String(format: "%.0f×/d", dailyDriveEquivalents)
    }

    var detail: String {
        let read = SystemMetricFormatting.bytes(readBytes)
        let written = SystemMetricFormatting.bytes(writeBytes)
        let writeRate = SystemMetricFormatting.bytesPerSecond(currentWriteBytesPerSecond)

        if let capacityBytes {
            return "\(written) written · \(writeRate) now · \(SystemMetricFormatting.bytes(capacityBytes)) SSD"
        }

        return "\(written) written · \(writeRate) now · \(read) read"
    }

    var severitySortValue: Double {
        guard let dailyDriveEquivalents,
              dailyDriveEquivalents.isFinite else {
            return -.infinity
        }

        let activityPercent = max(dailyDriveEquivalents * 100, 0)
        if dailyDriveEquivalents > 1 { return 200 + activityPercent }
        if dailyDriveEquivalents > (1.0 / 3.0) { return 100 + activityPercent }
        return activityPercent
    }
}

@MainActor
enum SystemGaugeReadings {
    static func all(
        sampler: ProcessSampler,
        systemMetrics: SystemMetricsStore
    ) -> [SystemGaugeReading] {
        let diskActivity = diskActivity(from: systemMetrics.diskSnapshot)

        return [
            SystemGaugeReading(
                metric: .cpu,
                percent: sampler.hasSystemCPUSample ? sampler.systemCPUPercent : nil,
                detail: sampler.hasSystemCPUSample
                    ? "System processor load"
                    : "Waiting for first sample"
            ),
            SystemGaugeReading(
                metric: .memory,
                percent: sampler.hasSystemMemorySample ? sampler.memoryGaugePercent : nil,
                detail: sampler.hasSystemMemorySample
                    ? memoryDetail(for: sampler.systemMemoryPressureState) + " · \(Int(sampler.systemMemoryUsedPercent.rounded()))% RAM occupied including cache"
                    : "Waiting for first sample"
            ),
            SystemGaugeReading(
                metric: .disk,
                percent: diskActivity?.intensityPercent,
                detail: diskActivity?.detail
                    ?? diskDetail(from: systemMetrics.diskSnapshot),
                valueText: diskActivity?.valueText,
                gaugeValue: diskActivity?.gaugeValue,
                tint: diskActivity?.tint,
                severitySortValue: diskActivity?.severitySortValue
            ),
            SystemGaugeReading(
                metric: .gpu,
                percent: systemMetrics.gpuSnapshot?.utilizationPercent,
                detail: systemMetrics.gpuSnapshot?.deviceName ?? "Utilization unavailable"
            )
        ]
    }

    static func diskActivity(
        from snapshot: DiskMetricsSnapshot?
    ) -> DiskGaugeActivity? {
        guard let io = snapshot?.io else { return nil }

        let capacityBytes = snapshot?.volume?.totalBytes
        let uptime = ProcessInfo.processInfo.systemUptime
        let dailyDriveEquivalents: Double?

        if let capacityBytes,
           capacityBytes > 0,
           uptime.isFinite,
           uptime >= 60 {
            let averageBytesPerDay = (Double(io.cumulativeWriteBytes) / uptime) * 86_400
            let equivalents = averageBytesPerDay / Double(capacityBytes)
            dailyDriveEquivalents = equivalents.isFinite && equivalents >= 0
                ? equivalents
                : nil
        } else {
            dailyDriveEquivalents = nil
        }

        return DiskGaugeActivity(
            readBytes: io.cumulativeReadBytes,
            writeBytes: io.cumulativeWriteBytes,
            currentWriteBytesPerSecond: io.writeBytesPerSecond,
            capacityBytes: capacityBytes,
            dailyDriveEquivalents: dailyDriveEquivalents
        )
    }

    private static func memoryDetail(
        for pressure: MemoryPressureState
    ) -> String {
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
        from snapshot: DiskMetricsSnapshot?
    ) -> String {
        guard let volume = snapshot?.volume else {
            return "Capacity unavailable"
        }

        return "Activity unavailable · \(SystemMetricFormatting.bytes(volume.totalBytes)) SSD"
    }
}

struct SystemGaugeOverview: View {
    enum Layout {
        case grid
        case list
    }

    let readings: [SystemGaugeReading]
    let displayMode: PopupGaugeDisplayMode
    var layout: Layout = .grid

    var body: some View {
        Group {
            if readings.isEmpty {
                Text("No system gauges selected. Choose gauges in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if displayMode == .combinedAverage {
                combinedAverage
            } else {
                switch layout {
                case .grid:
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10)
                        ],
                        spacing: 10
                    ) {
                        ForEach(readings) { reading in
                            tile(for: reading)
                        }
                    }

                case .list:
                    LazyVStack(spacing: 10) {
                        ForEach(readings) { reading in
                            tile(for: reading)
                        }
                    }
                }
            }
        }
    }

    private var availableReadings: [SystemGaugeReading] {
        readings.filter { $0.percent != nil }
    }

    private var averagePercent: Double? {
        let values = availableReadings.compactMap(\.percent)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private var combinedAverage: some View {
        let reading = SystemGaugeReading(
            metric: .cpu,
            percent: averagePercent,
            detail: availableReadings.isEmpty
                ? "No selected metrics are currently available"
                : "Average of \(availableReadings.count) available selected metric\(availableReadings.count == 1 ? "" : "s")"
        )

        return SystemMetricSummaryTile(
            title: "Combined System",
            value: reading.valueText,
            detail: reading.detail,
            systemImage: "gauge.with.dots.needle.67percent",
            progress: reading.progress,
            tint: reading.tint,
            gaugeValue: reading.gaugeValue
        )
    }

    private func tile(for reading: SystemGaugeReading) -> some View {
        SystemMetricSummaryTile(
            title: reading.metric.displayName,
            value: reading.valueText,
            detail: reading.detail,
            systemImage: reading.metric.systemImage,
            progress: reading.progress,
            tint: reading.tint,
            gaugeValue: reading.gaugeValue
        )
    }
}
