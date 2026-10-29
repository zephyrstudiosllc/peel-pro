#!/usr/bin/env python3
"""Compile the unchanged production identity payload with Apple's equivalent SHA256 API.

This isolates pure projection from provider probes and the full CodexBar app test graph.
The bundled helper uses swift-crypto's Crypto import; this macOS fixture uses CryptoKit.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / "Sources/CodexBar/Sources/CodexBarCLI/DashboardPayloads.swift").read_text()
start = source.index("struct DashboardIdentityPayload:")
end = source.index("struct DashboardWindowPayload:", start)
with tempfile.TemporaryDirectory(prefix="peel-account-key-") as temporary:
    directory = Path(temporary)
    payload = directory / "Payload.swift"
    payload.write_text("import Foundation\nimport CryptoKit\n" + source[start:end])
    binary = directory / "checks"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                    "-default-isolation", "MainActor", "-strict-concurrency=complete", "-warnings-as-errors",
                    str(payload), str(root / "Tools/PeelUsageHistoryTests/AccountKeyChecks.swift"),
                    "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
