#!/usr/bin/env python3
"""Compile the production home-computer projection and its browser adapter.

Unit 1 compiles the projection block from PeelDirectEndpoint.swift verbatim
with label-only cases. Unit 2 compiles the same block plus the real adapter,
readiness, session-ownership and Disconnect methods and host identity
properties against minimal browser/session stand-ins. Source checks confirm
the iPad/iPhone home uses the projection and owned readiness, and that the
adapter never writes to discovery.
"""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / "Shared/Client/ClientBrowser"
HOME = ROOT / "Peel-iPad/iPadContentView.swift"
HERE = Path(__file__).resolve().parent


def block(text, signature):
    start = text.index(signature)
    brace = text.index("{", start)
    depth, end = 1, brace + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


endpoint = (BASE / "PeelDirectEndpoint.swift").read_text()
connection = (BASE / "Connection.swift").read_text()
browser_source = (BASE / "PeelClientBrowser.swift").read_text()
host_key = (BASE / "PeelHostKey.swift").read_text()

begin, end = "// BEGIN PeelHomeComputerProjection", "// END PeelHomeComputerProjection"
projection = endpoint[endpoint.index(begin):endpoint.index(end) + len(end)]
adapter = block(endpoint, "    func homeComputerProjection()")

assert not re.search(r"\bhosts\s*(\.append|\.insert|=[^=])", adapter), \
    "Projection adapter must not add saved-address sessions to discovery"
assert "pairedPeer(for: host)?.id" in adapter and "session.directPairingID" in adapter, \
    "Adapter must bind discovered hosts and sessions to their saved pairing identity"
assert "owningSession(for: host)" in adapter and "isConnected(to:" not in adapter, \
    "Adapter readiness must come from the owning session, not the global name fallback"

home = HOME.read_text()
assert "browser.homeComputerProjection()" in home, "Home must use the production projection"
assert "showsComputerList(hasConnectedSession:" in home, "Home list gate must use the projection"
assert "if browser.hosts.isEmpty" not in home, "Home must not hide direct sessions behind empty discovery"
assert "browser.hiddenSavedPairedMacs" not in home, "Home saved list must come from the projection"
assert "browser.isConnected(to:" not in home, "Home rows must use owned readiness"

browser_methods = "\n".join([
    block(connection, "    func isConnected(to host: PeelHostInfo)"),
    block(connection, "    fileprivate func existingSession(matching host: PeelHostInfo)"),
    block(connection, "    func owningSession(for host: PeelHostInfo)"),
    block(connection, "    func hasOwnedReadyConnection(to host: PeelHostInfo)"),
    block(connection, "    func disconnect(from host: PeelHostInfo"),
])
host_properties = "\n".join([
    block(browser_source, "    var isDirectEndpoint: Bool {"),
    block(browser_source, "    var stableIdentityKey: String {"),
    block(host_key, "    var hostKey: PeelHostKey {"),
])
session_properties = "\n".join([
    block(endpoint, "    var isUsingDirectEndpoint: Bool {"),
    block(endpoint, "    var directPairingID: String? {"),
])


def adapter_unit(projection_block, adapter_block):
    return (projection_block + "\n"
            + "extension PeelHostInfo {\n" + host_properties + "\n}\n"
            + "extension PeelHostSession {\n" + session_properties + "\n}\n"
            + "extension PeelClientBrowser {\n" + browser_methods + "\n" + adapter_block + "\n}\n")


pure_cases = (HERE / "Checks.swift").read_text()
adapter_cases = (HERE / "AdapterChecks.swift").read_text()
dependencies, cases = adapter_cases.split("// ADAPTER CASES", 1)

units = [
    ("current", "import Foundation\n" + projection + "\n" + pure_cases, True),
    ("adapter-current", dependencies + "\n" + adapter_unit(projection, adapter) + "\n" + cases, True),
]
if "--verify-regression" in sys.argv:
    # Each mutation removes one rule the cases depend on.
    pure_mutations = [
        ("direct-sessions-ignored", projection.replace("            activeDirect.append(session)\n", "")),
        ("duplicate-discovery-listed",
         projection.replace("return !directPairingIDs.contains(pairingID)", "return true")),
        ("saved-record-not-required",
         projection.replace("                  savedIDs.contains(pairingID),\n", "")),
        ("discovery-only-gate",
         projection.replace("hasDiscoveredComputers || !connected.isEmpty || hasConnectedSession",
                            "hasDiscoveredComputers")),
    ]
    for name, mutated in pure_mutations:
        assert mutated != projection, f"Mutation {name} no longer applies; update the runner"
        units.append((name, "import Foundation\n" + mutated + "\n" + pure_cases, False))
    # Restores the reviewed seam: discovered readiness from the global
    # selected-session name instead of the candidate's owning session.
    global_name = adapter.replace("let owned = state(of: owningSession(for: host))",
                                  "let owned = (ready: isConnected(to: host), active: isConnected(to: host))")
    assert global_name != adapter, "Mutation adapter-global-name-readiness no longer applies"
    units.append(("adapter-global-name-readiness",
                  dependencies + "\n" + adapter_unit(projection, global_name) + "\n" + cases, False))

unexpected = False
with tempfile.TemporaryDirectory(prefix="peel-home-projection-") as scratch:
    for name, unit, should_pass in units:
        path = Path(scratch) / (name + ".swift")
        binary = Path(scratch) / name
        path.write_text(unit)
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", str(path), "-o", str(binary)],
                       check=True, timeout=120)
        result = subprocess.run([str(binary)], timeout=15)
        matched = (result.returncode == 0) == should_pass
        unexpected |= not matched
        print(json.dumps({"variant": name,
                          "productionProjectionSHA256": hashlib.sha256(projection.encode()).hexdigest(),
                          "productionAdapterSHA256": hashlib.sha256(
                              (adapter + browser_methods).encode()).hexdigest(),
                          "compiledUnitSHA256": hashlib.sha256(unit.encode()).hexdigest(),
                          "exitCode": result.returncode, "expectedOutcomeMatched": matched}), flush=True)
raise SystemExit(1 if unexpected else 0)
