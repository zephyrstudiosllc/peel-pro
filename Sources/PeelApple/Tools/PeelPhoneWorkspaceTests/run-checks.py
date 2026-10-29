#!/usr/bin/env python3
"""Compile the actual phone layout/stream-transition policy without UIKit."""
from pathlib import Path
import subprocess
import tempfile

def block(text, signature):
    start = text.index(signature)
    brace = text.index("{", start)
    depth, end = 1, brace + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end].replace("private ", "")

root = Path(__file__).resolve().parents[2]
source = (root / "Peel-iPad/iPhoneDevelopmentWorkspace.swift").read_text()
policy = source[source.index("enum PeelPhoneWorkspacePane:"):]
checks = (Path(__file__).parent / "Checks.swift").read_text()
geometry = (root / "Peel-iPad/PeelPhoneWorkspaceGeometry.swift").read_text()
geometry_checks = (Path(__file__).parent / "GeometryChecks.swift").read_text()
with tempfile.TemporaryDirectory(prefix="peel-phone-workspace-") as tmp:
    swift = Path(tmp) / "Checks.swift"
    exe = Path(tmp) / "checks"
    swift.write_text("import Foundation\n" + policy + "\n" + geometry + "\n" + checks + "\n" + geometry_checks)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", str(swift), "-o", str(exe)], check=True, timeout=60)
    subprocess.run([str(exe)], check=True, timeout=15)
    streams = (root / "Peel-iPad/PeelPhoneWorkspaceStreams.swift").read_text()
    lease_checks = (Path(__file__).parent / "LeaseChecks.swift").read_text()
    swift.write_text("import Foundation\n" + policy + "\n" + streams + "\n" + lease_checks)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", str(swift), "-o", str(exe)], check=True, timeout=60)
    subprocess.run([str(exe)], check=True, timeout=15)

    availability = (root / "Peel-iPad/PeelPhoneSceneAvailability.swift").read_text()
    coordinator = (root / "Peel-iPad/iPhoneAgentPresentationCoordinator.swift").read_text()
    scene_checks = (Path(__file__).parent / "SceneChecks.swift").read_text()
    scene_checks = scene_checks.replace("// ROUTE METHOD", block(coordinator, "    private func setRouteRegistered("))
    swift.write_text(availability + "\n" + scene_checks)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", str(swift), "-o", str(exe)], check=True, timeout=60)
    subprocess.run([str(exe)], check=True, timeout=15)

    pane = (root / "Peel-iPad/iPadPeeledWindowView.swift").read_text()
    pointer_methods = "\n".join(block(pane, signature) for signature in [
        "    private func cancelPointerInteraction(", "    private func releaseLocalMouseDownIfNeeded("
    ])
    pointer_checks = (Path(__file__).parent / "PointerChecks.swift").read_text()
    swift.write_text(pointer_checks.replace("// POINTER METHODS", pointer_methods))
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", str(swift), "-o", str(exe)], check=True, timeout=60)
    subprocess.run([str(exe)], check=True, timeout=15)

    adapter = block(source, "    private func geometryPlan(")
    pane_enum = block(source, "enum PeelPhoneWorkspacePane:")
    adapter_checks = (Path(__file__).parent / "RegionAdapterChecks.swift").read_text()
    swift.write_text(pane_enum + "\n" + geometry + "\n" + adapter_checks.replace("// REGION ADAPTER", adapter))
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", str(swift), "-o", str(exe)], check=True, timeout=60)
    subprocess.run([str(exe)], check=True, timeout=15)
