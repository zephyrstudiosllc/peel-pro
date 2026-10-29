//
//  ControlPanelDiskView.swift
//  Kill Switch
//

import SwiftUI

struct ControlPanelDiskView: View {
    @EnvironmentObject private var systemMetrics: SystemMetricsStore

    private var snapshot: DiskMetricsSnapshot? {
        systemMetrics.diskSnapshot
    }

    private var volume: DiskVolumeCapacity? {
        snapshot?.volume
    }

    private var activity: DiskGaugeActivity? {
        SystemGaugeReadings.diskActivity(from: snapshot)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if let activity {
                    HStack(alignment: .top, spacing: 16) {
                        SystemMetricGaugeCard(
                            title: "SSD Writes",
                            status: trafficStatus(activity),
                            subtitle: "\(SystemMetricFormatting.bytes(activity.writeBytes)) written since boot",
                            systemImage: "internaldrive",
                            progress: activity.dailyDriveEquivalents,
                            valueText: activity.gaugeValue,
                            tint: activity.tint
                        )

                        if let volume {
                            volumeDetails(volume)
                        } else {
                            unavailableCard(
                                title: "SSD capacity unavailable",
                                detail: "Traffic totals are available, but App Mechanic cannot normalize them against this drive’s capacity."
                            )
                        }
                    }
                } else {
                    unavailableCard(
                        title: "Physical disk traffic unavailable",
                        detail: snapshot?.errorDescription
                            ?? "Waiting for the first bounded storage sample."
                    )
                }

                activitySection
                samplingFooter
            }
            .padding(20)
        }
        .navigationTitle("Disk")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "internaldrive")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 3) {
                Text("Disk")
                    .font(.largeTitle.weight(.semibold))

                Text("SSD write volume and rolling rates, with reads and capacity as context")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                systemMetrics.refreshAll()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(systemMetrics.isRefreshing)
        }
    }

    private func volumeDetails(_ volume: DiskVolumeCapacity) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Measured Volume", systemImage: "externaldrive.badge.checkmark")
                .font(.headline)

            VStack(spacing: 10) {
                detailRow("Name", volume.displayName)
                detailRow("Mount", volume.mountPath)
                Divider()
                detailRow("Used", SystemMetricFormatting.bytes(volume.usedBytes))
                detailRow("Available", SystemMetricFormatting.bytes(volume.freeBytes))
                detailRow("Total", SystemMetricFormatting.bytes(volume.totalBytes))
            }

            Text("Capacity is secondary context from the mounted startup volume; App Mechanic does not scan files or folders.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Lifetime TBW requires the drive’s SMART Data Units Written counter. If macOS does not grant that access, App Mechanic reports it as unavailable instead of estimating it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Write Rate History")
                .font(.title3.weight(.semibold))

            Text("Current, 5-minute, and 15-minute write rates come from a fixed-size rolling history. Longer averages appear after at least 80% of their window is observed.")
                .font(.caption)
                .foregroundStyle(.secondary)

            let io = snapshot?.io
            HStack(alignment: .top, spacing: 12) {
                SystemMetricActivityRow(
                    title: "Write Now",
                    value: SystemMetricFormatting.bytesPerSecond(io?.writeBytesPerSecond),
                    detail: cumulativeDetail("written", bytes: io?.cumulativeWriteBytes),
                    systemImage: "arrow.up.to.line",
                    progress: activityProgress(io?.writeBytesPerSecond),
                    tint: .purple
                )

                SystemMetricActivityRow(
                    title: "5 Minute Average",
                    value: SystemMetricFormatting.bytesPerSecond(io?.writeBytesPerSecond5Minutes),
                    detail: "Rolling host writes",
                    systemImage: "clock",
                    progress: activityProgress(io?.writeBytesPerSecond5Minutes),
                    tint: .purple
                )
            }

            HStack(alignment: .top, spacing: 12) {
                SystemMetricActivityRow(
                    title: "15 Minute Average",
                    value: SystemMetricFormatting.bytesPerSecond(io?.writeBytesPerSecond15Minutes),
                    detail: "Rolling host writes",
                    systemImage: "clock.arrow.circlepath",
                    progress: activityProgress(io?.writeBytesPerSecond15Minutes),
                    tint: .purple
                )

                SystemMetricActivityRow(
                    title: "Read Now",
                    value: SystemMetricFormatting.bytesPerSecond(io?.readBytesPerSecond),
                    detail: cumulativeDetail("read", bytes: io?.cumulativeReadBytes),
                    systemImage: "arrow.down.to.line",
                    progress: activityProgress(io?.readBytesPerSecond),
                    tint: .blue
                )
            }

            if let io {
                Text(ioSourceDescription(io))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let error = snapshot?.errorDescription, !error.isEmpty {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var samplingFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "leaf")
                .foregroundStyle(.green)

            Text(systemMetrics.cadenceDescription)

            if let sampledAt = snapshot?.sampledAt {
                Text("Last disk sample \(sampledAt.formatted(date: .omitted, time: .standard)).")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .monospacedDigit()
                .textSelection(.enabled)
        }
    }

    private func unavailableCard(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "questionmark.circle")
                .font(.headline)
            Text(detail)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private func trafficStatus(_ activity: DiskGaugeActivity) -> String {
        guard let dailyDriveEquivalents = activity.dailyDriveEquivalents else {
            return "Rate Unavailable"
        }

        if dailyDriveEquivalents > 1 {
            return "More Than One SSD Per Day"
        }

        if dailyDriveEquivalents > (1.0 / 3.0) {
            return "Moderate Daily Traffic"
        }

        return "Light Daily Traffic"
    }

    private func activityProgress(_ bytesPerSecond: Double?) -> Double? {
        guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond >= 0 else {
            return nil
        }

        let referenceRate = 2_000_000_000.0
        return log10(bytesPerSecond + 1) / log10(referenceRate + 1)
    }

    private func cumulativeDetail(_ verb: String, bytes: UInt64?) -> String {
        guard let bytes else {
            return "A second stable sample is needed for a rate."
        }
        return "\(SystemMetricFormatting.bytes(bytes)) \(verb) since boot"
    }

    private func ioSourceDescription(_ io: DiskIOStatistics) -> String {
        switch io.source {
        case .physicalDevices:
            return "Reading \(io.deviceCount) physical storage device\(io.deviceCount == 1 ? "" : "s") directly through bounded IOKit counters."
        case .dominantWritableFallback:
            return "Storage identity was incomplete, so activity uses one dominant writable whole-media device."
        }
    }
}
