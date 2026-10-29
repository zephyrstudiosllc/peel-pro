//
//  ControlPanelGPUView.swift
//  Kill Switch
//

import SwiftUI

struct ControlPanelGPUView: View {
    @EnvironmentObject private var systemMetrics: SystemMetricsStore

    private var snapshot: GPUMetricsSnapshot? {
        systemMetrics.gpuSnapshot
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                utilizationOverview
                memorySection
                mediaSection
                samplingFooter
            }
            .padding(20)
        }
        .navigationTitle("GPU")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "display")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 3) {
                Text("GPU")
                    .font(.largeTitle.weight(.semibold))

                Text(snapshot?.deviceName ?? "Graphics hardware")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                systemMetrics.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(systemMetrics.isRefreshing)
        }
    }

    private var utilizationOverview: some View {
        HStack(alignment: .top, spacing: 16) {
            SystemMetricGaugeCard(
                title: "GPU Utilization",
                status: utilizationStatus,
                subtitle: utilizationSubtitle,
                systemImage: "gauge.with.dots.needle.67percent",
                progress: snapshot?.utilizationPercent.map { $0 / 100 },
                valueText: SystemMetricFormatting.percent(
                    snapshot?.utilizationPercent,
                    fractionDigits: 0
                ),
                tint: utilizationTint
            )

            VStack(alignment: .leading, spacing: 14) {
                Label("Graphics Device", systemImage: "cpu")
                    .font(.headline)

                detailRow("Default", snapshot?.deviceName ?? "Unavailable")
                detailRow(
                    "Visible GPUs",
                    snapshot.map { String($0.availableDeviceNames.count) } ?? "Unavailable"
                )

                Divider()

                Text(snapshot?.driverMetricScope.description
                    ?? "Waiting for the first bounded GPU sample.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let keys = snapshot?.exposedDriverStatisticKeys, !keys.isEmpty {
                    Text("Driver values: \(keys.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
        }
    }

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GPU Memory")
                .font(.title3.weight(.semibold))

            HStack(alignment: .top, spacing: 12) {
                SystemMetricActivityRow(
                    title: "In Use",
                    value: SystemMetricFormatting.bytes(snapshot?.memoryUsedBytes),
                    detail: memoryUseDetail,
                    systemImage: "memorychip",
                    progress: memoryUseProgress,
                    tint: .blue
                )

                SystemMetricActivityRow(
                    title: "Allocated",
                    value: SystemMetricFormatting.bytes(snapshot?.memoryAllocatedBytes),
                    detail: "Driver-reported allocation; this is not a fixed hardware capacity.",
                    systemImage: "square.stack.3d.up",
                    progress: nil,
                    tint: .indigo
                )
            }

            if let workingSetLimit = snapshot?.recommendedWorkingSetLimitBytes {
                Text("Metal recommends up to \(SystemMetricFormatting.bytes(workingSetLimit)) for this process’s GPU working set. This is a capability hint, not system-wide memory usage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var mediaSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Media Engines")
                .font(.title3.weight(.semibold))

            Text("These optional gauges appear only when the graphics driver publishes distinct numeric activity. Unsupported does not mean idle.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 12) {
                mediaGauge(
                    title: "Video Encoder",
                    systemImage: "video.badge.waveform",
                    percent: snapshot?.mediaEngines.encodeUtilizationPercent,
                    tint: .purple
                )

                mediaGauge(
                    title: "Video Decoder",
                    systemImage: "play.rectangle",
                    percent: snapshot?.mediaEngines.decodeUtilizationPercent,
                    tint: .teal
                )
            }

            Text(snapshot?.mediaEngines.availabilityText
                ?? "Waiting for the first media capability sample.")
                .font(.caption2)
                .foregroundStyle(.secondary)
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
                Text("Last GPU sample \(sampledAt.formatted(date: .omitted, time: .standard)).")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func mediaGauge(
        title: String,
        systemImage: String,
        percent: Double?,
        tint: Color
    ) -> some View {
        SystemMetricActivityRow(
            title: title,
            value: SystemMetricFormatting.percent(percent),
            detail: percent == nil
                ? "Unavailable on this driver"
                : "Driver-reported engine activity",
            systemImage: systemImage,
            progress: percent.map { $0 / 100 },
            tint: tint
        )
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .lineLimit(1)
                .textSelection(.enabled)
        }
    }

    private var utilizationStatus: String {
        guard let percent = snapshot?.utilizationPercent else {
            return "Unavailable"
        }

        if percent > 66 { return "Very High" }
        if percent >= 33 { return "Busy" }
        return "Normal"
    }

    private var utilizationSubtitle: String {
        if snapshot?.utilizationPercent == nil {
            return "This driver does not expose a trustworthy utilization value."
        }
        return "Current driver-reported device activity"
    }

    private var utilizationTint: Color {
        guard let percent = snapshot?.utilizationPercent else {
            return .secondary
        }

        if percent > 66 { return .red }
        if percent >= 33 { return .yellow }
        return .green
    }

    private var memoryUseProgress: Double? {
        guard let used = snapshot?.memoryUsedBytes,
              let limit = snapshot?.memoryLimitBytes,
              limit > 0 else {
            return nil
        }

        return Double(used) / Double(limit)
    }

    private var memoryUseDetail: String {
        if let limit = snapshot?.memoryLimitBytes {
            return "Driver-reported limit: \(SystemMetricFormatting.bytes(limit))"
        }
        return "No trustworthy fixed GPU memory limit is exposed."
    }
}
