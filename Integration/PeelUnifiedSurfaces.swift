import AppKit
import SwiftUI

/// Consent and its stop action stay outside the scrolling agent stack.
private struct PeelAgentControlActivity: View {
    @ObservedObject var host: PeelHost

    var body: some View {
        PeelLocalComputerAccessActivity(host: host, access: host.localComputerAccess)
        if host.agentControlAllowed {
            HStack(spacing: 8) {
                Label(host.agentControlStatus, systemImage: "cursorarrow.rays")
                    .font(.caption)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Agent Control: \(host.agentControlStatus)")
                Button("Stop", systemImage: "stop.circle", role: .destructive) {
                    host.setAgentControlAllowed(false)
                }
                .controlSize(.small)
                .accessibilityLabel("Stop Agent Control")
                .help("Stop agent input immediately and revoke control until you enable it again.")
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .contain)
        }
    }
}

/// Visible whenever an AI may use apps on this Mac, with an immediate Stop.
private struct PeelLocalComputerAccessActivity: View {
    @ObservedObject var host: PeelHost
    @ObservedObject var access: PeelLocalComputerAccess

    var body: some View {
        if access.isAllowed {
            HStack(spacing: 8) {
                Label(access.activity ?? "AI can use apps on this Mac", systemImage: "cursorarrow.rays")
                    .font(.caption)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("AI access to this Mac: \(access.activity ?? access.status)")
                Button("Stop", systemImage: "stop.circle", role: .destructive) {
                    host.setLocalComputerAccessAllowed(false)
                }
                .controlSize(.small)
                .accessibilityLabel("Stop AI access to this Mac")
                .help("Stop AI access to apps on this Mac immediately. Turn it on again in Remote Desktop › Share This Mac.")
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .contain)
        }
    }
}

struct PeelUnifiedMenuView: View {
    @Bindable var model: PeelUnifiedModel
    @ObservedObject var host: PeelHost
    @State private var hostExpanded = true
    @State private var pulseExpanded = true
    @State private var usageExpanded = true
    @State private var mechanicExpanded = false
    @AppStorage("peel.bar.appLimit") private var appLimit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AgentNotificationControls(store: model.sidePulse)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            PeelAgentControlActivity(host: host)
                .padding(.horizontal, 16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("Peel Pro", systemImage: "rectangle.on.rectangle")
                            .font(.title2.bold())
                        Spacer()
                        Button("Open", systemImage: "arrow.up.right.square") { model.open(.host) }
                    }
                    Button("switch to notch", action: model.switchToNotch)
                        .buttonStyle(.link)
                    PeelUnifiedNavigationShortcuts(open: model.open)
                    DisclosureGroup("Peel Pro", isExpanded: $hostExpanded) {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(host.statusText).font(.callout)
                            Text("Desktops and individual app windows, each in its own window")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Remote Desktop") { model.openRemoteDesktop(.connect) }
                                    .help("Connect to another computer")
                                Button("Share This Mac…") { model.openRemoteDesktop(.share) }
                                    .help("Pairing, permissions and sharing for this Mac")
                                Button("Copy Pairing Code") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(host.pairingPIN, forType: .string)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }
                    Divider()
                    DisclosureGroup("Notch Pulse", isExpanded: $pulseExpanded) {
                        SidePulseMenuBarView(store: model.sidePulse,
                                             openAgent: model.sidePulse.openAgent,
                                             openCommandCenter: { model.open(.overview) },
                                             openSettings: { model.open(.settings) },
                                             showsNotificationControls: false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider()
                    DisclosureGroup("Usage Limits", isExpanded: $usageExpanded) {
                        PeelUsageCompactRows(store: model.usage, remoteLines: model.sidePulse.remoteUsageLines)
                            .padding(.top, 8)
                        Button("All Usage & Accounts") { model.open(.usage) }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider()
                    PeelMachineStatusRow(sampler: model.sampler, systemMetrics: model.systemMetrics)
                    PeelAnimatedMetricStrip(sampler: model.sampler, systemMetrics: model.systemMetrics)
                    PeelResourceLeadersStrip(sampler: model.sampler, openMechanic: { model.open(.mechanic) })
                    PeelResourceStatusLabel(sampler: model.sampler)
                        .padding(10)
                        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 10))
                    DisclosureGroup("App Mechanic", isExpanded: $mechanicExpanded) {
                        PeelMechanicSurface(processSampler: model.sampler, systemMetrics: model.systemMetrics,
                                            compactAppLimit: appLimit == 5 ? 5 : 3)
                        Button("Open Mechanic") { model.open(.mechanic) }
                    }
                    DisclosureGroup("Menu Bar Indicators") {
                        PeelMenuBarIndicatorPreferences(
                            usage: model.usage,
                            appLimit: $appLimit,
                            systemAlertsOnIdleIndicators: Binding(
                                get: { model.systemAlertsOnIdleIndicators },
                                set: { model.setSystemAlertsOnIdleIndicators($0) }
                            )
                        )
                    }
                    Divider()
                    Button("Quit Peel Pro", systemImage: "power") { NSApp.terminate(nil) }
                }
                .padding(16)
            }
        }
        .frame(width: 480, height: 680)
    }
}

