import Darwin
import Foundation

// Owner-local process identity for hook events.
//
// The hook socket is 0600 in the user's state directory. When a hook connects,
// the runtime reads the kernel's peer credentials for that connection
// (getpeereid + LOCAL_PEERPID) — never a PID, TTY or terminal claimed inside
// the JSON. It then walks the live process ancestry once to find the agent
// process and the GUI terminal that hosts it, recording PID + kernel birth
// time so a later activation can prove the same processes still exist.
// Nothing here leaves this Mac; paired Macs only ever see an opaque token and
// a capability (exact / app only / unavailable).

nonisolated struct AgentProcessStamp: Hashable, Sendable {
    var pid: Int32
    var startSeconds: UInt64
    var startMicroseconds: UInt64
}

nonisolated struct AgentProcessRecord: Equatable, Sendable {
    var stamp: AgentProcessStamp
    var parentPID: Int32
    var uid: UInt32
    /// Controlling terminal device, nil when the process has none.
    var ttyDevice: UInt32?
    /// Executable name (kernel `p_comm`), without a login-shell dash.
    var name: String
    var executablePath: String?
}

nonisolated protocol AgentProcessInspecting: Sendable {
    func record(pid: Int32) -> AgentProcessRecord?
    func ttyPath(device: UInt32) -> String?
}

nonisolated struct DarwinAgentProcessInspector: AgentProcessInspecting {
    func record(pid: Int32) -> AgentProcessRecord? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) >= size,
              info.pbi_status != UInt32(SZOMB) else { return nil }
        let name = withUnsafeBytes(of: info.pbi_comm) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path = pathLength > 0 ? String(cString: pathBuffer) : nil
        // NODEV is (dev_t)-1; e_tdev is 0 or NODEV without a controlling tty.
        let tty = info.e_tdev == UInt32.max || info.e_tdev == 0 ? nil : info.e_tdev
        return AgentProcessRecord(
            stamp: AgentProcessStamp(pid: pid, startSeconds: info.pbi_start_tvsec,
                                     startMicroseconds: info.pbi_start_tvusec),
            parentPID: Int32(bitPattern: info.pbi_ppid),
            uid: info.pbi_uid,
            ttyDevice: tty,
            name: name.hasPrefix("-") ? String(name.dropFirst()) : name,
            executablePath: path)
    }

    func ttyPath(device: UInt32) -> String? {
        guard let name = devname(dev_t(bitPattern: device), S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }
}

/// Kernel credentials of the process that connected to the hook socket.
nonisolated struct AgentHookPeer: Equatable, Sendable {
    var pid: Int32
    var uid: UInt32

    /// Reads credentials from an accepted Unix socket. Returns nil if either
    /// kernel query fails; the event is then treated as unbound (legacy).
    static func read(from descriptor: Int32) -> AgentHookPeer? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(descriptor, &uid, &gid) == 0 else { return nil }
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else { return nil }
        return AgentHookPeer(pid: pid, uid: uid)
    }
}

nonisolated enum AgentTerminalHost: Equatable, Sendable {
    /// Apple's Terminal.app: tabs expose their TTY through its scripting
    /// dictionary, so an existing tab can be selected exactly.
    case appleTerminal(app: AgentProcessStamp)
    /// Another GUI app (iTerm, an editor, …): only the app can be raised.
    case application(app: AgentProcessStamp, name: String)

    var app: AgentProcessStamp {
        switch self {
        case .appleTerminal(let app), .application(let app, _): app
        }
    }

    var label: String {
        switch self {
        case .appleTerminal: "Terminal"
        case .application(_, let name): name
        }
    }
}

nonisolated struct AgentTerminalBinding: Equatable, Sendable {
    var agent: AgentProcessStamp
    var agentExecutablePath: String
    var ttyDevice: UInt32
    var ttyPath: String
    var host: AgentTerminalHost
    var hostExecutablePath: String
    /// Every process between the agent and its host app (agent's parent
    /// first). Revalidation requires this exact live parent chain.
    var chain: [AgentProcessStamp]
    var boundAt: Date
}

