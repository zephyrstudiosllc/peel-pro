#!/usr/bin/env python3
"""Exercise exact production admission against deterministic, effect-only adapters."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import time


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
        raise ValueError(f"Expected one anchor: {old!r}; got {source.count(old)}")
    return source.replace(old, new, 1)


def admission(host, wire, fixture):
    signatures = [
        "    private func currentSendSnapshot(", "    private func isCurrentSendSnapshot(",
        "    private func isCurrentSendGeneration(", "    private func currentControlAdmissionGeneration(",
        "    private func isCurrentOrIdleControlAdmission(",
        "    private func currentListenerAdmissionEpoch(", "    private func updateControlAdmissionPairingIDs(",
        "    private func invalidatePendingConnections(", "    private func isCurrentPendingConnection(",
        "    private func claimPendingConnection(", "    private enum ControlCandidateClaim",
        "    private func claimPendingControlConnection(", "    private func rejectPendingConnection(",
        "    private func accept(", "    private func handleUnclassifiedConnectionStateUpdate(",
        "    private struct InitialSocketMessageType", "    private func startConnectionClassification(",
        "    private func admitControlCandidate(", "    private func rejectPendingControlCandidate<",
        "    private func promoteControlConnection(", "    private func processIncomingData(",
        "    private func cleanupConnectionOnConnectionQueue("]
    production = "\n\n".join(block(host, signature) for signature in signatures)
    protocol = "enum PeelProtocol {\n"
    for line in wire.splitlines():
        if line.startswith("    static let currentProtocolVersion =") or line.startswith("    static let minimumSupportedProtocolVersion ="):
            protocol += line + "\n"
    # Capabilities are not part of admission; only satisfy the unused Hello
    # initializer's default argument. The actual Codable fields remain intact.
    protocol += "    static let capabilities = Set<String>()\n"
    protocol += block(wire, "    static func isCompatible(") + "\n}"
    types = protocol + "\n\n" + "\n\n".join(block(wire, signature) for signature in (
        "struct ClientHelloMessage:", "struct ProtocolRejectedMessage:", "struct PairingRevokedMessage:"))
    return fixture.replace("/* PRODUCTION_WIRE_TYPES */", types).replace("    /* PRODUCTION_ADMISSION */", production), production


def observer(host, fixture):
    initialization = "        knownControlPairingIDs = Set(pairingStore.paired.map(\\.id))"
    if host.count(initialization) != 1:
        raise ValueError("Expected initial metadata snapshot")
    init = block(host, "    init(pairingStore:")
    pipeline = init[init.index("        pairingCancellable = pairingStore.$paired"):init.rfind("\n    }")]
    updater = block(host, "    private func updateControlAdmissionPairingIDs(")
    production = initialization + "\n" + pipeline + "\n" + updater
    unit = fixture.replace("        /* PRODUCTION_PAIRING_INITIALIZATION */", initialization)
    unit = unit.replace("        /* PRODUCTION_PAIRING_OBSERVER */", pipeline)
    unit = unit.replace("    /* PRODUCTION_PAIRING_MEMBERSHIP_UPDATE */", updater)
    return unit, production


def main():
    parser = argparse.ArgumentParser()
    here = Path(__file__).resolve().parent
    host_root = here.parents[1]
    parser.add_argument("--host-source", type=Path, default=host_root / "Peel-Host/PeelHost/HostNetworkServer.swift")
    parser.add_argument("--wire-source", type=Path, default=host_root / "Peel-Host/PeelSharedMessages.swift")
    parser.add_argument("--swift-version", choices=("5", "6"), default="6")
    parser.add_argument("--verify-regression", action="store_true")
    parser.add_argument("--receipt", type=Path)
    args = parser.parse_args()
    host, wire = args.host_source.read_text(), args.wire_source.read_text()
    variants = [("admission-current", host, True, "admission"), ("observer-current", host, True, "observer")]
    if args.verify_regression:
        variants += [
            ("wrong-discriminator-admitted", replace_once(host, '              hello.type == "clientHello",\n', ''), False, "admission"),
            ("empty-name-admitted", replace_once(host, '              !hello.deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,\n', ''), False, "admission"),
            ("empty-platform-admitted", replace_once(host,
                '              !hello.platform.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {',
                '              hello.type == "clientHello" else {'), False, "admission"),
            ("protocol-mismatch-admitted", replace_once(host,
                '        guard PeelProtocol.isCompatible(remoteCurrent: hello.protocolVersion,\n'
                '                                        remoteMinimum: hello.minimumSupportedProtocolVersion) else {',
                '        guard hello.type == "clientHello" else {'), False, "admission"),
            ("revoked-pairing-admitted", replace_once(host,
                '        guard knownControlPairingIDs.contains(pairingID) else { return .unknownPairing }', ''), False, "admission"),
            ("newer-incumbent-generation-ignored", replace_once(host,
                '              entry.1 == listenerAdmissionEpoch,\n'
                '              isCurrentOrIdleControlAdmission(expectedGeneration) else { return .stale }',
                '              entry.1 == listenerAdmissionEpoch else { return .stale }'), False, "admission"),
            ("listener-epoch-ignored-at-claim", replace_once(host,
                '              entry.1 == listenerAdmissionEpoch,\n'
                '              isCurrentOrIdleControlAdmission(expectedGeneration) else { return .stale }',
                '              isCurrentOrIdleControlAdmission(expectedGeneration) else { return .stale }'), False, "admission"),
            ("idle-reconnect-gap-rejected", replace_once(host,
                '        return sendGeneration == expectedGeneration || (connection == nil && sendConnection == nil)',
                '        return sendGeneration == expectedGeneration'), False, "admission"),
            ("fragmented-candidate-refreshes-generation", replace_once(host,
                '                                                       expectedControlGeneration: expectedControlGeneration)',
                '                                                       expectedControlGeneration: self.currentControlAdmissionGeneration())'), False, "admission"),
            ("rejection-sent-to-incumbent", replace_once(host,
                '        candidate.send(content: data, completion:', '        sendConnection!.send(content: data, completion:'), False, "admission"),
            ("receive-buffer-cleared-before-validation", replace_once(host,
                '                self.admitControlCandidate(activeConn, firstLineData:',
                '                self.receiveBuffer.removeAll()\n                self.admitControlCandidate(activeConn, firstLineData:'), False, "admission"),
            ("membership-update-after-main-hop", replace_once(host,
                '        pairingCancellable = pairingStore.$paired\n'
                '            .handleEvents(receiveOutput: { [weak self] peers in\n'
                '                self?.updateControlAdmissionPairingIDs(Set(peers.map(\\.id)))\n'
                '            })\n'
                '            .receive(on: DispatchQueue.main)',
                '        pairingCancellable = pairingStore.$paired\n'
                '            .receive(on: DispatchQueue.main)\n'
                '            .handleEvents(receiveOutput: { [weak self] peers in\n'
                '                self?.updateControlAdmissionPairingIDs(Set(peers.map(\\.id)))\n'
                '            })'), False, "observer"),
            ("preview-does-not-track-revocations", replace_once(host,
                '            .handleEvents(receiveOutput: { [weak self] peers in\n',
                '            .handleEvents(receiveOutput: { [weak self] peers in\n'
                '                guard observesPairing else { return }\n'), False, "observer"),
        ]
    outcomes = []
    began = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="peel-control-candidate-admission-") as directory:
        folder = Path(directory)
        for name, variant, should_pass, kind in variants:
            fixture = (here / ("Checks.swift" if kind == "admission" else "PairingObserverChecks.swift")).read_text()
            unit, production = (admission(variant, wire, fixture) if kind == "admission" else observer(variant, fixture))
            source, executable = folder / f"{name}.swift", folder / name
            source.write_text(unit)
            command = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", args.swift_version,
                       "-default-isolation", "MainActor", "-warnings-as-errors", str(source), "-o", str(executable)]
            compiled = subprocess.run(command, capture_output=True, text=True, timeout=60)
            if compiled.returncode:
                print(compiled.stdout, end=""); print(compiled.stderr, end="")
                raise SystemExit(f"Compilation failure never counts as a killed mutant: {name}")
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=15)
            # Retain unexpected runtime diagnostics in the receipt while keeping
            # the console focused on the assertion and outcome.
            print(result.stdout, end="")
            outcome = {"variant": name, "swiftVersion": args.swift_version,
                       "expectedOutcomeMatched": (result.returncode == 0) == should_pass,
                       "exitCode": result.returncode, "productionBoundariesSHA256": hashlib.sha256(production.encode()).hexdigest(),
                       "compiledUnitSHA256": hashlib.sha256(unit.encode()).hexdigest(),
                       "stderr": result.stderr[:3000]}
            outcomes.append(outcome)
            print(json.dumps({key: value for key, value in outcome.items() if key != "stderr"}), flush=True)
    receipt = {"hostSHA256": hashlib.sha256(host.encode()).hexdigest(),
               "wireSHA256": hashlib.sha256(wire.encode()).hexdigest(),
               "swiftVersion": args.swift_version, "elapsedSeconds": round(time.monotonic() - began, 3),
               "scope": "No sockets, Host launch, Keychain, pairing persistence, capture, native input or device operations",
               "outcomes": outcomes, "passed": all(row["expectedOutcomeMatched"] for row in outcomes)}
    if args.receipt:
        args.receipt.parent.mkdir(parents=True, exist_ok=True)
        args.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps({key: value for key, value in receipt.items() if key != "outcomes"}), flush=True)
    raise SystemExit(0 if receipt["passed"] else 1)


if __name__ == "__main__":
    main()
