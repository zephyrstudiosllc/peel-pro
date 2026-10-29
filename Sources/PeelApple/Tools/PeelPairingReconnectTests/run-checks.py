#!/usr/bin/env python3
"""Exercise production post-pair state and connection admission with a fake clock."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / "Shared/Client/ClientBrowser"


def method(text, signature):
    start = text.index(signature)
    brace = text.index("{", start)
    depth, end = 1, brace + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


pairing = (BASE / "PairingHandshake.swift").read_text()
connection = (BASE / "Connection.swift").read_text()
lifecycle = (BASE / "LifecycleStreams.swift").read_text()
browser = (BASE / "PeelClientBrowser.swift").read_text()
session = (BASE / "PeelHostSession.swift").read_text()
browser_methods = [
    method(pairing, "    func prepareReconnectAfterPairing("),
    method(browser, "    func session(for host:"),
    method(connection, "    fileprivate func existingSession("),
    method(connection, "    func connectAndRequestWindows(for host:"),
    method(lifecycle, "    func attemptPendingReconnectIfPossible("),
]
session_connection = connection.split("extension PeelHostSession {", 1)[1]
admission = method(session_connection, "    func connectAndRequestWindows(")
# Keep the actual selection, manual-connect and delayed-connect gates. The next
# statement begins transport work; replace only that boundary with a recorder.
admission = admission.split("        didHandleDisconnectForCurrentConnection = false", 1)[0]
admission += "        recordTransportAdmission()\n    }"
production = "extension PeelClientBrowser {\n" + "\n".join(browser_methods) + "\n}\n"
production += "extension PeelHostSession {\n" + method(session, "    func updateHost(") + "\n" + method(session_connection, "    func matchesReconnectTarget(") + "\n" + method(session_connection, "    func deferConnectionWhileHidden(") + "\n" + method(lifecycle.split("extension PeelHostSession {", 1)[1], "    func attemptPendingReconnectIfPossible(") + "\n" + admission + "\n}\n"
adapted = production.replace("DispatchQueue.main", "FixtureScheduler.main").replace("Date()", "FixtureClock.date")
fixture = (ROOT / "Tools/PeelPairingReconnectTests/Checks.swift").read_text()
dependencies, cases = fixture.split("// REGRESSION CASES", 1)

variants = [("current", adapted, True)]
if "--verify-regression" in sys.argv:
    variants += [
        ("browser-only-cooldown", adapted.replace("        targetSession.nextAllowedConnectAt = reconnectAt\n", ""), False),
        ("stale-session-suppression", adapted.replace("        targetSession.suppressAutoReconnect = false\n", ""), False),
        ("hidden-session-admission", adapted.replace("        guard !deferConnectionWhileHidden() else { return }\n", "", 1), False),
    ]
    for name, mutated, _ in variants[1:]:
        assert mutated != adapted, f"Mutation {name} no longer applies; update the runner"
unexpected = False
with tempfile.TemporaryDirectory(prefix="peel-pair-reconnect-") as scratch:
    for name, transitions, should_pass in variants:
        path = Path(scratch) / (name + ".swift")
        binary = Path(scratch) / name
        unit = dependencies + "\n" + transitions + "\n" + cases
        path.write_text(unit)
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", str(path), "-o", str(binary)], check=True, timeout=60)
        result = subprocess.run([str(binary)], timeout=15)
        matched = (result.returncode == 0) == should_pass
        unexpected |= not matched
        print(json.dumps({"variant": name,
                          "productionTransitionsSHA256": hashlib.sha256(production.encode()).hexdigest(),
                          "compiledUnitSHA256": hashlib.sha256(unit.encode()).hexdigest(),
                          "exitCode": result.returncode, "expectedOutcomeMatched": matched}), flush=True)
raise SystemExit(1 if unexpected else 0)