private struct PeelUnifiedNavigationShortcuts: View {
    let open: (CommandCenterSection) -> Void

    var body: some View {
        HStack(spacing: 6) {
            shortcut("Remote Desktop", "display", .host, "1")
            shortcut("Notch Pulse", "circle.dotted", .overview, "2")
            shortcut("Usage Limits", "gauge.with.dots.needle.50percent", .usage, "3")
            shortcut("App Mechanic", "wrench.and.screwdriver", .mechanic, "4")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shortcut(
        _ title: String,
        _ symbol: String,
        _ section: CommandCenterSection,
        _ key: Character
    ) -> some View {
        Button {
            open(section)
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1)
                    Text("⌘⇧\(String(key))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: symbol)
            }
            .font(.caption)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .keyboardShortcut(KeyEquivalent(key), modifiers: [.command, .shift])
        .accessibilityLabel("Open \(title)")
        .accessibilityHint("Command Shift \(String(key))")
    }
}

struct PeelUsageCompactRows: View {
    @Bindable var store: PeelUsageStore
    /// Owner-tagged lines from paired Macs (never added to local values).
    var remoteLines: [RemoteUsageLine] = []
    @AppStorage(PeelUsageBarSelection.providerDefaultsKey) private var selectedProviderID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.snapshot != nil {
                let summary = store.compactSummary(selectedProviderID: selectedProviderID.isEmpty ? nil : selectedProviderID)
                ForEach(summary.rows) { row in
                    HStack {
                        Text(row.name).lineLimit(1)
                        Spacer()
                        if let window = row.window, let remaining = window.normalizedRemainingPercent {
                            Text("\(window.label) · \(Int(remaining.rounded()))% left")
                                .monospacedDigit()
                                .foregroundStyle(remaining <= 20 ? Color.orange : Color.secondary)
                        } else {
                            Text(row.state.shortLabel).foregroundStyle(.secondary)
                        }
                    }.font(.caption)
                }
                if let hidden = summary.hiddenSummaryText {
                    Text(hidden).font(.caption2).foregroundStyle(.secondary)
                }
                if let snapshot = store.snapshot {
                    HStack(spacing: 4) {
                        Text(snapshot.isStale(at: .now) ? "Previous snapshot" : "Snapshot refreshed")
                        Text(snapshot.generatedAt, style: .relative)
                        Text("ago")
                    }.font(.caption2).foregroundStyle(.secondary)
                }
            } else if store.isRefreshing {
                ProgressView("Reading provider limits…").controlSize(.small)
            } else {
                Button("Connect Usage Limits") { store.connect() }
                Text("Use your existing provider connections.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(remoteLines) { line in
                HStack(spacing: 4) {
                    AgentOwnerBadge(label: line.ownerLabel)
                    RemoteUsageLineView(line: line)
                }
            }
        }
    }
}

struct PeelUnifiedBarLabel: View {
    @ObservedObject var sampler: ProcessSampler
    @Bindable var usage: PeelUsageStore
    @State private var gauge = MenuBarGaugeImageCache()
    @AppStorage("peel.bar.showUsage") private var showUsage = true
    @AppStorage("peel.bar.showGauge") private var showGauge = true
    @AppStorage("peel.bar.showTopApp") private var showTopApp = true
    @AppStorage(PeelUsageBarSelection.providerDefaultsKey) private var selectedProviderID = ""
    @AppStorage(PeelUsageBarSelection.windowDefaultsKey) private var selectedWindowKind = ""

