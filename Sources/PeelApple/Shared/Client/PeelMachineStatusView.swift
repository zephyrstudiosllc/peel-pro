//
//  PeelMachineStatusView.swift
//  Shared Mac status panel for iOS and visionOS clients.
//
//  The view owns presentation only. The caller supplies a value snapshot and
//  performs the authenticated request when `onRefresh` is invoked.
//

import Foundation
import SwiftUI

nonisolated public struct PeelMachineStatusViewModel: Equatable, Sendable {
    public let snapshot: PeelMachineStatusMessage?
    /// Local client/transport availability text, when the caller has no reply.
    public let availability: String?
    public let errorMessage: String?
    public let isRefreshing: Bool

    public init(
        snapshot: PeelMachineStatusMessage? = nil,
        availability: String? = nil,
        errorMessage: String? = nil,
        isRefreshing: Bool = false
    ) {
        self.snapshot = snapshot
        self.availability = availability
        self.errorMessage = errorMessage
        self.isRefreshing = isRefreshing
    }
}

public struct PeelMachineStatusView: View {
    public let model: PeelMachineStatusViewModel
    private let onRefresh: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(
        model: PeelMachineStatusViewModel,
        onRefresh: @escaping () -> Void
    ) {
        self.model = model
        self.onRefresh = onRefresh
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                stateMessage

                if let snapshot = model.snapshot {
                    sampleHeader(snapshot)
                    metricGrid(snapshot)
                    topApps(snapshot)
                    usage(snapshot)
                } else if model.errorMessage == nil, model.availability == nil {
                    unavailableCard
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
    }

    private var header: some View {
        adaptiveRow(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.snapshot?.hostName ?? "Computer status")
                    .font(.title3.weight(.semibold))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                Text("System health, App Mechanic, and AI usage")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: 8)
            }

