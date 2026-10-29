import Foundation

// Synthetic process trees only: no real process, Terminal, Automation or
// user session is touched. Mirrors the documented hook model: command hooks
// run WITHOUT a controlling terminal, as children of the agent.

private struct FakeInspector: AgentProcessInspecting {
    var processes: [Int32: AgentProcessRecord]
    var ttys: [UInt32: String] = [5: "/dev/ttys005", 7: "/dev/ttys007", 9: "/dev/console"]

    func record(pid: Int32) -> AgentProcessRecord? { processes[pid] }
    func ttyPath(device: UInt32) -> String? { ttys[device] }
}

private let user: UInt32 = 501
private let terminalPath = "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"
private let claudePath = "/Users/developer/.local/share/claude/versions/2.1.307"

private func proc(_ pid: Int32, parent: Int32, name: String, tty: UInt32?, uid: UInt32 = user,
                  path: String? = nil, start: UInt64 = 1_000) -> AgentProcessRecord {
    AgentProcessRecord(stamp: AgentProcessStamp(pid: pid, startSeconds: start, startMicroseconds: UInt64(pid)),
                       parentPID: parent, uid: uid, ttyDevice: tty, name: name, executablePath: path)
}

/// Terminal.app → login(root) → zsh → claude(native, ttys005) → sh (no tty) → python3 hook (no tty)
private func terminalTree() -> [Int32: AgentProcessRecord] {
    [
        100: proc(100, parent: 1, name: "Terminal", tty: nil, path: terminalPath),
        200: proc(200, parent: 100, name: "login", tty: 5, uid: 0),
        300: proc(300, parent: 200, name: "zsh", tty: 5),
        400: proc(400, parent: 300, name: "2.1.307", tty: 5, path: claudePath),
        500: proc(500, parent: 400, name: "sh", tty: nil),
        600: proc(600, parent: 500, name: "python3", tty: nil, path: "/usr/bin/python3"),
    ]
}

private func resolve(_ tree: [Int32: AgentProcessRecord], pid: Int32 = 600, uid: UInt32 = user,
                     ttys: [UInt32: String]? = nil) -> AgentTerminalBindingResult {
    var inspector = FakeInspector(processes: tree)
    if let ttys { inspector.ttys = ttys }
    return AgentTerminalBindingResolver.resolve(peer: AgentHookPeer(pid: pid, uid: uid), expectedUID: user,
                                                inspector: inspector)
}

@main
enum AgentProcessIdentitySmoke {
    static func main() {
        testNoTTYHookChildBindsToClaude()
        testFailClosedCases()
        testRevalidation()
        testSupersededSessions()
        testClassifier()
        testTerminalScriptContract()
        print("Agent process identity smoke passed: no-TTY hook → native Claude → Terminal, fail-closed, revalidated")
    }

    static func testNoTTYHookChildBindsToClaude() {
        guard case .bound(let binding) = resolve(terminalTree()) else {
            preconditionFailure("A no-TTY hook child must still bind via its Claude parent")
        }
        precondition(binding.agent.pid == 400 && binding.agentExecutablePath == claudePath)
        precondition(binding.ttyPath == "/dev/ttys005", "The agent's TTY is used, not the hook's")
        precondition(binding.host == .appleTerminal(app: terminalTree()[100]!.stamp))
        precondition(binding.chain.map(\.pid) == [300, 200], "Exact agent→host parent chain is recorded")

        var direct = terminalTree()
        direct[600]?.parentPID = 400  // spawned without a shell
        guard case .bound = resolve(direct) else { preconditionFailure("Direct child of Claude binds") }

        var iterm = terminalTree()
        iterm[100] = proc(100, parent: 1, name: "iTerm2", tty: nil, path: "/Applications/iTerm.app/Contents/MacOS/iTerm2")
        guard case .bound(let other) = resolve(iterm), case .application(_, let name) = other.host else {
            preconditionFailure("Expected app-only host")
        }
        precondition(name == "iTerm")
    }

