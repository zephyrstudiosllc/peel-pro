#!/usr/bin/env python3
"""Create a fresh fixture simulator, build a hosted XCTest bundle, run three launches."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import uuid

FIXTURES = Path(__file__).resolve().parent
WORKSPACE = FIXTURES.parents[2]
POLICY = WORKSPACE / "Sources/PeelApple/Shared/Client/PeelLegacyPurchasePolicy.swift"
RUN = WORKSPACE / ".build" / ("storekit-xctest-" + uuid.uuid4().hex[:10])
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
NAME = "Peel-StoreKit-Disposable-" + RUN.name.removeprefix("storekit-xctest-")
BUNDLE_ID = "dev.peel.disposable.storekit.host"
RUN.mkdir(parents=True)
manifest = {"name": NAME, "runtime": RUNTIME, "policySHA256": hashlib.sha256(POLICY.read_bytes()).hexdigest(),
            "scope": "Local Xcode StoreKit fixtures only; no App Store sandbox/backend/account acceptance", "phases": []}


def run(command, *, log=None, timeout=300, check=True):
    if log:
        with (RUN / log).open("w") as output:
            result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, timeout=timeout)
    else:
        result = subprocess.run(command, text=True, capture_output=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {command[0:4]}; log={log}; {getattr(result, 'stderr', '')}")
    return result


device = None
try:
    # Never accept a supplied device, clone, existing app, or existing account.
    device = run(["xcrun", "simctl", "create", NAME,
                  "com.apple.CoreSimulator.SimDeviceType.iPhone-17e", RUNTIME]).stdout.strip()
    uuid.UUID(device)
    manifest["simulatorUDID"] = device
    (RUN / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Disposable simulator {device}; evidence {RUN}", flush=True)

    spec = {
        "name": "PeelDisposableStoreKit",
        "options": {"deploymentTarget": {"iOS": "17.0"}},
        "settings": {"base": {"SWIFT_VERSION": "5.0", "CODE_SIGN_IDENTITY": "-", "GENERATE_INFOPLIST_FILE": "YES"}},
        "targets": {
            "StoreKitHost": {"type": "application", "platform": "iOS", "sources": [str(FIXTURES / "HostApp.swift")],
                "settings": {"base": {"PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
                    "INFOPLIST_KEY_UILaunchScreen_Generation": "YES", "TARGETED_DEVICE_FAMILY": "1,2"}}},
            "StoreKitTests": {"type": "bundle.unit-test", "platform": "iOS",
                "dependencies": [{"target": "StoreKitHost"}],
                "sources": [str(FIXTURES / "StoreKitLifecycleTests.swift"), str(POLICY),
                    {"path": str(FIXTURES / "LocalPurchases.storekit"), "buildPhase": "resources"}],
                "settings": {"base": {"PRODUCT_BUNDLE_IDENTIFIER": "dev.peel.disposable.storekit.tests",
                    "ENABLE_TESTING_SEARCH_PATHS": "YES"}}}},
        "schemes": {"StoreKitLifecycle": {
            "build": {"targets": {"StoreKitHost": "all", "StoreKitTests": ["test"]}},
            "run": {"storeKitConfiguration": "LocalPurchases.storekit"},
            "test": {"targets": ["StoreKitTests"], "environmentVariables": {"PEEL_DISPOSABLE_UDID": device},
                     "parallelizable": False, "gatherCoverageData": False}}}
    }
    shutil.copyfile(FIXTURES / "LocalPurchases.storekit", RUN / "LocalPurchases.storekit")
    (RUN / "project.json").write_text(json.dumps(spec, indent=2) + "\n")
    run(["xcodegen", "generate", "--spec", str(RUN / "project.json"), "--project", str(RUN)], log="generate.log")
    base = ["xcodebuild", "-project", str(RUN / "PeelDisposableStoreKit.xcodeproj"), "-scheme", "StoreKitLifecycle",
            "-destination", f"platform=iOS Simulator,id={device}", "-derivedDataPath", str(RUN / "DerivedData"),
            "-jobs", "2", "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never"]
    run(base + ["build-for-testing"], log="build.log")
    phases = ["testPhase1BuyAndPersist", "testPhase2RelaunchRestoreAndRefund", "testPhase3RelaunchRevocationAndRepurchase"]
    for number, phase in enumerate(phases, start=1):
        print(f"Starting phase {number}: {phase}", flush=True)
        result = run(base + ["test-without-building", f"-only-testing:StoreKitTests/StoreKitLifecycleTests/{phase}",
                    "-resultBundlePath", str(RUN / f"phase{number}.xcresult")], log=f"phase{number}.log", timeout=240, check=False)
        manifest["phases"].append({"phase": phase, "result": "passed" if result.returncode == 0 else "failed",
                                   "exitCode": result.returncode})
        (RUN / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        # Explicitly end only this disposable test host between independent runs.
        run(["xcrun", "simctl", "terminate", device, BUNDLE_ID], check=False)
        if result.returncode:
            # Continue only after independently verified refund/cache evidence
            # was persisted. Delivery-test failure remains failure in the result.
            core_passed = (number == 1 and "LOCAL_STOREKIT_PHASE1_PURCHASE_CORE_PASS" in (RUN / "phase1.log").read_text()) or (number == 2 and "LOCAL_STOREKIT_PHASE2_REFUND_CORE_PASS" in (RUN / "phase2.log").read_text())
            if not core_passed:
                break
    manifest["status"] = "passed" if len(manifest["phases"]) == 3 and all(p["result"] == "passed" for p in manifest["phases"]) else "failed"
except Exception as error:
    manifest["status"] = "failed"
    manifest["error"] = str(error)
    print(str(error), file=sys.stderr, flush=True)
finally:
    if device:
        run(["xcrun", "simctl", "shutdown", device], check=False)
    (RUN / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest, indent=2), flush=True)
sys.exit(0 if manifest.get("status") == "passed" else 1)