    var body: some View {
        HStack(spacing: 6) {
            if showUsage {
                usageLabel
            }
            if showGauge {
                Image(nsImage: gauge.image(for: sampler.currentMetricLoadPercent / 100))
                    .renderingMode(.template).frame(width: 18, height: 18)
                    .help("\(sampler.selectedMetric.displayName) gauge")
            }
            if showTopApp {
                Text(sampler.topApp.map { String($0.appName.prefix(12)) } ?? "Idle")
                    .font(.system(size: 11)).lineLimit(1)
            }
        }
        .fixedSize()
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var usageLabel: some View {
        switch PeelUsageBarSelection.resolve(
            providers: usage.providers,
            providerID: selectedProviderID,
            windowKind: selectedWindowKind)
        {
        case let .value(provider, window, display):
            Text("\(provider.name.prefix(8)) \(PeelUsageBarSelection.valueText(display))")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .help(PeelUsageBarSelection.valueHelp(
                    provider: provider,
                    window: window,
                    display: display))
        case let .unavailable(providerName, windowLabel):
            Text("Unavailable")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .help(PeelUsageBarSelection.unavailableHelp(
                    providerName: providerName,
                    windowLabel: windowLabel))
        case .noProvider:
            Image(systemName: "gauge.with.dots.needle.50percent")
                .help("Connect Usage Limits to show provider limits")
        }
    }
}

struct PeelUnifiedNotchView: View {
    @Bindable var model: PeelUnifiedModel
    @ObservedObject var host: PeelHost
    @ObservedObject var sampler: ProcessSampler

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                Text("Peel Pro").font(.caption.bold())
                Spacer()
                notchButton("Remote", "display", .host, fullTitle: "Remote Desktop")
                notchButton("Notch Pulse", "circle.dotted", .overview)
                notchButton("Usage Limits", "gauge.with.dots.needle.50percent", .usage)
                notchButton("Mechanic", "wrench.and.screwdriver", .mechanic)
            }
            AgentNotificationControls(store: model.sidePulse)
            PeelAgentControlActivity(host: host)
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    NotchIslandView(store: model.sidePulse,
                                    openAgent: model.sidePulse.openAgent,
                                    openCommandCenter: { model.open(.agents) },
                                    togglePower: model.sidePulse.toggleOutputPower,
                                    showsNotificationControls: false)
                        .frame(height: min(180, NotchIslandView.contentHeight(
                            agentCount: model.sidePulse.notchRowCount,
                            showsNotificationControls: false,
                            showsEmptyState: !model.sidePulse.collapsesAgentNotificationSpace)))
                    PeelAnimatedMetricStrip(sampler: sampler, systemMetrics: model.systemMetrics)
                    PeelMachineStatusRow(sampler: sampler, systemMetrics: model.systemMetrics)
                    PeelResourceLeadersStrip(sampler: sampler, openMechanic: { model.open(.mechanic) })
                    PeelResourceStatusLabel(sampler: sampler, compact: true)
                    PeelUsageCompactRows(store: model.usage, remoteLines: model.sidePulse.remoteUsageLines)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)
            Button("switch to menu bar", action: model.switchToMenuBar)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.75))
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(12)
        .foregroundStyle(.white)
        .background(.black, in: .rect(cornerRadius: 14))
    }

    private func notchButton(_ title: String, _ symbol: String, _ section: CommandCenterSection,
                             fullTitle: String? = nil) -> some View {
        Button { model.open(section) } label: {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .lineLimit(1)
            }
            .frame(minWidth: 44, minHeight: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(fullTitle ?? title)")
        .accessibilityLabel("Open \(fullTitle ?? title)")
    }

}

/// Compact Host-owned summary embedded in SidePulse's existing Overview.
/// It observes the same sampler, usage store, and Mechanic controls used by
/// the unified menu and notch; it does not create any new sampling work.
struct PeelOverviewSummary: View {
    @Environment(PeelUnifiedModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("System & usage", systemImage: "gauge.with.dots.needle.50percent")
                    .font(.headline)
                Spacer(minLength: 8)
                Button("Usage") { model.open(.usage) }
                    .buttonStyle(.link)
                Button("Mechanic") { model.open(.mechanic) }
                    .buttonStyle(.link)
            }
            PeelMachineStatusRow(sampler: model.sampler, systemMetrics: model.systemMetrics)
            PeelAnimatedMetricStrip(sampler: model.sampler, systemMetrics: model.systemMetrics)
            PeelResourceLeadersStrip(sampler: model.sampler, openMechanic: { model.open(.mechanic) })
            Divider()
            HStack(spacing: 8) {
                Text("AI usage")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 4)
                Button("All usage") { model.open(.usage) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            PeelUsageCompactRows(store: model.usage, remoteLines: model.sidePulse.remoteUsageLines)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("System meters, resource leaders, and AI usage")
    }
}

