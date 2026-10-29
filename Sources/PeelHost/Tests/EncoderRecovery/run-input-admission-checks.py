#!/usr/bin/env python3
"""Check actual encoder admission with real CoreMedia buffer lifetimes and a blocked queue."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
HOST = HERE.parents[1] / "Peel-Host/PeelHost"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", type=Path, default=HOST / "WindowStreamer.swift")
args = parser.parse_args()
source = args.source.read_text()
start = source.index("    func invalidateAsync() {", source.index("private final class VideoH264Encoder {"))
end = source.index("    func update(bitRate:", start)
admission = source[start:end]
# A saved old encoder can use the new mailbox declaration while its actual old
# admission methods demonstrate the raw-frame dispatch-retention regression.
current = (HOST / "WindowStreamer.swift").read_text()
mailbox = current[current.index("nonisolated private final class VideoEncoderInputMailbox:"):]
fixture = (HERE / "EncoderInputAdmissionChecks.swift").read_text()
fixture = fixture.replace("// PRODUCTION_ADMISSION_METHODS", admission)
unit = fixture + "\n" + mailbox
with tempfile.TemporaryDirectory(prefix="peel-encoder-admission-") as scratch:
    directory = Path(scratch)
    path = directory / "Checks.swift"
    path.write_text(unit)
    binary = directory / "checks"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                    "-default-isolation", "MainActor", "-strict-concurrency=complete",
                    "-warnings-as-errors", str(path), "-o", str(binary)], check=True, timeout=60)
    result = subprocess.run([str(binary)], timeout=15)
    print(json.dumps({"productionAdmissionSHA256": hashlib.sha256(admission.encode()).hexdigest(),
                      "productionMailboxSHA256": hashlib.sha256(mailbox.encode()).hexdigest(),
                      "fixtureSHA256": hashlib.sha256(unit.encode()).hexdigest(),
                      "substitution": "VideoToolbox encode replaced with deterministic queue stall; real CoreMedia samples",
                      "exitCode": result.returncode}), flush=True)
    raise SystemExit(result.returncode)