    static func testFailClosedCases() {
        precondition(resolve(terminalTree(), uid: 502) == .unavailable(.foreignUser))
        var foreign = terminalTree()
        foreign[600]?.uid = 0
        precondition(resolve(foreign) == .unavailable(.foreignUser))
        precondition(resolve(terminalTree(), pid: 9_999) == .unavailable(.senderExited),
                     "A hook that exited before inspection binds nothing")
        var orphan = terminalTree()
        orphan[500] = nil
        precondition(resolve(orphan) == .unavailable(.senderExited), "Broken ancestry during the race binds nothing")

        // Unknown wrapper/launcher between hook and agent (uv/node/python).
        var wrapped = terminalTree()
        wrapped[500] = proc(500, parent: 400, name: "uv", tty: nil, path: "/opt/homebrew/bin/uv")
        precondition(resolve(wrapped) == .unavailable(.unverified))
        var nodeWrapper = terminalTree()
        nodeWrapper[500] = proc(500, parent: 400, name: "node", tty: 5, path: "/opt/homebrew/bin/node")
        precondition(resolve(nodeWrapper) == .unavailable(.unverified),
                     "The first non-shell ancestor is not trusted unless it is a recognized agent")

        // npm/node-launched or unknown agent: not a recognized executable.
        var unknownAgent = terminalTree()
        unknownAgent[400] = proc(400, parent: 300, name: "claude", tty: 5, path: "/opt/homebrew/bin/node")
        precondition(resolve(unknownAgent) == .unavailable(.unverified))
        var fakeVersions = terminalTree()
        fakeVersions[400] = proc(400, parent: 300, name: "claude", tty: 5, path: "/tmp/claude/versions/2.1.307")
        precondition(resolve(fakeVersions) == .unavailable(.unverified))

        // Headless AGENT (e.g. `claude -p` in the background) is unavailable;
        // a headless HOOK alone never implies that (covered above).
        var headless = terminalTree()
        headless[400]?.ttyDevice = nil
        precondition(resolve(headless) == .unavailable(.headless))

        var tmux = terminalTree()
        tmux[300] = proc(300, parent: 250, name: "zsh", tty: 7)
        tmux[250] = proc(250, parent: 1, name: "tmux", tty: nil)
        tmux[400]?.ttyDevice = 7
        precondition(resolve(tmux) == .unavailable(.multiplexer))

        var ssh = terminalTree()
        ssh[200] = proc(200, parent: 150, name: "sshd-session", tty: 5, uid: 0)
        ssh[150] = proc(150, parent: 1, name: "sshd", tty: nil, uid: 0)
        precondition(resolve(ssh) == .unavailable(.remoteShell))

        var noGUI = terminalTree()
        noGUI[200] = proc(200, parent: 1, name: "launchd-child", tty: 5, uid: 0)
        noGUI[100] = nil
        precondition(resolve(noGUI) == .unavailable(.noTerminalApp))

        precondition(resolve(terminalTree(), ttys: [5: "/dev/console"]) == .unavailable(.unverified),
                     "Only /dev/ttysN paths are ever passed to Terminal")
    }

    static func testRevalidation() {
        let tree = terminalTree()
        guard case .bound(let binding) = resolve(tree) else { preconditionFailure() }
        func check(_ t: [Int32: AgentProcessRecord]) -> AgentTerminalRevalidation {
            AgentTerminalBindingResolver.revalidate(binding, inspector: FakeInspector(processes: t))
        }
        var hookGone = tree
        hookGone[500] = nil
        hookGone[600] = nil
        precondition(check(hookGone) == .valid, "The hook exiting later does not matter")

        var reused = tree
        reused[400] = proc(400, parent: 300, name: "2.1.307", tty: 5, path: claudePath, start: 2_000)
        precondition(check(reused) == .agentEnded, "A reused PID with a new birth time is a different process")
        var swappedExe = tree
        swappedExe[400]?.executablePath = "/opt/homebrew/bin/node"
        precondition(check(swappedExe) == .agentEnded)
        var moved = tree
        moved[400]?.ttyDevice = 7
        precondition(check(moved) == .agentEnded)
        var reparented = tree
        reparented[400]?.parentPID = 1
        precondition(check(reparented) == .terminalChanged, "The recorded parent chain must still hold")
        var newShell = tree
        newShell[300] = proc(300, parent: 200, name: "zsh", tty: 5, start: 4_000)
        precondition(check(newShell) == .terminalChanged)
        var relaunched = tree
        relaunched[100] = proc(100, parent: 1, name: "Terminal", tty: nil, path: terminalPath, start: 3_000)
        precondition(check(relaunched) == .terminalChanged)
    }

    static func binding(boundAt: TimeInterval, host: AgentTerminalHost? = nil) -> AgentTerminalBinding {
        AgentTerminalBinding(
            agent: AgentProcessStamp(pid: 400, startSeconds: 1, startMicroseconds: 1),
            agentExecutablePath: claudePath, ttyDevice: 5, ttyPath: "/dev/ttys005",
            host: host ?? .appleTerminal(app: AgentProcessStamp(pid: 100, startSeconds: 1, startMicroseconds: 1)),
            hostExecutablePath: terminalPath, chain: [], boundAt: Date(timeIntervalSince1970: boundAt))
    }

