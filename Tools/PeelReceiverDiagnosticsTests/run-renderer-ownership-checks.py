#!/usr/bin/env python3
"""Check actual container methods with real layers and bounded UIKit stand-ins."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", type=Path,
                    default=ROOT / "Sources/PeelApple/Shared/Client/CompressedVideoRenderer.swift")
parser.add_argument("--ownership-only", action="store_true", help="Run preexisting ownership API regression against old source")
args = parser.parse_args()
source = args.source.read_text()
start = source.index("final class VideoLayerContainerView: UIView {")
end = source.index("\n#endif\n", source.index("    private func applyLayerLayout()", start))
container = source[start:end]
checks = (HERE / "RendererOwnershipChecks.swift").read_text()
if args.ownership_only:
    begin = checks.index("        // SCREEN_CHECKS_BEGIN")
    end = checks.index("        // SCREEN_CHECKS_END", begin) + len("        // SCREEN_CHECKS_END")
    checks = checks[:begin] + checks[end:]
unit = checks + "\n" + container
with tempfile.TemporaryDirectory(prefix="peel-renderer-ownership-") as scratch:
    directory = Path(scratch)
    combined = directory / "RendererOwnershipChecks.swift"
    combined.write_text(unit)
    binary = directory / "checks"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                    "-default-isolation", "MainActor", "-strict-concurrency=complete", "-warnings-as-errors",
                    str(combined), "-o", str(binary)], check=True, timeout=60)
    result = subprocess.run([str(binary)], timeout=10)
    print(json.dumps({"productionContainerSHA256": hashlib.sha256(container.encode()).hexdigest(),
                      "compiledUnitSHA256": hashlib.sha256(unit.encode()).hexdigest(),
                      "ownershipOnly": args.ownership_only, "exitCode": result.returncode}), flush=True)
    raise SystemExit(result.returncode)