nonisolated enum AgentTerminalUnavailableReason: String, Equatable, Sendable {
    case headless          // the agent itself has no controlling terminal (`claude -p`, background)
    case multiplexer       // tmux/screen/zellij: no stable pane selector
    case remoteShell       // reached through sshd; the GUI is elsewhere
    case noTerminalApp     // no GUI application ancestor
    case foreignUser       // connection or process from another user
    case senderExited      // hook exited before its ancestry could be read
    case unverified        // an unknown wrapper/launcher sits between hook and agent
    case unrecognizedAgent // no supported agent executable in the hook's ancestry
    case superseded        // a newer session now owns the same agent process
}

nonisolated enum AgentTerminalBindingResult: Equatable, Sendable {
    case bound(AgentTerminalBinding)
    case unavailable(AgentTerminalUnavailableReason)
}

nonisolated enum AgentTerminalRevalidation: Equatable, Sendable {
    case valid
    case agentEnded
    case terminalChanged
}

nonisolated enum AgentTerminalBindingResolver {
    static let maximumDepth = 64
    /// Hooks run as `sh -c <command>` children of the agent; only shells may
    /// sit between the hook sender and the agent.
    static let maximumHookHops = 4
    static let shellNames: Set<String> = ["sh", "bash", "zsh", "dash"]
    static let multiplexerNames: Set<String> = ["tmux", "screen", "zellij", "abduco", "dtach", "byobu"]
    static let remoteShellNames: Set<String> = ["sshd", "sshd-session", "mosh-server"]
    static let appleTerminalPaths: Set<String> = [
        "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
        "/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
    ]

    /// Supported agent executables, by kernel executable path (no argv/env).
    /// Native Claude Code installs as ~/.local/share/claude/versions/<version>
    /// (the ~/.local/bin/claude symlink resolves there).
    static func isRecognizedAgent(_ record: AgentProcessRecord) -> Bool {
        guard let path = record.executablePath else { return false }
        let parts = path.split(separator: "/")
        guard parts.count >= 6,
              parts[parts.count - 2] == "versions", parts[parts.count - 3] == "claude",
              parts[parts.count - 4] == "share", parts[parts.count - 5] == ".local" else { return false }
        let version = parts[parts.count - 1]
        return !version.isEmpty && version.first?.isNumber == true
            && version.allSatisfy { $0.isNumber || $0.isLetter || $0 == "." || $0 == "-" || $0 == "+" }
    }

    /// Resolves the hook sender's agent process and hosting terminal from
    /// live kernel data captured while the hook connection is open. The hook
    /// child normally has NO controlling terminal; the agent's own TTY is used.
    static func resolve(peer: AgentHookPeer, expectedUID: UInt32,
                        inspector: some AgentProcessInspecting, now: Date = .now) -> AgentTerminalBindingResult {
        guard peer.uid == expectedUID else { return .unavailable(.foreignUser) }
        guard let sender = inspector.record(pid: peer.pid) else { return .unavailable(.senderExited) }
        guard sender.uid == expectedUID else { return .unavailable(.foreignUser) }

        // 1. sender → (shells) → recognized agent.
        var cursor = sender
        var agent: AgentProcessRecord?
        for _ in 0..<maximumHookHops {
            guard cursor.parentPID > 1, cursor.parentPID != cursor.stamp.pid,
                  let parent = inspector.record(pid: cursor.parentPID) else { return .unavailable(.senderExited) }
            if parent.uid == expectedUID, isRecognizedAgent(parent) { agent = parent; break }
            guard parent.uid == expectedUID, shellNames.contains(parent.name.lowercased()) else {
                return .unavailable(.unverified)
            }
            cursor = parent
        }
        guard let agent, let agentPath = agent.executablePath else { return .unavailable(.unrecognizedAgent) }
        guard let tty = agent.ttyDevice else { return .unavailable(.headless) }

        // 2. agent → … → GUI host app, recording the exact chain.
        var chain: [AgentProcessRecord] = []
        cursor = agent
        var host: AgentProcessRecord?
        for _ in 0..<maximumDepth {
            guard cursor.parentPID > 1, cursor.parentPID != cursor.stamp.pid,
                  let parent = inspector.record(pid: cursor.parentPID) else { break }
            let name = parent.name.lowercased()
            if multiplexerNames.contains(name) || name.hasPrefix("tmux") { return .unavailable(.multiplexer) }
            if remoteShellNames.contains(name) { return .unavailable(.remoteShell) }
            if parent.uid == expectedUID, parent.executablePath?.contains(".app/Contents/MacOS/") == true {
                host = parent
                break
            }
            chain.append(parent)
            cursor = parent
        }
        guard let host, let hostPath = host.executablePath else { return .unavailable(.noTerminalApp) }
        guard let ttyPath = inspector.ttyPath(device: tty), isTerminalTTYPath(ttyPath) else {
            return .unavailable(.unverified)
        }
        let kind: AgentTerminalHost = appleTerminalPaths.contains(hostPath)
            ? .appleTerminal(app: host.stamp)
            : .application(app: host.stamp, name: applicationName(fromExecutablePath: hostPath))
        return .bound(AgentTerminalBinding(agent: agent.stamp, agentExecutablePath: agentPath, ttyDevice: tty,
                                           ttyPath: ttyPath, host: kind, hostExecutablePath: hostPath,
                                           chain: chain.map(\.stamp), boundAt: now))
    }

    /// Re-proves, immediately before acting, the same live agent (birth time,
    /// executable, TTY), the same parent chain, and the same host app.
    static func revalidate(_ binding: AgentTerminalBinding,
                           inspector: some AgentProcessInspecting) -> AgentTerminalRevalidation {
        guard let agent = inspector.record(pid: binding.agent.pid), agent.stamp == binding.agent,
              agent.executablePath == binding.agentExecutablePath,
              agent.ttyDevice == binding.ttyDevice else { return .agentEnded }
        var childParent = agent.parentPID
        for stamp in binding.chain {
            guard childParent == stamp.pid, let record = inspector.record(pid: stamp.pid),
                  record.stamp == stamp else { return .terminalChanged }
            childParent = record.parentPID
        }
        guard childParent == binding.host.app.pid,
              let app = inspector.record(pid: binding.host.app.pid), app.stamp == binding.host.app,
              app.executablePath == binding.hostExecutablePath else { return .terminalChanged }
        return .valid
    }

    static func isTerminalTTYPath(_ path: String) -> Bool {
        let prefix = "/dev/ttys"
        guard path.hasPrefix(prefix) else { return false }
        let digits = path.dropFirst(prefix.count)
        return (1...4).contains(digits.count) && digits.allSatisfy(\.isASCII) && digits.allSatisfy(\.isNumber)
    }

    static func applicationName(fromExecutablePath path: String) -> String {
        guard let range = path.range(of: ".app/Contents/MacOS/") else { return "App" }
        let bundlePath = path[..<range.lowerBound]
        let name = bundlePath.split(separator: "/").last.map(String.init) ?? "App"
        return String(name.prefix(32))
    }

    /// Only the newest session bound to a given agent process keeps its
    /// binding; older sessions from the same process (e.g. before /clear)
    /// would focus a tab that now shows a different session.
    static func currentBindings(_ results: [String: AgentTerminalBindingResult])
        -> [String: AgentTerminalBindingResult]
    {
        var newest: [AgentProcessStamp: (String, Date)] = [:]
        for (key, result) in results {
            guard case .bound(let binding) = result else { continue }
            if let existing = newest[binding.agent], existing.1 > binding.boundAt
                || (existing.1 == binding.boundAt && existing.0 < key) { continue }
            newest[binding.agent] = (key, binding.boundAt)
        }
        var output = results
        for (key, result) in results {
            guard case .bound(let binding) = result, newest[binding.agent]?.0 != key else { continue }
            output[key] = .unavailable(.superseded)
        }
        return output
    }
}

/// What an open action can honestly do for one local session.
enum AgentActivationClassifier {
    static func support(for agent: AgentSession,
                        binding: AgentTerminalBindingResult?) -> (AgentActivationSupport, reason: String?) {
        if case .bound(let terminal) = binding {
            switch terminal.host {
            case .appleTerminal: return (.exactSession, nil)
            case .application:
                // A session URL, if any, is more precise than raising an app.
                if let url = AgentOpenRouting.allowedDestination(for: agent),
                   AgentOpenRouting.support(forDestination: url) == .exactSession {
                    return (.exactSession, nil)
                }
                return (.applicationOnly, "terminal_app_only")
            }
        }
        if let url = AgentOpenRouting.allowedDestination(for: agent) {
            let support = AgentOpenRouting.support(forDestination: url)
            return (support, support == .applicationOnly ? "app_only_url" : nil)
        }
        if case .unavailable(let reason) = binding { return (.unavailable, reason.rawValue) }
        return (.unavailable, "no_destination")
    }
}
