#!/usr/bin/env python3
"""Exercise the actual Mac client renderer with deterministic decoder/clock state."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", type=Path, default=ROOT / "Integration/PeelRemoteMacVideoRenderer.swift")
args = parser.parse_args()
source = args.source.read_text()
start = source.index("@MainActor final class PeelRemoteMacVideoRenderer {")
end = source.index("\nstruct PeelRemoteMacVideoLayerView:", start)
renderer = source[start:end]
adapted = renderer.replace("AVSampleBufferDisplayLayer", "FixtureDisplayLayer")
adapted = adapted.replace("ProcessInfo.processInfo.systemUptime", "FixtureClock.now")
unit = (ROOT / "Tools/PeelMacRendererRecoveryTests/MacRendererRecoveryChecks.swift").read_text() + "\n" + adapted
with tempfile.TemporaryDirectory(prefix="peel-mac-renderer-") as scratch:
    directory = Path(scratch)
    path = directory / "Checks.swift"
    path.write_text(unit)
    binary = directory / "checks"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                    "-default-isolation", "MainActor", "-strict-concurrency=complete",
                    str(path), "-o", str(binary)], check=True, timeout=60)
    result = subprocess.run([str(binary)], timeout=15)
    print(json.dumps({"productionRendererSHA256": hashlib.sha256(renderer.encode()).hexdigest(),
                      "compiledUnitSHA256": hashlib.sha256(unit.encode()).hexdigest(),
                      "exitCode": result.returncode}), flush=True)
    raise SystemExit(result.returncode)
