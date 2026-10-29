//
//  ControlPanelAlertsView.swift
//  Kill Switch
//
//  Created by Zach on 4/16/26.
//

//
//  ControlPanelAlertsView.swift
//  Kill Switch
//

import SwiftUI
import UserNotifications

struct ControlPanelAlertsView: View {
    @EnvironmentObject var sampler: ProcessSampler
    @State private var watchedAppName = ""

    private var standardAlertRules: [IntentAlertRule] {
        sampler.alertRules.filter { $0.trigger != .appAppeared }
    }

    private var processAlertRules: [IntentAlertRule] {
        sampler.alertRules.filter { $0.trigger == .appAppeared }
    }

    private var notificationStatusLabel: String {
        switch sampler.notificationAuthorizationStatus {
        case .authorized:
            return sampler.isNotificationAlertsEnabled ? "Allowed" : "Allowed, Off"
        case .provisional:
            return sampler.isNotificationAlertsEnabled ? "Quietly Allowed" : "Quietly Allowed, Off"
        case .ephemeral:
            return sampler.isNotificationAlertsEnabled ? "Temporarily Allowed" : "Temporarily Allowed, Off"
        case .denied:
            return "Denied"
        case .notDetermined:
            return sampler.isNotificationAlertsEnabled ? "Not Requested Yet" : "Off"
        @unknown default:
            return "Unknown"
        }
    }