private struct PeelAnimatedMetricStrip: View {
    @ObservedObject var sampler: ProcessSampler
    @ObservedObject var systemMetrics: SystemMetricsStore

    private var cpuPercent: Double? {
        guard sampler.hasSystemCPUSample else { return nil }
        return boundedPercent(sampler.systemCPUPercent)
    }

    private var memoryPercent: Double? {
        guard sampler.hasSystemMemorySample else { return nil }
        return boundedPercent(sampler.memoryGaugePercent)
    }

    private var gpuPercent: Double? {
        guard let value = systemMetrics.gpuSnapshot?.utilizationPercent else { return nil }
        return boundedPercent(value)
    }

    var body: some View {
        HStack(spacing: 8) {
            if let cpuPercent {
                PeelAnimatedMeter(title: "CPU", percent: cpuPercent, tint: .cyan)
            }
            if let memoryPercent {
                PeelAnimatedMeter(title: "RAM pressure", percent: memoryPercent, tint: .mint)
                    .help("Memory pressure score, matching App Mechanic. RAM occupancy including cached memory: \(Int(sampler.systemMemoryUsedPercent.rounded()))%.")
            }
            if let gpuPercent {
                PeelAnimatedMeter(title: "GPU", percent: gpuPercent, tint: .purple)
            }
            if cpuPercent == nil, memoryPercent == nil, gpuPercent == nil {
                Text("Waiting for system sample")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.04), in: .rect(cornerRadius: 9))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Animated system meters")
    }

    private func boundedPercent(_ value: Double) -> Double? {
        guard value.isFinite, value >= 0 else { return nil }
        return min(value, 100)
    }
}

private struct PeelAnimatedMeter: View {
    let title: String
    let percent: Double
    let tint: Color

    private var fraction: Double { percent / 100 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(title)
                Spacer(minLength: 2)
                Text(String(format: "%.0f%%", percent))
                    .monospacedDigit()
            }
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(tint)
                        .frame(width: max(3, proxy.size.width * fraction))
                }
            }
            .frame(height: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.35), value: percent)
    }
}

private struct PeelResourceLeadersStrip: View {
    @ObservedObject var sampler: ProcessSampler
    let openMechanic: () -> Void
    @State private var pendingForceQuit: ProcessSample?

