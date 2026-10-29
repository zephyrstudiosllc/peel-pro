import SwiftUI

/// Keep this row outside the agent scroller so a full stack cannot hide it.
struct AgentNotificationControls: View {
    @Bindable var store: CommandCenterStore

    var body: some View {
        HStack(spacing: 8) {
            Text(store.agentNotificationsHidden ? "Agents hidden" : "Agents")
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("Clear All", systemImage: "xmark.circle") {
                store.clearAgentNotifications()
            }
            .disabled(store.pendingAgentNotificationCount == 0)
            .help("Clear current agent notifications. New events can appear; agents keep running.")
            .accessibilityLabel("Clear All Agent Notifications")
            .accessibilityHint("Clears the notch and menu bar only. Agents keep running.")
            Button(store.agentNotificationsHidden ? "Show Agents" : "Hide Agents",
                   systemImage: store.agentNotificationsHidden ? "eye" : "eye.slash") {
                store.setAgentNotificationsHidden(!store.agentNotificationsHidden)
            }
            .help("Hide agent notifications in the notch and menu bar until you show them again. Agents keep running.")
            .accessibilityLabel(store.agentNotificationsHidden ? "Show Agent Notifications" : "Hide Agent Notifications")
            .accessibilityValue(store.agentNotificationsHidden ? "Hidden" : "Shown")
        }
        .font(.caption)
        .controlSize(.small)
        .buttonStyle(.bordered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent notification controls")
    }
}

struct AgentNotificationSettingsView: View {
    @Bindable var store: CommandCenterStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agent Notifications").font(.headline)
            Toggle("Hide Agent Notifications", isOn: Binding(
                get: { store.agentNotificationsHidden },
                set: { store.setAgentNotificationsHidden($0) }
            ))
            .toggleStyle(.switch)
            Button("Clear All Agent Notifications", systemImage: "xmark.circle") {
                store.clearAgentNotifications()
            }
            .disabled(store.pendingAgentNotificationCount == 0)
            Text("Applies to the notch and menu bar. Agents keep running, with sessions and history available in Agent Hub. Lights continue normally. Cleared notifications return only for new events.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
