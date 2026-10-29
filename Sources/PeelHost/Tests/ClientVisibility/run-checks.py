#!/usr/bin/env python3
"""Compile real Host visibility boundaries against in-memory effect recorders.

No Host launch, network, Keychain, UserDefaults, capture, audio or input injection.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def block(source, signature):
    start = source.index(signature)
    brace = source.index("{", start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def replace_once(source, old, new):
    if source.count(old) != 1:
        raise ValueError(f"Expected exactly one mutation/extraction anchor: {old!r}")
    return source.replace(old, new, 1)


def production(host, wire):
    fields = "\n".join(line for line in host.splitlines()
                       if line.startswith("    private var clientIsVisible:")
                       or line.startswith("    private var clientHasReportedVisibility:"))
    if fields.count("private var") != 2:
        raise ValueError("Expected both production visibility state declarations")

    connect = block(host, "    func hostNetworkServerDidConnect(")
    connect = connect[connect.index("        clientIsVisible = true\n"):
                      connect.index("        // New control connection")]
    disconnect = block(host, "    func hostNetworkServerDidDisconnect(")
    disconnect = disconnect[disconnect.index("        stopClientPingMonitor()\n"):]
    # This tail includes the original closing brace of the disconnect method.
    lifecycle = "    func connect(generation: UInt64) {\n"
    lifecycle += "        network.currentGeneration = generation\n" + connect + "    }\n"
    lifecycle += "    func disconnect() {\n" + disconnect + "\n"

    route = block(host, "    private func handleLineInReceivedSession(")
    prefix = route[route.index("\n") + 1:route.index("        do {\n")]
    visibility = route.split('            case "clientVisibility":\n', 1)[1]
    visibility = visibility.split('            case "clientPing":', 1)[0]
    receive = "    func receiveVisibility(_ line: String, generation: UInt64?) {\n" + prefix
    receive += "        do {\n"
    receive += "            let envelope = try decoder.decode(MessageEnvelope.self, from: data)\n"
    receive += '            guard envelope.type == "clientVisibility" else { return }\n'
    receive += visibility
    receive += "        } catch { decodeFailures += 1 }\n    }\n"

    request = block(host, "    private func handle(request:")
    request = request.replace("private func", "func", 1)
    video = block(host, "    func hostNetworkServer(\n        _ server: HostNetworkServer,\n        didOpenVideoStreamForWindow")
    awake = block(host, "    private func updateAwakePolicy(")
    permission = block(host, "    private func isRemoteControlAllowed(")
    # Only OS permission reads become in-memory fixture reads. The actual
    # combined locked/visible/permission/trust predicate remains unchanged.
    permission = permission.replace("UserDefaults.standard", "FixturePermissions.standard")
    permission = permission.replace("AXIsProcessTrusted()", "FixturePermissions.axTrusted")
    types = "\n".join(block(wire, signature) for signature in (
        "struct PeelRequest:", "struct ClientVisibilityMessage:",
        "public struct MessageEnvelope:", "struct InputRejectedMessage:",
        "struct HostStreamDebugMessage:"))
    transitions = "\n".join((fields, lifecycle, receive, request, video, awake, permission))
    return types, transitions


def main():
    parser = argparse.ArgumentParser()
    host_root = Path(__file__).resolve().parents[2]
    parser.add_argument("--host-source", type=Path,
                        default=host_root / "Peel-Host/PeelHost/PeelHost.swift")
    parser.add_argument("--wire-source", type=Path,
                        default=host_root / "Peel-Host/PeelSharedMessages.swift")
    parser.add_argument("--swift-version", choices=("5", "6"), default="5")
    parser.add_argument("--verify-regression", action="store_true")
    arguments = parser.parse_args()
    host = arguments.host_source.read_text()
    wire = arguments.wire_source.read_text()
    fixture = Path(__file__).with_name("Checks.swift").read_text()
    variants = [("current", host, True)]
    if arguments.verify_regression:
        variants += [
            ("enumeration-overrides-explicit-hidden", replace_once(host,
                "            if !clientHasReportedVisibility {\n                clientIsVisible = true\n            }",
                "            clientIsVisible = true"), False),
            ("explicit-message-not-remembered", replace_once(host,
                "                clientHasReportedVisibility = true\n", ""), False),
            ("connect-keeps-previous-visibility-owner", replace_once(host,
                "        clientIsVisible = true\n        clientHasReportedVisibility = false\n",
                "        clientIsVisible = true\n"), False),
            ("disconnect-keeps-previous-visibility-owner", replace_once(host,
                "        clientIsVisible = false\n        clientHasReportedVisibility = false\n",
                "        clientIsVisible = false\n"), False),
            ("stale-generation-accepted", replace_once(host,
                '        if let generation, !network.isCurrentControlGeneration(generation) {\n'
                '            logRejectedClientFocusLine(line, generation: generation, reason: "staleControlGenerationAtReceive")\n'
                '            return\n        }\n', ""), False),
            ("locked-visibility-accepted", replace_once(host,
                '        guard hostIsLockedOrAsleep == false else {\n'
                '            logRejectedClientFocusLine(line, generation: generation, reason: "hostLockedOrAsleepAtReceive")\n'
                '            return\n        }\n', ""), False),
        ]
    outcomes = []
    with tempfile.TemporaryDirectory(prefix="peel-host-client-visibility-") as directory:
        temporary = Path(directory)
        for name, variant, should_pass in variants:
            types, transitions = production(variant, wire)
            unit = fixture.replace("/* PRODUCTION_TYPES */", types)
            unit = unit.replace("/* PRODUCTION_HOST_BOUNDARIES */", transitions)
            source = temporary / f"{name}.swift"
            executable = temporary / name
            source.write_text(unit)
            command = ["xcrun", "swiftc", "-swift-version", arguments.swift_version,
                       "-default-isolation", "MainActor",
                       "-warnings-as-errors", str(source), "-o", str(executable)]
            # A compiler failure never counts as a successfully killed mutant.
            compiled = subprocess.run(command, capture_output=True, text=True, timeout=60)
            if compiled.returncode:
                print(compiled.stdout, end="")
                print(compiled.stderr, end="")
                raise SystemExit(compiled.returncode)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=15)
            print(result.stdout, end="")
            print(result.stderr, end="")
            outcome = {"variant": name, "swiftVersion": arguments.swift_version,
                       "expectedOutcomeMatched": (result.returncode == 0) == should_pass,
                       "exitCode": result.returncode,
                       "hostSHA256": hashlib.sha256(host.encode()).hexdigest(),
                       "wireSHA256": hashlib.sha256(wire.encode()).hexdigest(),
                       "productionBoundariesSHA256": hashlib.sha256(transitions.encode()).hexdigest(),
                       "compiledUnitSHA256": hashlib.sha256(unit.encode()).hexdigest()}
            print(json.dumps(outcome), flush=True)
            outcomes.append(outcome)
    raise SystemExit(0 if all(outcome["expectedOutcomeMatched"] for outcome in outcomes) else 1)


if __name__ == "__main__":
    main()
