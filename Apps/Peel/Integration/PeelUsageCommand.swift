import Darwin
import Foundation

final class PeelUsageCancellation: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var cancelled = false

    nonisolated func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    nonisolated var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

enum PeelUsageCommandError: LocalizedError {
    case missingHelper, cancelled, timedOut, outputTooLarge, failed(Int32), emptyOutput

    nonisolated var errorDescription: String? {
        switch self {
        case .missingHelper: "The usage helper is missing. Rebuild Peel with its bundled helper."
        case .cancelled: "Usage refresh was cancelled."
        case .timedOut: "Usage refresh timed out. Your previous readings are still shown."
        case .outputTooLarge: "The usage response was larger than expected."
        case .failed(let code): "The usage helper exited with code \(code). Check the provider connection in Z-CodexBar."
        case .emptyOutput: "The usage helper returned no readings."
        }
    }
}

/// Providers whose token history comes from harness logs on this Mac. Cursor's cost comes from its
/// cookie-authenticated web dashboard, so it is deliberately not representable here: the automatic
/// local-token lane can never broaden into a network or cookie fetch.
nonisolated enum PeelLocalTokenProvider: String, CaseIterable, Sendable, Equatable {
    case claude
    case codex
}

enum PeelUsageCommandMode: Sendable, Equatable {
    case allowances
    case full
    /// One provider's local-log token/model history. `--omit-projects` keeps project names and
    /// paths out of the response; an older helper rejects the flag instead of returning them.
    case localTokens(PeelLocalTokenProvider)
    /// Help text only, used once to learn whether the bundled helper supports `--omit-projects`.
    /// It performs no provider, credential or log work.
    case costCapabilities

    nonisolated var arguments: [String] {
        switch self {
        case .allowances:
            ["dashboard", "--identity", "redacted", "--no-cost", "--timeout", "\(Int(providerTimeout))"]
        case .full:
            ["dashboard", "--identity", "redacted", "--timeout", "\(Int(providerTimeout))"]
        case let .localTokens(provider):
            ["cost", "--format", "json", "--json-only", "--provider", provider.rawValue, "--omit-projects"]
        case .costCapabilities:
            ["cost", "--help"]
        }
    }

    /// The dashboard's own provider budget. The cost command has no such option; its scan is bounded
    /// only by the outer process timeout.
    nonisolated var providerTimeout: TimeInterval {
        switch self {
        case .allowances, .full: 60
        case .localTokens: 175
        case .costCapabilities: 5
        }
    }

    /// The outer bound leaves a small amount of time for process startup and cleanup.
    nonisolated var timeout: TimeInterval { providerTimeout + 5 }
}

/// Bounded stdout plus the helper's exit status. Stderr is drained and discarded, never returned.
nonisolated struct PeelUsageCommandOutput: Sendable, Equatable {
    let data: Data
    let exitStatus: Int32
}

enum PeelUsageCommand {
    /// Runs only the bundled helper with fixed arguments. Reads are bounded and never use a shell.
    nonisolated static func run(
        executable: URL,
        cancellation: PeelUsageCancellation,
        arguments: [String] = ["dashboard", "--identity", "redacted", "--no-cost", "--timeout", "60"],
        timeout: TimeInterval = 65
    ) throws -> Data {
        let output = try execute(
            executable: executable,
            cancellation: cancellation,
            arguments: arguments,
            timeout: timeout)
        guard output.exitStatus == 0 else {
            throw PeelUsageCommandError.failed(output.exitStatus)
        }
        guard !output.data.isEmpty else { throw PeelUsageCommandError.emptyOutput }
        return output.data
    }

    /// Like `run`, but a nonzero exit that still wrote a bounded response is returned with its status.
    /// The cost command reports provider errors as JSON and exits nonzero; the caller decides what that
    /// response means. A nonzero exit with no output still throws `failed`.
    nonisolated static func runCapturingStatus(
        executable: URL,
        cancellation: PeelUsageCancellation,
        mode: PeelUsageCommandMode
    ) throws -> PeelUsageCommandOutput {
        try runCapturingStatus(
            executable: executable,
            cancellation: cancellation,
            arguments: mode.arguments,
            timeout: mode.timeout)
    }

