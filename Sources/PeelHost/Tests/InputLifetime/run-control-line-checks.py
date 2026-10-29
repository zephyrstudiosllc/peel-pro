#!/usr/bin/env python3
"""Compile the exact production line-delivery method with controlled socket state."""
from pathlib import Path
import hashlib
import subprocess
import tempfile

here = Path(__file__).resolve().parent
source = (here / "../../Peel-Host/PeelHost/HostNetworkServer.swift").resolve().read_text()
start = "    private func processIncomingData(_ data: Data) {"
end = "    func netServiceDidPublish(_ sender: NetService) {"
if source.count(start) != 1 or source.count(end) != 1:
    raise SystemExit("Production method boundaries changed; review the fixture extraction")
method = source[source.index(start):source.index(end)]
fixture = (here / "ControlLineDeliveryChecks.swift").read_text()
if fixture.count("    // PRODUCTION_METHOD") != 1:
    raise SystemExit("Fixture insertion marker changed")
unit = fixture.replace("    // PRODUCTION_METHOD", method)
with tempfile.TemporaryDirectory(prefix="peel-control-line-checks-") as temporary:
    folder = Path(temporary)
    swift = folder / "ControlLineDeliveryChecks.swift"
    swift.write_text(unit)
    binary = folder / "checks"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                    "-default-isolation", "MainActor", "-strict-concurrency=complete", "-warnings-as-errors",
                    str(swift), "-o", str(binary)], check=True)
    print("Production delivery method SHA256:", hashlib.sha256(method.encode()).hexdigest(), flush=True)
    subprocess.run([str(binary)], check=True)
