import AppKit
import SwiftUI

@main
enum AgentNotificationSmoke {
    @MainActor
    static func main() async throws {
        precondition(ProcessInfo.processInfo.arguments.contains("--peel-preview"),
                     "This fixture must never start the live agent or hardware runtime")
        let liveHiddenBefore = AppPreferences.agentNotificationsHidden()
        let liveDismissalsBefore = UserDefaults.standard.data(forKey: "sidepulse.agent-notification-dismissals.v1")
        let suiteName = "sidepulse.notification-smoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        if ProcessInfo.processInfo.arguments.contains("--show-fixture") {
            showFixture(defaults: defaults)
            NSApp.run()
            return
        }

        testPresentationAndHistory(defaults: defaults)
        testSnapshotRetention()
        await testStoreAndViews(defaults: defaults)
        precondition(AppPreferences.agentNotificationsHidden() == liveHiddenBefore)
        precondition(UserDefaults.standard.data(forKey: "sidepulse.agent-notification-dismissals.v1") == liveDismissalsBefore,
                     "The smoke must not change live notification preferences")
        print("Agent notification smoke passed: exact Clear All, refresh/relaunch, new events, durable Hide/Show, history/output isolation, bounded snapshot, and capped notch layout")
    }

    fileprivate static func sessions(count: Int) -> [AgentSession] {
        (0..<count).map { index in
            AgentSession(id: "codex:fixture-\(index)", provider: .codex, sessionID: "fixture-\(index)",
                         name: "Fixture \(index)", project: "Test", cwd: nil,
                         state: [.working, .waiting, .error, .completed][index % 4],
                         eventName: "Fixture", toolName: nil,
                         updatedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)), message: nil)
        }
    }

    private static func testPresentationAndHistory(defaults: UserDefaults) {
        let original = sessions(count: 5000)
        var history = AgentSignalHistoryLedger()
        history.record(original)
        let historyBefore = history.entries
        let stateBefore = AgentDisplayPolicy.aggregateState(for: original, mode: .simple)
        let lightingBefore = AgentDisplayPolicy.lightingSessions(from: original, mode: .simple)
        var presentation = AgentNotificationPresentation()
        precondition(presentation.visibleSessions(original).count == original.count)

        presentation.clearCurrent(original)
        precondition(presentation.clearedCount == original.count)
        precondition(presentation.visibleSessions(original).isEmpty, "Clear All must have no arbitrary stack limit")
        precondition(!presentation.reconcile(with: original), "An unchanged refresh must stay cleared")
        presentation.save(to: defaults)
        presentation = .load(from: defaults)
        precondition(presentation.visibleSessions(original).isEmpty, "Relaunch must not revive the same stack")

        var renamed = original[0]
        renamed.name = "Renamed without an event"
        renamed.openURL = URL(string: "codex://threads/new-title")
        precondition(presentation.visibleSessions([renamed]).isEmpty)
        var stale = original[0]
        stale.updatedAt = stale.updatedAt.addingTimeInterval(-1)
        stale.state = .error
        precondition(presentation.visibleSessions([stale]).isEmpty, "Stale discovery must not revive cleared work")

        var next = original[0]
        next.updatedAt = next.updatedAt.addingTimeInterval(1)
        precondition(presentation.visibleSessions([next]).count == 1, "A new event timestamp must be eligible")
        next = original[0]
        next.state = .completed
        precondition(presentation.visibleSessions([next]).count == 1, "Same-time state changes are new events")
        next = original[0]
        next.eventName = "New event"
        precondition(presentation.visibleSessions([next]).count == 1)
        next = original[0]
        next.toolName = "A new tool"
        precondition(presentation.visibleSessions([next]).count == 1)
        precondition(presentation.visibleSessions([next], hidden: true).isEmpty)

        precondition(history.entries == historyBefore, "Presentation must not erase task history")
        precondition(AgentDisplayPolicy.aggregateState(for: original, mode: .simple) == stateBefore)
        precondition(AgentDisplayPolicy.lightingSessions(from: original, mode: .simple) == lightingBefore,
                     "Clearing presentation must not acknowledge or alter the agent signal")
    }

    private static func testSnapshotRetention() {
        var presentation = AgentNotificationPresentation()
        var current = sessions(count: 100)
        for generation in 0..<100 {
            for index in current.indices {
                current[index].updatedAt = Date(timeIntervalSince1970: Double(1_800_000_000 + generation * 100 + index))
            }
            presentation.clearCurrent(current)
            precondition(presentation.clearedCount == current.count, "Past event generations must not accumulate")
        }
        let changed = current.map { session -> AgentSession in
            var updated = session
            updated.state = .toolRunning
            return updated
        }
        precondition(presentation.reconcile(with: changed))
        precondition(presentation.clearedCount == 0)
        presentation.clearCurrent(current)
        precondition(presentation.reconcile(with: []))
        precondition(presentation.clearedCount == 0, "Disappeared sessions must release their markers")
    }

    @MainActor
    private static func testStoreAndViews(defaults: UserDefaults) async {
        _ = NSApplication.shared
        AgentNotificationPresentation().save(to: defaults)
        AppPreferences.saveAgentNotificationsHidden(false, to: defaults)
        let store = CommandCenterStore(notificationDefaults: defaults)
        store.universalBrightness = 1
        store.agentDisplayMode = .simple
        store.agents = sessions(count: 1000).map { agent in
            var working = agent
            working.state = .working
            return working
        }
        store.recompile()
        let original = store.agents
        var history = AgentSignalHistoryLedger()
        history.record(original)
        store.agentSignalHistory = history.entries
        let historyBefore = store.agentSignalHistory
        let programBefore = store.softwareDisplayProgram
        precondition(store.notchDrivingAgents.count == original.count)
        let maxHeight = NotchIslandView.contentHeight(agentCount: original.count)
        precondition(maxHeight == NotchIslandView.contentHeight(agentCount: 4))
        precondition(maxHeight < 270, "A full stack must scroll, leaving utility controls in reach")

        let controls = NSHostingView(rootView: AgentNotificationControls(store: store))
        controls.frame = CGRect(x: 0, y: 0, width: 376, height: 28)
        let island = NSHostingView(rootView: NotchIslandView(
            store: store, openAgent: { _ in }, openCommandCenter: {}, togglePower: {}))
        island.frame = CGRect(x: 0, y: 0, width: 400, height: maxHeight)
        controls.layoutSubtreeIfNeeded()
        island.layoutSubtreeIfNeeded()

        store.clearAgentNotifications()
        precondition(store.agentNotificationSessions.isEmpty && store.notchDrivingAgents.isEmpty)
        precondition(store.collapsesAgentNotificationSpace)
        precondition(store.agents == original && store.agentSignalHistory == historyBefore)
        precondition(store.softwareDisplayProgram == programBefore)
        let collapsedHeight = NotchIslandView.contentHeight(agentCount: 0, showsEmptyState: false)
        precondition(collapsedHeight == 114 && collapsedHeight < maxHeight)
        var restored = CommandCenterStore(notificationDefaults: defaults)
        restored.agents = original
        precondition(restored.agentNotificationSessions.isEmpty)

        var updated = original[0]
        updated.updatedAt = updated.updatedAt.addingTimeInterval(1)
        store.agents[0] = updated
        precondition(store.agentNotificationSessions.map(\.id) == [updated.id])
        precondition(store.notchDrivingAgents.map(\.id) == [updated.id], "A new event must not be blocked by old cleared sessions")
        store.setAgentNotificationsHidden(true)
        precondition(store.agentNotificationSessions.isEmpty && store.notchDrivingAgents.isEmpty)
        precondition(AppPreferences.agentNotificationsHidden(from: defaults))
        restored = CommandCenterStore(notificationDefaults: defaults)
        restored.agents = store.agents
        precondition(restored.agentNotificationsHidden && restored.agentNotificationSessions.isEmpty)
        restored.setAgentNotificationsHidden(false)
        precondition(!AppPreferences.agentNotificationsHidden(from: defaults))
        precondition(restored.agentNotificationSessions.map(\.id) == [updated.id])
        precondition(store.agents[0] == updated && store.agents.count == original.count)
        precondition(store.softwareDisplayProgram == programBefore)
        await Task.yield()
    }

    @MainActor
    private static func showFixture(defaults: UserDefaults) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        let view = NSHostingView(rootView: AgentNotificationFixture(defaults: defaults))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 780, height: 760),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Peel Notification Controls Fixture"
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Interactive QA uses actual production views and a random isolated defaults
/// suite. The preview initializer never starts runtime, networking or hardware.
private struct AgentNotificationFixture: View {
    let defaults: UserDefaults
    @State private var store: CommandCenterStore
    @State private var action = "Ready for Clear All and Hide / Show checks"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        _store = State(initialValue: Self.makeStore(defaults: defaults))
    }

    private static func makeStore(defaults: UserDefaults) -> CommandCenterStore {
        AgentNotificationPresentation().save(to: defaults)
        AppPreferences.saveAgentNotificationsHidden(false, to: defaults)
        let result = CommandCenterStore(notificationDefaults: defaults)
        result.universalBrightness = 1
        result.flashlightMode = .behindAnimations
        result.flashlightEnabled = true
        result.agentDisplayMode = .simple
        result.agents = AgentNotificationSmoke.sessions(count: 1000).map {
            var agent = $0
            agent.state = .working
            return agent
        }
        var history = AgentSignalHistoryLedger()
        history.record(result.agents)
        result.agentSignalHistory = history.entries
        result.recompile()
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Peel notification controls · isolated fixture").font(.title2.bold())
            Text("Synthetic sessions only. No live agents, devices or settings are changed.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Reset 1,000 Notifications") { store = Self.makeStore(defaults: defaults) }
                Button("New Agent Event") {
                    store.agents[0].updatedAt = max(Date.now, store.agents[0].updatedAt.addingTimeInterval(1))
                    store.agents[0].eventName = UUID().uuidString
                }
                Button("Close Fixture") { NSApp.terminate(nil) }
            }
            Text("\(store.agents.count) sessions · \(store.agentSignalHistory.count) history entries · \(store.agentNotificationSessions.count) visible notifications")
                .font(.caption.monospaced())
                .accessibilityLabel("Fixture counts: \(store.agents.count) sessions, \(store.agentSignalHistory.count) history entries, \(store.agentNotificationSessions.count) visible notifications")
            Text(action).font(.caption)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Actual notch surface").font(.headline)
                    NotchIslandView(store: store,
                                    openAgent: { _ in action = "Agent destination opened" },
                                    openCommandCenter: { action = "Command Center remains reachable" },
                                    togglePower: { action = "Power remains reachable (fixture does not change output)" })
                        .frame(width: 400, height: NotchIslandView.contentHeight(
                            agentCount: store.notchDrivingAgents.count,
                            showsEmptyState: !store.collapsesAgentNotificationSpace))
                    Text("The large stack scrolls inside the panel. Other controls stay in place.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Actual menu bar surface").font(.headline)
                    SidePulseMenuBarView(store: store,
                                         openAgent: { _ in action = "Agent destination opened" },
                                         openCommandCenter: { action = "Command Center remains reachable" },
                                         openSettings: { action = "Settings remain reachable" })
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 720, alignment: .topLeading)
    }
}
