import AppKit
import CoreGraphics
import Foundation

/// Opens one of THIS Mac's sessions, for a local click or an authenticated
/// paired-Mac request. Every path uses only owner-local data:
///
/// - Terminal.app session with a kernel-verified binding: re-prove the agent
///   and Terminal processes (PID + birth time), then select the one existing
///   tab whose `tty` matches, using a fixed script whose only input is the
///   validated `/dev/ttysN` path. Success is reported as exact only when the
///   selected tab of Terminal's front window reads back as that TTY.
/// - Other verified GUI host (iTerm, editors): activate that exact app
///   process; reported as app-only.
/// - Allow-listed session URL (Codex thread/cloud task) via NSWorkspace;
///   reported as "requested", because delivery is not visual confirmation.
///
/// It never starts a terminal, shell, agent, `--resume`/`--continue`, never
/// reads tab contents/history, never falls back to a first window, title or
/// working-directory match, and never acts on another Mac.
@MainActor
enum AgentActivationExecutor {
    typealias Completion = @MainActor (AgentActivationOutcome, String?) -> Void

    nonisolated static let terminalBundleIdentifier = "com.apple.Terminal"
    nonisolated static let scriptTimeout: TimeInterval = 15

    /// `stillAuthorized` is consulted immediately before the side effect,
    /// after the process revalidation work. A local click passes `{ true }`.
    static func activate(_ agent: AgentSession,
                         binding: AgentTerminalBindingResult?,
                         requireUnlocked: Bool,
                         stillAuthorized: @escaping @MainActor () -> Bool,
                         completion: @escaping Completion) {
        if requireUnlocked, isScreenLocked() {
            completion(.ownerLocked, nil)
            return
        }
        if case .bound(let terminal) = binding {
            let inspector = DarwinAgentProcessInspector()
            switch AgentTerminalBindingResolver.revalidate(terminal, inspector: inspector) {
            case .agentEnded:
                completion(.sessionEnded, terminal.host.label)
                return
            case .terminalChanged:
                completion(.terminalNotRunning, terminal.host.label)
                return
            case .valid:
                break
            }
            switch terminal.host {
            case .appleTerminal(let app):
                guard let running = NSRunningApplication(processIdentifier: app.pid),
                      running.bundleIdentifier == terminalBundleIdentifier, !running.isTerminated else {
                    completion(.terminalNotRunning, "Terminal")
                    return
                }
                guard stillAuthorized() else { completion(.notAllowed, nil); return }
                focusTerminalTab(ttyPath: terminal.ttyPath, completion: completion)
                return
            case .application(let app, let name):
                // A session URL addresses the session itself; prefer it.
                if let url = AgentOpenRouting.allowedDestination(for: agent),
                   AgentOpenRouting.support(forDestination: url) == .exactSession {
                    break
                }
                guard let running = NSRunningApplication(processIdentifier: app.pid), !running.isTerminated else {
                    completion(.terminalNotRunning, name)
                    return
                }
                guard stillAuthorized() else { completion(.notAllowed, nil); return }
                completion(running.activate() ? .applicationOnly : .launchFailed, name)
                return
            }
        }

        guard let url = AgentOpenRouting.allowedDestination(for: agent) else {
            completion(.unsupported, nil)
            return
        }
        let support = AgentOpenRouting.support(forDestination: url)
        let label = AgentOpenRouting.applicationLabel(for: url)
        guard stillAuthorized() else { completion(.notAllowed, nil); return }
        let workspace = NSWorkspace.shared
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let finish: @Sendable (Error?) -> Void = { error in
            Task { @MainActor in
                if error != nil { completion(.launchFailed, label); return }
                completion(support == .exactSession ? .exactSessionRequested : .applicationOnly, label)
            }
        }
        if let bundleIdentifier = AgentOpenRouting.applicationBundleIdentifier(for: url),
           let applicationURL = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            workspace.open([url], withApplicationAt: applicationURL, configuration: configuration) { _, error in
                finish(error)
            }
        } else if AgentOpenRouting.applicationBundleIdentifier(for: url) != nil {
            // The session's own app is not installed: report it, do not guess.
            completion(.launchFailed, label)
        } else {
            workspace.open(url, configuration: configuration) { _, error in finish(error) }
        }
    }

    static func isScreenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    // MARK: Terminal.app

    /// Fixed script. Its only input is argv item 1, a validated TTY path.
    /// It reads only window IDs/tab counts and each tab's `tty` property
    /// (never a tab's `contents`/`history`), refuses zero or multiple
    /// matches, never launches Terminal, and creates nothing.
    nonisolated static let terminalScript: [String] = [
        "on run argv",
        "set targetTTY to item 1 of argv",
        "if application id \"com.apple.Terminal\" is not running then return \"notRunning\"",
        "tell application id \"com.apple.Terminal\"",
        "set matchCount to 0",
        "set matchWindowID to 0",
        "set matchTabIndex to 0",
        "repeat with wi from 1 to (count of windows)",
        "try",
        "set tabCount to count of tabs of window wi",
        "on error",
        "set tabCount to 0",
        "end try",
        "repeat with ti from 1 to tabCount",
        "try",
        "set tabTTY to tty of tab ti of window wi",
        "on error",
        "set tabTTY to \"\"",
        "end try",
        "if tabTTY is targetTTY then",
        "set matchCount to matchCount + 1",
        "set matchWindowID to id of window wi",
        "set matchTabIndex to ti",
        "end if",
        "end repeat",
        "end repeat",
        "if matchCount is 0 then return \"noTab\"",
        "if matchCount is greater than 1 then return \"ambiguous\"",
        "set targetWindow to window id matchWindowID",
        "set selected tab of targetWindow to tab matchTabIndex of targetWindow",
        "set index of targetWindow to 1",
        "activate",
        "delay 0.2",
        "if frontmost and ((tty of selected tab of front window) is targetTTY) then return \"focused\"",
        "return \"delivered\"",
        "end tell",
        "end run",
    ]

    nonisolated enum TerminalScriptResult: Equatable, Sendable {
        case focused, delivered, noTab, ambiguous, notRunning
        case failed(code: Int?)
    }

    nonisolated static func outcome(for result: TerminalScriptResult) -> AgentActivationOutcome {
        switch result {
        case .focused: .focusedExactSession
        case .delivered: .exactSessionRequested
        case .noTab: .sessionEnded
        case .ambiguous: .ambiguousTarget
        case .notRunning: .terminalNotRunning
        case .failed(let code):
            // -1743: errAEEventNotPermitted (Automation consent missing/denied).
            code == -1743 ? .automationDenied : .launchFailed
        }
    }

    nonisolated static func parse(stdout: String, stderr: String, exitCode: Int32) -> TerminalScriptResult {
        if exitCode == 0 {
            switch stdout.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "focused": return .focused
            case "delivered": return .delivered
            case "noTab": return .noTab
            case "ambiguous": return .ambiguous
            case "notRunning": return .notRunning
            default: return .failed(code: nil)
            }
        }
        // osascript reports "… (-1743)" style codes on stderr.
        if let open = stderr.lastIndex(of: "("), let close = stderr.lastIndex(of: ")"), open < close,
           let code = Int(stderr[stderr.index(after: open)..<close]) {
            return .failed(code: code)
        }
        return .failed(code: nil)
    }

    private static func focusTerminalTab(ttyPath: String, completion: @escaping Completion) {
        guard AgentTerminalBindingResolver.isTerminalTTYPath(ttyPath) else {
            completion(.launchFailed, "Terminal")
            return
        }
        let arguments = terminalScript.flatMap { ["-e", $0] } + [ttyPath]
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runOsaScript(arguments: arguments, timeout: scriptTimeout)
            Task { @MainActor in completion(outcome(for: result), "Terminal") }
        }
    }

    nonisolated private static func runOsaScript(arguments: [String], timeout: TimeInterval) -> TerminalScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch { return .failed(code: nil) }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            return .failed(code: -1712)
        }
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile().prefix(256), as: UTF8.self)
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile().prefix(4096), as: UTF8.self)
        return parse(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
    }
}