            Button(action: onRefresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .fixedSize()
            }
            .buttonStyle(.bordered)
            .disabled(model.isRefreshing)
        }
    }

    @ViewBuilder
    private var stateMessage: some View {
        if let errorMessage = model.errorMessage {
            statusCard(
                title: "Status unavailable",
                detail: errorMessage,
                systemImage: "exclamationmark.triangle")
        } else if model.snapshot == nil, let availability = model.availability {
            statusCard(
                title: "Status unavailable",
                detail: availability,
                systemImage: "questionmark.circle")
        }
    }

    private func sampleHeader(_ snapshot: PeelMachineStatusMessage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
            Text("Sampled")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(Date(timeIntervalSince1970: snapshot.sampledAt), style: .relative)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let localStatus = snapshot.localStatus {
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(localStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func metricGrid(_ snapshot: PeelMachineStatusMessage) -> some View {
        if horizontalSizeClass == .compact || dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) {
                metricCards(snapshot)
            }
        } else {
            LazyVGrid(
                columns: [GridItem(.flexible(minimum: 0)), GridItem(.flexible(minimum: 0))],
                spacing: 8
            ) {
                metricCards(snapshot)
            }
        }
    }

    @ViewBuilder
    private func metricCards(_ snapshot: PeelMachineStatusMessage) -> some View {
        fractionCard("CPU", value: snapshot.cpuFraction, detail: "System load")

        if snapshot.memoryUsedBytes == nil, let memoryFraction = snapshot.memoryFraction {
            fractionCard("Memory", value: memoryFraction, detail: "System memory used")
        } else {
            memoryCard(used: snapshot.memoryUsedBytes, total: snapshot.memoryTotalBytes)
        }

        storageCard(
            free: snapshot.storageFreeBytes,
            total: snapshot.storageTotalBytes)

        if let gpuFraction = snapshot.gpuFraction {
            fractionCard("GPU", value: gpuFraction, detail: "System GPU load")
        }
        if let batteryFraction = snapshot.batteryFraction {
            fractionCard("Battery", value: batteryFraction, detail: "Charge", isRemaining: true)
        }

        if snapshot.networkReceiveBytesPerSecond != nil || snapshot.networkSendBytesPerSecond != nil {
            networkCard(
                receive: snapshot.networkReceiveBytesPerSecond,
                send: snapshot.networkSendBytesPerSecond)
        }
    }

    private func fractionCard(
        _ title: String,
        value: Double?,
        detail: String,
        isRemaining: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer(minLength: 4)
                Text(value.map { Self.percent($0 * 100) } ?? "Unavailable")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(value == nil ? .secondary : .primary)
            }

            if let value {
                ProgressView(value: value, total: 1)
                    .tint(Self.tint(for: isRemaining ? 1 - value : value))
            } else {
                Text("Unavailable")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func memoryCard(used: UInt64?, total: UInt64?) -> some View {
        let progress: Double? = if let used, let total, total > 0 {
            min(max(Double(used) / Double(total), 0), 1)
        } else {
            nil
        }
        let valueText: String = if let used {
            Self.bytes(used)
        } else {
            "Unavailable"
        }
        let detail = if let total {
            "of \(Self.bytes(total))"
        } else {
            "Total unavailable"
        }

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Memory").font(.subheadline.weight(.medium))
                Spacer(minLength: 4)
                Text(valueText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(used == nil ? .secondary : .primary)
            }

            if let progress {
                ProgressView(value: progress, total: 1)
                    .tint(Self.tint(for: progress))
            } else {
                Text("Unavailable")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func storageCard(free: UInt64?, total: UInt64?) -> some View {
        let progress: Double? = if let free, let total, total > 0 {
            min(max(Double(free) / Double(total), 0), 1)
        } else {
            nil
        }

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Storage").font(.subheadline.weight(.medium))
                Spacer(minLength: 4)
                Text(free.map(Self.bytes) ?? "Unavailable")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(free == nil ? .secondary : .primary)
            }

            if let progress {
                ProgressView(value: progress, total: 1)
                    .tint(Self.tint(for: 1 - progress))
            } else {
                Text("Unavailable")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(total.map { "Free of \(Self.bytes($0))" } ?? "Total unavailable")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func networkCard(receive: Double?, send: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Network").font(.subheadline.weight(.medium))
            HStack(spacing: 10) {
                Label(receive.map(Self.rate) ?? "Unavailable", systemImage: "arrow.down")
                Label(send.map(Self.rate) ?? "Unavailable", systemImage: "arrow.up")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(receive == nil && send == nil ? .secondary : .primary)
            Text("Current transfer rate")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func topApps(_ snapshot: PeelMachineStatusMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("App Mechanic")
                .font(.headline)

            if snapshot.topApps.isEmpty {
                Text("No process sample is available from this computer yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(
                    Array(snapshot.topApps.prefix(PeelMachineStatusValidation.maxTopApps).enumerated()),
                    id: \.offset
                ) { _, app in
                    adaptiveRow(spacing: 8) {
                        Text(app.displayName)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        if !dynamicTypeSize.isAccessibilitySize {
                            Spacer(minLength: 4)
                        }
                        VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 2) {
                            Text("\(Self.percent(app.cpuPercent)) CPU")
                            Text("\(Self.bytes(app.memoryBytes)) Memory")
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func usage(_ snapshot: PeelMachineStatusMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AI Usage")
                .font(.headline)

            if snapshot.usage.isEmpty {
                Text("No fresh provider usage is available. Check Usage Limits connection and enabled providers in Peel Pro, then refresh here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(
                    Array(snapshot.usage.prefix(PeelMachineStatusValidation.maxUsageEntries).enumerated()),
                    id: \.offset
                ) { _, item in
                    VStack(alignment: .leading, spacing: 4) {
                        adaptiveRow(spacing: 8) {
                            Text(item.providerName)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                            if !dynamicTypeSize.isAccessibilitySize {
                                Spacer(minLength: 4)
                            }
                            if let usedPercent = item.usedPercent {
                                Text("\(Self.percent(usedPercent)) used")
                                    .font(.caption.monospacedDigit())
                                    .fixedSize()
                            } else {
                                Text("Unavailable")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let resetAt = item.resetAt {
                            HStack(spacing: 3) {
                                Text("Resets")
                                Text(Date(timeIntervalSince1970: resetAt), style: .relative)
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .font(.subheadline)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }

    private var unavailableCard: some View {
        statusCard(
            title: "No host sample",
            detail: model.availability ?? "Refresh after the host is connected.",
            systemImage: "desktopcomputer.and.arrow.down")
    }

    private func adaptiveRow<Content: View>(
        spacing: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: spacing))
        return layout(content)
    }

    private func statusCard(
        title: String,
        detail: String,
        systemImage: String
    ) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }

    private static func tint(for fraction: Double) -> Color {
        fraction >= 0.9 ? .red : fraction >= 0.7 ? .orange : .accentColor
    }

    private static func percent(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1))) + "%"
    }

    private static func bytes(_ value: UInt64) -> String {
        let bounded = min(value, UInt64(Int64.max))
        return ByteCountFormatter.string(
            fromByteCount: Int64(bounded),
            countStyle: .file)
    }

    private static func rate(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "Unavailable" }
        return bytes(UInt64(min(value.rounded(), Double(Int64.max)))) + "/s"
    }
}
