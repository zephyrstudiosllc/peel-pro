import Foundation

/// Dismissals belong to the compact UI, never the agent runtime or LED output.
/// Only event identity is retained; messages, paths and task history stay out.
struct AgentNotificationPresentation: Codable, Sendable {
    private static let storageKey = "sidepulse.agent-notification-dismissals.v1"

    private struct Event: Codable, Equatable, Sendable {
        var updatedAt: Date
        var state: AgentState
        var eventName: String
        var toolName: String?

        init(_ session: AgentSession) {
            updatedAt = session.updatedAt
            state = session.state
            eventName = session.eventName
            toolName = session.toolName
        }

        func suppresses(_ session: AgentSession) -> Bool {
            // An older discovery snapshot must not revive a cleared event.
            session.updatedAt < updatedAt || self == Event(session)
        }
    }

    private var clearedByID: [String: Event] = [:]
    var clearedCount: Int { clearedByID.count }

    init() {}

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: storageKey),
              let result = try? JSONDecoder().decode(Self.self, from: data)
        else { return Self() }
        return result
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    func visibleSessions(_ sessions: [AgentSession], hidden: Bool = false) -> [AgentSession] {
        guard !hidden else { return [] }
        return sessions.filter { $0.state != .idle && clearedByID[$0.id]?.suppresses($0) != true }
    }

    mutating func clearCurrent(_ sessions: [AgentSession]) {
        let ordered = sessions.filter { $0.state != .idle }.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
        }
        // Replace the snapshot rather than accumulating past dismissals. Its
        // size is bounded by the current sessions, so Clear All stays exact.
        clearedByID = Dictionary(
            ordered.map { ($0.id, Event($0)) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Retire a dismissal when its event changes or its session leaves the
    /// authoritative snapshot. Refreshing the same event keeps it dismissed.
    @discardableResult
    mutating func reconcile(with sessions: [AgentSession]) -> Bool {
        let current = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let previousCount = clearedByID.count
        clearedByID = clearedByID.filter { id, event in
            current[id].map { event.suppresses($0) } ?? false
        }
        return clearedByID.count != previousCount
    }
}
