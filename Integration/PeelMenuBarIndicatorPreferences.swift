import SwiftUI

/// Shared menu-bar indicator preferences used by Host's menu and Command
/// Center Settings. The AppStorage keys remain compatible with the existing
/// menu-bar label and SidePulse presentation.
struct PeelMenuBarIndicatorPreferences: View {
    @Bindable var usage: PeelUsageStore
    @Binding var appLimit: Int
    @Binding var systemAlertsOnIdleIndicators: Bool
    @AppStorage("peel.bar.showLEDs") private var showLEDs = true
    @AppStorage("peel.bar.showUsage") private var showUsage = true
    @AppStorage("peel.bar.showGauge") private var showGauge = true
    @AppStorage("peel.bar.showTopApp") private var showTopApp = true

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle("Notch Pulse LEDs", isOn: $showLEDs)
            Toggle("Usage limits", isOn: $showUsage)
            PeelUsageBarSelectionControls(store: usage)
            Toggle("My gauge", isOn: $showGauge)
            Toggle("Top app name", isOn: $showTopApp)
            Toggle("System alerts on idle indicators", isOn: $systemAlertsOnIdleIndicators)
            Text("Show system alerts when your Notch Pulse indicators are available.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Picker("Top apps in Mechanic", selection: $appLimit) {
                Text("Top 3").tag(3)
                Text("Top 5").tag(5)
            }
            .pickerStyle(.segmented)
            Text("Hold, resume or quit an app from its row.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }
}
