import AppKit
import Darwin
import SwiftUI

/// The App Mechanic surface used by the unified Mac host.
///
/// The sampler and system-metrics store are owned by the host lifecycle. This
/// view observes those instances and never starts another sampling loop.
struct PeelMechanicSurface: View {
    enum Presentation: Hashable {
        case compact
        case controlPanel
        case alerts
        case settings
    }

    @ObservedObject private var sampler: ProcessSampler
    @ObservedObject private var systemMetrics: SystemMetricsStore

    private let presentation: Presentation
    private let compactAppLimit: Int
    private let openHostSettings: (() -> Void)?

    @State private var isShowingControlPanel = false
    @State private var hoveredPID: pid_t?

    // These keys are shared with App Mechanic's existing popup. Keeping the
    // same storage and defaults preserves the user's gauge choices.
    @AppStorage("menuBarGaugeMask") private var menuBarGaugeMask = SystemGaugeSelection.defaultMask
    @AppStorage("popupGaugeDisplayMode") private var popupGaugeDisplayModeRawValue = PopupGaugeDisplayMode.individual.rawValue

    init(
        processSampler: ProcessSampler,
        systemMetrics: SystemMetricsStore,
        presentation: Presentation = .compact,
        compactAppLimit: Int = 5,
        openHostSettings: (() -> Void)? = nil
    ) {
        _sampler = ObservedObject(wrappedValue: processSampler)
        _systemMetrics = ObservedObject(wrappedValue: systemMetrics)
        self.presentation = presentation
        self.openHostSettings = openHostSettings
        self.compactAppLimit = compactAppLimit >= 5 ? 5 : 3
    }

    var body: some View {
        switch presentation {
        case .compact:
            compactBody
        case .controlPanel:
            ControlPanelHomeView(title: "App Mechanic")
                .environmentObject(sampler)
                .environmentObject(systemMetrics)
        case .alerts:
            ControlPanelAlertsView()
                .environmentObject(sampler)
        case .settings:
            ControlPanelSettingsView(showsAboutFooter: true, embeddedInHost: true,
                                     openPeelProSettings: openHostSettings)
                .environmentObject(sampler)
        }
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            systemGauges
            severityApps
        }
        .padding(16)
        .frame(minWidth: 420, idealWidth: 520)
        .sheet(isPresented: $isShowingControlPanel) {
            PeelMechanicSurface(
                processSampler: sampler,
                systemMetrics: systemMetrics,
                presentation: .controlPanel,
                compactAppLimit: compactAppLimit
            )
            .frame(minWidth: 620, idealWidth: 700, minHeight: 360, idealHeight: 420)
        }
        .onDisappear {
            // A menu-bar popover can disappear without the hover exit firing.
            // Always return ownership of ordering to the sampler when it closes.
            hoveredPID = nil
            sampler.setInteractionFrozen(false)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label("App Mechanic", systemImage: "gauge.with.dots.needle.67percent")
                .font(.title3.weight(.semibold))

            Spacer(minLength: 8)

            Button("Open Controls", systemImage: "macwindow") {
                isShowingControlPanel = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var systemGauges: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("System Gauges")
                    .font(.headline)

                Spacer(minLength: 8)

                Text(popupGaugeDisplayMode.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SystemGaugeOverview(
                readings: selectedSystemReadings,
                displayMode: popupGaugeDisplayMode
            )
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var severityApps: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Top \(compactAppLimit) Apps")
                        .font(.headline)

                    Text("Ranked by \(sampler.selectedMetric.displayName) severity")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if let lastUpdated = sampler.lastUpdated {
                    Text(lastUpdated, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if severitySamples.isEmpty {
                Text(sampler.lastError ?? "Waiting for the first process sample.")
                    .font(.caption)
                    .foregroundStyle(sampler.lastError == nil ? Color.secondary : Color.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                LazyVStack(spacing: 5) {
                    ForEach(severitySamples) { sample in
                        severityRow(sample)
                    }
                }
            }

            if let lastError = sampler.lastError, !lastError.isEmpty, !severitySamples.isEmpty {
                Text(lastError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .onHover { isHovering in
            sampler.setInteractionFrozen(isHovering)

            if !isHovering {
                hoveredPID = nil
            }
        }
    }

    private var popupGaugeDisplayMode: PopupGaugeDisplayMode {
        PopupGaugeDisplayMode(rawValue: popupGaugeDisplayModeRawValue) ?? .individual
    }

    private var selectedSystemReadings: [SystemGaugeReading] {
        let selectedMetrics = Set(SystemGaugeSelection.metrics(in: menuBarGaugeMask))
        return SystemGaugeReadings
            .all(sampler: sampler, systemMetrics: systemMetrics)
            .filter { selectedMetrics.contains($0.metric) }
    }

    private var severitySamples: [ProcessSample] {
        Array(sampler.topApps.prefix(compactAppLimit))
    }

    private func severityRow(_ sample: ProcessSample) -> some View {
        HStack(spacing: 8) {
            ProcessIconView(sample: sample, size: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(sample.appName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text(
                    sampler.isHeld(sample)
                        ? "Held · \(sample.processType)"
                        : "\(sample.processType) · Running \(sample.uptimeText)"
                )
                .font(.caption2)
                .foregroundStyle(sampler.isHeld(sample) ? Color.orange : Color.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(sampler.metricText(for: sample))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if sampler.isHeld(sample) {
                Button("Resume") {
                    sampler.resume(sample)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button("Hold") {
                    sampler.hold(sample)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button("Kill", role: .destructive) {
                forceQuit(sample)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Force quit \(sample.appName)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(hoveredPID == sample.pid ? Color.primary.opacity(0.08) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { isHovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredPID = isHovering ? sample.pid : (hoveredPID == sample.pid ? nil : hoveredPID)
            }
        }
    }

    @MainActor
    private func forceQuit(_ sample: ProcessSample) {
        guard Self.matchesCurrentProcessIdentity(sample), sampler.isCurrentProcess(sample) else {
            sampler.lastError = "Kill skipped for PID \(sample.pid): the sampled process identity is unavailable or changed. Refresh and try again."
            return
        }

        sampler.forceQuit(sample)
    }

    @MainActor
    private static func matchesCurrentProcessIdentity(_ sample: ProcessSample) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: sample.pid) else {
            return false
        }

        var comparedStableIdentity = false

        if let expectedBundleIdentifier = normalizedIdentity(sample.bundleIdentifier) {
            comparedStableIdentity = true
            guard app.bundleIdentifier == expectedBundleIdentifier else {
                return false
            }
        }

        if let expectedBundleURLPath = normalizedPath(sample.bundleURLPath) {
            comparedStableIdentity = true
            guard normalizedPath(app.bundleURL?.path) == expectedBundleURLPath else {
                return false
            }
        }

        if let expectedExecutablePath = normalizedPath(sample.executablePath) {
            comparedStableIdentity = true
            guard normalizedPath(app.executableURL?.path) == expectedExecutablePath else {
                return false
            }
        }

        // A PID and display name alone are not enough to authorize a kill.
        return comparedStableIdentity
    }

    private static func normalizedIdentity(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedPath(_ value: String?) -> String? {
        guard let value = normalizedIdentity(value) else { return nil }
        return URL(fileURLWithPath: value)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}
