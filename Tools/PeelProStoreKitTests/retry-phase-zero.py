#!/usr/bin/env python3
"""Retry a failed initial phase in its owned simulator without resetting any data."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import uuid

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
spec = importlib.util.spec_from_file_location("runner", HERE / "run-tests.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("original_run")
parser.add_argument("--lifecycle-only", action="store_true")
args = parser.parse_args()
phases = runner.LIFECYCLE_PHASES if args.lifecycle_only else runner.PHASES
original = Path(args.original_run).resolve()
assert original.parent == ROOT / ".build" and original.name.startswith("pro-storekit-")
previous = json.loads((original / "manifest.json").read_text())
assert previous["status"] == "failed"
assert previous["name"].startswith("Peel-Pro-StoreKit-")
assert len(previous["phases"]) <= 1 and all(p["exitCode"] != 0 for p in previous["phases"])
device = previous["simulatorUDID"]
uuid.UUID(device)
output = original / ("retry-" + uuid.uuid4().hex[:8])
output.mkdir()
manifest = {key: previous[key] for key in ["scope", "runtime", "name", "simulatorUDID", "sources"]}
manifest.update({"originalRun": str(original), "mode": "signed-external-lifecycle" if args.lifecycle_only else "purchase-action",
                 "expectedPhases": phases, "status": "running", "phases": [], "commands": [],
                 "retryScope": "No data reset; native initial phase requires no completed marker and empty StoreKit history",
                 "harnessSources": [{"path": str(p), "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
                                    for p in HERE.glob("*.swift")]})


def save():
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


def run(command, log, timeout=300, check=True):
    try:
        with (output / log).open("w") as stream:
            result = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, timeout=timeout)
    except subprocess.TimeoutExpired:
        manifest["commands"].append({"argv": command, "log": log, "exitCode": None, "timeoutSeconds": timeout})
        save()
        raise
    manifest["commands"].append({"argv": command, "log": log, "exitCode": result.returncode})
    save()
    if check and result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}); see {output / log}")
    return result


save()
print(f"Retry evidence {output}; reusing owned simulator {device} without resets", flush=True)
base = ["xcodebuild", "-project", str(original / "PeelProStoreKitValidation.xcodeproj"),
        "-scheme", "PeelProStoreKit", "-destination", f"platform=iOS Simulator,id={device}",
        "-derivedDataPath", str(original / "DerivedData"), "-jobs", "2",
        "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never"]
try:
    spec_path = original / "project.json"
    project_spec = json.loads(spec_path.read_text())
    project_spec["schemes"]["PeelProStoreKit"]["test"]["environmentVariables"]["PEEL_PRO_LIFECYCLE_ONLY"] = "1" if args.lifecycle_only else "0"
    spec_path.write_text(json.dumps(project_spec, indent=2) + "\n")
    run(["xcodegen", "generate", "--spec", str(spec_path), "--project", str(original)], "generate.log")
    run(base + ["build-for-testing"], "build.log", timeout=600)
    run(["xcrun", "simctl", "boot", device], "boot.log", timeout=60, check=False)
    run(["xcrun", "simctl", "bootstatus", device, "-b"], "bootstatus.log", timeout=180)
    for number, phase in enumerate(phases, 1):
        print(f"Running {phase}", flush=True)
        result = run(base + ["test-without-building", f"-only-testing:ProStoreKitTests/ProStoreKitTests/{phase}",
                            "-resultBundlePath", str(output / f"phase{number}.xcresult")],
                     f"phase{number}.log", timeout=240 if number == 1 else 180, check=False)
        content = (output / f"phase{number}.log").read_text()
        executed = (f"PEEL_PRO_STOREKIT_PHASE_{number}_PASS" in content and f"{phase}]' passed" in content
                    and "Executed 1 test, with 0 failures" in content)
        manifest["phases"].append({"phase": phase, "exitCode": result.returncode,
                                   "executedExactlyOnePassingTest": executed})
        run(["xcrun", "simctl", "terminate", device, runner.BUNDLE], f"terminate{number}.log", check=False, timeout=45)
        if result.returncode or not executed:
            raise RuntimeError(f"Phase {number} failed or did not execute exactly one passing named test")
    manifest["status"] = "passed"
except Exception as error:
    manifest["status"] = "failed"
    manifest["error"] = str(error)
    print(str(error), file=sys.stderr, flush=True)
finally:
    try:
        run(["xcrun", "simctl", "shutdown", device], "shutdown.log", timeout=45, check=False)
    except subprocess.TimeoutExpired:
        manifest["cleanupWarning"] = "Owned simulator shutdown timed out; inspect this exact UUID"
    save()
    print(f"Result {manifest['status']}; manifest {output / 'manifest.json'}", flush=True)
sys.exit(0 if manifest["status"] == "passed" else 1)
