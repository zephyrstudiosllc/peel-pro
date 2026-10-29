#!/usr/bin/env python3
"""Compile actual AX identity collection/filter methods with controlled AX replies."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", type=Path, default=ROOT / "Sources/PeelHost/Peel-Host/PeelHost/WindowEnumerator.swift")
args = parser.parse_args()
source = args.source.read_text()
start = source.index("    private static func accessibilityWindowIdsByPID(")
end = source.index("    private static func windowHasVisiblePixels(", start)
methods = source[start:end]
accessibility = (ROOT / "Sources/PeelHost/Peel-Host/PeelHost/AccessibilityManager.swift").read_text()
resolver_start = accessibility.index("    static func cgWindowID(of window:")
resolver_end = accessibility.index("    private func exactAXWindowElement(", resolver_start)
resolver = accessibility[resolver_start:resolver_end]
unit = (ROOT / "Tools/PeelWindowEnumerationTests/WindowIdentityChecks.swift").read_text()
unit += "\nenum WindowEnumerator {\n" + methods + "\n}\n"
unit += "\nenum AccessibilityManager {\n" + resolver + "\n}\n"
with tempfile.TemporaryDirectory(prefix="peel-window-identity-") as scratch:
    directory = Path(scratch)
    path = directory / "Checks.swift"
    path.write_text(unit)
    binary = directory / "checks"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                    "-default-isolation", "MainActor", "-strict-concurrency=complete", "-warnings-as-errors",
                    str(path), "-o", str(binary)], check=True, timeout=60)
    result = subprocess.run([str(binary)], timeout=10)
    print(json.dumps({"productionMethodsSHA256": hashlib.sha256(methods.encode()).hexdigest(),
                      "productionResolverSHA256": hashlib.sha256(resolver.encode()).hexdigest(),
                      "compiledUnitSHA256": hashlib.sha256(unit.encode()).hexdigest(),
                      "exitCode": result.returncode}), flush=True)
    raise SystemExit(result.returncode)
