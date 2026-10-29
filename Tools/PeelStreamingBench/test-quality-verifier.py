#!/usr/bin/env python3
"""Exercise the decode verifier with real captured, mismatched and truncated fixtures."""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile

folder = Path(sys.argv[1]).resolve()
checker = Path(__file__).with_name("check-captured-luma.py").resolve()
capture = json.loads((folder / "capture.json").read_text())
encoded = (folder / "encoded.annexb").read_bytes()
assert len(capture["frames"]) >= 2
receipt = folder / "verifier-regressions.json"
if receipt.exists():
    raise SystemExit("Regression receipt already exists")
results = {}
with tempfile.TemporaryDirectory(prefix="peel-quality-regressions-") as scratch:
    for case in ["matched", "wrong_phase", "missing_last_access_unit"]:
        destination = Path(scratch) / case
        destination.mkdir()
        metadata = json.loads(json.dumps(capture))
        payload = encoded
        if case == "wrong_phase":
            for frame in metadata["frames"]:
                frame["patternPhase"] = (frame["patternPhase"] + 1) % 8
        if case == "missing_last_access_unit":
            payload = payload[:metadata["frames"][-1]["byteOffset"]]
            metadata["encodedBytes"] = len(payload)
        (destination / "capture.json").write_text(json.dumps(metadata))
        (destination / "encoded.annexb").write_bytes(payload)
        completed = subprocess.run([sys.executable, str(checker), str(destination)],
                                   capture_output=True, text=True, timeout=120)
        if case == "missing_last_access_unit":
            assert completed.returncode != 0 and not (destination / "luma-quality-v2.json").exists(), \
                "A missing captured frame must not produce a passing receipt"
            results[case] = {"rejected": True, "reason": completed.stderr.strip()[-500:]}
        else:
            assert completed.returncode == 0, completed.stderr
            result = json.loads((destination / "luma-quality-v2.json").read_text())
            assert result["comparedFrames"] == len(capture["frames"])
            assert result["professionalImageQualityAcceptance"] is None
            results[case] = {"approximatePSNRdB": result["approximateAggregateLumaPSNRdB"]}
assert results["matched"]["approximatePSNRdB"] - results["wrong_phase"]["approximatePSNRdB"] > 10, \
    "A visibly wrong bar position must materially degrade the measured score"
results["checkerSHA256"] = hashlib.sha256(checker.read_bytes()).hexdigest()
results["testSHA256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
results["passed"] = True
receipt.write_text(json.dumps(results, indent=2) + "\n")
print(json.dumps(results))
