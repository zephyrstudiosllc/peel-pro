import Foundation

// Row color semantics, open-destination allow-list, activation outcome wire
// names and paired-row capability text. Compiled with Models.swift only.

@main
enum AgentPresentationSmoke {
    static func main() {
        testRowColorsUseActualState()
        testCustomPaletteIsRespected()
        testAggregateKeepsSimpleModeMeaning()
        testDestinationAllowList()
        testOutcomeWireNames()
        testRemoteRowCapabilities()
        print("Agent presentation smoke passed: actual row colors, allow-listed destinations, honest outcomes")
    }

    private static func session(_ state: AgentState, id: String = UUID().uuidString,
                                provider: AgentProvider = .claude, openURL: URL? = nil) -> AgentSession {
        AgentSession(id: id, provider: provider, sessionID: id, name: "Fixture", project: "Peel", cwd: nil,
                     state: state, eventName: "Fixture", toolName: nil, updatedAt: .now, message: nil,
                     openURL: openURL)
    }

    private static func testRowColorsUseActualState() {
        let profile = LightingProfile.factoryDefault
        let tool = AgentStatePresentation.rowColorHex(for: .toolRunning, profile: profile)
        let working = AgentStatePresentation.rowColorHex(for: .working, profile: profile)
        precondition(tool == profile.style(for: .toolRunning).colorHex)
        precondition(working == profile.style(for: .working).colorHex)
        precondition(tool != working, "Tool Running and Thinking rows must stay visually distinct")
        for state in AgentState.allCases {
            precondition(AgentStatePresentation.rowColorHex(for: state, profile: profile)
                            == profile.style(for: state).colorHex,
                         "Every row state must use its own saved color")
        }
        precondition(AgentStatePresentation.rowColorHex(for: nil, profile: profile)
                        == AgentStatePresentation.unknownColorHex,
                     "An unknown remote state must render neutral, never borrow another state's color")
    }

    private static func testCustomPaletteIsRespected() {
        var profile = LightingProfile.factoryDefault
        var waiting = profile.style(for: .waiting)
        waiting.colorHex = "#123456"
        profile.updateStyle(waiting)
        precondition(AgentStatePresentation.rowColorHex(for: .waiting, profile: profile) == "#123456",
                     "A saved custom palette must win over factory defaults")
    }

    private static func testAggregateKeepsSimpleModeMeaning() {
        let profile = LightingProfile.factoryDefault
        let agents = [session(.toolRunning)]
        precondition(AgentStatePresentation.aggregateColorHex(for: agents, mode: .simple, profile: profile)
                        == profile.style(for: .working).colorHex,
                     "Simple mode's combined signal still counts tool activity as Thinking")
        precondition(AgentStatePresentation.aggregateColorHex(for: agents, mode: .perAgent, profile: profile)
                        == profile.style(for: .toolRunning).colorHex)
        precondition(AgentStatePresentation.aggregateColorHex(for: [], mode: .simple, profile: profile) == nil)
    }

    private static func testDestinationAllowList() {
        func support(_ string: String) -> AgentActivationSupport {
            AgentOpenRouting.support(forDestination: URL(string: string)!)
        }
        precondition(support("codex://threads/abc") == .exactSession)
        precondition(support("codex://threads/abc/extra") == .unavailable)
        precondition(support("codex://threads/abc?cmd=rm") == .unavailable)
        precondition(support("codex://settings") == .unavailable)
        precondition(support("grokbot://app/v1/open") == .applicationOnly)
        precondition(support("grokbot://app/v1/run") == .unavailable)
        precondition(support("https://chatgpt.com/codex/tasks/task-1") == .exactSession)
        precondition(support("https://evil.example/codex/tasks/task-1") == .unavailable)
        precondition(support("file:///Applications/Calculator.app") == .unavailable)
        precondition(support("x-apple.systempreferences:com.apple.Focus") == .unavailable)

        let claude = session(.working, provider: .claude)
        precondition(AgentOpenRouting.allowedDestination(for: claude) == nil,
                     "Claude CLI sessions have no URL; only a verified terminal binding can open them")
        let hostile = session(.working, provider: .codex, openURL: URL(string: "file:///tmp/payload")!)
        precondition(AgentOpenRouting.allowedDestination(for: hostile) == nil,
                     "A non-allow-listed openURL must never be opened")
        let codex = session(.working, id: "thread-1", provider: .codex)
        precondition(AgentOpenRouting.allowedDestination(for: codex)?.absoluteString == "codex://threads/thread-1")
    }

    private static func testOutcomeWireNames() {
        // These raw values are the paired-Mac wire contract
        // (PeelPeerActivationOutcome). Renaming one breaks old/new peers.
        let expected = [
            "focusedExactSession", "exactSessionRequested", "applicationOnly", "unsupported", "sessionEnded",
            "staleEpoch", "ownerLocked", "notAllowed", "rateLimited", "launchFailed", "automationDenied",
            "ambiguousTarget", "terminalNotRunning", "requestConflict", "targetChanged", "unknownResult", "timedOut", "ownerOffline", "revoked",
            "peerTooOld",
        ]
        precondition(AgentActivationOutcome.allCases.map(\.rawValue) == expected)
        precondition(AgentActivationOutcome.focusedExactSession.isSuccess)
        precondition(AgentActivationOutcome.exactSessionRequested.isSuccess)
        precondition(AgentActivationOutcome.applicationOnly.isSuccess)
        precondition(!AgentActivationOutcome.timedOut.isSuccess)
        precondition(AgentActivationOutcome.exactSessionRequested.message(owner: "MacBook", appLabel: "Codex")
                        .contains("not confirmed"),
                     "Delivery must not be described as visual focus")
        precondition(AgentActivationOutcome.timedOut.message(owner: "MacBook", appLabel: nil)
                        .contains("may or may not"))
        precondition(AgentActivationOutcome.ownerOffline.message(owner: "MacBook", appLabel: nil)
                        .contains("nothing was opened"))
    }

    private static func testRemoteRowCapabilities() {
        var row = RemoteAgentRow(id: "peer:x:claude:t", ownerHostID: UUID().uuidString, ownerLabel: "MacBook",
                                 provider: .claude, providerTitle: "Claude", name: "Fix", project: "Peel",
                                 state: .waiting, toolName: nil, updatedAt: .now, isAlert: true,
                                 activation: .exactSession, unavailableReason: nil, freshness: .live,
                                 ownerAcceptsActivation: true)
        precondition(row.canRequestActivation && row.actionTitle == "Open session")
        row.freshness = .reconnecting(since: .now)
        precondition(!row.canRequestActivation && row.actionTitle == "MacBook offline",
                     "A stale owner must refuse clicks rather than guess")
        row.freshness = .live
        row.ownerAcceptsActivation = false
        precondition(!row.canRequestActivation && row.actionTitle == "View only")
        row.ownerAcceptsActivation = true
        row.activation = .unavailable
        precondition(!row.canRequestActivation && row.actionTitle == "No open action")
        row.state = nil
        precondition(row.stateTitle == "Unknown state" && row.priority > AgentState.idle.priority - 1)
    }
}