    private var leaders: [ProcessSample] {
        Array(sampler.topApps.lazy.filter { sample in
            (sample.cpu.isFinite && sample.cpu >= 0)
                || (sample.memoryMB.isFinite && sample.memoryMB >= 0)
        }.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Label("Resource leaders", systemImage: "chart.bar.xaxis")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .help("Top three apps ranked by \(sampler.selectedMetric.displayName)")
                Spacer(minLength: 4)
                Button("Open Mechanic", systemImage: "wrench.and.screwdriver") {
                    openMechanic()
                }
                .buttonStyle(.plain)
                .font(.caption2.weight(.semibold))
                .help("Open App Mechanic")
                .accessibilityLabel("Open App Mechanic")
            }

            if leaders.isEmpty {
                Text("Waiting for process sample")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        ForEach(leaders) { sample in
                            leaderCell(sample)
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(leaders) { sample in
                            leaderRow(sample)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.04), in: .rect(cornerRadius: 9))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Top process resource leaders")
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

    private func leaderCell(_ sample: ProcessSample) -> some View {
        HStack(spacing: 5) {
            VStack(alignment: .leading, spacing: 2) {
                Text(sample.appName)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    Text("CPU \(cpuText(sample.cpu))")
                    Text("RAM \(memoryText(sample.memoryMB))")
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            processActions(for: sample)
        }
        .frame(minWidth: 132, maxWidth: 168, alignment: .leading)
    }

    private func leaderRow(_ sample: ProcessSample) -> some View {
        HStack(spacing: 6) {
            Text(sample.appName)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("CPU \(cpuText(sample.cpu))")
            Text("RAM \(memoryText(sample.memoryMB))")
            processActions(for: sample)
        }
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    @ViewBuilder
    private func processActions(for sample: ProcessSample) -> some View {
        if sampler.isHeld(sample) {
            Button {
                resumeIfCurrent(sample)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.orange)
            .help("Resume \(sample.appName)")
            .accessibilityLabel("Resume \(sample.appName)")
        }

        Button {
            requestForceQuit(sample)
        } label: {
            ForceQuitBadge()
        }
        .buttonStyle(.plain)
        .help("Force quit \(sample.appName)")
        .accessibilityLabel("Force quit \(sample.appName)")
    }

    private func requestForceQuit(_ sample: ProcessSample) {
        guard isCurrentSample(sample), processIsCurrent(sample) else { return }
        pendingForceQuit = sample
    }

    private func forceQuitIfCurrent(_ sample: ProcessSample) {
        guard isCurrentSample(sample), processIsCurrent(sample) else { return }
        sampler.forceQuit(sample)
    }

    private func isCurrentSample(_ sample: ProcessSample) -> Bool {
        guard let current = sampler.topApps.first(where: { $0.pid == sample.pid }) else {
            return false
        }
        return current.appName == sample.appName
            && current.bundleIdentifier == sample.bundleIdentifier
            && current.executablePath == sample.executablePath
    }

    private func resumeIfCurrent(_ sample: ProcessSample) {
        guard isCurrentSample(sample), processIsCurrent(sample) else { return }
        sampler.resume(sample)
    }

    private func processIsCurrent(_ sample: ProcessSample) -> Bool {
        guard let running = NSRunningApplication(processIdentifier: sample.pid) else {
            return false
        }
        if let bundleIdentifier = sample.bundleIdentifier {
            return running.bundleIdentifier == bundleIdentifier
        }
        guard let executablePath = sample.executablePath else { return false }
        return running.executableURL?.path == executablePath
    }

    private func cpuText(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        return String(format: "%.0f%%", value)
    }

    private func memoryText(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        if value >= 1_024 {
            return String(format: "%.1fG", value / 1_024)
        }
        return String(format: "%.0fM", value)
    }
}

struct PeelResourceStatusLabel: View {
    @ObservedObject var sampler: ProcessSampler
    var compact = false

    private var rule: RunawayMemoryProtection {
        sampler.runawayMemoryProtection.sanitized
    }

    private var heldAppName: String? {
        sampler.heldProcesses.first?.appName
    }

    private var pressureTitle: String {
        switch sampler.systemMemoryPressureState {
        case .normal: return "Memory normal"
        case .warning: return "Memory elevated"
        case .critical: return "Memory critical"
        }
    }

    private var pressureColor: Color {
        if heldAppName != nil { return .orange }
        switch sampler.systemMemoryPressureState {
        case .normal: return .secondary
        case .warning: return .orange
        case .critical: return .red
        }
    }

    private var symbolName: String {
        if heldAppName != nil { return "exclamationmark.triangle.fill" }
        switch sampler.systemMemoryPressureState {
        case .normal: return rule.isEnabled ? "shield.checkered" : "shield.slash"
        case .warning, .critical: return "exclamationmark.triangle.fill"
        }
    }

    private var protectionTitle: String {
        if let heldAppName {
            return "Runaway hold · \(heldAppName)"
        }
        guard rule.isEnabled else { return "Runaway protection off" }
        let appName = rule.appMatch.isEmpty ? "configured app" : rule.appMatch
        return "Runaway watch · \(appName)"
    }

    private var thresholdText: String {
        if rule.memoryThresholdMB >= 1_024 {
            return String(format: "%.1f GB", rule.memoryThresholdMB / 1_024)
        }
        return "\(Int(rule.memoryThresholdMB.rounded())) MB"
    }

    private var detailText: String {
        var details = [pressureTitle]
        if sampler.hasSystemMemorySample {
            details.append("RAM \(Int(sampler.systemMemoryUsedPercent.rounded()))% occupied including cache")
        } else {
            details.append("memory sample pending")
        }
        if rule.isEnabled {
            details.append("threshold \(thresholdText)")
        }
        return details.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbolName)
                .font(.system(size: compact ? 9 : 11, weight: .semibold))
                .foregroundStyle(pressureColor)

            if compact {
                Text(heldAppName.map { "Held · \($0)" } ??
                     (rule.isEnabled ? "\(pressureTitle) · runaway watch" : "\(pressureTitle) · runaway off"))
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(protectionTitle)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(detailText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .foregroundStyle(.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(protectionTitle)
        .accessibilityValue(detailText)
        .help("\(protectionTitle) · \(detailText)")
    }
}

struct PeelMachineStatusRow: View {
    @ObservedObject var sampler: ProcessSampler
    @ObservedObject var systemMetrics: SystemMetricsStore

    var body: some View {
        let status = PeelMachineStatus(sampler: sampler, systemMetrics: systemMetrics)
        HStack(alignment: .top, spacing: 8) {
            ForEach(status.badges) { badge in
                VStack(alignment: .leading, spacing: 3) {
                    Text(badge.title).foregroundStyle(.secondary)
                    Text(badge.displayValue).monospacedDigit()
                        .foregroundStyle(color(badge.severity))
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .font(.caption2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(badge.isStale ? "Previous sample is stale" : (badge.detail ?? "Measurement unavailable"))
            }
        }
        .help(status.attributionNote)
    }

    private func color(_ severity: PeelMachineStatusSeverity) -> Color {
        switch severity {
        case .unavailable: return .secondary
        case .normal: return .primary
        case .elevated: return .orange
        case .critical: return .red
        }
    }
}

struct PeelTrustedSignalsCard: View {
    @Environment(PeelUnifiedModel.self) private var peel
    let store: CommandCenterStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Paired Computers", systemImage: "lock.shield").font(.headline)
            Text("\(Text(startupSummary).foregroundStyle(.primary)) \(startupNextStep) Notch Pulse sharing uses computers paired through Peel Pro. Unpaired broadcasts are ignored.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Pair a Computer in Peel Pro", systemImage: "link.badge.plus") {
                store.openPeelPairing?()
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.openPeelPairing == nil)
            Button("Manage Trusted Devices") { peel.openRemoteDesktop(.share) }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    /// This Mac's own local startup state. Local readiness is not a connection.
    private var startupSummary: String {
        switch store.nearbyServiceSnapshot.startup {
        case .notStarted:
            "Paired computer sharing hasn't started on this Mac yet."
        case .identityUnavailable:
            "This Mac's sharing identity couldn't be loaded, so paired computer sharing is unavailable here."
        case .disabled:
            "Paired computer sharing is off on this Mac."
        case .noUsablePairedTrust(pairedKeyUnavailable: false):
            "This Mac has no paired computer it can use for sharing right now."
        case .noUsablePairedTrust(pairedKeyUnavailable: true):
            "This Mac couldn't read the saved key for a paired computer, so sharing can't start."
        case .preparing:
            "Starting local sharing on this Mac…"
        case .localReady(.browseOnly):
            "This Mac is looking for paired computers on this network. That doesn't mean one is connected."
        case .localReady:
            "This Mac is available to paired computers on this network. That doesn't mean one is connected."
        case .failed(.listenerCreate):
            "Local sharing couldn't start on this Mac."
        case .failed(.listenerFailed):
            "Local sharing stopped on this Mac; Peel is trying again."
        case .failed(.browserFailed):
            "Looking for paired computers stopped on this Mac; Peel is trying again."
        case .failed(.listenerWaiting), .failed(.browserWaiting):
            "Local sharing on this Mac is waiting for the network."
        }
    }

    private var startupNextStep: String {
        switch store.nearbyServiceSnapshot.startup {
        case .notStarted, .failed(.listenerFailed), .failed(.browserFailed):
            "If this doesn't change, quit and reopen Peel."
        case .identityUnavailable, .failed(.listenerCreate):
            "Quit and reopen Peel."
        case .disabled:
            "To use it, turn on Share this Mac or Find nearby Macs below, or the Paired Macs switches in Agent Hub."
        case .noUsablePairedTrust:
            "Check Manage Trusted Devices, or quit and reopen Peel."
        case .preparing:
            "This usually takes a few seconds."
        case .localReady:
            "Agent Hub shows whether a paired Mac is actually connected."
        case .failed(.listenerWaiting), .failed(.browserWaiting):
            "Check that this Mac is on the same network as the other computer."
        }
    }
}
