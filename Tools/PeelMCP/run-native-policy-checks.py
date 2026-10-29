#!/usr/bin/env python3
"""Compile the actual request/policy source with focused admission assertions."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[2]
source = (root / "Sources/PeelHost/Peel-Host/PeelHost/WindowStreamer.swift").read_text()
shared = (root / "Sources/PeelApple/Shared/All/PeelSharedMessages.swift").read_text()
unit = "import Foundation\n"
unit += source[source.index("enum PeelStreamingSettings {"):source.index("private enum PeelPixelBudget")]
start = shared.index("nonisolated struct PeelReceiverDisplayCapabilities:")
end = shared.index("/// Host -> Client", start) if "/// Host -> Client" in shared[start:] else -1
# Keep the exact declarations up through the dedicated-socket hello.
hello_start = shared.index("struct VideoStreamHelloMessage:", start)
hello_end = shared.index("\n}\n", hello_start) + 3
unit += shared[start:hello_end]
unit += "\nenum PeelProtocol { static let currentProtocolVersion = 2; static let minimumSupportedProtocolVersion = 2; static let capabilities: Set<String> = [] }\n"
output = root / ".build/NativePolicyChecks"
output.mkdir(parents=True, exist_ok=True)
path = output / "NativePolicyProduction.swift"
path.write_text(unit)
subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
    "-default-isolation", "MainActor", "-strict-concurrency=complete", "-warnings-as-errors",
    str(path), str(root / "Tools/PeelMCP/NativePolicyChecks.swift"),
    "-o", str(output / "native-policy-checks")], check=True)
subprocess.run([str(output / "native-policy-checks")], check=True)