    nonisolated static func runCapturingStatus(
        executable: URL,
        cancellation: PeelUsageCancellation,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> PeelUsageCommandOutput {
        let output = try execute(
            executable: executable,
            cancellation: cancellation,
            arguments: arguments,
            timeout: timeout)
        guard !output.data.isEmpty else {
            if output.exitStatus != 0 { throw PeelUsageCommandError.failed(output.exitStatus) }
            throw PeelUsageCommandError.emptyOutput
        }
        return output
    }

    nonisolated private static func execute(
        executable: URL,
        cancellation: PeelUsageCancellation,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> PeelUsageCommandOutput {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw PeelUsageCommandError.missingHelper
        }
        guard !cancellation.isCancelled else { throw PeelUsageCommandError.cancelled }

        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        // Every usage/settings request is unattended, including a manual refresh. The helper
        // propagates this policy to its children and refuses prompt-capable auth fallbacks.
        var environment = ProcessInfo.processInfo.environment
        environment["CODEXBAR_NO_KEYCHAIN_PROMPTS"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        let outputFD = output.fileHandleForReading.fileDescriptor
        let errorFD = errors.fileHandleForReading.fileDescriptor
        for fd in [outputFD, errorFD] {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                throw CocoaError(.fileReadUnknown)
            }
        }

        defer {
            stop(process)
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForReading.close()
            try? errors.fileHandleForWriting.close()
        }
        try process.run()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.1, timeout)
        var data = Data()
        var discardedErrorBytes = 0
        while true {
            if cancellation.isCancelled { throw PeelUsageCommandError.cancelled }
            if ProcessInfo.processInfo.systemUptime >= deadline { throw PeelUsageCommandError.timedOut }
            try drain(outputFD) { bytes in
                guard data.count + bytes.count <= 2 * 1024 * 1024 else {
                    throw PeelUsageCommandError.outputTooLarge
                }
                data.append(contentsOf: bytes)
            }
            try drain(errorFD) { bytes in
                discardedErrorBytes += bytes.count
                guard discardedErrorBytes <= 256 * 1024 else {
                    throw PeelUsageCommandError.outputTooLarge
                }
            }
            if !process.isRunning {
                // A final drain captures the exit-time tail without waiting on descendants' pipe handles.
                try drain(outputFD) { bytes in
                    guard data.count + bytes.count <= 2 * 1024 * 1024 else {
                        throw PeelUsageCommandError.outputTooLarge
                    }
                    data.append(contentsOf: bytes)
                }
                return PeelUsageCommandOutput(data: data, exitStatus: process.terminationStatus)
            }
            usleep(50_000)
        }
    }

    /// Runs the bounded dashboard request for either a fast allowance poll or a user-requested
    /// full reading. The full mode intentionally omits `--no-cost` so CodexBar can attach its
    /// current local cost values while retaining the same provider timeout and outer bound.
    nonisolated static func run(
        executable: URL,
        cancellation: PeelUsageCancellation,
        mode: PeelUsageCommandMode
    ) throws -> Data {
        try run(
            executable: executable,
            cancellation: cancellation,
            arguments: mode.arguments,
            timeout: mode.timeout)
    }

    nonisolated private static func drain(
        _ fd: Int32, receive: (ArraySlice<UInt8>) throws -> Void
    ) throws {
        var buffer = [UInt8](repeating: 0, count: 8192)
        // Limit each pass so a continuously writing child cannot starve cancellation or its deadline.
        for _ in 0..<32 {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 { try receive(buffer.prefix(count)) }
            else if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK { return }
            else if errno != EINTR { throw CocoaError(.fileReadUnknown) }
        }
    }

    nonisolated private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let grace = ProcessInfo.processInfo.systemUptime + 0.5
        while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { usleep(10_000) }
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
    }
}
