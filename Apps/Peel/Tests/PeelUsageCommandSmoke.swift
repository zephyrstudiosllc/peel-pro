import Foundation

@main
enum PeelUsageCommandSmoke {
    static func main() throws {
        precondition(PeelUsageCommandMode.allowances.arguments.contains("--no-cost"))
        precondition(!PeelUsageCommandMode.full.arguments.contains("--no-cost"))
        precondition(PeelUsageCommandMode.allowances.arguments.contains("--timeout"))
        precondition(PeelUsageCommandMode.full.arguments.contains("--timeout"))
        precondition(PeelUsageCommandMode.allowances.providerTimeout == 60)
        precondition(PeelUsageCommandMode.full.providerTimeout == 60)
        precondition(PeelUsageCommandMode.allowances.timeout == 65)
        precondition(PeelUsageCommandMode.full.timeout == 65)

        // The local-token lane is one provider per call, path-free, bounded, and can never name Cursor.
        precondition(PeelLocalTokenProvider.allCases.map(\.rawValue) == ["claude", "codex"])
        for provider in PeelLocalTokenProvider.allCases {
            let mode = PeelUsageCommandMode.localTokens(provider)
            precondition(mode.arguments == [
                "cost", "--format", "json", "--json-only", "--provider", provider.rawValue, "--omit-projects",
            ])
            precondition(!mode.arguments.contains("--refresh"))
            precondition(mode.timeout == 180)
        }
        precondition(PeelUsageCommandMode.costCapabilities.arguments == ["cost", "--help"])
        precondition(PeelUsageCommandMode.costCapabilities.timeout == 10)

        let data = try PeelUsageCommand.run(
            executable: URL(fileURLWithPath: "/usr/bin/printf"),
            cancellation: PeelUsageCancellation(), arguments: ["%s", "{\"ok\":true}"], timeout: 2)
        precondition(String(decoding: data, as: UTF8.self) == "{\"ok\":true}")

        let promptPolicy = try PeelUsageCommand.run(
            executable: URL(fileURLWithPath: "/usr/bin/printenv"),
            cancellation: PeelUsageCancellation(), arguments: ["CODEXBAR_NO_KEYCHAIN_PROMPTS"], timeout: 2)
        precondition(String(decoding: promptPolicy, as: UTF8.self) == "1\n")
        let childPromptPolicy = try PeelUsageCommand.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            cancellation: PeelUsageCancellation(),
            arguments: ["-c", "/usr/bin/printenv CODEXBAR_NO_KEYCHAIN_PROMPTS"], timeout: 2)
        precondition(String(decoding: childPromptPolicy, as: UTF8.self) == "1\n")

        do {
            _ = try PeelUsageCommand.run(executable: URL(fileURLWithPath: "/usr/bin/false"),
                                         cancellation: PeelUsageCancellation(), arguments: [])
            fatalError("Nonzero exit accepted")
        } catch PeelUsageCommandError.failed(let code) { precondition(code != 0) }

        do {
            _ = try PeelUsageCommand.run(executable: URL(fileURLWithPath: "/usr/bin/true"),
                                         cancellation: PeelUsageCancellation(), arguments: [])
            fatalError("Empty response accepted")
        } catch PeelUsageCommandError.emptyOutput {}

        // A nonzero exit that still wrote JSON is returned with its status for the caller to interpret;
        // stderr stays discarded.
        let failedWithJSON = try PeelUsageCommand.runCapturingStatus(
            executable: URL(fileURLWithPath: "/bin/sh"),
            cancellation: PeelUsageCancellation(),
            arguments: ["-c", "printf '[{\"provider\":\"claude\"}]'; printf 'secret' >&2; exit 3"],
            timeout: 2)
        precondition(failedWithJSON.exitStatus == 3)
        precondition(String(decoding: failedWithJSON.data, as: UTF8.self) == "[{\"provider\":\"claude\"}]")
        do {
            _ = try PeelUsageCommand.runCapturingStatus(
                executable: URL(fileURLWithPath: "/usr/bin/false"),
                cancellation: PeelUsageCancellation(), arguments: [], timeout: 2)
            fatalError("Nonzero exit without output accepted")
        } catch PeelUsageCommandError.failed(let code) { precondition(code != 0) }
        let capturedPolicy = try PeelUsageCommand.runCapturingStatus(
            executable: URL(fileURLWithPath: "/usr/bin/printenv"),
            cancellation: PeelUsageCancellation(), arguments: ["CODEXBAR_NO_KEYCHAIN_PROMPTS"], timeout: 2)
        precondition(String(decoding: capturedPolicy.data, as: UTF8.self) == "1\n")
        do {
            _ = try PeelUsageCommand.runCapturingStatus(
                executable: URL(fileURLWithPath: "/usr/bin/python3"), cancellation: PeelUsageCancellation(),
                arguments: ["-c", "import os; os.write(1, b'x' * (3 * 1024 * 1024))"], timeout: 5)
            fatalError("Output bound not enforced for status capture")
        } catch PeelUsageCommandError.outputTooLarge {}

        let start = Date.now
        do {
            _ = try PeelUsageCommand.run(executable: URL(fileURLWithPath: "/bin/sleep"),
                                         cancellation: PeelUsageCancellation(), arguments: ["5"], timeout: 0.1)
            fatalError("Timeout not enforced")
        } catch PeelUsageCommandError.timedOut { precondition(Date.now.timeIntervalSince(start) < 2) }

        let token = PeelUsageCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { token.cancel() }
        do {
            _ = try PeelUsageCommand.run(executable: URL(fileURLWithPath: "/bin/sleep"),
                                         cancellation: token, arguments: ["5"], timeout: 3)
            fatalError("Cancellation ignored")
        } catch PeelUsageCommandError.cancelled {}

        for fd in [1, 2] {
            do {
                _ = try PeelUsageCommand.run(
                    executable: URL(fileURLWithPath: "/usr/bin/python3"), cancellation: PeelUsageCancellation(),
                    arguments: ["-c", "import os; os.write(\(fd), b'x' * (3 * 1024 * 1024))"], timeout: 5)
                fatalError("Output bound not enforced for descriptor \(fd)")
            } catch PeelUsageCommandError.outputTooLarge {}
        }
        print("PeelUsageCommandSmoke passed: silent policy and child inheritance, output, exit, empty, timeout, cancellation, both pipe limits, local-token modes and status capture")
    }
}
