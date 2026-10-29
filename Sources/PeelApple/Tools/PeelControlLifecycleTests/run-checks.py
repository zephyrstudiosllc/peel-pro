#!/usr/bin/env python3
"""Exercise production control lifecycle transitions using queued synthetic sockets."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / "Shared/Client/ClientBrowser"

def block(text, signature):
    start = text.index(signature)
    brace = text.index("{", start)
    depth, end = 1, brace + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]

all_connection = (BASE / "Connection.swift").read_text()
connection = all_connection.split("extension PeelHostSession {", 1)[1]
lifecycle = (BASE / "LifecycleStreams.swift").read_text()
evidence = (ROOT / "Shared/Client/PeelProEvidenceClient.swift").read_text()
receive = (BASE / "Receive.swift").read_text().split("extension PeelHostSession {", 1)[1]
window_list = receive.split('            case "windowList":\n', 1)[1].split('            case "windowGeometry":', 1)[0]
state_handler = block(connection, "        newConnection.stateUpdateHandler =")
methods = [block(connection, "    func " + name + "(") for name in
           ("handleDisconnectOnce", "matchesReconnectTarget", "sendWindowListRequest", "deferConnectionWhileHidden")]
# Exercise the real entry/admission and manual-intent prefix, not a second
# handwritten model. The tail stands in for resolve/TLS side effects, which are
# outside this synthetic fixture. The actual queued ready handler is below.
connect = block(connection, "    func connectAndRequestWindows(")
connect_entry = connect.split("        let now = Date()", 1)[0]
connect_entry += """        transportAdmissions += 1
        FixtureScheduler.main.async { self.isConnectBusy = true }
    }"""
methods += [connect_entry]
methods += [block(lifecycle.split("extension PeelHostSession {", 1)[1], "    func attemptPendingReconnectIfPossible("),
            block(receive, "    func startReceiveLoop(")]
methods += ["    func receiveWindowList(_ data: Data, sourceConnection: NWConnection?) throws {\n" + window_list + "\n    }"]
methods += ["    func installHandler(on newConnection: NWConnection) {\n"
            "        let activeConn = newConnection\n        let browser = self.browser!\n"
            "        let connectionPSKOrder = 0\n" + state_handler + "\n    }"]
production = "extension PeelHostSession {\n" + "\n".join(methods) + "\n}\n"
production += "extension PeelClientBrowser {\n" + "\n".join([
    block(lifecycle, "    func attemptPendingReconnectIfPossible("),
    block(lifecycle, "    func setClientVisibility("),
    block(all_connection, "    func scheduleReconnect("),
    block(all_connection, "    func sendWindowListRequest("),
    block(all_connection, "    func handleDisconnectOnce("),
    # setClientVisibility retires signed Pro evidence through this real method.
    block(evidence, "    func invalidateProEvidence(")]) + "\n}\n"
adapted = production.replace("DispatchQueue.main", "FixtureScheduler.main").replace("Thread.isMainThread", "FixtureScheduler.isMainThread")
# Foundation's actual DispatchWorkItem cancellation is preserved; only ordering
# and the main-thread predicate are controlled by this fixture.
fixture = (ROOT / "Tools/PeelControlLifecycleTests/Checks.swift").read_text()
dependencies, cases = fixture.split("// REGRESSION CASES", 1)
variants = [("current", adapted, True)]
if "--verify-regression" in sys.argv:
    variants += [
        ("hidden-entry-admission", adapted.replace("        guard !deferConnectionWhileHidden() else { return }\n", "", 1), False),
        ("hidden-ready-admission", adapted.replace("""                    guard self.isClientVisible else {
                        self.handleDisconnectOnce("Client became inactive before connection ready", sourceConnection: activeConn)
                        return
                    }
""", "", 1), False),
        ("stale-state-callback", adapted.replace("                guard self.connection === activeConn else { return }\n", "", 1), False),
        ("stale-disconnect", adapted.replace("                  self.connection === disconnectingConnection,\n", "", 1), False),
        ("missing-bonjour-resume", adapted.replace("for session in sessionsByHostKey.values {", "for session in sessionsByHostKey.values where session.isUsingDirectEndpoint {", 1), False),
        ("legacy-lifecycle-owner", adapted.replace("let usesLegacyTransport = activeSessions.isEmpty", "let usesLegacyTransport = true", 1), False),
        ("lagging-browser-mirror", adapted.replace("            guard self.sessionsByHostKey.isEmpty else { return }\n", "", 1), False),
        ("legacy-browser-reset-owner", adapted.replace("""            if let owner = self.sessionsByHostKey.values.first(where: {
                $0.connection === disconnectingConnection
            }) {
                owner.handleDisconnectOnce(reason, sourceConnection: disconnectingConnection)
                return
            }
""", "", 1), False),
        ("stale-window-list", adapted.replace(
            "                    guard let sourceConnection, self.connection === sourceConnection else { return }\n", "", 1), False),
        ("legacy-visibility-tail", adapted.replace(
            "if pendingReconnectWhenVisible, connection == nil,\n               !activeSessions.contains(where: { matchesReconnectTarget($0.host) }) {",
            "if pendingReconnectWhenVisible, connection == nil {"), False),
        ("unbound-send-failure", adapted.replace(", sourceConnection: connection)", ")"), False),
        ("unbound-receive-failure", adapted.replace("self.handleDisconnectOnce(reason, sourceConnection: activeConn)", "self.handleDisconnectOnce(reason)"), False),
        ("evidence-not-retired", adapted.replace("        invalidateProEvidence()\n", "", 1), False),
        ("evidence-before-visibility", adapted.replace("        invalidateProEvidence()\n", "", 1).replace(
            "        isClientVisible = visible\n", "        invalidateProEvidence()\n        isClientVisible = visible\n", 1), False),
        ("evidence-client-skipped", adapted.replace("client.localAccessOrVisibilityChanged()", "_ = client", 1), False),
    ]
    for name, mutated, _ in variants[1:]:
        assert mutated != adapted, f"Mutation {name} no longer applies; update the runner"
unexpected = False
with tempfile.TemporaryDirectory(prefix="peel-control-lifecycle-") as scratch:
    for name, transitions, should_pass in variants:
        source = Path(scratch) / (name + ".swift")
        executable = Path(scratch) / name
        unit = dependencies + "\n" + transitions + "\n" + cases
        source.write_text(unit)
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", str(source), "-o", str(executable)], check=True, timeout=60)
        result = subprocess.run([str(executable)], timeout=15)
        matched = (result.returncode == 0) == should_pass
        unexpected |= not matched
        print(json.dumps({"variant": name, "expectedOutcomeMatched": matched,
                          "exitCode": result.returncode,
                          "productionTransitionsSHA256": hashlib.sha256(production.encode()).hexdigest(),
                          "compiledUnitSHA256": hashlib.sha256(unit.encode()).hexdigest()}), flush=True)
raise SystemExit(1 if unexpected else 0)
