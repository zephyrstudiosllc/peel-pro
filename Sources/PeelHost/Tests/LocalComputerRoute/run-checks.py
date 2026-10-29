#!/usr/bin/env python3
"""Compile the exact Host local-computer route with the real InputSynthesizer,
window controller, leases, local-access state and app catalog.

Only OS window lists, focus, capture output, permission reads and event posting
are replaced. The catalog scans the real /System/Applications read-only; launch
is recorded, never performed. No Host launch, socket, Keychain, TCC change,
capture or input injection.

  --verify-regression   also compile mutants that must fail.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
host_dir = root / "Peel-Host"


def declaration(source, marker):
    start = source.index(marker)
    brace = source.index("{", start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def replace_once(source, old, new):
    if source.count(old) != 1:
        raise ValueError(f"Expected exactly one anchor: {old!r}")
    return source.replace(old, new, 1)


HOST_MEMBERS = [
    "    func setLocalComputerAccessAllowed(",
    "    private func configureLocalComputerAccess(",
    "    private func revokeLocalComputerAccess(",
    "    private func interruptLocalAgentRequests(",
    "    private func localControlWindowIsReady(",
    "    private func inputControlGenerationIsCurrent(",
    "    private func isLocalControlAllowed(",
    "    private func localScreenCaptureAllowed(",
    "    private func localControlPermissions(",
    "    private var localComputerDeviceJSON:",
    "    private func localAgentPolicyAllows(",
    "    private func localRequestAuthority(",
    "    private func localFocusAuthority(",
    "    private func endLocalRequest(",
    "    private func localWindowIsEligible(",
    "    private func localWindowJSON(",
    "    private static func localLaunchErrorCode(",
    "    private func localRequestFinisher(",
    "    private func handleLocalComputerRequest(",
    "    private func handleLocalWindowControl(",
    "    private func handleHostCommand(",
]


def production_route(host):
    blocks = []
    for marker in HOST_MEMBERS:
        block = declaration(host, marker)
        blocks.append(block.replace("    private ", "    ", 1))
    start = host.index("    private static let localComputerSupportedMethods")
    end = host.index("]\n", start) + 2
    blocks.append(host[start:end].replace("    private ", "    ", 1))
    route = "\n".join(blocks)
    # Only OS permission reads become in-memory fixture reads.
    route = route.replace("UserDefaults.standard.bool(forKey: Self.allowControlThisMacDefaultsKey)", "FixturePermissions.masterGate")
    route = route.replace("AXIsProcessTrusted()", "FixturePermissions.accessibility")
    route = route.replace("CGPreflightScreenCaptureAccess()", "FixturePermissions.screenCapture")
    for leaked in ("UserDefaults.standard", "AXIsProcessTrusted", "CGPreflightScreenCaptureAccess", "NSRunningApplication"):
        if leaked in route:
            raise ValueError(f"Unexpected live OS read in extracted route: {leaked}")
    return route


def production_focus_sequence():
    """The real local AX entry point and staged sequence. Only each raise's AX
    effects after its own authority/PID guard and the activation effect are
    replaced by recorded fakes; stage delays are kept."""
    ax = (host_dir / "PeelHost/AccessibilityManager.swift").read_text()
    entry = declaration(ax, "    func bringWindowToFrontForLocalAgent(")
    entry = replace_once(entry, "    func bringWindowToFrontForLocalAgent(", "    func productionBringWindowToFrontForLocalAgent(")
    entry = replace_once(entry, "AXIsProcessTrustedWithOptions(nil)", "FixturePermissions.accessibility")
    entry = replace_once(entry, "NSRunningApplication(processIdentifier: pid) != nil", "pid > 0")
    sequence = declaration(ax, "    private func runAuthoritativeBringToFrontSequence(").replace("    private ", "    ", 1)
    hop = "DispatchQueue.main.asyncAfter(deadline: .now() + "
    if sequence.count(hop) != 3:
        raise ValueError("Expected three staged main-queue delays")
    sequence = sequence.replace(hop, "FixtureMain.after(")
    start = ax.index("    private func performAXRaiseAttempt(")
    head = ax[start:ax.index("        let appElement = AXUIElementCreateApplication(pid)\n", start)]
    head = replace_once(head, "AXIsProcessTrustedWithOptions(nil)", "FixturePermissions.accessibility").replace("    private ", "    ", 1)
    raise_attempt = head + "        recordStagedRaise(windowId: windowId, pid: pid, phase: diagnosticPhase)\n        return true\n    }\n"
    route = "\n".join([entry, sequence, raise_attempt])
    for leaked in ("AXUIElement", "AXIsProcessTrusted", "NSRunningApplication", "NSWorkspace", "DispatchQueue.main"):
        if leaked in route:
            raise ValueError(f"Unexpected live OS effect in extracted focus sequence: {leaked}")
    return route


def source_invariants(host):
    """Structural invariants that a compiled fixture cannot observe directly."""
    locked = declaration(host, "    private var hostIsLockedOrAsleep: Bool = false {")
    assert "revokeLocalComputerAccess(reason:" in locked, "lock/sleep must revoke local access"
    assert "revokeLocalComputerAccess(reason:" in declaration(host, "    func stopLocalAgentBridge("), "bridge stop must revoke"
    line = declaration(host, "    private func handleLineInReceivedSession(")
    assert "interruptLocalAgentRequests(" in line, "paired user input must interrupt local agent requests"
    assert "handleHostCommand(msg, generation: generation)" in line, "host commands carry their session generation"
    request = declaration(host, "    private func handleLocalAgentRequest(")
    local = request.index("PeelLocalComputerAccess.isLocalTarget(requested)")
    assert local < request.index("guard case .string(let pairingID) = request.params[\"targetPairingId\"]"), \
        "local branch must precede paired-target lookup"
    assert local > request.index("if request.method == .listDevices {"), "local branch follows bridge-wide methods"
    for name in ("handleLocalAgentRequest", "handleLocalComputerRequest", "handleLocalWindowControl"):
        body = declaration(host, f"    private func {name}(")
        assert "setAllowed(" not in body and "setLocalComputerAccessAllowed(" not in body, \
            f"{name} must never grant local consent"
        assert "commerceAllows" not in body or name == "handleLocalAgentRequest", f"{name} has no paid gate"
    wiring = declaration(host, "    private func wireControllers(")
    assert ("        accessibility.isRemoteControlAllowed = { [weak self] in\n"
            "            self?.isRemoteControlAllowed() ?? false\n        }") in wiring, \
        "the shared AX predicate is exactly the paired-client predicate"
    assert ("        accessibility.sendInputRejected = { [weak self] windowId, reason in\n"
            "            self?.network.sendJSONLine(InputRejectedMessage(windowId: windowId, reason: reason))\n        }") in wiring, \
        "paired rejection delivery is unchanged"
    for anchor in ("inputControlGenerationIsCurrent(generation)", "isLocalControlAllowed()", "localControlWindowIsReady(windowId)"):
        assert anchor in wiring, f"wireControllers must install {anchor}"
    assert "localComputerAccess" not in wiring.replace("configureLocalComputerAccess()", ""), \
        "no local authority is lent to a shared paired gate"
    assert "accessibilityControlAllowed" not in host, "no union of local and paired AX authority"
    for name in ("handleLocalComputerRequest", "handleLocalWindowControl"):
        body = declaration(host, f"    private func {name}(")
        assert "accessibility.bringWindowToFront(" not in body, f"{name} must not use the paired focus sequence"
        assert "isExactWindowFocusedForAgentInput(windowId: windowID)" not in body, f"{name} must pass its own authority"
    assert "bringWindowToFrontForLocalAgent(windowId: windowID, authorized: authority)" in host, "local focus carries its authority"
    assert ("let authority = localFocusAuthority(requestAuthority, windowID: windowID, advertised: advertised)"
            in declaration(host, "    private func handleLocalComputerRequest(")), \
        "local focus authority is bound to the advertised window and app instance"
    ax = (host_dir / "PeelHost/AccessibilityManager.swift").read_text()
    for name in ("closeWindow", "minimizeWindow", "focusAuthoritativeWindowIfNeeded"):
        assert "guard isRemoteControlAllowed() else" in declaration(ax, f"    func {name}("), f"{name} keeps the paired gate"
    local_ax = declaration(ax, "    func bringWindowToFrontForLocalAgent(")
    assert "authorized()" in local_ax and "shouldContinue: authorized" in local_ax and "authorized: authorized" in local_ax, \
        "local AX path checks its own authority at entry and every stage"
    sequence = declaration(ax, "    private func runAuthoritativeBringToFrontSequence(")
    assert sequence.count("authorized: authorized") == 4 and "if (authorized ?? { true })() {" in sequence, \
        "every staged raise and the activation recheck the supplied authority"
    assert "PeelLocalComputerWindowPolicy.postedEventMarker" in host, "posted events are marked"
    catalog = (host_dir / "AgentBridge/PeelAgentAppCatalog.swift").read_text()
    assert '"/System/Applications"' in catalog and "maximumFolderDepth = 2" in catalog, "catalog covers system apps"
    for app in ("/System/Applications/System Settings.app", "/System/Applications/Utilities/Terminal.app"):
        assert Path(app).is_dir(), f"expected real application bundle {app}"


def build_and_run(host, synthesizer, label, should_pass, folder):
    fixture = (Path(__file__).with_name("Checks.swift")).read_text()
    fixture = replace_once(fixture, "/* PRODUCTION_LOCAL_ROUTE */", production_route(host))
    fixture = replace_once(fixture, "/* PRODUCTION_LOCAL_FOCUS_SEQUENCE */", production_focus_sequence())
    network = (host_dir / "PeelHost/HostNetworkServer.swift").read_text()
    shim = (host_dir / "PeelHost/WindowEnumerator.swift").read_text()
    shim = '@_silgen_name("CGWindowListCreateImage")' + shim.split('@_silgen_name("CGWindowListCreateImage")')[1]
    stubs = "import Foundation\nimport AppKit\n\n" + declaration(network, "nonisolated struct PeelControlSession") + "\n" + shim + "\n"
    work = folder / label
    work.mkdir()
    (work / "Checks.swift").write_text(fixture)
    (work / "Stubs.swift").write_text(stubs)
    (work / "InputSynthesizer.swift").write_text(synthesizer)
    sources = [host_dir / p for p in [
        "PeelSharedMessages.swift", "PeelStreamDiagnosticsMessages.swift",
        "PeelHost/PeelPointerInput.swift", "PeelHost/PeelKeyboardEventFactory.swift",
        "AgentBridge/PeelLocalAgentServer.swift", "AgentBridge/PeelAgentPresentationPolicy.swift",
        "AgentBridge/PeelAgentControlPolicy.swift", "AgentBridge/PeelAgentWindowControl.swift",
        "AgentBridge/PeelAgentAppCatalog.swift", "AgentBridge/PeelLocalComputerAccess.swift"]]
    executable = work / "checks"
    compiled = subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
        "-default-isolation", "MainActor", "-strict-concurrency=complete", "-warnings-as-errors",
        *map(str, sources), str(work / "InputSynthesizer.swift"), str(work / "Stubs.swift"),
        str(work / "Checks.swift"), "-o", str(executable)])
    passed = compiled.returncode == 0 and subprocess.run([str(executable)]).returncode == 0
    if passed != should_pass:
        raise SystemExit(f"{label}: expected {'pass' if should_pass else 'failure'}")
    print(f"{'PASS' if passed else 'EXPECTED FAILURE'} {label}", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--verify-regression", action="store_true")
    arguments = parser.parse_args()
    host = (host_dir / "PeelHost/PeelHost.swift").read_text()
    synthesizer = (host_dir / "PeelHost/InputSynthesizer.swift").read_text()
    source_invariants(host)
    print("PASS source invariants", flush=True)
    variants = [("current", host, synthesizer, True)]
    if arguments.verify_regression:
        variants += [
            ("local-uses-paired-authority", host, replace_once(synthesizer,
                "? isLocalControlAllowed() : isRemoteControlAllowed()",
                "? isRemoteControlAllowed() : isRemoteControlAllowed()"), False),
            ("local-moves-paired-focus", host, replace_once(synthesizer,
                "        guard !Self.isLocalControlGeneration(generation.control) else { return }\n", ""), False),
            ("own-window-listed", replace_once(host,
                "                .filter { localWindowIsEligible($0.1) }\n", ""), synthesizer, False),
            ("local-list-uses-remote-enumeration", replace_once(host,
                "            let eligible = localWindowListing()\n",
                "            let eligible = WindowEnumerator.enumerateWindows().map { ($0, agentWindowFingerprint($0)) }\n"),
                synthesizer, False),
            ("local-inspect-uses-remote-enumeration", replace_once(host,
                "              let window = localFocusWindowRow(windowID: windowID),\n",
                "              let window = WindowEnumerator.enumerateWindows().first(where: { $0.windowId == windowID }),\n"),
                synthesizer, False),
            ("authority-ignores-owner", replace_once(host,
                "                self.localComputerAccess.isAuthorityCurrent(owner) &&\n", ""), synthesizer, False),
            ("person-input-keeps-idle-leases", replace_once(host,
                "        localControlOwner = nil\n        localWindowControl.cancel(input: input, reason: reason)\n",
                "        localControlOwner = nil\n"), synthesizer, False),
            ("deadline-cancels-any-owner", replace_once(host,
                "                if self.localControlOwner?.owner == owner {\n",
                "                if self.localControlOwner != nil {\n"), synthesizer, False),
            ("policy-ignores-caller-lifetime", replace_once(host,
                " &&\n            request.lifetime.isActive\n", "\n"), synthesizer, False),
            ("host-command-ignores-generation", replace_once(host,
                "                guard self.network.isCurrentControlGeneration(generation), self.isRemoteControlAllowed() else { return }\n                self.accessibility.closeWindow(windowId: windowId)",
                "                guard generation != 0, self.isRemoteControlAllowed() else { return }\n                self.accessibility.closeWindow(windowId: windowId)"), synthesizer, False),
            ("focus-authority-ignores-window", replace_once(host,
                "            let authority = localFocusAuthority(requestAuthority, windowID: windowID, advertised: advertised)\n",
                "            let authority = requestAuthority\n"), synthesizer, False),
            ("focus-authority-ignores-launch", replace_once(host,
                "            return self.localApplicationMatches(advertised)\n",
                "            return true\n"), synthesizer, False),
        ]
    with tempfile.TemporaryDirectory(prefix="peel-local-computer-route-") as directory:
        for label, host_variant, synthesizer_variant, should_pass in variants:
            build_and_run(host_variant, synthesizer_variant, label, should_pass, Path(directory))


if __name__ == "__main__":
    main()