    private var simpleNotificationDescription: String {
        switch sampler.notificationAuthorizationStatus {
        case .authorized:
            return sampler.isNotificationAlertsEnabled
                ? "App Mechanic can send you alerts."
                : "Alerts are turned off."
        case .provisional:
            return sampler.isNotificationAlertsEnabled
                ? "App Mechanic can send you quiet alerts."
                : "Alerts are turned off."
        case .denied:
            return "Notifications are off in Mac settings."
        case .notDetermined:
            return "Turn notifications on to get alerts."
        @unknown default:
            return "Notification status is unavailable."
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {

                    Image(nsImage: NSApp.applicationIconImage)

                        .resizable()

                        .scaledToFit()

                        .frame(width: 32, height: 32)

                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                    Text("Alerts")

                        .font(.largeTitle.weight(.semibold))

                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Notification Access")
                        .font(.headline)

                    Toggle(isOn: Binding(
                        get: { sampler.isNotificationAlertsEnabled },
                        set: { newValue in
                            sampler.setNotificationAlertsEnabled(newValue)
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enable Notifications")


                        }
                    }
                    .toggleStyle(.switch)

                    HStack {
                        
                        
                        Text(notificationStatusLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        
                        

                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
                HStack {
                    Spacer()
                    Button("Open Notification Settings") {
                        sampler.openNotificationSettings()
                    }
                    .buttonStyle(.bordered)
                }

                runawayMemoryProtectionSection

                VStack(alignment: .leading, spacing: 12) {
                    Text("Configured Alerts")
                        .font(.headline)

                    if standardAlertRules.isEmpty {
                        Text("No standard alerts configured yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(standardAlertRules) { rule in
                                AlertRuleCard(
                                    rule: binding(for: rule),
                                    onTest: {
                                        sampler.testAlert(rule.id)
                                    },
                                    onDelete: {
                                        sampler.removeAlert(rule.id)
                                    }
                                )
                            }
                        }
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )

                VStack(alignment: .leading, spacing: 12) {
                    Text("Create Process Alert")
                        .font(.headline)

                    Text("Add a name to get an alert when that app or process shows up.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        TextField("Safari, Xcode, com.apple.Safari, etc.", text: $watchedAppName)

                        Button("Add Alert") {
                            let trimmed = watchedAppName.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            sampler.addWatchedAppAlert(named: trimmed)
                            watchedAppName = ""
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if processAlertRules.isEmpty {
                        Text("No custom process alerts yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(processAlertRules) { rule in
                                AlertRuleCard(
                                    rule: binding(for: rule),
                                    onTest: {
                                        sampler.testAlert(rule.id)
                                    },
                                    onDelete: {
                                        sampler.removeAlert(rule.id)
                                    }
                                )
                            }
                        }
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Recent Alert Activity")
                            .font(.headline)

                        Spacer()

                        if !sampler.recentAlertEvents.isEmpty {
                            Button("Clear") {
                                sampler.clearAlertHistory()
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    if sampler.recentAlertEvents.isEmpty {
                        Text("No alerts fired yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(sampler.recentAlertEvents) { event in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(event.ruleName)
                                            .font(.body.weight(.semibold))

                                        Spacer()

                                        Text(event.date, style: .time)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Text(event.message)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.primary.opacity(0.04))
                                )
                            }
                        }
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )

                HStack {
                    Spacer()

                    Button("Reset to Defaults") {
                        watchedAppName = ""
                        sampler.resetAlertsToDefaults()
                    }
                }
                .padding(.top, 4)
            }
            .padding(20)
        }
        .navigationTitle("App Mechanic")
        .onAppear {
            sampler.refreshNotificationAuthorizationStatus()
        }
    }

    private func binding(for rule: IntentAlertRule) -> Binding<IntentAlertRule> {
        Binding(
            get: {
                sampler.alertRules.first(where: { $0.id == rule.id }) ?? rule
            },
            set: { newValue in
                sampler.updateAlert(newValue)
            }
        )
    }

    private var runawayMemoryProtectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(
                "Hold Runaway App",
                isOn: protectionBinding(\.isEnabled)
            )
            .font(.headline)
            .toggleStyle(.switch)

            Text("App Mechanic totals the main app and its helper processes. When the matching app reaches the limit, it is paused—not quit—so the Mac can recover.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("App name or bundle ID")
                Spacer()
                TextField(
                    "ChatGPT",
                    text: protectionBinding(\.appMatch)
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
            }

            HStack {
                Text("Hold at")
                Spacer()
                Text(
                    ByteCountFormatter.string(
                        fromByteCount: Int64(
                            sampler.runawayMemoryProtection.memoryThresholdMB * 1_048_576
                        ),
                        countStyle: .memory
                    )
                )
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }

            Stepper(
                value: protectionBinding(\.memoryThresholdMB),
                in: 512...32_768,
                step: 256
            ) {
                EmptyView()
            }
            .labelsHidden()

            if !sampler.heldProcesses.isEmpty {
                Divider()

                ForEach(sampler.heldProcesses) { held in
                    Label(
                        "\(held.appName) held at \(ByteCountFormatter.string(fromByteCount: Int64(held.memoryMBAtHold * 1_048_576), countStyle: .memory))",
                        systemImage: "pause.circle.fill"
                    )
                    .foregroundStyle(.orange)
                }

                Text("Use Resume or Force Quit beside the held app on Home or in the menu-bar popup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private func protectionBinding<Value>(
        _ keyPath: WritableKeyPath<RunawayMemoryProtection, Value>
    ) -> Binding<Value> {
        Binding(
            get: { sampler.runawayMemoryProtection[keyPath: keyPath] },
            set: { newValue in
                var updated = sampler.runawayMemoryProtection
                updated[keyPath: keyPath] = newValue
                sampler.updateRunawayMemoryProtection(updated)
            }
        )
    }
}

private struct AlertRuleCard: View {
    @Binding var rule: IntentAlertRule
    let onTest: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $rule.isEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.name)
                        .font(.body.weight(.semibold))

                    Text(rule.summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            switch rule.trigger {
            case .cpuThresholdExceeded:
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("CPU threshold")
                        Spacer()
                        Text("\(Int(rule.cpuThreshold))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Stepper(value: $rule.cpuThreshold, in: 10...400, step: 5) {
                        EmptyView()
                    }
                    .labelsHidden()

                    HStack {
                        Text("Sustain for")
                        Spacer()
                        Text("\(rule.requiredConsecutiveMatches * 2) sec")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Stepper(value: $rule.requiredConsecutiveMatches, in: 1...60, step: 1) {
                        EmptyView()
                    }
                    .labelsHidden()
                }

            case .memoryThresholdExceeded:
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Memory threshold")
                        Spacer()
                        Text("\(Int(rule.memoryThresholdMB)) MB")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Stepper(value: $rule.memoryThresholdMB, in: 256...32768, step: 128) {
                        EmptyView()
                    }
                    .labelsHidden()

                    HStack {
                        Text("Sustain for")
                        Spacer()
                        Text("\(rule.requiredConsecutiveMatches * 2) sec")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Stepper(value: $rule.requiredConsecutiveMatches, in: 1...60, step: 1) {
                        EmptyView()
                    }
                    .labelsHidden()
                }

            case .appAppeared:
                VStack(alignment: .leading, spacing: 8) {
                    Text("Match value")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("App name or bundle id", text: $rule.watchedAppName)

                    HStack {
                        Text("Sustain for")
                        Spacer()
                        Text("\(rule.requiredConsecutiveMatches * 2) sec")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Stepper(value: $rule.requiredConsecutiveMatches, in: 1...60, step: 1) {
                        EmptyView()
                    }
                    .labelsHidden()
                }

            case .topAppChanged:
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Cooldown")
                        Spacer()
                        Text("\(Int(rule.cooldownSeconds)) sec")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Stepper(value: $rule.cooldownSeconds, in: 10...1800, step: 10) {
                        EmptyView()
                    }
                    .labelsHidden()
                }
            }

            if rule.trigger != .topAppChanged {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Cooldown")
                        Spacer()
                        Text("\(Int(rule.cooldownSeconds)) sec")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Stepper(value: $rule.cooldownSeconds, in: 10...1800, step: 10) {
                        EmptyView()
                    }
                    .labelsHidden()
                }
            }

            HStack(spacing: 10) {
                Button("Test") {
                    onTest()
                }

                if rule.trigger == .appAppeared {
                    Button("Remove", role: .destructive) {
                        onDelete()
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}