    static func testSupersededSessions() {
        let old = binding(boundAt: 10)
        let new = binding(boundAt: 20)
        let current = AgentTerminalBindingResolver.currentBindings(["claude:session:a": .bound(old),
                                                                    "claude:session:b": .bound(new)])
        precondition(current["claude:session:a"] == .unavailable(.superseded),
                     "After /clear the old session must not claim the tab now showing the new one")
        precondition(current["claude:session:b"] == .bound(new))
    }

    static func testClassifier() {
        func agent(_ provider: AgentProvider, id: String = "s1") -> AgentSession {
            AgentSession(id: "\(provider.rawValue):session:\(id)", provider: provider, sessionID: id, name: "Fixture",
                         project: "Peel", cwd: "/private/should-not-matter", state: .working, eventName: "PreToolUse",
                         toolName: nil, updatedAt: .now, message: nil)
        }
        let terminal = binding(boundAt: 1)
        let iterm = binding(boundAt: 1, host: .application(app: terminal.host.app, name: "iTerm"))
        precondition(AgentActivationClassifier.support(for: agent(.claude), binding: .bound(terminal)).0 == .exactSession)
        let appOnly = AgentActivationClassifier.support(for: agent(.claude), binding: .bound(iterm))
        precondition(appOnly.0 == .applicationOnly && appOnly.reason == "terminal_app_only")
        precondition(AgentActivationClassifier.support(for: agent(.codex), binding: .bound(iterm)).0 == .exactSession)
        let none = AgentActivationClassifier.support(for: agent(.claude), binding: nil)
        precondition(none.0 == .unavailable && none.reason == "no_destination")
        let headless = AgentActivationClassifier.support(for: agent(.claude), binding: .unavailable(.headless))
        precondition(headless.0 == .unavailable && headless.reason == "headless")
        precondition(AgentActivationClassifier.support(for: agent(.codex), binding: .unavailable(.unrecognizedAgent)).0
                        == .exactSession, "Codex keeps its thread URL even without a terminal binding")
        let grok = AgentActivationClassifier.support(for: agent(.grokBot), binding: nil)
        precondition(grok.0 == .applicationOnly && grok.reason == "app_only_url")
    }

    static func testTerminalScriptContract() {
        let script = AgentActivationExecutor.terminalScript.joined(separator: "\n").lowercased()
        for forbidden in ["do script", "contents", "history", "keystroke", "do shell script", "make new",
                          "custom title", "launch", "name of", "processes"] {
            precondition(!script.contains(forbidden), "Terminal script must not use `\(forbidden)`")
        }
        precondition(script.contains("is not running then return"), "Never launch Terminal to focus a session")
        precondition(script.contains("matchcount is greater than 1 then return \"ambiguous\""))
        precondition(script.contains("item 1 of argv"), "The TTY is an argument, never interpolated")

        typealias R = AgentActivationExecutor.TerminalScriptResult
        precondition(AgentActivationExecutor.parse(stdout: "focused\n", stderr: "", exitCode: 0) == R.focused)
        precondition(AgentActivationExecutor.parse(stdout: "delivered", stderr: "", exitCode: 0) == R.delivered)
        precondition(AgentActivationExecutor.parse(stdout: "ambiguous", stderr: "", exitCode: 0) == R.ambiguous)
        precondition(AgentActivationExecutor.parse(stdout: "noTab", stderr: "", exitCode: 0) == R.noTab)
        precondition(AgentActivationExecutor.parse(stdout: "surprise", stderr: "", exitCode: 0) == R.failed(code: nil))
        let denied = AgentActivationExecutor.parse(
            stdout: "", stderr: "execution error: Not authorized to send Apple events to Terminal. (-1743)", exitCode: 1)
        precondition(denied == R.failed(code: -1743))
        precondition(AgentActivationExecutor.outcome(for: denied) == .automationDenied)
        precondition(AgentActivationExecutor.outcome(for: R.focused) == .focusedExactSession)
        precondition(AgentActivationExecutor.outcome(for: R.delivered) == .exactSessionRequested,
                     "An unverified selection is reported as requested, not focused")
        precondition(AgentActivationExecutor.outcome(for: R.ambiguous) == .ambiguousTarget)
        precondition(AgentActivationExecutor.outcome(for: R.noTab) == .sessionEnded)

        precondition(AgentTerminalBindingResolver.isTerminalTTYPath("/dev/ttys012"))
        for bad in ["/dev/ttys", "/dev/ttys12345", "/dev/ttys1; echo", "/dev/console", "ttys001", "/dev/ttys00a"] {
            precondition(!AgentTerminalBindingResolver.isTerminalTTYPath(bad), bad)
        }
    }
}
