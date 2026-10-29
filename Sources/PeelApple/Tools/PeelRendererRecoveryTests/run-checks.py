#!/usr/bin/env python3
"""Exercise actual renderer recovery with a deterministic clock/decoder (no UI)."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", type=Path, default=ROOT / "Shared/Client/CompressedVideoRenderer.swift")
args = parser.parse_args()
source = args.source.read_text()
start = source.index("final class CompressedVideoRenderer {")
end = source.index("\n#if canImport(UIKit)\nstruct CompressedVideoLayerView:", start)
renderer = source[start:end]
# Keep production branches/methods intact. Only framework identity and clock are
# substituted so readiness, exact deadlines and missing callbacks are controllable.
adapted = renderer.replace("AVSampleBufferDisplayLayer", "FixtureDisplayLayer")
adapted = adapted.replace("ProcessInfo.processInfo.systemUptime", "FixtureClock.now")
fixture = (ROOT / "Tools/PeelRendererRecoveryTests/RendererRecoveryChecks.swift").read_text()
unit = fixture + "\n" + adapted
with tempfile.TemporaryDirectory(prefix="peel-renderer-recovery-") as scratch:
    directory = Path(scratch)
    path = directory / "Checks.swift"
    path.write_text(unit)
    binary = directory / "checks"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                    "-default-isolation", "MainActor", "-strict-concurrency=complete",
                    str(ROOT / "Shared/All/PeelStreamDiagnosticsMessages.swift"),
                    str(ROOT / "Shared/Client/PeelClientVideoDiagnostics.swift"), str(path),
                    "-o", str(binary)], check=True, timeout=60)
    result = subprocess.run([str(binary)], timeout=15)
    print(json.dumps({"productionRendererSHA256": hashlib.sha256(renderer.encode()).hexdigest(),
                      "compiledUnitSHA256": hashlib.sha256(unit.encode()).hexdigest(),
                      "exitCode": result.returncode}), flush=True)
    raise SystemExit(result.returncode)
