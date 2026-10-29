//
//  ControlPanelHomeView.swift
//  Kill Switch
//

import SwiftUI
import AppKit
import Darwin

struct ControlPanelHomeView: View {
    @EnvironmentObject private var sampler: ProcessSampler
    @EnvironmentObject private var systemMetrics: SystemMetricsStore

    private let title: String

    @State private var hoveredPID: pid_t?
    @State private var pendingForceQuit: ProcessSample?

    init(title: String = "Home") {
        self.title = title
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                systemGaugeSection
                mostActiveAppSection
                processSection
            }
            .padding(20)
        }
        .navigationTitle(title)
        .contentShape(Rectangle())
        .onDisappear {
            hoveredPID = nil
            pendingForceQuit = nil
            sampler.setInteractionFrozen(false)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.largeTitle.weight(.semibold))

                Text("Your Mac at a glance")
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var systemGaugeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("System Gauges", systemImage: "gauge.with.dots.needle.67percent")
                    .font(.title3.weight(.semibold))

                Spacer()

                Text("Highest activity first")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SystemGaugeOverview(
                readings: orderedSystemReadings,
                displayMode: .individual,
                layout: .list
            )

            if let io = systemMetrics.diskSnapshot?.io {
                Divider()

                HStack(spacing: 10) {
                    writeRateCell(
                        title: "Write Now",
                        value: io.writeBytesPerSecond,
                        detail: io.rateInterval.map { "\(Int($0.rounded())) sec sample" }
                    )
                    writeRateCell(
                        title: "5 Min",
                        value: io.writeBytesPerSecond5Minutes,
                        detail: "rolling average"
                    )
                    writeRateCell(
                        title: "15 Min",
                        value: io.writeBytesPerSecond15Minutes,
                        detail: "rolling average"
                    )
                }

                Label(
                    "Lifetime TBW is unavailable without drive SMART access; App Mechanic does not invent an estimate.",
                    systemImage: "externaldrive.badge.questionmark"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var mostActiveAppSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Most Active App", systemImage: "app.badge")
                    .font(.headline)

                Spacer()

                Text("Ranked by \(sampler.selectedMetric.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let app = sampler.topApp {
                HStack(spacing: 12) {
                    ProcessIconView(sample: app, size: 28)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(app.appName)
                            .font(.title2.weight(.semibold))
                            .lineLimit(1)

                        Text(sampler.metricText(for: app))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()

                        if sampler.isHeld(app) {
                            Label("Held to protect system memory", systemImage: "pause.circle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                        }

                        if let bundleIdentifier = app.bundleIdentifier {
                            Text(bundleIdentifier)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                        }
                    }

                    Spacer()
                }
            } else if let error = sampler.lastError, !error.isEmpty {
                Text(error)
                    .foregroundStyle(.red)
            } else {
                Text("Waiting for the first process sample.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var processSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Apps")
                    .font(.title3.weight(.semibold))

                Spacer()

                if let lastUpdated = sampler.lastUpdated {
                    Text("\(sampler.topApps.count) · \(sampler.selectedMetric.displayName) · Updated \(lastUpdated.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(sampler.topApps.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            LazyVStack(spacing: 6) {
                ForEach(sampler.topApps) { app in
                    processRow(app)
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .onHover { isHovering in
            sampler.setInteractionFrozen(isHovering)

            if !isHovering {
                hoveredPID = nil
            }
        }
        .confirmationDialog(
            "Force Quit \(pendingForceQuit?.appName ?? "this app")?",
            isPresented: Binding(
                get: { pendingForceQuit != nil },
                set: { isPresented in
                    if !isPresented { pendingForceQuit = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Force Quit", role: .destructive) {
                guard let sample = pendingForceQuit else { return }
                pendingForceQuit = nil
                forceQuitIfCurrent(sample)
            }
            Button("Cancel", role: .cancel) {
                pendingForceQuit = nil
            }
        } message: {
            Text("This ends the selected app and its running processes.")
        }
    }

    private func processRow(_ app: ProcessSample) -> some View {
        HStack(spacing: 12) {
            Button {
                sampler.open(app)
            } label: {
                HStack(spacing: 12) {
                    ProcessIconView(sample: app, size: 18)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.appName)
                            .font(.headline)
                            .lineLimit(1)

                        Text(
                            sampler.isHeld(app)
                                ? "\(app.processType) • Held"
                                : "\(app.processType) • Running \(app.uptimeText)"
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("Click to open \(app.appName)")

            Spacer()

            Text(sampler.metricText(for: app))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            if sampler.isHeld(app) {
                Text("Held")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)

                Button("Resume") {
                    resumeIfCurrent(app)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button("Hold") {
                    holdIfCurrent(app)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button("Kill", role: .destructive) {
                requestForceQuit(app)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Force quit \(app.appName)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hoveredPID == app.pid ? Color.primary.opacity(0.08) : Color.clear)
        )
        .onHover { isHovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredPID = isHovering ? app.pid : (hoveredPID == app.pid ? nil : hoveredPID)
            }
        }
    }

    private func holdIfCurrent(_ sample: ProcessSample) {
        guard isCurrentSample(sample), processIsCurrent(sample) else {
            rejectStaleAction(for: sample)
            return
        }

        sampler.hold(sample)
    }

    private func resumeIfCurrent(_ sample: ProcessSample) {
        guard isCurrentSample(sample), processIsCurrent(sample) else {
            rejectStaleAction(for: sample)
            return
        }

        sampler.resume(sample)
    }

    private func requestForceQuit(_ sample: ProcessSample) {
        guard isCurrentSample(sample), processIsCurrent(sample) else {
            rejectStaleAction(for: sample)
            return
        }

        pendingForceQuit = sample
    }

    private func forceQuitIfCurrent(_ sample: ProcessSample) {
        guard isCurrentSample(sample), processIsCurrent(sample) else {
            rejectStaleAction(for: sample)
            return
        }

        sampler.forceQuit(sample)
    }

    private func rejectStaleAction(for sample: ProcessSample) {
        sampler.lastError = "Action skipped for PID \(sample.pid): the sampled process identity is unavailable or changed. Refresh and try again."
    }

    private func isCurrentSample(_ sample: ProcessSample) -> Bool {
        guard let current = sampler.topApps.first(where: { $0.pid == sample.pid }) else {
            return false
        }

        return current.appName == sample.appName
            && current.bundleIdentifier == sample.bundleIdentifier
            && current.bundleURLPath == sample.bundleURLPath
            && current.executablePath == sample.executablePath
            && current.processStartTime == sample.processStartTime
    }

    private func processIsCurrent(_ sample: ProcessSample) -> Bool {
        return sampler.isCurrentProcess(sample)
    }

    private var orderedSystemReadings: [SystemGaugeReading] {
        SystemGaugeReadings
            .all(sampler: sampler, systemMetrics: systemMetrics)
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.severitySortValue == rhs.element.severitySortValue {
                    return lhs.offset < rhs.offset
                }

                return lhs.element.severitySortValue > rhs.element.severitySortValue
            }
            .map(\.element)
    }

    private func writeRateCell(
        title: String,
        value: Double?,
        detail: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.purple)

            Text(
                value == nil
                    ? "Collecting"
                    : SystemMetricFormatting.bytesPerSecond(value)
            )
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()

            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}
