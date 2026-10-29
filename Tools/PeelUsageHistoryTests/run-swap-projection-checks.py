#!/usr/bin/env python3
"""Exercise real compiled Core projection into the unchanged dashboard account builder.

Requires a built Release libCodexBarCore.a. Extracts production account/identity
payloads and the actual makeClaudeSwapAccount and display-redaction methods.
Only unrelated window and pace formatting are stubbed; no provider is contacted.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
component = root / "Sources/CodexBar"
products = component / ".build/out/Products/Release"
modulemap = component / ".build/out/Intermediates.noindex/GeneratedModuleMaps/CQuickJS.modulemap"
for prerequisite in [products / "libCodexBarCore.a", modulemap]:
    if not prerequisite.is_file():
        raise SystemExit(
            f"Missing prerequisite: {prerequisite}\n"
            "Build the Core library with this checkout's macOS Swift toolchain first:\n"
            "swift build --package-path Sources/CodexBar -c release -j 2 --product CodexBarCore\n"
            "The CLI-only build-host.sh build need not produce this library."
        )

def block(text, marker):
    start = text.index(marker)
    brace = text.index("{", start)
    depth = 1
    cursor = brace + 1
    while depth:
        if text[cursor] == "{": depth += 1
        if text[cursor] == "}": depth -= 1
        cursor += 1
    return text[start:cursor]

payloads = (component / "Sources/CodexBarCLI/DashboardPayloads.swift").read_text()
builder = (component / "Sources/CodexBarCLI/DashboardSnapshotBuilder.swift").read_text()
parts = ["import Foundation\nimport CryptoKit\nimport CodexBarCore\n"]
for name in ["enum DashboardIdentityMode:", "struct DashboardAccountPayload:",
             "struct DashboardIdentityPayload:", "struct DashboardWindowPayload:"]:
    parts.append(block(payloads, name))
parts.append("""
struct ProviderPacePayload: Encodable {}
enum CLIRenderer {
    static func providerPacePayload(provider: UsageProvider, snapshot: UsageSnapshot,
        weeklyWorkDays: Int?, now: Date) -> ProviderPacePayload? { nil }
}
enum DashboardSnapshotBuilder {
    static func makeWindows(provider: UsageProvider?, metadata: ProviderMetadata?,
        usage: UsageSnapshot?) -> [DashboardWindowPayload] { [] }
    static func project(_ account: ProviderAccountUsageSnapshot, now: Date) -> DashboardAccountPayload {
        makeClaudeSwapAccount(account, identityMode: .redacted, weeklyWorkDays: nil, generatedAt: now)
    }
""")
for name in ["makeClaudeSwapAccount", "claudeSwapDashboardLabel", "dashboardEmail", "redactEmailShapedText",
             "emailTokenStart", "emailTokenEnd", "isEmailBoundary"]:
    parts.append(block(builder, "private static func " + name + "("))
parts.append("}")
parts.append("""
@main struct Check {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func project(_ organization: String, email: String = "shared@example.test") -> (DashboardAccountPayload, ProviderAccountUsageSnapshot) {
            let row = ClaudeSwapAccountRow(number: 1, email: email, organizationName: organization,
                isActive: true, usageStatus: .ok, fiveHour: .init(usedPercent: 10, resetsAt: nil), sevenDay: nil)
            let account = ClaudeSwapAccountProjection.accountSnapshots(
                from: .init(activeAccountNumber: 1, accounts: [row]), now: now)[0]
            return (DashboardSnapshotBuilder.project(account, now: now), account)
        }
        let first = project("  Organization A  ")
        let second = project("Organization B")
        let normalized = project("Organization A")
        let otherEmail = project("Organization A", email: "other@example.test")
        precondition(first.0.id == second.0.id)
        precondition(first.0.identity?.accountKey != nil)
        precondition(first.0.identity?.accountKey != second.0.identity?.accountKey)
        precondition(first.0.identity?.accountKey == normalized.0.identity?.accountKey)
        precondition(first.0.identity?.accountKey != otherEmail.0.identity?.accountKey)
        precondition(first.0.identity?.accountEmail == "redacted@example.test")
        precondition(first.1.accountOrganization == "Organization A")
        precondition(first.1.snapshot?.identity?.accountOrganization == nil)
        precondition(first.1.snapshot?.identity?.accountID == "claude-swap:1")
        print("Real Core projection to dashboard checks passed: organization/email isolation, normalization, redaction and unchanged source/cloud identity")
    }
}
""")
with tempfile.TemporaryDirectory(prefix="peel-swap-projection-") as directory:
    source = Path(directory) / "Check.swift"
    source.write_text("\n\n".join(parts))
    binary = Path(directory) / "checks"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-I", str(products), "-L", str(products),
                    "-Xcc", "-fmodule-map-file=" + str(modulemap),
                    "-lCodexBarCore", str(source), "-o", str(binary)], check=True)
    env = dict(os.environ, CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS="1", CODEXBAR_TEST_CODEX_FILE_ISOLATION="1",
               CODEXBAR_TEST_SESSION_FILE_ISOLATION="1")
    subprocess.run([str(binary)], check=True, env=env)
