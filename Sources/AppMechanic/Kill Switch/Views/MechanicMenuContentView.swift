//
//  MechanicMenuContentView.swift
//  Kill Switch
//
//


//
//  MechanicMenuContentView.swift
//  Kill Switch
//


import SwiftUI
import AppKit
import Darwin

struct MechanicMenuContentView: View {
    @EnvironmentObject var sampler: ProcessSampler
    @EnvironmentObject var systemMetrics: SystemMetricsStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var hoveredPID: pid_t?
    @AppStorage("menuBarGaugeMask") private var menuBarGaugeMask = SystemGaugeSelection.defaultMask
    @AppStorage("popupGaugeDisplayMode") private var popupGaugeDisplayModeRawValue = PopupGaugeDisplayMode.individual.rawValue


    private var popupGaugeDisplayMode: PopupGaugeDisplayMode {
        PopupGaugeDisplayMode(rawValue: popupGaugeDisplayModeRawValue) ?? .individual
    }

    private var selectedSystemReadings: [SystemGaugeReading] {
        let selectedMetrics = Set(SystemGaugeSelection.metrics(in: menuBarGaugeMask))
        return SystemGaugeReadings
            .all(sampler: sampler, systemMetrics: systemMetrics)
            .filter { selectedMetrics.contains($0.metric) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: 8) {

                    Image(nsImage: NSApp.applicationIconImage)

                        .resizable()

                        .scaledToFit()

                        .frame(width: 24, height: 24)

                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                    Text("App Mechanic")

                        .font(.title2.weight(.semibold))

                }

                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()

                Button {
                    showControlPanel()
                } label: {
                    Image(systemName: "macwindow")
                }
                .buttonStyle(.bordered)
                .help("Open full app")
            }
            


            HStack {
                Spacer()
                Picker(
                    "Metric",
                    selection: Binding(
                        get: { sampler.selectedMetric },
                        set: { newValue in
                            sampler.updateSelectedMetric(newValue)
                        }
                    )
                ) {
                    ForEach(UsageMetric.allCases) { metric in
                        Text(metric.displayName).tag(metric)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.large)
                .labelsHidden()
                Spacer()
            }
            
            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("System Gauges")
                        .font(.headline)

                    Spacer()

                    Text(popupGaugeDisplayMode.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SystemGaugeOverview(
                    readings: selectedSystemReadings,
                    displayMode: popupGaugeDisplayMode
                )
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apps")
                        .font(.headline)

                    Text("Hover a row for Force Quit")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(sampler.topApps.count)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()

                    Text(sampler.selectedMetric.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                LazyVStack(spacing: 2) {
                    if sampler.topApps.isEmpty {
                        Text(sampler.lastError ?? "Waiting for the first process sample.")
                            .foregroundStyle(
                                sampler.lastError == nil
                                    ? Color.secondary
                                    : Color.red
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                    } else {
                        ForEach(sampler.topApps) { app in
                            processRow(app)
                        }
                    }
                }
            }
            .scrollIndicators(.visible)
            .frame(minHeight: 220, maxHeight: 320)
        }
        .padding()
        .frame(width: 400)
        .contentShape(Rectangle())
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    showControlPanel()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .help("Open full app")
            }
        }
        .onHover { isHovering in
            DispatchQueue.main.async {
                sampler.setInteractionFrozen(isHovering)
            }
        }
    }

    private func showControlPanel() {
        if let existingWindow = AppDelegate.controlPanelWindow {
            existingWindow.makeKeyAndOrderFront(nil)
            existingWindow.orderFrontRegardless()
        } else {
            openWindow(id: "control-panel")
        }

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)

            if let window = AppDelegate.controlPanelWindow {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }

            dismiss()
        }
    }

    private func processRow(_ app: ProcessSample) -> some View {
        HStack(spacing: 10) {
            ProcessIconView(sample: app, size: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.appName)
                    .lineLimit(1)

                Text(
                    sampler.isHeld(app)
                        ? "\(app.processType) • Held"
                        : "\(app.processType) • Running \(app.uptimeText)"
                )
                    .font(.caption2)
                    .foregroundStyle(sampler.isHeld(app) ? Color.orange : Color.secondary)
            }

            Spacer()

            Text(
                sampler.selectedMetric == .cpu
                    ? String(format: "%.1f%%", app.cpu)
                    : String(format: "%.1f MB", app.memoryMB)
            )
            .monospacedDigit()
            .foregroundStyle(.secondary)

            if sampler.isHeld(app) {
                Button("Resume") {
                    sampler.resume(app)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    sampler.forceQuit(app)
                } label: {
                    ForceQuitBadge()
                }
                .buttonStyle(.plain)
                .help("Force quit \(app.appName)")
            } else if hoveredPID == app.pid {
                Button {
                    sampler.forceQuit(app)
                } label: {
                    ForceQuitBadge()
                }
                .buttonStyle(.plain)
                .help("Force quit \(app.appName)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hoveredPID == app.pid ? Color.primary.opacity(0.08) : Color.clear)
        )
        .help(app.processType == "App" ? "Click to open app" : "Click to open in Activity Monitor")
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            sampler.open(app)
        }
        .onHover { isHovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredPID = isHovering ? app.pid : (hoveredPID == app.pid ? nil : hoveredPID)
            }
        }
    }
}
