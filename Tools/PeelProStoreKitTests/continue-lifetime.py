#!/usr/bin/env python3
"""Validate lifetime independently after the recorded annual fixture failure, without resetting data."""
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
args = parser.parse_args()
phases = runner.LIFETIME_PHASES
original = Path(args.original_run).resolve()
assert original.is_relative_to(ROOT / ".build")
previous = json.loads((original / "manifest.json").read_text())
assert previous["status"] == "failed"
assert previous["name"].startswith("Peel-Pro-StoreKit-")
assert previous["mode"] == "signed-external-lifecycle"
assert len(previous["phases"]) == 3
assert all(p["exitCode"] == 0 and p["executedExactlyOnePassingTest"] for p in previous["phases"][:2])
assert previous["phases"][2]["exitCode"] != 0
project_root = Path(previous["originalRun"])
assert project_root.parent == ROOT / ".build" and project_root.name.startswith("pro-storekit-")
device = previous["simulatorUDID"]
uuid.UUID(device)
output = original / ("lifetime-" + uuid.uuid4().hex[:8])
output.mkdir()
manifest = {key: previous[key] for key in ["scope", "runtime", "name", "simulatorUDID", "sources"]}
manifest.update({"originalRun": str(original), "mode": "signed-lifetime-lifecycle",
                 "expectedPhases": phases, "status": "running", "phases": [], "commands": [],
                 "retryScope": "No data reset; independent lifetime begins at marker2 and requires verified refunded monthly plus actual free store/runtime baseline; annual failure remains failed",
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
base = ["xcodebuild", "-project", str(project_root / "PeelProStoreKitValidation.xcodeproj"),
        "-scheme", "PeelProStoreKit", "-destination", f"platform=iOS Simulator,id={device}",
        "-derivedDataPath", str(project_root / "DerivedData"), "-jobs", "2",
        "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never"]
try:
    spec_path = project_root / "project.json"
    project_spec = json.loads(spec_path.read_text())
    project_spec["schemes"]["PeelProStoreKit"]["test"]["environmentVariables"]["PEEL_PRO_LIFECYCLE_ONLY"] = "1"
    spec_path.write_text(json.dumps(project_spec, indent=2) + "\n")
    run(["xcodegen", "generate", "--spec", str(spec_path), "--project", str(project_root)], "generate.log")
    run(base + ["build-for-testing"], "build.log", timeout=600)
    run(["xcrun", "simctl", "boot", device], "boot.log", timeout=60, check=False)
    run(["xcrun", "simctl", "bootstatus", device, "-b"], "bootstatus.log", timeout=180)
    for number, phase in enumerate(phases, 4):
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
