#!/usr/bin/env python3
"""Independently reject zero-test success and incomplete native StoreKit runs."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

directory = Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location("runner", Path(__file__).with_name("run-tests.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
manifest = json.loads((directory / "manifest.json").read_text())
mode = manifest.get("mode", "purchase-action")
expected = runner.LIFETIME_PHASES if mode == "signed-lifetime-lifecycle" else (runner.LIFECYCLE_PHASES if mode == "signed-external-lifecycle" else runner.PHASES)
first_marker = 4 if mode == "signed-lifetime-lifecycle" else 1
checks = []
for number, name in enumerate(expected, first_marker):
    path = directory / f"phase{number}.log"
    content = path.read_text() if path.exists() else ""
    matching = [phase for phase in manifest.get("phases", []) if phase.get("phase") == name]
    checks.append({"phase": name, "logSHA256": hashlib.sha256(content.encode()).hexdigest(),
                   "completedMarker": f"PEEL_PRO_STOREKIT_PHASE_{number}_PASS" in content,
                   "namedTestPassed": f"{name}]' passed" in content,
                   "executedExactlyOneTestWithoutFailure": "Executed 1 test, with 0 failures" in content,
                   "successfulRecordedExit": len(matching) == 1 and matching[0]["exitCode"] == 0})
passed = (manifest.get("status") == "passed" and len(manifest.get("phases", [])) == len(expected)
          and all(all(value for key, value in check.items() if key not in {"phase", "logSHA256"}) for check in checks))
audit = {"status": "passed" if passed else "failed", "scope": "Independent named-test/count/completion/exit audit",
         "run": str(directory), "mode": manifest.get("mode", "purchase-action"), "purchaseActionCompletionValidated": mode == "purchase-action" and passed, "checks": checks}
(directory / "execution-audit.json").write_text(json.dumps(audit, indent=2) + "\n")
print(json.dumps(audit, indent=2))
sys.exit(0 if passed else 1)
